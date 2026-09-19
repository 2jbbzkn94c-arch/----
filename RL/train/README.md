# RL 训练流水线（搭好 + 试点）

本目录只放**训练流水线本体**，不改任何游戏代码。所有对局都跑在冻结的整局对局引擎
`RL/harness/对局.tscn` 上，规则由真实 `Battle` 结算。

## 文件

| 文件 | 作用 |
|---|---|
| `Train.ps1` | 入口。子任务：`selftest` / `coverage` / `gen` / `run` / `status` / `estimate` / `compare` / `repair` |
| `RlTrain.ps1` | 库：权重生成、阵容生成、Godot 调度、`R|m|` 解析、统计、配对比较、审计记录、报告渲染 |
| `train_spec.json` | 协议：种子划分、阵容池 stride、参数网格、每配置 beam、阶段预算、验收标准 |
| `sensitivity_design.md` | 敏感度体检 + 分阶段训练方案（设计稿，含预算与门槛） |
| `Find-Strides.ps1` | 一次性离线搜索：训练阵容 stride 表（保证每个英雄 ≥2 次出场） |
| `Find-HoldoutStrides.ps1` | 一次性离线搜索：留出阵容 stride 表（保证与训练阵容零重合） |
| `lineup_coverage.md` | `-Task coverage` 生成的阵容覆盖统计（英雄×出现次数、训练/留出逐 seed 阵容） |
| `results/<run>/measure.csv` | 解析后的每局一行（主键 `config+seed+first+seq`，含 `weights_sha12` / `audit` 审计列） |
| `results/<run>/raw_lines.log` | **原始 `R|` 行逐字留档**（append-only；每批表头含 `exit/wall_s/e_deck/p_deck/audit=[…]`） |
| `results/<run>/summary.csv` | 每个配置的汇总（N/W/L/D/胜率/Wilson/场均分差） |
| `results/<run>/b_*.out`、`b_*.godot.log` | 每批 Godot 的 stdout 与引擎日志原文 |
| `results/<run>/RUNNING.lock` | 并发写保护（同一 run 只允许一个写者；异常退出残留的锁会打印 pid 与 age） |

> `raw_lines.log` 是权威原文；`measure.csv` 只是它的结构化副本，可用 `-Task repair` 从原文
> **完整重建并按测量主键去重**。报告里每个结论都能追到具体原始行
> （`measure.csv` 的 `batch_out` + `line_no` 定位到 `b_*.out` 的第几行）。

### 可审计性（每次跑都必须有）

`对局.gd` 的 `R|cfg|` 行只打印 **脚本哈希 + `nA`（收到多少项权重）+ beam**，**不打印权重内容哈希**，
而它是冻结文件不能改。所以驱动自己记录：

* `raw_lines.log` 每批表头：`audit=[w=<权重 sha256 前12> beam=… jitter=… kill=… focus=… engage=… threat=… hv=<非1.0个数>/<总数> entries=<键数>]`
* `measure.csv` 的 `weights_sha12` 与 `audit` 两列（同内容，便于按行筛选）。

实测样例（同一 `fp`、不同 `sha12` = "θ 相同、只有算力不同"）：

```
[cfg] beam_ctrl file=cand_beamsweep_beam_ctrl.json fp=4e45698ba19c5d6f sha12=986383dae431 | w=986383dae431 beam=1200 jitter=0.0 kill=35.0 focus=30.0 engage=1.2 threat=0.70 hv=49/45 entries=22
[cfg] beam_200  file=cand_beamsweep_beam_200.json  fp=4e45698ba19c5d6f sha12=3b274007c05d | w=3b274007c05d beam=200  jitter=0.0 kill=35.0 focus=30.0 engage=1.2 threat=0.70 hv=49/45 entries=22
```

**`nA` 是最该看的注入健康指标**：它等于权重文件的键数（含 `_` 说明键）。`nA=0` 就说明权重
根本没送到 A 方；实测正常值为 22。

### 版本闸门（哈希守卫）——防止两个版本混进同一张表

**背景**：候选 `RL/ai/AI_Battle.gd` 与规则脚本会随实机 DIFF 修复而变
（实测 08:24:50：`da8ab33c3306` → `6f62d5a77c83`，`技能对拍.gd` 同时从 `e5488c08151f` → `fe95eae9b3ed`）。
若把一个版本的结果追加进另一个版本的 `measure.csv`，整张表就报废了——**而且看不出来**。

`Start-MeasureRun` 在**写任何行之前**做硬校验：

1. 记录四个脚本哈希：`cand`（候选 `AI_Battle.gd`）、`base`（原版副本）、`duel`（`对局.gd`）、
   `skil`（`技能对拍.gd`），写入 `results/<run>/run_manifest.json`；
2. 同一 run 再跑时比对：一致 → 正常追加；**不一致 → 抛错拒绝开跑**。
   显式给 `-AllowHashChange` 才会把旧 manifest 归档成 `run_manifest.<时间戳>.json` 再写新的，
   于是"哪一段属于哪个版本"永远可查；
3. 每次 run 的 `audit` 行末尾带 `scripts[cand=… base=… duel=… skil=…]`，每行结果都能反查版本；
4. `-Task status -Run <run>` 先报版本状态：`MATCH` / `MISMATCH` /
   `N row(s) but NO run_manifest.json -> historical run, version unrecorded`。

实测输出：
```
[guard] wrote run manifest: cand=6f62d5a77c83 base=bd0750a016b6 duel=03de13f6de34 skil=fe95eae9b3ed
# 换版本后追加 -> 拒绝：
FATAL: HASH GUARD: run "x" was created with cand=da8ab33c3306 ... but the scripts now are cand=6f62d5a77c83 ...
# 显式放行：
[guard] HASH CHANGE ACCEPTED: archived old manifest as run_manifest.20260913_084212.json ; now ...
```

> **纪律**：在"DIFF 工作结束、可以冻结"之前**不要把任何哈希当冻结值**。跨版本对比请用
> **新的 `-Run`**（或 `-AllowHashChange` + 保留归档 manifest）。历史 run
> （`pilot` / `inj` / `beamsweep`）**只对 `da8ab33c3306` 有效**。

## 用法

> **调用方式很重要**：用 `powershell -File Train.ps1 -Firsts e,p` 时，PowerShell 会把
> `e,p` 先拆成数组再按空格拼回字符串 `"e p"`，于是 `-Firsts/-Asides/-Configs` 会收到错值。
> 统一用 **`-Command`** 调用（下面所有示例都是），或写成 `-Firsts 'e','p'`。
> 脚本对非法取值会**直接报错**（不会带病跑）。

```powershell
cd "D:\Game creating\战旗"
$T = "RL\train\Train.ps1"
function Run-Train { param([Parameter(ValueFromRemainingArguments=$true)]$Args)
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "& '$T' $($Args -join ' ')"
}

# 0) 统计实现自检（Wilson 对照教科书值）
Run-Train -Task selftest

# 1) 阵容池覆盖 + 训练/留出不相交自检（会写 lineup_coverage.md）
Run-Train -Task coverage

# 2) 只生成候选权重 JSON（不跑对局）
Run-Train -Task gen -Run pilot -Configs base,kb_x2

# 3) 跑对局（可中断续跑：已跑过的 (配置,种子,先手) 自动跳过）
Run-Train -Task run -Run pilot -Configs base,kb_x2 -SeedSet train -MaxSeeds 2 -Firsts e -Asides e,p

# 4) 看进度 / 估墙钟
Run-Train -Task status   -Run pilot
Run-Train -Task estimate -Run pilot

# 5) 配对敏感度比较（第一个名字是基线，其余是处理组）
Run-Train -Task compare -Run sens -Configs base_nightmare,kb_lo,kb_hi -OutMd sens_table.md
```

### 敏感度比较的口径（`-Task compare`）

* **配对单元 = `(seed, first, a_side)`**，只用两个配置**都有**的元组（缺的自动忽略并计入 `pairs`）。
  由于扫参数时这批元组固定不变，逐元组做差就消掉了种子/阵容噪声。
* 输出：`ctrl_rate` / `treat_rate` / `Δrate` / `Δpts`（每局分差之差）/ `Δpts_sd` /
  **`Δpts` 的 95% CI（t 分布，df = pairs−1）** / 是否排除 0。
* 判定：`Δpts` 的 95% CI 不含 0 才算“测出影响”；再与**噪声地板**（同权重、不同 seed 块的
  `Δpts_sd`）比较，只有超过 `2×噪声 sd` 才算“真影响”。噪声地板用 `-FloorRun/-FloorControl/
  -FloorTreatment` 传入（默认不传则只给 CI 结论）。

### 关键参数

| 参数 | 含义 |
|---|---|
| `-Run` | 结果目录名（`RL/train/results/<Run>/`），也是候选权重文件名的一部分 |
| `-Configs` | 逗号分隔的配置名，取自 `train_spec.json` 的 `configs`，或 `all` |
| `-SeedSet` | `train` / `holdout`；`holdout` 必须显式加 `-IKnowThisIsHoldout` |
| `-SeedStart/-SeedBlock/-MaxSeeds` | 从种子集里取一段（`-SeedBlock 8` = 前 8 个） |
| `-Firsts` / `-Asides` | 覆盖 spec 的先手 / 阵营组合，例如 `-Firsts e`、`-Asides e,p` |
| `-FixedDecks` | 关闭阵容轮换，退回 spec 里写死的 3v3（**仅用于与历史测量对齐**） |
| `-Force` | 重测已有 (配置,种子,先手)，会先删掉该组的旧行再追加 |
| `-TimeoutSec` | 单批 Godot 的墙钟上限（超时只杀本次调用启动的 PID，然后抛错让你续跑） |
| `-MaxWallSec` | 本次调用总墙钟上限，超了退出码 2 |

## 权重 JSON 可接受 schema

权重文件是**平铺 JSON**，由 `RL/ai/AI_Battle.gd::set_weights()` 消费（只读，勿改）：

```jsonc
{
  "KILL_BONUS": 35.0,             // 12 个通用评分键（float 或 int，其他类型静默跳过）
  "FOCUS_FIRE_WEIGHT": 30.0,
  "GOLD_TAKE_VALUE": 26.0,
  "GOLD_TAKE_VALUE_LOW": 34.0,
  "GOLD_LOW_ATK": 4,
  "BUFF_TAKE_WEIGHT": 3.0,
  "THREAT_MOVE_DISCOUNT": 0.7,    // 0~1
  "OBSTACLE_DETOUR_WEIGHT": 4.0,
  "ENGAGE_PULL_PER_CELL": 1.2,
  "MAX_MOVE_OPTIONS": 16,
  "BEAM": 1200,                   // 搜索波束（困难档=800）
  "JITTER": 0.0,                  // 0 = 纯最优、可复现
  "HERO_VALUE": {                 // 英雄特化段：hero_id -> 核心价值系数（默认 1.0）
    "hero_22": 1.35,
    "hero_40": 0.9
  }
}
```

规则（来自 `AI_Battle.gd` L312-365）：

* 未知键**静默忽略**，值不是数字**静默跳过**；`_` 开头的说明键天然被忽略（所以
  `噩梦.json` 里的 `_说明/_替换方法/...` 全部无害）。
* `HERO_VALUE` 是唯一被特判的嵌套段：`set_weights` 把它转给 `set_hero_weights`。
* `HERO_VALUE` 的注入优先级：**权重文件 > 内置默认表 `HERO_VALUE_DEFAULT` > 1.0**。
  因此**只写部分英雄**时，未写的英雄仍走内置表，不是 1.0；要显式归 1.0 必须写出来
  （`全1对照.json` 就是全 49 个显式写 1.0）。
* 系数同时影响两件事：① 敌方该英雄价值越高 → 越优先集火；② 己方该英雄价值越高 →
  越倾向保它。建议区间 0.8~1.5。
* `set_hero_weights()` 另支持 `{ "hero_42": { "GOLD_TAKE_VALUE": 40.0 } }` 这种**按英雄覆盖
  通用键**的形式，但 `对局.gd` 只通过 `set_weights` 注入，所以这条路径在当前流水线里没用到。
* **本流水线的候选文件一律写到 `RL/weights/cand_<Run>_<Config>.json`**，绝不覆盖
  `噩梦.json` / `全1对照.json` / `基础.json` / `base.json`。

## 种子与阵容划分（写死在 `train_spec.json`，脚本每次启动自检）

* 训练种子：`10001..10120`（120 个）；留出种子：`90001..90024`（24 个）。
* 启动即校验两集合交集 = 0，否则 `Read-TrainSpec` 直接抛错。
* **阵容也要不重叠**：每个 seed 用确定性映射取一套 3v3 阵容
  （`lineup = pool[seed % slots]`，详见 `lineup_coverage.md`），训练阵容池与留出阵容池
  的 (a,b,c) 组合**零交集**，脚本硬校验。
* 偶数 seed → 生成阵容给**敌方**侧；奇数 seed → 给**玩家**侧；另一侧用 anchor 轮换
  （A/B/C 三套固定阵容）。这样两侧都在轮换，且 HERO_VALUE 在两侧都有梯度信号。
* 留出集只能用于最终验收：`-SeedSet holdout` 必须显式加 `-IKnowThisIsHoldout`。

## 统计口径

对每个配置在指定种子集上的全部对局：

* **胜率**：`W=1 / D=0.5 / L=0`，即 `rate = (W + D/2) / N`。
* **Wilson 95% 双侧区间**（在“半胜单位”上算，`n = 2N` 次伯努利试验，`k = 2W + D`）：

  ```
  p̂ = k/n
  lo,hi = [ p̂ + z²/2n ∓ z·sqrt( p̂(1-p̂)/n + z²/4n² ) ] / (1 + z²/n),   z = 1.959963984540054
  ```

  实现见 `Get-WilsonInterval`；自检对照公开值：`4/5 → 0.375535..0.963776`、
  `10/100 → 0.055229..0.174366`、`50/100 → 0.403832..0.596168`。
  起点基线 `N=14, 8W 6L` → `rate=0.5714`、`lo=0.325906`、`hi=0.786192`。
* **每局平均分差**：`mean(ptsA − ptsB)`，`ptsA/ptsB` 取 `R|m|` 行的战局优势分（含胜负 ±20、
  击杀差×3、伤害差、血量差、替补差、回合数惩罚），并给出 sd 与 95% 正态区间 `mean ± 1.96·sd/√N`。
* Wilson 下界是**单侧可用的保守判据**（双侧区间的下端），所以拿它做“显著强于”的门槛，
  不会因为“双侧还是单侧”而放宽。

## 验收标准

在**留出种子集 + 留出阵容池**上，冻结候选的 **`rate_lo95 > 0.5`** 才算“噩梦档显著强于困难档”。
对照口径：`N=96`（24 种子 × 2 先手 × 2 阵营）时，需要大约 62 胜 34 负（≈64.6%）才能过线。

## 实例互斥（重要）

* 跑对局前 `Wait-GodotSlot` 会检查 `Get-Process -Name 'Godot*'`，**除用户编辑器 PID 25124 之外**
  任何 Godot 进程存在就等 30 秒再查，最多 20 轮；拿不到就抛错，**不会启动任何东西**。
* 同一时刻只跑一个 Godot 实例（本流水线是串行的：一个批次退出了才起下一个）。
* 超时只杀**本次调用启动的** Godot PID（批开始前已存在的 PID 集合做差集），以及记录在
  `b_*.jobpid` 里的 job host PID；**绝不杀别人的进程**。
* `results/<run>/RUNNING.lock` 防止两个 run 并发写同一目录；异常退出留下的锁需人工确认后删。
* Godot 输出必须 `cmd /c "... > out 2>&1"` 再 `Get-Content -Encoding UTF8` 读——
  PowerShell 直接捕获 Godot 输出会得到空。
* 本目录所有 `.ps1` 必须带 **UTF-8 BOM**：PS 5.1 会把无 BOM 的 `.ps1` 按 ANSI 解码，
  里面的中文路径字面量会当场变成乱码（曾把 9 个文件写成 0 字节）。脚本启动时有
  `Assert-ScriptEncoding` 硬校验，缺 BOM 直接报错而不是带病运行。

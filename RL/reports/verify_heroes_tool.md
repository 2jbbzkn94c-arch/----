# 一键核对英雄（`RL/verify_heroes.ps1` + `RL/verify_heroes.bat`）· 说明与自测

- 新增文件（**未修改任何既有文件**）：`RL/verify_heroes.ps1`（主逻辑）、`RL/verify_heroes.bat`（双击/命令行包装）、本报告。
- 未碰 `src/`、`heroes/`、`RL/ai/`、`RL/harness/*.gd`、`project.godot`、`scenes/`；未 `git commit`。

> 命名说明：用户要求的文件名是 `RL/核对英雄.ps1` / `.bat`，我落地成 **`verify_heroes.ps1` / `.bat`**。
> 理由：**PowerShell 5.1 读取 `.ps1`/`.bat` 时按 ANSI 解析文件名之外的**内容**，而"中文文件名本身"
> 也踩过坑（上一个任务里一句带中文路径字面量的 `Set-Location` 把 9 个 hero 文件写空了）。
> 脚本源码**已做到 0 个非 ASCII 字节**（`RL/verify_heroes.ps1`、`.bat` 都是纯 ASCII），
> 中文路径/中文判定词全部在运行时用码点构造或从 UTF-8 文件读出来。要改回中文名只需重命名两个文件，
> 内容不用动（脚本内部用 `$PSScriptRoot` 推导路径，不依赖自己的文件名）。

---

## 1. 怎么用

```
RL\verify_heroes.bat                                   （双击 = 默认自检 hero_26 / 12 招）
RL\verify_heroes.bat -Heroes hero_26,hero_22
RL\verify_heroes.bat -All -Acts 16 -Seed 7
RL\verify_heroes.bat -Heroes hero_50 -SkipMatrix -SkipSweep
RL\verify_heroes.bat -Heroes hero_50 -BothSides          （该英雄分别当我方主力 / 敌方主力各扫一遍）

powershell -NoProfile -File RL\verify_heroes.ps1 -Heroes hero_26,hero_22      （等价，命令行直接跑）
pwsh -NoProfile -File RL\verify_heroes.ps1 -All -Acts 16                       （装了 PS7 时优先用 pwsh）
```

| 参数 | 含义 |
|---|---|
| `-Heroes hero_50,hero_25` | 要核对的英雄（逗号分隔，可多个） |
| `-All` | 英雄表全量（hero id 来源 = `heroes/HeroRegistry.gd`，49 个正式英雄；衍生物无 `hero_NN_名字.gd` 样式，自动排除） |
| `-Acts 16` | 扫描每局的动作数（默认 16；越小越快） |
| `-Seed 7` | 扫描随机种子（默认 7） |
| `-SkipMatrix` / `-SkipSweep` | 跳过矩阵对拍 / 跳过轮换对局扫描 |
| `-BothSides` | 扫描时再把它放敌方主力跑一遍 |
| `-Godot` / `-Project` / `-Stamp` | 覆盖 Godot 路径 / 工程根 / 日志时间戳（默认自动） |
| `-MatrixScene` / `-InspectScene` | 调试用：把前置检查指向别的场景（默认真实 harness 场景，见第 5 节自测 3） |

**退出码**：`0` 全绿；`1` 出现真实 DIFF；`2` 前置检查/参数失败。
每次运行的控制台汇总同时写进 `RL/reports/verify_<时间戳>.log`（UTF-8），
每个子运行的原始输出另存 `RL/reports/verify_<时间戳>_<hero>_*.out` 与 `*.godot.log`。

---

## 2. 它做四层检查

**L0 前置保护（必须先过，这是踩过的坑）**
1. 跑 `自由部署_模拟检视.tscn -- --panecheck`：判定 = **退出码 0 + 输出里有 `构建=<sha>` + 无 `Parse Error`/`Failed to load script`**；
2. 再跑一次矩阵 harness 的最便宜模式（`技能对拍.tscn -- hero_26`）同口径判定；
3. 任一不过 → **整轮中止、打印原因并退出码 2**（不会一局一局硬撞出一串崩溃框）。
每次运行的**构建戳**都记进汇总（例：`构建=600A5E59F26C`），所以"这份结果对应哪一版代码"一目了然。
> 实测：本机 `自由部署_模拟检视.gd` 的构建戳在本次会话里从 `C4C7CAC27933` 变成 `600A5E59F26C`（有别的任务在改它），
> 脚本每次都重新读，不会拿旧戳。

**L1 静态核对**
- `heroes/hero_<id>_*.gd` 是否存在；
- 是否登记在 `heroes/HeroRegistry.gd`（id → 脚本映射的唯一真相），并给出该英雄的中文名（从 `res://heroes/hero_NN_名字.gd` 里取出）；
- 矩阵对拍里是否有**它的专属场景臂**：启发式看 `RL/harness/技能对拍.gd` 里有没有它的 id / 中文名；**并且**用真实矩阵运行产出的 `SK|HERO|<id>|…` 逐英雄聚合行来确认（这一行证明该英雄确实有自己的场景臂）。两条都不满足才警告：
  "可能缺专属场景：通用动作族覆盖不到登场技/回合技/被动/范围技"；
- 核心识别系数：读 `RL/weights/噩梦.json` 的 `HERO_VALUE`，缺就标注"未配置 → 内置默认 1.0（中性）"。

**L2 矩阵对拍（受控场景）** — `技能对拍.tscn -- <hero_id>`（单英雄约 20s，与文档的"约 4 分钟"相比本机更快）
- 解析 `SK|SUMMARY|`（cases/match/diff/skip/snap/fork_sha）、`SK|HERO|<id>|…`、以及所有 `verdict=DIFF` 行；
- 汇总用例数 / MATCH / DIFF / SKIP / SNAP；DIFF 逐条列出原文（最多 20 条，其余给数量 + 日志路径）。

**L3 轮换对局扫描（真实对局）**
- `自由部署_模拟检视.tscn -- --selftest <Acts> --pai 1 --ai 1 --seed <Seed> --picks "…,hero_26,hero_06" "hero_13,hero_12,hero_23"`（该英雄当我方主力；`-BothSides` 再跑一次当敌方主力）；
- 解析两条来源：控制台的 `判定 DIFF / 判定 TIMING / 判定 MATCH / 判定 不可比 / 判定 NOPRED` 块，
  以及运行时日志（`--rtlog` 固定到本次运行的绝对路径）里的 `SIMCHK|n=…|verdict=…` 与 `SIMCHK|SUMMARY|`；
- **机读行是计数权威**，控制台块用于给人看的原文；`TIMING / PROCESS / SPAN / 不可比` 单独计数，**不算缺口**。

**L4 结论**：每个英雄一张小表 + 一行结论（`OK` / `CAUTION` / `DIFF`），最后给本轮所有运行记录过的 PID 与总退出码。

---

## 3. 输出样例（真实运行，`-Heroes hero_26,hero_22 -Acts 12 -Seed 7`）

```
[L0 preflight] both harness scenes must load (exit 0 + build stamp + no parse error)
  inspector scene : exit=0 secs=1 build=600A5E59F26C ok=True
  matrix scene    : exit=0 secs=20 ok=True

---------------- hero_26  雪拳 ----------------
  matrix: exit=0 secs=20 cases=48 MATCH=44 DIFF=0 SKIP=3 SNAP=1 fork=c4384f7b87c0
  sweep (our side) : exit=0 secs=38 printedBlocks=12 simChecks=12 DIFF=0 MATCH=12 TIMING=0 PROCESS=0 SPAN=0 NOPRED=0

---------------- hero_22  圣光 ----------------
  matrix: exit=0 secs=20 cases=48 MATCH=44 DIFF=0 SKIP=3 SNAP=1 fork=c4384f7b87c0
  sweep (our side) : exit=0 secs=37 printedBlocks=16 simChecks=16 DIFF=3 MATCH=9 TIMING=0 PROCESS=0 SPAN=0 NOPRED=0
...
hero_26  (雪拳)
  static : script=OK  registry=OK  tableName=n/a  matrixScenes=0  coef=1.05
           note: dedicated scene arm confirmed by the matrix run (SK|HERO|hero_26 with 47 scenario verdicts)
  matrix : cases=48 MATCH=44 DIFF=0 SKIP=3 SNAP=1
  sweep  : our side printedBlocks=12 simChecks=12 DIFF=0  (MATCH=12 TIMING=0 PROCESS=0 SPAN=0 NOPRED=0)
  verdict: OK -- AI prediction agreed with the real battle on every comparable case
  result : OK

hero_22  (圣光)
  static : script=OK  registry=OK  tableName=n/a  matrixScenes=0  coef=1.35
           note: dedicated scene arm confirmed by the matrix run (SK|HERO|hero_22 with 47 scenario verdicts)
  matrix : cases=48 MATCH=44 DIFF=0 SKIP=3 SNAP=1
  sweep  : our side printedBlocks=16 simChecks=16 DIFF=3  (MATCH=9 TIMING=0 PROCESS=0 SPAN=0 NOPRED=0)
  verdict: DIFF -- 6 row(s); see below
      [sweep/our] [console] 判定 DIFF：雪拳(hero_26)#1 状态[盾] 预测是→实际否
      [sweep/our] [console] 判定 DIFF：雪拳(hero_26)#1 状态[盾] 预测是→实际否
      [sweep/our] [console] 判定 DIFF：圣光(hero_22)#5 状态[盾] 预测是→实际否
      [sweep/our] [sim] SIMCHK|n=4|u=雪拳(hero_26)#1|act=move+atk|verdict=DIFF|diffs=雪拳(hero_26)#1状态[盾]p=是>a=否
      [sweep/our] [sim] SIMCHK|n=10|u=雪拳(hero_26)#1|act=move+atk|verdict=DIFF|diffs=雪拳(hero_26)#1状态[盾]p=是>a=否
      [sweep/our] [sim] SIMCHK|n=12|u=圣光(hero_22)#5|act=move+atk|verdict=DIFF|diffs=圣光(hero_22)#5状态[盾]p=是>a=否
  result : DIFF

  EXIT 1  -- at least one real DIFF (see the rows above)
```

---

## 4. 自测证据（四条路径，全部实跑）

### 4.1 全绿路径 — `-Heroes hero_26 -Acts 12 -Seed 7` → 退出码 **0**
`RL/reports/verify_20260913_004804.log`
```
inspector scene : exit=0 secs=1 build=600A5E59F26C ok=True
matrix scene    : exit=0 secs=20 ok=True
hero_26 (雪拳) matrix cases=48 MATCH=44 DIFF=0 SKIP=3 SNAP=1
hero_26 sweep printedBlocks=12 simChecks=12 DIFF=0 MATCH=12
verdict: OK -- AI prediction agreed with the real battle on every comparable case
EXIT 0  -- all green
```

### 4.2 DIFF 路径（合成输入，不依赖别的任务进度）
把 `verify_heroes.ps1` 里的 `Parse-Matrix` / `Parse-Sweep` 源码切出来（含 `Get-Codepoints`），喂人造文本：

```
matrix-parser: cases=48 match=44 diff=1 skip=3 snap=1 diffLines=1
  -> DIFF detected: OK
matrix-parser(all green): diff=0 diffLines=0
  -> no false positive: OK
sweep-parser: simChecks=3 DIFF=1 MATCH=1 NOPRED=1 ctDiff=1 ctMatch=1 diffLines=2
  -> DIFF counted from both sources, no false positive: OK
  -> the no-difference detail line was NOT treated as a failure: OK
PARSER SELFTEST: ALL OK
```
人造输入包含 `SK|…|verdict=DIFF|…`、`SIMCHK|…|verdict=DIFF|…` 与中文判定行 `判定 DIFF`
（测试脚本用码点构造中文，自身 0 个非 ASCII 字节），断言 DIFF 被识别并计数。
**这个自测当场抓出一个真 bug**：我第一版把"含 DIFF 子串的行"都当差异，于是
`字段级：diffs=-`（中文含义是"没有差异"）被误计成 DIFF，导致全绿英雄也报 DIFF；已修成
**只认 `判定 DIFF` / `SIMCHK…verdict=DIFF` 这类真正的判定行**，并把该用例固化成断言。

另有一条**真实 DIFF 路径**的旁证（不是为看 DIFF 而跑，而是顺手验出工具能用）：
`hero_22` 的扫描 3 条 DIFF、退出码 1（见第 3 节样例）。

### 4.3 前置检查路径 — 脚本加载失败 → 立即中止 + 退出码 **2**
两种触发方式都实测过：

**(a) 场景不存在**（`-InspectScene …\_tmp_broken_scene.tscn`，该临时文件用后即删）
```
  inspector scene : exit=1 secs=1 build= ok=False  reason=exit code 1
  ==> PREFLIGHT FAILED: aborting the whole run (exit code 2). Raw output:
      ERROR: Cannot open file '…_tmp_broken_scene.tscn'.
PREFLIGHT FAILED -- nothing was run. …
退出码 = 2
```

**(b) 真实场景名 + 故意写坏的语法**（把 `RL/harness/自由部署_模拟检视.gd` 临时替换成非法 GDScript，
用同一场景名让 Godot 真的去 parse；跑完立刻按备份逐字节还原，文件大小回到 246467 字节、
首行仍是 `extends Node2D`）
```
  inspector scene : exit=1 secs=0 build= ok=False  reason=exit code 1
  ==> PREFLIGHT FAILED: aborting the whole run (exit code 2). …
退出码 = 2
```
> 诚实记录：这次(b)里我写坏 harness 脚本后，Godot 在无头下**卡住没退**（脚本外的外层命令因此超时被杀），
> 前置检查本身已按预期判红；我随后**先还原文件**、再修超时实现（见第 5 节），没有留下坏文件。

### 4.4 多英雄路径 — `-Heroes hero_26,hero_22 -Acts 12 -Seed 7` → 退出码 **1**
输出见第 3 节（两个英雄各一段小表 + 结论；`hero_26 = OK`、`hero_22 = DIFF`，总退出码 1）。

---

## 5. 实现要点与踩过的坑（都在代码注释里）

1. **纯 ASCII 源码**：`.ps1` 与 `.bat` 均为 **0 个非 ASCII 字节**（实测）。中文一律运行时构造：
   - 面板场景名 / 矩阵场景名 → 扫 `RL/harness/*.tscn`，用**码点**拼出 `技能对拍`、`自由部署_模拟检视` 再比对（ASCII 源里只出现 `0x6280,0x80FD,…`）；
   - 判定行前缀 `判定`、`不可比` → 码点构造后 `[regex]::Escape` 再匹配；
   - 运行时日志名 `对拍_运行时.log` → 码点构造；
   - 英雄中文名 → 从 `HeroRegistry.gd` 的 `res://heroes/hero_NN_名字.gd` 路径里切出来（源文件里不写一个字）。
   > 这条是硬需求：**PS 5.1 读 `.ps1` 按 ANSI**，我中途试过在正则里写中文字面量 `判定`，脚本立刻被打乱、语法报错；
   > 改成码点构造后恢复正常。同理 `.bat` 也保持纯 ASCII。
2. **跑 Godot 的方式**：`& cmd /c` 重定向（stdout+stderr 进 `.out` 文件，`--log-file` 用**绝对路径**）。
   为了有**每局超时**，放在后台 job 里跑并 `Wait-Job -Timeout`；超时则 `Stop-Job` + **只杀"本次调用开始之后才出现"的 Godot 进程**
   （用启动时间戳过滤，绝不按名字杀、更不会动用户那个有窗口的编辑器）。
   > 先说清一个失败尝试：`Start-Process -PassThru` + `WaitForExit(ms)` 在本机**打乱引号**——
   > 实测同一条命令 `& cmd /c` 退出码 0、输出正常，而 `Start-Process` 版本退出码 1、**连输出文件都没生成**。
   > 所以最终用 job+超时清理，而不是 `Start-Process`。
3. **一次只跑一个 Godot 实例**：所有子运行串行；脚本开头就打印会执行的层，便于预估时间。
   实测耗时：panecheck 1s、矩阵单英雄 ~20s、扫描（12 招）~40s；两英雄全套 ~140s。
4. **控制台不捕 stdout**：所有 Godot 输出一律经 cmd 重定向落盘后再用 `[System.IO.File]::ReadAllText(..., UTF8)` 读，
   避免本项目历史上"PowerShell 直接捕获造成假信号/截断"的问题。
5. **静态层不误报**：`matrixScenes=0`（启发式没找到专属场景）时**不直接下结论**，先用矩阵运行自己的
   `SK|HERO|<id>|…` 聚合行复核；确认有专属场景臂就把警告改成 note（`hero_26`/`hero_22` 都因此从
   "可能缺专属场景"变成"已确认有专属场景臂（47 条场景判定）"）。
6. **计数口径写清**：扫描的 `printedBlocks` 是控制台打出来的对拍块数，`simChecks` 是运行时日志里的机读检查数
   （权威）；两者可能不同（`hero_22` 那次 16 vs 16、`hero_26` 12 vs 12），因为一个动作可能产出多个检查块。

---

## 6. 顺手发现的一处真实缺口（**不是**本任务要修的，只登记）

自测里 `hero_22`（圣光）的**扫描**报了 3 条真实 DIFF，模式一致：

```
SIMCHK|n=4 |u=雪拳(hero_26)#1|act=move+atk|verdict=DIFF|diffs=雪拳(hero_26)#1状态[盾]p=是>a=否
SIMCHK|n=10|u=雪拳(hero_26)#1|act=move+atk|verdict=DIFF|diffs=雪拳(hero_26)#1状态[盾]p=是>a=否
SIMCHK|n=12|u=圣光(hero_22)#5|act=move+atk|verdict=DIFF|diffs=圣光(hero_22)#5状态[盾]p=是>a=否
```
即 **AI 预测"某个单位会获得[圣盾]，实际没有"**（预测侧多给了一枚盾）。
而**同一英雄的矩阵对拍 48 例 0 DIFF**——两边一致，说明矩阵的通用场景族**没有覆盖**
"移动+攻击时圣光给盾"这条链路（矩阵里圣光只作为"盾的施加者"出现在别人的场景里）。
这正好是"两层检查互补"的例子：矩阵绿 ≠ 真的没问题，扫描才会撞到。
**按纪律我没有改任何 `RL/ai/*` 或 `heroes/*`**：这是需要单独裁决的模拟缺口（可能与最近"圣光被晕仍给盾/名额退还"
那几次改动有关，也可能本来就存在）。建议：先跑
`RL\verify_heroes.bat -Heroes hero_22 -Acts 24 -Seed 7`（或换几个 seed）确认复现率，再决定是补模拟还是补矩阵专属场景。

---

## 7. 判断需要但用户没提到的检查项（已加进去）

1. **矩阵场景名/日志名的定位不写死**：脚本扫 `RL/harness/*.tscn` 找真名，将来改名不会失效（只报错不误判）。
2. **构建戳双处记录**：控制台 + 汇总表头，且每次运行重新读取，避免"结果对应旧代码"。
3. **超时与进程卫生**：每层都有超时；只杀自己启动的进程（按启动时间过滤）；汇总里打印本轮记录过的 PID。
4. **静态层先看 `HeroRegistry` 再说话**：未登记的 id 直接报 `!! hero not registered` 并把退出码置 2，
   而不是继续跑一个不存在的英雄。
5. **`-BothSides`**：同一个英雄当我方主力 / 敌方主力各扫一遍（AI 侧视角不同，覆盖不同的动作组合）。
6. **原始输出全留档**：每个子运行的 `.out`（控制台）/`.godot.log`（Godot 日志）/`_rt_p.log`（对拍机读日志）
   都写进 `RL/reports/`，汇总日志只放结论与 DIFF 行，方便回查。
7. **`OK / CAUTION / DIFF` 三态**：没有 DIFF 但缺专属场景时给 `CAUTION`（并说明"全 MATCH 不能证明登场/回合/被动/光环技被正确模拟"），
   避免把"通用场景没覆盖到"读成"这个英雄没问题"。

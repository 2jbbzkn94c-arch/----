# 对局统计收集（RL/stats）

把**真实对局**（`scenes/Main.tscn`，规则全由 src/ 结算）跑成两份 CSV，供后续做
**英雄强度榜 / 组合强度榜 / 对位胜率矩阵**。

## 文件清单（本目录全是新增文件，未改动任何既有文件）

| 文件 | 作用 |
|---|---|
| `RL/stats/对局统计.gd` | 一局驱动 + 统计钩子 + 落盘。蓝本是 `RL/harness/对局.gd`（只读，未改）的插桩副本 |
| `RL/stats/对局统计.tscn` | 场景入口（只有一个 Node，挂上面的脚本） |
| `RL/stats/collect_stats.ps1` | 批量跑 + 合并 CSV + 每局一行摘要（并发上限 2，独立 APPDATA） |
| `test bat/统计收集.bat` | 一键外壳（转交参数给 ps1；不带 pause，可被 `cmd /c` 直接调用） |
| `RL/reports/stats/*.csv` | 产物（带时间戳的一份 + 固定名一份） |

## 怎么跑

### 1) 一键（推荐，Windows）

```
test bat\统计收集.bat                                  rem = 3v3、10 局、seed 7、beam 50
test bat\统计收集.bat -Mode 5v5 -Games 20 -Seed 100     rem 5v5（上场 3 + 替补 2）20 局
test bat\统计收集.bat -Games 10 -Beam 800 -Workers 2    rem 2 并发（上限就是 2）
```

### 2) 直接跑 ps1

```powershell
powershell -NoProfile -File RL\stats\collect_stats.ps1 -Mode 3v3 -Games 10 -Seed 7 -Beam 50 -Workers 4 -Tag trial
```

参数：`-Mode 3v3|5v5`、`-Games N`、`-Seed S`、`-Beam N`、`-Workers W`（默认 4，**实际并发 = min(W,2)**）、
`-Tag T`、`-Speed 20`、`-WeightsA <权重>`、`-WeightsB <权重|base>`、`-Godot <exe>`、`-Project <根>`、
`-TimeoutSec N`、`-KeepParts`。
（权重那两个参数**故意不叫** `-WA/-WB`：PowerShell 内置别名 `wa` = WarningAction，同名参数会让整个脚本
绑定失败——实测踩过。）

跑完在 `RL\reports\stats\` 下给你：带时间戳的合并 CSV + 固定名 `matches.csv` / `units.csv`（= 最新一次合并结果），
每个 worker 的原始 CSV 与 stdout 日志留在 `RL\reports\stats\parts\<tag>_<时间戳>\`。

### 3) 直接跑场景（自己拼参数，最灵活）

```
"C:\Users\79076\Desktop\Godot_v4.7.1-stable_win64.exe" --headless --path "D:\Game creating\战旗" ^
  res://RL/stats/对局统计.tscn -- --mode 3v3 --games 3 --seed 7 --first both --beam 50 --speed 20 ^
  --wA res://RL/weights/噩梦.json --wB base --out res://RL/reports/stats --tag stats
```

PowerShell 抓不到 Godot 的 stdout，一律走 `cmd /c "... > out.txt 2>&1"` 再看文件。
并行多开时**每个实例必须给独立 APPDATA**，并设 `ZB_NO_MIRROR=1`（关掉"固定名镜像"这个唯一共享写点）。

### CLI 参数（`--` 之后的 `OS.get_cmdline_user_args()`）

| 参数 | 默认 | 说明 |
|---|---|---|
| `--mode 3v3\|5v5` | `3v3` | 3v3 = 双方各 3 人；5v5 = **上场 3 + 替补 2**（生产口径，卡组 5 人） |
| `--games N` | 1 | 本进程打几局（每局结束就落一次盘） |
| `--seed S` | 10000 | 第 i 局用 `S+i`（同时决定阵容随机、先手交替、全局随机种子） |
| `--first p\|e\|both` | both | `both` = 逐局交替先手（第 0、2、4…局 P 先手） |
| `--beam N` | 800 | 搜索宽度（玩家方那份权重生效；`--wB base` 时对方固定 800，见下） |
| `--speed N` | 20 | 只缩放 `Engine.time_scale`（演出/等待时长），不碰任何规则 |
| `--wA <路径>` | `res://RL/weights/噩梦.json` | 玩家方(P)权重；缺失键=用默认常量（等价"关闭"），文件不存在=默认 |
| `--wB <路径\|base>` | 同上 | 敌方(E)权重；`base` = 原版困难档 `RL/ai/AI_Battle_原版.gd`（无权重注入、beam 固定 800） |
| `--out <目录>` | `res://RL/reports/stats` | 输出目录（也接受绝对/相对路径） |
| `--tag <前缀>` | `stats` | 文件名前缀 |
| `--picks "a,b,c[,d,e]" "…"` | 空 | 固定双方阵容（不写则**按 seed 确定性随机抽人**、双方不重复） |

## 输出

* `matches_<tag>_<MMDD_HHMMSS>.csv` / `matches.csv`：**一局一行**
* `units_<tag>_<MMDD_HHMMSS>.csv` / `units.csv`：**一个上过场的单位一行**
* 都是 **UTF-8 带 BOM**（Excel 双击不乱码）、CRLF、逗号分隔；字段内含逗号时才加引号
* `ZB_NO_MIRROR=1` 时不写固定名镜像（并行安全）

## 字段与口径

### matches.csv

| 列 | 口径 |
|---|---|
| `match_id` | `s<seed>`（同一 seed 可复现同一局；seed 决定阵容/先手/内部随机） |
| `seed` / `mode` | 同上 |
| `first_side` | `P` / `E`（本局谁先手） |
| `half_rounds` | **半回合数**：每方各走一次算 2（一局 13 就是 13 次半回合） |
| `wall_ms` | 本局墙钟耗时（含建局/拆局，不含进程启动） |
| `winner` | `P` / `E` / `D`（D = 未判出胜负，看 `end_reason`） |
| `end_reason` | `deaths`（累计阵亡 3 名判负）/ `half_limit`（打到 60 半回合上限）/ `stuck`（异常中断） |
| `P_lineup` / `E_lineup` | 该方卡组（最多 5 人），用 `|` 分隔 |
| `P_first3` / `E_first3` | 首发 3 人（= 卡组前 3 名，摆位见下） |
| `P_alive_end` / `E_alive_end` | 局末存活人数（**只数阵容成员**，召唤物不算） |
| `P_total_dmg` / `E_total_dmg` | 该方各单位 `dmg_dealt` 之和（= **已归因到具体单位的真实掉血**，见下"归因"） |
| `P_total_heal` / `E_total_heal` | 同上，回血 |
| `P_kills` / `E_kills` | 该方各单位 `kills` 之和（**已归因的击杀**；归因不到的计入下一行的 `unattr_kills`） |
| `P_gold` / `E_gold` | 该方拾取金矿/金块的总次数 |
| `unattr_dmg` | **归因不到出手者**的真实掉血总量（毒 / 回合烧血 / 炸弹 / 荆棘反伤 / 镜像附体 / 回合开始与结束类效果）。它只进受击方的 `dmg_taken`，不记给任何单位 |
| `unattr_heal` | 同上，归因不到的回血 |
| `unattr_kills` | 同上，归因不到的击杀（环境击杀） |
| `P_sub_enter_rounds` / `E_sub_enter_rounds` | 替补登场的半回合序号列表（`|` 分隔）；没有替补留空 |
| `P_first_death_round` / `E_first_death_round` | 该方**阵容成员**（不含召唤物）第一个阵亡的半回合序号；没人死留空 |
| `beam_P` / `beam_E` | 实际搜索宽度（`wB=base` 时 E 侧是它自己的常量 800） |
| `w_P` / `w_E` | 权重来源：`路径#sha256前12位` / `base` / `default`（文件不存在或无注入） |
| `fork_sha` | `RL/ai/AI_Battle.gd` 的 sha256 前 12 位（哪一版 AI 打出来的数据） |

### units.csv

| 列 | 口径 |
|---|---|
| `match_id` | 同 matches.csv |
| `side` | `P` / `E` |
| `slot` | `首发` / `替补` / `召唤`（第三个是召唤物：不是阵容成员，但会打伤害，所以单列一行） |
| `hero_id` / `hero_name` | 登场时的英雄 id 与显示名（古灵精怪变身后**不**改写这两列） |
| `enter_round` | 登场半回合序号：**首发一律 0**；替补 = 真正落位那一刻的半回合序号（0 起） |
| `first_death_round` | 阵亡半回合序号；没死留空 |
| `alive_at_end` | 1 / 0 |
| `rounds_alive` | `(阵亡半回合 或 总半回合) − enter_round`（首发整局存活时 = `half_rounds`） |
| `dmg_dealt` | 该单位**造成的真实掉血**（含它打出的反击；不含被圣盾吸收/被塔盾代扛的部分） |
| `dmg_taken` | 该单位**实际掉的血**（含环境伤害：毒/烧血/炸弹/荆棘/镜像） |
| `heal_done` | 该单位造成的真实回血（上限封顶后的实际值） |
| `kills` | 归因到它的击杀数 |
| `deaths` | 0 / 1（一个单位一局最多死一次） |
| `gold_taken` | 拾取金矿/金块次数 |
| `moves` / `attacks` | 本局它真正发生的移动/攻击次数（`attacks` 含打障碍物） |
| `status_dealt` | 它行动期间挂到**敌方**单位身上的状态条目数（帧轮询差集，见下） |

> **没有 `skills_used` 列**（原先留了一个恒为空的占位列，已删掉）：技能触发点观测不到（原因见文末
> 「拿不到的字段」第 1 条），留一个永远空的列只会让人以为"漏采了"。技能造成的可见后果已各自成列
> （`status_dealt` / `heal_done` / `dmg_dealt`）。

### 摆位与替补（5v5）

* 首发 3 人按 `RL/harness/对局.gd` 同一套格子摆：P = (1,4)(3,4)(1,5)，E = (1,2)(3,2)(1,1)。
* 卡组第 4、5 人进替补席：`Battle.player_roster` / `enemy_roster` = 卡组里没首发的那几个
  （生产里同一套语义；自由放置分支自己不建替补席，所以本工具显式补上）。
* `GameState.dual_control = true`（必须，否则敌方回合会由生产 AI 抢着驱动）会让
  `Battle._is_manual_sub_faction()` 对**双方**都返回 true → 阵亡一律弹"手动替补面板"。
  工具替那一次点击，**口径与生产一致**：
  * 选谁：**敌方**用生产自己的 `_best_enemy_sub_idx()`；**玩家方**用替补席第一张
    （= `Battle._auto_sub_on_timeout()` 的兜底口径）。
  * 怎么落位：`_on_sub_pick(hero)` → `_auto_sub_cell(fn)` → `_try_place_sub(cell)`
    （与 `_auto_sub_on_timeout()` 同一条 API：墓碑优先、出生区兜底、光环/登场技全由 Battle 自己结算）。
  * 同一个规则也作为 `build_state` 的第 10 参（`auto_sub`）喂给 AI 的模拟，保证"AI 预测的替补"和
    "工具真的点的替补"是同一条规则。

## 有争议 / 我替你判断了的地方（逐条）

1. **首发 `enter_round = 0`**：口径写的是"首发记 0/1"。我取 **0 起**：第一个半回合 = 0，
   首发一律 0，替补/阵亡记"发生时的半回合序号"。`half_rounds` 也按同一套序号计数。
2. **`dmg_taken` 不含被圣盾吸收的部分**：`Unit.take_damage()` 在盾挡时**直接 return**（不改 hp、
   不发 `damaged`），塔盾代扛也在扣血前把伤害改小——这两块的数值**在引擎里就没有落地**，
   所以 `dmg_dealt`/`dmg_taken` 一律是「**实际掉血**」口径，不是"面板上写了多少伤害"。
   想统计"被挡掉多少"必须改 `src/Unit.gd`（冻结），所以这里**不混入**、也不猜。
3. **伤害唯一真相 = `hp_changed` 的差值**，不是 `take_damage(amount)` 的参数：
   血量不够扣时（hp=3 挨 5 点）后者会报 5，差值更接近"真实结算"。
4. **归因规则**（只影响 `dmg_dealt` / `heal_done` / `kills`，不影响 `dmg_taken`）：
   * 反击（`Unit._was_counter_damage`）→ 记给"被攻击者"（还手的那一方）；
   * 受击方与出手方**不同阵营** → 记给出手方；
   * 治疗 → 记给"出手单位且同阵营"（吸血/自愈/医护都成立）；
   * 其余（毒/回合烧血/炸弹/荆棘反伤/镜像附体/回合开始与结束类效果）→ **归因不到**，
     不进任何单位的 `dmg_dealt`，但仍进受击方的 `dmg_taken`；总量落在 matches.csv 的
     **`unattr_dmg` / `unattr_heal` / `unattr_kills`** 三列（同一局 stdout 的 `R|m|…unattr_*=` 也有一份）。
     因此 **只拿两张 CSV 就能对账**：`units.dmg_taken` 按 `match_id` 求和
     = `P_total_dmg + E_total_dmg + unattr_dmg`；`units.deaths` 求和 = `P_kills + E_kills + unattr_kills`。
   * 已知会**记错人**的一处：风语者那类"移动光环治疗"发生在移动者的行动窗口里，
     治疗量会记在**移动者**头上而不是光环源头上。
5. **`status_dealt` 只算"挂到敌方身上"的状态条目**，且是逐帧差集观测：同一帧内挂上又消失会漏计；
   回合开始类（猛毒等）没有出手单位，归因不到。给己方的增益不计入这一列。
6. **`P_kills`/`E_kills` 是"归因到该方单位的击杀数"**（含该方召唤物的击杀），不是"对方阵亡人数"
   （两者在环境击杀时会差）。对方阵亡人数可以从 units.csv 的 `deaths` 按 side 求和得到。
   注意 `P_alive_end`/`P_first_death_round` 只数**阵容成员**，召唤物不进这两项。
7. **`gold_taken` 是"拾取金矿/金块次数"**：游戏里金矿的收益是"攻+1 / 上限+3 / 回3血"（没有"金币"这个数值），
   所以次数是能观测到的最大信息量；判定方式 = `buff_items` 里 `"gold"` 消失 + 站在该格且
   `can_pickup_gold()` 为真的单位。金矿自然风化（3 回合）不会被记到任何人头上。
8. **`attacks` 含打障碍物**（`_do_attack_obstacle`）；`moves` 只算"格子真的变了或 `moved_this_turn` 翻真"的移动。
9. **阵容默认按 seed 随机**（而不是固定训练那 6 人）：英雄强度榜需要阵容多样性。
   要复刻训练口径就显式给 `--picks hero_13,hero_12,hero_23 hero_06,hero_17,hero_26`。
10. **`--first both` = 逐局交替先手**（不是"每局打两遍"）：`--games N` 仍然是 N 局，先手记录在 `first_side` 列。
11. **胜负判定口径与训练 harness 一致**：`GameState.match_ended` 的赢家（单机视角 = P 方）；
    没判出（超半回合上限/异常）记 `D` + `end_reason`，不替它猜一个赢家。
12. **`beam_E` 在 `--wB base` 时记 800**：原版困难档的搜索宽度是它自己的常量
    （`RL/ai/AI_Battle_原版.gd:387`），不吃 `--beam`。

## 拿不到的字段（如实列出）

1. **技能次数（原 `skills_used` 列，已从 units.csv 删掉）：拿不到。** 技能触发点
   （`HeroBase.on_turn_start / on_attack / on_after_attack / on_enter / on_die…`）**不是信号**，
   GDScript 不能给已有实例打桩；唯一能数的是"技能造成的可见后果"（状态/治疗/伤害），
   而它们已经各自成列（`status_dealt`/`heal_done`/`dmg_dealt`）。硬凑一个"技能次数"就是编数据，
   所以整列删掉（而不是留一个恒为空的占位）。
2. **被圣盾吸收的伤害量、塔盾代扛的减免量**：引擎里不落地（见口径第 2 条）。
3. **归因不到的那部分伤害/治疗/击杀**：只有总量（matches.csv 的 `unattr_dmg` / `unattr_heal` /
   `unattr_kills` 三列，stdout 的 `R|m|` 行里也有一份），**没有"是哪一次环境伤害"的明细**。
4. **金矿的实际收益数值**：游戏没有"金币"数值（收益是攻/上限/血量），只能记拾取次数。
5. **"AI 前瞻/模拟产生的伤害"**：本来就不存在——`AI_Battle.search()` 在纯数据 `Sim` 上跑，
   不碰真实 `Unit`；本工具只挂真实结算的信号，所以天然排除（口径要求的那一条由架构保证，不是靠过滤）。
6. **古灵精怪变身后的真实形态**：`hero_id`/`hero_name` 记的是登场时的英雄（变身会在局中改写
   `Unit.hero_id`，本工具不追）。
7. **逐招时间线 / 谁先动**：只记半回合序号，没记招序。
8. **道具/增益持有量、场地剩余回合（金矿寿命）等中间态**：没记。

## 怎么手动验

1. 双击 `test bat\统计收集.bat`（默认 3v3 / 10 局 / seed 7 / beam 50），看它打印的
   `worker results`（`script_errors=0 parse_errors=0`）+ 每局一行摘要。
2. 用 Excel 打开 `RL\reports\stats\matches.csv`：中文表头不该乱码（UTF-8 BOM）。
3. 想只看一局、看细节：把 stdout 重定向到文件后看 `R|setup| / R|plan| / R|act| / R|status| /
   R|death| / R|sub_pick| / R|sub_place| / R|gold| / R|half| / R|m|` 这些行——
   `R|half|` 里带每半回合的耗时与帧数，`R|m|` 是该局的机读摘要。
4. 校验口径（**只用两张 CSV 就够**，不必翻 stdout）：
   * `units.dmg_taken` 按 `match_id` 求和 = `matches.P_total_dmg + E_total_dmg + unattr_dmg`
     —— 伤害必有受击方，所以这两个数**必须完全相等**；
   * `units.dmg_dealt` 按 side 求和 = 该局 `matches.P_total_dmg` / `E_total_dmg`；
   * `units.deaths` 全表求和 = `matches.P_kills + E_kills + unattr_kills`；
   * 回血侧口径不同，注意别加错：`units.heal_done` 按 side 求和 = `P_total_heal` / `E_total_heal`，
     而 `unattr_heal` 是**归因不到施治者**的那部分（回合开始/结束类光环治疗等），
     它**不会**出现在任何单位行里 —— 所以"heal_done 之和 = P+E+unattr_heal"是**错的**。
   （实测：s201 的 `units.dmg_taken` 合计 95 = P_dmg 64 + E_dmg 31 + unattr_dmg 0；
     `unattr_heal=18` 而所有单位 `heal_done` 全为 0，正是这条口径的例子。）

## 后续怎么接训练管线

* **落盘格式就是为接管准备的**：每局一行 `R|m|…` 的机读摘要与 `RL/harness/对局.gd` 同风格，
  字段是它的超集（多 heal/kills/subs/alive/unattr_*）。现成的解析器（`RL/train/RlTrain.ps1`）
  加几个字段就能直接吃。
* **英雄强度榜**：`units.csv` 按 `hero_id` 分组聚合 `dmg_dealt/dmg_taken/kills/deaths/alive_at_end/
  rounds_alive`，再按 `slot` 分层（首发 vs 替补口径不同）。
* **组合强度榜**：按 `matches.csv` 的 `P_lineup`/`E_lineup` 分组（可用 `|` 拆开后排序成组合键）。
* **对位胜率矩阵**：把 `units.csv` 与 `matches.csv` 按 `match_id` join，展开 `P_first3 × E_first3`
  得到 hero↔hero 的共现/克制样本；胜负用 `winner`。
* **数据卫生**：任何一张榜都要带上 `fork_sha` + `w_P`/`w_E`（含权重文件 sha12）+ `beam_*` 分组，
  否则不同 AI 版本的数据会混在一起。
* **要加新统计**：只在 `_register()` 里加列 + 在 `_on_hp_changed`/`_poll_units` 里挂钩子即可；
  驱动/建局/替补那一层不用动。要评估"替补策略"就只改 `_drive_sub_panel()` 这一个入口
  （它同时决定喂给模拟的 `auto_sub` 规则，改一处两边同源）。

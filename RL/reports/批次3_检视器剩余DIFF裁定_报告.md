# 批次3 · 检视器剩余 DIFF 逐条裁定 + 派生量家族修复

- `RL/ai/AI_Battle.gd`：`5ce78ea4f6e2` → **`2c47d67db87f`**
- `RL/harness/技能对拍.gd`：`72b7e28eec92` → **`d20f4facc05e`**（只新增场景，既有判定一条未改）
- 矩阵：1263 用例 → **1375 用例，diff=0**、skip=132、snap=65
- 逐 tag 回归（vs 上一轮 1263：**回归 0**、verdict 变化 0、新增 112 tag 全 MATCH；vs 最初 938：**回归 0**、105 条 DIFF→MATCH）

---

## 1. 检视器审计结果（全部剩余 DIFF 逐条列出并裁定）

以盘上当前版本跑（检视器 sha 见 §5；它在本轮被第三方持续改动，我在每次跑前用 `--selftest 2` 探污染）。

| seed | goal=20 剩余 DIFF | goal=40 剩余 DIFF |
|---|---|---|
| 20250911 | 3 条：`墓碑@(3,4)`×2 有>无 + 1 无>有 | 13 条：11 墓碑（(3,4)/(1,4)/(1,5) 成对有>无/无>有）+ **有效移 ×3** + **有效攻 ×1**（见 §4 残留） |
| 4242 | 2 条：`墓碑@(3,4)`、`墓碑@(1,4)` 有>无 | 5 条：4 墓碑 + 1 `单位数 预测4→实际3` |
| 7777 | 3 条：`墓碑@(3,4)`、`墓碑@(1,4)`×2（原复合场景已消失） | 未跑（编辑期挡住） |
| 7 | 2 条：`墓碑@(1,4)` 有>无 + 无>有 | 7 条：6 墓碑 + **有效移 ×1** |
| 1234 | 4 条：`墓碑@(3,4)`/`(1,4)` 各成对 | 未跑 |
| 31337 | 2 条：`墓碑@(3,4)`×2 有>无 | 未跑 |

**三条"待定"全部定案（不是采样差，是真缺口；已修并在 §3 进矩阵）：**
- seed7 goal20 n=19 `医护兵#2有效攻p=1>a=3` + `伐木工#5血量p=26>a=24` → 同源：**远程移动后"被贴"状态没刷新**。
  算术：伐木工 27 血，真实 27−3=24（移动后解除被贴、攻击力 3），模拟按移动前的 1 → 27−1=**26**。
- seed4242 goal40 n=31 `hero_23#0血量p=7>a=6` + `hero_17#2有效攻p=3>a=4` → **一次性攻击道具没并入 effective_atk**：
  真实 eatk=3+1(道具)=4、复仇者 10−4=6；模拟 eatk 仍 3、10−3=7。
- seed4242 goal40 n=35 `hero_06#0有效攻p=1>a=3` + `hero_26#2血量p=19>a=21` + `hero_03#3血量p=12>a=10` →
  `医护兵` 移动解除被贴后 **两个消费者**都变了：攻击伤害（3 而不是 1）与 `_heal_adjacent_lowest` 的治疗量
  （`maxi(1, effective_atk())` = 3 而不是 1）——真实队友血更高、敌人血更低，与日志两条反向血量差完全吻合。

---

## 2. 本轮修掉的"派生量家族"缺口（都在 `RL/ai/AI_Battle.gd`）

真实侧 `effective_atk()/effective_move()` 是**每次现算**的：
`atk = base(远程被贴=1) + atk_buff + ramble_bonus + sun_bonus + atk_use_buff − 麻痹`；
`move = move_range + move_buff + move_use_buff − (冰冻 ? 1 : 0)`（眩晕/荆棘 = 0）。
模拟把这些当"快照静态字段"，于是任何"本招内改变派生量"的规则都对不上。本轮补齐：

1. **移动道具（emove）**：捡到 → `move_use_buff+1`、emove+1；移动 → 只消耗"移动开始前持有的"那份
   （真实 `_do_move` 的 `prev_move_buff`），emove 同步减回。`_move_cells` 原来还额外 `+1`，口径统一为
   "emove 就是 effective_move()"。
2. **一次性攻击道具并入 eatk**：捡到 → eatk+1；**攻击/反击结算后**才扣掉（真实 `_finish_attack` /
   `_play_counter` 的 `atk_use_buff = 0`）。删掉了"远程被贴时用 `1 + maxi(eatk-atk,0)` 重算 dmg"的冗余分支
   ——它会把道具那 +1 吃掉。
3. **`_sim_mult` 补"远程被贴身 → 伤害倍率技失效"**（真实 `_bonus_damage` 的 `if RANGED and _adjacent: return 1`）。
4. **大骑士冲锋加成 = 直线冲锋实际格数**（真实 `charge_path()`；目的地偏轴时退化为 1 格），原来用六边形距离。
5. **太阳斩递减下限**改为 `基础攻 + 麻痹 + 道具`（否则道具被递减吞掉）。

---

## 3. 新增矩阵场景（脱离检视器复现，全部进矩阵）

| 场景 | 覆盖英雄 | 修复前 | 修复后 |
|---|---|---|---|
| `带道具·移动捡移速` | 全 49 | `hero_06 emove 真实4 / 模拟3` | MATCH |
| `带道具·移动捡攻击后出招` | 全 49 | `hero_17 真实32/40 模拟33/40`；`hero_20 真实39/40 模拟36/40`；`hero_29/24/32/38` 各 1 条 | MATCH |
| `他动·贴上来(远程被压)` | 14 远程 | 对照第三方日志 `hero_05#5有效攻p=3>a=1`（别人走到它身边，它自己被压成 1，模拟没刷） | MATCH（真实 `hero_05 eatk 3→1`，模拟一致） |

复现命令：
```
"C:\Users\79076\Desktop\Godot_v4.7.1-stable_win64.exe" --headless --path "D:\Game creating\战旗" \
  --log-file "D:\Game creating\战旗\RL\reports\pin3_hero_06.log" \
  --scene res://RL/harness/技能对拍.tscn -- hero_06
```
新增场景 `SK|EV|` 原文（最终 sha 2c47d67db87f）：
```
SK|EV|hero_06·带道具·移动捡移速|MATCH|units+hero_06@(1, 3)=13/16|eatk=1|emove=4|已动 ; units-hero_06@(2, 4) ; items-(1, 3)
SK|EV|hero_06·带道具·移动捡攻击后出招|MATCH|units+hero_06@(1, 3)=11/16|eatk=1|emove=3|已动,已攻 ; units-hero_06@(2, 5) ; units[hero_13@(2, 3)]:40/40|eatk=2|emove=2|→38/40|eatk=2|emove=2| ; items-(1, 3)
SK|EV|hero_06·他动·贴上来(远程被压)|MATCH|units+hero_13@(2, 5)=40/40|eatk=2|emove=2|已动 ; units[hero_06@(2, 4)]:13/16|eatk=3|emove=3|→13/16|eatk=1|emove=3| ; units-hero_13@(2, 6)
```

---

## 4. 裁定：采样时机差（不改模拟）

**`墓碑 预测有/无 → 实际无/有`**（本轮 27 条里 24 条是它）
- 机制（代码路径）：`Unit.die()` 先播 0.3s 淡出，**淡出结束才 `died.emit`** → `Battle._on_unit_died`
  才写 `graves[cell]`（`src/Battle.gd:4272`）；`Battle._drain_pending_deaths()`（`:5098`）只在回合切边时排空。
  检视器是"每招执行完立刻采样"，所以死亡那一招采样时真实还没有碑。
- 指纹（与本轮日志完全吻合）：**同一格、相邻两步、方向成对**——
  `#19 墓碑@(3,4) 有>无`（烛火杀人那招）→ `#20 墓碑@(3,4) 无>有`（下一招采样时真实已结算）；
  seed7 `#17/#18 墓碑@(1,4)`、`#35/#36 墓碑@(1,5)`；seed20250911 `#9/#19/#34 有>无` 对 `#20/#35 无>有`。
- 反证"不是模拟缺口"：同一套墓碑规则在**技能对拍**里逐字段 MATCH（`hero_17·击杀 graves=["(2,3)"]`、
  `hero_27·击杀 graves=["(2,4)"]`…），因为对拍在比较前调了 `_b._drain_pending_deaths()`。
- 要消除：检视器采样前 `await _battle._drain_pending_deaths()`（harness 一行）。**我没有动那个文件。**

## 5. 裁定：设计如此（不改）

**`单位数 预测4→实际3（出招后有单位离场/下标位移）`**（seed4242 #42）
- 真实 `_on_unit_died` 会把单位从 `battle.units` 里 `erase` 并 `queue_free`（`:4278`）；
  sim 刻意**保留尸体条目**（`alive=false`），因为 AI 的动作下标是"快照 descs 下标"，中途删条目会让后续
  计划全部错位。模拟该释放的东西都释放了：`sim.occ.erase(cell)` + `graves[cell]` 与真实逐字段一致
  （见技能对拍 `击杀/阵亡` 场景 MATCH）。
- 所以这是**比对口径**（数组长度）而非规则差异：属已知设计。要"消掉"需检视器按 `alive` 计数，不建议。

## 6. 无法在 `RL/` 内消除的残留（卡在快照层，非模拟层）

goal=40 里还剩 4 条 `有效攻/有效移`：seed20250911 `#26 雪拳有效攻 预测3→实际2`、`#34 烛火有效移 预测4→实际3`、
`#35 雪拳有效移 预测5→实际4`、seed7 `#36 医护兵有效移 预测4→实际3`。四条都是**同一个方向**：
"该单位在**建快照那一刻就持有**一次性道具，随后移动/攻击把它消耗掉"——真实 `effective_*()` 当场回落，
而模拟无从得知它持有（快照 `eatk/emove` 只给合并后的数值，`src/BattleSnapshot.gd` 的 `unit_desc` 不含
`atk_use_buff / move_use_buff`），于是少减 1。
- 我在**技能对拍侧**已用 descs 注入解决（`descs[i]["atk_use_buff"|"move_use_buff"] = ru.…`），矩阵 0 DIFF；
  检视器的 `build_state` 调用不注入、我又不许动那个文件，所以它仍报这 4 条。
- 要彻底消除需在 `src/BattleSnapshot.gd` 的 `unit_desc` 里加两个字段（1 行）：
  `"atk_use_buff": u.atk_use_buff, "move_use_buff": u.move_use_buff` → 与 `eatk/emove` 同源同实时。
  **`src/` 不在我白名单，请安排。** 不加也不影响生产 AI 的正确性（与改动前同口径）。

## 7. 环境与并发（如实记录）

- 我 17:10–17:35 期间的检视器运行**全部作废**并已重跑：`audit_g20_seed7777.log`（`Parse Error` 515B）、
  17:33 的 probe（goal=1）、`audit_g20_seed7.log`（14 DIFF、1:03 跑完、出现 `已移动 p=是>a=否` 这类
  "真实侧动作没执行"的指纹）。**未作废**：`audit_g20_seed20250911.log`/`audit_g20_seed4242.log`（16:55/16:57，
  污染行 0）——本轮表格里的 goal=20 数字全部来自重跑。
- 检视器本轮被第三方改了至少 6 次（观察到 sha：`4e05ac050ba2…` → `ea92147233dece05` → `71afbadb6a383868`
  → `c6a04a983110c80b`（**在一次 run 中途变化**）→ `9c7c05987ca18fe5` → `7acdf15f8a5d425e` → `124f8a18dd14c610`
  → `2af56e9d58f6b58f`）。其中 17:23/17:33/18:2x 三次因它处于 `Parse Error`（`_build_plan()` 未 await、
  `_find_by_name()` 未定义）而无法运行；`--selftest 40 --seed 20250911` 一次因脚本损坏空转到 10 分钟超时。
- 检视器最新版会读 `SimUnit.atkdown`（`_snap_sim`），模拟里没有这个字段（麻痹记在 `atk_mod`），
  日志里出现 `Invalid access to property or key 'atkdown'`；若要比较[麻痹]状态，需 harness 侧把
  `has_status(ATKDOWN)` 也注入 descs（同 solid 的做法），或在 fork 里加一个 `atkdown` 派生字段。
- 另有第三方在 17:48/17:53 改了 `src/Battle.gd`、`src/BattleAI.gd`（我全程未动 `src/`）；
  我最终一轮全部运行都在 17:53 之后，口径一致。

## 8. 顺带发现（不是我的白名单，请裁决）

第三方给 `src/BattleAI.gd` 加了 `Sim.me_faction` + `BOMB_STAND_PENALTY`（踩炸弹惩罚）；
但 `RL/ai/AI_Battle_原版.gd`（陪练基准）与 `RL/ai/AI_Battle.gd`（fork）都**没有**这两处 →
"A/B 基准必须与 src/BattleAI.gd 行为一致"这条不变量现在被打破。要么把这两处移植进 `原版`（基准可比性），
要么明确接受差异；另外我在 fork 里加的 `Sim.active_fn`（"当前行动方"，用于圣光时机）与他们的 `me_faction`
（"AI 指挥哪一方"，用于炸弹惩罚）语义不同但生产环境取值相同，命名上建议统一，避免以后混用。

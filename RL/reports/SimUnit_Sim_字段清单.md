# `SimUnit` / `Sim` 字段清单（`RL/ai/AI_Battle.gd`，fork sha `247d68dc64b5`）

> 用途：给检视器/对拍的**字段层比对源**做对照表 —— 比对一个字段前先确认它在 fork 里**真实存在**，
> 避免"读不存在的字段 → 静默 null → 恒 false → 判定全错"这一族假 DIFF（用户实机撞到的
> `SimUnit.atkdown` 就是这一族）。**本表以文件实际内容为准**：字段增删请以本表为准更新。

## 一、`SimUnit`（每个模拟单位；`class SimUnit:` 定义在 `Sim` 之前）

| 字段 | 类型 | 含义 |
|---|---|---|
| `sim_index` | int | 在 `sim.units` 里的下标（宿魂镜像/附体绑定用） |
| `fn` | int | 阵营（`DataRegistry.Faction.PLAYER` / `ENEMY`） |
| `hero_id` | String | 英雄 id（如 `hero_17`）；召唤物如 `summon_skeleton` |
| `cell` | Vector2i | 当前格（offset 坐标） |
| `hp` / `max_hp` | int | 当前血 / 血上限 |
| `hp0` | int | 本回合快照开始时的血（评估"本回合对同一目标累计伤害"的基准） |
| `atk` | int | **基础**攻击力（不含任何 buff） |
| `eatk` | int | **有效**攻击力（实时值：基础/buff/冲锋/太阳斩/道具/麻痹/远程被贴身） |
| `atk_mod` | int | 本回合"麻痹"等降攻的**记账**（远程被贴身重算时不被冲掉；≠状态存在性） |
| `atkdown` | bool | **[麻痹] 状态存在性**（对应真实 `has_status(ATKDOWN)`，新增） |
| `thorn` | bool | **[荆棘] 状态存在性**（对应真实 `has_status(THORN)`，新增；效果另记在 `emove=0`） |
| `pin_flag` | bool | 远程"被贴身"的**缓存标记**（真实 `Unit.ranged_adjacent`，只在特定时机刷新） |
| `pin_buffs` | int | 由快照 `eatk` 反推出的 buff 部分（pin 重算时用） |
| `pin_init` | bool | 建局时是否已取过真实 pin 标记 |
| `move` / `emove` | int | 基础移动力 / 有效移动力（含道具/冰冻/眩晕/荆棘→0） |
| `atk_range` | int | 射程（坠炮手在场时被 build_state 改写为 99 或退化 2） |
| `atk_type` | int | 攻击类型（`DataRegistry.AttackType`，远程/近战） |
| `skills` | Array | 技能 id 列表（关键字判定用） |
| `moved` / `attacked` / `counter_used` | bool | 本回合已移动 / 已攻击 / 已反击（真实 `Unit.*_this_turn`） |
| `alive` | bool | 是否存活 |
| `name` | String | 显示名（决策日志用） |
| `stunned` | bool | [眩晕]：不能移动/攻击/反击/触发技能 |
| `silenced` | bool | [沉默]：非关键词技能失效 |
| `shield` | bool | [圣盾]：抵挡一次伤害（并挡该次攻击附带的状态） |
| `heavy` | bool | [重伤]：受到的伤害 +1 |
| `solid` | bool | [坚固]（hero_48）：受到**攻击**伤害 −1（与重伤共存：先加后减，最低 0） |
| `poisoned` | bool | [猛毒]：每回合开始掉 1 血 |
| `frozen` | bool | [冰冻]：移动力 −1 |
| `atk_use_buff` | int | 一次性攻击道具的持有量（+1 攻，攻击结算后消耗） |
| `move_use_buff` | int | 一次性移动道具的持有量（+1 移动，本次移动消耗"移动前已有"的那份） |
| `hurt_times` | int | 本回合被攻击次数（集火评估） |
| `aura_used` | bool | 本回合已触发过光环/每回合限一次技（圣光护盾等） |
| `ignore_los` | bool | 攻击无视障碍/单位/墓碑阻挡（坠炮手 hero_45） |
| `immune_bombs` | bool | 免疫炸弹（炸弹人 hero_35 自己踩雷不炸） |
| `can_pickup_gold` | bool | 能拾取金矿（黄金矿工 hero_42） |
| `possessed_by` | int | 被宿魂(hero_46)附体：记录施加者的 `sim_index`（−1 = 无） |
| `owner_idx` | int | 召唤物主人 `sim_index`（死灵法师阵亡时只散自己的骷髅；−1 = 非召唤物） |

**`clone()` 覆盖**：上面除 `sim_index`（由下标重写）外的**所有**字段都被复制；
`skills` 走 `duplicate()`。新增字段必须同步加进 `clone()`，否则会出现"同一回合搜索内状态丢失"。

## 二、`Sim`（一份模拟局面）

| 字段 | 类型 | 含义 |
|---|---|---|
| `units` | Array[SimUnit] | 全部单位（**含已死**：保持下标稳定，`alive=false` 表示尸体） |
| `occ` | Dictionary | 格 → SimUnit（占用；**亡者不占**，被拖走的亡者也不占） |
| `gold_cells` | Dictionary | 格 → true（金矿，黄金矿工可拾取） |
| `graves` | Dictionary | 格 → true（墓碑：阻挡移动、不可落停；**召唤物不立碑**） |
| `obstacles` | Dictionary | 格 → 剩余耐久 int（障碍：阻挡移动与视线） |
| `bombs` | Dictionary | 格 → true（炸弹：经过不炸、落停引爆 5 点；免疫者跳过） |
| `buff_cells` | Dictionary | 格 → `"atk"/"move"/"shield"/"heal"`（增益道具） |
| `killed_players` | int | 本回合内击杀的**英雄**数（召唤物不计，驱动"先收残血"）——⚠️ 2026-09-15 曾随 `KILL_BONUS` 删项短暂移除，**同日已按用户口径恢复**（引擎保留该项；"删项"改由 `RL/weights/噩梦.json` 的 `KILL_BONUS: 0` 表达，生产三档不动） |
| `buff_taken` | float | 本回合拾取道具的价值合计（驱动主动去吃） |
| `gold_taken` | int | 本回合吃到的金矿数（黄金矿工） |
| `active_fn` | int | **当前行动方**阵营（圣光/锤头鲨这类"看是不是敌方回合"的判定；由 harness 传入） |
| `pending_vanish` | Array | "随主人消散"的召唤物队列（死灵法师阵亡 → 动作末尾统一离场） |
| `walk_cache` | Dictionary | 起点格 → {格: 步数}（地形当墙；克隆时**共享引用**，地形变化由 `_apply` 清空） |
| `walk_cache_pass` | Dictionary | 同上，忽略地形墙（能穿障碍/墓碑的单位） |
| `soft_cache` | Dictionary | 障碍"软代价"路网缓存（穿一格障碍多付 1+剩余耐久 步；耐久变化即清空） |
| `_neg_gained` | Dictionary | 本动作内已对负墟(hero_44)计过 +1 攻的单位（同帧多个负面只计一次） |
| `_pos_mirror_depth` | int | 宿魂附体镜像递归深度（防互附死循环，上限 8；每次搜索步重置） |

**`Sim.clone()` 覆盖**：上表全部字段（`walk_cache*`/`soft_cache` 共享引用，其余 duplicate）。

## 三、`build_state(descs, occ, gold, graves, obstacles, bombs, buff, active_fn?)` 读的 descs 键

- **`src/BattleSnapshot.gd::unit_desc` 自带**：`fn`、`hero`、`cell`、`hp`、`max_hp`、`atk`、`eatk`、
  `move`、`emove`、`atk_range`、`atk_type`、`skills`、`name`、`stunned`、`silenced`、`shield`、
  `heavy`、`poisoned`、`frozen`、`poss_by`、`immune_bombs`、`can_pickup_gold`、
  `atk_use_buff`、`move_use_buff`。
- **快照不带、由 harness 注入（缺省值 = 改动前行为）**：
  `row`（本方底线行，供镜像喂玩家方用）、`solid`、`ranged_adjacent`、`moved`、`attacked`、
  `counter_used`、`owner`、**`atkdown`（新）**、**`thorn`（新）**。
- `occ` 传 `"格 → 下标"`，`build_state` 内部统一转成 `"格 → SimUnit 对象"`。

## 四、检视器字段层建议对照的"真实侧等价物"

| Sim 字段 | 真实 `src/Unit.gd` 等价物 |
|---|---|
| `alive` | `u.alive` |
| `hp` / `max_hp` / `cell` / `eatk` / `emove` | `u.hp` / `u.max_hp` / `u.cell` / `u.effective_atk()` / `u.effective_move()` |
| `stunned` / `silenced` / `shield` / `heavy` / `solid` / `poisoned` / `frozen` | `u.has_status(StatusDB.X)` |
| `atkdown` / `thorn` | `u.has_status(StatusDB.ATKDOWN)` / `u.has_status(StatusDB.THORN)` |
| `moved` / `attacked` / `counter_used` | `u.moved_this_turn` / `u.attacked_this_turn` / `u.counter_used_this_turn` |
| `atk_use_buff` / `move_use_buff` | `u.atk_use_buff` / `u.move_use_buff` |
| `graves` / `obstacles` / `bombs` / `buff_cells` / `gold_cells` | `battle.graves` / `battle.obstacles` / `battle.bombs` / `battle.buff_items` / `battle.gold_left` |

> **没有真实侧等价物、检视器不应比对**：`hp0`、`pin_flag`/`pin_buffs`/`pin_init`、`atk_mod`、
> `atk`（模拟内部记账）、`hurt_times`、`aura_used`、`owner_idx`、`killed_players`、`buff_taken`、
> `gold_taken`、`pending_vanish`、`*_cache`、`_neg_gained`、`_pos_mirror_depth`、`sim_index`。

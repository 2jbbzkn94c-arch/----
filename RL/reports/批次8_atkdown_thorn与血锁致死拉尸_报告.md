# 批次 8 报告：`SimUnit.atkdown`/`thorn` 真字段 + 血锁致死拉尸 + 字段清单

> fork `RL/ai/AI_Battle.gd` sha12：**`247d68dc64b5`**（本轮起点 `26927b9889bc`）
> harness `RL/harness/技能对拍.gd`：新增场景 5 条、可读层加 2 个状态位（均是**追加**，原有场景与判定未改）
> 真实侧 `src/`、`heroes/`：**本次零改动**（`src/BattleSnapshot.gd` 也没加字段，见 §3 说明）

---

## 1. 用户实机撞到的假 DIFF 根因 + 修复

### 根因（确认）
`战锤(hero_25) 打 炸弹人(hero_35)` 那条：**检视器可读层两侧都显示"麻 否→是"（模拟其实挂上了）**，
但字段层报 `diffs=["… 状态[麻] 预测否→实际是"]` —— 因为它读的是 `SimUnit.atkdown`，
而 fork 里**没有这个字段**：麻痹的降攻记在 `atk_mod` 记账上。读不存在的键 → `null` → 恒 false → **假 DIFF**。

### 修复（fork `247d68dc64b5`）
1. `SimUnit` 新增两个**真字段**：
   - `atkdown: bool` —— [麻痹] 的**状态存在性**（`atk_mod` 记账**原样保留**，攻击力算法一行未改）；
   - `thorn: bool` —— [荆棘] 的**状态存在性**（移动力算法同样未改，见 §2 的如实说明）。
2. `SimUnit.clone()` 同步复制这两个字段（`cu.atkdown = u.atkdown` / `cu.thorn = u.thorn`）——
   漏了就会重现"同一回合搜索里状态丢失"的老问题。
3. 施加点同步维护：
   - `hero_25` 命中：`t.atk_mod -= 1` / `t.eatk -= 1` 之后 `t.atkdown = true`（负墟免疫分支不动）；
   - `hero_49` 命中：`t.emove = 0` 之后 `t.thorn = true`。
4. `build_state` 读 `d.get("atkdown", false)` / `d.get("thorn", false)` —— **缺省 false = 改动前行为**，
   生产路径（`BattleSnapshot` 不带这两个键）行为完全不变。

### 矩阵验证（新增场景 + 可读层补位）
- `技能对拍.gd` 两侧可读层都补了 `麻` / `荆`（真实侧 `has_status(ATKDOWN/THORN)`，
  sim 侧 `SimUnit.atkdown/.thorn`）→ 原有 `负面·战锤` / `负面·荆棘树人` 场景**自动升级**为状态一致性检查。
- 新增两条"负面挂上之后单位还要行动"的复合场景（两动作，真实与 sim 各走同一动作序列）：
  - `负面·麻痹后出招`：战锤打 X → X 立刻出招（吃 −1 攻）→ **MATCH**；
  - `负面·荆棘后出招`：荆棘树人打 X → X 立刻出招（荆棘只禁移动、不禁攻击）→ **MATCH**。
- harness 的 `_build_sim` 像 `solid` 一样把真实状态注入 descs（`atkdown`/`thorn`）。

**实测**（fork `247d68dc64b5`）：

| 场景/英雄 | 结果 |
|---|---|
| `hero_25`（战锤本体） | `cases=46 match=42 diff=0 skip=3 snap=1` |
| `hero_49`（荆棘树人本体） | `cases=46 match=42 diff=0 skip=3 snap=1` |
| `hero_10`（远程 × 麻痹记账） | `negative·麻痹后出招` MATCH；本轮 diff 仅`血锁`那条（hero_10 无） |
| `hero_44`（负墟，免疫麻痹/荆棘） | `cases=48 match=43 diff=0 skip=3 snap=2`（两个负面都不挂、不误报） |
| `hero_41`（真实侧落地后复跑，fork `fa78a1f9e90c`） | `cases=48 match=44 **diff=0** skip=3 snap=1` —— `血锁·致死拉尸` 与对照 `血锁·活人拉近` **均 MATCH** ✔ |

## 2. 关于 THORN（荆棘）——如实说明

- **已经建模了**（不是"永远 false 的假字段"）：真实 `src/Unit.gd::effective_move()`
  对 `STUN/THORN` 直接返回 0，fork 的既有做法是在命中时把目标 `emove` 记成 0 ——
  这**就是**荆棘的效果，矩阵里 `负面·荆棘树人` 一直是 MATCH（可读层 `emove 2→0` 两侧一致）。
- 本次只是**补上"状态在不在"这一位**（`thorn`），让字段层能按状态比对；
  移动力算法、免疫分支、`emove=0` 的效果记账**都没动**。
- 唯一"没建模"的是**派生可见性**：荆棘与眩晕在 sim 里没有独立的 `can_move()` 概念
  （真实 `Unit.can_move()` 同时被移动枚举与技能钩子读）。当前 sim 靠 `emove=0` 等价覆盖移动枚举，
  矩阵 49 英雄 0 diff —— 没有发现需要额外建模的证据，**不建议**为此扩工程。

## 3. 快照（`src/BattleSnapshot.gd`）为什么没加这两个键

`unit_desc` 目前不带 `atkdown`/`thorn`，所以 fork 用"缺省 false + harness 注入"的方式兼容。
这**不影响**真实规则：两者在快照里的**效果**本来就已体现（`eatk` 已含麻痹降攻、`emove` 已含荆棘清零），
新字段只服务"按状态比对"的字段层。
如果检视器/对拍想不注入就拿到状态，需要给 `src/BattleSnapshot.gd::unit_desc` 再加两行 ——
**按纪律这要先问用户**，本次没有动。

## 4. 血锁(hero_41) 规则变更：一击致死也拉尸（模拟侧已同步）

- **真实闸门（另一任务实测确认，本报告据此修正注释归因）**：`src/Battle.gd::_trigger_on_attack`
  按目标存活分派 —— 活人走 `hero_41::on_attack`，**致死走 `hero_41::on_attack_dead`**，
  两者共用 `_pull_with_hook(target)`。所以**只去掉 `on_attack` 里的存活守卫等于没改**（对照实验逐字相同）。
- **sim 侧触发点对得上**：fork 的 `_sim_pull_target` 调用点在"统一伤害出口判死**之后**"的命中后钩子区
  （该处的旧守卫 `and t.alive` 正是为致死分支而设）→ 致死分支天然覆盖，**不是**只在 `on_attack`
  那条路径上判断。实测佐证：`血锁·致死拉尸` 里 sim 侧把碑搬到了 (2,4)。
- 改动：`_sim_pull_target` 去掉"目标存活"前置；**亡者分支**：不进 `occ`、把 `sim.graves` 从原格**搬到新格**
  （召唤物不立碑）、**不**触发炸弹/道具拾取；活人分支照旧（含拉到炸弹格引爆）。
- 矩阵新增：`血锁·致死拉尸`（X(2,5)↔目标(2,2)，目标 1 血被钩死）、`血锁·活人拉近`（对照）。
- **当前状态**：`血锁·活人拉近` = MATCH；`血锁·致死拉尸` = DIFF
  （`graves: 真实=["(2,2)"] | AI模拟=["(2,4)"]`）——**真实侧改动尚未落地**，这是**预期 DIFF**，
  不是回归；真实侧改完后会自然转 MATCH（模拟侧无需再改）。

## 5. 交付物

- `RL/reports/SimUnit_Sim_字段清单.md` —— **`SimUnit` / `Sim` 全部字段表**（名字+类型+含义）、
  `clone()` 覆盖情况、`build_state` 读取的全部 descs 键、"真实侧等价物"对照表、
  以及"没有真实等价物、检视器不应比对"的字段清单（给检视器启动自检当对照表用）。
- 本报告 + 矩阵证据：`RL/reports/fix13_atkthorn.txt`、`RL/reports/fix14_pull.txt`。
- `RL/reports/已知窄差异与场外界线_登记.md` 新增两条：
  §5 harness 边界（`_apply` 不复核走位）、§6 血锁致死拉尸的预期 DIFF 与真实侧落地判据。

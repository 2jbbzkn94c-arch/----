# 负墟(hero_44)钩子化 + hero_28 描述 交付报告

日期：2026-09-12 · 执行：子代理（白名单严格受限）

## 1. 改动清单（sha256 前 12 位）

| 文件 | 改前 | 改后 | 备份 |
|---|---|---|---|
| `src/Unit.gd` | `1849762e6e9f` | `714cbc49597f` | `RL/reports/backup_20260912/Unit.gd` |
| `heroes/HeroBase.gd` | `04a2febe44df` | `a4fbb139203a` | `RL/reports/backup_20260912/HeroBase.gd` |
| `heroes/hero_44_负墟.gd` | `eb7aa8f3de9f` | `1160b90d4d1c` | `RL/reports/backup_20260912/hero_44_负墟.gd` |
| `英雄相关/角色列表.json` | `c76764d18e03`（我备份时） | `52e71fe1d887` | `RL/reports/backup_20260912/角色列表.json`（**不是我改的**） |

一键回退：把 `RL/reports/backup_20260912/` 里的同名文件拷回原位即可（该目录已放 `.gdignore`）。

注意：`backup_20260912/` 里的 `.gd` 副本会被 Godot 当成项目脚本（重复 `class_name`），**必须保留 `.gdignore`**，否则 hero_44 会 `Parse Error: Class "HeroNullfield" hides a global script class`。

## 2. 任务 1：hero_28 描述（已被外部完成，我未写该文件）

`英雄相关/角色列表.json:309` 现在已经是原文：

```
        "我方回合开始时，随机变为己方队伍中的一名其他角色，暂时获得其所有技能和特性，直到下次变化为止。",
```

- JSON 合法性：`ConvertFrom-Json` 通过，52 行；新文本出现 1 次，旧文本出现 0 次。
- 该文件在 **14:43:55** 被外部改动（同时 `英雄相关/角色列表.xlsx` 14:43:37 由 25316→25328 字节），diff 里另有一条**与本任务无关**的改动：末日(hero_31) 的"配合"列 `能提供攻击力加成的角色` → `""`。
- **白名单外仍存同份（旧）描述文本的位置，需你决定是否同步**：
  1. `heroes/hero_28_古灵精怪.gd:2` —— 脚本头注释仍是"对方回合结束时……暂时获得其所有技能直到下次变化为止。"（且漏了"和特性"）。不在白名单，我没动。
  2. `RL/reports/英雄效果核对.md:151、181` —— 报告里的引用（含"不一致"结论）。
  3. `英雄相关/角色列表.xlsx` —— 二进制，我无法读写；14:43 已被外部改过，是否已同步请你在 Excel 里确认。
  4. `autoload/DataRegistry.gd` 无描述兜底表（技能文本直接来自本张表），无副本。

## 3. `git status --short` 原文

```
 M heroes/HeroBase.gd
 M heroes/hero_44_负墟.gd
 M src/Unit.gd
 M 英雄相关/角色列表.json
 M 英雄相关/角色列表.xlsx
?? RL/
```

前 3 个是我改的白名单文件；json/xlsx 是外部改动（见第 2 节）。

## 4. 每个文件的完整 diff

`RL/reports/diff_src_Unit.gd.txt`、`RL/reports/diff_heroes_HeroBase.gd.txt`、`RL/reports/diff_heroes_hero_44_负墟.gd.txt`（也可 `git diff -- <file>`）。要点：

- `HeroBase.gd`：+11 行，只新增两个默认实现钩子 —— `immune_to_negative()->bool`（默认 false）、`on_negative_blocked()->void`（默认空），紧挨已有的 `immune_to_bombs()`。其余 48 英雄零影响。
- `Unit.gd`：净 -9 行。`add_status` 里 `hero_id == "hero_44"` 硬编码 → `behavior.immune_to_negative()` 调用；删除 `_neg_immune_on_hit()` 与成员 `_neg_immune_frame`；TODO 注释随之移除。**Unit 里不再有第二份负墟逻辑。**
- `hero_44_负墟.gd`：+19/-2 行。`immune_to_negative()=true`；`on_negative_blocked()` 内做同帧去重 + `unit.atk_buff += 1` + `unit.refresh_stats()` + `unit._float_text("免疫负面 攻+1", …)`。

## 5. 对拍前后对照

**摘要行原文**（harness 版本不同，见第 7 节说明）：

```
PRE  all: SK|SUMMARY|mode=all|cases=742|match=494|diff=102|skip=132|snap=14|fork_sha=bc53af932adf
POST all: SK|SUMMARY|mode=all|cases=938|match=638|diff=105|skip=132|snap=63|fork_sha=bc53af932adf
PRE  h44: SK|SUMMARY|mode=hero_44|cases=15|match=10|diff=2|skip=3|snap=0|fork_sha=bc53af932adf
POST h44: SK|SUMMARY|mode=hero_44|cases=18|match=12|diff=2|skip=3|snap=1|fork_sha=bc53af932adf
```

**逐场景对拍（核心证据，`RL/reports/ev_compare.txt`）**：把两次 `-- all` 的全部 `SK|EV|` 行按场景名配对逐字节比 —— **common=610 / byte_identical=610 / different=0**；pre-only=0；post-only=196（全是新版 harness 新增场景）。`hero_44` 专项 common=12 / identical=12 / different=0。两份日志均 **0 条 SCRIPT ERROR**（`RL/reports/log_health.txt`）。

**hero_44 四个场景（原样行）**：

```
PRE  SK|EV|hero_44·出招|MATCH|units[hero_13@(2, 3)]:40/40|eatk=2|emove=2|→38/40|eatk=2|emove=2| ; units[hero_44@(2, 4)]:23/26|eatk=2|emove=2|→21/26|eatk=2|emove=2|已攻
POST SK|EV|hero_44·出招|MATCH|units[hero_13@(2, 3)]:40/40|eatk=2|emove=2|→38/40|eatk=2|emove=2| ; units[hero_44@(2, 4)]:23/26|eatk=2|emove=2|→21/26|eatk=2|emove=2|已攻
PRE  SK|EV|hero_44·出招·距离2|MATCH|units[hero_13@(2, 3)]:40/40|eatk=2|emove=2|→38/40|eatk=2|emove=2| ; units[hero_44@(2, 5)]:23/26|eatk=2|emove=2|→23/26|eatk=2|emove=2|已攻
POST SK|EV|hero_44·出招·距离2|MATCH|units[hero_13@(2, 3)]:40/40|eatk=2|emove=2|→38/40|eatk=2|emove=2| ; units[hero_44@(2, 5)]:23/26|eatk=2|emove=2|→23/26|eatk=2|emove=2|已攻
PRE  SK|EV|hero_44·移动|MATCH|units+hero_44@(1, 3)=23/26|eatk=2|emove=2|已动 ; units-hero_44@(2, 4)
POST SK|EV|hero_44·移动|MATCH|units+hero_44@(1, 3)=23/26|eatk=2|emove=2|已动 ; units-hero_44@(2, 4)
PRE  SK|EV|hero_44·被攻击|MATCH|units[hero_13@(2, 3)]:40/40|eatk=2|emove=2|→38/40|eatk=2|emove=2|已攻 ; units[hero_44@(2, 4)]:23/26|eatk=2|emove=2|→21/26|eatk=2|emove=2|
POST SK|EV|hero_44·被攻击|MATCH|units[hero_13@(2, 3)]:40/40|eatk=2|emove=2|→38/40|eatk=2|emove=2|已攻 ; units[hero_44@(2, 4)]:23/26|eatk=2|emove=2|→21/26|eatk=2|emove=2|
```

`hero_44·击杀 / ·阵亡 = DIFF`（`graves: 真实=[…] | AI模拟=[]`）与 `SNAP·*` 的 SKIP/SNAP 是**改动前后完全相同**的既有缺口（模拟端未建模墓碑），按约定未修。

## 6. 负墟行为等价性论证

原来由 `Unit.add_status` 在"未挂状态"前用 `hero_id == "hero_44"` 判定并调用 `Unit._neg_immune_on_hit()`；现在同一个位置改成问 `behavior.immune_to_negative()`（负墟的 `HeroNullfield` 返回 true）并回调 `on_negative_blocked()`，被调用的对象仍是那个单位、语句顺序与运算（同帧去重 → `atk_buff += 1` → `refresh_stats()` → 飘字）逐行相同；`behavior` 与 `hero_id` 在 `_spawn_unit`(:1669)、`_apply_base_hero`(:4177)、`_transform`(:4219-4223) 三处始终一起赋值，唯一可能不一致的是 `_transform` 内 4177→4219 的同步窗口（其间只有字段赋值与 `refresh_identity()`，不会调用 `add_status`），召唤物与替补登场路径的 `behavior` 也在 `_hero(u)` 里补建，因此钩子判定与旧硬编码**逐位等价**。附带两点：圣盾判定仍在免疫之前（带盾者先扣盾、不计 +1）；沉默/眩晕与旧实现一致地**不影响**免疫（两版都没有 `skill_allowed()` 判定）。

## 7. 已知例外与待办

1. **"每次负面 +1 攻"未被对拍覆盖 → 需你手动验**：新版 harness 里 hero_44 的敌人假想靶全是 `hero_13` 独脚龟（攻击不带任何负面），所以免疫/成长路径一次都没被触发（`被攻击` 那条的 `eatk` 始终 2）。手动步骤：用带负面的英雄打负墟 —— 毒蛇淑女[猛毒]、巨剑[重伤]、**战锤[麻痹+冰冻]（同一次攻击两个负面，验证同帧只 +1）**、沉默术士[沉默]、白游侠/雪拳[冰冻]、宿魂[附体]、荆棘树人[荆棘]；现象：目标身上不出现紫色减益、负墟牌面弹"免疫负面 攻+1"且攻击力 +1、回合结束后回落到原值。再补两条边界：①负墟带[圣盾]被负面打 → 先扣盾、不 +1；②古灵精怪变身为负墟后同样免疫。
2. **我造成并已修复的事故**：最初把 3 个 `.gd` 备份进 `RL/reports/backup_20260912/`（项目内），Godot 把副本的 `class_name HeroBase/HeroNullfield` 写进 `.godot/global_script_class_cache.cfg`，导致真脚本报"hides a global script class"、hero_44 无法生成。处置：备份目录加 `.gdignore`、删掉 Godot 在其中生成的 3 个 `.uid`、跑 `--import` 重扫（cache 15:18:46 已无 `res://RL/` 条目）。因此 **`RL/reports/verify_all_before2.log`（hero_44 全 SETUP 那次）作废**，不要引用。
3. **harness 一直在被别人改**，所以拿不到"同版本改前/改后"的 `SK|SUMMARY|` 对比：改前 `9cde6dab089b`（cases=742，`verify_all_before3.log` / `hero44_before3.log`），改后 `9b8984de01ba`（cases=938，`verify_all.log`；sha 在整次运行前后一致）。上述结论因此建立在**逐场景 `SK|EV|` 逐字节比对**上（610/610 一致），`diff` 计数 102→105、`snap` 14→63 的增量全部来自新增的 196 个场景（共有场景里没有一条判定变化）。两次运行 `fork_sha` 都是 `bc53af932adf`，即模拟端字节未变。
4. **另一个环境问题（非我引入，已由上级修复）**：15:0x 那次 post 跑出 78 条 SCRIPT ERROR（`Could not parse global class "HexGrid" from "res://RL/ai/AI_HexGrid.gd"`）、hero_18 全 SETUP；类缓存修好后重跑为 0 错误。污染版本留档 `RL/reports/verify_all_polluted_1518.log`。
5. 未做、也不该由我做的：未跑 `tests/`、未改 harness/其它英雄/Battle.gd、未 commit、未放宽任何判定。

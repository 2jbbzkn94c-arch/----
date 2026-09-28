class_name HeroBase
extends RefCounted
## 单个英雄的「行为」基类。每个英雄一个脚本（hero_XX.gd）继承本类。
## 属性数值（攻/防/血/移动/射程/词条）仍由 DataRegistry 从 角色列表.md 解析，
## 这里只存放该英雄的**技能实现**（对战斗层的各个触发时机做反应）。
##
## 触发时机（Battle 通过 _hero(u) 分发）：
##   on_turn_start / on_turn_end / on_move / on_attack / on_attack_dead
##   on_enter / on_attack_obstacle / damage_mult / counter_mult
##   on_someone_damaged(光环) / on_died / on_spawn
##   on_after_attack / on_after_counter / obstacle_damage
## 基类全部为 no-op，英雄脚本按需 override。
##
## 访问战斗状态：unit 指向本英雄所在单位；battle 指向 Battle 节点。
## 战斗原语（_heal/_knockback/_swap_units/_damage_obstacle...）集中在 Battle，
## 英雄脚本通过 battle.<原语>(...) 动态调用。battle 有意保持未定型，
## 以便对 Battle 的私有方法做动态分发（定型 Node 会因方法不存在而解析失败）。

var battle = null
var unit: Unit = null

## 由 HeroRegistry 创建后调用，注入上下文。
func setup(battle_: Node, unit_: Unit) -> void:
	battle = battle_
	unit = unit_

# ---- 触发器（默认 no-op）----

## 播放本英雄专属技能特效（在英雄**真正施放技能的那一刻**调用，避免平时到处乱触发）。
func fx() -> void:
	if unit == null or not is_instance_valid(unit):
		return
	var d := DataRegistry.hero_fx(unit.hero_id)
	unit.burst_fx(d.color, d.text)

## 技能命中目标处的受击特效：以本英雄主色在目标格爆环+粒子+白闪，不飘字(避免盖伤害数字)。
func fx_on_target(t: Unit) -> void:
	if unit == null or not is_instance_valid(unit):
		return
	if t == null or not is_instance_valid(t) or not t.alive:
		return
	var d := DataRegistry.hero_fx(unit.hero_id)
	t.burst_fx(d.color, "")

## 己方回合开始时触发。返回 true 表示有技能演出（用于被动闪烁）。
func on_turn_start() -> bool:
	return false

## 己方回合结束时触发。返回 true 表示有技能演出。
func on_turn_end() -> bool:
	return false

## 移动结算后触发。
func on_move() -> void:
	pass

## 攻击命中（目标存活）后触发。
func on_attack(_target: Unit) -> void:
	pass

## 攻击**出招动画**阶段的专属特效（在结算伤害之前调用，用于"攻击动作"本身的演出：
## 如嬉皮死神的镰刀横扫）。默认无。英雄专属特效一律写在自己的脚本里，Battle 只负责调用本钩子。
func play_attack_fx(_target: Unit) -> void:
	pass

## 能否拾取**金矿**（默认不能：金矿只有黄金矿工可拾，其他人踩到不消费、金矿留在格上）。
## 这是"是不是金矿的拾取者"的判定；捡到之后的收益见 on_pickup_gold()。
func can_pickup_gold() -> bool:
	return false

## 拾到一枚金矿时的收益结算（只有 can_pickup_gold() 为 true 的英雄会被调用）。
## Battle 负责把矿从盘面移除，收益数值全部写在本钩子里（黄金矿工：攻 +1 永久 / 上限 +3 / 回 3 血）。
func on_pickup_gold() -> void:
	pass

## 是否需要在"每方回合开始"做一次**整队取样**类结算（默认否）。
## 返回 true 的英雄会在每方回合开始被调用一次 on_side_turn_start（每方只调一次，见 Battle._begin_side）。
func wants_side_turn_start_sync() -> bool:
	return false

## 是否会在**伤害结算前**替队友分担伤害（默认否）。返回 true 的英雄才会被 Battle 依次询问。
## 用于塔盾这类"替相邻队友扛伤"的机制，避免 Battle 认识具体英雄。
func is_damage_absorber() -> bool:
	return false

## 替队友分担伤害（在队友的伤害结算**之前**调用，dmg 为其将受的伤害）。
## 返回分担后的伤害（未分担则原样返回 dmg）。默认不分担。
func absorb_ally_damage(_target: Unit, dmg: int) -> int:
	return dmg

## 是否向本方提供"移动光环"（默认否）。返回 true 的英雄会在队友移动/新人入场时被询问（如风语者）。
func grants_move_aura() -> bool:
	return false

## 队友完成移动后（mover 移动了 dist 格）：光环拥有者在此结算收益（风语者：回复 = 移动距离）。
## Battle 每方只派发一次（由第一个拥有该光环的队友处理），避免多个光环源重复结算。
func on_ally_moved(_mover: Unit, _dist: int) -> void:
	pass

## 队友新入场（替补登场）后：光环拥有者给新单位补上光环（风语者：+1 移动力）。
func on_ally_entered(_newcomer: Unit) -> void:
	pass

## 刷新"身份类状态位"（不随回合/变身失效的机制标志：血锁恒直线攻击、坠炮手全场射程等）。
## Battle 在"变身后"与"回合末清理临时状态时"调用；默认清成普通人，需要保留的英雄自行置位。
func refresh_identity() -> void:
	if unit == null or not is_instance_valid(unit):
		return
	unit.los_ignore = false
	unit.branch_override = false

## 近战出招时是否**跳过**"前冲再弹回"的动画（默认不跳过）。
## 适用于攻击后自身会位移/靠远程手段拉人的英雄（暗域换位、血锁钩爪），
## 前冲弹回会与后续位移演出打架。
func skips_lunge_anim() -> bool:
	return false

## 【2026-09-23 新增·用户实机反馈】这一击**结算之后**，我自己的出招演出还要放多久（秒）：
##   **反击会等这段时间 + 标准停顿再开始**（见 `Battle._apply_attack` 里那个 counter gap）。
## 为什么需要它（用户原话：「暗域换位后…换位动画结束，反击就来了」）：
##   `skips_lunge_anim()` 的那些英雄把"前冲再弹回"换成了**更长的演出**，而伤害是在演出**开始**时
##   就结算的 ⇒ 反击若只等固定的 0.15s，就会在换位/拖人还没放完时冲上来。
##   普通近战不受影响：它们的 0.22s 前冲动画是在伤害**之前**放完的。
## 返回 0（默认）= 行为与以前**逐位一致**（普通英雄、以及所有不写这个钩子的英雄）。
func attack_settle_delay() -> float:
	return 0.0

## 自身被动失效时（如坠炮手被沉默，全场狙击失效）射程退化成的值；-1 = 无此机制（默认）。
func suppressed_attack_range() -> int:
	return -1

## 面板/卡面是否按"移动 ∞"展示（大骑士冲锋）。默认否。
func shows_infinite_move() -> bool:
	return false

## 面板/卡面是否按"射程 ∞"展示（坠炮手全场狙击生效时）。默认否。
func shows_infinite_range() -> bool:
	return false

## 是否使用"直线冲锋"式移动（大骑士）：可达格 / 路径 / 步数上限全部交给本脚本决定。默认否。
func uses_charge_movement() -> bool:
	return false

## 【2026-09-21 用户定稿】**瞬移式移动**（宿魂 hero_46：「可以移动到任意格子」）。
## 口径（用户逐条确认）：**每回合都能用** · 落点 = **任意空格**（**可以落道具格/炸弹格**；
##   不能落墓碑/障碍/单位格）· **算一次移动**（走完不能再动，攻击照常）·
##   **不触发「队友移动后」类效果**（风语者的回血/移动光环）· **会拾取道具、会踩炸弹**。
## 默认实现按 `hero_id` 兜底（**故意不改英雄脚本**：用户正在改这几个英雄，避免撞车）；
##   英雄脚本要显式表达时，覆盖本函数即可。
func uses_teleport_movement() -> bool:
	return unit != null and unit.hero_id == "hero_46"

## 瞬移的可达格集合（`uses_teleport_movement()` 为真时 Battle 直接采用本结果；默认空 = 用 Battle 的通用实现）。
func teleport_reachable_cells() -> Dictionary:
	return {}

## 【2026-09-21 用户定稿】瞬移式移动的**演出**：不要"平移过去"，改成
##   「原地沉入地下 → 在落点从地里钻出来（渐显 + 由小放大）」。
## 与 `uses_teleport_movement()` 同一套兜底口径（按 hero_id，不改英雄脚本，避免撞车）。
func uses_emerge_move_anim() -> bool:
	return unit != null and unit.hero_id == "hero_46"

## 冲锋式移动的可达格集合（uses_charge_movement() 为 true 时 Battle 直接采用本结果）。
func charge_reachable_cells() -> Dictionary:
	return {}

## 冲锋路径（沿 6 轴向直线冲向 target，遇阻挡即停在阻挡前）；返回空数组 = 一步未动。
func charge_path(_target: Vector2i) -> Array:
	return []

## 冲锋单次移动的步数上限（冲锋不封顶，但仍设一个安全上限）。默认 60。
func charge_step_cap() -> int:
	return 60

## 冲锋落定后结算（actual_steps = 本次实际冲到的格数，0 = 一步未动）。
func on_charge_settled(_actual_steps: int) -> void:
	pass

## 能否放置炸弹（炸弹人：移动后可在周围空地放雷）。默认否。
## 这是"有没有这个能力"的粗判（联机 bomb 指令的合法性预检）；具体能放哪几格见 bomb_place_cells()。
func can_place_bomb() -> bool:
	return false

## 本英雄此刻可以放炸弹的格（默认空数组 = 一个都放不了）。
## 放置合法性、UI 橙色高亮、AI 落点全部以此为准；Battle 只提供地形合法性原语 bomb_cell_ok(cell)。
func bomb_place_cells() -> Array:
	return []

## 是否免疫炸弹（炸弹人自己踩雷不引爆）。默认否。
## Battle 在逐格移动 / 击退 / 拉近 / 换位 / 瞬移 / 召唤等所有落点统一询问本钩子。
func immune_to_bombs() -> bool:
	return false

## 是否免疫一切负面状态（默认否）。返回 true 的英雄：Unit.add_status 拒绝挂上该负面状态
## （毒/重伤/麻痹/冰冻/沉默/眩晕/附体/荆棘），改为回调 on_negative_blocked()。
## 判定在圣盾之后（带盾者先被盾挡下，不算"被负面命中"，走不到这里）。
func immune_to_negative() -> bool:
	return false

## 一次负面状态被免疫挡下时回调（默认无事发生；负墟借此"被负面命中"计数 +1 攻）。
## 同一次攻击内连续施加多个负面，Unit 会逐个询问，是否只计一次由英雄自己决定。
func on_negative_blocked() -> void:
	pass

## 变身为该英雄后，是否补触发一次"回合开始技"（默认补触发）。
## 古灵精怪变回自身时不补，避免重复触发自己的回合开效果。
func wants_turn_start_on_transform() -> bool:
	return true

## 回合结束时，即使被沉默也要执行 on_turn_end()（召唤物消散等非技能效果）。默认否。
func runs_turn_end_while_silenced() -> bool:
	return false

## 己方回合开始时的**非技能**结算：不受沉默/眩晕影响，只用来清"跨回合账目"
## （如锤头鲨的攻击力加成到本方回合开始即到期）。技能类的回合开始效果仍走 on_turn_start
## ——那个被沉默就不触发，所以到期清理不能挂在它上面，否则被沉默时会漏清。
func on_own_turn_start_always() -> void:
	pass


## 阵营级回合开始同步（在"回合开始技"全部触发**之后**调用一次）。
## 用于需要先采样整队状态再统一赋值的英雄（如共鸣者按"所有队友攻击力之和"改写自己攻击力）。
func on_side_turn_start(_faction: int) -> void:
	pass

## 变身为该英雄后调用（古灵精怪变形）：用于"变身即生效"的数值补算。
## 默认行为：清掉变身前的临时加成残留（共鸣加成等不随变身保留）。
func on_become_hero() -> void:
	if unit == null or not is_instance_valid(unit):
		return
	unit.echo_set = -1
	unit.refresh_stats()

## 攻击命中且目标被打死后触发（死于本次攻击）。
func on_attack_dead(_target: Unit) -> void:
	pass

## 替补登场时触发。
func on_enter() -> void:
	pass

## 以障碍物为攻击目标时触发（AOE/穿透类）。
## 已停用：**主动攻击障碍物不触发英雄技能**（障碍只承受直接攻击 / 伐木工额外伤害），
## 保留空实现仅避免破坏继承接口。
## 与之互补的另一条规则：技能**对敌人生效时波及到**的障碍会掉耐久
## （剑气穿透/散射/自爆等，走 Battle.sweep_obstacles / sweep_obstacles_around）。
func on_attack_obstacle(_oc: Vector2i) -> void:
	pass

## 攻击/反击的主动伤害倍率（乘在基础伤害上）。默认 1。
func damage_mult(_target: Unit) -> int:
	return 1

## 本次攻击命中后会附加负面状态(毒/冻/重伤/麻痹/沉默…)。
## 带盾目标被此类攻击命中时：圣盾优先保留给异常(伤害不吃盾),使目标不吃状态。
func applies_status_on_hit() -> bool:
	return false

## 反击倍率。默认 1。
func counter_mult() -> int:
	return 1

## 反击命中目标(原攻击者)时的受击演出回调(默认无)。
func on_counter_landed(_target: Unit) -> void:
	pass

## 反击次数是否不受"每回合一次"限制（复仇者：反击次数无限）。默认 false。
func infinite_counter() -> bool:
	return false

## 任意单位受到伤害时触发（光环类：圣光/塔盾/锤头鲨）。
## target 为受伤单位，amount 为实际伤害。
func on_someone_damaged(_target: Unit, _amount: int) -> void:
	pass

## 自身阵亡时触发（红帽扑街等）。
func on_died() -> void:
	pass

## 被**主动撤下**（撤下/换替补）时触发。与 on_died 分开是有意的：
##   "阵亡才发动"的技能（红帽扑街自爆）在撤下时**不该发动**；
##   而"离场清理"（风语者收回移动光环）必须照做——那类英雄覆写本钩子即可。
func on_withdrawn() -> void:
	pass

## 出生/上场时的数值修正（大骑士冲锋、血锁射程等）。spawn 时调用。
func on_spawn() -> void:
	pass

## 主动攻击结算后触发（太阳斩攻击后攻-1）。
func on_after_attack() -> void:
	pass

## 反击结算后触发（太阳斩反击后攻-1）。
func on_after_counter() -> void:
	pass

## 攻击障碍物时造成的耐久伤害。默认 1（伐木工额外+99）。
func obstacle_damage() -> int:
	return 1

## 是否由英雄自己在 on_attack 中结算基础攻击伤害（长角在击退/2倍中一并结算）。
## 默认 false：Battle 先按常规结算基础伤害，再触发 on_attack 追加效果。
func handles_base_damage() -> bool:
	return false

## 【2026-09-28·新增】"这一击大概多少伤害"——只给**击杀预告**用（`Battle._kill_intro()` 决定要不要先播击杀卡面）。
## 默认 = 面板伤害 × 克制系数（与 `Battle._apply_attack()` 结算用的同一式）。
## ⚠️ **自己结算伤害**的英雄（`handles_base_damage() == true`）必须重写它：预告按默认的 1 倍估，
##    会漏掉"长角不能击退时的 2 倍"那类差异 ⇒ 双倍才打死的局面不播击杀特效（用户 2026-09-28 报的就是这个）。
## 只影响演出，不参与任何伤害/判定。
func preview_attack_damage(target: Unit) -> int:
	if battle == null or unit == null:
		return 0
	return battle._attack_total(unit, target)

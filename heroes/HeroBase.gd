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
func can_pickup_gold() -> bool:
	return false

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
## 已停用：障碍物不再触发英雄技能（仅承受直接攻击 / 伐木工额外伤害），
## 保留空实现仅避免破坏继承接口。
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

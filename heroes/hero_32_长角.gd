extends HeroBase
## 长角：攻击时，将目标击退1格。如果其后方有阻挡不能击退，则造成2倍伤害。
## 长角自己结算基础伤害（击退则1倍，无法击退则2倍），故 handles_base_damage=true。
class_name HeroLonghorn

func handles_base_damage() -> bool:
	return true

func on_attack(target: Unit) -> void:
	fx()
	fx_on_target(target)
	if target == null or not target.alive:
		return
	var kb: bool = battle._knockback(target, unit.cell)
	var hdmg: int = battle._attack_damage(unit) * _bonus_damage(target)
	var hit: int = hdmg if kb else hdmg * 2   # 击退=1 倍；不能击退=2 倍
	target.set_big_hit_style()   # 撞击/重击均为技能伤害数字,大号突出
	var hp_before: int = target.hp
	target.take_damage(hit, false, false,
			("被%s撞飞" % unit.display_name) if kb else ("被%s的重击重创" % unit.display_name), true)
	# 【演出】长角自己结算平A伤害（Battle 不代结），所以震屏也要在这里补一处：
	# 与其它攻击同一判定口径 —— 面板伤害 ≥6 且真的打掉了血（含击杀）就震；被圣盾格挡/坚固完全防住（0 伤）不震
	battle._shake_once(hit, hp_before - target.hp)

func _bonus_damage(target: Unit) -> int:
	return battle._bonus_damage(unit, target)

## 【2026-09-28·用户报「长角双倍伤害打死对方时没有触发击杀特效」】击杀预告（`Battle._kill_intro()`）
## 要"这一击多少伤害"才能判断会不会打死人：长角自己结算伤害（`handles_base_damage() == true`），
## 所以必须把"**能击退 = 1 倍 / 不能击退 = 2 倍**"这条也报上去 —— 按默认的 1 倍估，
## 双倍才打死的局面会被判成"打不死" ⇒ 不播击杀卡面（用户报的就是这个）。
## ⚠️ 用 `battle._knockback_dest()`（**纯计算**：不真的推人、不触发炸弹/拾取），
##    与 `on_attack()` 真正结算时走的是**同一把尺**（`_knockback()` 内部也调它）。
func preview_attack_damage(target: Unit) -> int:
	var hdmg: int = battle._attack_damage(unit) * _bonus_damage(target)
	if target == null or not is_instance_valid(target) or not target.alive:
		return hdmg
	return hdmg if battle._knockback_dest(target, unit.cell).x != -99 else hdmg * 2

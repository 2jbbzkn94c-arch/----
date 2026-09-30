extends HeroBase
## 共鸣者：我方回合开始时，攻击力**变为**所有队友攻击力之和，直到我方回合结束。
## 本脚本负责全部结算（Battle 只负责在"回合开始技全部触发之后"派发一次本钩子）。
## 被沉默/眩晕时本回合不共鸣；我方回合结束由 _clear_statuses 清 echo_set 复位。
class_name HeroEcho

## 需要"整队取样再赋值"：每方回合开始被派发一次
func wants_side_turn_start_sync() -> bool:
	return true

## 阵营级回合开始同步：先对所有共鸣者**取样**（此刻都还没吃到共鸣加成），再统一赋值，
## 避免"先赋值的共鸣者污染后者的取样"（古灵精怪变身成第二个共鸣者时会遇到）。
func on_side_turn_start(faction: int) -> void:
	var list: Array = []
	for u in battle.units:
		if u == null or not is_instance_valid(u) or not u.alive:
			continue
		if u.faction == faction and u.hero_id == "hero_47" and u.skill_allowed():
			list.append(u)
	if list.size() == 0:
		return
	var sums := {}
	for u in list:
		var total := 0
		for v in battle.units:
			if v == null or not is_instance_valid(v) or not v.alive:
				continue
			if v == u or v.faction != faction:
				continue
			total += v.effective_atk()
		sums[u] = total
	for u in list:
		u.echo_set = sums[u]
		u.refresh_stats()
		# 【2026-09-30·用户口径「共鸣者要"共鸣"」】取样赋值完（技能真生效）⇒ 每个共鸣者各弹一次「共鸣」。
		#   颜色/文案走 `HERO_FX["hero_47"]`（原来这条整条没登记 ⇒ 查表拿到白字空文案 = 什么都不弹）。
		#   ⚠️ 只在这一处弹：`on_become_hero()`（古灵精怪变身成共鸣者）那条路**不弹** ——
		#   变身本身已经飘了「变身」，再叠一个就是两个字样（风语者那次的老毛病）。
		var kd := DataRegistry.hero_fx("hero_47")
		u.burst_fx(kd.color, kd.text)

## 变身为共鸣者：立即按当前队友取和（插队变身也不耽误当回合）
func on_become_hero() -> void:
	if unit == null or not is_instance_valid(unit) or not unit.alive or not unit.skill_allowed():
		return
	var total := 0
	for v in battle.units:
		if v == null or not is_instance_valid(v) or not v.alive:
			continue
		if v == unit or v.faction != unit.faction:
			continue
		total += v.effective_atk()
	unit.echo_set = total
	unit.refresh_stats()

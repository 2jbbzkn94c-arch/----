extends HeroBase
## 红帽：扑街时，对相邻的**敌方**单位造成13点伤害（**不再误伤己方**）。强退时不触发。
## 自爆波及到的相邻障碍物各掉 1 点耐久（技能波及障碍要掉耐久）。
class_name HeroRedhood

## 扑街自爆的伤害数（三处共用：击杀预告 / 卡面请求 / 真正结算 —— 只此一份，防各自写死漂移）
const BLAST_DMG := 13

func on_died() -> void:
	# 被[沉默]或[眩晕]期间阵亡：非关键词技能失效，不再触发扑街自爆
	if unit == null or unit.has_status(StatusDB.SILENCE) or unit.has_status(StatusDB.STUN):
		return
	play_skill_sfx()   # 扑街自爆发动（被沉默/眩晕时上面已 return，不响）
	# 自爆演出：双环扩散（橙红主环 + 外扩亮环）
	if unit != null and unit.is_inside_tree():
		battle._boom_ring_fx(unit.cell, Color(1.0, 0.55, 0.25), 1.4, 0.3)
		battle._boom_ring_fx(unit.cell, Color(1.0, 0.85, 0.4), 2.2, 0.45)
	battle.sweep_obstacles_around(unit.cell)   # 自爆波及到的相邻障碍：各 -1 耐久
	for v in battle.units:
		if v == null or not is_instance_valid(v) or not v.alive:
			continue
		# 【2026-10-01·用户「把红帽的技能效果改成只对敌人造成爆炸伤害」】只炸**敌对阵营**：
		#   同阵营（含她自己）一律跳过 —— 原来这里是"相邻的**所有**单位（含己方队友）"。
		if v.faction == unit.faction:
			continue
		if battle.grid.distance(unit.cell, v.cell) == 1:
			# 【2026-09-30·用户报「技能波及到的目标死亡时候，不弹击杀特效」】自爆炸死相邻敌人也弹卡面
			#   （`is_attack = false`：自爆不是"攻击伤害"，与下面 `take_damage` 的默认口径一致）
			#   【2026-10-03】主路径已改成**先播卡面再落地**（见 `death_blast_hits()`：那一击打死我之前
			#   就把这些人的卡面播完）⇒ 这一句现在只兜底"没有预告可用的死法"（中毒 / 烧血 / 踩雷 /
			#   附体等），同一招里重复请求会被 `Battle._kill_intro_seen` 挡掉。
			battle.kill_intro_side(unit, v, BLAST_DMG, false)
			v.take_damage(BLAST_DMG, false, false, "被%s扑街自爆波及" % unit.display_name)
			battle.log_message.emit("红帽扑街，波及 %s！" % v.display_name)

## 【2026-10-03·用户口径「击杀特效要在杀死人之前」】击杀预告：我**阵亡**时这一炸会打到谁。
##   判据与 `on_died()` 里那个循环**逐条同一把尺**：同一批目标（相邻的**敌对阵营**活人，跳过同阵营
##   含自己）、同一个伤害数（`BLAST_DMG`）、`is_attack = false`。
##   ⇒ `Battle._kill_intro()` 在"这一击会打死我"的那一刻拿它播完这些人的卡面，之后自爆才落地
##   ⇒ 观感从"人被炸死了卡面才出来"变成"卡面滑完 → 才炸"。
##   ⚠️ 纯查询：不改状态、不引爆。⚠️ 两道门与 `on_died()` 同尺：被[沉默]/[眩晕]时自爆不发动
##   （`skill_allowed()`）⇒ 这里一个字都不报。
func death_blast_hits() -> Array:
	var out: Array = []
	if unit == null or not is_instance_valid(unit):
		return out
	if not unit.skill_allowed():
		return out   # 被[沉默]/[眩晕]：扑街自爆不发动（与 `on_died()` 开头那道门同一把尺）
	for v in battle.units:
		if v == null or not is_instance_valid(v) or not v.alive:
			continue
		if v.faction == unit.faction:
			continue
		if battle.grid.distance(unit.cell, v.cell) == 1:
			out.append({ "v": v, "dmg": BLAST_DMG, "atk": false })
	return out

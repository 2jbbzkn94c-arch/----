extends HeroBase
## 死灵法师：己方回合开始时，随机在相邻位置召唤 2 个骷髅兵（位置不足则少召）。
## 阵亡时他召唤的骷髅兵一起消散。
class_name HeroNecro

func on_turn_start() -> bool:
	battle._summon_skeletons(unit)
	play_skill_sfx()   # 召唤即技能发动（阵亡消散那一下不重复响）
	return true

## 阵亡：自己召唤的骷髅兵一起消散（骷髅都带召唤者 id summon_owner，逐个淡出离场）
func on_died() -> void:
	_skeletons_vanish()

## 被主动撤下（换替补）：同样让他召唤的骷髅一起消散——
## 撤下不发动"阵亡技能"，但这是"离场清理"（骷髅靠 summon_owner 绑定主人），必须照做
func on_withdrawn() -> void:
	_skeletons_vanish()

func _skeletons_vanish() -> void:
	if unit == null or not is_instance_valid(unit):
		return
	for s in battle.units.duplicate():
		if s == null or not is_instance_valid(s) or not s.alive:
			continue
		if s.hero_id != "summon_skeleton" or s.summon_owner != unit.id:
			continue
		battle.log_message.emit("%s 召唤的骷髅兵随之消散。" % s.display_name)
		s.alive = false
		# 【2026-09-30·同 `summon_骷髅兵.gd` 那处】原来写 `battle._skeleton_owner_gone.bind(s)`：
		#   回调 0.25 秒后才响，而这段路上骷髅可能先被释放（它同时被打死 / 主人在同一次结算里
		#   被撤下又阵亡）⇒ 绑进去的是已释放实例，`_skeleton_owner_gone(s: Unit)` 的形参转换
		#   在**进入函数体之前**就失败（用户贴的 `Cannot convert argument 1 from Object to Object`）。
		#   改法同款：补间绑在骷髅自己身上 + 回调走 `WeakRef` 重新取、校验后再调。
		var w_s: WeakRef = weakref(s)
		var st: Tween = s.create_tween()
		if st == null:
			battle._skeleton_owner_gone(s)   # 兜底：拿不到补间（不在树里）就直接收尾
			continue
		st.tween_property(s, "modulate:a", 0.0, 0.25)
		st.tween_callback(func():
			var u = w_s.get_ref()
			if u != null and is_instance_valid(u):
				battle._skeleton_owner_gone(u))

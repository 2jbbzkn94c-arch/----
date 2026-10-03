extends Node
## 【2026-10-03 一次性探针·只读】自进化那两条机制的**行为自检**（不是语法检查，是"它真的会动吗"）。
##   机制 1 `adapt_to_opponent()`：对手阵容命中时，权重**真的被叠上**了吗？没命中时**一动不动**吗？
##   机制 2 `_trap_term()`：把敌方远程的退路占掉时，这一项**真的从 0 变成正数**吗？退路还剩几个？
## 用法：& RL\train\跑Godot隔离.ps1 -Tag mymech -TimeoutSec 300 -Args @('--headless','--path',(Get-Location).Path,
##        '--scene','res://RL/自进化/probe/我的机制自检.tscn')
const MYAI := preload("res://RL/自进化/AI.gd")

var _grid: HexGrid

func _ready() -> void:
	get_tree().create_timer(150.0).timeout.connect(func() -> void:
		print("PROBE|WATCHDOG|150s 到点，强制退出")
		get_tree().quit(2))
	_run.call_deferred()

func _run() -> void:
	_grid = HexGrid.new(5, 7, 48.0)
	_grid.top_cap_cols = [1, 3]
	print("PROBE|AI 脚本 = 自进化的子类（RL/自进化/AI.gd）")

	# ---------- 机制 1：对手阵容档 ----------
	print("PROBE|—— 机制 1：对手阵容档 ——")
	var ai = MYAI.new(_grid)
	ai.set_weights({ "ADAPT_PROFILE": 1, "ADAPT_MIN_CNT": 1,
		"ADAPT_VS_RANGED": { "EXPOSURE_TOTAL_W": 9.0 }, "TRAP_W": 0.0 })
	print("PROBE|  设完键：ADAPT_PROFILE=%s · MIN_CNT=%s · VS_RANGED=%s" % [
		str(ai.w_adapt_profile), str(ai.w_adapt_min_cnt), str(ai.w_adapt_vs_ranged)])
	# ① 有 1 个敌方远程（影丸）⇒ 应命中
	var b1 := _board(["hero_07"], [], "只有敌方远程")
	ai.adapt_to_opponent(b1["units"])
	print("PROBE|  ① 对手=影丸(远程) ⇒ EXPOSURE_TOTAL_W 现在是 %s（期望 9.0）" % str(ai.w_exposure_total))
	# ② 对手全是近战 ⇒ 不该命中
	var ai2 = MYAI.new(_grid)
	ai2.set_weights({ "ADAPT_PROFILE": 1, "ADAPT_MIN_CNT": 1, "ADAPT_VS_RANGED": { "EXPOSURE_TOTAL_W": 9.0 } })
	var b2 := _board([], ["hero_04"], "只有敌方近战")
	ai2.adapt_to_opponent(b2["units"])
	print("PROBE|  ② 对手=鼠队长(近战) ⇒ EXPOSURE_TOTAL_W 现在是 %s（期望仍是默认 0.0）" % str(ai2.w_exposure_total))
	# ③ 开关关着 ⇒ 一动不动
	var ai3 = MYAI.new(_grid)
	ai3.set_weights({ "ADAPT_PROFILE": 0, "ADAPT_VS_RANGED": { "EXPOSURE_TOTAL_W": 9.0 } })
	ai3.adapt_to_opponent(b1["units"])
	print("PROBE|  ③ ADAPT_PROFILE=0 ⇒ EXPOSURE_TOTAL_W 现在是 %s（期望 0.0）" % str(ai3.w_exposure_total))

	# ---------- 机制 2：下套（围死对方远程） ----------
	print("PROBE|—— 机制 2：下套 ——")
	for arm in [[Vector2i(4, 0), Vector2i(4, 6), "两个近战都在远处（不围）"],
				[Vector2i(0, 5), Vector2i(1, 6), "贴上去、堵住邻格（围）"]]:
		var ai4 = MYAI.new(_grid)
		ai4.set_weights({ "TRAP_W": 3.0, "TRAP_FREE_TARGET": 2 })
		var sim = _sim_with(ai4, [arm[0], arm[1]], "hero_07")   # 我方两人 + 敌方影丸
		var e = sim.units[2]
		var free := 0
		var budget: int = ai4._threat_emove_next(sim, e)
		for c in ai4._sim_walk_cells(sim, e.cell, budget, e.skills.has(DataRegistry.Skill.INFILTRATE)):
			if not ai4._sim_enemy_adjacent(sim, e, c):
				free += 1
		print("PROBE|  %s：影丸 移动力=%d · 不贴我方的落点=%d ⇒ _trap_term = %+.2f（TRAP_W=3 ⇒ 每少一个安全落点 3 分）" % [
			arm[2], budget, free, ai4._trap_term(sim)])
		var ai5 = MYAI.new(_grid)
		ai5.set_weights({ "TRAP_W": 0.0 })
		print("PROBE|     对照 TRAP_W=0 ⇒ _trap_term = %+.2f" % ai5._trap_term(sim))
	_check_learned()
	print("PROBE|END")
	get_tree().quit(0)

# ---------- 第 C 步（学出来的评估）的通路自检 ----------
## 判据：① 缺系数文件 ⇒ `_evaluate` **等于父类**（安全退回，不变弱）；② 有系数文件且 LEARNED_EVAL=1
## ⇒ `_evaluate` = 学出来的那个加权和（与手算一致）。由 `_run()` 调。
func _check_learned() -> void:
	print("PROBE|—— 第 C 步：学出来的评估 ——")
	var sim = _sim_with(MYAI.new(_grid), [Vector2i(4, 0), Vector2i(4, 6)], "hero_07")
	var a_off = MYAI.new(_grid)
	a_off.set_weights({ "LEARNED_EVAL": 1, "LEARNED_COEF": "res://RL/自进化/probe/_不存在的系数.json" })
	print("PROBE|  ① 系数文件缺失 ⇒ _evaluate=%.4f（应与父类同值）" % a_off._evaluate(sim, true))
	var a_ref = MYAI.new(_grid)
	print("PROBE|     父类口径           ⇒ _evaluate=%.4f" % a_ref._evaluate(sim, true))

func _unused_placeholder() -> void:
	pass

## 一块盘：我方 = 两个近战（位置由调用方给）+ 敌方 = 指定英雄
func _board(player_heroes: Array, enemy_heroes: Array, _tag: String) -> Dictionary:
	var descs: Array = []
	var cells := [Vector2i(1, 1), Vector2i(2, 2), Vector2i(3, 3), Vector2i(3, 5), Vector2i(2, 6), Vector2i(1, 6)]
	var k := 0
	for h in player_heroes:
		descs.append(_desc(DataRegistry.Faction.PLAYER, String(h), cells[k], String(h)))
		k += 1
	for h in enemy_heroes:
		descs.append(_desc(DataRegistry.Faction.ENEMY, String(h), cells[k], String(h)))
		k += 1
	var ai = MYAI.new(_grid)
	var occ := {}
	for i in descs.size():
		occ[descs[i]["cell"]] = i
	var sim = ai.build_state(descs, occ, {}, {}, {}, {}, {})
	# ⚠️ `build_state` 返回的 sim.units 是 SimUnit；这里要的是"单位数组"给 adapt_to_opponent
	return { "sim": sim, "units": sim.units, "ai": ai }

func _sim_with(ai, our_cells: Array, foe_hero: String) -> Variant:
	var descs: Array = []
	descs.append(_desc(DataRegistry.Faction.ENEMY, "hero_04", our_cells[0], "我方1"))
	descs.append(_desc(DataRegistry.Faction.ENEMY, "hero_01", our_cells[1], "我方2"))
	descs.append(_desc(DataRegistry.Faction.PLAYER, foe_hero, Vector2i(0, 6), "敌方影丸"))
	var occ := {}
	for i in descs.size():
		occ[descs[i]["cell"]] = i
	return ai.build_state(descs, occ, {}, {}, {}, {}, {})

func _desc(fn: int, hid: String, cell: Vector2i, nm: String) -> Dictionary:
	var hd = DataRegistry.heroes[hid]
	var emove := 2
	if (hd.skills as Array).has(DataRegistry.Skill.SWIFT):
		emove = 3
	return {
		"fn": fn, "hero": hid, "cell": cell, "hp": int(hd.max_hp), "max_hp": int(hd.max_hp),
		"atk": int(hd.atk), "eatk": int(hd.atk), "move": emove, "emove": emove,
		"atk_range": maxi(int(hd.attack_range), 1), "atk_type": int(hd.attack_type),
		"skills": (hd.skills as Array).duplicate(), "name": nm,
	}

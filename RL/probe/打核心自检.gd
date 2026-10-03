extends Node
## 【2026-10-03 一次性探针·只读】`FOCUS_VALUE_POW`（"**打核心**"）的**行为验收**：
##   固定盘上摆**两个血量完全相同、都没有嘲讽**的敌人，只有"核心度"不同 ⇒ 看 AI 打谁会不会跟着翻。
##   盘面：我方 古拉博士(hero_14，攻4) 站中间；玩家 红帽(hero_40 · 输出潜力 15.4) 与
##         鼠队长(hero_04 · 输出潜力 8.8)，两者 **max_hp/hp 都强制改成 20**（⇒ ④集火 frac² 完全相同、
##         ③血量账 也完全对称）⇒ **唯一的差别就是"核心度"**（身价^0.5 × 输出潜力^0.5）。
##   跑两遍：`-- fvp0`（门关，应复刻现役）与 `-- fvp2`（p=2，应改打核心）。
## ⚠️ 本探针**故意 preload `src/BattleAI.gd` 而不是 fork** —— 因为 fork 正被 v3/v4 两批跑着，
##   中途重建会踩"引擎在跑批期间被改"那个坑。src 与 fork 正文逐字节相同，用它等价。
const AI_SRC := preload("res://src/BattleAI.gd")
const WEIGHTS := "res://RL/weights/噩梦1.json"

var _grid: HexGrid
var _nm: Dictionary = {}
var _pow := 0.0

func _ready() -> void:
	for ua in OS.get_cmdline_user_args():
		var s := String(ua)
		if s.begins_with("fvp"):
			_pow = float(s.substr(3))
	get_tree().create_timer(120.0).timeout.connect(func() -> void:
		print("PROBE|WATCHDOG|120s 到点，强制退出")
		get_tree().quit(2))
	_run.call_deferred()

func _run() -> void:
	_grid = HexGrid.new(5, 7, 48.0)
	_grid.top_cap_cols = [1, 3]
	_nm = _load_json(WEIGHTS)
	var center := Vector2i(2, 4)
	var nbrs: Array = _grid.neighbors(center)
	if nbrs.size() < 2:
		print("PROBE|盘面构造失败：邻居不足")
		get_tree().quit(2)
		return
	var c_core: Vector2i = nbrs[0]     # 核心（红帽）
	var c_weak: Vector2i = nbrs[1]     # 弱（鼠队长）
	var descs: Array = [
		_desc(DataRegistry.Faction.ENEMY, "hero_14", center, "我方古拉博士"),
		_desc(DataRegistry.Faction.PLAYER, "hero_40", c_core, "玩家红帽(核心)", { "hp": 20, "max_hp": 20 }),
		_desc(DataRegistry.Faction.PLAYER, "hero_04", c_weak, "玩家鼠队长(弱)", { "hp": 20, "max_hp": 20 }),
	]
	var occ := {}
	for i in descs.size():
		occ[descs[i]["cell"]] = i
	var ai = AI_SRC.new(_grid)
	ai.difficulty = 3
	ai.log_decisions = false
	ai.set_weights(_nm)
	if _pow > 0.0:
		ai.set_weights({ "FOCUS_VALUE_POW": _pow })
	var sim = ai.build_state(descs, occ, {}, {}, {}, {}, {})

	var core_v: float = ai._core_raw(sim, sim.units[1])
	var weak_v: float = ai._core_raw(sim, sim.units[2])
	var ref: float = ai._foe_core_ref(sim)
	print("PROBE|FOCUS_VALUE_POW=%.1f|核心度 红帽=%.2f · 鼠队长=%.2f · 对面均值=%.2f ⇒ 倍率 红帽=%.2f · 鼠队长=%.2f" % [
		_pow, core_v, weak_v, ref,
		ai._target_core_mult(sim, sim.units[1]), ai._target_core_mult(sim, sim.units[2])])

	var plan: Array = ai.search(sim, DataRegistry.Faction.ENEMY)
	var hit := -1
	for st in plan:
		var a: Dictionary = st["action"]
		if int(a.get("atk", -1)) >= 0:
			hit = int(a["atk"])
	print("PROBE|    搜索的选择：%s" % ("打【核心 红帽】" if hit == 1 else ("打【弱 鼠队长】" if hit == 2 else "没打人（%s）" % str(plan))))
	# 直接对拍：同一手分别打两人，各值多少分
	for ti in [1, 2]:
		var s2 = sim.clone()
		ai._apply(s2, 0, { "move": null, "atk": ti })
		print("PROBE|    原地打 %s ⇒ _evaluate=%+.3f（③血量账 %+.2f · ④集火 %+.2f）" % [
			("红帽(核心)" if ti == 1 else "鼠队长(弱)"), ai._evaluate(s2, true),
			float(ai._eval_breakdown(s2, true)["③血量账"]), float(ai._eval_breakdown(s2, true)["④集火frac²"])])
	print("PROBE|END")
	get_tree().quit(0)

func _desc(fn: int, hid: String, cell: Vector2i, nm: String, over: Dictionary = {}) -> Dictionary:
	var hd = DataRegistry.heroes[hid]
	var emove := 2
	if (hd.skills as Array).has(DataRegistry.Skill.SWIFT):
		emove = 3
	var d := {
		"fn": fn, "hero": hid, "cell": cell, "hp": int(hd.max_hp), "max_hp": int(hd.max_hp),
		"atk": int(hd.atk), "eatk": int(hd.atk), "move": emove, "emove": emove,
		"atk_range": maxi(int(hd.attack_range), 1), "atk_type": int(hd.attack_type),
		"skills": (hd.skills as Array).duplicate(), "name": nm,
	}
	for k in over.keys():
		d[k] = over[k]
	return d

func _load_json(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var d = JSON.parse_string(f.get_as_text())
	f.close()
	return d if d is Dictionary else {}

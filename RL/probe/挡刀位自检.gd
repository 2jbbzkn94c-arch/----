extends Node
## 【2026-10-03 一次性探针·只读】`FORM_SCREEN_W`（**㉜ 坦克挡刀位**）的**尺子验收**：
##   同一块盘面只挪坦克一格，看 `_screen_val()` 会不会跟着变：
##     ① 坦克站在**脆皮与敌人之间**（贴身 + 比脆皮更靠近那个敌人）⇒ 期望 **1.00**
##     ② 坦克站在脆皮**另一侧**（贴身，但不比脆皮更靠近）⇒ 期望 **0.00**
##     ③ 坦克离得远（不贴身）⇒ 期望 **0.00**
##   盘面：我方 红帽(hero_40 · 13 血 · 输出潜力 15.4 ⇒ 进"须保护"门) ＋ 装甲堡垒(hero_48 · 36 血
##   ⇒ 非须保护 = 坦克)；玩家 古拉博士(hero_14) 放在"脆皮往某个方向走 2 步"的位置。
## ⚠️ 本探针**故意 preload `src/BattleAI.gd` 而不是 fork**（fork 正被跑批占着；src 与 fork 正文逐字节相同）。
const AI_SRC := preload("res://src/BattleAI.gd")
const WEIGHTS := "res://RL/weights/噩梦1.json"

var _grid: HexGrid
var _nm: Dictionary = {}

func _ready() -> void:
	get_tree().create_timer(120.0).timeout.connect(func() -> void:
		print("PROBE|WATCHDOG|120s 到点，强制退出")
		get_tree().quit(2))
	_run.call_deferred()

func _run() -> void:
	_grid = HexGrid.new(5, 7, 48.0)
	_grid.top_cap_cols = [1, 3]
	_nm = _load_json(WEIGHTS)
	var c := Vector2i(2, 4)                      # 脆皮站中间
	var nbrs: Array = _grid.neighbors(c)
	if nbrs.size() < 2:
		print("PROBE|盘面构造失败：邻居不足")
		get_tree().quit(2)
		return
	var c_front: Vector2i = nbrs[0]              # 朝敌人那一侧的邻格
	var c_back: Vector2i = nbrs[1]               # 另一侧的邻格
	# 敌人：离脆皮 2 步、且紧贴 c_front（⇒ c_front 正好"挡在中间"）
	var c_foe := Vector2i(-1, -1)
	for x in _grid.all_cells():
		if _grid.distance(c, x) == 2 and _grid.distance(c_front, x) == 1:
			c_foe = x
			break
	if c_foe.x < 0:
		print("PROBE|盘面构造失败：找不到 2 步外的敌人格")
		get_tree().quit(2)
		return
	# 验证 c_back 确实"不更靠近敌人"（若不成立就换一个邻格）
	for nb in nbrs:
		if _grid.distance(nb, c_foe) >= 2 and nb != c_front:
			c_back = nb
			break
	print("PROBE|盘面：脆皮%s · 朝敌邻格%s · 背敌邻格%s（到敌 %d）· 敌人%s（到脆皮 %d）" % [
		str(c), str(c_front), str(c_back), _grid.distance(c_back, c_foe), str(c_foe), _grid.distance(c, c_foe)])

	var far := Vector2i(-1, -1)
	for x in _grid.all_cells():
		if _grid.distance(c, x) >= 3:
			far = x
			break
	for pair in [[c_front, "① 坦克站【脆皮与敌人之间】", 1.0],
			[c_back, "② 坦克站【脆皮另一侧】", 0.0],
			[far, "③ 坦克【离得远】", 0.0]]:
		var tcell: Vector2i = pair[0]
		var ai = AI_SRC.new(_grid)
		ai.difficulty = 3
		ai.log_decisions = false
		ai.set_weights(_nm)
		var descs: Array = [
			_desc(DataRegistry.Faction.ENEMY, "hero_40", c, "我方红帽(须保护)"),
			_desc(DataRegistry.Faction.ENEMY, "hero_48", tcell, "我方装甲堡垒(坦克)"),
			_desc(DataRegistry.Faction.PLAYER, "hero_14", c_foe, "玩家古拉博士"),
		]
		var occ := {}
		for i in descs.size():
			occ[descs[i]["cell"]] = i
		var sim = ai.build_state(descs, occ, {}, {}, {}, {}, {})
		var off: float = ai._screen_val(sim)
		var ev_off: float = ai._evaluate(sim, true)
		ai.set_weights({ "FORM_SCREEN_W": 1.0 })
		var on: float = ai._screen_val(sim)
		var ev_on: float = ai._evaluate(sim, true)
		var verdict := "✓" if (absf(off - float(pair[2])) < 1e-9 and absf(on - float(pair[2])) < 1e-9) else "✗ 与期望不符"
		# 接线检查：门开 − 门关 的**总分差**必须正好等于这一项（同一块盘面 ⇒ 其它项一分不变）
		var wired := "✓ 接线正确" if absf((ev_on - ev_off) - float(pair[2])) < 1e-6 else "✗ 接线不对（总分只差 %+.3f）" % (ev_on - ev_off)
		print("PROBE|%-22s 坦克%s ⇒ _screen_val：%.2f（期望 %.2f）%s · _evaluate 门关=%+.3f → 门开=%+.3f · %s" % [
			pair[1], str(tcell), on, float(pair[2]), verdict, ev_off, ev_on, wired])
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

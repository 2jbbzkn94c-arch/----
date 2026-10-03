extends Node
## 【2026-10-03 一次性探针·只读】验证我的"记录模式"**真的写出样本**（跑一次 search 就把文件读回来）。
## 判据：文件存在、行数 ≥ 1、每行含 seed/first/aside/is_cand/terms/score，且 terms 里项数 ≥ 10。
const MYAI := preload("res://RL/自进化/AI.gd")
const PREFIX := "/tmp/rec_probe"     # 会被替换成绝对路径
var _grid: HexGrid

func _ready() -> void:
	get_tree().create_timer(200.0).timeout.connect(func() -> void:
		print("PROBE|WATCHDOG|200s 到点，强制退出")
		get_tree().quit(2))
	_run.call_deferred()

func _run() -> void:
	_grid = HexGrid.new(5, 7, 48.0)
	_grid.top_cap_cols = [1, 3]
	var base := OS.get_environment("DSH_EVO_REC")
	if base == "":
		base = OS.get_user_data_dir().path_join("rec_probe")
	print("PROBE|记录前缀 = %s" % base)
	var f0 := "%s.%d.jsonl" % [base, OS.get_process_id()]
	if FileAccess.file_exists(f0):
		DirAccess.remove_absolute(f0)

	var ai = MYAI.new(_grid)
	ai.set_weights({ "RECORD_PATH": base })
	ai.set_game_tag(10001, 0, 1, int(DataRegistry.Faction.ENEMY))   # seed=10001 first=p aside=1(E) myfn=E ⇒ is_cand=true
	var descs: Array = [
		_desc(DataRegistry.Faction.ENEMY, "hero_04", Vector2i(2, 3), "我方鼠队长"),
		_desc(DataRegistry.Faction.ENEMY, "hero_01", Vector2i(2, 4), "我方伐木工"),
		_desc(DataRegistry.Faction.PLAYER, "hero_07", Vector2i(2, 0), "敌方影丸"),
	]
	var occ := {}
	for i in descs.size():
		occ[descs[i]["cell"]] = i
	var sim = ai.build_state(descs, occ, {}, {}, {}, {}, {})
	print("PROBE|RECORD_PATH 生效? %s（空 = 没吃进去）" % ("是" if ai.w_record_path != "" else "否"))
	var plan: Array = ai.search(sim, DataRegistry.Faction.ENEMY)
	print("PROBE|search() 返回 %d 步" % plan.size())
	print("PROBE|记录文件存在? %s" % str(FileAccess.file_exists(f0)))
	if FileAccess.file_exists(f0):
		var txt := FileAccess.get_file_as_string(f0)
		var lines := txt.strip_edges().split("\n")
		print("PROBE|行数 = %d" % lines.size())
		var d = JSON.parse_string(lines[0])
		if d is Dictionary:
			var terms: Dictionary = d.get("terms", {})
			print("PROBE|首行：seed=%s first=%s aside=%s is_cand=%s steps=%s score=%.2f my_alive=%s foe_alive=%s terms项数=%d" % [
				str(d.get("seed")), str(d.get("first")), str(d.get("aside")), str(d.get("is_cand")),
				str(d.get("steps")), float(d.get("score", 0.0)), str(d.get("my_alive")), str(d.get("foe_alive")), terms.size()])
			var ks := terms.keys()
			ks.sort()
			print("PROBE|terms 前 6 项：%s" % str(ks.slice(0, 6)))
	print("PROBE|END")
	get_tree().quit(0)

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

extends Node
## 【2026-10-02 一次性探针·只读】`FORM_ROLE_GATE`（⑳/㉓ 按身份分档）的**全英雄验收**：
##   逐英雄打印「血上限 / 是不是后勤 / 输出潜力 / 进不进 ㉖ 门 / 分档系数」，
##   回答用户口径「后勤也需要被保护啊，你自己看看后勤都是些什么英雄」。
## 判据：① 后勤 3 个（烛火/末日/涌电技师）必须 = **1.0**；② 脆皮输出（红帽/影丸/风语者/古拉博士/沉默术士）= 1.0；
##   ③ 能自己打的战士/坦克（伐木工 27 血 / 装甲堡垒 36 血 …）= **0.25**。
## 用法：`—Args @('--headless','--path',…,'--scene','res://RL/probe/队形身份分档自检.tscn')`（可加 `-- role`）
const FORK := preload("res://RL/ai/AI_Battle.gd")
const WEIGHTS := "res://RL/weights/噩梦1.json"

var _grid: HexGrid
var _nm: Dictionary = {}
var _role_on := true      # 默认就打开门（本探针就是验它的）

func _ready() -> void:
	for ua in OS.get_cmdline_user_args():
		if String(ua) == "off":
			_role_on = false
	get_tree().create_timer(120.0).timeout.connect(func() -> void:
		print("PROBE|WATCHDOG|120s 到点，强制退出")
		get_tree().quit(2))
	_run.call_deferred()

func _run() -> void:
	_grid = HexGrid.new(5, 7, 48.0)
	_grid.top_cap_cols = [1, 3]
	_nm = _load_json(WEIGHTS)
	var ai = FORK.new(_grid)
	ai.difficulty = 3
	ai.set_weights(_nm)
	if _role_on:
		ai.set_weights({ "FORM_ROLE_GATE": 1 })
	print("PROBE|门=%s · EXPOSURE_HP_MAX=%s · 输出门=%s" % [
		str(_role_on), str(_nm.get("EXPOSURE_HP_MAX", "-")), str(ai.EXPOSURE_OUT_MIN)])

	var ids: Array = DataRegistry.heroes.keys()
	ids.sort()
	var rows: Array = []
	for hid in ids:
		var h: String = String(hid)
		if DataRegistry.summons.has(h):
			continue
		var descs: Array = [_desc(DataRegistry.Faction.ENEMY, h, Vector2i(2, 3), h)]
		var occ := { Vector2i(2, 3): 0 }
		var sim = ai.build_state(descs, occ, {}, {}, {}, {}, {})
		var u = sim.units[0]
		rows.append({
			"id": h, "hp": int(u.max_hp), "logi": bool(u.skills.has(DataRegistry.Skill.LOGISTICS)),
			"pot": ai._output_potential(h), "cov": bool(ai._exposure_covered(u)),
			"mult": ai._form_role_mult(u),
		})
	# 打印：先后勤、再脆皮输出、再其余
	rows.sort_custom(func(a, b):
		var ka := 0 if a["logi"] else (1 if a["cov"] else 2)
		var kb := 0 if b["logi"] else (1 if b["cov"] else 2)
		if ka != kb: return ka < kb
		return a["hp"] < b["hp"])
	print("PROBE|%-8s %5s %5s %8s %7s %6s  %s" % ["英雄", "血上限", "后勤", "输出潜力", "进㉖门", "系数", "分组"])
	for r in rows:
		var grp := "后勤（须保护）" if r["logi"] else ("脆皮输出（须保护）" if r["cov"] else "能自己打 ⇒ 0.25 档")
		print("PROBE|%-8s %5d %5s %8.1f %7s %6.2f  %s" % [
			r["id"], r["hp"], str(r["logi"]), r["pot"], str(r["cov"]), r["mult"], grp])
	var prot := 0
	for r in rows:
		if r["mult"] >= 1.0:
			prot += 1
	print("PROBE|小结|共 %d 个英雄：受保护（全价）%d 个 · 0.25 档 %d 个" % [rows.size(), prot, rows.size() - prot])
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

func _load_json(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var d = JSON.parse_string(f.get_as_text())
	f.close()
	return d if d is Dictionary else {}

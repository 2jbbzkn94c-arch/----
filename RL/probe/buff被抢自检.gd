extends Node
## 【2026-09-28 一次性探针】㉙「buff 被抢」（`BUFF_DENY_W`）行为自检 —— 跑完即退，**不改任何生产代码**。
##
## 用户报：「现在 AI 有个问题，总喜欢站到 buff 旁边，让玩家吃 buff，还能给 AI 一下」⇒ 拍板 A 案：
##   本回合**够得到却没去吃**、而对面**下回合够得到** ⇒ 按道具价值扣分（=「要么现在吃掉、要么别停在它旁边」）。
##
## 盘面 A：AI 一名近战 (1,1)、玩家一名 (3,1)，中间 (1,3) 放一枚**攻击道具** —— 双方都够得到
##   （AI emove=2：(1,1)→(2,2)→(1,3)；玩家 emove=2：(3,1)→(2,2)→(1,3)）。
## 盘面 B：把道具放到**只有玩家够得到**的地方（AI 够不到）⇒ 本项应当**一分都不罚**（不是"能吃却没吃"）。
## 盘面 C：道具**归属玩家**（圣诞老人的礼物那种）⇒ 踩上去只是踩掉 ⇒ 也不算被抢，不罚。
## 每臂（0 / 1.0 / 2.0）跑一次 `search()`，量：
##   · `deny0` = 起始局面的 `_buff_deny()`（"被抢价值"合计，正数）
##   · `bd29`  = 末态 `_eval_breakdown(end, true)` 里的 ㉙ 项（负分）
##   · `ate`   = 末态道具还在不在（`buff_cells.has(cell)`：false = AI 吃掉了）
##   · `standing` = 末态有没有 AI 单位**贴着**那枚道具（相邻）—— 就是用户看到的那件事
##   · `score` = `_evaluate(end, true)`
##
## 用法：& RL\train\跑Godot隔离.ps1 -Tag buffdeny -TimeoutSec 600 -Args @('--headless','--path',(Get-Location).Path,'--scene','res://RL/probe/buff被抢自检.tscn')
## 输出：每行 `PROBE|...`，末尾 `PROBE|END`。

const AI := preload("res://src/BattleAI.gd")
const ARMS := [0.0, 1.0, 2.0]

var _grid: HexGrid
var _nm: Dictionary = {}

func _ready() -> void:
	_grid = HexGrid.new(5, 7, 48.0)
	_grid.top_cap_cols = [1, 3]
	_run.call_deferred()

func _run() -> void:
	_nm = _load_json("res://RL/weights/噩梦.json")
	print("PROBE|CFG|src_sha=%s|flat_BUFF_DENY_W=%s|flat_BUFF_TAKE_WEIGHT=%s|HEAL_CREDIT_W=%s" % [
		_sha("res://src/BattleAI.gd"), str(_nm.get("BUFF_DENY_W", -1)),
		str(_nm.get("BUFF_TAKE_WEIGHT", -1)), str(_nm.get("HEAL_CREDIT_W", -1))])
	_case("A_双方都够得到", Vector2i(2, 2), true, -1)
	_case("B_只有玩家够得到", Vector2i(4, 2), true, -1)
	_case("C_归属玩家", Vector2i(2, 2), true, DataRegistry.Faction.PLAYER)
	# D：AI 站在玩家**贴身**处（有"打一下"这个诱人选项），道具在旁边 ⇒ 看它选打还是选吃
	_case("D_贴身且旁边有道具", Vector2i(2, 2), true, -1, Vector2i(2, 3), Vector2i(2, 4))
	print("PROBE|END")
	get_tree().quit(0)

func _case(tag: String, buff_cell: Vector2i, ai_can: bool, owner: int,
		ai_cell: Vector2i = Vector2i(1, 1), foe_cell: Vector2i = Vector2i(3, 1)) -> void:
	var descs: Array = []
	descs.append(_desc(DataRegistry.Faction.ENEMY, "hero_12", ai_cell, "AI近战"))
	descs.append(_desc(DataRegistry.Faction.PLAYER, "hero_12", foe_cell, "玩家近战"))
	var occ := {}
	for i in descs.size():
		occ[descs[i]["cell"]] = i
	var buffs := { buff_cell: "atk" }
	var owners := {}
	if owner >= 0:
		owners[buff_cell] = owner
	var ai = AI.new(_grid)
	ai.difficulty = 3
	ai.log_decisions = false
	ai.time_budget_ms = 20000
	ai.set_weights(_nm)
	var root = ai.build_state(descs, occ, {}, {}, {}, {}, buffs, -1, {}, {}, owners)
	var d0: float = ai._buff_deny(root)
	print("PROBE|POS|%s|buff=%s|owner=%d|ai_reach=%d(emove0=%d)|foe_reach=%d(emove=%d)|deny0=%.2f" % [
		tag, str(buff_cell), owner,
		int(ai.walk_dist(root, root.units[0].cell0, buff_cell)), int(root.units[0].emove0),
		int(ai.walk_dist(root, root.units[1].cell, buff_cell)), int(root.units[1].emove), d0])
	for w in ARMS:
		ai.set_weights({ "BUFF_DENY_W": float(w) })
		var s = root.clone()
		var t0 := Time.get_ticks_msec()
		var plan: Array = ai.search(s, DataRegistry.Faction.ENEMY)
		var ms := Time.get_ticks_msec() - t0
		var end = root.clone()
		for st in plan:
			ai._apply(end, int(st["idx"]), st["action"])
		var bd: Dictionary = ai._eval_breakdown(end, true)
		var ate: bool = not end.buff_cells.has(buff_cell)
		var standing := false
		for u in end.units:
			if u != null and u.alive and u.fn == DataRegistry.Faction.ENEMY and u.cell in _grid.neighbors(buff_cell):
				standing = true
		print("PROBE|ARM|%s|w=%.1f|deny_end=%.2f|bd29=%.2f|ate=%s|standing=%s|score=%.2f|steps=%d|ms=%d|plan=%s" % [
			tag, float(w), ai._buff_deny(end), float(bd.get("㉙buff被抢", 0.0)), str(ate), str(standing),
			ai._evaluate(end, true), plan.size(), ms, _plan_txt(root, plan)])

func _plan_txt(root, plan: Array) -> String:
	var txt := ""
	for st in plan:
		var act: Dictionary = st["action"]
		var mv: Variant = act.get("move")
		txt += "%s[->%s,atk=%d] " % [String(root.units[int(st["idx"])].name),
			("原地" if mv == null else str(mv)), int(act.get("atk", -1))]
	return txt

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

func _sha(path: String) -> String:
	var c := FileAccess.get_file_as_bytes(path)
	var h := HashingContext.new()
	h.start(HashingContext.HASH_SHA256)
	h.update(c)
	return h.finish().hex_encode().substr(0, 12)

extends Node
## 队形合并自检（⑳ + ㉓ 并成"一把尺"、㉑ 退役）—— **2026-09-22 晚·用户点名**（一次性探针，跑完即退）。
##
## 要证明两件事：
##   ① **数值等价**：`FORM_MERGE_MODE = 1` 时，㉓ 那一项的值 == 现役的 `⑳ + ㉓` 之和（逐局面误差 < 1e-6）
##      ⇒ 合并**没有偷偷改曲线**，跑批的差异只可能来自"㉑ 退路/被夹 退役"。
##   ② **㉑ 的影响面**：同一局面 mode0 vs mode1 的 `search()` 出招差多少（应该只由 ㉑ 引起）。
##
## 运行：
##   & RL\train\跑Godot隔离.ps1 -Tag fm -TimeoutSec 600 -Args @('--headless','--path',(Get-Location).Path,'--scene','res://RL/probe/队形合并自检.tscn','--','60')

const FORK := preload("res://RL/ai/AI_Battle.gd")
const NIGHTMARE_PATH := "res://RL/weights/噩梦.json"

var _grid: HexGrid

func _ready() -> void:
	_grid = HexGrid.new()
	_grid.width = 6
	_grid.height = 5
	_run.call_deferred()

func _run() -> void:
	var ua := OS.get_cmdline_user_args()
	var beam := int(ua[0]) if ua.size() > 0 else 60
	var w := _load_flat_weights(NIGHTMARE_PATH)
	w["BEAM"] = beam
	var w_merge := w.duplicate()
	w_merge["FORM_MERGE_MODE"] = 1
	var coh_w := float(w.get("FORM_COHESION_W", 0.0))
	var spr_w := float(w.get("FORM_SPREAD_CELL_W", 0.0))
	var esc_w := float(w.get("FORM_ESCAPE_W", 0.0))
	print("FM|CFG|positions=%d|beam=%d|board=%dx%d|fork_sha=%s|w_sha=%s|coh=%.2f|spread=%.2f|esc=%.2f|iso_ratio=%.4f" % [
		_positions().size(), beam, _grid.width, _grid.height,
		_sha("res://RL/ai/AI_Battle.gd"), _sha(NIGHTMARE_PATH), coh_w, spr_w, esc_w, FORM_RATIO])

	var n_eq := 0
	var n_plan := 0
	var n_first := 0
	var total := 0
	var worst := 0.0
	for pos in _positions():
		total += 1
		var nm := String(pos["name"])
		var ai0 = _mk_ai(w)
		var ai1 = _mk_ai(w_merge)
		var s0 = _sim(ai0, pos)
		var s1 = _sim(ai1, pos)
		var p0: Vector3 = ai0._formation_parts(s0)
		var p1: Vector3 = ai1._formation_parts(s1)
		# ① 数值等价：mode0 的 ⑳+㉓ 分值 vs mode1 的 ㉓ 分值
		var v0 := coh_w * p0.x + spr_w * p0.z
		var v1 := spr_w * p1.z
		var dv := absf(v0 - v1)
		if dv > worst:
			worst = dv
		if dv <= 1.0e-6:
			n_eq += 1
		print("FM|PARTS|%s|coh0=%.3f|esc0=%.3f|spr0=%.3f|z1=%.4f|v0(⑳+㉓)=%.4f|v1(㉓合并)=%.4f|Δ=%.6f|%s" % [
			nm, p0.x, p0.y, p0.z, p1.z, v0, v1, dv, ("等价" if dv <= 1.0e-6 else "**不等价**")])
		# ② 出招差（应只由 ㉑ 引起）
		var r0 := _one(ai0, pos)
		var r1 := _one(ai1, pos)
		var dplan: bool = String(r0["fp"]) != String(r1["fp"])
		var dfirst: bool = String(r0["firstfp"]) != String(r1["firstfp"])
		if dplan:
			n_plan += 1
		if dfirst:
			n_first += 1
		print("FM|PLAN|%s|esc0=%.3f|esc罚(现役)=%.3f|plan=%s|first=%s|steps0=%d|steps1=%d" % [
			nm, p0.y, (esc_w * p0.y), ("变" if dplan else "同"), ("变" if dfirst else "同"),
			int(r0["steps"]), int(r1["steps"])])
		if dplan:
			print("FM|DIFF|%s|mode0=%s||mode1=%s" % [nm, String(r0["fp"]), String(r1["fp"])])
	print("FM|SUM|positions=%d|等价=%d|最大Δ=%.6f|出招变=%d|第一步变=%d" % [total, n_eq, worst, n_plan, n_first])
	print("FM|READ|等价=全部 且 出招变>0 ⇒ 合并忠实，差异只来自「㉑ 退路/被夹 退役」")
	print("FM|END")
	get_tree().quit(0)

const FORM_RATIO := 5.0 / 3.0

func _mk_ai(inject: Dictionary):
	var ai = FORK.new(_grid)
	ai.difficulty = 2
	ai.log_decisions = false
	ai.time_budget_ms = 0
	ai.set_weights(inject)
	return ai

func _sim(ai, pos: Dictionary):
	return ai.build_state(pos["descs"], pos.get("occ", {}), pos.get("gold", {}),
		pos.get("graves", {}), pos.get("obs", {}), pos.get("bombs", {}), pos.get("buff", {}))

func _one(ai, pos: Dictionary) -> Dictionary:
	var sim = _sim(ai, pos)
	var plan: Array = ai.search(sim, DataRegistry.Faction.ENEMY)
	var parts: Array = []
	for s in plan:
		var a: Dictionary = s.get("action", {})
		parts.append("%d:%s:%d:%s" % [
			int(s.get("idx", -1)), str(a.get("move", null)),
			int(a.get("atk", -99)), str(a.get("atk_obs", null))])
	return {
		"steps": plan.size(),
		"fp": ">".join(parts),
		"firstfp": String(parts[0]) if parts.size() > 0 else "",
	}

func _load_flat_weights(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var d = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(d) != TYPE_DICTIONARY:
		return {}
	var out: Dictionary = {}
	for k in (d as Dictionary).keys():
		if String(k).begins_with("_"):
			continue
		out[String(k)] = (d as Dictionary)[k]
	return out

func _sha(path: String) -> String:
	if not FileAccess.file_exists(path):
		return "?"
	var ctx := HashingContext.new()
	if ctx.start(HashingContext.HASH_SHA256) != OK:
		return "?"
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return "?"
	ctx.update(f.get_buffer(f.get_length()))
	f.close()
	return ctx.finish().hex_encode().substr(0, 12)

func _u(fn: int, hero: String, cell: Vector2i, hp: int, max_hp: int, atk: int, mv: int,
		rng: int, typ: int, skills: Array, nm: String) -> Dictionary:
	return {
		"fn": fn, "hero": hero, "cell": cell, "hp": hp, "max_hp": max_hp,
		"atk": atk, "eatk": atk, "move": mv, "emove": mv,
		"atk_range": rng, "atk_type": typ, "skills": skills, "name": nm,
	}

## 局面集：① 掉单（格距 3~5，考验梯度）② 贴在一起（都不罚）③ 隔墙（⑳ 的 0/1 份）
##   ④ 孤立 + 被夹（㉑ 该发力）⑤ 贴墙/死胡同（㉑ 该发力）
func _positions() -> Array:
	var E := DataRegistry.Faction.ENEMY
	var P := DataRegistry.Faction.PLAYER
	var MELEE := int(DataRegistry.AttackType.MELEE)
	var out: Array = []

	# ① 掉单：我方 A 在 (0,0)，队友在 (5,4) ⇒ 格距很远（梯度该罚 4 份）
	out.append({ "name": "①掉单", "descs": [
		_u(E, "hero_25", Vector2i(0, 0), 40, 40, 10, 3, 1, MELEE, [], "我方掉单"),
		_u(E, "hero_13", Vector2i(5, 4), 45, 45, 3, 3, 1, MELEE, [], "我方队友"),
		_u(P, "hero_23", Vector2i(3, 2), 20, 20, 5, 2, 1, MELEE, [], "敌嘲讽"),
	] })

	# ② 贴在一起：三个单位相邻 ⇒ ⑳㉓ 都不罚
	out.append({ "name": "②贴身", "descs": [
		_u(E, "hero_25", Vector2i(2, 2), 40, 40, 10, 3, 1, MELEE, [], "我方A"),
		_u(E, "hero_13", Vector2i(2, 3), 45, 45, 3, 3, 1, MELEE, [], "我方B"),
		_u(E, "hero_37", Vector2i(3, 2), 30, 30, 5, 2, 2, int(DataRegistry.AttackType.RANGED), [], "我方C"),
		_u(P, "hero_23", Vector2i(5, 2), 20, 20, 5, 2, 1, MELEE, [], "敌嘲讽"),
	] })

	# ③ 隔墙：两名队友恰好格距 2、中间格是障碍 ⇒ ⑳ 判"不算抱团"（模式 1 的台阶要照样触发）
	out.append({ "name": "③隔墙", "descs": [
		_u(E, "hero_25", Vector2i(1, 2), 40, 40, 10, 3, 1, MELEE, [], "我方A"),
		_u(E, "hero_13", Vector2i(3, 2), 45, 45, 3, 3, 1, MELEE, [], "我方B"),
		_u(P, "hero_23", Vector2i(5, 4), 20, 20, 5, 2, 1, MELEE, [], "敌嘲讽"),
	], "obs": { Vector2i(2, 2): 3 } })

	# ④ 孤立 + 相邻敌比队友多（㉑ 的"被夹"那一半该发力）
	out.append({ "name": "④被夹", "descs": [
		_u(E, "hero_25", Vector2i(2, 2), 40, 40, 10, 3, 1, MELEE, [], "我方被夹"),
		_u(E, "hero_13", Vector2i(0, 4), 45, 45, 3, 3, 1, MELEE, [], "我方远队友"),
		_u(P, "hero_23", Vector2i(3, 2), 20, 20, 5, 2, 1, MELEE, [], "敌A"),
		_u(P, "hero_26", Vector2i(1, 2), 20, 20, 5, 2, 1, MELEE, [], "敌B"),
		_u(P, "hero_31", Vector2i(2, 1), 18, 18, 4, 2, 2, int(DataRegistry.AttackType.RANGED), [], "敌C"),
	] })

	# ⑤ 贴墙 + 死胡同（㉑ 的"退路"那一半该发力）
	out.append({ "name": "⑤贴墙角", "descs": [
		_u(E, "hero_25", Vector2i(0, 0), 40, 40, 10, 3, 1, MELEE, [], "我方贴角"),
		_u(E, "hero_13", Vector2i(2, 2), 45, 45, 3, 3, 1, MELEE, [], "我方队友"),
		_u(P, "hero_23", Vector2i(4, 4), 20, 20, 5, 2, 1, MELEE, [], "敌嘲讽"),
	], "obs": { Vector2i(0, 1): 3, Vector2i(1, 0): 3, Vector2i(1, 1): 3 } })
	return out

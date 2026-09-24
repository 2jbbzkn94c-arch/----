extends Node
## 【2026-09-24 一次性探针】⑥规则B 的**门**（`Sim.engaged0`）到底开不开 —— 跑完即退，只读。
##
## 起因（bt29 剂量批的读数）：`难度体检 -Mode bpool`（镜像噩梦 · `MOVE_ACCEPT_POOL` bp0=0 / bp1=1，
## 4 组牌 × 4 种子 × 2 先后手）两臂**逐格完全一致** —— bp0/bp1 都是 8-8、`pts_sd` 到小数第二位相同。
## 剂量批里"没差别"只有两种可能：(a) 旋钮没接线（已查：注入文件 bp0=0 / bp1=1 正确、fork 里
## `_rule_b_score()` 的分支在）；(b) ⑥ 整项**根本没参与评分**。本探针查 (b)：
##   `_accept_threshold()` 读 `sim.engaged0`（**本回合行动前**的快照）⇒ 已交战就返回 0 ⇒ ⑥ 恒 0。
##   而 `RL/harness/对局.gd` 的固定部署是 P=(1,4)(3,4)(1,5) / E=(1,2)(3,2)(1,1) ⇒ **只隔 2 行**，
##   而"交战"的判据是 `_threat_can_hit()` = **射程＋移动力**（近战 = 1+2 = 3）⇒ 一行都不走就已经在圈里。
##
## 三问（全部只读、不写盘）：
##   A 标准部署下开局：`engaged0` / 阈值 / ⑥ 两臂分值 / 我方各单位挨打合计 = ?
##   B 把两侧拉开到**门开着**：⑥ 的 knob0 vs knob1 分值差多少、出招指纹变不变（验这条线是通的）
##   C 拉开到多远门才开（扫间距）⇒ 这张 5×7 棋盘上 ⑥ 的有效窗口有多窄
##
## 判读：
##   · A 全是 `engaged0=true` ⇒ **镜像/对局协议量不到 ⑥**（旋转钮 = 白转），bt29 的"两臂一致"是**协议地板**；
##   · B 里 knob0≠knob1 或出招变 ⇒ 线是通的，只是标准部署踩不到；
##   · C 里"门开"的最小间距 ≥ 双方首回合移动力之和 ⇒ 实战里 ⑥ 只在**开局第一两回合**可能生效。
##
## 用法：
##   & RL\train\跑Godot隔离.ps1 -Tag gate -TimeoutSec 900 -Args @('--headless','--path',(Get-Location).Path,'--scene','res://RL/probe/开局交战门自检.tscn')

const FORK := preload("res://RL/ai/AI_Battle.gd")
const BASE := "res://RL/weights/噩梦_基线.json"
const BEAM := 200                      # 与镜像批同口径（harness 把两侧都设成 200）
## 镜像批用的标准 4 组（`-Decks`）
const DECKS: Array = [
	["hero_42", "hero_03", "hero_17"],
	["hero_13", "hero_12", "hero_18"],
	["hero_24", "hero_09", "hero_20"],
	["hero_46", "hero_11", "hero_27"],
]
## `RL/harness/对局.gd` 的固定部署（一字不改抄过来）
const E_CELLS: Array = [Vector2i(1, 2), Vector2i(3, 2), Vector2i(1, 1)]
const P_CELLS: Array = [Vector2i(1, 4), Vector2i(3, 4), Vector2i(1, 5)]

var _grid: HexGrid
var _w0: Dictionary = {}
var _w1: Dictionary = {}

func _ready() -> void:
	_grid = HexGrid.new(5, 7, 48.0)
	_grid.top_cap_cols = [1, 3]
	_run.call_deferred()

func _run() -> void:
	var w := _flat(BASE)
	_w0 = w.duplicate()
	_w0["MOVE_ACCEPT_POOL"] = 0
	_w1 = w.duplicate()
	_w1["MOVE_ACCEPT_POOL"] = 1
	print("GT|CFG|fork=%s|base=%s|beam=%d|decks=%d|E=%s|P=%s|w_MOVE_ACCEPT_DAMAGE=%s|w_INCOMING_POOL_W=%s" % [
		_sha("res://RL/ai/AI_Battle.gd"), _sha(BASE), BEAM, DECKS.size(),
		str(E_CELLS), str(P_CELLS), str(w.get("MOVE_ACCEPT_DAMAGE", "缺")), str(w.get("INCOMING_POOL_W", "缺"))])
	var n_a_gate := 0
	var n_c_open := 0
	var n_c_total := 0
	var n_b_diff_rb := 0
	var n_b_diff_plan := 0
	for d in DECKS:
		var deck: Array = d
		# ---------------- A) 标准部署 ----------------
		var a := _probe(String(deck[0]), deck, E_CELLS, P_CELLS)
		print("GT|A|deck=%s|cells=P%s|engaged0=%s|gate=%s|thr=%.0f|rb_k0=%.2f|rb_k1=%.2f|inc=%s" % [
			"-".join(deck), str(P_CELLS), str(bool(a["engaged"])), ("开" if not bool(a["engaged"]) else "关"),
			float(a["thr"]), float(a["rb0"]), float(a["rb1"]), String(a["inc_txt"])])
		if not bool(a["engaged"]):
			n_a_gate += 1
		# ---------------- Z) 真实出生区（`Battle.gd`：敌方 = 顶帽(1,0)(3,0) + 皇冠行 (2,1)；我方 = 底行 row6）----------------
		var zc: Array = [Vector2i(0, 6), Vector2i(2, 6), Vector2i(4, 6)]
		var zec: Array = [Vector2i(1, 0), Vector2i(3, 0), Vector2i(2, 1)]
		var z := _probe(String(deck[0]), deck, zec, zc)
		print("GT|Z|deck=%s|E=%s|P=%s|engaged0=%s|thr=%.0f|rb_k0=%.2f|rb_k1=%.2f|inc=%s" % [
			"-".join(deck), str(zec), str(zc), str(bool(z["engaged"])), float(z["thr"]),
			float(z["rb0"]), float(z["rb1"]), String(z["inc_txt"])])
		# ---------------- D) **人工把门掰开**（`sim.engaged0 = false`）：量"若门开着，⑥ 会罚多少、两臂差多少、出招变不变"
		var f := _probe(String(deck[0]), deck, E_CELLS, P_CELLS, true)
		var d_rb := absf(float(f["rb1"]) - float(f["rb0"])) > 0.001
		var pl0 := _plan(f["descs"], _w0, true)
		var pl1 := _plan(f["descs"], _w1, true)
		var d_plan: bool = String(pl0["fp"]) != String(pl1["fp"])
		if d_rb:
			n_b_diff_rb += 1
		if d_plan:
			n_b_diff_plan += 1
		print("GT|D|deck=%s|掰开门|thr=%.0f|rb_k0=%.2f|rb_k1=%.2f|rb_差=%s|steps=%d/%d|出招=%s|inc=%s" % [
			"-".join(deck), float(f["thr"]), float(f["rb0"]), float(f["rb1"]),
			("变" if d_rb else "同"), int(pl0["steps"]), int(pl1["steps"]), ("变" if d_plan else "同"),
			String(f["inc_txt"])])
		print("GT|DPLAN|deck=%s|k0=%s" % ["-".join(deck), String(pl0["fp"])])
		print("GT|DPLAN|deck=%s|k1=%s" % ["-".join(deck), String(pl1["fp"])])
		# ---------------- C) 扫间距：把玩家侧整排往下推（三格列各不相同，不许重叠）----------------
		var first_open := {}
		for g in [0, 1, 2]:
			var pc: Array = [Vector2i(1, 4 + g), Vector2i(3, 4 + g), Vector2i(2, 5 + g)]
			var r := _probe(String(deck[0]), deck, E_CELLS, pc)
			n_c_total += 1
			if not bool(r["engaged"]):
				n_c_open += 1
				if first_open.is_empty():
					first_open = r
			print("GT|C|deck=%s|shift=+%d|P=%s|engaged0=%s|thr=%.0f|rb_k0=%.2f|rb_k1=%.2f|inc=%s" % [
				"-".join(deck), g, str(pc), str(bool(r["engaged"])), float(r["thr"]),
				float(r["rb0"]), float(r["rb1"]), String(r["inc_txt"])])
		# ---------------- B) 门开着的那一档（如果扫到了）：两臂真出手 ----------------
		if first_open.is_empty():
			pass
		else:
			var p0 := _plan(first_open["descs"], _w0)
			var p1 := _plan(first_open["descs"], _w1)
			var d_rb2: bool = absf(float(first_open["rb1"]) - float(first_open["rb0"])) > 0.001
			var d_plan2: bool = String(p0["fp"]) != String(p1["fp"])
			if d_rb2:
				n_b_diff_rb += 1
			if d_plan2:
				n_b_diff_plan += 1
			print("GT|B|deck=%s|P=%s|rb_k0=%.2f|rb_k1=%.2f|rb_差=%s|steps_k0=%d|steps_k1=%d|出招=%s" % [
				"-".join(deck), str(first_open["cells"]), float(first_open["rb0"]), float(first_open["rb1"]),
				("变" if d_rb2 else "同"), int(p0["steps"]), int(p1["steps"]), ("变" if d_plan2 else "同")])
			print("GT|BPLAN|deck=%s|k0=%s" % ["-".join(deck), String(p0["fp"])])
			print("GT|BPLAN|deck=%s|k1=%s" % ["-".join(deck), String(p1["fp"])])
	print("GT|SUM|decks=%d|A_门开=%d|C_门开=%d/%d|B_⑥分值变=%d|B_出招变=%d" % [
		DECKS.size(), n_a_gate, n_c_open, n_c_total, n_b_diff_rb, n_b_diff_plan])
	print("GT|READ|判读：A 全 engaged0=true ⇒ 标准部署下 ⑥ 恒不生效（镜像批量不到它）")
	print("GT|END")
	get_tree().quit(0)

## 建局 + 只读诊断：门 / 阈值 / 两臂 ⑥ 分值 / 各单位挨打合计（当前格 + 全部候选落点里最大）
## `force_open` = **人工把门掰开**（把 `sim.engaged0` 覆写成 false，只为量"若门开着会怎样"，不改生产）
func _probe(_tag: String, deck: Array, ecells: Array, pcells: Array, force_open: bool = false) -> Dictionary:
	var descs := _descs(deck, ecells, pcells)
	var ai = _mk(_w0)
	var sim = ai.build_state(descs, _occ(descs), {}, {}, {}, {}, {})
	var ai1 = _mk(_w1)
	var sim1 = ai1.build_state(descs, _occ(descs), {}, {}, {}, {}, {})
	if force_open:
		sim.engaged0 = false
		sim1.engaged0 = false
	var incs: Array = []
	for i in sim.units.size():
		var u = sim.units[i]
		if u == null or not u.alive or u.fn != DataRegistry.Faction.ENEMY:
			continue
		var cur := float(ai._incoming_total_on(sim, u, u.cell))
		var hi := cur
		var hi_cell: Vector2i = u.cell
		for combo in ai._actions_for(sim, i):
			var mc: Vector2i = u.cell
			if combo.get("move") != null:
				mc = combo["move"]
			var v := float(ai._incoming_total_on(sim, u, mc))
			if v > hi:
				hi = v
				hi_cell = mc
		incs.append("%s:now=%.0f/max=%.0f@%s" % [str(u.name), cur, hi, str(hi_cell)])
	return {
		"descs": descs, "cells": pcells,
		"engaged": bool(sim.engaged0), "thr": float(ai._accept_threshold(sim)),
		"rb0": float(ai._rule_b_score(sim)), "rb1": float(ai1._rule_b_score(sim1)),
		"inc_txt": " ".join(incs),
	}

## 真跑一臂：返回出招指纹（`force_open` 同上：搜之前把根局面的门掰开 ⇒ 整回合都开着）
func _plan(descs: Array, inject: Dictionary, force_open: bool = false) -> Dictionary:
	var ai = _mk(inject)
	var sim = ai.build_state(descs, _occ(descs), {}, {}, {}, {}, {})
	if force_open:
		sim.engaged0 = false
	var plan: Array = ai.search(sim, DataRegistry.Faction.ENEMY)
	var parts: Array = []
	for s in plan:
		var a: Dictionary = s.get("action", {})
		parts.append("%d:%s:%d" % [int(s.get("idx", -1)), str(a.get("move", null)), int(a.get("atk", -99))])
	return { "steps": plan.size(), "fp": ">".join(parts) }

func _mk(inject: Dictionary):
	var ai = FORK.new(_grid)
	ai.difficulty = 2                    # 与 harness 同口径（difficulty>=2 ⇒ 用 w_beam / w_jitter）
	ai.log_decisions = false
	ai.time_budget_ms = 0                # 不限时（可复现），与镜像批一致
	ai.w_beam = BEAM
	ai.set_weights(inject)
	return ai

func _descs(deck: Array, ecells: Array, pcells: Array) -> Array:
	var out: Array = []
	for i in deck.size():
		out.append(_desc(DataRegistry.Faction.ENEMY, String(deck[i]), ecells[i], "我方%d" % i))
	for i in deck.size():
		out.append(_desc(DataRegistry.Faction.PLAYER, String(deck[i]), pcells[i], "玩家%d" % i))
	return out

func _occ(descs: Array) -> Dictionary:
	var occ := {}
	for i in descs.size():
		occ[descs[i]["cell"]] = i
	return occ

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

func _flat(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var d = JSON.parse_string(f.get_as_text())
	f.close()
	var out: Dictionary = {}
	if typeof(d) != TYPE_DICTIONARY:
		return out
	for k in (d as Dictionary).keys():
		if String(k).begins_with("_"):
			continue                     # `_说明` 之类的注释字段不是键
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

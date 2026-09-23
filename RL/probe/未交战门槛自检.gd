extends Node
## 未交战门槛自检（⑥规则B / `MOVE_ACCEPT_DAMAGE`）—— **2026-09-22 晚·用户点名「补6」**（一次性探针，跑完即退）。
##
## 为什么要单独补这一轮：
##   `RL/probe/敏感度.gd` 的 `-Mode ablate`（41 个局面 = 24 随机 + 12 手工）量到
##   `MOVE_ACCEPT_DAMAGE` 的**出招变化率 = 0.00**（删掉它出招一模一样、分数差也是 0）。
##   但 ⑥ 的**门控**恰恰是「**只在未交战**时生效」：`_accept_threshold()` 读 `Sim.engaged0`
##   （= 本回合行动前的快照，`_engaged()` 在 `build_state` 里算一次），**已交战 ⇒ 整项返回 0**。
##   ⇒ 那 41 个局面大多已经交战，等于**根本没测到**这一项。本探针只干一件事：
##   **构造未交战局面**（我方单位在敌方「射程＋移动力」圈外），再看 ⑥ 换不换出招。
##
## 三个臂（同一局面、只换阈值；其余键一字不动）：
##   `thr4`   = 现役值 4（`噩梦.json`）
##   `thr0`   = **删掉权重表里那一行**之后的引擎默认值 0（= 罚满额：挨多少罚多少）
##   `thr999` = 等价于**关掉 ⑥**（`max(挨打−999, 0)` 恒 0）
## 每局面打印：`engaged0` / 阈值 / ⑥ 三个分值 / 我方各单位的挨打合计（当前格 + 候选落点里最大那个）
##   / 三臂的计划指纹与差异。末尾给汇总率。
##
## 判读：
##   · 若 `未交战` 局面里 `diff_4v999` 明显 > 0 ⇒ **⑥ 是活的**，"ablate 读 0" 只是那批局面没覆盖；
##   · 若未交战局面里也全 0 ⇒ ⑥ 真是死键 ⇒ 可以按精简方案删掉它。
##
## 运行：
##   & RL\train\跑Godot隔离.ps1 -Tag nv -TimeoutSec 600 -Args @('--headless','--path',(Get-Location).Path,'--scene','res://RL/probe/未交战门槛自检.tscn','--','60')

const FORK := preload("res://RL/ai/AI_Battle.gd")
const NIGHTMARE_PATH := "res://RL/weights/噩梦.json"

var _grid: HexGrid

func _ready() -> void:
	_grid = HexGrid.new()
	_grid.width = 7
	_grid.height = 5
	_run.call_deferred()

func _run() -> void:
	var ua := OS.get_cmdline_user_args()
	var beam := int(ua[0]) if ua.size() > 0 else 60
	var w := _load_flat_weights(NIGHTMARE_PATH)
	var thr_now := float(w.get("MOVE_ACCEPT_DAMAGE", 0.0))
	w["BEAM"] = beam
	var w0 := w.duplicate()
	w0.erase("MOVE_ACCEPT_DAMAGE")            # 删键 ⇒ 引擎默认 0
	var w999 := w.duplicate()
	w999["MOVE_ACCEPT_DAMAGE"] = 999.0        # 等价于关掉整项
	print("NV|CFG|positions=%d|beam=%d|board=%dx%d|fork_sha=%s|w_sha=%s|thr_in_file=%.0f" % [
		_positions().size(), beam, _grid.width, _grid.height,
		_sha("res://RL/ai/AI_Battle.gd"), _sha(NIGHTMARE_PATH), thr_now])

	var n_gate := 0
	var n_plan40 := 0
	var n_plan4999 := 0
	var n_first40 := 0
	var n_first4999 := 0
	var sum_gap40 := 0.0
	var sum_six4 := 0.0
	var total := 0
	for pos in _positions():
		total += 1
		var nm := String(pos["name"])
		# ---- A) 门控 + 挨打合计的诊断（用现役阈值建局，与生产同口径）----
		var ai = _mk_ai(w)
		var sim = ai.build_state(pos["descs"], pos.get("occ", {}), pos.get("gold", {}),
			pos.get("graves", {}), pos.get("obs", {}), pos.get("bombs", {}), pos.get("buff", {}))
		var thr := float(ai._accept_threshold(sim))
		var gate_open: bool = not bool(sim.engaged0)
		if gate_open:
			n_gate += 1
		var rb4 := float(ai._rule_b_score(sim))
		var ai0 = _mk_ai(w0)
		var sim0 = ai0.build_state(pos["descs"], pos.get("occ", {}), pos.get("gold", {}),
			pos.get("graves", {}), pos.get("obs", {}), pos.get("bombs", {}), pos.get("buff", {}))
		var rb0 := float(ai0._rule_b_score(sim0))
		var ai9 = _mk_ai(w999)
		var sim9 = ai9.build_state(pos["descs"], pos.get("occ", {}), pos.get("gold", {}),
			pos.get("graves", {}), pos.get("obs", {}), pos.get("bombs", {}), pos.get("buff", {}))
		var rb9 := float(ai9._rule_b_score(sim9))
		print("NV|POS|%s|engaged0=%s|gate=%s|thr=%.0f|rb_thr4=%.2f|rb_thr0=%.2f|rb_off=%.2f" % [
			nm, str(bool(sim.engaged0)), ("开" if gate_open else "关"), thr, rb4, rb0, rb9])
		# 我方每个单位的挨打合计（当前格 / 候选落点里最大的那个）
		for i in sim.units.size():
			var u = sim.units[i]
			if u == null or not u.alive or u.fn != DataRegistry.Faction.ENEMY:
				continue
			var inc_cur := float(ai._incoming_total_on(sim, u, u.cell))
			var inc_max := inc_cur
			var inc_cell: Vector2i = u.cell
			for combo in ai._actions_for(sim, i):
				var mc: Vector2i = u.cell
				if combo.get("move") != null:
					mc = combo["move"]
				var v := float(ai._incoming_total_on(sim, u, mc))
				if v > inc_max:
					inc_max = v
					inc_cell = mc
			print("NV|UNIT|%s|%s|cell=%s|hp=%d|emove=%d|rng=%d|eatk=%d|inc_cur=%.1f|inc_max=%.1f|max_cell=%s" % [
				nm, str(u.name), str(u.cell), int(u.hp), int(u.emove), int(u.atk_range), int(u.eatk),
				inc_cur, inc_max, str(inc_cell)])
			# ⚠️ 上面那两列 `rb_*` 是在**初始态**算的 ⇒ 我方的挨打合计天然是 0（人还在圈外）⇒ 三档必然都是 0。
			#   阈值真正发力的时刻是"**压到那个最挨打的落点之后**" ⇒ 这里补算一次：
			#   克隆局面 → 把"落点挨打最大"的那个纯移动候选应用上去 → 再按三档算 ⑥（HP_VALUE_W = 1.0）。
			if inc_max > inc_cur:
				var c = sim.clone()
				for combo2 in ai._actions_for(sim, i):
					var mc2: Vector2i = u.cell
					if combo2.get("move") != null:
						mc2 = combo2["move"]
					if mc2 == inc_cell and int(combo2.get("atk", -1)) == -1:
						ai._apply(c, i, combo2)
						break
				var s4 := 0.0
				var s0 := 0.0
				for u2 in c.units:
					if u2 == null or not u2.alive or u2.fn != DataRegistry.Faction.ENEMY:
						continue
					var inc2 := float(ai._incoming_total_on(c, u2, u2.cell))
					s4 += maxf(inc2 - 4.0, 0.0)
					s0 += maxf(inc2, 0.0)
				print("NV|RB|%s|%s|at=%s|inc=%.1f|six_thr4=%.2f|six_thr0=%.2f|six_off=0.00|gap(4v0)=%.2f" % [
					nm, str(u.name), str(inc_cell), inc_max, s4, s0, (s0 - s4)])
				sum_gap40 += (s0 - s4)     # 阈值 4→0（= 删键后的默认）多罚多少
				sum_six4 += s4             # 现役阈值 4 下 ⑥ 实际扣了多少（关掉能省这笔）
		# ---- B) 三臂出招对比 ----
		var p4 := _one(pos, w)
		var p0 := _one(pos, w0)
		var p9 := _one(pos, w999)
		var d40: bool = String(p4["fp"]) != String(p0["fp"])
		var d4999: bool = String(p4["fp"]) != String(p9["fp"])
		var f40: bool = String(p4["firstfp"]) != String(p0["firstfp"])
		var f4999: bool = String(p4["firstfp"]) != String(p9["firstfp"])
		var s40: bool = String(p4["setfp"]) != String(p0["setfp"])
		var s4999: bool = String(p4["setfp"]) != String(p9["setfp"])
		if d40:
			n_plan40 += 1
		if d4999:
			n_plan4999 += 1
		if f40:
			n_first40 += 1
		if f4999:
			n_first4999 += 1
		print("NV|PLAN|%s|steps4=%d|steps0=%d|steps_off=%d|plan_4v0=%s|plan_4voff=%s|first_4v0=%s|first_4voff=%s|set_4v0=%s|set_4voff=%s" % [
			nm, int(p4["steps"]), int(p0["steps"]), int(p9["steps"]),
			("变" if d40 else "同"), ("变" if d4999 else "同"),
			("变" if f40 else "同"), ("变" if f4999 else "同"),
			("变" if s40 else "同"), ("变" if s4999 else "同")])
		if d40:
			print("NV|DIFF4v0|%s|thr4=%s||thr0=%s" % [nm, String(p4["fp"]), String(p0["fp"])])
		if d4999:
			print("NV|DIFF4vOFF|%s|thr4=%s||off=%s" % [nm, String(p4["fp"]), String(p9["fp"])])
	print("NV|SUM|positions=%d|gate_open=%d|plan_4v0=%d|plan_4voff=%d|first_4v0=%d|first_4voff=%d|sum_six_thr4=%.2f|sum_gap(4v0)=%.2f" % [
		total, n_gate, n_plan40, n_plan4999, n_first40, n_first4999, sum_six4, sum_gap40])
	print("NV|READ|判读：gate_open>0 且 plan_4voff>0 ⇒ ⑥ 在未交战局面里是活的（ablate 读 0 只是那批局面没覆盖）；全 0 ⇒ 真是死键")
	print("NV|END")
	get_tree().quit(0)

func _mk_ai(inject: Dictionary):
	var ai = FORK.new(_grid)
	ai.difficulty = 2
	ai.log_decisions = false
	ai.time_budget_ms = 0
	ai.set_weights(inject)
	return ai

## 跑一臂：返回计划指纹（fp = 逐步序列；setfp = 无序集合；firstfp = 第一步）
func _one(pos: Dictionary, inject: Dictionary) -> Dictionary:
	var ai = _mk_ai(inject)
	var sim = ai.build_state(pos["descs"], pos.get("occ", {}), pos.get("gold", {}),
		pos.get("graves", {}), pos.get("obs", {}), pos.get("bombs", {}), pos.get("buff", {}))
	var plan: Array = ai.search(sim, DataRegistry.Faction.ENEMY)
	var parts: Array = []
	for s in plan:
		var a: Dictionary = s.get("action", {})
		parts.append("%d:%s:%d:%s" % [
			int(s.get("idx", -1)), str(a.get("move", null)),
			int(a.get("atk", -99)), str(a.get("atk_obs", null))])
	var sorted_parts := parts.duplicate()
	sorted_parts.sort()
	return {
		"steps": plan.size(),
		"fp": ">".join(parts),
		"setfp": ">".join(sorted_parts),
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

func _u(fn: int, hero: String, cell: Vector2i, hp: int, max_hp: int, atk: int, mv: int,
		rng: int, typ: int, skills: Array, nm: String) -> Dictionary:
	return {
		"fn": fn, "hero": hero, "cell": cell, "hp": hp, "max_hp": max_hp,
		"atk": atk, "eatk": atk, "move": mv, "emove": mv,
		"atk_range": rng, "atk_type": typ, "skills": skills, "name": nm,
	}

## 局面集（7×5 棋盘；E = 我方/AI 侧，P = 玩家侧）
## 设计口径：**我方单位开局全在敌方「射程＋移动力」圈外**（⇒ `engaged0 = false` ⇒ ⑥ 的门开着），
##   同时"往前压一到两格"的落点又落进圈里（⇒ 挨打合计 > 阈值 ⇒ ⑥ 真扣分）。
func _positions() -> Array:
	var E := DataRegistry.Faction.ENEMY
	var P := DataRegistry.Faction.PLAYER
	var MELEE := int(DataRegistry.AttackType.MELEE)
	var RANGED := int(DataRegistry.AttackType.RANGED)
	var out: Array = []

	# ① 推进窗口（未交战）：我方近战 3 格移动力，玩家侧两名 5 攻近战(mv2/rng1) + 一名远程(mv2/rng2)
	#    ⇒ 压到第 3 列就进圈（挨打合计 ≈ 10~14），⑥ 在 thr=4 / thr=0 / 关 三档下差 4~14 分。
	out.append({ "name": "①推进窗口", "descs": [
		_u(E, "hero_25", Vector2i(0, 2), 40, 40, 10, 3, 1, MELEE, [], "我方战锤"),
		_u(E, "hero_13", Vector2i(0, 0), 45, 45, 3, 3, 1, MELEE, [DataRegistry.Skill.TAUNT], "我方嘲讽"),
		_u(E, "hero_37", Vector2i(0, 4), 30, 30, 5, 2, 2, RANGED, [], "我方远程"),
		_u(P, "hero_23", Vector2i(6, 2), 20, 20, 5, 2, 1, MELEE, [DataRegistry.Skill.TAUNT], "敌嘲讽"),
		_u(P, "hero_26", Vector2i(6, 0), 20, 20, 5, 2, 1, MELEE, [], "敌近战A"),
		_u(P, "hero_31", Vector2i(6, 4), 18, 18, 4, 2, 2, RANGED, [], "敌远程"),
	] })

	# ② 只有远程能压（够不着人但可以走进圈）：我方只有一名远程 ⇒ 候选全是"纯走位"，
	#    ⑥ 与 ⑤位置拉力（每格 +2.4）直接对冲，最能看出阈值换不换出招。
	out.append({ "name": "②远程纯压位", "descs": [
		_u(E, "hero_37", Vector2i(0, 2), 30, 30, 5, 2, 2, RANGED, [], "我方远程"),
		_u(P, "hero_23", Vector2i(6, 2), 20, 20, 5, 2, 1, MELEE, [], "敌近战A"),
		_u(P, "hero_26", Vector2i(6, 0), 20, 20, 5, 2, 1, MELEE, [], "敌近战B"),
	] })

	# ③ 刚过阈值：只有一名 5 攻近战够得到 ⇒ 落点挨打合计 ≈ 5 ⇒ ⑥ 在 thr4 只罚 1、thr0 罚 5
	out.append({ "name": "③刚过阈值", "descs": [
		_u(E, "hero_25", Vector2i(0, 2), 40, 40, 10, 3, 1, MELEE, [], "我方战锤"),
		_u(P, "hero_23", Vector2i(6, 2), 20, 20, 5, 2, 1, MELEE, [], "敌近战A"),
	] })

	# ④ 高攻玩家（10 伤）：落点挨打合计 ≈ 20 ⇒ thr4 罚 16 / thr0 罚 20 / 关罚 0 ⇒ 最敏感的一档
	out.append({ "name": "④高攻10伤", "descs": [
		_u(E, "hero_25", Vector2i(0, 2), 40, 40, 10, 3, 1, MELEE, [], "我方战锤"),
		_u(E, "hero_13", Vector2i(0, 0), 45, 45, 3, 3, 1, MELEE, [DataRegistry.Skill.TAUNT], "我方嘲讽"),
		_u(P, "hero_25", Vector2i(6, 2), 40, 40, 10, 2, 1, MELEE, [], "敌高攻A"),
		_u(P, "hero_25", Vector2i(6, 0), 40, 40, 10, 2, 1, MELEE, [], "敌高攻B"),
	] })

	# ⑤ 对照组·已交战（同一批单位，但我方开局就站在玩家圈里）⇒ 门应当**关着**，
	#    三臂计划应当**完全一样**（用来证明"ablate 读 0"确实是门控造成的，而不是探针坏了）
	out.append({ "name": "⑤对照·已交战", "descs": [
		_u(E, "hero_25", Vector2i(3, 2), 40, 40, 10, 3, 1, MELEE, [], "我方战锤"),
		_u(E, "hero_13", Vector2i(3, 0), 45, 45, 3, 3, 1, MELEE, [DataRegistry.Skill.TAUNT], "我方嘲讽"),
		_u(E, "hero_37", Vector2i(3, 4), 30, 30, 5, 2, 2, RANGED, [], "我方远程"),
		_u(P, "hero_23", Vector2i(6, 2), 20, 20, 5, 2, 1, MELEE, [DataRegistry.Skill.TAUNT], "敌嘲讽"),
		_u(P, "hero_26", Vector2i(6, 0), 20, 20, 5, 2, 1, MELEE, [], "敌近战A"),
		_u(P, "hero_31", Vector2i(6, 4), 18, 18, 4, 2, 2, RANGED, [], "敌远程"),
	] })
	return out

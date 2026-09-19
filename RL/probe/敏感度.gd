extends Node
## 决策敏感度扫描（**不跑对局**）——把"改了也不改出招"的死键筛掉。
##
## 做什么：对 19 个通用可调键逐个做 ×0.5 / ×2.0 注入，在 12 个手工局面上比较
##   ① 局面分数 `_evaluate()` 的变化量（分数敏感度）
##   ② `search()` 出来的**首选计划**是否改变（出招敏感度：有序 / 无序集合 / 第一步 三种口径）
## 为什么这么做：调参只有在"改这个键真的会改出招"时才有意义；分数敏感但出招不敏感的键，
##   说明它被别的项压过去了（改它等于白占搜索维度）。
## 只用 HexGrid，不建 Battle、不跑回放 —— 秒级，且完全离线（不改任何既有文件）。
##
## 运行：godot --headless --path <项目> --scene res://RL/probe/敏感度.tscn -- [beam]
##   beam 缺省 40（探针只看"决策方向"，不需要满宽度；调小是为了快）

const FORK := preload("res://RL/ai/AI_Battle.gd")

## 键 -> fork 实例里的变量名（与 `set_weights` 的分支逐字对应）
## ⚠️ 2026-09-19：`MAX_MOVE_OPTIONS` / `ENGAGE_PULL_PER_CELL` / `PLAYER_VALUE_MULT` /
##   `VALUE_SOLO_W` / `VALUE_RELATION_W` **已于 2026-09-18 写死成 const**（不再是 `w_*` 变量）⇒
##   从本表移除（否则 `ai.w_xxx = …` 会在运行时炸）；要测它们只能改 src 再跑对局。
const KEY_VAR := {
	"BEAM": "w_beam",
	"BUFF_TAKE_WEIGHT": "w_buff_take",
	"FOCUS_FIRE_WEIGHT": "w_focus_fire",
	"FOCUS_TIMES_WEIGHT": "w_focus_times",
	"HP_VALUE_W": "w_hp_value",
	"JITTER": "w_jitter",
	"KILL_BONUS": "w_kill_bonus",
	"OBSTACLE_DETOUR_WEIGHT": "w_obstacle_detour",
	"SELF_DEATH_W": "w_self_death",
	"THREAT_DEAD_FOLD": "w_threat_dead_fold",
	"THREAT_INCOMING_W": "w_threat_incoming",
	"THREAT_MOVE_DISCOUNT": "w_threat_discount",
	"VALUE_SILENCE_FOLD": "w_silence_fold",
	"VALUE_STUN_FOLD": "w_stun_fold",
	# ---- 2026-09-18/19 新增的机制键（默认关）----
	"RISK_W": "w_risk",
	"RISK_CORE_POW": "w_risk_core_pow",
	"RISK_DEATH_MULT": "w_risk_death_mult",
	"CORE_BY_THREAT": "w_core_by_threat",
	"REPLY_TOPK": "w_reply_topk",
	"REPLY_W": "w_reply_w",
	"TERMINAL_W": "w_terminal",
	# ---- 2026-09-19 并列裁决层（主杠杆）----
	"TIEBREAK_MODE": "w_tiebreak_mode",
	"TIEBREAK_EPS": "w_tiebreak_eps",
}
const INT_KEYS := ["BEAM", "REPLY_TOPK", "CORE_BY_THREAT", "TIEBREAK_MODE"]
const FACTORS := [0.5, 2.0]
## 宽程阶梯（含 0 = 归零消融）：用来区分"局部不敏感"的两种原因——
##   · **不重要的项**：整条曲线都平（任何值都不改出招）
##   · **已饱和的项**：默认点附近平，但拉到 0 或极端值时出招剧变 ⇒ 这一项其实**主导棋风**，
##     只是默认值落在"饱和区"里（用户 2026-09-15 指出的正是这种：`KILL_BONUS=38` 可能本身就太高，
##     ÷2 之后仍然压过一切，所以看起来"改了没变化"）。
const LADDER := [0.0, 0.05, 0.15, 0.4, 1.0, 2.5, 6.0, 15.0]

var _grid: HexGrid

func _ready() -> void:
	_grid = HexGrid.new()
	_grid.width = 6
	_grid.height = 5
	_run.call_deferred()

func _run() -> void:
	var ua := OS.get_cmdline_user_args()
	var beam := int(ua[0]) if ua.size() > 0 else 40
	# 模式：默认 "hand"（12 个人工局面，跑两段）；"rand N" = N 个随机局面，只跑局部边际段
	var mode := String(ua[1]) if ua.size() > 1 else "hand"
	var positions: Array = _positions()
	if mode == "rand" or mode == "ladder":
		positions = _rand_positions(int(ua[2]) if ua.size() > 2 else 60)
	elif mode == "ladderhand":
		positions = _positions()   # 人工局面里有"能一击必杀/集火/威胁"等**定向场景**，用于补覆盖
	elif mode == "scen":
		positions = _scenarios()   # 每个键专属的定向场景（覆盖优先）
	if mode == "uv":
		_unit_value_report()
		get_tree().quit(0)
		return
	print("SENS|CFG|mode=%s|positions=%d|keys=%d|factors=%s|beam=%d|fork_sha=%s" % [
		mode, positions.size(), KEY_VAR.size(), str(FACTORS), beam, _sha("res://RL/ai/AI_Battle.gd")])

	# 默认值（从一份干净实例上读，避免手抄）
	var probe_ai = FORK.new(_grid)
	probe_ai.difficulty = 2
	var defaults := {}
	for k in KEY_VAR.keys():
		defaults[k] = probe_ai.get(String(KEY_VAR[k]))
	probe_ai = null

	# 基线：每局面的分数 + 计划指纹（随机局面模式下跳过整盘搜索，只做下面的局部段）
	var base := {}
	if mode == "hand":
		for pos in positions:
			var r := _one(pos, { "BEAM": beam })
			base[String(pos["name"])] = r
			print("SENS|POS|%s|score=%.2f|steps=%d|fp=%s" % [
				String(pos["name"]), r["score"], int(r["steps"]), String(r["fp"])])

	# 逐个键 × 因子扫描
	if mode == "hand":
		for k in KEY_VAR.keys():
			var key := String(k)
			var d0: Variant = defaults[key]
			if float(d0) == 0.0:
				print("SENS|SKIP|%s|默认值=0，按比例注入无意义（JITTER 属于这类）" % key)
				continue
			for f in FACTORS:
				var v: Variant = _scaled(d0, float(f), INT_KEYS.has(key))
				var n_order := 0
				var n_set := 0
				var n_first := 0
				var dsum := 0.0
				var dmax := 0.0
				for pos in positions:
					var nm := String(pos["name"])
					var b: Dictionary = base[nm]
					var r := _one(pos, { "BEAM": beam, key: v })
					var d: float = absf(float(r["score"]) - float(b["score"]))
					dsum += d
					dmax = maxf(dmax, d)
					var ch_order := int(String(r["fp"]) != String(b["fp"]))
					var ch_set := int(String(r["setfp"]) != String(b["setfp"]))
					var ch_first := int(String(r["firstfp"]) != String(b["firstfp"]))
					n_order += ch_order
					n_set += ch_set
					n_first += ch_first
					print("SENS|ROW|%s|%.2f|%s|v=%s|dscore=%.3f|order=%d|set=%d|first=%d" % [
						key, float(f), nm, str(v), d, ch_order, ch_set, ch_first])
				var n := float(positions.size())
				print("SENS|SUM|%s|%.2f|pos=%d|dscore_mean=%.3f|dscore_max=%.3f|order_rate=%.2f|set_rate=%.2f|first_rate=%.2f" % [
					key, float(f), positions.size(), dsum / n, dmax,
					float(n_order) / n, float(n_set) / n, float(n_first) / n])
	print("SENS|END")

	# ===================== 第二段：局部动作边际（补第一段的盲点） =====================
	# 第一段用"整盘计划指纹"判敏感度，但 `_evaluate(初始局面)` 对**动作后果类**的键天然不敏感
	# （伤害/击杀/阵亡/拾取都要**动作落地后**才进分数）。所以这里对**第一个我方单位**枚举它所有动作，
	# 每个动作 clone+apply 后再评分，看：
	#   · margin = 最优动作 − 次优动作 的分数差（"决策余量"；余量 ≫ 某键的影响 ⇒ 该键不可能翻盘）
	#   · local_best = 该单位的最优动作（扰动后是否改变 = 真正的"局部出招敏感度"）
	print("SENS2|CFG|positions=%d|keys=%d|factors=%s|beam=%d" % [
		positions.size(), KEY_VAR.size(), str(FACTORS), beam])
	var lbase := {}
	var margins: Array = []
	for pos in positions:
		var r := _local(pos, { "BEAM": beam })
		lbase[String(pos["name"])] = r
		margins.append(float(r["margin"]))
		print("SENS2|POS|%s|n_actions=%d|best=%.3f|second=%.3f|margin=%.3f|fp=%s" % [
			String(pos["name"]), int(r["n"]), float(r["best"]), float(r["second"]),
			float(r["margin"]), String(r["fp"])])
	# 决策余量分布：只看"有得选"的局面（动作数 ≥ 3）；margin≈0 = 最优与次优**打平**
	var m_sorted := margins.duplicate()
	m_sorted.sort()
	var m_med := 0.0
	if m_sorted.size() > 0:
		m_med = float(m_sorted[m_sorted.size() / 2])
	var n_usable := 0
	var n_tie := 0
	var contested := {}
	for pos in positions:
		var nm := String(pos["name"])
		var r: Dictionary = lbase[nm]
		if int(r["n"]) < 3:
			continue
		n_usable += 1
		if float(r["margin"]) < 0.5:
			n_tie += 1
		if float(r["margin"]) < 5.0:
			contested[nm] = true   # "有争议"：余量小到可能被权重翻盘
	print("SENS2|MARGIN|pos=%d|usable=%d|tie_lt0.5=%d|tie_rate=%.2f|contested_lt5=%d|median=%.3f|max=%.3f" % [
		positions.size(), n_usable, n_tie, float(n_tie) / maxf(float(n_usable), 1.0),
		contested.size(), m_med, float(m_sorted[m_sorted.size() - 1]) if m_sorted.size() > 0 else 0.0])
	for k in KEY_VAR.keys():
		var key := String(k)
		var d0: Variant = defaults[key]
		if float(d0) == 0.0:
			continue
		for f in FACTORS:
			var v: Variant = _scaled(d0, float(f), INT_KEYS.has(key))
			var n_chg := 0
			var n_chg_c := 0
			var msum := 0.0
			var mmin := 1e9
			for pos in positions:
				var nm := String(pos["name"])
				var b: Dictionary = lbase[nm]
				var r := _local(pos, { "BEAM": beam, key: v })
				var ch := int(String(r["fp"]) != String(b["fp"]))
				n_chg += ch
				if contested.has(nm) and ch == 1:
					n_chg_c += 1
				msum += float(r["margin"])
				mmin = minf(mmin, float(r["margin"]))
				print("SENS2|ROW|%s|%.2f|%s|v=%s|margin=%.3f|local_changed=%d" % [
					key, float(f), nm, str(v), float(r["margin"]), ch])
			var n := float(positions.size())
			var nc := maxf(float(contested.size()), 1.0)
			print("SENS2|SUM|%s|%.2f|pos=%d|local_rate=%.2f|contested_rate=%.2f|margin_mean=%.3f|margin_min=%.3f" % [
				key, float(f), positions.size(), float(n_chg) / n, float(n_chg_c) / nc, msum / n, mmin])
	print("SENS2|END")

	# ===================== 第三段：宽程阶梯（区分"不重要" vs "已饱和"） =====================
	if mode == "ladder" or mode == "ladderhand":
		_ladder(positions, beam, defaults)
	if mode == "scen":
		_run_scenarios(positions, beam, defaults)
		_gap_stage(positions, beam, defaults)
	get_tree().quit(0)

## 决策边界（Δgap）：把"最优 vs 次优"这两个**具体动作**固定下来，看每个键把它俩的分数差推多远。
## 为什么需要它：并列（gap≈0）时"任何微小扰动都会翻盘"，光看 flip 率分不清"真重要"和"并列噪声"；
## Δgap 给的是**量**：这个键最多能把这个决策的余量推动多少分、能不能推过 0（推过 = 它能单独翻这个决策）。
func _gap_stage(positions: Array, beam: int, defaults: Dictionary) -> void:
	for pos in positions:
		var nm := String(pos["name"])
		var base := _local(pos, { "BEAM": beam })
		var fp1 := String(base.get("fp", ""))
		if fp1 == "":
			continue
		var ai = _mk_ai({ "BEAM": beam })
		var sim = _mk_sim(ai, pos)
		var idx := _first_enemy(sim)
		if idx < 0:
			continue
		var rows: Array = []
		for a in ai._actions_for(sim, idx):
			rows.append({ "fp": _act_fp(a), "s": _score_of(ai, sim, idx, a) })
		rows.sort_custom(func(x, y): return float(x["s"]) > float(y["s"]))
		if rows.size() < 2:
			continue
		var fp2 := String(rows[1]["fp"])
		var gap0 := float(rows[0]["s"]) - float(rows[1]["s"])
		var parts: Array = []
		var crossed := false
		var push := 0.0
		for k in (pos.get("targets", []) as Array):
			var key := String(k)
			var d0: Variant = defaults.get(key, null)
			if d0 == null or float(d0) == 0.0:
				continue
			for f in [0.0, 0.15, 2.5, 15.0]:
				var v: Variant = _scaled(d0, float(f), INT_KEYS.has(key))
				var ai2 = _mk_ai({ "BEAM": beam, key: v })
				var sim2 = _mk_sim(ai2, pos)
				var g: float = _score_by_fp(ai2, sim2, idx, fp1) - _score_by_fp(ai2, sim2, idx, fp2)
				if not is_nan(g):
					push = maxf(push, absf(g - gap0))
					if g < 0.0:
						crossed = true
					parts.append("%s@%s=%+.1f" % [key, str(f), g])
		print("GAP|%s|gap0=%+.2f|crossed=%s|push=%.1f|%s" % [
			nm, gap0, str(crossed), push, " ".join(parts)])

func _act_fp(a: Dictionary) -> String:
	return "%s:%d:%s" % [str(a.get("move", null)), int(a.get("atk", -99)), str(a.get("atk_obs", null))]

## 身价拆账：打印若干英雄的 solo / synergy / counter 三分量与加权后的身价。
## 目的：回答"`VALUE_SOLO_W` 对'击杀时身价项消失'的贡献占多少"——即把 solo 归零后，那笔自动收益还剩多少。
func _unit_value_report() -> void:
	var same := ["hero_25", "hero_13"]              # 队友（配合分用）
	var other := ["hero_23", "hero_26", "hero_31"]  # 对手（克制分用）
	var ids := ["hero_22", "hero_13", "hero_25", "hero_42", "hero_03", "hero_48", "hero_31", "hero_23"]
	print("UV|CFG|w_solo=%.2f|w_relation=%.2f|hero_value=%.2f|队友=%s|对手=%s" % [
		1.0, 0.6, 1.0, str(same), str(other)])
	for hid in ids:
		var p: Dictionary = DataRegistry.battle_unit_value_parts(String(hid), same, other, null)
		var solo := float(p["solo"])
		var syn := float(p["synergy"])
		var cnt := float(p["counter"])
		var v_def := solo * 1.0 + (syn + cnt) * 0.6
		var v_solo0 := 0.0 + (syn + cnt) * 0.6
		var share := 100.0 * (solo * 1.0) / maxf(v_def, 0.001)
		print("UV|%s|solo=%.2f|syn=%.2f|cnt=%.2f|v_default=%.2f|v_solo0=%.2f|solo_share=%.0f%%|kill_jump_default=%.1f|kill_jump_solo0=%.1f" % [
			String(hid), solo, syn, cnt, v_def, v_solo0, share, v_def * 1.25, v_solo0 * 1.25])

func _mk_ai(inject: Dictionary):
	var ai = FORK.new(_grid)
	ai.difficulty = 2
	ai.log_decisions = false
	ai.time_budget_ms = 0
	ai.set_weights(inject)
	return ai

func _mk_sim(ai, pos: Dictionary):
	return ai.build_state(pos["descs"], pos.get("occ", {}), pos.get("gold", {}),
		pos.get("graves", {}), pos.get("obs", {}), pos.get("bombs", {}), pos.get("buff", {}))

func _first_enemy(sim) -> int:
	for i in sim.units.size():
		if sim.units[i].alive and sim.units[i].fn == DataRegistry.Faction.ENEMY:
			return i
	return -1

func _score_of(ai, sim, idx: int, a: Dictionary) -> float:
	var c = sim.clone()
	ai._apply(c, idx, a)
	return float(ai._evaluate(c))

func _score_by_fp(ai, sim, idx: int, want: String) -> float:
	for a in ai._actions_for(sim, idx):
		if _act_fp(a) == want:
			return _score_of(ai, sim, idx, a)
	return NAN

## 定向场景扫描：每个场景**只扫它自己声明针对的键**，于是"敏感度"是在**该键自己的场景里**测的。
## 这修掉了前两轮的两个坑：① 覆盖（场景按需求构造）② 只测局部斜率（用宽程阶梯）。
func _run_scenarios(positions: Array, beam: int, defaults: Dictionary) -> void:
	var bplan := {}
	var blocal := {}
	var cover := {}
	for pos in positions:
		var nm := String(pos["name"])
		bplan[nm] = String(_one(pos, { "BEAM": beam })["fp"])
		blocal[nm] = String(_local(pos, { "BEAM": beam })["fp"])
		for k in (pos.get("targets", []) as Array):
			cover[String(k)] = int(cover.get(String(k), 0)) + 1
	var keys_sorted: Array = cover.keys()
	keys_sorted.sort()
	for k in keys_sorted:
		print("SCEN|COVER|%s|scenarios=%d" % [String(k), int(cover[k])])
	for k in keys_sorted:
		var key := String(k)
		var d0: Variant = defaults.get(key, null)
		if d0 == null or float(d0) == 0.0:
			print("SCEN|SKIP|%s|默认值缺失或为 0（JITTER 属于后者）" % key)
			continue
		var pcurve: Array = []
		var lcurve: Array = []
		for f in LADDER:
			var v: Variant = _scaled(d0, float(f), INT_KEYS.has(key))
			var pf := 0
			var lf := 0
			var n := 0
			for pos in positions:
				if not (pos.get("targets", []) as Array).has(key):
					continue
				n += 1
				var nm := String(pos["name"])
				if String(_one(pos, { "BEAM": beam, key: v })["fp"]) != String(bplan[nm]):
					pf += 1
				if String(_local(pos, { "BEAM": beam, key: v })["fp"]) != String(blocal[nm]):
					lf += 1
			pcurve.append("%s:%d/%d" % [str(f), pf, n])
			lcurve.append("%s:%d/%d" % [str(f), lf, n])
			print("SCEN|ROW|%s|%s|v=%s|plan=%d/%d|local=%d/%d" % [key, str(f), str(v), pf, n, lf, n])
		print("SCEN|CURVE|%s|plan[%s]|local[%s]" % [key, "|".join(pcurve), "|".join(lcurve)])

## 对每个键沿 LADDER 扫一遍，输出"响应曲线"。
## 关键：**条件覆盖**——某项只在它的场景存在时才可能起作用（例：`KILL_BONUS` 只在"这一招能击杀"时才有意义）。
## 所以除了全局面 flip_rate，还按子集分别统计：能击杀 / 能攻击 / 够得到道具 / 会被打（threat>0）。
func _ladder(positions: Array, beam: int, defaults: Dictionary) -> void:
	var lbase := {}
	var subsets := { "kill": [], "atk": [], "buff": [], "threat": [] }
	for pos in positions:
		var nm := String(pos["name"])
		var r := _local(pos, { "BEAM": beam })
		lbase[nm] = r
		if bool(r["has_kill"]):
			subsets["kill"].append(nm)
		if bool(r["has_atk"]):
			subsets["atk"].append(nm)
		if bool(r["reach_buff"]):
			subsets["buff"].append(nm)
		if float(r["threat"]) > 0.0:
			subsets["threat"].append(nm)
	print("SENS3|CFG|ladder=%s|positions=%d" % [str(LADDER), positions.size()])
	print("SENS3|COVER|kill=%d|atk=%d|buff=%d|threat=%d|total=%d" % [
		subsets["kill"].size(), subsets["atk"].size(), subsets["buff"].size(),
		subsets["threat"].size(), positions.size()])
	for k in KEY_VAR.keys():
		var key := String(k)
		var d0: Variant = defaults[key]
		if float(d0) == 0.0:
			continue
		var curve: Array = []
		for f in LADDER:
			var v: Variant = _scaled(d0, float(f), INT_KEYS.has(key))
			var n_flip := 0
			var flips := { "kill": 0, "atk": 0, "buff": 0, "threat": 0 }
			for pos in positions:
				var nm := String(pos["name"])
				var b: Dictionary = lbase[nm]
				var r := _local(pos, { "BEAM": beam, key: v })
				var changed := String(r["fp"]) != String(b["fp"])
				if changed:
					n_flip += 1
					for tag in flips.keys():
						if (subsets[tag] as Array).has(nm):
							flips[tag] = int(flips[tag]) + 1
			var n := maxf(float(positions.size()), 1.0)
			curve.append("%s:%.2f" % [str(f), float(n_flip) / n])
			var cond := ""
			for tag in ["kill", "atk", "buff", "threat"]:
				var sn := (subsets[tag] as Array).size()
				if sn > 0:
					cond += "%s=%d/%d " % [tag, int(flips[tag]), sn]
			print("SENS3|ROW|%s|%s|v=%s|flip_rate=%.2f|%s" % [
				key, str(f), str(v), float(n_flip) / n, cond.strip_edges()])
		print("SENS3|CURVE|%s|%s" % [key, "|".join(curve)])

## 局部动作边际：第一个存活我方单位的所有动作，逐个 apply 后评分
func _local(pos: Dictionary, inject: Dictionary) -> Dictionary:
	var ai = FORK.new(_grid)
	ai.difficulty = 2
	ai.log_decisions = false
	ai.time_budget_ms = 0
	ai.set_weights(inject)
	var sim = ai.build_state(pos["descs"], pos.get("occ", {}), pos.get("gold", {}),
		pos.get("graves", {}), pos.get("obs", {}), pos.get("bombs", {}), pos.get("buff", {}))
	var idx := -1
	for i in sim.units.size():
		if sim.units[i].alive and sim.units[i].fn == DataRegistry.Faction.ENEMY:
			idx = i
			break
	if idx < 0:
		return { "n": 0, "best": 0.0, "second": 0.0, "margin": 0.0, "fp": "" }
	var acts: Array = ai._actions_for(sim, idx)
	var scored: Array = []
	var has_atk := false
	var has_kill := false
	var reach_buff := false
	for a in acts:
		var c = sim.clone()
		ai._apply(c, idx, a)
		scored.append({ "s": float(ai._evaluate(c)), "a": a })
		if a.has("atk") and int(a["atk"]) >= 0:
			has_atk = true
			# 这一招打完之后有没有玩家单位死掉 → "本局面里这个单位能击杀"
			for j in c.units.size():
				var cu = c.units[j]
				if (not cu.alive) and cu.fn != DataRegistry.Faction.ENEMY:
					has_kill = true
		var mc = a.get("move", null)
		if mc != null and sim.buff_cells.has(mc):
			reach_buff = true
	var threat := 0.0
	if idx >= 0 and idx < sim.units.size():
		threat = float(ai._incoming_damage_on(sim, sim.units[idx]))
	scored.sort_custom(func(x, y): return float(x["s"]) > float(y["s"]))
	var best := 0.0
	var second := 0.0
	if scored.size() > 0:
		best = float(scored[0]["s"])
	# 只有一个动作 = 没有"次优"可比；把 second 设成 best（margin=0），
	# 否则 second 会留在 0.0 而 best 是负数 → margin 变成负的（探针自身的坑）
	second = best
	if scored.size() > 1:
		second = float(scored[1]["s"])
	var fp := ""
	if scored.size() > 0:
		var a: Dictionary = scored[0]["a"]
		fp = "%s:%d:%s" % [str(a.get("move", null)), int(a.get("atk", -99)), str(a.get("atk_obs", null))]
	return { "n": acts.size(), "best": best, "second": second, "margin": best - second, "fp": fp,
		"has_atk": has_atk, "has_kill": has_kill, "reach_buff": reach_buff, "threat": threat }

## 跑一次：注入 -> 建 sim -> 分数 -> 搜索 -> 三种指纹
func _one(pos: Dictionary, inject: Dictionary) -> Dictionary:
	var ai = FORK.new(_grid)
	ai.difficulty = 2
	ai.log_decisions = false
	ai.time_budget_ms = 0
	ai.set_weights(inject)
	var sim = ai.build_state(pos["descs"], pos.get("occ", {}), pos.get("gold", {}),
		pos.get("graves", {}), pos.get("obs", {}), pos.get("bombs", {}), pos.get("buff", {}))
	var score := float(ai._evaluate(sim))
	var plan: Array = ai.search(sim, DataRegistry.Faction.ENEMY)
	var parts := _parts(plan)
	var sorted_parts := parts.duplicate()
	sorted_parts.sort()
	return {
		"score": score,
		"steps": plan.size(),
		"fp": ">".join(parts),
		"setfp": ">".join(sorted_parts),
		"firstfp": String(parts[0]) if parts.size() > 0 else "",
	}

func _parts(plan: Array) -> Array:
	var out: Array = []
	for s in plan:
		var a: Dictionary = s.get("action", {})
		out.append("%d:%s:%d:%s" % [
			int(s.get("idx", -1)),
			str(a.get("move", null)),
			int(a.get("atk", -99)),
			str(a.get("atk_obs", null))])
	return out

func _scaled(d0, factor: float, is_int: bool):
	var v: float = float(d0) * factor
	if is_int:
		return maxi(int(round(v)), 1)
	return v

func _sha(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return "?"
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(f.get_buffer(f.get_length()))
	f.close()
	return ctx.finish().hex_encode().substr(0, 12)

## 随机局面：3v3、随机英雄/站位/血量，随机地形与道具/金矿/炸弹，随机状态。
## 为什么需要它：人工局面太简单/太对称（实测 12 个人工局面里 8 个"最优与次优打平"），
## 用随机采样才能估计"这个键在**一般局面**下改不改得出招"。
## 固定随机种子 → 可复现。
func _rand_positions(n: int) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260915
	var ids: Array = []
	for hid in DataRegistry.heroes.keys():
		var hd = DataRegistry.heroes[hid]
		if hd != null and not hd.is_summon:
			ids.append(String(hid))
	ids.sort()
	var cells: Array = _grid.all_cells()
	var out: Array = []
	var guard := 0
	while out.size() < n and guard < n * 60:
		guard += 1
		var descs: Array = []
		var used := {}
		for side in 2:
			var fn := DataRegistry.Faction.ENEMY if side == 0 else DataRegistry.Faction.PLAYER
			for k in 3:
				var hid: String = String(ids[rng.randi() % ids.size()])
				var hd = DataRegistry.heroes[hid]
				if hd == null:
					continue
				var cand: Vector2i = cells[rng.randi() % cells.size()]
				if used.has(cand):
					continue
				used[cand] = true
				var pct := 0.3 + rng.randf() * 0.7
				var hp := maxi(int(round(float(hd.max_hp) * pct)), 1)
				var nm := "%s%s#%d" % ["我" if side == 0 else "敌", String(hd.display_name), descs.size()]
				var extra := {}
				var r := rng.randf()
				if r < 0.08:
					extra["stunned"] = true
				elif r < 0.16:
					extra["silenced"] = true
				elif r < 0.24:
					extra["shield"] = true
				var d := _u(fn, hid, cand, hp, maxi(int(hd.max_hp), 1), maxi(int(hd.atk), 1),
					maxi(int(hd.move_range), 1), maxi(int(hd.attack_range), 1),
					int(hd.attack_type), (hd.skills as Array).duplicate(), nm, extra)
				if hid == "hero_42":
					d["can_pickup_gold"] = true
				descs.append(d)
		var n_e := 0
		var n_p := 0
		for d in descs:
			if int(d["fn"]) == int(DataRegistry.Faction.ENEMY):
				n_e += 1
			else:
				n_p += 1
		if n_e < 2 or n_p < 2:
			continue
		var obs := {}
		var buff := {}
		var gold := {}
		var bombs := {}
		for c in cells:
			var rr := rng.randf()
			if rr < 0.06:
				obs[c] = true
			elif rr < 0.09:
				buff[c] = ["atk", "move", "shield", "heal"][rng.randi() % 4]
			elif rr < 0.12:
				gold[c] = true
			elif rr < 0.14:
				bombs[c] = true
		for c in used.keys():
			obs.erase(c)
			buff.erase(c)
			gold.erase(c)
			bombs.erase(c)
		out.append({
			"name": "R%02d" % out.size(), "descs": descs,
			"obs": obs, "buff": buff, "gold": gold, "bombs": bombs,
		})
	return out

## 定向场景：**每个键配它自己的场景**（"这个键只有在它的场景里才可能起作用"）。
## 每个场景声明 `targets` = 它针对哪些键；扫描时**只在这些场景里扫这些键** ⇒ 敏感度是"覆盖正确"的。
func _scenarios() -> Array:
	var E := DataRegistry.Faction.ENEMY
	var P := DataRegistry.Faction.PLAYER
	var MELEE := int(DataRegistry.AttackType.MELEE)
	var RANGED := int(DataRegistry.AttackType.RANGED)
	var out: Array = []

	# —— 击杀族：能不能杀 / 杀谁 ——
	out.append({ "name": "S01 击杀二选一(同血不同身价)",
		"targets": ["KILL_BONUS", "VALUE_SOLO_W", "PLAYER_VALUE_MULT"], "descs": [
		_u(E, "hero_25", Vector2i(2, 4), 40, 40, 10, 3, 1, MELEE, [], "我方战锤A"),
		_u(E, "hero_26", Vector2i(4, 4), 20, 20, 6, 3, 1, MELEE, [], "我方战锤B"),
		_u(P, "hero_22", Vector2i(2, 3), 8, 30, 4, 3, 1, MELEE, [], "敌核心(8血)"),
		_u(P, "hero_31", Vector2i(4, 3), 8, 18, 4, 3, 2, RANGED, [], "敌远程(8血)"),
	] })
	out.append({ "name": "S02 击杀 vs 打核心",
		"targets": ["KILL_BONUS", "PLAYER_VALUE_MULT", "VALUE_SOLO_W"], "descs": [
		_u(E, "hero_25", Vector2i(2, 4), 40, 40, 10, 3, 1, MELEE, [], "我方战锤"),
		_u(P, "hero_31", Vector2i(2, 3), 6, 18, 4, 3, 2, RANGED, [], "敌远程(6血,可杀)"),
		_u(P, "hero_22", Vector2i(3, 3), 30, 30, 4, 3, 1, MELEE, [], "敌核心(30血)"),
	] })
	out.append({ "name": "S03 合力才够杀(20血目标)",
		"targets": ["FOCUS_FIRE_WEIGHT", "FOCUS_TIMES_WEIGHT", "KILL_BONUS"], "descs": [
		_u(E, "hero_25", Vector2i(1, 4), 40, 40, 8, 3, 1, MELEE, [], "我方A"),
		_u(E, "hero_26", Vector2i(2, 4), 20, 20, 8, 3, 1, MELEE, [], "我方B"),
		_u(E, "hero_23", Vector2i(3, 4), 20, 20, 8, 3, 1, MELEE, [], "我方C"),
		_u(P, "hero_22", Vector2i(2, 3), 20, 30, 4, 3, 1, MELEE, [], "敌核心(20血)"),
	] })

	# —— 集火族 ——
	out.append({ "name": "S04 集火 vs 分摊",
		"targets": ["FOCUS_FIRE_WEIGHT", "FOCUS_TIMES_WEIGHT"], "descs": [
		_u(E, "hero_25", Vector2i(1, 4), 40, 40, 6, 3, 1, MELEE, [], "我方A"),
		_u(E, "hero_26", Vector2i(2, 4), 20, 20, 6, 3, 1, MELEE, [], "我方B"),
		_u(E, "hero_23", Vector2i(3, 4), 20, 20, 6, 3, 1, MELEE, [], "我方C"),
		_u(P, "hero_22", Vector2i(1, 3), 12, 30, 4, 3, 1, MELEE, [], "敌核心(12血)"),
		_u(P, "hero_31", Vector2i(3, 3), 12, 18, 4, 3, 2, RANGED, [], "敌远程(12血)"),
	] })
	out.append({ "name": "S05 集火第二击边际",
		"targets": ["FOCUS_TIMES_WEIGHT"], "descs": [
		_u(E, "hero_25", Vector2i(2, 4), 40, 40, 6, 3, 1, MELEE, [], "我方A"),
		_u(E, "hero_26", Vector2i(3, 4), 20, 20, 6, 3, 1, MELEE, [], "我方B"),
		_u(P, "hero_31", Vector2i(2, 3), 3, 18, 4, 3, 2, RANGED, [], "敌远程(3血,一打就死)"),
		_u(P, "hero_22", Vector2i(3, 3), 12, 30, 4, 3, 1, MELEE, [], "敌核心(12血)"),
	] })

	# —— 我方阵亡族（本回合我方真会死人）——
	out.append({ "name": "S06 我方1血远程被反击死",
		"targets": ["SELF_DEATH_W", "THREAT_DEAD_FOLD", "THREAT_INCOMING_W"], "descs": [
		_u(E, "hero_37", Vector2i(1, 3), 1, 30, 5, 2, 2, RANGED, [], "我方残血远程"),
		_u(E, "hero_25", Vector2i(1, 4), 40, 40, 8, 3, 1, MELEE, [], "我方战锤"),
		_u(P, "hero_23", Vector2i(2, 3), 20, 20, 10, 3, 1, MELEE, [], "敌复仇者(反击10)"),
		_u(P, "hero_26", Vector2i(3, 2), 20, 20, 8, 3, 1, MELEE, [], "敌雪拳"),
	] })
	out.append({ "name": "S07 我方1血·踩炸弹二选一",
		"targets": ["SELF_DEATH_W", "THREAT_DEAD_FOLD"], "descs": [
		_u(E, "hero_25", Vector2i(1, 4), 1, 40, 8, 3, 1, MELEE, [], "我方1血战锤"),
		_u(P, "hero_23", Vector2i(1, 1), 20, 20, 6, 3, 1, MELEE, [], "敌复仇者"),
	], "bombs": { Vector2i(1, 3): true, Vector2i(1, 2): true } })
	out.append({ "name": "S08 我方满血也会被秒",
		"targets": ["THREAT_DEAD_FOLD", "THREAT_INCOMING_W"], "descs": [
		_u(E, "hero_37", Vector2i(2, 2), 8, 30, 5, 2, 2, RANGED, [], "我方远程(8血)"),
		_u(E, "hero_25", Vector2i(0, 0), 40, 40, 8, 3, 1, MELEE, [], "我方战锤"),
		_u(P, "hero_23", Vector2i(2, 4), 20, 20, 6, 3, 1, MELEE, [], "敌A"),
		_u(P, "hero_26", Vector2i(3, 3), 20, 20, 6, 3, 1, MELEE, [], "敌B"),
		_u(P, "hero_31", Vector2i(1, 3), 18, 18, 6, 3, 2, RANGED, [], "敌C"),
	] })
	out.append({ "name": "S21 我方2血·打它换不掉但会死",
		"targets": ["SELF_DEATH_W", "THREAT_DEAD_FOLD"], "descs": [
		_u(E, "hero_37", Vector2i(1, 3), 2, 30, 5, 2, 2, RANGED, [], "我方残血远程"),
		_u(P, "hero_23", Vector2i(1, 2), 20, 20, 10, 3, 1, MELEE, [], "敌复仇者(反击10)"),
		_u(P, "hero_26", Vector2i(2, 4), 20, 20, 8, 3, 1, MELEE, [], "敌雪拳"),
	] })

	# —— 威胁族 ——
	out.append({ "name": "S09 贴脸能打但会被集火",
		"targets": ["THREAT_INCOMING_W", "THREAT_MOVE_DISCOUNT", "THREAT_DEAD_FOLD"], "descs": [
		_u(E, "hero_25", Vector2i(2, 3), 40, 40, 8, 3, 1, MELEE, [], "我方战锤"),
		_u(P, "hero_23", Vector2i(2, 2), 20, 20, 6, 3, 1, MELEE, [], "敌A"),
		_u(P, "hero_26", Vector2i(3, 3), 20, 20, 6, 3, 1, MELEE, [], "敌B"),
		_u(P, "hero_31", Vector2i(1, 2), 18, 18, 4, 3, 2, RANGED, [], "敌C"),
	] })
	out.append({ "name": "S10 要先走一步才够得到",
		"targets": ["THREAT_MOVE_DISCOUNT"], "descs": [
		_u(E, "hero_25", Vector2i(0, 4), 40, 40, 8, 3, 1, MELEE, [], "我方战锤"),
		_u(P, "hero_23", Vector2i(2, 4), 20, 20, 6, 3, 1, MELEE, [], "敌近战(2格外)"),
		_u(P, "hero_31", Vector2i(2, 2), 18, 18, 4, 3, 2, RANGED, [], "敌远程"),
	] })

	# —— 状态折减族 ——
	out.append({ "name": "S11 眩晕敌人 vs 正常敌人",
		"targets": ["VALUE_STUN_FOLD", "PLAYER_VALUE_MULT", "VALUE_SOLO_W"], "descs": [
		_u(E, "hero_25", Vector2i(2, 4), 40, 40, 10, 3, 1, MELEE, [], "我方战锤"),
		_u(P, "hero_22", Vector2i(2, 3), 10, 30, 4, 3, 1, MELEE, [], "敌核心(眩晕)", { "stunned": true }),
		_u(P, "hero_31", Vector2i(3, 3), 10, 18, 4, 3, 2, RANGED, [], "敌远程(正常)"),
	] })
	out.append({ "name": "S12 沉默敌人 vs 正常敌人",
		"targets": ["VALUE_SILENCE_FOLD", "VALUE_SOLO_W"], "descs": [
		_u(E, "hero_25", Vector2i(2, 4), 40, 40, 10, 3, 1, MELEE, [], "我方战锤"),
		_u(P, "hero_22", Vector2i(2, 3), 10, 30, 4, 3, 1, MELEE, [], "敌核心(沉默)", { "silenced": true }),
		_u(P, "hero_31", Vector2i(3, 3), 10, 18, 4, 3, 2, RANGED, [], "敌远程(正常)"),
	] })

	# —— 经济 / 走位族 ——
	out.append({ "name": "S13 道具 vs 攻击(二选一)",
		"targets": ["BUFF_TAKE_WEIGHT"], "descs": [
		_u(E, "hero_25", Vector2i(1, 4), 40, 40, 8, 3, 1, MELEE, [], "我方战锤"),
		_u(E, "hero_37", Vector2i(1, 1), 30, 30, 5, 2, 2, RANGED, [], "我方远程"),
		_u(P, "hero_23", Vector2i(3, 4), 20, 20, 6, 3, 1, MELEE, [], "敌近战"),
	], "buff": { Vector2i(0, 3): "atk", Vector2i(0, 2): "shield" } })
	out.append({ "name": "S14 道具在身后 vs 压上",
		"targets": ["BUFF_TAKE_WEIGHT", "ENGAGE_PULL_PER_CELL"], "descs": [
		_u(E, "hero_25", Vector2i(4, 4), 40, 40, 8, 3, 1, MELEE, [], "我方战锤"),
		_u(E, "hero_37", Vector2i(4, 3), 30, 30, 5, 2, 2, RANGED, [], "我方远程"),
		_u(P, "hero_23", Vector2i(0, 4), 20, 20, 6, 3, 1, MELEE, [], "敌A"),
		_u(P, "hero_26", Vector2i(0, 3), 20, 20, 6, 3, 1, MELEE, [], "敌B"),
	], "buff": { Vector2i(5, 4): "atk", Vector2i(5, 3): "heal" } })
	out.append({ "name": "S15 远距离(够不到任何人)",
		"targets": ["ENGAGE_PULL_PER_CELL"], "descs": [
		_u(E, "hero_25", Vector2i(0, 4), 40, 40, 8, 3, 1, MELEE, [], "我方战锤"),
		_u(E, "hero_37", Vector2i(0, 2), 30, 30, 5, 2, 2, RANGED, [], "我方远程"),
		_u(P, "hero_23", Vector2i(5, 4), 20, 20, 6, 3, 1, MELEE, [], "敌A"),
		_u(P, "hero_26", Vector2i(5, 2), 20, 20, 6, 3, 1, MELEE, [], "敌B"),
	] })
	out.append({ "name": "S16 障碍封路(必须绕)",
		"targets": ["OBSTACLE_DETOUR_WEIGHT"], "descs": [
		_u(E, "hero_25", Vector2i(0, 2), 40, 40, 8, 3, 1, MELEE, [], "我方战锤"),
		_u(P, "hero_22", Vector2i(5, 2), 25, 25, 4, 3, 1, MELEE, [], "敌核心"),
	], "obs": { Vector2i(1, 2): true, Vector2i(2, 2): true, Vector2i(3, 2): true, Vector2i(4, 2): true } })

	# —— 身价族 ——
	out.append({ "name": "S17 高身价 vs 低身价(都可打)",
		"targets": ["VALUE_SOLO_W", "PLAYER_VALUE_MULT", "VALUE_RELATION_W"], "descs": [
		_u(E, "hero_25", Vector2i(2, 4), 40, 40, 10, 3, 1, MELEE, [], "我方战锤"),
		_u(P, "hero_22", Vector2i(2, 3), 12, 30, 4, 3, 1, MELEE, [], "敌核心(身价高)"),
		_u(P, "hero_13", Vector2i(3, 3), 12, 40, 3, 3, 1, MELEE, [], "敌肉盾(身价低)"),
	] })
	out.append({ "name": "S18 配合加成影响打谁",
		"targets": ["VALUE_RELATION_W", "VALUE_SOLO_W"], "descs": [
		_u(E, "hero_25", Vector2i(2, 4), 40, 40, 10, 3, 1, MELEE, [], "我方战锤"),
		_u(P, "hero_22", Vector2i(2, 3), 12, 30, 4, 3, 1, MELEE, [], "敌圣光(与塔盾有配合)"),
		_u(P, "hero_11", Vector2i(4, 3), 30, 40, 3, 3, 1, MELEE, [], "敌塔盾"),
		_u(P, "hero_31", Vector2i(3, 3), 12, 18, 4, 3, 2, RANGED, [], "敌末日"),
	] })

	# —— 算力 / 候选数 ——
	out.append({ "name": "S19 开阔地(候选多)",
		"targets": ["MAX_MOVE_OPTIONS", "BEAM"], "descs": [
		_u(E, "hero_25", Vector2i(0, 4), 40, 40, 8, 4, 1, MELEE, [], "我方A"),
		_u(E, "hero_37", Vector2i(0, 2), 30, 30, 5, 3, 2, RANGED, [], "我方B"),
		_u(E, "hero_13", Vector2i(0, 0), 45, 45, 3, 3, 1, MELEE, [], "我方C"),
		_u(P, "hero_23", Vector2i(5, 4), 20, 20, 6, 3, 1, MELEE, [], "敌A"),
		_u(P, "hero_26", Vector2i(5, 2), 20, 20, 6, 3, 1, MELEE, [], "敌B"),
		_u(P, "hero_31", Vector2i(5, 0), 18, 18, 4, 3, 2, RANGED, [], "敌C"),
	] })

	# —— 血量汇率 ——
	out.append({ "name": "S20 打残血 vs 打满血(换血账)",
		"targets": ["HP_VALUE_W", "FOCUS_FIRE_WEIGHT"], "descs": [
		_u(E, "hero_25", Vector2i(2, 4), 40, 40, 8, 3, 1, MELEE, [], "我方战锤"),
		_u(P, "hero_31", Vector2i(2, 3), 1, 18, 4, 3, 2, RANGED, [], "敌远程(1血)"),
		_u(P, "hero_22", Vector2i(3, 3), 30, 30, 4, 3, 1, MELEE, [], "敌核心(30血)"),
	] })
	return out

# ===================== 局面（手工合成，覆盖各类评分项） =====================
func _u(fn: int, hero: String, cell: Vector2i, hp: int, max_hp: int, atk: int, mv: int,
		rng: int, typ: int, skills: Array, nm: String, extra: Dictionary = {}) -> Dictionary:
	var d := {
		"fn": fn, "hero": hero, "cell": cell, "hp": hp, "max_hp": max_hp,
		"atk": atk, "eatk": atk, "move": mv, "emove": mv,
		"atk_range": rng, "atk_type": typ, "skills": skills, "name": nm,
	}
	for k in extra.keys():
		d[k] = extra[k]
	return d

func _positions() -> Array:
	var E := DataRegistry.Faction.ENEMY
	var P := DataRegistry.Faction.PLAYER
	var MELEE := int(DataRegistry.AttackType.MELEE)
	var RANGED := int(DataRegistry.AttackType.RANGED)
	var out: Array = []

	# ① 近战贴脸 · 两个目标血量不同（考验 HP 汇率 / 集火 / 击杀）
	out.append({ "name": "①贴脸双目标", "descs": [
		_u(E, "hero_25", Vector2i(2, 3), 40, 40, 10, 3, 1, MELEE, [], "我方战锤"),
		_u(P, "hero_13", Vector2i(2, 2), 10, 40, 3, 3, 1, MELEE, [DataRegistry.Skill.TAUNT], "肉盾"),
		_u(P, "hero_22", Vector2i(3, 3), 9, 30, 4, 3, 1, MELEE, [], "核心"),
	] })

	# ② 远程卡位（远程被贴身只有 1 伤 → 逼它选位置）
	out.append({ "name": "②远程卡位", "descs": [
		_u(E, "hero_37", Vector2i(0, 4), 30, 30, 5, 2, 2, RANGED, [], "我方远程"),
		_u(P, "hero_23", Vector2i(2, 2), 20, 20, 5, 3, 1, MELEE, [], "敌近战A"),
		_u(P, "hero_26", Vector2i(3, 4), 20, 20, 5, 3, 1, MELEE, [], "敌近战B"),
		_u(P, "hero_31", Vector2i(4, 3), 18, 18, 4, 3, 2, RANGED, [], "敌远程"),
	] })

	# ③ 开局远距离（考验"够不着就压上"）
	out.append({ "name": "③远距离开局", "descs": [
		_u(E, "hero_25", Vector2i(0, 0), 40, 40, 8, 3, 1, MELEE, [], "我方A"),
		_u(E, "hero_37", Vector2i(0, 2), 30, 30, 5, 2, 2, RANGED, [], "我方B"),
		_u(E, "hero_13", Vector2i(0, 4), 45, 45, 3, 3, 1, MELEE, [DataRegistry.Skill.TAUNT], "我方C"),
		_u(P, "hero_23", Vector2i(5, 0), 20, 20, 5, 3, 1, MELEE, [], "敌A"),
		_u(P, "hero_26", Vector2i(5, 2), 20, 20, 5, 3, 1, MELEE, [], "敌B"),
		_u(P, "hero_31", Vector2i(5, 4), 18, 18, 4, 3, 2, RANGED, [], "敌C"),
	] })

	# ④ 增益道具（考验"绕路去吃"）
	out.append({ "name": "④道具格", "descs": [
		_u(E, "hero_25", Vector2i(1, 3), 40, 40, 8, 3, 1, MELEE, [], "我方战锤"),
		_u(E, "hero_37", Vector2i(1, 1), 30, 30, 5, 2, 2, RANGED, [], "我方远程"),
		_u(P, "hero_23", Vector2i(4, 3), 20, 20, 5, 3, 1, MELEE, [], "敌A"),
		_u(P, "hero_26", Vector2i(4, 1), 20, 20, 5, 3, 1, MELEE, [], "敌B"),
	], "buff": { Vector2i(2, 4): "atk", Vector2i(1, 0): "shield", Vector2i(2, 0): "heal" } })

	# ⑤ 金矿 + 矿工（`can_pickup_gold` 专属；通用键在这里主要考验"绕不绕"）
	out.append({ "name": "⑤金矿", "descs": [
		_u(E, "hero_42", Vector2i(1, 2), 30, 30, 3, 3, 1, MELEE, [], "我方矿工", { "can_pickup_gold": true }),
		_u(E, "hero_25", Vector2i(1, 4), 40, 40, 8, 3, 1, MELEE, [], "我方战锤"),
		_u(P, "hero_23", Vector2i(4, 2), 20, 20, 5, 3, 1, MELEE, [], "敌A"),
		_u(P, "hero_26", Vector2i(4, 4), 20, 20, 5, 3, 1, MELEE, [], "敌B"),
	], "gold": { Vector2i(0, 1): true, Vector2i(3, 1): true } })

	# ⑥ 障碍封路（考验拆墙/绕路代价）
	out.append({ "name": "⑥障碍", "descs": [
		_u(E, "hero_25", Vector2i(1, 2), 40, 40, 8, 3, 1, MELEE, [], "我方战锤"),
		_u(P, "hero_22", Vector2i(5, 2), 25, 25, 4, 3, 1, MELEE, [], "敌核心"),
	], "obs": { Vector2i(2, 2): true, Vector2i(3, 2): true, Vector2i(4, 2): true } })

	# ⑦ 我方残血 · 有阵亡风险（SELF_DEATH / 威胁）
	out.append({ "name": "⑦我方残血", "descs": [
		_u(E, "hero_37", Vector2i(2, 2), 2, 30, 5, 2, 2, RANGED, [], "我方残血远程"),
		_u(E, "hero_25", Vector2i(1, 3), 40, 40, 8, 3, 1, MELEE, [], "我方战锤"),
		_u(P, "hero_23", Vector2i(2, 3), 20, 20, 8, 3, 1, MELEE, [], "敌近战A"),
		_u(P, "hero_26", Vector2i(3, 1), 20, 20, 8, 3, 1, MELEE, [], "敌近战B"),
	], "bombs": { Vector2i(2, 4): true, Vector2i(0, 4): true } })

	# ⑧ 一击必杀（击杀奖励 / 集火）
	out.append({ "name": "⑧可一击必杀", "descs": [
		_u(E, "hero_25", Vector2i(2, 4), 40, 40, 10, 3, 1, MELEE, [], "我方战锤A"),
		_u(E, "hero_26", Vector2i(3, 4), 20, 20, 6, 3, 1, MELEE, [], "我方战锤B"),
		_u(P, "hero_22", Vector2i(2, 3), 8, 30, 4, 3, 1, MELEE, [], "敌核心(8血)"),
		_u(P, "hero_31", Vector2i(3, 3), 6, 18, 4, 3, 2, RANGED, [], "敌远程(6血)"),
	] })

	# ⑨ 集火 vs 分摊（同一目标叠伤害的凸性奖励）
	out.append({ "name": "⑨集火分摊", "descs": [
		_u(E, "hero_25", Vector2i(2, 4), 40, 40, 6, 3, 1, MELEE, [], "我方A"),
		_u(E, "hero_26", Vector2i(3, 4), 20, 20, 6, 3, 1, MELEE, [], "我方B"),
		_u(E, "hero_23", Vector2i(4, 4), 20, 20, 6, 3, 1, MELEE, [], "我方C"),
		_u(P, "hero_22", Vector2i(2, 3), 12, 30, 4, 3, 1, MELEE, [], "敌核心(12血)"),
		_u(P, "hero_31", Vector2i(4, 3), 10, 18, 4, 3, 2, RANGED, [], "敌远程(10血)"),
	] })

	# ⑩ 被控敌人（受控折减两个键）
	out.append({ "name": "⑩被控敌人", "descs": [
		_u(E, "hero_25", Vector2i(2, 4), 40, 40, 10, 3, 1, MELEE, [], "我方战锤"),
		_u(P, "hero_22", Vector2i(2, 3), 10, 30, 4, 3, 1, MELEE, [], "敌核心(眩晕)", { "stunned": true }),
		_u(P, "hero_31", Vector2i(3, 3), 10, 18, 4, 3, 2, RANGED, [], "敌远程(沉默)", { "silenced": true }),
	] })

	# ⑪ 挨打威胁（威胁血点 / 会被打掉）
	out.append({ "name": "⑪挨打威胁", "descs": [
		_u(E, "hero_37", Vector2i(2, 2), 8, 30, 5, 2, 2, RANGED, [], "我方远程(8血)"),
		_u(E, "hero_25", Vector2i(1, 2), 40, 40, 8, 3, 1, MELEE, [], "我方战锤"),
		_u(P, "hero_23", Vector2i(2, 4), 20, 20, 6, 3, 1, MELEE, [], "敌近战A"),
		_u(P, "hero_26", Vector2i(3, 4), 20, 20, 6, 3, 1, MELEE, [], "敌近战B"),
		_u(P, "hero_31", Vector2i(0, 4), 18, 18, 4, 3, 3, RANGED, [], "敌远程"),
	] })

	# ⑫ 坦克替核心挡刀（嘲讽 + 塔盾代扛的位置价值）
	out.append({ "name": "⑫坦克挡刀", "descs": [
		_u(E, "hero_13", Vector2i(2, 3), 45, 45, 3, 3, 1, MELEE, [DataRegistry.Skill.TAUNT], "我方坦克"),
		_u(E, "hero_22", Vector2i(1, 3), 12, 30, 4, 3, 1, MELEE, [], "我方核心(12血)"),
		_u(P, "hero_23", Vector2i(3, 3), 20, 20, 7, 3, 1, MELEE, [], "敌近战A"),
		_u(P, "hero_26", Vector2i(2, 1), 20, 20, 7, 3, 1, MELEE, [], "敌近战B"),
	] })
	return out

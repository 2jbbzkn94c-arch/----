extends Node
## ⚠️⚠️【2026-09-20 已废弃·不要再跑】**本探针测的那条链已经整块删除**：它直接调 `ai._incoming_damage_on()`
##   （引擎内 0 个调用者）与位移威胁一族（`_incoming_plain` / `_nova_threat_at` / `_displace_standing_cells` /
##   `_displace_landing_cell` / `DISPLACE_THREAT_W` / `DISPLACE_HEROES`）—— 用户 2026-09-20 拍板「要」（删）
##   ⇒ 这些函数在 `src/BattleAI.gd` / fork 里都不存在了，**本探针现在跑起来会报 `Nonexistent function`**。
##   保留文件只为**存档当时的读数**（`RL/reports/暗域威胁_原始输出.txt`）；要看现役口径请用
##   `RL/probe/敏感度.gd`（`order` / `ablate` / `actdiff` 三个模式）。
## ⚠️ 教训（写在最前面防复发）：历史上"`DISPLACE_THREAT_W` 键是活的"的结论，就是**本探针直接调用那个函数**
##   得出的 —— 而函数在 AI 的决策路径上**没有任何调用点** ⇒ 探针里的"活"≠ AI 会用。**判断键活性必须看
##   决策路径的调用点，不能只看探针能不能调通。**

## 暗域威胁探针（**只读型决策探针**，只新增文件、不改任何既有文件）——量一件事：
##   **AI 在做落点决策时，认不认得「站在暗域(hero_27)旁边会被换位」这个技能威胁？**
##
## 背景（逐条读代码确认，出处写在下面，不凭感觉）：
##   · 机制：`heroes/hero_27_暗域.gd::on_attack` → `battle._swap_units(unit, target)`
##     = 「攻击时和对象交换位置」（`on_attack_dead` = 目标死亡时占据其格）。
##     模拟侧对应 `src/BattleAI.gd:2388`：`if u.hero_id == "hero_27": _sim_swap_cells(sim, u, t)`。
##   · 后果：AI 单位只要**停在与暗域相邻的格子上**，玩家回合让暗域打它一下，它就被**免费换进玩家阵中**
##     （换位不花行动、紧跟在暗域那次普攻之后），随后被暗域周围那两个队友围杀。
##   · AI 的"下回合会被打多少" = `src/BattleAI.gd:4218 _incoming_damage_on()`：逐敌人累加**一次普攻**
##     （`_threat_hit_value` 基本就是 `eatk`，需要动一步的按 `THREAT_MOVE_DISCOUNT` 折算），
##     里面**没有任何技能/位移技能**。落点评分链条 = `_evaluate → _threat_forecast(4083) → _incoming_damage_on`。
##     ⇒ 预期：**换位这笔账在 AI 的落点评分里根本不存在**。
##
## 怎么量（不写"标准答案"，只做**同盘面 A/B/C/D 对照**）：
##   四个变体的**站位、血量、攻击、移动力、英雄身价全部逐字段相同**，唯一变量是
##   **中军那个玩家的英雄 id**（hero_27 暗域 / hero_26 陪练）。连身价都等值，是为了排除"打谁更值钱"。
##   ⇒ 若 AI 认得威胁：换掉 hero_27 之后它的走位选择**应当改变**。
##     若 C 与 D 的计划**逐字节相同**：它不但没避开，连"这个英雄有技能"都没进决策。
##
## 每条配置另打印两个"实际挨打"量（都用引擎自己的模拟算，不另写公式）：
##   `inc_land` = 落点上 `_incoming_damage_on` 之和 == **AI 自己以为的危险度**（换位之前）
##   `inc_swap` = 把"玩家那一回合最优一手（含暗域换位）"贪心推演一遍后，其实会挨多少
##   `d_inc`    = 两者之差 == **AI 看不见的那部分**（换位白送的刀）
##   `esc_inc@换位格` = 被换到的那个格子上，敌方（AI 方）合计能打它多少 —— 用来判断这个变体
##                      "换过去到底亏不亏"（探针自己给的判决依据，不靠肉眼）
##
## 运行：
##   godot --headless --path <项目> --scene res://RL/probe/暗域威胁.tscn -- [beam] [rollout]
##   缺省 beam=200（= 生产困难/噩梦宽度）· rollout=0（关掉推演层，只量评分层、且可复现）
##   `time_budget_ms = 0` ⇒ 不靠墙钟兜底 ⇒ 同一输入必然同一输出。
##
## 输出：`DY|…` 每行一条；末尾 `DY|SUM|…` 汇总；同时落盘 `RL/reports/暗域威胁_原始输出.txt`。

const FORK := preload("res://RL/ai/AI_Battle.gd")
const NM_PATH := "res://RL/weights/噩梦.json"

## 配置：唯一变量是"末端推演层 / 生产口径"（键见 `RL/weights/噩梦.json`）。
##   `base`   = 只用评分层（关掉推演层与规则 B）—— 探针主口径，直接量"评分层认不认得暗域"
##   `ro32`   = 连噩梦的推演层一起开（ROLLOUT_TOPK=32 / MODE=1）—— 看它能不能补救
##   `mad1`   = **生产噩梦口径**（推演层 + `MOVE_ACCEPT_DAMAGE=1`）：规则 B 会把"危险落点"往外挤
##              ⇒ 用来确认"AI 不躲暗域"在真实档位下也成立（而不是被探针的关阈值放大了）
const CONFIGS := [
	{ "name": "base", "rollout": 0, "mad": 0.0 },
	{ "name": "ro32", "rollout": 32, "mad": 0.0 },
	{ "name": "mad1", "rollout": 32, "mad": 1.0 },
]

var _grid: HexGrid
var _nm: Dictionary = {}
var _lines: Array = []

func _ready() -> void:
	_line("DY|BOOT")
	_grid = HexGrid.new()
	_grid.width = 8
	_grid.height = 6
	_run.call_deferred()

func _run() -> void:
	var ua := OS.get_cmdline_user_args()
	var beam := int(ua[0]) if ua.size() > 0 else 200
	var roll_arg := int(ua[1]) if ua.size() > 1 else 0
	_nm = _load_json(NM_PATH)
	var scen: Array = _scenarios()
	_line("DY|CFG|scenarios=%d|configs=%d|beam=%d|rollout_arg=%d|fork_sha=%s|nm_keys=%d|nm_roll=%s|nm_mad=%s|nm_term=%s" % [
		scen.size(), CONFIGS.size(), beam, roll_arg, _sha("res://RL/ai/AI_Battle.gd"),
		_nm.size(), str(_nm.get("ROLLOUT_TOPK", "(缺)")), str(_nm.get("MOVE_ACCEPT_DAMAGE", "(缺)")),
		str(_nm.get("TERMINAL_W", "(缺)"))])
	var n_reach := 0
	var n_adj := {}
	var plans := {}
	for cfg in CONFIGS:
		n_adj[String(cfg["name"])] = 0
	for s in scen:
		_line("DY|SCEN|%s|%s" % [String(s["name"]), String(s["note"])])
		_line("DY|SCEN|%s|MAP|%s" % [String(s["name"]), _map_text(s)])
		_line("DY|SCEN|%s|CHECK|d_x0_dark=%d|d_x0_bait=%d|d_dark_bait=%d|pairs=%d|land_near_mid=%d|ok=%s|land_cells=%s|esc_cells=%s" % [
			String(s["name"]), int(s["d_atk"]), int(s["d_bait"]), int(s["d_dark_bait"]),
			int(s["adj_ally_pair"]), int(s["bait_near"]), "YES" if bool(s["ok"]) else "NO",
			str(s["land_cells"]), str(s["esc_cells"])])
		for cfg in CONFIGS:
			var cn := String(cfg["name"])
			var r := _one(s, cfg, beam, roll_arg)
			var tag := "DY|ROW|%s|%s" % [String(s["name"]), cn]
			_line("%s|steps=%d|chose_adj_dark=%s|end_adj_dark=%s|end=%s|chose_adj_plain=%s|inc_land=%.2f|inc_swap=%.2f|d_inc=%+.2f|esc_inc_swapcell=%.2f|score=%.2f|margin=%.2f" % [
				tag, int(r["steps"]), str(r["adj_dark"]), str(r["adj_end"]), str(r["end_cell"]),
				str(r["adj_plain"]),
				float(r["inc_land"]), float(r["inc_swap"]), float(r["inc_swap"]) - float(r["inc_land"]),
				float(r["esc_inc_swapcell"]), float(r["score"]), float(r["margin"])])
			_line("%s|X0可选落点危险度%s" % [tag, _cells_brief(s, r["ranked"])])
			for ln in r["plan_lines"]:
				_line("%s|%s" % [tag, String(ln)])
			plans["%s|%s" % [String(s["name"]), cn]] = String(r["fp"])
			plans["%s|%s|x0" % [String(s["name"]), cn]] = String(r["x0_fp"])
			if bool(r["adj_dark"]):
				n_adj[cn] = int(n_adj[cn]) + 1
			if bool(r["dark_in_reach"]):
				n_reach += 1
	# 主对照：C(普通单位) vs D(hero_27)，同盘面同数值。
	# 除了整条计划，还单独比"出击者那一手"——计划里还有别的单位，整体不同不足以说明问题
	# （也可能整体不同、而那一手恰好相同 ⇒ 那就说明它其实没在区分暗域）。
	# ⚠️ 两个变体的英雄**身价**不同（hero_27 vs hero_26）⇒ 打分必然不同，所以 `DIFF` 本身不是结论；
	#    真正的判据是**出击者的落点与所打的目标是否相同**（= 它有没有因为"对面是暗域"而改变选择）。
	for cfg in CONFIGS:
		var cn2 := String(cfg["name"])
		var all_same := String(plans.get("C普通对照|%s|x0" % cn2, "")) == String(plans.get("D暗域贴脸|%s|x0" % cn2, ""))
		var whole_same := String(plans.get("C普通对照|%s" % cn2, "")) == String(plans.get("D暗域贴脸|%s" % cn2, ""))
		_line("DY|CTRL|%s|整条计划=%s|出击者那一手=%s|C=%s|D=%s" % [
			cn2, "SAME" if whole_same else "DIFF", "SAME" if all_same else "DIFF",
			String(plans.get("C普通对照|%s|x0" % cn2, "")), String(plans.get("D暗域贴脸|%s|x0" % cn2, ""))])
	_selfdiag(beam)
	var sum := ""
	for cfg in CONFIGS:
		sum += "|%s_chose_adj_dark=%d" % [String(cfg["name"]), int(n_adj[String(cfg["name"])])]
	_line("DY|SUM|scenarios=%d|configs=%d%s|dark_in_reach=%d" % [
		scen.size(), CONFIGS.size(), sum, n_reach])
	_line("DY|END")
	_dump()
	get_tree().quit(0)

# ---------------------------------------------------------------- 权重 / 单次决策

## 组装一次注入用的权重：噩梦基线（噩梦.json）+ BEAM。
## ⚠️ `MOVE_ACCEPT_DAMAGE`（规则 B 落点阈值）在 `base`/`ro32` 里**置 0 = 关**：那一项会把"危险落点"
##    直接挤出候选表前 16 名，掩盖"评分层认不认得暗域"这件事。`mad1` 保留噩梦原值（= 生产口径）。
func _build_weights(cfg: Dictionary, beam: int, roll_arg: int) -> Dictionary:
	var w := { "BEAM": beam }
	for k in _nm.keys():
		if String(k).begins_with("_"):
			continue                     # `_说明` 之类的注释字段不是键
		w[k] = _nm[k]
	var mad := float(cfg.get("mad", -1.0))
	w["MOVE_ACCEPT_DAMAGE"] = float(_nm.get("MOVE_ACCEPT_DAMAGE", 1.0)) if mad < 0.0 else mad
	var ro := int(cfg.get("rollout", 0))
	if ro <= 0:
		w["ROLLOUT_TOPK"] = 0
		w["ROLLOUT_MODE"] = 0
	else:
		w["ROLLOUT_TOPK"] = roll_arg if roll_arg > 0 else ro
		w["ROLLOUT_MODE"] = int(_nm.get("ROLLOUT_MODE", 1))
	return w

## 跑一个（场景 × 配置）：出计划 + 逐步评分 + 实际挨打
func _one(s: Dictionary, cfg: Dictionary, beam: int, roll_arg: int) -> Dictionary:
	var ai = FORK.new(_grid)
	ai.difficulty = 2
	ai.log_decisions = false
	ai.time_budget_ms = 0                 # 可复现：不用墙钟兜底
	ai.set_weights(_build_weights(cfg, beam, roll_arg))
	var sim = ai.build_state(s["descs"], s["occ"])
	var plan: Array = ai.search(sim, DataRegistry.Faction.ENEMY)
	var x0 = sim.units[int(s["atk_idx"])]
	var dark = sim.units[int(s["dark_idx"])]
	var plain = sim.units[int(s["plain_idx"])]
	# ⚠️ 暗域/杂兵的**出招前位置**要先记下来：下面每执行一步计划，它们自己也会移动，
	#    用移动后的 cell 去判"X0 是否停在暗域旁边"会算错（第一版就踩了这个坑）。
	var dark0: Vector2i = dark.cell
	var plain0: Vector2i = plain.cell
	var x0_cell0: Vector2i = x0.cell
	var land_dark: Array = []
	var land_plain: Array = []
	for c in ai._move_cells(sim, x0).keys():
		if _adjacent(c, dark0):
			land_dark.append(c)
		if _adjacent(c, plain0):
			land_plain.append(c)
	var dark_in_reach := land_dark.size() > 0 or _adjacent(x0_cell0, dark0)
	# X0 每个可达落点的"AI 以为的危险度"（复原 `_actions_for` 的排序键，便于看它眼里的地形）
	var ranked: Array = []
	for c in ai._move_cells(sim, x0).keys():
		ranked.append({ "c": c, "thr": float(ai._incoming_damage(sim, c, x0.fn)),
			"d": int(ai.approach_dist(sim, c, dark.cell)) })
	ranked.sort_custom(func(a, b):
		if a["thr"] != b["thr"]:
			return float(a["thr"]) < float(b["thr"])
		return int(a["d"]) < int(b["d"]))
	var fin = sim
	var lines: Array = []
	var n := 0
	var adj_dark := false
	var adj_plain := false
	var inc_land := 0.0
	var best1 := -INF
	var best2 := -INF
	var x0_fp := ""
	for st in plan:
		var idx := int(st.get("idx", -1))
		if idx < 0 or idx >= fin.units.size():
			continue
		var u = fin.units[idx]
		if u == null or not u.alive:
			continue
		var a: Dictionary = st.get("action", {})
		var mv = a.get("move", null)
		var land: Vector2i = u.cell if mv == null else Vector2i(mv)
		var atk := int(a.get("atk", -99))
		var c = fin.clone()
		ai._apply(c, idx, a)
		var sc := float(ai._evaluate(c))
		if sc > best1:
			best2 = best1
			best1 = sc
		elif sc > best2:
			best2 = sc
		var inc := float(ai._incoming_damage_on(fin, u))
		inc_land += inc
		var is_d := (idx == int(s["atk_idx"])) and _adjacent(land, dark0)
		var is_p := (idx == int(s["atk_idx"])) and _adjacent(land, plain0)
		if is_d:
			adj_dark = true
		if is_p:
			adj_plain = true
		lines.append("step%d|%s|move=%s|atk=%s|land=%s|score=%.2f|inc_land=%.2f|adj_dark=%s|adj_plain=%s" % [
			n, String(u.name), _v(mv), _uname(fin, atk), str(land), sc, inc, str(is_d), str(is_p)])
		if idx == int(s["atk_idx"]):
			x0_fp = "move=%s|atk=%s|land=%s|inc_land=%.2f|score=%.2f" % [
				_v(mv), _uname(fin, atk), str(land), inc, sc]
		n += 1
		ai._apply(fin, idx, a)             # 推进计划（与 `决策损失.gd` 同口径）
	# 被换到的格子上，AI 方能打它多少（判断"换过去亏不亏"）+ 换位后实际挨打
	var inc_swap := 0.0
	var swap_cell := Vector2i(-9, -9)
	var esc_inc := 0.0
	var sw := _swap_probe(ai, fin, int(s["dark_idx"]), int(s["atk_idx"]))
	if bool(sw["swapped"]):
		inc_swap = float(sw["inc"])
		swap_cell = sw["cell"]
		esc_inc = float(sw["esc_inc"])
	# 计划走完之后，出击者**实际停在哪**、离暗域（起始格）多远 —— 这是最直观的那条判据
	var x0_end = fin.units[int(s["atk_idx"])]
	var x0_end_cell: Vector2i = x0.cell if x0_end == null else x0_end.cell
	return { "steps": n, "plan_lines": lines, "adj_dark": adj_dark, "adj_plain": adj_plain,
		"inc_land": inc_land, "inc_swap": inc_swap, "esc_inc_swapcell": esc_inc,
		"dark_in_reach": dark_in_reach, "ranked": ranked,
		"end_cell": x0_end_cell, "adj_end": _adjacent(x0_end_cell, dark0),
		"score": float(ai._evaluate(fin)), "margin": (best1 - best2) if best2 > -INF else 0.0,
		"fp": ">".join(lines), "x0_fp": x0_fp }

## 玩家最优一手（含暗域换位）→ 被换过去的那个 AI 单位实际会挨多少。
## 口径与 AI 自己那把尺子**同一个函数**（`_incoming_damage_on`）⇒ 两个数可以直接比。
func _swap_probe(ai, sim, dark_idx: int, atk_idx: int) -> Dictionary:
	var out := { "swapped": false, "inc": 0.0, "esc_inc": 0.0, "cell": Vector2i(-9, -9), "why": "" }
	var dark = sim.units[dark_idx]
	var victim = sim.units[atk_idx]
	if dark == null or victim == null:
		out["why"] = "no_unit"
		return out
	if not dark.alive:
		out["why"] = "dark_dead"
		return out
	if not victim.alive:
		out["why"] = "victim_dead"
		return out
	# 先确认"暗域这一手真能打到它"（拿候选表验，不靠猜）
	var can_hit := false
	for a in ai._actions_for(sim, dark_idx):
		if int(a.get("atk", -99)) == atk_idx:
			var mc = a.get("move", null)
			var c2: Vector2i = dark.cell if mc == null else Vector2i(mc)
			if _adjacent(c2, victim.cell):
				can_hit = true
				break
	if not can_hit:
		out["why"] = "dark_cannot_reach"
		return out
	var cur = sim
	var order: Array = []
	for i in cur.units.size():
		var q = cur.units[i]
		if q != null and q.alive and q.fn == DataRegistry.Faction.PLAYER and not q.attacked:
			order.append(i)
	for idx in order:
		var u = cur.units[idx]
		if u == null or not u.alive:
			continue
		var best_a := { "move": null, "atk": -1 }
		var best_v := INF
		for a in ai._actions_for(cur, idx):
			var c3 = cur.clone()
			ai._apply(c3, idx, a)
			var v := float(ai._evaluate(c3))
			if v < best_v:
				best_v = v
				best_a = a
		var c4 = cur.clone()
		ai._apply(c4, idx, best_a)
		cur = c4
	var v2 = cur.units[atk_idx]
	out["swapped"] = true
	if v2 != null:
		out["cell"] = v2.cell
		# 它被换到的那个格子上：AI 方合计能打它多少（用同一族 `_threat_*` 算子反向量）
		out["esc_inc"] = float(_outgoing_from_sim(ai, cur, v2))
		if v2.alive:
			out["inc"] = float(ai._incoming_damage_on(cur, v2))
	return out

## `_incoming_damage_on` 算"对面打我"；这里反过来算"我（AI 方）能围它多少"。
## 直接用引擎同一族的 `_threat_can_reach` + `_threat_hit_value`，不另立公式。
func _outgoing_from_sim(ai, sim, target) -> float:
	var total := 0.0
	for i in sim.units.size():
		var a = sim.units[i]
		if a == null or not a.alive or a.fn == target.fn:
			continue
		var d: int = ai.walk_dist(sim, target.cell, a.cell)
		if not bool(ai._threat_can_reach(sim, a, d)):
			continue
		if not bool(ai._taunt_allows(sim, a, target)):
			continue
		total += float(ai._threat_hit_value(sim, a, d))
	return total

## 自我诊断：手工把"暗域打一下 → 换位"跑一遍，证明换位在这个盘面里**真的触发**（别让"没触发"伪装成"避开了"）
func _selfdiag(beam: int) -> void:
	var s: Dictionary = (_scenarios() as Array)[1]     # 取 B（暗域+两名侍卫）
	var ai = FORK.new(_grid)
	ai.difficulty = 2
	ai.log_decisions = false
	ai.time_budget_ms = 0
	ai.set_weights(_build_weights({ "rollout": 0 }, beam, 0))
	var sim = ai.build_state(s["descs"], s["occ"])
	var di := int(s["dark_idx"])
	var xi := int(s["atk_idx"])
	var x = sim.units[xi]
	var dark = sim.units[di]
	var naive0 := float(ai._incoming_damage(sim, x.cell, x.fn))
	# ① 手工把 X0 挪到"贴着中军"的那个落点（不依赖 AI 自己选什么）
	var land: Vector2i = s["land_cells"][0]
	var ok_move := false
	for c in ai._move_cells(sim, x).keys():
		if Vector2i(c) == land:
			ok_move = true
			break
	ai._apply(sim, xi, { "move": land, "atk": -1 })
	var naive1 := float(ai._incoming_damage(sim, x.cell, x.fn))
	var naive_on := float(ai._incoming_damage_on(sim, x))
	# ② 中军原地攻击 X0（相邻 ⇒ 应当换位）
	var can_hit := false
	for a in ai._actions_for(sim, di):
		if int(a.get("atk", -99)) == xi:
			can_hit = true
			break
	var x_before: Vector2i = x.cell
	var d_before: Vector2i = dark.cell
	ai._apply(sim, di, { "move": null, "atk": xi })
	var fired := false
	if x.cell != x_before and x.cell == d_before:
		fired = true
	var post_inc := 0.0
	if x.alive:
		post_inc = float(ai._incoming_damage_on(sim, x))
	var esc := float(_outgoing_from_sim(ai, sim, x))
	_line("DY|DIAG|land_reachable=%s|naive_at_spawn=%.2f|naive_at_land=%.2f|naive_on_target=%.2f|land=%s|dark=%s|can_dark_hit=%s|after_swap_x=%s|after_swap_dark=%s|swap_fired=%s|post_swap_inc_on_x=%.2f|ai_side_hit_on_x=%.2f|x_hp=%d" % [
		str(ok_move), naive0, naive1, naive_on, str(x_before), str(d_before), str(can_hit),
		str(x.cell), str(dark.cell), str(fired), post_inc, esc, int(x.hp)])

# ---------------------------------------------------------------- 盘面

## 四个变体：**站位/血量/攻击/移动力/英雄身价逐字段相同**，唯一变量 = 中军那个玩家的英雄 id。
## 设计约束（写在这里防复发）：
##   ① 两个可选目标必须**数值完全相同**（血量/攻击/身价），否则 AI 选谁只是在算身价，
##      量不到"威胁"这件事 —— 所以连英雄都刻意挑同一身价档。
##   ② 中军(4,3)必须**被自己人夹住**（侍卫(3,3)+(5,3)），否则"换进去被围杀"不成立。
##   ③ 关键几何（第三版，前两版踩过坑）：AI 主攻 X0 出生在 **(6,1)**，与中军(4,3) 距离 3 ⇒ 它**没有**
##      一开始就贴着暗域。本回合它能打到的落点只有两个 —— (6,2) 打杂兵(5,4) / (4,2) 打中军；
##      而**只有 (4,2) 挨着中军** ⇒ 走那条路必须自己踏进暗域的换位格。
##      杂兵摆在 X0 出生点**相反的一侧**：否则 AI 只会去够更近的杂兵、压根走不到暗域旁边，
##      就问不出"它认不认得暗域"（第一版 (1,2)、第二版 (3,4) 都是这个毛病）。
##   ④ 中军与杂兵都必须**本回合可达**（`d_x0_dark`/`d_x0_bait` 每行打印自校验）。
##   ⑤ A 变体 = 中军**孤立**（没有侍卫）：换过去其实不亏 ⇒ 反面对照，守住"别为了躲而躲"。
##   ⑥ C/D 是同盘面同数值的**主对照**（唯一差别 = 中军 hero_27 vs hero_26）⇒ 出击者那一手是否
##      逐字节相同就是答案（`CTRL` 行）。
func _scenarios() -> Array:
	var E := DataRegistry.Faction.ENEMY
	var P := DataRegistry.Faction.PLAYER
	var ML := int(DataRegistry.AttackType.MELEE)
	var out: Array = []
	var esc_pairs := [Vector2i(3, 3), Vector2i(5, 3)]
	var mid := Vector2i(4, 3)
	var bait := Vector2i(5, 4)                # 只挨着 (6,2) 那一侧：把 AI 往"躲开暗域"的方向拉
	var land_cells := [Vector2i(6, 2), Vector2i(4, 2)]   # 出击者的两个"能打人"的落点
	var defs := [
		{ "name": "A暗域孤立", "dark": "hero_27", "plain": "hero_26", "esc": false,
			"note": "中军=暗域(hero_27)、**没有侍卫**：被换过去其实不亏 ⇒ 期望照打（反面对照）" },
		{ "name": "B暗域被夹击", "dark": "hero_27", "plain": "hero_26", "esc": true,
			"note": "中军=暗域、侍卫(3,3)+(5,3)夹住 ⇒ 被换进去会被围杀（威胁真实存在）" },
		{ "name": "C普通对照", "dark": "hero_26", "plain": "hero_26", "esc": true,
			"note": "把 hero_27 换成普通单位，位置数值全不动 ⇒ 与 D 的主对照" },
		{ "name": "D暗域贴脸", "dark": "hero_27", "plain": "hero_26", "esc": true,
			"note": "与 C 同盘面同数值，唯一差别 = 中军是 hero_27 ⇒ **C vs D 是本探针的主对照**" },
	]
	for cfg in defs:
		var descs: Array = []
		# AI 方：X0(6,1) 主攻(移动4) · X1(2,1) 助攻(移动3)
		# X0 出生点**不挨着中军**（距离 3）⇒ "贴上去"是它自己走出来的（第一版出生在 (5,2)、
		# 一开始就相邻 ⇒ 那条量不到"它是否选择走过去"）。
		descs.append(_u(E, "hero_26", Vector2i(6, 1), 30, 30, 5, 4, 1, ML, [], "X0主攻"))
		descs.append(_u(E, "hero_26", Vector2i(2, 1), 30, 30, 5, 3, 1, ML, [], "X1助攻"))
		# 玩家方：中军(4,3) · 侍卫(3,3)(5,3) · 杂兵(5,4)——中军=descs[2]、杂兵=最后一个
		descs.append(_u(P, String(cfg["dark"]), mid, 30, 30, 4, 2, 1, ML, [], "中军"))
		if bool(cfg["esc"]):
			descs.append(_u(P, "hero_26", esc_pairs[0], 30, 30, 4, 2, 1, ML, [], "侍卫甲"))
			descs.append(_u(P, "hero_26", esc_pairs[1], 30, 30, 4, 3, 1, ML, [], "侍卫乙"))
		descs.append(_u(P, String(cfg["plain"]), bait, 30, 30, 4, 3, 1, ML, [], "杂兵"))
		var occ := _occ(descs)
		var x0c: Vector2i = descs[0]["cell"]
		var dark_c: Vector2i = descs[2]["cell"]
		var bait_c: Vector2i = descs[descs.size() - 1]["cell"]
		var pair := 0
		for i in descs.size():
			for j in range(i + 1, descs.size()):
				if int(descs[i]["fn"]) == P and int(descs[j]["fn"]) == P \
						and _grid.distance(Vector2i(descs[i]["cell"]), Vector2i(descs[j]["cell"])) == 1:
					pair += 1
		var d_atk: int = _grid.distance(x0c, dark_c)
		var d_bait: int = _grid.distance(x0c, bait_c)
		# 自校验：两个落点里**恰好一个**挨着中军、另一个不挨；两个落点也各自"打得着一个目标"
		var near_mid := 0
		for c in land_cells:
			if _grid.distance(Vector2i(c), dark_c) == 1:
				near_mid += 1
		out.append({ "name": String(cfg["name"]), "note": String(cfg["note"]),
			"descs": descs, "occ": occ, "dark_idx": 2, "plain_idx": descs.size() - 1, "atk_idx": 0,
			"d_atk": d_atk, "d_bait": d_bait, "d_dark_bait": _grid.distance(dark_c, bait_c),
			"adj_ally_pair": pair, "land_cells": land_cells, "esc_cells": esc_pairs, "bait_near": near_mid,
			"ok": (d_atk <= 6 and d_bait <= 6 and near_mid == 1 and pair >= (2 if bool(cfg["esc"]) else 0)) })
	return out

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

func _occ(descs: Array) -> Dictionary:
	var o := {}
	for i in descs.size():
		o[descs[i]["cell"]] = i
	return o

# ---------------------------------------------------------------- 小工具

func _adjacent(a: Vector2i, b: Vector2i) -> bool:
	return _grid.distance(a, b) == 1

func _uname(sim, idx: int) -> String:
	if idx < 0 or idx >= sim.units.size():
		return "无"
	var t = sim.units[idx]
	if t == null:
		return "无"
	return "%s#%d(hp%d,atk%d)" % [String(t.name), idx, int(t.hp), int(t.eatk)]

func _v(mv) -> String:
	return "原地" if mv == null else str(mv)

## 把"X0 全部可达落点"整理成一眼能读的一行：先按危险度分档，再逐个标出两个关键落点。
## 为什么要它：AI 的落点取舍**全部**来自 `_incoming_damage`（`_actions_for` 的排序键 + `_threat_forecast`），
## 所以这张表就是"它眼里的地形"。表里 (6,2)（不挨暗域）与 (4,2)（挨暗域）谁更危险，
## 直接决定它愿不愿意走过去贴暗域 —— 这一行就是那条判据的原始数字。
func _cells_brief(s: Dictionary, ranked: Array) -> String:
	if ranked.is_empty():
		return "(无可达落点)"
	var lo := 1.0e9
	var hi := -1.0
	for p in ranked:
		lo = minf(lo, float(p["thr"]))
		hi = maxf(hi, float(p["thr"]))
	var safe := 0
	for p in ranked:
		if float(p["thr"]) <= lo + 1.0e-6:
			safe += 1
	var out := "可达%d个|最小危险%.2f|最大危险%.2f|并列最安全%d个" % [ranked.size(), lo, hi, safe]
	var dark_cell: Vector2i = Vector2i(s["descs"][int(s["dark_idx"])]["cell"])
	for c in s["land_cells"]:
		var cc: Vector2i = c
		var v := -1.0
		for p in ranked:
			if Vector2i(p["c"]) == cc:
				v = float(p["thr"])
				break
		out += "|落点%s(挨暗域=%s,d暗域=%d,该格危险=%.2f)" % [
			str(cc), str(_grid.distance(cc, dark_cell) == 1), _grid.distance(cc, dark_cell), v]
	return out

## 紧凑棋盘（只标下标+阵营+英雄尾号）：0/1 我方、2 中军、3/4 侍卫、末位杂兵
func _map_text(s: Dictionary) -> String:
	var descs: Array = s["descs"]
	var rows: Array = []
	for y in _grid.height:
		var row := "%d|" % y
		for x in _grid.width:
			var c := Vector2i(x, y)
			var found := -1
			for i in descs.size():
				if Vector2i(descs[i]["cell"]) == c:
					found = i
					break
			if found < 0:
				row += " .. "
			else:
				var d: Dictionary = descs[found]
				var mark := "我" if int(d["fn"]) == DataRegistry.Faction.ENEMY else "敌"
				row += " %s%d%s " % [mark, found, String(d["hero"]).substr(5)]
		rows.append(row)
	var head := "  |"
	for x in _grid.width:
		head += " %d  " % x
	rows.append(head)
	return " ‖ ".join(rows)

func _line(t: String) -> void:
	print(t)
	_lines.append(t)

func _load_json(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		_line("DY|WARN|读不到 %s ⇒ 噩梦基线为空" % path)
		return {}
	var txt := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(txt)
	if typeof(parsed) != TYPE_DICTIONARY:
		_line("DY|WARN|%s 解析失败" % path)
		return {}
	return parsed

func _sha(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return "nofile"
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(f.get_buffer(f.get_length()))
	f.close()
	return ctx.finish().hex_encode().substr(0, 12)

## 原始输出落盘（与 stdout 逐行一致，留档用）
func _dump() -> void:
	var dir := "res://RL/reports"
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open("res://RL/reports/暗域威胁_原始输出.txt", FileAccess.WRITE)
	if f == null:
		print("DY|WARN|落盘失败")
		return
	for ln in _lines:
		f.store_line(String(ln))
	f.close()

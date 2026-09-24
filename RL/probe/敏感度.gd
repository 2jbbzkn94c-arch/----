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
	# 【已删 2026-09-19（用户同意）】`FOCUS_TIMES_WEIGHT` / `w_focus_times` 整项从引擎删除 ⇒
	#   本表必须移除它：留着会在 `ai.w_focus_times = …` 处运行时炸（变量已不存在）。
	"HP_VALUE_W": "w_hp_value",
	# 【已删 2026-09-20】JITTER / w_jitter 连抖动机制一起从引擎删除（低档改由 WEAK_* 承担难度）。
	"OBSTACLE_DETOUR_WEIGHT": "w_obstacle_detour",
	"THREAT_DEAD_FOLD": "w_threat_dead_fold",
	# 【已删 2026-09-20】THREAT_INCOMING_W 随 ⑦ 合并整条删除（逐单位线性挨打血点）。
	"THREAT_MOVE_DISCOUNT": "w_threat_discount",
	# ---- 2026-09-18/19 新增的机制键（默认关）----
	# 【2026-09-21 恢复·用户拍板 A】RISK_W / RISK_CORE_POW（⑦位置暴露）回来了（输入 =「挨打合计」）⇒
	#   本表要跟着加回，否则 `ablate` 模式无法拆这两键。
	"RISK_W": "w_risk",
	"RISK_CORE_POW": "w_risk_core_pow",
	"INCOMING_POOL_W": "w_incoming_pool",
	# 【已删 2026-09-20】REPLY_TOPK / REPLY_W（对手最优反击一层）实测无效果（rp4 −0.45 / rp8 +1.74，CI 跨 0）⇒ 连代码删除。
	"TERMINAL_W": "w_terminal",
	# ---- 2026-09-19 并列裁决层（主杠杆）----
	"TIEBREAK_MODE": "w_tiebreak_mode",
	"TIEBREAK_EPS": "w_tiebreak_eps",
	# ---- 【2026-09-21 新增】两项"队形"评分：⑳抱团（孤立罚）/ ㉑退路被夹；默认 0 = 关 ----
	"FORM_COHESION_W": "w_form_cohesion",
	"FORM_ESCAPE_W": "w_form_escape",
	# 【2026-09-22 新增】㉓离队距离（⑳ 的每格梯度，`w_form_spread`）：默认 0 = 关。
	"FORM_SPREAD_CELL_W": "w_form_spread",
	# ---- 【2026-09-21 新增】治疗计价（③回血侧）与 附体计价（⑬宿魂）----
	#   ⚠️ `POSSESS_TARGET_W` 真实读取走 `_wh()`（按**施加者英雄段**覆盖）⇒ 这里注入的是**扁平兜底值**；
	#   噩梦档 `hero_46` 段是空的 ⇒ 兜底值就是实际生效值 ✓（要测"打开有没有用"正是这一条）。
	"HEAL_CREDIT_W": "w_heal_credit",
	"POSSESS_TARGET_W": "w_possess_target",
	# ============ 【2026-09-24 补齐】2026-09-21 之后新增 / 历史上漏收的键 ============
	# 口径：**本表应恒等于 `set_weights` 里的扁平键全集**（现在 45 个）；`INT_KEYS` 恒等于其中
	#   `int(v)` 转型的那 14 个。漏收的后果**不是报错**，而是 `ablate` / `order` / `actdiff`
	#   **静默测不到那个键** —— 看起来像"这个键没用"，其实是探针根本没动它。
	# ⚠️ **英雄段覆盖（`_wh()`）**：下面这些都**按英雄段覆盖**读 ——
	#   `POISON_TICK_VALUE` / `POISON_APPLY_W` / `SOLID_HOLD_W` / `SILENCE_VALUE_W` /
	#   `THORN_PIN_SUP_W` / `THORN_PIN_RANGED_W` / `PARALYZE_ZERO_W` / `POSSESS_TARGET_W`（连同上方的
	#   `POSSESS_TARGET_W`）。`_wh(hero_id, key, 扁平兜底)` 的语义是**段里有值就用段里的**
	#   ⇒ 本表注入的只是**扁平兜底值**：只有当"那个英雄没写这个键 / 查不到施加者"时才生效。
	#   例：`噩梦.json` 的 `hero_03` 段写着 `POISON_TICK_VALUE 2.5` ⇒ 在这里把 `w_poison_tick` 设 0
	#   **不会**让毒蛇铺的毒变 0 分（2026-09-24 跑 T25 批时正是在这里栽的跟头、整批作废重跑）。
	#   要给这类键做剂量，得用"剥掉英雄段的测试基线"（见 `RL/weights/噩梦_测毒.json`）。
	"POISON_TICK_VALUE": "w_poison_tick",
	"POISON_MAX_TICKS": "w_poison_max_ticks",     # 不按英雄段覆盖 ⇒ 注入即生效
	"POISON_APPLY_W": "w_poison_apply",
	"SOLID_HOLD_W": "w_solid_hold",
	"SILENCE_VALUE_W": "w_silence",
	"THORN_PIN_SUP_W": "w_pin_sup",
	"THORN_PIN_RANGED_W": "w_pin_ranged",
	"PARALYZE_ZERO_W": "w_paralyze",
	"SPLIT_W": "w_split",
	"FORM_MERGE_MODE": "w_form_merge",
	"SHIELD_BREAK_W": "w_shield_break",
	"TAUNT_SOAK_W": "w_taunt_soak",
	"IDLE_HIT_PENALTY": "w_idle_hit_penalty",
	"STAY_OPTION": "w_stay_option",
	# 【2026-09-24·用户拍板「A」】⑥ 的罚也按血量池折算（1 = 开；见 `src/BattleAI.gd` 的 `const MOVE_ACCEPT_POOL`）。
	"MOVE_ACCEPT_POOL": "w_move_accept_pool",
	"MOVE_ACCEPT_DAMAGE": "w_move_accept_damage",
	"SUB_JOIN_RULE": "w_sub_join_rule",
	"SUB_FINISH_W": "w_sub_finish_w",
	"NO_LOSS_FILTER": "w_no_loss_filter",
	"GOLD_OPPORTUNITY_W": "w_gold_oc",
	"ENGAGE_PULL_PER_CELL": "w_engage_pull",
	"WEAK_MODE": "w_weak_mode",
	"WEAK_P": "w_weak_p",
	"WEAK_SEED": "w_weak_seed",
	# ⚠️ 注入 **0 = 不限时** ⇒ 会撞上 `search()` 那个已知收敛隐患（空动作表死循环，见 §1.3）⇒ 别设 0。
	"TIME_BUDGET_MS": "time_budget_ms",
	# ⚠️ 搜索结构三键只在 `SEARCH_MODE >= 1` 的路径上有意义（模式 0 根本不经过两阶段搜索）。
	"SEARCH_MODE": "w_search_mode",
	"TWO_PHASE_P1_BEAM": "w_tp_p1_beam",
	"TWO_PHASE_DEDUP": "w_tp_dedup",
	# 【2026-09-24·用户拍板「改」】召唤物的阶段 1 候选集（1 = 只走"能打到人的格"；见 `src/BattleAI.gd` 的
	#   `const SUMMON_SLOT_ONLY` 处三处铁证：骷髅兵本方回合结束即消散 ⇒ 不能借此攻击的落点价值恒 0）。
	"SUMMON_SLOT_ONLY": "w_summon_slot_only",
}

# 【2026-09-24 补齐】= `set_weights` 里 `int(v)` 转型的**全部 14 个**键（数量不对 = 有键漏了或类型变了）。
const INT_KEYS := ["BEAM", "TIME_BUDGET_MS", "MOVE_ACCEPT_DAMAGE", "MOVE_ACCEPT_POOL", "SUB_JOIN_RULE", "WEAK_MODE", "WEAK_SEED",
	"NO_LOSS_FILTER", "TIEBREAK_MODE", "POISON_MAX_TICKS", "STAY_OPTION", "FORM_MERGE_MODE", "SEARCH_MODE",
	"TWO_PHASE_P1_BEAM", "TWO_PHASE_DEDUP", "SUMMON_SLOT_ONLY"]
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
	# 【2026-09-20 新增】第 4 个参数 = 棋盘口径："real" ⇒ 用生产的 5×7 + 顶帽(1,3)；缺省 = 探针历史上的 6×5。
	var board := String(ua[3]) if ua.size() > 3 else "probe"
	if board == "real":
		_grid.width = 5
		_grid.height = 7
		_grid.top_cap_cols = [1, 3]
	var positions: Array = _positions()
	if mode == "rand" or mode == "ladder":
		positions = _rand_positions(int(ua[2]) if ua.size() > 2 else 60)
	elif mode == "ladderhand":
		positions = _positions()   # 人工局面里有"能一击必杀/集火/威胁"等**定向场景**，用于补覆盖
	elif mode == "scen":
		positions = _scenarios()   # 每个键专属的定向场景（覆盖优先）
	elif mode == "ablate":
		# 【2026-09-20 新增·用户要求】"噩梦那一堆键到底有没有用" ⇒ 只在**删键消融**里回答（见 `_ablate`）。
		# 【2026-09-20 扩展】随机局面**+ 人工定向局面**：专属键（毒/坚固/金矿）在随机盘面上命中率极低
		#   （实测 12 随机局面里 ⑯ 命中 0 次）⇒ 不补定向局面就会把它们误判成死键。
		positions = _rand_positions(int(ua[2]) if ua.size() > 2 else 24) + _positions()
	elif mode == "actdiff":
		# 【2026-09-20 新增·T6 活性验证】**动作级**键敏感度（见 `_actdiff`）：
		#   `40 actdiff <hero_id 或 -> <KEY> <值>` ⇒ 对每个定向局面的第一个我方单位的**每个候选动作**
		#   各打一次分（不走整盘搜索）⇒ 直接看到"这个键给哪些动作加/减了多少钱、有没有改首选"。
		#   为什么需要它：`ablate` 的 dscore 是**初始局面**的分（⑯/⑭ 这类**动作后**才产生的项恒为 0），
		#   而 order_rate 只回答"改不改整盘出招" ⇒ 键**活着但不够大**时会被误判成死键。
		positions = _positions()
	if mode == "order":
		# 【2026-09-20 新增·用户提问】把整盘计划的**行动顺序**打出来（含"动手那一刻的攻击力"），
		# 用来回答"AI 认不认本回合内攻击力的变化（锤头鲨见证加成 / 麻痹降攻 / 冲锋涨攻…）"。
		positions = _positions()
	if mode == "order":
		# 【2026-09-20 新增可选参数】`ua[4]` = `KEY=值`：临时覆盖噩梦基线里那一个键（其余键一字不动）。
		#   用途：把「fork 同步后行为有没有变」拆成两半 —— 覆盖 `MOVE_ACCEPT_DAMAGE=0` 跑一遍，
		#   若与**旧 fork 同覆盖**的结果逐行相同 ⇒ 证明被删的 8 个键/威胁合并确实逐位不变，
		#   差异全部来自 ⑥ 的口径改动（而不是删键）。
		var ov := (String(ua[4]) if ua.size() > 4 else "")
		_plan_orders(positions, beam, ov)
		get_tree().quit(0)
		return
	if mode == "actdiff":
		print("AD|ARGS|" + str(OS.get_cmdline_user_args()))
		if ua.size() < 5:
			print("AD|FATAL|用法：<beam> actdiff <hero_id|-> <KEY> <值>")
			get_tree().quit(1)
			return
		_actdiff(positions, beam, str(ua[2]), str(ua[3]), float(ua[4]))
		get_tree().quit(0)
		return
	if mode == "ablate":
		_ablate(positions, beam)
		get_tree().quit(0)
		return
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
		threat = float(ai._incoming_total_on(sim, sim.units[idx], sim.units[idx].cell))   # 【2026-09-20】旧 `_incoming_damage_on` 已随位移威胁一族删除 ⇒ 改用按目标求和的现役尺子
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
## 【2026-09-20 新增·用户要求】ablate 模式：**逐个键做"删掉它"的消融**。
## 口径：基线 = **完整 `RL/weights/噩梦.json`**；每个键 = 同一份权重**去掉那一行**（其余键一字不动）
##   ⇒ 引擎默认值接管（= 这一行"白写了没有"）。比较三件事：
##     ① `_evaluate(初始局面)` 的分数差（分数敏感度）
##     ② `search()` 的首选计划 / 无序集合 / 第一步 是否改变（整盘出招敏感度）
##     ③ 首个我方单位的**最优动作**是否改变（局部出招敏感度，最灵敏的一档）
##   ⇒ **三项全 0 = 这个键在采样局面里从不改出招**（死键）；>0 才谈得上"有用"，量级再看棋力批。
## ⚠️ 它只回答"改不改出招"，不回答"改了之后是变强还是变弱"（后者必须跑对局）。
const NIGHTMARE_PATH := "res://RL/weights/噩梦.json"

func _load_flat_weights(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("读不到权重文件: " + path)
		return {}
	var txt := f.get_as_text()
	f.close()
	var j = JSON.parse_string(txt)
	if typeof(j) != TYPE_DICTIONARY:
		push_error("权重文件不是字典: " + path)
		return {}
	var out := {}
	for k in (j as Dictionary).keys():
		if String(k).begins_with("_"):
			continue                      # 说明段（`_xxx`）不注入
		out[String(k)] = j[k]
	return out

func _ablate(positions: Array, beam: int) -> void:
	var w := _load_flat_weights(NIGHTMARE_PATH)
	if w.is_empty():
		print("ABL|FATAL|权重为空")
		return
	print("ABL|CFG|keys=%d|positions=%d|beam=%d|board=%dx%d|fork_sha=%s|w_sha=%s" % [
		w.size(), positions.size(), beam, _grid.width, _grid.height,
		_sha("res://RL/ai/AI_Battle.gd"), _sha(NIGHTMARE_PATH)])
	print("ABL|KEYS|" + ",".join(w.keys()))
	# ⚠️ 必须显式注入 BEAM：探针一贯口径是"用 CLI 给的 beam"，而噩梦权重表里**没有** `BEAM` 这一行 ⇒
	#   不注入就会回落到引擎默认 200（再叠加噩梦档开着的 `ROLLOUT_TOPK=32` 推演层 ⇒ 单次 search 慢上千倍，
	#   第一次跑就是这么超时的）。这里把 `inject_base` 当公共底，消融时只删"文件里真的有的那一行"。
	var inject_base: Dictionary = w.duplicate()
	inject_base["BEAM"] = beam
	# 【2026-09-20 扩展·用户要求"毒/宿魂/坚固 都要能看到数值与活性"】消融目标 = 顶层扁平键 **+ `hero_XX` 段里的每个子键**。
	#   为什么必须拆到子键：`hero_03` 段一删就是"毒值 + 上毒动作钱"两键一起消失 ⇒ 分不清是哪个键在起作用。
	#   子键的消融口径 = **把它置 0**（不是删段），这样英雄段里其它键照旧生效，单变量。
	var targets: Array = []
	for k in w.keys():
		var key := String(k)
		if typeof(w[key]) == TYPE_DICTIONARY:
			for sk in (w[key] as Dictionary).keys():
				targets.append({ "label": "%s|%s" % [key, String(sk)],
						"kind": "hero", "key": key, "sub": String(sk), "val": (w[key] as Dictionary)[sk] })
		else:
			targets.append({ "label": key, "kind": "flat", "key": key, "val": w[key] })
	print("ABL|TARGETS|flat=%d|hero=%d|total=%d" % [
		_count_kind(targets, "flat"), _count_kind(targets, "hero"), targets.size()])
	# 基线 = 完整噩梦
	var base := {}
	var lbase := {}
	for pos in positions:
		var nm := String(pos["name"])
		base[nm] = _one(pos, inject_base)
		lbase[nm] = _local(pos, inject_base)
	# 逐键：删掉那一行（英雄子键 = 置 0）
	for t in targets:
		var inj: Dictionary = inject_base.duplicate(true)
		if String(t["kind"]) == "flat":
			inj.erase(String(t["key"]))
		else:
			var sub: Dictionary = (inj[String(t["key"])] as Dictionary).duplicate()
			sub[String(t["sub"])] = 0.0
			inj[String(t["key"])] = sub
		var n_order := 0
		var n_set := 0
		var n_first := 0
		var n_local := 0
		var dsum := 0.0
		var dmax := 0.0
		for pos in positions:
			var nm := String(pos["name"])
			var r := _one(pos, inj)
			var b: Dictionary = base[nm]
			var d: float = absf(float(r["score"]) - float(b["score"]))
			dsum += d
			dmax = maxf(dmax, d)
			n_order += int(String(r["fp"]) != String(b["fp"]))
			n_set += int(String(r["setfp"]) != String(b["setfp"]))
			n_first += int(String(r["firstfp"]) != String(b["firstfp"]))
			var l := _local(pos, inj)
			var l0: Dictionary = lbase[nm]
			n_local += int(String(l["fp"]) != String(l0["fp"]))
		var n := float(positions.size())
		print("ABL|ROW|%s|v=%s|dscore_mean=%.3f|dscore_max=%.3f|order_rate=%.2f|set_rate=%.2f|first_rate=%.2f|local_rate=%.2f" % [
			String(t["label"]), str(t["val"]), dsum / n, dmax,
			float(n_order) / n, float(n_set) / n, float(n_first) / n, float(n_local) / n])
	print("ABL|END")

## 【2026-09-20 新增·用户提问】把整盘计划的**行动顺序**打印出来 —— 每一步显示"谁、什么动作、
## **动手那一刻的有效攻击力**、打完之后谁涨/掉了多少攻"。用来回答"AI 认不认本回合内的攻击力变化"。
func _plan_orders(positions: Array, beam: int, override: String = "") -> void:
	var w: Dictionary = _load_flat_weights(NIGHTMARE_PATH)
	w["BEAM"] = beam
	if override != "":
		var kv := override.split("=")
		if kv.size() == 2:
			w[kv[0]] = float(kv[1])
	print("PO|CFG|positions=%d|beam=%d|override=%s|fork_sha=%s|w_sha=%s" % [
		positions.size(), beam, override, _sha("res://RL/ai/AI_Battle.gd"), _sha(NIGHTMARE_PATH)])
	for pos in positions:
		var ai = _mk_ai(w)
		var sim = _mk_sim(ai, pos)
		var plan: Array = ai.search(sim, DataRegistry.Faction.ENEMY)
		print("PO|POS|%s|steps=%d" % [str(pos["name"]), plan.size()])
		var c = sim.clone()
		var step := 0
		for s in plan:
			step += 1
			var idx := int(s.get("idx", -1))
			var a: Dictionary = s.get("action", {})
			if idx < 0 or idx >= c.units.size():
				continue
			var u = c.units[idx]
			var before := {}
			for v in c.units:
				if v != null and v.alive:
					before[v.sim_index] = v.eatk
			ai._apply(c, idx, a)
			var bumps: Array = []
			for v2 in c.units:
				if v2 == null:
					continue
				var e0 := int(before.get(v2.sim_index, v2.eatk))
				if v2.eatk != e0:
					bumps.append("%s%+d" % [str(v2.name), int(v2.eatk) - e0])
			print("PO|STEP|%d|%s(%s) eatk=%d|move=%s atk=%d|变化=%s" % [
				step, str(u.name), str(u.hero_id), int(before.get(idx, u.eatk)),
				str(a.get("move", null)), int(a.get("atk", -1)),
				(" ".join(bumps) if bumps.size() > 0 else "无")])
	print("PO|END")

func _count_kind(targets: Array, kind: String) -> int:
	var c := 0
	for t in targets:
		if String(t["kind"]) == kind:
			c += 1
	return c

## 【2026-09-20 新增·T6 活性验证】动作级键敏感度：**固定局面 + 两套权重（这个键 = 值 / = 0）**，
## 对第一个我方单位的每个候选动作各打一次分（`_score_of` = 应用这个动作后 `_evaluate` 一次，**不跑整盘搜索**）。
## 回答三件事：① 这个键给哪些动作加了多少钱（Δ 列）② 有没有改动"这个单位的最优动作"（changed）
## ③ 每个局面的最大 Δ（max_delta）。⇒ "键活着但还没大到能改决策"和"键根本是死的"能分开。
func _actdiff(positions: Array, beam: int, hero_id: String, key: String, val: float) -> void:
	var on: Dictionary = _load_flat_weights(NIGHTMARE_PATH)
	var off: Dictionary = _load_flat_weights(NIGHTMARE_PATH)
	if on.is_empty():
		print("AD|FATAL|权重为空")
		return
	on["BEAM"] = beam
	off["BEAM"] = beam
	if hero_id == "-":
		on[key] = val
		off[key] = 0.0
	else:
		var so: Dictionary = (on.get(hero_id, {}) as Dictionary).duplicate()
		so[key] = val
		on[hero_id] = so
		var sf: Dictionary = (off.get(hero_id, {}) as Dictionary).duplicate()
		sf[key] = 0.0
		off[hero_id] = sf
	print("AD|CFG|hero=%s|key=%s|val=%s|positions=%d|beam=%d|fork_sha=%s|w_sha=%s" % [
		hero_id, key, str(val), positions.size(), beam, _sha("res://RL/ai/AI_Battle.gd"), _sha(NIGHTMARE_PATH)])
	# 【自检】两臂的"按英雄覆盖"字典到底装进去了没有（`w_hero` 形如 `hero_48|SOLID_HOLD_W`）
	var ai_chk_on = _mk_ai(on)
	var ai_chk_off = _mk_ai(off)
	print("AD|WH|on=%s||off=%s" % [str(ai_chk_on.w_hero), str(ai_chk_off.w_hero)])
	var n_changed := 0
	var n_fired := 0
	var max_delta_all := 0.0
	for pos in positions:
		var ai_on = _mk_ai(on)
		var ai_off = _mk_ai(off)
		var sim_on = _mk_sim(ai_on, pos)
		var sim_off = _mk_sim(ai_off, pos)
		var idx := _first_enemy(sim_on)
		if idx < 0:
			continue
		# 把 off 权重下同一批动作按指纹对齐（两个 AI 的候选表可能因这个键本身而不同）
		var off_scores := {}
		for b in ai_off._actions_for(sim_off, idx):
			off_scores[_act_fp(b)] = _score_of(ai_off, sim_off, idx, b)
		var best_on := ""
		var best_off := ""
		var s_on := -1e30
		var s_off := -1e30
		var diffs: Array = []
		var max_delta := 0.0
		var n_act := 0
		for a in ai_on._actions_for(sim_on, idx):
			var fp := _act_fp(a)
			if not off_scores.has(fp):
				continue
			n_act += 1
			var v_on := _score_of(ai_on, sim_on, idx, a)
			var v_off := float(off_scores[fp])
			if v_on > s_on:
				s_on = v_on
				best_on = fp
			if v_off > s_off:
				s_off = v_off
				best_off = fp
			var dd := v_on - v_off
			if absf(dd) > max_delta:
				max_delta = absf(dd)
			if absf(dd) >= 0.01:
				var act := "移动"
				if int(a.get("atk", -1)) >= 0:
					act = "攻击"
				diffs.append("%s[%s]%+.2f" % [fp.substr(0, 24), act, dd])
		var changed := best_on != best_off
		if changed:
			n_changed += 1
		if max_delta >= 0.01:
			n_fired += 1
		max_delta_all = maxf(max_delta_all, max_delta)
		# 【诊断】把"原地不动"那个动作（`<null>:-1:<null>`；不在候选里就跳过）的**逐项拆解**打出来
		# ⇒ 直接看到 ⑭坚固 / ⑯猛毒新挂 / ⑧道具 这类"动作后才产生"的项到底有没有钱。
		var stay_fp := "<null>:-1:<null>"
		var a_stay: Variant = null
		for a2 in ai_on._actions_for(sim_on, idx):
			if _act_fp(a2) == stay_fp:
				a_stay = a2
				break
		var brk := ""
		if a_stay != null:
			var c_on = sim_on.clone()
			ai_on._apply(c_on, idx, a_stay)
			var c_off = sim_off.clone()
			ai_off._apply(c_off, idx, a_stay)
			var d_on: Dictionary = ai_on._eval_breakdown(c_on)
			var d_off: Dictionary = ai_off._eval_breakdown(c_off)
			var bp: Array = []
			for kk in d_on.keys():
				var vv := float(d_on[kk]) - float(d_off.get(kk, 0.0))
				if absf(vv) >= 0.005:
					bp.append("%s%+.2f" % [str(kk), vv])
			brk = "stay项Δ[%s]" % (" ".join(bp) if bp.size() > 0 else "全 0")
		else:
			brk = "stay动作不在候选表"
		print("AD|BREAK|%s|%s" % [str(pos["name"]), brk])
		print("AD|POS|%s|unit=%s|n=%d|maxΔ=%.2f|changed=%s|best_off=%s|best_on=%s|diffs=%s" % [
			String(pos["name"]), String(sim_on.units[idx].name), n_act, max_delta, str(changed),
			best_off.substr(0, 26), best_on.substr(0, 26), " ".join(diffs)])
	var np := float(positions.size())
	print("AD|SUM|fired_rate=%.2f|changed_rate=%.2f|maxΔ_any=%.2f" % [
		float(n_fired) / np, float(n_changed) / np, max_delta_all])
	print("AD|END")

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
		"targets": ["FOCUS_FIRE_WEIGHT", "KILL_BONUS"], "descs": [
		_u(E, "hero_25", Vector2i(1, 4), 40, 40, 8, 3, 1, MELEE, [], "我方A"),
		_u(E, "hero_26", Vector2i(2, 4), 20, 20, 8, 3, 1, MELEE, [], "我方B"),
		_u(E, "hero_23", Vector2i(3, 4), 20, 20, 8, 3, 1, MELEE, [], "我方C"),
		_u(P, "hero_22", Vector2i(2, 3), 20, 30, 4, 3, 1, MELEE, [], "敌核心(20血)"),
	] })

	# —— 集火族 ——
	out.append({ "name": "S04 集火 vs 分摊",
		"targets": ["FOCUS_FIRE_WEIGHT"], "descs": [
		_u(E, "hero_25", Vector2i(1, 4), 40, 40, 6, 3, 1, MELEE, [], "我方A"),
		_u(E, "hero_26", Vector2i(2, 4), 20, 20, 6, 3, 1, MELEE, [], "我方B"),
		_u(E, "hero_23", Vector2i(3, 4), 20, 20, 6, 3, 1, MELEE, [], "我方C"),
		_u(P, "hero_22", Vector2i(1, 3), 12, 30, 4, 3, 1, MELEE, [], "敌核心(12血)"),
		_u(P, "hero_31", Vector2i(3, 3), 12, 18, 4, 3, 2, RANGED, [], "敌远程(12血)"),
	] })
	# 【2026-09-19】S05 原目标 `FOCUS_TIMES_WEIGHT` 已整项删除 ⇒ 改测 `FOCUS_FIRE_WEIGHT`（frac²）：
	#   这个盘面（3 血一打就死 + 12 血核心）测的正是"第二击该压谁"，现在由 frac² 独家表达。
	out.append({ "name": "S05 集火第二击边际(frac²)",
		"targets": ["FOCUS_FIRE_WEIGHT"], "descs": [
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

	# ⑬ 【2026-09-20 新增·T6 专用】毒蛇上毒 vs 退开：**这一手到底"铺毒"值不值**
	#   为什么要有这一局：随机局面里"毒蛇正好站在没中毒的敌人旁边"的概率很低（12 随机局面实测命中 0 次）
	#   ⇒ ⑯`POISON_APPLY_W` 在 ablate 里一行全 0，看起来像死键。这里手工造一个**必触发**的局面，
	#   让 ⑯（以及 ⑫）至少在一个局面上有覆盖：毒蛇贴脸、目标**未中毒**，旁边还有个够不到的目标
	#   （= 有"跑过去再上一个人"的诱惑），同时毒蛇自己站在会被反击的位置（= 有"退开"的诱惑）。
	out.append({ "name": "⑬毒蛇上毒取舍", "descs": [
		_u(E, "hero_03", Vector2i(2, 4), 26, 26, 6, 3, 1, MELEE, [], "我方毒蛇"),
		_u(E, "hero_25", Vector2i(0, 4), 40, 40, 8, 3, 1, MELEE, [], "我方战锤"),
		_u(P, "hero_12", Vector2i(2, 3), 24, 24, 7, 3, 1, MELEE, [], "敌巨剑(未中毒)"),
		_u(P, "hero_31", Vector2i(4, 3), 18, 18, 5, 3, 2, RANGED, [], "敌远程(够不到)"),
	] })

	# ⑭ 【2026-09-20 新增·专属键覆盖】装甲堡垒"站着不动换[坚固]"：它没动 + 敌人在射程内 ⇒ ⑭ 该给钱。
	out.append({ "name": "⑭堡垒扎根取舍", "descs": [
		_u(E, "hero_48", Vector2i(2, 4), 30, 30, 5, 3, 1, MELEE, [], "我方堡垒"),
		_u(E, "hero_37", Vector2i(0, 4), 30, 30, 5, 2, 2, RANGED, [], "我方远程"),
		_u(P, "hero_23", Vector2i(2, 2), 20, 20, 7, 3, 1, MELEE, [], "敌近战(够得到堡垒)"),
		_u(P, "hero_26", Vector2i(4, 2), 20, 20, 7, 3, 1, MELEE, [], "敌近战B"),
	] })

	# ⑮ 【2026-09-20 新增·专属键覆盖】金矿 + 矿工：矿工那批键（GOLD_TAKE_VALUE / GOLD_NEAR）的覆盖局面。
	out.append({ "name": "⑮矿工吃矿取舍", "descs": [
		_u(E, "hero_42", Vector2i(2, 4), 24, 24, 4, 3, 1, MELEE, [], "我方矿工", { "can_pickup_gold": true }),
		_u(E, "hero_25", Vector2i(0, 4), 40, 40, 8, 3, 1, MELEE, [], "我方战锤"),
		_u(P, "hero_23", Vector2i(2, 2), 20, 20, 6, 3, 1, MELEE, [], "敌近战A"),
		_u(P, "hero_26", Vector2i(3, 3), 20, 20, 6, 3, 1, MELEE, [], "敌近战B"),
	], "gold": { Vector2i(1, 3): true, Vector2i(4, 4): true } })

	# ⑯ 【2026-09-20 新增·用户提问"AI 认不认攻击力变化 / 锤头鲨会不会最先就打了"】
	#   设计成**顺序可判**：锤头鲨吃 6 攻、敌方 B 血 7 ⇒ 只有"先让队友打伤一个敌人（锤头鲨 +1 攻）再打 B"
	#   才能一击杀；反过来先打 B 就只剩 1 血 ⇒ 少一次击杀（≈ 身价 22~26 + 集火 30 分）。
	#   队友（战锤）mv1/射程1 ⇒ 只够得到 A，够不到 B ⇒ 它没法替锤头鲨收尾。
	out.append({ "name": "⑯锤头鲨顺序(带加成)", "descs": [
		_u(E, "hero_37", Vector2i(2, 5), 30, 30, 6, 3, 1, MELEE, [], "我方锤头鲨"),
		_u(E, "hero_25", Vector2i(1, 4), 40, 40, 8, 1, 1, MELEE, [], "我方战锤(够不到B)"),
		_u(P, "hero_12", Vector2i(1, 3), 20, 20, 7, 3, 1, MELEE, [], "敌A(血20)"),
		_u(P, "hero_31", Vector2i(4, 4), 7, 7, 5, 3, 2, RANGED, [], "敌B(血7,只有鲨够得到)"),
	] })

	# ⑰ 对照：把锤头鲨换成一只**没有加成机制**的同属性单位 ⇒ 顺序偏好应当消失/变弱。
	out.append({ "name": "⑰锤头鲨对照(无加成)", "descs": [
		_u(E, "hero_26", Vector2i(2, 5), 30, 30, 6, 3, 1, MELEE, [], "我方雪拳(同属性,无加成)"),
		_u(E, "hero_25", Vector2i(1, 4), 40, 40, 8, 1, 1, MELEE, [], "我方战锤(够不到B)"),
		_u(P, "hero_12", Vector2i(1, 3), 20, 20, 7, 3, 1, MELEE, [], "敌A(血20)"),
		_u(P, "hero_31", Vector2i(4, 4), 7, 7, 5, 3, 2, RANGED, [], "敌B(血7,只有它够得到)"),
	] })

	return out

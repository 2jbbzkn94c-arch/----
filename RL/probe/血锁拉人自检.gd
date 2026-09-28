extends Node
## 【2026-09-28 一次性探针】用户报「血锁怎么不会拉人？只会贴着打」—— 要回答的是
##   **这是搜索问题还是定价问题**：AI 到底有没有把"站 2~3 格开钩"当成一个候选。
##
## 机制回顾（读代码得到的判据，探针就是来验它）：
##   · 血锁 hero_41 出生 `attack_range +2`（=3）、只能沿 6 条轴向直线攻击；`on_attack` 里
##     `Battle._pull_to()` 把目标拉到面前一格（**已贴身则不拉**）⇒ **拉人 = "从 2~3 格出手"的副作用**，
##     它不是一步可选动作。所以"会不会拉人"等价于"AI 会不会选距离 ≥2 的那条出手线"。
##   · 全引擎唯一能读到位移的地方是威胁估计 `_displace_landing_cells()`（L8433-8435）——那是**对手打我**；
##     我方自己拉人**没有任何评分项**（L1125 只有一行 `血锁钩爪开团` 注释，没有 `var`、没有读者）。
##
## 六个盘面（全部"血锁与目标在同一条轴上、中间留空"，否则拉人/直线都无从谈起）：
##   ① 独狼·距离3：能拉 vs 能走1格→贴身打 ‖ 末态分对照
##   ② 独狼·距离4：只有"走1格到3格"才够得着拉（走2格到2格也行）‖ 看它选哪条
##   ③ 独狼·距离2：拉与贴身**同一回合都可达**（走1格贴身 / 原地开钩）‖ 最干净的 A/B
##   ④ 带队友：队友**只有拉完那一格够得到**目标 ⇒ 拉人开团该被看见吗
##   ⑤ 有第二个敌人：拉进来会让自己多挨一刀（自己给自己加权暴露）⇒ 反向推力有多大
##   ⑥ 噩梦档全队搜索：血锁+两队友 vs 三敌人，直接看 search() 给出的招
## 输出：每行 `LOCK|...`，末尾 `LOCK|END`。
##
## 【2026-09-28 实测读数（噩梦权重 · fork 78d0129d1696）】—— 修正了上面那条"预期"：
##   ① A 原地开钩 Δ=**−1.481** vs B 走1格贴身打 Δ=**+0.519** ⇒ A−B = **−2.000**（AI 明确选贴身）
##      ⇒ 这 2 分**全部**来自 ㉑退路/被夹（`FORM_ESCAPE_W 2.0`）：拉完人后"敌人在邻格、队友不在"
##      ⇒ `esc = max(0, 2−可走邻格) + max(0, 邻敌−邻友)` 记 1 份 ⇒ **开着钩就等于"被夹住"**。
##   ③ 距离 2 时 A = B = −1.481（末态逐项字面同分）⇒ 定价体系对"拉"与"贴着打"**完全无偏好**。
##   ④ 带队友时 **A − B = +21.876**（B 把血锁拉到离队 3 格 ⇒ ㉓离队距离 −12 + ⑳抱团 −10）
##      ⇒ 拉不拉**只由队形尺**（⑳㉑㉓）决定，与"拉人本身值多少分"无关。
##   ⑤ 侧后有第二个敌人时 A = B = −1.538 ⇒ 依旧贴上去打。
##   ⑥ 全队盘面 `search()` 的两步**都是"从 3 格外出手"**（拉人）——但候选表里它分最低
##      （"走到(3,1)打巨剑→拉人" = −9.530，"走到(3,1)打影丸→贴身" = −7.473）⇒ 是队形/暴露账
##      把贴身线压下去的，不是拉人本身有分。
##   ⚠️ 附带发现（与拉人无关的读法）：㉑ 的第二半 `邻敌 − 邻友` 在**棋盘边缘**会失真 ——
##      目标贴边时（如目标在 (2,5)、板宽 5 列）"玩家站在它旁边"那一格是出界的 ⇒ 估方不把血锁
##      算成"邻敌"，A/B 因此差 2 分。这是"威胁站哪"与"相邻位置存不存在"混用，登记备查。

const FORK := preload("res://RL/ai/AI_Battle.gd")
const DmgModel := preload("res://src/DamageModel.gd")
const NIGHTMARE_PATH := "res://RL/weights/噩梦.json"
const MELEE := 0

var _grid: HexGrid
var _w: Dictionary = {}
## 【2026-09-28 剂量用】非空时 `_mk_ai()` 用它替换 `_w`（注入 `PULL_*` 那一族键做对照）。
var _dose: Dictionary = {}
var _logf: FileAccess = null

func _log(s: String) -> void:
	print(s)
	if _logf == null:
		_logf = FileAccess.open("res://.godot_userdata/_lock_probe.log", FileAccess.WRITE)
	if _logf != null:
		_logf.store_line(s)
		_logf.flush()

func _ready() -> void:
	_grid = HexGrid.new()
	_grid.width = 7
	_grid.height = 5
	_run.call_deferred()

func _run() -> void:
	_w = _load_flat_weights(NIGHTMARE_PATH)
	_log("LOCK|CFG|fork=%s|keys=%d|BEAM=%d|SEARCH_MODE=%d|ENGAGE_PULL_PER_CELL=%.2f|RISK_W=%.2f|MOVE_ACCEPT_DAMAGE=%d" % [
		_sha("res://RL/ai/AI_Battle.gd"), _w.size(), int(_w.get("BEAM", 0)), int(_w.get("SEARCH_MODE", 0)),
		float(_w.get("ENGAGE_PULL_PER_CELL", 0.0)), float(_w.get("RISK_W", 0.0)),
		int(_w.get("MOVE_ACCEPT_DAMAGE", 0))])
	_log("LOCK|CFG2|嬉皮死神(hero_30) 攻击类型=%s（0=近战 1=远程）" % str(DataRegistry.get_hero("hero_30").attack_type))
	_s1()
	_s2()
	_s3()
	_s4()
	_s5()
	_s6()
	_s7()
	_log("LOCK|END")
	get_tree().quit(0)

# ---------------- 盘面⑦：嬉皮死神协同（"拉出来落单"那一半的靶子） ----------------
## 摆位：血锁(2,2) · 目标(2,4) · 嬉皮死神(2,0)。
##   ① 嬉皮**当前够不到目标**（格距 4 > 移动2+射程2）⇒ 拉之前它只能打空气；
##   ② 血锁原地开钩 ⇒ 目标落到 (2,3) ⇒ 嬉皮从 (2,0) 走 1 格到 (2,1) 就能打（格距 2 ≤ 射程2）
##      且**拉完只有嬉皮与血锁在场上** ⇒ 目标**孤立** ⇒ `_sim_mult` 里 ×2 成立；
##   ③ 对照组 = 血锁走 1 格（(2,3)）贴身打 ⇒ 不拉 ⇒ 目标留在 (2,4)、格距 4 ⇒ 嬉皮够不到、也不孤立。
## 三个剂量：现役（㉗ 关，验证"基线仍然贴上去打"）· 只开包围 · 开包围+拉出来落单。
func _s7() -> void:
	_log("LOCK|⑦ 嬉皮协同：血锁(2,2) 目标(2,4) 嬉皮死神(2,0)——拉完目标回 (2,3) 落入嬉皮射程且孤立")
	var descs := [
		_lock(Vector2i(2, 2)),
		_foe("hero_12", Vector2i(2, 4), 24, 2, "巨剑(假想敌)"),
		_ally("hero_30", Vector2i(2, 0), 20, 3, "嬉皮死神(队友)"),
	]
	for dose in [
		{ "tag": "㉗ 关（现役默认）", "open": 0.0, "iso": 0.0 },
		{ "tag": "只开包围", "open": 1.2, "iso": 0.0 },
		{ "tag": "包围1.2 + 落单2.0", "open": 1.2, "iso": 2.0 },
		{ "tag": "包围1.2 + 落单6.0（剂量对照）", "open": 1.2, "iso": 6.0 },
	]:
		var w2: Dictionary = _w.duplicate()
		w2["PULL_OPEN_W"] = float(dose["open"])
		w2["PULL_ISOLATE_W"] = float(dose["iso"])
		_dose = w2
		var sim = _mk_sim(descs)
		var tag := "⑦[%s]" % str(dose["tag"])
		_cmp_end_states(sim, 0, 1, Vector2i(2, 3), tag)
		_run_search(sim, tag)
	_dose = {}
	# 对照 A：把嬉皮换成"不相关的队友"（面板一样，但没有孤立 ×2）⇒ 落单那一半必须恒 0
	_log("LOCK|⑦对照A 把嬉皮换成普通队友（无倍率）⇒ 应当看不到落单收益")
	var descs2 := [
		_lock(Vector2i(2, 2)),
		_foe("hero_12", Vector2i(2, 4), 24, 2, "巨剑(假想敌)"),
		_ally("hero_07", Vector2i(2, 0), 20, 3, "影丸(队友·无倍率)"),
	]
	var w3: Dictionary = _w.duplicate()
	w3["PULL_OPEN_W"] = 1.2
	w3["PULL_ISOLATE_W"] = 2.0
	_dose = w3
	var sim2 = _mk_sim(descs2)
	_cmp_end_states(sim2, 0, 1, Vector2i(2, 3), "⑦对照A[无嬉皮]")
	_run_search(sim2, "⑦对照A[无嬉皮]")
	# 对照 B：嬉皮摆到**不挡视线**的一侧（(1,0) 而不是 (2,0)）—— 上一条里血锁自己站在 (2,2)
	#   正好挡在嬉皮与落点 (2,3) 之间（`_threat_can_hit` 查视线、单位也挡）⇒ 那次拉人反而**断了自家枪线**。
	_log("LOCK|⑦对照B 嬉皮摆到不挡视线的一侧 (1,0)：这次拉人应当真的给嬉皮开出枪位")
	var descs3 := [
		_lock(Vector2i(2, 2)),
		_foe("hero_12", Vector2i(2, 4), 24, 2, "巨剑(假想敌)"),
		_ally("hero_30", Vector2i(1, 0), 20, 3, "嬉皮死神(队友)"),
	]
	_dose = w3
	var sim3 = _mk_sim(descs3)
	_cmp_end_states(sim3, 0, 1, Vector2i(2, 3), "⑦对照B[嬉皮不挡线]")
	_run_search(sim3, "⑦对照B[嬉皮不挡线]")
	_dose = {}

# ---------------- 盘面①：独狼 · 距离3 ----------------
func _s1() -> void:
	_log("LOCK|① 独狼·目标在3格外（同轴、(2,2)→(2,5)，中间两格空）")
	var descs := [
		_lock(Vector2i(2, 2)),
		_foe("hero_12", Vector2i(2, 5), 24, 2, "巨剑(假想敌)"),
	]
	var sim = _mk_sim(descs)
	_dump_candidates(sim, 0, "①")
	_cmp_end_states(sim, 0, 1, Vector2i(2, 4), "①｜A 原地开钩(距3) vs B 走1格贴身打")
	_run_search(sim, "①")

# ---------------- 盘面②：独狼 · 距离4 ----------------
func _s2() -> void:
	_log("LOCK|② 独狼·目标在4格外（(2,2)→(2,6)：走1格可开钩、走2格贴身）")
	var descs := [
		_lock(Vector2i(2, 2)),
		_foe("hero_12", Vector2i(2, 6), 24, 2, "巨剑(假想敌)"),
	]
	var sim = _mk_sim(descs)
	_dump_candidates(sim, 0, "②")
	_run_search(sim, "②")

# ---------------- 盘面③：独狼 · 距离2（最干净的 A/B） ----------------
func _s3() -> void:
	_log("LOCK|③ 独狼·目标在2格外（(2,2)→(2,4)：走1格贴身 / 原地开钩，两者同回合都可达）")
	var descs := [
		_lock(Vector2i(2, 2)),
		_foe("hero_12", Vector2i(2, 4), 24, 2, "巨剑(假想敌)"),
	]
	var sim = _mk_sim(descs)
	_dump_candidates(sim, 0, "③")
	_cmp_end_states(sim, 0, 1, Vector2i(2, 3), "③｜A 原地开钩(距2) vs B 走1格贴身打")
	_run_search(sim, "③")

# ---------------- 盘面④：带队友（队友只有"拉完那格"够得到） ----------------
func _s4() -> void:
	_log("LOCK|④ 带队友：血锁(2,2) 目标(2,5) 队友长剑(1,1)——目标在原位时队友够不到，拉一格后够得到")
	var descs := [
		_lock(Vector2i(2, 2)),
		_foe("hero_12", Vector2i(2, 5), 24, 2, "巨剑(假想敌)"),
		_ally("hero_18", Vector2i(1, 1), 20, 3, "长剑(队友)"),
	]
	var sim = _mk_sim(descs)
	_dump_candidates(sim, 0, "④")
	_cmp_end_states(sim, 0, 1, Vector2i(2, 4), "④｜A 原地开钩(距3) vs B 走1格贴身打")
	_run_search(sim, "④")

# ---------------- 盘面⑤：有第二个敌人（拉进来 = 自己多挨一刀） ----------------
func _s5() -> void:
	_log("LOCK|⑤ 反向推力：血锁(2,2) 目标(2,5) 另有敌(3,3)在侧后——拉人会把血锁拖进它的射程圈")
	var descs := [
		_lock(Vector2i(2, 2)),
		_foe("hero_12", Vector2i(2, 5), 24, 2, "巨剑(假想敌)"),
		_foe("hero_07", Vector2i(3, 3), 14, 5, "影丸(旁观敌)"),
	]
	var sim = _mk_sim(descs)
	_dump_candidates(sim, 0, "⑤")
	_cmp_end_states(sim, 0, 1, Vector2i(2, 4), "⑤｜A 原地开钩(距3) vs B 走1格贴身打")
	_run_search(sim, "⑤")
	# 对照 C（㉗上半真正的靶子）：队友**只有拉完那一格才够得到**（长剑 (1,1)、目标 (2,5)
	#   格距 3 ⇒ 移动2+射程1 够不到；拉到 (2,3) 后格距 2 ⇒ 够得到）
	_log("LOCK|⑤对照C 队友只有拉完才够得到：血锁(2,2) 目标(2,5) 长剑(1,1)")
	var descs_c := [
		_lock(Vector2i(2, 2)),
		_foe("hero_12", Vector2i(2, 5), 24, 2, "巨剑(假想敌)"),
		_ally("hero_18", Vector2i(1, 1), 20, 3, "长剑(队友)"),
	]
	for dose in [
		{ "tag": "㉗ 关", "open": 0.0, "iso": 0.0 },
		{ "tag": "只开包围 1.2", "open": 1.2, "iso": 0.0 },
		{ "tag": "包围 1.2 + 落单 2.0", "open": 1.2, "iso": 2.0 },
	]:
		var wc: Dictionary = _w.duplicate()
		wc["PULL_OPEN_W"] = float(dose["open"])
		wc["PULL_ISOLATE_W"] = float(dose["iso"])
		_dose = wc
		var sim_c = _mk_sim(descs_c)
		var tag_c := "⑤对照C[%s]" % str(dose["tag"])
		_cmp_end_states(sim_c, 0, 1, Vector2i(2, 4), tag_c)
		_run_search(sim_c, tag_c)
	_dose = {}

# ---------------- 盘面⑥：噩梦档全队搜索 ----------------
func _s6() -> void:
	_log("LOCK|⑥ 全队：血锁+长剑+风语者 vs 巨剑+影丸+火枪手（照用户实机阵容的味道摆）")
	var descs := [
		_lock(Vector2i(2, 1)),
		_ally("hero_18", Vector2i(0, 1), 20, 3, "长剑"),
		_ally("hero_43", Vector2i(1, 0), 14, 1, "风语者"),
		_foe("hero_12", Vector2i(3, 4), 24, 2, "巨剑"),
		_foe("hero_07", Vector2i(4, 2), 14, 5, "影丸"),
		_foe("hero_09", Vector2i(5, 3), 20, 4, "火枪手"),
	]
	var sim = _mk_sim(descs)
	_dump_candidates(sim, 0, "⑥")
	_run_search(sim, "⑥")

# ---------------- 通用工具 ----------------

## 枚举该单位**全部候选**并按 `_evaluate(末态)` 打分（这就是搜索看到的全部信息）。
func _dump_candidates(sim, idx: int, tag: String) -> void:
	var ai = _mk_ai(_w)
	var acts: Array = ai._actions_for(sim, idx)
	var base := float(ai._evaluate(sim, true))
	var rows: Array = []
	for a in acts:
		var s2 = sim.clone()
		ai._apply(s2, idx, a)
		var sc := float(ai._evaluate(s2, true)) - base
		rows.append({ "d": float(sc), "txt": _act_txt(sim, idx, a, s2) })
	rows.sort_custom(func(x, y): return float(x["d"]) > float(y["d"]))
	_log("LOCK|%s|候选 %d 条（按末态分降序；基准=不动末态 %.2f）" % [tag, acts.size(), base])
	for i in mini(8, rows.size()):
		_log("LOCK|%s|  %+.3f  %s" % [tag, float(rows[i]["d"]), str(rows[i]["txt"])])

## 直接对照两条具体走法的末态分 —— 这就是"定价问题还是搜索问题"的判决。
func _cmp_end_states(sim, idx: int, tgt: int, walk_cell: Vector2i, tag: String) -> void:
	var ai = _mk_ai(_w)
	var base := float(ai._evaluate(sim, true))
	# A：原地出手（距离 ≥2 ⇒ 触发拉人）
	var a_act := {"move": null, "atk": tgt}
	var sa = sim.clone()
	ai._apply(sa, idx, a_act)
	# B：走到贴身那一格再打（距离 1 ⇒ `_pull_to` 直接 return，不拉）
	var b_act := {"move": walk_cell, "atk": tgt}
	var sb = sim.clone()
	ai._apply(sb, idx, b_act)
	var d_a := float(ai._evaluate(sa, true)) - base
	var d_b := float(ai._evaluate(sb, true)) - base
	_log("LOCK|%s|A 原地开钩 Δ=%+.3f（拉完：目标@%s 血%d / 血锁@%s 血%d / 这一手 ㉗=%.2f）" % [
		tag, d_a, str(sa.units[tgt].cell), int(sa.units[tgt].hp), str(sa.units[idx].cell), int(sa.units[idx].hp),
		float(sa.pull_open_val)])
	_log("LOCK|%s|B 贴身打   Δ=%+.3f（走完：目标@%s 血%d / 血锁@%s 血%d / 这一手 ㉗=%.2f）" % [
		tag, d_b, str(sb.units[tgt].cell), int(sb.units[tgt].hp), str(sb.units[idx].cell), int(sb.units[idx].hp),
		float(sb.pull_open_val)])
	_log("LOCK|%s|⇒ **A − B = %+.3f**" % [tag, d_a - d_b])
	# 嬉皮死神 ×2 的判据：目标在各自末态格上挨我方嬉皮一下是几倍？
	for pair in [["A", sa], ["B", sb]]:
		var s2 = pair[1]
		var who: String = pair[0]
		for i in s2.units.size():
			var a2 = s2.units[i]
			if a2 == null or not a2.alive or a2.fn != DataRegistry.Faction.ENEMY or a2.hero_id != "hero_30":
				continue
			var t2 = s2.units[tgt]
			var silent: bool = a2.silenced or a2.stunned
			var ranged: bool = a2.atk_type == DataRegistry.AttackType.RANGED
			var pinned: bool = ranged and ai._sim_enemy_adjacent(s2, a2, a2.cell)
			_log("LOCK|%s|%s 嬉皮倍率=%s（目标孤立=%s · 技能有效=%s · 远程=%s/被贴身=%s · 格距=%d）" % [
				tag, who, str(DmgModel.attack_mult("hero_30", not silent, ranged, pinned, t2.alive, false, false,
					ai._sim_isolated(s2, t2, a2))), str(ai._sim_isolated(s2, t2, a2)), str(not silent),
				str(ranged), str(pinned), _grid.distance(a2.cell, t2.cell)])
	var bd_a: Dictionary = ai._eval_breakdown(sa, true)
	var bd_b: Dictionary = ai._eval_breakdown(sb, true)
	_log("LOCK|%s|A 逐项：%s" % [tag, _all_terms(bd_a)])
	_log("LOCK|%s|B 逐项：%s" % [tag, _all_terms(bd_b)])
	_log("LOCK|%s|A 盘面：%s" % [tag, _board(sa, idx, tgt)])
	_log("LOCK|%s|B 盘面：%s" % [tag, _board(sb, idx, tgt)])
	_log("LOCK|%s|A 挨打合计=%.2f / B 挨打合计=%.2f ｜ A 交战门 reach0=%s / B reach0=%s" % [
		tag, float(ai._incoming_total_on(sa, sa.units[idx], sa.units[idx].cell)),
		float(ai._incoming_total_on(sb, sb.units[idx], sb.units[idx].cell)),
		str(sa.units[idx].reach0), str(sb.units[idx].reach0)])
	# ㉑「退路/被夹」到底为什么差？（`_formation_parts()` 的 y 分量 × FORM_ESCAPE_W=2.0）
	_log("LOCK|%s|队形分量 A coh/esc/spread=%s ｜ B=%s（㉑ = −2.0 × esc）" % [
		tag, str(ai._formation_parts(sa)), str(ai._formation_parts(sb))])
	_log("LOCK|%s|㉑ 量纲读数：A 血锁 pool=%.4f（TRADE_HP_REF=%d · INCOMING_POOL_W=%.2f · hp0=%d）" % [
		tag, float(ai._incoming_pool_mult(sa.units[idx])), int(ai.TRADE_HP_REF),
		float(ai.w_incoming_pool), int(sa.units[idx].hp0)])
	# ㉑ 的 esc 拆两半：邻格差额 + 正对面那个敌人的单点值（看引擎里 `foe_threat` 到底取到几）
	for pair in [["A", sa], ["B", sb]]:
		var s3 = pair[1]
		var u3 = s3.units[idx]
		var hit := 0.0
		var back := 0.0
		var who := "无"
		var who_back := "无"
		for i in s3.units.size():
			var e3 = s3.units[i]
			if e3 == null or not e3.alive or _grid.distance(u3.cell, e3.cell) != 1:
				continue
			if e3.fn == u3.fn:
				var b3 := float(ai._adj_foe_hit_on(s3, e3, u3))
				if b3 > back:
					back = b3
					who_back = str(e3.name)
			else:
				var h3 := float(ai._adj_foe_hit_on(s3, u3, e3))
				if h3 > hit:
					hit = h3
					who = str(e3.name)
		_log("LOCK|%s|%s ㉑拆解：贴身敌人=%s 单点值=%.3f ｜ 贴身队友「%s」能还手=%.3f ⇒ max(差,0)=%.3f ×%.0f = %.3f" % [
			tag, str(pair[0]), who, hit, who_back, back, maxf(hit - back, 0.0), float(ai.FORM_ESCAPE_SCALE),
			maxf(hit - back, 0.0) * float(ai.FORM_ESCAPE_SCALE)])
	# ㉗ 的输入侧读数：引擎里的权重是否真的注进去了 + `_pull_value` 对每个敌人各算出什么
	_log("LOCK|%s|adj 诊断：格距==1 的敌人数=%d ｜ `_sim_enemy_adjacent`=%s ｜ `_threat_can_hit`=%s" % [
		tag, _adj1_count(sa, sa.units[idx]),
		str(ai._sim_enemy_adjacent(sa, sa.units[idx], sa.units[idx].cell)),
		_adj1_hit(sa, sa.units[idx], ai)])
	_log("LOCK|%s|㉗ 引擎权重：PULL_OPEN_W=%.2f PULL_ISOLATE_W=%.2f（注入剂量 open=%.2f iso=%.2f）" % [
		tag, float(ai.w_pull_open), float(ai.w_pull_isolate),
		float(_dose.get("PULL_OPEN_W", -1.0)), float(_dose.get("PULL_ISOLATE_W", -1.0))])
	_log("LOCK|%s|㉗ 逐敌拆解：%s" % [tag, _pull_trace(ai, sim, idx)])
	_log("LOCK|%s|邻格画像 A：%s" % [tag, _neigh(ai, sa, sa.units[idx].cell)])
	_log("LOCK|%s|邻格画像 B：%s" % [tag, _neigh(ai, sb, sb.units[idx].cell)])

## 逐个邻格标出"能不能走 / 被谁占"，并对邻敌**现算一遍 ㉑ 的新单点值**（核对引擎里那个数怎么来的）。
func _neigh(ai, s, cell: Vector2i) -> String:
	var bits: Array[String] = []
	var free_n := 0
	var adj_foe := 0
	var adj_friend := 0
	var hits: Array[String] = []
	for d in FORK.FORM_DIRS:
		var off: Vector2i = _grid.offset_of(_grid.axial_of(cell) + d)
		var kind := ""
		if not _grid.in_bounds(off):
			kind = "出界"
		elif s.obstacles.has(off) or s.graves.has(off):
			kind = "障碍/碑"
		elif s.occ.has(off):
			var ou = s.occ[off]
			if ou != null and ou.alive:
				if ou.fn == s.units[0].fn:
					kind = "队友:" + str(ou.name)
					adj_friend += 1
				else:
					adj_foe += 1
					kind = "敌人:" + str(ou.name)
					hits.append(_foe_hit_trace(ai, s, s.units[0], ou))
			else:
				kind = "占位(非活)"
		else:
			kind = "空(可走)"
			free_n += 1
		bits.append("%s=%s" % [str(off), kind])
	var tail := "" if hits.is_empty() else " ｜ ㉑单点值：%s" % " ".join(hits)
	return "可走%d 邻敌%d 邻友%d ｜ %s%s" % [free_n, adj_foe, adj_friend, " ".join(bits), tail]

## 复刻 `_adj_foe_hit_on()` 的四步并逐段打印（与引擎里那个函数同序），用来解释 ㉑ 到底罚了多少。
func _foe_hit_trace(ai, s, t, a) -> String:
	var tv := float(ai._threat_hit_value(s, a, 1, false, t.cell, t))
	var echo := float(ai._echo_atk_now(s, a))
	var bonus := float(ai._sim_turn_start_atk_bonus(s, a))
	var raw := tv + bonus
	var mult := float(ai._sim_mult_at(s, a, t, t.cell))
	var after := float(ai._hit_after_target_mods(s, t, t.cell, raw * mult))
	return "%s[_threat_hit_value=%.3f · echo_atk=%.3f · 祭司+%.3f ⇒ ×倍率%d ⇒ 受击侧%.3f] ×池%.3f ×%.0f = **%.3f**" % [
		str(a.name), tv, echo, bonus, int(mult), after, _pool(ai, s, t), float(ai.FORM_ESCAPE_SCALE),
		after * _pool(ai, s, t) * float(ai.FORM_ESCAPE_SCALE)]

## 血量池倍率（与 `_incoming_pool_mult()` 同式；探针自己算一份便于逐段对照）。
func _pool(ai, s, t) -> float:
	return float(ai._incoming_pool_mult(t))

## 格距 == 1 的敌人数（纯几何，不看视线）。
func _adj1_count(s, u) -> int:
	var n := 0
	for i in s.units.size():
		var e = s.units[i]
		if e != null and e.alive and e.fn != u.fn and _grid.distance(u.cell, e.cell) == 1:
			n += 1
	return n

## 格距 == 1 且 `_threat_can_hit` 为真的敌人数那一步过没过。
func _adj1_hit(s, u, ai) -> String:
	for i in s.units.size():
		var e = s.units[i]
		if e != null and e.alive and e.fn != u.fn and _grid.distance(u.cell, e.cell) == 1:
			return str(ai._threat_can_hit(s, e, u.cell, u))
	return "无邻敌"

## ㉗ 的输入侧逐敌拆解：每个敌人的落点 / 出手前后"够得到它的我方单位数" / 落点是否孤立。
func _pull_trace(ai, sim, idx: int) -> String:
	var u = sim.units[idx]
	var now: int = int(ai._pull_reach_count(sim, u.cell, u))
	var reaper: bool = bool(ai._pull_reaper_ready(sim, u))
	var bits: Array[String] = ["出手前够得到任一人数=%d（注：各目标共用同一个分母）" % now,
		"嬉皮就绪=%s" % str(reaper), "这一手累计=%.2f" % float(ai._pull_value(sim, u))]
	for i in sim.units.size():
		var t = sim.units[i]
		if t == null or not t.alive or t.fn == u.fn:
			continue
		var land: Vector2i = ai._pull_out_landing(sim, u.cell, t.cell)
		if land.x == -99:
			bits.append("%s：贴身/无空位 ⇒ 拉不动" % str(t.name))
			continue
		var before := int(ai._pull_reach_count(sim, t.cell, t))
		var after := int(ai._pull_reach_count(sim, land, t))
		bits.append("%s：落点%s 够得到它 %d→%d 孤立=%s" % [
			str(t.name), str(land), before, after, str(ai._sim_isolated_at(sim, t, land, u))])
	return " ｜ ".join(bits)

## 真跑一遍 `search()`：这是生产里真正会被执行的计划。
func _run_search(sim, tag: String) -> void:
	var ai = _mk_ai(_w)
	var path: Array = ai.search(sim, DataRegistry.Faction.ENEMY)
	var bits: Array[String] = []
	var pulled := 0
	for st in path:
		var idx := int((st as Dictionary)["idx"])
		var a: Dictionary = (st as Dictionary)["action"]
		var atk := int(a.get("atk", -1))
		var what := "不出手"
		if atk >= 0 and atk < sim.units.size():
			var tgt: Vector2i = sim.units[atk].cell
			var from: Vector2i = sim.units[idx].cell if a.get("move") == null else a["move"]
			var d := _grid.distance(from, tgt)
			what = "打 %s（间距 %d）%s" % [str(sim.units[atk].name), d, "→拉人" if d >= 2 else "→贴身(不拉)"]
			if d >= 2:
				pulled += 1
		if a.get("move") != null:
			what = "走到 %s，%s" % [str(a["move"]), what]
		bits.append("%s：%s" % [str(sim.units[idx].name), what])
	_log("LOCK|%s|search() 计划（%d 步，其中「从≥2格出手」=%d）" % [tag, path.size(), pulled])
	for b in bits:
		_log("LOCK|%s|  %s" % [tag, b])

func _act_txt(sim, idx: int, a: Dictionary, post) -> String:
	var atk := int(a.get("atk", -1))
	var mv := "原地" if a.get("move") == null else ("走到 " + str(a["move"]))
	if atk == -1:
		return mv + "，不出手"
	if atk == -2:
		return mv + "，敲障碍 " + str(a.get("atk_obs", "?"))
	var from: Vector2i = sim.units[idx].cell if a.get("move") == null else a["move"]
	var d := _grid.distance(from, sim.units[atk].cell)
	var tail := "→拉人" if d >= 2 else "→贴身(不拉)"
	var landed := str(post.units[atk].cell) if post.units[atk] != null else "?"
	return "%s，打 %s（间距 %d %s，落点 %s）" % [mv, str(sim.units[atk].name), d, tail, landed]

func _top_terms(bd: Dictionary) -> String:
	var keys: Array = bd.keys()
	keys.sort_custom(func(a, b): return absf(float(bd[a])) > absf(float(bd[b])))
	var bits: Array[String] = []
	for k in mini(6, keys.size()):
		if absf(float(bd[k])) < 0.005:
			continue
		bits.append("%s %+.2f" % [str(k), float(bd[k])])
	return " · ".join(bits)

## 逐项**全打**（不截断、不滤零）：A/B 同分时也要看出到底哪几项在动。
func _all_terms(bd: Dictionary) -> String:
	var keys: Array = bd.keys()
	keys.sort_custom(func(a, b): return absf(float(bd[a])) > absf(float(bd[b])))
	var bits: Array[String] = []
	for k in keys:
		if absf(float(bd[k])) < 0.005:
			continue
		bits.append("%s=%+.2f" % [str(k), float(bd[k])])
	return " ｜ ".join(bits)

## 两家盘面画像：位置 + 与对手的格距 + 视野内的东西（用来解释"末态到底差在哪"）。
func _board(s, idx: int, tgt: int) -> String:
	var me = s.units[idx]
	var t = s.units[tgt]
	var bits: Array[String] = []
	bits.append("血锁@%s 血%d/%d 攻%d 移%d 射%d" % [str(me.cell), int(me.hp), int(me.max_hp), int(me.eatk), int(me.emove), int(me.atk_range)])
	bits.append("目标@%s 血%d 与血锁格距%d" % [str(t.cell), int(t.hp), _grid.distance(me.cell, t.cell)])
	for i in s.units.size():
		var u = s.units[i]
		if u == null or i == idx or i == tgt:
			continue
		bits.append("%s@%s 血%d（与血锁 %d / 与目标 %d）" % [str(u.name), str(u.cell), int(u.hp),
			_grid.distance(me.cell, u.cell), _grid.distance(t.cell, u.cell)])
	return " ｜ ".join(bits)

func _mk_sim(descs: Array):
	var ai = _mk_ai(_w)
	var occ := {}
	for i in descs.size():
		occ[descs[i]["cell"]] = i
	return ai.build_state(descs, occ, {}, {}, {}, {}, {})

func _mk_ai(inject: Dictionary):
	var ai = FORK.new(_grid)
	ai.difficulty = 3
	ai.log_decisions = false
	ai.time_budget_ms = 800       # 【诊断】盘面小、只问"它会选哪一手"，别让搜索跑满上限
	ai.set_weights(_dose if not _dose.is_empty() else inject)
	return ai

func _lock(cell: Vector2i) -> Dictionary:
	# 血锁：攻 2 / 24 血 / 移动 2 / 射程 3（出生 +2）/ 近战；"只能直线"由 hero_id 判据给出
	return _u(DataRegistry.Faction.ENEMY, "hero_41", cell, 24, 24, 2, 2, 3, MELEE, [], "血锁")

func _foe(hero: String, cell: Vector2i, hp: int, atk: int, nm: String) -> Dictionary:
	return _u(DataRegistry.Faction.PLAYER, hero, cell, hp, hp, atk, 2, 1, MELEE, [], nm)

func _ally(hero: String, cell: Vector2i, hp: int, atk: int, nm: String) -> Dictionary:
	return _u(DataRegistry.Faction.ENEMY, hero, cell, hp, hp, atk, 2, 1, MELEE, [], nm)

func _u(fn: int, hero: String, cell: Vector2i, hp: int, max_hp: int, atk: int,
		mv: int, rng: int, typ: int, skills: Array, nm: String) -> Dictionary:
	return {
		"fn": fn, "hero": hero, "cell": cell, "hp": hp, "max_hp": max_hp,
		"atk": atk, "eatk": atk, "move": mv, "emove": mv,
		"atk_range": rng, "atk_type": typ, "skills": skills, "name": nm,
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
		if str(k).begins_with("_"):
			continue
		out[str(k)] = (d as Dictionary)[k]
	return out

func _sha(path: String) -> String:
	var ctx := HashingContext.new()
	if ctx.start(HashingContext.HASH_SHA256) != OK:
		return "?"
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return "?"
	ctx.update(f.get_buffer(f.get_length()))
	f.close()
	return ctx.finish().hex_encode().substr(0, 12)

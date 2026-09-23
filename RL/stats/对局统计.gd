extends Node
## 【对局统计收集】在**真实 scenes/Main.tscn** 上跑整局（3v3 或 5v5=上场3+替补2），
## 把每一局与每一个单位的统计数据落成 CSV，供后续做英雄强度榜 / 组合强度榜 / 对位胜率矩阵。
##
## 蓝本 = `RL/harness/对局.gd`（本文件是它的**插桩副本**，不改那个文件）：
##   建局 / 驱动双方 AI / 等一招 / 判胜负的写法逐条照抄，只额外做三件事：
##     ① 挂统计钩子（hp_changed / died / 状态轮询 / buff_items 轮询）；
##     ② 5v5 时自己给双方补替补（`dual_control=true` 下 Battle 把双方替补都判成"手动"，
##        没人点就会一直开面板等人 → 本工具按生产口径替那一"下手"）；
##     ③ 每局结束写 CSV（UTF-8 带 BOM）。
##
## 规则侧**零实现**：所有结算都由真实 Battle / Unit / 英雄脚本完成，本文件只读它们的信号与公开状态。
##
## 用法（无头，示例）：
##   godot --headless --path <项目> res://RL/stats/对局统计.tscn -- \
##         --mode 3v3 --games 3 --seed 7 --first both --beam 50 --speed 20 \
##         --wA res://RL/weights/噩梦.json --wB base --out res://RL/reports/stats --tag stats
##   （PowerShell 抓不到 Godot 的 stdout，一律 cmd /c "... > out.txt 2>&1" 再看文件；
##     并行跑必须给每个实例独立 APPDATA，见 RL/stats/collect_stats.ps1）
##
## 口径详见 RL/stats/README.md。

const FORK := preload("res://RL/ai/AI_Battle.gd")          # 候选 AI（可注入权重）
const BASE := preload("res://RL/ai/AI_Battle_原版.gd")      # 原版困难档（与 src/BattleAI.gd 同源）
const SNAP := preload("res://src/BattleSnapshot.gd")

const MAIN_SCENE := "res://scenes/Main.tscn"
const W_NIGHTMARE := "res://RL/weights/噩梦.json"
const DEFAULT_OUT := "res://RL/reports/stats"

# 与 RL/harness/对局.gd 同一套摆位（首发 3 人）
const P_CELLS: Array[Vector2i] = [Vector2i(1, 4), Vector2i(3, 4), Vector2i(1, 5)]
const E_CELLS: Array[Vector2i] = [Vector2i(1, 2), Vector2i(3, 2), Vector2i(1, 1)]

const MAX_HALF := 60            # 半回合上限（防跑飞；正常 3 杀判负远小于此）
const ACT_WALL_MS := 1000       # 等一招动画的上限（scale=20 下实测每招只需要几十毫秒）
const READY_WALL_MS := 30000    # 等 Battle 开出第一个回合
const ROUND_WALL_MS := 30000    # 等一回合收尾
const WATCHDOG_MS := 1800 * 1000

const COLS_MATCH := ["match_id", "seed", "mode", "first_side", "half_rounds", "wall_ms",
	"winner", "end_reason", "P_lineup", "E_lineup", "P_first3", "E_first3",
	"P_alive_end", "E_alive_end", "P_total_dmg", "E_total_dmg", "P_total_heal", "E_total_heal",
	"P_kills", "E_kills", "P_gold", "E_gold",
	# 归因不到出手者的伤害/治疗/击杀（毒、回合烧血、炸弹、荆棘反伤、镜像附体、回合开始/结束类效果）。
	# 放进 CSV 是为了**只拿两张表就能自证**：units.dmg_taken 按 match_id 求和
	# = P_total_dmg + E_total_dmg + unattr_dmg（原来这三项只在 stdout 的 R|m| 行里）。
	"unattr_dmg", "unattr_heal", "unattr_kills",
	"P_sub_enter_rounds", "E_sub_enter_rounds",
	"P_first_death_round", "E_first_death_round", "beam_P", "beam_E", "w_P", "w_E", "fork_sha"]

# 注意：**没有 skills_used 列** —— 技能触发点（HeroBase.on_turn_start / on_attack / on_after_attack /
# on_enter / on_die…）不是信号，在"不改 src/"的前提下观测不到；留一个恒为空的占位列会让人误以为
# "漏采了"。技能造成的可见后果已各自成列（status_dealt / heal_done / dmg_dealt）。详见 README。
const COLS_UNIT := ["match_id", "side", "slot", "hero_id", "hero_name", "enter_round",
	"first_death_round", "alive_at_end", "rounds_alive", "dmg_dealt", "dmg_taken", "heal_done",
	"kills", "deaths", "gold_taken", "moves", "attacks", "status_dealt"]

# ---- CLI ----
var _mode := "3v3"
var _games := 1
var _seed0 := 10000
var _first_mode := "both"        # p / e / both（both=逐局交替先手）
var _beam := 800
var _speed := 20.0
var _wA_path := W_NIGHTMARE      # 玩家方(P)权重
var _wB_path := W_NIGHTMARE      # 敌方(E)权重；"base" = 原版困难档
var _wA: Dictionary = {}
var _wB: Dictionary = {}
var _wB_base := false
var _out_dir := DEFAULT_OUT
var _tag := "stats"
var _picks_p: Array = []         # --picks "a,b,c[,d,e]" 固定玩家方阵容（默认按 seed 随机）
var _picks_e: Array = []
var _run_stamp := ""             # 本次运行的统一时间戳（**每局落盘都写同一个文件**，覆盖式累积）

# ---- 运行期 ----
var _b: Battle = null
var _matches: Array = []         # 每局一行（Dictionary）
var _rows: Array = []            # 本局每个登记过的单位一行
var _unit_out: Array = []        # 本次运行累积的 units.csv 输出行（跨局）
var _idx: Dictionary = {}        # Unit -> _rows 下标
var _hp_prev: Dictionary = {}    # Unit -> 上次已知 hp
var _status_now: Dictionary = {} # Unit -> 本帧状态集合（做差集找"新挂上的状态"）
var _gold_cells: Dictionary = {} # 本帧存在的金矿格
var _ctx_actor: Unit = null      # 当前正在出手的单位（归因用）
var _ctx_target: Unit = null     # 当前这一招的目标（反击归因用）
var _half := 0                   # 半回合序号（0 起；每方各走一次算 2）
var _unattributed_dmg := 0
var _unattributed_heal := 0
var _unattributed_kills := 0
var _last_winner := -2           # GameState.match_ended 的 winner_side（-2=未结束）
var _m_deck_p: Array = []
var _m_deck_e: Array = []

func _ready() -> void:
	_watchdog()
	_run.call_deferred()

## 墙钟看门狗：脚本异常/建局卡死时也能退出并留下痕迹（无头跑没有人工中断）
func _watchdog() -> void:
	while Time.get_ticks_msec() < WATCHDOG_MS:
		await get_tree().process_frame
	print("R|WATCHDOG|wall_s=%d" % (WATCHDOG_MS / 1000))
	get_tree().quit(3)

# ================= 入口 =================

func _run() -> void:
	_parse_args(OS.get_cmdline_user_args())
	if not GameState.match_ended.is_connected(_on_match_ended):
		GameState.match_ended.connect(_on_match_ended)
	_wA = _load_w(_wA_path)
	_wB = _load_w(_wB_path)
	_run_stamp = _stamp_txt()
	_matches = []
	_unit_out = []
	_ensure_out_dir()
	print("R|cfg|mode=%s|games=%d|seed0=%d|first=%s|beam=%d|speed=%.0f|wA=%s(n=%d)|wB=%s(n=%d)|out=%s|tag=%s|fork_sha=%s|base_sha=%s" % [
		_mode, _games, _seed0, _first_mode, _beam, _speed,
		_w_label(_wA_path), _wA.size(), _w_label(_wB_path), _wB.size(), _out_dir, _tag,
		_sha("res://RL/ai/AI_Battle.gd"), _sha("res://RL/ai/AI_Battle_原版.gd")])
	var t_all := Time.get_ticks_msec()
	for i in _games:
		var seed_v := _seed0 + i
		var first_side: int = GameState.SIDE_PLAYER
		if _first_mode == "e":
			first_side = GameState.SIDE_ENEMY
		elif _first_mode == "both":
			first_side = GameState.SIDE_PLAYER if i % 2 == 0 else GameState.SIDE_ENEMY
		await _play(seed_v, first_side)
		_write_csvs()      # 每局落一次盘：中途崩了也已经拿到前面几局
	print("R|SUMMARY|games=%d|wall_s=%.1f|out=%s" % [
		_matches.size(), (Time.get_ticks_msec() - t_all) / 1000.0, _out_dir])
	print("R|END")
	get_tree().quit(0)

func _parse_args(ua: Array) -> void:
	var i := 0
	while i < ua.size():
		var k := String(ua[i])
		var v := String(ua[i + 1]) if i + 1 < ua.size() else ""
		match k:
			"--mode":
				_mode = v if (v == "3v3" or v == "5v5") else "3v3"
				i += 2
			"--games":
				_games = maxi(int(v), 1)
				i += 2
			"--seed":
				_seed0 = int(v)
				i += 2
			"--first":
				_first_mode = v if (v == "p" or v == "e" or v == "both") else "both"
				i += 2
			"--beam":
				_beam = clampi(int(v), 1, 8000)
				i += 2
			"--speed":
				_speed = clampf(float(v), 1.0, 50.0)
				i += 2
			"--wA":
				_wA_path = v
				i += 2
			"--wB":
				_wB_path = v
				_wB_base = (v == "base")
				i += 2
			"--out":
				_out_dir = v
				i += 2
			"--tag":
				_tag = v
				i += 2
			"--picks":
				# --picks "p1,p2,p3[,p4,p5]" "e1,e2,e3[,e4,e5]"（两个参数，用逗号分人）
				_picks_p = []
				_picks_e = []
				if i + 1 < ua.size():
					for x in String(ua[i + 1]).split(","):
						_picks_p.append(String(x))
				if i + 2 < ua.size():
					for x in String(ua[i + 2]).split(","):
						_picks_e.append(String(x))
				i += 3
			_:
				i += 1

# ================= 一局 =================

func _play(seed_v: int, first_side: int) -> void:
	await _setup(seed_v, first_side)
	var t0 := Time.get_ticks_msec()
	_half = 0
	var rounds := 0
	while not GameState.match_over and rounds < MAX_HALF:
		var side: int = GameState.active_side
		_b.turn_time_left = 0.0
		_b.peer_turn_time_left = 0.0
		_b._turn_expired = false
		var t_a := Time.get_ticks_msec()
		var f_a := Engine.get_process_frames()
		await _ai_side(side)
		await _pump_pending()
		var t_b := Time.get_ticks_msec()
		var f_b := Engine.get_process_frames()
		if GameState.match_over:
			break
		await _b._end_side(side)
		rounds += 1
		_half = rounds
		var t_c := Time.get_ticks_msec()
		var f_c := Engine.get_process_frames()
		await _wait_ready()
		print("R|half|idx=%d|side=%d|fn=%d|ai_ms=%d|ai_fr=%d|end_ms=%d|end_fr=%d|wait_ms=%d|wait_fr=%d" % [
			rounds - 1, side, _b.side_faction(side), t_b - t_a, f_b - f_a,
			t_c - t_b, f_c - f_b, Time.get_ticks_msec() - t_c, Engine.get_process_frames() - f_c])
	var wall_ms := Time.get_ticks_msec() - t0
	_record_match(seed_v, first_side, rounds, wall_ms)
	await _teardown()

func _record_match(seed_v: int, first_side: int, rounds: int, wall_ms: int) -> void:
	var m := {}
	for c in COLS_MATCH:
		m[c] = ""
	m["match_id"] = "s%d" % seed_v
	m["seed"] = seed_v
	m["mode"] = _mode
	m["first_side"] = "P" if first_side == GameState.SIDE_PLAYER else "E"
	m["half_rounds"] = rounds
	m["wall_ms"] = wall_ms
	m["P_lineup"] = "|".join(PackedStringArray(_m_deck_p))
	m["E_lineup"] = "|".join(PackedStringArray(_m_deck_e))
	m["P_first3"] = "|".join(PackedStringArray(_m_deck_p.slice(0, 3)))
	m["E_first3"] = "|".join(PackedStringArray(_m_deck_e.slice(0, 3)))
	m["beam_P"] = _beam
	# 原版困难档的搜索宽度是它自己的常量（RL/ai/AI_Battle_原版.gd:387 `_beam()` = 800），
	# 不吃 --beam → 这一侧如实记 800。
	m["beam_E"] = 800 if _wB_base else _beam
	m["w_P"] = _w_label(_wA_path)
	m["w_E"] = _w_label(_wB_path)
	m["fork_sha"] = _sha("res://RL/ai/AI_Battle.gd")
	var win := "D"
	if _last_winner == GameState.SIDE_PLAYER:
		win = "P"
	elif _last_winner == GameState.SIDE_ENEMY:
		win = "E"
	m["winner"] = win
	if GameState.match_over:
		m["end_reason"] = "deaths"
	elif rounds >= MAX_HALF:
		m["end_reason"] = "half_limit"
	else:
		m["end_reason"] = "stuck"
	# 逐单位汇总
	var agg := {
		"P": {"alive": 0, "dmg": 0, "heal": 0, "kills": 0, "gold": 0, "subs": [], "fd": -1},
		"E": {"alive": 0, "dmg": 0, "heal": 0, "kills": 0, "gold": 0, "subs": [], "fd": -1},
	}
	for r in _rows:
		var s: String = "P" if int(r["faction"]) == DataRegistry.Faction.PLAYER else "E"
		var a: Dictionary = agg[s]
		if String(r["slot"]) != "召唤":
			a["alive"] = int(a["alive"]) + (1 if bool(r["alive"]) else 0)
			if bool(r["died"]) and int(r["first_death_round"]) >= 0:
				var fd: int = int(a["fd"])
				if fd < 0 or int(r["first_death_round"]) < fd:
					a["fd"] = int(r["first_death_round"])
		if String(r["slot"]) == "替补":
			a["subs"].append(int(r["enter_round"]))
		a["dmg"] = int(a["dmg"]) + int(r["dmg_dealt"])
		a["heal"] = int(a["heal"]) + int(r["heal_done"])
		a["kills"] = int(a["kills"]) + int(r["kills"])
		a["gold"] = int(a["gold"]) + int(r["gold_taken"])
	m["P_alive_end"] = agg["P"]["alive"]
	m["E_alive_end"] = agg["E"]["alive"]
	m["P_total_dmg"] = agg["P"]["dmg"]
	m["E_total_dmg"] = agg["E"]["dmg"]
	m["P_total_heal"] = agg["P"]["heal"]
	m["E_total_heal"] = agg["E"]["heal"]
	m["P_kills"] = agg["P"]["kills"]
	m["E_kills"] = agg["E"]["kills"]
	m["P_gold"] = agg["P"]["gold"]
	m["E_gold"] = agg["E"]["gold"]
	# 归因不到出手者的那部分（毒/烧血/炸弹/荆棘/镜像/回合开始结束类）：只进 dmg_taken，不记给任何单位。
	# 有这三列，任何人都能只拿两张 CSV 对账（stdout 不再是唯一出处）。
	m["unattr_dmg"] = _unattributed_dmg
	m["unattr_heal"] = _unattributed_heal
	m["unattr_kills"] = _unattributed_kills
	m["P_sub_enter_rounds"] = "|".join(PackedStringArray(_to_strs(agg["P"]["subs"])))
	m["E_sub_enter_rounds"] = "|".join(PackedStringArray(_to_strs(agg["E"]["subs"])))
	if int(agg["P"]["fd"]) >= 0:
		m["P_first_death_round"] = agg["P"]["fd"]
	if int(agg["E"]["fd"]) >= 0:
		m["E_first_death_round"] = agg["E"]["fd"]
	_matches.append(m)
	_collect_unit_rows()      # units.csv 的输出行（累积）
	# 每局一行摘要（机读，与 RL/harness/对局.gd 的 R|m| 行同风格）
	var sum_line := "R|m|id=%s|mode=%s|seed=%d|first=%s|win=%s|half=%d|wall_ms=%d|P_lineup=%s|E_lineup=%s|P_dmg=%d|E_dmg=%d|P_heal=%d|E_heal=%d|P_kills=%d|E_kills=%d|P_alive=%d|E_alive=%d|P_subs=%s|E_subs=%s|unattr_dmg=%d|unattr_heal=%d|unattr_kills=%d" % [
		m["match_id"], _mode, seed_v, m["first_side"], win, rounds, wall_ms,
		m["P_lineup"], m["E_lineup"], m["P_total_dmg"], m["E_total_dmg"],
		m["P_total_heal"], m["E_total_heal"], m["P_kills"], m["E_kills"],
		m["P_alive_end"], m["E_alive_end"], m["P_sub_enter_rounds"], m["E_sub_enter_rounds"],
		_unattributed_dmg, _unattributed_heal, _unattributed_kills]
	print(sum_line)

func _on_match_ended(winner_side: int) -> void:
	_last_winner = int(winner_side)

# ================= 建局 / 拆局 =================

func _setup(seed_v: int, first_side: int) -> void:
	Engine.time_scale = _speed
	GameState.reset_online()
	GameState.dual_control = true          # 关键：不让 _begin_side(ENEMY) 自动跑生产 AI
	GameState.no_death_limit = false       # 正常判负规则：累计阵亡 3 名即结束
	GameState.arena_mode = false
	GameState.pick_deck_in_battle = false
	GameState.match_over = false
	GameState.ai_difficulty = 2
	GameState.clear_placement()
	var size := 5 if _mode == "5v5" else 3
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_v * 31 + size
	var decks := _make_decks(size, rng)
	_m_deck_p = decks[0]
	_m_deck_e = decks[1]
	for i in P_CELLS.size():
		GameState.player_placement[P_CELLS[i]] = _m_deck_p[i]
	for i in E_CELLS.size():
		GameState.enemy_placement[E_CELLS[i]] = _m_deck_e[i]
	GameState.player_deck = _m_deck_p.duplicate()
	GameState.enemy_deck = _m_deck_e.duplicate()
	# 本局统计清零
	_rows = []
	_idx = {}
	_hp_prev = {}
	_status_now = {}
	_gold_cells = {}
	_ctx_actor = null
	_ctx_target = null
	_unattributed_dmg = 0
	_unattributed_heal = 0
	_unattributed_kills = 0
	_last_winner = -2
	_b = load(MAIN_SCENE).instantiate() as Battle
	_b.set_random_seed(seed_v)
	_b._first_side = first_side
	get_tree().root.add_child(_b)
	# ★ 5v5 的"上场 3 + 替补 2"：自由放置分支（placement 非空）只摆首发、不建替补席
	#   （src/Battle.gd:1448-1467：只有 no_death_limit 的沙箱才 _seed_sandbox_roster）。
	#   这里按生产同一口径自己补上替补席：卡组里没上场的那几个。
	_b.player_roster = _m_deck_p.slice(3).duplicate()
	_b.enemy_roster = _m_deck_e.slice(3).duplicate()
	var t0 := Time.get_ticks_msec()
	while _b.state != Battle.State.PLAYER_INPUT and Time.get_ticks_msec() - t0 < READY_WALL_MS:
		_drive_sub_panel()
		await get_tree().process_frame
	_register_starters()
	print("R|setup|seed=%d|first=%s|p_deck=%s|e_deck=%s|p_roster=%s|e_roster=%s|state=%d" % [
		seed_v, "P" if first_side == GameState.SIDE_PLAYER else "E",
		str(_m_deck_p), str(_m_deck_e), str(_b.player_roster), str(_b.enemy_roster), int(_b.state)])

func _teardown() -> void:
	Engine.time_scale = 1.0
	if _b != null and is_instance_valid(_b):
		_b.queue_free()
	_b = null
	_idx = {}
	_hp_prev = {}
	_status_now = {}
	await get_tree().process_frame
	await get_tree().process_frame

## 阵容：命令行给了就用（不足按随机补齐），否则**按 seed 确定性随机抽**（双方互不重复）。
## 之所以默认随机：英雄强度榜/组合榜/对位矩阵要靠阵容的多样性；要复刻训练口径用
## `--picks hero_13,hero_12,hero_23 hero_06,hero_17,hero_26`。
func _make_decks(size: int, rng: RandomNumberGenerator) -> Array:
	var pool: Array = DataRegistry.heroes.keys()
	pool.sort()                      # 排序后再洗：保证"同 seed → 同阵容"（字典序与加载顺序无关）
	var used := {}
	return [_take_lineup(_picks_p, size, pool, used, rng), _take_lineup(_picks_e, size, pool, used, rng)]

func _take_lineup(given: Array, size: int, pool: Array, used: Dictionary, rng: RandomNumberGenerator) -> Array:
	var out: Array = []
	for v in given:
		var s := String(v).strip_edges()
		if s != "" and DataRegistry.heroes.has(s) and not used.has(s):
			out.append(s)
			used[s] = true
	if out.size() >= size:
		return out.slice(0, size)
	var cand: Array = []
	for h in pool:
		if not used.has(h):
			cand.append(h)
	cand = _shuffle(cand, rng)
	var i := 0
	while out.size() < size and i < cand.size():
		var h2 := String(cand[i])
		i += 1
		out.append(h2)
		used[h2] = true
	return out

func _shuffle(src: Array, rng: RandomNumberGenerator) -> Array:
	var a := src.duplicate()
	for i in range(a.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var t = a[i]
		a[i] = a[j]
		a[j] = t
	return a

# ================= AI 驱动（A=玩家方 / B=敌方） =================

func _ai_side(side: int) -> void:
	var fn := _b.side_faction(side)
	var snap: Dictionary = SNAP.collect(_b)
	var refs: Array = _b.units.duplicate()
	var is_p: bool = fn == DataRegistry.Faction.PLAYER
	var ai
	if is_p:
		ai = FORK.new(_b.grid)
		ai.set_weights(_wA)
		ai.w_beam = _beam
	elif _wB_base:
		ai = BASE.new(_b.grid)             # 原版困难档：不注入权重，beam 是它自己的常量 800
	else:
		ai = FORK.new(_b.grid)
		ai.set_weights(_wB)
		ai.w_beam = _beam
	ai.difficulty = 2
	ai.log_decisions = false
	ai.time_budget_ms = 0                  # 不限时：自然搜完 → 可复现
	var descs: Array = snap["descs"]
	if fn != DataRegistry.Faction.ENEMY:
		descs = _relabel(descs)            # 替玩家方规划：对调 fn 标签
	var sim = _build_sim(ai, descs, snap, fn)
	var t_s := Time.get_ticks_msec()
	var plan: Array = ai.search(sim, DataRegistry.Faction.ENEMY)
	print("R|plan|half=%d|fn=%d|side=%d|steps=%d|search_ms=%d" % [
		_half, fn, side, plan.size(), Time.get_ticks_msec() - t_s])
	for step in plan:
		if GameState.match_over:
			break
		var idx := int(step.get("idx", -1))
		if idx < 0 or idx >= refs.size():
			continue
		var u = refs[idx]
		if u == null or not is_instance_valid(u) or not u.alive:
			continue
		var a: Dictionary = step.get("action", {})
		if a.has("move") and a["move"] != null:
			var cell0: Vector2i = u.cell
			var was_moved: bool = u.moved_this_turn
			await _act_and_wait(u, null, func() -> void: _b._do_move(u, a["move"], fn == DataRegistry.Faction.ENEMY))
			if is_instance_valid(u) and (u.cell != cell0 or (not was_moved and u.moved_this_turn)):
				_bump(u, "moves")
			await _resolve_pending_bomb()
		# ★ 每一步都要**重新**判活：上一招可能把出手者自己弄死（踩雷/荆棘反伤/自爆），
		#   实例已释放时再把它传给 `_in_attack_range` 会报
		#   "The Object-derived class of argument 1 (previously freed) is not a subclass of …"
		#   （实机踩到：5v5 第 4 半回合，炸弹炸死自己后还要接着算攻击）。
		if not _alive_unit(u):
			continue
		if a.has("atk_obs"):
			await _act_and_wait(u, null, func() -> void: _b._do_attack_obstacle(u, a["atk_obs"], fn == DataRegistry.Faction.ENEMY))
			_bump(u, "attacks")
		if a.has("atk") and int(a["atk"]) >= 0:
			var ti := int(a["atk"])
			if ti >= 0 and ti < refs.size() and _alive_unit(refs[ti]):
				var t: Unit = refs[ti]
				if t.faction != fn and _b._in_attack_range(u, t):
					_bump(u, "attacks")
					await _act_and_wait(u, t, func() -> void: _b._do_attack(u, t, fn == DataRegistry.Faction.ENEMY))

## 单位还在场上活着（下一招/下一次读属性之前必须重新判一次：上一招可能已经把它释放）
func _alive_unit(u) -> bool:
	return u != null and is_instance_valid(u) and u.alive

## 建 sim：fork 的第 8/9/10 参（active_fn / rosters / auto_sub）按能力探测传，
## 原版副本只收 7 参，多传会直接报 "Expected 7 argument(s)"。
func _build_sim(ai, descs: Array, snap: Dictionary, fn: int):
	if _ai_args(ai) >= 10:
		return ai.build_state(descs, snap["occ"], snap["gold"], snap["grave"],
				snap["obstacle"], snap["bomb"], snap["buff"], fn, snap.get("rosters", {}), _auto_sub_sides())
	if _ai_args(ai) >= 9:
		return ai.build_state(descs, snap["occ"], snap["gold"], snap["grave"],
				snap["obstacle"], snap["bomb"], snap["buff"], fn, snap.get("rosters", {}))
	if _ai_args(ai) >= 8:
		return ai.build_state(descs, snap["occ"], snap["gold"], snap["grave"],
				snap["obstacle"], snap["bomb"], snap["buff"], fn)
	return ai.build_state(descs, snap["occ"], snap["gold"], snap["grave"],
			snap["obstacle"], snap["bomb"], snap["buff"])

func _ai_args(ai) -> int:
	if ai == null:
		return 0
	for m in ai.get_method_list():
		if String(m.get("name", "")) == "build_state":
			return int(m.get("args", []).size())
	return 0

## 按阵营告诉 sim"这一方的替补由工具按什么规则点"（必须与 _drive_sub_panel 真正用的规则一致）：
## 敌方 = 生产打分（_best_enemy_sub_idx），玩家方 = 替补席第一张（_auto_sub_on_timeout 的兜底口径）。
func _auto_sub_sides() -> Dictionary:
	var out := {}
	if _b == null or not is_instance_valid(_b):
		return out
	for fn in [DataRegistry.Faction.PLAYER, DataRegistry.Faction.ENEMY]:
		if _b._roster_of(fn).size() > 0:
			out[fn] = "score" if fn == DataRegistry.Faction.ENEMY else "first"
	return out

## 对调 fn 标签（fork 恒把 ENEMY 当"我方"），并显式给出真实的 row（出生侧基线）
func _relabel(descs: Array) -> Array:
	var out: Array = []
	for d in descs:
		var dd: Dictionary = (d as Dictionary).duplicate()
		var f := int(dd["fn"])
		var true_enemy: bool = f == DataRegistry.Faction.ENEMY
		dd["row"] = 0 if true_enemy else _b.grid.height - 1
		dd["fn"] = DataRegistry.Faction.PLAYER if true_enemy else DataRegistry.Faction.ENEMY
		out.append(dd)
	return out

## 等一招结算完：敌方路径靠 action_finished 信号放行；玩家方路径没有该信号
## （src/Battle.gd:3501 _after_player_action 直接回 PLAYER_INPUT），所以两条判据都收。
## 等待期间照常驱动"等你点一下"的状态（替补面板 / 炸弹人放雷），否则会干等到回合限时。
func _act_and_wait(u: Unit, target: Unit, cb: Callable) -> void:
	_ctx_actor = u
	_ctx_target = target
	var c0 := Vector2i(-99, -99)
	var m0 := false
	var a0 := false
	if u != null and is_instance_valid(u):
		c0 = u.cell
		m0 = u.moved_this_turn
		a0 = u.attacked_this_turn
	var done: Array = [false]
	var h := func() -> void: done[0] = true
	_b.action_finished.connect(h, CONNECT_ONE_SHOT)
	cb.call()
	var t0 := Time.get_ticks_msec()
	var frames := 0
	while not done[0] and Time.get_ticks_msec() - t0 < ACT_WALL_MS:
		_drive_sub_panel()
		await _resolve_pending_bomb()
		_poll_units()
		await get_tree().process_frame
		frames += 1
		if GameState.match_over:
			break
		if frames >= 3 and _b.state == Battle.State.PLAYER_INPUT:
			break       # 玩家方路径：回到输入态即本招结束
		if frames >= 15 and _no_op_moved(u, c0, m0, a0):
			break       # 空动作：`_do_move` 因"已攻击过"直接 return，玩家方路径不会回 PLAYER_INPUT
	if not done[0] and is_instance_valid(_b) and _b.action_finished.is_connected(h):
		_b.action_finished.disconnect(h)
	print("R|act|half=%d|by=%s|to=%s|ms=%d|frames=%d|sig=%s|state=%d" % [
		_half, str(u.display_name) if (u != null and is_instance_valid(u)) else "?",
		str(target.display_name) if (target != null and is_instance_valid(target)) else "-",
		Time.get_ticks_msec() - t0, frames, str(done[0]), int(_b.state)])
	_ctx_actor = null
	_ctx_target = null

## 本招是否为"空动作"：单位已释放，或格子/移动标记/攻击标记全部没变
## （真移动在 `src/Battle.gd:3112` 就同步改了 `u.cell`，真攻击在收尾时置 `attacked_this_turn`）。
func _no_op_moved(u: Unit, c0: Vector2i, m0: bool, a0: bool) -> bool:
	if u == null or not is_instance_valid(u):
		return true
	return u.cell == c0 and u.moved_this_turn == m0 and u.attacked_this_turn == a0

## 玩家侧的炸弹人（hero_35）在真实游戏里是"移动后由玩家点格放雷"；无头没有手，
## 所以调英雄自己的 `bomb_place_cells()` + `_frontest()`（与单机敌方 AI 分支同一套规则）
## 再走 `_try_place_bomb` 落子 —— 不新增任何策略，只替代"人手点击"。（与 RL/harness/对局.gd 同款）
func _resolve_pending_bomb() -> void:
	if _b == null or not is_instance_valid(_b):
		return
	if _b.state != Battle.State.PLACE_BOMB or _b._pending_bomb_unit == null:
		return
	var u: Unit = _b._pending_bomb_unit
	var hero = _b._hero(u)
	var cells: Array = hero.bomb_place_cells()
	if cells.is_empty():
		return
	_b._try_place_bomb(hero._frontest(cells))
	await get_tree().process_frame

# ================= 替补面板（5v5 的关键） =================

## `GameState.dual_control = true` 时 `Battle._is_manual_sub_faction()` 对**双方**都返回 true
## （src/Battle.gd:1942），阵亡一律走"手动替补面板"，没人点就卡到 90 秒回合限时。
## 本工具就替那一次点击，且**口径与生产一致**：
##   · 选谁：敌方用生产自己的 `_best_enemy_sub_idx()`；玩家方用替补席第一张
##     （= `_auto_sub_on_timeout()` 的兜底口径）；
##   · 怎么落位：`_on_sub_pick(hero)` → `_auto_sub_cell(fn)` → `_try_place_sub(cell)`
##     （与 `_auto_sub_on_timeout()` 同一条 API，墓碑优先/出生区兜底全由 Battle 自己算）。
## 面板归属看 `_sub_faction`，**不看 active_side**（面板属于阵亡的那一方，与谁在行动无关）。
func _drive_sub_panel() -> void:
	if _b == null or not is_instance_valid(_b):
		return
	var st := int(_b.state)
	if st != Battle.State.SUBSTITUTING and st != Battle.State.PLACE_SUB:
		return
	var fn := int(_b._sub_faction)
	if fn < 0:
		return
	var roster: Array = _b._roster_of(fn)
	if roster.size() <= 0:
		return
	if st == Battle.State.SUBSTITUTING:
		var idx := 0
		if fn == DataRegistry.Faction.ENEMY:
			idx = int(_b._best_enemy_sub_idx())
		idx = clampi(idx, 0, roster.size() - 1)
		var hero := String(roster[idx])
		_b._on_sub_pick(hero)
		print("R|sub_pick|half=%d|fn=%d|hero=%s|idx=%d|roster=%d" % [_half, fn, hero, idx, roster.size()])
	if int(_b.state) != Battle.State.PLACE_SUB:
		return
	var cell: Vector2i = _b._auto_sub_cell(fn)
	if cell.x == -99:
		return
	var ok: bool = bool(_b._try_place_sub(cell))
	print("R|sub_place|half=%d|fn=%d|cell=(%d,%d)|ok=%s" % [_half, fn, cell.x, cell.y, str(ok)])
	if ok:
		_sync_units()

# ================= 等待 =================

## 等到 Battle 回到"可输入"（= 本回合的换边/回合开始演出 + 替补面板都走完）。
## 只在 `_end_side` 之后调用：`_end_side` 末尾会 await `_begin_side`，正常返回时状态已经是
## PLAYER_INPUT；只有"回合开始先补位"那条路会停在 SUBSTITUTING 等我们点。
func _wait_ready() -> void:
	var t0 := Time.get_ticks_msec()
	while not GameState.match_over and _b != null and is_instance_valid(_b) \
			and int(_b.state) != int(Battle.State.PLAYER_INPUT) \
			and int(_b.state) != int(Battle.State.ENDED) \
			and Time.get_ticks_msec() - t0 < ROUND_WALL_MS:
		_drive_sub_panel()
		await _resolve_pending_bomb()
		_poll_units()
		await get_tree().process_frame

## 一招/一回合之间的"等你点一下"清扫：只驱动 SUBSTITUTING / PLACE_SUB / PLACE_BOMB。
## 为什么不能在这里等 PLAYER_INPUT：**敌方**路径的动作收尾是
## `src/Battle.gd:3249-3257` / `3478-3497` 的 `action_finished.emit()`，它发完信号就 return，
## `state` 会停在 ANIMATING——生产是 EnemyReplay 的回放循环随后收尾，而本工具自己就是驱动者，
## 没人替它收尾（实测：在这里等 PLAYER_INPUT 会让**每一个敌方回合**白等满 30s 上限）。
## 状态停在 ANIMATING 不影响 `_end_side`：它自己第一件事就是 `state = State.ANIMATING`。
func _pump_pending() -> void:
	var t0 := Time.get_ticks_msec()
	while _b != null and is_instance_valid(_b) and not GameState.match_over \
			and _is_waiting_state(int(_b.state)) \
			and Time.get_ticks_msec() - t0 < ROUND_WALL_MS:
		_drive_sub_panel()
		await _resolve_pending_bomb()
		_poll_units()
		await get_tree().process_frame

func _is_waiting_state(st: int) -> bool:
	return st == int(Battle.State.SUBSTITUTING) or st == int(Battle.State.PLACE_SUB) \
		or st == int(Battle.State.PLACE_BOMB)

# ================= 统计钩子 =================

## 把 _b.units 里"还没登记过"的单位登记进 _rows。
## 走这条路的都是**开局之后**才出现的：替补（卡组里没首发的那几个）或召唤物。
func _sync_units() -> void:
	if _b == null or not is_instance_valid(_b):
		return
	for u in _b.units:
		if u == null or not is_instance_valid(u) or _idx.has(u):
			continue
		_register(u, "替补", _half)

## 新建一行统计并挂信号。slot = 首发 / 替补 / 召唤；enter = 登场半回合序号。
## slot 由**英雄表**兜底判定：不在 `DataRegistry.heroes` 里的（骷髅兵等召唤物）一律记 `召唤`，
## 否则死灵法师那种"开局就召唤出骷髅"的单位会被当成首发，把 `P_alive_end` / 首个阵亡回合算歪。
func _register(u: Unit, slot: String, enter: int) -> void:
	if not DataRegistry.heroes.has(u.hero_id):
		slot = "召唤"
	var r := {
		"faction": u.faction, "slot": slot, "hero_id": u.hero_id, "hero_name": u.display_name,
		"enter_round": enter, "first_death_round": -1, "died": false, "alive": true,
		"death_half": -1, "dmg_dealt": 0, "dmg_taken": 0, "heal_done": 0, "kills": 0,
		"deaths": 0, "gold_taken": 0, "moves": 0, "attacks": 0,
		"status_dealt": 0, "last_dealer": -1, "last_dealer_half": -1,
	}
	_idx[u] = _rows.size()
	_rows.append(r)
	_hp_prev[u] = u.hp
	_status_now[u] = _status_set(u)
	u.hp_changed.connect(_on_hp_changed)
	u.died.connect(_on_died)

func _status_set(u: Unit) -> Dictionary:
	var d := {}
	for k in u.statuses.keys():
		d[k] = true
	return d

func _row(u) -> Dictionary:
	if u == null or not is_instance_valid(u) or not _idx.has(u):
		return {}
	return _rows[int(_idx[u])]

func _bump(u: Unit, key: String, n: int = 1) -> void:
	var r := _row(u)
	if r.is_empty():
		return
	r[key] = int(r[key]) + n

## 首发登记：建局后 _b.units 里的都是首发（enter_round=0）
func _register_starters() -> void:
	if _b == null or not is_instance_valid(_b):
		return
	for u in _b.units:
		if u == null or not is_instance_valid(u) or _idx.has(u):
			continue
		_register(u, "首发", 0)

## 每帧轮询：死亡（died 信号在淡出后 0.3s 才发，这里用 alive 翻转更准）+ 状态挂载 + 金矿拾取
func _poll_units() -> void:
	if _b == null or not is_instance_valid(_b):
		return
	_sync_units()
	for u in _b.units:
		if u == null or not is_instance_valid(u):
			continue
		var r := _row(u)
		if r.is_empty():
			continue
		if not u.alive and not bool(r["died"]):
			_record_death(u, r)
		# 状态：与上一帧的集合做差，新出现的算"被挂上"
		var now := _status_set(u)
		var prev: Dictionary = _status_now.get(u, {})
		for k in now.keys():
			if not prev.has(k):
				_note_status(u, String(k))
		_status_now[u] = now
	_poll_gold()

func _note_status(target: Unit, key: String) -> void:
	var a := _ctx_actor
	if a == null or not is_instance_valid(a) or not _idx.has(a):
		return
	if target.faction == a.faction:
		return            # 只记"施加给敌方"的状态；给己方的增益记在 heal_done/其它列里
	_bump(a, "status_dealt")
	print("R|status|half=%d|by=%s|to=%s|key=%s" % [_half, a.display_name, target.display_name, key])

## 伤害/治疗：唯一真相 = hp 变化量（真实掉血/回血；被圣盾吸收的部分**不进**这里，
## 因为 Unit.take_damage 在盾挡时直接 return，不 emit damaged、hp 也不变）。
func _on_hp_changed(u: Unit) -> void:
	if not _idx.has(u):
		return
	var before := int(_hp_prev.get(u, u.hp))
	var delta := u.hp - before
	_hp_prev[u] = u.hp
	var r := _row(u)
	if r.is_empty():
		return
	if delta < 0:
		var amt := -delta
		r["dmg_taken"] = int(r["dmg_taken"]) + amt
		var dealer := _attribute_damage(u)
		var dr := _row(dealer) if dealer != null else {}
		if dr.is_empty():
			_unattributed_dmg += amt
			r["last_dealer"] = -1
		else:
			dr["dmg_dealt"] = int(dr["dmg_dealt"]) + amt
			r["last_dealer"] = int(_idx[dealer])
		r["last_dealer_half"] = _half
	elif delta > 0:
		var h := _attribute_heal(u)
		var hr := _row(h) if h != null else {}
		if hr.is_empty():
			_unattributed_heal += delta
		else:
			hr["heal_done"] = int(hr["heal_done"]) + delta

## 归因规则（README 有完整口径）：
##   ① 反击（Unit._was_counter_damage）：伤害来自"当前这一招的目标"（被攻击者还手）；
##   ② 受击方与出手方**不同阵营** → 记在出手方头上；
##   ③ 其余（同阵营自伤/镜像/毒/烧血/炸弹/荆棘/回合外效果）→ 归因不到，单独计数。
func _attribute_damage(victim: Unit) -> Unit:
	if bool(victim._was_counter_damage) and _ctx_target != null and is_instance_valid(_ctx_target):
		return _ctx_target
	var a := _ctx_actor
	if a == null or not is_instance_valid(a):
		return null
	if victim.faction != a.faction:
		return a
	return null

## 治疗归因：只有"出手单位正在行动期间"的回血才算它的（且必须是同阵营）。
## 回合开始/结束类治疗（光环、德鲁伊回合末等）没有出手单位 → 归因不到，单独计数。
func _attribute_heal(victim: Unit) -> Unit:
	var a := _ctx_actor
	if a == null or not is_instance_valid(a):
		return null
	if victim.faction != a.faction:
		return null
	return a

## 金矿拾取：金矿格从 buff_items 里消失 + 有"能拾取金矿"的单位站在那格 → 记它一次
## （金矿也会自然风化消失，所以必须同时满足"站在格上且 can_pickup_gold()"才记）
func _poll_gold() -> void:
	var now := {}
	for c in _b.buff_items.keys():
		if String(_b.buff_items[c]) == "gold":
			now[c] = true
	for c in _gold_cells.keys():
		if now.has(c):
			continue
		var taker: Unit = null
		for u in _b.units:
			if u == null or not is_instance_valid(u) or not u.alive:
				continue
			if u.cell == c and bool(_b._hero(u).can_pickup_gold()):
				taker = u
				break
		if taker == null:
			continue
		_bump(taker, "gold_taken")
		print("R|gold|half=%d|by=%s|cell=(%d,%d)" % [_half, taker.display_name, c.x, c.y])
	_gold_cells = now

func _on_died(u: Unit) -> void:
	var r := _row(u)
	if r.is_empty() or bool(r["died"]):
		return
	_record_death(u, r)

func _record_death(u: Unit, r: Dictionary) -> void:
	r["died"] = true
	r["alive"] = false
	r["deaths"] = 1
	r["death_half"] = _half
	if int(r["first_death_round"]) < 0:
		r["first_death_round"] = _half
	# 击杀归因：优先"当前出手者"（不同阵营）；否则用**这次致命伤害的施害者**
	# （`_on_hp_changed` 记下的 last_dealer——反击/技能补刀这类发生在出手之后的情形靠它）。
	var killer_idx := -1
	var a := _ctx_actor
	if a != null and is_instance_valid(a) and _idx.has(a) and a.faction != u.faction:
		killer_idx = int(_idx[a])
	elif int(r["last_dealer"]) >= 0 and int(r["last_dealer_half"]) == _half:
		killer_idx = int(r["last_dealer"])
	var killer := ""
	if killer_idx >= 0:
		_rows[killer_idx]["kills"] = int(_rows[killer_idx]["kills"]) + 1
		killer = str(_rows[killer_idx]["hero_name"])
	else:
		_unattributed_kills += 1
	print("R|death|half=%d|fn=%d|hero=%s|slot=%s|cause=%s|by=%s" % [
		_half, u.faction, str(r["hero_id"]), str(r["slot"]), u.death_cause, killer])

# ================= 落盘 =================

func _ensure_out_dir() -> void:
	var abs_dir := _out_dir   # ⚠️ 别叫 `abs`：那是 GDScript 内置函数名（SHADOWED_GLOBAL_IDENTIFIER）
	if _out_dir.begins_with("res://") or _out_dir.begins_with("user://"):
		abs_dir = ProjectSettings.globalize_path(_out_dir)
	elif not _out_dir.is_absolute_path():
		abs_dir = ProjectSettings.globalize_path("res://").path_join(_out_dir)
		_out_dir = abs_dir
	DirAccess.make_dir_recursive_absolute(abs_dir)
	# ★ 关掉 Godot 的**资源导入扫描**：CSV 是 Godot 注册的"翻译表"格式，res:// 下的 .csv
	#   会被导入器扫成 `*.csv.import` + 一堆 `*.translation`（实测跑一局就生成上百个垃圾文件）。
	#   放一个 `.gdignore`，导入器就整目录跳过；未导出的项目里 res:// 就是磁盘目录，
	#   FileAccess 读写完全不受影响。
	var ignore := abs_dir.path_join(".gdignore")
	if not FileAccess.file_exists(ignore):
		var g := FileAccess.open(ignore, FileAccess.WRITE)
		if g != null:
			g.store_string("# Godot: skip this directory (CSV would be imported as translation tables)\n")
			g.close()

func _write_csvs() -> void:
	_write_one("matches", COLS_MATCH, _matches, "matches_%s_%s.csv" % [_tag, _run_stamp])
	_write_one("units", COLS_UNIT, _unit_out, "units_%s_%s.csv" % [_tag, _run_stamp])

## 把本局 `_rows` 转成 units.csv 的输出行并**累积**（跨局），供每局结束后的覆盖式落盘。
func _collect_unit_rows() -> void:
	if _matches.size() == 0:
		return
	var mid := String(_matches[-1]["match_id"])
	var half_end := int(_matches[-1]["half_rounds"])
	for r in _rows:
		var enter := int(r["enter_round"])
		var stop := int(r["death_half"]) if bool(r["died"]) else half_end
		_unit_out.append({
			"match_id": mid,
			"side": "P" if int(r["faction"]) == DataRegistry.Faction.PLAYER else "E",
			"slot": r["slot"], "hero_id": r["hero_id"], "hero_name": r["hero_name"],
			"enter_round": enter,
			"first_death_round": r["first_death_round"] if int(r["first_death_round"]) >= 0 else "",
			"alive_at_end": 1 if bool(r["alive"]) else 0,
			"rounds_alive": maxi(stop - enter, 0),
			"dmg_dealt": r["dmg_dealt"], "dmg_taken": r["dmg_taken"], "heal_done": r["heal_done"],
			"kills": r["kills"], "deaths": r["deaths"], "gold_taken": r["gold_taken"],
			"moves": r["moves"], "attacks": r["attacks"],
			"status_dealt": r["status_dealt"],
		})

func _write_one(kind: String, cols: Array, rows: Array, stamped_name: String) -> void:
	var lines: Array = []
	for r in rows:
		var cells: Array = []
		for c in cols:
			cells.append(_csv_cell(r.get(c, "")))
		lines.append(_join(cells, ","))
	var body := _join(cols, ",") + "\n" + _join(lines, "\n") + ("\n" if lines.size() > 0 else "")
	var paths: Array = [_out_dir.path_join(stamped_name)]
	if OS.get_environment("ZB_NO_MIRROR") != "1":
		paths.append(_out_dir.path_join("%s.csv" % kind))    # 固定名镜像（并行跑要设 ZB_NO_MIRROR=1 关掉）
	for p in paths:
		var path := String(p)
		var f := FileAccess.open(path, FileAccess.WRITE)
		if f == null:
			push_error("[对局统计] 写不了 %s（err=%d）" % [path, FileAccess.get_open_error()])
			continue
		f.store_buffer(char(0xFEFF).to_utf8_buffer())        # UTF-8 BOM：Excel 直接打开不乱码
		f.store_string(body)
		f.flush()
		f.close()
		print("R|csv|%s|rows=%d|path=%s" % [kind, rows.size(), path])

func _csv_cell(v) -> String:
	# 注意：只能用 str()，不能用 String(v)——GDScript 的 String 构造器不接受 int/bool
	# （`String(5)` 会报 "Nonexistent 'String' constructor"）。
	var s := str(v)
	if s.contains(",") or s.contains("\"") or s.contains("\n"):
		return "\"%s\"" % s.replace("\"", "\"\"")
	return s

func _join(a: Array, sep: String) -> String:
	var out := ""
	for i in a.size():
		if i > 0:
			out += sep
		out += str(a[i])
	return out

func _to_strs(a: Array) -> Array:
	var out: Array = []
	for v in a:
		out.append(str(v))
	return out

func _stamp_txt() -> String:
	var d := Time.get_datetime_dict_from_system(false)
	return "%02d%02d_%02d%02d%02d" % [int(d["month"]), int(d["day"]), int(d["hour"]),
		int(d["minute"]), int(d["second"])]

# ================= 小工具 =================

func _load_w(path: String) -> Dictionary:
	if path == "" or path == "-" or path == "base" or not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var txt := f.get_as_text()
	f.close()
	var d = JSON.parse_string(txt)
	return d if typeof(d) == TYPE_DICTIONARY else {}

## 权重列的可复现标签：路径（或 base/default）+ 文件 sha256 前 12 位
func _w_label(path: String) -> String:
	if path == "base":
		return "base"
	if not FileAccess.file_exists(path):
		return "default"
	return "%s#%s" % [path, _sha(path)]

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

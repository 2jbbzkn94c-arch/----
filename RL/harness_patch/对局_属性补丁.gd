extends Node
## RL 对局引擎 v2：在**真实 scenes/Main.tscn** 上跑整局，双方动作都走真实 Battle 的
## `_do_move/_do_attack/_do_attack_obstacle`（与生产 EnemyReplay 的执行语义一致），
## 规则全部由真实 Battle 结算，本文件不实现任何规则。
##
## A 方 = 候选（`RL/ai/AI_Battle.gd`，默认权重 = 原常量同值）；B 方 = 对手：
##   opp=cand : 对手也用 fork（旧行为，训练自对弈用）
##   opp=base : 对手用 `RL/ai/AI_Battle_原版.gd`（与 `src/BattleAI.gd` 逐字节同源）
##              → 即生产"困难档"（difficulty=2 → beam 800 / jitter 0）
##
## 用法：
##   godot --headless --path <proj> --log-file <log> --scene res://RL/harness/对局.tscn -- \
##        <seeds> <seed0> <edeck> <pdeck> <wA> <wB> [<beamA> <beamB>] [<opp> <first>]
##   first: p=玩家方先手(默认) / e=敌方先手 / both=两种都打（每 seed 4 局：阵营×先手全覆盖）
##
## 输出（供统计解析）：
##   R|cfg|...
##   R|m|seed=..|a_side=..|first=..|res=W/L/D|killsA=..|killsB=..|rounds=..|ptsA=..|ptsB=..|dmgA=..|dmgB=..|hpA=..|hpB=..|over=..
##   R|SUMMARY|games=..|w=..|l=..|d=..|ptsA=..|ptsB=..|search_ms_max=..|wall_s=..
##
## 注意：权重文件是平铺 JSON（键 = KILL_BONUS / FOCUS_FIRE_WEIGHT / ... / BEAM / JITTER）。

const FORK := preload("res://RL/ai/AI_Battle.gd")
const BASE := preload("res://RL/ai/AI_Battle_原版.gd")

const P_CELLS: Array[Vector2i] = [Vector2i(1, 4), Vector2i(3, 4), Vector2i(1, 5)]
const E_CELLS: Array[Vector2i] = [Vector2i(1, 2), Vector2i(3, 2), Vector2i(1, 1)]
const MAX_HALF := 40            # 半回合上限（防跑飞；正常 3 杀判负远小于此）
const ACT_WALL_MS := 400        # 等一招动画的上限（scale=20 下生产侧等效约 150ms）
const READY_WALL_MS := 30000

var _b: Battle = null
var _e_deck: Array = ["hero_06", "hero_17", "hero_26"]
var _p_deck: Array = ["hero_13", "hero_12", "hero_23"]
var _wA: Dictionary = {}        # 候选权重（A 方，空 = 默认常量）
var _wB: Dictionary = {}        # 对手权重（仅 opp=cand 时生效）
var _beamA := 800               # 候选算力（默认 800 = 生产困难档同档）
var _beamB := 800
var _opp := "cand"              # cand / base
var _first_mode := "p"          # p / e / both

var _sum := { "games": 0, "w": 0, "l": 0, "d": 0, "ptsA": 0.0, "ptsB": 0.0, "ms_max": 0 }
var _game_ms_max := 0           # 本局单次思考最久的毫秒（每局清零；纯取证，见 `_ai_side`）
# ---- 【2026-09-25 新增】每单位账本（**纯取证**：只加 print，不改任何判定/权重/流程）----
#   为什么：`measure.csv` 只有局级账 ⇒ 想问"某个英雄值多少分/哪一列最能预测胜负"就得每次专门挂批。
#   有了它，**每个批都自带英雄级数据**（池子批/难度批/剂量批全都能反哺平衡），见
#   `RL/reports/英雄平衡_初筛_pool3_20260925.md` 的"下一步 · 第 2 步"。
#   口径：`dealt/taken` 读 `Unit.damaged(受击者, 实际伤害)` 信号（圣盾/坚固/塔盾代扛之后的值），
#   归因规则 = **一招之内只有发起者与目标两人**：伤害落在目标身上记给发起者，落在发起者身上记给目标
#   （= 反击）。毒/烧血/炸弹这类没有发起者的记为"环境伤"（不计入任何人的 dealt）。
var _led: Dictionary = {}       # unit 实例 id -> 统计字典
var _led_actor: Unit = null     # 当前这一招的发起者
var _led_target: Unit = null    # 当前这一招的目标
var _led_round := 0

func _ready() -> void:
	_watchdog()
	_run.call_deferred()

## 墙钟看门狗：脚本异常/建局卡死时也能退出并留下痕迹（无头跑没有人工中断）
func _watchdog() -> void:
	var limit_ms := 1800 * 1000
	while Time.get_ticks_msec() < limit_ms:
		await get_tree().process_frame
	print("R|WATCHDOG|wall_s=%d" % (limit_ms / 1000))
	get_tree().quit(3)

func _run() -> void:
	var ua := OS.get_cmdline_user_args()
	var pairs := int(ua[0]) if ua.size() > 0 else 4
	var seed0 := int(ua[1]) if ua.size() > 1 else 10000
	if ua.size() > 2 and String(ua[2]) != "-":
		_e_deck = String(ua[2]).split(",")
	if ua.size() > 3 and String(ua[3]) != "-":
		_p_deck = String(ua[3]).split(",")
	_wA = _load_w(String(ua[4])) if ua.size() > 4 else {}
	_wB = _load_w(String(ua[5])) if ua.size() > 5 else {}
	if ua.size() > 6:
		_beamA = int(ua[6])
	if ua.size() > 7:
		_beamB = int(ua[7])
	if ua.size() > 8 and String(ua[8]) != "-":
		_opp = String(ua[8])
	if ua.size() > 9 and String(ua[9]) != "-":
		_first_mode = String(ua[9])
	if ua.size() > 11 and String(ua[11]) != "-":
		_apply_stat_patch(String(ua[11]))   # 第 12 个参数 = 属性补丁（不传/`-` ⇒ 逐位不变）
	var firsts: Array = [GameState.SIDE_PLAYER]
	if _first_mode == "e":
		firsts = [GameState.SIDE_ENEMY]
	elif _first_mode == "both":
		firsts = [GameState.SIDE_PLAYER, GameState.SIDE_ENEMY]
	# 只打某一侧（配合"一局一个进程"跑法：长对局里若某个英雄组合把引擎搞崩，
	# 崩也只丢那一局，不影响已落盘的结果）
	var asides: Array = [DataRegistry.Faction.ENEMY, DataRegistry.Faction.PLAYER]
	if ua.size() > 10:
		if String(ua[10]) == "p":
			asides = [DataRegistry.Faction.PLAYER]
		elif String(ua[10]) == "e":
			asides = [DataRegistry.Faction.ENEMY]
	print("R|cfg|seeds=%d|seed0=%d|edeck=%s|pdeck=%s|beamA=%d|beamB=%d|opp=%s|first=%s|nA=%d|nB=%d|fork_sha=%s|base_sha=%s" % [
		pairs, seed0, str(_e_deck), str(_p_deck), _beamA, _beamB, _opp, _first_mode, _wA.size(), _wB.size(),
		_sha("res://RL/ai/AI_Battle.gd"), _sha("res://RL/ai/AI_Battle_原版.gd")])
	var t_all := Time.get_ticks_msec()
	for i in pairs:
		var sd := seed0 + i
		for first in firsts:
			# 每个 seed×先手 打 2 局：A 先当敌方、再当玩家方（阵营对称）
			for a_side in asides:
				await _play(sd, a_side, int(first))
	print("R|SUMMARY|games=%d|w=%d|l=%d|d=%d|ptsA=%.2f|ptsB=%.2f|search_ms_max=%d|wall_s=%.1f" % [
		int(_sum["games"]), int(_sum["w"]), int(_sum["l"]), int(_sum["d"]),
		float(_sum["ptsA"]), float(_sum["ptsB"]), int(_sum["ms_max"]),
		(Time.get_ticks_msec() - t_all) / 1000.0])
	print("R|END")
	get_tree().quit(0)

# ---------------- 一局 ----------------

## a_side = 候选（A）这一方扮演的阵营；first_side = 谁先手
func _play(seed_v: int, a_side: int, first_side: int) -> Dictionary:
	var t_game := Time.get_ticks_msec()   # 本局墙钟起点（打印在 R|m| 的 ms= 上）
	_game_ms_max = 0                      # 本局"单次思考最久"（_ai_side 里累计，打印在 msmax= 上）
	await _setup(seed_v, first_side)
	var hp0 := _side_hp()
	_led_begin()
	var rounds := 0
	while not GameState.match_over and rounds < MAX_HALF:
		var side: int = GameState.active_side
		_b.turn_time_left = 0.0
		_b.peer_turn_time_left = 0.0
		await _ai_side(side, a_side)
		if GameState.match_over:
			break
		await _b._end_side(side)
		rounds += 1
		_led_tick_round()
		if _b.state != Battle.State.PLAYER_INPUT and not GameState.match_over:
			var t0 := Time.get_ticks_msec()
			while _b.state != Battle.State.PLAYER_INPUT and not GameState.match_over \
					and Time.get_ticks_msec() - t0 < READY_WALL_MS:
				await get_tree().process_frame
	var hp := _side_hp()
	_led_print(seed_v, a_side, first_side)
	var out := {
		"seed": seed_v, "a_side": a_side, "first": first_side,
		"pd": _b.player_dead, "ed": _b.enemy_dead,
		"rounds": rounds, "over": GameState.match_over,
		"hpP": hp[DataRegistry.Faction.PLAYER], "hpE": hp[DataRegistry.Faction.ENEMY],
		"hpP0": hp0[DataRegistry.Faction.PLAYER], "hpE0": hp0[DataRegistry.Faction.ENEMY],
		"subP": _b.player_roster.size(), "subE": _b.enemy_roster.size(),
	}
	await _teardown()
	var a_is_enemy: bool = a_side == DataRegistry.Faction.ENEMY
	var dmgA: int = (int(out["hpP0"]) - int(out["hpP"])) if a_is_enemy else (int(out["hpE0"]) - int(out["hpE"]))
	var dmgB: int = (int(out["hpE0"]) - int(out["hpE"])) if a_is_enemy else (int(out["hpP0"]) - int(out["hpP"]))
	# 统一按"A 方视角"打印
	var hpA: int = int(out["hpE"]) if a_is_enemy else int(out["hpP"])
	var hpB: int = int(out["hpP"]) if a_is_enemy else int(out["hpE"])
	var hpA0: int = int(out["hpE0"]) if a_is_enemy else int(out["hpP0"])
	var hpB0: int = int(out["hpP0"]) if a_is_enemy else int(out["hpE0"])
	var subA: int = int(out["subE"]) if a_is_enemy else int(out["subP"])
	var subB: int = int(out["subP"]) if a_is_enemy else int(out["subE"])
	out["dmgA"] = dmgA
	out["dmgB"] = dmgB
	out["hpA"] = hpA
	out["hpB"] = hpB
	out["hpA0"] = hpA0
	out["hpB0"] = hpB0
	out["subA"] = subA
	out["subB"] = subB
	var fn_a: int = DataRegistry.Faction.ENEMY if a_is_enemy else DataRegistry.Faction.PLAYER
	var fn_b: int = DataRegistry.Faction.PLAYER if a_is_enemy else DataRegistry.Faction.ENEMY
	var ptsA: float = _pts(out, fn_a)
	var ptsB: float = _pts(out, fn_b)
	var killsA: int = int(out["pd"]) if a_is_enemy else int(out["ed"])
	var killsB: int = int(out["ed"]) if a_is_enemy else int(out["pd"])
	var res := "D"
	if bool(out["over"]):
		if killsA >= Battle.LOSS_DEATH_COUNT and killsB < Battle.LOSS_DEATH_COUNT:
			res = "W"
		elif killsB >= Battle.LOSS_DEATH_COUNT and killsA < Battle.LOSS_DEATH_COUNT:
			res = "L"
	# 平局/超时/同归于尽都记 D（同归于尽在真实规则里判"本端胜"，这里不采纳以免偏袒）
	# 【2026-09-25 用户要求「统计一下每一局的时间有没有异常」】`R|m|` 行末尾补两个**纯取证**字段
	#   （key=value 解析 ⇒ 自动进 `measure.csv` 新列，不改任何既有列/判定）：
	#   `ms` = 这一局从建局到收尾的墙钟毫秒 · `msmax` = 这一局**单次思考最久**的那一步（AI 搜索 ms）。
	#   ⚠️ `msmax` 才是能和实战比的数：本 harness 把 `time_budget_ms` 设成 0（不限时、可复现），
	#   而生产噩梦档是 `TIME_BUDGET_MS = 40000` ⇒ `msmax > 40000` 的那些步在实战里会被超时截断
	#   （后半段转 `_greedy_finish()` 贪心收尾），那正是"时间异常"的判据。
	print("R|m|seed=%d|a_side=%d|first=%d|res=%s|killsA=%d|killsB=%d|rounds=%d|ptsA=%.2f|ptsB=%.2f|dmgA=%d|dmgB=%d|hpA=%d|hpB=%d|over=%s|subA=%d|subB=%d|ms=%d|msmax=%d" % [
		seed_v, a_side, first_side, res, killsA, killsB, rounds, ptsA, ptsB, dmgA, dmgB, hpA, hpB,
		str(bool(out["over"])), subA, subB,
		Time.get_ticks_msec() - t_game, _game_ms_max])
	_sum["games"] = int(_sum["games"]) + 1
	_sum["ptsA"] = float(_sum["ptsA"]) + ptsA
	_sum["ptsB"] = float(_sum["ptsB"]) + ptsB
	_sum[res.to_lower()] = int(_sum[res.to_lower()]) + 1
	return out

## 战局优势分（指定阵营视角）。公式为已确认版本：
##   ±胜负(±20) + 击杀差×3 + 净伤害差/对手总血量×10 + 剩余血量差/本方总血量×6 + 替补差×2 − 回合数×0.3
func _pts(r: Dictionary, fn: int) -> float:
	var is_enemy: bool = fn == DataRegistry.Faction.ENEMY
	var my_kills: float = float(r["pd"] if is_enemy else r["ed"])
	var their_kills: float = float(r["ed"] if is_enemy else r["pd"])
	var my_hp: float = float(r["hpP"] if is_enemy else r["hpE"])
	var their_hp: float = float(r["hpE"] if is_enemy else r["hpP"])
	var my_hp0: float = float(r["hpP0"] if is_enemy else r["hpE0"])
	var their_hp0: float = float(r["hpE0"] if is_enemy else r["hpP0"])
	var my_dmg: float = 0.0
	var their_dmg: float = 0.0
	var a_side := int(r["a_side"])
	if fn == a_side:
		my_dmg = float(r["dmgA"])
		their_dmg = float(r["dmgB"])
	else:
		my_dmg = float(r["dmgB"])
		their_dmg = float(r["dmgA"])
	var my_sub: float = float(r["subP"] if is_enemy else r["subE"])
	var their_sub: float = float(r["subE"] if is_enemy else r["subP"])
	var pts := (my_kills - their_kills) * 3.0
	if bool(r["over"]):
		if my_kills >= 3.0 and their_kills < 3.0:
			pts += 20.0
		elif their_kills >= 3.0 and my_kills < 3.0:
			pts -= 20.0
	pts += (my_dmg - their_dmg) / maxf(their_hp0, 1.0) * 10.0
	pts += (my_hp - their_hp) / maxf(my_hp0, 1.0) * 6.0
	pts += (my_sub - their_sub) * 2.0
	pts -= 0.3 * float(r["rounds"])
	return pts

# ---------------- AI 驱动（A=候选 / B=对手） ----------------

## 让 AI 替 side 这一方规划。fork 把 ENEMY 当"我方"，所以替玩家方规划时要把阵营标签对调
## （镜像法：只改喂给 AI 的副本描述，refs/下标不动，动作照旧作用在正确单位上）。
func _ai_side(side: int, a_side: int) -> void:
	var fn := _b.side_faction(side)
	var snap: Dictionary = BattleSnapshot.collect(_b)
	var refs: Array = _b.units.duplicate()
	var is_a: bool = fn == a_side
	var ai                              # BattleAI(RefCounted，非 Node)：fork 或原版副本
	if is_a or _opp == "cand":
		# 候选（A）恒用 fork；opp=cand 时对手也用 fork（可注入不同权重，训练自对弈）
		ai = FORK.new(_b.grid)
		ai.set_weights(_wA if is_a else _wB)
		ai.w_beam = _beamA if is_a else _beamB
		# ★ 2026-09-14 修：**必须**给候选设 difficulty。fork 的 _beam()/_jitter() 都是
		#   `if difficulty >= 2: return w_beam / w_jitter`，difficulty 默认是 1 → 候选会恒用
		#   beam 300 + `randf_range(-1.5, 1.5)` 随机抖动，注入的 BEAM/JITTER 全被忽略
		#   （实测：JITTER 0→0.5 在 32 局里逐局完全相同；所有候选侧 beam 臂其实都跑在 300）。
		#   生产噩梦档走的是 `Battle._make_battle_ai()` → `ai.difficulty = 3`，本来就是 >=2，
		#   所以生产没这个毛病；只有本 harness 漏了，导致"训练口径 ≠ 生产口径"。
		ai.difficulty = 2                      # 与生产噩梦档同口径：beam 用 w_beam、抖动用 w_jitter（默认 0 = 可复现）
	else:
		# 生产困难档对手：用与 src/BattleAI.gd 逐字节同源的副本
		ai = BASE.new(_b.grid)
		ai.difficulty = 2                      # 困难档口径（生产困难档对手）
	ai.log_decisions = false
	ai.time_budget_ms = 0                  # 不限时：自然搜完 → 可复现（实测远低于生产 10s 上限）
	var descs: Array = snap["descs"]
	if fn != DataRegistry.Faction.ENEMY:
		descs = _relabel(descs)            # 替玩家方规划：对调 fn 标签
	var sim = ai.build_state(descs, snap["occ"], snap["gold"], snap["grave"],
			snap["obstacle"], snap["bomb"], snap["buff"], -1, {}, {}, snap.get("buff_owner", {}))
	# ⚠️ 第 9/10 参（rosters / auto_sub）**保持不传**（= {}）：harness 的对局从不发生替补
	#   （`measure.csv` 里 subA/subB 恒 0），传了会让模拟"预测替补登场及其登场效果"、
	#   凭空改变跑批里的 AI 决策 ⇒ 与本批历史读数不可比。只补第 11 参 `buff_owner`（道具归属）。
	var t_s := Time.get_ticks_msec()
	var plan: Array = ai.search(sim, DataRegistry.Faction.ENEMY)
	var el := Time.get_ticks_msec() - t_s
	if el > int(_sum["ms_max"]):
		_sum["ms_max"] = el
	if el > _game_ms_max:
		_game_ms_max = el      # 本局最久的一次思考（`R|m|` 的 msmax=，与生产 40s 上限对比用）
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
			_led_note(u, "moves")
			await _act_and_wait(func() -> void: _b._do_move(u, a["move"], fn == DataRegistry.Faction.ENEMY))
			_resolve_pending_bomb()
		if a.has("atk_obs"):
			_led_note(u, "obs")
			await _act_and_wait(func() -> void: _b._do_attack_obstacle(u, a["atk_obs"], fn == DataRegistry.Faction.ENEMY))
		if a.has("atk") and int(a["atk"]) >= 0:
			var ti := int(a["atk"])
			if ti >= 0 and ti < refs.size() and is_instance_valid(refs[ti]):
				var t: Unit = refs[ti]
				if t.alive and t.faction != fn and _b._in_attack_range(u, t):
					_led_note(u, "attacks")
					_led_actor = u
					_led_target = t
					await _act_and_wait(func() -> void: _b._do_attack(u, t, fn == DataRegistry.Faction.ENEMY))
					if not is_instance_valid(t) or not t.alive:   # 目标已 free/已死 ⇒ 这一招是击杀
						_led_note(u, "kills")
					_led_actor = null
					_led_target = null

## 玩家侧的炸弹人（hero_35）在真实游戏里是"移动后由玩家点格放雷"；对局引擎里没有手，
## 所以这里调**英雄自己的** `bomb_place_cells()` + `_frontest()`（与单机敌方 AI 分支同一套规则）
## 再走 `_try_place_bomb` 落子 —— 不新增任何策略，只替代"人手点击"。
## 双方各当一次玩家方，故这一接管对两个 AI 完全对称。
func _resolve_pending_bomb() -> void:
	if _b == null or not is_instance_valid(_b):
		return
	if _b.state != Battle.State.PLACE_BOMB or _b._pending_bomb_unit == null:
		return
	var u: Unit = _b._pending_bomb_unit
	var hero = _b._hero(u)
	var cells: Array = hero.bomb_place_cells()
	if cells.is_empty():
		print("R|WARN|bomb_no_cell|u=%s" % u.display_name)
		return
	_b._try_place_bomb(hero._frontest(cells))

func _relabel(descs: Array) -> Array:
	# 对调 fn 之外，还必须显式给出**真实**的 row（出生侧基线）：
	# 否则 build_state 会按对调后的标签算 row，"推进度"方向会被反过来，
	# 导致玩家方一路后退。row 的语义是"该单位本方底线在棋盘哪一行"。
	var out: Array = []
	for d in descs:
		var dd: Dictionary = (d as Dictionary).duplicate()
		var f := int(dd["fn"])
		var true_enemy: bool = f == DataRegistry.Faction.ENEMY
		dd["row"] = 0 if true_enemy else _b.grid.height - 1
		dd["fn"] = DataRegistry.Faction.PLAYER if true_enemy else DataRegistry.Faction.ENEMY
		out.append(dd)
	return out

# ---------------- 建局 / 工具 ----------------

func _setup(seed_v: int, first_side: int) -> void:
	Engine.time_scale = 20.0
	GameState.reset_online()
	GameState.dual_control = true          # 关键：不让 _begin_side(ENEMY) 自动跑生产 AI
	GameState.no_death_limit = false
	GameState.arena_mode = false
	GameState.pick_deck_in_battle = false
	GameState.match_over = false
	GameState.ai_difficulty = 2
	GameState.clear_placement()
	for i in P_CELLS.size():
		GameState.player_placement[P_CELLS[i]] = _p_deck[i]
	for i in E_CELLS.size():
		GameState.enemy_placement[E_CELLS[i]] = _e_deck[i]
	GameState.player_deck = _p_deck.duplicate()
	GameState.enemy_deck = _e_deck.duplicate()
	_b = load("res://scenes/Main.tscn").instantiate() as Battle
	_b.set_random_seed(seed_v)
	_b._first_side = first_side
	get_tree().root.add_child(_b)
	var t0 := Time.get_ticks_msec()
	while _b.state != Battle.State.PLAYER_INPUT and Time.get_ticks_msec() - t0 < READY_WALL_MS:
		await get_tree().process_frame

func _teardown() -> void:
	Engine.time_scale = 1.0
	if _b != null and is_instance_valid(_b):
		_b.queue_free()
	_b = null
	await get_tree().process_frame
	await get_tree().process_frame

func _act_and_wait(cb: Callable) -> void:
	var done: Array = [false]
	var h := func() -> void: done[0] = true
	_b.action_finished.connect(h, CONNECT_ONE_SHOT)
	cb.call()
	var t0 := Time.get_ticks_msec()
	while not done[0] and Time.get_ticks_msec() - t0 < ACT_WALL_MS:
		await get_tree().process_frame
	if not done[0] and is_instance_valid(_b) and _b.action_finished.is_connected(h):
		_b.action_finished.disconnect(h)

func _side_hp() -> Dictionary:
	var out := { DataRegistry.Faction.PLAYER: 0, DataRegistry.Faction.ENEMY: 0 }
	for u in _b.units:
		if u != null and is_instance_valid(u) and u.alive:
			out[u.faction] += u.hp
	return out

func _load_w(path: String) -> Dictionary:
	if path == "" or path == "-" or not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var txt := f.get_as_text()
	f.close()
	var d = JSON.parse_string(txt)
	return d if typeof(d) == TYPE_DICTIONARY else {}

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

# ---------------- 【本副本新增】属性补丁（只影响测量，不改游戏数据）----------------
## 用法：命令行第 12 个用户参数 = `hero_43:atk+1,hp-3;hero_11:hp+3`（不传 ⇒ 与 `RL/harness/对局.gd` 逐位相同）
func _apply_stat_patch(spec: String) -> void:
	for part in spec.split(";"):
		var p := String(part).strip_edges()
		if p == "":
			continue
		var bits := p.split(":")
		if bits.size() != 2:
			continue
		var hid := String(bits[0]).strip_edges()
		var def = DataRegistry.heroes.get(hid, null)
		if def == null:
			push_warning("属性补丁：找不到 " + hid)
			continue
		for kv in String(bits[1]).split(","):
			var s := String(kv).strip_edges()
			var sign := 1
			if s.begins_with("-"):
				sign = -1
				s = s.substr(1)
			elif s.begins_with("+"):
				s = s.substr(1)
			if s.begins_with("atk"):
				def.atk = int(def.atk) + sign * int(s.substr(3))
			elif s.begins_with("hp"):
				def.max_hp = int(def.max_hp) + sign * int(s.substr(2))
		print("PATCH|%s|atk=%d|max_hp=%d" % [hid, int(def.atk), int(def.max_hp)])

# ---------------- 每单位账本（见文件上方 `_led` 处说明；纯取证，不改任何判定）----------------

## 账本键：优先用 `Unit.id`（引擎自增、全生命周期唯一）；拿不到才退回 instance id。
## ⚠️ 不能用 instance id 当键：单位阵亡后会被 `queue_free()`，**实例 id 会被回收**，
##   后建的实例可能撞上老键 ⇒ 实测出现 `hp_end=32 > max=18` 的串账。
func _led_key(u: Unit) -> String:
	if u == null or not is_instance_valid(u):
		return ""
	return u.id if u.id != "" else ("obj%d" % u.get_instance_id())

func _led_begin() -> void:
	_led.clear()
	_led_actor = null
	_led_target = null
	_led_round = 0
	if _b == null:
		return
	for u in _b.units:
		if u == null or not is_instance_valid(u):
			continue
		_led[_led_key(u)] = {
			"u": u,
			"hero": u.hero_id, "fn": u.faction, "max_hp": u.max_hp, "hp0": u.hp,
			"hp_end": u.hp, "alive_end": true, "rounds": 0, "death_round": -1,
			"dealt": 0, "taken": 0, "kills": 0, "attacks": 0, "moves": 0, "obs": 0,
		}
		if not u.damaged.is_connected(_led_on_damaged):
			u.damaged.connect(_led_on_damaged)

## 受击回调：记"吃伤"；并按"一招之内只有发起者与目标两人"把伤害记给打的人（反击记给被攻击者）
func _led_on_damaged(victim: Unit, amount: int) -> void:
	if victim == null or not is_instance_valid(victim):
		return
	var vr = _led.get(_led_key(victim))
	if vr != null:
		vr["taken"] = int(vr["taken"]) + amount
	var src: Unit = null
	if _led_target != null and is_instance_valid(_led_target) and victim == _led_target:
		src = _led_actor
	elif _led_actor != null and is_instance_valid(_led_actor) and victim == _led_actor:
		src = _led_target
	if src == null or not is_instance_valid(src):
		return
	var sr = _led.get(_led_key(src))
	if sr != null:
		sr["dealt"] = int(sr["dealt"]) + amount

func _led_note(u: Unit, key: String) -> void:
	if u == null or not is_instance_valid(u):
		return
	var r = _led.get(_led_key(u))
	if r != null:
		r[key] = int(r[key]) + 1

func _led_tick_round() -> void:
	_led_round += 1
	if _b == null or not is_instance_valid(_b):
		return
	# ⚠️ 遍历**自己的记录**、不遍历 `_b.units`：实测阵亡单位会被移出 `_b.units`（甚至被 free）
	#   ⇒ 靠 `_b.units` 会把它整行漏掉（第一次冒烟：6 个单位只打出 1 行）。
	for k in _led.keys():
		var r: Dictionary = _led[k]
		var u = r.get("u", null)
		if u != null and is_instance_valid(u) and u.alive:
			r["rounds"] = int(r["rounds"]) + 1
			r["hp_end"] = u.hp
			r["alive_end"] = true
		else:
			r["alive_end"] = false
			if int(r["death_round"]) < 0:
				r["death_round"] = _led_round

## 每局每个单位一行 `R|u|...`（解析见 `RL/train/单位账本.ps1`）
func _led_print(seed_v: int, a_side: int, first_side: int) -> void:
	if _b == null or not is_instance_valid(_b) or _led.is_empty():
		return
	for k in _led.keys():
		var r: Dictionary = _led[k]
		print("R|u|seed=%d|a_side=%d|first=%d|fn=%s|hero=%s|hp0=%d|max=%d|hp_end=%d|alive=%d|rounds=%d|death_round=%d|dealt=%d|taken=%d|kills=%d|attacks=%d|moves=%d|obs=%d" % [
			seed_v, a_side, first_side,
			("E" if int(r["fn"]) == DataRegistry.Faction.ENEMY else "P"),
			str(r["hero"]), int(r["hp0"]), int(r["max_hp"]), int(r["hp_end"]),
			(1 if bool(r["alive_end"]) else 0), int(r["rounds"]), int(r["death_round"]),
			int(r["dealt"]), int(r["taken"]), int(r["kills"]), int(r["attacks"]),
			int(r["moves"]), int(r["obs"])])

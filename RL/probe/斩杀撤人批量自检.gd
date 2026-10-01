extends Node
## 【2026-10-01·用户「你自己能不能跑一下训练，我不想自己一次一次试了。你就模拟一大堆能斩杀玩家的
##   情况，然后你自己去看看 AI 会不会主动撤人来斩杀玩家」】**随机批量自检**。
##
## 做法：随机生成 `N_CASES` 个局面（固定种子 ⇒ 可复现），每个局面：
##   ① 跑 `_ai_finish_withdraw_pick()` 看它**撤不撤**；
##   ② 撤了就 `await _ai_finish_withdraw_apply()`，跑完"撤下 → 替补落位 → 补那一刀"；
##   ③ 比对**玩家方阵亡数**有没有真的增加（= 到底斩杀了没有）。
##
## 四个统计口径（这才是用户要的答案）：
##   · `违规`：**硬门该拦却撤了** —— `玩家已死 + 本回合可撤次数 < 判负线`（这一局根本收不掉），
##     按 2026-10-01 的规则**必须不撤**。**这个数必须是 0**。
##   · `白撤`：撤了，但**玩家一个都没多死** ⇒ 纯亏一个阵亡（用户最恨的就是这个）。**必须是 0**。
##   · `斩杀`：撤了，且玩家方阵亡数**真的增加了** ⇒ 这一刀成了。
##   · `漏判`：硬门该放（`玩家已死 + 可撤次数 ≥ 判负线`）且"粗判够得到"（玩家场上最低血 ≤
##     动态池里最高的面板攻击力），但 AI **没撤**。⚠️ 粗判**不含**倍率/坚固/距离/嘲讽门 ⇒ 会有误报，
##     只当"值得人工看一眼"的清单。
##
## ⚠️ 与 `斩杀撤人全盘自检` 的区别：那个是**我手写的 31 个定点局面**（回归用）；本探针是
##   **随机撒 60 个**，用来回答"AI 到底会不会主动撤人斩杀"这个概率性问题。

const SEED := 20261001
const N_CASES := 60
const WEIGHTS := "res://RL/weights/噩梦.json"
# 玩家方阵亡数 / 我方阵亡数 / 玩家在场人数 / 我方在场人数 的取样范围
const PD_CHOICES := [0, 1, 2]
const ED_CHOICES := [0, 1]
const FOE_MIN := 1
const FOE_MAX := 3
const MINE_MIN := 1
const MINE_MAX := 3

var battle: Battle
var _rng := RandomNumberGenerator.new()
var _n_violate := 0      # 违规：硬门该拦却撤了
var _n_white := 0        # 白撤：撤了但一个都没多死
var _n_kill := 0         # 斩杀：撤了且真的多死了
var _n_missed := 0       # 漏判：该放且粗判够得到，却没撤
var _n_gate_ok := 0      # 硬门放行的局面数（漏判的分母）
var _bad_violate: Array = []
var _bad_white: Array = []
var _bad_missed: Array = []

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	_rng.seed = SEED
	print("B|CFG|seed=%d|cases=%d|weights=%s" % [SEED, N_CASES, WEIGHTS])
	for i in N_CASES:
		await _run_one(i)
	print("B|END|违规=%d 白撤=%d 斩杀=%d 漏判=%d（硬门放行 %d 例）" % [
		_n_violate, _n_white, _n_kill, _n_missed, _n_gate_ok])
	for row in _bad_violate.slice(0, 5):
		print("B|违规样本|%s" % String(row))
	for row in _bad_white.slice(0, 5):
		print("B|白撤样本|%s" % String(row))
	for row in _bad_missed.slice(0, 8):
		print("B|漏判样本|%s" % String(row))
	get_tree().quit(0)

# ---------------------------------------------------------------- 单个局面
func _run_one(ci: int) -> void:
	await _fresh()
	GameState.enemy_recipe = { "dynamic_bench": true }   # 走动态替补池（全英雄池 − 本局已出现过的）
	battle.enemy_roster = []
	GameState.no_death_limit = false
	var pdead: int = PD_CHOICES[_rng.randi() % PD_CHOICES.size()]
	var edead: int = ED_CHOICES[_rng.randi() % ED_CHOICES.size()]
	battle.player_dead = pdead
	battle.enemy_dead = edead
	battle._finish_withdraw_used = 0
	var n_foe := FOE_MIN + _rng.randi() % (FOE_MAX - FOE_MIN + 1)
	var n_mine := MINE_MIN + _rng.randi() % (MINE_MAX - MINE_MIN + 1)
	# 玩家方：血 1~12，散在中场/下半（y 2~6）
	var foe_hps: Array = []
	for k in n_foe:
		var hp := 1 + _rng.randi() % 12
		var cell := _rand_free_cell(0, 4, 1 + k * 2, 6)
		if cell.x < 0:
			continue
		var u := _spawn("hero_10", DataRegistry.Faction.PLAYER, cell)
		if u != null:
			u.hp = hp
			foe_hps.append(hp)
	# 我方：散在上半（y 0~3），标成"本回合已出手"（这正是该被撤的那批）
	for k in n_mine:
		var cell := _rand_free_cell(0, 4, 0, 3)
		if cell.x < 0:
			continue
		var mu := _spawn("hero_11", DataRegistry.Faction.ENEMY, cell)
		if mu != null:
			mu.attacked_this_turn = true
	for i in 3:
		await get_tree().process_frame
	if foe_hps.is_empty() or battle.units.size() < 2:
		return   # 这个随机局面没摆成，跳过（不计入任何统计）
	var hp_txt := []
	for f in battle.units:
		if f != null and is_instance_valid(f) and f.alive and f.faction == DataRegistry.Faction.PLAYER:
			hp_txt.append(int(f.hp))
	hp_txt.sort()
	# ⚠️ 与新硬门**同一把尺**：可撤次数还要夹到"场上活着的玩家单位数"
	#   （`Battle._ai_finish_withdraw_pick()` 里那道门就是这么算的）。
	var gate_ok := (pdead + mini(battle._finish_gate_mult(), hp_txt.size())) >= battle.LOSS_DEATH_COUNT
	# ---- 跑 pick ----
	battle._ai_finish_withdraw_pick()
	var decided := battle._finish_withdraw_target != null
	var who := ""
	if decided:
		var v := battle._finish_withdraw_victim_unit
		who = (str(v.display_name) if (v != null and is_instance_valid(v)) else "?") + "→" + String(battle._finish_withdraw_hero)
	var pd0: int = battle.player_dead
	var killed := false
	if decided:
		# 【2026-10-01】跑满"最多撤两个"那两轮 —— 与 `_run_enemy_turn()` 的调用点**同一套循环**
		#   （否则"两刀合力"的第二刀永远不会执行 ⇒ 把本该两刀收掉的局面误记成"白撤"）。
		battle._finish_withdraw_used = 0
		for fw_round in battle.FINISH_WITHDRAW_MAX:
			if GameState.match_over or battle.state == battle.State.ENDED:
				break
			if fw_round > 0:
				battle._ai_finish_withdraw_pick()
				if battle._finish_withdraw_target == null and battle._finish_withdraw_hero == "":
					break
			await battle._ai_finish_withdraw_apply()
			battle._finish_withdraw_used += 1
			for i in 10:
				await get_tree().process_frame
		killed = battle.player_dead > pd0
	var desc := "例%d|玩家已死%d/我方已死%d|玩家血%s|我方%d人|可撤%d次|硬门=%s|%s" % [
		ci, pdead, edead, str(hp_txt), n_mine, battle._finish_gate_mult(),
		("放行" if gate_ok else "**该拦**"), ("撤:%s" % who if decided else "不撤")]
	if not gate_ok:
		if decided:
			_n_violate += 1
			_bad_violate.append(desc)
	else:
		_n_gate_ok += 1
		if decided:
			if killed:
				_n_kill += 1
			else:
				_n_white += 1
				_bad_white.append(desc)
		else:
			# 粗判：玩家场上最低血 ≤ 动态池里最高的面板攻击力 ⇒ 理论上这一刀收得掉（可能误报）
			var max_atk := 0
			for hid in battle._dynamic_sub_candidates():
				var d = DataRegistry.get_hero(String(hid))
				if d != null:
					max_atk = maxi(max_atk, int(d.atk))
			if not hp_txt.is_empty() and int(hp_txt[0]) <= max_atk:
				_n_missed += 1
				_bad_missed.append(desc + "|池里最高面板攻=%d" % max_atk)
	print("B|%s|%s" % [("撤" if decided else "不撤"), desc])

# ---------------------------------------------------------------- helper
## 起一局干净盘面（清掉 Main.tscn 自带的首发与地形）
func _fresh() -> void:
	if battle != null and is_instance_valid(battle):
		battle.queue_free()
		for i in 4:
			await get_tree().process_frame
	battle = (load("res://scenes/Main.tscn") as PackedScene).instantiate() as Battle
	add_child(battle)
	for i in 3:
		await get_tree().process_frame
	for u in battle.units:
		if is_instance_valid(u):
			u.queue_free()
	battle.units.clear()
	battle.occupancy.clear()
	battle.graves.clear()
	battle.obstacles.clear()
	battle.bombs.clear()
	battle.player_dead = 0
	battle.enemy_dead = 0
	battle.player_roster = []
	battle.enemy_roster = []
	GameState.match_over = false
	GameState.active_side = GameState.SIDE_ENEMY
	battle.state = battle.State.ENEMY_TURN
	for i in 2:
		await get_tree().process_frame

## 在 [x0..x1] × [y0..y1] 里随机找一个空格（找不到返回 (-1,-1)）
func _rand_free_cell(x0: int, x1: int, y0: int, y1: int) -> Vector2i:
	for _try in 40:
		var c := Vector2i(x0 + _rng.randi() % (x1 - x0 + 1), y0 + _rng.randi() % (y1 - y0 + 1))
		if not battle.occupancy.has(c) and not battle.graves.has(c) and not battle.obstacles.has(c):
			return c
	return Vector2i(-1, -1)

func _spawn(hid: String, faction: int, cell: Vector2i) -> Unit:
	return battle._spawn_unit(hid, faction, cell)

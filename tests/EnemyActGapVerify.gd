extends Node
## 探针：敌方 AI 回放的行动节奏（相邻英雄之间的间隔 / 同一英雄"移动→攻击"的间隔）
##      以及"正在行动"红橙描边的交接与清除。
## 运行：godot --headless --scene res://tests/EnemyActGapVerify.tscn
## 断言：
##  T1 任意一帧最多只有一名敌人亮着行动描边（不会两名同时亮、看串）
##  T2 两名敌人各自都亮过描边，且回放结束后全部熄灭
##  T3 第1名敌人：亮边→出手 ≥ EnemyReplay.TELL_GAP（起手先亮边再动）
##  T4 第2名敌人：亮边→首次移动 ≥ EnemyReplay.HERO_GAP（英雄之间留出了可辨识的间隔）
##  T5 第2名敌人：移动开始→出手 ≥ 移动动画 + EnemyReplay.STEP_GAP（走位与出手不粘成一段）
##  T6 计划照常执行：两名敌人都完成攻击、第2名敌人走到计划格、目标掉血
var battle: Battle

var _sampling := false
var _tracked: Array = []
var _samples: Array = []        # 每帧：{t, on:[亮边单位下标], pos:[各单位位置的拷贝]}
var _attack_times: Array = []   # "XX 攻击 YY。" 日志的时间戳（不含反击）

func _ready() -> void:
	_run.call_deferred()

func _process(_delta: float) -> void:
	if not _sampling:
		return
	var on: Array = []
	var pos: Array = []
	for i in _tracked.size():
		var u: Unit = _tracked[i]
		if u != null and is_instance_valid(u):
			if u._acting_border != null and u._acting_border.visible:
				on.append(i)
			pos.append(u.position)
		else:
			pos.append(Vector2.ZERO)
	_samples.append({ "t": Time.get_ticks_msec(), "on": on, "pos": pos })

func _on_log(text: String) -> void:
	if "攻击" in text:
		_attack_times.append({ "t": Time.get_ticks_msec(), "text": text })

func _run() -> void:
	GameState.reset_online()
	GameState.match_over = false
	battle = load("res://scenes/Main.tscn").instantiate() as Battle
	add_child(battle)
	await get_tree().process_frame
	# 清空自动放置的单位，自建局面：两名近战敌人 + 一名高血量目标
	for u in battle.units:
		if is_instance_valid(u):
			u.queue_free()
	battle.units.clear()
	battle.occupancy.clear()
	battle.obstacles.clear()
	battle.graves.clear()
	battle.bombs.clear()
	battle.buff_items.clear()
	battle.state = Battle.State.ENEMY_TURN
	var ea := battle._spawn_unit("hero_04", DataRegistry.Faction.ENEMY, Vector2i(2, 5))   # 已贴身：直接出手
	var eb := battle._spawn_unit("hero_04", DataRegistry.Faction.ENEMY, Vector2i(0, 5))   # 需先走一格再出手
	var tgt := battle._spawn_unit("hero_13", DataRegistry.Faction.PLAYER, Vector2i(2, 6))
	for u in [ea, eb, tgt]:
		u.max_hp = 200
		u.hp = 200
	var refs: Array = battle.units.duplicate()
	var plan: Array = [
		{ "idx": 0, "action": { "atk": 2 } },                             # 第1名：只出手（不走位）
		{ "idx": 1, "action": { "move": Vector2i(1, 5), "atk": 2 } },     # 第2名：走位后出手
	]
	_tracked = refs
	battle.log_message.connect(_on_log)
	var t0 := Time.get_ticks_msec()
	_sampling = true
	await battle._replay_enemy_plan(plan, refs, battle._session_id)
	_sampling = false
	var total := Time.get_ticks_msec() - t0

	print(">> 回放总耗时 %d ms，采样 %d 帧，攻击日志 %d 条" % [total, _samples.size(), _attack_times.size()])

	# ---- 采样分析：两名的描边时刻 / 首次移动时刻 ----
	var max_on := 0                       # 同帧亮边人数峰值
	var hero0_on := -1
	var hero1_on := -1
	var hero0_move := -1
	var hero1_move := -1
	var pos0: Vector2 = _samples[0]["pos"][0]
	var pos1: Vector2 = _samples[0]["pos"][1]
	for s in _samples:
		var on: Array = s["on"]
		max_on = maxi(max_on, on.size())
		if on.has(0) and hero0_on < 0:
			hero0_on = int(s["t"])
		if on.has(1) and hero1_on < 0:
			hero1_on = int(s["t"])
		if hero0_move < 0 and (s["pos"][0] as Vector2).distance_to(pos0) > 0.5:
			hero0_move = int(s["t"])
		if hero1_move < 0 and (s["pos"][1] as Vector2).distance_to(pos1) > 0.5:
			hero1_move = int(s["t"])
	var still_on := (_samples[-1]["on"] as Array).size()

	var tell_gap := -1        # 第1名：亮边→出手
	if _attack_times.size() >= 1 and hero0_on >= 0:
		tell_gap = int(_attack_times[0]["t"]) - hero0_on
	var hero_gap := -1        # 第2名：亮边→首次移动
	if hero1_on >= 0 and hero1_move >= 0:
		hero_gap = hero1_move - hero1_on
	var step_gap := -1        # 第2名：移动开始→出手
	if _attack_times.size() >= 2 and hero1_move >= 0:
		step_gap = int(_attack_times[_attack_times.size() - 1]["t"]) - hero1_move

	print(">> 第1名 亮边→出手 %d ms（期望≥%d）" % [tell_gap, int(EnemyReplay.TELL_GAP * 1000.0) - 50])
	print(">> 第2名 亮边→移动 %d ms（期望≥%d）" % [hero_gap, int(EnemyReplay.HERO_GAP * 1000.0) - 100])
	print(">> 第2名 移动→出手 %d ms（期望≥%d = 移动动画+间隔）" % [step_gap, int(EnemyReplay.STEP_GAP * 1000.0) + 150])

	# ---- 判定 ----
	var t1: bool = max_on <= 1
	var t2: bool = hero0_on >= 0 and hero1_on >= 0 and still_on == 0
	var t3: bool = tell_gap >= int(EnemyReplay.TELL_GAP * 1000.0) - 50
	var t4: bool = hero_gap >= int(EnemyReplay.HERO_GAP * 1000.0) - 100
	var t5: bool = step_gap >= int(EnemyReplay.STEP_GAP * 1000.0) + 150   # 至少走完一格(约200ms)+间隔
	var t6: bool = _attack_times.size() == 2 and ea.attacked_this_turn and eb.attacked_this_turn \
			and eb.cell == Vector2i(1, 5) and tgt.hp < 200
	print("T1 同帧最多一人亮行动描边(峰值=%d): %s" % [max_on, "PASS" if t1 else "FAIL"])
	print("T2 两人都亮过且结束后全熄灭(剩=%d): %s" % [still_on, "PASS" if t2 else "FAIL"])
	print("T3 第1名起手亮边停顿: %s" % ["PASS" if t3 else "FAIL"])
	print("T4 英雄之间间隔: %s" % ["PASS" if t4 else "FAIL"])
	print("T5 移动与出手之间间隔: %s" % ["PASS" if t5 else "FAIL"])
	print("T6 计划照常执行(攻%d次 落格=%s 目标血=%d): %s" % [_attack_times.size(), str(eb.cell), tgt.hp, "PASS" if t6 else "FAIL"])
	var ok: bool = t1 and t2 and t3 and t4 and t5 and t6
	print("FINAL " + ("PASS" if ok else "FAIL"))
	get_tree().quit(0 if ok else 1)

extends Node
## 【2026-09-28 一次性探针】"AI 自己 1 血中毒单位"到底在哪一刻死 —— 决定"主动撤人"能不能救它。
## 已量到的事实（上一轮）：
##   · 毒 tick 在**每一方回合开场**跑（`_tick_statuses()`，`TURN_START_SKILL_DELAY = 0.9s` 之后）；
##   · 若毒是在**玩家回合**给这个 AI 单位挂上的 ⇒ 敌方回合开场那一次 tick 就把它收走，
##     等不到"玩家回合开场"（`PT|死在哪|① 敌方回合开场`）。
## 本探针再量第二种可能：**毒是在敌方回合中途挂上的**（晚于那次 tick）——
##   这种情况下它会活过敌方回合，死在**下一个玩家回合开场**，而"敌方回合里撤它"就是最后的窗口。
## 输出：每行 `PT|...`，末尾 `PT|END`。

var battle: Battle
var t0 := 0.0
var log_on := false
var log_lines: Array[String] = []
var banner_lines: Array[String] = []
var es_t := -1.0

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	battle = (load("res://scenes/Main.tscn") as PackedScene).instantiate() as Battle
	add_child(battle)
	for i in 3:
		await get_tree().process_frame
	battle.enemy_roster = []
	battle.player_roster = []
	# 孤零零一个 AI 单位，1 血：谁都不打它 ⇒ 唯一死因只能是毒 tick
	var v = battle._spawn_unit("hero_11", DataRegistry.Faction.ENEMY, Vector2i(2, 2))
	v.hp = 1
	v.remove_status(StatusDB.SHIELD)
	for i in 2:
		await get_tree().process_frame
	print("PT|初始|%s 血=%d｜盾=%s｜首手=%d｜场上=%d" % [
		str(v.display_name), _hp(), str(_has(StatusDB.SHIELD)), int(battle._first_side), battle.units.size()])

	battle.turn_banner.connect(func(txt: String):
		banner_lines.append("[%5.2f] 横幅 「%s」" % [Time.get_ticks_msec() / 1000.0 - t0, txt]))
	battle.log_message.connect(func(txt: String): _note("日志 「%s」" % txt))

	t0 = Time.get_ticks_msec() / 1000.0
	log_on = true
	_note("开始｜首手=%d｜active_side=%d" % [int(battle._first_side), int(GameState.active_side)])

	# ---------- ① 敌方回合开场（此时**还没中毒**）----------
	GameState.active_side = GameState.SIDE_ENEMY
	_note("→ 开敌方回合（_begin_side(ENEMY)），此时未中毒")
	battle._begin_side(GameState.SIDE_ENEMY)
	var last := ""
	var n := 0
	var in_side := false
	while n < 900:
		n += 1
		await get_tree().process_frame
		var now := "血=%d|毒=%s" % [_hp(), str(_has(StatusDB.POISON))]
		if now != last:
			_note("状态 %s｜active_side=%d" % [now, int(GameState.active_side)])
			last = now
		if _hp() <= 0:
			_note("★ 意外：未中毒就死了")
			break
		# 过了毒 tick 时点（0.9s + 一点余量）之后，模拟"敌方回合中途才中毒"
		if not in_side and Time.get_ticks_msec() / 1000.0 - t0 > 2.9:
			in_side = true
			_battle_unit().add_status(StatusDB.POISON, true)
			_note("★ 在**敌方回合中途**给它上毒（模拟「敌人本回合才中毒」）")
		if in_side and Time.get_ticks_msec() / 1000.0 - t0 > 4.2:
			break
	var dead_at := ""
	if _hp() > 0:
		# ---------- ② 我方回合开场 ----------
		GameState.active_side = GameState.SIDE_PLAYER
		_note("→ 开我方回合（_begin_side(PLAYER)）")
		battle._begin_side(GameState.SIDE_PLAYER)
		var m := 0
		while m < 900:
			m += 1
			await get_tree().process_frame
			var now2 := "血=%d|毒=%s" % [_hp(), str(_has(StatusDB.POISON))]
			if now2 != last:
				_note("状态 %s｜active_side=%d" % [now2, int(GameState.active_side)])
				last = now2
			if _hp() <= 0:
				dead_at = "② 我方回合开场"
				break
			if Time.get_ticks_msec() / 1000.0 - t0 > 6.5:
				break
	else:
		dead_at = "① 敌方回合开场"
	log_on = false

	print("PT|死在哪|%s" % (dead_at if dead_at != "" else "（全程没死）"))
	for ln in banner_lines:
		print("  " + ln)
	for ln in log_lines:
		print("  " + ln)
	print("PT|END")
	get_tree().quit(0)

func _battle_unit():
	for u in battle.units:
		if u != null and is_instance_valid(u) and u.faction == DataRegistry.Faction.ENEMY:
			return u
	return null

func _hp() -> int:
	var u = _battle_unit()
	if u == null or not u.alive:
		return 0
	return int(u.hp)

func _has(s: String) -> bool:
	var u = _battle_unit()
	if u == null or not u.alive:
		return false
	return u.has_status(s)

func _note(s: String) -> void:
	if log_on:
		log_lines.append("[%5.2f] %s" % [Time.get_ticks_msec() / 1000.0 - t0, s])

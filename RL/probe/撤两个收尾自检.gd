extends Node
## 【2026-10-01 一次性探针·只读·用户「现在主动撤人好像不会撤两个来斩杀」→「上」】**「一回合连撤两个收尾」自检**
##
## 用户口径：一个替补收不掉（或被撤下的人本身也是废子）时，允许**同一回合再撤一个**接着收。
## 本次改动三处：① 新成员 `_finish_withdraw_used` + `FINISH_WITHDRAW_MAX`；② ①b 门从
## `enemy_dead >= 2` 改成 `enemy_dead + 1 >= LOSS_DEATH_COUNT`（按"撤完之后"算）；③ `_run_enemy_turn()`
## 里的调用点包成 `for _fw_round in FINISH_WITHDRAW_MAX` 循环（每轮 pick→apply，用掉一次计数）。
##
## 本探针**照着改后的调用点原样驱动那两轮**（不复制判据、只重复循环体的四行），因为真正的病灶是
## "第二轮进不进得来"：`_finish_withdraw_used` 有没有拦住自己、`_pending_enemy_sub` 有没有在第二轮
## 之前被 apply 清干净、以及 `_finish_withdraw_pick()` 选中的字段有没有被上一轮清空。
##
## 摆盘（5×7，x 0..4 / y 0..6）：
##   · 玩家方：T1(2,2) 血3、T2(2,4) 血4 —— 两个都残，且都在 (1,0) 的 3 格射程内、都不与 (1,2) 相邻；
##   · 我方：受害者 hero_11 放 (1,4)（撤下 ⇒ 墓碑 (1,4)，替补可落），另一个 hero_12 放 (4,6) 并
##     标 `attacked_this_turn`（模拟"回放已跑完、这一手是最后补的"⇒ 它不会被 `_finish_withdraw_victim()` 挑中）；
##   · 另在 (0,1) 造一座敌方墓碑（凑够两个合法落点，且 (1,0) 这个出生空格本来就能落）。
## 期望：第 1 轮撤一个、替补落 (1,0) 收掉 T1 或 T2；第 2 轮**还能再撤一个**、把另一个也收掉；
##   第 3 次 pick 必须被 `_finish_withdraw_used` 拦住。三条都成立才算 PASS。

var battle: Battle
var _pass := 0
var _fail := 0

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	var hurt := await _fresh()
	GameState.no_death_limit = false
	GameState.enemy_recipe = {}
	battle.enemy_roster = ["hero_07", "hero_07", "hero_07"]
	battle._finish_withdraw_used = 0
	battle._pending_enemy_sub = 0
	battle.player_dead = 0
	battle.enemy_dead = 0
	# 敌方墓碑：凑第二个合法落点（(1,0) 是出生空格，本来就能落）
	battle.graves[Vector2i(0, 1)] = { "fn": DataRegistry.Faction.ENEMY, "hero": "hero_11" }
	var t1 := _spawn("hero_10", DataRegistry.Faction.PLAYER, Vector2i(2, 2))
	t1.hp = 3
	# T2 摆在 (0,2)：实测 (0,1) 这格拔掉 (1,2) 的那一刀是**原地开火**（日志"原地打 白游侠"）⇒ 说明
	#   (0,1) 与它相隔的格数在影丸射程内；(0,2) 与 (0,1) 相邻，(1,2) 与 (0,1) 也相邻（同一排相邻 x）
	#   ⇒ 两个目标都在同一把射程里，第二轮才有得打。
	var t2 := _spawn("hero_10", DataRegistry.Faction.PLAYER, Vector2i(0, 2))
	t2.hp = 4
	var vic := _spawn("hero_11", DataRegistry.Faction.ENEMY, Vector2i(1, 4))
	var other := _spawn("hero_12", DataRegistry.Faction.ENEMY, Vector2i(4, 6))
	other.attacked_this_turn = true   # 已出手 ⇒ 不会被挑成"要撤的人"
	for i in 3:
		await get_tree().process_frame
	# ---- 定点：直接调一次 `_place_enemy_sub(true)`，看它到底吃掉几个名额 ----
	battle._pending_enemy_sub = 1
	battle._forced_sub_hero = "hero_07"
	battle._forced_sub_cell = Vector2i(0, 1)
	battle._enemy_plan_running = true
	GameState.active_side = GameState.SIDE_ENEMY
	print("T|定点1|调用前 替补席=%s 待补=%d" % [str(battle.enemy_roster), battle._pending_enemy_sub])
	await battle._place_enemy_sub(true)
	print("T|定点1|调用后 替补席=%s 待补=%d 场上=%d" % [str(battle.enemy_roster), battle._pending_enemy_sub, battle.units.size()])
	battle._enemy_plan_running = false
	battle._forced_sub_hero = ""
	battle._forced_sub_cell = Vector2i(-99, -99)
	# 定点结束，重新摆回原状给下面的正式两轮用
	battle.enemy_roster = ["hero_07", "hero_07", "hero_07"]
	for u2 in battle.units:
		if is_instance_valid(u2) and u2.faction == DataRegistry.Faction.ENEMY and u2.hero_id == "hero_07":
			u2.queue_free()
			battle.units.erase(u2)
			battle.occupancy.erase(u2.cell)
	battle._pending_enemy_sub = 0
	for i in 3:
		await get_tree().process_frame
	print("T|摆盘|玩家血=%d+%d 我方阵亡=%d 玩家阵亡=%d 门槛和=%.0f/%d 合法落点=%s" % [
		int(t1.hp), int(t2.hp), battle.enemy_dead, battle.player_dead,
		battle._finish_gate_sum(), battle._finish_gate_need(), str(battle._sub_legal_cells_for_ai())])
	print("T|摆盘2|出生格=%s|占位=%s|障碍=%s|墓碑=%s" % [
		str(battle._spawn_cells(DataRegistry.Faction.ENEMY)), str(battle.occupancy.keys()),
		str(battle.obstacles.keys()), str(battle.graves.keys())])

	# ---- 第 1 轮（= 改后调用点循环体原样）----
	battle._ai_finish_withdraw_pick()
	var d1 := battle._finish_withdraw_target != null
	var h1: String = battle._finish_withdraw_hero
	var c1: Vector2i = battle._finish_withdraw_cell
	if d1:
		print("T|apply前|替补席=%s 待补=%d" % [str(battle.enemy_roster), battle._pending_enemy_sub])
		await battle._ai_finish_withdraw_apply()
		battle._finish_withdraw_used += 1
		# ⚠️ 这句在 `_ai_finish_withdraw_apply()` **返回之后**立刻读一次：先看是不是 apply 自己削的
		print("T|apply刚返回|替补席=%s" % str(battle.enemy_roster))
		for i in 12:
			await get_tree().process_frame
			if i % 4 == 3:
				print("T|apply后+%d帧|替补席=%s 待补=%d" % [i + 1, str(battle.enemy_roster), battle._pending_enemy_sub])
	var a1 := _alive(t1)
	var a2 := _alive(t2)
	print("T|第1轮|决定撤=%s 换谁=%s 落点=%s ⇒ T1活着=%s T2活着=%s 我方阵亡=%d 待补名额=%d 已撤次数=%d" % [
		str(d1), h1, str(c1), str(a1), str(a2), battle.enemy_dead, battle._pending_enemy_sub,
		battle._finish_withdraw_used])

	# ---- 第 2 轮（关键：计数=1 时还能不能进来）----
	battle._ai_finish_withdraw_pick()
	var d2 := battle._finish_withdraw_target != null
	var h2: String = battle._finish_withdraw_hero
	var c2: Vector2i = battle._finish_withdraw_cell
	if d2:
		await battle._ai_finish_withdraw_apply()
		battle._finish_withdraw_used += 1
		for i in 12:
			await get_tree().process_frame
	var b1 := _alive(t1)
	var b2 := _alive(t2)
	print("T|第2轮|决定撤=%s 换谁=%s 落点=%s ⇒ T1活着=%s T2活着=%s 我方阵亡=%d 已撤次数=%d" % [
		str(d2), h2, str(c2), str(b1), str(b2), battle.enemy_dead, battle._finish_withdraw_used])

	# ---- 第 3 次 pick（必须被次数上限拦住）----
	battle._ai_finish_withdraw_pick()
	var d3 := battle._finish_withdraw_target != null
	print("T|第3次pick|决定撤=%s（期望 false：已撤次数=%d ≥ 上限 %d）" % [str(d3), battle._finish_withdraw_used, battle.FINISH_WITHDRAW_MAX])

	# ---- 判读 ----
	_expect("第1轮撤了人", d1)
	_expect("第1轮换的是收尾特例", h1 != "")
	_expect("第1轮后待补名额清干净（不然第2轮被 apply 那道门拦）", battle._pending_enemy_sub == 0)
	_expect("第1轮收掉一个目标", (not a1) or (not a2))
	_expect("第2轮还能再撤（计数=1 < 上限 2）", d2)
	_expect("两轮各撤一个 ⇒ 我方共 2 个阵亡（撤下算阵亡）", battle.enemy_dead == 2)
	_expect("两个目标都被收掉", (not b1) and (not b2))
	_expect("第3次 pick 被次数上限拦住", not d3)
	print("T|END|PASS=%d FAIL=%d" % [_pass, _fail])

func _spy_roster() -> Thread:
	# 逐帧盯着 `enemy_roster.size()`/内容：一旦变小就把当时的值打出来。
	# ⚠️ 主线程 `await` 期间读 `enemy_roster` 是安全的（只在协程让出的间隙读一次），
	#    这里用 `Thread` 只为不阻塞主流程；读的是 Array 的 size 与字符串快照。
	var b := battle
	var t := Thread.new()
	t.start(func() -> void:
		var last := b.enemy_roster.duplicate()
		var t0 := Time.get_ticks_msec()
		while Time.get_ticks_msec() - t0 < 30000:
			var now: Array = b.enemy_roster.duplicate()
			if now.size() != last.size():
				print("T|替补席变动|%s → %s" % [str(last), str(now)])
				last = now
			OS.delay_msec(20)
	)
	return t

func _alive(u) -> bool:	# ⚠️ 顺序不能反：目标被打死后 `Unit` 会被 `queue_free()` ⇒ 传进来的可能是**已释放对象**，
	#   先 `u != null` 判不出来，而把已释放对象传给 `Unit` 形参会直接报 "previously freed"。
	return is_instance_valid(u) and (u as Unit).alive

func _expect(nm: String, ok: bool) -> void:
	if ok:
		_pass += 1
	else:
		_fail += 1
	print("T|%s|%s" % [nm, ("PASS" if ok else "FAIL")])

## 起一局干净盘面（清掉 Main.tscn 自带的首发与地形），只留探针自己摆的人
func _fresh() -> Unit:
	if battle != null and is_instance_valid(battle):
		battle.queue_free()
		for i in 4:
			await get_tree().process_frame
	battle = (load("res://scenes/Main.tscn") as PackedScene).instantiate() as Battle
	add_child(battle)
	for i in 3:
		await get_tree().process_frame
	_clear()
	battle.player_roster = []
	battle.enemy_roster = []
	GameState.no_death_limit = false
	GameState.match_over = false
	GameState.active_side = GameState.SIDE_ENEMY
	battle.state = battle.State.ENEMY_TURN
	for i in 2:
		await get_tree().process_frame
	return null

func _clear() -> void:
	for u in battle.units:
		if is_instance_valid(u):
			u.queue_free()
	battle.units.clear()
	battle.occupancy.clear()
	battle.graves.clear()
	battle.obstacles.clear()
	battle.bombs.clear()
	battle.enemy_dead = 0
	battle.player_dead = 0

func _spawn(hid: String, faction: int, cell: Vector2i) -> Unit:
	var u := battle._spawn_unit(hid, faction, cell)
	if u == null:
		print("T|WARN|spawn_failed|%s" % hid)
	return u

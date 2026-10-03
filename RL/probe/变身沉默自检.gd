extends Node
## 【2026-10-02·一次性探针·只读】用户问：「**为什么古灵精怪变身之后还是古灵精怪，没被沉默**」⇒
##   把这件事拆成三问，逐条打读数：
##   ① **被沉默时到底会不会变身**（门 = `Battle._trigger_turn_start()` 里的 `u.skill_allowed()`）；
##   ② 变身**成功后**身份换没换（`hero_id` / `display_name` / 词条 / 攻击图标），以及**卡面立绘换没换**
##      （`Unit._art` / `_art_hex.texture` —— 变身路径里没有任何换图代码 ⇒ 立绘**故意不变**）；
##   ③ 沉默在它身上**留多久**（`Unit.clear_temp_statuses()` 里有没有 SILENCE ⇒ 回合末清不清）。
## 输出：TS|… / TS|END

const GREMLIN := "hero_28"

var battle: Battle

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	GameState.ai_difficulty = 2
	await _rebuild()
	GameState.ai_difficulty = 2
	var g = _spawn(GREMLIN, DataRegistry.Faction.ENEMY, Vector2i(2, 2), 0)
	_spawn("hero_18", DataRegistry.Faction.ENEMY, Vector2i(3, 2), 0)   # 队友（进变身候选池）
	_spawn("hero_19", DataRegistry.Faction.ENEMY, Vector2i(1, 2), 0)
	_spawn("hero_03", DataRegistry.Faction.PLAYER, Vector2i(3, 4), 0)
	if g == null:
		print("TS|古灵精怪没造出来")
		print("TS|END")
		get_tree().quit(0)
	for i in 3:
		await get_tree().process_frame
	_info("初始", g)
	print("TS|立绘|`_art`=%s｜`clear_temp_statuses()` 里含 SILENCE 吗（下面第③条会验）" % str(g._art))
	# ① 沉默状态下触发"回合开始技" —— 应当**不变身**
	g.add_status(StatusDB.SILENCE)
	_info("给它挂上[沉默]之后", g)
	var before_id: String = g.hero_id
	battle._trigger_turn_start(g)
	print("TS|① 被沉默时触发回合开始技|skill_allowed=%s｜hero_id %s → %s｜%s" % [
		str(g.skill_allowed()), before_id, g.hero_id,
		("**没变身**（沉默挡住了）✓" if g.hero_id == before_id else "**照样变身了** ✗")])
	# ③ 沉默留多久：手动跑一次"回合末清状态"，看它还在不在
	var had: bool = g.has_status(StatusDB.SILENCE)
	g.clear_temp_statuses()
	print("TS|③ 沉默的寿命|清临时状态前 has(SILENCE)=%s ⇒ 清之后=%s（回合末 `_clear_statuses(该方)` 调的就是这个）" % [
		str(had), str(g.has_status(StatusDB.SILENCE))])
	# ② 沉默没了 ⇒ 再触发一次回合开始技 —— 应当**变身**
	var id2: String = g.hero_id
	var name2: String = g.display_name
	var art2 := str(g._art)
	battle._trigger_turn_start(g)
	print("TS|② 解除沉默后触发|hero_id %s → %s｜display_name 「%s」→「%s」｜词条=%s｜攻击图标=%s" % [
		id2, g.hero_id, name2, g.display_name, str(g.skills), str(g.get_node_or_null("AtkIcon") != null)])
	print("TS|② 立绘|变身前后 `_art` 同一个对象吗 = %s（`%s` → `%s`）" % [
		str(art2 == str(g._art)), art2, str(g._art)])
	print("TS|② 判读|%s" % (
		"**身份换了（hero_id/名字/词条都换）但立绘不换** —— 这就是「看着还是古灵精怪」的来源" if g.hero_id != GREMLIN
		else "**变身没生效**（hero_id 还是 hero_28）✗"))
	print("TS|END")
	get_tree().quit(0)

func _info(tag: String, u) -> void:
	print("TS|%s|hero_id=%s｜display_name=「%s」｜skill_allowed=%s｜has(SILENCE)=%s｜词条=%s" % [
		tag, String(u.hero_id), String(u.display_name), str(u.skill_allowed()),
		str(u.has_status(StatusDB.SILENCE)), str(u.skills)])

func _spawn(hid: String, fn, cell: Vector2i, hp: int = 0):
	var u = battle._spawn_unit(hid, fn, cell)
	if u != null:
		u.moved_this_turn = false
		u.attacked_this_turn = false
		if hp > 0:
			u.hp = hp
	return u

func _rebuild() -> void:
	if battle != null and is_instance_valid(battle):
		battle.queue_free()
		for i in 3:
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
	GameState.no_death_limit = false
	GameState.match_over = false
	GameState.active_side = GameState.SIDE_ENEMY
	battle.state = battle.State.ENEMY_TURN

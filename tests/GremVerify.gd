extends Node
## 百变精灵变身触发验证：
## 古灵精怪(hero_28)在其他英雄/自身回合开始时变身，变身后应立即触发新英雄的"己方回合开始"技能。
## 运行：godot --headless --scene res://tests/GremVerify.tscn
var battle: Battle

func _ready() -> void:
	battle = load("res://scenes/Main.tscn").instantiate() as Battle
	add_child(battle)
	_run.call_deferred()

func clear_all() -> void:
	for u in battle.units:
		if is_instance_valid(u):
			u.queue_free()
	battle.units.clear()
	battle.occupancy.clear()
	battle.bombs.clear()
	battle.buff_items.clear()
	battle.obstacles.clear()
	battle.graves.clear()
	battle.player_dead = 0
	battle.enemy_dead = 0
	battle.selected = null
	battle.state = Battle.State.ENDED

func spawn(hid: String, f: int, c: Vector2i) -> Unit:
	return battle._spawn_unit(hid, f, c)

func _run() -> void:
	# T1: 古灵精怪变身为黄金矿工 -> 立即触发"回合开始"放金块
	clear_all()
	battle.player_roster = []
	var g := spawn("hero_28", DataRegistry.Faction.PLAYER, Vector2i(3, 6))
	var bandit := spawn("hero_42", DataRegistry.Faction.PLAYER, Vector2i(2, 6))   # 队友黄金矿工作为候选
	battle._transform(g, "hero_42")   # 强制变身为黄金矿工
	var gold_placed := battle.buff_items.size()   # 黄金矿工应放金块到 buff_items
	print("T1 变身为黄金矿工立即放金块: hero_id=%s gold=%d => %s" % [g.hero_id, gold_placed, "PASS" if g.hero_id == "hero_42" and gold_placed >= 1 else "FAIL"])

	# T2: 古灵精怪变身为圣诞老人(放道具) -> 立即触发
	clear_all()
	battle.player_roster = []
	var g2 := spawn("hero_28", DataRegistry.Faction.PLAYER, Vector2i(3, 6))
	var santa := spawn("hero_02", DataRegistry.Faction.PLAYER, Vector2i(2, 6))
	battle._transform(g2, "hero_02")
	var items := battle.buff_items.size()
	print("T2 变身为圣诞老人立即放道具: hero_id=%s items=%d => %s" % [g2.hero_id, items, "PASS" if g2.hero_id == "hero_02" and items >= 1 else "FAIL"])

	# T3: 走真实"己方回合开始"流程: _begin_side 还原本源 -> _trigger_turn_start_all -> 古灵精怪变身 -> 触发新英雄回合开始
	clear_all()
	battle.player_roster = []
	var g3 := spawn("hero_28", DataRegistry.Faction.PLAYER, Vector2i(3, 6))
	var santa3 := spawn("hero_02", DataRegistry.Faction.PLAYER, Vector2i(2, 6))
	battle._transform(g3, "hero_02")   # 上一回合已变身为圣诞老人
	var before_items := battle.buff_items.size()
	# 模拟己方回合开始：还原本源，然后触发回合开始技能
	g3.hero_id = g3.transform_base_id
	battle._apply_base_hero(g3, g3.transform_base_id)
	battle._trigger_turn_start(g3)   # hero_28.on_turn_start -> 重新变身 -> 触发新英雄回合开始
	var final_items := battle.buff_items.size()
	var re_transformed := g3.hero_id != "hero_28"
	print("T3 回合开始还原本源再变身触发回合开始: items %d->%d 再变身=%s => %s" % [before_items, final_items, str(re_transformed), "PASS" if re_transformed and final_items > before_items else "FAIL"])

	# T4: 变身为死灵法师 -> 应召唤骷髅兵
	clear_all()
	battle.player_roster = []
	var g4 := spawn("hero_28", DataRegistry.Faction.PLAYER, Vector2i(3, 6))
	var necro := spawn("hero_33", DataRegistry.Faction.PLAYER, Vector2i(2, 6))
	var skel_before := 0
	for u in battle.units:
		if u.hero_id == "summon_skeleton":
			skel_before += 1
	battle._transform(g4, "hero_33")
	var skel_after := 0
	for u in battle.units:
		if u.hero_id == "summon_skeleton":
			skel_after += 1
	print("T4 变身为死灵法师召唤骷髅: hero_id=%s 骷髅%d->%d => %s" % [g4.hero_id, skel_before, skel_after, "PASS" if g4.hero_id == "hero_33" and skel_after > skel_before else "FAIL"])

	# T5: 真实"回合开始"流程: _trigger_turn_start_all 里古灵精怪变身为死灵法师 -> 召唤骷髅
	clear_all()
	battle.player_roster = []
	var g5 := spawn("hero_28", DataRegistry.Faction.PLAYER, Vector2i(3, 6))
	var necro5 := spawn("hero_33", DataRegistry.Faction.PLAYER, Vector2i(2, 6))
	var skel5_before := 0
	for u in battle.units:
		if u.hero_id == "summon_skeleton":
			skel5_before += 1
	await battle._trigger_turn_start_all(DataRegistry.Faction.PLAYER)
	var skel5_after := 0
	for u in battle.units:
		if u.hero_id == "summon_skeleton":
			skel5_after += 1
	print("T5 回合开始流程变身死灵法师召唤骷髅: 骷髅%d->%d 变身为%s => %s" % [skel5_before, skel5_after, g5.hero_id, "PASS" if skel5_after > skel5_before else "FAIL"])

	get_tree().quit()
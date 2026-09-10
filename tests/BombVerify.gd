extends Node
## 炸弹验证（现行规则 + 炸弹人规则归属）：
## T1 普通英雄**经过**炸弹格（非终点）不爆炸，走完全程、炸弹保留；
## T2 普通英雄**停在**炸弹格 -> 引爆：掉 5 血、炸弹从盘面消失；
## T3 炸弹人经过/停在炸弹格都安全（免疫来自英雄脚本钩子 immune_to_bombs）；
## T4 可放格由英雄脚本给出（hero_35.bomb_place_cells）：地形不合法的格（障碍/单位/已有雷/道具）不在集合里；
## T5 没有放雷能力的英雄（HeroBase 默认）一个格都放不了：_apply_bomb_placement 拒绝；
## T6 AI 侧不再硬编码 hero_35：免疫炸弹的单位可把炸弹格当落点，普通单位不行。
## 运行：godot --headless --scene res://tests/BombVerify.tscn
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

func sleep_frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame

func spawn(hid: String, f: int, c: Vector2i) -> Unit:
	return battle._spawn_unit(hid, f, c)

func put_bomb(c: Vector2i) -> void:
	battle.bombs[c] = true
	if battle.board_view:
		battle.board_view.bombs = battle.bombs

func _run() -> void:
	# ---- T1: 经过中途炸弹格：不爆炸（现行规则：只有停在炸弹格才引爆）----
	clear_all()
	battle.state = Battle.State.PLAYER_INPUT
	var u := spawn("hero_06", DataRegistry.Faction.PLAYER, Vector2i(2, 6))
	u.hp = 10; u.move_range = 3; u.refresh_stats()
	put_bomb(Vector2i(3, 6))   # 路径 (2,6)->(3,6)->(4,6) 的中间格
	battle._do_move(u, Vector2i(4, 6), true)
	await sleep_frames(300)
	var kept := battle.bombs.has(Vector2i(3, 6))
	var t1: bool = u.hp == 10 and kept and u.cell == Vector2i(4, 6)
	print("T1 经过炸弹格不爆炸: hp=%d 雷保留=%s 终格=%s => %s" % [u.hp, str(kept), str(u.cell), "PASS" if t1 else "FAIL"])

	# ---- T2: 停在炸弹格：引爆，掉 BOMB_DAMAGE 血，雷消失 ----
	clear_all()
	battle.state = Battle.State.PLAYER_INPUT
	var u2 := spawn("hero_06", DataRegistry.Faction.PLAYER, Vector2i(2, 6))
	u2.hp = 10; u2.move_range = 3; u2.refresh_stats()
	put_bomb(Vector2i(3, 6))   # 直接走到炸弹格停下
	battle._do_move(u2, Vector2i(3, 6), true)
	await sleep_frames(300)
	var gone := not battle.bombs.has(Vector2i(3, 6))
	var t2: bool = u2.hp == 10 - battle.BOMB_DAMAGE and gone
	print("T2 停在炸弹格引爆: hp=%d(原10, 应-%d) 雷消失=%s => %s" % [u2.hp, battle.BOMB_DAMAGE, str(gone), "PASS" if t2 else "FAIL"])

	# ---- T3: 炸弹人经过/停在炸弹格都安全（免疫钩子）----
	clear_all()
	battle.state = Battle.State.PLAYER_INPUT
	var b := spawn("hero_35", DataRegistry.Faction.PLAYER, Vector2i(2, 6))
	b.hp = 10; b.move_range = 3; b.refresh_stats()
	var immune: bool = battle._hero(b).immune_to_bombs()
	put_bomb(Vector2i(3, 6))
	battle._do_move(b, Vector2i(4, 6), true)   # 经过
	await sleep_frames(300)
	var pass_safe: bool = b.hp == 10 and battle.bombs.has(Vector2i(3, 6))
	battle._do_move(b, Vector2i(3, 6), true)   # 再走回来停在雷上
	await sleep_frames(300)
	var stop_safe: bool = b.hp == 10 and battle.bombs.has(Vector2i(3, 6))
	var t3: bool = immune and pass_safe and stop_safe
	print("T3 炸弹人免疫: 免疫钩子=%s 经过 hp=%d 停雷 hp=%d => %s" % [str(immune), b.hp, b.hp, "PASS" if t3 else "FAIL"])

	# ---- T4: 可放格由英雄脚本给出（排除地形不合法的格）----
	clear_all()
	battle.state = Battle.State.PLAYER_INPUT
	var b2 := spawn("hero_35", DataRegistry.Faction.PLAYER, Vector2i(2, 6))
	battle.obstacles[Vector2i(3, 6)] = 3     # 障碍挡住的相邻格
	battle.buff_items[Vector2i(1, 5)] = "atk"  # 道具格
	b2.refresh_stats()
	var cells: Array = battle._hero(b2).bomb_place_cells()
	var has_obs: bool = cells.has(Vector2i(3, 6))
	var has_buff: bool = cells.has(Vector2i(1, 5))
	var has_open: bool = cells.has(Vector2i(2, 5))
	var all_ok := true
	for c in cells:
		if not battle.bomb_cell_ok(c):
			all_ok = false
	var t4: bool = not has_obs and not has_buff and has_open and all_ok
	print("T4 可放格=英雄脚本决定: 可放=%s 含障碍格=%s 含道具格=%s 全合法=%s => %s" % [str(cells), str(has_obs), str(has_buff), str(all_ok), "PASS" if t4 else "FAIL"])

	# ---- T5: 无放雷能力的英雄（HeroBase 默认空集）一个格都放不了 ----
	clear_all()
	battle.state = Battle.State.PLAYER_INPUT
	var n := spawn("hero_06", DataRegistry.Faction.PLAYER, Vector2i(2, 6))
	var none_cells: Array = battle._hero(n).bomb_place_cells()
	var placed := battle._apply_bomb_placement(n, Vector2i(2, 5))   # 相邻空地，但该英雄不会放雷
	var t5: bool = none_cells.size() == 0 and not placed and battle.bombs.is_empty()
	print("T5 非炸弹人不能放: 可放格数=%d 放置成功=%s 盘面雷数=%d => %s" % [none_cells.size(), str(placed), battle.bombs.size(), "PASS" if t5 else "FAIL"])

	# ---- T6: 炸弹人放雷落盘（走公共原语 place_bomb）+ 落点复检 ----
	clear_all()
	battle.state = Battle.State.PLAYER_INPUT
	var b3 := spawn("hero_35", DataRegistry.Faction.PLAYER, Vector2i(2, 6))
	var ok_near: bool = battle._apply_bomb_placement(b3, Vector2i(2, 5))     # 相邻空地：应成功
	var ok_far: bool = battle._apply_bomb_placement(b3, Vector2i(4, 6))      # 非相邻：应被拒
	var ok_dup: bool = battle._apply_bomb_placement(b3, Vector2i(2, 5))      # 已有雷：应被拒
	var t6: bool = ok_near and not ok_far and not ok_dup and battle.bombs.has(Vector2i(2, 5)) and battle.bombs.size() == 1
	print("T6 落点校验: 相邻=%s 非相邻=%s 重复格=%s 盘面雷数=%d => %s" % [str(ok_near), str(ok_far), str(ok_dup), battle.bombs.size(), "PASS" if t6 else "FAIL"])

	# ---- T7: AI 侧不再硬编码 hero_35，改看 desc 里的免疫标记 ----
	clear_all()
	battle.state = Battle.State.ENDED
	var ai := BattleAI.new(battle.grid)
	var bomb_cell := Vector2i(1, 6)

	var dmg: Dictionary = _desc("hero_06", Vector2i(0, 6), false)
	var sim1 := ai.build_state([dmg], { Vector2i(0, 6): 0 }, {}, {}, {}, { bomb_cell: true })
	var reach1: Dictionary = ai._move_cells(sim1, sim1.units[0])

	var dbom: Dictionary = _desc("hero_35", Vector2i(0, 6), true)
	var sim2 := ai.build_state([dbom], { Vector2i(0, 6): 0 }, {}, {}, {}, { bomb_cell: true })
	var reach2: Dictionary = ai._move_cells(sim2, sim2.units[0])

	var normal_avoids: bool = not reach1.has(bomb_cell)   # 普通单位：不把炸弹格当落点
	var bomber_takes: bool = reach2.has(bomb_cell)        # 免疫单位：可以站上去
	var t7: bool = normal_avoids and bomber_takes
	print("T7 AI 免疫标记: 普通可停雷上=%s 炸弹人可停雷上=%s => %s" % [str(not normal_avoids), str(bomber_takes), "PASS" if t7 else "FAIL"])

	var ok := t1 and t2 and t3 and t4 and t5 and t6 and t7
	print("FINAL " + ("PASS" if ok else "FAIL"))
	get_tree().quit(0 if ok else 1)

# 造一份最小 AI 描述（只填 build_state 需要的字段），immune_bombs 模拟 Battle 现在会传来的标记
func _desc(hid: String, cell: Vector2i, immune_bombs: bool) -> Dictionary:
	var def := DataRegistry.get_hero(hid)
	return {
		"fn": DataRegistry.Faction.PLAYER, "hero": hid, "cell": cell,
		"hp": 20, "max_hp": 20, "atk": def.atk, "move": def.move_range,
		"atk_range": def.attack_range, "atk_type": def.attack_type,
		"skills": def.skills, "name": def.display_name,
		"immune_bombs": immune_bombs,
	}

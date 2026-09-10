extends Node
## 圣光（hero_22）新规则验证：**敌方回合**里一名己方英雄受伤后，其获得[圣盾]，一回合限一次。
## 发盾是延迟到下一帧的（避免盾挡住同一次攻击后续附加的状态），所以每次都要等帧再断言。
## T1 敌方回合：己方英雄受伤 → 获得[圣盾]；
## T2 己方回合：己方英雄受伤 → **不**给盾（新规则的关键差异）；
## T3 敌方回合内两名队友先后受伤 → 只有第一个得盾（一回合限一次）；
## T4 圣光被沉默时不触发（既有规则回归）；
## T5 目标已有盾时不消耗次数：名额留给下一位伤者。
## 运行：godot --headless --scene res://tests/HolyShieldTurnVerify.tscn
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

func sleep_frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame

# 造成一次真实受伤（走 damaged → _on_unit_damaged → 圣光钩子）
func hurt(victim: Unit, dmg: int) -> void:
	victim.take_damage(dmg, false, false, "测试受伤")
	await sleep_frames(3)

func _run() -> void:
	# ---- T1: 敌方回合 → 给盾 ----
	clear_all()
	spawn("hero_22", DataRegistry.Faction.PLAYER, Vector2i(3, 6))
	var v1 := spawn("hero_15", DataRegistry.Faction.PLAYER, Vector2i(4, 6))
	GameState.active_side = GameState.SIDE_ENEMY
	await hurt(v1, 3)
	var t1: bool = v1.has_status(StatusDB.SHIELD)
	print("T1 敌方回合受伤给盾: 盾=%s => %s" % [str(t1), "PASS" if t1 else "FAIL"])

	# ---- T2: 己方回合 → 不给盾 ----
	clear_all()
	spawn("hero_22", DataRegistry.Faction.PLAYER, Vector2i(3, 6))
	var v2 := spawn("hero_15", DataRegistry.Faction.PLAYER, Vector2i(4, 6))
	GameState.active_side = GameState.SIDE_PLAYER
	await hurt(v2, 3)
	var t2: bool = not v2.has_status(StatusDB.SHIELD)
	print("T2 己方回合受伤不给盾: 盾=%s => %s" % [str(v2.has_status(StatusDB.SHIELD)), "PASS" if t2 else "FAIL"])

	# ---- T3: 敌方回合内一回合限一次 ----
	clear_all()
	spawn("hero_22", DataRegistry.Faction.PLAYER, Vector2i(3, 6))
	var a3 := spawn("hero_15", DataRegistry.Faction.PLAYER, Vector2i(2, 6))
	var b3 := spawn("hero_15", DataRegistry.Faction.PLAYER, Vector2i(4, 6))
	GameState.active_side = GameState.SIDE_ENEMY
	await hurt(a3, 3)
	await hurt(b3, 3)
	var t3: bool = a3.has_status(StatusDB.SHIELD) and not b3.has_status(StatusDB.SHIELD)
	print("T3 一回合限一次: 先受伤者盾=%s 后受伤者盾=%s => %s"
			% [str(a3.has_status(StatusDB.SHIELD)), str(b3.has_status(StatusDB.SHIELD)), "PASS" if t3 else "FAIL"])

	# ---- T4: 圣光被沉默不触发 ----
	clear_all()
	var light := spawn("hero_22", DataRegistry.Faction.PLAYER, Vector2i(3, 6))
	var v4 := spawn("hero_15", DataRegistry.Faction.PLAYER, Vector2i(4, 6))
	light.add_status(StatusDB.SILENCE)
	GameState.active_side = GameState.SIDE_ENEMY
	await hurt(v4, 3)
	var t4: bool = not v4.has_status(StatusDB.SHIELD)
	print("T4 沉默不触发: 圣光沉默=%s 伤者盾=%s => %s"
			% [str(light.has_status(StatusDB.SILENCE)), str(v4.has_status(StatusDB.SHIELD)), "PASS" if t4 else "FAIL"])

	# ---- T5: 目标已有盾 → 不消耗次数，名额留给下一位 ----
	clear_all()
	spawn("hero_22", DataRegistry.Faction.PLAYER, Vector2i(3, 6))
	var a5 := spawn("hero_15", DataRegistry.Faction.PLAYER, Vector2i(2, 6))
	var b5 := spawn("hero_15", DataRegistry.Faction.PLAYER, Vector2i(4, 6))
	a5.add_status(StatusDB.SHIELD)   # A 已有盾
	GameState.active_side = GameState.SIDE_ENEMY
	await hurt(a5, 3)
	await hurt(b5, 3)
	var t5: bool = b5.has_status(StatusDB.SHIELD)
	print("T5 已有盾不耗次数: A盾=%s B盾=%s => %s"
			% [str(a5.has_status(StatusDB.SHIELD)), str(b5.has_status(StatusDB.SHIELD)), "PASS" if t5 else "FAIL"])

	GameState.active_side = GameState.SIDE_PLAYER   # 还原
	var ok := t1 and t2 and t3 and t4 and t5
	print("FINAL " + ("PASS" if ok else "FAIL"))
	get_tree().quit(0 if ok else 1)

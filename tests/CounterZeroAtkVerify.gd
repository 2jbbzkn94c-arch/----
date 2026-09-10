extends Node
## 反击规则：攻击力为 0 的单位不反击、且不播反击演出。
## 判定依据用"反击日志"（_play_counter 命中时才打印"%s 反击 %s…"）——日志没出 = 演出没播。
## T1 攻击力被麻痹压到 0：被近战攻击 → 攻击者不掉血、无反击日志、不占"每回合一次"名额；
## T2 同一单位攻击力回到 1（解除麻痹）→ 正常反击（回归：不能一刀切禁掉）；
## T3 远程对射时攻击力 0 同样不反击；
## T4 正常单位反击不受影响（攻击力>0 照常掉血 + 有反击日志）。
## 运行：godot --headless --scene res://tests/CounterZeroAtkVerify.tscn
var battle: Battle
var _counter_logs: Array = []

func _ready() -> void:
	battle = load("res://scenes/Main.tscn").instantiate() as Battle
	add_child(battle)
	battle.log_message.connect(func(t: String):
		if "反击" in t:
			_counter_logs.append(t))
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
	_counter_logs = []

func spawn(hid: String, f: int, c: Vector2i) -> Unit:
	return battle._spawn_unit(hid, f, c)

func sleep_frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame

# 走真实攻击链路（含反击判定/演出）
func attack_and_wait(a: Unit, t: Unit) -> void:
	battle._do_attack(a, t, false)
	await sleep_frames(90)

func _run() -> void:
	# ---- T1: 攻击力 0 不反击 ----
	clear_all()
	battle.state = Battle.State.PLAYER_INPUT
	var atk1 := spawn("hero_04", DataRegistry.Faction.PLAYER, Vector2i(2, 5))    # 攻 4 近战
	var zero := spawn("hero_04", DataRegistry.Faction.ENEMY, Vector2i(2, 4))     # 目标：攻击力压到 0
	zero.atk = 1
	zero.add_status(StatusDB.ATKDOWN)   # 麻痹 -1 -> 有效攻击 0
	var a_hp0 := atk1.hp
	var z_hp0 := zero.hp
	await attack_and_wait(atk1, zero)
	var t1: bool = zero.effective_atk() == 0 and atk1.hp == a_hp0 \
			and _counter_logs.is_empty() and not zero.counter_used_this_turn
	print("T1 攻击力0不反击: 目标有效攻=%d 攻方HP %d->%d 反击日志=%d 占用反击名额=%s => %s"
			% [zero.effective_atk(), a_hp0, atk1.hp, _counter_logs.size(), str(zero.counter_used_this_turn),
			"PASS" if t1 else "FAIL"])

	# ---- T2: 攻击力回到 1 -> 正常反击（回归）----
	clear_all()
	battle.state = Battle.State.PLAYER_INPUT
	var atk2 := spawn("hero_04", DataRegistry.Faction.PLAYER, Vector2i(2, 5))
	var one := spawn("hero_04", DataRegistry.Faction.ENEMY, Vector2i(2, 4))
	one.atk = 1   # 有效攻击 1（无麻痹）
	var a2_hp0 := atk2.hp
	await attack_and_wait(atk2, one)
	var t2: bool = one.effective_atk() > 0 and atk2.hp < a2_hp0 \
			and _counter_logs.size() == 1 and one.counter_used_this_turn
	print("T2 攻击力>0 正常反击: 目标有效攻=%d 攻方HP %d->%d 反击日志=%d => %s"
			% [one.effective_atk(), a2_hp0, atk2.hp, _counter_logs.size(), "PASS" if t2 else "FAIL"])

	# ---- T3: 远程对射且反击方攻击力 0 -> 不反击 ----
	clear_all()
	battle.state = Battle.State.PLAYER_INPUT
	var r1 := spawn("hero_09", DataRegistry.Faction.PLAYER, Vector2i(2, 5))     # 远程
	var r0 := spawn("hero_09", DataRegistry.Faction.ENEMY, Vector2i(2, 3))      # 远程，距离 2
	r0.atk = 1
	r0.add_status(StatusDB.ATKDOWN)   # 有效攻击 0
	var r1_hp0 := r1.hp
	await attack_and_wait(r1, r0)
	var t3: bool = r1.hp == r1_hp0 and _counter_logs.is_empty()
	print("T3 远程对射0攻不反击: 攻方HP %d->%d 反击日志=%d => %s" % [r1_hp0, r1.hp, _counter_logs.size(), "PASS" if t3 else "FAIL"])

	# ---- T4: 正常单位（攻击力>0）反击照旧 ----
	clear_all()
	battle.state = Battle.State.PLAYER_INPUT
	var n1 := spawn("hero_04", DataRegistry.Faction.PLAYER, Vector2i(2, 5))
	var n2 := spawn("hero_13", DataRegistry.Faction.ENEMY, Vector2i(2, 4))      # 塔盾：攻击力>0
	var n1_hp0 := n1.hp
	await attack_and_wait(n1, n2)
	var t4: bool = n2.effective_atk() > 0 and n1.hp < n1_hp0 and _counter_logs.size() == 1
	print("T4 正常反击不受影响: 目标有效攻=%d 攻方HP %d->%d 反击日志=%d => %s"
			% [n2.effective_atk(), n1_hp0, n1.hp, _counter_logs.size(), "PASS" if t4 else "FAIL"])

	var ok := t1 and t2 and t3 and t4
	print("FINAL " + ("PASS" if ok else "FAIL"))
	get_tree().quit(0 if ok else 1)

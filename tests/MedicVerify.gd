extends Node
## 医护兵治疗量用"移动后"攻击力验证：
## 远程医护兵移动前被贴身(ranged_adjacent=true, 攻击降1)，移动到脱离贴身后治疗队友，
## 治疗量应取移动后攻击力(=3)，而不是按贴身(=1)。
## 运行：godot --headless --scene res://tests/MedicVerify.tscn
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

func _run() -> void:
	# 医疗兵(hero_06,攻3,远程) 在 (3,4)，被敌人贴身 (3,3)。队友在 (4,5)。移动到 (4,4) 脱离贴身。
	clear_all()
	battle.state = Battle.State.PLAYER_INPUT
	var medic := spawn("hero_06", DataRegistry.Faction.PLAYER, Vector2i(3, 4))
	medic.move_range += 1; medic.refresh_stats()
	var foe := spawn("hero_13", DataRegistry.Faction.ENEMY, Vector2i(3, 3))   # 贴身
	var ally := spawn("hero_13", DataRegistry.Faction.PLAYER, Vector2i(4, 5))
	ally.hp = 3; ally.max_hp = 20; ally.refresh_stats()
	battle._sync_ranged_adjacent()
	var adj_before := medic.ranged_adjacent
	# 打印 (3,4) 的邻居，选一个与敌人(3,3)距离>1、且与队友(4,5)距离1的格
	# 医疗兵移动到 (3,5)：与敌人(3,3)距离2(脱离贴身)，与队友(4,5)距离1(相邻)
	battle._do_move(medic, Vector2i(3, 5), true)
	await sleep_frames(300)
	var adj_after := medic.ranged_adjacent
	var heal_amt := medic.effective_atk()
	print("T1 移动后治疗用攻击力: 前贴身=%s 后贴身=%s 治疗量=%d(攻%d) 队友hp=%d => %s" % [
		adj_before, adj_after, heal_amt, medic.atk, ally.hp,
		"PASS" if ally.hp > 3 else "FAIL"])
	print("  移动后 cell=", medic.cell, " distToFoe=", battle.grid.distance(medic.cell, foe.cell))
	get_tree().quit()

extends Node
## 血锁「只能沿6方向直线攻击」玩家侧统一拦截验证：
## _in_attack_range 应对血锁的直线目标 true、非直线目标 false。
## 运行：godot --headless --scene res://tests/BloodLockVerify.gd
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
	clear_all()
	battle.state = Battle.State.PLAYER_INPUT
	var blood := spawn("hero_41", DataRegistry.Faction.PLAYER, Vector2i(3, 8))
	# 直线目标：同列（offset 视觉同一列，轴向直线）
	var line_t := spawn("hero_13", DataRegistry.Faction.ENEMY, Vector2i(3, 5))
	# 非直线目标：斜向偏离（不在6方向直线上）
	var off_t := spawn("hero_13", DataRegistry.Faction.ENEMY, Vector2i(5, 8))
	var r_line := battle._in_attack_range(blood, line_t)
	var r_off := battle._in_attack_range(blood, off_t)
	print("T1 血锁_in_attack_range直线: 直线=%s 非直线=%s => %s" % [r_line, r_off, "PASS" if r_line and not r_off else "FAIL"])
	get_tree().quit()

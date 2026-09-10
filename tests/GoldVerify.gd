extends Node
## 金矿验证（金矿规则归属 + 收益/寿命数值）：
## T1 非矿工踩矿：不消费、金矿留在格上继续倒计时、自身数值不变；
## T2 矿工捡矿：攻 +1（永久）、攻上限 +1、HP 上限 +3、回 3 血（不超上限）；
## T3 拾取权由英雄脚本钩子决定：只有黄金矿工 can_pickup_gold()=true；
## T4 掉矿落点走 Battle 的 gold_cell_ok：只剩一格合法时必定落在那格（墓碑格会被排除）；
## T5 寿命 = GOLD_LIFE 个完整回合，减到 0 时矿风化消失。
## 运行：godot --headless --scene res://tests/GoldVerify.tscn
## 调试：卡住时看 log/gold_verify_progress.txt（stdout 会被管道缓冲吞掉）
var battle: Battle
const PROG := "res://log/gold_verify_progress.txt"

func _ready() -> void:
	battle = load("res://scenes/Main.tscn").instantiate() as Battle
	add_child(battle)
	_run.call_deferred()

# 进度落盘（带 flush）：定位"卡在哪一步"
func _step(msg: String) -> void:
	print(msg)
	var f := FileAccess.open(PROG, FileAccess.READ_WRITE)
	if f == null:
		f = FileAccess.open(PROG, FileAccess.WRITE)
	if f == null:
		return
	f.seek_end()
	f.store_line(msg)
	f.flush()
	f.close()

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
	battle.gold_left.clear()
	battle.player_dead = 0
	battle.enemy_dead = 0
	battle.selected = null
	battle.state = Battle.State.ENDED

func spawn(hid: String, f: int, c: Vector2i) -> Unit:
	return battle._spawn_unit(hid, f, c)

# 走真实"移动结算"路径踩到某格（与 AISmokeTest 的 T13/T14 同口径）
func walk_onto(u: Unit, cell: Vector2i) -> void:
	battle.occupancy.erase(u.cell)
	u.cell = cell
	battle.occupancy[cell] = u
	battle._finish_move(u, false)

func _run() -> void:
	var d := DirAccess.open("res://log")
	if d != null and d.file_exists("gold_verify_progress.txt"):
		d.remove("gold_verify_progress.txt")
	_step("== 开始 ==")

	# ---- T1: 非矿工踩到金矿：不消费 ----
	clear_all()
	battle.state = Battle.State.PLAYER_INPUT
	var w := spawn("hero_04", DataRegistry.Faction.PLAYER, Vector2i(3, 6))
	var atk0 := w.effective_atk()
	var max0 := w.max_hp
	battle.place_gold(Vector2i(4, 6), null)
	walk_onto(w, Vector2i(4, 6))
	var kept: bool = battle.buff_items.get(Vector2i(4, 6), "") == "gold"
	var ticking := battle.gold_left.has(Vector2i(4, 6))
	var t1: bool = kept and ticking and w.effective_atk() == atk0 and w.max_hp == max0
	_step("T1 非矿工不消费金矿: 金矿保留=%s 仍倒计时=%s 攻=%d(原%d) 上限=%d(原%d) => %s"
			% [str(kept), str(ticking), w.effective_atk(), atk0, w.max_hp, max0, "PASS" if t1 else "FAIL"])

	# ---- T2: 矿工捡到金矿：收益数值 ----
	clear_all()
	battle.state = Battle.State.PLAYER_INPUT
	var m := spawn("hero_42", DataRegistry.Faction.PLAYER, Vector2i(3, 6))
	m.hp = m.max_hp - 10   # 留出回血空间，验证 +3
	var atk1 := m.effective_atk()
	var perm0 := m.perm_atk
	var hp1 := m.hp
	var max1 := m.max_hp
	battle.place_gold(Vector2i(4, 6), null)
	walk_onto(m, Vector2i(4, 6))
	var gone: bool = not battle.buff_items.has(Vector2i(4, 6)) and not battle.gold_left.has(Vector2i(4, 6))
	var t2: bool = gone and m.effective_atk() == atk1 + 1 and m.perm_atk == perm0 + 1 \
			and m.max_hp == max1 + 3 and m.hp == hp1 + 3
	_step("T2 矿工捡矿收益: 金矿消失=%s 攻=%d(原%d) 永久攻=%d(原%d) 上限=%d(原%d) HP=%d(原%d) => %s"
			% [str(gone), m.effective_atk(), atk1, m.perm_atk, perm0, m.max_hp, max1, m.hp, hp1, "PASS" if t2 else "FAIL"])

	# ---- T2b: 满血时回血不溢出上限 ----
	var m2 := spawn("hero_42", DataRegistry.Faction.PLAYER, Vector2i(1, 6))
	m2.hp = m2.max_hp
	var max2 := m2.max_hp
	battle.place_gold(Vector2i(0, 6), null)
	walk_onto(m2, Vector2i(0, 6))
	var t2b: bool = m2.hp == max2 + 3   # 上限+3 与回血+3 同步：满血时血=新上限
	_step("T2b 满血捡矿不溢出: 上限=%d(原%d) HP=%d => %s" % [m2.max_hp, max2, m2.hp, "PASS" if t2b else "FAIL"])

	# ---- T3: 拾取权由英雄脚本钩子决定 ----
	clear_all()
	battle.state = Battle.State.PLAYER_INPUT
	var miner := spawn("hero_42", DataRegistry.Faction.PLAYER, Vector2i(3, 6))
	var other := spawn("hero_04", DataRegistry.Faction.PLAYER, Vector2i(1, 6))
	var t3: bool = battle._hero(miner).can_pickup_gold() and not battle._hero(other).can_pickup_gold()
	_step("T3 拾取权钩子: 矿工=%s 其他=%s => %s"
			% [str(battle._hero(miner).can_pickup_gold()), str(battle._hero(other).can_pickup_gold()), "PASS" if t3 else "FAIL"])

	# ---- T4: 掉矿落点 = 经过 gold_cell_ok 的合法格 ----
	clear_all()
	battle.state = Battle.State.PLAYER_INPUT
	var m3 := spawn("hero_42", DataRegistry.Faction.PLAYER, Vector2i(2, 3))
	var only := Vector2i(1, 2)   # 只留这一格空着，其余全用障碍占掉
	for c in battle.grid.all_cells():
		if c != only and not battle.occupancy.has(c):
			battle.obstacles[c] = 3
	battle._hero(m3).on_turn_start()
	var landed_ok: bool = battle.buff_items.get(only, "") == "gold"
	# 再来一发：唯一空格是墓碑 -> 应放不出来
	battle.buff_items.clear()
	battle.gold_left.clear()
	battle.obstacles.clear()
	for c in battle.grid.all_cells():
		if c != only and not battle.occupancy.has(c):
			battle.obstacles[c] = 3
	battle.graves[only] = { "hero": "hero_04", "fn": DataRegistry.Faction.PLAYER }
	battle._hero(m3).on_turn_start()
	var no_gold_on_grave: bool = battle.buff_items.get(only, "") != "gold"
	var t4: bool = landed_ok and no_gold_on_grave
	_step("T4 掉矿走 gold_cell_ok: 唯一空格=%s 落矿=%s 唯一空格是墓碑时放不出=%s => %s"
			% [str(only), str(landed_ok), str(no_gold_on_grave), "PASS" if t4 else "FAIL"])

	# ---- T5: 寿命 = GOLD_LIFE 个完整回合 ----
	clear_all()
	battle.state = Battle.State.PLAYER_INPUT
	battle.place_gold(Vector2i(2, 5), null)
	var life_ok: bool = battle.gold_left.get(Vector2i(2, 5), -1) == battle.GOLD_LIFE
	var ticks: Array = []
	for i in battle.GOLD_LIFE:
		battle._tick_gold_age()
		ticks.append(battle.gold_left.get(Vector2i(2, 5), 0))
	var decayed: bool = not battle.buff_items.has(Vector2i(2, 5)) and not battle.gold_left.has(Vector2i(2, 5))
	var t5: bool = life_ok and decayed
	_step("T5 金矿寿命=%d 回合: 初值=%s 逐轮=%s 到期消失=%s => %s"
			% [battle.GOLD_LIFE, str(life_ok), str(ticks), str(decayed), "PASS" if t5 else "FAIL"])

	var ok := t1 and t2 and t2b and t3 and t4 and t5
	_step("FINAL " + ("PASS" if ok else "FAIL"))
	get_tree().quit(0 if ok else 1)

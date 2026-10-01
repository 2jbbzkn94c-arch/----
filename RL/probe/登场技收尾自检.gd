extends Node
## 【2026-10-01·用户「？猎颅者是登场打3伤啊」→ 选 A（严格：能赢才撤）】**登场技收尾**复刻自检。
##
## 背景：④ 的判据原来只算"走+打"普攻，**完全没算登场技** ⇒ 猎颅者（`hero_39`：登场对**全场 HP
##   最低的敌人**打 3 伤 + 眩晕，**无距离要求**）在判据里等于不存在。用户那局"沉默术士只剩 1 血、
##   缩在我方出生区 6 格外"就被判成「没人做得到」。已修。
##
## 用户选了 **(A) 严格：能赢才撤** ⇒ 逐臂验证两件事：
##   · 臂 A（原局：玩家已死 **1** 名）⇒ 收掉沉默术士也只到 **2** 名 ⇒ **不赢** ⇒ **期望不撤**
##   · 臂 B（玩家已死 **2** 名）⇒ 再收 1 个就赢 ⇒ **期望撤，而且换的就是 hero_39（猎颅者）**
##     —— 这一臂才是"登场技那一路"的真正验收（落点离目标很远，普攻绝无可能）。

const BENCH := ["hero_08", "hero_39", "hero_36", "hero_14"]   # 用户那局：预设替补席 4 人，含猎颅者
var battle: Battle

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	print("E|CFG|登场技收尾复刻（猎颅者登场 3 伤、无距离；目标缩在最深处）")
	await _arm("A 原局·玩家已死1名（收掉也只到2名 ⇒ 期望不撤）", 1, false)
	await _arm("B 对照·玩家已死2名（再收1个就赢 ⇒ 期望撤+上猎颅者）", 2, true)
	print("E|END")

func _arm(nm: String, pdead: int, expect: bool) -> void:
	await _fresh()
	GameState.enemy_recipe = {}
	battle.enemy_roster = BENCH.duplicate()
	GameState.no_death_limit = false
	battle.player_dead = pdead
	battle.enemy_dead = 1          # 用户那局：我方已阵亡 1 名 ⇒ 本回合只能撤 1 次
	battle._finish_withdraw_used = 0
	# 目标：沉默术士 1 血，缩在玩家最深处（4,6）；**场上只有它** ⇒ 必然是"全场最低血"
	var tgt := _spawn("hero_34", DataRegistry.Faction.PLAYER, Vector2i(4, 6))
	if tgt != null:
		tgt.hp = 1
	# 我方：两名已出手的单位（该被撤的那批），离目标很远
	for spec in [["hero_11", Vector2i(1, 2)], ["hero_12", Vector2i(3, 1)]]:
		var mu := _spawn(String(spec[0]), DataRegistry.Faction.ENEMY, spec[1])
		if mu != null:
			mu.attacked_this_turn = true
	for i in 3:
		await get_tree().process_frame
	var legal := battle._sub_legal_cells_for_ai()
	var near := 99
	for c in legal:
		near = mini(near, battle.grid.distance(c, Vector2i(4, 6)))
	print("E|%s|我方已阵亡=%d ⇒ 可撤 %d 次 ｜ 合法落点=%s ｜ 最近落点到目标=%d 格 ｜ 席里最高面板攻=%d" % [
		nm, battle.enemy_dead, battle._finish_gate_mult(), DataRegistry.cells_txt(legal), near,
		_max_bench_atk()])
	battle._ai_finish_withdraw_pick()
	var decided := battle._finish_withdraw_target != null
	var who := String(battle._finish_withdraw_hero)
	print("E|%s|⇒ **%s**%s" % [nm, ("撤：" + who) if decided else "不撤",
		("（落点 %s）" % str(battle._finish_withdraw_cell)) if decided else ""])
	var ok := (decided == expect) and (not expect or who == "hero_39")
	print("E|%s|%s" % [nm, ("PASS" if ok else "FAIL")])

func _max_bench_atk() -> int:
	var m := 0
	for hid in BENCH:
		var d = DataRegistry.get_hero(hid)
		if d != null:
			m = maxi(m, int(d.atk))
	return m

func _fresh() -> void:
	if battle != null and is_instance_valid(battle):
		battle.queue_free()
		for i in 4:
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
	battle.player_dead = 0
	battle.enemy_dead = 0
	battle.player_roster = []
	battle.enemy_roster = []
	GameState.match_over = false
	GameState.active_side = GameState.SIDE_ENEMY
	battle.state = battle.State.ENEMY_TURN
	for i in 2:
		await get_tree().process_frame

func _spawn(hid: String, faction: int, cell: Vector2i) -> Unit:
	return battle._spawn_unit(hid, faction, cell)

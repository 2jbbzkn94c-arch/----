extends Node
## 【2026-09-29 一次性探针】炸弹人 AI 的**放雷落点**：旧口径（`_frontest` 只挑最靠对手底线）vs
##   新口径（按价值：踩得到谁 / 通路 / 血锁邻格）。用户问「炸弹放哪有没有说法／和血锁没配合」。
## 摆盘：敌方 炸弹人(hero_35) + **血锁(hero_41)**，我方一个近战在血锁附近（能走到某些候选格）。
## 输出：每行 `BOMB|...`，末尾 `BOMB|END`。

var battle: Battle

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	battle = (load("res://scenes/Main.tscn") as PackedScene).instantiate() as Battle
	add_child(battle)
	for i in 3:
		await get_tree().process_frame
	battle.state = Battle.State.PLAYER_INPUT
	# 盘面 A：血锁在炸弹人**侧后**（(3,4)）⇒ 它与旧口径挑的那格恰好重合（看不出差别）
	await _case("A_血锁在侧后", Vector2i(3, 4), Vector2i(2, 2))
	# 盘面 B：血锁在炸弹人**正上方**（(2,3)）⇒ 它的邻格在最前那格之外
	#   ⇒ 旧口径仍挑"最靠对手底线"的 (2,5)，新口径应改挑血锁邻格
	await _case("B_血锁在上方", Vector2i(2, 3), Vector2i(3, 2))
	print("BOMB|END")
	get_tree().quit(0)

func _case(tag: String, chain_cell: Vector2i, foe_cell: Vector2i) -> void:
	var bomber = battle._spawn_unit("hero_35", DataRegistry.Faction.ENEMY, Vector2i(2, 4))
	var chain = battle._spawn_unit("hero_41", DataRegistry.Faction.ENEMY, chain_cell)
	var foe = battle._spawn_unit("hero_12", DataRegistry.Faction.PLAYER, foe_cell)
	for i in 3:
		await get_tree().process_frame
	var hero = battle._hero(bomber)
	var cells: Array = hero.bomb_place_cells()
	var pa = hero._pull_ally()
	print("BOMB|%s|盘面|炸弹人=%s|血锁=%s|我方近战=%s(emove=%d)" % [
		tag, str(bomber.cell), str(chain.cell), str(foe.cell), foe.effective_move()])
	print("BOMB|%s|候选=%s|旧口径=%s|新口径=%s|血锁识别=%s" % [
		tag, str(cells), str(hero._frontest(cells)), str(hero._best_bomb_cell(cells)),
		"是" if pa != null else "否"])
	for c in cells:
		print("BOMB|%s|  格%s 分=%.1f|到我方近战距离=%d|是血锁邻格=%s" % [
			tag, str(c), hero._bomb_cell_score(c, pa), battle.grid.distance(foe.cell, c),
			str(battle.grid.distance(chain.cell, c) == 1)])
	# 拆掉这一盘的三个单位，给下一盘腾地方
	for u in [bomber, chain, foe]:
		if u != null and is_instance_valid(u):
			battle._remove_unit_now(u) if battle.has_method("_remove_unit_now") else u.free()

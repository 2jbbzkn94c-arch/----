extends Node
## 【2026-09-29 一次性探针·只读】"拖动撤下"三件事自检 —— 用户口径：
##   「拖动撤下的时候，棋子需要显示在场，拖动的是虚化的影子，撤下后，棋子需要有消失的动画」。
##
## 四项读数（都在真 Battle 上跑，不改生产代码）：
##   ① `_begin_drag()` + `_drag_follow()` 拖起来之后：**真棋子位置/层级一动没动**（还在原格、还占着格），
##      鼠标上多出一枚 `VisualCopy`（虚化影子）—— 打印它的 alpha / z / 子节点构成（应为投影+底色+人物图+穹顶、
##      **没有任何 Label**）；
##   ② `_finish_drag()` 松手（没拖出棋盘）⇒ 影子被回收、棋子照旧；
##   ③ `_apply_withdraw()` 撤下 ⇒ 单位照旧被移除、**不立碑**、阵亡数 +1，同时场上多出一枚 `VisualCopy`
##      （消失动画的副本：`_obs_allow_visual_fx` 打开后 headless 也会真造）—— 打印它的初始 alpha、
##      两帧后的 alpha（应变小 = 在淡出）、以及最终是否自毁；
##   ④ `Unit.make_visual_copy()` 的构成（纯外观、无文字）。
##
## 输出：`DRAG|...` 行，末尾 `DRAG|END`。

var _b: Battle = null

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	Engine.time_scale = 10.0
	GameState.reset_online()
	GameState.dual_control = false
	GameState.pick_deck_in_battle = true
	GameState.ai_difficulty = 0
	_b = load("res://scenes/Main.tscn").instantiate() as Battle
	_b.set_random_seed(99011)
	get_tree().root.add_child(_b)
	if not await _wait_state([Battle.State.DECK_PICK], 15.0):
		print("DRAG|FATAL|no_deck_pick|state=%d" % int(_b.state))
		await _done()
		return
	_b._start_with_player_deck(["hero_01", "hero_06", "hero_12"])
	await _frames(8)
	_clear()
	_spawn("hero_01", DataRegistry.Faction.PLAYER, Vector2i(3, 3))
	_spawn("hero_26", DataRegistry.Faction.ENEMY, Vector2i(3, 1))
	var cell := Vector2i(3, 3)
	var u: Unit = _b.occupancy.get(cell, null)
	if u == null:
		print("DRAG|FATAL|没摆上棋子")
		await _done()
		return
	var pos0: Vector2 = u.position
	var z0: int = u.z_index
	# ---- ④ 外观副本的构成（纯外观、无文字）----
	var probe_copy := u.make_visual_copy()
	print("DRAG|④make_visual_copy|子节点=%d|%s|含Label=%s" % [probe_copy.get_child_count(),
		_types_txt(probe_copy), str(_has_label(probe_copy))])
	probe_copy.free()
	# ---- ① 拖起来：真棋子不动 + 鼠标上出现虚化影子 ----
	_b._begin_drag(u)
	_b._drag_start_mouse = _b.get_global_mouse_position() + Vector2(400, 400)   # 制造"越过阈值"的位移
	_b._drag_follow()
	var g: Node2D = _b._drag_ghost
	var mouse: Vector2 = _b.get_global_mouse_position()
	print("DRAG|①拖动中|dragging=%s|真棋子位置没动=%s（%s→%s）|z没变=%s|仍占格=%s|影子=%s|alpha=%.2f|z=%d|影子在鼠标上=%s|子节点=%d|%s" % [
		str(_b._dragging), str(u.position == pos0), str(pos0), str(u.position), str(u.z_index == z0),
		str(_b.occupancy.get(cell, null) == u), str(g != null), (g.modulate.a if g != null else -1.0),
		(g.z_index if g != null else -999), str(g != null and g.position == mouse),
		(g.get_child_count() if g != null else -1), (_types_txt(g) if g != null else "∅")])
	# ---- ② 松手取消：影子回收、棋子照旧 ----
	_b._finish_drag()
	await _frames(2)
	print("DRAG|②松手（没拖出棋盘）|影子已回收=%s|棋子还在=%s|影子字段已清=%s" % [
		str(g == null or not is_instance_valid(g)), str(_b.occupancy.get(cell, null) == u), str(_b._drag_ghost == null)])
	# ---- ③ 撤下：单位移除 + 不立碑 + 阵亡+1 + 消失副本出现→淡出→自毁 ----
	Engine.time_scale = 1.0            # 让"0.35 秒的消失动画"能采到中间态（10× 下两帧就演完了）
	# ⚠️ 还要**等帧长稳定**：headless 开局那几帧 dt 能到 0.39s（实测），0.35s 的动画一帧就演完，
	#   看起来像"瞬间消失" —— 那是探针环境的假象，不是动画没播。
	for i in 30:
		await get_tree().process_frame
	print("DRAG|③采样前|time_scale=%.2f|上一帧 dt=%.4f" % [Engine.time_scale, _b.get_process_delta_time()])
	_b._obs_allow_visual_fx = true     # 探针观测位：headless 也真造消失副本（生产恒 false）
	var grave0: int = _b.graves.size()
	var dead0: int = _b.player_dead
	var units0: int = _b.units.size()
	print("DRAG|③apply 前子节点= %s" % _kids_txt())
	_b._apply_withdraw(u)
	print("DRAG|③apply 后子节点= %s" % _kids_txt())
	var c := _find_copy()
	var found := is_instance_valid(c)
	var samples: Array[String] = []
	if found:
		for i in 16:
			if not is_instance_valid(c):
				samples.append("×已释放")
				break
			samples.append("%.2f" % c.modulate.a)
			await get_tree().process_frame
		if is_instance_valid(c):
			samples.append("%.2f" % c.modulate.a)
	print("DRAG|③撤下瞬间|消失副本=%s|alpha 时间线（逐帧）= %s|单位 %d→%d 个|碑 %d→%d|阵亡 %d→%d" % [
		str(found), " ".join(samples), units0, _b.units.size(), grave0, _b.graves.size(), dead0, _b.player_dead])
	var freed := false
	for i in 240:
		await get_tree().process_frame
		if _find_copy() == null:
			freed = true
			break
	print("DRAG|③副本自毁=%s|残留副本=%d" % [str(freed), _count_copies()])
	await _done()

func _kids_txt() -> String:
	var bits: Array[String] = []
	for k in _b.get_children():
		bits.append("%s(%s)" % [String(k.name), k.get_class()])
	return ", ".join(bits)

func _count_copies() -> int:
	var n := 0
	for c in _b.get_children():
		if String(c.name).contains("WithdrawFx"):
			n += 1
	return n

func _find_copy() -> Node2D:
	for c in _b.get_children():
		if String(c.name).contains("WithdrawFx") and is_instance_valid(c):
			return c as Node2D
	return null

func _types_txt(n: Node) -> String:
	var bits: Array = []
	for c in n.get_children():
		bits.append("%s/%s" % [c.name, c.get_class()])
	return "[" + ", ".join(bits) + "]"

func _has_label(n: Node) -> bool:
	for c in n.get_children():
		if c is Label:
			return true
	return false

func _clear() -> void:
	for u in _b.units:
		if is_instance_valid(u):
			u.queue_free()
	_b.units.clear()
	_b.occupancy.clear()
	_b.graves.clear()
	_b.obstacles.clear()
	_b.enemy_roster.clear()
	_b.player_roster.clear()
	_b.enemy_dead = 0
	_b.player_dead = 0

func _spawn(hid: String, faction: int, cell: Vector2i) -> void:
	if _b._spawn_unit(hid, faction, cell) == null:
		print("DRAG|WARN|spawn_failed|%s" % hid)

func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame

func _wait_state(states: Array, limit: float) -> bool:
	var t := 0.0
	while t < limit:
		if states.has(_b.state):
			return true
		await get_tree().process_frame
		t += 1.0 / 60.0
	return false

func _done() -> void:
	print("DRAG|END")
	get_tree().quit(0)

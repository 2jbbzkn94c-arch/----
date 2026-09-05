extends Node
## 全英雄联机回归：对每个英雄（DataRegistry.heroes 全部 43 名）在两台"联机 Battle"上跑同一脚本，
## 校验：
##   1) 镜像一致性：主机/客户端两端对应单位的关键状态在每一步后完全一致；
##   2) "直到回合结束"类临时增益（烈焰祭司 +1 攻等）在回合结束时必须被清空且不残留、
##      否则下回合再叠 = 与技能描述不符（联机专坑）。
## 运行：godot --headless --scene res://tests/NetAllHeroResetVerify.tscn
var host: Battle
var client: Battle
var results := {}

func _ready() -> void:
	GameState.is_online = true
	GameState.is_host = true
	host = load("res://scenes/Main.tscn").instantiate()
	add_child(host)
	GameState.is_host = false
	client = load("res://scenes/Main.tscn").instantiate()
	add_child(client)
	_run.call_deferred()

func _clear_board(b: Battle) -> void:
	for u in b.units:
		if is_instance_valid(u):
			u.queue_free()
	b.units.clear()
	b.occupancy.clear()
	b.graves.clear()
	b.bombs.clear()
	b.obstacles.clear()
	b.buff_items.clear()
	b.player_dead = 0
	b.enemy_dead = 0
	b.selected = null
	b._preview_cells = {}

func _spawn_pair(hid: String) -> void:
	_clear_board(host)
	_clear_board(client)
	# 主机=玩家(蓝)：被测英雄 + 一个队友(供烈焰祭司式光环作用) + 敌方单位(供攻击/移动触发)
	GameState.online_seed = 20260905
	host.set_random_seed(GameState.online_seed)
	client.set_random_seed(GameState.online_seed)
	host._spawn_unit(hid, DataRegistry.Faction.PLAYER, Vector2i(2, 7))
	host._spawn_unit("hero_06", DataRegistry.Faction.PLAYER, Vector2i(3, 8))
	host._spawn_unit("hero_13", DataRegistry.Faction.ENEMY, Vector2i(4, 7))
	client._spawn_unit(hid, DataRegistry.Faction.PLAYER, Vector2i(2, 7))
	client._spawn_unit("hero_06", DataRegistry.Faction.PLAYER, Vector2i(3, 8))
	client._spawn_unit("hero_13", DataRegistry.Faction.ENEMY, Vector2i(4, 7))

const _TEMP_FIELDS := ["atk_buff", "move_buff", "ramble_bonus", "sun_bonus", "atk_use_buff", "move_use_buff", "branch_override"]

func _unit_state(u: Unit) -> Dictionary:
	var d := {}
	for f in _TEMP_FIELDS:
		d[f] = u.get(f)
	d["hp"] = u.hp
	d["atk"] = u.atk
	d["cell"] = u.cell
	d["moved"] = u.moved_this_turn
	d["attacked"] = u.attacked_this_turn
	d["status"] = u.statuses.duplicate()
	return d

func _mirror_diff() -> String:
	if host.units.size() != client.units.size():
		return "单位数量 %d != %d" % [host.units.size(), client.units.size()]
	for i in host.units.size():
		var a: Unit = host.units[i]
		var b: Unit = client.units[i]
		if a.hero_id != b.hero_id or a.cell != b.cell:
			return "第%d个单位 %s@%s vs %s@%s 不匹配" % [i, a.hero_id, str(a.cell), b.hero_id, str(b.cell)]
		var sa := _unit_state(a)
		var sb := _unit_state(b)
		for k in sa.keys():
			if sa[k] != sb[k]:
				return "%s(%s).%s 主机=%s 客户端=%s" % [a.hero_id, str(a.cell), k, str(sa[k]), str(sb[k])]
	return ""

func _all_temp_cleared(b: Battle) -> String:
	for u in b.units:
		if u == null or not is_instance_valid(u):
			continue
		if u.faction != DataRegistry.Faction.PLAYER:
			continue
		for f in _TEMP_FIELDS:
			if int(u.get(f)) != 0:
				return "%s.%s 残留=%d" % [u.hero_id, f, int(u.get(f))]
		if u.has_status("heavy") or u.has_status("atkdown") or u.has_status("freeze") \
				or u.has_status("silence") or u.has_status("stun"):
			return "%s 残留状态" % u.hero_id
	return ""

func _run_hero(hid: String) -> void:
	_spawn_pair(hid)
	var ok := true
	var note := ""
	# 触发：我方回合开始（含烈焰祭司光环/傀儡师/古灵精怪等）+ 移动 + 攻击
	for b in [host, client]:
		for u in b.units.duplicate():
			if u != null and is_instance_valid(u) and u.alive and u.faction == DataRegistry.Faction.PLAYER:
				b._trigger_turn_start(u)
				b._trigger_on_move(u)
				for t in b.units.duplicate():
					if t != null and is_instance_valid(t) and t.alive and t.faction != DataRegistry.Faction.PLAYER and b.grid.distance(u.cell, t.cell) <= 2:
						b._trigger_on_attack(u, t, false)
						break
	var diff := _mirror_diff()
	if diff != "":
		ok = false
		note = "触发后镜像不一致：" + diff
	# 我方回合结束：两端都必须清空"直到回合结束"的临时增益（联机本端也要清）
	host._clear_statuses(DataRegistry.Faction.PLAYER)
	client._clear_statuses(DataRegistry.Faction.PLAYER)
	diff = _mirror_diff()
	if diff != "":
		ok = false
		note = "清理后镜像不一致：" + diff
	var res_h := _all_temp_cleared(host)
	if res_h != "":
		ok = false
		note = "主机端清理不净：" + res_h
	var res_c := _all_temp_cleared(client)
	if res_c != "":
		ok = false
		note = "客户端清理不净：" + res_c
	results[hid] = [ok, note]

func _run() -> void:
	for hid in DataRegistry.heroes.keys():
		_run_hero(hid)
	var pass_n := 0
	for hid in DataRegistry.heroes.keys():
		var r: Array = results[hid]
		if r[0]:
			pass_n += 1
		print("%s  [%s] %s" % [hid, "PASS" if r[0] else "FAIL", r[1]])
	print("==== 全英雄联机回归: %d/%d 通过 ====" % [pass_n, DataRegistry.heroes.size()])
	get_tree().quit()

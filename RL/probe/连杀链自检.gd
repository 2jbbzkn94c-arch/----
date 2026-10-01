extends Node
## 【2026-09-29 晚·一次性探针·只读】验证用户那条连杀链在 **AI 自己的模拟里**成不成立：
##   ① 红帽(hero_40) 打 嬉皮死神(hero_30, 11 血) 打掉多少；
##   ② 削完之后嬉皮死神是不是**全场最低血**（= 小阴影 hero_15 的 ×2 条件）；
##   ③ 此时小阴影打它多少 —— 够不够 6（= 打死）。
## 结论意义：如果三步都成立，说明 `ai.search()` 本来算得出来，只是**没人问它**（替补选人走的是静态扫描）
##   ⇒ 支持"落位时让搜索自己回答该上谁"（`SUB_BY_SEARCH`）。

const DUMP := "[战局转储] AI: hero_18@(2, 6) hp7/18 atk3 r1 mv3 m0/a0/c0 | hero_40@(1, 5) hp11/13 atk5 r1 mv2 m0/a0/c0 | hero_21@(2, 4) hp19/19 atk1 r2 mv2 m0/a0/c0　‖　玩家: hero_30@(1, 3) hp11/20 atk3 r1 mv2 m0/a0/c0 | hero_41@(3, 3) hp11/24 atk2 r3 mv2 m0/a0/c0 | hero_44@(2, 5) hp1/26 atk2 r1 mv2 m0/a0/c0　‖　碑=[]　‖　障碍=[(0, 4), (0, 3), (4, 4), (4, 3)]　‖　炸弹=[]　‖　buff格=[]　‖　金矿=[]"

var battle: Battle

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	await _rebuild()
	GameState.ai_difficulty = 3
	var ai = battle._make_battle_ai()
	if ai == null:
		print("CHAIN|拿不到 AI"); get_tree().quit(0); return
	var snap := BattleSnapshot.collect(battle)
	var sim = ai.build_state(snap["descs"], snap["occ"], snap["gold"], snap["grave"],
			snap["obstacle"], snap["bomb"], snap["buff"], -1, snap.get("rosters", {}), {}, snap.get("buff_owner", {}))
	var i40 := _idx(sim, "hero_40")
	var i30 := _idx(sim, "hero_30")
	var i44 := _idx(sim, "hero_44")
	if i40 < 0 or i30 < 0:
		print("CHAIN|下标找不到（i40=%d i30=%d i44=%d）" % [i40, i30, i44]); get_tree().quit(0); return
	var red: RefCounted = sim.units[i40]
	var hip: RefCounted = sim.units[i30]
	print("CHAIN|①初始|嬉皮死神 hp=%d｜全场最低血是它吗=%s" % [int(hip.hp), str(ai._sim_lowest_hp(sim, hip))])
	# 【用户链条的第 2 步】先把 1 血的 hero_44 收掉（模拟里就是让它 alive=false、并从占位里摘掉）
	#   —— 这一步不改"谁是最低血"以外的任何东西，但它是小阴影 ×2 能亮的前提（1 血那个不在了）。
	if i44 >= 0:
		var h44: RefCounted = sim.units[i44]
		if h44 != null and h44.alive:
			h44.alive = false
			if sim.occ.get(h44.cell, null) == h44:
				sim.occ.erase(h44.cell)
			sim.walk_cache.clear()
			sim.walk_cache_pass.clear()
			print("CHAIN|②先把 1 血的 hero_44 收掉（用户链条第 2 步）")
	var h1: int = int(ai._adj_foe_hit_on(sim, hip, red))
	print("CHAIN|②红帽(hero_40) 打它真实一击=%d ⇒ 剩 %d" % [h1, maxi(int(hip.hp) - h1, 0)])
	hip.hp = maxi(int(hip.hp) - h1, 1)
	var lowest: bool = ai._sim_lowest_hp(sim, hip)
	print("CHAIN|③削完|嬉皮死神 hp=%d｜现在是全场最低血吗（小阴影 ×2 的条件）=%s" % [int(hip.hp), str(lowest)])
	var sub = ai._sub_probe_unit("hero_15", hip.cell)
	if sub == null:
		print("CHAIN|造不出小阴影的探针单位")
	else:
		var h2: int = int(ai._adj_foe_hit_on(sim, hip, sub))
		print("CHAIN|④小阴影(hero_15) 打它真实一击=%d｜倍率=%d｜够不够收掉(%d 血)：%s" % [
			h2, int(ai._sim_mult_at(sim, sub, hip, hip.cell)), int(hip.hp),
			("够 ⇒ 这一条链成立（先削再 ×2 收）" if h2 >= int(hip.hp) else "不够")])
	print("CHAIN|END")
	get_tree().quit(0)

func _idx(sim, hid: String) -> int:
	for i in sim.units.size():
		var u: RefCounted = sim.units[i]
		if u != null and u.alive and String(u.hero_id) == hid:
			return i
	return -1

func _rebuild() -> void:
	battle = (load("res://scenes/Main.tscn") as PackedScene).instantiate() as Battle
	add_child(battle)
	for i in 3:
		await get_tree().process_frame
	for u in battle.units:
		if is_instance_valid(u):
			u.queue_free()
	battle.units.clear(); battle.occupancy.clear(); battle.graves.clear(); battle.obstacles.clear(); battle.bombs.clear()
	GameState.no_death_limit = false
	GameState.match_over = false
	GameState.active_side = GameState.SIDE_ENEMY
	battle.state = battle.State.ENEMY_TURN
	for i in 2:
		await get_tree().process_frame
	var body := DUMP.substr(String("[战局转储]").length())
	for seg0 in body.split("　‖　"):
		var seg := String(seg0).strip_edges()
		if seg.begins_with("AI:") or seg.begins_with("玩家:"):
			var fn := DataRegistry.Faction.ENEMY if seg.begins_with("AI:") else DataRegistry.Faction.PLAYER
			for one in seg.split(":", true, 1)[1].split("|"):
				var t := String(one).strip_edges()
				if t == "":
					continue
				var sp := t.find(" hp")
				var head := (t.substr(0, sp) if sp > 0 else t)
				var at := head.split("@")
				var u2 := battle._spawn_unit(String(at[0]), fn, _cv(str_to_var("Vector2i" + String(at[1]))))
				if u2 == null:
					continue
				for tok in t.split(" "):
					if String(tok).begins_with("hp"):
						u2.hp = int(String(tok).substr(2).split("/")[0])
		elif seg.begins_with("障碍="):
			for c in _cells(seg.substr(3)):
				battle.obstacles[c] = 2
	for i in 3:
		await get_tree().process_frame
	battle._sync_ranged_adjacent()

func _cells(t: String) -> Array:
	var out: Array = []
	var s := t.strip_edges()
	if s.length() < 3:
		return out
	s = s.substr(1, s.length() - 2)
	for one in s.split("),"):
		var x := String(one).strip_edges()
		if x == "":
			continue
		if not x.ends_with(")"):
			x += ")"
		var v: Vector2i = _cv(str_to_var("Vector2i" + x))
		if v != null:
			out.append(v)
	return out

## 【2026-10-01】转储行里的坐标是**界面口径**（左上角 =(1, 1)）⇒ 这里 −1 换回引擎 0 基。
func _cv(c) -> Vector2i:
	if typeof(c) != TYPE_VECTOR2I:
		return Vector2i.ZERO
	var v: Vector2i = c
	return Vector2i(v.x - DataRegistry.CELL_DISPLAY_OFFSET, v.y - DataRegistry.CELL_DISPLAY_OFFSET)

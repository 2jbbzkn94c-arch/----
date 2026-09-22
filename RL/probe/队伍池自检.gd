extends Node
## 【2026-09-22 一次性探针】队伍池"配方（类型）"整条链对账 —— 跑完即退，**不改任何生产代码**。
##
## 查什么（用户："你自己跑一遍测试，看看选人系统有没有问题"）：
##   ① 每场是不是**随机抽 1 条类型**、抽到哪条
##   ② 卡组是不是 = 锁定首发 + 预设替补（含**多组** `bench_multi`）
##   ③ 部署阶段是不是**按槽位填首发**、候选是不是来自该槽位的**全部候选**（含不在卡组里的，如"复仇者/负墟"）
##   ④ 古灵精怪的**变身形态池**到底有几个（把 `_transform()` 连跑 120 次，收集实际变出来的英雄）
##   ⑤ 没写预设替补的类型：开场替补席应为空（动态替补留给"需要时"）
##
## 用法：
##   godot --headless --path <项目根> --scene res://RL/probe/队伍池自检.tscn
## 输出：每局一行 `POOL|<局号>|...`，末尾一行 `POOL|SUMMARY|...`。
const MATCHES := 16          # 局数（8 个类型 ⇒ 16 局基本都能覆盖到）

var _b: Battle = null

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	Engine.time_scale = 10.0
	GameState.reset_online()
	GameState.dual_control = false      # 敌方交给生产 AI（配方档要的就是它）
	GameState.no_death_limit = false
	GameState.arena_mode = false
	GameState.pick_deck_in_battle = true    # ★ 必须 true：否则游戏**跳过"选卡组"态**、直接用硬编码兜底卡组
	                                        #   （`Battle.gd` 里 player_deck 为空时会填 ["hero_06","hero_17","hero_26"]）
	                                        #   ⇒ 配方这条链根本不会被触发（第一次跑探针就踩到了，state=4 直接进部署）
	GameState.ai_difficulty = 3         # 噩梦 ⇒ strong 档 ⇒ 配方
	var pool_ok := FileAccess.file_exists("res://RL/weights/队伍池.json")
	print("POOL|cfg|difficulty=%d|pool_exists=%s|deck_pick_in_battle=%s" % [
		GameState.ai_difficulty, str(pool_ok), str(GameState.pick_deck_in_battle)])
	var tally := {}
	var bad := 0
	for k in MATCHES:
		var r := await _one_match(k)
		if not bool(r.get("ok", false)):
			bad += 1
		var t := String(r.get("type", "无"))
		tally[t] = int(tally.get(t, 0)) + 1
	print("POOL|SUMMARY|matches=%d|types=%s|bad=%d" % [MATCHES, str(tally), bad])
	get_tree().quit(0)

func _names(ids: Array) -> Array:
	var out: Array = []
	for h in ids:
		out.append(_nm(String(h)))
	return out

func _nm(hid: String) -> String:
	var d := DataRegistry.get_hero(hid)
	if d == null:
		return hid
	return "%s(%s)" % [d.display_name, hid]

func _one_match(k: int) -> Dictionary:
	# ⚠️ **每局都要重设**：`_start_with_player_deck()` 会把 `pick_deck_in_battle` 置回 false，
	#   不重设的话第 2 局起会**跳过"选卡组"态**、直接进战斗（第一次跑探针就是这样：只有第 0 局有效）。
	GameState.pick_deck_in_battle = true
	GameState.match_over = false
	GameState.player_deck = []
	GameState.enemy_deck = []
	GameState.enemy_recipe = {}
	GameState.clear_placement()
	GameState.player_placement = {}
	GameState.enemy_placement = {}
	_b = load("res://scenes/Main.tscn").instantiate() as Battle
	_b.set_random_seed(70000 + k)
	_b._first_side = GameState.SIDE_PLAYER
	get_tree().root.add_child(_b)
	if not await _wait_state([Battle.State.DECK_PICK], 10.0):
		print("POOL|%d|!! did_not_reach_DECK_PICK|state=%d" % [k, int(_b.state)])
		await _teardown()
		return { "ok": false, "type": "无" }
	# 玩家卡组：固定给 5 个（与配方无关，只为把流程推起来）
	var my_deck := ["hero_01", "hero_06", "hero_12", "hero_22", "hero_33"]
	_b._start_with_player_deck(my_deck)
	var rec: Dictionary = GameState.enemy_recipe
	var tid := String(rec.get("id", ""))
	var slots: Array = rec.get("slots", [])
	var slot_desc: Array = []
	for s in slots:
		var pool: Array = (s as Dictionary).get("pool", [])
		slot_desc.append("%d[%s]" % [pool.size(), ",".join(pool)])
	var bench: Array = rec.get("bench", [])
	var bmulti: Array = rec.get("bench_multi", [])
	var gdesc: Array = []
	for g in bmulti:
		var gd := g as Dictionary
		gdesc.append("pool%d:n%d" % [(gd.get("pool", []) as Array).size(), int(gd.get("n", 0))])
	print("POOL|%d|type=%s|slots=%d|%s|bench=%d|bench_multi=%d[%s]|dynamic=%s|jitter=%.1f" % [
		k, tid, slots.size(), "|".join(slot_desc), bench.size(), bmulti.size(), ",".join(gdesc),
		str(bool(rec.get("dynamic_bench", true))), float(rec.get("jitter", 0.0))])
	print("POOL|%d|init_deck=%d[%s]" % [k, GameState.enemy_deck.size(), ",".join(PackedStringArray(GameState.enemy_deck))])
	# ---- 驱动部署（双方轮流；玩家侧我们替他点）----
	var guard := 0
	while (_b.state == Battle.State.DEPLOY or _b.state == Battle.State.PLACE_DEPLOY) and guard < 6000:
		guard += 1
		if _b.state == Battle.State.PLACE_DEPLOY:
			var fn: int = DataRegistry.Faction.PLAYER
			if String(_b._pending_enemy_deploy) != "":
				fn = DataRegistry.Faction.ENEMY
			var placed := false
			for c in _b._spawn_cells(fn):
				if fn == DataRegistry.Faction.PLAYER:
					if _b._try_place_deploy(c):
						placed = true
						break
				else:
					if _b._try_place_enemy_deploy(c):
						placed = true
						break
			if not placed:
				break
		elif _b.state == Battle.State.DEPLOY and _b._deploy_side == 0 and _b.player_deployed.size() < 3:
			for hid in _b.player_pool:
				if not _b.player_deployed.has(String(hid)):
					_b._on_deploy_pick(String(hid))
					break
		await get_tree().process_frame
	# ---- 对账 ----
	var ok := true
	var starters: Array = _b.enemy_deployed.duplicate()
	# ③ 每个首发都应落在对应槽位的候选池里
	for i in mini(starters.size(), slots.size()):
		var pool: Array = ((slots[i] as Dictionary).get("pool", []) as Array)
		if not pool.has(String(starters[i])):
			ok = false
			print("POOL|%d|!! slot_mismatch|slot=%d|starter=%s|pool=[%s]" % [
				k, i + 1, String(starters[i]), ",".join(pool)])
	# ⑤ 动态替补的类型：开场替补席应为空；设置了预设替补的：替补应 = "卡组 −（首发中在卡组里的那些人）"
	#    ⚠️ 首发的第 3 个可能**不在卡组里**（"复仇者/负墟"这类只活在槽位池里的候选）⇒ 不能简单用 卡组−首发数
	var dyn := bool(rec.get("dynamic_bench", true))
	var in_deck_starters := 0
	for s in starters:
		if GameState.enemy_deck.has(String(s)):
			in_deck_starters += 1
	var expect_bench := GameState.enemy_deck.size() - in_deck_starters
	if not dyn and _b.enemy_roster.size() != expect_bench:
		ok = false
		print("POOL|%d|!! bench_count_mismatch|actual=%d|expect=%d|deck=%d|starters_in_deck=%d" % [
			k, _b.enemy_roster.size(), expect_bench, GameState.enemy_deck.size(), in_deck_starters])
	if dyn and _b.enemy_roster.size() != 0:
		ok = false
		print("POOL|%d|!! dynamic_but_bench_not_empty|actual=%d" % [k, _b.enemy_roster.size()])
	print("POOL|%d|starters=[%s]|bench=[%s]|pstarters=[%s]|verdict=%s" % [
		k, ",".join(PackedStringArray(starters)),
		",".join(PackedStringArray(_b.enemy_roster)),
		",".join(PackedStringArray(_b.player_deployed)),
		"OK" if ok else "BAD"])
	# ④ 古灵精怪形态池（若本局场上有）
	for u in _b.units:
		if u == null or not is_instance_valid(u) or not u.alive:
			continue
		if String(u.hero_id) != "hero_28":
			continue
		var seen := {}
		for i in 200:
			if not is_instance_valid(u):
				break
			_b._transform(u)
			seen[String(u.hero_id)] = true
		seen.erase("hero_28")
		print("POOL|%d|gremlin|faction=%d|forms=%d|[%s]" % [
			k, int(u.faction), seen.size(), ",".join(PackedStringArray(seen.keys()))])
	# ⑥ 动态替补：直接问它"现在需要补位，你上谁"（候选应来自**全英雄池**，可以不在卡组里）
	if dyn:
		for t in 3:
			var pk: Dictionary = _b._dynamic_sub_pick()
			var pid := String(pk.get("id", ""))
			print("POOL|%d|dyn_sub_pick|id=%s|in_deck=%s|cell=%s" % [
				k, pid, str(GameState.enemy_deck.has(pid)), str(pk.get("cell", Vector2i(-99, -99)))])
	await _teardown()
	return { "ok": ok, "type": tid }

func _wait_state(states: Array, sec: float) -> bool:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < int(sec * 1000.0):
		if _b != null and is_instance_valid(_b) and states.has(_b.state):
			return true
		await get_tree().process_frame
	return false

func _teardown() -> void:
	if _b != null and is_instance_valid(_b):
		_b.queue_free()
	_b = null
	await get_tree().process_frame
	await get_tree().process_frame

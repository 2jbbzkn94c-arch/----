extends Node
## 【2026-09-25 一次性探针·临时】竞技场选人 AI 的**信息集 + 第一手评估**自检。
##
## 回答两件事：
##   ① 用户口径「**AI 不能在偷看玩家的牌，只能根据自己选择的牌和给玩家的牌做配合和克制**」——
##      新公式必须**恰好等于**"只对『敌方自己送出去的牌』求和"，且对"玩家手里没送过的那几张"记 0 分；
##   ② 用户第二版口径「**第一手克制分也不是恒为零，要考虑自己选的和送给敌人的那张关系**」——
##      所以探针把**敌方第一手**那一刻单独摆出来（前 4 轮玩家轮手工推完），打印：
##      敌方手里已有几名、这一对的 `赠牌关系` 分（两个方向）、`克玩家(已送)`（那一手应为 0）与选择结果。
##
## 输出：每行 `PROBE|...`，末尾 `PROBE|END`。

var _b: Battle = null

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	GameState.reset_online()
	GameState.dual_control = false
	GameState.arena_mode = true
	GameState.pick_deck_in_battle = false
	GameState.ai_difficulty = 3          # 跟实战一致（难度 0 才走掷签）
	_b = load("res://scenes/Main.tscn").instantiate() as Battle
	_b.set_random_seed(20260925)
	get_tree().root.add_child(_b)
	await get_tree().process_frame
	_b.call("_begin_arena_draft")

	# ---- 手工推完前 4 轮"玩家轮"（每轮玩家拿第 1 张、另一张归敌方），
	#      这样才能**停在敌方第一手之前**看它的信息集（真调 `_on_arena_pick` 会一路跑完 8 轮）----
	var picked: Array = _b.get("_arena_picked")
	var enemy: Array = _b.get("_arena_enemy")
	var pool: Array = _b.get("_arena_pool")
	for r in 4:
		var pend: Array = (_b.get("_arena_pending") as Array).duplicate()
		if pend.size() < 2:
			print("PROBE|!!|第 %d 轮没拿到候选" % (r + 1))
			break
		print("PROBE|玩家轮%d|候选=%s｜玩家拿=%s（另一张归敌方）" % [r + 1, _nms(pend), _nm(String(pend[0]))])
		picked.append(String(pend[0]))
		enemy.append(String(pend[1]))
		pool.erase(String(pend[0]))
		pool.erase(String(pend[1]))
		_b.set("_arena_player_rounds", int(_b.get("_arena_player_rounds")) + 1)
		_b.set("_arena_pending", [pool[0], pool[1]] if pool.size() >= 2 else [])

	# ---- 敌方**第一手**那一刻的信息集与评估 ----
	# 【第三版口径】玩家塞过来的那 4 张（`_arena_enemy` 前 4 个）在选人阶段**不算 AI 的信息** ⇒
	#   它"知道"的自己的牌 = `_arena_own_picks()`（自己挑的，第一手时为空）。
	var own: Array = _b.call("_arena_own_picks")
	print("PROBE|敌方第一手|队伍里已有 %d 名，其中**玩家塞过来的** %d 名 = %s｜**它自己挑的** %d 名 = %s" % [
		enemy.size(), enemy.size() - own.size(), _nms(enemy.slice(0, enemy.size() - own.size())), own.size(), _nms(own)])
	var pair: Array = (_b.get("_arena_pending") as Array).duplicate()
	var a := String(pair[0])
	var b := String(pair[1])
	print("PROBE|敌方第一手|本轮两张 = %s ↔ %s（它拿 1 张，另一张归玩家）" % [_nm(a), _nm(b)])
	for side in [0, 1]:
		var take := a if side == 0 else b
		var give := b if side == 0 else a
		var tot: float = float(_b.call("_hero_strength", take)) + float(_b.call("_deck_synergy", own, take)) \
			+ float(_b.call("_counter_player_score", take)) + float(_b.call("_counter_gift_score", take, give)) \
			+ float(DataRegistry.role_balance_bonus(own, take))
		print("PROBE|敌方第一手·若拿%s|单体%.1f + 己方协同%.1f + 克玩家(已送)%.1f + **赠牌关系%.1f** + 职能配比%.1f ⇒ 总分%.1f｜赠牌明细=%s" % [
			_nm(take), float(_b.call("_hero_strength", take)), float(_b.call("_deck_synergy", own, take)),
			float(_b.call("_counter_player_score", take)), float(_b.call("_counter_gift_score", take, give)),
			float(DataRegistry.role_balance_bonus(own, take)), tot,
			str(_b.call("_counter_gift_note", take, give))])

	# ---- 让敌方把后 4 轮跑完 ----
	_b.call("_action_arena_enemy_pick")
	var gave: Array = _b.get("_arena_gave")
	print("PROBE|名单|玩家%d名=%s" % [picked.size(), _nms(picked)])
	print("PROBE|名单|敌方%d名=%s" % [enemy.size(), _nms(enemy)])
	print("PROBE|名单|敌方送出去的%d名=%s" % [gave.size(), _nms(gave)])

	# ---- 口径核对：新公式 ≡ 只对"送出去的"求和；与"偷看玩家全部牌"的差 = 被去掉的偷看 ----
	var heroes: Array = DataRegistry.heroes.keys()
	var mismatch := 0
	var changed: Array = []
	for h in heroes:
		var new_s: float = _b.call("_counter_player_score", String(h))
		var only_gave := 0.0
		var all_picked := 0.0
		for pid in gave:
			var c1 := DataRegistry.counter_bonus(String(h), String(pid))
			if c1 > 0.0:
				only_gave += c1
		for pid in picked:
			var c2 := DataRegistry.counter_bonus(String(h), String(pid))
			if c2 > 0.0:
				all_picked += c2
		if absf(new_s - only_gave) > 0.001:
			mismatch += 1
			print("PROBE|!!|%s 新公式=%.1f ≠ 只对送出的求和 %.1f" % [_nm(String(h)), new_s, only_gave])
		if absf(all_picked - only_gave) > 0.001:
			changed.append("%s(%.0f→%.0f)" % [_nm(String(h)), all_picked, only_gave])
	print("PROBE|判定|新公式 ≡ 只对送出去的求和：不一致 %d 个（应为 0）" % mismatch)
	print("PROBE|判定|被去掉的「偷看」：%d 名英雄的克制分变了 %s" % [changed.size(), str(changed)])
	# ---- 赠牌关系"能不能非零"的存在性检查（这一局的候选对恰好没关系也无所谓）----
	#   把两项拆开打印：① take↔give 这一对本身 ② give↔"它自己挑过的牌"（明细里会写清是谁）
	var hit := ""
	for x in heroes:
		for y in heroes:
			if x == y:
				continue
			var v: float = _b.call("_counter_gift_score", String(x), String(y))
			if absf(v) > 0.05:
				var pair_part: float = DataRegistry.counter_bonus(String(x), String(y)) - DataRegistry.counter_bonus(String(y), String(x))
				hit = "拿「%s」送「%s」⇒ 赠牌关系 %+.1f（其中「这一对本身」 %+.1f ／ 与它自己挑过的牌 %+.1f）｜明细=%s" % [
					_nm(String(x)), _nm(String(y)), v, pair_part, v - pair_part,
					str(_b.call("_counter_gift_note", String(x), String(y)))]
				break
		if hit != "":
			break
	print("PROBE|赠牌关系存在性|%s" % hit)
	print("PROBE|END")
	get_tree().quit(0)

func _nm(hid: String) -> String:
	var d: DataRegistry.HeroDef = DataRegistry.heroes.get(hid, null)
	return d.display_name if d != null else hid

func _nms(arr: Array) -> String:
	var out: Array = []
	for h in arr:
		out.append(_nm(String(h)))
	return "[" + ", ".join(out) + "]"

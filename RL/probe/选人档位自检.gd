extends Node
## 【2026-09-25 一次性探针·临时】"选人阶段"的**难度梯度**自检（用户口径：
##   简单 = 完全不看评分瞎选 · 普通 = 照旧日"简单档"（拉平掷签）· 困难/噩梦 = 保持原样）。
##
## 两块读数：
##   ① **权重函数**直查（`_pick_weight`）：给两个分数悬殊的候选（比如 5 分 vs 30 分）看权重比 ——
##      简单应恒为 1:1（评分完全不参与）、普通应是拉平后的 ≈1.5:4（3~4 倍）、困难/噩梦应是 ≈6:31。
##   ② **端到端**：同一批盘面（20 个种子重新洗牌）分别跑四种难度，各跑一遍竞技场敌方 4 手，
##      统计"它挑中的那张的单体强度" vs "这一对两张开局的均值 / 最大值" ——
##      简单应≈均值（等于瞎选）、普通介于均值与最大之间、困难/噩梦≈最大。
##
## 输出：每行 `PROBE|...`，末尾 `PROBE|END`。

const ROUNDS := 20          # 每种难度跑多少局选人（每局 4 手）
var _b: Battle = null

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	GameState.reset_online()
	GameState.dual_control = false
	GameState.arena_mode = true
	GameState.pick_deck_in_battle = false
	_b = load("res://scenes/Main.tscn").instantiate() as Battle
	get_tree().root.add_child(_b)
	await get_tree().process_frame

	# ① 权重函数直查（低分 5 / 高分 30 —— 对应"弱英雄 vs 强英雄"）
	print("PROBE|权重函数|两个候选 5 分 vs 30 分 的抽取权重比：")
	for d in [0, 1, 2, 3]:
		GameState.ai_difficulty = d
		var w5: float = _b.call("_pick_weight", 5.0)
		var w30: float = _b.call("_pick_weight", 30.0)
		print("PROBE|权重函数|难度%d（%s）：w(5)=%.2f · w(30)=%.2f ⇒ 强/弱 = %.2f 倍%s" % [
			d, ["简单", "普通", "困难", "噩梦"][d], w5, w30, w30 / w5,
			"（评分完全不参与 = 瞎选）" if is_equal_approx(w5, w30) else ""])

	# ② 端到端：每种难度跑 ROUNDS 局竞技场选人，看它挑中的牌有多强
	for d in [0, 1, 2, 3]:
		GameState.ai_difficulty = d
		var n := 0
		var sum_pick := 0.0
		var sum_mean := 0.0
		var sum_best := 0.0
		for t in ROUNDS:
			_b.set_random_seed(770000 + t)      # 每局重洗牌：候选对/池子都换一轮
			_b.call("_begin_arena_draft")
			# 玩家 4 轮：固定拿每对的第一张（确定性，四种难度用同一套盘面）
			var picked: Array = _b.get("_arena_picked")
			var enemy: Array = _b.get("_arena_enemy")
			var pool: Array = _b.get("_arena_pool")
			for r in 4:
				var pend: Array = (_b.get("_arena_pending") as Array).duplicate()
				if pend.size() < 2:
					break
				picked.append(String(pend[0]))
				enemy.append(String(pend[1]))
				pool.erase(String(pend[0]))
				pool.erase(String(pend[1]))
				_b.set("_arena_player_rounds", int(_b.get("_arena_player_rounds")) + 1)
				_b.set("_arena_pending", [pool[0], pool[1]] if pool.size() >= 2 else [])
			# 敌方 4 手：先记下"接下来的每一对"（= 池子按顺序的前两个一对），再让它跑
			var pool_before: Array = pool.duplicate()
			_b.call("_action_arena_enemy_pick")
			var own: Array = _b.call("_arena_own_picks")
			for k in own.size():
				if (k * 2 + 1) >= pool_before.size():
					break
				var x: float = float(_b.call("_hero_strength", String(pool_before[k * 2])))
				var y: float = float(_b.call("_hero_strength", String(pool_before[k * 2 + 1])))
				var p: float = float(_b.call("_hero_strength", String(own[k])))
				sum_pick += p
				sum_mean += (x + y) * 0.5
				sum_best += maxf(x, y)
				n += 1
		if n == 0:
			print("PROBE|端到端|难度%d 没跑到任何一手" % d)
			continue
		print("PROBE|端到端|难度%d（%s）：%d 手 ｜ 挑中均值 %.2f ／ 每对均值 %.2f ／ 每对最大值 %.2f ⇒ 比瞎选高 %+.2f、比'总挑最强'差 %+.2f" % [
			d, ["简单", "普通", "困难", "噩梦"][d], n,
			sum_pick / n, sum_mean / n, sum_best / n,
			sum_pick / n - sum_mean / n, sum_pick / n - sum_best / n])
	print("PROBE|END")
	get_tree().quit(0)

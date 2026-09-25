extends Node
## 【2026-09-24 一次性探针·用户报的 bug】"远程被贴身 ⇒ AI 把它的伤害只算 1"这条估计，
##   在**它其实退得掉**的时候应当按"退开后的满额伤害"算（用户原话：「实际如果有空位，玩家会退开远程」）。
## 做法：直接建一个最小 Sim（一个我方近战贴身 + 一个对面远程），调 `BattleAI._threat_hit_value()`：
##   ① 远程周围有空格可退 ⇒ 应返回满额攻击（> 1）
##   ② 把可退的格子全堵上 / 把它的移动力压成 0 ⇒ 应返回 1（贴身压制）
## 用法：godot --headless --path . --scene res://RL/probe/贴身退开估值自检.tscn

const AI := preload("res://src/BattleAI.gd")
# 两份同步副本也 preload 一下：它们坏了（同步出问题）会在这里当场炸出来
const AI_FORK := preload("res://RL/ai/AI_Battle.gd")
const AI_ORIG := preload("res://RL/ai/AI_Battle_原版.gd")

var _fail := 0

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	var grid := HexGrid.new(5, 7, 60.0)
	var ai = AI.new(grid)
	# 双方各一个单位：对面远程站 (2,3)，我方近战贴它 (2,4)
	var foe: AI.SimUnit = AI.SimUnit.new()
	foe.hero_id = "hero_10"      # 白游侠（远程，面板攻击 3）
	foe.fn = DataRegistry.Faction.PLAYER   # "对面" = 玩家方（AI 估的就是玩家下回合的伤害）
	foe.cell = Vector2i(2, 3)
	foe.atk = 3
	foe.eatk = 3
	foe.atk_range = 2
	foe.atk_type = DataRegistry.AttackType.RANGED
	foe.emove = 3
	foe.alive = true
	var mine: AI.SimUnit = AI.SimUnit.new()
	mine.hero_id = "hero_13"     # 独角龟（近战），贴身牵制
	mine.fn = DataRegistry.Faction.ENEMY
	mine.cell = Vector2i(2, 4)
	mine.atk = 2
	mine.eatk = 2
	mine.atk_range = 1
	mine.atk_type = DataRegistry.AttackType.MELEE
	mine.emove = 3
	mine.alive = true
	var sim: AI.Sim = AI.Sim.new()
	sim.units = [foe, mine]
	sim.occ = { foe.cell: 0, mine.cell: 1 }

	# ① 有空位可退（只有我方这一个单位贴着，四周大多空着）⇒ 应算满额
	var v_free: float = ai._threat_hit_value(sim, foe, 1, false)
	print("PROBE|① 退得掉：伤害 = %.2f（应 = 满额 3.00）" % v_free)
	if v_free < 2.9:
		_fail += 1
		print("PROBE|  ❌ 退得掉却还按压 1 估")

	# ② 把它四周能站的空格全用"我方单位"堵上（只剩原格）⇒ 退不掉 ⇒ 应算 1
	var blockers: Array = []
	var idx := 2
	for n in grid.neighbors(foe.cell):
		if grid.in_bounds(n) and n != mine.cell:
			var b: AI.SimUnit = AI.SimUnit.new()
			b.fn = DataRegistry.Faction.ENEMY
			b.cell = n
			b.atk_type = DataRegistry.AttackType.MELEE
			b.alive = true
			sim.units.append(b)
			sim.occ[n] = idx
			idx += 1
			blockers.append(n)
	var v_blocked: float = ai._threat_hit_value(sim, foe, 1, false)
	print("PROBE|② 退不掉（邻格被堵 %d 个）：伤害 = %.2f（应 = 1.00）" % [blockers.size(), v_blocked])
	if v_blocked > 1.01:
		_fail += 1
		print("PROBE|  ❌ 退不掉却算成了满额")

	# ③ 动不了（荆棘/眩晕 ⇒ emove=0）⇒ 也该按 1 算
	for n in blockers:
		sim.occ.erase(n)
	sim.units = [foe, mine]
	var foe2: AI.SimUnit = AI.SimUnit.new()
	foe2.hero_id = "hero_10"
	foe2.fn = DataRegistry.Faction.PLAYER
	foe2.cell = Vector2i(2, 3)
	foe2.atk = 3
	foe2.eatk = 3
	foe2.atk_range = 2
	foe2.atk_type = DataRegistry.AttackType.RANGED
	foe2.emove = 0
	foe2.alive = true
	sim.units = [foe2, mine]
	sim.occ = { foe2.cell: 0, mine.cell: 1 }
	var v_no_move: float = ai._threat_hit_value(sim, foe2, 1, false)
	print("PROBE|③ 动不了（emove=0）：伤害 = %.2f（应 = 1.00）" % v_no_move)
	if v_no_move > 1.01:
		_fail += 1
		print("PROBE|  ❌ 动不了却算成了满额")

	# ④ 没被贴身 ⇒ 照旧满额（防止误伤这条老口径）
	var far: AI.SimUnit = AI.SimUnit.new()
	far.hero_id = "hero_10"
	far.fn = DataRegistry.Faction.PLAYER
	far.cell = Vector2i(2, 1)     # 离我方近战 2 格
	far.atk = 3
	far.eatk = 3
	far.atk_range = 2
	far.atk_type = DataRegistry.AttackType.RANGED
	far.emove = 3
	far.alive = true
	sim.units = [far, mine]
	sim.occ = { far.cell: 0, mine.cell: 1 }
	var v_far: float = ai._threat_hit_value(sim, far, 2, false)
	print("PROBE|④ 没被贴身（距离 2）：伤害 = %.2f（应 = 满额 3.00）" % v_far)
	if v_far < 2.9:
		_fail += 1
		print("PROBE|  ❌ 没被贴身却掉了伤害")

	print("PROBE|⑤ 三份同源：src=%s · fork=%s · orig=%s" % [
		"ok" if AI != null else "null", "ok" if AI_FORK != null else "null", "ok" if AI_ORIG != null else "null"])
	print("PROBE|%s" % ("全部通过 ✅" if _fail == 0 else "有 %d 项不对 ❌" % _fail))
	print("PROBE|END")
	get_tree().quit(0 if _fail == 0 else 1)

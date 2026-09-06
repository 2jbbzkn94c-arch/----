class_name BattleAI
extends RefCounted
## 敌方强力 AI：对敌方"本回合全部可能操作"做搜索并打分，选出最优行动序列。
## 采用"按单位逐次扩展 + 波束保留最优"的搜索，评估函数综合考虑单位强度/击杀/走位。

# ---- 轻量模拟状态 ----
class SimUnit:
	var fn := 0
	var hero_id := ""
	var cell := Vector2i.ZERO
	var hp := 10
	var max_hp := 10
	var atk := 4          # 基础攻击
	var eatk := 4         # 有效攻击（含buff/冲锋/太阳斩/攻降）
	var move := 3         # 基础移动
	var emove := 3        # 有效移动（含移动buff/冰冻/眩晕→0）
	var atk_range := 1
	var atk_type := 0
	var skills: Array = []
	var moved := false
	var attacked := false
	var counter_used := false
	var alive := true
	var name := ""
	var stunned := false    # 眩晕：不能移动/攻击/反击
	var silenced := false   # 沉默：非关键词技能失效
	var shield := false     # 圣盾：抵挡一次伤害
	var heavy := false      # 重伤：受到的伤害+1
	var poisoned := false   # 猛毒（每回合开始1点，供评估用）
	var frozen := false     # 冰冻（移动-1）
	var hurt_times := 0     # 本回合被攻击次数（集火评估）
	var aura_used := false   # 本回合已触发过的光环/次数技（圣光护盾等每回合限一次）

class Sim:
	var units: Array = []
	var occ: Dictionary = {}   # cell -> idx
	var gold_cells: Dictionary = {}   # cell -> true（黄金矿工可拾取的金矿）
	var graves: Dictionary = {}        # cell -> true（阵亡墓碑：阻挡移动，不可落停）
	var obstacles: Dictionary = {}     # cell -> true（障碍物：阻挡移动与攻击视线）

	func clone() -> Sim:
		var c := Sim.new()
		c.gold_cells = gold_cells.duplicate()
		c.graves = graves.duplicate()
		c.obstacles = obstacles.duplicate()
		for u in units:
			var cu := SimUnit.new()
			cu.fn = u.fn
			cu.hero_id = u.hero_id
			cu.cell = u.cell
			cu.hp = u.hp
			cu.max_hp = u.max_hp
			cu.atk = u.atk
			cu.eatk = u.eatk
			cu.move = u.move
			cu.emove = u.emove
			cu.atk_range = u.atk_range
			cu.atk_type = u.atk_type
			cu.skills = u.skills.duplicate()
			cu.moved = u.moved
			cu.attacked = u.attacked
			cu.counter_used = u.counter_used
			cu.alive = u.alive
			cu.name = u.name
			cu.stunned = u.stunned
			cu.silenced = u.silenced
			cu.shield = u.shield
			cu.heavy = u.heavy
			cu.poisoned = u.poisoned
			cu.frozen = u.frozen
			cu.hurt_times = u.hurt_times
			cu.aura_used = u.aura_used
			c.units.append(cu)
		c.occ = occ.duplicate()
		return c

var grid: HexGrid
var difficulty := 1   # 0 简单 / 1 普通 / 2 困难

const MAX_MOVE_OPTIONS := 16

func _init(g: HexGrid) -> void:
	grid = g

# 由 Battle 提供的数据构建模拟状态（units 顺序与 Battle.units 一致）
func build_state(unit_descs: Array, occ: Dictionary, gold_cells: Dictionary = {}, graves: Dictionary = {}, obstacles: Dictionary = {}) -> Sim:
	var s := Sim.new()
	s.gold_cells = gold_cells.duplicate()
	s.graves = graves.duplicate()
	s.obstacles = obstacles.duplicate()
	for d in unit_descs:
		var u := SimUnit.new()
		u.fn = d["fn"]
		u.hero_id = d["hero"]
		u.cell = d["cell"]
		u.hp = d["hp"]
		u.max_hp = d["max_hp"]
		u.atk = d["atk"]
		u.eatk = d.get("eatk", d["atk"])
		u.move = d["move"]
		u.emove = d.get("emove", d["move"])
		u.atk_range = d["atk_range"]
		u.atk_type = d["atk_type"]
		u.skills = d["skills"].duplicate()
		u.name = d["name"]
		u.stunned = d.get("stunned", false)
		u.silenced = d.get("silenced", false)
		u.shield = d.get("shield", false)
		u.heavy = d.get("heavy", false)
		u.poisoned = d.get("poisoned", false)
		u.frozen = d.get("frozen", false)
		s.units.append(u)
	s.occ = occ.duplicate()
	return s

# ---- 主入口：返回最优行动序列 [{idx, action}] ----
func search(sim: Sim, enemy_faction: int) -> Array:
	var enemy_idxs: Array = []
	for i in sim.units.size():
		if sim.units[i].fn == enemy_faction and sim.units[i].alive:
			enemy_idxs.append(i)

	# 自由行动顺序：每层从"尚未行动"的敌人中任选一个扩展，让搜索能探索不同攻击顺序
	# （如先近战贴脸、后远程收割残血），选出整体利益最大的方案。用 done 记录各状态已行动单位。
	var states: Array = [{ "sim": sim, "path": [], "score": _evaluate(sim), "done": {} }]
	while true:
		var pending := false
		var next: Array = []
		for st in states:
			# 找出该状态尚未行动的敌人
			var remaining: Array = []
			for i in enemy_idxs:
				if not (st["done"] as Dictionary).has(i):
					remaining.append(i)
			if remaining.size() == 0:
				next.append(st)   # 已全部行动完，保留该完成态
				continue
			pending = true
			for idx in remaining:
				var a_list := _actions_for(st["sim"], idx)
				for a in a_list:
					var s2: Sim = st["sim"].clone()
					_apply(s2, idx, a)
					var path: Array = (st["path"] as Array).duplicate()
					path.append({ "idx": idx, "action": a })
					var done2: Dictionary = (st["done"] as Dictionary).duplicate()
					done2[idx] = true
					next.append({ "sim": s2, "path": path, "score": _evaluate(s2) + _jitter(), "done": done2 })
		if not pending:
			break
		next.sort_custom(func(a, b): return a["score"] > b["score"])
		states = next.slice(0, _beam())
	if states.size() == 0:
		return []
	return states[0]["path"]

# 难度决定保留的状态数（困难=搜索更充分；波束越大越接近全局最优）
func _beam() -> int:
	if difficulty >= 2:
		return 110
	if difficulty == 1:
		return 60
	return 20

# 难度相关的随机抖动（简单=易失误，困难=纯最优）
func _jitter() -> float:
	if difficulty >= 2:
		return 0.0
	if difficulty == 1:
		return randf_range(-1.5, 1.5)
	return randf_range(-8.0, 8.0)

# ---- 生成某单位本回合所有候选行动 ----
func _actions_for(sim: Sim, idx: int) -> Array:
	var u: SimUnit = sim.units[idx]
	# 眩晕：无法移动、攻击、反击（真实规则）
	if u.stunned:
		return [{ "move": null, "atk": -1 }]
	# 可移动到的空格（不含自己被占格外的空位；若是原地则移动为空）
	var move_cells: Array = []
	if not u.moved:
		var reach := _move_cells(sim, u)
		var ranked: Array = []
		for c in reach.keys():
			var target := _nearest_player(sim, c)
			var d := 1 << 30
			if target != null:
				d = grid.distance(c, target.cell)
			# 黄金矿工：可达的金矿格优先列入候选（优先走过去拾取）
			if u.hero_id == "hero_42" and sim.gold_cells.has(c):
				d = -1
			# 走位质量：落点被玩家威胁越强，排序越靠后（同时保留近战贴脸候选）
			var threat := _incoming_damage(sim, c, u.fn)
			ranked.append({ "cell": c, "d": d, "threat": threat })
		# 主排序：接近玩家（攻击机会）优先；同距离下威胁小的格优先
		ranked.sort_custom(func(a, b):
			if a["d"] != b["d"]:
				return a["d"] < b["d"]
			return a["threat"] < b["threat"])
		for i in mini(MAX_MOVE_OPTIONS, ranked.size()):
			move_cells.append(ranked[i]["cell"])
		# 再补入几个"低威胁"的走位格（撤退/绕后），避免只保留贴脸候选
		var safe_ranked: Array = []
		for r in ranked:
			if r["threat"] <= 0.0:
				safe_ranked.append(r)
		safe_ranked.sort_custom(func(a, b): return a["threat"] < b["threat"])
		for r in safe_ranked:
			if move_cells.has(r["cell"]):
				continue
			move_cells.append(r["cell"])
			if move_cells.size() >= MAX_MOVE_OPTIONS + 4:
				break
		# **能攻击的落点强制入选**：任意能打到一个玩家的格子都保留攻击组合，
		# 否则"能打的位置"可能因排名靠后被砍掉，出现"能攻不攻"。
		for c in reach.keys():
			if move_cells.has(c):
				continue
			if _valid_targets(sim, u, c).size() > 0:
				move_cells.append(c)

	var combos: Array = []
	# 追加"原地不动"作为移动候选
	move_cells.append(u.cell)

	# 后勤：不能主动攻击
	var can_attack := not u.skills.has(DataRegistry.Skill.LOGISTICS)
	# 攻击组合：从每个落点出发可攻击的目标
	for mc in move_cells:
		var targets := _valid_targets(sim, u, mc)
		if targets.size() > 0 and not u.attacked and can_attack:
			for t in targets:
				combos.append({ "move": null if mc == u.cell else mc, "atk": t })
		elif not u.attacked and can_attack:
			# 无目标可打，仅移动
			if mc != u.cell:
				combos.append({ "move": mc, "atk": -1 })
	# 纯移动（即便能攻击，也可选择只移动走位）
	if not u.moved:
		for mc in move_cells:
			if mc != u.cell:
				combos.append({ "move": mc, "atk": -1 })
	if combos.size() == 0:
		combos.append({ "move": null, "atk": -1 })
	return combos

func _move_cells(sim: Sim, u: SimUnit) -> Dictionary:
	# 大骑士：沿 6 个轴向直线冲锋（与玩家一致，避免规划与执行轨迹不符）。
	# 途中被单位/墓碑/**障碍物**阻挡即停：障碍同样挡冲锋，防止 AI 计划穿墙。
	if u.hero_id == "hero_24":
		var out := {}
		var dirs: Array[Vector2i] = [Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 1), Vector2i(-1, 0), Vector2i(0, -1), Vector2i(1, -1)]
		for d in dirs:
			var ax := grid.axial_of(u.cell) + d
			while true:
				var off := grid.offset_of(ax)
				if not grid.in_bounds(off):
					break
				if sim.occ.has(off) or sim.graves.has(off) or sim.obstacles.has(off):
					break
				out[off] = true
				ax += d
		return out
	var stop := sim.occ.duplicate()
	var blockers := sim.occ.duplicate()
	if u.skills.has(DataRegistry.Skill.INFILTRATE):
		blockers = {}
		for c in sim.occ.keys():
			if sim.units[sim.occ[c]].fn == u.fn:
				blockers[c] = true
		for g in sim.graves.keys():
			stop[g] = true   # 渗透：墓碑可穿行，但不可落停
	else:
		for g in sim.graves.keys():
			stop[g] = true
			blockers[g] = true
	return grid.reachable(u.cell, u.emove, stop, blockers)

func _in_range(sim: Sim, u: SimUnit, from_cell: Vector2i, t: SimUnit) -> bool:
	var d := grid.distance(from_cell, t.cell)
	var range_at := u.atk_range
	if u.atk_type == DataRegistry.AttackType.RANGED and _sim_enemy_adjacent(sim, u, from_cell):
		range_at = 1   # 远程被贴身：射程降为1
	if d < 1 or d > range_at:
		return false
	# 血锁：只能沿直线攻击（6 条轴向方向之一），与真实规则一致
	if u.hero_id == "hero_41" and not _sim_straight_line_cells(from_cell, t.cell):
		return false
	# 障碍物阻挡攻击视线（与真实规则一致）
	if _sim_path_blocked(sim, from_cell, t.cell):
		return false
	return true

# 血锁：判定 to 是否位于从 from 出发的某条六边形直线上
func _sim_straight_line_cells(from_cell: Vector2i, to_cell: Vector2i) -> bool:
	var da := grid.axial_of(from_cell)
	var db := grid.axial_of(to_cell)
	var dx := db.x - da.x
	var dy := db.y - da.y
	if dx == 0 and dy == 0:
		return true
	var g := _gcd(abs(dx), abs(dy))
	var sx := int(dx / float(g))
	var sy := int(dy / float(g))
	var dirs: Array = [Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 1), Vector2i(-1, 0), Vector2i(0, -1), Vector2i(1, -1)]
	for d in dirs:
		if d.x == sx and d.y == sy:
			return true
	return false

func _gcd(a: int, b: int) -> int:
	while b != 0:
		var t := a % b
		a = b
		b = t
	return max(a, 1)

# 模拟：from->to 之间（不含两端）是否有障碍物阻挡攻击
func _sim_path_blocked(sim: Sim, from_cell: Vector2i, to_cell: Vector2i) -> bool:
	if from_cell == to_cell:
		return false
	var fa := grid.axial_of(from_cell)
	var ta := grid.axial_of(to_cell)
	var dx := ta.x - fa.x
	var dy := ta.y - fa.y
	var steps := maxi(abs(dx), abs(dy))
	if steps <= 1:
		return false
	for s in range(1, steps):
		var ax: int = fa.x + int(round(float(dx) * float(s) / float(steps)))
		var ay: int = fa.y + int(round(float(dy) * float(s) / float(steps)))
		var off := grid.offset_of(Vector2i(ax, ay))
		if sim.obstacles.has(off):
			return true
		if sim.occ.has(off):
			return true   # 单位（敌我）也阻挡攻击视线：与真实规则一致
	return false

# 模拟里某格是否有相邻的对立单位（用于远程被贴身判定）
func _sim_enemy_adjacent(sim: Sim, u: SimUnit, from_cell: Vector2i) -> bool:
	for i in sim.units.size():
		var t: SimUnit = sim.units[i]
		if t.alive and t.fn != u.fn and grid.distance(from_cell, t.cell) == 1:
			# 被障碍物隔断的相邻攻击不算被贴身（与真实规则一致）
			if _sim_path_blocked(sim, from_cell, t.cell):
				continue
			return true
	return false

# 返回某落点可攻击的目标 idx（含嘲讽规则）
func _valid_targets(sim: Sim, u: SimUnit, from_cell: Vector2i) -> Array:
	var taunts: Array = []
	for i in sim.units.size():
		var t: SimUnit = sim.units[i]
		if t.alive and t.fn != u.fn and t.skills.has(DataRegistry.Skill.TAUNT) and _in_range(sim, u, from_cell, t):
			taunts.append(i)
	var out: Array = []
	for i in sim.units.size():
		var t: SimUnit = sim.units[i]
		if not t.alive or t.fn == u.fn or not _in_range(sim, u, from_cell, t):
			continue
		if taunts.size() > 0 and not t.skills.has(DataRegistry.Skill.TAUNT):
			continue
		out.append(i)
	return out

func _nearest_player(sim: Sim, cell: Vector2i) -> SimUnit:
	var best: SimUnit = null
	var best_d := 1 << 30
	for i in sim.units.size():
		var t: SimUnit = sim.units[i]
		if t.alive and t.fn != DataRegistry.Faction.ENEMY:
			var d := grid.distance(cell, t.cell)
			if d < best_d:
				best_d = d
				best = t
	return best

# ---- 应用一个行动到模拟状态 ----
func _apply(sim: Sim, idx: int, a: Dictionary) -> void:
	var u: SimUnit = sim.units[idx]
	if a.has("move") and a["move"] != null:
		var mc: Vector2i = a["move"]
		if mc != u.cell:
			var prev_cell: Vector2i = u.cell
			sim.occ.erase(u.cell)
			u.cell = mc
			sim.occ[mc] = idx
			u.moved = true
			# 大骑士：冲锋移动距离加成攻击力（与真实规则一致，冲越远攻越高）
			if u.hero_id == "hero_24":
				u.eatk += grid.distance(prev_cell, mc)
			# 黄金矿工踏上加分的金矿格：拾取（攻击+1，血量上限+3）
			if u.hero_id == "hero_42" and sim.gold_cells.has(mc):
				sim.gold_cells.erase(mc)
				u.atk += 1
				u.max_hp += 3
				u.hp += 3
			# 移动后专属（与真实规则同触发点：移动落位后、攻击前；沉默时失效）
			if not u.silenced:
				_sim_on_move(sim, u)
	if a.has("atk") and a["atk"] != null and int(a["atk"]) >= 0:
		var tidx := int(a["atk"])
		var t: SimUnit = sim.units[tidx]
		if t.alive:
			# 长角：自己结算基础伤害——击退则 1 倍、不能击退则 2 倍（与真实 handles_base_damage 一致）
			if u.hero_id == "hero_32" and not u.silenced:
				_sim_do_longhorn(sim, u, t)
				u.attacked = true
				return
			var dmg := u.eatk * _sim_mult(sim, u, t)
			# 远程被贴身：基础攻击压为1，buff 照常（与真实规则一致）
			if u.atk_type == DataRegistry.AttackType.RANGED and _sim_enemy_adjacent(sim, u, u.cell):
				var buff: int = maxi(u.eatk - u.atk, 0)
				dmg = 1 + buff
			# 圣盾：抵挡一次伤害
			var dealt := false   # 是否实际造成伤害（圣盾抵消则未造成）
			if not t.shield:
				if t.heavy:
					dmg += 1   # 重伤：受到的伤害+1
				t.hp = max(t.hp - dmg, 0)
				dealt = true
			else:
				t.shield = false
			# 锤头鲨：每当敌人受到一次伤害（非反击）-> 同阵营锤头鲨攻击力+1。
			# 模拟中累积 eatk，让 AI 倾向"先队友攻击累积 buff、锤头鲨最后攻击"。
			if dealt:
				for v in sim.units:
					if v.alive and v.fn == u.fn and v.hero_id == "hero_37":
						v.eatk += 1
			# 特技（沉默：非关键词技能失效）
			if not u.silenced:
				if u.hero_id == "hero_03":   # 毒蛇淑女：猛毒
					t.poisoned = true
				if u.hero_id == "hero_12":   # 巨剑：重伤
					t.heavy = true
				if u.hero_id == "hero_25":   # 战锤：攻降（近似=攻-1有效）+ 冰冻
					t.eatk = max(t.eatk - 1, 0)
					t.frozen = true
				if u.hero_id == "hero_34":   # 沉默术士：沉默
					t.silenced = true
			# 白游侠：远程命中后，对目标相邻的敌人溅射等量伤害并冰冻（模拟，无反击）
			if not u.silenced and u.hero_id == "hero_10":
				for k in sim.units.size():
					var w: SimUnit = sim.units[k]
					if w == null or w == t or not w.alive or w.fn != t.fn:
						continue
					if grid.distance(t.cell, w.cell) != 1:
						continue
					_sim_hit_no_counter(sim, w, u.eatk)
					if w.alive:
						w.frozen = true
			t.hurt_times += 1
			if t.hp <= 0:
				t.alive = false
				sim.occ.erase(t.cell)
			# 攻击后专属（真实顺序：先结算命中效果，再判定反击；目标死亡时部分技能仍对原位置生效）
			if not u.silenced:
				if u.hero_id == "hero_21":
					_sim_nova(sim, u, t)   # 超新星：目标相邻敌人击退/伤害
				if u.hero_id == "hero_18":
					_sim_pierce_line(sim, u, t.cell)   # 长剑：身后直线穿透
				if u.hero_id == "hero_27":
					if t.alive:
						_sim_swap_cells(sim, u, t)   # 暗域：换位
					else:
						_sim_occupy_dead_cell(sim, u, t)   # 目标死亡：占据其格
				if u.hero_id == "hero_41" and t.alive:
					_sim_pull_target(sim, u, t)   # 血锁：拉近
			_sim_counter_check(sim, u, t)
		u.attacked = true

# 移动后专属机制（敌方 AI 规划时模拟，与真实执行一致，减少"计划打不到/漏算"）：
#   烛火：灼烧相邻玩家（伤害=有效攻击，受圣盾/重伤规则影响，不触发反击）
#   雪拳：令相邻玩家冰冻
#   医护兵：治疗相邻最低血队友（回复=自身有效攻击）
#   涌电技师：攻击力+1，然后对射程内 HP 最低的玩家造成等同当前攻击的伤害
func _sim_on_move(sim: Sim, u: SimUnit) -> void:
	if u.hero_id == "hero_17":   # 烛火：相邻全伤
		for i in sim.units.size():
			var t: SimUnit = sim.units[i]
			if t.alive and t.fn != u.fn and grid.distance(u.cell, t.cell) == 1:
				_sim_hit_no_counter(sim, t, u.eatk)
	if u.hero_id == "hero_26":   # 雪拳：相邻冰冻
		for i in sim.units.size():
			var t: SimUnit = sim.units[i]
			if t.alive and t.fn != u.fn and grid.distance(u.cell, t.cell) == 1:
				t.frozen = true
	if u.hero_id == "hero_06":   # 医护兵：治疗相邻最低血队友
		var best_ally: SimUnit = null
		for i in sim.units.size():
			var v: SimUnit = sim.units[i]
			if not v.alive or v.fn != u.fn or v == u:
				continue
			if grid.distance(u.cell, v.cell) != 1:
				continue
			if v.hp >= v.max_hp:
				continue
			if best_ally == null or v.hp < best_ally.hp:
				best_ally = v
		if best_ally != null:
			best_ally.hp = mini(best_ally.hp + u.eatk, best_ally.max_hp)
	if u.hero_id == "hero_38":   # 涌电技师：攻击+1 后电最低血玩家（真实伤害，无视圣盾）
		u.eatk += 1
		var lowest: SimUnit = null
		for i in sim.units.size():
			var t: SimUnit = sim.units[i]
			if not t.alive or t.fn == u.fn:
				continue
			var d := grid.distance(u.cell, t.cell)
			var rng := u.atk_range
			if d < 1 or d > rng:
				continue
			if lowest == null or t.hp < lowest.hp:
				lowest = t
		if lowest != null:
			_sim_real_damage(sim, lowest, u.eatk)

# 无反击的直伤结算（圣盾抵消/重伤+1，与真实 take_damage 一致；不触发反击）
func _sim_hit_no_counter(sim: Sim, t: SimUnit, dmg_raw: int) -> void:
	var dmg := dmg_raw
	if t.shield:
		t.shield = false
		return
	if t.heavy:
		dmg += 1
	t.hp = max(t.hp - dmg, 0)
	if t.hp <= 0:
		t.alive = false
		sim.occ.erase(t.cell)

# 真实伤害（无视圣盾；圣盾保留、直接扣血，与 take_damage(…, true) 一致）
func _sim_real_damage(sim: Sim, t: SimUnit, dmg_raw: int) -> void:
	var dmg := dmg_raw
	if t.heavy:
		dmg += 1
	t.hp = max(t.hp - dmg, 0)
	if t.hp <= 0:
		t.alive = false
		sim.occ.erase(t.cell)

# 长角：自己结算基础伤害——先把目标沿"攻击者->目标"直线方向击退 1 格（能退则 1 倍伤害），
# 不能击退（界外/被占/被挡）则 2 倍伤害；击退后若仍贴身则目标可反击（与真实一致）。
func _sim_do_longhorn(sim: Sim, u: SimUnit, t: SimUnit) -> void:
	var hd := u.eatk * _sim_mult(sim, u, t)
	var kb := _sim_knockback_away(sim, t, u.cell)
	_sim_hit_no_counter(sim, t, hd * (1 if kb else 2))
	_sim_counter_check(sim, u, t)

# 把 target 沿"from_cell -> target"正后方推 1 格；成功返回 true（界外/被单位/障碍/墓碑挡则失败）
func _sim_knockback_away(sim: Sim, target: SimUnit, from_cell: Vector2i) -> bool:
	var fa := grid.axial_of(from_cell)
	var ta := grid.axial_of(target.cell)
	var step := ta - fa
	if step == Vector2i.ZERO:
		return false
	var best := grid.offset_of(ta + step)
	if not grid.in_bounds(best) or sim.occ.has(best) or sim.obstacles.has(best) or sim.graves.has(best):
		return false
	sim.occ.erase(target.cell)
	target.cell = best
	sim.occ[best] = target
	return true

# 超新星：把与目标相邻（同目标阵营）的单位推离目标 1 格；推不动则伤害之（伤害=自身攻击）
func _sim_nova(sim: Sim, u: SimUnit, target: SimUnit) -> void:
	for i in sim.units.size():
		var v: SimUnit = sim.units[i]
		if not v.alive or v.fn != target.fn or v == target:
			continue
		if grid.distance(target.cell, v.cell) != 1:
			continue
		if not _sim_knockback_away(sim, v, target.cell):
			_sim_hit_no_counter(sim, v, u.eatk)

# 长剑：目标身后（沿攻击方向）直线上的所有对立单位受伤（伤害=自身攻击，穿透不停止）
func _sim_pierce_line(sim: Sim, u: SimUnit, target_cell: Vector2i) -> void:
	var a := grid.axial_of(u.cell)
	var t := grid.axial_of(target_cell)
	var step := t - a
	if step == Vector2i.ZERO:
		return
	var cur := t + step
	for _i in 60:
		var off := grid.offset_of(cur)
		if not grid.in_bounds(off):
			break
		var idx := int(sim.occ.get(off, -1))
		if idx >= 0 and idx < sim.units.size():
			var other: SimUnit = sim.units[idx]
			if other.alive and other.fn != u.fn:
				_sim_hit_no_counter(sim, other, u.eatk)
		cur += step

# 暗域：与目标交换位置（occupancy 同步更新）
func _sim_swap_cells(sim: Sim, u: SimUnit, t: SimUnit) -> void:
	var ca := u.cell
	var cb := t.cell
	sim.occ.erase(ca)
	sim.occ.erase(cb)
	u.cell = cb
	t.cell = ca
	sim.occ[cb] = u
	sim.occ[ca] = t

# 暗域：目标死亡时占据其空出的格子（若该格仍空且界内）
func _sim_occupy_dead_cell(sim: Sim, u: SimUnit, t: SimUnit) -> void:
	var c := t.cell
	if not grid.in_bounds(c) or sim.occ.has(c):
		return
	sim.occ.erase(u.cell)
	u.cell = c
	sim.occ[c] = u

# 血锁：把目标拉到血锁面前的空格（贴身则不动），与真实 _pull_to 一致
func _sim_pull_target(sim: Sim, u: SimUnit, t: SimUnit) -> void:
	if grid.distance(u.cell, t.cell) <= 1:
		return
	var best: Vector2i = Vector2i(-99, -99)
	var best_d := 1 << 30
	for n in grid.neighbors(u.cell):
		if sim.occ.has(n) or sim.obstacles.has(n) or sim.graves.has(n):
			continue
		var d := grid.distance(n, t.cell)
		if d < best_d:
			best_d = d
			best = n
	if best.x == -99:
		return
	sim.occ.erase(t.cell)
	t.cell = best
	sim.occ[best] = t

# 反击判定（与真实规则一致）：普通单位每回合一次；复仇者无限反击；眩晕/已死不反。
# 距离=1（近战互搏 / 贴身）：照常反击。
# 距离>1（远程对射）：仅当双方都是远程、且被攻击方没有被敌人贴身时，才全额反击。
func _sim_counter_check(sim: Sim, u: SimUnit, t: SimUnit) -> void:
	if not t.alive or t.stunned:
		return
	var dist_c := grid.distance(u.cell, t.cell)
	if dist_c > 1:
		# 远程对射：攻击方与反击方都必须是远程；被攻击方被贴身则反击不了
		if u.atk_type != DataRegistry.AttackType.RANGED:
			return
		if t.atk_type != DataRegistry.AttackType.RANGED:
			return
		if _sim_enemy_adjacent(sim, t, t.cell):
			return   # 目标正被敌人贴身（压制中），无法远程反击
	else:
		if dist_c != 1:
			return
	if t.counter_used and t.hero_id != "hero_23":
		return
	t.counter_used = true
	var cdmg: int = t.eatk * (2 if t.hero_id == "hero_23" else 1)
	u.hp = max(u.hp - cdmg, 0)
	if u.hp <= 0:
		u.alive = false
		sim.occ.erase(u.cell)
	elif not u.shield:
		_sim_maybe_guard(sim, u)   # 圣光：己方受损后获盾（每回合一次）

# 圣光：己方(敌方)角色受伤后获得圣盾；每名圣光每回合限一次（模拟真实 aura_used 节奏）
func _sim_maybe_guard(sim: Sim, wounded: SimUnit) -> void:
	if wounded.shield or not wounded.alive:
		return
	for i in sim.units.size():
		var g: SimUnit = sim.units[i]
		if not g.alive or g.fn != wounded.fn or g.hero_id != "hero_22" or g.silenced or g.aura_used:
			continue
		g.aura_used = true
		wounded.shield = true
		return

# 特技伤害倍率（小阴影/赏金猎人/嬉皮死神/复仇者；沉默时失效）
func _sim_mult(sim: Sim, u: SimUnit, t: SimUnit) -> int:
	if u.silenced:
		return 1
	var mult := 1
	if u.hero_id == "hero_15" and _sim_lowest_hp(sim, t):
		mult = 2
	if u.hero_id == "hero_20" and u.atk_type == DataRegistry.AttackType.RANGED and t.skills.has(DataRegistry.Skill.TAUNT):
		mult = 2
	if u.hero_id == "hero_30" and _sim_isolated(sim, t, u):
		mult = 2
	if u.hero_id == "hero_23":
		mult = 2
	return mult

func _sim_lowest_hp(sim: Sim, t: SimUnit) -> bool:
	for u in sim.units:
		if u.alive and u.hp < t.hp:
			return false
	return true

func _sim_isolated(sim: Sim, target: SimUnit, attacker: SimUnit) -> bool:
	for u in sim.units:
		if u.alive and u != attacker and u.fn != target.fn and grid.distance(target.cell, u.cell) == 1:
			return false
	return true

# ---- 启发式评估（敌方视角，越高对敌方越有利）----
# 战术特征：
#   1. 单位价值（数值+状态权重）
#   2. 击杀价值：能"便宜"地换取敌人单位价值
#   3. 集火：本回合有多个敌方单位打了同一玩家单位 -> 加分
#   4. 威胁图：站位风险（这格下回合会被玩家打多少）
#   5. 胜负节奏：玩家接近 3 杀时补刀权重上升；自己接近死亡时保命权重上升
#   6. 走位定位：坦克前压、奶妈/后勤缩后、远程贴边缘、AOE 不扎堆
func _evaluate(sim: Sim) -> float:
	var score := 0.0
	var enemy_dead := 0
	var player_dead := 0
	for i in sim.units.size():
		var u: SimUnit = sim.units[i]
		if not u.alive:
			if u.fn == DataRegistry.Faction.ENEMY:
				# 骷髅兵是回合结束即消失的消耗品：死亡不计入敌方阵亡（不扣分）
				if u.hero_id == "summon_skeleton":
					pass
				elif _was_doomed(sim, u):
					# 逃不掉且必死的单位：无论是否攻击都会被玩家打死（死亡已注定），
					# 死亡不额外扣分——避免"怕被反死而不敢攻击"，鼓励死前攻击换血。
					pass
				else:
					enemy_dead += 1
			else:
				player_dead += 1
			continue
		var is_enemy := u.fn == DataRegistry.Faction.ENEMY
		var v := _unit_value(u)
		score += v if is_enemy else -v * 1.25   # 攻击方略微占优（1.25 让"打玩家"收益更明显，增强攻击欲望）
		# 状态持续价值：中毒/冰冻/眩晕/沉默对敌方有利（扣玩家分）
		if not is_enemy:
			if u.poisoned:
				score -= 4.0
			if u.frozen:
				score -= 1.5
			if u.stunned:
				score -= 2.0
			if u.silenced:
				score -= 1.5
	# 胜负节奏：杀到 3 个就赢 -> 击杀优先权随玩家阵亡数上升
	score += float(player_dead) * 3.0
	# 敌方单位死亡扣分（骷髅兵例外：其是回合结束即消失的消耗品，死亡不扣，已在上方排除）。
	# 残局求稳：自己每多死一个，再死的代价非线性上升——
	# 已经死 2 人（再死就输）时，AI 会避免"换命式"冒险，宁可保守保血线。
	score -= float(enemy_dead) * 2.0 * (1.0 + float(enemy_dead))
	# 走位定位：坦克前压 / 支援缩后 / 远程贴射程边缘 / 保持移动力价值
	score += _position_score(sim)
	# 战斗增援：敌方有人受伤/交战时，其余英雄逼近参战
	score += _siege_bonus(sim)
	# 威胁图：敌方格子的"来袭风险"（玩家单位能打该格多少伤害）
	score += _threat_map(sim)
	# 集火：同一玩家单位本回合被多个敌方打过 -> 加分（保证击杀；提高权重增强攻击欲望）
	for i in sim.units.size():
		var u: SimUnit = sim.units[i]
		if u.alive and u.fn != DataRegistry.Faction.ENEMY and u.hurt_times >= 2:
			score += 5.0 * (u.hurt_times - 1)
	score += _synergy_value(sim)
	# 黄金矿工拾取金矿的收益：站在金矿格上给予高额加分，引导 AI 走过去拾取
	for i in sim.units.size():
		var u: SimUnit = sim.units[i]
		if u.alive and u.fn == DataRegistry.Faction.ENEMY and u.hero_id == "hero_42" and sim.gold_cells.has(u.cell):
			score += 12.0
	# 搏命攻击激励：敌方单位本回合攻击过（即使之后被反死也保留 attacked 标记），且其所在格逃不掉。
	# 这种单位注定会被玩家揍/击杀，死前攻击换血是划算的；给一个足够大的激励，
	# 抵消"玩家反击/单位死亡"等扰动对攻击方案的压制。仅攻击过且逃不掉才加，避免激励错加到逃跑方案。
	for i in sim.units.size():
		var u2: SimUnit = sim.units[i]
		if u2.fn == DataRegistry.Faction.ENEMY and u2.attacked and _incoming_damage(sim, u2.cell, u2.fn) > 0.0:
			score += 6.0 + float(u2.eatk) * 1.5
	# 玩家反应前瞻：预测玩家下一回合"走位逼近后"的最大反制（集火/击杀哪个敌方），
	# 把它算作当前决策的长期代价——AI 会避开"只图眼前、给玩家留下破绽"的走法。
	score += _player_reaction_threat(sim)
	# 骗反击价值：贴身反击每回合一次——玩家某单位已反击过（次数用掉），
	# 说明我方主力后续贴身攻击更安全；杂鱼/骷髅先去"吃反击"也能带出该收益。
	for i in sim.units.size():
		var pc: SimUnit = sim.units[i]
		if pc.alive and pc.fn != DataRegistry.Faction.ENEMY and pc.counter_used:
			score += 0.5
	# 德鲁伊光环：回合结束时治疗全体队友——队伍有德鲁伊时，伤员是"会被救回来"的，
	# 保留残血单位/敢于交换的收益略升（避免 AI 把能被奶住的单位当废棋丢）。
	var has_druid := false
	for i in sim.units.size():
		var dd: SimUnit = sim.units[i]
		if dd.alive and dd.fn == DataRegistry.Faction.ENEMY and dd.hero_id == "hero_08" and not dd.silenced:
			has_druid = true
			break
	if has_druid:
		for i in sim.units.size():
			var vv: SimUnit = sim.units[i]
			if vv.alive and vv.fn == DataRegistry.Faction.ENEMY and vv.hp < vv.max_hp:
				score += 0.6
	return score

# 预测玩家下一回合的最佳反制威胁：玩家每个单位若能走位逼近后攻击/集火敌方，则该项为负（对敌方不利）。
# 用"玩家单位向最近敌方贴近一步后能造成的伤害"近似玩家会主动进攻，比静态威胁图更贴近实时判断。
func _player_reaction_threat(sim: Sim) -> float:
	var s := 0.0
	for i in sim.units.size():
		var p: SimUnit = sim.units[i]
		if not p.alive or p.fn == DataRegistry.Faction.ENEMY:
			continue
		if p.skills.has(DataRegistry.Skill.LOGISTICS):
			continue   # 后勤不主动输出
		var best := 0.0
		# 玩家当前格攻击 + 玩家向每个可达格逼近一格后能造成的最佳伤害
		var cands := [p.cell]
		var reach := _move_cells(sim, p)
		for c in reach.keys():
			if grid.distance(c, p.cell) <= 1:
				cands.append(c)
		for c in cands:
			for j in sim.units.size():
				var e: SimUnit = sim.units[j]
				if not e.alive or e.fn == p.fn:
					continue   # 只把敌方(非玩家方)作为可被反制的目标
				var d := grid.distance(c, e.cell)
				var rng := p.atk_range
				if p.atk_type == DataRegistry.AttackType.RANGED and _sim_enemy_adjacent(sim, p, c):
					rng = 1
				if d >= 1 and d <= rng:
					# 玩家武器击杀价值：能打死敌方给高权重，否则按伤害算
					var dmg := float(p.eatk)
					if e.hp <= dmg:
						best = maxf(best, float(e.eatk) * 1.5 + 2.0)   # 击杀敌方：大幅扣分
					else:
						best = maxf(best, dmg)
					if e.skills.has(DataRegistry.Skill.TAUNT):
						best = maxf(best, float(p.eatk) * 1.5 + 2.0)
		s -= best * 0.25   # 玩家反制作为敌方不利项，权重适中
	# 集火拔除威胁：若玩家本回合静态火力合计 ≥ 我方某单位剩余血量，
	# 则它下回合大概率被一波带走（即使本回合逃得开也可能被追死）——重罚站位/方案，除非本回合先解决火力点。
	for i in sim.units.size():
		var e: SimUnit = sim.units[i]
		if not e.alive or e.fn != DataRegistry.Faction.ENEMY or e.hp <= 0:
			continue
		var sumd := _incoming_damage(sim, e.cell, e.fn)
		if sumd >= float(e.hp):
			s -= float(_unit_value(e)) * 0.5
	return s

# 威胁图（敌方视角）：对每个敌方单位，若其当前位置被玩家单位强烈威胁（下回合会被打掉大量血/击杀），扣分。
# 同时 "预判换位价值"：站在玩家打不到/只能被低价值单位打到的格 -> 轻微加分（走位分与威胁图合并）。
func _threat_map(sim: Sim) -> float:
	var s := 0.0
	for i in sim.units.size():
		var u: SimUnit = sim.units[i]
		if not u.alive or u.fn != DataRegistry.Faction.ENEMY:
			continue
		var incoming := _incoming_damage(sim, u.cell, u.fn)
		if incoming <= 0.0:
			s += 1.0   # 安全格：轻微奖励
			continue
		# 逃不掉（无论怎么移动都会被玩家攻击到）时，不再因"露头"扣威胁分——
		# 站哪都会被揍，那不如留在能攻击的位置输出/换血，而不是无意义逃跑。
		if _min_escape_incoming(sim, u) > 0.0:
			continue
		# 威胁按"对本单位血量占比"折算；被高输出单位盯上则更危险。
		# 惩罚系数：3.0 适中偏低，鼓励进攻（过高会因怕暴露而不打，过低会送死）。
		var ratio := incoming / float(max(u.hp, 1))
		s -= ratio * 3.0
	return s

# 某格下回合会被对立阵营单位造成的合计伤害（近似：区域内每单位按有效攻击计算）
func _incoming_damage(sim: Sim, cell: Vector2i, fn: int) -> float:
	var total := 0.0
	for i in sim.units.size():
		var t: SimUnit = sim.units[i]
		if not t.alive or t.fn == fn:
			continue
		var d := grid.distance(cell, t.cell)
		var range_at := t.atk_range
		if t.atk_type == DataRegistry.AttackType.RANGED and _sim_enemy_adjacent(sim, t, t.cell):
			range_at = 1
		if d >= 1 and d <= range_at:
			var dmg := float(t.eatk)
			if t.atk_type == DataRegistry.AttackType.RANGED and _sim_enemy_adjacent(sim, t, t.cell):
				# 远程被贴身：基础压为1、buff保留
				var buff: int = maxi(t.eatk - t.atk, 0)
				dmg = 1.0 + float(buff)
			total += dmg
	return total

# 该敌方单位是否"被迫死战"：当前被玩家威胁（会被打），且无法移动到不受攻击的格（逃不掉）。

# 单位在所有可达格（含当前格）中被攻击的最小威胁值。
# 若 >0，说明它无论怎么走都会被玩家攻击到（逃不掉）。
func _min_escape_incoming(sim: Sim, u: SimUnit) -> float:
	var best := _incoming_damage(sim, u.cell, u.fn)   # 当前格威胁
	var reach := _move_cells(sim, u)
	for c in reach.keys():
		var inc := _incoming_damage(sim, c, u.fn)
		if inc < best:
			best = inc
	return best

# 该敌方单位是否"逃不掉且必死"：当前所在格会被玩家攻击，且所有可达格也都会被攻击。
# 允许对已死亡的单位调用（死亡后 cell 仍保留，用于判定其是否注定损失）。
func _was_doomed(sim: Sim, u: SimUnit) -> bool:
	if _incoming_damage(sim, u.cell, u.fn) <= 0.0:
		return false
	return _min_escape_incoming(sim, u) > 0.0

# 走位定位分（敌方视角）：
#   - 坦克（嘲讽）：越靠近敌方半场（y 越大）越好 → 顶住
#   - 后勤/支援（奶/光环）：缩在后方 → y 越小越好（保持安全距离）
#   - 远程：与最近玩家距离恰好=射程边缘最佳（贴脸降攻/被贴身=灾难）
#   - 每保留 1 格移动力 = 小价值（灵活走位）
func _position_score(sim: Sim) -> float:
	var s := 0.0
	for i in sim.units.size():
		var u: SimUnit = sim.units[i]
		if not u.alive or u.fn != DataRegistry.Faction.ENEMY:
			continue
		var row := float(u.cell.y)
		var max_y := float(grid.height - 1)
		if u.skills.has(DataRegistry.Skill.TAUNT):
			s += row / max_y * 4.0                     # 坦克前压
		elif u.skills.has(DataRegistry.Skill.LOGISTICS):
			s += (1.0 - row / max_y) * 3.0             # 后勤缩后
		if u.atk_type == DataRegistry.AttackType.RANGED:
			var near := _nearest_enemy_dist(sim, u)
			if near == 1:
				s -= 3.0                               # 被贴脸：远程大难
			elif near == u.atk_range:
				s += 1.0                               # 卡在射程边缘：安全又能打
		# 保留移动力 = 机动性价值
		if not u.moved:
			s += 0.5
	return s

# 与最近对立单位（此处即玩家单位）的距离；无则返回一个大数
func _nearest_enemy_dist(sim: Sim, u: SimUnit) -> int:
	var best := 1 << 30
	for i in sim.units.size():
		var t: SimUnit = sim.units[i]
		if t.alive and t.fn != u.fn:
			var d := grid.distance(u.cell, t.cell)
			if d < best:
				best = d
	return best

# 战斗增援激励：敌方有单位受伤（hp<max_hp）或与玩家相邻交战（战斗已爆发）时，
# 其余敌方非后勤英雄应加速逼近最近玩家参战，而不是各自观望/缩后。
# 给出"越靠近玩家越高"的加分（propulsion），驱动尚未交战的敌方单位推进参战。
func _siege_bonus(sim: Sim) -> float:
	var erupted := false
	var has_player := false
	# 先判断是否有玩家在场、是否有敌方受伤/交战（独立遍历，避免 break 影响另一判据）
	for i in sim.units.size():
		var u: SimUnit = sim.units[i]
		if not u.alive:
			continue
		if u.fn != DataRegistry.Faction.ENEMY:
			has_player = true
			continue
		if u.hp < u.max_hp:
			erupted = true
		for j in sim.units.size():
			var t: SimUnit = sim.units[j]
			if t.alive and t.fn != u.fn and grid.distance(u.cell, t.cell) == 1:
				erupted = true
				break
	if not erupted or not has_player:
		return 0.0
	var s := 0.0
	for i in sim.units.size():
		var u: SimUnit = sim.units[i]
		if not u.alive or u.fn != DataRegistry.Faction.ENEMY:
			continue
		if u.skills.has(DataRegistry.Skill.LOGISTICS):
			continue   # 后勤可在后方支援，不强行贴脸
		var near := _nearest_enemy_dist(sim, u)
		# 参战激励：能打到玩家(在射程内)给强加分，这正是"参与战斗"；
		# 超出攻击射程(打不到)则按超出格数**扣分**——明确惩罚"躲在角落游荡"，
		# 驱动远程/近战都压上到可攻击玩家/作战的位置。
		var over := maxi(near - u.atk_range, 0)
		s += 3.0 - float(over) * 0.8
	return s

# 机制协同：己方(敌方)协同双人在场加分；玩家协同在场视为威胁扣分
func _synergy_value(sim: Sim) -> float:
	var s := 0.0
	for i in sim.units.size():
		for j in range(i + 1, sim.units.size()):
			var a: SimUnit = sim.units[i]
			var b: SimUnit = sim.units[j]
			if not a.alive or not b.alive:
				continue
			# 机制协同（同方加成、对方视为威胁扣分）
			var bon := DataRegistry.synergy_bonus(a.hero_id, b.hero_id)
			if bon > 0.0:
				if a.fn == DataRegistry.Faction.ENEMY and b.fn == DataRegistry.Faction.ENEMY:
					s += bon * 0.6
				elif a.fn != DataRegistry.Faction.ENEMY and b.fn != DataRegistry.Faction.ENEMY:
					s -= bon * 0.6
			# 克制（来自角色列表"被克制/有效行为"列）：敌方克制玩家加分、玩家克制敌方扣分
			var cr := DataRegistry.counter_bonus(a.hero_id, b.hero_id)
			if cr > 0.0:
				if a.fn == DataRegistry.Faction.ENEMY and b.fn != DataRegistry.Faction.ENEMY:
					s += cr * 0.6   # 敌方 a 克制玩家 b
				elif b.fn == DataRegistry.Faction.ENEMY and a.fn != DataRegistry.Faction.ENEMY:
					s += cr * 0.6   # 敌方 b 克制玩家 a
				elif a.fn != DataRegistry.Faction.ENEMY and b.fn != DataRegistry.Faction.ENEMY:
					s -= cr * 0.6   # 玩家克制敌方（对敌方不利）
	return s

func _unit_value(u: SimUnit) -> float:
	# 骷髅兵是"回合结束即消失"的消耗品：价值为 0，死亡不亏——
	# AI 不会护着它（避免它往远离敌人的地方跑），而是拿它去换伤害/骚扰。
	if u.hero_id == "summon_skeleton":
		return 0.0
	var base := float(u.eatk) * 1.6 + float(u.hp) * 1.0
	if u.atk_type == DataRegistry.AttackType.RANGED:
		base += 2.0
	if u.skills.has(DataRegistry.Skill.TAUNT):
		base += 1.5
	if u.skills.has(DataRegistry.Skill.SWIFT):
		base += 0.5
	if u.skills.has(DataRegistry.Skill.LOGISTICS):
		base += 1.0   # 后勤光环类（奶/辅助）价值略高，AI 更想保它
	if u.stunned:
		base *= 0.4   # 眩晕：下回合几乎废
	if u.silenced:
		base *= 0.6   # 沉默：非关键词技能失效
	if u.shield:
		base += 2.0   # 圣盾：多一层免伤
	return base

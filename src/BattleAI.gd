class_name BattleAI
extends RefCounted
## 敌方强力 AI：对敌方"本回合全部可能操作"做搜索并打分，选出最优行动序列。
## 采用"按单位逐次扩展 + 波束保留最优"的搜索，评估函数综合考虑单位强度/击杀/走位。

# ---- 轻量模拟状态 ----
class SimUnit:
	var sim_index := -1      # 在 sim.units 里的下标（宿魂镜像等用）
	var fn := 0
	var hero_id := ""
	var cell := Vector2i.ZERO
	var hp := 10
	var hp0 := 10         # 本回合(快照)开始时的血量：用于评估"这一回合往同一目标叠了多少伤害"
	var max_hp := 10
	var atk := 4          # 基础攻击
	var eatk := 4         # 有效攻击（含buff/冲锋/太阳斩/麻痹减攻）
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
	var atk_use_buff := 0   # 攻击道具:下一次攻击+1
	var move_use_buff := 0  # 移动道具:下一次移动+1
	var heavy := false      # 重伤：受到的伤害+1
	var poisoned := false   # 猛毒（每回合开始1点，供评估用）
	var frozen := false     # 冰冻（移动-1）
	var hurt_times := 0     # 本回合被攻击次数（集火评估）
	var aura_used := false   # 本回合已触发过的光环/次数技（圣光护盾等每回合限一次）
	var ignore_los := false   # 坠炮手(hero_45)：攻击弹道无视障碍/单位/墓碑阻挡
	var immune_bombs := false  # 免疫炸弹（炸弹人自己踩雷不引爆）——由英雄脚本免疫钩子提供
	var can_pickup_gold := false  # 能拾取金矿（黄金矿工）——由英雄脚本 can_pickup_gold 钩子提供
	var possessed_by := -1   # 宿魂(hero_46)附体：被附体者记录"施加它的宿魂 sim_index"（-1=无；负墟免疫）

class Sim:
	var units: Array = []
	var occ: Dictionary = {}   # cell -> idx
	var gold_cells: Dictionary = {}   # cell -> true（黄金矿工可拾取的金矿）
	var graves: Dictionary = {}        # cell -> true（阵亡墓碑：阻挡移动，不可落停）
	var obstacles: Dictionary = {}     # cell -> true（障碍物：阻挡移动与攻击视线）
	var bombs: Dictionary = {}         # cell -> true（炸弹：经过不炸，落停引爆，非炸弹人应避免停在上面）
	var buff_cells: Dictionary = {}    # cell -> "atk"/"move"/"shield"/"heal"（普通增益道具，AI可评估收益去吃）
	var killed_players := 0   # 本回合内击杀的玩家单位数（评估给即时重奖，驱动"先收残血"顺序）
	var buff_taken := 0.0     # 本回合内拾取的增益道具价值合计（供评估加分，驱动 AI 主动去吃道具）
	var gold_taken := 0       # 本回合内吃到的金矿数（供评估加分，驱动黄金矿工去吃矿）
	var _neg_gained := {}     # 本动作已对负墟(hero_44)计过 +1 攻的单位 idx（负墟同帧多个负面只计一次）
	var _pos_mirror_depth := 0  # 宿魂附体镜像递归深度（防互相附体死循环，上限 8）
	# 路网距离缓存（见 BattleAI.walk_dist）：起点格 -> { 格: 步数 }。
	# 只取决于"静态地形"（障碍/墓碑），所以在同一地形下可以跨状态复用；
	# 克隆时**共享同一份引用**（父子局面地形相同），地形一变由 _apply 统一清空，不会读到脏值。
	var walk_cache: Dictionary = {}        # 地形当墙
	var walk_cache_pass: Dictionary = {}   # 忽略地形墙（渗透单位能穿障碍/墓碑）
	# 障碍"软代价"路网缓存：穿过一格障碍要额外付 (1 + 剩余耐久) 步。
	# 耐久的任何变化（掉 1 点/整块拆掉）都要清空这张表。
	var soft_cache: Dictionary = {}

	func clone() -> Sim:
		var c := Sim.new()
		c.gold_cells = gold_cells.duplicate()
		c.graves = graves.duplicate()
		c.obstacles = obstacles.duplicate()
		c.walk_cache = walk_cache            # 共享引用（不 duplicate：地形缓存是只读派生数据）
		c.walk_cache_pass = walk_cache_pass
		c.soft_cache = soft_cache
		c.bombs = bombs.duplicate()
		c.buff_cells = buff_cells.duplicate()
		c.killed_players = killed_players
		c.buff_taken = buff_taken
		c.gold_taken = gold_taken
		c._neg_gained = _neg_gained.duplicate()
		c._pos_mirror_depth = 0   # 镜像深度每次搜索步重置（防跨步累计误限）
		for i in units.size():
			var u: SimUnit = units[i]
			var cu := SimUnit.new()
			cu.sim_index = i
			cu.fn = u.fn
			cu.hero_id = u.hero_id
			cu.cell = u.cell
			cu.hp = u.hp
			cu.hp0 = u.hp0
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
			cu.atk_use_buff = u.atk_use_buff
			cu.move_use_buff = u.move_use_buff
			cu.heavy = u.heavy
			cu.poisoned = u.poisoned
			cu.frozen = u.frozen
			cu.hurt_times = u.hurt_times
			cu.aura_used = u.aura_used
			cu.ignore_los = u.ignore_los
			cu.immune_bombs = u.immune_bombs
			cu.can_pickup_gold = u.can_pickup_gold
			cu.possessed_by = u.possessed_by
			c.units.append(cu)
		c.occ = occ.duplicate()
		return c

var grid: HexGrid
var difficulty := 1   # 0 简单 / 1 普通 / 2 困难
var log_decisions := true   # 每次敌方行动后把"评分+决策理由"打到控制台（分析用）
## 单次搜索的思考时间上限（毫秒；<=0 = 不限）。
## 它是**上限**而不是固定等待：搜完就返回。给足预算让 beam 能铺开，逼近最优路线；
## 超时后剩下的单位改用贪心收尾（见 _greedy_finish），保证计划始终完整。
var time_budget_ms := 10000

const MAX_MOVE_OPTIONS := 16
# 黄金矿工：攻击力低于该值时视为"输出薄弱的成长型"，进一步提高吃矿优先级
const GOLD_LOW_ATK := 4
# 吃增益道具的评分权重：本回合拾取的道具按价值 × 该权重计入评估，驱动 AI 主动绕路去吃
const BUFF_TAKE_WEIGHT := 3.0
# 黄金矿工吃到 1 枚金矿的评分（永久 +1 攻 / +3 血上限，滚雪球）。
# 量级：普通一次攻击约 +2.5 分，击杀约 +25 起 —— 吃矿应明显优于"随手打一下"，但不该高于击杀。
const GOLD_TAKE_VALUE := 26.0
const GOLD_TAKE_VALUE_LOW := 34.0   # 攻击力 < GOLD_LOW_ATK 时更高（自身薄弱，成长更关键）
# 威胁评估：对方"需要先移动才能打到"的那一份伤害按此折算（移动要花掉一次走位机会）。
# 只看静态射程会把"离近战 2 格"误判成完全安全，只看可达又会让 AI 过度畏首畏尾。
const THREAT_MOVE_DISCOUNT := 0.7
# 击杀一个玩家单位的即时权重（"本回合击杀数 × 此值"）。
# 量级参考：普通一次攻击约 +2.5 分、击杀一个 10 血单位本身约值 +20（单位价值消失）——
# 击杀必须明显压过"随手多打一下"，否则 AI 会为了贪一点伤害放过必杀机会。
const KILL_BONUS := 35.0
# 集火推进权重：frac²×此值（frac = 本回合对同一目标已打掉的血 / 其回合开始血量）。
# 作用在**中间层评分**上，防止 beam 在"还没打出击杀"时就把合力线剪掉。
const FOCUS_FIRE_WEIGHT := 30.0
# 未参战时的"压上"拉力（每格）：单位这一回合够不到任何敌人时，
# 离"本回合可打击范围"每远 1 格就扣这么多分，逼它往战场压而不是在后方/出生点迂回。
# 只在够不到敌人时生效，进入打击范围后归零（后半程交给威胁图与伤害评估权衡）。
const ENGAGE_PULL_PER_CELL := 1.2

# ---- 路网距离（把障碍/墓碑当墙的真步数）----
# 走位评分不能只看直线：被墙隔开时"离敌人 2 格"可能实际要绕 6 格。
const INF_DIST := 1 << 29
# 障碍"挡路"惩罚：按实际绕路代价计分（而不是按障碍个数给固定小分），
# 于是"拆掉真正挡路的墙"能抬高局面分，拆不挡路的墙几乎不加分。
const OBSTACLE_DETOUR_WEIGHT := 4.0    # 每个"被墙挡出来的代价"的分值

func _init(g: HexGrid) -> void:
	grid = g

# 由 Battle 提供的数据构建模拟状态（units 顺序与 Battle.units 一致）
func build_state(unit_descs: Array, occ: Dictionary, gold_cells: Dictionary = {}, graves: Dictionary = {}, obstacles: Dictionary = {}, bombs: Dictionary = {}, buff_cells: Dictionary = {}) -> Sim:
	var s := Sim.new()
	s.gold_cells = gold_cells.duplicate()
	s.graves = graves.duplicate()
	s.obstacles = obstacles.duplicate()
	s.bombs = bombs.duplicate()
	s.buff_cells = buff_cells.duplicate()
	for d in unit_descs:
		var u := SimUnit.new()
		u.fn = d["fn"]
		u.hero_id = d["hero"]
		u.cell = d["cell"]
		u.hp = d["hp"]
		u.hp0 = u.hp   # 本回合起点血量：评估"本回合对同一目标累计伤害"的基准
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
		u.possessed_by = int(d.get("poss_by", -1))   # 已有宿魂附体绑定（真实残留）
		u.immune_bombs = bool(d.get("immune_bombs", false))   # 由英雄脚本免疫钩子提供（炸弹人=true）
		u.can_pickup_gold = bool(d.get("can_pickup_gold", false))   # 由英雄脚本金矿钩子提供（矿工=true）
		# 坠炮手：全场射程 + 无视阻挡（与真实规则一致）。
		# 被沉默/眩晕时"全场狙击"失效，射程退回 _effective_attack_range 的退化值 2
		# （否则 AI 会以为沉默中的坠炮手仍能全场狙击，白白畏手畏脚）。
		if u.hero_id == "hero_45":
			var mortar_ok := not u.silenced and not u.stunned
			u.atk_range = 99 if mortar_ok else 2
			u.ignore_los = true   # 沉默时 _in_range 里的 `ignore_los and not silenced` 自会拦住
		s.units.append(u)
	# 统一 occupancy 值语义为 SimUnit 对象：外部传入的是 "cell -> idx"，这里转成 "cell -> 对象"，
	# 与 _apply/_sim_swap_cells 等写入对象保持类型一致，避免部分状态 int、部分对象导致 cast 失败。
	var by_idx: Dictionary = {}
	for i in s.units.size():
		s.units[i].sim_index = i
		by_idx[i] = s.units[i]
	s.occ.clear()
	for k in occ.keys():
		var unit: SimUnit = by_idx.get(occ[k], null)
		if unit != null:
			s.occ[k] = unit
	return s

# ---- 主入口：返回最优行动序列 [{idx, action}] ----
func search(sim: Sim, enemy_faction: int) -> Array:
	var enemy_idxs: Array = []
	for i in sim.units.size():
		if sim.units[i].fn == enemy_faction and sim.units[i].alive:
			enemy_idxs.append(i)

	# 自由行动顺序：每层从"尚未行动"的敌人中任选一个扩展，让搜索能探索不同攻击顺序
	# （如先近战贴脸、后远程收割残血），选出整体利益最大的方案。用 done 记录各状态已行动单位。
	# 规模控制：deadline 决定"能搜多广"（见 time_budget_ms），beam 决定"每层保留多少条线"；
	# 边扩边归并（只留 top 2×beam）——不把所有子状态同时驻留，内存不随候选总量膨胀。
	var t0 := Time.get_ticks_msec()
	var deadline := (t0 + time_budget_ms) if time_budget_ms > 0 else 0
	var beam := _beam()
	var states: Array = [{ "sim": sim, "path": [], "score": _evaluate(sim), "done": {} }]
	while true:
		var pending := false
		var timed_out := false
		var merged: Array = []
		for st in states:
			# 找出该状态尚未行动的敌人
			var remaining: Array = []
			for i in enemy_idxs:
				if not (st["done"] as Dictionary).has(i):
					remaining.append(i)
			if remaining.size() == 0:
				merged.append(st)   # 已全部行动完，保留该完成态
				continue
			pending = true
			for idx in remaining:
				for a in _actions_for(st["sim"], idx):
					var s2: Sim = st["sim"].clone()
					_apply(s2, idx, a)
					var path: Array = (st["path"] as Array).duplicate()
					path.append({ "idx": idx, "action": a })
					var done2: Dictionary = (st["done"] as Dictionary).duplicate()
					done2[idx] = true
					merged.append({ "sim": s2, "path": path, "score": _evaluate(s2) + _jitter(), "done": done2 })
				# 归并：只留最好的若干条（被丢掉的状态分数更低，之后不可能再回到前 beam）
				if merged.size() > beam * 2:
					merged.sort_custom(func(a, b): return a["score"] > b["score"])
					merged = merged.slice(0, beam)
				if deadline > 0 and Time.get_ticks_msec() >= deadline:
					timed_out = true
					break
			if timed_out:
				break
		if not pending:
			break
		merged.sort_custom(func(a, b): return a["score"] > b["score"])
		states = merged.slice(0, beam)
		if timed_out:
			# 时间用尽：剩余单位改用贪心收尾（各自选一步内的最优动作），
			# 保证"每个敌人都行动"、计划完整，且不再花时间做 beam 扩展。
			# 只收尾最好的一小撮线（决赛只取 states[0]，尾部收益不值得再花时间）。
			states = _greedy_finish(states.slice(0, mini(states.size(), 24)), enemy_idxs)
			break
	if states.size() == 0:
		return []
	if log_decisions:
		_print_decision(sim, states[0])
	return states[0]["path"]

# 超时收尾：对每个候选状态，让尚未行动的敌人依次各自贪心选一步内的最优动作。
# 这样即使没搜完也返回"每个敌人都行动过"的完整计划，不会出现有人站着不动。
func _greedy_finish(states_in: Array, enemy_idxs: Array) -> Array:
	var out: Array = []
	for st in states_in:
		var cur: Dictionary = st
		for i in enemy_idxs:
			if (cur["done"] as Dictionary).has(i):
				continue
			var best_score := -INF
			var best_child: Dictionary = {}
			for a in _actions_for(cur["sim"], i):
				var s2: Sim = cur["sim"].clone()
				_apply(s2, i, a)
				var sc := _evaluate(s2)
				if sc > best_score:
					best_score = sc
					var path: Array = (cur["path"] as Array).duplicate()
					path.append({ "idx": i, "action": a })
					var done2: Dictionary = (cur["done"] as Dictionary).duplicate()
					done2[i] = true
					best_child = { "sim": s2, "path": path, "score": sc, "done": done2 }
			if best_child.is_empty():
				continue
			cur = best_child
		out.append(cur)
	out.sort_custom(func(a, b): return a["score"] > b["score"])
	return out

# 控制台输出本次敌方决策说明：总评分 + 每步行动的理由 + 每步得分变化（分析 AI 用）
func _print_decision(sim: Sim, chosen: Dictionary) -> void:
	var path: Array = chosen["path"]
	var txt := "\n===== 敌方AI 行动方案 · 总评分 %.1f · %d 步 =====" % [float(chosen["score"]), path.size()]
	# 回放克隆：按路径逐步执行，算出每一步给局面评分带来的增量 Δ
	var replay := sim.clone()
	var prev := _evaluate(replay)
	var start_score := prev
	for step in path:
		var idx := int(step["idx"])
		var u0: SimUnit = sim.units[idx]        # 名字用初始
		var ur: SimUnit = replay.units[idx]     # 数值用回放当前状态
		var a: Dictionary = step["action"]
		var line := " · %s" % u0.name
		var moved_to: Variant = a.get("move")
		if moved_to != null:
			var nc: Vector2i = moved_to
			var old_d := -1
			var new_d := -1
			var near: SimUnit = _nearest_player(replay, ur.cell)
			if near != null:
				old_d = grid.distance(ur.cell, near.cell)
			var near2: SimUnit = _nearest_player(replay, nc)
			if near2 != null:
				new_d = grid.distance(nc, near2.cell)
			line += " 移动 %s→%s" % [str(ur.cell), str(nc)]
			var reason: Array[String] = []
			if u0.can_pickup_gold and sim.gold_cells.has(nc):
				reason.append("捡金矿")
			if old_d >= 0 and new_d >= 0:
				if new_d < old_d:
					reason.append("贴近玩家(近%d格)" % new_d)
				else:
					reason.append("保持/拉距")
			var threat0 := _incoming_damage(replay, ur.cell, u0.fn)
			var threat1 := _incoming_damage(replay, nc, u0.fn)
			if threat1 < threat0 - 0.01:
				reason.append("避威胁(-%.0f伤)" % (threat0 - threat1))
			if reason.size() == 0:
				reason.append("走位")
			line += "(%s)" % "、".join(reason)
		else:
			line += " 原地"
		var atk := int(a.get("atk", -1))
		if atk >= 0 and atk < replay.units.size():
			var t: SimUnit = replay.units[atk]
			line += " → 攻击 %s" % t.name
			if t.hp <= ur.eatk:
				line += "（此击可击杀 hp%d≤攻%d）" % [t.hp, ur.eatk]
			else:
				line += "（造成%d伤，剩hp%d）" % [ur.eatk, maxi(t.hp - ur.eatk, 0)]
		else:
			line += " → 不攻击"
		_apply(replay, idx, a)
		var aft := _evaluate(replay)
		var delta := aft - prev
		prev = aft
		line += "  [本步 Δ%+.1f]" % delta
		txt += "\n" + line
	txt += "\n · 局面纯评分：%.1f → %.1f（决策总评含难度抖动=%.1f）" % [start_score, prev, float(chosen["score"])]
	txt += "\n===== 决策输出结束 ====="
	print(txt)

# 难度决定保留的状态数（困难=搜索更充分；波束越大越接近全局最优）。
# 现在有 deadline 兜底（搜得完就搜，搜不完就收窄），所以可以给足宽度去逼近最优路线。
func _beam() -> int:
	if difficulty >= 2:
		return 800
	if difficulty == 1:
		return 300
	return 50

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
	# 末日：移动后会伤害"所有 HP 小于末日"的角色（优先敌人）。
	# 若己方低血单位比对方更多，触发会净亏——本回合不应移动（不触发末日）。
	if u.hero_id == "hero_31":
		var own_low := 0
		var foe_low := 0
		for v in sim.units:
			if v == null or not v.alive:
				continue
			if v.fn == u.fn:
				if v.hp < u.hp:
					own_low += 1
			elif v.hp < u.hp:
				foe_low += 1
		if own_low > foe_low:
			return [{ "move": null, "atk": -1 }]
	# 可移动到的空格（不含自己被占格外的空位；若是原地则移动为空）
	var move_cells: Array = []
	if not u.moved:
		var reach := _move_cells(sim, u)
		var ranked: Array = []
		for c in reach.keys():
			var target := _nearest_player(sim, c)
			var d := INF_DIST
			if target != null:
				# 走位用**路网距离**：被墙隔开时"直线 2 格"可能实际要绕 6 格，
				# 用直线距离排序会让 AI 一头撞在墙上（看着离得近，其实过不去）。
				# 被墙完全隔死时退回"软代价"（肯砸墙的话有多远），否则整盘都是 INF、排序退化成随机。
				d = approach_dist(sim, c, target.cell, u.skills.has(DataRegistry.Skill.INFILTRATE))
			# 能拾金矿的单位：可达的金矿格优先列入候选（优先走过去拾取）
			if u.can_pickup_gold and sim.gold_cells.has(c):
				d = -1
			# 排序键：近战越近越好；远程以"正好站在射程边缘(通常2格)"为最优，
			# 贴脸(d=1)被贴脸降攻/挨打视为很差，避免远程总往敌人脸上贴。
			var dkey: float = float(d)
			if u.atk_type == DataRegistry.AttackType.RANGED and d >= 0:
				if d <= 1:
					dkey = 60.0
				elif d == u.atk_range:
					dkey = 1.0
				elif d >= INF_DIST:
					dkey = 999.0   # 路网不可达：排到最后（别把"被墙隔死的近格"当成好位置）
				else:
					dkey = 2.0 + absf(float(d - u.atk_range))
			# 走位质量：落点被玩家威胁越强，排序越靠后（同时保留近战贴脸候选）
			var threat := _incoming_damage(sim, c, u.fn)
			# 吃 buff 收益：落点有增益道具且对己有收益时显著加优先（但不算无脑,收益低/已有则不加)
			if sim.buff_cells.has(c):
				var bv := _buff_value(sim, u, String(sim.buff_cells[c]))
				if bv > 0.0:
					dkey -= bv * 3.0   # 权重提高：AI 更愿意绕路去吃有用的道具
			# 能拾金矿的单位（攻击力 < GOLD_LOW_ATK）：自身输出薄弱、吃矿成长收益更高，
			# 把可达矿格的优先度拉满——压过任何高价值增益道具格，保证"能吃到矿就一定先去吃"。
			if u.can_pickup_gold and u.eatk < GOLD_LOW_ATK and sim.gold_cells.has(c):
				dkey = -1000.0
			ranked.append({ "cell": c, "d": d, "dkey": dkey, "threat": threat })
		# 主排序：dkey（近战=距离、远程=射程边缘优先）；同键威胁小的格优先
		ranked.sort_custom(func(a, b):
			if a["dkey"] != b["dkey"]:
				return a["dkey"] < b["dkey"]
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
	# 落点去重：同一格只保留一份（否则同一行动会被枚举多次、白占 beam 名额，
	# 也让"能打到的落点"这类强制入选把候选表撑虚）
	var uniq_cells: Array = []
	var seen_cells := {}
	for c in move_cells:
		if seen_cells.has(c):
			continue
		seen_cells[c] = true
		uniq_cells.append(c)
	move_cells = uniq_cells

	# 后勤：不能主动攻击
	var can_attack := not u.skills.has(DataRegistry.Skill.LOGISTICS)
	# 攻击组合：从每个落点出发可攻击的目标
	for mc in move_cells:
		var targets := _valid_targets(sim, u, mc)
		if targets.size() > 0 and not u.attacked and can_attack:
			for t in targets:
				if _redhood_kill_unsafe(sim, u, t):
					continue   # 会点杀红帽且她身旁有己方单位：自爆13伤不划算，不打这一击
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
	# 攻击障碍（清障）候选：
	# 不再"只有当前格打不到人"才允许——障碍的价值由 _obstacle_detour 按**实际绕路代价**给分，
	# 该不该花一次攻击去拆墙交给评分决定（真正挡路的墙值得拆，不挡路的墙分很低自然不拆）。
	# ① 原地能打的障碍：任何情况下都是候选；
	# ② "移动→拆障碍"：只在"这一回合哪儿都打不到人"时才展开（否则候选会爆炸），
	#    典型场景：敌人被墙隔开、既走不到也打不到，那就走过去先把墙拆开。
	if can_attack and not u.attacked:
		var anywhere_hittable := false
		for mc in move_cells:
			if _valid_targets(sim, u, mc).size() > 0:
				anywhere_hittable = true
				break
		for oc in sim.obstacles.keys():
			var oc2: Vector2i = oc
			if grid.distance(u.cell, oc2) <= u.atk_range and not _sim_path_blocked(sim, u.cell, oc2):
				combos.append({ "move": null, "atk": -2, "atk_obs": oc2 })
		if not anywhere_hittable:
			# 每块障碍只安排**最近的一个落点**（move_cells 已按贴近目标排序），
			# 否则"每个落点 × 每块障碍"会让候选暴涨（实测搜索慢 3 倍）。
			var planned_obs := {}
			for mc in move_cells:
				if mc == u.cell:
					continue
				for oc in sim.obstacles.keys():
					var oc3: Vector2i = oc
					if planned_obs.has(oc3):
						continue
					if grid.distance(mc, oc3) <= u.atk_range and not _sim_path_blocked(sim, mc, oc3):
						planned_obs[oc3] = true
						combos.append({ "move": mc, "atk": -2, "atk_obs": oc3 })
	# 撤退克制：只有“移动且本步不打”的拉远走位才可能被去掉。
	# ① 当前格不疼（受威胁伤害 ≤1.5）→ 玩家下回合也碰不到/伤害可接受，站着占主动，没必要后撤；
	# ② 就算现在疼，退到“下回合移动力+射程也够不着敌人”的范围外 → 白白丢下一轮主动，也不退。
	var cur_inc := _incoming_damage(sim, u.cell, u.fn)
	var kept: Array = []
	for combo in combos:
		var mv: Variant = combo.get("move")
		if mv != null and int(combo.get("atk", -1)) == -1:
			var nc: Vector2i = mv
			var p0 := _nearest_player(sim, u.cell)
			var p1 := _nearest_player(sim, nc)
			var d0 := INF_DIST
			var d1 := INF_DIST
			if p0 != null:
				d0 = walk_dist(sim, u.cell, p0.cell)
			if p1 != null:
				d1 = walk_dist(sim, nc, p1.cell)
			if d1 > d0 and (cur_inc <= 3.0 or d1 > u.emove + u.atk_range):
				continue   # 丢弃这种“无谓后撤/退到够不着”
		kept.append(combo)
	combos = kept
	# 远程"不贴脸"闸门：若某个目标存在"不被贴身也能打到"的落点，就把"贴脸打它"的候选直接剔除。
	# 贴脸 = 基础攻击压 1 + 射程压 1 + 大概率被反击，几乎总是劣选；此前只能靠评分权衡，
	# 常常与"射程边缘输出"打成平手、再被抖动翻盘（表现为"远程贴上去打 1 点"）。
	if u.atk_type == DataRegistry.AttackType.RANGED and combos.size() > 1:
		var safe_targets := {}   # 目标 idx -> 存在"不贴脸也能打到它"的落点
		for combo in combos:
			var ti := int(combo.get("atk", -1))
			if ti < 0:
				continue
			var mc0: Vector2i = u.cell if combo.get("move") == null else combo["move"]
			if not _sim_enemy_adjacent(sim, u, mc0):
				safe_targets[ti] = true
		if safe_targets.size() > 0:
			var kept2: Array = []
			for combo in combos:
				var ti2 := int(combo.get("atk", -1))
				if ti2 >= 0 and safe_targets.has(ti2):
					var mc1: Vector2i = u.cell if combo.get("move") == null else combo["move"]
					if _sim_enemy_adjacent(sim, u, mc1):
						continue   # 有"不贴脸也能打到同一目标"的走法：不贴脸打
				kept2.append(combo)
			combos = kept2
	if combos.size() == 0:
		combos.append({ "move": null, "atk": -1 })
	return combos

# 红帽(hero_40)点杀风险：该击能把红帽打死（无圣盾且伤害≥其血），
# 而她死前会对"相邻的所有敌人"自爆13——若她身边有己方单位，点杀很亏，应避免。
# target 传入的是 sim.units 里的下标（生产路径），兼容直接传对象（测试）。
func _redhood_kill_unsafe(sim: Sim, u: SimUnit, target: Variant) -> bool:
	var t: SimUnit = sim.units[int(target)] if target is int else target
	if t == null or t.hero_id != "hero_40" or not t.alive:
		return false
	if t.shield or t.hp > u.eatk:
		return false   # 这一击打不死，没有自爆风险
	for v in sim.units:
		if v.alive and v.fn == u.fn and grid.distance(v.cell, t.cell) == 1:
			return true   # 有己方单位贴着她，点杀会把她炸到己方
	return false

func _move_cells(sim: Sim, u: SimUnit) -> Dictionary:	# 大骑士：沿 6 个轴向直线冲锋（与玩家一致，避免规划与执行轨迹不符）。
	# 途中被单位/墓碑/**障碍物**阻挡即停：障碍同样挡冲锋，防止 AI 计划穿墙。
	# 注：冲锋是移动方式，沉默不影响；只有"根本不能移动"（眩晕/荆棘）时 emove 已为 0
	if u.hero_id == "hero_24" and not u.stunned:
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
				if sim.bombs.has(off) and not u.immune_bombs:
					# 冲锋经过炸弹格可以穿过(不停不炸)，但不停在该格当终点
					ax += d
					continue
				out[off] = true
				ax += d
		return out
	var stop := sim.occ.duplicate()
	var blockers := sim.occ.duplicate()
	if u.skills.has(DataRegistry.Skill.INFILTRATE):
		# 渗透：可穿过双方单位+障碍/墓碑，只是不能停靠（stop 含全体单位/障碍/墓碑）
		blockers = {}
		for g in sim.graves.keys():
			stop[g] = true
		for o in sim.obstacles.keys():
			stop[o] = true
	else:
		for g in sim.graves.keys():
			stop[g] = true
			blockers[g] = true
		for o in sim.obstacles.keys():
			stop[o] = true   # 普通单位：障碍既不能穿过也不能停留
			blockers[o] = true
	var emv: int = u.emove + (1 if u.move_use_buff > 0 else 0)   # 移动道具:本次移动+1
	var res := grid.reachable(u.cell, emv, stop, blockers)
	# 炸弹：经过不炸但落停引爆 → 不免疫炸弹的单位不把炸弹格作为移动终点（免疫者可以站上去）
	if sim.bombs.size() > 0 and not u.immune_bombs:
		var safe := {}
		for c in res.keys():
			if not sim.bombs.has(c):
				safe[c] = true
		return safe
	return res

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
	# 障碍物阻挡攻击视线（与真实规则一致）；坠炮手(ignore_los)未沉默才无视阻挡
	if not (u.ignore_los and not u.silenced) and _sim_path_blocked(sim, from_cell, t.cell):
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
# 与真实规则一致：用六边形 cube 直线插值（修正旧轴向 round 插值在斜向偏格的问题）
func _sim_path_blocked(sim: Sim, from_cell: Vector2i, to_cell: Vector2i) -> bool:
	# 与真实规则一致：存在一条全程无阻挡的最短路径即可打；否则被挡。
	return grid.los_blocked(from_cell, to_cell, func(c):
		if sim.obstacles.has(c) or sim.graves.has(c):
			return true
		if sim.occ.has(c):
			var oi: int = (sim.occ[c] as SimUnit).sim_index
			if oi >= 0 and oi < sim.units.size():
				return true
		return false)

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

# 返回某落点可攻击的目标 idx（含嘲讽规则；坠炮手 ignore_los 且未被贴身时无视嘲讽）
func _valid_targets(sim: Sim, u: SimUnit, from_cell: Vector2i) -> Array:
	var taunts: Array = []
	# 坠炮手未沉默且"未被贴身"才无视嘲讽；被贴身时按普通远程处理、受嘲讽约束
	if not (u.ignore_los and not u.silenced and not _mortar_engaged(sim, u)):
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

# 坠炮手(hero_45)是否"被贴身"：有敌方单位紧邻其**当前格**。
# 被贴身时全场狙击的嘲讽豁免失效（与真实规则一致）。
func _mortar_engaged(sim: Sim, u: SimUnit) -> bool:
	for i in sim.units.size():
		var t: SimUnit = sim.units[i]
		if t != null and t.alive and t.fn != u.fn and grid.distance(u.cell, t.cell) == 1:
			return true
	return false

# ---- 路网距离（把障碍/墓碑当墙的 BFS 步数）----# 说明：只把**静态地形**（障碍/墓碑）当墙，不把单位当墙——单位会动，
# 按墙算会让"绕过一个暂时站着的队友"这种判断过于悲观。
# passing=true 时忽略地形墙（渗透单位能穿过障碍与墓碑）。
# 结果按"起点格"缓存在 sim.walk_cache 里：同一地形下反复问同一起点只算一次 BFS。
func walk_dist(sim: Sim, from: Vector2i, to: Vector2i, passing: bool = false) -> int:
	if from == to:
		return 0
	var cache: Dictionary = sim.walk_cache_pass if passing else sim.walk_cache
	var field: Dictionary = cache.get(from, {})
	if field.is_empty():
		field = _bfs_field(sim, from, passing)
		cache[from] = field
	return int(field.get(to, INF_DIST))

func _bfs_field(sim: Sim, from: Vector2i, ignore_terrain: bool) -> Dictionary:
	var dist: Dictionary = { from: 0 }
	var frontier: Array = [from]
	while frontier.size() > 0:
		var cur: Vector2i = frontier.pop_front()
		var d: int = dist[cur]
		for n in grid.neighbors(cur):
			if dist.has(n):
				continue
			if not ignore_terrain and (sim.obstacles.has(n) or sim.graves.has(n)):
				continue   # 地形墙：障碍/墓碑都过不去（渗透单位走 ignore_terrain 那份缓存）
			dist[n] = d + 1
			frontier.append(n)
	return dist

## 障碍"软代价"路网：把障碍当成"能硬穿但很贵"的墙——穿过一格障碍要额外付 (1 + 剩余耐久) 步，
## 墓碑按普通格算（打不掉，不参与"清障收益"）。棋盘只有 32 格，用线性扫描的 Dijkstra 足够快。
## 只用于**障碍价值评分**：走位/威胁/射程判定一律用硬规则 walk_dist（障碍根本过不去）。
func soft_route_cost(sim: Sim, from: Vector2i, to: Vector2i) -> int:
	var field: Dictionary = sim.soft_cache.get(from, {})
	if field.is_empty():
		field = _soft_field(sim, from)
		sim.soft_cache[from] = field
	return int(field.get(to, INF_DIST))

func _soft_field(sim: Sim, from: Vector2i) -> Dictionary:
	var dist: Dictionary = { from: 0 }
	var done: Dictionary = {}
	while true:
		var cur := Vector2i(-99, -99)
		var best := INF_DIST
		for c in dist.keys():
			if done.has(c):
				continue
			var dv: int = dist[c]
			if dv < best:
				best = dv
				cur = c
		if cur.x == -99:
			break
		done[cur] = true
		for n in grid.neighbors(cur):
			var step := 1
			if sim.obstacles.has(n):
				step = 1 + int(sim.obstacles[n])   # 硬穿一格障碍：按剩余耐久付费
			var nd: int = best + step
			if nd < int(dist.get(n, INF_DIST)):
				dist[n] = nd
	return dist

## 走位用的距离：优先硬路网；被墙完全隔死时退回软代价（"肯砸墙的话要走多远"），
## 免得整个棋盘所有格都是 INF、排序退化成随机（AI 会不知道该往哪走、也不知道该去砸哪面墙）。
func approach_dist(sim: Sim, from: Vector2i, to: Vector2i, passing: bool = false) -> int:
	var d := walk_dist(sim, from, to, passing)
	if d >= INF_DIST:
		d = soft_route_cost(sim, from, to)
	return d

func _nearest_player(sim: Sim, cell: Vector2i) -> SimUnit:
	# 选"路网意义上最近"的玩家（被墙隔开时，直线最近的未必是真正够得到的那个）
	var best: SimUnit = null
	var best_d := INF_DIST
	var best_straight := INF_DIST
	for i in sim.units.size():
		var t: SimUnit = sim.units[i]
		if t.alive and t.fn != DataRegistry.Faction.ENEMY:
			var sd := grid.distance(cell, t.cell)
			var wd := walk_dist(sim, cell, t.cell)
			if wd < best_d or (wd == best_d and sd < best_straight):
				best_d = wd
				best_straight = sd
				best = t
	return best

# 吃某 buff 对单位 u 的收益(0=无收益)。粗略但避免"见 buff 就吃":
# 攻击道具=下次攻击+1(常正);移动+1(常正);圣盾=无盾时正/有盾≈0;回血=受伤才正/满血0;金矿交黄金矿工(gold_snap单独)
func _buff_value(_sim: Sim, u: SimUnit, btype: String) -> float:
	match btype:
		"atk":
			return 1.0
		"move":
			return 0.7
		"shield":
			return 1.2 if not u.shield else 0.0
		"heal":
			return 1.2 if u.hp < u.max_hp else 0.0
	return 0.0

# ---- 应用一个行动到模拟状态 ----
func _apply(sim: Sim, idx: int, a: Dictionary) -> void:
	var u: SimUnit = sim.units[idx]
	if a.has("move") and a["move"] != null:
		var mc: Vector2i = a["move"]
		if mc != u.cell:
			var prev_cell: Vector2i = u.cell
			sim.occ.erase(u.cell)
			u.cell = mc
			sim.occ[mc] = u
			u.moved = true
			u.move_use_buff = 0   # 移动道具在本次移动中消耗
			# 移动后拾取普通增益道具(收益已在走位排序中权衡)
			if sim.buff_cells.has(mc):
				var bt: String = String(sim.buff_cells[mc])
				sim.buff_taken += _buff_value(sim, u, bt)   # 记录本回合吃到的道具价值（_evaluate 据此加分）
				sim.buff_cells.erase(mc)
				if bt == "atk":
					u.atk_use_buff += 1
				elif bt == "move":
					u.move_use_buff += 1
				elif bt == "shield":
					u.shield = true
				elif bt == "heal":
					u.hp += 3
			# 大骑士：冲锋移动距离加成攻击力（与真实规则一致，冲越远攻越高；被沉默则无加成）
			if u.hero_id == "hero_24" and not u.silenced and not u.stunned:
				u.eatk += grid.distance(prev_cell, mc)   # 沉默只吃不到这个加成，冲锋照常
			# 能拾金矿的单位踏上金矿格：拾取（数值镜像真实规则，见 hero_42_黄金矿工.gd 的 on_pickup_gold）
			if u.can_pickup_gold and sim.gold_cells.has(mc):
				sim.gold_cells.erase(mc)
				sim.gold_taken += 1
				u.atk += 1
				u.eatk += 1   # 有效攻击同步+1：本回合后续攻击即吃到这份成长
				u.max_hp += 3
				u.hp = mini(u.hp + 3, u.max_hp)
			# 移动后专属（与真实规则同触发点：移动落位后、攻击前；沉默时失效）
			if not u.silenced:
				_sim_on_move(sim, u)
	# 攻击障碍：耐久-1，打掉则移除
	if a.has("atk_obs"):
		u.attacked = true
		var oc2: Vector2i = a["atk_obs"]
		if sim.obstacles.has(oc2):
			var nd: int = int(sim.obstacles[oc2]) - 1
			sim.soft_cache.clear()        # 耐久变了：软代价路网整表作废（每敲一下都要重算）
			if nd <= 0:
				sim.obstacles.erase(oc2)
				sim.walk_cache.clear()    # 地形变了：硬路网距离缓存整表作废
				sim.walk_cache_pass.clear()
			else:
				sim.obstacles[oc2] = nd
		return
	if a.has("atk") and a["atk"] != null and int(a["atk"]) >= 0:
		var tidx := int(a["atk"])
		var t: SimUnit = sim.units[tidx]
		if t.alive:
			# 长角：自己结算基础伤害——击退则 1 倍、不能击退则 2 倍（与真实 handles_base_damage 一致）
			if u.hero_id == "hero_32" and not u.silenced:
				_sim_do_longhorn(sim, u, t)
				u.attacked = true
				return
			var ab := 0
			if u.atk_use_buff > 0:
				ab = u.atk_use_buff
				u.atk_use_buff = 0
			var dmg := (u.eatk + ab) * _sim_mult(sim, u, t)
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
			if dealt:
				_sim_possess_mirror(sim, t, dmg)   # 宿魂受伤：附体目标镜像（死亡清除前）
			# 锤头鲨（新规则）：**我方回合**内每当敌人受到一次伤害（非反击）-> 同阵营锤头鲨攻击力+1，
			# 加成撑到"对方回合结束"才消失。这里模拟的正是 AI 自己的回合，
			# 所以"只在我方回合"这条天然满足；模拟中累积 eatk，
			# 让 AI 倾向"先队友攻击累积 buff、锤头鲨最后攻击"。
			# （上一轮留下的加成已在快照的 eatk 里带上，见 BattleSnapshot.unit_desc。）
			if dealt:
				for v in sim.units:
					if v.alive and v.fn == u.fn and v.hero_id == "hero_37":
						v.eatk += 1
			# 特技（沉默：非关键词技能失效）——若目标为负墟则负面免疫（攻+1，见 helper）。
			# 注意 dealt：下面是"命中附加状态"的四个英雄（均有 applies_status_on_hit），
			# 真实规则里"带状态的攻击打盾"只挡伤害与状态（技能不挡），所以这里跟 dealt 一致。
			if not u.silenced and dealt:
				if u.hero_id == "hero_03" and not _sim_neg_immunity(sim, t):   # 毒蛇淑女：猛毒
					t.poisoned = true
				if u.hero_id == "hero_12" and not _sim_neg_immunity(sim, t):   # 巨剑：重伤
					t.heavy = true
				if u.hero_id == "hero_25":   # 战锤：麻痹（近似=攻-1有效）+ 冰冻
					if _sim_neg_immunity(sim, t):
						pass   # 负墟：两个负面一并免疫，攻只 +1（helper 去重）
					else:
						t.eatk = max(t.eatk - 1, 0)
						t.frozen = true
				if u.hero_id == "hero_34" and not _sim_neg_immunity(sim, t):   # 沉默术士：沉默
					t.silenced = true
			# 白游侠：远程命中后，先冰冻目标本体，再对目标相邻的敌人溅射等量伤害并冰冻。
			# 圣盾**只挡伤害/挡状态**，不挡技能：打盾时散射照常打到相邻敌人（与真实规则一致），
			# 只有"目标本体被冰冻"这条随 dealt 一起失效。
			if not u.silenced and u.hero_id == "hero_10":
				if dealt and t.alive and not _sim_neg_immunity(sim, t):
					t.frozen = true
				for k in sim.units.size():
					var w: SimUnit = sim.units[k]
					if w == null or w == t or not w.alive or w.fn != t.fn:
						continue
					if grid.distance(t.cell, w.cell) != 1:
						continue
					_sim_hit_no_counter(sim, w, u.eatk)
					if w.alive and not _sim_neg_immunity(sim, w):
						w.frozen = true
			if dealt:
				t.hurt_times += 1   # 被盾挡下不算"被打到"
			if t.hp <= 0:
				t.alive = false
				sim.occ.erase(t.cell)
				if t.fn != DataRegistry.Faction.ENEMY:
					sim.killed_players += 1   # 本回合击杀玩家单位：记入即时奖励（驱动"先收残血"）
			# 攻击后专属（真实顺序：先结算命中效果，再判定反击；目标死亡时部分技能仍对原位置生效）
			# 注意：圣盾只挡伤害，不挡技能——打盾时下面这些技能照常触发（与真实规则一致）。
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
				if u.hero_id == "hero_46" and t.alive and t.fn != u.fn:
					# 宿魂：令目标附体（负墟免疫则不绑定、攻+1）。后附覆盖先附（与真实一致）
					if not _sim_neg_immunity(sim, t):
						t.possessed_by = u.sim_index
			_sim_counter_check(sim, u, t)
		u.attacked = true

# 模拟端负墟(hero_44)：尝试对 t 施加一次负面（该次攻击带负面时才调用）。
# 若 t 是负墟 -> 免疫该负面并按"本次动作去重"给负墟 +1 攻；返回 true 表示应跳过原负面挂载。
func _sim_neg_immunity(sim: Sim, t: SimUnit) -> bool:
	if t == null or t.hero_id != "hero_44":
		return false
	if not sim._neg_gained.has(t.sim_index):
		sim._neg_gained[t.sim_index] = true
		t.eatk += 1   # 负墟被负面攻击命中：免疫负面、攻+1
	return true

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
				if not _sim_neg_immunity(sim, t):
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
	_sim_possess_mirror(sim, t, dmg)   # 宿魂受伤：附体目标镜像（在死亡清除前遍历）
	if t.hp <= 0:
		t.alive = false
		sim.occ.erase(t.cell)

# 真实伤害（无视圣盾；圣盾保留、直接扣血，与 take_damage(…, true) 一致）
func _sim_real_damage(sim: Sim, t: SimUnit, dmg_raw: int) -> void:
	var dmg := dmg_raw
	if t.heavy:
		dmg += 1
	t.hp = max(t.hp - dmg, 0)
	_sim_possess_mirror(sim, t, dmg)
	if t.hp <= 0:
		t.alive = false
		sim.occ.erase(t.cell)

# 宿魂附体镜像：宿魂（hero_46 施放者）受伤时，其附体的目标同受伤害（递归，防互相附体死循环）
func _sim_possess_mirror(sim: Sim, caster: SimUnit, dmg: int) -> void:
	if caster == null or caster.hero_id != "hero_46" or dmg <= 0:
		return
	if sim._pos_mirror_depth >= 8:
		return
	sim._pos_mirror_depth += 1
	var targets: Array = []
	for i in sim.units.size():
		var m: SimUnit = sim.units[i]
		if m != null and m.alive and m.possessed_by == caster.sim_index and m != caster:
			targets.append(m)
	for m in targets:
		if m == null or not m.alive:
			continue
		_sim_hit_no_counter(sim, m, dmg)   # 镜像目标受伤害（其自身圣盾/重伤同样生效，可再触发镜像）
	sim._pos_mirror_depth -= 1

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
		var holder = sim.occ.get(off, null)
		if holder is SimUnit:
			var other: SimUnit = holder
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

# 反击判定（与真实规则一致）：普通单位每回合一次；复仇者无限反击；眩晕/已死/**攻击力为 0** 不反。
# 距离=1（近战互搏 / 贴身）：照常反击。
# 距离>1（远程对射）：仅当双方都是远程、且被攻击方没有被敌人贴身时，才全额反击。
func _sim_counter_check(sim: Sim, u: SimUnit, t: SimUnit) -> void:
	if not t.alive or t.stunned:
		return
	if t.eatk <= 0:
		return   # 攻击力为 0（麻痹等）打不出反击：与真实规则一致（也不占用"每回合一次"名额）
	var dist_c := grid.distance(u.cell, t.cell)
	if dist_c > 1:
		# 远程对射：攻击方与反击方都必须是远程；被攻击方被贴身则反击不了
		if u.atk_type != DataRegistry.AttackType.RANGED:
			return
		if t.atk_type != DataRegistry.AttackType.RANGED:
			return
		if _sim_enemy_adjacent(sim, t, t.cell):
			return   # 目标正被敌人贴身（压制中），无法远程反击
		if dist_c > t.atk_range:
			return   # 攻击者不在自己射程内，够不到则无法反击（与真实一致）
	else:
		if dist_c != 1:
			return
	if t.counter_used and t.hero_id != "hero_23":
		return
	t.counter_used = true
	var cdmg: int = t.eatk * (2 if t.hero_id == "hero_23" else 1)
	u.hp = max(u.hp - cdmg, 0)
	_sim_possess_mirror(sim, u, cdmg)   # 被反击的宿魂受伤：附体目标镜像
	if u.hp <= 0:
		u.alive = false
		sim.occ.erase(u.cell)
	elif not u.shield:
		_sim_maybe_guard(sim, u)   # 圣光：己方受损后获盾（每回合一次）

# 圣光：**敌方回合**里己方角色受伤后获得圣盾；每名圣光每回合限一次（模拟真实 aura_used 节奏）。
# 本模拟固定是"敌方(AI 自己)回合"，所以只有**非行动方**（玩家一方）的伤者才会触发——
# 与真实规则一致：行动方自己回合里挨打不给盾。
func _sim_maybe_guard(sim: Sim, wounded: SimUnit) -> void:
	if wounded.shield or not wounded.alive:
		return
	if wounded.fn == DataRegistry.Faction.ENEMY:
		return   # 行动方(=AI 自己)的伤者发生在"己方回合"，不触发圣光
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
	# 与真实 Battle._is_isolated 一致：目标"孤立"= 1 格内**没有与其同阵营的队友**相邻。
	# 排除 attacker 与 target 自身；只看与 target 同阵营(fn==target.fn)的其他单位。
	for u in sim.units:
		if u.alive and u != target and u != attacker and u.fn == target.fn and grid.distance(target.cell, u.cell) == 1:
			return false   # 有同阵营队友相邻 → 目标不孤
	return true

# ---- 启发式评估（敌方视角，越高对敌方越有利）----
# 战术特征：
#   1. 单位价值（数值+状态权重）
#   2. 击杀价值：能"便宜"地换取敌人单位价值
#   3. 集火：本回合有多个敌方单位打了同一玩家单位 -> 加分
#   4. 威胁图：站位风险（这格下回合会被玩家打多少）
#   5. 胜负节奏：玩家接近 3 杀时补刀权重上升；自己接近死亡时保命权重上升
#   6. 走位定位：坦克前压、奶妈/后勤缩后、远程贴边缘、AOE 不扎堆
# 障碍"挡路"惩罚：对每个敌方单位，取它**直线最近**的玩家当目标，
## 比较"绕障碍的路网代价"与"直线距离"，多出来的部分就是墙挡出来的代价。
## 用**软代价路网**（soft_route_cost：穿过障碍要按剩余耐久付费）而不是"要么绕死要么不可达"，
## 这样每敲掉 1 点耐久，代价就降一点 —— 搜索才有"敲一下也变好一点"的梯度，
## 否则一次清障（耐久 3）在前两下拿不到任何分，波束搜索根本走不到"第三下拆掉"的那一步。
## 于是：拆挡路的墙 -> 局面分上升（且按耐久给部分分）；拆不挡路的墙 -> 代价为 0，不涨分。
## 开销：每个敌方单位只查一次（走 soft_route_cost 的缓存），对搜索速度影响很小。
func _obstacle_detour(sim: Sim) -> float:
	if sim.obstacles.is_empty():
		return 0.0   # 没墙就恒为 0（绝大多数局面走这条快路）
	var total := 0.0
	for i in sim.units.size():
		var u: SimUnit = sim.units[i]
		if not u.alive or u.fn != DataRegistry.Faction.ENEMY:
			continue
		var target: SimUnit = null
		var straight := INF_DIST
		for j in sim.units.size():
			var p: SimUnit = sim.units[j]
			if not p.alive or p.fn == u.fn:
				continue
			var sd := grid.distance(u.cell, p.cell)
			if sd < straight:
				straight = sd
				target = p
		if target == null or straight >= INF_DIST:
			continue
		var soft := soft_route_cost(sim, u.cell, target.cell)
		if soft < INF_DIST:
			total += maxf(float(soft - straight), 0.0)
	return total * OBSTACLE_DETOUR_WEIGHT

func _evaluate(sim: Sim) -> float:
	var score := 0.0
	# 障碍"挡路"惩罚：按**实际绕路代价**计分（不再按障碍个数给固定小分）。
	# 于是"拆掉真正挡路的墙"会明显抬高局面分，"拆掉不相干的墙"几乎没有收益 ——
	# 该不该花一次攻击去清障，交给评分决定（候选见 _actions_for 的清障分支）。
	score -= _obstacle_detour(sim)
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
	# 本回合内击杀玩家单位的即时重奖：让"能收残血就优先收"（把击杀前置），
	# 避免搜索偏好"把另一人打残"而放过眼前能收的残血。
	# 权重抬高：击杀是"3 人判负"节奏里最值钱的一步，宁可多给也不让 AI 放过必杀机会。
	score += float(sim.killed_players) * KILL_BONUS
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
	# 集火推进（凸性奖励）：对**同一目标**累计的本回合伤害越集中，越接近"合力必杀"。
	# 为什么单靠"伤害线性项 + 末端击杀奖励"不够：3+3 分摊给两人 与 6 全压一人 同分，
	# 于是 beam 在中间层就把"合击线"剪掉——最后谁也没死，表现为"三个人打不死一个、
	# 总有一两个转头去摸别人"。这里用 frac² 让"往同一目标叠伤害"在**中间层**就明显更值钱：
	# frac = 本回合已打掉的血 / 目标回合开始血量 → 0.3→0.09、0.6→0.36、1.0(打空)=1.0。
	for i in sim.units.size():
		var ft: SimUnit = sim.units[i]
		if ft == null or ft.fn == DataRegistry.Faction.ENEMY or ft.hp0 <= 0:
			continue   # 跳过己方、以及本回合开始前就已阵亡的单位（hp0=0）
		var dealt := ft.hp0 - maxi(ft.hp, 0)
		if dealt <= 0:
			continue
		var frac := float(dealt) / float(maxi(ft.hp0, 1))
		score += FOCUS_FIRE_WEIGHT * frac * frac
	# 集火：同一玩家单位本回合被多个敌方打过 -> 加分（保证击杀；提高权重增强攻击欲望）
	for i in sim.units.size():
		var u: SimUnit = sim.units[i]
		if u.alive and u.fn != DataRegistry.Faction.ENEMY and u.hurt_times >= 2:
			score += 5.0 * (u.hurt_times - 1)
	# 斩杀压力：玩家单位已残血(≤6)仍活着 → 补刀价值大，避免"打残一个就跑去打别人"
	for i in sim.units.size():
		var t: SimUnit = sim.units[i]
		if t != null and t.alive and t.fn != DataRegistry.Faction.ENEMY:
			if t.hp <= 3:
				score += 4.0   # 濒死：谁都能补死，别放过
			elif t.hp <= 6:
				score += 1.8   # 残血：再挨一两刀就死，优先收
	score += _synergy_value(sim)
	# 黄金矿工吃矿：金矿每枚=攻击+1、HP上限+3(永久成长),是滚雪球核心。评分分两种情形：
	#  1) 本回合真的吃到了矿(sim.gold_taken)：给重奖——此前"站在金矿格"的判定永不命中
	#     （拾取时金矿已被擦除），导致"移动去吃矿"在评分上没有任何收益，矿工就转头去打人了。
	#  2) 还没吃到：按"离最近金矿的距离"给梯度，让它在够不着时也会朝矿的方向靠。
	# 攻击力 < GOLD_LOW_ATK 的矿工自身输出薄弱，吃矿权重再提高一档。
	for i in sim.units.size():
		var u: SimUnit = sim.units[i]
		if u.alive and u.fn == DataRegistry.Faction.ENEMY and u.can_pickup_gold:
			var low_atk: bool = u.eatk < GOLD_LOW_ATK
			if sim.gold_taken > 0:
				score += float(sim.gold_taken) * (GOLD_TAKE_VALUE_LOW if low_atk else GOLD_TAKE_VALUE)
			elif sim.gold_cells.size() > 0:
				var gd := _nearest_gold_dist(sim, u)
				var base := 14.0 if low_atk else 8.0
				score += maxf(base - float(gd) * 2.0, 0.0)
	# 吃增益道具：本回合实际拾取的道具按价值计入（攻击/移动/圣盾/回血），
	# 让 AI 主动绕路去吃有用的道具，而不是"顺路才吃"。
	score += sim.buff_taken * BUFF_TAKE_WEIGHT
	# 走位候选(见 _actions_for):矿工把可达金矿格排最前(d=-1),这里额外把"能走到金矿"纳入评分,
	# 让"绕路去吃矿"也值得,而不只盯着当前占格。
	# 搏命攻击激励：敌方单位本回合攻击过（即使之后被反死也保留 attacked 标记），且**逃不掉且必死**。
	# 这种单位注定会被击杀，死前攻击换血是划算的；给一个足够大的激励，
	# 抵消"玩家反击/单位死亡"等扰动对攻击方案的压制。
	# 判据必须是 _was_doomed（"当前格致命 + 所有可达格也致命"）——
	# 早先这里只判了"当前格会被打到"，等于**只要停在会被打的位置就白拿 +6+1.5×攻击力**，
	# 反而奖励了"贴脸打 1 点"（远程最差走法）。
	for i in sim.units.size():
		var u2: SimUnit = sim.units[i]
		if u2.fn == DataRegistry.Faction.ENEMY and u2.attacked and _was_doomed(sim, u2):
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
		# 只有"逃不掉且必死"才不因露头扣威胁分（站哪都会被带走，那不如留在能输出的位置）。
		# 注意不能用"逃不掉会被攻击"当豁免：威胁已含玩家移动力后那几乎恒真，会把威胁图整个废掉。
		if _was_doomed(sim, u):
			continue
		# 威胁按"对本单位血量占比"折算；被高输出单位盯上则更危险。
		# 惩罚系数：3.0 适中偏低，鼓励进攻（过高会因怕暴露而不打，过低会送死）。
		var ratio := incoming / float(max(u.hp, 1))
		s -= ratio * 3.0
	return s

# 某格下回合会被对立阵营单位造成的合计伤害。
# 对方的**移动力也算进去**：玩家下回合可以"走两步再打"，只看静态射程会把
# "离近战 2 格"当成完全安全（AI 因此敢站在近战面前输出、残血也敢露头）。
# 需要移动才能打到的那一份按 THREAT_MOVE_DISCOUNT 折算（移动要花掉一次走位机会）。
func _incoming_damage(sim: Sim, cell: Vector2i, fn: int) -> float:
	var total := 0.0
	for i in sim.units.size():
		var t: SimUnit = sim.units[i]
		if not t.alive or t.fn == fn:
			continue
		# 威胁也用**路网距离**：被墙隔开的玩家这一回合其实够不到这格，不该算成威胁
		var d := walk_dist(sim, cell, t.cell)
		var range_at := t.atk_range
		if t.atk_type == DataRegistry.AttackType.RANGED and _sim_enemy_adjacent(sim, t, t.cell):
			range_at = 1
		if d < 1 or d > range_at + maxi(t.emove, 0):
			continue
		var dmg := float(t.eatk)
		if t.atk_type == DataRegistry.AttackType.RANGED and _sim_enemy_adjacent(sim, t, t.cell):
			# 远程被贴身：基础压为1、buff保留
			var buff: int = maxi(t.eatk - t.atk, 0)
			dmg = 1.0 + float(buff)
		if d > range_at:
			dmg *= THREAT_MOVE_DISCOUNT
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

# 该敌方单位是否"逃不掉且必死"：当前所在格会被打到**致死**，且所有可达格也都会被致死。
# 判据用"威胁 ≥ 当前血量"而不是"威胁 > 0"：后者在"威胁已含玩家移动力"之后几乎恒真
# （小棋盘上玩家基本够得到任何格），会让"死亡不扣分/威胁不扣分/搏命奖励"三条全线失控。
# 允许对已死亡的单位调用（死亡后 cell 仍保留，用于判定其是否注定损失）。
func _was_doomed(sim: Sim, u: SimUnit) -> bool:
	var lethal := maxf(float(u.hp), 1.0)
	if _incoming_damage(sim, u.cell, u.fn) < lethal:
		return false
	return _min_escape_incoming(sim, u) >= lethal

# 走位定位分（敌方视角）：
#   - 坦克（嘲讽）：越靠近敌方半场（y 越大）越好 → 顶住
#   - 后勤/支援（奶/光环）：缩在后方 → y 越小越好（保持安全距离）
#   - 远程：与最近玩家距离恰好=射程边缘最佳（贴脸降攻/被贴身=灾难）
#   - 未参战（本回合够不到任何敌人）：离可打击范围越远扣越多 → 压上参战，不在后方迂回
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
		elif _logistics_charges(u):
			s += row / max_y * 4.0                     # 烛火：虽为后勤但要冲前线（靠移动后相邻AOE输出）
		elif u.skills.has(DataRegistry.Skill.LOGISTICS):
			s += (1.0 - row / max_y) * 3.0             # 后勤缩后
		var near := _nearest_enemy_dist(sim, u)   # 到最近玩家的**路网**距离（场上无玩家 = 大数）
		if u.atk_type == DataRegistry.AttackType.RANGED:
			if near == 1:
				s -= 8.0                               # 被贴脸：远程大难（更重的惩罚，避免贴脸站位）
			elif near == u.atk_range:
				s += 2.0                               # 卡在射程边缘：安全又能打
		# 未参战压上（近战/远程/坦克/烛火都算；普通后勤另按上面的"缩后"项走）：
		# 这一回合**够不到**任何敌人时，离"可打击范围"越远扣越多 —— 逼它往战场压，
		# 而不是在后方/出生点原地迂回看戏（"队友已经打起来、它还在出生点晃悠"就是这条拉力太弱）。
		# 关键：拉力只在 near > 移动+射程 时生效，一旦进了"本回合就能打到"的范围就归零，
		# 后半程交给威胁图(_threat_map)与玩家反制前瞻(_player_reaction_threat)逐格权衡 ——
		# 所以整体是"在尽量不挨打的前提下尽量靠近"：既不缩在后排，也不会为了靠近而撞进集火圈。
		if not u.skills.has(DataRegistry.Skill.LOGISTICS) or _logistics_charges(u):
			var engage := u.emove + u.atk_range   # 本回合全力后可够到的距离
			if near > engage and near < INF_DIST:
				# 场上已无存活对手时 near=INF，此时不给拉力（否则杀最后一人会被判成天文负分）
				s -= float(near - engage) * ENGAGE_PULL_PER_CELL
		# 保留移动力 = 机动性价值
		if not u.moved:
			s += 0.5
	return s

# 黄金矿工到最近金矿的路网距离（无金矿返回一个大数）。用于给"朝矿靠拢"的评分梯度。
# 被墙隔死时退回软代价（"肯砸墙的话要走多远"），否则矿工对着被墙隔开的矿会完全没有方向。
func _nearest_gold_dist(sim: Sim, u: SimUnit) -> int:
	var best := INF_DIST
	var passing: bool = u.skills.has(DataRegistry.Skill.INFILTRATE)
	for c in sim.gold_cells.keys():
		var d := approach_dist(sim, u.cell, c, passing)
		if d < best:
			best = d
	return best

# 后勤里"需要冲前线"的特例：烛火(hero_17) 靠"移动后伤害相邻敌人"输出，
# 必须顶到敌人身边才有效——不能按普通后勤缩在后方。
func _logistics_charges(u: SimUnit) -> bool:
	return u.hero_id == "hero_17"

# 与最近对立单位（此处即玩家单位）的**路网距离**；无则返回一个大数。
# 用路网距离：被墙挡着时"直线 3 格"不等于"这一回合够得到"。
# 被墙完全隔死时退回软代价（"肯砸墙的话有多远"），这样"我够不到谁"的判断仍有远近之分。
func _nearest_enemy_dist(sim: Sim, u: SimUnit) -> int:
	var best := INF_DIST
	var passing: bool = u.skills.has(DataRegistry.Skill.INFILTRATE)
	for i in sim.units.size():
		var t: SimUnit = sim.units[i]
		if t.alive and t.fn != u.fn:
			var d := approach_dist(sim, u.cell, t.cell, passing)
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
		if u.skills.has(DataRegistry.Skill.LOGISTICS) and not _logistics_charges(u):
			continue   # 后勤可在后方支援，不强行贴脸（烛火例外：它必须冲前线）
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

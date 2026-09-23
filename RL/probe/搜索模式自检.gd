extends Node
## 【2026-09-23 一次性探针】搜索模式自检 —— 跑完即退，**不改任何生产代码**。
##
## 回答用户的问题：「为什么考虑的多了却变弱了？以前的路径也会考虑到，如果以前强，那他还是会按以前的路径」。
## **为什么这个反驳在动作空间上成立、但在搜索上不一定成立**：模式 2 的候选**确实**包含模式 0 的那些"移动+攻击"
##   一步组合（阶段 2 对还没挪位的单位就是直接给 `_actions_for()` 全套），但两阶段的**预算切法不同**：
##     阶段 1 用 `_layout_score()`（= `_evaluate(sim, end_of_turn=true)` 的**位置/威胁/队形分** + 一笔
##     "这一格够得到人就记它 eatk"的粗潜力）给**整队阵型**排序，只留 `_beam()` 条；随后**再只取前
##     `TWO_PHASE_LAYOUTS(8)` 套**进阶段 2，而阶段 2 每套的内层宽度只有 `max(4, beam/8)`。
##   ⇒ 模式 0 里"打分最高"的那套方案，如果它的**走位阵型**在阶段 1 的位置分里排到第 9 名开外，
##     模式 2 **永远看不到它**（选项还在，但在被评分之前就被剪掉了）。
##
## 本探针在**同一个局面**上分别跑 `SEARCH_MODE = 0` 与 `= 2`，然后用**同一个完整评分** `_evaluate(sim, true)`
## 量两套计划走完之后的终局分（两模式都在"全队行动完"的末态评分 ⇒ 可比）：
##   · 若 `score0 > score2` ⇒ **模式 2 确实自己把更好的方案丢了**（不是"选项变少"，是剪枝）；
##   · 再把两套计划各自的**走位阵型**单独拆出来，打上 `_layout_score()`（阶段 1 用的那把尺子）：
##       若 `proxy(布局0) < proxy(布局2)` ⇒ 阶段 1 的**位置分**把更好的阵型判没了（病灶 = 阶段 1 的尺子）；
##       若 `proxy(布局0) > proxy(布局2)` ⇒ 阶段 1 没看错，是**阶段 2 / 8 套漏斗**把它丢了。
##
## 用法：
##   & RL\train\跑Godot隔离.ps1 -Tag smprobe -TimeoutSec 900 -Args @('--headless','--path',(Get-Location).Path,'--scene','res://RL/probe/搜索模式自检.tscn')
## 输出：每行 `PROBE|...`（ASCII），末尾 `PROBE|END`。

const FORK := preload("res://RL/ai/AI_Battle.gd")
const WEIGHTS := "res://RL/weights/噩梦.json"
const SEARCH_CAP_MS := 30000   # 单次搜索上限（>=0；探针里给足但不无限，避免 §1.3 那个"空动作表死循环"把探针挂住）

var _grid: HexGrid
var _nm: Dictionary = {}

func _ready() -> void:
	_grid = HexGrid.new(5, 7, 48.0)
	_grid.top_cap_cols = [1, 3]
	_run.call_deferred()

func _run() -> void:
	_nm = _load_json(WEIGHTS)
	print("PROBE|CFG|fork=%s|nm_SEARCH_MODE=%s|cap_ms=%d" % [
		_sha("res://RL/ai/AI_Battle.gd"), str(_nm.get("SEARCH_MODE", 0)), SEARCH_CAP_MS])
	_case("D1_近战前排", ["hero_13", "hero_12", "hero_18"], ["hero_13", "hero_12", "hero_18"])
	_case("D2_远程多", ["hero_24", "hero_09", "hero_20"], ["hero_13", "hero_12", "hero_18"])
	_case("D4_堡垒古拉战锤", ["hero_48", "hero_14", "hero_25"], ["hero_13", "hero_09", "hero_11"])
	_case("D5_宿魂塔盾德鲁伊", ["hero_46", "hero_11", "hero_08"], ["hero_13", "hero_12", "hero_18"])
	_act_counts()
	_threat_block_case()
	_real_board_case()
	print("PROBE|END")
	get_tree().quit(0)

## 【2026-09-23 深夜⑦】按用户截图（`PICTURE/QQ20260923-131016.png`，视觉模型读出）原样复现真实局面：
##   敌方(AI)：小阴影(3,1) · 圣光(3,2)【嘲讽】 · 暗域(3,3)　我方(玩家)：白游侠(0,6) · 圣光(1,6) · 黄金矿工(2,6)
##   障碍：(2,2)(2,3)(2,4)(2,5) 四个木桶（x=2 那列 y2~y5 连成一堵墙）。
##   要回答两件事：① 矿工这一回合**实际能站到哪些格**（限步 BFS，单位/障碍都当墙）；
##   ② 圣光 / 暗域 的"挨打合计"各是多少（并打印旧判据用的 `walk_dist` 作对照）。
func _real_board_case() -> void:
	var my_cells := [Vector2i(3, 1), Vector2i(3, 2), Vector2i(3, 3)]
	var my_ids := ["hero_15", "hero_22", "hero_27"]
	var my_names := ["小阴影", "圣光", "暗域"]
	var foe_cells := [Vector2i(0, 6), Vector2i(1, 6), Vector2i(2, 6)]
	var foe_ids := ["hero_10", "hero_22", "hero_42"]
	var foe_names := ["白游侠", "圣光", "黄金矿工"]
	var descs: Array = []
	for i in 3:
		descs.append(_desc(DataRegistry.Faction.ENEMY, String(my_ids[i]), my_cells[i], String(my_names[i])))
	for i in 3:
		descs.append(_desc(DataRegistry.Faction.PLAYER, String(foe_ids[i]), foe_cells[i], String(foe_names[i])))
	var obs := { Vector2i(2, 2): true, Vector2i(2, 3): true, Vector2i(2, 4): true, Vector2i(2, 5): true }
	var built := _build(descs, obs)
	var ai = built["ai"]
	var sim = built["sim"]
	var miner = sim.units[5]                 # 黄金矿工（近战、攻2、疾行）
	var holy = sim.units[1]                  # 敌方圣光（嘲讽）
	var dark = sim.units[2]                  # 暗域
	# ① 矿工这一回合能站的格（限步 BFS：障碍/墓碑/被占格都当墙）
	var cells: Array = ai._sim_walk_cells(sim, miner.cell, maxi(miner.emove, 0))
	var near_holy := 0
	var near_dark := 0
	var txt := ""
	for c in cells:
		if _grid.distance(c, holy.cell) == 1:
			near_holy += 1
		if _grid.distance(c, dark.cell) == 1:
			near_dark += 1
		txt += str(c) + " "
	print("PROBE|REAL|矿工=%s emove=%d|能站%d格：%s" % [str(miner.cell), miner.emove, cells.size(), txt])
	print("PROBE|REAL|其中贴着圣光的=%d 格 ｜ 贴着暗域的=%d 格" % [near_holy, near_dark])
	print("PROBE|REAL|旧判据用到的路网距离（只看地形）：矿工→圣光格=%s ｜ 矿工→暗域格=%s（射程1+移动%d ⇒ 门槛%d）" % [
		str(ai.walk_dist(sim, miner.cell, holy.cell)), str(ai.walk_dist(sim, miner.cell, dark.cell)),
		miner.emove, 1 + miner.emove])
	var ih: Dictionary = {}
	var vh := float(ai._incoming_total_on(sim, holy, holy.cell, ih))
	var idk: Dictionary = {}
	var vd := float(ai._incoming_total_on(sim, dark, dark.cell, idk))
	print("PROBE|REAL|挨打合计：圣光=%.1f%s ｜ 暗域=%.1f%s" % [vh, str(ih.get("parts", [])), vd, str(idk.get("parts", []))])
	print("PROBE|REAL|圣光有嘲讽=%s（矿工从当前格能打到的目标=%d 个）" % [
		str(holy.skills.has(DataRegistry.Skill.TAUNT)), ai._valid_targets(sim, miner, miner.cell).size()])
	# 【2026-09-23 深夜⑦】嘲讽这一步单独说清：**只有在"够得到某个嘲讽者"时才被迫打它**（位置相关）。
	var taunt_lock: bool = not bool(ai._taunt_allows(sim, miner, dark, miner.cell))
	print("PROBE|REAL|嘲讽锁：矿工够得到嘲讽者(圣光)=%s ⇒ 被迫只能打圣光=%s（暗域因此被算成 %s）" % [
		str(ai._threat_can_hit(sim, miner, holy.cell)), str(taunt_lock), ("0" if taunt_lock else "正常")])

## 【2026-09-23 深夜⑤】复现用户那一例：「**能打到圣光的格子被暗域挡住了**，圣光却有伤害量」。
##   构造：把"圣光"周围除一格外的所有相邻格都用障碍封死；那一格先放我们自己的"暗域"（堵住），
##   再把它挪走（对照组）。敌人是**近战**矿工（射程 1、移动 3），放在离那一格两步的位置。
##   期望：堵住时 `_incoming_total_on(圣光)` = **0**；挪走后 = **2**（矿工攻击 2）。
func _threat_block_case() -> void:
	var holy := Vector2i(1, 0)                 # 顶帽格，邻格少 ⇒ 好封
	var nb := _grid.neighbors(holy)
	if nb.size() < 2:
		print("PROBE|THREAT|构造失败：顶帽格邻格不足")
		return
	var fire_cell: Vector2i = nb[0]            # 唯一留出的"能站过去打中"的格
	var obs := {}
	for i in range(1, nb.size()):
		obs[nb[i]] = true                       # 其余相邻格封成障碍
	# 敌人落点：离 fire_cell 恰好 2 格、不被占/不是障碍的第一个格
	var enemy_cell := Vector2i(-1, -1)
	for c in _grid.all_cells():
		if c == holy or c == fire_cell or obs.has(c):
			continue
		if _grid.distance(c, fire_cell) == 2:
			enemy_cell = c
			break
	if enemy_cell.x < 0:
		print("PROBE|THREAT|构造失败：找不到敌人落点")
		return
	var descs: Array = []
	descs.append(_desc(DataRegistry.Faction.ENEMY, "hero_22", holy, "圣光我"))
	descs.append(_desc(DataRegistry.Faction.ENEMY, "hero_27", fire_cell, "暗域我"))
	descs.append(_desc(DataRegistry.Faction.PLAYER, "hero_42", enemy_cell, "矿工敌"))
	var built := _build(descs, obs)
	var ai = built["ai"]
	var sim = built["sim"]
	var out_a: Dictionary = {}
	var blocked := float(ai._incoming_total_on(sim, sim.units[0], holy, out_a))
	# 对照组：把"暗域"挪到远处空格 ⇒ 那一格空出来，矿工就能站过去打中
	var away := Vector2i(-1, -1)
	for c in _grid.all_cells():
		if c == holy or c == fire_cell or c == enemy_cell or obs.has(c) or sim.occ.has(c):
			continue
		if _grid.distance(c, fire_cell) >= 4:
			away = c
			break
	ai._apply(sim, 1, { "move": away, "atk": -1 })
	var out_b: Dictionary = {}
	var free_hit := float(ai._incoming_total_on(sim, sim.units[0], holy, out_b))
	print("PROBE|THREAT|圣光=%s|那一格=%s|矿工=%s|堵住时=%.1f(来源=%s) ｜ 挪开后=%.1f(来源=%s)" % [
		str(holy), str(fire_cell), str(enemy_cell), blocked, str(out_a.get("parts", [])).replace("\n", ""),
		free_hit, str(out_b.get("parts", [])).replace("\n", "")])

## 【2026-09-23 深夜④】回答用户「一个近战走到谁都打不到的格子，下一步能搜到几个攻击动作」：
##   打印"移动前 / 移动后"两种状态的候选表条数，并把其中**带攻击**（`atk >= 0`）与**敲障碍**分开数。
func _act_counts() -> void:
	var descs: Array = []
	descs.append(_desc(DataRegistry.Faction.ENEMY, "hero_13", Vector2i(1, 1), "近战我"))
	descs.append(_desc(DataRegistry.Faction.ENEMY, "hero_12", Vector2i(2, 1), "队友我"))
	descs.append(_desc(DataRegistry.Faction.PLAYER, "hero_09", Vector2i(1, 5), "敌0"))
	descs.append(_desc(DataRegistry.Faction.PLAYER, "hero_20", Vector2i(3, 5), "敌1"))
	var obs := { Vector2i(3, 1): true }   # 落点 (4, 1) 旁边放一块障碍（测"敲障碍"那条）
	var built := _build(descs, obs)
	var ai = built["ai"]
	var sim = built["sim"]
	var before: Array = ai._actions_for(sim, 0)
	var nb: int = before.size()
	var na := 0
	for a in before:
		if int(a.get("atk", -1)) >= 0:
			na += 1
	# 把它挪到 (4,1)：离敌人 4 格 ⇒ 近战（射程 1）够不到任何人；此时它已经是"已移动"状态
	ai._apply(sim, 0, { "move": Vector2i(4, 1), "atk": -1 })
	var after: Array = ai._actions_for(sim, 0)
	var n2: int = after.size()
	var a2 := 0
	var ob := 0
	for a in after:
		if int(a.get("atk", -1)) >= 0:
			a2 += 1
		if a.has("atk_obs"):
			ob += 1
	print("PROBE|ACTS|移动前:候选=%d|其中攻击=%d ｜ 已移动到(4,1)后:候选=%d|其中攻击=%d|敲障碍=%d" % [nb, na, n2, a2, ob])

## 一个局面：我方（ENEMY，探针指挥方）三人在 y=1，玩家三人在 y=5
func _case(tag: String, my_ids: Array, foe_ids: Array) -> void:
	var descs: Array = []
	var xs := [1, 2, 3]
	for i in my_ids.size():
		descs.append(_desc(DataRegistry.Faction.ENEMY, String(my_ids[i]), Vector2i(xs[i], 1), "我%d" % i))
	for i in foe_ids.size():
		descs.append(_desc(DataRegistry.Faction.PLAYER, String(foe_ids[i]), Vector2i(xs[i], 5), "敌%d" % i))
	var built := _build(descs)
	var ai = built["ai"]
	var root = built["sim"]
	var r0 := _arm(ai, root, 0)
	var r2 := _arm(ai, root, 2)
	print("PROBE|CASE|%s|score0=%.2f|score2=%.2f|gap(0-2)=%+.2f|steps0=%d|steps2=%d|ms0=%d|ms2=%d" % [
		tag, r0["score"], r2["score"], r0["score"] - r2["score"], r0["steps"], r2["steps"], r0["ms"], r2["ms"]])
	print("PROBE|LAY|%s|proxy0=%.2f|proxy2=%.2f|full0=%.2f|full2=%.2f|same_plan=%s" % [
		tag, r0["proxy"], r2["proxy"], r0["lay_full"], r2["lay_full"], str(r0["plan"] == r2["plan"])])
	print("PROBE|PLAN0|%s|%s" % [tag, r0["plan_txt"]])
	print("PROBE|PLAN2|%s|%s" % [tag, r2["plan_txt"]])

## 跑一个模式：返回终局完整分 / 走位阵型分 / 计划
func _arm(ai, root, mode: int) -> Dictionary:
	ai.set_weights({ "SEARCH_MODE": mode })
	var s = root.clone()
	var t0 := Time.get_ticks_msec()
	var plan: Array = ai.search(s, DataRegistry.Faction.ENEMY)
	var ms := Time.get_ticks_msec() - t0
	# ① 完整计划走完的终局分（与现役同一个尺子：都按"全队行动完"评）
	var end = root.clone()
	for st in plan:
		ai._apply(end, int(st["idx"]), st["action"])
	var score := float(ai._evaluate(end, true))
	# ② 只把两套计划的"走位部分"拆出来（攻击整段不执行）⇒ 就是阶段 1 看到的那套阵型
	var lay = root.clone()
	for st in plan:
		var act: Dictionary = st["action"]
		var mv: Variant = act.get("move")
		if mv != null and Vector2i(mv) != root.units[int(st["idx"])].cell:
			ai._apply(lay, int(st["idx"]), { "move": mv, "atk": -1 })
	var proxy := float(ai._layout_score(lay))
	var lay_full := float(ai._evaluate(lay, true))
	var txt := ""
	for st in plan:
		var idx := int(st["idx"])
		var act2: Dictionary = st["action"]
		var mv2: Variant = act2.get("move")
		txt += "%s[%s->%s,atk=%d] " % [String(root.units[idx].name), str(root.units[idx].cell),
			("原地" if mv2 == null else str(mv2)), int(act2.get("atk", -1))]
	return { "score": score, "ms": ms, "steps": plan.size(), "proxy": proxy,
		"lay_full": lay_full, "plan": plan, "plan_txt": txt }

# ---------------------------------------------------------------- 工具
func _build(descs: Array, obs: Dictionary = {}) -> Dictionary:
	var occ := {}
	for i in descs.size():
		occ[descs[i]["cell"]] = i
	var ai = FORK.new(_grid)
	ai.difficulty = 3
	ai.log_decisions = false
	ai.time_budget_ms = SEARCH_CAP_MS
	ai.set_weights(_nm)
	var sim = ai.build_state(descs, occ, {}, {}, obs, {}, {})
	return { "sim": sim, "ai": ai }

func _desc(fn: int, hid: String, cell: Vector2i, nm: String) -> Dictionary:
	var hd = DataRegistry.heroes[hid]
	var emove := 2
	if (hd.skills as Array).has(DataRegistry.Skill.SWIFT):
		emove = 3
	return {
		"fn": fn, "hero": hid, "cell": cell, "hp": int(hd.max_hp), "max_hp": int(hd.max_hp),
		"atk": int(hd.atk), "eatk": int(hd.atk), "move": emove, "emove": emove,
		"atk_range": maxi(int(hd.attack_range), 1), "atk_type": int(hd.attack_type),
		"skills": (hd.skills as Array).duplicate(), "name": nm,
	}

func _load_json(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var d = JSON.parse_string(f.get_as_text())
	f.close()
	if d is Dictionary:
		return d
	return {}

func _sha(path: String) -> String:
	var c := FileAccess.get_file_as_bytes(path)
	var h := HashingContext.new()
	h.start(HashingContext.HASH_SHA256)
	h.update(c)
	return h.finish().hex_encode().substr(0, 12)

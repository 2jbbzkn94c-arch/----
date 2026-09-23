extends Node
## 【2026-09-22 一次性探针】㉒「隔断」自检 —— 跑完即退，**不改任何生产代码**。
##
## 查四件事（用户两条硬约束逐条验）：
##   ① **真能隔开**：走廊口站一个我方近战（且身边有队友）⇒ ㉒ 应该 > 0，且整局净收益要能盖过
##      ㉑「站在两人中间」那笔罚（`FORM_ESCAPE_W=2.0` × 2 = −4）；
##   ② **孤军不加分**：同一格、把队友挪走 ⇒ ㉒ 必须 = 0（"不能为了隔断把自己漏单"）；
##   ③ **远程不贴身**：远程站在走廊口（贴着两名玩家）⇒ ㉒ 必须 = 0；远程站在**不贴身**的位置 ⇒ 算墙
##      （用 `_split_wall_ok()` 逐个格直接打印，回答"远程到底算不算墙"）；
##   ④ **真跑一遍 `search()`**：SPLIT_W=0 与 2.0 两臂，看它会不会真的去卡走廊口。
##
## 棋盘（真实参数：5×7 + 顶帽 [1,3]）：y=5 一整排障碍、只留 (1,5) 一个口子 ⇒
##   玩家两名在 (1,6) 与 (1,4)，**唯一连接就是 (1,5)** —— 谁站那儿就把他们切开。
##
## 用法：
##   & RL\train\跑Godot隔离.ps1 -Tag split -TimeoutSec 600 -Args @('--headless','--path',(Get-Location).Path,'--scene','res://RL/probe/隔断自检.tscn')
## 输出：每行 `PROBE|...`（ASCII），末尾 `PROBE|END`。

const FORK := preload("res://RL/ai/AI_Battle.gd")
const WEIGHTS := "res://RL/weights/噩梦.json"

var _grid: HexGrid
var _nm: Dictionary = {}

func _ready() -> void:
	_grid = HexGrid.new(5, 7, 48.0)
	_grid.top_cap_cols = [1, 3]
	_run.call_deferred()

func _run() -> void:
	_nm = _load_json(WEIGHTS)
	print("PROBE|CFG|SPLIT_W=%s|fork=%s" % [str(_nm.get("SPLIT_W", 0.0)), _sha("res://RL/ai/AI_Battle.gd")])
	_case("S1_近战卡口_有队友", Vector2i(1, 5), true, "hero_40")
	_case("S2_近战卡口_孤军", Vector2i(1, 5), false, "hero_40")
	_case("S3_近战不卡口", Vector2i(0, 6), true, "hero_40")
	_case("S4_远程卡口_贴脸", Vector2i(1, 5), true, "hero_43")
	_gate_scan()
	_search_arm(0.0)
	_search_arm(2.0)
	print("PROBE|END")
	get_tree().quit(0)

## 一个局面：走廊口那个位置放谁/放不放队友，打印 ㉒ / ㉑ / ⑳ / 整局分
func _case(tag: String, blocker_cell: Vector2i, with_buddy: bool, blocker_hero: String) -> void:
	var descs: Array = []
	descs.append(_desc(DataRegistry.Faction.ENEMY, blocker_hero, blocker_cell, 13, 5, 2, "卡口我"))
	if with_buddy:
		descs.append(_desc(DataRegistry.Faction.ENEMY, "hero_26", Vector2i(2, 6), 26, 2, 3, "队友我"))
	# 玩家：塔盾 + 火枪手（塔盾"替相邻队友扛 1 点"正是被切开就会失效的那条机制）
	descs.append(_desc(DataRegistry.Faction.PLAYER, "hero_11", Vector2i(1, 6), 26, 2, 2, "塔盾敌"))
	descs.append(_desc(DataRegistry.Faction.PLAYER, "hero_09", Vector2i(1, 4), 20, 4, 2, "火枪手敌"))
	var built := _build(descs)
	var sim = built["sim"]
	var ai = built["ai"]
	var split := float(ai._split_parts(sim))
	var fp: Vector3 = ai._formation_parts(sim)   # Vector3：x=抱团罚基数 y=退路罚基数 z=㉓离队距离（2026-09-22 起）
	var ev := float(ai._evaluate(sim, true))
	var wall_ok := str(ai._split_wall_ok(sim, sim.units[0]))
	print("PROBE|%s|blocker=%s|hero=%s|buddy=%s|split=%.2f|split_pts=%+.2f|coh=%.1f|esc=%.1f|eot=%.2f|wall_ok=%s|terr_dist=%d" % [
		tag, str(blocker_cell), blocker_hero, str(with_buddy), split, split * float(ai.w_split),
		fp.x, fp.y, ev, wall_ok,
		int(ai.grid.distance(Vector2i(1, 6), Vector2i(1, 4)))])

## 远程"算不算墙"的逐格扫描（回答②③两条约束）
func _gate_scan() -> void:
	var descs: Array = []
	descs.append(_desc(DataRegistry.Faction.ENEMY, "hero_43", Vector2i(4, 6), 14, 1, 2, "远程我"))
	descs.append(_desc(DataRegistry.Faction.ENEMY, "hero_26", Vector2i(4, 5), 26, 2, 3, "队友我"))
	descs.append(_desc(DataRegistry.Faction.PLAYER, "hero_11", Vector2i(1, 6), 26, 2, 2, "塔盾敌"))
	descs.append(_desc(DataRegistry.Faction.PLAYER, "hero_09", Vector2i(1, 4), 20, 4, 2, "火枪手敌"))
	var built := _build(descs)
	var sim = built["sim"]
	var ai = built["ai"]
	var ru = sim.units[0]
	var txt := ""
	for cell in [Vector2i(1, 5), Vector2i(2, 6), Vector2i(4, 6), Vector2i(3, 4)]:
		var save: Vector2i = ru.cell
		ru.cell = cell
		sim.occ.erase(save)
		sim.occ[cell] = ru
		var adj := str(ai._sim_enemy_adjacent(sim, ru, cell))
		var ok := str(ai._split_wall_ok(sim, ru))
		txt += "%s[贴玩家=%s,算墙=%s] " % [str(cell), adj, ok]
		sim.occ.erase(cell)
		ru.cell = save
		sim.occ[save] = ru
	print("PROBE|gate|远程逐格：%s" % txt)

## 真跑一遍 search()：SPLIT_W 覆盖成 w，看它选不选"卡走廊口"那一手
func _search_arm(w: float) -> void:
	var descs: Array = []
	descs.append(_desc(DataRegistry.Faction.ENEMY, "hero_40", Vector2i(0, 6), 13, 5, 2, "红帽我"))
	descs.append(_desc(DataRegistry.Faction.ENEMY, "hero_26", Vector2i(2, 6), 26, 2, 3, "雪拳我"))
	descs.append(_desc(DataRegistry.Faction.PLAYER, "hero_11", Vector2i(1, 6), 26, 2, 2, "塔盾敌"))
	descs.append(_desc(DataRegistry.Faction.PLAYER, "hero_09", Vector2i(1, 4), 20, 4, 2, "火枪手敌"))
	var built := _build(descs)
	var ai = built["ai"]
	ai.set_weights({ "SPLIT_W": w })
	var sim = built["sim"]
	var plan: Array = ai.search(sim.clone(), DataRegistry.Faction.ENEMY)
	var txt := ""
	for st in plan:
		var idx := int(st["idx"])
		var act: Dictionary = st["action"]
		var mv: Variant = act.get("move")
		txt += "%s[%s->%s,atk=%d] " % [String(sim.units[idx].name), str(sim.units[idx].cell),
			("原地" if mv == null else str(mv)), int(act.get("atk", -1))]
	print("PROBE|search|SPLIT_W=%.1f|steps=%d|%s" % [w, plan.size(), txt])

# ---------------------------------------------------------------- 工具
func _build(descs: Array) -> Dictionary:
	var occ := {}
	for i in descs.size():
		occ[descs[i]["cell"]] = i
	# 走廊：y=5 一整排障碍，只留 (1,5)
	var obs := {}
	for x in 5:
		if x != 1:
			obs[Vector2i(x, 5)] = true
	var ai = FORK.new(_grid)
	ai.difficulty = 3
	ai.log_decisions = false
	ai.time_budget_ms = 20000   # ⚠️ 不用 0：那份"不限时"口径有已知死循环隐患（见 1_通用策略 §1.3）
	ai.set_weights(_nm)
	var sim = ai.build_state(descs, occ, {}, {}, obs, {}, {})
	return { "sim": sim, "ai": ai }

func _desc(fn: int, hid: String, cell: Vector2i, hp: int, atk: int, emove: int, nm: String) -> Dictionary:
	var hd = DataRegistry.heroes[hid]
	var d := {
		"fn": fn, "hero": hid, "cell": cell, "hp": hp, "max_hp": maxi(int(hd.max_hp), hp),
		"atk": atk, "eatk": atk, "move": emove, "emove": emove,
		"atk_range": maxi(int(hd.attack_range), 1), "atk_type": int(hd.attack_type),
		"skills": (hd.skills as Array).duplicate(), "name": nm,
	}
	if hid == "hero_42":
		d["can_pickup_gold"] = true
	return d

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

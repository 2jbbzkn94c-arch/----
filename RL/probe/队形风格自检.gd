extends Node
## 【2026-09-24 一次性探针】㉒隔断 / ㉓离队距离 的**风格读数**自检 —— 跑完即退，**不改任何生产代码**。
##
## 为什么需要它：§五 T16/T17 两行都写着「这两项要看**风格读数**（离散度 / 卡口次数 / 挨打量），
##   别只看胜率」—— 因为它们是**风格旋钮**（判死纪录里写明"再往加权和里加评分项天花板 ±5 分/局"）。
##   `难度体检 -Mode split / -Mode spread` 给的是 Δpts，本探针给的是**行为到底变没变**。
##
## 每个盘面按两组剂量各跑一遍 `search()`，把计划落到终局后量：
##   · `mean_gap`  = 我方非召唤单位**到最近队友的平均格距**（离散度；越小 = 越抱团）
##   · `isolated`  = 没有合格队友（`_has_buddy()`，含地形判定）的单位数
##   · `fp`        = `_formation_parts()` 的原始三元组（x = ⑳ 孤立份 · y = ㉑ 退路/被夹 · z = ㉓ 每格梯度合计）
##   · `split_raw` = `_split_parts()`（㉒ 原始量：我方身体把玩家切开的程度，含两条硬约束）
##   · `score`     = 终局完整评分（`_evaluate(sim, true)`）⇒ 顺手看"风格变了、质量有没有塌"
##   两组剂量：`FORM_SPREAD_CELL_W` = 0 / 3 / 6（`SPLIT_W` 保持 `噩梦.json` 的现役值）
##             `SPLIT_W`            = 0 / 2 / 4（`FORM_SPREAD_CELL_W` 保持现役值）
##
## 判读：剂量 ↑ ⇒ `mean_gap` ↓ / `isolated` ↓ / `fp.z` ↓ 说明㉓真把队伍收紧了；
##   `split_raw` ↑ 说明㉒真去卡口了。若全程不动 ⇒ 该旋钮在这类盘面上是死的。
##
## 用法：
##   & RL\train\跑Godot隔离.ps1 -Tag fstyle -TimeoutSec 900 -Args @('--headless','--path',(Get-Location).Path,'--scene','res://RL/probe/队形风格自检.tscn')
## 输出：每行 `PROBE|...`，末尾 `PROBE|END`。

const FORK := preload("res://RL/ai/AI_Battle.gd")
const WEIGHTS := "res://RL/weights/噩梦.json"
const SEARCH_CAP_MS := 30000
const ARMS_SPREAD := [0.0, 3.0, 6.0]   # 3.0 = 现役
const ARMS_SPLIT := [0.0, 2.0, 4.0]    # 2.0 = 现役

var _grid: HexGrid
var _nm: Dictionary = {}

func _ready() -> void:
	_grid = HexGrid.new(5, 7, 48.0)
	_grid.top_cap_cols = [1, 3]
	_run.call_deferred()

func _run() -> void:
	_nm = _load_json(WEIGHTS)
	print("PROBE|CFG|fork=%s|nm[FORM_SPREAD_CELL_W=%s,SPLIT_W=%s,FORM_COHESION_W=%s,FORM_ESCAPE_W=%s,FORM_MERGE_MODE=%s]|cap_ms=%d" % [
		_sha("res://RL/ai/AI_Battle.gd"), str(_nm.get("FORM_SPREAD_CELL_W", -1)), str(_nm.get("SPLIT_W", -1)),
		str(_nm.get("FORM_COHESION_W", -1)), str(_nm.get("FORM_ESCAPE_W", -1)), str(_nm.get("FORM_MERGE_MODE", -1)),
		SEARCH_CAP_MS])
	# F1 开阔推进：三只散开在 y=1，玩家在 y=4 两个
	_case("F1_开阔推进",
		[["hero_13", Vector2i(0, 1), "我A"], ["hero_12", Vector2i(2, 1), "我B"], ["hero_11", Vector2i(4, 1), "我C"]],
		[["hero_03", Vector2i(1, 4), "敌A"], ["hero_24", Vector2i(3, 4), "敌B"]], {})
	# F2 卡口在两人之间：**照 `RL/probe/隔断自检.gd` 的做法、不用障碍** —— 两个玩家相隔一格
	#   （塔盾 (1,6) / 火枪手 (1,4)，`grid.distance` = 2），谁站到中间的 (1,5) 谁就把他们切开。
	#   ⚠️ 第一版我拿「整排障碍」当卡口是错的：那样玩家是被**地形**隔开的，而 ㉒ 明确
	#     「地形本来就隔开的不付」⇒ `split_raw` 恒 0，那组读数作废。
	#   我方：近战 A 在 (1,3)（到 (1,5) 恰好 2 格 ⇒ emove 2 够得着）+ 队友在 (2,4)
	#     （`_split_wall_ok()` 要求「算墙者自己有队友在半径内」，否则孤军堵路一分不给）。
	_case("F2_卡口在两人之间",
		[["hero_13", Vector2i(1, 3), "卡口我"], ["hero_26", Vector2i(2, 4), "队友我"]],
		[["hero_11", Vector2i(1, 6), "塔盾敌"], ["hero_09", Vector2i(1, 4), "火枪手敌"]], {})
	# F3 远程多：两个远程 + 一个前排，看 ㉓ 会不会把远程硬拉进近战区
	_case("F3_远程多",
		[["hero_24", Vector2i(0, 1), "远A"], ["hero_09", Vector2i(2, 1), "远B"], ["hero_13", Vector2i(4, 1), "前排"]],
		[["hero_12", Vector2i(2, 4), "敌A"], ["hero_11", Vector2i(3, 4), "敌B"]], {})

	print("PROBE|END")
	get_tree().quit(0)

func _case(tag: String, my_rows: Array, foe_rows: Array, obs: Dictionary) -> void:
	var descs: Array = []
	for r in my_rows:
		descs.append(_desc(DataRegistry.Faction.ENEMY, String(r[0]), Vector2i(r[1]), String(r[2])))
	for r in foe_rows:
		descs.append(_desc(DataRegistry.Faction.PLAYER, String(r[0]), Vector2i(r[1]), String(r[2])))
	var built := _build(descs, obs)
	var ai = built["ai"]
	var root = built["sim"]
	for w in ARMS_SPREAD:
		_arm(ai, root, tag, "SPREAD", float(w), { "FORM_SPREAD_CELL_W": float(w) })
	for w in ARMS_SPLIT:
		_arm(ai, root, tag, "SPLIT", float(w), { "SPLIT_W": float(w) })

func _arm(ai, root, tag: String, key: String, w: float, theta: Dictionary) -> void:
	ai.set_weights(theta)
	var s = root.clone()
	var t0 := Time.get_ticks_msec()
	var plan: Array = ai.search(s, DataRegistry.Faction.ENEMY)
	var ms := Time.get_ticks_msec() - t0
	var end = root.clone()
	for st in plan:
		ai._apply(end, int(st["idx"]), st["action"])
	var fp: Vector3 = ai._formation_parts(end)
	var split_raw := float(ai._split_parts(end))
	# 离散度：我方非召唤单位到最近队友的平均格距 + 没有合格队友的个数
	var sum_gap := 0.0
	var n := 0
	var iso := 0
	for u in end.units:
		if u == null or not u.alive or u.fn != DataRegistry.Faction.ENEMY:
			continue
		if DataRegistry.summons.has(u.hero_id):
			continue
		var dmin := 999
		for m in end.units:
			if m == null or not m.alive or m == u or m.fn != u.fn:
				continue
			if DataRegistry.summons.has(m.hero_id):
				continue
			dmin = mini(dmin, _grid.distance(u.cell, m.cell))
		if dmin < 999:
			sum_gap += float(dmin)
		n += 1
		if not ai._has_buddy(end, u):
			iso += 1
	var mean_gap := (sum_gap / float(maxi(n - 1, 1))) if n > 1 else 0.0
	print("PROBE|ARM|%s|%s=%.1f|mean_gap=%.2f|isolated=%d|fp[%.1f,%.1f,%.1f]|split_raw=%.2f|score=%.2f|n_my=%d|steps=%d|ms=%d" % [
		tag, key, w, mean_gap, iso, fp.x, fp.y, fp.z, split_raw, float(ai._evaluate(end, true)), n, plan.size(), ms])
	print("PROBE|PLAN|%s|%s=%.1f|%s" % [tag, key, w, _plan_txt(root, plan)])

func _plan_txt(root, plan: Array) -> String:
	var txt := ""
	for st in plan:
		var idx := int(st["idx"])
		var act: Dictionary = st["action"]
		var mv: Variant = act.get("move")
		txt += "%s[->%s,atk=%d] " % [String(root.units[idx].name),
			("原地" if mv == null else str(mv)), int(act.get("atk", -1))]
	return txt

# ---------------------------------------------------------------- 工具（与其它探针同款）
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

extends Node
## 【2026-09-24 一次性探针】召唤物（骷髅兵）**阶段 1 候选集**的行为自检 —— 跑完即退，**不改生产代码**。
##
## 回答用户那两条口径：
##   ① 「用小骷髅去挡反击」这条路**不能**被弊掉（用户原话：「你这样就会把用小骷髅去挡反击的路径给弊了」）；
##   ② 「英雄不能把骷髅要用的攻击位盲抢了」（用户原话：「英雄先走位，其他不参与。那英雄不就会把敌人附近的格子给占了」）。
##
## 机制事实（三处铁证，见 `src/BattleAI.gd` 的 `const SUMMON_SLOT_ONLY`）：
##   `heroes/summon_骷髅兵.gd::on_turn_end()` = 「己方回合结束：干净淡出离场」（沉默也照散）；
##   `Battle._end_side()` 是**本方**回合结束的结算点；面板 = **攻 1 / 血 1 / 无特性**。
##   ⇒ 骷髅永远挡不住敌人、也永远不会被敌人主动打 ⇒ 它这辈子只有两件事值钱：
##     **本回合打出的伤害** + **替英雄吃下的反击**。
##
## 两个盘面（各跑 key = 0 / 1 两臂）：
##   **S1 反击吸收**：玩家一个「会反击、攻 5」的目标 A（血 2）；我方 = 骷髅(攻1血1) + 火枪手(攻4)。
##     正解 = **骷髅先打 A**（A 剩 1 血、骷髅吃下 5 点反击而死 ⇒ 我方的 ③血量账 不痛，因为骷髅身价 0），
##     随后火枪手补掉 A（A 已死 ⇒ **不吃反击**）。若火枪手先打，则 5 点反击**记在英雄头上**。
##     读数：`order` = 骷髅那一手排在英雄之前吗 · `skel_atk` = 骷髅打没打 A · `hero_counter` = 英雄是否吃了反击。
##   **S2 唯一攻击位**：A 周围只剩**一格**能打（其余用障碍围死），骷髅与英雄都能走到那一格。
##     正解 = **骷髅占那格**（它吃反击 = 白吃），英雄去别处/原地。
##     读数：`slot_holder` = 谁占了那格（0=骷髅 / 1=英雄 / -1=没人）· `score` 越高越好。
##
## 额外打一行 `LEDGER`：阶段 1 的**按单位类型分账**（`last_tp_p1_hero_kids` / `summon_kids` / 各自评分次数）
##   —— 这是"收窄候选到底省了多少"的直接读数（key=1 时召唤物那两笔应该明显变小）。
##
## ⚠️ **假通过守卫**：本探针依赖 fork 里新增的 `w_summon_slot_only`。若它是 null（= fork 还没重建），
##   两臂会跑出一模一样的结果 —— 那不是"没差别"，而是"键根本不存在"。所以遇到 null 直接打 `GUARD|FAIL` 并退 1。
##
## 用法：
##   & RL\train\跑Godot隔离.ps1 -Tag summon -TimeoutSec 900 -Args @('--headless','--path',(Get-Location).Path,'--scene','res://RL/probe/骷髅动作集自检.tscn')
## 输出：每行 `PROBE|...`，末尾 `PROBE|END`。

const FORK := preload("res://RL/ai/AI_Battle.gd")
const WEIGHTS := "res://RL/weights/噩梦.json"
const SEARCH_CAP_MS := 30000
const ARMS := [0, 1]        # 0 = 现役（枚举全部落点）· 1 = 召唤物只走"能打到人的格"

var _grid: HexGrid
var _nm: Dictionary = {}

func _ready() -> void:
	_grid = HexGrid.new(5, 7, 48.0)
	_grid.top_cap_cols = [1, 3]
	_run.call_deferred()

func _run() -> void:
	_nm = _load_json(WEIGHTS)
	print("PROBE|CFG|fork=%s|weights=%s|arms=%s|cap_ms=%d" % [
		_sha("res://RL/ai/AI_Battle.gd"), WEIGHTS, str(ARMS), SEARCH_CAP_MS])
	# 假通过守卫：fork 里没有这个键就直接失败（否则两臂结果相同会被误读成"改了没影响"）
	var probe_ai = FORK.new(_grid)
	var has_key: bool = probe_ai.get("w_summon_slot_only") != null
	print("PROBE|GUARD|has_w_summon_slot_only=%s" % str(has_key))
	probe_ai = null
	if not has_key:
		print("PROBE|GUARD|FAIL|fork 里还没有 w_summon_slot_only ⇒ 先跑 _rebuild_sync.ps1 重建两份副本再跑本探针")
		print("PROBE|END")
		get_tree().quit(1)
		return
	_case1_counter_soak()
	_case2_only_slot()
	print("PROBE|END")
	get_tree().quit(0)

# ---------------------------------------------------------------- S1：骷髅替英雄吃反击
func _case1_counter_soak() -> void:
	# AI = 骷髅(攻1血1) + 火枪手(攻4血20)；玩家 = 红帽 hero_40（攻5 · 血 13）但把它压到 2 血
	var descs: Array = []
	descs.append(_desc_summon(Vector2i(1, 1), "骷髅"))
	descs.append(_desc(DataRegistry.Faction.ENEMY, "hero_09", Vector2i(3, 1), "火枪手"))
	var a := _desc(DataRegistry.Faction.PLAYER, "hero_40", Vector2i(2, 2), "红帽A")
	a["hp"] = 2                       # 血 2：骷髅 1 伤 + 火枪手 4 伤 ⇒ 谁先谁后决定"吃不吃反击"
	descs.append(a)
	for w in ARMS:
		var built := _build(descs, w)
		var ai = built["ai"]
		var root = built["sim"]
		var t0 := Time.get_ticks_msec()
		var plan: Array = ai.search(root.clone(), DataRegistry.Faction.ENEMY)
		var ms := Time.get_ticks_msec() - t0
		# 计划顺序：骷髅(idx0) 的那一手排在第几位；它打了谁；英雄有没有吃到反击
		var skel_pos := -1; var skel_atk := -99; var hero_atk := -99; var step_i := 0
		for st in plan:
			var idx := int(st["idx"])
			var atk := int((st["action"] as Dictionary).get("atk", -1))
			if atk >= 0:
				if idx == 0:
					skel_pos = step_i
					skel_atk = atk
				elif idx == 1:
					hero_atk = atk
			step_i += 1
		# 英雄是否吃了反击：把计划落到终局，看 `sim` 里火枪手掉没掉血（A 攻 5 ⇒ 吃一下就 -5）
		var end = root.clone()
		for st in plan:
			ai._apply(end, int(st["idx"]), st["action"])
		var hero_hp: int = int(end.units[1].hp)
		var skel_alive: bool = bool(end.units[0].alive)
		var bd: Dictionary = ai._eval_breakdown(end, true)
		print("PROBE|S1|w=%d|skel_pos=%d|skel_atk=%d|hero_atk=%d|hero_hp=%d(起始%d)|skel_alive=%s|score=%.2f|bd3=%.2f|steps=%d|ms=%d" % [
			int(w), skel_pos, skel_atk, hero_atk, hero_hp, int(root.units[1].hp), str(skel_alive),
			float(ai._evaluate(end, true)), float(bd.get("③血量账", 0.0)), plan.size(), ms])
		print("PROBE|S1PLAN|w=%d|%s" % [int(w), _plan_txt(root, plan)])
		print("PROBE|LEDGER|S1|w=%d|hero_kids=%d|hero_evals=%d|summon_kids=%d|summon_evals=%d|p1_evals=%d|p1_dups=%d" % [
			int(w), int(ai.last_tp_p1_hero_kids), int(ai.last_tp_p1_hero_evals),
			int(ai.last_tp_p1_summon_kids), int(ai.last_tp_p1_summon_evals),
			int(ai.last_tp_p1_evals), int(ai.last_tp_p1_dups)])

# ---------------------------------------------------------------- S2：唯一攻击位（英雄不能盲抢）
func _case2_only_slot() -> void:
	# A 在 (2,2)，把它的 6 个邻格里除 (1,2) 之外**全部用障碍堵死** ⇒ 只有 (1,2) 能打到它。
	# 骷髅与火枪手都能走到 (1,2) ⇒ "谁占那格"由搜索自己决定（正解 = 骷髅，因为它吃反击不心疼）。
	var descs: Array = []
	descs.append(_desc_summon(Vector2i(1, 4), "骷髅"))
	descs.append(_desc(DataRegistry.Faction.ENEMY, "hero_09", Vector2i(3, 4), "火枪手"))
	var a := _desc(DataRegistry.Faction.PLAYER, "hero_40", Vector2i(2, 2), "红帽A")
	a["hp"] = 2
	descs.append(a)
	var obs := {}
	for n in _grid.neighbors(Vector2i(2, 2)):
		if n != Vector2i(1, 2):
			obs[n] = 3        # 障碍耐久 3（只做"堵路/挡视线"，不打算被打掉）
	for w in ARMS:
		var built := _build(descs, w, obs)
		var ai = built["ai"]
		var root = built["sim"]
		var t0 := Time.get_ticks_msec()
		var plan: Array = ai.search(root.clone(), DataRegistry.Faction.ENEMY)
		var ms := Time.get_ticks_msec() - t0
		var end = root.clone()
		var holder := -1
		for st in plan:
			ai._apply(end, int(st["idx"]), st["action"])
		for i in end.units.size():
			var u = end.units[i]
			if u != null and u.alive and u.cell == Vector2i(1, 2):
				holder = i
		print("PROBE|S2|w=%d|slot_holder=%d(0=骷髅 1=火枪手)|score=%.2f|steps=%d|ms=%d" % [
			int(w), holder, float(ai._evaluate(end, true)), plan.size(), ms])
		print("PROBE|S2PLAN|w=%d|%s" % [int(w), _plan_txt(root, plan)])
		print("PROBE|LEDGER|S2|w=%d|hero_kids=%d|hero_evals=%d|summon_kids=%d|summon_evals=%d|p1_evals=%d|p1_dups=%d" % [
			int(w), int(ai.last_tp_p1_hero_kids), int(ai.last_tp_p1_hero_evals),
			int(ai.last_tp_p1_summon_kids), int(ai.last_tp_p1_summon_evals),
			int(ai.last_tp_p1_evals), int(ai.last_tp_p1_dups)])

# ---------------------------------------------------------------- 工具（与其它探针同款）
func _plan_txt(root, plan: Array) -> String:
	var txt := ""
	for st in plan:
		var idx := int(st["idx"])
		var act: Dictionary = st["action"]
		var mv: Variant = act.get("move")
		var atk := int(act.get("atk", -1))
		var who := "不打"
		if atk >= 0 and atk < root.units.size():
			who = String(root.units[atk].name)
		txt += "%s[->%s,atk=%s] " % [String(root.units[idx].name),
			("原地" if mv == null else str(mv)), who]
	return txt

func _build(descs: Array, slot_only: int, obs: Dictionary = {}) -> Dictionary:
	var occ := {}
	for i in descs.size():
		occ[descs[i]["cell"]] = i
	var ai = FORK.new(_grid)
	ai.difficulty = 3
	ai.log_decisions = false
	ai.time_budget_ms = SEARCH_CAP_MS
	ai.set_weights(_nm)
	ai.set_weights({ "SUMMON_SLOT_ONLY": int(slot_only) })
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

## 召唤物描述（骷髅兵在 `DataRegistry.summons` 里，不在 `heroes` 里）
func _desc_summon(cell: Vector2i, nm: String) -> Dictionary:
	var hd = DataRegistry.get_summon("summon_skeleton")
	return {
		"fn": DataRegistry.Faction.ENEMY, "hero": "summon_skeleton", "cell": cell,
		"hp": int(hd.max_hp), "max_hp": int(hd.max_hp), "atk": int(hd.atk), "eatk": int(hd.atk),
		"move": 2, "emove": 2, "atk_range": maxi(int(hd.attack_range), 1),
		"atk_type": int(hd.attack_type), "skills": (hd.skills as Array).duplicate(), "name": nm,
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

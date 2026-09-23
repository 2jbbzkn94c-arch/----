extends Node
## 【2026-09-23 一次性探针】锤头鲨不前进自检 —— 跑完即退，**不改任何生产代码**。
##
## 回答用户的问题：「为什么 AI 的锤头鲨不往前走、打玩家 5 伤？」
##   盘面按用户截图 `image.png`（第 4 回合·玩家回合）＋ AI 决策日志反推成 **AI 回合开始那一刻**：
##     敌方(AI)：负墟 hero_44(1,1)【嘲讽 · 只剩 2 血】· 锤头鲨 hero_37(1,0)【面板攻击 **2**，
##               截图里那个 5 是它技能"本回合每次敌人受伤 +1"被喂出来的】· 超新星 hero_21(3,1)
##     我方(玩家)：波盾 hero_16(0,2)11 · 红帽 hero_40(1,3)6 · 风语者 hero_43(3,3)11
##     障碍：(2,2) 耐久1 · (2,4) 耐久2 · (2,5) 耐久3
##   日志里 AI 的 4 步计划：超新星 (3,1)→(2,1) · 负墟 (1,1)→(0,1)【㉕ +58.76！】· 负墟 打波盾 2 ·
##     超新星 打红帽 3 —— **锤头鲨一步都没有**。
##
## 本探针查四件事：
##   ① 这盘面 ㉕ 的逐单位拆解（多少血点被"少挨"了？）＋ 玩家全队一回合的输出上限（Σ eatk）——
##      用来验"19.6 血点 > 10 点上限"这个**重复计价**的怀疑；
##   ② 锤头鲨这一回合**到底够不够得着**人：可达格逐格列出能打谁、伤害多少（含 +1 加成后的值）；
##   ③ 真跑 `search()`：与用户日志对照（计划里有没有锤头鲨）；
##   ④ 对照实验：把计划整套走完后，**强行让锤头鲨再补一手**（每个可达格 × 每个目标），
##      看终局分是涨还是跌 ⇒ 分清"够不到"与"够得到但被 ㉕ 劝退"。
##
## 用法：
##   & RL\train\跑Godot隔离.ps1 -Tag hh -TimeoutSec 900 -Args @('--headless','--path',(Get-Location).Path,'--scene','res://RL/probe/锤头鲨不前进自检.tscn')
## 输出：每行 `PROBE|...`，末尾 `PROBE|END`。

const FORK := preload("res://RL/ai/AI_Battle.gd")
const WEIGHTS := "res://RL/weights/噩梦.json"
const CAP_MS := 30000

var _grid: HexGrid
var _nm: Dictionary = {}

func _ready() -> void:
	_grid = HexGrid.new(5, 7, 48.0)
	_grid.top_cap_cols = [1, 3]
	_run.call_deferred()

func _run() -> void:
	_nm = _load_json(WEIGHTS)
	print("PROBE|CFG|fork=%s|SEARCH_MODE=%s|BEAM=%s|TAUNT_SOAK_W=%s" % [
		_sha("res://RL/ai/AI_Battle.gd"), str(_nm.get("SEARCH_MODE", 0)), str(_nm.get("BEAM", 0)),
		str(_nm.get("TAUNT_SOAK_W", 0))])
	var descs: Array = []
	descs.append(_desc(DataRegistry.Faction.ENEMY, "hero_44", Vector2i(1, 1), "负墟", { "hp": 2 }))
	descs.append(_desc(DataRegistry.Faction.ENEMY, "hero_37", Vector2i(1, 0), "锤头鲨", {}))
	descs.append(_desc(DataRegistry.Faction.ENEMY, "hero_21", Vector2i(3, 1), "超新星", { "hp": 17 }))
	descs.append(_desc(DataRegistry.Faction.PLAYER, "hero_16", Vector2i(0, 2), "波盾", { "hp": 11 }))
	descs.append(_desc(DataRegistry.Faction.PLAYER, "hero_40", Vector2i(1, 3), "红帽", { "hp": 6 }))
	descs.append(_desc(DataRegistry.Faction.PLAYER, "hero_43", Vector2i(3, 3), "风语者", { "hp": 11 }))
	var obs := { Vector2i(2, 2): true, Vector2i(2, 4): true, Vector2i(2, 5): true }
	var built := _build(descs, obs)
	var ai = built["ai"]
	var sim = built["sim"]
	var hh = sim.units[1]                      # 锤头鲨
	for i in sim.units.size():
		var u = sim.units[i]
		print("PROBE|盘面|%s%s@%s|atk=%d eatk=%d hp=%d/%d|emove=%d 射程=%d|后勤=%s 嘲讽=%s" % [
			("AI " if u.fn == DataRegistry.Faction.ENEMY else "玩家"), String(u.name), str(u.cell),
			int(u.atk), int(u.eatk), int(u.hp), int(u.max_hp), int(u.emove), int(u.atk_range),
			str(u.skills.has(DataRegistry.Skill.LOGISTICS)), str(u.skills.has(DataRegistry.Skill.TAUNT))])
	# ① ㉕ 逐单位 + 玩家输出上限
	var foe_out := 0
	for i in sim.units.size():
		var u = sim.units[i]
		if u != null and u.alive and u.fn != DataRegistry.Faction.ENEMY:
			foe_out += int(u.eatk)
	var soak_sum := 0.0
	for i in sim.units.size():
		var x = sim.units[i]
		if x == null or not x.alive or x.fn != DataRegistry.Faction.ENEMY:
			continue
		if x.skills.has(DataRegistry.Skill.TAUNT):
			continue
		var pf: Dictionary = {}
		var free_v := float(ai._incoming_total_on(sim, x, x.cell, pf, true))
		var pa: Dictionary = {}
		var act_v := float(ai._incoming_total_on(sim, x, x.cell, pa))
		var mult := float(ai._incoming_pool_mult(x))
		soak_sum += maxf(free_v - act_v, 0.0) * mult
		print("PROBE|㉕|%s@%s|关掉嘲讽门=%.1f%s ｜ 实际=%.1f%s ｜ 池倍率=%.3f ⇒ 这一笔=%.2f" % [
			String(x.name), str(x.cell), free_v, str(pf.get("parts", [])), act_v, str(pa.get("parts", [])),
			mult, maxf(free_v - act_v, 0.0) * mult])
	print("PROBE|㉕合计|原始血点=%.2f ⇒ ×权重 %.1f = **%.2f** ｜ 玩家全队一回合输出上限=Σ eatk=**%d** ⇒ %s" % [
		soak_sum, float(_nm.get("TAUNT_SOAK_W", 0.0)), soak_sum * float(_nm.get("TAUNT_SOAK_W", 0.0)),
		foe_out, ("⚠️ 超过上限 ⇒ 同一笔伤害被按多个我方单位重复计了" if soak_sum > float(foe_out) else "在上限内")])
	# ② 锤头鲨够不够得着
	var reach: Array = ai._move_cells(sim, hh).keys()
	var can_hit_any := false
	for c in reach:
		var cc: Vector2i = c
		var tns: Array = []
		for ti in ai._valid_targets(sim, hh, cc):
			tns.append(String(sim.units[int(ti)].name))
		if tns.size() > 0:
			can_hit_any = true
		print("PROBE|锤头鲨格|%s|几何距最近玩家=%d|与敌相邻=%s|能打=%s" % [
			str(cc), _nearest_foe_dist(sim, hh, cc), str(ai._sim_enemy_adjacent(sim, hh, cc)), str(tns)])
	print("PROBE|锤头鲨|可达格 %d 个 ｜ 其中能打到人的=%s｜当前 eatk=%d（面板 %d）" % [
		reach.size(), str(can_hit_any), int(hh.eatk), int(hh.atk)])
	for combo in ai._actions_for(sim, 1):
		var mc: Vector2i = hh.cell if combo.get("move") == null else combo["move"]
		var ti := int(combo.get("atk", -1))
		var tn := "-"
		if ti >= 0 and ti < sim.units.size():
			tn = String(sim.units[ti].name)
		print("PROBE|锤头鲨候选|move=%s atk=%d(%s)|开火时贴敌=%s" % [
			("原地" if combo.get("move") == null else str(mc)), ti, tn,
			str(ai._sim_enemy_adjacent(sim, hh, mc))])
	# ③ 真跑搜索
	var plan: Array = ai.search(sim.clone(), DataRegistry.Faction.ENEMY)
	var txt := ""
	var has_hh := false
	for st in plan:
		var idx := int(st["idx"])
		var act2: Dictionary = st["action"]
		var mv: Variant = act2.get("move")
		var ti2 := int(act2.get("atk", -1))
		var tn2 := "-"
		if ti2 >= 0 and ti2 < sim.units.size():
			tn2 = String(sim.units[ti2].name)
		if idx == 1:
			has_hh = true
		txt += "%s[%s->%s,atk=%s] " % [String(sim.units[idx].name), str(sim.units[idx].cell),
			("原地" if mv == null else str(mv)), tn2]
	print("PROBE|计划|%s" % txt)
	print("PROBE|计划|含锤头鲨步骤=%s" % str(has_hh))
	var post = sim.clone()
	for st in plan:
		ai._apply(post, int(st["idx"]), st["action"])
	var base_score := float(ai._evaluate(post, true))
	print("PROBE|计划结算|终局分=%.2f|玩家剩血：%s|该末态 ㉕=%.2f（原始血点 %.2f）" % [
		base_score, _hp_txt(post), float(_nm.get("TAUNT_SOAK_W", 0.0)) * float(ai._taunt_soak(post)),
		float(ai._taunt_soak(post))])
	# ④ 消融实验：把 ㉕ 关掉（TAUNT_SOAK_W = 0）再搜一次 —— 若锤头鲨这时就出手了，
	#    那"它不动"就是被 ㉕ 压住的（两者抢同一格 (0,1)：负墟站那儿当嘲讽盾 vs 锤头鲨站那儿才能打到波盾）。
	ai.set_weights({ "TAUNT_SOAK_W": 0.0 })
	var plan0: Array = ai.search(sim.clone(), DataRegistry.Faction.ENEMY)
	var txt0 := ""
	var hh0 := false
	for st in plan0:
		var idx0 := int(st["idx"])
		var a0: Dictionary = st["action"]
		var mv0: Variant = a0.get("move")
		var t0 := int(a0.get("atk", -1))
		var n0 := "-"
		if t0 >= 0 and t0 < sim.units.size():
			n0 = String(sim.units[t0].name)
		if idx0 == 1 and t0 >= 0:
			hh0 = true
		txt0 += "%s[%s->%s,atk=%s] " % [String(sim.units[idx0].name), str(sim.units[idx0].cell),
			("原地" if mv0 == null else str(mv0)), n0]
	var post0 = sim.clone()
	for st in plan0:
		ai._apply(post0, int(st["idx"]), st["action"])
	print("PROBE|消融㉕=0|计划：%s" % txt0)
	print("PROBE|消融㉕=0|锤头鲨出手=%s|终局分=%.2f|玩家剩血：%s" % [
		str(hh0), float(ai._evaluate(post0, true)), _hp_txt(post0)])
	ai.set_weights(_nm)
	print("PROBE|END")
	get_tree().quit(0)

func _hp_txt(s) -> String:
	var out := ""
	for i in s.units.size():
		var u = s.units[i]
		if u.fn != DataRegistry.Faction.ENEMY:
			out += "%s=%d " % [String(u.name), int(u.hp)]
	return out

func _nearest_foe_dist(sim, u, cell: Vector2i) -> int:
	var best := 99
	for i in sim.units.size():
		var t = sim.units[i]
		if t.alive and t.fn != u.fn:
			best = mini(best, _grid.distance(cell, t.cell))
	return best

# ---------------------------------------------------------------- 工具
func _build(descs: Array, obs: Dictionary = {}) -> Dictionary:
	var occ := {}
	for i in descs.size():
		occ[descs[i]["cell"]] = i
	var ai = FORK.new(_grid)
	ai.difficulty = 3
	ai.log_decisions = false
	ai.time_budget_ms = CAP_MS
	ai.set_weights(_nm)
	var sim = ai.build_state(descs, occ, {}, {}, obs, {}, {})
	return { "sim": sim, "ai": ai }

func _desc(fn: int, hid: String, cell: Vector2i, nm: String, over: Dictionary = {}) -> Dictionary:
	var hd = DataRegistry.heroes[hid]
	var emove := 2
	if (hd.skills as Array).has(DataRegistry.Skill.SWIFT):
		emove = 3
	var d := {
		"fn": fn, "hero": hid, "cell": cell, "hp": int(hd.max_hp), "max_hp": int(hd.max_hp),
		"atk": int(hd.atk), "eatk": int(hd.atk), "move": emove, "emove": emove,
		"atk_range": maxi(int(hd.attack_range), 1), "atk_type": int(hd.attack_type),
		"skills": (hd.skills as Array).duplicate(), "name": nm,
	}
	for k in over.keys():
		d[k] = over[k]
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

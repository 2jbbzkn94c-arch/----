extends Node
## 英雄特化探针（**不跑对局**）——量"这个英雄有没有把那一手用对"。
##
## 与 `RL/probe/敏感度.gd` 的分工：
##   · 敏感度：量"改这个键会不会改出招"（筛死键）。
##   · 本探针：量"出招**对不对**" —— 固定盘面 + **已知正确答案**，直接给命中率。
##
## 为什么需要它（`英雄特化_总账.md` §七）：单英雄键的作用面只有"含该英雄的阵容"，
##   在 8 队通用批次里信号被稀释 8~49 倍，量不出来 ⇒ 先用这个秒级仪器把键值扫出来，
##   再用「英雄聚焦批次」（8 队全含该英雄 + 陪练=噩梦）做确认。
##
## ⚠️ 口径（用户 2026-09-19 指出后修正，见总账 §0.5）：
##   候选必须**从噩梦档起步**（`RL/weights/噩梦.json`），不能从"引擎默认"起步 ——
##   两者键完全不同（噩梦是 `KILL_BONUS=0` / `SELF_DEATH_W=0` / 折减 1.0 / 带推演层）。
##   所以本探针把噩梦权重**读进来当基线**，并在每行记录 `kill=` 之类的口径证据。
##
## 运行：
##   godot --headless --path <项目> --scene res://RL/probe/英雄特化.tscn -- [beam]
##   缺省 beam = 200（与生产困难/噩梦同宽度：探针要复现真实决策，不要用窄束）
##
## 输出：HERO|… 每行一个（场景 × 配置）的判定；末尾 HERO|SUM|… 汇总命中率。

const FORK := preload("res://RL/ai/AI_Battle.gd")
const NM_PATH := "res://RL/weights/噩梦.json"

## 配置表：每一项 = (名字, 是否叠噩梦权重, hero 段注入)
## `hard` = 引擎默认（= 困难口径，`KILL_BONUS=38`）—— 保留它只为**对照**，不是训练口径。
## ⚠️ 2026-09-21：`噩梦.json` 的 `hero_42` 段现在**本身就是** T4 落地的值
##   （`GOLD_TAKE_VALUE 34` + `GOLD_ATK_DECAY 2.0`）⇒ 下面 `nm` = **现役线上口径**，
##   带 `GOLD_ATK_DECAY` 的那几条是**在同一份底座上覆盖**（覆盖后以本条为准）。
const CONFIGS := [
	{ "name": "hard", "nm": false, "hero": {} },
	{ "name": "nm", "nm": true, "hero": {} },
	{ "name": "nm+decay1", "nm": true, "hero": { "GOLD_ATK_DECAY": 1.0 } },
	{ "name": "nm+decay2", "nm": true, "hero": { "GOLD_ATK_DECAY": 2.0 } },
	{ "name": "nm+end03", "nm": true, "hero": { "GOLD_ENDGAME_MULT": 0.3 } },
	{ "name": "nm+gate", "nm": true, "hero": { "GOLD_KILL_GATE": 1 } },
	{ "name": "nm+oc1", "nm": true, "hero": {}, "oc": 1.0 },
	{ "name": "nm+oc2", "nm": true, "hero": {}, "oc": 2.0 },
	{ "name": "nm+oc5", "nm": true, "hero": {}, "oc": 5.0 },
	{ "name": "nm+oc1full", "nm": true, "hero": { "GOLD_ATK_DECAY": 1.0, "GOLD_ENDGAME_MULT": 0.3, "GOLD_KILL_GATE": 1 }, "oc": 1.0 },
	{ "name": "nm+oc5full", "nm": true, "hero": { "GOLD_ATK_DECAY": 1.0, "GOLD_ENDGAME_MULT": 0.3, "GOLD_KILL_GATE": 1 }, "oc": 5.0 },
	{ "name": "nm+full", "nm": true, "hero": { "GOLD_ATK_DECAY": 1.0, "GOLD_ENDGAME_MULT": 0.3, "GOLD_KILL_GATE": 1 } },
	# ---- 2026-09-21 追加：回答"能不能靠压低矿价拦住 5 攻吃矿" ----
	# decay3/5 = 更强的衰减（攻 5 的矿价：decay2→11.3 · decay3→8.5 · decay5→5.7）⇒ 看 S5 会不会翻成 no_eat
	{ "name": "nm+decay3", "nm": true, "hero": { "GOLD_ATK_DECAY": 3.0 } },
	{ "name": "nm+decay5", "nm": true, "hero": { "GOLD_ATK_DECAY": 5.0 } },
	# 收官专用杠杆：只在"任一方剩 ≤1 人"时打折（不动成长期的价）
	{ "name": "nm+end015", "nm": true, "hero": { "GOLD_ENDGAME_MULT": 0.15 } },
	{ "name": "nm+decay2end015", "nm": true, "hero": { "GOLD_ENDGAME_MULT": 0.15 } },
	# 极端反证：矿价直接压到 0（矿分 + 靠近分都归零）⇒ 若这一档**仍然吃矿**，说明驱动它的不是矿价
	{ "name": "nm+price0", "nm": true, "hero": { "GOLD_TAKE_VALUE": 0.0, "GOLD_TAKE_VALUE_LOW": 0.0, "GOLD_NEAR": 0.0, "GOLD_NEAR_LOW_ATK": 0.0 } },
	# 【2026-09-21 追加·回答"到底要压到多低"】只动"吃到矿的分"（靠近分不动）⇒ 二分出**翻转点**
	#   = 那个局面里"压上去打一下"的**净价值**（矿价低于它 ⇒ 就会去打）。
	{ "name": "nm+price40", "nm": true, "hero": { "GOLD_TAKE_VALUE": 4.0, "GOLD_TAKE_VALUE_LOW": 4.0 } },
	{ "name": "nm+price25", "nm": true, "hero": { "GOLD_TAKE_VALUE": 2.5, "GOLD_TAKE_VALUE_LOW": 2.5 } },
	{ "name": "nm+price10", "nm": true, "hero": { "GOLD_TAKE_VALUE": 1.0, "GOLD_TAKE_VALUE_LOW": 1.0 } },
	{ "name": "nm+price05", "nm": true, "hero": { "GOLD_TAKE_VALUE": 0.5, "GOLD_TAKE_VALUE_LOW": 0.5 } },
	# 【2026-09-21 追加·收官专用旋钮的阈值】只对"任一方存活 ≤1"生效 ⇒ 不动成长期 ⇒ 精准得多。
	#   引擎实际乘子 = 基础衰减 × 本值（现役基础衰减 2.0 ⇒ 攻5 时 0.333）⇒ 0.10 ⇒ 矿价 ≈ 1.13 分。
	{ "name": "nm+end010", "nm": true, "hero": { "GOLD_ENDGAME_MULT": 0.10 } },
	{ "name": "nm+end005", "nm": true, "hero": { "GOLD_ENDGAME_MULT": 0.05 } },
	{ "name": "nm+end000", "nm": true, "hero": { "GOLD_ENDGAME_MULT": 0.0 } },
]

var _grid: HexGrid
var _nm_base: Dictionary = {}

func _ready() -> void:
	print("HERO|BOOT")
	_grid = HexGrid.new()
	_grid.width = 8
	_grid.height = 6
	_run.call_deferred()

func _run() -> void:
	var ua := OS.get_cmdline_user_args()
	var beam := int(ua[0]) if ua.size() > 0 else 200
	_nm_base = _load_json(NM_PATH)
	var scen: Array = _scenarios()
	print("HERO|CFG|scenarios=%d|configs=%d|beam=%d|fork_sha=%s|nm_keys=%d|nm_kill=%s|nm_rollout=%s" % [
		scen.size(), CONFIGS.size(), beam, _sha("res://RL/ai/AI_Battle.gd"),
		_nm_base.size(), str(_nm_base.get("KILL_BONUS", "(缺)")), str(_nm_base.get("ROLLOUT_TOPK", "(缺)"))])
	var tally := {}
	for cfg in CONFIGS:
		tally[String(cfg["name"])] = 0
	for s in scen:
		for cfg in CONFIGS:
			var inject := _build_weights(cfg, beam)
			var r := _one(s, inject)
			var ok: bool = (String(r["actual"]) == String(s["expect"]))
			if ok:
				tally[String(cfg["name"])] = int(tally[String(cfg["name"])]) + 1
			print("HERO|ROW|%s|%s|expect=%s|actual=%s|%s|move=%s|atk=%d|score=%.2f|combo=%s|kill_act=%s|gold_cand=%s|n_act=%d|gold_mult=%.3f" % [
				String(s["name"]), String(cfg["name"]), String(s["expect"]), String(r["actual"]),
				"PASS" if ok else "FAIL", str(r["move"]), int(r["atk"]), float(r["score"]),
				str(r["combo"]), str(r["kill_act"]), str(r["gold_in_cand"]), int(r["n_act"]), float(r["gold_mult"])])
	for cfg in CONFIGS:
		print("HERO|SUM|%s|%d/%d" % [String(cfg["name"]), int(tally[String(cfg["name"])]), scen.size()])
	print("HERO|END")
	get_tree().quit(0)

## 组装一次注入用的权重：噩梦基线（可选）+ hero 段
func _build_weights(cfg: Dictionary, beam: int) -> Dictionary:
	var w := { "BEAM": beam }
	if bool(cfg["nm"]):
		for k in _nm_base.keys():
			w[k] = _nm_base[k]
	var hero: Dictionary = cfg["hero"]
	if not hero.is_empty():
		w["hero_42"] = (hero as Dictionary).duplicate()
	if cfg.has("oc"):
		w["GOLD_OPPORTUNITY_W"] = float(cfg["oc"])
	return w

## 跑一个场景：返回矿工那一步做了什么（move / atk）、是否吃矿，以及自校验字段。
## 吃矿的判定：矿工这一步的落点就是金矿格 —— 真实规则是"踏上即拾取"，所以"移到矿格"= 吃矿。
func _one(s: Dictionary, inject: Dictionary) -> Dictionary:
	var ai = FORK.new(_grid)
	ai.difficulty = 2
	ai.log_decisions = false
	ai.time_budget_ms = 0
	ai.set_weights(inject)
	var sim = ai.build_state(s["descs"], s["occ"], s["gold"])
	var plan: Array = ai.search(sim, DataRegistry.Faction.ENEMY)
	var mi := int(s["miner"])
	var mv = null
	var atk := -99
	for st in plan:
		if int(st.get("idx", -1)) == mi:
			var a: Dictionary = st.get("action", {})
			mv = a.get("move", null)
			atk = int(a.get("atk", -99))
			break
	var ate := false
	if mv != null and (s["gold"] as Dictionary).has(mv):
		ate = true
	# ---- 自校验：这个场景到底构不构成"吃矿 vs 该做的事"的二选一？----
	# `combo` = 存在一手**既落到矿格又攻击**（那"吃矿"和"打人"就不冲突，场景无效）；
	# `kill_act` = 存在一手能一击收掉某个敌人（用来判断 gate 该不该生效）；
	# `gold_cand` = 矿格在不在这位矿工本回合的候选表里（不在 ⇒ 它压根没得选）。
	# ⚠️ 不能写 `var t2: SimUnit = …`：`SimUnit` 是 BattleAI 的**内部类**，而本探针加载的是 fork
	#   （`RL/ai/AI_Battle.gd`，没有 `class_name`）⇒ 该类型名在这一作用域里不存在，Godot 会在**解析阶段**
	#   报 `Could not find type "SimUnit"` 并让**整个脚本不加载**（后果：`quit()` 不在 ⇒ headless 永久挂住）。
	var combo := false
	var kill_act := false
	var n_act := 0
	var gold_in_cand := false
	for a2 in ai._actions_for(sim, mi):
		n_act += 1
		var m2 = a2.get("move", null)
		var k2 := int(a2.get("atk", -99))
		if m2 != null and (s["gold"] as Dictionary).has(m2):
			gold_in_cand = true
			if k2 >= 0:
				combo = true
		if k2 >= 0 and k2 < sim.units.size():
			var t2 = sim.units[k2]
			if t2 != null and t2.hp <= sim.units[mi].eatk:
				kill_act = true
	# 探针自己复算一遍"矿分乘子"（与 `_evaluate` 里那段同公式），让每行都能看到键到底生效没有
	var mul := 1.0
	var d := float(inject.get("hero_42", {}).get("GOLD_ATK_DECAY", 0.0))
	if d > 0.0:
		mul /= 1.0 + d * float(maxi(int(sim.units[mi].eatk) - 4, 0))
	var e := float(inject.get("hero_42", {}).get("GOLD_ENDGAME_MULT", 1.0))
	if e != 1.0:
		var mine := 0
		var foes := 0
		for j in sim.units.size():
			var p = sim.units[j]
			if p == null or not p.alive:
				continue
			if p.fn == DataRegistry.Faction.ENEMY:
				mine += 1
			else:
				foes += 1
		if mini(mine, foes) <= 1:
			mul *= e
	if mul > 0.0 and int(inject.get("hero_42", {}).get("GOLD_KILL_GATE", 0)) > 0 and kill_act:
		mul = 0.0
	return { "move": mv, "atk": atk, "actual": "eat" if ate else "no_eat", "score": float(ai._evaluate(sim)),
		"combo": combo, "kill_act": kill_act, "n_act": n_act, "gold_in_cand": gold_in_cand, "gold_mult": mul }

## 单位描述（与 敏感度.gd 的 `_u` 同族；`extra` 用来打 `can_pickup_gold` 这类标记）
func _u(fn: int, hero: String, cell: Vector2i, hp: int, max_hp: int, atk: int, mv: int,
		rng: int, typ: int, skills: Array, nm: String, extra: Dictionary = {}) -> Dictionary:
	var d := {
		"fn": fn, "hero": hero, "cell": cell, "hp": hp, "max_hp": max_hp,
		"atk": atk, "eatk": atk, "move": mv, "emove": mv,
		"atk_range": rng, "atk_type": typ, "skills": skills, "name": nm,
	}
	for k in extra.keys():
		d[k] = extra[k]
	return d

## 把 descs 的落点整理成 occ（"cell -> 单位下标"）—— 探针要的是**真实**局面，不能省 occ。
func _occ(descs: Array) -> Dictionary:
	var o := {}
	for i in descs.size():
		o[descs[i]["cell"]] = i
	return o

## 四个场景：S1/S2 = 契约（期望不吃矿），S3/S4 = 反向（期望照常吃矿）
## 设计约束（第一版踩过坑，写在这里防复发）：
##   ① 矿格必须**本回合可达**（否则矿工压根没得选）——注意 5 攻的矿工不再享受 `dkey=-1000` 强制入选，
##      矿格得靠"离敌人近"排进候选表；
##   ② 矿格**不能与任何敌人相邻**（否则"踩矿 + 打人"能同一手完成 ⇒ 这个场景不构成二选一）；
##   ③ 不要放嘲讽单位（会把目标选择整个劫持掉）；
##   ④ 这四条性质由探针每行打印的 `combo / gold_cand / kill_act / n_act` **自校验**，不靠肉眼保证。
## 矿工 = 黄金矿工 hero_42（`can_pickup_gold: true` 必须手工打上：探针不跑英雄脚本）。
func _scenarios() -> Array:
	var E := DataRegistry.Faction.ENEMY
	var P := DataRegistry.Faction.PLAYER
	var MELEE := int(DataRegistry.AttackType.MELEE)
	var GOLD := { "can_pickup_gold": true }
	var out: Array = []

	# S1 契约核心·**有必杀**：3v3、矿工 5 攻，眼前有一个「一击能收掉」的残血（4 血），
	# 矿在本回合可达但不与敌人相邻 ⇒ 「踩矿」与「收人头」互斥。
	# ⚠️ 这一条正是用户抱怨的场景在**噩梦口径**下的复现：噩梦 `KILL_BONUS=0`（击杀奖励被删），
	#   所以"收人头"不再有 +38 的即时重奖，只剩身价自动扣除的那笔 ⇒ 矿工容易改去吃矿。
	var s1: Array = [
		_u(E, "hero_42", Vector2i(2, 2), 20, 26, 5, 3, 1, MELEE, [], "矿工(5攻)", GOLD),
		_u(E, "hero_26", Vector2i(0, 1), 18, 18, 5, 3, 1, MELEE, [], "队友A", {}),
		_u(E, "hero_17", Vector2i(0, 4), 16, 16, 4, 3, 1, MELEE, [], "队友B", {}),
		_u(P, "hero_23", Vector2i(5, 2), 4, 20, 5, 3, 1, MELEE, [], "残血(一击可收)", {}),
		_u(P, "hero_22", Vector2i(7, 0), 20, 30, 4, 3, 1, MELEE, [], "敌核心", {}),
		_u(P, "hero_26", Vector2i(7, 5), 20, 20, 5, 3, 1, MELEE, [], "敌A", {}),
	]
	out.append({ "name": "S1有必杀·该收人头", "descs": s1, "occ": _occ(s1),
		"gold": { Vector2i(4, 4): true }, "miner": 0, "expect": "no_eat" })

	# S2 契约·**终局**：我方只剩 2 人、对面只剩 1 人（= 3 死判负里的最后一个），
	# 那最后一个已经残血（一击可收 = 直接赢）⇒ 更不该去吃矿。
	var s2: Array = [
		_u(E, "hero_42", Vector2i(2, 2), 20, 26, 5, 3, 1, MELEE, [], "矿工(5攻)", GOLD),
		_u(E, "hero_26", Vector2i(0, 0), 18, 18, 5, 3, 1, MELEE, [], "队友", {}),
		_u(P, "hero_23", Vector2i(5, 2), 4, 30, 5, 3, 1, MELEE, [], "对面最后一个(4血)", {}),
	]
	out.append({ "name": "S2终局·最后一个残血", "descs": s2, "occ": _occ(s2),
		"gold": { Vector2i(4, 4): true }, "miner": 0, "expect": "no_eat" })

	# S5 契约·**无必杀 + 终局**（= 用户抱怨的真正形态）：
	#   对面最后一个还有 20 血（5 攻打不死），矿在本回合可达且与敌人不相邻 ⇒
	#   「踩矿（+26 分）」对上「压上去打一下（只掉 5 血，约 +6 分）」——**基线必然选矿**，
	#   而收官阶段该做的是压上去（杀 3 个才判负 ⇒ 对面只剩 1 人时，打掉它就是赢）。
	#   注意 gate 在这种局面**不该生效**（没有可一击收掉的目标）⇒ 这一条专门测"衰减类"键。
	var s5: Array = [
		_u(E, "hero_42", Vector2i(2, 2), 20, 26, 5, 3, 1, MELEE, [], "矿工(5攻)", GOLD),
		_u(E, "hero_26", Vector2i(0, 0), 18, 18, 5, 3, 1, MELEE, [], "队友", {}),
		_u(P, "hero_23", Vector2i(5, 2), 20, 30, 5, 3, 1, MELEE, [], "对面最后一个(20血)", {}),
	]
	out.append({ "name": "S5无必杀·终局该压上", "descs": s5, "occ": _occ(s5),
		"gold": { Vector2i(4, 4): true }, "miner": 0, "expect": "no_eat" })

	# S6 诊断·**同 S 5，但对面攻击力只有 1**（= 拆掉"等价换血"那半边账）：
	#   用来证明 S5 里"打一下不值钱"的真正原因**不是评分缺项**，而是**对面反击把血账打平**了 ——
	#   对面 5 攻时：打它 5 血 +5、被反击 −5、集火 frac² +0.8 ⇒ **净 ≈ +0.8**；
	#   对面 1 攻时：+5 − 1 + 0.8 ⇒ **净 ≈ +4.8** ⇒ 同一档矿价（decay2 = 11.3）依然吃，
	#   但把矿价压到 4 分左右就该翻了 ⇒ 两条曲线的差就是"换血"这笔账。
	var s6: Array = [
		_u(E, "hero_42", Vector2i(2, 2), 20, 26, 5, 3, 1, MELEE, [], "矿工(5攻)", GOLD),
		_u(E, "hero_26", Vector2i(0, 0), 18, 18, 5, 3, 1, MELEE, [], "队友", {}),
		_u(P, "hero_23", Vector2i(5, 2), 20, 30, 1, 3, 1, MELEE, [], "对面最后一个(20血·1攻)", {}),
	]
	out.append({ "name": "S6诊断·同S5但对面1攻", "descs": s6, "occ": _occ(s6),
		"gold": { Vector2i(4, 4): true }, "miner": 0, "expect": "no_eat" })

	# S3 反向·开局 1 攻：**弱矿工该先成长** —— 3v3、无必杀、矿在本回合可达 ⇒ 期望照常吃矿
	# （守住"别把吃矿整体关掉"）
	var s3: Array = [
		_u(E, "hero_42", Vector2i(1, 1), 20, 20, 1, 3, 1, MELEE, [], "矿工(1攻)", GOLD),
		_u(E, "hero_26", Vector2i(0, 3), 18, 18, 5, 3, 1, MELEE, [], "队友A", {}),
		_u(E, "hero_17", Vector2i(0, 5), 16, 16, 4, 3, 1, MELEE, [], "队友B", {}),
		_u(P, "hero_23", Vector2i(3, 1), 20, 20, 5, 3, 1, MELEE, [], "敌A", {}),
		_u(P, "hero_22", Vector2i(5, 3), 20, 30, 4, 3, 1, MELEE, [], "敌核心", {}),
		_u(P, "hero_26", Vector2i(7, 5), 20, 20, 5, 3, 1, MELEE, [], "敌B", {}),
	]
	out.append({ "name": "S3反向·1攻该吃矿", "descs": s3, "occ": _occ(s3),
		"gold": { Vector2i(1, 3): true }, "miner": 0, "expect": "eat" })

	# S4 反向·够不到人：5 攻、矿紧邻、敌人全在远端（≥6 格）⇒ 没别的事可做，期望照常吃矿
	# （守住"衰减别把吃矿算成 0 或负收益"）
	var s4: Array = [
		_u(E, "hero_42", Vector2i(0, 0), 26, 26, 5, 3, 1, MELEE, [], "矿工(5攻)", GOLD),
		_u(E, "hero_26", Vector2i(0, 2), 18, 18, 5, 3, 1, MELEE, [], "队友A", {}),
		_u(E, "hero_17", Vector2i(0, 4), 16, 16, 4, 3, 1, MELEE, [], "队友B", {}),
		_u(P, "hero_23", Vector2i(7, 1), 20, 20, 5, 3, 1, MELEE, [], "敌A", {}),
		_u(P, "hero_22", Vector2i(7, 3), 20, 30, 4, 3, 1, MELEE, [], "敌核心", {}),
		_u(P, "hero_26", Vector2i(7, 5), 20, 20, 5, 3, 1, MELEE, [], "敌B", {}),
	]
	out.append({ "name": "S4反向·够不到人该吃矿", "descs": s4, "occ": _occ(s4),
		"gold": { Vector2i(1, 0): true }, "miner": 0, "expect": "eat" })

	return out

func _load_json(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		print("HERO|WARN|读不到 %s ⇒ 噩梦基线为空（口径会退化成困难！）" % path)
		return {}
	var txt := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(txt)
	if typeof(parsed) != TYPE_DICTIONARY:
		print("HERO|WARN|%s 解析失败 ⇒ 噩梦基线为空" % path)
		return {}
	return parsed

func _sha(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return "nofile"
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(f.get_buffer(f.get_length()))
	f.close()
	return ctx.finish().hex_encode().substr(0, 12)

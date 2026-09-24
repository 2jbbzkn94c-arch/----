extends Node
## 【2026-09-24 一次性探针·只读】两阶段搜索的**路径账**：钱花在"枚举走位"还是"排出手"上。
##
## 起因：用户「**你仔细思考一下如何减少路径**」。已知事实（§五 T23/T24/T30）：
##   · 阶段 1 的「同末态去重」把那一层从 10.6~13.5s 压到 0.6s（n! 份决定顺序被折叠）；
##   · 漏斗 16 → 32 **棋力真的涨**（+3.11 [+0.16,+6.06]，但单格墙钟 +25~40%、`search_ms_max` 12~19s → 26~34s）；
##   ⇒ 要"不降水平地少走路"，先得知道**哪一半在吃钱**、以及**同一末态被复制了多少份**。
##
## 本探针量四件事（每个局面 × 每臂一行）：
##   `p1_ms` 阶段 1 耗时 · `p2_ms` 阶段 2 耗时 · `evals` 阶段 1 真正跑的完整评分次数 · `dups` 阶段 1 丢掉的重份
##   `built` 阶段 1 产出多少套阵型 · `used` 送进阶段 2 多少套 · `leaves` 阶段 2 评估出的完整计划数
##   `steps` 计划步数 + 计划指纹（用来判"两臂是不是真的同解"）
##
## 臂（都跑在同一起点上；只改搜索结构键，评分键一字不动）：
##   `f8` / `f16` / `f32` = 漏斗 `TWO_PHASE_LAYOUTS` 8 / 16 / 32（beam 200，与镜像批同口径）
##   `f16b400`            = 漏斗 16 + beam 400（**贴近实机噩梦档**：生产 `BEAM = 400`）
##   `f32p96`             = 漏斗 32 + 阶段 1 每层宽度 96（`TWO_PHASE_P1_BEAM = 96`：看"先砍宽度再加漏斗"是否等价）
##
## 用法：
##   & RL\train\跑Godot隔离.ps1 -Tag paths -TimeoutSec 2400 -Args @('--headless','--path',(Get-Location).Path,'--scene','res://RL/probe/路径分账自检.tscn')
## 输出：每行 `PATH|...`（ASCII，只有英雄名是中文），末尾 `PATH|END`。

const FORK := preload("res://RL/ai/AI_Battle.gd")
const BASE := "res://RL/weights/噩梦_基线.json"
const SEARCH_CAP_MS := 0            # 0 = 不限时（与跑批同口径，可复现）

var _grid: HexGrid

func _ready() -> void:
	_grid = HexGrid.new(5, 7, 48.0)
	_grid.top_cap_cols = [1, 3]
	_run.call_deferred()

func _run() -> void:
	var w := _flat(BASE)
	print("PATH|CFG|fork=%s|base=%s|cap_ms=%d|positions=%d" % [
		_sha("res://RL/ai/AI_Battle.gd"), _sha(BASE), SEARCH_CAP_MS, _positions().size()])
	var arms: Array = [
		{ "name": "f8", "beam": 200, "theta": { "TWO_PHASE_LAYOUTS": 8 } },
		{ "name": "f16", "beam": 200, "theta": { "TWO_PHASE_LAYOUTS": 16 } },
		{ "name": "f32", "beam": 200, "theta": { "TWO_PHASE_LAYOUTS": 32 } },
		{ "name": "f16b400", "beam": 400, "theta": { "TWO_PHASE_LAYOUTS": 16 } },
		{ "name": "f32p96", "beam": 200, "theta": { "TWO_PHASE_LAYOUTS": 32, "TWO_PHASE_P1_BEAM": 96 } },
		# 组合臂：漏斗 32 + 阶段 1 宽度 96 + 召唤物候选收窄（`SUMMON_SLOT_ONLY`；⚠️ 基线里**没有**这个键
		#   ⇒ 前面几臂都是"召唤物剪枝关着"的重活口径）
		{ "name": "f32p96sm1", "beam": 200, "theta": { "TWO_PHASE_LAYOUTS": 32, "TWO_PHASE_P1_BEAM": 96, "SUMMON_SLOT_ONLY": 1 } },
		# L1 判决臂：**阶段 2 同末态去重**（`TWO_PHASE_P2_DEDUP`）—— 与 `f16` / `f32` 逐字对比
		#   （预期：计划指纹**逐字相同**、`p2_ms` 与阶段 2 评分次数下降）
		{ "name": "f16p2d1", "beam": 200, "theta": { "TWO_PHASE_LAYOUTS": 16, "TWO_PHASE_P2_DEDUP": 1 } },
		{ "name": "f32p2d1", "beam": 200, "theta": { "TWO_PHASE_LAYOUTS": 32, "TWO_PHASE_P2_DEDUP": 1 } },
	]
	# `--` 后面可以只跑指定臂（逗号分隔），例如 `-- f16,f16p2d1` ⇒ 省时间
	var only: Array = []
	var ua := OS.get_cmdline_user_args()
	if ua.size() > 0 and String(ua[0]) != "":
		only = String(ua[0]).split(",", false)
		var kept: Array = []
		for arm in arms:
			if only.has(String(arm["name"])):
				kept.append(arm)
		if kept.size() > 0:
			arms = kept
	for pos in _positions():
		var nm := String(pos["name"])
		for arm in arms:
			var inj: Dictionary = w.duplicate()
			inj["BEAM"] = int(arm["beam"])
			inj["SEARCH_MODE"] = 2
			inj["TWO_PHASE_DEDUP"] = 1
			inj["TIME_BUDGET_MS"] = 0
			for k in (arm["theta"] as Dictionary).keys():
				inj[k] = (arm["theta"] as Dictionary)[k]
			var ai = _mk(inj)
			var sim = ai.build_state(pos["descs"], _occ(pos["descs"]), pos.get("gold", {}), pos.get("graves", {}),
				pos.get("obs", {}), pos.get("bombs", {}), pos.get("buff", {}))
			var t0 := Time.get_ticks_msec()
			var plan: Array = ai.search(sim, DataRegistry.Faction.ENEMY)
			var wall := Time.get_ticks_msec() - t0
			var fp: Array = []
			for st in plan:
				var a: Dictionary = st.get("action", {})
				fp.append("%d:%s:%d" % [int(st.get("idx", -1)), str(a.get("move", null)), int(a.get("atk", -99))])
			# 【2026-09-24·L1 判决】把计划落成终局局面再评一次分：**棋力看这一列，不看指纹**
			#   （去重会改变 `inner=25` 名额里活下来的那批状态 ⇒ 计划可能不同 ⇒ 必须比分数）
			var end = sim.clone()
			for st in plan:
				ai._apply(end, int(st["idx"]), st["action"])
			var end_score := float(ai._evaluate(end, true))
			print("PATH|%s|%s|ms=%d|p1_ms=%d|p2_ms=%d|evals=%d|dups=%d|p2_evals=%d|p2_dups=%d|hero_kids=%d|sm_kids=%d|built=%d|used=%d|leaves=%d|steps=%d|score=%.2f|fp=%s" % [
				nm, String(arm["name"]), wall, int(ai.last_tp_phase1_ms), int(ai.last_tp_phase2_ms),
				int(ai.last_tp_p1_evals), int(ai.last_tp_p1_dups),
				int(ai.last_tp_p2_evals), int(ai.last_tp_p2_dups),
				int(ai.last_tp_p1_hero_kids), int(ai.last_tp_p1_summon_kids),
				int(ai.last_tp_layouts_built), int(ai.last_tp_layouts_used), int(ai.last_tp_leaves),
				plan.size(), end_score, ">".join(fp)])
	print("PATH|READ|p1_ms vs p2_ms 决定「该砍哪一半」；dups/evals = 同末态重份比例；leaves 随 used 线性涨 ⇒ 漏斗就是阶段 2 的乘法器")
	print("PATH|END")
	get_tree().quit(0)

func _mk(inject: Dictionary):
	var ai = FORK.new(_grid)
	ai.difficulty = 2                 # 与 harness 同口径（>=2 ⇒ 用 w_beam / w_jitter）
	ai.log_decisions = false
	ai.time_budget_ms = SEARCH_CAP_MS
	ai.set_weights(inject)
	return ai

func _occ(descs: Array) -> Dictionary:
	var occ := {}
	for i in descs.size():
		occ[descs[i]["cell"]] = i
	return occ

func _desc(fn: int, hid: String, cell: Vector2i, nm: String, hp: int = -1) -> Dictionary:
	var hd = DataRegistry.heroes.get(hid, null)
	if hd == null:
		hd = DataRegistry.summons.get(hid, null)     # 召唤物（`summon_skeleton`）不在 heroes 里
	if hd == null:
		push_error("PATH|BADHERO|" + hid)
		return {}
	var emove := 2
	if (hd.skills as Array).has(DataRegistry.Skill.SWIFT):
		emove = 3
	var mx := int(hd.max_hp)
	return {
		"fn": fn, "hero": hid, "cell": cell, "hp": (mx if hp < 0 else hp), "max_hp": mx,
		"atk": int(hd.atk), "eatk": int(hd.atk), "move": emove, "emove": emove,
		"atk_range": maxi(int(hd.attack_range), 1), "atk_type": int(hd.attack_type),
		"skills": (hd.skills as Array).duplicate(), "name": nm,
	}

## 局面集：都按 `RL/harness/对局.gd` 的部署（E=(1,2)(3,2)(1,1) / P=(1,4)(3,4)(1,5)），只改牌组与血量
func _positions() -> Array:
	var E := DataRegistry.Faction.ENEMY
	var P := DataRegistry.Faction.PLAYER
	var ec: Array = [Vector2i(1, 2), Vector2i(3, 2), Vector2i(1, 1)]
	var pc: Array = [Vector2i(1, 4), Vector2i(3, 4), Vector2i(1, 5)]
	var out: Array = []
	# ① 标准 3 人队（近战/远程混编）
	out.append({ "name": "①42-03-17", "descs": [
		_desc(E, "hero_42", ec[0], "我A"), _desc(E, "hero_03", ec[1], "我B"), _desc(E, "hero_17", ec[2], "我C"),
		_desc(P, "hero_42", pc[0], "敌A"), _desc(P, "hero_03", pc[1], "敌B"), _desc(P, "hero_17", pc[2], "敌C"),
	] })
	# ② 交战态（两排贴上去、都掉过血 ⇒ 候选里大量"能打到人"的落点）
	out.append({ "name": "②交战24-09-20", "descs": [
		_desc(E, "hero_24", Vector2i(1, 3), "我肉"), _desc(E, "hero_09", Vector2i(2, 3), "我枪"), _desc(E, "hero_20", Vector2i(0, 2), "我狙", 12),
		_desc(P, "hero_24", Vector2i(1, 4), "敌肉", 18), _desc(P, "hero_09", Vector2i(2, 4), "敌枪", 14), _desc(P, "hero_20", Vector2i(3, 3), "敌狙"),
	] })
	# ③ 召唤队（骷髅兵 = 阶段 1 的重份大户；也让 `SUMMON_SLOT_ONLY` 生效）
	#   ⚠️ 召唤物在 `DataRegistry.summons`（id = `summon_skeleton`），不在 `heroes` 里
	out.append({ "name": "③召唤33-03-18", "descs": [
		_desc(E, "hero_33", Vector2i(1, 2), "死灵"), _desc(E, "hero_03", Vector2i(3, 2), "毒蛇"), _desc(E, "hero_18", Vector2i(1, 1), "长剑"),
		_desc(E, "summon_skeleton", Vector2i(2, 2), "骷髅1"), _desc(E, "summon_skeleton", Vector2i(0, 1), "骷髅2"),
		_desc(P, "hero_13", Vector2i(1, 4), "红帽"), _desc(P, "hero_12", Vector2i(3, 5), "巨剑"), _desc(P, "hero_06", Vector2i(0, 4), "医护"),
	] })
	# ④ 障碍多的局面（威胁/视线要查墙 ⇒ 每次 `_evaluate` 更贵）
	out.append({ "name": "④障碍局", "descs": [
		_desc(E, "hero_46", Vector2i(1, 2), "宿魂"), _desc(E, "hero_11", Vector2i(3, 1), "塔盾"), _desc(E, "hero_27", Vector2i(0, 2), "我C"),
		_desc(P, "hero_49", Vector2i(1, 5), "荆棘"), _desc(P, "hero_25", Vector2i(3, 4), "战锤"), _desc(P, "hero_34", Vector2i(2, 4), "敌C"),
	], "obs": { Vector2i(2, 3): true, Vector2i(4, 3): true, Vector2i(0, 3): true } })
	return out

func _flat(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var d = JSON.parse_string(f.get_as_text())
	f.close()
	var out: Dictionary = {}
	if typeof(d) != TYPE_DICTIONARY:
		return out
	for k in (d as Dictionary).keys():
		if String(k).begins_with("_"):
			continue
		out[String(k)] = (d as Dictionary)[k]
	return out

func _sha(path: String) -> String:
	if not FileAccess.file_exists(path):
		return "?"
	var ctx := HashingContext.new()
	if ctx.start(HashingContext.HASH_SHA256) != OK:
		return "?"
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return "?"
	ctx.update(f.get_buffer(f.get_length()))
	f.close()
	return ctx.finish().hex_encode().substr(0, 12)

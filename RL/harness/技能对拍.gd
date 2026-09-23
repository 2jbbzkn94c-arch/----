extends Node
## 技能对拍矩阵：同一个局面 + 同一个动作，分别走
##   ① 真实结算（真实 scenes/Main.tscn 的 _do_move/_do_attack/_do_attack_obstacle）
##   ② AI 的内部模拟（RL/ai/AI_Battle.gd 的 build_state + _apply）
## 然后逐字段比对（HP/攻/移/状态/位置/炸弹/墓碑/障碍耐久/金矿剩余回合/增益道具/阵亡数）。
##
## 目的：找出「AI 预判 ≠ 真实规则」的英雄技能——这类缺口会让 AI 按错误预期选招，
## 是"训练出来的权重没意义"的根源之一。
##
## 判定档位（layer 标出验证的是哪一层）：
##   MATCH —— action 层：真实结算与 AI 模拟逐字段一致
##   SNAP  —— snapshot 层：真实回合边界/登场钩子跑完后，"用该局面重建的 Sim" 与真实局面逐字段一致
##            （注意：这**不**证明"模拟复现了回合技"——AI 只模拟本回合内我方行动，
##             回合开始/结束技不在模拟范围内，能验证的只是"成果有没有被快照完整带入 AI 视野"）
##   DIFF  —— 不一致（layer=act 动作预测 / layer=snap 局面读取）
##   SKIP  —— 真实侧该场景未生效（动作被拦 / 条件不成立 / 钩子无事发生）：**不作为一致性证据**，
##            避免"两边都正确地什么都没做"被读成"技能对齐"
##   SETUP —— 场景构造失败（起始局面两边就对不上），与技能无关
##
## 运行：
##   godot --headless --path <proj> --log-file <log> --scene res://RL/harness/技能对拍.tscn -- [模式]
## 模式：
##   all      = 7 个手工特殊场景 + 全部英雄的 15 个通用场景族
##   special  = 只跑手工特殊场景
##   hero_XX  = 只跑该英雄的通用场景族
##   act      = 通用族中"动作层"场景（不含 hook）
##   snap     = 通用族中"快照层"场景（含 hook）
##   ext      = 通用族中的新增场景（不含原有 5 个基础场景）
## 输出（stdout 与 --log-file 同一份）：
##   SK|<tag>|verdict=MATCH|DIFF|SKIP|SETUP|diffs=...     （只打异常项）
##   SK|EV|<tag>|<verdict>|<真实侧字段变化>               （每个场景的真实侧证据）
##   SK|HERO|<英雄>|<场景>=<判定>|...                      （逐英雄聚合）
##   SK|DIFFBYSCENE|... / SK|SKIPBYSCENE|... / SK|DIFFKINDS|...（差异/跳过按场景与字段归类）
##   SK|SUMMARY|mode=..|cases=..|match=..|diff=..|skip=..|snap=..|fork_sha=..

const FORK := preload("res://RL/ai/AI_Battle.gd")

const E := 1   # 敌方（AI 视角的"我方"）
const P := 0   # 玩家方
const MAX_WAIT := 600   # 等一招动画的帧上限

# ---- 通用布局常量（board 5×7：x∈[0,4]，y∈[0,6]，y=0 只留 {1,3} 顶帽）----
# 相邻关系（odd-q 轴向距离）：
#   (2,3) 的邻居 = {(1,2),(2,2),(3,2),(3,3),(2,4),(1,3)}
#   (2,4) 的邻居 = {(1,3),(2,3),(3,3),(3,4),(2,5),(1,4)}
#   (1,3) 的邻居 = {(0,3),(1,2),(2,3),(2,4),(1,4),(0,4)}
const C_X := Vector2i(2, 4)       # 被测英雄 X 的默认位置
const C_D := Vector2i(2, 3)       # 假想敌 D：与 X 同列相邻（距离 1）
const C_X2 := Vector2i(2, 5)      # 距离 2 变体：X 挪到 (2,5)，与 D(2,3) 相隔 2 格
const C_NEAR := Vector2i(1, 3)    # 移动落点：**同时紧邻 D(2,3) 与队友 A(1,4)**
								  #   —— 修"移动后相邻"假绿：原落点 (2,5) 与 D 距离变 2，
								  #      烛火/雪拳的"相邻"条件恒不成立，MATCH 只是"两边都没做事"
const C_FAR := Vector2i(2, 5)     # 原"移动"落点：移动后与 D 距离变 2（保留作对照）
const C_D2 := Vector2i(2, 2)      # 第二个假想敌：正在 D 的"身后同一直线"上
const C_A := Vector2i(1, 4)       # 队友 A：紧邻 X
const C_DA := Vector2i(1, 3)      # 攻击队友 A 的敌人：紧邻 A
const C_OBS_MV := Vector2i(1, 2)  # 移动落点 (1,3) 旁的障碍格（烛火点燃用）
const C_OBS_ATK := Vector2i(2, 3) # 被直接攻击的障碍格（占用原假想敌位，与 X 距离 1 同列直线）
const C_NEG_FAR := Vector2i(2, 2) # 距离 2 的负面来源位（沉默术士这类远程：不被贴身才会挂状态）

var _b: Battle = null
var _fail := 0
var _ai_fork = null
var _req := {}
var _req_player_raw := {}
var _req_enemy_raw := {}
var _setup_bad := ""
# 归类统计（只用于输出归类行，不参与判定）
var _diff_by_scene := {}
var _skip_by_scene := {}
var _diff_kinds := {}

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	var ua := OS.get_cmdline_user_args()
	var mode := String(ua[0]) if ua.size() > 0 else "special"
	if mode == "plancore":
		await _run_plan_core()
		return
	var cases := _select(mode)
	var n_match := 0
	var n_diff := 0
	var n_skip := 0
	var n_snap := 0
	var bad: Array = []
	var hero_lines := {}
	for i in cases.size():
		var sc: Dictionary = cases[i]
		var r := await _run_case(sc)
		var v := String(r["verdict"])
		match v:
			"MATCH":
				n_match += 1
			"SNAP":
				n_snap += 1
			"DIFF":
				n_diff += 1
			_:
				n_skip += 1
		if v != "MATCH" and v != "SNAP":
			bad.append(r)
		_note(r)
		# 真实侧证据：每个场景都打一行"真实侧到底发生了什么"，供报告逐条核对
		# （没有它就只能看到"两边一致"，却说不清技能是否真的触发了）
		var delta := String(r.get("delta", ""))
		if delta != "":
			print("SK|EV|%s|%s|%s" % [String(r["tag"]), v, delta])
		var pre_delta := String(r.get("pre_delta", ""))
		if pre_delta != "":
			# 快照场景的"前提动作"变化：单独一行、标签带 #前提动作 后缀，便于逐行核对
			print("SK|EV|%s#前提动作|%s|%s" % [String(r["tag"]), v, pre_delta])
		var post_delta := String(r.get("post_delta", ""))
		if post_delta != "":
			# 快照场景里"回合/登场钩子自己造成的变化"（不含前提动作）
			print("SK|EV|%s#钩子后|%s|%s" % [String(r["tag"]), v, post_delta])
		if sc.has("hero"):
			var hid := String(sc["hero"])
			var lst: Array = hero_lines.get(hid, [])
			lst.append("%s=%s" % [String(r["scene"]), v])
			hero_lines[hid] = lst
	# 只打印异常项（几百个场景全打印会把结论淹掉），正常项只计数
	for r in bad:
		print("SK|%s|verdict=%s|layer=%s|diffs=%s" % [
			String(r["tag"]), String(r["verdict"]), String(r.get("layer", "?")), str(r["diffs"])])
	for hid in hero_lines.keys():
		print("SK|HERO|%s|%s" % [hid, "|".join(hero_lines[hid])])
	print("SK|DIFFBYSCENE|%s" % _kind_str(_diff_by_scene))
	print("SK|SKIPBYSCENE|%s" % _kind_str(_skip_by_scene))
	print("SK|DIFFKINDS|%s" % _kind_str(_diff_kinds))
	print("SK|SUMMARY|mode=%s|cases=%d|match=%d|diff=%d|skip=%d|snap=%d|fork_sha=%s" % [
		mode, n_match + n_diff + n_skip + n_snap, n_match, n_diff, n_skip, n_snap,
		_sha("res://RL/ai/AI_Battle.gd")])
	print("SK|END")
	get_tree().quit(0)

# ===================== 核心识别（plan 层）证据 =====================
## 目的：证明 `HERO_VALUE`（英雄核心价值系数）真的改变了**目标选择**，
## 而不是"谁血少打谁"。做法：手工造一个**两个目标都能一击打死**的局面 ——
##   · 肉盾 独脚龟(hero_13)：血量更高（自然评分略高），系数 0.9
##   · 核心 圣光(hero_22)：血量更低，系数 1.35
## 于是：系数全 1.0 时 AI 会打死"评分自然更高"的肉盾；开系数后应改成优先打死核心。
## 只比 `search()` 出来的**首选攻击目标下标**，不涉及真实 Battle（这是 plan 层检查）。
func _run_plan_core() -> void:
	var E := DataRegistry.Faction.ENEMY
	var P := DataRegistry.Faction.PLAYER
	# 先建一局真实 Battle：只为拿一个真 HexGrid（搜索需要它），局面本身不用
	await _setup({ "scene": "plancore",
		"units": [ { "h": "hero_25", "fn": E, "c": Vector2i(2, 4) },
			{ "h": "hero_13", "fn": P, "c": Vector2i(2, 3) },
			{ "h": "hero_22", "fn": P, "c": Vector2i(3, 4) } ] })
	var row_bottom: int = _b.grid.height - 1
	var me := { "fn": E, "hero": "hero_25", "cell": Vector2i(2, 4), "hp": 40, "max_hp": 40,
		"atk": 10, "eatk": 10, "move": 3, "emove": 3, "atk_range": 1, "atk_type": 0,
		"skills": [], "name": "我方战锤", "row": 0 }
	var tank := { "fn": P, "hero": "hero_13", "cell": Vector2i(2, 3), "hp": 10, "max_hp": 40,
		"atk": 3, "eatk": 3, "move": 3, "emove": 3, "atk_range": 1, "atk_type": 0,
		"skills": [DataRegistry.Skill.TAUNT], "name": "肉盾独脚龟", "row": row_bottom }
	var core := { "fn": P, "hero": "hero_22", "cell": Vector2i(3, 4), "hp": 9, "max_hp": 40,
		"atk": 4, "eatk": 4, "move": 3, "emove": 3, "atk_range": 1, "atk_type": 0,
		"skills": [], "name": "核心圣光", "row": row_bottom }
	var descs: Array = [me, tank, core]
	print("PLAN|cfg|我方=战锤(eatk10,贴脸可一击打死两者) 目标0=肉盾独脚龟(hp10+嘲讽) 目标1=核心圣光(hp9)")
	# 注释：set_weights({}) **不会**清掉 w_hero_value（空 = 回内置默认表），所以要测"关闭核心识别"
	# 必须**显式注入全 1.0**，不能用空表。
	var all1 := {}
	for hid in DataRegistry.heroes.keys():
		all1[String(hid)] = 1.0
	_plan_core_try(descs, { "HERO_VALUE": all1 }, "关闭核心识别(注入全1.0)")
	_plan_core_try(descs, null, "开内置默认表(圣光1.35/独脚龟0.90)")
	# 再按"噩梦.json 里实际写的那段"注入一次，证明"文件里写什么就是什么"
	var from_json := { "HERO_VALUE": { "hero_22": 1.35, "hero_13": 0.90, "hero_25": 1.05 } }
	_plan_core_try(descs, from_json, "按权重文件注入(同噩梦.json)")
	await _teardown()
	get_tree().quit(0)

## table = {} → 全 1.0；table = null → 用内置默认表
func _plan_core_try(descs: Array, table, label: String) -> void:
	var ai = FORK.new(_b.grid)
	ai.difficulty = 2
	ai.log_decisions = false
	ai.time_budget_ms = 0
	if table != null:
		ai.set_weights(table)
	var sim = ai.build_state(descs, {}, {}, {}, {}, {}, {})
	var plan: Array = ai.search(sim, DataRegistry.Faction.ENEMY)
	var tgt := -1
	for step in plan:
		var a: Dictionary = step.get("action", {})
		if a.has("atk") and int(a["atk"]) >= 0:
			tgt = int(a["atk"])
			break
	var tname := "无攻击" if tgt < 0 else String(descs[tgt]["name"])
	var v1 := ai._unit_value(ai.build_state(descs, {}, {}, {}, {}, {}, {}).units[1])
	var v2 := ai._unit_value(ai.build_state(descs, {}, {}, {}, {}, {}, {}).units[2])
	print("PLAN|%s|首选目标=%d(%s)|肉盾value=%.2f|核心value=%.2f" % [label, tgt, tname, v1, v2])
	print("PLAN|%s|当前圣光系数=%.2f 独脚龟系数=%.2f" % [label, ai._hero_value("hero_22"), ai._hero_value("hero_13")])

# ===================== 场景挑选 =====================
func _select(mode: String) -> Array:
	if mode == "special":
		return _cases()
	if mode.begins_with("hero_"):
		return _generic_for(mode)
	var out: Array = []
	if mode == "all" or mode == "":
		out.append_array(_cases())
	for sc in _generic_cases():
		match mode:
			"all", "":
				out.append(sc)
			"snap":
				if sc.has("hook"):
					out.append(sc)
			"act":
				if not sc.has("hook"):
					out.append(sc)
			"ext":
				if String(sc.get("fam", "")) == "ext":
					out.append(sc)
			_:
				pass
	return out

# ===================== 通用场景：每个英雄 × 各触发时机 =====================
## 为什么是"一族一钩子"：技能钩子分几类触发时机 —— 自己出招(on_attack*)、自己移动(on_move)、
## 自己被攻击(受伤/反击后钩子)、自己阵亡(on_died)、替补登场(on_enter)、回合边界(on_turn_start/end)。
## 每个英雄各跑一遍，就能覆盖绝大多数技能。
## 注意：通用场景只覆盖"无条件触发"的技能；带条件的（古拉博士需目标血高于自己、塔盾需相邻队友…）
## 要么靠专门布局的族（双队友/多敌/击杀…），要么靠 _cases() 里的针对性场景，所以几种一起跑。
func _generic_cases() -> Array:
	var out: Array = []
	for hid in _hero_ids():
		out.append_array(_generic_for(hid))
	return out

func _hero_ids() -> Array:
	var ids: Array = []
	for id in DataRegistry.heroes.keys():
		var d = DataRegistry.heroes[id]
		if d == null:
			continue
		if bool(d.is_summon):
			continue   # 召唤物不算英雄本体
		ids.append(String(id))
	ids.sort()
	return ids

## 一个英雄的全部场景族。布局说明见文件头的 C_* 常量。
## fam=base 是原有 5 个场景（出招/出招·距离2/移动/移动·远离/被攻击），fam=ext 是本次新增。
func _generic_for(hid: String) -> Array:
	# ---- 单位模板 ----
	var X := { "h": hid, "fn": E, "c": C_X, "wounded": true }
	var X2 := { "h": hid, "fn": E, "c": C_X2, "wounded": true }
	var Xf := { "h": hid, "fn": E, "c": C_X }                      # 满血版
	var Xdie := { "h": hid, "fn": E, "c": C_X, "hp": 1 }           # 1 血版（等死）
	var D := { "h": "hero_13", "fn": P, "c": C_D, "hp": 40, "max_hp": 40 }
	var D2 := { "h": "hero_13", "fn": P, "c": C_D2, "hp": 40, "max_hp": 40 }
	var Dlow := { "h": "hero_13", "fn": P, "c": C_D, "hp": 1, "max_hp": 40 }
	var A := { "h": "hero_13", "fn": E, "c": C_A, "hp": 5, "max_hp": 10 }    # 受伤队友
	var Af := { "h": "hero_13", "fn": E, "c": C_A, "hp": 8, "max_hp": 40 }   # 近乎满血队友（受击用）
	var DA := { "h": "hero_13", "fn": P, "c": C_DA, "hp": 40, "max_hp": 40 } # 打队友的敌人
	# ---- 负面来源（真的会 add_status 负面的英雄，见 heroes/*.gd）----
	var N_ATK := { "h": "hero_25", "fn": P, "c": C_D, "hp": 40, "max_hp": 40 }      # 战锤：麻痹+冰冻（同一次攻击两个负面）
	var N_POISON := { "h": "hero_03", "fn": P, "c": C_D, "hp": 40, "max_hp": 40 }   # 毒蛇淑女：猛毒
	var N_SILENCE := { "h": "hero_34", "fn": P, "c": C_NEG_FAR, "hp": 40, "max_hp": 40 } # 沉默术士：沉默（远程，需不被贴身）
	var N_POSSESS := { "h": "hero_46", "fn": P, "c": C_D, "hp": 40, "max_hp": 40 }  # 宿魂：附体（走 add_status 的负面）
	var N_HEAVY := { "h": "hero_12", "fn": P, "c": C_D, "hp": 40, "max_hp": 40 }    # 巨剑：重伤
	var N_THORN := { "h": "hero_49", "fn": P, "c": C_D, "hp": 40, "max_hp": 40 }    # 荆棘树人：荆棘
	var Xshield := { "h": hid, "fn": E, "c": C_X, "status": [StatusDB.SHIELD] }     # 带[圣盾]的 X（负墟专用）
	var obs_atk := {}       # 被直接攻击的 3 耐久障碍（OBSTACLE_DUR）
	obs_atk[C_OBS_ATK] = 3
	var obs_mv := {}        # 移动落点旁的 3 耐久障碍（烛火点燃用）
	obs_mv[C_OBS_MV] = 3
	var out: Array = [
		# ① 贴身出招：近战距离 1 命中（攻击后技能 on_attack 的主路径）
		{ "scene": "出招", "fam": "base", "hero": hid, "units": [X.duplicate(), D.duplicate()],
			"act": { "by": 0, "move": null, "atk": 1 } },
		# ② 距离 2 出招：远程英雄的正常命中路径（贴身位对远程是特例：降攻+技能失效）
		{ "scene": "出招·距离2", "fam": "base", "hero": hid, "units": [X2.duplicate(), D.duplicate()],
			"act": { "by": 0, "move": null, "atk": 1 } },
		# ③ 移动：落点 (1,3) —— **绕到假想敌另一侧，移动后仍与假想敌相邻**
		#    （烛火"伤害相邻敌人"/雪拳"冰冻相邻敌人"/医护兵"治疗相邻队友"都要求移动后相邻）
		{ "scene": "移动", "fam": "base", "hero": hid, "units": [X.duplicate(), D.duplicate()],
			"act": { "by": 0, "move": C_NEAR, "atk": -1 } },
		# ④ 移动·远离：原"移动"几何（落点 (2,5)，移动后与假想敌距离变 2）——保留作对照，
		#    验证"移动后相邻技在不相邻时确实不触发"（旧结果里这一条正是被读成假绿的地方）
		{ "scene": "移动·远离", "fam": "base", "hero": hid, "units": [X.duplicate(), D.duplicate()],
			"act": { "by": 0, "move": C_FAR, "atk": -1 } },
	]
	# ④b/④c 【RL 修正】"移动 + 出招"复合场景：远程被贴状态是**按当前位置**算的
	# （真实 src/Unit.gd effective_atk()：有敌人紧邻时基础攻击压为 1；Battle 在移动后
	#  `_sync_ranged_adjacent()` 重算，见 _do_move 里"先刷远程被贴状态，再触发移动后技能"）。
	# 上面 ①②③④ 全是"只移动"或"只出招"，**没有一条同时移动又出招**，所以
	# "移动改变了被贴状态、而 AI 模拟仍按移动前的攻击力算伤害"这个缺口从来没被测到。
	# ④b：起点贴身（快照 eatk=1）→ 退到 2 格外再打 → 真实解除被贴、伤害=正常攻击。
	# ④c：起点不贴身（快照 eatk=基础攻）→ 贴上去打 → 真实被贴、伤害压为 1。
	# 只对远程英雄加这两条：贴身压攻是远程专属规则，近战跑这两条没有意义（且距离 2 的近战攻击
	# 在真实侧本来就不该成立）。
	if (DataRegistry.heroes[hid] as DataRegistry.HeroDef).attack_type == DataRegistry.AttackType.RANGED:
		out.append({ "scene": "移动·远离后出招", "fam": "ext", "hero": hid,
			"units": [X.duplicate(), D.duplicate()],
			"act": { "by": 0, "move": C_FAR, "atk": 1 } })
		out.append({ "scene": "移动·贴近后出招", "fam": "ext", "hero": hid,
			"units": [X2.duplicate(), D.duplicate()],
			"act": { "by": 0, "move": C_NEAR, "atk": 1 } })
	# ④d/④e 【RL 修正】"移动 + 道具"复合场景：道具（圣诞老人那四种）是**一次性 buff**，
	# 真实侧 `effective_move()/effective_atk()` 是实时算的（`move_range + move_buff + move_use_buff`
	# / `base + atk_buff + ramble + sun + atk_use_buff`），捡到/消耗掉都会立刻改变派生值。
	# 模拟原来把 emove 当静态快照字段、把 atk_use_buff 当独立字段（进快照时 +1 已经含在 eatk 里），
	# 于是"移动中捡到道具"这一步两侧对不上——同一个"派生量不重算"家族（与 pins 同型）。
	# ④d：移动落点 (1,3) 放一个移速道具 → 真实捡到后 `move_use_buff=1`、本回合不被消耗
	#      （`_do_move` 只消耗"移动开始前就有的"那份）→ emove = 基础 +1。
	# ④e：移动落点放攻击道具 → 真实捡到后下一次攻击 +1（远程贴上去打时是 1 + 1 = 2）。
	# 这两条对**所有英雄**都成立（不像 pins 只对远程），所以不加 RANGED 门控。
	out.append({ "scene": "带道具·移动捡移速", "fam": "ext", "hero": hid,
		"units": [X.duplicate(), D.duplicate()], "items": { C_NEAR: "move" },
		"act": { "by": 0, "move": C_NEAR, "atk": -1 } })
	out.append({ "scene": "带道具·移动捡攻击后出招", "fam": "ext", "hero": hid,
		"units": [X2.duplicate(), D.duplicate()], "items": { C_NEAR: "atk" },
		"act": { "by": 0, "move": C_NEAR, "atk": 1 } })
	# ④e2 【RL 修正】四类增益道具在**移动落点**上的完整覆盖（真实 `_finish_move` →
	# `_pickup_buff_at_cell(u)`：该格道具**从盘面消失** + 立刻生效）。
	# 原来只测了 atk / move 两类，圣盾与回血在移动路径上没被钉住（用户实机报过
	# "真实踩到道具挂上盾、模拟没挂"）。这里补齐 shield / heal；
	# dump 里的 `items` 字段同时验证"道具真的被消耗"（不是只记了 buff_taken 的钱）。
	out.append({ "scene": "带道具·移动捡圣盾", "fam": "ext", "hero": hid,
		"units": [X.duplicate(), D.duplicate()], "items": { C_NEAR: "shield" },
		"act": { "by": 0, "move": C_NEAR, "atk": -1 } })
	out.append({ "scene": "带道具·移动捡回血", "fam": "ext", "hero": hid,
		"units": [X.duplicate(), D.duplicate()], "items": { C_NEAR: "heal" },
		"act": { "by": 0, "move": C_NEAR, "atk": -1 } })
	# ④e3 **经过**道具格但不停在上面：真实只在路径终点拾取（`_pickup_buff_at_cell` 只在
	# `_finish_move` 调一次）→ 道具必须**留在盘面上**。
	# 几何：(2,4) → (1,3) → (1,2)，道具放在 (1,3)（必经），落点 (1,2) 无道具。
	out.append({ "scene": "带道具·经过道具不拾取", "fam": "ext", "hero": hid,
		"units": [X.duplicate(), D.duplicate()], "items": { C_NEAR: "shield" },
		"act": { "by": 0, "move": Vector2i(1, 2), "atk": -1 } })
	# ④m 【RL 修正】烛火绕障碍的**方位**与**无相邻敌人**两条分支：
	# 真实 heroes/hero_17_烛火.gd 的注释明确写着"无相邻敌人时也要烧障碍"，
	# 而 `sweep_obstacles_around(cell) = 该格 + 6 个邻居` 是全场方位。
	# 原来的 `带障碍·移动后相邻` 只覆盖了 (1,3) 落点 + (1,2) 障碍这一个方位，且当时有相邻敌人；
	# 多物种扫描里报出的 (2,4)/(3,3)/(1,3) 等方位需要补上（先确认是矩阵漏方位，还是相邻判定口径不同）。
	# ④m1：落点 (1,3)，障碍放在 (0,3)（另一个方位），**仍有**相邻敌人 D(2,3)。
	# ④m2：落点 (1,3)，障碍放在 (0,3)，**没有**相邻敌人（D 挪到 (2,2)，不在 (1,3) 的邻居里）。
	var obs_mv2 := {}
	obs_mv2[Vector2i(0, 3)] = 3
	out.append({ "scene": "带障碍·移动后相邻(另一方位)", "fam": "ext", "hero": hid,
		"units": [X.duplicate(), D.duplicate()], "obs": obs_mv2.duplicate(),
		"act": { "by": 0, "move": C_NEAR, "atk": -1 } })
	out.append({ "scene": "带障碍·移动后无相邻敌人", "fam": "ext", "hero": hid,
		"units": [X.duplicate(), { "h": "hero_13", "fn": P, "c": Vector2i(2, 2), "hp": 40, "max_hp": 40 }],
		"obs": obs_mv2.duplicate(),
		"act": { "by": 0, "move": C_NEAR, "atk": -1 } })
	# ④f 【RL 修正】"别人动、我被贴"：真实 `_sync_ranged_adjacent()` 是**全场**重算——
	# 敌方(或队友)走到我身边，也会把**我**的远程攻击力压成 1；移动者本人不是唯一受影响的人。
	# 这里让 P 方的 hero_13 从 (2,6) 走到 (2,5)（紧邻 X(2,4)），X 全程不动：
	# 真实 X 的 effective_atk 3→1，而"只刷新移动者"的实现会漏掉 X。
	# 实测出处：第三方检视器 seed4242 n=39 `hero_05#5有效攻p=3>a=1`（当时是移动者之外的单位被漏刷）。
	if (DataRegistry.heroes[hid] as DataRegistry.HeroDef).attack_type == DataRegistry.AttackType.RANGED:
		out.append({ "scene": "他动·贴上来(远程被压)", "fam": "ext", "hero": hid,
			"units": [X.duplicate(), { "h": "hero_13", "fn": P, "c": Vector2i(2, 6), "hp": 40, "max_hp": 40 }],
			"act": { "by": 1, "move": Vector2i(2, 5), "atk": -1 } })
	# ④f2 【RL 修正】**阵容维度**：`技能对拍` 的被测英雄 X 恒为 E 方、场上只有 hero_13 当陪练，
	# 于是"需要**同阵营见证者**在场"的跨单位机制一直没被覆盖 —— 最典型的是锤头鲨(hero_37)：
	# 真实 `hero_37_锤头鲨.gd::on_someone_damaged` 的触发条件是"**我方回合**内敌人受伤"，
	# 而 sim 是在攻击分支里扫同阵营的 hero_37 给 `eatk += 1`（`_evaluate` 的即时账）。
	# 这条场景在 X 之外再放一个**同阵营的锤头鲨见证者**：X 打 D → 见证者的有效攻应当 +1。
	out.append({ "scene": "阵容·同阵营锤头鲨见证", "fam": "ext", "hero": hid,
		"units": [X.duplicate(), { "h": "hero_37", "fn": E, "c": C_A, "hp": 40, "max_hp": 40 }, D.duplicate()],
		"act": { "by": 0, "move": null, "atk": 2 } })
	# ④f3 【RL 修正】**每回合状态**场景（真实 Unit.counter_used_this_turn）：
	# 普通单位每回合只能反击一次；"本回合已经反击过"必须能带进每招重建的 sim，
	# 否则会出现"模拟以为还能反击、真实已经没名额"。实测出处（用户实机）：赏金猎人(hero_20)
	# 本回合已反击过 → 鼠队长(hero_04) 再打它真实 0 反击；模拟扣了 1 点 → `血量 预测14→实际15`。
	# ④n：D(hero_13) 已反击过 → X 打它应当**拿不到反击**。
	# ④o：D 换成复仇者(hero_23) —— 它的 `infinite_counter()` 是例外，已反击过**仍然反**（注入后必须仍成立）。
	out.append({ "scene": "每回合状态·对方已反击过", "fam": "ext", "hero": hid,
		"units": [X.duplicate(), { "h": "hero_13", "fn": P, "c": C_D, "hp": 40, "max_hp": 40, "counter_used": true }],
		"act": { "by": 0, "move": null, "atk": 1 } })
	out.append({ "scene": "每回合状态·复仇者已反击过仍反", "fam": "ext", "hero": hid,
		"units": [X.duplicate(), { "h": "hero_23", "fn": P, "c": C_D, "hp": 40, "max_hp": 40, "counter_used": true }],
		"act": { "by": 0, "move": null, "atk": 1 } })
	# ⑤c 【RL 修正】**阵容维度（跨英雄联动）**——被测英雄 X 之外再放一个**有机制的同场单位**：
	# ⑤c1 塔盾护第三人：X 打 D，而 D 旁边站着 D 方的塔盾(hero_11) → 真实 `_bulwark_absorb` 由**第三方**顶 1 点
	#      （塔盾 -1 血、D 少掉 1 点）。原矩阵只在"X 自己是塔盾 / X 的队友挨打"两个方向覆盖过。
	# ⑤c2 圣光一次只给一个盾：X 一次动作里有两个 D 方单位受伤（散射/剑气/击退/移动 AOE 等），
	#      同阵营的圣光(hero_22) **每回合只给一个盾** → 第一个伤者拿盾、第二个没有。
	# ⑤c3 移动伤害 + 圣光：X 用"移动后伤害"打伤 D 方的低血单位 → 圣光应当**在那条路上**也给盾
	#      （批次1 修过"直击/移动伤害也要触发圣光"，这条是它的回归守门场景）。
	# ⑤c4 击杀死灵法师 → 他召唤的骷髅一起消散（真实 hero_33::on_died；召唤物不立碑、不计胜负死亡数）。
	out.append({ "scene": "阵容·塔盾护第三人", "fam": "ext", "hero": hid,
		"units": [X.duplicate(), D.duplicate(), { "h": "hero_11", "fn": P, "c": Vector2i(2, 2), "hp": 40, "max_hp": 40 }],
		"act": { "by": 0, "move": null, "atk": 1 } })
	out.append({ "scene": "阵容·圣光一次只给一个盾", "fam": "ext", "hero": hid,
		"units": [X.duplicate(), D.duplicate(), D2.duplicate(), { "h": "hero_22", "fn": P, "c": Vector2i(1, 5), "hp": 40, "max_hp": 40 }],
		"act": { "by": 0, "move": null, "atk": 1 } })
	out.append({ "scene": "阵容·移动伤害+圣光", "fam": "ext", "hero": hid,
		"units": [X.duplicate(), Dlow.duplicate(), { "h": "hero_22", "fn": P, "c": Vector2i(2, 2), "hp": 40, "max_hp": 40 }],
		"act": { "by": 0, "move": C_NEAR, "atk": -1 } })
	out.append({ "scene": "阵容·击杀死灵法师骷髅消散", "fam": "ext", "hero": hid,
		"units": [Xf.duplicate(), { "h": "hero_33", "fn": P, "c": C_D, "hp": 1, "max_hp": 40 }],
		"summon": 1, "act": { "by": 0, "move": null, "atk": 1 } })
	# ④g 【RL 修正】"落停引爆"：真实规则是"经过不炸、**落停引爆**"——
	# `_bomb_enter_check` 只在路径终点判定 → `_explode_bomb_at(cell, u)`：炸弹格清除 +
	# 落停者吃 `Battle.BOMB_DAMAGE = 5`（非攻击伤害：坚固不减、圣盾照挡；炸弹人免疫）。
	# 模拟原来只把炸弹格从"落点候选"里剔除（_move_cells），**落地那一下的爆炸与伤害完全没建模**，
	# 于是 AI 以为"踩上去没事"（评分层靠 BOMB_STAND_PENALTY 兜一点，但血量/阵亡层面算不出来）。
	# 落点用 C_FAR(2,5)，把炸弹放在那里：X 从 (2,4) 走过去落停即引爆。
	out.append({ "scene": "带炸弹·落停引爆", "fam": "ext", "hero": hid,
		"units": [X.duplicate(), D.duplicate()], "bombs": [C_FAR],
		"act": { "by": 0, "move": C_FAR, "atk": -1 } })
	# ④h/④i/④j/④k 【RL 修正】**强制位移落到炸弹格也会引爆**（真实 `Battle._trigger_bomb`）：
	# 真实在 击退 `_knockback` / 换位 `_swap_units`（双方各一次）/ 拉人 `_pull_to` /
	# 暗域占格 `_occupy_dead_cell` / 影丸随机步 / 召唤骷髅落点 之后都会调它。
	# 模拟原来只在"移动落停"那条路引爆，于是 AI 以为"把人推到炸弹上"没有代价。
	# ④h 击退（超新星 hero_21 会把**目标相邻的同阵营单位**推离目标一格）：
	#     D(2,3) 旁的 V(2,2) 被推到 (2,1)，那里放了炸弹 → 真实 V 吃 5 点、炸弹清空。
	# ④i 击退（长角 hero_32 推的是**目标本体**）：不放 V，(2,3)→(2,1) 一路无阻挡 → 目标落到炸弹上。
	# ④j 拉人（血锁 hero_41）：X 在 (2,5)、D 在 (2,2)，被拉到 X 面前最近的一格 (2,4) = 炸弹格。
	# ④k 换位（暗域 hero_27）：炸弹预置在**目标脚下**——真实里 `bomb_cell_ok` 不允许炸弹落到人脚下，
	#     这条属于"把规则本身钉住"的人造局面（两侧都按同一条规则结算）。
	var V := { "h": "hero_13", "fn": P, "c": Vector2i(2, 2), "hp": 40, "max_hp": 40 }
	out.append({ "scene": "带炸弹·击退落炸弹", "fam": "ext", "hero": hid,
		"units": [X2.duplicate(), D.duplicate(), V.duplicate()], "bombs": [Vector2i(2, 1)],
		"act": { "by": 0, "move": null, "atk": 1 } })
	out.append({ "scene": "带炸弹·击退目标落炸弹", "fam": "ext", "hero": hid,
		"units": [X.duplicate(), D.duplicate()], "bombs": [Vector2i(2, 2)],
		"act": { "by": 0, "move": null, "atk": 1 } })
	out.append({ "scene": "带炸弹·拉人落炸弹", "fam": "ext", "hero": hid,
		"units": [X2.duplicate(), { "h": "hero_13", "fn": P, "c": Vector2i(2, 2), "hp": 40, "max_hp": 40 }],
		"bombs": [Vector2i(2, 4)],
		"act": { "by": 0, "move": null, "atk": 1 } })
	out.append({ "scene": "带炸弹·换位落炸弹", "fam": "ext", "hero": hid,
		"units": [X.duplicate(), D.duplicate()], "bombs": [C_D],
		"act": { "by": 0, "move": null, "atk": 1 } })
	# ④l 【RL 修正】"被贴标记过期"：真实 `Unit.ranged_adjacent` 是**缓存标记**，
	# 击退/换位/拉人/召唤落点这些位移路径**不刷新**它，所以存在"人已贴身、eatk 仍按未贴身算"的过期窗口；
	# 该窗口里的攻击用旧攻击力，**攻击收尾 `_finish_attack` 才刷新**（实测 ctr3 #1：医护兵打完后有效攻 3→1）。
	# 这条用场景键 pin=false 复现：X 与 D(2,3) 本来相邻，但把 X 的标记强行置为"未贴身"（= 过期态）。
	if (DataRegistry.heroes[hid] as DataRegistry.HeroDef).attack_type == DataRegistry.AttackType.RANGED:
		out.append({ "scene": "被贴标记过期·出招", "fam": "ext", "hero": hid,
			"units": [{ "h": hid, "fn": E, "c": C_X, "pin": false }, D.duplicate()],
			"act": { "by": 0, "move": null, "atk": 1 } })
	out.append_array([
		# ⑤ 被攻击：敌方出手，测受伤/反击后钩子（复仇者反击 2 倍等）。
		#    注意：这里的假想敌 hero_13 **不带任何负面攻击**，所以它**测不到**负墟的
		#    "免疫负面 + 每次负面 +1 攻"——那两条要靠下面 ⑤b 的「负面·」族（真让会挂负面的英雄去打）。
		{ "scene": "被攻击", "fam": "base", "hero": hid, "units": [X.duplicate(), D.duplicate()],
			"act": { "by": 1, "move": null, "atk": 0 } },
		# ⑤b 负面族：由**真的会 add_status 负面的英雄**出手打 X（负面来源逐个真实英雄：
		#    战锤=麻痹+冰冻两个负面同一次攻击、毒蛇淑女=猛毒、沉默术士=沉默(远程)、宿魂=附体）。
		#    负墟(hero_44)在这四个场景里应当：不挂任何负面、攻击力 +1（同一次攻击多个负面只 +1）；
		#    其它英雄则正常吃到负面（用于验证 sim 的负面挂载与负墟免疫两条路径）。
		{ "scene": "负面·战锤(麻痹+冰冻)", "fam": "ext", "hero": hid,
			"units": [Xf.duplicate(), N_ATK.duplicate()],
			"act": { "by": 1, "move": null, "atk": 0 } },
		{ "scene": "负面·毒蛇猛毒", "fam": "ext", "hero": hid,
			"units": [Xf.duplicate(), N_POISON.duplicate()],
			"act": { "by": 1, "move": null, "atk": 0 } },
		{ "scene": "负面·沉默术士(远程)", "fam": "ext", "hero": hid,
			"units": [Xf.duplicate(), N_SILENCE.duplicate()],
			"act": { "by": 1, "move": null, "atk": 0 } },
		{ "scene": "负面·宿魂附体", "fam": "ext", "hero": hid,
			"units": [Xf.duplicate(), N_POSSESS.duplicate()],
			"act": { "by": 1, "move": null, "atk": 0 } },
		{ "scene": "负面·巨剑重伤", "fam": "ext", "hero": hid,
			"units": [Xf.duplicate(), N_HEAVY.duplicate()],
			"act": { "by": 1, "move": null, "atk": 0 } },
		{ "scene": "负面·荆棘树人", "fam": "ext", "hero": hid,
			"units": [Xf.duplicate(), N_THORN.duplicate()],
			"act": { "by": 1, "move": null, "atk": 0 } },
		# ⑤b2 【RL 修正】"负面**挂上之后单位还要行动**"的复合场景（两动作）：
		#     上面 ⑤b 一族只验证"负面挂没挂上"，但真实 `effective_atk()/effective_move()` 是
		#     **实时重算**的，所以"挂上[麻痹]后这一击按 −1 攻结算""挂上[荆棘]后这次移动会被拒"
		#     属于另一条路径（用户实机撞到过字段层读不到 `SimUnit.atkdown` → 判定全错的假 DIFF）。
		#     act  = 负面来源打 X（真实 add_status + sim 挂状态）
		#     act2 = X 立刻出招（吃这条负面：麻痹按 −1 攻结算；荆棘只禁移动、不禁攻击）
		#     注：【荆棘禁移动】这条**不能**用"喂一个走位"来测 —— 真实 `_do_move` 会拒（emove=0），
		#     而 sim 的 `_apply` 是"执行 AI 自己搜出来的合法计划"，不做出招/走位复核，
		#     喂非法走位它会照做（这是 harness 边界，不是模拟差异，已登记）。
		#     荆棘对移动的压制靠 `emove/荆` 字段与 plan 层（`_actions_for` 不再产出 move）覆盖。
		{ "scene": "负面·麻痹后出招", "fam": "ext", "hero": hid,
			"units": [Xf.duplicate(), N_ATK.duplicate()],
			"act": { "by": 1, "move": null, "atk": 0 },
			"act2": { "by": 0, "move": null, "atk": 1 } },
		{ "scene": "负面·荆棘后出招", "fam": "ext", "hero": hid,
			"units": [Xf.duplicate(), N_THORN.duplicate()],
			"act": { "by": 1, "move": null, "atk": 0 },
			"act2": { "by": 0, "move": null, "atk": 1 } },
		# ⑥ 多敌·出招：D2 在 D 的"身后同一直线"上 —— 长剑穿透 / 超新星击退目标相邻敌人 /
		#    白游侠散射目标相邻敌人 / 长角"击退被 D2 挡住则 2 倍"
		{ "scene": "多敌·出招", "fam": "ext", "hero": hid,
			"units": [X.duplicate(), D.duplicate(), D2.duplicate()],
			"act": { "by": 0, "move": null, "atk": 1 } },
		# ⑦b 多敌·距离2出招：X 在 (2,5)（与 D 相隔 2，**不被贴身**）——
		#     远程英雄"被贴身则技能失效"这一门控不会生效，测的是技能的正向路径：
		#     超新星击退目标相邻敌人 / 白游侠散射目标相邻敌人 / 长剑穿透
		{ "scene": "多敌·距离2出招", "fam": "ext", "hero": hid,
			"units": [X2.duplicate(), D.duplicate(), D2.duplicate()],
			"act": { "by": 0, "move": null, "atk": 1 } },
		# ⑦c 双队友·移动后相邻：X 走到 (1,3)（同时紧邻假想敌 D 与受伤队友 A）——
		#    烛火/雪拳的"移动后相邻"真触发、医护兵治队友、末日打"HP 比你低的角色"
		{ "scene": "双队友·移动后相邻", "fam": "ext", "hero": hid,
			"units": [X.duplicate(), A.duplicate(), D.duplicate()],
			"act": { "by": 0, "move": C_NEAR, "atk": -1 } },
		# ⑧ 双队友·队友被攻击：敌方打 X 的相邻队友 —— 塔盾替邻扛伤 / 圣光给受伤队友套盾
		#    active=P：真实规则里圣光只在"敌方回合"护己方，故把行动方设成 P 阵营
		{ "scene": "双队友·队友被攻击", "fam": "ext", "hero": hid,
			"units": [Xf.duplicate(), Af.duplicate(), DA.duplicate()],
			"act": { "by": 2, "move": null, "atk": 1 }, "active": "P" },
		# ⑨ 击杀：假想敌压到 1 血被一击打死 —— 攻击后"目标已死"分支（暗域占格/长剑穿透/
		#    超新星击退/白游侠散射/沉默术士）与墓碑生成
		{ "scene": "击杀", "fam": "ext", "hero": hid,
			"units": [Xf.duplicate(), Dlow.duplicate(), D2.duplicate()],
			"act": { "by": 0, "move": null, "atk": 1 } },
		# ⑨b 宿魂·附体后受伤（两步）：X 先打 D 一次（挂上[附体]），再让 D 反打 X ——
		#     X 受伤时[附体]镜像才可见（被附体的 D 同受等量伤害）。
		{ "scene": "附体后受伤（两步）", "fam": "ext", "hero": hid,
			"units": [Xf.duplicate(), D.duplicate()],
			"act": { "by": 0, "move": null, "atk": 1 },
			"act2": { "by": 1, "move": null, "atk": 0 } },
		# ⑩ 阵亡：X 被压到 1 血后被打死，相邻同时有队友与敌人 —— 红帽扑街自爆（含伤队友）
		{ "scene": "阵亡", "fam": "ext", "hero": hid,
			"units": [Xdie.duplicate(), Af.duplicate(), D.duplicate()],
			"act": { "by": 2, "move": null, "atk": 0 } },
		# ⑪ 带障碍·攻击障碍：直接敲一块 3 耐久障碍 —— 伐木工额外 -99、障碍耐久字段
		{ "scene": "带障碍·攻击障碍", "fam": "ext", "hero": hid,
			"units": [Xf.duplicate()], "obs": obs_atk.duplicate(),
			"act": { "by": 0, "move": null, "atk": -1, "atk_obs": C_OBS_ATK } },
		# ⑫ 带障碍·移动后相邻：落点旁放障碍 —— 烛火"点燃相邻障碍"（技能波及障碍 -1 耐久）
		{ "scene": "带障碍·移动后相邻", "fam": "ext", "hero": hid,
			"units": [X.duplicate(), D.duplicate()],
			"obs": obs_mv.duplicate(),
			"act": { "by": 0, "move": C_NEAR, "atk": -1 } },
		# ⑫b 登场后出招（前提=真实登场）：先用真实的 `Battle._trigger_on_enter` 把登场技跑完
		#     （太阳斩 +3 攻 / 梅林换位 / 猎颅者眩晕…），**再从该局面建 Sim**，然后两边各打一次。
		#     验证的是"登场之后这一击"的动作层预测（例如太阳斩"每次攻击后 -1"的衰减）；
		#     Sim 并没有复现登场技本身，开头那次起点比对就是这条边界。
		{ "scene": "登场后出招（前提=真实登场）", "fam": "ext", "hero": hid,
			"units": [Xf.duplicate(), A.duplicate(), D.duplicate()],
			"act": { "by": 0, "move": null, "atk": 2 }, "pre": "enter" },
	])
	# ---- ⑤d 【RL 修正】"真实侧今日改动"的阵容/状态对照场景（逐条对齐 heroes/ 的新闸门）----
	# ① 圣光被[眩晕]时不发盾：真实 `skill_allowed()`=存活且未沉默且未眩晕；修复前 sim 只看 silenced
	#    → 会发出盾（DIFF），修复后两侧都不发（MATCH）。
	var G22 := { "h": "hero_22", "fn": E, "c": C_A, "hp": 40, "max_hp": 40, "status": [StatusDB.STUN] }
	out.append({ "scene": "阵容·圣光被眩晕不给盾", "fam": "ext", "hero": hid,
		"units": [Xf.duplicate(), G22.duplicate(), N_ATK.duplicate()],
		"act": { "by": 2, "move": null, "atk": 0 } })
	# ② 风语者被[沉默]时移动光环失效：真实 `grants_move_aura()` 返回 skill_allowed()。
	#    （sim 侧本来就同时判 silenced/stunned，本场景是把这条钉进矩阵。）
	#    注意：**hero_43 自己的那一遍不加这条场景** —— 那时场上会有两个风语者（移动者 X 与沉默的 G43），
	#    暴露出"移动者本人是否吃自己光环"这个尚未查清的问题（见 已知窄差异登记 §7），
	#    为了避免用一个未定论的规则去污染矩阵，只在别的英雄族里加这条。
	if true:   # sim 已对齐「另有风语者时本人也吃」，hero_43 自己那一遍也纳入
		var G43 := { "h": "hero_43", "fn": E, "c": C_A, "hp": 40, "max_hp": 40, "status": [StatusDB.SILENCE] }
		out.append({ "scene": "阵容·风语者被沉默不给回血", "fam": "ext", "hero": hid,
			"units": [X.duplicate(), G43.duplicate(), D.duplicate()],
			"act": { "by": 0, "move": C_NEAR, "atk": -1 } })
	if hid == "hero_01":
		# ③ 伐木工被[沉默]时拆墙退化：真实 `obstacle_damage()` 返回 1（修复前 sim 照给 +99 → 墙直接没）
		out.append({ "scene": "带障碍·被沉默拆墙", "fam": "ext", "hero": hid,
			"units": [{ "h": hid, "fn": E, "c": C_X, "status": [StatusDB.SILENCE] }, D.duplicate()],
			"obs": obs_atk.duplicate(), "act": { "by": 0, "move": null, "atk_obs": C_OBS_ATK } })
	if hid == "hero_47":
		# 【RL 修正】共鸣者：移动捡到攻击道具后出招 —— 真实 effective_atk() 在 echo 激活时直接 return，
		# 道具的 +1 **不生效**（修复前 sim 多算 1 点伤害：预测 14、实际 15）。
		# pre=begin 触发它自己的 on_side_turn_start，让 echo 生效后再做这一招。
		out.append({ "scene": "带道具·共鸣者移动捡攻击", "fam": "ext", "hero": hid,
			"units": [X2.duplicate(), A.duplicate(), D.duplicate()], "items": { C_NEAR: "atk" },
			"act": { "by": 0, "move": C_NEAR, "atk": 2 }, "pre": "begin" })
	if hid == "hero_35":
		# ⑥ 炸弹人被[沉默]时不能放雷：真实 `can_place_bomb()/bomb_place_cells()` 受 skill_allowed 控制
		out.append({ "scene": "带状态·被沉默不放雷", "fam": "ext", "hero": hid,
			"units": [{ "h": hid, "fn": E, "c": C_X, "status": [StatusDB.SILENCE] }, D.duplicate()],
			"act": { "by": 0, "move": C_NEAR, "atk": -1 } })
	if hid == "hero_41":
		# ⑤ 血锁被[沉默]时钩爪射程退化到 1（真实 suppressed_attack_range）：距离 2 的目标打不到。
		# 期望：真实侧"动作未生效"→ SKIP；修复前 sim 会照打（DIFF）——DIFF→SKIP 就是修复证据。
		out.append({ "scene": "被沉默·钩爪够不到", "fam": "ext", "hero": hid,
			"units": [{ "h": hid, "fn": E, "c": C_X, "status": [StatusDB.SILENCE] },
				{ "h": "hero_13", "fn": P, "c": C_D2, "hp": 40, "max_hp": 40 }],
			"act": { "by": 0, "move": null, "atk": 1 } })
	if hid == "hero_22":
		# S1–S3：圣光盾"占位立即、发盾延后、帧末复查+名额退还"三条链路（真实语义见 heroes/hero_22_圣光.gd）。
		# S1 名额竞争：一招内两名同阵营单位同时受伤 → 只有第一次触发占位 → 只有一面盾。
		out.append({ "scene": "阵容·圣光名额竞争(一招两伤)", "fam": "ext", "hero": hid,
			"units": [{ "h": hid, "fn": E, "c": C_X, "hp": 40, "max_hp": 40 },
				{ "h": "hero_13", "fn": E, "c": C_A, "hp": 13, "max_hp": 40 },
				{ "h": "hero_13", "fn": E, "c": Vector2i(3, 3), "hp": 13, "max_hp": 40 },
				{ "h": "hero_31", "fn": P, "c": C_D, "hp": 18, "max_hp": 18 }],
			"act": { "by": 3, "move": C_D2, "atk": -1 } })
		# S2 触发时目标已有盾 → 不占名额：① 开场带盾、② 无盾，两人同时受伤 → 盾应落到 ②。
		out.append({ "scene": "阵容·圣光遇已有盾不占名额", "fam": "ext", "hero": hid,
			"units": [{ "h": hid, "fn": E, "c": C_X, "hp": 40, "max_hp": 40 },
				{ "h": "hero_13", "fn": E, "c": C_A, "hp": 13, "max_hp": 40, "status": [StatusDB.SHIELD] },
				{ "h": "hero_13", "fn": E, "c": Vector2i(3, 3), "hp": 13, "max_hp": 40 },
				{ "h": "hero_31", "fn": P, "c": C_D, "hp": 18, "max_hp": 18 }],
			"act": { "by": 3, "move": C_D2, "atk": -1 } })
		# S3（⑤b 可测子集，必做）：先触发占位的目标随后被打死 → 帧末复查失败 → 退还名额、不发盾；
		# 于是 act2 里另一名队友受伤时才用得上这个退还的名额（旧实现在 act 就消耗掉名额 → ② 拿不到盾 = DIFF）。
		# 布局要点（避免"死者在中间导致 units 收缩、act2 下标漂移"）：
		#   · 会被打死的只有**列表最后一位**（阵亡后 units 收缩，前面下标不漂）；
		#   · act2 由 **act 的同一个行动者**（末日，下标 2，永不阵亡）执行，目标下标 1 稳定；
		#   · ② 用 40 血（> 末日的 18）→ **不会被 AOE 命中**，只在 act2 挨打。
		out.append({ "scene": "阵容·圣光目标随后死亡不发盾", "fam": "ext", "hero": hid,
			"units": [{ "h": hid, "fn": E, "c": C_X, "hp": 40, "max_hp": 40 },
				{ "h": "hero_13", "fn": E, "c": C_D, "hp": 40, "max_hp": 40 },
				{ "h": "hero_31", "fn": P, "c": C_X2, "hp": 18, "max_hp": 18 },
				{ "h": "hero_13", "fn": E, "c": Vector2i(3, 3), "hp": 3, "max_hp": 40 }],
			"act": { "by": 2, "move": C_NEAR, "atk": -1 },
			"act2": { "by": 2, "move": null, "atk": 1 } })
	if hid == "hero_26":
		# 【RL 修正】移动者被[沉默]时 on_move 不派发（真实 Battle.gd:3742-3743）：
		# 被沉默的雪拳移到敌人旁边 → 邻居**不该**有[冻]、有效移不该降。
		out.append({ "scene": "雪拳·被沉默·移动后不冰冻", "fam": "ext", "hero": hid,
			"units": [{ "h": hid, "fn": E, "c": C_X, "status": [StatusDB.SILENCE] }, D.duplicate()],
			"act": { "by": 0, "move": C_NEAR, "atk": -1 } })
	if hid == "hero_17":
		# 【RL 修正】同上：被沉默的烛火移动后**不灼烧相邻敌人、也不点燃相邻障碍**。
		out.append({ "scene": "烛火·被沉默·移动后不灼烧", "fam": "ext", "hero": hid,
			"units": [{ "h": hid, "fn": E, "c": C_X, "status": [StatusDB.SILENCE] }, D.duplicate()],
			"obs": obs_mv.duplicate(), "act": { "by": 0, "move": C_NEAR, "atk": -1 } })
	# 【RL 修正】"已攻击 → 本回合已完成、不能再移动"两条护栏（真实 Battle.gd 的 _is_done 口径）。
	# 这两条**期望两侧都无动作**，判定是 SKIP（真实侧动作未生效）而非 MATCH；
	# 修复前模拟会照做 move（→ DIFF），修复后与真实同为无动作（→ SKIP）：DIFF→SKIP 即修复证据。
	out.append({ "scene": "已攻击单位移动被拒(双侧无动作)", "fam": "ext", "hero": hid,
		"units": [{ "h": hid, "fn": E, "c": C_X, "attacked": true }, D.duplicate()],
		"act": { "by": 0, "move": C_NEAR, "atk": -1 } })
	if hid == "hero_26":
		# 样本 B 的最小局面：雪拳本回合**已攻击** → 不该再移动，因此也不该冰冻相邻复仇者、
		# 不该出现落点/有效移变化（用户局 #18 那三行红就是这个根因）。
		out.append({ "scene": "已攻击单位移动后不冰冻", "fam": "ext", "hero": hid,
			"units": [{ "h": hid, "fn": E, "c": C_X, "attacked": true },
				{ "h": "hero_23", "fn": P, "c": C_D, "hp": 26, "max_hp": 26 }],
			"act": { "by": 0, "move": C_NEAR, "atk": -1 } })
	if hid == "hero_41":
		# 【RL 修正】真实 Battle._pull_to:4059-4061：位移后对**活着**的目标 _trigger_bomb + _pickup_buff_at_cell。
		# 本场景把被拉者的落点 (2,4) 摆成一个回血道具 → 道具应被消耗、被拉者 +3 血（允许溢出）。
		out.append({ "scene": "血锁·拉到道具格·道具被拾取", "fam": "ext", "hero": hid,
			"units": [X2.duplicate(), { "h": "hero_13", "fn": P, "c": Vector2i(2, 2), "hp": 30, "max_hp": 40 }],
			"items": { Vector2i(2, 4): "heal" }, "act": { "by": 0, "move": null, "atk": 1 } })
	# 【RL 修正】反击的那一击：真实 `take_damage(cdmg, false, true, ...)` + `Unit.gd:283` 的
	# `dmg = amount + (1 if has_status(HEAVY) else 0)`（**重伤 +1 无条件**）→ 受击者带[重伤]时应 = cdmg+1。
	out.append({ "scene": "反击·重伤目标+1", "fam": "ext", "hero": hid,
		"units": [{ "h": hid, "fn": E, "c": C_X, "status": [StatusDB.HEAVY] }, D.duplicate()],
		"act": { "by": 0, "move": null, "atk": 1 } })
	out.append({ "scene": "反击·无重伤对照", "fam": "ext", "hero": hid,
		"units": [X.duplicate(), D.duplicate()], "act": { "by": 0, "move": null, "atk": 1 } })
	# 【RL 修正】反击伤害**也是攻击伤害** → [坚固](SOLID) 照样 −1。
	# 真实 `Unit.take_damage(amount, ignore_shield, counter, cause, is_attack)` 的第 5 参在反击处
	# 就是 `true`（src/Battle.gd:3433），而 `Unit.gd:284` 的 `if has_status(SOLID) and is_attack`
	# 决定了这一减。模拟原来把反击的 `is_attack` 传成 false → 打装甲堡垒(hero_48) 时**多算 1 点**
	# （用户局实测：`装甲堡垒(hero_48)#2 血量 预测15→实际16`、`预测13→实际14`）。
	# 本场景给被测英雄 X 挂 [坚固]，让它被 D 的反击打一下：期望两侧都只掉 cdmg−1。
	out.append({ "scene": "反击·坚固目标-1", "fam": "ext", "hero": hid,
		"units": [{ "h": hid, "fn": E, "c": C_X, "status": [StatusDB.SOLID] }, D.duplicate()],
		"act": { "by": 0, "move": null, "atk": 1 } })
	if hid == "hero_18":
		# 【RL 修正】剑气穿过障碍物：真实 `src/Battle.gd:4069-4091` `_pierce_line` 末尾有
		# `sweep_obstacles(swept)` —— 剑气扫过的障碍**各 −1 耐久**（技能对敌人生效时波及到的障碍要掉耐久）。
		# 几何：X(2,4) 打 D(2,3)，障碍放在 D 身后同一直线 (2,2)=C_D2 上（耐久 3 → 期望两侧都变 2）。
		out.append({ "scene": "剑气扫过障碍·耐久-1", "fam": "ext", "hero": hid,
			"units": [X.duplicate(), D.duplicate()], "obs": { C_D2: 3 },
			"act": { "by": 0, "move": null, "atk": 1 } })
	if hid == "hero_40":
		# 【RL 修正】红帽阵亡自爆**闸门**：真实 `hero_40_红帽.gd:8` 在被[沉默]/[眩晕]时不触发
		# （fork 侧 `_sim_on_died` 的 `if t.silenced or t.stunned: return` 与之对齐）。
		# 本场景 = 红帽(X) 带[沉默]、1 血、身边同时有队友与敌人，被敌人打死 →
		# 真实应当**不炸**（队友与敌人都毫发无损）；模拟若照炸就是缺口。
		# 对照组已存在：通用 `阵亡` 场景（不带沉默，红帽自爆伤到相邻单位）。
		out.append({ "scene": "红帽·被沉默阵亡·不自爆", "fam": "ext", "hero": hid,
			"units": [{ "h": hid, "fn": E, "c": C_X, "hp": 1, "max_hp": 40, "status": [StatusDB.SILENCE] },
				A.duplicate(), D.duplicate()],
			"act": { "by": 2, "move": null, "atk": 0 } })
	if hid == "hero_31":
		# 【忠实复现】末日·共鸣者同盘(echo 激活)：照用户那一局的原成分摆位 ——
		#   我方(P)：烛火 hero_17 (13 血) @(1,4)、长角 hero_32 @(2,4)、共鸣者 hero_47 (13 血) @(3,3)
		#   敌方(E)：末日 hero_31 (15/18, 有效攻 4) @(2,3)、红帽 hero_40 (1 血) @(3,4)、战锤 hero_25 @(1,5)
		#   招式：末日 (2,3)→(2,2)（= C_D → C_D2）
		#   pre=begin 让**共鸣者自己回合开始**把 echo 生效（echo 值量级 = 队友攻击力之和），
		#   看 actor 行的 eatk 会不会被抬到 13、以及清单里 hero_47 的 echo= 是多少。
		out.append({ "scene": "末日·共鸣者同盘(echo 激活)", "fam": "ext", "hero": hid,
			"units": [
				{ "h": hid, "fn": E, "c": C_D, "hp": 15, "max_hp": 18 },
				{ "h": "hero_40", "fn": E, "c": Vector2i(3, 4), "hp": 1, "max_hp": 40 },
				{ "h": "hero_25", "fn": E, "c": Vector2i(1, 5), "hp": 40, "max_hp": 40 },
				{ "h": "hero_17", "fn": P, "c": C_A, "hp": 13, "max_hp": 40 },
				{ "h": "hero_32", "fn": P, "c": C_X, "hp": 40, "max_hp": 40 },
				{ "h": "hero_47", "fn": P, "c": Vector2i(3, 3), "hp": 13, "max_hp": 40 }],
			"act": { "by": 0, "move": C_D2, "atk": -1 }, "pre": "begin" })
		# 【确定性复现】末日·AOE 含阵亡：照用户那一局的机理去掉无关变量 ——
		#   出手者 末日(HP 高于所有目标) + **同阵营 1 血单位**（队友轮里会被打死 = 分叉触发点）
		#   + **两个 13 血敌对单位**（都应只掉 4 = 末日的有效攻，且都不该死）。
		# 若模拟让这两个 13 血单位掉 >4 或直接死 → 复现出"末日在受害者阵亡后把 AOE 重复结算/串值"。
		out.append({ "scene": "末日·AOE 含阵亡", "fam": "ext", "hero": hid,
			"units": [X.duplicate(),
				{ "h": "hero_13", "fn": E, "c": C_A, "hp": 1, "max_hp": 40 },
				{ "h": "hero_13", "fn": P, "c": C_D, "hp": 13, "max_hp": 40 },
				{ "h": "hero_13", "fn": P, "c": C_D2, "hp": 13, "max_hp": 40 }],
			"act": { "by": 0, "move": C_NEAR, "atk": -1 } })
		out.append({ "scene": "末日·AOE 不击杀", "fam": "ext", "hero": hid,
			"units": [X.duplicate(),
				{ "h": "hero_13", "fn": E, "c": C_A, "hp": 30, "max_hp": 40 },
				{ "h": "hero_13", "fn": P, "c": C_D, "hp": 13, "max_hp": 40 },
				{ "h": "hero_13", "fn": P, "c": C_D2, "hp": 13, "max_hp": 40 }],
			"act": { "by": 0, "move": C_NEAR, "atk": -1 } })
	if hid == "hero_43":
		# §7：【双风语者】移动者本人也吃光环（真实 `_another_windspeaker_exists()` 让"本人"成为发放者）。
		# 这条正是矩阵自己抓到的那条 DIFF；修好后必须 MATCH。
		out.append({ "scene": "双风语者·移动者本人回血", "fam": "ext", "hero": hid,
			"units": [X.duplicate(),
				{ "h": "hero_43", "fn": E, "c": C_A, "hp": 14, "max_hp": 14 },
				D.duplicate()],
			"act": { "by": 0, "move": C_NEAR, "atk": -1 } })
	if hid == "hero_48":
		# ④ 装甲堡垒[坚固]按时清：真实改成"自己回合开始总执行"里清（on_own_turn_start_always）
		out.append({ "scene": "SNAP·坚固回合初清", "fam": "ext", "hero": hid,
			"units": [{ "h": hid, "fn": E, "c": C_X, "status": [StatusDB.SOLID] },
				A.duplicate(), D.duplicate()],
			"act": {}, "hook": "begin" })
	# ---- 英雄专属场景：负墟(hero_44) 的两条只对它成立的规则 ----
	if hid == "hero_44":
		# ⑯ 带[圣盾]被打：真实的顺序是"盾先挡下整次攻击 → 攻击附带的状态根本不进 add_status"
		#    （见 src/Unit.gd take_damage 与 Battle._add_status_msg 的 _shield_block_status），
		#    所以这一条应当**不 +1 攻**（盾被白扣一次，换来的不是成长）。
		out.append({ "scene": "负墟·圣盾时不+1攻", "fam": "ext", "hero": hid,
			"units": [Xshield.duplicate(), N_ATK.duplicate()],
			"act": { "by": 1, "move": null, "atk": 0 } })
		# ⑰ 回合末回落（SNAP）：前提 = 真实被战锤打一次（攻击力 +1 记账），
		#    然后真实走一次我方回合结束（_clear_statuses 把 atk_buff 清零）——
		#    验证"持续到我方回合结束"这一半，以及回合末局面能否被快照完整带入。
		out.append({ "scene": "负墟·回合末回落", "fam": "ext", "hero": hid,
			"units": [Xf.duplicate(), N_ATK.duplicate()],
			"act": { "by": 1, "move": null, "atk": 0 }, "hook": "end" })
	# ---- 英雄专属场景：血锁(hero_41) 的钩爪拖拽 ----
	# 【RL 修正】规则变更（用户批准）：一击**致死也照拉**——真实闸门是 `Battle._trigger_on_attack`
	# 按目标存活与否分派：活人 → `hero_41::on_attack`，**致死 → `hero_41::on_attack_dead`**，
	# 两者共用 `_pull_with_hook(target)`（只去掉 `on_attack` 里的存活守卫是没用 的）。
	# 亡者被拖到血锁面前那格，墓碑按死亡淡出后的 `u.cell` 写，所以**碑立在被拖到的格子**上
	# （原格不留碑）；亡者不引爆炸弹、不拾道具（`_pull_to` 对已死目标跳过这两个副作用）。
	# 几何：X(血锁) 在 C_X2=(2,5)、目标在 (2,2)，同列直线距离 3 → 拉近落点 (2,4)。
	# 说明：真实侧这条改动的落地时间可能晚于模拟侧；在它落地前，本场景会报 1 条 DIFF
	# （真实没拉、模拟拉了），**属于预期**，不是回归。
	if hid == "hero_41":
		out.append({ "scene": "血锁·致死拉尸", "fam": "ext", "hero": hid,
			"units": [X2.duplicate(), { "h": "hero_13", "fn": P, "c": Vector2i(2, 2), "hp": 1, "max_hp": 40 }],
			"act": { "by": 0, "move": null, "atk": 1 } })
		out.append({ "scene": "血锁·活人拉近", "fam": "ext", "hero": hid,
			"units": [X2.duplicate(), { "h": "hero_13", "fn": P, "c": Vector2i(2, 2), "hp": 40, "max_hp": 40 }],
			"act": { "by": 0, "move": null, "atk": 1 } })
	if hid == "hero_22":
		# 【RL 修正】"同一击里被沉默的圣光"不发盾。真实 `hero_22_圣光.gd::on_someone_damaged` 只在
		# 受伤那一刻占位，真正的发盾是 `call_deferred()`（下一帧）并在 grant 里**再判一次**
		# `unit.skill_allowed()`；沉默术士(hero_34) 的沉默由 `_trigger_on_attack`（src/Battle.gd:3365）
		# 在**伤害之后**才挂上 → 下一帧发盾时圣光已不能发 → 退还名额、**不发盾**。
		# 模拟原来在本笔伤害结算处就 flush（沉默还没落账）→ 多发一面盾（用户局实测：
		# `圣光(hero_22)#1 状态[盾] 预测是→实际否`）。几何：沉默术士放 (2,2)（与圣光距离 2、
		# 自己不被贴身），圣光在 (2,4) 属非行动方（默认 active=E）→ 满足圣光触发条件。
		out.append({ "scene": "同一击被沉默·不发盾", "fam": "ext", "hero": hid,
			"units": [{ "h": "hero_34", "fn": E, "c": C_NEG_FAR },
				{ "h": "hero_22", "fn": P, "c": C_X }],
			"act": { "by": 0, "move": null, "atk": 1 } })
	# ---- 英雄专属场景：古灵精怪(hero_28) 变成负墟后同样免疫负面 ----
	if hid == "hero_28":
		out.append({ "scene": "古灵精怪·变身后免疫负面", "fam": "ext", "hero": hid,
			"units": [Xf.duplicate(), { "h": "hero_44", "fn": E, "c": C_A, "hp": 20, "max_hp": 20 },
				N_ATK.duplicate()],
			"act": { "by": 2, "move": null, "atk": 0 }, "pre": "t44" })
	# ⑬⑭⑮ 回合边界 / 登场：**快照层**（SNAP）——真实跑一次回合切换或登场钩子，
	# 再用"该真实局面"重建 Sim 逐字段比。AI 的模拟只模拟本回合内我方行动，
	# 回合开始/结束技根本不在模拟范围内，所以这里**不**声称"模拟复现了回合技"。
	var snap_units := [Xf.duplicate(), A.duplicate(), D.duplicate(), D2.duplicate()]
	out.append({ "scene": "SNAP·回合开始", "fam": "ext", "hero": hid,
		"units": snap_units.duplicate(true), "act": {}, "hook": "begin" })
	out.append({ "scene": "SNAP·回合结束", "fam": "ext", "hero": hid,
		"units": snap_units.duplicate(true), "act": {}, "hook": "end" })
	out.append({ "scene": "SNAP·登场", "fam": "ext", "hero": hid,
		"units": snap_units.duplicate(true), "act": {}, "hook": "enter" })
	# ⑯ SNAP·回合循环：先让 X 真打一次（造成伤害 → 锤头鲨等"我方回合内敌人受伤"的账目 +1），
	#    再走完整的"我方回合结束 → 对方回合 → 回到我方回合开始"循环（跨回合到期的账目在这里结算），
	#    最后比"真实局面 vs 用该局面重建的 Sim"。同样只是**快照层**验证。
	out.append({ "scene": "SNAP·回合循环", "fam": "ext", "hero": hid,
		"units": snap_units.duplicate(true), "act": { "by": 0, "move": null, "atk": 2 }, "hook": "cycle" })
	# ---- 替补登场（真实 Battle.gd:4338 → 4388 `_place_enemy_sub` → 4561 `_free_sub_cell_for`）----
	# 这是原来整条链路的盲区：模拟只知道"阵亡 → 立墓碑"，不知道"同一动作窗口内该方还会补一个人进来、
	# 落点首选**自己的墓碑格**（顶掉墓碑）并触发 on_enter。两个场景都把替补席塞进真实 Battle
	# （场景键 enemy_roster）并关掉双控（`_is_manual_sub_faction`：双控下敌方也要玩家手点，
	# 单机口径下敌方是 AI **自动**补位 —— 那才是要被模拟预测的那条路径）。
	if hid == "hero_16":
		# ① 落位顶碑：E 侧 hero_13(1 血) 打 P 侧 hero_13 被反击打死 → 墓碑先立在 (2,4)，
		#    替补 hero_29 随即落位到 (2,4) → 墓碑被 `_place_enemy_sub` 清掉、新单位带登场效果（太阳斩 +3 攻）。
		out.append({ "scene": "替补·落位顶掉墓碑", "fam": "ext", "hero": hid,
			"units": [{ "h": "hero_13", "fn": E, "c": C_X, "hp": 1, "max_hp": 40 }, D.duplicate()],
			"enemy_roster": ["hero_29"],
			"act": { "by": 0, "move": null, "atk": 1 } })
		# ② 登场效果：替补 = 波盾(hero_16) → `on_enter` 令**己方在场全体**（含它自己、含远处 (2,5) 那只
		#    hero_25）获得[圣盾]。远处那只用来证明"全队"而不是"只给新来的人"。
		out.append({ "scene": "替补·波盾登场给己方全体圣盾", "fam": "ext", "hero": hid,
			"units": [{ "h": "hero_13", "fn": E, "c": C_X, "hp": 1, "max_hp": 40 }, D.duplicate(),
				{ "h": "hero_25", "fn": E, "c": C_X2, "hp": 40, "max_hp": 40 }],
			"enemy_roster": ["hero_16"],
			"act": { "by": 0, "move": null, "atk": 1 } })
		# ③ 替补·按打分选人：把"选谁"这件事也钉住（真实 `Battle._best_enemy_sub_idx()`，见
		#    AI_Battle.gd 的 `_sim_best_sub_idx`）。场景要点：**替补席第 1 张不是该选的那张**。
		#    roster = [圣光(hero_22, 嘲讽, atk2/hp21), 塔盾(hero_11, 嘲讽, atk1/hp40)]：
		#      · 基础分：圣光 2*1.6+21*0.9=22.1 ／ 塔盾 1*1.6+40*0.9=37.6 → 塔盾本来就高；
		#      · 场上此刻**没有任何嘲讽**（E 侧只有 1 血伐木工 hero_01、P 侧只有独脚龟 hero_28），
		#        所以两张候选都吃到"缺前排坦克 +11" → 塔盾 48.6 > 圣光 33.1；
		#      · 真实 `_place_enemy_sub` 于是不会 pop 第 1 张（圣光）而 pop 塔盾 → 落位单位=塔盾；
		#      · 改前模拟写死 `pool[0]` → 上圣光（且圣光 `on_enter` 不给盾、塔盾也没有）→ 落位单位不同 → DIFF；
		#        改后模拟照同一个打分函数选 → 选到塔盾=真实 → MATCH。
		#    注意两张都带<嘲讽>是有意的：这样"选谁"只由**分数**决定，不牵扯 on_enter 效果差异。
		out.append({ "scene": "替补·按打分选人", "fam": "ext", "hero": hid,
			"units": [{ "h": "hero_01", "fn": E, "c": C_X, "hp": 1 },
				{ "h": "hero_28", "fn": P, "c": C_D, "hp": 40, "max_hp": 40 }],
			"enemy_roster": ["hero_22", "hero_11"],
			"act": { "by": 1, "move": null, "atk": 0 } })
		# ④ 替补·落位顶碑并贴身远程：复现用户实测那一招的两个字段差异来源
		#    （`墓碑@(0,4) 预测有→实际无` + `超新星(hero_21) 有效攻 预测3→实际1`）。
		#    几何：P 侧独脚龟(hero_28)@(2,3) 一击打死 E 侧 1 血太阳斩(hero_29)@(2,4) →
		#      · E 侧墓碑立在 (2,4)；
		#      · `_free_sub_cell_for` 优先**本方墓碑格** → 替补直接落 (2,4) 并把墓碑顶掉；
		#      · 落位单位紧邻 P 侧远程 超新星(hero_21)@(1,4)（六边形邻居）→ 真实 `_sync_ranged_adjacent`
		#        把它的有效攻压成 1，即"远程被贴身"；模拟侧要在同一位置放同一个单位才算出同样的 1。
		#      · 原 roster 只放 1 张，避免"选谁"再引入一条变量（那条由 ③ 单独测）。
		out.append({ "scene": "替补·落位顶碑并贴身远程", "fam": "ext", "hero": hid,
			"units": [{ "h": "hero_29", "fn": E, "c": C_X, "hp": 1 },
				{ "h": "hero_28", "fn": P, "c": C_D, "hp": 40, "max_hp": 40 },
				{ "h": "hero_21", "fn": P, "c": C_A, "hp": 40, "max_hp": 40 }],
			"enemy_roster": ["hero_11"],
			"act": { "by": 1, "move": null, "atk": 0 } })
	return out

# ===================== 场景定义 =====================
## units: 英雄/阵营/格/可选 hp、max_hp；act: 谁对谁做什么（move 为空即只攻击）
## 额外的场景键：
##   obs: {格: 耐久} 障碍；items: {格: 类型} 增益道具（"gold"=金矿）
##   active: "P" 把行动方设成玩家阵营（圣光/锤头鲨这类看"是不是敌方回合"的技能要用）
##   enemy_roster / player_roster: [英雄 id] → 把真实 Battle 的替补席塞成这些（替补场景用；见 _setup）
##   hook: "begin"/"end"/"enter" → 该场景是快照层（SNAP），act 不参与
func _cases() -> Array:
	return [
		{ "scene": "对照·普通攻击", "units": [
				{ "h": "hero_13", "fn": E, "c": Vector2i(1, 3) },
				{ "h": "hero_06", "fn": P, "c": Vector2i(1, 4) } ],
			"act": { "by": 0, "move": null, "atk": 1 } },
		{ "scene": "对照·普通移动", "units": [
				{ "h": "hero_06", "fn": E, "c": Vector2i(1, 3) } ],
			"act": { "by": 0, "move": Vector2i(1, 4), "atk": -1 } },
		{ "scene": "塔盾替邻扛伤(hero_11)", "units": [
				{ "h": "hero_12", "fn": E, "c": Vector2i(1, 3) },
				{ "h": "hero_13", "fn": P, "c": Vector2i(1, 4) },
				{ "h": "hero_11", "fn": P, "c": Vector2i(1, 5) } ],
			"act": { "by": 0, "move": null, "atk": 1 } },
		{ "scene": "古拉博士攻击回血(hero_14)", "units": [
				{ "h": "hero_14", "fn": E, "c": Vector2i(1, 3), "hp": 5, "max_hp": 10 },
				{ "h": "hero_13", "fn": P, "c": Vector2i(1, 4), "hp": 9, "max_hp": 9 } ],
			"act": { "by": 0, "move": null, "atk": 1 } },
		{ "scene": "炸弹人移动布雷(hero_35)", "units": [
				{ "h": "hero_35", "fn": E, "c": Vector2i(1, 3) },
				{ "h": "hero_13", "fn": P, "c": Vector2i(1, 1) } ],
			"act": { "by": 0, "move": Vector2i(1, 4), "atk": -1 } },
		{ "scene": "风语者·队友移动回血(hero_43)", "units": [
				{ "h": "hero_43", "fn": E, "c": Vector2i(1, 3) },
				{ "h": "hero_13", "fn": E, "c": Vector2i(1, 4), "hp": 5, "max_hp": 10 } ],
			"act": { "by": 1, "move": Vector2i(1, 5), "atk": -1 } },
		{ "scene": "太阳斩·连击衰减(hero_29)", "units": [
				{ "h": "hero_29", "fn": E, "c": Vector2i(1, 3) },
				{ "h": "hero_13", "fn": P, "c": Vector2i(1, 4), "hp": 30, "max_hp": 30 } ],
			"act": { "by": 0, "move": null, "atk": 1 } },
	]

# ===================== 单个场景 =====================
func _run_case(sc: Dictionary) -> Dictionary:
	var scene := String(sc["scene"]) if sc.has("scene") else String(sc["name"])
	var tag := scene
	if sc.has("hero"):
		tag = "%s·%s" % [String(sc["hero"]), scene]
	await _setup(sc)
	if _setup_bad != "":
		await _teardown()
		return { "verdict": "SETUP", "diffs": [_setup_bad], "tag": tag, "scene": scene, "layer": "setup" }
	if sc.has("hook"):
		return await _run_snap(sc, tag, scene)
	return await _run_act(sc, tag, scene)

## 动作层：同一动作分别走真实结算与 AI 模拟，逐字段比对
func _run_act(sc: Dictionary, tag: String, scene: String) -> Dictionary:
	# 有"前提"的场景（pre=enter）：先让真实侧把前提跑完（替补登场派发点），**之后**才建 sim。
	# 于是 sim 的起点就是"前提已完成"的真实局面；起点照样逐字段比对（对不上报 SETUP）。
	# 注意：这条不声称"模拟复现了前提技能"，只验证前提之后那次动作的预测。
	if sc.has("pre"):
		await _call_hook(String(sc["pre"]))
		if _b != null and is_instance_valid(_b):
			_b.turn_time_left = 0.0
			_b._turn_expired = false
		await _drain()
	# sim 必须在"真实动作之前"就建好（它只吃动作前的快照），之后两边各走各的：
	# 真实结算作用于 Battle，模拟作用于这份 sim。若在真实动作之后再建 sim，
	# 就会把动作重复应用一次（真实掉 2 血、模拟掉 4 血 —— 对照组会立刻暴露）。
	var sim = _build_sim()
	var start_real := _dump_real()
	var start_sim := _dump_sim(sim)
	var setup_diffs := _diff_of(start_real, start_sim)
	if not setup_diffs.is_empty():
		# 起始局面两边就对不上：属于场景构造问题（不是技能模拟差异），单独报出来
		await _teardown()
		return { "verdict": "SETUP", "diffs": setup_diffs, "tag": tag, "scene": scene, "layer": "setup" }

	# ① 真实结算（可选两步：act 之后再来一个 act2 —— "先挂[附体]、再让宿魂受伤"这类
	#    需要前置动作才看得见的效果，单动作场景测不到）
	var act: Dictionary = sc.get("act", {})
	var by_i := int(act.get("by", 0))
	await _run_real_action(act)
	if sc.has("act2"):
		await _run_real_action(sc["act2"])
	var end_real := _dump_real()

	# ② AI 模拟（同一动作序列，作用在动作前建好的那份 sim 上）
	var sa1 := _sim_action_of(act)
	if not sa1.is_empty():
		FORK.new(_b.grid)._apply(sim, by_i, sa1)
	if sc.has("act2"):
		var a2: Dictionary = sc["act2"]
		var sa2 := _sim_action_of(a2)
		if not sa2.is_empty():
			FORK.new(_b.grid)._apply(sim, int(a2.get("by", 0)), sa2)
	var end_sim := _dump_sim(sim)

	var diffs := _diff_of(end_real, end_sim)
	# 真实侧"动作完全没生效"时（例如射程不够、后勤不能主动攻击、落点被占），
	# 差异多半来自场景前提而不是模拟错误：标 SKIP 单独计数（**不算验证通过**）。
	var real_noop := _same_dump(start_real, end_real)
	var v := "MATCH"
	var layer := "act"
	if real_noop:
		v = "SKIP"
		layer = "act-noop"
		diffs = ["真实侧动作未生效（局面逐字段无变化）"]
	elif not diffs.is_empty():
		v = "DIFF"
	var out := { "verdict": v, "diffs": diffs, "tag": tag, "scene": scene, "layer": layer,
		"delta": _delta_str(start_real, end_real), "sim_delta": _delta_str(start_sim, end_sim) }
	await _teardown()
	return out

## 快照层（SNAP）：真实跑一次回合一侧的开始/结束，或一次替补登场派发，
## 然后用**这个真实局面**重建 Sim，逐字段比"真实局面 vs AI 视野里的局面"。
## 验证的是"技能成果有没有被 BattleSnapshot/build_state 完整带进 AI 的视野"，不是"模拟复现了技能"。
func _run_snap(sc: Dictionary, tag: String, scene: String) -> Dictionary:
	var before := _dump_real()
	# 快照场景也可以带一个"前提动作"（真实侧先打一次，制造跨回合账目等前提）
	var act: Dictionary = sc.get("act", {})
	var pre_delta := ""
	var post_delta := ""
	var mid := before
	if not act.is_empty():
		await _run_real_action(act)
		# 前提动作本身的变化也留证（否则"先吃了 +1 攻、回合末又回落"这种一进一出在看最终快照时是隐形的）
		mid = _dump_real()
		pre_delta = _delta_str(before, mid)
	await _call_hook(String(sc["hook"]))
	# 回合切换可能把回合交给"本端可操作方"并重新开始 90 秒倒计时：置 0 关掉超时自动结束回合，
	# 否则后面排帧期间会自己 submit_end_turn 再切一次回合，把快照污染掉。
	if _b != null and is_instance_valid(_b):
		_b.turn_time_left = 0.0
		_b._turn_expired = false
	await _drain()
	var after := _dump_real()
	if not act.is_empty():
		post_delta = _delta_str(mid, after)
	# "钩子是否真的做了事"：有前提动作时看"钩子前后"（前提动作的位移/掉血不算钩子的功劳）
	if _same_dump(mid, after):
		# 该英雄没有这一时机的技能（或条件不成立）：真实侧无事发生 → SKIP，不当成"对齐证据"
		await _teardown()
		return { "verdict": "SKIP", "diffs": ["真实侧钩子未生效：局面逐字段无变化（该时机无技能/条件不成立）"],
			"tag": tag, "scene": scene, "layer": "snap-noop", "delta": "" }
	var sim = _build_sim()
	var sd := _dump_sim(sim)
	var diffs := _diff_of(after, sd)
	var v := "SNAP"
	if not diffs.is_empty():
		v = "DIFF"
	var out := { "verdict": v, "diffs": diffs, "tag": tag, "scene": scene, "layer": "snap",
		"delta": _delta_str(before, after), "pre_delta": pre_delta, "post_delta": post_delta }
	await _teardown()
	return out

## 跑真实的回合边界/登场钩子（派发点与 src/Battle.gd 一致）
func _call_hook(h: String) -> void:
	match h:
		"begin":
			await _b._begin_side(GameState.SIDE_ENEMY)   # 被测英雄所在阵营（E）的回合开始
		"end":
			await _b._end_side(GameState.SIDE_ENEMY)     # 该阵营回合结束（内部会接着开对方回合）
		"enter":
			# 替补登场的真实派发点（src/Battle.gd `_trigger_on_enter`）；units[0] 即场景里的 X。
			# 不弹替补面板、不走 UI 流程：这里测的是"登场技本身 + 它的成果能否进快照"。
			if _b.units.size() > 0:
				_b._trigger_on_enter(_b.units[0])
		"cycle":
			# 跨回合：我方(E)回合结束（含回合末技能与临时状态清理）→ 走真实 _begin_side(P)
			# → 再开我方(E)下个回合开始（跨回合到期的账目在此结算）。
			await _b._end_side(GameState.SIDE_ENEMY)
			await _b._begin_side(GameState.SIDE_ENEMY)
		"t44":
			# 古灵精怪变身成负墟：走真实的 Battle._transform(unit, picked_override)
			# （picked_override 是它自带的测试用指定变身入口；无 override 时随机选）。
			# 场景里必须有一个 hero_44 队友当候选，否则 _transform 的候选集为空、直接 return。
			if _b.units.size() > 0:
				_b._transform(_b.units[0], "hero_44")
		_:
			pass

## 场景动作 → AI 模拟的动作字典（键名与 AI_Battle._apply 一致）
func _sim_action_of(act: Dictionary) -> Dictionary:
	var out := {}
	if act.get("move", null) != null:
		out["move"] = act["move"]
	var sa := int(act.get("atk", -1))
	if sa >= 0:
		out["atk"] = sa
	if act.get("atk_obs", null) != null:
		out["atk_obs"] = act["atk_obs"]
	return out

## 跑一次真实动作（移动 / 攻击 / 攻击障碍）并等演出结算完
func _run_real_action(act: Dictionary) -> void:
	if act.is_empty():
		return
	var by_i := int(act.get("by", 0))
	var u_by = _b.units[by_i]
	if act.get("move", null) != null:
		await _act(func() -> void: _b._do_move(u_by, act["move"], true))
	if int(act.get("atk", -1)) >= 0:
		var ti := int(act["atk"])
		if ti >= 0 and ti < _b.units.size():
			var t = _b.units[ti]
			if is_instance_valid(t) and t.alive:
				await _act(func() -> void: _b._do_attack(u_by, t, true))
	if act.get("atk_obs", null) != null:
		# 攻击障碍：2026-09-23 起 _do_attack_obstacle(u, cell, true) 也会 emit action_finished
		# （以前不发，只能靠超时兜底）。这里仍用排帧 _drain() 等演出结算 —— 与它的 _do_attack(..., true) 同款口径。
		_b._do_attack_obstacle(u_by, act["atk_obs"], true)
	await _drain()

## 比对两份 dump，返回差异列表（最多 12 条）
func _diff_of(a: Dictionary, b: Dictionary) -> Array:
	var out: Array = []
	for k in a.keys():
		var va = a[k]
		var vb = b.get(k, null)
		if typeof(va) == TYPE_DICTIONARY:
			var ka: Array = (va as Dictionary).keys()
			var kb: Array = (vb as Dictionary).keys() if typeof(vb) == TYPE_DICTIONARY else []
			ka.sort()
			kb.sort()
			if ka != kb:
				out.append("%s: 键集不同 真实=%s AI模拟=%s" % [k, str(ka), str(kb)])
				continue
			for uk in ka:
				if str(va[uk]) != str((vb as Dictionary)[uk]):
					out.append("%s[%s]: 真实=%s | AI模拟=%s" % [k, uk, str(va[uk]), str((vb as Dictionary)[uk])])
		elif str(va) != str(vb):
			out.append("%s: 真实=%s | AI模拟=%s" % [k, str(va), str(vb)])
		if out.size() >= 12:
			break
	return out

## 整份 dump 是否逐字段完全相同（用于"真实侧有没有生效"的判断）
func _same_dump(a: Dictionary, b: Dictionary) -> bool:
	if a.size() != b.size():
		return false
	for k in a.keys():
		if not b.has(k):
			return false
		if str(a[k]) != str(b[k]):
			return false
	return true

## 两个 dump 之间的"字段变化"摘要（给 SK|EV| 证据行用；只列变了的部分）
func _delta_str(a: Dictionary, b: Dictionary) -> String:
	var parts: Array = []
	for k in a.keys():
		var va = a[k]
		var vb = b.get(k, null)
		if typeof(va) == TYPE_DICTIONARY:
			var kb: Array = (vb as Dictionary).keys() if typeof(vb) == TYPE_DICTIONARY else []
			var ka: Array = (va as Dictionary).keys()
			ka.sort()
			kb.sort()
			for uk in kb:
				if not (va as Dictionary).has(uk):
					parts.append("%s+%s=%s" % [k, uk, str((vb as Dictionary)[uk])])
			for uk in ka:
				if not (vb as Dictionary).has(uk):
					parts.append("%s-%s" % [k, uk])
				elif str(va[uk]) != str((vb as Dictionary)[uk]):
					parts.append("%s[%s]:%s→%s" % [k, uk, str(va[uk]), str((vb as Dictionary)[uk])])
		elif str(va) != str(vb):
			parts.append("%s:%s→%s" % [k, str(va), str(vb)])
	var s := " ; ".join(parts)
	if s.length() > 700:
		s = s.substr(0, 700) + "…"
	return s

# ===================== 建局 =====================
func _setup(sc: Dictionary) -> void:
	Engine.time_scale = 20.0
	GameState.reset_online()
	GameState.dual_control = true
	GameState.no_death_limit = false
	GameState.arena_mode = false
	GameState.pick_deck_in_battle = false
	GameState.match_over = false
	GameState.round_number = 1
	GameState.clear_placement()
	var pd: Array = []
	var ed: Array = []
	var pc: Array = []
	var ec: Array = []
	for u in sc["units"]:
		if int(u["fn"]) == P:
			pd.append(String(u["h"]))
			pc.append(u["c"])
		else:
			ed.append(String(u["h"]))
			ec.append(u["c"])
	if pd.is_empty():
		pd = ["hero_13"]
		pc = [Vector2i(5, 6)]
	if ed.is_empty():
		ed = ["hero_13"]
		ec = [Vector2i(5, 1)]
	for i in pc.size():
		GameState.player_placement[pc[i]] = pd[i]
	for i in ec.size():
		GameState.enemy_placement[ec[i]] = ed[i]
	GameState.player_deck = pd.duplicate()
	GameState.enemy_deck = ed.duplicate()
	# 记录"我要求的落位"，setup 之后与真实落位对照（对不上就报 SETUP，
	# 避免把"我的布局没生效"误算成"AI 模拟与真实不一致"）
	# 记录"我要求的落位"：只取场景自己声明的单位（不含为了触发自由放置分支而塞的填充单位，
	# 那种填充单位在清空重建时不会生成，会被断言误报成"缺席"）
	_req = {}
	for u in sc["units"]:
		_req["%s@%s" % [String(u["h"]), str(u["c"])]] = true
	_req_player_raw = GameState.player_placement.duplicate()
	_req_enemy_raw = GameState.enemy_placement.duplicate()
	_b = load("res://scenes/Main.tscn").instantiate() as Battle
	_b.set_random_seed(4242)
	_b._first_side = GameState.SIDE_ENEMY
	get_tree().root.add_child(_b)
	var t0 := Time.get_ticks_msec()
	while _b.state != Battle.State.PLAYER_INPUT and Time.get_ticks_msec() - t0 < 30000:
		await get_tree().process_frame
	# 关键：建局成功后**清空棋盘再精确重建**（仓库测试里的标准做法 clear_all + spawn）。
	# 否则随机障碍/开局道具会干扰落位（实测出现过"要求 (2,3)、实际生成 (1,3)"），
	# 那种偏移会让后面的技能比对全部失真。
	for u in _b.units.duplicate():
		if is_instance_valid(u):
			u.queue_free()
	_b.units.clear()
	_b.occupancy.clear()
	_b.obstacles.clear()
	_b.buff_items.clear()
	_b.gold_left.clear()   # 金矿寿命账本：与 buff_items 一起清，否则上一局的矿会残留倒计时
	_b.bombs.clear()
	_b.graves.clear()
	_b.player_dead = 0
	_b.enemy_dead = 0
	for i in 12:
		await get_tree().process_frame
	# 按场景顺序精确重建（units 顺序 = sc["units"] 顺序，攻击者/目标下标才可靠）
	var _pin_overrides: Array = []
	for u in sc["units"]:
		var unit := _b._spawn_unit(String(u["h"]), int(u["fn"]), u["c"])
		if unit != null and u.has("max_hp"):
			unit.max_hp = int(u["max_hp"])
		if unit != null and u.has("hp"):
			unit.hp = int(u["hp"])
		elif unit != null and bool(u.get("wounded", false)):
			unit.hp = maxi(unit.max_hp - 3, 1)   # 压到"受伤"状态：触发"受伤才生效/血量比较"类条件
		if unit != null:
			unit.refresh_stats()
		if unit != null and u.has("status"):
			# 场景可预置状态（例：给负墟先套[圣盾]，验证"盾先挡下整次攻击 → 不给攻成长"）。
			# 走的是真实的 Unit.add_status，不是直接塞 statuses 字典。
			for s in u["status"]:
				unit.add_status(String(s))
			unit.refresh_stats()
		# 【RL 修正】场景可强制"远程被贴身"标记的缓存值（真实 Unit.set_ranged_adjacent）：
		# 用于复现"标记过期"窗口（人已贴身但标记还是 false，真实在击退/换位/拉人/召唤落点后不刷新它）。
		# 注意**必须放在全部单位生成之后**：`_spawn_unit`（真实 Battle 的"新单位上场"）会调
		# `_sync_ranged_adjacent()` 把标记刷成实时值，放在生成循环里会被后一个单位的生成冲掉。
		if u.has("pin"):
			_pin_overrides.append({ "unit": unit, "pin": bool(u["pin"]) })
		# 【RL 修正】场景可强制"每回合状态"（真实 Unit 的 moved_this_turn / attacked_this_turn /
		# counter_used_this_turn）：用于复现"本回合已经反击过 → 不能再反击"这类边界。
		if u.get("counter_used", false):
			unit.counter_used_this_turn = true
		if u.get("moved", false):
			unit.moved_this_turn = true
		if u.get("attacked", false):
			unit.attacked_this_turn = true
	for o in _pin_overrides:
		var pu = o["unit"]
		if pu != null and is_instance_valid(pu):
			pu.set_ranged_adjacent(bool(o["pin"]))
	# 地形：障碍（带耐久）/ 增益道具 / 金矿（带剩余回合）——默认全空，场景要才摆
	if sc.has("obs"):
		var obs: Dictionary = sc["obs"]
		for c in obs.keys():
			_b.obstacles[c] = int(obs[c])
	if sc.has("items"):
		var items: Dictionary = sc["items"]
		var gl: Dictionary = sc.get("gold_left", {})
		for c in items.keys():
			var t := String(items[c])
			_b.buff_items[c] = t
			if t == "gold":
				_b.gold_left[c] = int(gl.get(c, 3))
	# 【RL 修正】炸弹：场景键 bombs = [格, 格…]（预置炸弹，验"落停引爆"这类地形规则）。
	# 真实规则：经过不炸、**落停引爆**（src/Battle.gd `_bomb_enter_check` → `_explode_bomb_at`：
	# 炸弹格清除 + 落停者吃 Battle.BOMB_DAMAGE，炸弹人免疫）。
	if sc.has("bombs"):
		for c in sc["bombs"]:
			_b.bombs[c] = true
	# 【RL 修正】召唤：场景键 summon = <单位下标> —— 让该单位在开局就召唤一次骷髅兵
	# （走真实 `Battle._summon_skeletons`：落点是相邻空位、带 `summon_owner`、召唤格上的炸弹照常引爆）。
	# 用于覆盖"召唤物 × 墓碑/替补/死灵法师阵亡"这类跨单位交互。
	if sc.has("summon"):
		var si := int(sc["summon"])
		if si >= 0 and si < _b.units.size() and _b.units[si] != null and is_instance_valid(_b.units[si]):
			_b._summon_skeletons(_b.units[si])
			for i in 5:
				await get_tree().process_frame
			# 召唤出来的骷髅也计入"要求的落位"（否则下面的 setup 自检会报"单位数量不同"
			# ——那会把它误判成 SETUP，而它其实是本场景要测的对象）。
			for u2 in _b.units:
				if u2 != null and is_instance_valid(u2) and String(u2.hero_id) == "summon_skeleton":
					_req["%s@%s" % [String(u2.hero_id), str(u2.cell)]] = true
	_b._refresh_board()
	_b.turn_time_left = 0.0
	# 行动方：默认 = 建局时的先手方 E；场景可显式改成 P（"是不是敌方回合"类技能要用）
	if String(sc.get("active", "E")) == "P":
		GameState.active_side = GameState.SIDE_PLAYER
	else:
		GameState.active_side = GameState.SIDE_ENEMY
	# 【RL 修正】替补场景支持：把替补席塞进真实 Battle（真实 `_roster_of` / `_place_enemy_sub` 用它选人），
	# 并把"自由部署双控"关掉 —— 双控下敌方替补也要玩家手动点选（`_is_manual_sub_faction` 返回 true），
	# 而**单机口径**下敌方(AI)阵亡是自动补位（`_on_unit_died` → `_pending_enemy_sub += 1` →
	# 本回合内阵亡时立即 `_place_enemy_sub()`），这才是模拟要对齐的那条路径。
	# 注意放在"棋盘重建完成之后"：建局期的自由部署仍按双控走，不受影响。
	if sc.has("enemy_roster"):
		_b.enemy_roster = (sc["enemy_roster"] as Array).duplicate()
	if sc.has("player_roster"):
		_b.player_roster = (sc["player_roster"] as Array).duplicate()
	if sc.has("enemy_roster") or sc.has("player_roster"):
		GameState.dual_control = false
	# ---- setup 自检：真实落位必须与我要求的完全一致，否则后面所有比对都不可信 ----
	var actual := {}
	for u in _b.units:
		if u != null and is_instance_valid(u):
			actual["%s@%s" % [u.hero_id, str(u.cell)]] = true
	_setup_bad = ""
	if actual.size() != _req.size():
		_setup_bad = "单位数量不同 要求=%d 实际=%d" % [_req.size(), actual.size()]
	else:
		for k in _req.keys():
			if not actual.has(k):
				_setup_bad = "缺少要求的落位 %s" % k
				break
	if _setup_bad != "":
		print("SK|SETUP_DIFF|%s|req=%s|actual=%s|raw_p=%s|raw_e=%s" % [
			_setup_bad, str(_req.keys()), str(actual.keys()),
			str(_req_player_raw), str(_req_enemy_raw)])

func _find(hid: String, c: Vector2i) -> Unit:
	for u in _b.units:
		if u != null and is_instance_valid(u) and u.alive and u.hero_id == hid and u.cell == c:
			return u
	return null

func _teardown() -> void:
	Engine.time_scale = 1.0
	if _b != null and is_instance_valid(_b):
		_b.queue_free()
	_b = null
	await get_tree().process_frame
	await get_tree().process_frame

func _act(cb: Callable) -> void:
	var done: Array = [false]
	var h := func() -> void: done[0] = true
	_b.action_finished.connect(h, CONNECT_ONE_SHOT)
	cb.call()
	var n := 0
	while not done[0] and n < MAX_WAIT:
		n += 1
		await get_tree().process_frame
	if not done[0] and is_instance_valid(_b) and _b.action_finished.is_connected(h):
		_b.action_finished.disconnect(h)

func _drain() -> void:
	for i in 30:
		await get_tree().process_frame
	if _b != null and is_instance_valid(_b):
		await _b._drain_pending_deaths()
	for i in 5:
		await get_tree().process_frame

# ===================== 状态转储 =====================
func _dump_real() -> Dictionary:
	var units := {}
	for u in _b.units:
		if u == null or not is_instance_valid(u) or not u.alive:
			continue
		units["%s@%s" % [u.hero_id, str(u.cell)]] = "%d/%d|eatk=%d|emove=%d|%s" % [
			u.hp, u.max_hp, u.effective_atk(), u.effective_move(), _flags_real(u)]
	# 金矿：真实侧寿命记在 battle.gold_left（每完整回合 -1，GOLD_LIFE=3 回合后消失）
	var gold := {}
	var items := {}
	for c in _b.buff_items.keys():
		if _b.buff_items[c] == "gold":
			gold[str(c)] = int(_b.gold_left.get(c, 0))
		else:
			items[str(c)] = String(_b.buff_items[c])
	# 障碍：带耐久（不是只有格集合）——伐木工/清障/烛火点燃/剑气扫过都靠它才能观测
	var obs := {}
	for c in _b.obstacles.keys():
		obs[str(c)] = int(_b.obstacles[c])
	return {
		"units": units, "pd": _b.player_dead, "ed": _b.enemy_dead,
		"bombs": _keys(_b.bombs), "graves": _keys(_b.graves),
		"obstacles": obs, "gold": gold, "items": items,
	}

func _flags_real(u: Unit) -> String:
	var f: Array = []
	if u.has_status(StatusDB.SHIELD): f.append("盾")
	if u.has_status(StatusDB.HEAVY): f.append("重伤")
	if u.has_status(StatusDB.POISON): f.append("毒")
	if u.has_status(StatusDB.FREEZE): f.append("冰")
	if u.has_status(StatusDB.STUN): f.append("晕")
	if u.has_status(StatusDB.SILENCE): f.append("默")
	if u.has_status(StatusDB.POSSESS): f.append("附")
	if u.has_status(StatusDB.SOLID): f.append("固")
	# 【RL 修正】[麻痹]/[荆棘] 的存在性：真实 Unit 用 has_status 判定，
	# sim 侧对应 SimUnit.atkdown / .thorn（原先两侧都没列这两位 → 这一族状态不被比对，
	# 检视器字段层又去读不存在的字段 → 假 DIFF）。
	if u.has_status(StatusDB.ATKDOWN): f.append("麻")
	if u.has_status(StatusDB.THORN): f.append("荆")
	if u.moved_this_turn: f.append("已动")
	if u.attacked_this_turn: f.append("已攻")
	f.sort()
	return ",".join(f)

## 建 Sim。注意：金矿寿命在 BattleSnapshot 里只透传成 cell->true（sim 只做 .has() 判定），
## 这里把快照里的值换成真实剩余回合数，好让 dump 能逐字段比"金矿还剩几回合"。
## sim 本身**不建模**寿命倒计时（AI 只模拟本回合内行动，回合切换不在模拟范围内）。
## 【RL 修正】风语者(hero_43) 移动光环的"真实账本份数"：按**接收者 instance_id** 数出
## "本回合被几位存活风语者发过光环"（真实 `hero_43._aura_given` 只记真发过的队友：
## 中途 spawn / 被沉默时都没记 → 阵亡时真实一个都不减）。快照的 `emove` 只是合计、看不出这件事，
## 所以由 harness 注入 descs 键 `ws_aura`，模拟在风语者阵亡时据此收回 +1 移动力。
func _windspeaker_aura_counts() -> Dictionary:
	var out := {}
	if _b == null:
		return out
	for u in _b.units:
		if u == null or not is_instance_valid(u) or not u.alive:
			continue
		if String(u.hero_id) != "hero_43":
			continue
		var hb = _b._hero(u)
		if hb == null:
			continue
		var given = hb.get("_aura_given")
		if typeof(given) != TYPE_DICTIONARY:
			continue
		for k in (given as Dictionary).keys():
			out[k] = int(out.get(k, 0)) + 1
	return out

func _build_sim():
	var snap: Dictionary = BattleSnapshot.collect(_b)
	var gold: Dictionary = snap["gold"]
	for c in gold.keys():
		gold[c] = int(_b.gold_left.get(c, 0))
	# 【RL 修正】[坚固](hero_48 装甲堡垒)：src/BattleSnapshot.gd 的 unit_desc **不带**这个状态，
	# 于是 AI 视野里没有它（SNAP·回合结束 必报 DIFF）。BattleSnapshot 在 src/ 不可改，
	# 所以在 harness 侧建 Sim 之前把真实单位的 [坚固] 补进 descs（新增键 "solid"）。
	# fork 侧 SimUnit.solid / _sim_take_damage 会按真实语义使用（is_attack 时伤害 -1）。
	# 顺序与 snap["descs"] 一致（都取自 battle.units）。
	var descs: Array = snap["descs"]
	# 【RL 修正】风语者(hero_43) 移动光环的"真实账本"：本回合**真发过**光环的队友（真实
	# `hero_43._aura_given`，键=接收者 instance_id）。风语者阵亡时模拟要按它收回 +1 移动力，
	# 而快照里 `emove` 只是合计、看不出"谁真拿过" → 由这里注入 descs 键 `ws_aura`（份数）。
	var ws_counts := _windspeaker_aura_counts()
	if descs.size() == _b.units.size():
		for i in descs.size():
			var ru: Unit = _b.units[i]
			if ru != null and is_instance_valid(ru):
				descs[i]["solid"] = ru.has_status(StatusDB.SOLID)
				# 【RL 修正】移动道具的持有量（真实 Unit.move_use_buff，快照不带）：
				# sim 的 emove 现在按真实公式记账（移动消耗/捡到 +1），需要这个初值才能对齐。
				descs[i]["move_use_buff"] = ru.move_use_buff
				# 【RL 修正】一次性攻击道具的持有量（真实 Unit.atk_use_buff）：它属于 effective_atk()，
				# 快照 eatk 里已经含它；sim 要单列出来才能在攻击结算后正确扣掉。
				descs[i]["atk_use_buff"] = ru.atk_use_buff
				# 【RL 修正】[麻痹]/[荆棘] 的状态存在性（真实 Unit.has_status）：快照不带这两个键，
				# 由这里补进 descs（与 solid 同一手法）。sim 侧 SimUnit.atkdown/.thorn 读取它。
				# 【RL 修正】每回合限一次类技能的名额（真实 `Unit.once_this_turn`）：快照不带，由 harness
				# 注入 descs，sim 侧 `SimUnit.aura_used` 读取（缺省 false = 改动前行为）。
				descs[i]["once_this_turn"] = ru.once_this_turn
				descs[i]["atkdown"] = ru.has_status(StatusDB.ATKDOWN)
				descs[i]["thorn"] = ru.has_status(StatusDB.THORN)
				# 【RL 修正】远程"被贴身"是真实 Unit 的**缓存标记**（只在出生/切边/移动落位/反击前/
				# 攻击收尾/变身时刷新；击退/换位/拉人/召唤落点都不刷新 → 可能过期）。
				# sim 要如实建模这个"过期窗口"，所以把真实标记原样带进去。
				descs[i]["ranged_adjacent"] = ru.ranged_adjacent
				# 【RL 修正】风语者光环"真发过几份"（见上面 `ws_counts` 的说明）：
				# sim 侧 `SimUnit.ws_aura` 读取，风语者阵亡时只收回真发过的那一份。
				descs[i]["ws_aura"] = int(ws_counts.get(ru.get_instance_id(), 0))
				# 【RL 修正】**每回合状态**（真实 Unit 的 moved_this_turn / attacked_this_turn /
				# counter_used_this_turn）：检视器/对拍是"每招重建一份 sim"，不带这三个标志就会丢掉
				# "本回合已经反击过/已经出过手"。实测：已反击过的赏金猎人被鼠队长再打一次 →
				# 真实不给反击（名额已用）、模拟却扣了 1 点血。
				descs[i]["moved"] = ru.moved_this_turn
				descs[i]["attacked"] = ru.attacked_this_turn
				descs[i]["counter_used"] = ru.counter_used_this_turn
				# 【RL 修正】召唤物的主人（真实 Unit.summon_owner → 本快照里的下标）：
				# 死灵法师(hero_33) 阵亡时只让**自己召唤的**骷髅消散，所以要能分辨归属。
				var owner_i := -1
				if String(ru.summon_owner) != "":
					for k in _b.units.size():
						var ou: Unit = _b.units[k]
						if ou != null and is_instance_valid(ou) and String(ou.id) == String(ru.summon_owner):
							owner_i = k
							break
				descs[i]["owner"] = owner_i
	_ai_fork = FORK.new(_b.grid)
	_ai_fork.difficulty = 2
	_ai_fork.log_decisions = false
	# 【RL 修正】把**真实行动方阵营**传进 Sim：场景可以用 active="P" 把行动方设成玩家
	# （圣光/锤头鲨这类"看是不是敌方回合"的技能要靠它）。不传时 fork 缺省按"敌方自己行动"算，
	# 与生产路径（AI 只在敌方回合开始装快照做搜索）一致。
	var act_fn: int = _b.side_faction(GameState.active_side)
	# 第 9 参 rosters：【RL 修正】快照 "rosters" 键（用户已批准那一行）→ sim 才能预测
	# "本招打死人 → 该方替补登场"（真实 src/Battle.gd:4338 记名额 / 4388 落位）。
	# 第 10 参 auto_sub（本轮新增）：声明"哪一方的替补**不需要真人点选**、按什么规则选人"（见 AI_Battle.Sim.auto_sub）。
	# 本 harness 的替补场景显式关掉了双控（`_setup` 里 `GameState.dual_control = false`，见那段注释）
	# → 敌方(AI)阵亡由生产自己自动补位（`_on_unit_died` → `_pending_enemy_sub` → `_place_enemy_sub`），
	# 所以**敌方 = "score"**（生产打分，可预测）。玩家方在本 harness 里没有真人点选、也没有
	# `_auto_sub_on_timeout` 兜底，替补不会自行落位 → **不传**（= 不预测）。
	# 墓碑改用 `_grave_fns(...)`：把每座墓碑的**阵营**带进 sim（快照把它压成了 cell→true），
	# 模拟才能按真实口径判"这座碑是谁的"（本方墓碑格可落位 / 该方替补补完时清本方剩余墓碑）。
	return _ai_fork.build_state(descs, snap["occ"], snap["gold"], _grave_fns(snap["grave"]),
			snap["obstacle"], snap["bomb"], snap["buff"], act_fn, snap.get("rosters", {}),
			{ DataRegistry.Faction.ENEMY: "score" })


## 【RL 修正】墓碑的**阵营**要带进 sim：`BattleSnapshot.collect` 把真实 `battle.graves`
## （src 里本来就是 `{ "hero", "fn" }`，见 src/Battle.gd:3983 / 4297）压成 `cell → true`，
## 于是模拟只认得"这格有墓碑"、认不出**是谁的**墓碑，而真实两处都按阵营判：
##   · `_free_sub_cell_for(fn)`（src/Battle.gd:4561）：只挑**本方**墓碑格落位；
##   · `_clear_side_graves(fn)`（src/Battle.gd:4710，`_place_enemy_sub` 收尾:4408 调用）：只清**本方**墓碑。
## 这里按真实 `battle.graves` 重建一份带 fn 的（值形状与 sim 自己 `_sim_kill` 写入的一致）；
## 取不到 fn 的格保持原值（true = 阵营未知 → sim 侧保守不动）。
func _grave_fns(snap_grave: Dictionary) -> Dictionary:
	var out := {}
	for c in snap_grave.keys():
		out[c] = snap_grave[c]
	if _b == null or not is_instance_valid(_b):
		return out
	var live: Dictionary = _b.graves
	for c in live.keys():
		if not out.has(c):
			continue
		var gd = live[c]
		if typeof(gd) == TYPE_DICTIONARY:
			out[c] = {
				"hero": String((gd as Dictionary).get("hero", "")),
				"fn": int((gd as Dictionary).get("fn", -1)),
			}
	return out

func _dump_sim(sim) -> Dictionary:
	# 转储前先做一次"AI 视角"的刷新（_evaluate 每次都会做）：
	# 例如"远程被贴"的攻击力是按当前位置算的，原始字段可能还是快照值。
	if _ai_fork != null:
		_ai_fork._sim_sync_pins(sim)
	var units := {}
	for u in sim.units:
		if not u.alive:
			continue
		units["%s@%s" % [u.hero_id, str(u.cell)]] = "%d/%d|eatk=%d|emove=%d|%s" % [
			u.hp, u.max_hp, u.eatk, u.emove, _flags_sim(u)]
	var gold := {}
	for c in sim.gold_cells.keys():
		gold[str(c)] = int(sim.gold_cells[c])
	var items := {}
	for c in sim.buff_cells.keys():
		items[str(c)] = String(sim.buff_cells[c])
	var obs := {}
	for c in sim.obstacles.keys():
		obs[str(c)] = int(sim.obstacles[c])
	var pd := 0
	var ed := 0
	for u in sim.units:
		if not u.alive:
			# 【RL 修正】召唤物不计入胜负死亡数（与真实 `_on_unit_died` 的 `if not is_summon`
			# 以及 `battle.player_dead/enemy_dead` 口径一致）——否则骷髅消散会被算成"击杀"。
			if DataRegistry.summons.has(u.hero_id):
				continue
			if u.fn == E:
				ed += 1
			else:
				pd += 1
	return {
		"units": units, "pd": pd, "ed": ed,
		"bombs": _keys(sim.bombs), "graves": _keys(sim.graves),
		"obstacles": obs, "gold": gold, "items": items,
	}

func _flags_sim(u) -> String:
	var f: Array = []
	if u.shield: f.append("盾")
	if u.heavy: f.append("重伤")
	if u.poisoned: f.append("毒")
	if u.frozen: f.append("冰")
	if u.stunned: f.append("晕")
	if u.silenced: f.append("默")
	if u.possessed_by >= 0: f.append("附")
	# [坚固](SOLID)：src/BattleSnapshot.gd 不产出该字段，所以由 harness 在 _build_sim 里
	# 从真实单位补进 descs["solid"]，fork 侧 SimUnit.solid 读取（见 AI_Battle.build_state）。
	var solid = u.get("solid")
	if solid != null and bool(solid): f.append("固")
	# 【RL 修正】[麻痹](ATKDOWN) / [荆棘](THORN)：SimUnit 的真字段（由 harness 注入初值 +
	# 战锤/荆棘树人命中时在 sim 内挂上）。降攻数值仍走 atk_mod 记账，这里比的是"状态在不在"。
	var atkdown = u.get("atkdown")
	if atkdown != null and bool(atkdown): f.append("麻")
	var thorn = u.get("thorn")
	if thorn != null and bool(thorn): f.append("荆")
	if u.moved: f.append("已动")
	if u.attacked: f.append("已攻")
	f.sort()
	return ",".join(f)

func _keys(d: Dictionary) -> Array:
	var out: Array = []
	for k in d.keys():
		out.append(str(k))
	out.sort()
	return out

# ===================== 归类输出 =====================
func _note(r: Dictionary) -> void:
	var scene := String(r.get("scene", "?"))
	var v := String(r["verdict"])
	if v == "DIFF":
		_inc(_diff_by_scene, scene)
		for d in r["diffs"]:
			var k := String(d).split(":")[0]
			if k.begins_with("units["):
				k = "units(逐单位)"
			_inc(_diff_kinds, k)
	elif v == "SKIP" or v == "SETUP":
		_inc(_skip_by_scene, scene)

func _inc(d: Dictionary, k: String) -> void:
	d[k] = int(d.get(k, 0)) + 1

func _kind_str(d: Dictionary) -> String:
	var keys: Array = d.keys()
	keys.sort_custom(func(a, b): return int(d[a]) > int(d[b]))
	var out: Array = []
	for k in keys:
		out.append("%s=%d" % [String(k), int(d[k])])
	return "|".join(out)

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

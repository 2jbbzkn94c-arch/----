extends RefCounted
## 竞技场决策桥：把协议 `Observation` 还原成项目内部的 `BattleAI.Sim`，再用**项目自己的 AI**
## 选出协议 `legalActions` 里的一个 `actionId`。
##
## 三块职责：
##   ① **坐标**：协议 `(x,y)` ↔ 项目 `Vector2i`。项目盘 = `HexGrid.new(5,7)` + `top_cap_cols=[1,3]`
##      （偶列 x=0/2/4 占 y=1..6、奇列 x=1/3 占 y=0..6），协议 = 偶列 y=0..5、奇列 y=0..6
##      ⇒ 映射 `本地 = (x, y+1) 若 x 偶 / (x, y) 若 x 奇`（已按 32 格 + 150 条边穷举核对一致）。
##   ② **还原**：VisibleHero / barriers / envBuffs / bombs / goldCells → sim 的 descs 与地形字典。
##      协议不给的字段（moved/attacked/atk_buff 分量、墓碑归属、对手替补池）按最保守口径近似，
##      见每个 `_warn_once` 处的说明。
##   ③ **选动作**：游戏阶段走 `ai.search()` 的整回合计划，取计划里的下一步映射成协议的单个动作；
##      计划用完/映射不上时退化成"1 层评估"（对每个合法动作 clone 一份 sim、`_apply`、`_evaluate`）。
##      布阵 / 中途替补阶段（DEPLOY）没有"回合计划"可言，走 `pick_sub_hero/pick_sub_cell` 那套。

const GRID_W := 5
const GRID_H := 7
const TOP_CAP: Array[int] = [1, 3]        # 与 src/Battle.gd:516 的 TOP_CAP_COLS 一致

const AI_FORK_PATH := "res://RL/ai/AI_Battle.gd"     # 噩梦档用的候选（与 src/BattleAI.gd 同源 + 可注入权重）
const AI_ARENA_PATH := "res://arena/ArenaAI.gd"      # **竞技场覆盖层**：extends 上面那份，只覆盖"裁判规则不同"的函数
const AI_SRC_PATH := "res://src/BattleAI.gd"
const WEIGHT_PATH := {
	0: "res://RL/weights/简单.json",
	1: "res://RL/weights/普通.json",
	2: "res://RL/weights/困难.json",
	3: "res://RL/weights/噩梦.json",
}

## 墓碑（规则书里的 `B_8300001`）：协议没单列墓碑，它只可能混在 `barriers` 里
const GRAVE_KIND := 8300001
## 名称与项目不同名的三位（其余同名）
const NAME_ALIAS := { "大大骑士": "大骑士", "沉默": "沉默术士", "毒蛇女士": "毒蛇淑女" }

var _eng = null                 # ArenaEngine（只用它的日志）
var _rules: Dictionary = {}     # 规则包
var _tier := 3
var _think_ms := 0              # 0 = 自动：按本局选的回合预算算（见 `_think_budget`）
var _policy := "ai"
## 计划缓存：同一回合内复用上一份计划里没走完的步骤。
## **默认开** —— 因为"每一手都从头重搜"根本吃不起生产级的思考时间：生产噩梦档单次搜索上限是
## 40 秒（`噩梦.json` 的 TIME_BUDGET_MS），一回合 5~6 手 ⇒ 每手重搜就只能给 1~2 秒，
## 一撞上限搜索就转 `_greedy_finish` 贪心收尾（计划后半段根本没搜过）。
## 现在的口径 = **第一手深搜一次（最多到生产那个 40 秒量级），后面几手复用那份计划**；
## 一旦"预测 vs 实际"发现我们算错了（`_last_diff_mine > 0`）或计划里那一步映射不上合法动作，
## 立刻丢掉缓存重搜。`--no-cache-plan` 可退回"每手重搜"（排查用）。
var _use_cache := true
var _aggro := true               # 擂台倾向：松一档"敢压上"的闸门（见 `_make_ai` 里的说明）

var _grid: HexGrid = null
var _ai = null                  # BattleAI（src 或 RL 分叉）
var _kind2hero: Dictionary = {} # 协议 kind(int) -> 项目 hero_id
var _kind_hero_def: Dictionary = {}   # kind -> 规则包里的英雄条目
var _barrier_kinds: Dictionary = {}   # 规则包里的 isBarrier kind 集合
var _self_side := ""            # 本局我方 side（"red"/"blue"），每局第一次决策时记下
var _warned: Dictionary = {}    # 只打一次的话
var _watch = null               # ArenaWatch：本地思考面板（可为 null = 面板没开）
## 上一手的"预测"：我交了这个动作后，**我这边算出来**的局面应该长什么样（下一手拿真观察来对账）。
## 字段：match/turn/phase + pred（sim，已 apply 那一手）+ ids/hero_of/act + 地形快照。
## 对不上就是"我模拟的规则与裁判不一致"—— 面板和日志都会点名。
var _pred: Dictionary = {}
## 【自纠正】"这一回合已经反击过"的敌人（协议不给 `counterUsed`，只能自己推）：
##   键 = "<matchId>|<turnCount>|<协议 hero 实例 id>"。来源：我们预测"这一击会被 X 反击 N 点"，
##   而真实局面里**自己一点没掉**（或掉得比 N 少）⇒ X 这一回合的反击名额已经用掉了。
##   只记本回合（回合号在键里，跨回合自然失效）。
var _countered := {}
var _cur_match := ""
var _cur_turn := -1
var _cap_logged := -1            # 只打一次"思考上限"那行
## 【本回合已经花掉的搜索毫秒】`_think_budget()` 用它给"本回合剩下的每一手"分额度。
##   用户 2026-10-01 口径：「我和 AI 打的时候，AI 也得像个几秒十秒的。怎么在网页上，没想就动了」
##   ⇒ 擂台改成**每一手都重新搜**（不再照计划缓存逐手执行），每手都要真花几秒；
##     预算必须按"本回合还剩多少额度"分，否则一手 40 秒 × 五六手会撞掉回合时限（超两倍被裁判强制推进）。
var _turn_spent_ms := 0
## 【搜索宽度覆盖】`--beam=N`：只调宽每层候选线（不动权重文件）。
var _beam_override := 0
## 【每手最少思考】`--min-think=N ms`：搜索太快（局面简单时几十毫秒）就把它垫到这个时长，
##   让节奏与游戏里一致（用户 2026-10-01：「AI 也得像个几秒十秒的」）。0 = 关（不留垫时间）。
var _min_think_ms := 0
## 【本手起点】任务到手那一刻的毫秒表 —— `_min_think_ms` 的垫时间按它算（见 `_choose_gameplay` 末尾）。
var _hand_t0 := 0
var _last_diff_mine := 0         # 上一手"我方与裁判对不上"的条数（>0 ⇒ 丢掉计划缓存重搜）
var _last_own: Array = []        # 最近一次局面里"我方已上阵"的 hero_id（布阵评分要用）
var _last_foe: Array = []        # 同上，对手已上阵
var _withdraw_intent: Dictionary = {}   # 撤人换人时记下"要换谁上来、落哪格"，替补阶段照办

# ---- 计划缓存（一个回合内不必每一步都重搜）----
var _cache: Dictionary = {}


func setup(eng, rules: Dictionary, tier: int, think_ms: int, policy: String, use_cache: bool = false, aggro: bool = true,
		beam: int = 0, min_think_ms: int = 0) -> void:
	_eng = eng
	_rules = rules
	_tier = clampi(tier, 0, 3)
	_think_ms = maxi(think_ms, 0)
	_policy = policy
	_use_cache = use_cache
	_aggro = aggro
	_beam_override = maxi(beam, 0)
	_min_think_ms = maxi(min_think_ms, 0)
	_grid = HexGrid.new(GRID_W, GRID_H, 60.0)
	_grid.top_cap_cols = TOP_CAP.duplicate()
	_build_kind_map()
	_make_ai()
	_report_static_diff()


func on_match_end(match_id: String) -> void:
	_cache.clear()
	_self_side = ""


# ============================================================ 建 AI ============================================================

func _make_ai() -> void:
	# 与 `Battle._make_battle_ai()`（src/Battle.gd:9616-9651）同口径：
	#   0/1/2 档 = src/BattleAI.gd + 对应低档权重；3 档 = RL/ai/AI_Battle.gd + 噩梦.json。
	#   3 档再套一层 `arena/ArenaAI.gd`（只覆盖"裁判规则与我们不同"的那几处，游戏本体不动）。
	var path := AI_FORK_PATH if _tier >= 3 else AI_SRC_PATH
	if _tier >= 3:
		path = AI_ARENA_PATH
	var script = load(path)
	if script == null:
		_warn_once("no_ai", "!! 加载 %s 失败，退回 %s" % [path, AI_SRC_PATH])
		script = load(AI_SRC_PATH)
	_ai = script.new(_grid)
	_ai.difficulty = _tier
	_ai.log_decisions = false
	var w := _load_weights(_tier)
	if not w.is_empty():
		_ai.set_weights(w)
	if _beam_override > 0:
		# 【`--beam=N`】只把搜索宽度调宽（不动权重文件）：擂台想要"更强/想得更久"就调这里。
		#   宽度 = 每层保留多少条候选线；调宽 = 同一局面搜得更深更广，代价是每手耗时线性上涨。
		_eng._log("搜索宽度覆盖：beam %d → %d（--beam=N；权重文件不动）" % [_ai.w_beam, _beam_override])
		_ai.w_beam = _beam_override
	if _min_think_ms > 0:
		_eng._log("每手最少思考：%dms（--min-think=N；0 = 关）" % _min_think_ms)
	_ai.time_budget_ms = _think_ms
	# 【擂台倾向 · 只在竞技场这一侧】松一档"敢压上"的闸门（**不动权重文件、不动游戏**）：
	#   依据是引擎自己的注释（`src/BattleAI.gd:920`，`MOVE_ACCEPT_ENGAGED` 那一行）：
	#     "嫌 AI 缩手缩脚、该压上不压 ⇒ 升到 10~12 或删掉权重文件里那一行"。
	#   病灶：`噩梦.json` 里 `MOVE_ACCEPT_ENGAGED = 8` ⇒ **够得到人的单位**一旦踏进对方火力圈、
	#   且"下回合挨打合计"超过 8 点就被扣分 ⇒ 表现出来就是"对面都冲过来了，它还在往回缩/苟一回合"。
	#   随机阵容的擂台里我们没有练过的队形优势，这一档松一点更划算。`--no-aggro` 可关（回权重原值）。
	if _aggro:
		_ai.w_move_accept_engaged = 12
		_ai.w_idle_hit_penalty = 3.0
		_eng._log("擂台倾向：敢压上开（MOVE_ACCEPT_ENGAGED 8→12、IDLE_HIT_PENALTY 2→3；--no-aggro 可关）")
	_eng._log("AI：%s｜难度档=%d｜权重=%s（%d 键）｜beam=%d" % [
		path, _tier, WEIGHT_PATH.get(_tier, "无"), w.size(), int(_ai.w_beam)])


## 本地英雄表里的**基础移动力**（= 表里的移动 + <疾行>；不含 hero_24 冲锋那 +6 的引擎约定）
func _local_base_move(d: DataRegistry.HeroDef) -> int:
	return int(d.move_range) + (1 if (d.skills as Array).has(DataRegistry.Skill.SWIFT) else 0)


func _load_weights(tier: int) -> Dictionary:
	var path := String(WEIGHT_PATH.get(tier, ""))
	if path == "" or not FileAccess.file_exists(path):
		_warn_once("w_" + str(tier), "!! 权重文件不存在：%s（该档退回引擎默认值）" % path)
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	return parsed if parsed is Dictionary else {}


## 协议 kind → 项目 hero_id（按**中文名**匹配 + 别名 + 同名互含），并把静态数据逐项对一遍。
func _build_kind_map() -> void:
	_kind2hero.clear()
	_kind_hero_def.clear()
	_barrier_kinds.clear()
	var by_name: Dictionary = {}
	for hid in DataRegistry.heroes.keys():
		var d: DataRegistry.HeroDef = DataRegistry.heroes[hid]
		by_name[String(d.display_name)] = String(hid)
	# 召唤物在 `DataRegistry.summons` 里（不在 heroes），单独收一份（骷髅兵 kind=8200001）
	for hid in DataRegistry.summons.keys():
		var d2: DataRegistry.HeroDef = DataRegistry.summons[hid]
		by_name[String(d2.display_name)] = String(hid)
	var heroes: Array = _rules.get("heroes", [])
	var missing: Array = []
	for h in heroes:
		if not (h is Dictionary):
			continue
		var kind := int(h.get("kind", 0))
		var nm := String(h.get("name", ""))
		_kind_hero_def[kind] = h
		if bool(h.get("isBarrier", false)):
			_barrier_kinds[kind] = true
			continue
		var hid := ""
		if by_name.has(nm):
			hid = String(by_name[nm])
		elif NAME_ALIAS.has(nm) and by_name.has(String(NAME_ALIAS[nm])):
			hid = String(by_name[String(NAME_ALIAS[nm])])
		else:
			for k in by_name.keys():     # 兜底①：同名互含（如"沉默" ↔ "沉默术士"）
				if String(k).find(nm) >= 0 or nm.find(String(k)) >= 0:
					hid = String(by_name[k])
					break
		if hid == "":
			# 兜底②：按 (攻, 血, 基础移动) 三元组唯一匹配本地英雄（纯改名也能对上）
			var want := [int(h.get("attackPower", -1)), int(h.get("maxHealth", -1)), int(h.get("mobility", -1))]
			var cands: Array = []
			for hid2 in DataRegistry.heroes.keys():
				var d2: DataRegistry.HeroDef = DataRegistry.heroes[hid2]
				var is_sum: bool = bool(d2.is_summon)
				if is_sum != bool(h.get("isSummon", false)):
					continue
				if [int(d2.atk), int(d2.max_hp), _local_base_move(d2)] == want:
					cands.append(String(hid2))
			for hid2 in DataRegistry.summons.keys():
				var d3: DataRegistry.HeroDef = DataRegistry.summons[hid2]
				if [int(d3.atk), int(d3.max_hp), _local_base_move(d3)] == want:
					cands.append(String(hid2))
			if cands.size() == 1:
				hid = String(cands[0])
		if hid == "":
			missing.append("%d/%s" % [kind, nm])
			continue
		_kind2hero[kind] = hid
	_eng._log("kind→hero 映射：%d 项（障碍 %d 项）%s" % [
		_kind2hero.size(), _barrier_kinds.size(),
		"" if missing.is_empty() else "｜**没对上**：" + ", ".join(missing)])


## 协议静态数据 vs 本地英雄表：不一致就点名（规则包是这场比赛的权威，本地表只在协议没给的
## 字段上兜底 —— 所以不一致时以协议为准，但必须让人看见）。
func _report_static_diff() -> void:
	var diffs: Array = []
	for kind in _kind2hero.keys():
		var h: Dictionary = _kind_hero_def[kind]
		var d: DataRegistry.HeroDef = _get_def(String(_kind2hero[kind]))
		if d == null:
			continue
		var bits: Array = []
		if int(h.get("attackPower", d.atk)) != int(d.atk):
			bits.append("攻 %d↔%d" % [int(h.get("attackPower", -1)), int(d.atk)])
		if int(h.get("maxHealth", d.max_hp)) != int(d.max_hp):
			bits.append("血 %d↔%d" % [int(h.get("maxHealth", -1)), int(d.max_hp)])
		var mv := int(h.get("mobility", -1))
		if mv != _local_base_move(d):
			bits.append("速 %d↔%d" % [mv, _local_base_move(d)])
		var at := String(h.get("attackType", ""))
		var local_ranged := int(d.attack_type) == int(DataRegistry.AttackType.RANGED)
		if (at == "range") != local_ranged:
			bits.append("远程 %s↔%s" % [at, "range" if local_ranged else "melee"])
		if not bits.is_empty():
			diffs.append("%s(%s)" % [String(h.get("name", "?")), " ".join(bits)])
	_eng._log("静态数据核对：%s" % ("全部一致" if diffs.is_empty()
		else "%d 位有差异（以协议为准）：%s" % [diffs.size(), ", ".join(diffs)]))


# ============================================================ 对外入口 ============================================================

## 返回 {"actionId": "...", "note": "..."}；policy=random 时只验证连通性。
func choose(task: Dictionary) -> Dictionary:
	var legal: Array = task.get("legalActions", [])
	var obs: Dictionary = task.get("observation", {})
	if legal.is_empty():
		return {}
	if _self_side == "":
		_self_side = String(task.get("side", ""))
		_eng._log("本局 %s｜我方 side=%s｜规则=%s｜对手未知候补=%d" % [
			String(task.get("matchId", "?")), _self_side,
			String(task.get("rulesVersion", "?")), int(obs.get("opponentBenchCount", 0))])
	if _policy == "random":
		var ra: Dictionary = legal[randi() % legal.size()]
		return {"actionId": String(ra.get("actionId", "")), "note": "random"}
	var phase := String(obs.get("phase", "gameplay"))
	var prev_key := "%s|%d" % [_cur_match, _cur_turn]
	_cur_match = String(task.get("matchId", ""))
	_cur_turn = int(obs.get("turnCount", 0))
	_hand_t0 = Time.get_ticks_msec()      # 本手起点（`_min_think_ms` 垫时间用）
	if prev_key != "%s|%d" % [_cur_match, _cur_turn]:
		_turn_spent_ms = 0       # 新回合 ⇒ 本回合的搜索额度重新开始计（见 `_think_budget`）
	if phase == "deploy" or phase == "gamerelay":
		return _choose_deploy(task, obs, legal)
	return _choose_gameplay(task, obs, legal)


# ------------------------------------------------------------ 布阵 / 替补 ------------------------------------------------------------

func _choose_deploy(task: Dictionary, obs: Dictionary, legal: Array) -> Dictionary:
	var mid := String(task.get("matchId", ""))
	# ⓪ 同 `_choose_gameplay`：对账（台账 `_countered`）必须排在**建 sim 之前**，否则这份 sim 里的
	#    `counter_used` 还是旧的（协议不给 `counterUsed`，全靠这一步自纠正）。
	var pre := _build_sim(obs)
	var diff: Dictionary = _diff_prediction(mid, obs, pre)
	_last_diff_mine = int(diff.get("n_mine", 0)) if not diff.is_empty() else 0
	if _last_diff_mine > 0:
		_cache = {}
	var built := _build_sim(obs)
	if built.is_empty():
		return _any_legal(legal, "no-sim")
	var sim = built["sim"]
	var cells := _deploy_cells(legal)
	var slot_of := _kind_slot_map(obs)
	var roster := _undeployed_ids(obs)
	var hero_of_slot := _kind_slot_hero(obs)
	# 选谁：战场上已经有人（中途替补）时用 AI 自己的"斩杀优先"选人；开局布阵用阵容价值。
	var want_hero := ""
	var enemy_on_board := _alive_count(sim, DataRegistry.Faction.PLAYER)
	# 【撤人换人】上一次我们主动撤人时记下了"要换谁上来" ⇒ 这一手照办（否则需求制会换个人上来，白花一条命）
	if not _withdraw_intent.is_empty():
		var want_w := String(_withdraw_intent.get("hero", ""))
		var want_c: Vector2i = _withdraw_intent.get("cell", Vector2i(-99, -99))
		if want_w != "" and slot_of.has(want_w):
			var aid_w := _match_deploy(legal, want_w, want_c, slot_of)
			if aid_w == "":
				aid_w = _match_deploy(legal, want_w, Vector2i(-99, -99), slot_of)
			if aid_w != "":
				var dw: DataRegistry.HeroDef = _get_def(want_w)
				var ow := {"actionId": aid_w, "note": "撤人换人：%s 上场收尾" % (String(dw.display_name) if dw != null else want_w)}
				_pred = _make_prediction(mid, obs, legal, built, sim, ow)
				_withdraw_intent = {}
				_push_watch(task, obs, legal, ow, built, sim, [], 0, 0, diff)
				return ow
		_withdraw_intent = {}
	if String(obs.get("phase", "")) == "gamerelay" and enemy_on_board > 0 and not roster.is_empty():
		# 中途替补：走**游戏自己的替补流水线**（`DataRegistry.sub_need_for` + `sub_hero_score`，
		# 与 `Battle._best_enemy_sub_idx()` 同源：先判"缺什么"（嘲讽/治疗/伤员/输出/远程），再按需求挑人）。
		# 挑不出（名单里没人够格）才退到 AI 的"斩杀优先"选人。
		want_hero = _sub_pick_by_need(roster, obs)
		if want_hero == "":
			want_hero = String(_ai.pick_sub_hero(sim, roster, cells))
	# 兜底 / 开局：按"单体身价 + 与已上阵队友/已知敌人的协同克制"排序
	if want_hero == "" or not slot_of.has(want_hero):
		want_hero = _best_deploy_hero(sim, built, roster, hero_of_slot, obs)
	var want_cell: Vector2i = _ai.pick_sub_cell(sim, want_hero, cells)
	# 映射：先精确 (slot, cell)，再退化成"这个英雄的任意落点"，最后按分挑
	var aid := _match_deploy(legal, want_hero, want_cell, slot_of)
	if aid == "":
		aid = _match_deploy(legal, want_hero, Vector2i(-99, -99), slot_of)
	if aid == "":
		aid = _best_deploy_pair(legal, sim, built, slot_of, hero_of_slot)
	var out: Dictionary = {}
	if aid == "":
		out = _any_legal(legal, "deploy-no-match")
	else:
		var d: DataRegistry.HeroDef = _get_def(want_hero)
		out = {"actionId": aid, "note": "%s %s→%s" % [
			"替补" if String(obs.get("phase", "")) == "gamerelay" else "布阵",
			(String(d.display_name) if d != null else want_hero), _cell_txt(want_cell)]}
	# 对账已在 ⓪ 做过（diff 就是那一份），这里只管造这一手的预测
	_pred = _make_prediction(mid, obs, legal, built, sim, out)
	_push_watch(task, obs, legal, out, built, sim, [], 0, 0, diff)
	return out


## 中途替补选人：**照 `Battle._best_enemy_sub_idx()` 的口径**——
##   ① 先把场上情况收成 ctx（嘲讽数 / 治疗族 / 伤员 / 输出数 / 攻击力合计 / 远程数 / 对面核心 / 核心是否已被克制）
##   ② 问 `DataRegistry.sub_need_for(roster, ctx)`：这一手"缺什么"（按优先级，且名单里得有人够格）
##   ③ 每个候选按 `DataRegistry.sub_hero_score(hid, need, ctx)` 打分，取最高
## 这一整套都是游戏里跑的同一份实现（`DataRegistry`），我这边只负责把 ctx 从**观察**里重建。
func _sub_pick_by_need(roster: Array, obs: Dictionary) -> String:
	var ally: Array = []
	var foe: Array = []
	var taunt := 0
	var healers := 0
	var dps := 0
	var atk_sum := 0
	var ranged := 0
	var wounded := 0
	var heals: Array = DataRegistry.MECH_TAGS.get("治疗", [])
	for key in ["ownPool", "opponentRevealed", "summons"]:
		for h in obs.get(key, []):
			if not (h is Dictionary):
				continue
			var d: Dictionary = h
			var st := _s(d.get("status"))
			if st == "dead" or st == "quit" or st == "wait" or d.get("pos", null) == null:
				continue
			var hid := String(_kind2hero.get(_i(d.get("kind")), ""))
			if hid == "":
				continue
			if _s(d.get("side")) == _self_side:
				ally.append(hid)
				var def: DataRegistry.HeroDef = _get_def(hid)
				if def != null:
					if (def.skills as Array).has(DataRegistry.Skill.TAUNT):
						taunt += 1
					if heals.has(hid) or (DataRegistry.SUB_HEAL_EXTRA as Array).has(hid):
						healers += 1
					if int(def.atk) >= int(DataRegistry.SUB_DPS_ATK):
						dps += 1
					atk_sum += int(def.atk)
					if int(def.attack_type) == int(DataRegistry.AttackType.RANGED):
						ranged += 1
				if _i(d.get("health"), 1) < _i(d.get("maxHealth"), 1):
					wounded += 1
			else:
				foe.append(hid)
	var core := ""
	var core_v := -INF
	for hid2 in foe:
		var v := float(DataRegistry.hero_strength(hid2))
		if v > core_v:
			core_v = v
			core = hid2
	var countered := false
	if core != "":
		for a in ally:
			if float(DataRegistry.counter_bonus(String(a), core)) > 0.0:
				countered = true
				break
	var ctx := {"taunt": taunt, "healers": healers, "wounded": wounded, "dps": dps,
		"atk_sum": atk_sum, "ranged": ranged, "core": core, "countered": countered}
	var need = DataRegistry.sub_need_for(roster, ctx)
	ctx["need"] = need
	var best := ""
	var best_s := -INF
	for hid3 in roster:
		var sc = DataRegistry.sub_hero_score(String(hid3), need, ctx)
		var s := float((sc as Dictionary).get("s", -1e18)) if sc is Dictionary else -1e18
		if s > best_s:
			best_s = s
			best = String(hid3)
	if best != "":
		_warn_once("sub_need", "替补需求=%s ⇒ 选 %s（嘲讽%d 治疗%d 伤员%d 输出%d 核心=%s 已克制=%s）" % [
			str(need), best, taunt, healers, wounded, dps, core, str(countered)])
	return best


## 【主动撤人 = 斩杀换人】游戏里走 `Battle._finish_kill_hero_pick()` 那条链：花掉一条命（**撤退视为死亡**），
## 换一个"上来就能一刀收掉对面关键目标"的替补。竞技场协议里有 `WITHDRAW` 意图，之前我们**从来没用过** ⇒
## 整条机制在擂台上是关着的。这里用 AI 自己的 `sub_kill_scan()`（真实伤害模型：含倍率技/重伤/坚固/塔盾/圣盾）
## 来判"换谁能收掉谁"，门槛卡死：
##   · 我方已阵亡 ≤ 1（已有 2 死时撤退 = 第 3 死 = 直接判负，绝不撤）
##   · 必须是**一刀单杀**（solo），或"合力收掉"且对面只剩 2 人（这一刀就是赛点）
##   · 本回合我们还没杀到人（避免白花一条命）
## 决定撤之后，会把"要换谁上场"记进 `_withdraw_intent`，紧接着的替补阶段优先照这个意图落人。
func _maybe_withdraw(obs: Dictionary, legal: Array, sim, built: Dictionary) -> Dictionary:
	if String(obs.get("phase", "")) != "gameplay":
		return {}
	var dead_ours := _i((_d(obs.get("deadCount"))).get(_self_side), 0)
	if dead_ours > 1:
		return {}
	var roster := _undeployed_ids(obs)
	if roster.is_empty():
		return {}
	# 可撤的人（合法动作里带 WITHDRAW 的）
	var can: Dictionary = {}      # hero 实例 id -> actionId
	for a in legal:
		var d: Dictionary = a
		var it: Dictionary = _d(d.get("intent"))
		if _s(it.get("kind")) != "WITHDRAW":
			continue
		can[_s(it.get("heroId"))] = String(d.get("actionId", ""))
	if can.is_empty():
		return {}
	# 落点 = 被撤单位的格子（撤下来那一格空出来，新人落那儿 —— 与游戏 `_finish_kill_hero_pick` 同口径）
	var cells: Array = []
	var ids: Array = built.get("ids", [])
	for hid_inst in can.keys():
		var i := _idx_of(ids, String(hid_inst))
		if i >= 0 and i < (sim as Object).units.size():
			cells.append((sim as Object).units[i].cell)
	if cells.is_empty():
		return {}
	var scan: Dictionary = _ai.sub_kill_scan(sim, roster, cells)
	if scan.is_empty():
		return {}
	var foe_alive := int(scan.get("foe_alive", 9))
	var solo := bool(scan.get("solo", false))
	if not solo and foe_alive > 2:
		return {}      # 合力的收尾只在"这一刀就是赛点"时才值得花一条命
	# 撤谁：身价最低的那个（残血的优先 —— 反正活不下来）
	var victim := ""
	var victim_score := INF
	for hid_inst2 in can.keys():
		var i2 := _idx_of(ids, String(hid_inst2))
		if i2 < 0:
			continue
		var u = (sim as Object).units[i2]
		var s := float(DataRegistry.hero_strength(String(u.hero_id)))
		if int(u.hp) * 2 < int(u.max_hp):
			s -= 20.0
		if s < victim_score:
			victim_score = s
			victim = String(hid_inst2)
	if victim == "":
		return {}
	_withdraw_intent = {"hero": String(scan.get("hero", "")), "cell": scan.get("cell", Vector2i(-99, -99))}
	_warn_once("withdraw", "!! 主动撤人：撤 %s（身价 %.1f）换 %s 上来一刀收 %s（合击 %.1f/需 %.1f，对面剩 %d 人；我方已阵亡 %d）" % [
		victim, victim_score, String(scan.get("hero", "?")), String(scan.get("foe_idx", "?")),
		float(scan.get("total", 0.0)), float(scan.get("need", 0.0)), foe_alive, dead_ours])
	return {"actionId": String(can[victim]), "note": "主动撤人 → 换 %s 收尾（对面剩 %d 人）" % [String(scan.get("hero", "?")), foe_alive]}


## 开局布阵：谁的"上场价值"最高。**一比一复刻 `Battle._deploy_candidate_value()`
## （src/Battle.gd:2810）** —— 那一套才是游戏里真正的选人口径，含：
##   ① 单体强度 `DataRegistry.hero_strength`
##   ② 与已上阵队友的机制协同 `synergy_bonus`
##   ③ **职能配比** `DataRegistry.role_balance_bonus`（坦克/输出/功能各自占比）
##   ④ 对**对手已上阵**的净克制 `counter_bonus`（我克他 − 他克我）
##   ⑤ **已有坦克再上坦克 −3.5（避免双坦克开局）**、第三手防全脆皮 ±3、坦克重复 −1
##   ⑥ "不首发"名单：末日(hero_31) 按条件、赏金猎人(hero_20) 需对面已有嘲讽
## ⚠️ 之前只用了 `battle_unit_value`（单体+协同+克制），把 ③⑤⑥ 全漏了 ⇒ 真机出现过"开局上两个嘲讽肉盾"。
func _best_deploy_hero(sim, built: Dictionary, roster: Array, hero_of_slot: Dictionary, obs: Dictionary) -> String:
	var mine := _deploy_mine()          # 我方已上阵的 hero_id
	var foes := _deploy_foes()          # 对手已上阵的 hero_id
	var best := ""
	var best_s := -INF
	for hid in roster:
		var s := _deploy_value(String(hid), mine, foes)
		if best == "" or s > best_s:
			best_s = s
			best = String(hid)
	if best != "":
		_warn_once("deploy_" + best, "布阵评分冠军：%s（%.1f；已上阵 %s）" % [best, best_s, str(mine)])
	if best == "" and not roster.is_empty():
		best = String(roster[0])
	return best


## 我方/对手"此刻已经上阵"的 hero_id（部署阶段双方轮流上人 ⇒ 两边都在变）
func _deploy_mine() -> Array:
	var out: Array = []
	for h in _last_own:
		out.append(String(h))
	return out


func _deploy_foes() -> Array:
	var out: Array = []
	for h in _last_foe:
		out.append(String(h))
	return out


## `Battle._deploy_candidate_value()` 的复刻（arena 侧专用，**不改游戏本体**）
func _deploy_value(cand: String, deployed: Array, foe_deployed: Array) -> float:
	if not _no_starter_ok(cand, deployed, foe_deployed):
		return -999.0
	var s := float(DataRegistry.hero_strength(cand))
	for c in deployed:
		s += float(DataRegistry.synergy_bonus(String(c), cand))
	s += float(DataRegistry.role_balance_bonus(deployed, cand))
	for pid in foe_deployed:
		s += float(DataRegistry.counter_bonus(cand, String(pid))) - float(DataRegistry.counter_bonus(String(pid), cand))
	var is_tank := DataRegistry.hero_role_name(cand) == "坦克"
	var is_hard := _deploy_is_hard(cand)
	var tank_cnt := 0
	var hard_cnt := 0
	for id in deployed:
		if DataRegistry.hero_role_name(String(id)) == "坦克":
			tank_cnt += 1
		if _deploy_is_hard(String(id)):
			hard_cnt += 1
	if is_tank and tank_cnt >= 1:
		s -= 3.5                                   # ① 避免双坦克开局
	if deployed.size() == 2 and hard_cnt == 0:
		s += 3.0 if is_hard else -3.0              # ② 第三手防"全脆皮"
	if is_tank and tank_cnt >= 1 and hard_cnt >= 1:
		s -= 1.0                                   # ③ 坦克重复再压一点
	return s


## `Battle._deploy_is_hard()`：嘲讽/后勤，或血量 ≥ 24
func _deploy_is_hard(hid: String) -> bool:
	var d: DataRegistry.HeroDef = _get_def(hid)
	if d == null:
		return false
	if (d.skills as Array).has(DataRegistry.Skill.TAUNT) or (d.skills as Array).has(DataRegistry.Skill.LOGISTICS):
		return true
	return int(d.max_hp) >= 24


const NO_STARTER_HEROES := ["hero_31"]        # 末日：只在对面有低血(≤17)单位、且我方还没有时才好首发
const NO_STARTER_NEED_TAUNT := ["hero_20"]    # 赏金猎人：对面得先有<嘲讽>，否则上首发等于废
const NO_STARTER_LOW_HP := 18                 # 这条线**不含 18**（严格小于）

func _no_starter_ok(cand: String, deployed: Array, foe_deployed: Array) -> bool:
	if NO_STARTER_NEED_TAUNT.has(cand):
		return _has_taunt(foe_deployed)
	if not NO_STARTER_HEROES.has(cand):
		return true
	var p_low := 0
	for hid in foe_deployed:
		if _hp_below(String(hid), NO_STARTER_LOW_HP):
			p_low += 1
	var m_low := 0
	for hid in deployed:
		if _hp_below(String(hid), NO_STARTER_LOW_HP):
			m_low += 1
	if p_low >= 1 and m_low == 0:
		return true
	if p_low >= 2 and m_low <= 1:
		return true
	return false


func _hp_below(hid: String, line: int) -> bool:
	var d: DataRegistry.HeroDef = _get_def(hid)
	return d != null and int(d.max_hp) < line


func _has_taunt(ids: Array) -> bool:
	for hid in ids:
		var d: DataRegistry.HeroDef = _get_def(String(hid))
		if d != null and (d.skills as Array).has(DataRegistry.Skill.TAUNT):
			return true
	return false


func _match_deploy(legal: Array, hero_id: String, want: Vector2i, slot_of: Dictionary) -> String:
	if hero_id == "" or not slot_of.has(hero_id):
		return ""
	var slot := int(slot_of[hero_id])
	var any_hit := ""
	for a in legal:
		var it: Dictionary = (a as Dictionary).get("intent", {})
		if String(it.get("kind", "")) != "DEPLOY" or int(it.get("slot", -1)) != slot:
			continue
		var cell := _to_local(it.get("to", {}))
		if want == Vector2i(-99, -99) or cell == want:
			return String((a as Dictionary).get("actionId", ""))
		any_hit = String((a as Dictionary).get("actionId", ""))
	return any_hit


## 最后一档：对每个合法 DEPLOY 打"英雄价值 + 落点几何"，取最高。
func _best_deploy_pair(legal: Array, sim, built: Dictionary, slot_of: Dictionary, hero_of_slot: Dictionary) -> String:
	var foers: Array = []
	for i in built["ids"].size():
		if int(built["fn"][i]) == int(DataRegistry.Faction.PLAYER):
			foers.append(sim.units[i])
	var allies: Array = []
	for i in built["ids"].size():
		if int(built["fn"][i]) == int(DataRegistry.Faction.ENEMY):
			allies.append(sim.units[i])
	var best := ""
	var best_s := -INF
	for a in legal:
		var it: Dictionary = (a as Dictionary).get("intent", {})
		if String(it.get("kind", "")) != "DEPLOY":
			continue
		var slot := int(it.get("slot", -1))
		var hid := String(hero_of_slot.get(slot, ""))
		if hid == "":
			continue
		var cell := _to_local(it.get("to", {}))
		var d: DataRegistry.HeroDef = _get_def(hid)
		var s := 0.0
		if d != null:
			s += float(DataRegistry.battle_unit_value(hid, [hid], [])) * 0.1
			var reach: int = int(DataRegistry.spawn_move(d)) + int(DataRegistry.spawn_attack_range(d))
			var near := 1 << 30
			for t in foers:
				var dd: int = _ai.approach_dist(sim, cell, t.cell)
				near = mini(near, dd)
				if dd <= reach:
					s += 5.0
			s -= float(mini(near, 30)) * 0.2
		for al in allies:                       # 别和队友挤同一列
			if al.cell.x == cell.x:
				s -= 0.5
		if best == "" or s > best_s:
			best_s = s
			best = String((a as Dictionary).get("actionId", ""))
	return best


# ------------------------------------------------------------ 游戏阶段 ------------------------------------------------------------

func _choose_gameplay(task: Dictionary, obs: Dictionary, legal: Array) -> Dictionary:
	var remain := int(task.get("remainingMs", 0))
	var budget := _think_budget(remain, int(_d(task.get("settings")).get("turnBudgetMs", 0)))
	var built: Dictionary = {}
	var start_sim = null
	var plan: Array = []
	var ms := 0
	var pick: Dictionary = {}
	var mid := String(task.get("matchId", ""))
	# ⓪【对账必须排在"建 sim / 选动作"之前】先把上一手实际发生了什么算出来，落进台账 `_countered`
	#    （= "这个敌人本回合已经反击过"）。协议不给 `counterUsed`，这是我们唯一的来源；
	#    而 `_build_sim()` 建局时正是**读台账**填 `counter_used`（见 `_unit_desc`）。
	#    病灶（擂台实测 arena_ba8d6597，turn12 与 turn14 各一处）：
	#      turn14: red-5 ATTACK→(0,0) 打超新星、真机吃了 1 点反击（22→21）；
	#              紧接着 red-6 打**同一个**目标 —— 真机**不再反击**（名额已用，用户口径"第一次打才反击"），
	#              我们却还预测"会被 超新星 反击 1 点"（预测 5 / 实际 6）。
	#      turn12: red-5 ATTACK→(1,2) 吃反击（23→22），随后 red-3 打同一格 ⇒ 又是"预测 12 / 实际 13"。
	#    原来对账排在选完动作之后 ⇒ 这一手的 sim 是在台账更新**之前**建的，白怕一次反击；
	#    代价不止"报一处差异"：该打的刀会不敢打、该省的走位会多走一格。
	var pre := _build_sim(obs)
	var diff: Dictionary = _diff_prediction(mid, obs, pre)
	_last_diff_mine = int(diff.get("n_mine", 0)) if not diff.is_empty() else 0
	if _last_diff_mine > 0:
		_cache = {}     # 上一手算错了 ⇒ 那份计划是按假局面推的，作废
	# ⓪ 主动撤人（斩杀换人）：先看有没有"换个人上来就能一刀收掉"的机会 —— 有就直接撤，不必再搜。
	#    ⚠️ 只在**没有缓存计划**时判（一手只撤一次；撤完紧接着是替补阶段）。
	if _cache.is_empty() and String(obs.get("phase", "")) == "gameplay":
		var b0 := _build_sim(obs)
		if not b0.is_empty():
			var w := _maybe_withdraw(obs, legal, b0["sim"], b0)
			if not w.is_empty():
				built = b0
				start_sim = (b0["sim"] as Object).clone()
				pick = w
	# ① 计划缓存（默认开）：**上一手没算错**才敢复用（算错了说明我们的规则与裁判不一致，
	#    那份计划是按假局面推的，必须拿最新观察重搜）。同一回合内、映射得上合法动作才用。
	if _use_cache and _last_diff_mine == 0:
		pick = _try_cached(task, obs, legal)
		if not pick.is_empty():
			if _bad_bomb_move(obs, legal, String(pick.get("actionId", ""))):
				_cache = {}
				pick = {}
			else:
				# 走缓存省的是**搜索**；为了继续对账，局面还是要重建一份（很便宜，不搜）
				built = _build_sim(obs)
				start_sim = built.get("sim", null)
	elif not _use_cache:
		_cache = {}
	else:
		_cache = {}
	# ② 完整搜索：一次算完整个回合，取第一步
	if pick.is_empty() and budget >= 300:
		if built.is_empty():
			built = _build_sim(obs)
		if not built.is_empty():
			start_sim = (built["sim"] as Object).clone()   # search 会改传入的 sim ⇒ 留一份"起手"给面板/复盘
			_ai.time_budget_ms = maxi(budget - 300, 250)   # 留 300ms 给搜索之后的收尾（面板评分/映射）
			var t0 := Time.get_ticks_msec()
			plan = _ai.search(built["sim"], DataRegistry.Faction.ENEMY)
			ms = Time.get_ticks_msec() - t0
			_turn_spent_ms += ms    # 记进"本回合已花"⇒ 下一手分到的额度会自动变小
			if plan.is_empty():
				# AI 这回合没排任何动作：先看还有没有"能打"的单位（有就补一刀），再考虑结束回合
				var late0 := _late_strike(obs, legal, built)
				if not late0.is_empty():
					pick = late0
			if pick.is_empty() and plan.is_empty():
				var e := _find_end_turn(legal)
				if e != "":
					var idle2 := _idle_ids(built)
					if not idle2.is_empty():
						_warn_once("empty_idle", "!! AI 空计划 → END_TURN，但有单位还没行动：%s" % ", ".join(idle2))
					pick = {"actionId": e, "note": "AI 空计划（搜了 %dms）→ END_TURN%s" % [
						ms, ("" if idle2.is_empty() else "（还有没行动的单位：" + ", ".join(idle2) + "）")]}
			if pick.is_empty():
				pick = _consume_plan(task, obs, legal, built, plan)
				if not pick.is_empty():
					# 【取证】写明"这次搜索有没有撞上限" —— 用户 2026-10-01 问「为什么每回合都没怎么思考」：
					#   擂台是**一回合只搜一次**（本回合第一手），后面每一手都是照计划执行（几十毫秒）。
					#   而这一手到底"想够了没有"，看这句：`未超时` = 搜索自己收敛了（再给时间也一样）；
					#   `⚠️超时收尾` = 撞了 `TIME_BUDGET_MS`，计划后半段是贪心补的（那才是"没想透"）。
					pick["note"] = "%s（计划 %d 步，搜了 %dms/%dms·%s）" % [String(pick.get("note", "")), plan.size(), ms,
						_ai.time_budget_ms, ("⚠️超时收尾，后半段贪心补" if _ai.last_search_timeout else "未超时")]
				else:
					_warn_once("plan_miss", "!! 计划映射不上任何合法动作（plan=%d 步，搜了 %dms）⇒ 退 1 层评估" % [plan.size(), ms])
	elif pick.is_empty():
		_warn_once("thin_budget", "剩余预算 %dms 太紧 ⇒ 不搜索，走快路" % remain)
	# ③ 兜底：1 层评估（对每个合法动作 clone 一份 sim，apply 后 evaluate）
	if pick.is_empty():
		pick = _fallback_greedy(obs, legal)
	pick = _guarded(obs, legal, pick)
	# 【节奏】用户 2026-10-01 口径：「我和 AI 打的时候，AI 也得像个几秒十秒的。怎么在网页上，没想就动了」
	#   搜索是"铺完候选线就返回"，局面简单时几十毫秒就收敛（比如只剩 1~2 个单位能动）—— 那是**真没得算**，
	#   不是偷懒。但网页上看着就是"没想就动"，而且和游戏里的节奏对不上 ⇒ 这里把本手"从任务到提交"
	#   垫到 `_min_think_ms`（默认 2000ms；`--min-think=0` 关掉，`--min-think=N` 调长）。
	#   ⚠️ 垫的时间**记进本回合额度**（`_turn_spent_ms`），并且绝不吃掉收尾/网络的 5 秒余量
	#   ⇒ 一回合总耗时仍在回合预算内，不会被裁判判超时强制推进。
	if _min_think_ms > 0:
		var used := Time.get_ticks_msec() - _hand_t0
		var want := mini(_min_think_ms, maxi(remain - 5000, 0))
		if used < want:
			OS.delay_msec(want - used)
			_turn_spent_ms += (want - used)
	# 对账已在 ⓪ 做过（必须在建 sim 之前），这里只管造这一手的预测
	_pred = _make_prediction(mid, obs, legal, built, start_sim, pick)
	_push_watch(task, obs, legal, pick, built, start_sim, plan, ms, budget, diff)
	return pick


## 收口检查：**绝不主动踩雷**（非炸弹人停在有炸弹的格子上 = 白掉 5 血）。
## 我们的模拟里"炸弹人落雷的位置"是按价值算的（`_best_bomb_cell`），而裁判那边是"正前方"规则
## —— 两边的落点可能不一样 ⇒ 计划里给别的人排的那一步，可能正好落在裁判刚放下的那颗雷上。
## 真机实测就是这么踩上去的（2026-10-01 用户报「黄金矿工直接踩自己队弄出来的炸弹」）。
func _guarded(obs: Dictionary, legal: Array, pick: Dictionary) -> Dictionary:
	if pick.is_empty() or not _bad_bomb_move(obs, legal, String(pick.get("actionId", ""))):
		return pick
	_warn_once("bomb_guard", "!! 计划里那一步会踩到自己队的雷 ⇒ 弃掉，改走 1 层评估")
	_cache = {}
	var g := _fallback_greedy(obs, legal, true)
	if g.is_empty():
		var e := _find_end_turn(legal)
		if e != "":
			return {"actionId": e, "note": "踩雷步已弃 → END_TURN"}
	return g


## 这一手是不是"主动踩雷"（见 `_guarded`）
func _bad_bomb_move(obs: Dictionary, legal: Array, action_id: String) -> bool:
	if action_id == "":
		return false
	var bombs: Dictionary = {}
	for bm in obs.get("bombs", []):
		var bc := _to_local(_d(bm).get("cell", {}))
		if bc.x >= 0:
			bombs[bc] = true
	if bombs.is_empty():
		return false
	for a in legal:
		var d: Dictionary = a
		if String(d.get("actionId", "")) != action_id:
			continue
		var it: Dictionary = d.get("intent", {})
		if String(it.get("kind", "")) != "MOVE":
			return false
		if not bombs.has(_to_local(it.get("to", {}))):
			return false
		return _hero_of_instance(obs, String(it.get("heroId", ""))) != "hero_35"
	return false


func _hero_of_instance(obs: Dictionary, instance_id: String) -> String:
	for key in ["ownPool", "opponentRevealed", "summons"]:
		for h in obs.get(key, []):
			if h is Dictionary and String((h as Dictionary).get("id", "")) == instance_id:
				return String(_kind2hero.get(int((h as Dictionary).get("kind", 0)), ""))
	return ""


## 候选对比（诊断用，只在面板开着时算）：把"这一手所有能打的目标"逐个 apply 到一份 sim 副本上，
## 记下 **敌掉多少 / 我掉多少（含反击）/ 这一步的总分**，让"为什么打这个不打那个"看得见。
## （1 层估值只看这一手之后的局面分，不含整回合后续 —— 只用来横向比候选，不代表 AI 的计划分。）
func _candidates_view(legal: Array, built: Dictionary, start_sim, pick: Dictionary) -> Array:
	if start_sim == null or built.is_empty():
		return []
	var ids: Array = built["ids"]
	var occ: Dictionary = built.get("occ", {})
	var chosen := String(pick.get("actionId", ""))
	var rows: Array = []
	var taken := 0
	for a in legal:
		var d: Dictionary = a
		var it: Dictionary = d.get("intent", {})
		var kind := _s(it.get("kind"))
		var is_chosen := String(d.get("actionId", "")) == chosen
		if kind != "ATTACK" and not is_chosen:
			continue
		if taken >= 10:
			break
		var idx := _idx_of(ids, _s(it.get("heroId")))
		if idx < 0:
			continue
		var act := {}
		var tgt := -1
		if kind == "MOVE":
			act = {"move": _to_local(it.get("to", {})), "atk": -1}
		else:
			var tc := _to_local(it.get("target", {}))
			if occ.has(tc):
				tgt = int(occ[tc])
				act = {"move": null, "atk": tgt}
			else:
				act = {"move": null, "atk": -2, "atk_obs": tc}
		var c = (start_sim as Object).clone()
		var me0: int = int((c as Object).units[idx].hp)
		var t0: int = int((c as Object).units[tgt].hp) if tgt >= 0 else 0
		var cu0: bool = (tgt >= 0 and bool((c as Object).units[tgt].counter_used))
		var tn := ""
		if tgt >= 0:
			tn = String((c as Object).units[tgt].name)
		_ai._apply(c, idx, act)
		var me1: int = int((c as Object).units[idx].hp)
		var t1: int = int((c as Object).units[tgt].hp) if tgt >= 0 else 0
		var countered: bool = (tgt >= 0 and not cu0 and bool((c as Object).units[tgt].counter_used))
		var bd: Dictionary = _ai._eval_breakdown(c, false)
		rows.append({
			"label": ("%s→%s" % [String((c as Object).units[idx].name),
				(tn if tgt >= 0 else _cell_txt(_to_local(it.get("target", {}))))]) if kind == "ATTACK" \
				else "%s→%s（移动）" % [String((c as Object).units[idx].name), _cell_txt(_to_local(it.get("to", {})))],
			"kind": kind, "chosen": is_chosen, "countered": countered,
			"dmg": t0 - t1, "hp_lost": me0 - me1, "killed": (tgt >= 0 and t1 <= 0 and t0 > 0),
			"score": float(_ai._evaluate(c)),
			"hp_acc": float(bd.get("③血量账", 0.0)), "worth": float(bd.get("②身价", 0.0)),
			"risk": float(bd.get("⑦核心风险", 0.0)),
		})
		taken += 1
	rows.sort_custom(func(x, y): return float(x["score"]) > float(y["score"]))
	return rows


# ============================================================ 思考面板 ============================================================

func set_watch(w) -> void:
	_watch = w


## 造"这一手的预测"：把刚交的动作 apply 到我建的那份 sim 上（= 我算出来的下一手局面）。
## 交的动作在协议里是 intent，这里换回 sim 的 {idx, action} 再 apply —— 与 AI 自己推演用的是同一套规则。
func _make_prediction(match_id: String, obs: Dictionary, legal: Array, built: Dictionary,
		start_sim, pick: Dictionary) -> Dictionary:
	var out := {"match": match_id, "turn": int(obs.get("turnCount", 0)),
		"phase": String(obs.get("phase", "")), "act": String(pick.get("note", "")),
		"ids": [], "hero_of": [], "pred": null, "expect": {}, "skip": ""}
	if start_sim == null or built.is_empty():
		out["skip"] = "这一手没有完整搜索（缓存/兜底），不预测"
		return out
	var it: Dictionary = _d(_find_intent_of(legal, String(pick.get("actionId", ""))))
	var kind := _s(it.get("kind"))
	var ids: Array = built["ids"]
	var hero_of: Array = built["hero_of"]
	out["ids"] = ids.duplicate()
	out["hero_of"] = hero_of.duplicate()
	if kind == "DEPLOY":
		# 布阵/替补：只记"这个英雄应该满血出现在这一格"
		var slot := _i(it.get("slot"), -1)
		var hid := ""
		var inst := ""
		for h in obs.get("ownPool", []):
			if h is Dictionary and _i((h as Dictionary).get("slot"), -2) == slot:
				inst = _s((h as Dictionary).get("id"))
				hid = String(_kind2hero.get(_i((h as Dictionary).get("kind")), ""))
		out["expect"] = {"id": inst, "hero": hid, "cell": _cell_pair(_to_remote(_to_local(it.get("to", {}))))}
		return out
	var pred = (start_sim as Object).clone()
	if kind == "MOVE":
		var i0 := _idx_of(ids, _s(it.get("heroId")))
		if i0 < 0:
			out["skip"] = "找不到这个单位的 sim 下标"
			return out
		_ai._apply(pred, i0, {"move": _to_local(it.get("to", {})), "atk": -1})
	elif kind == "ATTACK":
		var i1 := _idx_of(ids, _s(it.get("heroId")))
		if i1 < 0:
			out["skip"] = "找不到这个单位的 sim 下标"
			return out
		var tc := _to_local(it.get("target", {}))
		var occ: Dictionary = built.get("occ", {})
		var tgt_i := int(occ[tc]) if occ.has(tc) else -1
		var hp0: int = int((pred as Object).units[i1].hp)
		var cu0: bool = (tgt_i >= 0 and bool((pred as Object).units[tgt_i].counter_used))
		if occ.has(tc):
			_ai._apply(pred, i1, {"move": null, "atk": tgt_i})
		else:
			_ai._apply(pred, i1, {"move": null, "atk": -2, "atk_obs": tc})
		# 记下"我这一手预计会挨什么"：被打的人是否反击、我掉多少 —— 下一手对账时一眼看出是哪一笔差了
		var hp1: int = int((pred as Object).units[i1].hp)
		var why := "预计挨 %d 点" % (hp0 - hp1) if hp0 != hp1 else "预计自己不掉血"
		if tgt_i >= 0 and not cu0 and bool((pred as Object).units[tgt_i].counter_used):
			why = "预计会被 %s 反击 %d 点" % [String((pred as Object).units[tgt_i].name), hp0 - hp1]
			out["counter_by_id"] = String(ids[tgt_i]) if tgt_i < ids.size() else ""
			out["counter_dmg"] = hp0 - hp1
		out["actor_id"] = String(ids[i1]) if i1 < ids.size() else ""
		out["actor_hp_before"] = hp0     # 出手前自己的血（判"盾被吃掉"那条要用）
		# 记下"被攻击方在模拟里的反击相关状态"：出"没料到却真挨了反击"时，一眼看出是哪道闸门压掉的
		if tgt_i >= 0 and tgt_i < (pred as Object).units.size():
			var tu = (pred as Object).units[tgt_i]
			out["tgt_probe"] = "目标 %s：eatk=%d 贴身=%s 出手前已反击=%s 出手后=%s 眩晕=%s 距离%d 射程%d 攻型%d" % [
				String(tu.name), int(tu.eatk), str(tu.pin_flag), str(cu0), str(tu.counter_used), str(tu.stunned),
				_grid.distance((pred as Object).units[i1].cell, tu.cell), int(tu.atk_range), int(tu.atk_type)]
		out["why"] = why
	else:
		out["skip"] = "这一手是 %s（没有局面变化可预测）" % kind
		return out
	out["pred"] = pred
	out["terrain"] = _terrain_pred(pred)
	return out


## `_self_side` 为空时的兜底推断（正常路径由 `choose()` 从任务的 `side` 字段钉好）
func _infer_self_side(obs: Dictionary) -> String:
	for h in obs.get("ownPool", []):
		if h is Dictionary:
			var s := _s((h as Dictionary).get("side"))
			if s != "" and s != "neutral":
				return s
	return _s(obs.get("currentSide"))


func _idx_of(ids: Array, instance_id: String) -> int:
	for i in ids.size():
		if String(ids[i]) == instance_id:
			return i
	return -1


func _terrain_pred(sim) -> Dictionary:
	var ob := {}
	for c in (sim as Object).obstacles.keys():
		ob[_cell_key(_to_remote(c))] = int((sim as Object).obstacles[c])
	var bombs: Array = []
	for c in (sim as Object).bombs.keys():
		bombs.append(_cell_key(_to_remote(c)))
	var buffs := {}
	for c in (sim as Object).buff_cells.keys():
		buffs[_cell_key(_to_remote(c))] = String((sim as Object).buff_cells[c])
	var gold: Array = []
	for c in (sim as Object).gold_cells.keys():
		gold.append(_cell_key(_to_remote(c)))
	return {"obstacles": ob, "bombs": bombs, "buffs": buffs, "gold": gold}


## 拿**这一手拿到的真观察**去对上一手的预测，列出每一处出入。
func _diff_prediction(match_id: String, obs: Dictionary, built: Dictionary) -> Dictionary:
	if _pred.is_empty():
		return {}
	var out := {"skip": "", "items": [], "n_mine": 0, "n_other": 0, "act": String(_pred.get("act", "")),
		"why": String(_pred.get("why", ""))}
	if String(_pred.get("match", "")) != match_id:
		out["skip"] = "换了局"
		return out
	if String(_pred.get("phase", "")) != String(obs.get("phase", "")):
		out["skip"] = "阶段变了（%s → %s）" % [_pred.get("phase", "?"), obs.get("phase", "?")]
		return out
	if int(_pred.get("turn", -1)) != int(obs.get("turnCount", -2)):
		out["skip"] = "对手回合已经过完（turn %s → %s）" % [_pred.get("turn", "?"), obs.get("turnCount", "?")]
		return out
	var skip := String(_pred.get("skip", ""))
	if skip != "":
		out["skip"] = skip
		return out
	# 布阵/替补那种"只记一个英雄"的预测
	var expect: Dictionary = _pred.get("expect", {})
	if not expect.is_empty():
		var hit := false
		for h in obs.get("ownPool", []):
			if h is Dictionary and _s((h as Dictionary).get("id")) == String(expect.get("id", "")):
				var cell := _cell_pair(_to_remote(_to_local((h as Dictionary).get("pos", {}))))
				if cell == expect.get("cell") and _i((h as Dictionary).get("health"), 0) > 0:
					hit = true
				else:
					out["items"].append({"side": "我", "who": String(expect.get("hero", "")),
						"field": "落点/血量", "want": str(expect.get("cell")), "got": "%s 血%s" % [str(cell), str((h as Dictionary).get("health"))]})
		if not hit and out["items"].is_empty():
			out["items"].append({"side": "我", "who": String(expect.get("hero", "")),
				"field": "登场", "want": "满血站在 %s" % str(expect.get("cell")), "got": "没看到"})
		out["n_mine"] = out["items"].size()
		return out
	var pred = _pred.get("pred", null)
	if pred == null or built.is_empty():
		out["skip"] = "没有可比对的预测"
		return out
	# ---- 单位逐个对（按协议 hero 实例 id）----
	var pids: Array = _pred.get("ids", [])
	var phero: Array = _pred.get("hero_of", [])
	var act_ids: Array = built.get("ids", [])
	var seen := {}
	for i in pids.size():
		var id := String(pids[i])
		seen[id] = true
		var ai := act_ids.find(id)
		var pu = (pred as Object).units[i] if i < (pred as Object).units.size() else null
		if pu == null:
			continue
		var want_cell := _cell_pair(_to_remote(pu.cell))
		if ai < 0:
			if pu.alive:
				out["items"].append({"side": "我" if int(pu.fn) == int(DataRegistry.Faction.ENEMY) else "敌",
					"who": String(phero[i]) if i < phero.size() else id, "field": "在场",
					"want": "活着@%s" % str(want_cell), "got": "实际不在场"})
			continue
		var au = ((built["sim"] as Object).units[ai])
		if au == null:
			continue
		var got_cell := _cell_pair(_to_remote(au.cell))
		var is_mine := int(pu.fn) == int(DataRegistry.Faction.ENEMY)
		if want_cell != got_cell:
			out["items"].append({"side": "我" if is_mine else "敌", "who": String(phero[i]),
				"field": "位置", "want": str(want_cell), "got": str(got_cell)})
		if int(pu.hp) != int(au.hp):
			out["items"].append({"side": "我" if is_mine else "敌", "who": String(phero[i]),
				"field": "血量", "want": str(int(pu.hp)), "got": str(int(au.hp))})
		var m0 := _mark_set(pu)
		var m1 := _mark_set(au)
		if m0 != m1:
			out["items"].append({"side": "我" if is_mine else "敌", "who": String(phero[i]),
				"field": "状态", "want": ",".join(m0) if not m0.is_empty() else "无",
				"got": ",".join(m1) if not m1.is_empty() else "无"})
	for i in act_ids.size():
		var id2 := String(act_ids[i])
		if seen.has(id2):
			continue
		var au2 = ((built["sim"] as Object).units[i])
		if au2 == null:
			continue
		out["items"].append({"side": "我" if int(au2.fn) == int(DataRegistry.Faction.ENEMY) else "敌",
			"who": String((built["hero_of"] as Array)[i]) if i < (built["hero_of"] as Array).size() else id2,
			"field": "多出", "want": "预测里没有它", "got": "实际在 %s" % str(_cell_pair(_to_remote(au2.cell)))})
	# ---- 地形对 ----
	var t0: Dictionary = _pred.get("terrain", {})
	if not t0.is_empty():
		var t1 := _terrain_pred(built["sim"])
		for k in (t0["obstacles"] as Dictionary).keys():
			var v0 := int(t0["obstacles"][k])
			var v1 := int((t1["obstacles"] as Dictionary).get(k, -1))
			if v0 != v1:
				out["items"].append({"side": "地", "who": "障碍 %s" % k, "field": "耐久",
					"want": str(v0), "got": ("没了" if v1 < 0 else str(v1))})
		for k2 in (t1["obstacles"] as Dictionary).keys():
			if not (t0["obstacles"] as Dictionary).has(k2):
				out["items"].append({"side": "地", "who": "障碍 %s" % k2, "field": "多出", "want": "没有", "got": "耐久 %d" % int(t1["obstacles"][k2])})
		var b0: Array = (t0["bombs"] as Array).duplicate()
		var b1: Array = (t1["bombs"] as Array).duplicate()
		b0.sort()
		b1.sort()
		if b0 != b1:
			out["items"].append({"side": "地", "who": "炸弹", "field": "集合", "want": ",".join(b0) if not b0.is_empty() else "无", "got": ",".join(b1) if not b1.is_empty() else "无"})
		var g0: Array = (t0["gold"] as Array).duplicate()
		var g1: Array = (t1["gold"] as Array).duplicate()
		g0.sort()
		g1.sort()
		if g0 != g1:
			out["items"].append({"side": "地", "who": "金块", "field": "集合", "want": ",".join(g0) if not g0.is_empty() else "无", "got": ",".join(g1) if not g1.is_empty() else "无"})
	for it in out["items"]:
		if String((it as Dictionary).get("side", "")) == "我":
			out["n_mine"] = int(out["n_mine"]) + 1
		else:
			out["n_other"] = int(out["n_other"]) + 1
	# 【自纠正】"预测会被 X 反击 N 点"，而真实局面里自己**恰好**只差这一笔（没有别的差异）⇒
	#   X 本回合的反击名额已经用掉了。⚠️ 判据卡死成"差额恰好等于那笔反击、且该单位没有别的出入"，
	#   否则盾/治疗/别的差异都会被误读成"它没反击"（第一版就吃过亏：pin 算错多出的差额被当成"没反击"）。
	var cby := String(_pred.get("counter_by_id", ""))
	var cdmg := int(_pred.get("counter_dmg", 0))
	var actor := String(_pred.get("actor_id", ""))
	if actor != "":
		var ids_p: Array = _pred.get("ids", [])
		var hero_p: Array = _pred.get("hero_of", [])
		var pi: int = ids_p.find(actor)
		var ai2: int = (built.get("ids", []) as Array).find(actor)
		var ahero := String(hero_p[pi]) if (pi >= 0 and pi < hero_p.size()) else ""
		var hits := 0
		var only_shield := true
		for it2 in out["items"]:
			if ahero != "" and String((it2 as Dictionary).get("who", "")) == ahero:
				hits += 1
				var fld := String((it2 as Dictionary).get("field", ""))
				if fld != "状态" or String((it2 as Dictionary).get("got", "")).find("圣盾") < 0:
					only_shield = false
		if pi >= 0 and ai2 >= 0 and pi < (pred as Object).units.size() and hits <= 1:
			var pred_hp: int = int((pred as Object).units[pi].hp)
			var real_hp: int = int((built["sim"] as Object).units[ai2].hp)
			var pre_hp: int = int(_pred.get("actor_hp_before", pred_hp))
			var gap := real_hp - pred_hp
			# ⚠️【2026-10-01 擂台实测后定的口径】账要记"**看见过的反击**"，而且有三条铁证（用户口径：
			#   "一个敌人本回合第一次被打就反击、第二次就不反击，复仇者除外" ⇒ 反击是**简单的次数账**）：
			#   ① 我们正好掉了那笔 ⇒ 它反击了 ✔ 记
			#   ② **这一手完全按预测发生**（连"盾被这笔反击吃掉"都对上了）⇒ 那笔反击履约了 ✔ 记
			#      ← 这条原来漏了：被盾吃掉的反击**不掉血**，没有任何差额可看，于是重复怕它
			#   ③ 我们没料到却挨了 ⇒ 多半就是它的反击 ✔ 记（同时报 `?!意外挨打`）
			#   只有"我以为会挨、实际没挨"**不记**（那说明它这一手没反击；原因可能不止"名额"，不猜）。
			if cdmg > 0 and gap == -cdmg:
				if cby != "":
					_countered["%s|%d|%s" % [_cur_match, _cur_turn, cby]] = true
			elif hits == 0 and cby != "":
				_countered["%s|%d|%s" % [_cur_match, _cur_turn, cby]] = true
			elif cdmg <= 0 and gap < 0:
				# 我们**没料到**会挨打，实际挨了：多半就是被攻击目标的反击 ⇒ 记下它（同时报出来）
				if cby != "":
					_countered["%s|%d|%s" % [_cur_match, _cur_turn, cby]] = true
				out["items"].append({"side": "?!", "who": ahero if ahero != "" else actor, "field": "意外挨打",
					"want": "预计自己不掉血", "got": "实际 %d→%d（差 %d）" % [pred_hp, real_hp, -gap]})
				out["n_mine"] = int(out["n_mine"]) + 1
	return out


func _mark_set(u) -> Array:
	var out: Array = []
	if u.shield:
		out.append(StatusDB.label(StatusDB.SHIELD))
	if u.stunned:
		out.append(StatusDB.label(StatusDB.STUN))
	if u.silenced:
		out.append(StatusDB.label(StatusDB.SILENCE))
	if u.frozen:
		out.append(StatusDB.label(StatusDB.FREEZE))
	if u.heavy:
		out.append(StatusDB.label(StatusDB.HEAVY))
	if u.poisoned:
		out.append(StatusDB.label(StatusDB.POISON))
	if u.atkdown:
		out.append(StatusDB.label(StatusDB.ATKDOWN))
	out.sort()
	return out


func _cell_key(c: Variant) -> String:
	if c is Dictionary:
		return "(%d,%d)" % [_i((c as Dictionary).get("x"), -1), _i((c as Dictionary).get("y"), -1)]
	return str(c)


func _push_watch(task: Dictionary, obs: Dictionary, legal: Array, pick: Dictionary,
		built: Dictionary, start_sim, plan: Array, ms: int, budget: int, diff: Dictionary = {}) -> void:
	if _watch == null:
		return
	var kinds := {}
	for a in legal:
		var k := String((_d((a as Dictionary).get("intent", {})).get("kind", "?")))
		kinds[k] = int(kinds.get(k, 0)) + 1
	var snap := {
		"at": Time.get_time_string_from_system(),
		"engine": "战旗GDScript AI 1.0.0",
		"tier": _tier, "tierName": ["简单", "普通", "困难", "噩梦"][_tier],
		"policy": _policy, "cachePlan": _use_cache,
		"match": String(task.get("matchId", "?")), "side": _self_side,
		"phase": String(obs.get("phase", "?")), "turn": int(obs.get("turnCount", 0)),
		"actingSide": String(obs.get("currentSide", "?")),
		"remainingMs": int(task.get("remainingMs", 0)), "budgetMs": budget, "thinkMs": ms,
		"legalCount": legal.size(), "legalKinds": kinds,
		"pick": {
			"note": String(pick.get("note", "")),
			"intent": _intent_text(_find_intent_of(legal, String(pick.get("actionId", "")))),
		},
		"plan": _plan_view(plan, built, start_sim),
		"score": _score_view(start_sim, plan),
		"cands": _candidates_view(legal, built, start_sim, pick),
		"diff": diff,
	}
	# 出入点名（日志里也留一份，方便事后查）
	if not diff.is_empty() and int(diff.get("n_mine", 0)) > 0:
		var bits: Array = []
		for it in diff.get("items", []):
			if String((it as Dictionary).get("side", "")) == "我":
				bits.append("%s %s 预测%s→实际%s" % [String((it as Dictionary).get("who", "?")),
					String((it as Dictionary).get("field", "?")), String((it as Dictionary).get("want", "?")),
					String((it as Dictionary).get("got", "?"))])
		_eng._log("!! 与裁判对不上 %d 处（上一手：%s）：%s" % [int(diff["n_mine"]), String(diff.get("act", "")), "；".join(bits)])
	var view_sim = start_sim if start_sim != null else built.get("sim", null)
	if view_sim != null:
		var uv := _units_view(view_sim, built if not built.is_empty() else {}, obs)
		snap["mine"] = uv["mine"]
		snap["foe"] = uv["foe"]
	# 本回合"敌方已反击过"的账（自己推的，见 `_countered`）：面板上直接标在对手那一列
	var used: Array = []
	for k in _countered.keys():
		var ks := String(k)
		if ks.begins_with("%s|%d|" % [_cur_match, _cur_turn]):
			used.append(ks.substr(ks.rfind("|") + 1))
	snap["counter_used"] = used
	snap["terrain"] = _terrain_view(obs)
	snap["pool"] = _pool_view(obs)
	_watch.push(snap)


func _find_intent_of(legal: Array, action_id: String) -> Variant:
	for a in legal:
		if String((a as Dictionary).get("actionId", "")) == action_id:
			return (a as Dictionary).get("intent", {})
	return {}


## 协议意图 → 一行说明（面板用；与 ArenaEngine 里那份同形，ArenaEngine 的那份只打日志）
func _intent_text(it: Variant) -> String:
	if not (it is Dictionary):
		return "?"
	var d: Dictionary = it
	match _s(d.get("kind"), "?"):
		"DEPLOY":
			return "DEPLOY slot%d → %s" % [_i(d.get("slot"), -1), _cell_txt(_to_local(d.get("to", {})))]
		"MOVE":
			return "MOVE %s → %s" % [_s(d.get("heroId"), "?"), _cell_txt(_to_local(d.get("to", {})))]
		"ATTACK":
			return "ATTACK %s → %s" % [_s(d.get("heroId"), "?"), _cell_txt(_to_local(d.get("target", {})))]
		"WITHDRAW":
			return "WITHDRAW %s" % _s(d.get("heroId"), "?")
		"END_TURN":
			return "END_TURN（结束回合）"
	return _s(d.get("kind"), "?")


func _plan_view(plan: Array, built: Dictionary, start_sim) -> Array:
	var out: Array = []
	var ids: Array = built.get("ids", [])
	for st in plan:
		if not (st is Dictionary):
			continue
		var d: Dictionary = st
		var a: Dictionary = _d(d.get("action", {}))
		var idx := int(d.get("idx", -1))
		var row := {"who": String(ids[idx]) if (idx >= 0 and idx < ids.size()) else "#%d" % idx,
			"move": null, "atk": "", "obs": ""}
		if a.get("move", null) != null:
			row["move"] = _cell_pair(_to_remote(a["move"]))
		var atk := int(a.get("atk", -1))
		if atk == -2:
			row["obs"] = _cell_pair(_to_remote(a.get("atk_obs", Vector2i(-99, -99))))
		elif atk >= 0:
			var tgt := ""
			if start_sim != null and atk < (start_sim as Object).units.size():
				var tu = (start_sim as Object).units[atk]
				if tu != null:
					tgt = "%s@(%d,%d)" % [String(tu.name), int(_to_remote(tu.cell)["x"]), int(_to_remote(tu.cell)["y"])]
			row["atk"] = tgt
		out.append(row)
	return out


func _score_view(start_sim, plan: Array) -> Dictionary:
	if start_sim == null:
		return {}
	var out := {"now": float(_ai._evaluate(start_sim)), "terms": []}
	var end_sim = null
	if not plan.is_empty():
		end_sim = (start_sim as Object).clone()
		for st in plan:
			if not (st is Dictionary):
				continue
			var idx := int((st as Dictionary).get("idx", -1))
			var a: Dictionary = _d((st as Dictionary).get("action", {}))
			if idx >= 0 and idx < (end_sim as Object).units.size():
				_ai._apply(end_sim, idx, a)
		out["end"] = float(_ai._evaluate(end_sim, true))
	var d0: Dictionary = _ai._eval_breakdown(start_sim, false)
	var d1: Dictionary = _ai._eval_breakdown(end_sim, true) if end_sim != null else {}
	var keys: Array = []
	for k in d0.keys():
		keys.append(k)
	for k in d1.keys():
		if not keys.has(k):
			keys.append(k)
	var terms: Array = []
	for k in keys:
		var a0 = d0.get(k, null)
		var a1 = d1.get(k, null)
		if (a0 != null and absf(float(a0)) > 0.01) or (a1 != null and absf(float(a1)) > 0.01):
			terms.append([String(k), a0, a1])
	terms.sort_custom(func(x, y): return absf(float(x[2] if x[2] != null else x[1])) > absf(float(y[2] if y[2] != null else y[1])))
	out["terms"] = terms
	return out


## 双方单位（我方=sim 里的 ENEMY 标签，对手=PLAYER —— 见 `_unit_desc` 的约定）
func _units_view(sim, built: Dictionary, obs: Dictionary) -> Dictionary:
	var mine: Array = []
	var foe: Array = []
	var ids: Array = built.get("ids", [])
	var hero_of: Array = built.get("hero_of", [])
	for i in (sim as Object).units.size():
		var u = (sim as Object).units[i]
		if u == null or not u.alive:
			continue
		var row := {
			"id": String(ids[i]) if i < ids.size() else "?",
			"hero": String(hero_of[i]) if i < hero_of.size() else String(u.hero_id),
			"name": String(u.name), "cell": _cell_pair(_to_remote(u.cell)),
			"hp": int(u.hp), "maxHp": int(u.max_hp), "atk": int(u.eatk), "baseAtk": int(u.atk),
			"move": int(u.emove), "range": int(u.atk_range),
			"moved": bool(u.moved), "attacked": bool(u.attacked),
			"marks": _marks_of(u),
		}
		if int(u.fn) == int(DataRegistry.Faction.ENEMY):
			mine.append(row)
		else:
			foe.append(row)
	return {"mine": mine, "foe": foe}


func _marks_of(u) -> Array:
	var out: Array = []
	if u.shield:
		out.append(StatusDB.label(StatusDB.SHIELD))
	if u.stunned:
		out.append(StatusDB.label(StatusDB.STUN))
	if u.silenced:
		out.append(StatusDB.label(StatusDB.SILENCE))
	if u.frozen:
		out.append(StatusDB.label(StatusDB.FREEZE))
	if u.heavy:
		out.append(StatusDB.label(StatusDB.HEAVY))
	if u.poisoned:
		out.append(StatusDB.label(StatusDB.POISON))
	if u.atkdown:
		out.append(StatusDB.label(StatusDB.ATKDOWN))
	if u.thorn:
		out.append(StatusDB.label(StatusDB.THORN))
	if u.atk_use_buff > 0:
		out.append("攻道具+%d" % int(u.atk_use_buff))
	return out


func _terrain_view(obs: Dictionary) -> Dictionary:
	var obstacles: Array = []
	for b in obs.get("barriers", []):
		if b is Dictionary and int((b as Dictionary).get("kind", 0)) != GRAVE_KIND:
			obstacles.append({"cell": _cell_pair(_to_remote(_to_local((b as Dictionary).get("pos", {})))),
				"hp": _i((b as Dictionary).get("health"), 1)})
	var buffs: Array = []
	for eb in obs.get("envBuffs", []):
		var e := _d(eb)
		buffs.append({"cell": _cell_pair(_to_remote(_to_local(e.get("cell", {})))), "kind": _s(e.get("kind"))})
	var gold: Array = []
	for g in obs.get("goldCells", []):
		gold.append(_cell_pair(_to_remote(_to_local(g))))
	var bombs: Array = []
	for bm in obs.get("bombs", []):
		bombs.append(_cell_pair(_to_remote(_to_local(_d(bm).get("cell", {})))))
	return {"obstacles": obstacles, "buffs": buffs, "gold": gold, "bombs": bombs}


func _pool_view(obs: Dictionary) -> Array:
	var out: Array = []
	for h in obs.get("ownPool", []):
		if not (h is Dictionary):
			continue
		var hid := String(_kind2hero.get(int((h as Dictionary).get("kind", 0)), ""))
		var d: DataRegistry.HeroDef = _get_def(hid)
		out.append({"name": (String(d.display_name) if d != null else hid), "hero": hid,
			"status": _s((h as Dictionary).get("status"))})
	return out


func _cell_pair(c: Variant) -> Array:
	if c is Dictionary:
		return [int((c as Dictionary).get("x", -1)), int((c as Dictionary).get("y", -1))]
	if c is Vector2i:
		var r := _to_remote(c)
		return [int(r["x"]), int(r["y"])]
	return [-1, -1]


## 把计划的第一步映射成协议动作；同时把剩余步骤存进缓存。
func _consume_plan(task: Dictionary, obs: Dictionary, legal: Array, built: Dictionary, plan: Array) -> Dictionary:
	# 计划 → 语义意图（heroId + 目标格），不存 sim 下标（下一次任务的世界可能重排）
	var intents: Array = []
	for st in plan:
		var it := _intent_of_step(st, built)
		if not it.is_empty():
			intents.append(it)
	if intents.is_empty():
		return {}
	var first: Dictionary = intents[0]
	var m := _match_intent(legal, first)
	if String(m.get("aid", "")) == "":
		return {}
	_cache = {
		"match": String(task.get("matchId", "")), "turn": int(obs.get("turnCount", 0)),
		"phase": String(obs.get("phase", "")), "intents": intents, "i": 1,
		"hero": String(first.get("hero", "")),
		# 这一步同时要"移动后再打"时，下一手就是那一击
		"pending": (first.get("atk", {}) if String(m["used"]) == "move" else {}),
	}
	var note := _intent_note(first)
	return {"actionId": String(m["aid"]), "note": note}


## 计划里的一步 → 协议语义：{hero, mv(本地格|null), atk(协议格|null), obs(协议格|null)}
func _intent_of_step(st: Variant, built: Dictionary) -> Dictionary:
	if not (st is Dictionary):
		return {}
	var idx := int((st as Dictionary).get("idx", -1))
	var a: Dictionary = (st as Dictionary).get("action", {})
	var ids: Array = built["ids"]
	if idx < 0 or idx >= ids.size():
		return {}
	var out := {"hero": String(ids[idx]), "mv": null, "atk": {}, "obs": {}}
	var mv: Variant = a.get("move", null)
	if mv != null:
		out["mv"] = _to_remote(mv)
	var atk := int(a.get("atk", -1))
	if atk == -2:
		out["obs"] = _to_remote(a.get("atk_obs", Vector2i(-99, -99)))
	elif atk >= 0 and atk < ids.size():
		out["atk"] = _to_remote(built["cell"][atk])
	if out["mv"] == null and out["atk"].is_empty() and out["obs"].is_empty():
		return {}     # 空动作（原地不出手）→ 没有对应协议动作，跳过
	return out


func _intent_note(it: Dictionary) -> String:
	var bits: Array = []
	if it.get("mv", null) != null:
		bits.append("MOVE→%s" % _cell_txt(it["mv"]))
	if not (it["atk"] as Dictionary).is_empty():
		bits.append("ATTACK→%s" % _cell_txt(it["atk"]))
	if not (it["obs"] as Dictionary).is_empty():
		bits.append("ATTACK障碍→%s" % _cell_txt(it["obs"]))
	return "%s %s" % [String(it.get("hero", "?")), " + ".join(bits)]


## 按语义意图在 legalActions 里找对应的 actionId。
## 返回 {"aid": String, "used": "move"|"atk"|"obs"}；找不到时 aid 为空串。
## 一步"走 + 打"在协议里是**两个动作**：这里先交走（used="move"），那一击留给下一次任务。
func _match_intent(legal: Array, it: Dictionary) -> Dictionary:
	var hero := String(it.get("hero", ""))
	var mv: Variant = it.get("mv", null)
	var atk: Dictionary = it.get("atk", {})
	var obs_c: Dictionary = it.get("obs", {})
	if mv != null:
		var aid := _find_legal(legal, "MOVE", hero, mv)
		if aid != "":
			return {"aid": aid, "used": "move"}
	if not atk.is_empty():
		var a2 := _find_legal(legal, "ATTACK", hero, atk)
		if a2 != "":
			return {"aid": a2, "used": "atk"}
	if not obs_c.is_empty():
		var a3 := _find_legal(legal, "ATTACK", hero, obs_c)
		if a3 != "":
			return {"aid": a3, "used": "obs"}
	return {}


func _find_legal(legal: Array, kind: String, hero: String, cell: Dictionary) -> String:
	for a in legal:
		var d: Dictionary = a
		var it: Dictionary = d.get("intent", {})
		if String(it.get("kind", "")) != kind:
			continue
		var key := "target" if kind == "ATTACK" else "to"
		var c: Dictionary = it.get(key, {})
		if int(c.get("x", -1)) != int(cell.get("x", -2)) or int(c.get("y", -1)) != int(cell.get("y", -2)):
			continue
		if String(it.get("heroId", "")) != hero:
			continue
		return String(d.get("actionId", ""))
	return ""


## 缓存命中：先补上"上一步是走+打"里那一击，再走计划里的下一步。
func _try_cached(task: Dictionary, obs: Dictionary, legal: Array) -> Dictionary:
	if _cache.is_empty():
		return {}
	if String(_cache.get("match", "")) != String(task.get("matchId", "")) \
			or int(_cache.get("turn", -1)) != int(obs.get("turnCount", 0)) \
			or String(_cache.get("phase", "")) != String(obs.get("phase", "")):
		_cache = {}
		return {}
	var pend: Dictionary = _cache.get("pending", {})
	if not pend.is_empty():
		var aid := _find_legal(legal, "ATTACK", String(_cache.get("hero", "")), pend)
		_cache["pending"] = {}
		if aid != "":
			return {"actionId": aid, "note": "计划·补那一击 ATTACK→%s" % _cell_txt(pend)}
		# 目标已经不在/打不到了：这一击作废，继续用计划里的下一步
	var intents: Array = _cache.get("intents", [])
	var i := int(_cache.get("i", 0))
	while i < intents.size():
		var it: Dictionary = intents[i]
		var m := _match_intent(legal, it)
		i += 1
		_cache["i"] = i
		if String(m.get("aid", "")) != "":
			_cache["hero"] = String(it.get("hero", ""))
			_cache["pending"] = (it.get("atk", {}) if String(m["used"]) == "move" else {})
			return {"actionId": String(m["aid"]), "note": "计划·缓存 %s" % _intent_note(it)}
	# 计划用完：先看还有没有"能打却没排上"的单位（有就补一刀），再结束回合
	var b_end := _build_sim(obs)
	var late := _late_strike(obs, legal, b_end)
	var covered := _plan_covered_ids()
	var idle := _idle_ids(b_end)
	if not late.is_empty():
		_cache = {}
		return late
	var end := _find_end_turn(legal)
	if not idle.is_empty():
		_warn_once("end_idle_" + str(idle.size()), "!! 计划用完 → END_TURN，但还有单位没被计划安排：%s（它们这一回合就不动了）" % ", ".join(idle))
	_cache = {}
	if end != "":
		return {"actionId": end, "note": "计划用完 → END_TURN（已安排 %d 个单位%s）" % [
			covered.size(), ("" if idle.is_empty() else "，未安排：" + ", ".join(idle))]}
	return {}


## 1 层兜底：每个合法动作 apply 到一份 sim 副本上，用 AI 自己的 `_evaluate` 打分。
## skip_bombs=true 时连"停在炸弹格"的候选都不收（见 `_guarded`）。
func _fallback_greedy(obs: Dictionary, legal: Array, skip_bombs: bool = false) -> Dictionary:
	var built := _build_sim(obs)
	if built.is_empty():
		return _any_legal(legal, "no-sim")
	var sim = built["sim"]
	var base := float(_ai._evaluate(sim))
	# 候选：所有 ATTACK + "落点能打到人"的 MOVE + END_TURN（当前局面分）
	var cands: Array = []
	for a in legal:
		var d: Dictionary = a
		var it: Dictionary = d.get("intent", {})
		var kind := String(it.get("kind", ""))
		if kind == "MOVE" and skip_bombs and _bad_bomb_move(obs, legal, String(d.get("actionId", ""))):
			continue
		if kind == "ATTACK" or kind == "MOVE":
			cands.append(d)
		if cands.size() >= 40:
			break
	var best_aid := ""
	var best_s := base - 0.0001      # 略低于"什么都不做"，避免无意义乱动
	var end := _find_end_turn(legal)
	var t0 := Time.get_ticks_msec()
	for d in cands:
		if Time.get_ticks_msec() - t0 > maxi(_think_ms * 2, 3000):
			break
		var it: Dictionary = d.get("intent", {})
		var hid := String(it.get("heroId", ""))
		var idx := _index_of_id(built, hid)
		if idx < 0:
			continue
		var act := {}
		var kind := String(it.get("kind", ""))
		if kind == "MOVE":
			act = {"move": _to_local(it.get("to", {})), "atk": -1}
		else:
			var tc := _to_local(it.get("target", {}))
			if built["occ"].has(tc):
				act = {"move": null, "atk": int(built["occ"][tc])}
			else:
				act = {"move": null, "atk": -2, "atk_obs": tc}
		var c = sim.clone()
		_ai._apply(c, idx, act)
		var s := float(_ai._evaluate(c))
		if s > best_s:
			best_s = s
			best_aid = String(d.get("actionId", ""))
	if best_aid != "":
		return {"actionId": best_aid, "note": "1层兜底（%.1f>%.1f）" % [best_s, base]}
	if end != "":
		return {"actionId": end, "note": "1层兜底：不划算 → END_TURN"}
	return _any_legal(legal, "greedy-none")


# ============================================================ 局面还原 ============================================================

## Observation → BattleAI.build_state 的输入。
## 返回 {sim, ids[], hero_of[], fn[], cell[]}：
##   ids[i]     = 协议里的 hero 实例 id（用来把 AI 的动作映射回协议）
##   hero_of[i] = 项目 hero_id
##   fn[i]      = sim 里的阵营标签：**我方=ENEMY、对方=PLAYER**（AI 把 ENEMY 当自己）
##   cell[i]    = 项目的 Vector2i
func _build_sim(obs: Dictionary) -> Dictionary:
	if _self_side == "":
		_self_side = _infer_self_side(obs)   # 兜底：正常路径由 `choose()` 用任务的 side 先钉好
	var self_side := _self_side
	var descs: Array = []
	var ids: Array = []
	var hero_of: Array = []
	var fns: Array = []
	var cells: Array = []
	var occ: Dictionary = {}

	# ---- 先按"场地物件"收：障碍/墓碑/道具/炸弹/金块 ----
	var obstacles: Dictionary = {}
	var graves: Dictionary = {}
	var buffs: Dictionary = {}
	var golds: Dictionary = {}
	var bombs: Dictionary = {}
	for b in obs.get("barriers", []):
		if not (b is Dictionary):
			continue
		var kind := int(b.get("kind", 0))
		var cell := _to_local(b.get("pos", {}) if b.get("pos", null) != null else {})
		if not _grid.in_bounds(cell):
			continue
		if kind == GRAVE_KIND:
			graves[cell] = true
		else:
			obstacles[cell] = maxi(int(b.get("health", 1)), 1)
			if not _barrier_kinds.has(kind):
				_warn_once("bar_" + str(kind), "?? 没见过的障碍 kind=%d（按耐久 %d 收下）" % [kind, int(b.get("health", 1))])
	for g in obs.get("goldCells", []):
		var gc := _to_local(g)
		if _grid.in_bounds(gc):
			golds[gc] = true
	for bm in obs.get("bombs", []):
		if bm is Dictionary:
			var bc := _to_local(bm.get("cell", {}))
			if _grid.in_bounds(bc):
				bombs[bc] = true
	for eb in obs.get("envBuffs", []):
		if not (eb is Dictionary):
			continue
		var ec := _to_local(eb.get("cell", {}))
		if not _grid.in_bounds(ec):
			continue
		buffs[ec] = _buff_kind(String(eb.get("kind", "")))

	# ---- 双方场上的单位：己方全池 + 对手已登场 + 召唤物（先收原始条目，再统一下标）----
	var wind := { "red": false, "blue": false }
	var raw: Array = []
	for list_key in ["ownPool", "opponentRevealed", "summons"]:
		for h in obs.get(list_key, []):
			if not (h is Dictionary):
				continue
			var pos = h.get("pos", null)
			if pos == null:
				continue
			var st := String(h.get("status", ""))
			if st == "dead" or st == "quit":
				# 阵亡/撤退留下的墓碑：协议没单列墓碑，只能按"它还躺在这个格子上"来判
				# （同格已经有活人/障碍/墓碑时忽略，见下面的收尾）
				var gcell := _to_local(pos)
				if _grid.in_bounds(gcell) and not graves.has(gcell):
					graves[gcell] = true
				continue
			if st == "wait":
				continue
			if int(h.get("health", 0)) <= 0:
				continue
			var cell2 := _to_local(pos)
			if not _grid.in_bounds(cell2):
				continue
			var hside := String(h.get("side", "neutral"))
			if String(_kind2hero.get(int(h.get("kind", 0)), "")) == "hero_43" and hside != "neutral":
				wind[hside] = true
			raw.append(h)
	for i in raw.size():
		var h: Dictionary = raw[i]
		var hid := String(_kind2hero.get(int(h.get("kind", 0)), ""))
		var hsid := String(h.get("side", "neutral"))
		ids.append(String(h.get("id", "")))
		hero_of.append(hid)
		fns.append(DataRegistry.Faction.ENEMY if hsid == self_side else DataRegistry.Faction.PLAYER)
		cells.append(_to_local(h.get("pos", {})))
		occ[cells[i]] = i
	# descs 的 `owner`（召唤物主人）要的是**本 sim 里的下标** ⇒ 先有 ids 才能算
	var pin := _adjacent_map(obs)
	for i in raw.size():
		descs.append(_unit_desc(raw[i], String((raw[i] as Dictionary).get("side", "neutral")), wind, obs, ids, pin))

	# ---- 收尾：墓碑别压在活人/障碍上 ----
	for c in occ.keys():
		graves.erase(c)
		obstacles.erase(c)

	var rosters := _guess_rosters(obs)
	var sim = _ai.build_state(descs, occ, golds, graves, obstacles, bombs, buffs, -1, rosters, {})
	# [虚弱]（协议）= [麻痹]（项目，ATKDOWN）：降攻那 -1 走 atk_mod，让 sim 自己按"远程被贴身"
	# 那套公式重算（只把 −1 混进 eatk 的话，"被贴身时基础攻压 1"的算式会差 1 点）。
	var weak_n := 0
	for i in sim.units.size():
		if sim.units[i] != null and sim.units[i].atkdown:
			sim.units[i].atk_mod = -1
			weak_n += 1
	if weak_n > 0:
		_ai._sim_sync_pins(sim)
	# 记下"双方此刻已上阵的 hero_id"（布阵评分要"看自己人 + 看对面"）
	_last_own = []
	_last_foe = []
	for i in hero_of.size():
		if int(fns[i]) == int(DataRegistry.Faction.ENEMY):
			_last_own.append(String(hero_of[i]))
		else:
			_last_foe.append(String(hero_of[i]))
	return {"sim": sim, "ids": ids, "hero_of": hero_of, "fn": fns, "cell": cells, "occ": occ}


## 实例 id → 此刻是否与**敌方单位**相邻（远程"被贴身"的判据，与真实 `_sync_ranged_adjacent` 同义）。
## 中立单位（障碍/墓碑）不算敌人。
func _adjacent_map(obs: Dictionary) -> Dictionary:
	var info: Dictionary = {}
	for key in ["ownPool", "opponentRevealed", "summons"]:
		for h in obs.get(key, []):
			if not (h is Dictionary):
				continue
			var d: Dictionary = h
			if d.get("pos", null) == null:
				continue
			var st := _s(d.get("status"))
			if st == "dead" or st == "quit" or st == "wait":
				continue
			var sid := _s(d.get("side"))
			if sid == "neutral" or sid == "":
				continue
			info[_s(d.get("id"))] = {"cell": _to_local(d.get("pos", {})), "side": sid}
	var out: Dictionary = {}
	for id in info.keys():
		var c: Vector2i = info[id]["cell"]
		var s: String = info[id]["side"]
		var adj := false
		for nb in _grid.neighbors(c):
			for id2 in info.keys():
				if id2 == id or info[id2]["side"] == s:
					continue
				if info[id2]["cell"] == nb:
					adj = true
					break
			if adj:
				break
		out[id] = adj
	return out


## 单位 desc（键名与 `BattleAI.build_state` 的读取表逐字对齐，见 src/BattleAI.gd:1731-1798）。
## ids = 本次 sim 的单位顺序（下标 i ↔ 协议 hero 实例 id），`owner` 要的是这个下标。
## pin = `_adjacent_map()` 的结果（实例 id → 是否与敌方单位相邻），只给远程单位用。
func _unit_desc(h: Dictionary, side: String, wind: Dictionary, obs: Dictionary, ids: Array, pin: Dictionary) -> Dictionary:
	var kind := int(h.get("kind", 0))
	var hid := String(_kind2hero.get(kind, ""))
	var def: DataRegistry.HeroDef = _get_def(hid)
	var hd: Dictionary = _kind_hero_def.get(kind, {})
	if hid == "":
		_warn_once("kind_unknown_" + str(kind), "!! 未知 kind=%d（%s）：该单位按空壳收下，AI 会低估它" % [kind, _s(h.get("name"), "?")])
	# 攻/血/速：以规则包为准（那才是这盘比赛的真相）；射程/技能/类型本地表（协议没给）
	var atk := int(hd.get("attackPower", 1 if def == null else int(def.atk)))
	var max_hp := int(hd.get("maxHealth", 10 if def == null else int(def.max_hp)))
	var move := int(hd.get("mobility", 2 if def == null else int(DataRegistry.spawn_move(def))))
	var ar := 1
	var atk_type := 0
	var skills: Array = []
	var nm := String(h.get("name", hid))
	if def != null:
		ar = int(DataRegistry.spawn_attack_range(def))
		atk_type = int(def.attack_type)
		skills = (def.skills as Array).duplicate()
		nm = String(def.display_name)
	var markers: Array = _ar(h.get("markers", []))
	var buff: Dictionary = _d(h.get("buff"))
	var item_atk := _i(buff.get("attack"), 0)             # 场地"攻击力上升"：下一次攻击 +2，可叠
	var turn_bonus := _i(h.get("turnAttackBonus"), 0)     # 本回合加攻（烈焰祭司/锤头鲨/冲锋…）
	var sustain := _i(h.get("sustainAttackBonus"), 0)     # 持续加攻（太阳斩那类，攻击后递减）
	# 古灵精怪变身：这一手它**当被模仿的那个英雄用** ⇒ 攻/血/速/射程/技能都按被模仿者算，
	# hero_id 仍留 hero_28（让 hero_28 的变身专属分支照旧认得它）。
	var mk = h.get("mimicKind", null)
	if mk != null:
		var mhid := String(_kind2hero.get(int(mk), ""))
		var mdef: DataRegistry.HeroDef = _get_def(mhid)
		if mdef != null:
			var mhd: Dictionary = _kind_hero_def.get(int(mk), {})
			atk = int(mhd.get("attackPower", int(mdef.atk)))
			max_hp = int(mhd.get("maxHealth", int(mdef.max_hp)))
			move = int(mhd.get("mobility", _local_base_move(mdef)))
			ar = int(DataRegistry.spawn_attack_range(mdef))
			atk_type = int(mdef.attack_type)
			skills = (mdef.skills as Array).duplicate()
	var eatk := maxi(atk + item_atk + turn_bonus + sustain, 0)
	# ⚠️【2026-10-01 实机挖出来的根因】远程单位"被贴身"时，真实 `Unit.effective_atk()` 是
	#   **先把基础攻击压成 1**，再叠道具/本回合加攻/持续加攻。我们这里原来一律按未贴身的值给，
	#   于是 sim 的 `_sim_sync_pins` 反推 `pin_buffs = eatk − use_buff − base_atk`（base 取 1）
	#   会推出 "buff +4" ⇒ 之后每次贴身反击都按 1+4=5 算（影丸 atk5 被贴身，真机反击是 1，我们算 5）。
	#   一条错值连锁带出两类现象：① 我方血量总比预测多 4~5（白怕反击）② 自纠正误判"它已经反击过"，
	#   下一手又真的挨了反击（真机 −3）。整局 10 手出入全是这一条。
	var base_eff := atk
	if atk_type == int(DataRegistry.AttackType.RANGED) and bool(pin.get(_s(h.get("id")), false)):
		base_eff = 1
	eatk = maxi(base_eff + item_atk + turn_bonus + sustain, 0)
	var st := _s(h.get("status"))
	# 移动力：协议只给静态值 ⇒ 自己叠 [冰冻]−1、[眩晕]/[荆棘]→0、风语者光环 +1
	var emove := move
	if _has(markers, "freeze"):
		emove -= 1
	if _has(markers, "stun"):
		emove = 0
	if side != "neutral" and bool(wind.get(side, false)) and hid != "hero_43":
		emove += 1
	emove = maxi(emove, 0)
	var owner_idx := -1
	var sb := _s(h.get("summonedBy"))
	if sb != "":
		owner_idx = ids.find(sb)
	return {
		"fn": DataRegistry.Faction.ENEMY if side == _self_side else DataRegistry.Faction.PLAYER,
		"hero": hid,
		"cell": _to_local(h.get("pos", {})),
		"hp": _i(h.get("health"), 1),
		"max_hp": max_hp,
		"atk": atk,
		"eatk": eatk,
		"move": move,
		"emove": emove,
		"atk_range": ar,
		"atk_type": atk_type,
		"skills": skills,
		"name": nm,
		"atk_use_buff": item_atk,
		"moved": st == "moved" or st == "finish",
		"attacked": st == "finish",
		# 协议不给"本回合是否已反击过"⇒ 用自纠正记住的（见 `_countered`）
		"counter_used": _countered.has("%s|%d|%s" % [_cur_match, _cur_turn, _s(h.get("id"))]),
		"stunned": _has(markers, "stun"),
		"silenced": _has(markers, "silence"),
		"shield": bool(buff.get("shield", false)),
		"heavy": _has(markers, "wound"),
		"poisoned": _has(markers, "poison"),
		"frozen": _has(markers, "freeze"),
		"atkdown": _has(markers, "weak"),
		"immune_bombs": hid == "hero_35",
		"can_pickup_gold": hid == "hero_42",
		"owner": owner_idx,
		# 圣光(hero_22)的"每回合限一次"名额：协议直接给了 ⇒ 别让模拟以为还能再发一面盾
		"once_this_turn": bool(_d(obs.get("holyLightUsedThisTurn")).get(side, false)),
	}


## 双方替补池（`rosters`）：我方 8 人池里没上场的全知道；对手**只知道人数**，其余按公开英雄集
## 确定性采样补足（同一场同一局面永远同一结果，便于复盘；协议本来就允许我们不知道）。
func _guess_rosters(obs: Dictionary) -> Dictionary:
	var mine: Array = []
	for h in obs.get("ownPool", []):
		if h is Dictionary and String(h.get("status", "")) == "wait":
			var hid := String(_kind2hero.get(int(h.get("kind", 0)), ""))
			if hid != "":
				mine.append(hid)
	var theirs: Array = []
	var need := int(obs.get("opponentBenchCount", 0))
	if need > 0:
		var seen: Dictionary = {}
		for h in obs.get("opponentRevealed", []):
			if h is Dictionary:
				seen[String(_kind2hero.get(int(h.get("kind", 0)), ""))] = true
		for h in obs.get("ownPool", []):
			if h is Dictionary:
				seen[String(_kind2hero.get(int(h.get("kind", 0)), ""))] = true
		var pool: Array = []
		for kind in _kind2hero.keys():
			var hid2 := String(_kind2hero[kind])
			if hid2.begins_with("hero_") and not seen.has(hid2):
				pool.append(hid2)
		pool.sort()
		# 用局面哈希当随机源（不用全局 RNG：跨进程可复现）
		var seedv := 0
		for ch in JSON.stringify(obs).md5_text():
			seedv = (seedv * 131 + ch.unicode_at(0)) & 0x7fffffff
		for i in need:
			if pool.is_empty():
				break
			theirs.append(String(pool[seedv % pool.size()]))
			seedv = (seedv * 1103515245 + 12345) & 0x7fffffff
	return { DataRegistry.Faction.ENEMY: mine, DataRegistry.Faction.PLAYER: theirs }


func _buff_kind(k: String) -> String:
	match k:
		"attack": return "atk"       # 协议 EnvBuffKind 的 attack/heart/shield ↔ sim 的 atk/heal/shield
		"heart": return "heal"
		"shield": return "shield"
		_: return "atk"


# ============================================================ 小工具 ============================================================

## 协议格 → 项目格（见文件头 ①）
func _to_local(cell: Variant) -> Vector2i:
	if not (cell is Dictionary) or (cell as Dictionary).is_empty():
		return Vector2i(-99, -99)
	var c: Dictionary = cell
	var x := int(c.get("x", -99))
	var y := int(c.get("y", -99))
	if x < 0 or y < 0:
		return Vector2i(-99, -99)
	return Vector2i(x, (y + 1) if x % 2 == 0 else y)


## 项目格 → 协议格
func _to_remote(c: Vector2i) -> Dictionary:
	return {"x": c.x, "y": (c.y - 1) if c.x % 2 == 0 else c.y}


func _cell_txt(c: Variant) -> String:
	if c is Dictionary:
		return "(%s,%s)" % [str(c.get("x", "?")), str(c.get("y", "?"))]
	if c is Vector2i:
		var r := _to_remote(c)
		return "(%d,%d)" % [int(r["x"]), int(r["y"])]
	return "?"


func _has(arr: Array, v: String) -> bool:
	return arr.has(v)


# ---- 协议字段是"显式 null"的（如 summonedBy/mimicKind/pos）：这些取值器把 null 收成缺省值，
#      免得 `String(null)` / `int(null)` 在运行期直接报错。
func _s(v: Variant, dflt: String = "") -> String:
	return dflt if v == null else String(v)


func _i(v: Variant, dflt: int = 0) -> int:
	return dflt if v == null else int(v)


func _d(v: Variant) -> Dictionary:
	return v if v is Dictionary else {}


func _ar(v: Variant) -> Array:
	return v if v is Array else []


## 本地英雄表：召唤物在 `DataRegistry.summons`（不在 heroes）
func _get_def(hid: String) -> DataRegistry.HeroDef:
	var d: DataRegistry.HeroDef = DataRegistry.heroes.get(hid, null)
	if d == null:
		d = DataRegistry.summons.get(hid, null)
	return d


func _alive_count(sim, fn: int) -> int:
	var n := 0
	for u in sim.units:
		if u != null and u.alive and int(u.fn) == fn:
			n += 1
	return n


func _index_of_id(built: Dictionary, hero_instance_id: String) -> int:
	var ids: Array = built["ids"]
	for i in ids.size():
		if String(ids[i]) == hero_instance_id:
			return i
	return -1


## 计划里安排过的那几个单位（协议 hero 实例 id），用来回答"结束回合时还有谁没被安排"
func _plan_covered_ids() -> Array:
	var out: Array = []
	for it in _cache.get("intents", []):
		var hid := String((it as Dictionary).get("hero", ""))
		if hid != "" and not out.has(hid):
			out.append(hid)
	return out


## 此刻"还没行动"的我方单位（既没移动也没出手）—— 与"计划安排过的"对照，就能看出谁被漏了
func _idle_ids(built: Dictionary) -> Array:
	var out: Array = []
	if built.is_empty():
		return out
	var ids: Array = built.get("ids", [])
	var fns: Array = built.get("fn", [])
	for i in ids.size():
		if i >= fns.size() or int(fns[i]) != int(DataRegistry.Faction.ENEMY):
			continue
		var u = (built["sim"] as Object).units[i]
		if u == null or not u.alive:
			continue
		if not u.moved and not u.attacked:
			var covered: Array = _plan_covered_ids()
			if not covered.has(String(ids[i])):
				out.append(String(ids[i]))
	return out


## 【计划用完/空计划时的"最后一刀"】**还有单位能打就必须打**，不许白白结束回合。
## 病灶（擂台实测，用户当场抓到）：`交 END_TURN 时 我方 red-0=moved，当时可攻击 red-0→(2,4)` ——
##   引擎对"远程被贴身"那一刀有闸门（贴脸只 1 点，判定不值就不排进计划），计划里没有 ⇒ 计划一用完
##   就直接结束回合，把**已经站在面前的免费一刀**丢了。这里在结束前兜一次：把所有"还没出手的单位"
##   的合法攻击逐个 apply 到 sim 副本上用 `_evaluate` 比一遍，只要**比空闲局面好**就打。
func _late_strike(obs: Dictionary, legal: Array, built: Dictionary) -> Dictionary:
	if built.is_empty():
		return {}
	var sim = built["sim"]
	var ids: Array = built.get("ids", [])
	var base := float(_ai._evaluate(sim))
	var best_aid := ""
	var best_s := base + 0.01          # 必须**明确更好**才打（打平就照旧结束回合）
	var t0 := Time.get_ticks_msec()
	for a in legal:
		if Time.get_ticks_msec() - t0 > 2500:
			break
		var d: Dictionary = a
		var it: Dictionary = _d(d.get("intent"))
		if _s(it.get("kind")) != "ATTACK":
			continue
		var idx := _idx_of(ids, _s(it.get("heroId")))
		if idx < 0 or idx >= (sim as Object).units.size():
			continue
		var u = (sim as Object).units[idx]
		if u == null or not u.alive or u.attacked:
			continue
		var tc := _to_local(it.get("target", {}))
		var occ: Dictionary = built.get("occ", {})
		var act := {"move": null, "atk": int(occ[tc])} if occ.has(tc) else {"move": null, "atk": -2, "atk_obs": tc}
		var c = (sim as Object).clone()
		_ai._apply(c, idx, act)
		var s := float(_ai._evaluate(c))
		if s > best_s:
			best_s = s
			best_aid = String(d.get("actionId", ""))
	if best_aid == "":
		return {}
	_warn_once("late_strike", "!! 计划里没排这一刀，但还有单位能打 ⇒ 补上（%.2f > 空闲 %.2f）" % [best_s, base])
	return {"actionId": best_aid, "note": "计划没排到它，但还能打 ⇒ 补一刀（%.2f>%.2f）" % [best_s, base]}


func _find_end_turn(legal: Array) -> String:
	for a in legal:
		var it: Dictionary = (a as Dictionary).get("intent", {})
		if String(it.get("kind", "")) == "END_TURN":
			return String((a as Dictionary).get("actionId", ""))
	return ""


func _any_legal(legal: Array, note: String) -> Dictionary:
	# 什么招都算不出来时也要交一个合法动作：优先"结束回合"；其次任何**不是撤退**的动作
	# （撤退=主动放弃一个英雄的命，绝不能当兜底）；最后才轮到撤退/第一个。
	var e := _find_end_turn(legal)
	if e != "":
		return {"actionId": e, "note": note + "→END_TURN"}
	for a in legal:
		var it: Dictionary = (a as Dictionary).get("intent", {})
		if String(it.get("kind", "")) != "WITHDRAW":
			return {"actionId": String((a as Dictionary).get("actionId", "")), "note": note + "→非撤退"}
	return {"actionId": String((legal[0] as Dictionary).get("actionId", "")), "note": note + "→first"}


func _think_budget(remain_ms: int, turn_budget_ms: int = 0) -> int:
	# 上限：`--think=N` 给了就用它；没给就**跟着本局选的回合预算自动算**。
	# 【2026-10-01 用户口径·擂台改成"每一手都真搜"】用户原话：「我和 AI 打的时候，AI 也得像个几秒
	#   十秒的。怎么在网页上，没想就动了」—— 原来是一回合只搜一次（第一手 40 秒），后面几手照计划
	#   缓存执行（几十毫秒）⇒ 网页上看着"没想"。现在**每手都重搜一次**（`--cache-plan` 可切回旧口径），
	#   于是预算必须按"本回合还剩多少额度"分，不能每手都给 40 秒：
	#     · 单手上限 = 生产噩梦档的 40 秒；
	#     · 一回合总搜索额度 = 回合预算的 60%（60 秒局 ⇒ 36 秒）—— 留足收尾/网络/映射时间，
	#       而且离"超两倍时限被裁判强制推进"（120 秒）还差得远；
	#     · 每一手拿的是**额度减去本回合已经花掉的**，所以五六手分下来每手仍是几秒量级，
	#       而不会出现"前几手把预算吃光、后面的手没得搜"。
	#   ⚠️ 搜索本身是"铺完候选线就返回"（deadline 是上限不是固定等待）⇒ 收敛了照样提前结束，
	#      日志里那行 `搜了 X/Y·未超时` 就是对这件事的取证。
	var cap := _think_ms
	if cap <= 0:
		var big := 40000 if turn_budget_ms > 0 else 15000
		var allow := big
		if turn_budget_ms > 0:
			allow = mini(big, int(float(turn_budget_ms) * 0.6))
		cap = clampi(allow - _turn_spent_ms, 1500, allow)
		if _cap_logged != cap:
			_cap_logged = cap
			_eng._log("思考上限：本手 %dms（本回合额度 %dms − 已花 %dms；本局回合预算 %dms；可用 --think=N 覆盖）" % [
				cap, allow, _turn_spent_ms, turn_budget_ms])
	if remain_ms <= 0:
		return cap
	# 还要给这一手之后留量（收尾/网络）：剩不到 5 秒就只做快路
	return clampi(mini(cap, remain_ms - 5000), 0, cap)


func _deploy_cells(legal: Array) -> Array:
	var out: Array = []
	var seen: Dictionary = {}
	for a in legal:
		var it: Dictionary = (a as Dictionary).get("intent", {})
		if String(it.get("kind", "")) != "DEPLOY":
			continue
		var c := _to_local(it.get("to", {}))
		if c.x >= 0 and not seen.has(c):
			seen[c] = true
			out.append(c)
	return out


func _kind_slot_hero(obs: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for h in obs.get("ownPool", []):
		if h is Dictionary:
			out[int(h.get("slot", -1))] = String(_kind2hero.get(int(h.get("kind", 0)), ""))
	return out


## hero_id → 我方池里的 slot（协议的 DEPLOY 用 slot 指人）
func _kind_slot_map(obs: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for h in obs.get("ownPool", []):
		if h is Dictionary:
			var hid := String(_kind2hero.get(int(h.get("kind", 0)), ""))
			if hid != "":
				out[hid] = int(h.get("slot", -1))
	return out


func _undeployed_ids(obs: Dictionary) -> Array:
	var out: Array = []
	for h in obs.get("ownPool", []):
		if h is Dictionary and String(h.get("status", "")) == "wait":
			var hid := String(_kind2hero.get(int(h.get("kind", 0)), ""))
			if hid != "":
				out.append(hid)
	return out


func _warn_once(key: String, msg: String) -> void:
	if _warned.has(key):
		return
	_warned[key] = true
	_eng._log(msg)

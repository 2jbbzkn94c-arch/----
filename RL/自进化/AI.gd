extends "res://RL/ai/AI_Battle.gd"
## ============================================================================
## 自进化 · AI 自己的 AI（档位 5「自进化」专用）
## ============================================================================
## 用户口径（2026-10-02 晚）：「**注意，你的所有东西都不要在原来的文件里，你另外起一个文件夹，
##   里面放你所有的东西**」⇒ 本文件是我（AI）的全部机制实现，住在 `RL/自进化/` 里：
##   · **不是副本**：用 `extends "res://RL/ai/AI_Battle.gd"`（路径继承）⇒ 父脚本一更新我自动跟上，
##     不存在项目里那个 fork 的"副本漂移 / 每次改 src 都要重建"的问题。
##   · **不往 `src/` 塞机制**：我的键解析 + 机制代码全在本文件；`src/Battle.gd` 只有两行通用接线
##     （难度 5 加载本文件 + `has_method("adapt_to_opponent")` 就调一下）。
##   · **只由 `RL/自进化/权重.json` 打开**：下面每个机制都跟着一个**引擎默认关**的键走 ⇒
##     噩梦(3)/噩梦1(4) 与简单/普通/困难**逐位不变**（它们加载的不是本文件，也没有这些键）。
##
## 用户点的病：「**我现在靠写评分的模式就会非常的死板，对所有对手都是一个套路**，
##   但实际上，面对对方不同阵容，不同的打法效果区别很大」⇒ 机制 1。
## 他还说了三条"强"：① 会选队伍（配合强、输出多、看血量比）② 下棋看盈亏比、会**下套**
##   ③ 替补选对人、会斩杀 ⇒ 按这个顺序继续做（每条都走"配对批 + CI 判定"）。

# ---------------------------------------------------------------- 我的键（引擎默认关）
const ADAPT_PROFILE := 0        # 0 = 关（默认）；1 = 按对手阵容叠权重档
const ADAPT_MIN_CNT := 2        # 某类对手达到几个才算"这套阵容"
var w_adapt_profile := ADAPT_PROFILE
var w_adapt_min_cnt := ADAPT_MIN_CNT
var w_adapt_vs_ranged: Dictionary = {}
var w_adapt_vs_tank: Dictionary = {}
var w_adapt_vs_squishy: Dictionary = {}
# 机制 2（下套）：围死对方远程
const TRAP_W := 0.0             # 0 = 关（默认）；>0 打开。分/每少一个"安全落点"
const TRAP_FREE_TARGET := 2     # 它至少要有几个"不贴我方"的落点才算没被围（与 ㉑ 的 FORM_ESCAPE_MIN 同口径）
var w_trap_w := TRAP_W
var w_trap_free_target := TRAP_FREE_TARGET

## 覆盖父类的 `set_weights`：先吃掉**我自己的键**，其余原样交给父类（未知键父类本来就会忽略）。
## ⚠️ 这样 `src/BattleAI.gd` 里**一个我的键都不用加**（用户口径：我的东西不进原来的文件）。
func set_weights(t: Dictionary) -> void:
	for k in t.keys():
		match String(k):
			"ADAPT_PROFILE":
				w_adapt_profile = maxi(int(t[k]), 0)
			"ADAPT_MIN_CNT":
				w_adapt_min_cnt = maxi(int(t[k]), 1)
			"ADAPT_VS_RANGED":
				w_adapt_vs_ranged = (t[k] as Dictionary) if t[k] is Dictionary else {}
			"ADAPT_VS_TANK":
				w_adapt_vs_tank = (t[k] as Dictionary) if t[k] is Dictionary else {}
			"ADAPT_VS_SQUISHY":
				w_adapt_vs_squishy = (t[k] as Dictionary) if t[k] is Dictionary else {}
			"TRAP_W":
				w_trap_w = maxf(float(t[k]), 0.0)
			"TRAP_FREE_TARGET":
				w_trap_free_target = maxi(int(t[k]), 0)
			"RECORD_PATH":
				w_record_path = String(t[k])
			"LEARNED_EVAL":
				w_learned_eval = maxi(int(t[k]), 0)
			"LEARNED_COEF":
				w_learned_coef = String(t[k])
				_coef_loaded_for = ""            # 换了路径 ⇒ 下次重新读
			_:
				pass
	super.set_weights(t)

# ---------------------------------------------------------------- 采数据（我的方法·第 A 步）
## 【为什么要有它】用户 2026-10-03 点破：我一直在**手调系数**（一个个加键、单键剂量），
##   而他朋友的 AI 是"**手写量当特征、权重交给网络学**"（dense 9 + 6182 稀疏，位置价值全靠学）。
##   ⇒ 本档改走那条路：**把 27 项 `_eval_breakdown` 当特征，用"这局的胜负"去拟合系数**。
##   这一步只负责**采样本**（默认关 ⇒ 不记录、不改决策、零开销）。
##   `RECORD_PATH` = 输出前缀（空 = 关）；每个进程写自己的 `<前缀>.<pid>.jsonl`（跑批是多进程，避免互踩）。
##   每行 = 一次决策的**已选末态**：这局的身份（seed/first/a_side/我是不是候选方）＋ 27 项分账 ＋ 汇总。
##   ⚠️ **只记录、绝不改决策**（记录发生在 `super.search()` 返回之后）⇒ 与对照仍可逐格配对。
var w_record_path := ""          # 键 `RECORD_PATH`："" = 关
## 【2026-10-03·为什么加环境变量通道】训练器的 `theta` 只认它自己那份键表（自动搜索键 / 规则键 / 钉住键），
##   我的键传不进去（实测 `FATAL: RuntimeException :: theta key not accepted by AI_Battle.set_weights: RECORD_PATH`）。
##   走环境变量就**不必去改用户的训练器**（我的东西全留在本文件夹），而且"进程里有没有这个变量"天然就是录制开关：
##   用户实机打难度5时进程里没有它 ⇒ 不录像、零开销。键名 `DSH_EVO_RECORD` = 输出前缀。
const REC_ENV := "DSH_EVO_RECORD"
var _rec_tag := {}               # 由走查台通过 `set_game_tag()` 告知（通用 hook）
var _rec_n := 0                  # 本进程内的决策序号

func _rec_prefix() -> String:
	if w_record_path != "":
		return w_record_path
	return OS.get_environment(REC_ENV)

## 走查台（`RL/harness/对局.gd`）在建完 AI 后调用；对没有本方法的 AI 是空操作。
func set_game_tag(seed_v: int, first_side: int, a_side: int, my_fn: int) -> void:
	_rec_tag = { "seed": seed_v, "first": first_side, "aside": a_side, "myfn": my_fn,
		"is_cand": (my_fn == a_side) }

## 重写 `search()`：先照父类搜，**搜完之后**把"已选末态"的特征记一行（不影响决策）。
func search(sim, enemy_faction: int) -> Array:
	var plan: Array = super.search(sim, enemy_faction)
	if plan.is_empty() or _rec_tag.is_empty() or _rec_prefix() == "":
		return plan
	_rec_decision(sim, plan)
	return plan

func _rec_decision(sim, plan: Array) -> void:
	var s = sim.clone()
	for st in plan:
		_apply(s, int(st["idx"]), st["action"])
	var bd: Dictionary = _eval_breakdown(s, true)
	var my_alive := 0
	var foe_alive := 0
	for u in s.units:
		var uu = u
		if uu == null or not bool(uu.get("alive")):
			continue
		if int(uu.get("fn")) == int(_rec_tag.get("myfn", 0)):
			my_alive += 1
		else:
			foe_alive += 1
	_rec_n += 1
	var rec := {
		"seed": _rec_tag.get("seed", 0), "first": _rec_tag.get("first", 0),
		"aside": _rec_tag.get("aside", 0), "is_cand": _rec_tag.get("is_cand", false),
		"n": _rec_n, "steps": plan.size(), "score": _evaluate(s, true),
		"my_alive": my_alive, "foe_alive": foe_alive, "terms": bd,
		"feat": _feature_vec(s, bd),
		"trap": _trap_term(s),
	}
	var path := "%s.%d.jsonl" % [_rec_prefix(), OS.get_process_id()]
	var f := FileAccess.open(path, FileAccess.READ_WRITE)
	if f == null:
		f = FileAccess.open(path, FileAccess.WRITE)
	elif f.get_length() > 0:
		f.seek_end()
	if f != null:
		f.store_line(JSON.stringify(rec))
		f.close()

# ---------------------------------------------------------------- 我的方法·第 C 步：学出来的评估
## 【为什么】用户 2026-10-03 点破：他朋友的强度来自"**手写量当特征、权重交给网络学**"，
##   而我一直在手调系数（一个个加键）⇒ 那条路已经证明是噪声（14 个臂 13 个跨 0）。
##   本档改成：**27 项分账当特征，系数用"这局胜负"拟合出来**（`拟合.py`），这里只是把学到的系数用起来。
##   `LEARNED_COEF` = 系数文件路径（空 = 关）· `LEARNED_EVAL` = 1 才启用（默认 0 ⇒ 逐位回到父类口径）。
##   ⚠️ 系数是拟合在"**特征全开**的配置"上的（见 `README.md` 的采数据一节）⇒ 启用时本档的权重文件也应当是
##      同一套配置，否则特征分布对不上（这一点由"采数据批"与"使用批"用同一份权重文件来保证）。
##   ⚠️ 文件缺失/解析失败 ⇒ **安全退回 `super._evaluate()`**（绝不因为缺文件而变弱或崩）。
var w_learned_eval := 0
var w_learned_coef := ""
var _coef: Dictionary = {}
var _coef_loaded_for := ""

func _load_coef() -> void:
	if w_learned_coef == "" or _coef_loaded_for == w_learned_coef:
		return
	_coef_loaded_for = w_learned_coef
	_coef = {}
	var f := FileAccess.open(w_learned_coef, FileAccess.READ)
	if f == null:
		return
	var d = JSON.parse_string(f.get_as_text())
	f.close()
	if d is Dictionary:
		_coef = d

## 【2026-10-03 修·接口必须与拟合器一致】打分用的特征向量**必须与采数据时是同一个** `_feature_vec()`：
##   ⚠️ 原来这里只对 `_eval_breakdown()` 的 27 项点乘 ⇒ 拟合器学出来的 **位置一热（`pos_x_y_my/foe`）**
##   与整队粗况（`n_my/n_foe/hp_*`）系数在实战里会被**静默忽略**；更糟的是那些系数是与 27 项**联合**拟合的
##   ⇒ 只丢掉一部分等于把剩下的系数也用歪（截距也会偏）。两处必须同一个函数、同一个键集。
func _learned_score(sim, eot: bool) -> float:
	var bd: Dictionary = _eval_breakdown(sim, eot)
	var f: Dictionary = _feature_vec(sim, bd)
	var s := float(_coef.get("_bias", 0.0))
	for k in f.keys():
		if _coef.has(k):
			s += float(_coef[k]) * float(f[k])
	return s

## 【我的方法·特征升级】用户 2026-10-03 追问「我朋友那种对你没有启示吗」——
##   启示的核心是：他 6182 个稀疏特征里**最大一块是 `(英雄, 阵营, 格子)` 一热**（位置价值靠学），
##   而只喂 27 个**汇总数**是学不出"站哪儿好"的（那只能把已有项的权重重排一遍）。
##   ⇒ 本函数产出**给拟合器用的特征向量**：
##     ① `pos_<x>_<y>_<my|foe>`：每个**被占格**的一热（与朋友那块同构，只是我们不区分英雄种类）
##     ② `n_my` / `n_foe` / `hp_my` / `hp_foe` / `hp_min_my`：整队粗况
##     ③ `t_<项名>`：27 项分账（保留 —— 它们是"手写量"，正好当特征用）
##   ⚠️ 纯函数、只读 `sim`；只在记录模式下调用（不影响决策、不影响评分）。
func _feature_vec(sim, bd: Dictionary) -> Dictionary:
	var f := {}
	var my_fn := int(sim.active_fn)
	var n_my := 0
	var n_foe := 0
	var hp_my := 0
	var hp_foe := 0
	var hp_min_my := 999
	for u in sim.units:
		var uu = u
		if uu == null or not bool(uu.get("alive")):
			continue
		var mine: bool = int(uu.get("fn")) == my_fn
		var c: Vector2i = uu.get("cell")
		f["pos_%d_%d_%s" % [c.x, c.y, ("my" if mine else "foe")]] = 1.0
		if mine:
			n_my += 1
			hp_my += int(uu.get("hp"))
			hp_min_my = mini(hp_min_my, int(uu.get("hp")))
		else:
			n_foe += 1
			hp_foe += int(uu.get("hp"))
	f["n_my"] = float(n_my)
	f["n_foe"] = float(n_foe)
	f["hp_my"] = float(hp_my)
	f["hp_foe"] = float(hp_foe)
	f["hp_min_my"] = float(hp_min_my if hp_min_my < 999 else 0)
	for k in bd.keys():
		f["t_" + String(k)] = float(bd[k])
	return f

# ---------------------------------------------------------------- 机制 2：下套（围死对方远程）## 【用户口径·他举的第 2 条】「下棋考虑盈亏比，不单止这回合，下回合也要考虑到，**还要下套**：
##   比如我这某个路径在这回合输出确实少了点、掉血也多一点，我给对方下了个套 —— 如果对方下回合想打满伤害，
##   比如**对方远程走到角落能打满，如果她走了，那我下回合就能把她围起来，让他输出不了**」
## ⇒ 现有账本里**没有一项为"占掉对方的退路"付钱**：㉑ 只罚**我们**被夹、⑳㉓ 还在奖励我们抱团、
##   ⑦㉖ 只算"我们会挨多少打"。这一项**把 ㉑ 的尺子翻过来量对方**：对每个敌方**远程**单位，
##   数它下回合"能走到、且不贴我方任何单位"的落点还剩几个，越少越值钱。
## ⚠️ 只看 `atk_range ≥ 2`（近战本来就得贴上来，围它没有额外意义）。
## ⚠️ 只在**末态**结算（与 ⑳㉑㉖ 同层）；纯局面量、纯加分，不掷骰子、不改搜索宽度。
## ⚠️ 与 ㉑ 的 esc 门同源：退路判据用**同一把尺子**（`_sim_walk_cells` + `_sim_enemy_adjacent`）。
func _evaluate(sim, end_of_turn := false) -> float:
	var score := 0.0
	if w_learned_eval > 0:
		_load_coef()
		if not _coef.is_empty():
			score = _learned_score(sim, end_of_turn)      # 学出来的评估
		else:
			score = super._evaluate(sim, end_of_turn)     # 系数缺失 ⇒ 安全退回父类
	else:
		score = super._evaluate(sim, end_of_turn)
	if w_trap_w != 0.0 and end_of_turn:
		score += _trap_term(sim)
	return score

func _trap_term(sim) -> float:
	var total := 0.0
	for i in sim.units.size():
		var e = sim.units[i]
		if e == null or not e.alive:
			continue
		if int(e.fn) != int(DataRegistry.Faction.PLAYER):
			continue
		if int(e.atk_range) < 2:
			continue                      # 只看远程（含被我们贴住的）
		var budget: int = _threat_emove_next(sim, e)
		if budget <= 0:
			total += float(w_trap_free_target)      # 动不了 ⇒ 它下回合的输出已经被钉死
			continue
		var free := 0
		for c in _sim_walk_cells(sim, e.cell, budget, e.skills.has(DataRegistry.Skill.INFILTRATE)):
			if not _sim_enemy_adjacent(sim, e, c):
				free += 1
		total += maxf(float(w_trap_free_target - free), 0.0)
	return w_trap_w * total

# ---------------------------------------------------------------- 机制 1：对手阵容档
## 【治"一个套路"】**对手阵容条件化的权重档**。做法：开局按**玩家方**（对手）的阵容特征选一组覆盖，
## 叠在本档权重之上。覆盖项就是普通的 `w_*` 键 ⇒ 走父类的 `set_weights`，不需要新解析、不改评分公式。
## 三个档可同时命中，**按下面的顺序叠加**（后面的覆盖前面的同名键）：
##   `ADAPT_VS_RANGED`   对手远程 ≥ `ADAPT_MIN_CNT` —— 对方靠远程输出 ⇒ 我们敢贴身/敢剥夺
##   `ADAPT_VS_TANK`     对手血上限 ≥ 22 的 ≥ N    —— 集火收益低 ⇒ 破盾/吸火/换血口径不同
##   `ADAPT_VS_SQUISHY`  对手血上限 ≤ 15 的 ≥ N    —— 斩杀优先
## ⚠️ 纯确定性分流（不掷骰子、不改搜索宽度）⇒ 可复现、可与对照逐格配对。
## ⚠️ 形参 `units` = **对手那一侧**的单位（由调用方筛）。**本方法不再自己按 `faction` 筛**：
##   生产上候选 AI 恒为敌方（敌=AI、玩=人）⇒ 从前写死"数 PLAYER"是对的；
##   但走查台的 A 方两边都当（`asides e,p`），镜像那半局里写死 PLAYER 就会把"自己"当成对手。
##   两个调用点各自负责传对的一侧：`src/Battle.gd`（数 PLAYER 阵营）· `RL/harness/对局.gd`（数 ≠ 我方阵营）。
func adapt_to_opponent(units: Array) -> void:
	if w_adapt_profile <= 0:
		return
	var c_ranged := 0
	var c_tank := 0
	var c_squishy := 0
	for u in units:
		var uu = u
		if uu == null:
			continue
		if not bool(uu.get("alive")):
			continue
		if int(uu.get("attack_type")) == int(DataRegistry.AttackType.RANGED):
			c_ranged += 1
		if int(uu.get("max_hp")) >= 22:
			c_tank += 1
		if int(uu.get("max_hp")) <= 15:
			c_squishy += 1
	var overlay := {}
	var plan := [[w_adapt_vs_ranged, c_ranged], [w_adapt_vs_tank, c_tank], [w_adapt_vs_squishy, c_squishy]]
	for pair in plan:
		var ov: Dictionary = pair[0]
		if int(pair[1]) < w_adapt_min_cnt or ov.is_empty():
			continue
		for k in ov.keys():
			overlay[k] = ov[k]
	if overlay.is_empty():
		return
	set_weights(overlay)
	if log_decisions:
		print("[自进化·对手阵容档] 远程%d / 坦克%d / 脆皮%d ⇒ 叠 %d 项：%s" % [
			c_ranged, c_tank, c_squishy, overlay.size(), str(overlay.keys())])

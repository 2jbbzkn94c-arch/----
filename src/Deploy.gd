class_name Deploy
extends Control
## 开局部署选人：随机一方先手，双方交替各选 1 名上阵，各选满 3 人后开始对战。
## 玩家手动从我方卡池选；敌方由 AI 自动选。

const DEPLOY := 3
# 【2026-09-22】配方首发挑选的调试日志（想看"敌方这一手为什么挑他"就改成 true）
const RECIPE_PICK_LOG := false

var player_pool: Array = []
var enemy_pool: Array = []
var player_deployed: Array = []
var enemy_deployed: Array = []
var current_side := 0   # 随机先手
var finished := false

var _turn_label: Label
var _status_label: Label
var _player_cards: Dictionary = {}   # id -> Button
var _enemy_cards: Dictionary = {}

func _ready() -> void:
	player_pool = GameState.player_deck.duplicate()
	enemy_pool = GameState.enemy_deck.duplicate()
	current_side = randi() % 2
	_build()
	_refresh()
	# 若敌方先手，稍作停顿后自动选
	if current_side == 1:
		_enemy_pick.call_deferred()

func _build() -> void:
	var vsize := get_viewport().get_visible_rect().size
	var bg := ColorRect.new()
	bg.color = Color(0.08, 0.08, 0.13, 1.0)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var vbox := VBoxContainer.new()
	vbox.position = Vector2(20, 30)
	vbox.size = Vector2(vsize.x - 40, vsize.y - 60)
	vbox.add_theme_constant_override("separation", 8)
	add_child(vbox)

	var title := Label.new()
	title.text = "开局选人（轮流部署）"
	title.add_theme_font_size_override("font_size", 26)
	title.add_theme_color_override("font_color", Color(1, 0.85, 0.5))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	_turn_label = Label.new()
	_turn_label.add_theme_font_size_override("font_size", 18)
	_turn_label.add_theme_color_override("font_color", Color(0.85, 0.9, 1.0))
	_turn_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(_turn_label)

	_status_label = Label.new()
	_status_label.add_theme_font_size_override("font_size", 15)
	_status_label.add_theme_color_override("font_color", Color(0.7, 0.9, 0.7))
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_status_label)

	vbox.add_child(_mk_pool_title("我方卡池（点击选出战）", Color(0.5, 0.85, 1.0)))
	vbox.add_child(_mk_pool_grid(true))
	vbox.add_child(_mk_pool_title("敌方卡池（AI 自动选）", Color(1.0, 0.5, 0.5)))
	vbox.add_child(_mk_pool_grid(false))

func _mk_pool_title(t: String, color: Color) -> Label:
	var l := Label.new()
	l.text = t
	l.add_theme_font_size_override("font_size", 15)
	l.add_theme_color_override("font_color", color)
	return l

func _mk_pool_grid(is_player: bool) -> GridContainer:
	var grid := GridContainer.new()
	grid.columns = 5
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 8)
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var pool: Array = player_pool if is_player else enemy_pool
	for hid in pool:
		var b := Button.new()
		var def := DataRegistry.get_hero(hid)
		b.text = def.display_name
		b.add_theme_font_size_override("font_size", 14)
		b.custom_minimum_size = Vector2(0, 42)
		b.pressed.connect(_on_player_pick.bind(hid) if is_player else func(): pass)
		if is_player:
			_player_cards[hid] = b
		else:
			_enemy_cards[hid] = b
		grid.add_child(b)
	return grid

func _on_player_pick(id: String) -> void:
	if finished or current_side != 0:
		return
	if not player_pool.has(id):
		return
	player_pool.erase(id)
	player_deployed.append(id)
	if player_deployed.size() == DEPLOY:
		_status_label.text = "我方已选满 3 名。"
		if enemy_deployed.size() == DEPLOY:
			_start_battle()
			return
		_pass_to_enemy()
		return
	_pass_to_enemy()

func _pass_to_enemy() -> void:
	current_side = 1
	_refresh()
	_enemy_pick.call_deferred()

# ---- 【2026-10-03·用户口径】**部署顺序偏好**：怕被针对的英雄，等对方先亮 ----
# 用户原话：「某些英雄存在鲜明的克制与非克制关系，**尽量不要前两个就上**……需要注意的是，
#   **我这条规则不能改变 AI 本来的部署策略，只是在部署顺序上需要考虑一下**」。
#   ① **毒蛇 hero_03**：靠毒吃饭；被**战锤 hero_25**（麻痹 ⇒ 有效攻击 0）克制 ⇒ 连毒都挂不上
#   ② **红帽 hero_40**：被**沉默术士 hero_34**克制（被沉默 ⇒ 不能自爆、整只废）
#   ③ **`<后勤>`**：被动挨打、还手极弱 ⇒ 怕**荆棘树人 hero_49**（[荆棘]=不能移动）/ **沉默术士**
#   ⚠️ **负墟 暂未登记** —— 还差它的 hero_id（用户口径第 2 条，见训练日志待办）。
# **做法**：**只压前 `EARLY_SLOTS` 格**、且**只在克制者还没亮出来时**压；用**乘法**（×0.2）而不是
#   减固定分 ⇒ 与 `_enemy_candidate_value()` 的量纲无关，也不会把候选人彻底排除（"尽量"不是"禁止"）。
#   ⚠️ **选人集合 / 落点 / 任何评分一律不动**：只改"同一次挑选里谁优先"。
#   ⚠️ 克制者**已经亮了** ⇒ 不压（那本来就该由净克制项把它压下去；本规则只管"什么时候上"）。
const EARLY_SLOTS := 2              # 前几格算"早"（用户：尽量不要前两个就上）
const EARLY_DEFER_MULT := 0.2       # 早格上这些英雄时分数打几折（乘法、量纲无关）

## 【2026-10-03·用户口径】这一格该不该"压后"：候选英雄怕的那个克制者**还没出现在玩家已首发表里** ⇒ true。
func _defer_early(cand: String) -> bool:
	if enemy_deployed.size() >= EARLY_SLOTS:
		return false                       # 已经过了"前两格" ⇒ 不压
	var revealed := {}
	for h in player_deployed:
		revealed[h] = true
	# 【2026-10-03·用户「我角色列表里不是有他克制的人吗」】**三条改成读数据**（不再手写清单）：
	#   `DataRegistry` 已有克制图（`HeroDef.beats` = 克制列 · `HeroDef.counters` = 被克制列）。
	#   判据 = **候选自己的「被克制列」里，一个都还没出现在玩家已首发表里 ⇒ 等对方先亮**；
	#          若其中**已经有**人亮了 ⇒ 不压（该不该选由 `_enemy_candidate_value()` 的净克制项决定）。
	#   实测数据：**毒蛇淑女「被克制列 = 战锤」** · **红帽「被克制列 = 涌电技师、影丸、火枪手、沉默术士、坠炮手」**
	#   （⚠️ 我第一版只写了"沉默术士"，**漏了另外 4 个** —— 这正是"别手写清单"的证据）。
	var cd: DataRegistry.HeroDef = DataRegistry.get_hero(cand)
	if cd != null and cd.counters.size() > 0:
		for x in cd.counters:
			if revealed.has(String(x)):
				return false                       # 它的克制者已经亮了 ⇒ 不压
		return true                                # 有克制者、但一个都没亮 ⇒ 等对方先亮
	# ④ `<后勤>`：被动挨打、还手极弱 ⇒ 怕**荆棘树人**（[荆棘]=不能移动）/ **沉默术士**
	#   ⚠️ 这一条**数据里没有**（医护兵/烛火的克制列与被克制列都是空的）⇒ 按用户口径手工登记。
	if cd != null and cd.skills.has(DataRegistry.Skill.LOGISTICS):
		return not (revealed.has("hero_49") or revealed.has("hero_34"))
	return false
	# 【2026-10-03·用户「我角色列表里不是有他克制的人吗」】**改正：读数据、不手写清单**。
	#   负墟 hero_44 的「克制」列原文 = **毒蛇淑女 / 战锤 / 雪拳 / 白游侠 / 沉默术士 / 猎颅者 / 巨剑 / 宿魂**
	#   （它的技能：所有负面效果对其无效，**每受到一次负面效果攻击，攻击力 +1**）。
	#   ⇒ `HeroDef.beats` 就是那一列（`DataRegistry` 已有克制图：`beats` 克制列 / `counters` 被克制列）。
	#   判据：玩家**已经亮出其中任何一个** ⇒ 负墟有得吃、不必压后；**一个都没亮** ⇒ 压后。
	if cand == "hero_44":
		var fd: DataRegistry.HeroDef = DataRegistry.get_hero("hero_44")
		if fd != null:
			for b in fd.beats:
				if revealed.has(String(b)):
					return false
		return true


func _enemy_pick() -> void:
	if finished:
		return
	# 【2026-09-22 配方档·用户口径】走配方时：**按槽位填人**（做法乙），候选 = 该槽位的候选池（全部，
	#   不进卡组）− 已上阵；打分 = 既有 `_enemy_candidate_value()`（含"对玩家已首发"的净克制）+ 抖动；
	#   并列随机。⇒ "1 近战 + 1 远程 + 1 嘲讽"这种结构不会被部署打散，且不会每次都精准克制。
	if not GameState.enemy_recipe.is_empty():
		_enemy_pick_by_recipe()
		return
	if enemy_pool.size() > 0 and enemy_deployed.size() < DEPLOY:
		# 【2026-09-18 改·用户第 1 条】原来是 `enemy_pool.pop_front()` —— **按池子顺序拿第一个**，
		# 也就是说敌方先发阵容**完全随机/固定**：不看强度、不看配合、不看对面站了谁。
		# 现在按 `DataRegistry` 里现成的三张表精确挑一个（0 新参数）：
		#   单人评分 + 与己方已选协同 + 对玩家已选**净克制** + 职能配比，
		# 并且**带 <替补> 标签的英雄不主动首发**（它的技能只在替补登场时触发，首发等于浪费
		# —— 这条口径与 `src/Battle.gd::_enemy_deploy()` 一致）。
		var best_i := 0
		var best_sc := -1e9
		for i in enemy_pool.size():
			var cand: String = enemy_pool[i]
			var cd: DataRegistry.HeroDef = DataRegistry.get_hero(cand)
			var is_bench: bool = cd != null and cd.skills.has(DataRegistry.Skill.BENCH)
			var sc: float = _enemy_candidate_value(cand) if not is_bench else -1e8
			# 【2026-10-03·用户口径】**部署顺序偏好**：怕被针对的英雄（毒蛇/红帽/后勤）在前两格压后
			#   （只改"什么时候上"，不改选谁 —— 详见 `_defer_early()` 上方那段）。
			if not is_bench and _defer_early(cand):
				sc *= EARLY_DEFER_MULT
			if sc > best_sc:
				best_sc = sc
				best_i = i
		var hid: String = enemy_pool[best_i]
		enemy_pool.remove_at(best_i)
		enemy_deployed.append(hid)
		if enemy_deployed.size() == DEPLOY and player_deployed.size() == DEPLOY:
			_start_battle()
			return
		# 交回我方（若我方还没选满）
		current_side = 0
		if player_deployed.size() == DEPLOY:
			# 我方先满，但敌方还需补选（不应发生，因交替）
			pass
		_refresh()

# 【2026-09-22 新增·配方档（做法乙）】按槽位填首发：
#   · 槽位序号 = 已上阵人数（第 1 次挑选填槽 0、第 2 次填槽 1、第 3 次填槽 2）
#   · 候选 = `slots[i].pool`（整池；**不是**只带两个）− 已上阵；<替补> 标签英雄不主动首发（与既有口径一致）
#   · 打分 = `_enemy_candidate_value()`（含对玩家已首发的净克制）+ `randf() * jitter`
#   · 取最高分；并列/近似并列在并列集里随机（不取第一个）
#   · 上阵后从 `enemy_pool` 移除同名（配方档的初始卡组 = 锁定首发 + 预设替补，避免"同一个人既在场上又在替补席"）
func _enemy_pick_by_recipe() -> void:
	var slots: Array = GameState.enemy_recipe.get("slots", [])
	var si: int = enemy_deployed.size()
	if si >= slots.size() or si >= DEPLOY:
		_pass_to_enemy_done()
		return
	var pool: Array = ((slots[si] as Dictionary).get("pool", []) as Array)
	var jitter := float(GameState.enemy_recipe.get("jitter", 2.0))
	var cands: Array = []
	var scores: Array = []
	for hid in pool:
		var h := String(hid)
		if h == "" or enemy_deployed.has(h):
			continue
		var cd: DataRegistry.HeroDef = DataRegistry.get_hero(h)
		if cd == null:
			continue
		if cd.skills.has(DataRegistry.Skill.BENCH):
			continue   # 替补标签英雄不主动首发（它的技能只在替补登场时触发）
		cands.append(h)
		scores.append(_enemy_candidate_value(h) + randf() * jitter)
	if cands.is_empty():
		# 该槽位挑不出人（都被禁/已上阵）⇒ 退回"从卡组挑"的老路径，尽量别空过
		_enemy_pick_fallback_from_pool()
		return
	# 取最高分；与最高分相同（或相差 < 1e-6）的一起随机
	var best := -1e18
	for s in scores:
		best = maxf(best, float(s))
	var tied: Array = []
	for i in cands.size():
		if float(scores[i]) >= best - 0.000001:
			tied.append(i)
	var pick_i: int = int(tied[randi() % tied.size()])
	var hid: String = String(cands[pick_i])
	enemy_pool.erase(hid)
	enemy_deployed.append(hid)
	if RECIPE_PICK_LOG:
		print("[部署·配方] 槽%d 候选%d 人 → 上 %s" % [si + 1, cands.size(), DataRegistry.get_hero(hid).display_name])
	if enemy_deployed.size() == DEPLOY and player_deployed.size() == DEPLOY:
		_start_battle()
		return
	current_side = 0
	_refresh()

# 兜底：配方该槽位无人可上 ⇒ 用既有"从卡组挑最优"的逻辑（有卡组时才有意义）
func _enemy_pick_fallback_from_pool() -> void:
	var best_i := 0
	var best_sc := -1e9
	for i in enemy_pool.size():
		var cand: String = enemy_pool[i]
		var cd: DataRegistry.HeroDef = DataRegistry.get_hero(cand)
		var is_bench: bool = cd != null and cd.skills.has(DataRegistry.Skill.BENCH)
		var sc: float = _enemy_candidate_value(cand) if not is_bench else -1e8
		if sc > best_sc:
			best_sc = sc
			best_i = i
	if enemy_pool.is_empty():
		_pass_to_enemy_done()
		return
	var hid: String = enemy_pool[best_i]
	enemy_pool.remove_at(best_i)
	enemy_deployed.append(hid)
	if enemy_deployed.size() == DEPLOY and player_deployed.size() == DEPLOY:
		_start_battle()
		return
	current_side = 0
	_refresh()

# 配方档：槽位填完但玩家还没选满 ⇒ 把选择权交回玩家（不空过）
func _pass_to_enemy_done() -> void:
	current_side = 0
	if player_deployed.size() == DEPLOY and enemy_deployed.size() == DEPLOY:
		_start_battle()
		return
	_refresh()

# 【2026-09-18 新增·用户第 1 条】敌方候选价值（0 新参数，全部来自 DataRegistry 现成表）：
#   单人评分 + 与己方已选协同 + 对玩家已选**净克制**（`battle_unit_value_parts` 的 counter 就是净额）
#   + 职能配比（避免"全体脆皮/双坦克"）。
func _enemy_candidate_value(cand: String) -> float:
	var parts: Dictionary = DataRegistry.battle_unit_value_parts(cand, enemy_deployed, player_deployed, null)
	return float(parts["solo"]) + float(parts["synergy"]) + float(parts["counter"]) \
			+ DataRegistry.role_balance_bonus(enemy_deployed, cand)

func _refresh() -> void:
	_turn_label.text = ("轮到我方选择" if current_side == 0 else "轮到敌方选择") + "   场次：我方 %d/3 · 敌方 %d/3" % [player_deployed.size(), enemy_deployed.size()]
	for hid in _player_cards.keys():
		var b: Button = _player_cards[hid]
		var used := player_deployed.has(hid) or not player_pool.has(hid)
		b.disabled = used or current_side != 0 or finished
		b.text = DataRegistry.get_hero(hid).display_name + (" ✓" if used and player_deployed.has(hid) else "")
	for hid in _enemy_cards.keys():
		var eb: Button = _enemy_cards[hid]
		var eused := enemy_deployed.has(hid) or not enemy_pool.has(hid)
		eb.disabled = true
		eb.text = DataRegistry.get_hero(hid).display_name + (" ✓" if eused and enemy_deployed.has(hid) else "")

func _start_battle() -> void:
	if finished:
		return
	finished = true
	# 已选 3 名排前，其余作替补
	GameState.player_deck = player_deployed + player_pool
	GameState.enemy_deck = enemy_deployed + enemy_pool
	GameState.clear_placement()
	get_tree().change_scene_to_file("res://scenes/Main.tscn")

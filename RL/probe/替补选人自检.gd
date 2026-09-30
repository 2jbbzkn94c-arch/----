extends Node
## 【2026-09-22 一次性探针】替补选人·两段式（需求 → 排名 → 圈内随机）自检 —— 跑完即退，**不改生产代码**。
##
## 查四件事：
##   ① 用户那局的场景（**场上已经有一个坦克**）⇒ 需求不该再是"缺前排"、战锤这类的**不该再被抖进圈**；
##   ② 没有嘲讽 ⇒ 需求 = 缺前排，且候选**只剩嘲讽族**；
##   ③ 伤员 ≥2 且没有治疗 ⇒ 需求 = 缺治疗（候选 = 治疗族 ∪ 波盾）；
##   ④ 什么都不缺 ⇒ 兜底，圈 = `最高分 − 3.0`（打印圈内名单，验证"原始分差 >3 的人进不来"）。
## 每场景把 `_sub_pick_need_band()` 连调 20 次统计出人分布（圈内随机 ⇒ 会看到多个名字）。
##
## 用法：
##   & RL\train\跑Godot隔离.ps1 -Tag sub -TimeoutSec 600 -Args @('--headless','--path',(Get-Location).Path,'--scene','res://RL/probe/替补选人自检.tscn')
## 输出：`PROBE|...` 行 + `[替补·需求]` 日志行，末尾 `PROBE|END`。

var _b: Battle = null

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	Engine.time_scale = 10.0
	GameState.reset_online()
	GameState.dual_control = false
	GameState.pick_deck_in_battle = true
	GameState.ai_difficulty = 3
	_b = load("res://scenes/Main.tscn").instantiate() as Battle
	_b.set_random_seed(99001)
	get_tree().root.add_child(_b)
	if not await _wait_state([Battle.State.DECK_PICK], 10.0):
		print("PROBE|FATAL|no_deck_pick|state=%d" % int(_b.state))
		await _done()
		return
	_b._start_with_player_deck(["hero_01", "hero_06", "hero_12", "hero_22", "hero_33"])
	await _frames(6)
	# 清场，自己摆盘面
	_clear()
	# ---- A：用户那局的样子（**我方已有一个坦克**：复仇者；对面 矿工/复仇者/影丸）----
	_spawn("hero_23", 1, Vector2i(2, 1))          # 我方 复仇者（嘲讽坦克，满血）
	_spawn("hero_32", 1, Vector2i(1, 1))          # 我方 长角
	_spawn("hero_34", 1, Vector2i(3, 1))          # 我方 沉默术士（远程）
	_spawn("hero_42", 0, Vector2i(2, 4), 16, 18)  # 玩家 黄金矿工（掉 2 血 ⇒ 伤员）
	_spawn("hero_23", 0, Vector2i(1, 4))          # 玩家 复仇者
	_spawn("hero_07", 0, Vector2i(3, 4))          # 玩家 影丸
	_case("A_已有坦克")
	# ---- B：我方没有嘲讽 ⇒ 需求应是"缺前排"，候选只剩嘲讽族 ----
	_clear()
	_spawn("hero_32", 1, Vector2i(1, 1))          # 长角（无嘲讽）
	_spawn("hero_34", 1, Vector2i(3, 1))          # 沉默术士
	_spawn("hero_07", 1, Vector2i(2, 2))          # 影丸（远程）
	_spawn("hero_42", 0, Vector2i(2, 4), 16, 18)
	_spawn("hero_23", 0, Vector2i(1, 4))
	_case("B_没有坦克")
	# ---- C：伤员 ≥2 且没有治疗 ⇒ 需求应是"缺治疗" ----
	_clear()
	_spawn("hero_23", 1, Vector2i(2, 1))          # 我方 复仇者（嘲讽，满血）
	_spawn("hero_34", 1, Vector2i(3, 1))
	_spawn("hero_32", 1, Vector2i(1, 1))
	_spawn("hero_42", 0, Vector2i(2, 4))
	_spawn("hero_23", 0, Vector2i(1, 4))
	_b.units[0].hp = maxi(_b.units[0].max_hp - 5, 1)   # 我方复仇者掉 5 血
	_b.units[1].hp = maxi(_b.units[1].max_hp - 4, 1)   # 沉默术士掉 4 血
	_case("C_伤员多无治疗")
	# ---- D：什么都不缺（有坦克/有治疗/有远程/有输出/无人受伤）⇒ 兜底 + 圈 = 最高−3 ----
	_clear()
	_spawn("hero_23", 1, Vector2i(2, 1))          # 嘲讽坦克
	_spawn("hero_06", 1, Vector2i(1, 1))          # 医护兵（治疗族）
	_spawn("hero_34", 1, Vector2i(3, 1))          # 沉默术士（远程，攻3 = 输出）
	_spawn("hero_42", 0, Vector2i(2, 4))
	_spawn("hero_23", 0, Vector2i(1, 4))
	_case("D_什么都不缺")
	# ---- E：**预设替补**那条路（配方写了 bench）：名单里同时放"坦克/续航/普通输出"，
	#      看需求能不能把"不缺的职能"压下去（旧口径是身价 + 缺前排+11/补坦克位+3 混算）----
	_b.enemy_roster = ["hero_25", "hero_11", "hero_16", "hero_36", "hero_32"]   # 战锤/塔盾/波盾/梅林/长角
	var ctxE := _b._sub_ctx()
	var idxE := _b._best_enemy_sub_idx()
	print("PROBE|E_预设替补|need=%s|名单=%s|选中=%s(下标%d)|分数=%s" % [
		DataRegistry.sub_need_label(String(ctxE.get("need", ""))), str(_b.enemy_roster),
		String(_b.enemy_roster[idxE]), idxE, _scores_txt(["hero_25", "hero_11", "hero_16", "hero_36", "hero_32"], ctxE)])
	# ---- F：【2026-09-29 追加】动态替补判据①扩成「**合力斩杀**」（用户口径：「如果对方已经死了两人，
	#      并且最后一人血量小于下回合 AI 和替补一起能造成的伤害，首要需求就是斩杀」）----
	#      盘面 = 我方两人够得到玩家最后一人（够不到就没人参与合力），对面已死 2 人；
	#      **目标血量按"我方两人合计攻击力 + 1"现算** ⇒ 队伍自己差一点收不掉，必须靠替补补上这一刀。
	_clear()
	_spawn("hero_26", 1, Vector2i(3, 1))
	_spawn("hero_16", 1, Vector2i(1, 1))
	_spawn("hero_23", 0, Vector2i(3, 3))
	# 替补的合法落点 = 本方墓碑格 + 出生区空格。出生区通常离战场很远 ⇒ 想验"合力斩杀"就得有**墓碑格**
	#   （真实里就是"刚阵亡那人的格子"）⇒ 这里在目标旁边立一座本方碑（`true` 就是"我方碑"的简写口径）。
	_b.graves[Vector2i(3, 2)] = true
	var tgtF: Unit = null
	var sum_atk := 0
	for u in _b.units:
		if u == null or not is_instance_valid(u) or not u.alive:
			continue
		if u.faction == DataRegistry.Faction.ENEMY:
			sum_atk += u.effective_atk()
		else:
			tgtF = u
	if tgtF != null:
		# ⚠️ 本探针自带牌组里有圣光(hero_22) ⇒ 它会在回合末 `call_deferred()` 给全队发 [圣盾]，
		#   飘到这一格上会把"合力斩杀"整条判成"收不掉"（第一版探针就踩了这个坑）。
		#   口径是"没盾时能不能收" ⇒ 这里先清掉，下面再单独加一面盾做对照。
		tgtF.remove_status(StatusDB.SHIELD)
		tgtF.max_hp = sum_atk + 1
		tgtF.hp = sum_atk + 1
		tgtF._update_hp_label()
	_b.player_dead = 2
	var candsF: Array = _b._dynamic_sub_candidates()
	var cellsF: Array = _b._sub_legal_cells_for_ai()
	var scanF := _b._sub_kill_scan(candsF, cellsF)
	print("PROBE|F_合力斩杀|我方合计攻=%d|目标血=%d|合法落点=%d" % [sum_atk, sum_atk + 1, cellsF.size()])
	if scanF.is_empty():
		print("PROBE|F_合力斩杀|候选池=%d|scan=❌ 没有斩杀计划" % candsF.size())
	else:
		print("PROBE|F_合力斩杀|候选池=%d|scan=%s→%s|需要%.0f=队友%.0f+替补%.0f|对面剩%d人|solo=%s" % [
			candsF.size(), String(scanF["hero"]), str(scanF["cell"]), float(scanF["need"]),
			float(scanF["team"]), float(scanF["sub"]), int(scanF["foe_alive"]), str(bool(scanF["solo"]))])
	var dynF := _b._dynamic_sub_pick()
	print("PROBE|F_合力斩杀|_dynamic_sub_pick()=%s" % str(dynF))
	# 同盘面加一面 [圣盾]：盾整次免伤、只挡一笔 ⇒ 应判"收不掉"（合力 6+5 − 最大那笔 5 = 6 < 7）
	if tgtF != null:
		tgtF.add_status(StatusDB.SHIELD)
		var scanSh := _b._sub_kill_scan(candsF, cellsF)
		print("PROBE|F_合力斩杀·带圣盾|scan=%s" % ("❌ 收不掉（盾吃掉最大那一笔）" if scanSh.is_empty() else str(scanSh)))
		tgtF.remove_status(StatusDB.SHIELD)
	# ---- G：【2026-09-29 晚·用户「为什么说的上塔盾，结果上了个超新星」】预设席那条路的**收尾优先覆盖**
	#      必须"日志说的"与"实际上的"是同一个人。这里摆一个"需求制想上坦克、收尾优先想上能补刀的人"的盘面，
	#      然后**真的跑一次 `_place_enemy_sub()`**，把"需求制建议 / 收尾优先选的人 / 实际上场的人"三者打出来。
	_clear()
	_spawn("hero_26", 1, Vector2i(3, 1))
	_spawn("hero_16", 1, Vector2i(1, 1))
	_spawn("hero_23", 0, Vector2i(3, 3))       # 玩家方：贴着下面那座碑的一血目标
	_spawn("hero_34", 0, Vector2i(1, 4))
	# ⚠️ 本探针的 `_spawn()` 返回 void（不是 Unit）⇒ 只能按格子把它找回来（写 `var t := _spawn(...)` 会解析报错、
	#   整个脚本加载失败、场景什么都不做 = 看着像"卡住"）。
	var tgtG: Unit = null
	for u in _b.units:
		if u != null and is_instance_valid(u) and u.alive and u.faction != DataRegistry.Faction.ENEMY and u.cell == Vector2i(3, 3):
			tgtG = u
	# ⚠️ 墓碑必须是**字典**（真实口径 `{ "fn": 阵营, "hero": id }`）：`_free_sub_cell_for()` 会读 `gd["fn"]`，
	#   塞个 `true` 进去会在真实落位那条路上抛错、协程当场死掉 ⇒ `await` 永远等不到（探针就卡死在这）。
	_b.graves[Vector2i(3, 2)] = { "fn": DataRegistry.Faction.ENEMY, "hero": "hero_11" }
	if tgtG != null:
		tgtG.remove_status(StatusDB.SHIELD)
		tgtG.hp = 1                              # 一血目标 ⇒ "补上来就能收"的人多半不是需求制那个
	_b.enemy_roster = ["hero_11", "hero_25", "hero_16", "hero_36"]   # 塔盾/战锤/波盾/梅林
	var ctxG := _b._sub_ctx()
	var need_idxG := _b._best_enemy_sub_idx()
	var need_name := String(_b.enemy_roster[need_idxG]) if need_idxG < _b.enemy_roster.size() else "（越界）"
	var fin_idxG := _b._sub_finish_hero_pick(_b._sub_legal_cells_for_ai(), need_idxG)
	var fin_name := (String(_b.enemy_roster[fin_idxG]) if fin_idxG >= 0 and fin_idxG < _b.enemy_roster.size() else "无（不覆盖）")
	var expect_hid := String(_b.enemy_roster[fin_idxG if fin_idxG >= 0 else need_idxG])
	_b._pending_enemy_sub = 1
	# ⚠️ 判"实际上场的是谁"要按**实例 id 差集**找新冒出来的那个（这个探针的 `_b` 还挂着 Main.tscn 自带牌组，
	#   按"下标 >= n0"找会误抓到别人 —— 第一版就抓成了 hero_28）。
	var before := {}
	for u in _b.units:
		before[u.get_instance_id()] = true
	var roster0 := _b.enemy_roster.size()
	# ⚠️ **不 `await`**：这一支是协程，落位发生在第一个 `await` 之前；若它中途抛错，`await` 会永远等不到
	#   （探针卡死、既没输出也没报错）。不 await + 等固定帧数 ⇒ 出错时只会看到"实际上场=（空）"。
	_b._place_enemy_sub()
	for i in 20:
		await get_tree().process_frame
	var landed := ""
	for u in _b.units:
		if u != null and is_instance_valid(u) and u.alive and not before.has(u.get_instance_id()) \
				and u.faction == DataRegistry.Faction.ENEMY:
			landed = String(u.hero_id)
			break        # ⚠️ 取**第一个**新冒出来的（`units` 按落位顺序追加；这片盘面里可能一次落好几个人）
	var note := "名单 %d→%d" % [roster0, _b.enemy_roster.size()]
	print("PROBE|G_收尾优先覆盖日志|SUB_FINISH_W=%.0f|需求=%s|需求制建议=%s(下标%d)|收尾优先=%s|**实际上场=%s**|%s|%s" % [
		_b._sub_finish_w(), DataRegistry.sub_need_label(String(ctxG.get("need", ""))),
		need_name, need_idxG, fin_name, landed, note,
		("PASS（日志说的与实际一致）" if landed == expect_hid else "FAIL（说的与实际不是一个人！）")])
	await _done()

## 逐人打分（只为日志对照）
func _scores_txt(list: Array, ctx: Dictionary) -> String:
	var out: Array = []
	for hid in list:
		var sc := DataRegistry.sub_hero_score(String(hid), String(ctx.get("need", "")), ctx)
		out.append("%s %.1f" % [String(hid), float(sc.get("s", 0.0))])
	return " ".join(out)

## 摆一个盘面，打印"需求 + 候选数 + 20 次出人分布"（`_sub_pick_need_band` 自己的日志会打圈内名单）
func _case(tag: String) -> void:
	var ctx := _b._sub_ctx()
	var need := String(ctx.get("need", ""))
	var cands: Array = _b._dynamic_sub_candidates()
	var elig: Array = []
	for hid in cands:
		if DataRegistry.sub_hero_eligible(String(hid), need, ctx):
			elig.append(String(hid))
	var picks := {}
	for i in 20:
		var hid := _b._sub_pick_need_band(cands, ctx, need)
		picks[hid] = int(picks.get(hid, 0)) + 1
	var dist: Array = []
	for k in picks.keys():
		dist.append("%s×%d" % [k, int(picks[k])])
	print("PROBE|%s|need=%s|ctx(嘲讽%d 治疗%d 输出%d 远程%d 伤员%d 核心%s 已被克制=%s)|候选=%d|需求命中=%d|20次出人: %s" % [
		tag, DataRegistry.sub_need_label(need),
		int(ctx.get("taunt", 0)), int(ctx.get("healers", 0)), int(ctx.get("dps", 0)),
		int(ctx.get("ranged", 0)), int(ctx.get("wounded", 0)), String(ctx.get("core", "")),
		str(bool(ctx.get("countered", false))), cands.size(), elig.size(), " ".join(dist)])

func _clear() -> void:
	for u in _b.units:
		if is_instance_valid(u):
			u.queue_free()
	_b.units.clear()
	_b.occupancy.clear()
	_b.graves.clear()
	_b.obstacles.clear()
	_b.enemy_roster.clear()
	_b.player_roster.clear()
	_b.enemy_dead = 0
	_b.player_dead = 0

func _spawn(hid: String, faction: int, cell: Vector2i, hp: int = -1, max_hp: int = -1) -> void:
	var u := _b._spawn_unit(hid, faction, cell)
	if u == null:
		print("PROBE|WARN|spawn_failed|%s" % hid)
		return
	if max_hp > 0:
		u.max_hp = max_hp
	if hp > 0:
		u.hp = hp
	u._update_hp_label()

func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame

func _wait_state(states: Array, limit: float) -> bool:
	var t := 0.0
	while t < limit:
		if states.has(_b.state):
			return true
		await get_tree().process_frame
		t += 1.0 / 60.0
	return false

func _done() -> void:
	print("PROBE|END")
	get_tree().quit(0)

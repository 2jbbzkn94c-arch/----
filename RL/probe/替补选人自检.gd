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

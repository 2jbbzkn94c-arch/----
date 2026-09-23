extends Node
## 【2026-09-23 一次性探针】嘲讽槽"概率实算"—— 完整复刻噩梦档的三槽部署链，
## 直接回答：「我首发带了**会被克制的英雄**（毒蛇 / 远程 / 后勤）时，AI 的嘲讽槽到底会挑谁、各多少概率」。
##
## 为什么不是"只算底分"：嘲讽槽（第 3 槽）的打分里除了"对玩家已首发的净克制"，还叠了
##   ① `_deck_synergy(enemy_deployed, cand)`（跟**敌方自己前两手**的协同）
##   ② `DataRegistry.role_balance_bonus(enemy_deployed, cand)`（职能配比）
##   ③ `_deploy_candidate_value()` 里的坦克/硬身板三条规则（都看 `enemy_deployed`）
##   ⇒ 这些全取决于"敌方前两手挑了谁"，而前两手本身又是随机的 ⇒ 必须整链蒙卡，不能只看底分。
##
## 与线上口径的对应（逐条对齐 `src/Battle.gd`）：
##   · 配方与三槽候选池：逐字抄 `RL/weights/队伍池_噩梦.json`（R04 / R05，`w` 都是 1 ⇒ 各 50%）
##   · 每槽打分：`_deploy_candidate_value(h, enemy_deployed) + randf() * jitter`（jitter = meta.pick_jitter = 2）
##   · 每槽挑法：3 槽 `pick` 全空 ⇒ 泛化槽"上位圈随机"：`分数 >= 最高分 − band` 里均匀随机（band = 6）
##   · 部署先后手：`_deploy_side = rng.randi() % 2` ⇒ 玩家先手 50%（此时嘲讽槽落地时玩家已上 3 人）
##     / 敌方先手 50%（此时玩家只上了 2 人）—— 两种都按 50% 混进蒙卡
##   · 替补（`Skill.BENCH`）候选剔除；同槽不重复上同一人
##
## 不改任何生产代码。用法（**必须走隔离跑法**）：
##   & RL\train\跑Godot隔离.ps1 -Tag taunt -TimeoutSec 600 -Args @('--headless','--path',(Get-Location).Path,'--scene','res://RL/probe/嘲讽位实算.tscn')
## 输出（**全 ASCII**，避免控制台编码把中文糊掉）：
##   TAUNT|cfg|trials=...|band=6.0|jitter=2.0|pool=队伍池_噩梦.json
##   TAUNT|L=hero_03,hero_20,hero_17|CTR=62.4|AVG=+0.86|hero_44=21.3|hero_25=14.0|...
##   TAUNT|END
##   `CTR` = 挑出来的嘲讽英雄**明确克制我方至少一人**的比例（"针对率"）；`AVG` = 该槽净克制项均值。

const TRIALS := 20000
const BAND := 6.0
const JITTER := 2.0

## 三槽候选池（= 队伍池_噩梦.json 里 R04/R05 的 slot 池，逐字照抄，顺序不影响结果）
const NEAR: Array[String] = ["hero_27", "hero_03", "hero_01", "hero_14", "hero_40", "hero_42", "hero_04", "hero_46", "hero_15", "hero_38", "hero_18", "hero_32", "hero_17"]
const RANGED: Array[String] = ["hero_10", "hero_21", "hero_34", "hero_08", "hero_09", "hero_20", "hero_33", "hero_06", "hero_07", "hero_45"]
const TAUNT: Array[String] = ["hero_13", "hero_44", "hero_23", "hero_49", "hero_12", "hero_22", "hero_11", "hero_26", "hero_25", "hero_48"]

## 玩家首发（顺序 = 玩家自己上的顺序；前两手/三手会按先后手决定"嘲讽槽落地时已上几个"）
## ⚠️ 文档 `Data/Progress_tracking/5_选人策略.md` §⑤-9 里的读数是**分两批**跑的：
##    A 批（下面第 1~10 条）每阵容 40000 次；B 批（第 11~16 条）每阵容 30000 次。
##    合成一份后默认 `TRIALS = 20000`（±0.3pp 级别，结论不变）—— 直接复跑会得到同样的分布，但小数位会差一点。
const LINEUPS := [
	# —— A 批：用户问的场景（毒蛇 / 远程 / 后勤）——
	["hero_03", "hero_20", "hero_17"],   # 毒蛇 + 远程(赏金猎人) + 后勤(烛火)
	["hero_03", "hero_09", "hero_38"],   # 毒蛇 + 远程(火枪手)  + 后勤(涌电技师)
	["hero_03", "hero_20", "hero_38"],   # 毒蛇 + 远程(赏金猎人) + 后勤(涌电技师)
	["hero_03", "hero_17", "hero_20"],   # 同上但顺序换成 毒蛇/后勤/远程
	["hero_03", "hero_27", "hero_01"],   # 只带毒蛇（另两名中性近战）
	["hero_20", "hero_27", "hero_01"],   # 只带远程（赏金猎人）
	["hero_09", "hero_27", "hero_01"],   # 只带远程（火枪手）
	["hero_17", "hero_27", "hero_01"],   # 只带后勤（烛火）
	["hero_38", "hero_27", "hero_01"],   # 只带后勤（涌电技师）
	["hero_27", "hero_01", "hero_04"],   # 对照组：三名中性近战（与嘲讽池无克制关系）
	# —— B 批：极端靶子（把"克制项"顶到 ±6 的上限，看嘲讽槽会不会被一家吃光）——
	["hero_09", "hero_20", "hero_17"],   # 远程+远程+后勤（荆棘树人克这三人全部 ⇒ +6）
	["hero_38", "hero_17", "hero_34"],   # 后勤+后勤+远程（同上 +6）
	["hero_03", "hero_25", "hero_26"],   # 毒蛇+战锤+雪拳（负墟克这三人全部 ⇒ +6）
	["hero_12", "hero_46", "hero_10"],   # 巨剑+宿魂+白游侠（负墟 +6）
	["hero_22", "hero_03", "hero_20"],   # 圣光+毒蛇+赏金猎人（圣光被毒蛇克 −2；赏金猎人克全嘲讽池 −2）
	["hero_17", "hero_38", "hero_09"],   # 后勤+后勤+远程（换顺序，验顺序敏感度）
]

var _b: Battle = null

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	seed(20260923)
	GameState.reset_online()
	GameState.dual_control = false
	GameState.arena_mode = false
	_b = load("res://scenes/Main.tscn").instantiate() as Battle
	get_tree().root.add_child(_b)
	await get_tree().process_frame
	await get_tree().process_frame
	print("TAUNT|cfg|trials=%d|band=%.1f|jitter=%.1f|pool=nightmare_R04R05" % [TRIALS, BAND, JITTER])
	for li in LINEUPS.size():
		_lineup(",".join(PackedStringArray(LINEUPS[li])))
	print("TAUNT|END")
	_b.queue_free()
	await get_tree().process_frame
	get_tree().quit(0)

func _lineup(ids: String) -> void:
	var lineup: Array = []
	for h in ids.split(","):
		lineup.append(String(h))
	var tally := {}
	var ctr_hits := 0
	var ctr_sum := 0.0
	for t in TRIALS:
		var player_first := randi() % 2 == 0
		var slot2: Array = RANGED if randi() % 2 == 0 else NEAR
		var rec: Array = [NEAR, slot2, TAUNT]
		_b.enemy_deployed = []
		var last := ""
		for i in 3:
			var n: int = i + (1 if player_first else 0)
			_b.player_deployed = []
			for k in mini(n, lineup.size()):
				_b.player_deployed.append(String(lineup[k]))
			last = _pick_slot(rec[i] as Array)
			_b.enemy_deployed.append(last)
		tally[last] = int(tally.get(last, 0)) + 1
		ctr_sum += _b._counter_deployed_score(last)
		for p in _b.player_deployed:
			if DataRegistry.counter_bonus(last, String(p)) > 0.0:
				ctr_hits += 1
				break
	var rows: Array = []
	for k in tally.keys():
		rows.append({ "h": String(k), "n": int(tally[k]) })
	rows.sort_custom(func(a, b): return int(a["n"]) > int(b["n"]))
	var txt := ""
	for r in rows:
		txt += "%s=%.1f|" % [String(r["h"]), 100.0 * float(r["n"]) / float(TRIALS)]
	print("TAUNT|L=%s|CTR=%.1f|AVG=%+.2f|%s" % [
		ids, 100.0 * float(ctr_hits) / float(TRIALS), ctr_sum / float(TRIALS), txt])

## 单槽挑人：与 `Battle._recipe_deploy_pick()` 的泛化槽分支逐条同口径（band 上位圈 + 抖动）
func _pick_slot(pool: Array) -> String:
	var cands: Array = []
	var scores: Array = []
	for h in pool:
		var hs := String(h)
		if hs == "" or _b.enemy_deployed.has(hs):
			continue
		var d := DataRegistry.get_hero(hs)
		if d == null or d.skills.has(DataRegistry.Skill.BENCH):
			continue
		cands.append(hs)
		scores.append(_b._deploy_candidate_value(hs, _b.enemy_deployed) + randf() * JITTER)
	if cands.is_empty():
		return ""
	var best := -1e18
	for s in scores:
		best = maxf(best, float(s))
	var pool_idx: Array = []
	for i in cands.size():
		if float(scores[i]) >= best - BAND:
			pool_idx.append(i)
	return String(cands[int(pool_idx[randi() % pool_idx.size()])])

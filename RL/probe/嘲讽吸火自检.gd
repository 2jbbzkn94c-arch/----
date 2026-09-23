extends Node
## 【2026-09-23 一次性探针】㉕嘲讽吸火自检 —— 跑完即退，**不改任何生产代码**。
##
## 回答用户贴的那条决策日志里的可疑读数：`毒蛇淑女 移动 (4,1)→(3,2) … 项Δ：㉕嘲讽吸火 +0.00→+6.67`。
## 盘面按用户截图 `PICTURE/堡垒不向前.png` + 那条日志原样复现（第 2 回合，AI 刚走完这一步）：
##   敌方(AI)：装甲堡垒(0,1)【嘲讽】 · 鼠队长(2,2) · 毒蛇淑女(3,2)
##   我方(玩家)：共鸣者(2,3) · 白游侠(2,4) · 荆棘树人(3,4)【嘲讽】<远程><后勤>
##   障碍：(1,3) 木桶（截图里还有一个桶位 (3,3) 已被打掉 ⇒ 这里当空格）
## 手算预期：嘲讽者是**远在 (0,1) 的装甲堡垒**（射程 1），我方三只对 (2,2)/(3,2) 的任一开火位都够不到它
##   ⇒ 嘲讽门**不该**挡下任何一笔 ⇒ ㉕ 应为 **0**。日志里却是 +6.67 ⇒ 本探针把 ㉕ 逐单位拆开：
##   对每个**非嘲讽的 AI 单位 X** 打印 `关掉嘲讽门的挨打合计 / 实际挨打合计 / 血量池倍率 / 这一笔贡献`，
##   并把两趟的**逐笔来源**（谁打的、多少）都列出来 ⇒ 一眼看出是被谁挡的、还是判据本身有问题。
## 另外为了交叉验证，两件事一起打：① `_threat_can_hit` 对每个(我方攻手 → AI 目标)的结论；
##   ② 全局面 `_evaluate` 拆解里的 ㉕ 那一项（应与 `_taunt_soak()` 一致）。
##
## 用法：
##   & RL\train\跑Godot隔离.ps1 -Tag tauntsoak -TimeoutSec 600 -Args @('--headless','--path',(Get-Location).Path,'--scene','res://RL/probe/嘲讽吸火自检.tscn')
## 输出：每行 `PROBE|...`（ASCII + 少量中文），末尾 `PROBE|END`。

const FORK := preload("res://RL/ai/AI_Battle.gd")
const WEIGHTS := "res://RL/weights/噩梦.json"

var _grid: HexGrid
var _nm: Dictionary = {}

func _ready() -> void:
	_grid = HexGrid.new(5, 7, 48.0)
	_grid.top_cap_cols = [1, 3]
	_run.call_deferred()

func _run() -> void:
	_nm = _load_json(WEIGHTS)
	print("PROBE|CFG|fork=%s|nm_TAUNT_SOAK_W=%s|nm_INCOMING_POOL_W=%s" % [
		_sha("res://RL/ai/AI_Battle.gd"), str(_nm.get("TAUNT_SOAK_W", 0)), str(_nm.get("INCOMING_POOL_W", 0))])
	# 主场景 = 日志里"毒蛇走完那一步之后"的局面；对照 = 走之前（毒蛇还在 (4,1)，日志说那时 ㉕=0）
	_case("AFTER", Vector2i(3, 2))
	_case("BEFORE", Vector2i(4, 1))
	print("PROBE|END")
	get_tree().quit(0)

func _case(tag: String, snake_cell: Vector2i) -> void:
	var descs: Array = []
	descs.append(_desc(DataRegistry.Faction.ENEMY, "hero_48", Vector2i(0, 1), "装甲堡垒"))
	descs.append(_desc(DataRegistry.Faction.ENEMY, "hero_04", Vector2i(2, 2), "鼠队长"))
	descs.append(_desc(DataRegistry.Faction.ENEMY, "hero_03", snake_cell, "毒蛇淑女"))
	descs.append(_desc(DataRegistry.Faction.PLAYER, "hero_47", Vector2i(2, 3), "共鸣者"))
	descs.append(_desc(DataRegistry.Faction.PLAYER, "hero_10", Vector2i(2, 4), "白游侠"))
	descs.append(_desc(DataRegistry.Faction.PLAYER, "hero_49", Vector2i(3, 4), "荆棘树人"))
	var obs := { Vector2i(1, 3): true }
	var built := _build(descs, obs)
	var ai = built["ai"]
	var sim = built["sim"]
	print("PROBE|%s|盘面：AI 堡垒(0,1) 鼠队长(2,2) 毒蛇%s ｜ 玩家 共鸣者(2,3) 白游侠(2,4) 荆棘树人(3,4) ｜ 障碍(1,3)" % [
		tag, str(snake_cell)])
	# ① 每个单位这一刻的"这一下多疼"（含 ⑪ 共鸣者补算）与 ⑩ 后勤门结论
	for i in sim.units.size():
		var u = sim.units[i]
		var side := "AI " if u.fn == DataRegistry.Faction.ENEMY else "玩家"
		print("PROBE|%s|ATK|%s%s@%s|eatk=%d|threat_atk=%.1f|后勤=%s|嘲讽=%s|射程=%d|移动=%d" % [
			tag, side, String(u.name), str(u.cell), int(u.eatk), float(ai._echo_atk_now(sim, u)),
			str(u.skills.has(DataRegistry.Skill.LOGISTICS)), str(u.skills.has(DataRegistry.Skill.TAUNT)),
			int(u.atk_range), int(u.emove)])
	# ② ㉕ 逐单位拆开
	for i in sim.units.size():
		var x = sim.units[i]
		if x == null or not x.alive or x.fn != DataRegistry.Faction.ENEMY:
			continue
		if x.skills.has(DataRegistry.Skill.TAUNT):
			print("PROBE|%s|㉕|%s 是嘲讽单位 ⇒ ㉕ 不算它" % [tag, String(x.name)])
			continue
		var pf: Dictionary = {}
		var free_v := float(ai._incoming_total_on(sim, x, x.cell, pf, true))
		var pa: Dictionary = {}
		var act_v := float(ai._incoming_total_on(sim, x, x.cell, pa))
		var mult := float(ai._incoming_pool_mult(x))
		print("PROBE|%s|㉕|%s@%s|关掉嘲讽门=%.1f%s ｜ 实际=%.1f%s ｜ 血量池倍率=%.3f ｜ 差额=%.1f ⇒ 这一笔=%.2f" % [
			tag, String(x.name), str(x.cell), free_v, str(pf.get("parts", [])),
			act_v, str(pa.get("parts", [])), mult, free_v - act_v, maxf(free_v - act_v, 0.0) * mult])
	# ③ 嘲讽门：每个(我方攻手 → AI 目标)一对，看 `_threat_can_hit` 怎么判
	for i in sim.units.size():
		var a = sim.units[i]
		if a == null or not a.alive or a.fn == DataRegistry.Faction.ENEMY:
			continue
		var blocked := ""
		for j in sim.units.size():
			var t = sim.units[j]
			if t == null or not t.alive or t.fn != DataRegistry.Faction.ENEMY:
				continue
			if t.skills.has(DataRegistry.Skill.TAUNT):
				continue
			blocked += "%s=%s " % [String(t.name), str(ai._threat_can_hit(sim, a, t.cell, t))]
		var taunt_reach := ""
		for j in sim.units.size():
			var t2 = sim.units[j]
			if t2 != null and t2.alive and t2.fn == DataRegistry.Faction.ENEMY \
					and t2.skills.has(DataRegistry.Skill.TAUNT):
				taunt_reach = "%s@%s 从它当前格够得到=%s" % [String(t2.name), str(t2.cell),
					str(ai._cell_in_range(sim, a, a.cell, t2.cell))]
		print("PROBE|%s|门|%s@%s 能否打到（带嘲讽门）：%s｜嘲讽者%s" % [
			tag, String(a.name), str(a.cell), blocked, taunt_reach])
	# ④ 全局面交叉验证
	var bd: Dictionary = ai._eval_breakdown(sim)
	print("PROBE|%s|合计|_taunt_soak()=%.2f ｜ 拆解㉕=%.2f ｜ 项Δ列表=%s" % [
		tag, float(ai._taunt_soak(sim)), float(bd.get("㉕嘲讽吸火", 0.0)), str(bd.keys())])

# ---------------------------------------------------------------- 工具
func _build(descs: Array, obs: Dictionary = {}) -> Dictionary:
	var occ := {}
	for i in descs.size():
		occ[descs[i]["cell"]] = i
	var ai = FORK.new(_grid)
	ai.difficulty = 3
	ai.log_decisions = false
	ai.time_budget_ms = 20000
	ai.set_weights(_nm)
	var sim = ai.build_state(descs, occ, {}, {}, obs, {}, {})
	return { "sim": sim, "ai": ai }

func _desc(fn: int, hid: String, cell: Vector2i, nm: String) -> Dictionary:
	var hd = DataRegistry.heroes[hid]
	var emove := 2
	if (hd.skills as Array).has(DataRegistry.Skill.SWIFT):
		emove = 3
	return {
		"fn": fn, "hero": hid, "cell": cell, "hp": int(hd.max_hp), "max_hp": int(hd.max_hp),
		"atk": int(hd.atk), "eatk": int(hd.atk), "move": emove, "emove": emove,
		"atk_range": maxi(int(hd.attack_range), 1), "atk_type": int(hd.attack_type),
		"skills": (hd.skills as Array).duplicate(), "name": nm,
	}

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

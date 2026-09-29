extends Node
## 【2026-09-28 一次性探针】"反击名额"自检 —— 回答：
##   AI 算"这一手值不值"时，知不知道**目标这一回合的反击已经被队友用掉了、我不会再吃**？
## 机制（读代码得到）：
##   · 真实：`Unit.counter_used_this_turn` 每回合一次（`src/Battle.gd:5988` 判、`:5998` 置；
##     `Unit.gd:846` 每回合清），例外 = 复仇者 hero_23 的 `infinite_counter()`。
##   · 模拟：`SimUnit.counter_used` + `_sim_counter_check()`（`src/BattleAI.gd:6536`），
##     判据与真实**同一句**：`if t.counter_used and t.hero_id != "hero_23": return`。
## 本探针把这条账**数字化**：同一目标连着被两个我方单位打 ⇒ 第二次该不该吃反击。
## ⚠️ 两次出手必须走**同一份 sim**（= 搜索里"第二步看到的是第一步结算后的局面"）。
## 输出：每行 `CT|...`，末尾 `CT|END`。

var battle: Battle

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	battle = (load("res://scenes/Main.tscn") as PackedScene).instantiate() as Battle
	add_child(battle)
	for i in 3:
		await get_tree().process_frame
	battle.player_roster = []
	battle.enemy_roster = []
	var a1 = battle._spawn_unit("hero_12", DataRegistry.Faction.ENEMY, Vector2i(1, 2))
	var a2 = battle._spawn_unit("hero_18", DataRegistry.Faction.ENEMY, Vector2i(3, 2))
	var foe = battle._spawn_unit("hero_10", DataRegistry.Faction.PLAYER, Vector2i(2, 3))
	for i in 2:
		await get_tree().process_frame
	print("CT|摆盘A|我方 %s@%s(攻%d) + %s@%s(攻%d)｜敌方 %s@%s(攻%d 血%d)" % [
		str(a1.display_name), str(a1.cell), int(a1.effective_atk()),
		str(a2.display_name), str(a2.cell), int(a2.effective_atk()),
		str(foe.display_name), str(foe.cell), int(foe.effective_atk()), int(foe.hp)])

	var res_a: Array = _two_hits(a1, a2, foe)
	var first: Dictionary = res_a[0]
	var second: Dictionary = res_a[1]
	print("CT|A 普通目标(每回合只能反击一次)|①%s 打 → 它掉 %d 血、吃反击 %d（目标反击名额 %s→%s）" % [
		str(first.get("attacker", "?")), int(first.get("foe_lost", -1)), int(first.get("attacker_lost", -1)),
		str(first.get("counter_before", "?")), str(first.get("counter_after", "?"))])
	print("CT|A 第二手|②%s 再打 → 它掉 %d 血、**吃反击 %d**（目标名额 %s→%s）" % [
		str(second.get("attacker", "?")), int(second.get("foe_lost", -1)), int(second.get("attacker_lost", -1)),
		str(second.get("counter_before", "?")), str(second.get("counter_after", "?"))])
	print("CT|A 判读|第二手吃到反击 %d 点（期望 0 = 名额已被队友用掉）" % int(second.get("attacker_lost", -1)))

	# ---------- 局面 B：复仇者（无限反击）----------
	var foe2 = battle._spawn_unit("hero_23", DataRegistry.Faction.PLAYER, Vector2i(2, 5))
	_move_to(a1, Vector2i(1, 4))
	_move_to(a2, Vector2i(3, 4))
	for i in 2:
		await get_tree().process_frame
	print("CT|摆盘B|敌方 %s@%s(攻%d 血%d)" % [
		str(foe2.display_name), str(foe2.cell), int(foe2.effective_atk()), int(foe2.hp)])
	var res_b: Array = _two_hits(a1, a2, foe2)
	var b1: Dictionary = res_b[0]
	var b2: Dictionary = res_b[1]
	print("CT|B 复仇者(无限反击)|①%s 打 → 它掉 %d、吃反击 %d；②%s 再打 → 它掉 %d、**吃反击 %d**" % [
		str(b1.get("attacker", "?")), int(b1.get("foe_lost", -1)), int(b1.get("attacker_lost", -1)),
		str(b2.get("attacker", "?")), int(b2.get("foe_lost", -1)), int(b2.get("attacker_lost", -1))])
	print("CT|B 判读|第二手仍吃反击 %d 点（期望 > 0 = 复仇者不受名额限制）" % int(b2.get("attacker_lost", -1)))

	print("CT|END")
	get_tree().quit(0)

## 在同一份模拟里连着做两次"我方近战贴身打同一个目标"，返回两次的反击结算读数。
func _two_hits(x: Unit, y: Unit, foe: Unit) -> Array:
	var out: Array = []
	var pair := battle._sim_pair(x, foe)
	if pair.is_empty():
		return [{ "err": "建不出模拟局面" }, { "err": "建不出模拟局面" }]
	var ai = pair["ai"]
	var sim = pair["sim"]
	var st: RefCounted = pair["st"]
	for i in 2:
		var atk: RefCounted = pair["su"] if i == 0 else _sim_of(sim, y)
		if atk == null:
			out.append({ "err": "找不到第二个攻击者" })
			continue
		var hp_before := int(atk.hp)
		var foe_before := int(st.hp)
		var cb := bool(st.counter_used)
		ai._sim_counter_check(sim, atk, st)
		out.append({
			"attacker": str(atk.name),
			"attacker_lost": hp_before - int(atk.hp),
			"foe_lost": foe_before - int(st.hp),
			"counter_before": cb, "counter_after": bool(st.counter_used),
		})
	return out

func _sim_of(sim, u: Unit) -> RefCounted:
	var i := battle.units.find(u)
	if i < 0 or i >= sim.units.size():
		return null
	return sim.units[i]

func _move_to(u: Unit, cell: Vector2i) -> void:
	u.cell = cell
	u.position = battle.grid.cell_to_world(cell)

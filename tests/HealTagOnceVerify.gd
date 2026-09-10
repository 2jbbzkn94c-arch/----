extends Node
## 机制飘字去重回归：一次治疗只该弹**一个**"治疗"飘字。
##
## 历史 bug（已修）：医护兵移动后治疗时"治疗"弹了两次——
##   ① Battle._heal_adjacent_lowest() 里 float_tag_text("治疗", ...)   → 飘字 #1（y-88）
##   ② hero_06_医护兵.gd 接着调 fx() → burst_fx(color, text)，
##      而 DataRegistry.HERO_FX["hero_06"].text 恰好也是 "治疗"        → 飘字 #2（y-46）
##   两个文案相同的 Label 一上一下叠着，看着就是"弹了两次治疗"。
## 修法：Battle 原语只做规则（_heal 让被治者弹 "+N"），**施加方的机制飘字交给英雄脚本的
## fx()**（与"重构第一批/第二批"把英雄演出搬进各自脚本的方向一致）。
##
## T1 医护兵（移动后治疗相邻最低血队友）→ "治疗" 恰好 1 个
## T2 德鲁伊（回合末治疗所有受伤队友）  → "治疗" 恰好 1 个
## T3 梅林  （替补登场治疗最低血+换位） → "治疗" 恰好 1 个（另有"置换"属正常，不计入）
##
## 运行：godot --headless --scene res://tests/HealTagOnceVerify.tscn
var battle: Battle
var results := {}

func _ready() -> void:
	battle = load("res://scenes/Main.tscn").instantiate() as Battle
	add_child(battle)
	_run.call_deferred()

func rec(id: String, ok: bool, note: String) -> void:
	results[id] = [ok, note]
	print("%s  [%s] %s" % [id, "PASS" if ok else "FAIL", note])

# 清场：清空单位 + 清掉上一例残留的飘字 Label（飘字存活约 1.2s，不清理会污染下一例计数）
func reset_field() -> void:
	for u in battle.units:
		if is_instance_valid(u):
			u.queue_free()
	battle.units.clear()
	battle.occupancy.clear()
	for c in battle.get_children():
		if c is Label:
			c.queue_free()
	await get_tree().process_frame

# _float_text 把飘字 Label 挂在单位的父节点（= Battle）上
func count_tag(text: String) -> int:
	var n := 0
	for c in battle.get_children():
		if c is Label and c.text == text:
			n += 1
	return n

func spawn(hid: String, c: Vector2i) -> Unit:
	return battle._spawn_unit(hid, DataRegistry.Faction.PLAYER, c)

func _run() -> void:
	# ---- T1: 医护兵 · 移动后治疗 ----
	await reset_field()
	var medic := spawn("hero_06", Vector2i(3, 6))
	var hurt1 := spawn("hero_15", Vector2i(4, 6))
	hurt1.hp = 1
	await get_tree().process_frame
	var before1 := count_tag("治疗")
	battle._trigger_on_move(medic)
	await get_tree().process_frame
	var n1 := count_tag("治疗") - before1
	rec("T1 医护兵", n1 == 1 and hurt1.hp > 1, "治疗飘字=%d 队友hp=%d" % [n1, hurt1.hp])

	# ---- T2: 德鲁伊 · 回合末治疗全体 ----
	await reset_field()
	var druid := spawn("hero_08", Vector2i(3, 6))
	var hurt2 := spawn("hero_15", Vector2i(4, 6))
	hurt2.hp = 1
	await get_tree().process_frame
	var before2 := count_tag("治疗")
	battle._trigger_turn_end(druid)
	await get_tree().process_frame
	var n2 := count_tag("治疗") - before2
	rec("T2 德鲁伊", n2 == 1 and hurt2.hp > 1, "治疗飘字=%d 队友hp=%d" % [n2, hurt2.hp])

	# ---- T3: 梅林 · 替补登场治疗 + 换位 ----
	await reset_field()
	var merlin := spawn("hero_36", Vector2i(3, 6))
	var hurt3 := spawn("hero_15", Vector2i(4, 6))
	hurt3.hp = 1
	await get_tree().process_frame
	var before3 := count_tag("治疗")
	battle._trigger_on_enter(merlin)
	await get_tree().process_frame
	var n3 := count_tag("治疗") - before3
	rec("T3 梅林", n3 == 1 and hurt3.hp > 1, "治疗飘字=%d 队友hp=%d" % [n3, hurt3.hp])

	# ---- 汇总 ----
	var ok := true
	for k in results.keys():
		if not results[k][0]:
			ok = false
	print("FINAL " + ("PASS" if ok else "FAIL"))
	get_tree().quit(0 if ok else 1)

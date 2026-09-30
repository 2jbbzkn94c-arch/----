extends Node
## 【2026-09-30 一次性探针】长角击退 × 远程反击 —— 量清"反击判定看到的距离是击退前还是击退后"。
## 用户口径：「长角把远程击退后，远程应该是可以远程反击的」。
##
## 三个局面（都让长角**贴身**打一个远程单位、它身后留一格空地可被推开）：
##   ① 长角 → 白游侠(远程)：打完距离 1 → 2（推开了），看它反不反击、若反击是近身冲还是远程抛射；
##   ② 对照·长角 → 近战单位：同理（近战被推开后按规则不该反击）；
##   ③ 对照·远程 ↔ 远程：远程对射本来就能反击（证明"远程反击"这条通路本身是通的）。
## 输出：每行 `KB|...`，末尾 `KB|END`。

var battle: Battle

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	battle = (load("res://scenes/Main.tscn") as PackedScene).instantiate() as Battle
	add_child(battle)
	for i in 4:
		await get_tree().process_frame
	# 听日志里那两行：反击与伤害
	battle.log_message.connect(func(t: String):
		if "反击" in t or "撞飞" in t or "重创" in t or "受到" in t:
			print("KB|日志|%s" % t))

	print("KB|单位类型|%s" % _type_txt())
	await _arm("hero_32", "hero_10", "①长角 → 远程(白游侠)")
	await _arm("hero_32", "hero_18", "②对照·长角 → 近战(长剑)")
	await _arm("hero_10", "hero_09", "③对照·远程 ↔ 远程(白游侠 → 火枪手)")
	print("KB|END")
	get_tree().quit(0)

func _arm(attacker_id: String, target_id: String, tag: String) -> void:
	var a = battle._spawn_unit(attacker_id, DataRegistry.Faction.ENEMY, Vector2i(2, 2))
	# 【关键摆位】目标在长角正下方 (2,3)、它更下方 (2,4) 留空 ⇒ 击退会把它推到 (2,4)（距离 1 → 2）
	var t = battle._spawn_unit(target_id, DataRegistry.Faction.PLAYER, Vector2i(2, 3))
	for i in 2:
		await get_tree().process_frame
	var d0: int = battle.grid.distance(a.cell, t.cell)
	var hp_t0 := int(t.hp)
	var hp_a0 := int(a.hp)
	print("KB|%s|开打前：%s(攻%d,%s)@%s vs %s(攻%d,%s)@%s｜距离=%d｜目标血=%d｜长角血=%d" % [
		tag, str(a.display_name), int(a.effective_atk()), _atk_type(a), str(a.cell),
		str(t.display_name), int(t.effective_atk()), _atk_type(t), str(t.cell), d0,
		hp_t0, hp_a0])
	# 逐帧采样：把"谁在第几帧动了、谁在第几帧掉血"抓出来（判断击退与反击的先后）
	var samples: Array[String] = []
	var last_sig := ""
	battle._do_attack(a, t, true)          # 协程：不 await，边跑边采样
	for f in 240:
		await get_tree().process_frame
		var sig := "%.1f|%s|%s|%d|%d" % [
			float(f),
			str(a.cell) if is_instance_valid(a) else "释放",
			str(t.cell) if is_instance_valid(t) else "释放",
			int(a.hp) if is_instance_valid(a) else -1,
			int(t.hp) if is_instance_valid(t) else -1]
		if sig.split("|")[1] != last_sig:
			pass
		var key := sig.substr(sig.find("|") + 1)
		if key != last_sig:
			samples.append("帧%-3d 长角@%s 血%s ｜目标@%s 血%s" % [
				f,
				str(a.cell) if is_instance_valid(a) else "释放",
				str(int(a.hp)) if is_instance_valid(a) else "-",
				str(t.cell) if is_instance_valid(t) else "释放",
				str(int(t.hp)) if is_instance_valid(t) else "-"])
			last_sig = key
		if not is_instance_valid(a) and not is_instance_valid(t):
			break
	for s in samples:
		print("KB|%s|变化|%s" % [tag, s])
	var d1: int = battle.grid.distance(a.cell, t.cell) if (is_instance_valid(a) and is_instance_valid(t)) else -1
	print("KB|%s|打完后：长角@%s(血 %d%s)｜目标@%s(血 %d%s)｜距离=%d" % [
		tag,
		str(a.cell) if is_instance_valid(a) else "释放", int(a.hp) if is_instance_valid(a) else -1,
		("，掉血 %d" % (hp_a0 - int(a.hp))) if is_instance_valid(a) and int(a.hp) < hp_a0 else "（没掉血 = 没被反击）",
		str(t.cell) if is_instance_valid(t) else "释放", int(t.hp) if is_instance_valid(t) else -1,
		("，掉血 %d" % (hp_t0 - int(t.hp))) if is_instance_valid(t) and int(t.hp) < hp_t0 else "（没掉血）",
		d1])
	# 清场，进下一个局面
	for u in battle.units.duplicate():
		if u == a or u == t:
			battle.units.erase(u)
			if is_instance_valid(u):
				u.queue_free()
	for i in 3:
		await get_tree().process_frame

func _atk_type(u: Unit) -> String:
	return "远程" if u.attack_type == DataRegistry.AttackType.RANGED else "近战"

func _type_txt() -> String:
	var bits: Array[String] = []
	for id in ["hero_32", "hero_10", "hero_18", "hero_09"]:
		var d = DataRegistry.get_hero(id)
		if d == null:
			continue
		bits.append("%s=%s(攻%d 射程%d)" % [id, str(d.display_name), int(d.atk), int(d.attack_range)])
	return "／".join(bits)

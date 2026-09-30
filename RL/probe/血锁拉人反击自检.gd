extends Node
## 【2026-09-30 一次性探针】血锁拉人 × 反击 —— 用户报「血锁把目标拉过来，目标不反击」。
## 机制（读代码）：`hero_41::on_attack` → `Battle._pull_to()` 把目标拉到**血锁面前一格**，
##   这是 `_trigger_on_attack()` 里发生的，**排在反击判定之前**。拉完距离 = **1（贴身）**
##   ⇒ 按规则「距离=1 ⇒ 攻击者在自己射程内即可反击」，**目标应该反击**。
## 四个局面（血锁在 (2,5)、目标在正上方 (2,3)=距离2 / (2,2)=距离3）：
##   ① 远程目标（白游侠）· 距离2  → 应被拉成贴身并反击
##   ② 近战目标（长剑）  · 距离2  → 同上
##   ③ 远程目标 · **目标身后/两侧被堵**（拉不动）→ 距离不变，看还反不反击
##   ④ 对照：目标本来就在贴身位（距离1）→ 不拉，照常反击
## 输出：每行 `LX|...`，末尾 `LX|END`。

var battle: Battle

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	await _case("hero_10", 2, false, "①远程目标·距离2·拉得动")
	await _case("hero_18", 2, false, "②近战目标·距离2·拉得动")
	await _case("hero_10", 3, false, "③远程目标·距离3·拉得动")
	await _case("hero_10", 1, false, "④对照·远程目标本来就贴身")
	print("LX|END")
	get_tree().quit(0)

func _case(tgt_id: String, dist: int, blocked: bool, tag: String) -> void:
	if battle != null and is_instance_valid(battle):
		battle.queue_free()
		for i in 4:
			await get_tree().process_frame
	battle = (load("res://scenes/Main.tscn") as PackedScene).instantiate() as Battle
	add_child(battle)
	for i in 3:
		await get_tree().process_frame
	battle.player_roster = []
	battle.enemy_roster = []
	# 血锁固定在 (2,5)，目标在它正上方 dist 格处（同一列 ⇒ 直线，血锁只能直线攻击）
	var w = battle._spawn_unit("hero_41", DataRegistry.Faction.ENEMY, Vector2i(2, 5))
	var t = battle._spawn_unit(tgt_id, DataRegistry.Faction.PLAYER, Vector2i(2, 5 - dist))
	if blocked:
		# 把血锁面前那一格堵上（拉不过来的情况）
		battle._spawn_unit("hero_11", DataRegistry.Faction.PLAYER, Vector2i(2, 4))
	for i in 2:
		await get_tree().process_frame
	var w_hp0 := int(w.hp)
	var t_hp0 := int(t.hp)
	var d0: int = battle.grid.distance(w.cell, t.cell)
	print("LX|%s|开打前：%s(攻%d 射程%d)@%s vs %s(攻%d 血%d)@%s｜距离=%d" % [
		tag, str(w.display_name), int(w.effective_atk()), int(w.attack_range), str(w.cell),
		str(t.display_name), int(t.effective_atk()), int(t.hp), str(t.cell), d0])
	var samples: Array[String] = []
	var last := ""
	battle._do_attack(w, t, true)
	for f in 240:
		await get_tree().process_frame
		var key := "%s|%s|%d|%d" % [
			str(w.cell) if is_instance_valid(w) else "释放",
			str(t.cell) if is_instance_valid(t) else "释放",
			int(w.hp) if is_instance_valid(w) else -1,
			int(t.hp) if is_instance_valid(t) else -1]
		if key != last:
			samples.append("帧%-3d 血锁@%s 血%s ｜目标@%s 血%s（距%d）" % [
				f,
				str(w.cell) if is_instance_valid(w) else "释放",
				str(int(w.hp)) if is_instance_valid(w) else "-",
				str(t.cell) if is_instance_valid(t) else "释放",
				str(int(t.hp)) if is_instance_valid(t) else "-",
				battle.grid.distance(w.cell, t.cell) if (is_instance_valid(w) and is_instance_valid(t)) else -1])
			last = key
	for s in samples:
		print("LX|%s|变化|%s" % [tag, s])
	print("LX|%s|结果|血锁掉 %d（>0 = 挨了反击）｜目标掉 %d｜最终距离 %d" % [
		tag,
		w_hp0 - (int(w.hp) if is_instance_valid(w) else 0),
		t_hp0 - (int(t.hp) if is_instance_valid(t) else 0),
		battle.grid.distance(w.cell, t.cell) if (is_instance_valid(w) and is_instance_valid(t)) else -1])

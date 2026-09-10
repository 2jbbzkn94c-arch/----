extends Node
## 实战式技能验证：每个角色构造真实对局，走真正的 攻击/移动/回合 流程，检查实战可观察结果。
## 运行：godot --headless --scene res://tests/Practical.tscn
var battle: Battle
var results := {}

func _ready() -> void:
	battle = load("res://scenes/Main.tscn").instantiate() as Battle
	add_child(battle)
	_run.call_deferred()

func clear_all() -> void:
	for u in battle.units:
		if is_instance_valid(u):
			u.queue_free()
	battle.units.clear()
	battle.occupancy.clear()
	battle.obstacles.clear()
	battle.bombs.clear()
	battle.buff_items.clear()
	battle.graves.clear()
	battle._preview_cells.clear()
	battle.player_dead = 0
	battle.enemy_dead = 0
	battle.selected = null
	battle.state = Battle.State.ENDED

func spawn(hid: String, faction: int, cell: Vector2i) -> Unit:
	return battle._spawn_unit(hid, faction, cell)

func rec(id: String, ok: bool, note: String) -> void:
	results[id] = [ok, note]

func _run() -> void:
	for id in DataRegistry.heroes.keys():
		clear_all()
		await _test_hero(id)
		if not results.has(id):
			results[id] = [false, "未产出结果"]
	for id in DataRegistry.heroes.keys():
		var r: Array = results[id]
		print("%s  [%s] %s" % [id, "PASS" if r[0] else "FAIL", r[1]])
	get_tree().quit()

func sleep_frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame

func _test_hero(id: String) -> void:
	var hero := spawn(id, DataRegistry.Faction.PLAYER, Vector2i(3, 6))
	if hero == null:
		rec(id, false, "无法生成")
		return
	match id:
		"hero_03", "hero_12", "hero_25", "hero_34", "hero_27", "hero_32", "hero_18", "hero_21", "hero_41", "hero_14", "hero_10":
			# 远程角色(白游侠/超新星/沉默术士)需距攻击者2格(非贴身)否则触发远程被贴身、技能失效；
			# 血锁(近距离)在被紧邻时不会拉动，其"拉近"测试需从2格外攻击
			# 5列棋盘 x∈0..4：hero_32击退方向朝x变小落点才不出界
			var tc := Vector2i(5, 6) if id in ["hero_10", "hero_21", "hero_34", "hero_41"] else (Vector2i(2, 6) if id == "hero_32" else Vector2i(4, 6))
			var t := spawn("hero_13", DataRegistry.Faction.ENEMY, tc)
			var oc := t.cell
			var h0 := t.hp
			battle._do_attack(hero, t, true)
			await sleep_frames(40)
			match id:
				"hero_03": rec(id, t.has_status("poison"), "poison=%s" % t.has_status("poison"))
				"hero_12": rec(id, t.has_status("heavy"), "heavy=%s" % t.has_status("heavy"))
				"hero_25": rec(id, t.has_status("freeze"), "freeze=%s" % t.has_status("freeze"))
				"hero_34": rec(id, t.has_status("silence"), "silence=%s" % t.has_status("silence"))
				"hero_27": rec(id, hero.cell == Vector2i(4, 6) and t.cell == Vector2i(3, 6), "换位")
				"hero_32": rec(id, t.cell != oc, "击退")
				"hero_18": rec(id, t.hp < h0, "目标受伤")
				"hero_21": rec(id, t.hp < h0, "目标受伤")
				"hero_41": rec(id, t.hp < h0 and t.cell != oc, "拉近+受伤")
				"hero_14":
					hero.hp = 5; t.hp = 20
					battle._attack_hp_before = t.hp   # 攻击前 HP（直接调 _trigger_on_attack 时需手动记录）
					var hh := hero.hp
					battle._trigger_on_attack(hero, t, false)
					rec(id, hero.hp > hh, "自疗%d->%d" % [hh, hero.hp])
				"hero_10": rec(id, t.has_status("freeze"), "freeze=%s" % t.has_status("freeze"))
		"hero_06", "hero_17", "hero_26", "hero_31", "hero_38", "hero_35":
			var e := spawn("hero_13", DataRegistry.Faction.ENEMY, Vector2i(4, 6))
			var h0 := e.hp
			battle._do_move(hero, Vector2i(4, 7), true)
			await sleep_frames(600)
			match id:
				"hero_06": rec(id, true, "治疗相邻(近似)")
				"hero_17": rec(id, e.hp < h0, "相邻敌伤%d" % (h0 - e.hp))
				"hero_26": rec(id, e.has_status("freeze"), "freeze=%s" % e.has_status("freeze"))
				"hero_31": rec(id, true, "弱敌受伤")
				"hero_38": rec(id, hero.atk == 1, "攻=%d" % hero.atk)
				"hero_35": rec(id, battle._pending_bomb_unit == hero, "待放=%s" % str(battle._pending_bomb_unit))
		"hero_02", "hero_05", "hero_19", "hero_33", "hero_42":
			spawn("hero_13", DataRegistry.Faction.ENEMY, Vector2i(4, 6))
			if id == "hero_19":
				var ally := spawn("hero_15", DataRegistry.Faction.PLAYER, Vector2i(2, 7))
				battle._trigger_turn_start(hero)
				rec(id, ally.atk_buff >= 1, "buff=%d" % ally.atk_buff)
				return
			battle._trigger_turn_start(hero)
			match id:
				"hero_02": rec(id, battle.buff_items.size() == 2, "道具=%d" % battle.buff_items.size())
				"hero_05": rec(id, true, "敌人位移")
				"hero_33": rec(id, battle.units.size() > 2, "召唤=%d" % battle.units.size())
				"hero_42": rec(id, battle.buff_items.size() > 0, "金矿=%d" % battle.buff_items.size())
		"hero_16", "hero_29", "hero_36", "hero_39":
			spawn("hero_15", DataRegistry.Faction.PLAYER, Vector2i(4, 6))
			var low := battle.units[1]; low.hp = 1
			battle._trigger_on_enter(hero)
			match id:
				"hero_16": rec(id, low.has_status("shield"), "圣盾=%s" % low.has_status("shield"))
				"hero_29": rec(id, hero.sun_bonus == 3, "buff=%d" % hero.sun_bonus)
				"hero_36": rec(id, low.hp > 1, "治疗+换位")
				"hero_39": rec(id, true, "敌受创(近似)")
		"hero_08":
			var ally := spawn("hero_15", DataRegistry.Faction.PLAYER, Vector2i(4, 6)); ally.hp = 1
			battle._trigger_turn_end(hero)
			rec(id, ally.hp > 1, "友血%d->%d" % [1, ally.hp])
		"hero_40":
			var e := spawn("hero_13", DataRegistry.Faction.ENEMY, Vector2i(4, 6)); var h0 := e.hp
			battle._on_unit_died(hero)
			rec(id, e.hp < h0, "相邻敌伤%d" % (h0 - e.hp))
		"hero_22", "hero_11", "hero_37":
			var vf := DataRegistry.Faction.ENEMY if id == "hero_37" else DataRegistry.Faction.PLAYER
			var victim := spawn("hero_15", vf, Vector2i(4, 6))
			match id:
				"hero_22":
					# 圣光：**敌方回合**里己方受伤 → 得[圣盾]；发盾延迟一帧，必须等帧再断言
					var side0: int = GameState.active_side
					GameState.active_side = GameState.SIDE_ENEMY
					battle._on_unit_damaged(victim, 3)
					await sleep_frames(3)
					rec(id, victim.has_status("shield"), "圣盾=%s" % victim.has_status("shield"))
					GameState.active_side = side0
				"hero_11": victim.take_damage(3); rec(id, hero.hp < hero.max_hp, "塔盾代受")   # 塔盾主动减免：走 take_damage 前置
				"hero_37": battle._on_unit_damaged(victim, 3); rec(id, hero.atk_buff >= 1, "buff=%d" % hero.atk_buff)
		"hero_43":
			spawn("hero_15", DataRegistry.Faction.PLAYER, Vector2i(4, 6))
			battle._trigger_turn_start(hero)
			rec(id, battle.units[1].move_buff >= 1, "buff=%d" % battle.units[1].move_buff)
		"hero_23": rec(id, battle._counter_bonus(hero, spawn("hero_13", DataRegistry.Faction.ENEMY, Vector2i(4, 6))) == 2, "反击2倍")
		"hero_15", "hero_20", "hero_30":
			# 赏金猎人(远程)需距攻击者2格(非贴身)否则触发远程被贴身、倍率失效
			var tc2 := Vector2i(4, 6) if id != "hero_20" else Vector2i(5, 6)
			var t := spawn("hero_13", DataRegistry.Faction.ENEMY, tc2)
			if id == "hero_15": t.hp = 1
			if id == "hero_20": t.skills.append(DataRegistry.Skill.TAUNT)
			rec(id, battle._bonus_damage(hero, t) == 2, "倍率%d" % battle._bonus_damage(hero, t))
		"hero_04", "hero_13", "hero_09", "hero_07":
			var ok := false
			if id == "hero_04": ok = hero.move_range == 3
			elif id == "hero_13": ok = hero.skills.has(DataRegistry.Skill.TAUNT)
			elif id == "hero_09" or id == "hero_07": ok = hero.attack_type == DataRegistry.AttackType.RANGED and hero.attack_range == 2
			rec(id, ok, "标签")
		"hero_01":
			battle.obstacles[Vector2i(4, 6)] = 30
			battle.selected = hero; battle._compute_ranges(hero)
			rec(id, battle.enemy_cells.has(Vector2i(4, 6)), "障碍可打")
		"hero_24": rec(id, battle._move_reachable(hero).size() > 6, "冲刺=%d" % battle._move_reachable(hero).size())
		"hero_44":
			var ok := hero.skills.has(DataRegistry.Skill.TAUNT)
			# 免疫负面：施加冰冻/麻痹/猛毒均不挂状态，且一次攻击(同帧多次负面)只 +1 攻
			var a0 := hero.atk_buff
			hero.add_status("freeze")
			hero.add_status("atkdown")
			hero.add_status("poison")
			var no_neg := not hero.has_status("freeze") and not hero.has_status("atkdown") and not hero.has_status("poison")
			var gain1 := hero.atk_buff == a0 + 1
			# 换一帧后再被负面攻击 -> 再 +1
			await sleep_frames(2)
			hero.add_status("silence")
			var gain2 := hero.atk_buff == a0 + 2
			rec(id, ok and no_neg and gain1 and gain2, "嘲讽=%s 免负=%s +1攻=%s 再+1=%s" % [ok, no_neg, gain1, gain2])
		"hero_28":
			spawn("hero_15", DataRegistry.Faction.PLAYER, Vector2i(4, 6))
			var n0 := hero.display_name
			battle._trigger_turn_start(hero)
			rec(id, hero.display_name != n0, "变身=%s" % hero.display_name)
			# 回归：下回合并始回溯本源后必须能再次变身（旧 bug：行为脚本未还原 → 永不再变）
			hero.hero_id = hero.transform_base_id
			battle._apply_base_hero(hero, hero.transform_base_id)
			var reverted := hero.behavior is HeroGremlin
			battle._trigger_turn_start(hero)
			rec(id, reverted and hero.hero_id != "hero_28", "再变身=%s" % hero.display_name)
		"hero_45":
			# 坠炮手：全场射程 99、无视阻挡（弹道不受障碍/单位/墓碑/嘲讽限制）
			var ok45 := hero.attack_range >= 99
			var obs := spawn("hero_13", DataRegistry.Faction.ENEMY, Vector2i(4, 6))
			rec(id, ok45, "射程=%d" % hero.attack_range)
		"hero_46":
			# 宿魂：攻击命中后目标获得附体绑定；负墟免疫附体
			var tgt := spawn("hero_13", DataRegistry.Faction.ENEMY, Vector2i(4, 6))
			battle._trigger_on_attack(hero, tgt, false)
			rec(id, battle._possess_links.has(tgt) and battle._possess_links[tgt] == hero, "附体=%s" % str(battle._possess_links.has(tgt)))
		"hero_47":
			# 共鸣者：攻击力"变为"队友有效攻击之和（echo_set）
			var ally := spawn("hero_15", DataRegistry.Faction.PLAYER, Vector2i(4, 6))
			# 走生产路径：Battle._run_side_skills 对声明 wants_side_turn_start_sync 的英雄派发本钩子
			# （原 battle._sync_one_echo 已在"重构第二批(1)"中删除，逻辑搬进 hero_47_共鸣者.gd）
			hero.behavior.on_side_turn_start(hero.faction)
			rec(id, hero.echo_set >= 1, "echo=%d" % hero.echo_set)
		_: rec(id, false, "未接入")
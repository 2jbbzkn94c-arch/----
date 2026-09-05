extends Node
## AI 战术冒烟测试：构造小对局，直接调用 BattleAI，验证评估函数驱动的行为方向。
## 运行：godot --headless --scene res://tests/AISmokeTest.tscn
var battle: Battle

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
	battle.bombs.clear()
	battle.buff_items.clear()
	battle.obstacles.clear()
	battle.graves.clear()
	battle.state = Battle.State.ENDED

func spawn(hid: String, f: int, c: Vector2i) -> Unit:
	return battle._spawn_unit(hid, f, c)

func build_desc(u: Unit) -> Dictionary:
	return {
		"fn": u.faction, "hero": u.hero_id, "cell": u.cell, "hp": u.hp, "max_hp": u.max_hp,
		"atk": u.atk, "eatk": u.effective_atk(), "move": u.move_range, "emove": u.effective_move(),
		"atk_range": u.attack_range, "atk_type": u.attack_type, "skills": u.skills, "name": u.display_name,
		"stunned": u.has_status("stun"), "silenced": u.has_status("silence"),
		"shield": u.has_status("shield"), "heavy": u.has_status("heavy"),
		"poisoned": u.has_status("poison"), "frozen": u.has_status("freeze"),
	}

func run_ai(label: String) -> Array:
	var descs: Array = []
	var occ := {}
	for i in battle.units.size():
		descs.append(build_desc(battle.units[i]))
		occ[battle.units[i].cell] = i
	var ai := BattleAI.new(battle.grid)
	ai.difficulty = 2
	var sim := ai.build_state(descs, occ)
	var plan: Array = ai.search(sim, DataRegistry.Faction.ENEMY)
	print("AI[%s] plan=%s" % [label, str(plan)])
	return plan

func _run() -> void:
	# 场景1：敌方刺客紧邻玩家 1HP 目标 -> 应选择攻击（击杀）
	clear_all()
	var u := spawn("hero_04", DataRegistry.Faction.ENEMY, Vector2i(3, 8))
	var v := spawn("hero_13", DataRegistry.Faction.PLAYER, Vector2i(4, 8))
	v.hp = 1
	var p1 := run_ai("相邻1HP")
	var killed := p1.size() > 0
	var a1 = p1[0]["action"]
	killed = a1.has("atk") and int(a1["atk"]) >= 0
	print("T1 击杀优先: %s" % ["PASS" if killed else "FAIL"])

	# 场景2：敌方远程紧邻玩家高攻单位 -> 远程被贴身时应后退/不打（评估应避免被贴脸）
	clear_all()
	var r := spawn("hero_09", DataRegistry.Faction.ENEMY, Vector2i(3, 8))
	var s := spawn("hero_23", DataRegistry.Faction.PLAYER, Vector2i(4, 8))
	s.hp = 30
	var p2 := run_ai("远程被贴脸")
	print("T2 远程被贴脸 plan=%s" % str(p2))

	# 场景3：玩家单位残血+两个敌方单位都能打到 -> 集火同一个
	clear_all()
	var a := spawn("hero_04", DataRegistry.Faction.ENEMY, Vector2i(2, 8))
	var b := spawn("hero_04", DataRegistry.Faction.ENEMY, Vector2i(4, 8))
	var t := spawn("hero_13", DataRegistry.Faction.PLAYER, Vector2i(3, 8))
	t.hp = 5
	var p3 := run_ai("两敌集火")
	var atk_targets := 0
	for step in p3:
		if step["action"].has("atk") and int(step["action"]["atk"]) >= 0:
			atk_targets += 1
	print("T3 集火目标次数: %d -> %s" % [atk_targets, "PASS" if atk_targets >= 1 else "FAIL"])

	# 场景4：远程贴身攻击 -> 突进演出 + 被反击（走真实 _do_attack）
	clear_all()
	var rng := spawn("hero_09", DataRegistry.Faction.PLAYER, Vector2i(3, 8))
	var tank := spawn("hero_13", DataRegistry.Faction.ENEMY, Vector2i(4, 8))
	var h0 := rng.hp
	battle._do_attack(rng, tank, false)
	for i in 80:
		await get_tree().process_frame
	print("T4 远程贴身被反击: 攻方 %d -> %d => %s" % [h0, rng.hp, "PASS" if rng.hp < h0 else "FAIL"])

	# 场景5：远程远距离攻击（距离2）不应被反击
	clear_all()
	var rng2 := spawn("hero_09", DataRegistry.Faction.PLAYER, Vector2i(3, 8))
	var far := spawn("hero_13", DataRegistry.Faction.ENEMY, Vector2i(5, 8))
	var h1 := rng2.hp
	battle._do_attack(rng2, far, false)
	for i in 80:
		await get_tree().process_frame
	print("T5 远程远距不被反击: 攻方 %d -> %d => %s" % [h1, rng2.hp, "PASS" if rng2.hp == h1 else "FAIL"])

	# 场景6：远程贴身 -> 面板攻击力 = 1（无buff）；远距离 = 原始攻击
	clear_all()
	var rng3 := spawn("hero_09", DataRegistry.Faction.PLAYER, Vector2i(3, 8))   # 火枪手 atk=4 远程
	var far3 := spawn("hero_13", DataRegistry.Faction.ENEMY, Vector2i(5, 8))
	battle._sync_ranged_adjacent()
	var far_atk := rng3.effective_atk()
	var far3c := far3.cell
	far3.cell = Vector2i(4, 8)
	battle.occupancy.erase(far3c)
	battle.occupancy[Vector2i(4, 8)] = far3
	battle._sync_ranged_adjacent()
	var adj_atk := rng3.effective_atk()
	print("T6 远程贴面板: 远=%d 贴=%d => %s" % [far_atk, adj_atk, "PASS" if far_atk == 4 and adj_atk == 1 else "FAIL"])

	# 场景7：远程贴身 + 攻击buff（+2）-> 面板 = 1 + 2 = 3（buff 保留）
	rng3.atk_buff = 2
	battle._sync_ranged_adjacent()
	var buff_adj_atk := rng3.effective_atk()
	print("T7 远程贴身+buff: 攻=%d => %s" % [buff_adj_atk, "PASS" if buff_adj_atk == 3 else "FAIL"])

	# 场景8：古灵精怪变身 -> 应触发新英雄的回合开始技能（黄金矿工丢矿）
	clear_all()
	var grem := spawn("hero_28", DataRegistry.Faction.PLAYER, Vector2i(3, 8))
	spawn("hero_42", DataRegistry.Faction.PLAYER, Vector2i(4, 8))   # 候选：黄金矿工
	battle._trigger_turn_start(grem)
	var is_gold := grem.hero_id == "hero_42"
	var gold_placed := false
	for c in battle.buff_items.keys():
		if battle.buff_items[c] == "gold":
			gold_placed = true
	print("T8 变身触发回合开始技能: 变身=%s 丢矿=%s => %s" % [is_gold, gold_placed, "PASS" if gold_placed else "FAIL"])

	# 场景9：圣诞老人替补登场 -> 立即放道具（回合开始类技能登场生效）
	clear_all()
	spawn("hero_02", DataRegistry.Faction.PLAYER, Vector2i(3, 8))
	battle.buff_items.clear()
	battle._trigger_on_enter(battle.units[-1])   # 模拟替补登场
	var placed := battle.buff_items.size()
	print("T9 圣诞(替补登场)立即放道具: 道具=%d => %s" % [placed, "PASS" if placed >= 2 else "FAIL"])

	# 场景10：血锁（branch_override）只能打直线；近距直线目标可选、非直线目标不可选
	clear_all()
	var blood := spawn("hero_41", DataRegistry.Faction.PLAYER, Vector2i(3, 8))
	# 直线上的敌人（同轴向）
	var line_target := spawn("hero_13", DataRegistry.Faction.ENEMY, Vector2i(3, 5))
	# 非直线敌人（斜向偏离）
	var off_target := spawn("hero_13", DataRegistry.Faction.ENEMY, Vector2i(5, 8))
	var vt := battle._valid_targets(blood)
	print("T10 血锁直线限制: 直线=%s 非直线=%s => %s" % [vt.has(line_target), vt.has(off_target), "PASS" if vt.has(line_target) and not vt.has(off_target) else "FAIL"])

	# 场景11：血锁直线攻击，但直线中途有障碍物 -> 打不到；无遮挡 -> 可打
	clear_all()
	var blood2 := spawn("hero_41", DataRegistry.Faction.PLAYER, Vector2i(3, 8))
	var open_target := spawn("hero_13", DataRegistry.Faction.ENEMY, Vector2i(3, 5))
	# 直线中途 (3,7) 放障碍
	battle.obstacles[Vector2i(3, 7)] = 30
	var vt_blocked := battle._valid_targets(blood2)
	battle.obstacles.erase(Vector2i(3, 7))
	var vt_clear := battle._valid_targets(blood2)
	print("T11 血锁视线阻挡: 隔墙=%s 无墙=%s => %s" % [vt_blocked.has(open_target), vt_clear.has(open_target), "PASS" if not vt_blocked.has(open_target) and vt_clear.has(open_target) else "FAIL"])

	# 场景12：战锤贴身攻击远程目标 -> 目标攻降为0，反击应为0伤害
	clear_all()
	var hammer := spawn("hero_25", DataRegistry.Faction.PLAYER, Vector2i(3, 8))   # 战锤：近战
	var rng_t := spawn("hero_09", DataRegistry.Faction.ENEMY, Vector2i(4, 8))   # 火枪手：远程 atk=4
	var hammer_hp0 := hammer.hp
	battle._do_attack(hammer, rng_t, false)
	for i in 90:
		await get_tree().process_frame
	print("T12 战锤麻痹0反击0伤: 战锤 %d->%d 目标atkdown=%s => %s" % [hammer_hp0, hammer.hp, rng_t.has_status("atkdown"), "PASS" if hammer.hp == hammer_hp0 else "FAIL"])

	# 场景13：只有黄金矿工能捡金矿；其他单位踩金矿不消费、金矿保留
	clear_all()
	var miner := spawn("hero_42", DataRegistry.Faction.PLAYER, Vector2i(3, 8))   # 黄金矿工
	var walker := spawn("hero_04", DataRegistry.Faction.PLAYER, Vector2i(4, 8))   # 鼠队长（非矿工）
	battle.buff_items[Vector2i(4, 8)] = "gold"   # 金矿放在 walker 脚下
	var walker_atk := walker.atk
	# walker 已是矿工格上，直接触发 _finish_move 提取逻辑？改为走一步到金矿格
	battle.buff_items.erase(Vector2i(4, 8))
	battle.buff_items[Vector2i(5, 8)] = "gold"
	# 让 walker 移动到金矿格
	walker.cell = Vector2i(5, 8)
	battle.occupancy[Vector2i(5, 8)] = walker
	battle._finish_move(walker, false)
	var walker_got := walker.atk != walker_atk
	var gold_still := battle.buff_items.has(Vector2i(5, 8))
	print("T13 非矿工不捡金矿: 升攻=%s 金矿保留=%s => %s" % [walker_got, gold_still, "PASS" if not walker_got and gold_still else "FAIL"])

	# 场景14：黄金矿工踩金矿 -> 拾取（攻+1、血上限+3、金矿消失）
	walker.cell = Vector2i(3, 8)   # 挪开 walker，腾出逻辑
	battle.occupancy.erase(Vector2i(5, 8))
	battle.occupancy[Vector2i(4, 8)] = walker   # walker 移回旁边
	miner.cell = Vector2i(5, 8)
	battle.occupancy.erase(Vector2i(3, 8))
	battle.occupancy[Vector2i(5, 8)] = miner
	var miner_atk := miner.atk
	battle._finish_move(miner, false)
	print("T14 矿工捡金矿: 升攻=%s 金矿消失=%s => %s" % [miner.atk > miner_atk, not battle.buff_items.has(Vector2i(5, 8)), "PASS" if miner.atk > miner_atk and not battle.buff_items.has(Vector2i(5, 8)) else "FAIL"])

	# 场景15：古灵精怪变身成替补英雄（波盾）-> 不应触发替补登场效果（队友不获得圣盾）
	clear_all()
	var grem2 := spawn("hero_28", DataRegistry.Faction.PLAYER, Vector2i(3, 8))
	var fellow := spawn("hero_02", DataRegistry.Faction.PLAYER, Vector2i(4, 8))   # 队友（非波盾，无圣盾）
	battle.player_roster = ["hero_16"]   # 让候选含波盾（替补池）
	battle._transform(grem2, "hero_16")   # 强制变身为波盾
	var shield_got := fellow.has_status("shield")
	print("T15 变身替补英雄不触发替补效果: 变身=%s 队友圣盾=%s => %s" % [grem2.hero_id == "hero_16", shield_got, "PASS" if not shield_got else "FAIL"])

	# 场景16：古灵精怪拾取永久攻击加成（pick 2次）后变身 -> 攻击力保留，不重置回3
	clear_all()
	var grem3 := spawn("hero_28", DataRegistry.Faction.PLAYER, Vector2i(3, 8))
	spawn("hero_42", DataRegistry.Faction.PLAYER, Vector2i(4, 8))   # 候选含黄金矿工
	grem3.perm_atk = 2   # 模拟捡了2次攻击buff/金矿
	grem3.atk += 2
	battle._transform(grem3, "hero_42")
	print("T16 变身保留永久攻加成: 变身=%s 攻=%d => %s" % [grem3.hero_id == "hero_42", grem3.atk, "PASS" if grem3.atk == 5 else "FAIL"])

	# 场景17：骷髅兵（消耗品）紧邻玩家单位时，AI 应选择攻击而非逃跑
	clear_all()
	# 手动创建骷髅兵（数据在 summons 而非 heroes），并让玩家紧邻
	var sdef := DataRegistry.get_summon("summon_skeleton")
	var skel := Unit.new(sdef, DataRegistry.Faction.ENEMY, Vector2i(3, 8), 48.0 * 0.82)
	battle.units.append(skel)
	battle.occupancy[Vector2i(3, 8)] = skel
	spawn("hero_13", DataRegistry.Faction.PLAYER, Vector2i(4, 8))   # 玩家紧邻骷髅兵
	var plan_s := run_ai("骷髅兵贴脸")
	var will_atk := false
	if plan_s.size() > 0:
		will_atk = plan_s[0]["action"].has("atk") and int(plan_s[0]["action"]["atk"]) >= 0
	print("T17 骷髅兵贴脸咬人: plan=%s 攻击=%s => %s" % [str(plan_s), will_atk, "PASS" if will_atk else "FAIL"])

	# 场景18：圣诞老人攻击buff为一次性——攻击后消失，下一次攻击不再+1
	clear_all()
	var att := spawn("hero_04", DataRegistry.Faction.PLAYER, Vector2i(3, 8))
	var dummy := spawn("hero_13", DataRegistry.Faction.ENEMY, Vector2i(4, 8))
	att.atk_use_buff = 1   # 模拟拾取攻击buff
	var first_atk := att.effective_atk()
	att.attacked_this_turn = true
	battle._finish_attack(att, false)   # 攻击结算
	var second_atk := att.effective_atk()
	print("T18 攻击buff一次性: 攻击时=%d 攻击后=%d => %s" % [first_atk, second_atk, "PASS" if first_atk > second_atk and att.atk_use_buff == 0 else "FAIL"])

	# 场景19：圣诞老人移动buff为一次性——移动后消失
	clear_all()
	var mvr := spawn("hero_04", DataRegistry.Faction.PLAYER, Vector2i(3, 8))
	mvr.move_use_buff = 1
	var mv0 := mvr.effective_move()
	battle._finish_move(mvr, false)   # 移动结算（原地）
	var mv1 := mvr.effective_move()
	print("T19 移动buff一次性: 移动时=%d 移动后=%d => %s" % [mv0, mv1, "PASS" if mv0 > mv1 and mvr.move_use_buff == 0 else "FAIL"])

	# 场景20：敌方能打到玩家残血 -> 应选择攻击（而非逃跑）
	clear_all()
	var attacker := spawn("hero_04", DataRegistry.Faction.ENEMY, Vector2i(3, 8))   # 近战 攻4
	var weak := spawn("hero_13", DataRegistry.Faction.PLAYER, Vector2i(4, 8))
	weak.hp = 1
	var plan20 := run_ai("能攻残血")
	var will_atk20 := false
	if plan20.size() > 0:
		will_atk20 = plan20[0]["action"].has("atk") and int(plan20[0]["action"]["atk"]) >= 0
	print("T20 能攻残血就打: plan=%s 攻击=%s => %s" % [str(plan20), will_atk20, "PASS" if will_atk20 else "FAIL"])

	# 场景21：大骑士应冲锋（移动几步）再攻击，利用冲锋加攻
	clear_all()
	var bigknight := spawn("hero_24", DataRegistry.Faction.ENEMY, Vector2i(3, 8))   # 大骑士
	var far_target := spawn("hero_13", DataRegistry.Faction.PLAYER, Vector2i(3, 4))   # 玩家在远处直线上
	var plan21 := run_ai("大骑士冲锋")
	var moved21 := false
	var atk21 := false
	if plan21.size() > 0:
		var act = plan21[0]["action"]
		moved21 = act.has("move") and act["move"] != null and act["move"] != Vector2i(3, 8)
		atk21 = act.has("atk") and int(act["atk"]) >= 0
	print("T21 大骑士冲锋攻击: plan=%s 移动=%s 攻击=%s => %s" % [str(plan21), moved21, atk21, "PASS" if moved21 and atk21 else "FAIL"])

	# 场景22：下方队伍只显示替补席（不含已上阵单位、不含已死英雄）
	clear_all()
	spawn("hero_03", DataRegistry.Faction.PLAYER, Vector2i(3, 8))   # 已上阵
	spawn("hero_04", DataRegistry.Faction.PLAYER, Vector2i(4, 8))   # 已上阵
	battle.player_roster = ["hero_42", "hero_43"]
	var team_ids := battle._player_team_ids()
	print("T22 队伍仅替补席: team=%s => %s" % [str(team_ids), "PASS" if team_ids.size() == 2 and team_ids.has("hero_42") and team_ids.has("hero_43") and not team_ids.has("hero_03") and not team_ids.has("hero_04") else "FAIL"])

	# 场景23：敌方落位分散——连续取3个出生格，列应错开而非连续从左到右
	clear_all()
	var cols: Array = []
	for i in 3:
		var c := battle._free_spawn_cell(DataRegistry.Faction.ENEMY)
		cols.append(c.x)
		# 模拟占位：在此格放一个敌方单位，供下一步分散计算
		var d := DataRegistry.get_summon("summon_skeleton")
		if d != null:
			var sk := Unit.new(d, DataRegistry.Faction.ENEMY, c, 48.0 * 0.82)
			battle.units.append(sk)
			battle.occupancy[c] = sk
	print("T23 敌方落位分散: cols=%s => %s" % [str(cols), "PASS" if cols[0] != cols[1] and cols[1] != cols[2] else "FAIL"])

	# 场景24：走到移动buff格捡到后，buff 保留到下一次移动（不被本次移动消耗）
	clear_all()
	var walker2 := spawn("hero_04", DataRegistry.Faction.PLAYER, Vector2i(3, 8))
	spawn("hero_02", DataRegistry.Faction.PLAYER, Vector2i(4, 8))   # 圣诞老人伙伴（占位）
	battle.buff_items[Vector2i(5, 8)] = "move"
	# 把单位放到 buff 格并结算本次移动（捡 buff）
	walker2.cell = Vector2i(5, 8)
	battle.occupancy.erase(Vector2i(3, 8))
	battle.occupancy[Vector2i(5, 8)] = walker2
	battle._finish_move(walker2, false)
	var got_buff := walker2.move_use_buff   # 捡到后应余 1
	var mv := walker2.effective_move()      # 包含 buff，应比基础移动力+1
	print("T24 捡移动buff保留: move_use_buff=%d eff_move=%d => %s" % [got_buff, mv, "PASS" if got_buff >= 1 else "FAIL"])

	get_tree().quit()

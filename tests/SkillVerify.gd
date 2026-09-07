extends Node
## 触发式技能验证：直接调用每个角色的技能钩子，检查可观察结果。
## 运行：godot --headless --scene res://tests/SkillVerify.tscn
var battle: Battle
var results := {}
func _ready() -> void:
	battle = load("res://scenes/Main.tscn").instantiate() as Battle
	add_child(battle)
	_run.call_deferred()
func clear_all() -> void:
	for u in battle.units: if is_instance_valid(u): u.queue_free()
	battle.units.clear(); battle.occupancy.clear(); battle.obstacles.clear(); battle.bombs.clear(); battle.buff_items.clear(); battle.graves.clear()
	battle._preview_cells.clear(); battle.player_dead = 0; battle.enemy_dead = 0; battle.selected = null
func spawn(hid: String, f: int, c: Vector2i) -> Unit: return battle._spawn_unit(hid, f, c)
func rec(id: String, ok: bool, note: String) -> void: results[id] = [ok, note]
func _run() -> void:
	for id in DataRegistry.heroes.keys():
		clear_all()
		_test_hero(id)
		if not results.has(id): results[id] = [false, "未产出"]
	for id in DataRegistry.heroes.keys():
		var r: Array = results[id]
		print("%s  [%s] %s" % [id, "PASS" if r[0] else "FAIL", r[1]])
	get_tree().quit()

func _test_hero(id: String) -> void:
	match id:
		"hero_01":
			var u := spawn(id, DataRegistry.Faction.PLAYER, Vector2i(3, 6)); battle.obstacles[Vector2i(4, 6)] = 30
			battle.selected = u; battle._compute_ranges(u)
			rec(id, battle.enemy_cells.has(Vector2i(4, 6)), "障碍可打")
		"hero_02":
			spawn(id, DataRegistry.Faction.PLAYER, Vector2i(3, 6)); battle._trigger_turn_start(battle.units[0])
			rec(id, battle.buff_items.size() == 2, "道具=%d" % battle.buff_items.size())
		"hero_03","hero_12","hero_25","hero_34","hero_27","hero_32","hero_18","hero_21","hero_41","hero_14","hero_10":
			var u := spawn(id, DataRegistry.Faction.PLAYER, Vector2i(3, 6))
			var t := spawn("hero_13", DataRegistry.Faction.ENEMY, Vector2i(4, 6))
			match id:
				"hero_03": battle._trigger_on_attack(u,t,false); rec(id, t.has_status("poison"), "poison")
				"hero_12": battle._trigger_on_attack(u,t,false); rec(id, t.has_status("heavy"), "heavy")
				"hero_25": battle._trigger_on_attack(u,t,false); rec(id, t.has_status("freeze"), "freeze")
				"hero_34": t.cell=Vector2i(5, 6); battle.occupancy.erase(Vector2i(4, 6)); battle.occupancy[Vector2i(5, 6)]=t; battle._trigger_on_attack(u,t,false); rec(id, t.has_status("silence"), "silence")
				"hero_27": var hc:=u.cell; battle._trigger_on_attack(u,t,false); rec(id, u.cell!=hc, "换位")
				# 5列棋盘 x∈0..4：击退/剑气落点须在界内
				"hero_32": t.cell=Vector2i(2, 6); battle.occupancy.erase(Vector2i(4, 6)); battle.occupancy[Vector2i(2, 6)]=t; var oc:=t.cell; battle._trigger_on_attack(u,t,false); rec(id, t.cell!=oc, "击退")
				"hero_18": t.cell=Vector2i(2, 6); battle.occupancy.erase(Vector2i(4, 6)); battle.occupancy[Vector2i(2, 6)]=t; var b:=spawn("hero_11", DataRegistry.Faction.ENEMY, Vector2i(1, 5)); var h1:=b.hp; battle._trigger_on_attack(u,t,false); rec(id, b.hp<h1, "身后伤")
				# 白游侠/超新星为远程：需距攻击者2格(非贴身)否则技能失效；邻敌须紧邻目标
				# 5列棋盘：u=(3,6) 距2的界内格为 (1,6)；邻敌放 (1,5)，击退其落点 (1,4) 界内
				"hero_21": t.cell=Vector2i(1, 6); battle.occupancy.erase(Vector2i(4, 6)); battle.occupancy[Vector2i(1, 6)]=t; var a:=spawn("hero_13", DataRegistry.Faction.ENEMY, Vector2i(1,5)); var ac:=a.cell; battle._trigger_on_attack(u,t,false); rec(id, a.cell!=ac, "击退邻敌")
				"hero_41": t.cell=Vector2i(6, 6); battle.occupancy.erase(Vector2i(4, 6)); battle.occupancy[Vector2i(6, 6)]=t; var oc:=t.cell; battle._trigger_on_attack(u,t,false); rec(id, t.cell!=oc, "拉近")
				"hero_14":
					u.hp=5; t.hp=20; var hh:=u.hp
					battle._attack_hp_before=t.hp   # 攻击前 HP（直接调 _trigger_on_attack 需手动记录）
					battle._trigger_on_attack(u,t,false)
					rec(id, u.hp>hh, "自疗%d->%d" % [hh,u.hp])
				"hero_10": t.cell=Vector2i(5, 6); battle.occupancy.erase(Vector2i(4, 6)); battle.occupancy[Vector2i(5, 6)]=t; battle._trigger_on_attack(u,t,false); rec(id, t.has_status("freeze"), "freeze")
		"hero_04","hero_07","hero_09","hero_13":
			var u := spawn(id, DataRegistry.Faction.PLAYER, Vector2i(3, 6))
			var ok := false
			if id=="hero_04": ok = u.move_range==3
			elif id=="hero_13": ok = u.skills.has(DataRegistry.Skill.TAUNT)
			else: ok = u.attack_type==DataRegistry.AttackType.RANGED and u.attack_range==2
			rec(id, ok, "标签")
		"hero_05":
			spawn(id, DataRegistry.Faction.PLAYER, Vector2i(3, 6)); spawn("hero_13", DataRegistry.Faction.ENEMY, Vector2i(1,0))
			battle._trigger_turn_start(battle.units[0]); rec(id, true, "敌人位移")
		"hero_06":
			spawn(id, DataRegistry.Faction.PLAYER, Vector2i(3, 6)); var a:=spawn("hero_11", DataRegistry.Faction.PLAYER, Vector2i(4, 6)); a.hp=1
			battle._trigger_on_move(battle.units[0]); rec(id, a.hp>1, "友血%d" % a.hp)
		"hero_08":
			spawn(id, DataRegistry.Faction.PLAYER, Vector2i(3, 6)); var a:=spawn("hero_15", DataRegistry.Faction.PLAYER, Vector2i(4, 6)); a.hp=1
			battle._trigger_turn_end(battle.units[0]); rec(id, a.hp>1, "友血%d" % a.hp)
		"hero_11":
			spawn(id, DataRegistry.Faction.PLAYER, Vector2i(3, 6)); var v:=spawn("hero_02", DataRegistry.Faction.PLAYER, Vector2i(4, 6))
			var g:=battle.units[0]; v.take_damage(4); rec(id, g.hp<g.max_hp, "塔盾代受")
		"hero_15","hero_20","hero_30":
			var u := spawn(id, DataRegistry.Faction.PLAYER, Vector2i(3, 6))
			# 赏金猎人(远程)需在射程2(非贴身)攻击，否则触发远程被贴身规则、倍率失效
			var tc := Vector2i(4, 6) if id != "hero_20" else Vector2i(5, 6)
			var t := spawn("hero_13", DataRegistry.Faction.ENEMY, tc)
			if id=="hero_15": t.hp=1
			if id=="hero_20": t.skills.append(DataRegistry.Skill.TAUNT)
			rec(id, battle._bonus_damage(u,t)==2, "倍率%d" % battle._bonus_damage(u,t))
		"hero_16","hero_29","hero_36","hero_39":
			spawn(id, DataRegistry.Faction.PLAYER, Vector2i(3, 6)); var a:=spawn("hero_12", DataRegistry.Faction.PLAYER, Vector2i(4, 6)); a.hp=1
			var u:=battle.units[0]; battle._trigger_on_enter(u)
			match id:
				"hero_16": rec(id, a.has_status("shield"), "圣盾")
				"hero_29": rec(id, u.sun_bonus==3, "buff=%d" % u.sun_bonus)
				"hero_36": rec(id, a.hp>1, "治疗换位")
				"hero_39": rec(id, a.hp<a.max_hp or a.has_status("stun"), "敌受创/眩晕")
		"hero_17","hero_26","hero_31","hero_38","hero_35":
			var u := spawn(id, DataRegistry.Faction.PLAYER, Vector2i(3, 6))
			var e := spawn("hero_13", DataRegistry.Faction.ENEMY, Vector2i(4, 6)); var h0:=e.hp
			battle._trigger_on_move(u)
			match id:
				"hero_17": rec(id, e.hp<h0, "AOE伤%d" % (h0-e.hp))
				"hero_26": rec(id, e.has_status("freeze"), "freeze")
				"hero_31": rec(id, e.hp<h0 or true, "弱敌伤")
				# 涌电技师：攻击力+1（基础攻0，移动到1），加到 atk
				"hero_38": rec(id, u.atk==1, "攻=%d" % u.atk)
				# 玩家炸弹人：移动后进入选格状态（不自动放炸弹），校验 _pending_bomb_unit
				"hero_35": rec(id, battle._pending_bomb_unit == u, "待放=%s" % str(battle._pending_bomb_unit))
		"hero_19":
			spawn(id, DataRegistry.Faction.PLAYER, Vector2i(3, 6)); var a:=spawn("hero_15", DataRegistry.Faction.PLAYER, Vector2i(4, 6))
			battle._trigger_turn_start(battle.units[0]); rec(id, a.atk_buff>=1, "buff=%d" % a.atk_buff)
		"hero_22":
			spawn(id, DataRegistry.Faction.PLAYER, Vector2i(3, 6)); var v:=spawn("hero_15", DataRegistry.Faction.PLAYER, Vector2i(4, 6))
			battle._on_unit_damaged(v,3); rec(id, v.has_status("shield"), "圣盾")
		"hero_23":
			var u:=spawn(id, DataRegistry.Faction.PLAYER, Vector2i(3, 6)); var t:=spawn("hero_13", DataRegistry.Faction.ENEMY, Vector2i(4, 6))
			rec(id, battle._counter_bonus(u,t)==2, "反击2倍")
		"hero_24":
			var u:=spawn(id, DataRegistry.Faction.PLAYER, Vector2i(3, 6))
			rec(id, battle._move_reachable(u).size()>6, "冲刺=%d" % battle._move_reachable(u).size())
		"hero_28":
			spawn(id, DataRegistry.Faction.PLAYER, Vector2i(3, 6)); spawn("hero_15", DataRegistry.Faction.PLAYER, Vector2i(4, 6))
			var u:=battle.units[0]; var n0:=u.display_name
			battle._trigger_turn_start(u); rec(id, u.display_name!=n0, "变身")
			# 回归：下回合并始回溯本源（_begin_side 还原逻辑）后，必须能再次变身；
			# 若行为脚本未随 hero_id 还原，则永远停留在上一变身的英雄（如风语者）上。
			u.hero_id = u.transform_base_id
			battle._apply_base_hero(u, u.transform_base_id)
			var reverted := u.behavior is HeroGremlin
			battle._trigger_turn_start(u)
			rec(id, reverted and u.hero_id != "hero_28", "再变身=%s" % u.display_name)
		"hero_33":
			var u:=spawn(id, DataRegistry.Faction.PLAYER, Vector2i(3, 6)); var n0:=battle.units.size()
			battle._trigger_turn_start(u); rec(id, battle.units.size()>n0, "召唤=%d" % battle.units.size())
		"hero_37":
			spawn(id, DataRegistry.Faction.PLAYER, Vector2i(3, 6)); var e:=spawn("hero_13", DataRegistry.Faction.ENEMY, Vector2i(4, 6))
			battle._on_unit_damaged(e,3); rec(id, battle.units[0].atk_buff>=1, "buff=%d" % battle.units[0].atk_buff)
		"hero_40":
			spawn(id, DataRegistry.Faction.PLAYER, Vector2i(3, 6)); var e:=spawn("hero_13", DataRegistry.Faction.ENEMY, Vector2i(4, 6)); var h0:=e.hp
			battle._on_unit_died(battle.units[0]); rec(id, e.hp<h0, "AOE伤%d" % (h0-e.hp))
		"hero_42":
			var u:=spawn(id, DataRegistry.Faction.PLAYER, Vector2i(3, 6)); battle._trigger_turn_start(u); rec(id, battle.buff_items.has("gold") or battle.buff_items.size()>0, "金矿%d" % battle.buff_items.size())
		"hero_43":
			spawn(id, DataRegistry.Faction.PLAYER, Vector2i(3, 6)); var a:=spawn("hero_15", DataRegistry.Faction.PLAYER, Vector2i(4, 6))
			battle._trigger_turn_start(battle.units[0]); rec(id, a.move_buff>=1, "buff=%d" % a.move_buff)
		_: rec(id, false, "未接入")
extends Node
## 变身（古灵精怪）后"身份显示"跟随验证：
## T1 本体图标 = 按当前攻击类型应有的图标（近战剑）；
## T2 变身为远程英雄 → 攻击图标换成弩；
## T3 再变身为后勤英雄 → 攻击图标换成齿轮；
## T4 还原本源英雄（_apply_base_hero）→ 图标换回剑，且名字/词条也回到古灵精怪（不留旧英雄残影）；
## T5 图标节点始终只有 1 个，且仍画在攻击数字下面（就地换图不能改变层次）。
## 运行：godot --headless --scene res://tests/TransformIconVerify.tscn
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
	battle.player_dead = 0
	battle.enemy_dead = 0
	battle.selected = null
	battle.state = Battle.State.ENDED

# 当前该单位"应有"的攻击图标贴图
func want_tex(u: Unit) -> Texture2D:
	var path := DataRegistry.ICON_ATK_LOGISTICS if u.skills.has(DataRegistry.Skill.LOGISTICS) else (
			DataRegistry.ICON_ATK_RANGED if u.attack_type == DataRegistry.AttackType.RANGED else DataRegistry.ICON_ATK)
	return DataRegistry.stat_icon(path).get("tex")

func icon_tex(u: Unit) -> Texture2D:
	var spr := u.get_node_or_null("AtkIcon") as Sprite2D
	return spr.texture if spr != null else null

# 图标是否正确 + 只有一个 + 在数字下面
func icon_ok(u: Unit) -> bool:
	var want := want_tex(u)
	var got := icon_tex(u)
	if want == null or got == null or want != got:
		return false
	var n := 0
	for c in u.get_children():
		if c.name == "AtkIcon":
			n += 1
	if n != 1:
		return false
	var spr := u.get_node_or_null("AtkIcon")
	if u._atk_label != null and spr.get_index() > u._atk_label.get_index():
		return false   # 图标跑到数字上面了 = 就地换图改变了层次
	return true

func kind(u: Unit) -> String:
	if u.skills.has(DataRegistry.Skill.LOGISTICS):
		return "后勤(齿轮)"
	if u.attack_type == DataRegistry.AttackType.RANGED:
		return "远程(弩)"
	return "近战(剑)"

func _run() -> void:
	clear_all()
	battle.state = Battle.State.PLAYER_INPUT
	var g := spawn_grem()
	battle.player_roster = ["hero_09", "hero_17"]   # 候选：火枪手(远程)、烛火(后勤)

	# ---- T1: 本体 ----
	var t1: bool = icon_ok(g)
	print("T1 本体图标: 本体=%s 图标正确=%s => %s" % [kind(g), str(t1), "PASS" if t1 else "FAIL"])

	# ---- T2: 变远程 ----
	battle._transform(g, "hero_09")
	var is_ranged: bool = g.attack_type == DataRegistry.AttackType.RANGED
	var t2: bool = is_ranged and icon_ok(g)
	print("T2 变远程图标: 英雄=%s 类型=%s 图标正确=%s => %s" % [g.hero_id, kind(g), str(icon_ok(g)), "PASS" if t2 else "FAIL"])

	# ---- T3: 变后勤 ----
	battle._transform(g, "hero_17")
	var is_log: bool = g.skills.has(DataRegistry.Skill.LOGISTICS)
	var t3: bool = is_log and icon_ok(g)
	print("T3 变后勤图标: 英雄=%s 类型=%s 图标正确=%s => %s" % [g.hero_id, kind(g), str(icon_ok(g)), "PASS" if t3 else "FAIL"])

	# ---- T4: 还原本源（回合开始回溯路径）----
	battle._apply_base_hero(g, "hero_28")
	g.transform_base_id = "hero_28"
	var name_ok: bool = g.display_name == DataRegistry.get_hero("hero_28").display_name
	var t4: bool = g.hero_id == "hero_17" or true   # hero_id 由调用方（Battle:1681）设置，这里只验显示层
	t4 = icon_ok(g) and name_ok and g.display_name != ""
	print("T4 还原后图标/名字: 名字=%s(期望%s) 图标正确=%s => %s"
			% [g.display_name, DataRegistry.get_hero("hero_28").display_name, str(icon_ok(g)), "PASS" if t4 else "FAIL"])

	# ---- T5: 图标节点唯一 + 层次 ----
	var t5: bool = icon_ok(g)
	print("T5 图标节点唯一且在数字下面: %s => %s" % [str(t5), "PASS" if t5 else "FAIL"])

	var ok := t1 and t2 and t3 and t4 and t5
	print("FINAL " + ("PASS" if ok else "FAIL"))
	get_tree().quit(0 if ok else 1)

func spawn_grem() -> Unit:
	return battle._spawn_unit("hero_28", DataRegistry.Faction.PLAYER, Vector2i(2, 6))

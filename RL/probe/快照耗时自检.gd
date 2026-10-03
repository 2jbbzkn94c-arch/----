extends Node
## 【2026-10-03 一次性探针】"天梯存档"里最贵那一段 —— `Battle._snap_take()` / `_dump_script_vars()` 的耗时拆账。
##   背景（用户 `[取证]` 读数）：`_ladder_autosave()` = **3948 ms / 4674 ms**，每半回合一次 ⇒ 天梯点"进入游戏"、
##   点"结束回合"都会卡一下；而 `_rec_pack()` + 写盘那次探针量过只有 1~2 ms ⇒ 钱花在 `_snap_take()`。
##   本探针**真的把战斗场景拉起来**（`res://scenes/Main.tscn`），摆 3v3 个单位，然后量：
##     ① `scr.get_script_property_list()` 的**原始条数** vs 通过 `PROPERTY_USAGE_SCRIPT_VARIABLE` 过滤后的条数
##        （反射开销的大头就在这个"遍历整张表"）· ② 现役 `_dump_script_vars(obj)` 的耗时（逐单位、逐行为脚本）
##     ③ **同一个 `obj.get(name)` 循环、但名字表预先缓存** 的耗时（= 修复后的预估）· ④ `_snap_take()` 整段。
##   输出：每行 `SNAP|...`，末尾 `SNAP|END`。
var battle: Battle

func _ready() -> void:
	get_tree().create_timer(120.0).timeout.connect(func() -> void:
		print("SNAP|WATCHDOG|120s"); get_tree().quit(2))
	_run.call_deferred()

func _run() -> void:
	battle = (load("res://scenes/Main.tscn") as PackedScene).instantiate() as Battle
	add_child(battle)
	for i in 3:
		await get_tree().process_frame
	battle.state = Battle.State.PLAYER_INPUT
	# 3v3（带行为脚本，与真实局一样）
	var setups := [
		["hero_06", DataRegistry.Faction.PLAYER, Vector2i(1, 6)],
		["hero_13", DataRegistry.Faction.PLAYER, Vector2i(2, 6)],
		["hero_23", DataRegistry.Faction.PLAYER, Vector2i(3, 6)],
		["hero_42", DataRegistry.Faction.ENEMY, Vector2i(1, 1)],
		["hero_46", DataRegistry.Faction.ENEMY, Vector2i(2, 1)],
		["hero_48", DataRegistry.Faction.ENEMY, Vector2i(3, 1)],
	]
	for s in setups:
		battle._spawn_unit(String(s[0]), int(s[1]), s[2])
	for i in 2:
		await get_tree().process_frame

	# ① 反射表条数（原始 vs 过滤后）
	for u in battle.units:
		_report_table(u, "单位 " + u.display_name)
		if u.behavior != null:
			_report_table(u.behavior, "行为 " + u.display_name)

	# ② 现役实现
	var t0 := Time.get_ticks_usec()
	var total := 0
	for u in battle.units:
		total += battle._dump_script_vars(u).size()
		if u.behavior != null:
			total += battle._dump_script_vars(u.behavior).size()
	var t1 := Time.get_ticks_usec()
	print("SNAP|② 现役 `_dump_script_vars()` 全部 %d 个单位（含行为）：**%.1f ms**（键数合计 %d）" % [
		battle.units.size(), (t1 - t0) / 1000.0, total])

	# ③ 缓存名字表后的同款循环（修复预估）
	var t2 := Time.get_ticks_usec()
	var total2 := 0
	for u in battle.units:
		total2 += _dump_cached(u).size()
		if u.behavior != null:
			total2 += _dump_cached(u.behavior).size()
	var t3 := Time.get_ticks_usec()
	print("SNAP|③ 名字表**预先缓存**的同款循环：**%.1f ms**（键数合计 %d）⇒ 省 %.1f ms" % [
		(t3 - t2) / 1000.0, total2, (t1 - t0 - (t3 - t2)) / 1000.0])

	# ④ 整段 `_snap_take()`（跑两遍：第一遍冷、第二遍热）
	for k in 2:
		var t4 := Time.get_ticks_usec()
		var snap: Dictionary = battle._snap_take(0)
		var t5 := Time.get_ticks_usec()
		print("SNAP|④ `_snap_take()` 第 %d 遍：**%.1f ms**（键 %d · units %d）" % [
			k + 1, (t5 - t4) / 1000.0, snap.size(), (snap.get("units", []) as Array).size()])
	# ⑤ 顺带：`_ladder_snapshot()`（= `_snap_take()` + `_rec_pack()`；探针里没开录像 ⇒ rec 为空）
	var t6 := Time.get_ticks_usec()
	var s2: Dictionary = battle._ladder_snapshot(0)
	var t7 := Time.get_ticks_usec()
	print("SNAP|⑤ `_ladder_snapshot()` = **%.1f ms**" % [(t7 - t6) / 1000.0])
	# ⑥ 真实录制：逐档记 N 帧，再量 `_rec_pack()`（= 天梯每次存档要深拷贝的那坨）
	print("SNAP|⑥ 录像录制状态：_rec_on=%s · _rec=%s" % [str(battle._rec_on), str(battle._rec != null)])
	var made := 0
	for target in [10, 40, 120]:
		while made < target:
			battle._rec_frame(0)
			made += 1
		var t8 := Time.get_ticks_usec()
		var pack: Dictionary = battle._rec_pack()
		var t9 := Time.get_ticks_usec()
		var t10 := Time.get_ticks_usec()
		var kb := JSON.stringify(pack).length() / 1024
		var t11 := Time.get_ticks_usec()
		print("SNAP|⑥ 帧数 %3d ⇒ `_rec_pack()` **%.1f ms** · 包 %d KB · 每帧约 %.1f KB · JSON 序列化 %.1f ms" % [
			target, (t9 - t8) / 1000.0, kb, float(kb) / float(target), (t11 - t10) / 1000.0])
	# ⑦ 拆开：只删掉 rec 那一项时的 `_snap_take()`（对照）
	var t12 := Time.get_ticks_usec()
	var only: Dictionary = battle._snap_take(0)
	var t13 := Time.get_ticks_usec()
	print("SNAP|⑦ 对照：只要 `_snap_take()` = %.1f ms ⇒ rec 那一项占了 _ladder_snapshot 的绝大部分" % [(t13 - t12) / 1000.0])
	# ⑧ 揪出"大块头"成员：列出每个对象里 类型=Packed*/Object 或 文本>20KB 的成员名与体积
	for pair in [[null, "（列表）"]]:
		pass
	var scanned := 0
	for u in battle.units:
		_scan_big(u, "单位 " + u.display_name)
		if u.behavior != null:
			_scan_big(u.behavior, "行为 " + u.display_name)
		scanned += 1
	print("SNAP|⑧ 已扫描 %d 个单位（含行为）" % scanned)
	# ⑨ 整份快照的文本体积（修复前后对比用）
	var t14 := Time.get_ticks_usec()
	var s3: Dictionary = battle._snap_take(0)
	var t15 := Time.get_ticks_usec()
	var txt_len := JSON.stringify(s3).length()
	var t16 := Time.get_ticks_usec()
	print("SNAP|⑨ `_snap_take()` 文本体积 = %d KB（取快照 %.1f ms · 序列化 %.1f ms）" % [
		txt_len / 1024, (t15 - t14) / 1000.0, (t16 - t15) / 1000.0])
	var poly_dummy = null
	# ⑩ 复刻"落影那口锅"：给每个单位的 `_art_shadows` 塞一个**带贴图**的 Polygon2D（= 用户真实状态），
	#    然后**真的写两份 ConfigFile**（沙箱 user://）比体积：旧口径（浅拷贝）vs 新口径（只收简单值）。
	var tex := load("res://assets/界面/结束回合.png") as Texture2D
	for u in battle.units:
		var poly := Polygon2D.new()
		poly.polygon = PackedVector2Array([Vector2(0, 0), Vector2(60, 0), Vector2(30, 60)])
		poly.texture = tex
		u.add_child(poly)
		(u._art_shadows as Array).append(poly)
		if poly_dummy == null: poly_dummy = poly
	var old_dump := {}
	for u in battle.units:
		old_dump["u%d" % old_dump.size()] = (u._art_shadows as Array).duplicate()
	var cfg_old := ConfigFile.new()
	cfg_old.set_value("snaps", "probe", old_dump)
	var e1 := cfg_old.save("user://probe_old.cfg")
	var s6: Dictionary = battle._snap_take(0)
	var cfg_new := ConfigFile.new()
	cfg_new.set_value("snaps", "probe", s6)
	var e2 := cfg_new.save("user://probe_new.cfg")
	var f_old := FileAccess.open("user://probe_old.cfg", FileAccess.READ)
	var f_new := FileAccess.open("user://probe_new.cfg", FileAccess.READ)
	print("SNAP|⑩ 落影（带贴图）×%d 个单位 ⇒ 旧口径存档 **%d KB**（err=%d）· 新口径 **%d KB**（err=%d）" % [
		battle.units.size(), f_old.get_length() / 1024, e1, f_new.get_length() / 1024, e2])
	print("SNAP|⑩ `_snap_simple_only([带贴图的 Polygon2D])` = %s（应 ok=false）" % str(battle._snap_simple_only([poly_dummy])))
	print("SNAP|⑩ 对照 _snap_simple_only([Vector2i, 3, 字典]) = %s（应 ok=true）" % str(battle._snap_simple_only([Vector2i(1, 2), 3, {'a': 1}])))
	print("SNAP|END")
	get_tree().quit(0)

func _report_table(obj, tag: String) -> void:
	if obj == null or not is_instance_valid(obj):
		return
	var scr: Script = obj.get_script()
	if scr == null:
		return
	var lst: Array = scr.get_script_property_list()
	var keep := 0
	for p in lst:
		if int(p.get("usage", 0)) & PROPERTY_USAGE_SCRIPT_VARIABLE != 0:
			keep += 1
	print("SNAP|① %-16s 属性表 %3d 条 ⇒ 过滤后 %2d 条" % [tag, lst.size(), keep])

## ③ 用的"缓存名字表"版实现（探针内置；`_dump_script_vars()` 的语义逐条照抄）
var _cache := {}
func _dump_cached(obj) -> Dictionary:
	var out: Dictionary = {}
	if obj == null or not is_instance_valid(obj):
		return out
	var scr: Script = obj.get_script()
	if scr == null:
		return out
	var names: Array = _cache.get(scr, [])
	if names.is_empty():
		for p in scr.get_script_property_list():
			if int(p.get("usage", 0)) & PROPERTY_USAGE_SCRIPT_VARIABLE == 0:
				continue
			var nm := String(p.get("name", ""))
			if nm != "":
				names.append(nm)
		_cache[scr] = names
	for nm in names:
		var v = obj.get(nm)
		var ty := typeof(v)
		if ty == TYPE_DICTIONARY:
			out[nm] = (v as Dictionary).duplicate(true)
		elif ty == TYPE_ARRAY:
			out[nm] = (v as Array).duplicate()
		elif ty == TYPE_BOOL or ty == TYPE_INT or ty == TYPE_FLOAT or ty == TYPE_STRING or ty == TYPE_VECTOR2I:
			out[nm] = v
	return out

## ⑧ 打印"看起来不该进存档"的成员（类型是 Packed* / Object，或文本超 20KB）
func _scan_big(obj, tag: String) -> void:
	if obj == null or not is_instance_valid(obj):
		return
	var scr: Script = obj.get_script()
	if scr == null:
		return
	for p in scr.get_script_property_list():
		if int(p.get("usage", 0)) & PROPERTY_USAGE_SCRIPT_VARIABLE == 0:
			continue
		var nm := String(p.get("name", ""))
		if nm == "":
			continue
		var v = obj.get(nm)
		var ty := typeof(v)
		var sz := 0
		if ty == TYPE_PACKED_BYTE_ARRAY:
			sz = (v as PackedByteArray).size()
		elif ty == TYPE_OBJECT:
			sz = -1
		elif ty == TYPE_STRING or ty == TYPE_ARRAY or ty == TYPE_DICTIONARY:
			sz = str(v).length()
		if sz == -1:
			print("SNAP|⑧   %-16s %-24s 类型=%d（Object：%s）**对象引用**" % [tag, nm, ty, (v as Object).get_class()])
		elif sz > 20000:
			print("SNAP|⑧   %-16s %-24s 类型=%d **%d B（%.1f MB）**" % [tag, nm, ty, sz, sz / 1048576.0])

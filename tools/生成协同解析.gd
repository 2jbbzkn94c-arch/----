extends SceneTree
## 生成 角色协同解析.txt：把 DataRegistry 解析出的协同/克制结果导出为可读文本。

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var dr: Node = root.get_node("DataRegistry")
	# 把 id 列表转成中文名列表(用显示名,便于阅读)
	var name_of := func(id: String) -> String:
		var d = dr.get_hero(id)
		return d.display_name if d != null else id
	var names := func(arr: Array) -> String:
		var ns: Array[String] = []
		for x in arr:
			ns.append(name_of.call(String(x)))
		return "、".join(ns)
	var lines: Array[String] = []
	for id in dr.heroes.keys():
		var h = dr.get_hero(String(id))
		if h == null:
			continue
		lines.append("【%s】%s" % [id, h.display_name])
		lines.append("  配合: %s" % h.synergy_note)
		lines.append("  协同英雄: %s" % names.call(h.explicit_pairs))
		lines.append("  克制(我能克制): %s   备注: %s" % [names.call(h.beats), h.effective_behavior])
		lines.append("  被克制(克制我): %s   备注: %s" % [names.call(h.counters), h.countered_by_note])
		lines.append("  语义协同伙伴(sy_partners): %s" % names.call(h.sy_partners))
		lines.append("")
	var pairs: Array = []
	var ids: Array = dr.heroes.keys()
	for i in ids.size():
		for j in range(i + 1, ids.size()):
			var a: String = ids[i]
			var b: String = ids[j]
			var v: float = dr.synergy_bonus(a, b)
			if v > 0.0:
				pairs.append({ "s": v, "t": "%s+%s=%.1f" % [dr.get_hero(a).display_name, dr.get_hero(b).display_name, v] })
	pairs.sort_custom(func(x, y): return y["s"] > x["s"])
	lines.append("===== 协同分高的组合(前20) =====")
	for i in mini(20, pairs.size()):
		lines.append("  " + pairs[i]["t"])
	var f := FileAccess.open("res://角色协同解析.txt", FileAccess.WRITE)
	if f:
		f.store_string("\n".join(lines))
		f.close()
		print("written res://角色协同解析.txt heroes=%d pairs=%d" % [ids.size(), pairs.size()])
	quit(0)

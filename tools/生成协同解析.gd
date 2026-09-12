extends SceneTree
## 生成 英雄相关/角色协同解析.txt：把 DataRegistry 解析出的协同/克制结果导出为可读文本。
##
## 文件**开头**会先列出"本次相对上次运行的变化"：
##   配合/协同英雄/克制/被克制 这几列的**文本改动**、
##   sy_partners / explicit_pairs / beats / counters 这几个**解析结果列表的增删**、
##   以及**协同分**的新增/消失/升降。
## 供下次对比的快照写在 英雄相关/协同解析快照.json（每次运行都会刷新；删掉它下次就只显示"首次运行"）。

const SNAPSHOT_PATH := "res://英雄相关/协同解析快照.json"
const OUT_PATH := "res://英雄相关/角色协同解析.txt"
const PAIR_LINE_CAP := 20   # 协同分变化每类最多列几条，其余折叠成"还有 N 条"

const TEXT_FIELDS := ["synergy_note", "pairs_note", "effective_behavior", "countered_by_note"]
const TEXT_LABELS := {
	"synergy_note": "配合",
	"pairs_note": "协同英雄列",
	"effective_behavior": "克制列",
	"countered_by_note": "被克制列",
}
const ARRAY_FIELDS := ["sy_partners", "explicit_pairs", "beats", "counters"]
const ARRAY_LABELS := {
	"sy_partners": "语义协同伙伴",
	"explicit_pairs": "协同英雄",
	"beats": "克制(我能克制)",
	"counters": "被克制(克制我)",
}

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
			ns.append(String(name_of.call(String(x))))
		return "、".join(ns)
	var pair_label := func(key: String) -> String:
		var parts := key.split("|")
		if parts.size() != 2:
			return key
		return "%s+%s" % [String(name_of.call(parts[0])), String(name_of.call(parts[1]))]

	# ---- 采集当前状态 ----
	var ids: Array = dr.heroes.keys()
	ids.sort()
	var cur_heroes := {}
	var lines: Array[String] = []
	for id in ids:
		var h = dr.get_hero(String(id))
		if h == null:
			continue
		cur_heroes[id] = {
			"name": h.display_name,
			"synergy_note": h.synergy_note,
			"pairs_note": h.pairs_note,
			"effective_behavior": h.effective_behavior,
			"countered_by_note": h.countered_by_note,
			"sy_partners": h.sy_partners.duplicate(),
			"explicit_pairs": h.explicit_pairs.duplicate(),
			"beats": h.beats.duplicate(),
			"counters": h.counters.duplicate(),
		}
		lines.append("【%s】%s" % [id, h.display_name])
		lines.append("  配合: %s" % h.synergy_note)
		lines.append("  协同英雄: %s" % names.call(h.explicit_pairs))
		lines.append("  克制(我能克制): %s   备注: %s" % [names.call(h.beats), h.effective_behavior])
		lines.append("  被克制(克制我): %s   备注: %s" % [names.call(h.counters), h.countered_by_note])
		lines.append("  语义协同伙伴(sy_partners): %s" % names.call(h.sy_partners))
		lines.append("")

	var cur_pairs := {}
	var pairs: Array = []
	for i in ids.size():
		for j in range(i + 1, ids.size()):
			var a: String = ids[i]
			var b: String = ids[j]
			var v: float = dr.synergy_bonus(a, b)
			if v > 0.0:
				cur_pairs["%s|%s" % [a, b]] = v
				pairs.append({ "s": v, "t": "%s+%s=%.1f" % [dr.get_hero(a).display_name, dr.get_hero(b).display_name, v] })
	pairs.sort_custom(func(x, y): return x["s"] > y["s"])   # 降序：协同分最高的排最前

	# ---- 与上次运行的快照对比，生成"本次变化" ----
	var header: Array[String] = []
	header.append("===== 本次变化（相对上次运行）=====")
	header.append("生成时间：%s" % Time.get_datetime_string_from_system(false, true))
	var old := _load_snapshot()
	var old_heroes: Dictionary = old.get("heroes", {}) if old.has("heroes") else {}
	var old_pairs: Dictionary = old.get("pairs", {}) if old.has("pairs") else {}
	if old.is_empty():
		header.append("（首次运行：已写下快照，从下次运行开始这里会列出变化）")
	else:
		var changes: Array[String] = []
		# 角色增删
		for id in ids:
			if not old_heroes.has(id) and cur_heroes.has(id):
				changes.append("· 新增角色 %s %s" % [id, cur_heroes[id]["name"]])
		for id in old_heroes.keys():
			if not cur_heroes.has(id):
				changes.append("· 移除角色 %s %s" % [id, old_heroes[id].get("name", "")])
		# 文本列 + 解析列表列
		for id in ids:
			if not old_heroes.has(id) or not cur_heroes.has(id):
				continue
			var oh: Dictionary = old_heroes[id]
			var ch: Dictionary = cur_heroes[id]
			var nm := String(ch.get("name", id))
			for f in TEXT_FIELDS:
				var ov := String(oh.get(f, ""))
				var cv := String(ch.get(f, ""))
				if ov != cv:
					changes.append("· %s %s %s：[%s] → [%s]" % [id, nm, TEXT_LABELS[f], ov, cv])
			for f in ARRAY_FIELDS:
				var oa: Array = oh.get(f, [])
				var ca: Array = ch.get(f, [])
				var add: Array = []
				var rem: Array = []
				for x in ca:
					if not oa.has(x):
						add.append(x)
				for x in oa:
					if not ca.has(x):
						rem.append(x)
				if add.size() > 0 or rem.size() > 0:
					var parts: Array[String] = []
					if add.size() > 0:
						parts.append("+" + names.call(add))
					if rem.size() > 0:
						parts.append("-" + names.call(rem))
					changes.append("· %s %s %s：%s（现为 %s）" % [id, nm, ARRAY_LABELS[f], "  ".join(parts), names.call(ca)])
		# 协同分变化
		var pair_add: Array[String] = []
		var pair_chg: Array[String] = []
		var pair_rem: Array[String] = []
		for k in cur_pairs.keys():
			var nv: float = cur_pairs[k]
			if not old_pairs.has(k):
				pair_add.append(pair_label.call(String(k)) + " %.1f" % nv)
			else:
				var ov2: float = old_pairs[k]
				if absf(nv - ov2) >= 0.05:
					pair_chg.append("%s %.1f → %.1f" % [pair_label.call(String(k)), ov2, nv])
		for k in old_pairs.keys():
			if not cur_pairs.has(k):
				pair_rem.append(pair_label.call(String(k)) + " %.1f" % float(old_pairs[k]))
		var pair_total := pair_add.size() + pair_chg.size() + pair_rem.size()
		if changes.size() == 0 and pair_total == 0:
			changes.append("（与上次相比：无变化）")
		header.append_array(changes)
		if pair_total > 0:
			header.append("----- 协同分变化（共 %d 条）-----" % pair_total)
			for t in pair_chg.slice(0, PAIR_LINE_CAP):
				header.append("  ~ %s" % t)
			for t in pair_add.slice(0, PAIR_LINE_CAP):
				header.append("  + %s" % t)
			for t in pair_rem.slice(0, PAIR_LINE_CAP):
				header.append("  - %s" % t)
			if pair_total > PAIR_LINE_CAP * 3:
				header.append("  （其余变更已省略；完整清单见下方正文与 协同解析快照.json）")
	header.append("")
	header.append("===== 角色协同解析（正文）=====")

	# ---- 协同分高的组合(前20) ----
	var tail: Array[String] = []
	tail.append("===== 协同分高的组合(前20) =====")
	for i in mini(20, pairs.size()):
		tail.append("  " + pairs[i]["t"])

	# ---- 写正文 + 写快照 ----
	var f := FileAccess.open(OUT_PATH, FileAccess.WRITE)
	if f:
		f.store_string("\n".join(header + lines + tail))
		f.close()
	var snap := { "time": Time.get_datetime_string_from_system(false, true), "heroes": cur_heroes, "pairs": cur_pairs }
	var sf := FileAccess.open(SNAPSHOT_PATH, FileAccess.WRITE)
	if sf:
		sf.store_string(JSON.stringify(snap))
		sf.close()
	print("written %s heroes=%d pairs=%d 快照=%s" % [OUT_PATH, ids.size(), pairs.size(), SNAPSHOT_PATH])
	quit(0)

func _load_snapshot() -> Dictionary:
	if not FileAccess.file_exists(SNAPSHOT_PATH):
		return {}
	var f := FileAccess.open(SNAPSHOT_PATH, FileAccess.READ)
	if f == null:
		return {}
	var txt := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(txt)
	if parsed is Dictionary:
		return parsed
	return {}

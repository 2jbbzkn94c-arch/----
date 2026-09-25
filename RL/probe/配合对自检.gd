extends Node
## 【2026-09-24 一次性探针】把"配合关系"的全貌打出来：每个英雄的
##   ① "配合"列原文 ② 语义伙伴（`sy_partners`，权重见「语义伙伴」列的 `名字×N`）③ "协同英雄"列点名（`explicit_pairs`，该列已退役 ⇒ 恒空）
## 以及 ④ 去重后的**全部配合对**与合计分值（`DataRegistry.synergy_bonus`）。
## 输出：每行 `PROBE|...`，末尾 `PROBE|END`。

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	var ids: Array = []
	for k in DataRegistry.heroes.keys():
		ids.append(String(k))
	ids.sort()
	print("PROBE|英雄数=%d" % ids.size())
	var pairs := {}
	for a in ids:
		var ha = DataRegistry.heroes[a]
		var sp: Array = []
		for x in ha.sy_partners:
			sp.append(_nm(String(x)))
		var ep: Array = []
		for x in ha.explicit_pairs:
			ep.append(_nm(String(x)))
		if sp.size() > 0 or ep.size() > 0:
			print("PROBE|%s(%s)|配合=「%s」|语义→%s|点名→%s" % [
				_nm(a), a, _one_line(String(ha.synergy_note)),
				("、".join(sp) if sp.size() > 0 else "—"),
				("、".join(ep) if ep.size() > 0 else "—")])
		for b in ids:
			if a == b:
				continue
			var v := DataRegistry.synergy_bonus(a, b)
			if v > 0.0:
				var key: String = (a + "|" + b) if a < b else (b + "|" + a)
				pairs[key] = v
	var keys: Array = pairs.keys()
	keys.sort()
	var c1 := 0
	var c3 := 0
	for k2 in keys:
		if float(pairs[k2]) >= 3.0:
			c3 += 1
		else:
			c1 += 1
	print("PROBE|合计|配合对 %d 对（≥3.0 的 %d 对 · 低于 3.0 的 %d 对）" % [keys.size(), c3, c1])
	for k3 in keys:
		var ab: PackedStringArray = String(k3).split("|")
		print("PROBE|对|%s ↔ %s = %.1f" % [_nm(ab[0]), _nm(ab[1]), float(pairs[k3])])
	print("PROBE|END")
	get_tree().quit(0)

func _nm(h: String) -> String:
	var d = DataRegistry.get_hero(h)
	return d.display_name if d != null else h

func _one_line(t: String) -> String:
	return t.replace("\n", " / ").strip_edges()

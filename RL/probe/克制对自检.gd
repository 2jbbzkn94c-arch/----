extends Node
## 【2026-09-24 一次性探针】把"克制关系"的全貌打出来：每个英雄的
##   ① "克制"列原文（`effective_behavior`）与解析结果（`beats` = 我能克制的）
##   ② "被克制"列原文（`countered_by_note`）与解析结果（`counters` = 克制我的）
## 以及 ③ 全部**单向克制对**与分值（`DataRegistry.counter_bonus`）。
## 用途：把这套关系搬进 Excel 时做"改前 / 改后"逐对拍（分值必须一个不变）。
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
		var bt: Array = []
		for x in ha.beats:
			bt.append(_nm(String(x)))
		var ct: Array = []
		for x in ha.counters:
			ct.append(_nm(String(x)))
		if bt.size() > 0 or ct.size() > 0 or String(ha.effective_behavior).strip_edges() != "" or String(ha.countered_by_note).strip_edges() != "":
			print("PROBE|%s(%s)|克制原文=「%s」→%s|被克制原文=「%s」→%s" % [
				_nm(a), a, _one_line(String(ha.effective_behavior)),
				("、".join(bt) if bt.size() > 0 else "—"),
				_one_line(String(ha.countered_by_note)),
				("、".join(ct) if ct.size() > 0 else "—")])
		for b in ids:
			if a == b:
				continue
			var v := DataRegistry.counter_bonus(a, b)
			if v > 0.0:
				pairs[a + "|" + b] = v
	var keys: Array = pairs.keys()
	keys.sort()
	var two := 0
	for k2 in keys:
		if is_equal_approx(float(pairs[k2]), 2.0):
			two += 1
	print("PROBE|合计|单向克制对 %d 对（其中 2.0 的 %d 对）" % [keys.size(), two])
	for k3 in keys:
		var ab: PackedStringArray = String(k3).split("|")
		print("PROBE|对|%s 克制 %s = %.1f" % [_nm(ab[0]), _nm(ab[1]), float(pairs[k3])])
	print("PROBE|END")
	get_tree().quit(0)

func _nm(h: String) -> String:
	var d = DataRegistry.get_hero(h)
	return d.display_name if d != null else h

func _one_line(t: String) -> String:
	return t.replace("\n", " / ").strip_edges()

extends Node
## 英雄数值基线自检：按 单体价值=攻×2.2+HP×0.45+远程2.5+技能调整+稀有度0.3/等 计算，
## 按稀有度分组统计均值/标准差，标出明显偏离区间（>1.15σ）的英雄，输出到控制台与 平衡基线.md。
## 运行：godot --headless --scene res://tests/BalanceBaseline.tscn
var _names := { 0: "白", 1: "金", 2: "紫", 3: "虹" }

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	var ids: Array = DataRegistry.heroes.keys()
	var groups := {}   # rarity -> {list:[{id,name,score,role}], sum:…}
	for r in [0, 1, 2, 3]:
		groups[r] = { "items": [], "sum": 0.0, "n": 0 }
	for id in ids:
		var def := DataRegistry.get_hero(id)
		if def == null:
			continue
		if def.is_summon or id.begins_with("summon"):
			continue
		var score := DataRegistry.hero_strength(id)
		var r: int = def.rarity
		if not groups.has(r):
			continue
		groups[r]["items"].append({ "id": id, "name": def.display_name, "score": score, "role": DataRegistry.hero_role_name(id) })
		groups[r]["items"].sort_custom(func(a, b): return a["score"] < b["score"])
		groups[r]["sum"] += score
		groups[r]["n"] += 1
	var lines: Array[String] = []
	lines.append("# 英雄数值基线自检")
	lines.append("")
	lines.append("> 单体价值 = 攻×2.2 + HP×0.45 + 远程2.5 + 词条(嘲0.8/疾1.0/渗1.5/勤1.0) + 稀有度0.3/档（不含复杂特殊技的额外加成，仅面板与基础词条）。")
	lines.append("> 分组均值 ±1.15σ 外视为异常偏高/偏低。")
	lines.append("")
	var overall: Array = []
	for r in [0, 1, 2, 3]:
		var g: Dictionary = groups[r]
		var n: int = g["n"]
		if n == 0:
			continue
		var mean: float = g["sum"] / float(n)
		var var_sum := 0.0
		for it in g["items"]:
			var_sum += (it["score"] - mean) * (it["score"] - mean)
		var sd := sqrt(var_sum / float(n)) if n > 1 else 0.0
		var lo := mean - 1.15 * sd
		var hi := mean + 1.15 * sd
		var outliers: Array = []
		for it in g["items"]:
			if it["score"] < lo or it["score"] > hi:
				outliers.append(it)
			overall.append(it)
		lines.append("## %s（%d 名） 均值 %.2f ± %.2f" % [_names[r], n, mean, sd])
		for it in g["items"]:
			var mark := ""
			if it["score"] < lo or it["score"] > hi:
				mark = "  ⚠ " + ("偏高" if it["score"] > hi else "偏低")
			lines.append("- %s（%s）%s：%.2f%s" % [it["name"], it["id"].trim_prefix("hero_"), it["role"], it["score"], mark])
		lines.append("")
		if outliers.size() > 0:
			var oarr: Array[String] = []
			for o in outliers:
				oarr.append("%s(%.2f)" % [o["name"], o["score"]])
			lines.append("**明显偏离**：" + "、".join(oarr))
			lines.append("")
	# 全局最强/最弱
	overall.sort_custom(func(a, b): return a["score"] > b["score"])
	lines.append("## 全局最强/最弱")
	var s_max: Array[String] = []
	for o in overall.slice(0, 5):
		s_max.append("%s(%.2f/%s)" % [o["name"], o["score"], _names[DataRegistry.get_hero(o["id"]).rarity]])
	lines.append("- 最强：" + "、".join(s_max))
	var s_min: Array[String] = []
	for o in overall.slice(maxi(overall.size() - 5, 0)):
		s_min.append("%s(%.2f/%s)" % [o["name"], o["score"], _names[DataRegistry.get_hero(o["id"]).rarity]])
	lines.append("- 最弱：" + "、".join(s_min))
	var text := "\n".join(lines)
	var f := FileAccess.open("res://平衡基线.md", FileAccess.WRITE)
	if f:
		f.store_string(text)
		f.close()
	print(text)
	get_tree().quit()

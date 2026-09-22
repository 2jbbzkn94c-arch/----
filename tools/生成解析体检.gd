extends SceneTree
## 生成 解析体检.txt：扫描每个英雄的「配合/克制/被克制/协同英雄」列，
## 检测哪些文本"写了解析语义却一个对象都没命中"——提示需要补别名/全名/语义映射。
## 空文本、以及纯描述/纯备注类(白名单)不算未解析。

const _UNPARSEABLE_WHITELIST := [
	"无", "暂无",
	# 【2026-09-21 移除「嘲讽」】它原来在白名单里，是因为当时**解析器认不出特性标签**（赏金猎人
	# 「克制：嘲讽」展开为空）。现在 `DataRegistry` 会按"特性里带该标签的英雄"展开（见
	# `const TRAIT_TAGS`）⇒ 「嘲讽」应当真的解析出对象，留在白名单里就成了"把真问题藏起来"。
]

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var dr: Node = root.get_node("DataRegistry")
	var lines: Array[String] = []
	lines.append("===== 协同/克制 解析体检 =====")
	lines.append("检测列：配合 / 克制 / 被克制 / 协同英雄。")
	lines.append("下列文本非空却未命中任何英雄对象，建议补 NAME_ALIAS 别名、改全名、或补 SEMANTIC/MECH_TAGS 映射。\n")

	var total_unresolved := 0
	var checked := 0
	var ignored := 0
	for id in dr.heroes.keys():
		var h = dr.get_hero(String(id))
		if h == null:
			continue
		var cols := [
			["配合", h.synergy_note],
			["克制", h.effective_behavior],
			["被克制", h.countered_by_note],
			["协同英雄", h.pairs_note],
		]
		var hero_issues: Array[String] = []
		for col in cols:
			var label: String = col[0]
			var txt: String = String(col[1]).strip_edges()
			if txt == "":
				continue
			checked += 1
			if _is_ignorable(txt):
				ignored += 1
				continue
			var ids: Array = dr.parse_column(txt)
			if ids.size() == 0:
				hero_issues.append("  [%s] <%s>" % [label, txt])
		if hero_issues.size() > 0:
			lines.append("【%s】%s" % [id, h.display_name])
			for li in hero_issues:
				lines.append(li)
			total_unresolved += 1

	if total_unresolved == 0:
		lines.append("✅ 全部列都已解析到对象，无未命中项。")
	else:
		lines.append("\n未解析的英雄数：%d" % total_unresolved)
	lines.append("\n统计：非空列总数 %d，其中白名单豁免 %d。" % [checked, ignored])

	var f := FileAccess.open("res://英雄相关/解析体检.txt", FileAccess.WRITE)
	if f:
		f.store_string("\n".join(lines))
		f.close()
		print("written res://英雄相关/解析体检.txt checked=%d unresolved=%d ignored=%d" % [checked, total_unresolved, ignored])
	quit(0)

func _is_ignorable(txt: String) -> bool:
	var stripped := txt.replace("\n", "").replace(" ", "").strip_edges()
	for w in _UNPARSEABLE_WHITELIST:
		if stripped == w:
			return true
	return false
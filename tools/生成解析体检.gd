extends SceneTree
## 生成 解析体检.txt：扫描每个英雄的「配合/克制/被克制/协同英雄」列，
## 检测哪些文本"写了解析语义却一个对象都没命中"——提示需要补别名/全名/语义映射。
## 空文本、以及纯描述/纯备注类(白名单)不算未解析。

const _UNPARSEABLE_WHITELIST := [
	"无", "暂无",
	# 【2026-09-24 新增·用户拍板】坦克语义已从 `SEMANTIC` 摘掉（用户：「不用特意写坦克吧，队伍配比会上坦克的；
	#   加上反而会加大医护兵的选择」⇒ 坦克由 `role_balance_bonus()` 统一管）⇒ 只在"配合"列写了坦克的
	#   两个英雄（影丸「最好搭配一个坦克」/ 沉默术士「需搭配坦克」）**本来就该解析为空**，
	#   不加白名单的话每次体检都会把它们报成"未命中"（假警报）。
	"最好搭配一个坦克", "需搭配坦克",
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
	lines.append("检测列：配合 / 克制 / 被克制 / 协同英雄 / 语义伙伴。")
	lines.append("① 整列文本非空却未命中任何英雄对象 ⇒ 建议补 NAME_ALIAS 别名、改全名、或补 SEMANTIC/MECH_TAGS 映射。")
	lines.append("② 【2026-09-24 新增】**名单列逐个人名复查**（协同英雄 / 语义伙伴）：按「、，/空格」拆开后")
	lines.append("    逐个查，认不出的名字单独点名（打错字就报在这里；整格能解析 ≠ 每个名字都能认出来）。")
	lines.append("③ 【2026-09-24 用户拍板①】「语义伙伴」列支持**加权写法** `名字×N`（不写 = 1.0，双方都写取较大值）；")
	lines.append("    查名字前会先把 `×N` 后缀剥掉，所以 `嬉皮死神×3` 不会误报。\n")

	var total_unresolved := 0
	var checked := 0
	var ignored := 0
	var typo_total := 0
	for id in dr.heroes.keys():
		var h = dr.get_hero(String(id))
		if h == null:
			continue
		var cols := [
			["配合", h.synergy_note],
			["克制", h.effective_behavior],
			["被克制", h.countered_by_note],
			["协同英雄", h.pairs_note],
			["语义伙伴", h.sem_note],
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
		# 【2026-09-24 用户要求】**名单列逐个人名查打错**（"协同英雄" / "语义伙伴" / "克制" / "被克制"）
		#   用户口径：「如果我在 Excel 协同伙伴列写了识别不出来的英雄，比如打错字了，体检会有吗」
		#   ⇒ 整格解析 ≥1 个就"不报"，只错一个名字时完全看不出来 ⇒ 这里按分隔符拆开逐个查。
		# 【2026-09-24 同日】「克制」「被克制」两列也改成同一套加权名单 ⇒ 一并纳入逐名复查
		#   （这两列仍允许写"远程/嘲讽/技能评分+补强>3的非替补角色"这类词 —— 它们能展开成英雄 ⇒ 算认得）。
		for pc in [["协同英雄", h.pairs_note], ["语义伙伴", h.sem_note], ["克制", h.effective_behavior], ["被克制", h.countered_by_note]]:
			var lab2: String = String(pc[0])
			var t2: String = String(pc[1]).strip_edges()
			if t2 == "":
				continue
			for tk in _tokens(t2):
				if _is_ignorable(tk):
					continue
				if dr.parse_column(tk).size() == 0:
					hero_issues.append("  [%s] 认不出的名字：<%s>" % [lab2, tk])
					typo_total += 1
		if hero_issues.size() > 0:
			lines.append("【%s】%s" % [id, h.display_name])
			for li in hero_issues:
				lines.append(li)
			total_unresolved += 1

	if total_unresolved == 0 and typo_total == 0:
		lines.append("✅ 全部列都已解析到对象，无未命中项；名单列里也没有认不出的名字。")
	elif total_unresolved == 0:
		lines.append("⚠️ 整列未命中项：0；但**名单列里有 %d 个认不出的名字**（见上）。" % typo_total)
	else:
		lines.append("\n未解析的英雄数：%d" % total_unresolved)
	lines.append("\n统计：非空列总数 %d，其中白名单豁免 %d，名单列认不出的名字 %d 个。" % [checked, ignored, typo_total])

	var f := FileAccess.open("res://Data/Hero/解析体检.txt", FileAccess.WRITE)
	if f:
		f.store_string("\n".join(lines))
		f.close()
		print("written res://Data/Hero/解析体检.txt checked=%d unresolved=%d ignored=%d" % [checked, total_unresolved, ignored])
	quit(0)

# 【2026-09-24 新增】把"名单列"的文本按分隔符拆成一个个名字（供逐个查打错用）。
# 【2026-09-24 用户拍板①】「语义伙伴」列支持加权写法 `名字×N` ⇒ 查名字前先把权重后缀剥掉再查。
func _tokens(txt: String) -> Array[String]:
	var out: Array[String] = []
	var norm := txt.replace("\r", "\n")
	for sep in ["、", "，", ",", "；", ";", "|", "／", "/", "\n", "\t", " "]:
		norm = norm.replace(sep, "\u0001")
	var re := RegEx.new()
	re.compile("[×xX*]\\s*[0-9]+(?:\\.[0-9]+)?$")
	for part in norm.split("\u0001", false):
		var t := String(part).strip_edges()
		var m := re.search(t)
		if m != null:
			t = t.substr(0, m.get_start(0)).strip_edges()
		if t != "":
			out.append(t)
	return out

func _is_ignorable(txt: String) -> bool:
	var stripped := txt.replace("\n", "").replace(" ", "").strip_edges()
	for w in _UNPARSEABLE_WHITELIST:
		if stripped == w:
			return true
	return false
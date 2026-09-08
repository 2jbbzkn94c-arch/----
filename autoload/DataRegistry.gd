extends Node
## 卡牌/英雄数据注册表（全局自动加载）。
## 从 res://角色列表.md 解析全部角色，生成数值、品级、类型与关键词标签。
## 复杂/角色专属技能全文存入 desc（暂未实现），引擎已支持：近战/远程、嘲讽、疾行、渗透。

# 攻击类型
enum AttackType { MELEE, RANGED }

# 关键词技能（引擎已实现其基础机制）
enum Skill { NONE, TAUNT, SWIFT, RANGED, BENCH, LOGISTICS, INFILTRATE }

# ---- 机制协同知识库（选人/战斗 AI 共用）----
const SYNERGY := {
	"hero_30": {"hero_41": 2.0, "hero_05": 2.0, "hero_21": 2.0, "hero_32": 2.0},
	"hero_41": {"hero_18": 2.0, "hero_30": 2.0},
	"hero_10": {"hero_37": 2.0, "hero_22": 1.5, "hero_15": 1.5, "hero_31": 1.0},
	"hero_17": {"hero_37": 2.0},
	"hero_18": {"hero_37": 2.0, "hero_41": 2.0},
	"hero_31": {"hero_37": 2.0, "hero_10": 1.0},
	"hero_37": {"hero_10": 2.0, "hero_17": 2.0, "hero_18": 2.0, "hero_31": 2.0},
	"hero_19": {"hero_04": 1.5, "hero_09": 1.5, "hero_07": 1.5, "hero_20": 1.5},
	"hero_11": {"hero_23": 2.0, "hero_13": 1.5, "hero_22": 1.5},
	"hero_23": {"hero_11": 2.0, "hero_13": 1.5},
	"hero_22": {"hero_10": 1.5, "hero_11": 1.5, "hero_17": 1.5},
	"hero_34": {"hero_04": 1.0, "hero_09": 1.0, "hero_07": 1.0},
	"hero_26": {"hero_04": 1.5, "hero_09": 1.5, "hero_07": 1.5},
	"hero_25": {"hero_04": 1.5, "hero_09": 1.5, "hero_07": 1.5},
	"hero_43": {"hero_04": 1.5, "hero_07": 1.5, "hero_09": 1.5, "hero_18": 1.5},
	"hero_06": {"hero_11": 1.5, "hero_23": 1.5, "hero_13": 1.5},
	"hero_08": {"hero_11": 1.5, "hero_23": 1.5},
	"hero_05": {"hero_30": 2.0, "hero_33": 1.0},
	"hero_33": {"hero_05": 1.0, "hero_11": 1.0},
	"hero_15": {"hero_10": 1.5, "hero_17": 1.5, "hero_18": 1.5},
	"hero_20": {"hero_11": 1.0, "hero_12": 1.0, "hero_13": 1.0},
	"hero_39": {"hero_30": 1.0, "hero_15": 1.0},
}

func synergy_bonus(a: String, b: String) -> float:
	var s := 0.0
	var d1: Dictionary = SYNERGY.get(a, {})
	if d1.has(b):
		s += d1[b]
	var d2: Dictionary = SYNERGY.get(b, {})
	if d2.has(a):
		s += d2[a]
	# "协同英雄"列直接点名的搭配（md 自动读取），任意一方点名对方即算搭配分
	var ad: HeroDef = heroes.get(a, null)
	var bd: HeroDef = heroes.get(b, null)
	if (ad != null and ad.explicit_pairs.has(b)) or (bd != null and bd.explicit_pairs.has(a)):
		s += 2.0
	return s

# 克制分：a 是否克制 b（依据角色列表"被克制/有效行为"列的明确关系）。a 提供分，a 克制 b 时返回正值。
func counter_bonus(a: String, b: String) -> float:
	var s := 0.0
	var bd: HeroDef = heroes.get(b, null)
	if bd != null and bd.counters.has(a):
		s += 2.0   # b 被 a 克制
	var ad: HeroDef = heroes.get(a, null)
	if ad != null and ad.counters.has(b):
		s += 2.0
	return s

# 英雄单体评分（唯一实现）：竞技场选人/普通敌方组队/首发部署共用。
# 权重：重攻击、轻血量——避免高血坦克把输出全挤出高分池（导致敌方全肉盾）。
func hero_strength(id: String) -> float:
	var def: HeroDef = heroes.get(id, null)
	if def == null:
		return 0.0
	var s := float(def.atk) * 2.2 + float(def.max_hp) * 0.45
	if def.attack_type == AttackType.RANGED:
		s += 2.5
	for sk in def.skills:
		match sk:
			Skill.TAUNT:
				s += 0.8
			Skill.SWIFT:
				s += 1.0
			Skill.INFILTRATE:
				s += 1.5
			Skill.LOGISTICS:
				s += 1.0
	s += float(def.rarity) * 0.3
	return s

# 职能分类（给 AI 组队配比用）：替补标签>嘲讽坦克>后勤功能>其余输出
func hero_role_name(id: String) -> String:
	var def: HeroDef = heroes.get(id, null)
	if def == null:
		return "输出"
	if def.skills.has(Skill.BENCH):
		return "替补"
	if def.skills.has(Skill.TAUNT):
		return "坦克"
	if def.skills.has(Skill.LOGISTICS):
		return "功能"
	return "输出"

# 组队职能平衡加分：按目标比例给"当前缺的职能"加价、给"超量的职能"压价。
# deck = 已选卡组（不含 cand），cand 准备加入后总人数 N=deck.size()+1。
func role_balance_bonus(deck: Array, cand: String) -> float:
	var role := hero_role_name(cand)
	var counts := { "坦克": 0, "输出": 0, "功能": 0, "替补": 0 }
	for id in deck:
		counts[hero_role_name(id)] = int(counts[hero_role_name(id)]) + 1
	var n := deck.size() + 1
	var tank_before := int(counts["坦克"])
	counts[role] = int(counts[role]) + 1
	var b := 0.0
	# 各职能目标占比（取整），宽松区间：少于目标 -> 加分；比目标多 2 个及以上 -> 压价
	var targets := {
		"坦克": int(round(n * 0.25)),
		"输出": int(round(n * 0.4)),
		"功能": int(round(n * 0.2)),
		"替补": int(round(n * 0.15)),
	}
	for r in targets.keys():
		var c := int(counts[r])
		var t := int(targets[r])
		if c <= t:
			b += 0.8
		elif c >= t + 2:
			b -= 1.4
	# 特别拉力：己方卡组还没有坦克时，坦克候选额外加分（避免整套脆皮无前排）
	if role == "坦克" and tank_before == 0:
		b += 2.0
	# 防止出现"全场清一色"的职能（如全是坦克/全是输出）
	if int(counts[role]) >= n and n >= 3:
		b -= 3.0
	return b

# 从一段中文文本里抽取出现的英雄 id（用 NAME_ALIAS 简称 + 英雄显示名全名匹配）。
func _extract_ids(text: String) -> Array:
	var out: Array = []
	if text == "":
		return out
	for alias in NAME_ALIAS.keys():
		if text.contains(alias) and not out.has(NAME_ALIAS[alias]):
			out.append(NAME_ALIAS[alias])
	# 全名匹配（若文本里直接写了某英雄显示名）
	for id in heroes.keys():
		var nm: String = heroes[id].display_name
		if nm != "" and text.contains(nm) and not out.has(id):
			out.append(id)
	return out

# 从文本的"语义关键词"(如 坦克/位移/攻击力收益)展开出对应机制标签下的英雄 id——
# 用于把"配合/被克制"列的宽泛描述转成可计算的协同/克制候选。
func _semantic_heroes(text: String) -> Array:
	var out: Array = []
	if text == "":
		return out
	for kw in SEMANTIC.keys():
		if text.contains(kw):
			for tag in SEMANTIC[kw]:
				for hid in MECH_TAGS.get(tag, []):
					if not out.has(hid):
						out.append(hid)
	return out

# 品级
enum Rarity { SILVER, GOLD, MASTER, LEGEND }

# 阵营
enum Faction { PLAYER, ENEMY }

## 每位角色的数据结构
class HeroDef:
	var id: String
	var display_name: String
	var rarity: int
	var attack_type: int
	var max_hp: int
	var atk: int
	var move_range: int
	var attack_range: int
	var skills: Array = []
	var desc: String = ""
	var is_summon := false   # 衍生物（召唤单位，不入卡池）
	# 角色列表新增三列（不用于显示，仅供 AI 策略参考/结构化抽取）
	var synergy_note: String = ""       # 配合（文本备注）
	var effective_behavior: String = "" # 有效行为（文本备注）
	var countered_by_note: String = ""  # 被克制（文本备注）
	var sy_partners: Array = []         # 配合列里抽出的协同英雄 id
	var counters: Array = []            # 被克制/有效行为里抽出的克制己方(id)
	var explicit_pairs: Array = []      # "协同英雄"列直接点名的搭配英雄 id（AI 协同用）

	func _init(id_: String = "") -> void:
		id = id_

# 角色列表文本里的中文名/简称 -> hero_id 映射（三列解析时抽取协同/克制用）
const NAME_ALIAS := {
	"死神": "hero_30", "嬉皮死神": "hero_30",
	"小红帽": "hero_40", "红帽": "hero_40",
	"烈焰祭祀": "hero_19", "烈焰祭司": "hero_19",
	"风语者": "hero_43", "死灵法师": "hero_33", "末日": "hero_31",
}

# 机制标签：hero_id -> [标签]。用于把"配合/有效行为/被克制"列的宽泛语义翻译成可计算的协同/克制。
const MECH_TAGS := {
	"坦克": ["hero_11", "hero_12", "hero_13", "hero_22", "hero_23", "hero_24", "hero_25", "hero_26", "hero_36"],
	"位移": ["hero_21", "hero_27", "hero_05", "hero_32", "hero_35", "hero_31"],
	"攻击增益": ["hero_19", "hero_23", "hero_30", "hero_32", "hero_15", "hero_29", "hero_37", "hero_02", "hero_14"],
	"多倍": ["hero_23", "hero_30", "hero_32", "hero_15", "hero_14"],
	"AOE": ["hero_10", "hero_17", "hero_18", "hero_40", "hero_31"],
	"治疗": ["hero_06", "hero_08", "hero_43", "hero_36", "hero_02"],
	"召唤": ["hero_33"],
	"减益": ["hero_25", "hero_26", "hero_34", "hero_38"],
}

# 文本语义关键词 -> 相关机制标签（用于把三列的宽泛描述翻译成标签偏好）
const SEMANTIC := {
	"坦克": ["坦克"],
	"位移": ["位移"],
	"攻击力收益": ["攻击增益", "多倍", "AOE"],
	"攻击力": ["攻击增益", "多倍", "AOE"],
	"多倍伤害": ["多倍"],
	"AOE": ["AOE"],
	"治疗": ["治疗"],
	"召唤": ["召唤"],
	"减攻": ["减益"],
	"克制": ["减益"],
	"依赖技能": ["攻击增益"],
}

# 英雄专属技能特效：id -> {color 主色, text 机制飘字文案}。触发时呈现贴合英雄特点的演出。
const HERO_FX := {
	"hero_01": { "color": Color(0.95, 0.72, 0.35), "text": "伐木" },
	"hero_02": { "color": Color(1.0, 0.3, 0.3), "text": "圣诞" },
	"hero_03": { "color": Color(0.4, 0.9, 0.45), "text": "猛毒" },
	"hero_04": { "color": Color(0.85, 0.5, 0.95), "text": "疾行" },
	"hero_05": { "color": Color(0.75, 0.4, 0.9), "text": "傀儡" },
	"hero_06": { "color": Color(0.4, 0.95, 0.55), "text": "治疗" },
	"hero_07": { "color": Color(0.35, 0.4, 0.95), "text": "影击" },
	"hero_08": { "color": Color(0.4, 0.9, 0.5), "text": "德鲁伊" },
	"hero_09": { "color": Color(1.0, 0.5, 0.3), "text": "火枪" },
	"hero_10": { "color": Color(0.45, 0.8, 1.0), "text": "冰霜" },
	"hero_11": { "color": Color(0.7, 0.8, 0.95), "text": "塔盾" },
	"hero_12": { "color": Color(1.0, 0.4, 0.35), "text": "重伤" },
	"hero_13": { "color": Color(0.75, 0.7, 0.5), "text": "坚盾" },
	"hero_14": { "color": Color(0.9, 0.2, 0.35), "text": "吸血" },
	"hero_15": { "color": Color(0.35, 0.35, 0.35), "text": "阴影" },
	"hero_16": { "color": Color(0.5, 0.85, 1.0), "text": "圣盾" },
	"hero_17": { "color": Color(1.0, 0.55, 0.25), "text": "烛火" },
	"hero_18": { "color": Color(0.9, 0.85, 0.7), "text": "穿透" },
	"hero_19": { "color": Color(1.0, 0.5, 0.6), "text": "烈焰" },
	"hero_20": { "color": Color(1.0, 0.8, 0.3), "text": "赏金" },
	"hero_21": { "color": Color(0.6, 0.7, 1.0), "text": "击退" },
	"hero_22": { "color": Color(0.95, 0.85, 0.4), "text": "圣光" },
	"hero_23": { "color": Color(0.85, 0.2, 0.25), "text": "复仇" },
	"hero_24": { "color": Color(0.9, 0.5, 0.2), "text": "冲锋" },
	"hero_25": { "color": Color(0.6, 0.6, 0.65), "text": "麻痹" },
	"hero_26": { "color": Color(0.5, 0.85, 1.0), "text": "冰冻" },
	"hero_27": { "color": Color(0.3, 0.3, 0.45), "text": "换位" },
	"hero_28": { "color": Color(0.75, 0.4, 0.95), "text": "变身" },
	"hero_29": { "color": Color(1.0, 0.75, 0.25), "text": "太阳斩" },
	"hero_30": { "color": Color(0.5, 0.35, 0.75), "text": "收割" },
	"hero_31": { "color": Color(0.35, 0.3, 0.55), "text": "末日" },
	"hero_32": { "color": Color(1.0, 0.55, 0.3), "text": "击退" },
	"hero_33": { "color": Color(0.45, 0.75, 0.4), "text": "召唤" },
	"hero_34": { "color": Color(0.55, 0.5, 0.75), "text": "沉默" },
	"hero_35": { "color": Color(1.0, 0.6, 0.15), "text": "爆破" },
	"hero_36": { "color": Color(0.5, 0.8, 0.95), "text": "置换" },
	"hero_37": { "color": Color(0.6, 0.85, 1.0), "text": "锤头" },
	"hero_38": { "color": Color(0.6, 0.9, 0.9), "text": "涌电" },
	"hero_39": { "color": Color(0.9, 0.4, 0.6), "text": "猎颅" },
	"hero_40": { "color": Color(0.95, 0.3, 0.25), "text": "扑街" },
	"hero_41": { "color": Color(0.9, 0.2, 0.3), "text": "血锁" },
	"hero_42": { "color": Color(1.0, 0.8, 0.3), "text": "金矿" },
	"hero_43": { "color": Color(0.5, 1.0, 0.8), "text": "风语" },
	"hero_44": { "color": Color(0.75, 0.6, 0.9), "text": "负墟" },
}

# 取某英雄的技能特效（颜色 + 文案），返回 {color, text}
func hero_fx(id: String) -> Dictionary:
	return HERO_FX.get(id, { "color": Color(1.0, 1.0, 1.0), "text": "" })
var heroes: Dictionary = {}
# id -> HeroDef（衍生物/召唤单位）
var summons: Dictionary = {}

func _ready() -> void:
	_load_heroes()

func _load_heroes() -> void:
	heroes.clear()
	summons.clear()
	var lines: PackedStringArray = []
	var f := FileAccess.open("res://角色列表.md", FileAccess.READ)
	if f == null:
		push_error("无法读取 res://角色列表.md")
		return
	lines = f.get_as_text().split("\n")
	f.close()

	# 表头列名 -> 下标（表格列可增改，按列名取值，避免列位置写死错位）
	var col := {}   # "名称"/"攻击力"/"HP"/"技能"/"等级"... -> 下标
	for line in lines:
		var t := line.strip_edges()
		if not t.begins_with("|"):
			continue
		var cells := t.split("|")
		if cells.size() < 2:
			continue
		if cells[1].strip_edges() == "No." or cells[1].strip_edges() == "No":
			for i in range(1, cells.size() - 1):
				var col_name_cell := cells[i].strip_edges()
				if col_name_cell != "":
					col[col_name_cell] = i
			break   # 表头行找到即停
	var col_grade: int = col.get("等级", 2)
	var col_no: int = col.get("No.", 1)
	var col_name: int = col.get("名称", 3)
	var col_atk: int = col.get("攻击力", 4)
	var col_hp: int = col.get("HP", 5)
	var col_trait: int = col.get("特性", -1)      # 新表：词条独立列（旧表无）
	var col_skill: int = col.get("技能", 6)        # 新表7/旧表6
	var col_syn: int = col.get("配合", 7)
	var col_eff: int = col.get("克制", col.get("有效行为", 8))   # 表头曾用"克制"，旧称"有效行为"
	var col_counter: int = col.get("被克制", 9)
	var col_pairs: int = col.get("协同英雄", 10)

	for line in lines:
		var t := line.strip_edges()
		if not t.begins_with("|"):
			continue
		var cells := t.split("|")
		if cells.size() < 7:
			continue
		var grade: String = cells[col_grade].strip_edges()
		if grade == "":
			continue
		# 跳过表头/分隔行（No 列非整数且非"-"）
		var no_text: String = cells[col_no].strip_edges()
		var is_summon := (grade == "衍生物")
		if not is_summon and (no_text == "" or not no_text.is_valid_int()):
			continue

		var h := HeroDef.new()
		if is_summon:
			h.id = "summon_skeleton"
		else:
			h.id = "hero_%02d" % no_text.to_int()
		h.display_name = cells[col_name].strip_edges()
		h.atk = cells[col_atk].strip_edges().to_int()
		h.max_hp = cells[col_hp].strip_edges().to_int()
		var cell_at := func(i: int) -> String:
			return cells[i].strip_edges() if (i >= 0 and i < cells.size()) else ""
		# 词条检测：新表"特性"列是独立词条区(在句号前)，直接查 contains；
		# 旧表词条嵌在技能正文尾部，用 _tail_has(最后'。'之后) 兼容。
		var trait_txt: String = (cell_at.call(col_trait)).replace("\\", "")
		var skill_raw: String = (cell_at.call(col_skill)).replace("\\", "")
		h.desc = skill_raw
		h.is_summon = is_summon

		# 解析三列（配合/克制/被克制）：文本存备注，并抽取其中的英雄名 -> 协同/克制 id
		h.synergy_note = cell_at.call(col_syn)
		h.effective_behavior = cell_at.call(col_eff)
		h.countered_by_note = cell_at.call(col_counter)
		h.sy_partners = _extract_ids(h.synergy_note) + _semantic_heroes(h.synergy_note)
		h.counters = _extract_ids(h.countered_by_note) + _semantic_heroes(h.countered_by_note)
		h.explicit_pairs = _extract_ids(cell_at.call(col_pairs))   # "协同英雄"列：直接点名的搭档

		var has_tag := func(tag: String) -> bool:
			return trait_txt.contains(tag) or _tail_has(skill_raw, tag)
		var has_ranged: bool = has_tag.call("<远程>")
		var has_taunt: bool = has_tag.call("<嘲讽>")
		var has_swift: bool = has_tag.call("<疾行>")
		var has_infiltrate: bool = has_tag.call("<渗透>")
		var has_logistics: bool = has_tag.call("<后勤>")
		var has_bench: bool = skill_raw.begins_with("<替补>") or has_tag.call("<替补>")

		h.rarity = _rarity_of(grade)
		h.attack_type = AttackType.RANGED if has_ranged else AttackType.MELEE
		# 基础移动力 2（疾行由生成时 +1），射程 1（远程 → 2）
		h.move_range = 2
		h.attack_range = 2 if has_ranged else 1
		h.skills = []
		if has_taunt:
			h.skills.append(Skill.TAUNT)
		if has_swift:
			h.skills.append(Skill.SWIFT)
		if has_infiltrate:
			h.skills.append(Skill.INFILTRATE)
		if has_logistics:
			h.skills.append(Skill.LOGISTICS)
		if has_bench:
			h.skills.append(Skill.BENCH)

		if is_summon:
			summons[h.id] = h
		else:
			heroes[h.id] = h

# 判断某关键词是否出现在技能文本"尾部标签区"（最后一个'。'之后）
# 正文中引用他人关键词（如"目标有<嘲讽>"）属于正文，不计为自身关键词。
func _tail_has(text: String, tag: String) -> bool:
	var tail := text
	var dot := text.rfind("。")
	if dot >= 0:
		tail = text.substr(dot + 1)
	return tail.contains(tag)

func _rarity_of(grade: String) -> int:
	match grade:
		"白":
			return Rarity.SILVER
		"金":
			return Rarity.GOLD
		"紫":
			return Rarity.MASTER
		"虹":
			return Rarity.LEGEND
	return Rarity.SILVER

func get_hero(id: String) -> HeroDef:
	return heroes.get(id, null)

func get_summon(id: String) -> HeroDef:
	return summons.get(id, null)

# —— 数值图标素材（爱心=血量、攻击=攻击力）——
# 素材是"图标+近白实底"：首次使用把白底抠成透明，同时记录主体包围盒（宽/高/中心）。
# 供 Unit 棋子与 HexCard 卡面按"主体宽度"等比放大，并把图标主体精确放到数字下方。
const ICON_HEART := "res://assets/美术资源/爱心.png"
const ICON_ATK := "res://assets/美术资源/攻击.png"
var _stat_icons: Dictionary = {}   # path -> {tex:Texture2D, w,h,cx,cy}
var _stat_bold_font: FontVariation = null   # 数值（攻击/血量）加粗字体，全部界面共享

# 数字/名字加粗：主题无粗体字体，用带中文的系统字体 + FontVariation 合成加粗（跨平台回退列表）
func stat_bold_font() -> FontVariation:
	if _stat_bold_font == null:
		var sys := SystemFont.new()
		sys.font_names = PackedStringArray(["Microsoft YaHei UI", "Microsoft YaHei", "PingFang SC", "Noto Sans CJK SC", "Source Han Sans SC", "sans-serif"])
		_stat_bold_font = FontVariation.new()
		_stat_bold_font.base_font = sys
		_stat_bold_font.variation_embolden = 0.9
	return _stat_bold_font

func stat_icon(path: String) -> Dictionary:
	if _stat_icons.has(path):
		return _stat_icons[path]
	var res := { "tex": null, "w": 0, "h": 0, "cx": 0, "cy": 0 }
	var tex := load(path) as Texture2D
	if tex != null:
		var img := tex.get_image()
		if img != null:
			img.convert(Image.FORMAT_RGBA8)
			var w := img.get_width()
			var h := img.get_height()
			var minx := w
			var miny := h
			var maxx := -1
			var maxy := -1
			for y in h:
				for x in w:
					var c := img.get_pixel(x, y)
					if c.r > 0.90 and c.g > 0.86 and c.b > 0.82:
						img.set_pixel(x, y, Color(0, 0, 0, 0))
					elif c.a > 0.5:
						if x < minx:
							minx = x
						if x > maxx:
							maxx = x
						if y < miny:
							miny = y
						if y > maxy:
							maxy = y
			res.tex = ImageTexture.create_from_image(img)
			if maxx >= minx and maxy >= miny:
				res.w = maxx - minx + 1
				res.h = maxy - miny + 1
				res.cx = (minx + maxx) / 2.0
				res.cy = (miny + maxy) / 2.0
		else:
			res.tex = tex
			res.w = tex.get_width()
			res.h = tex.get_height()
	_stat_icons[path] = res
	return res

# 词条 -> 中文解释（供选人/属性/工具提示共用）
func keyword_lines(skills: Array, attack_type: int) -> Array:
	var out: Array = []
	if attack_type == AttackType.RANGED:
		out.append("远程：射程为2，身边紧邻敌人时射程降为1、攻击降为1且技能效果失效")
	for s in skills:
		match s:
			Skill.SWIFT:
				out.append("疾行：移动力+1")
			Skill.TAUNT:
				out.append("嘲讽：攻击范围内有带【嘲讽】的敌人时，只能先攻击它")
			Skill.INFILTRATE:
				out.append("渗透：可穿过双方单位与障碍物（但不能落停在它们占据的格）")
			Skill.LOGISTICS:
				out.append("后勤：不能主动攻击，仅提供光环/支援效果")
			Skill.BENCH:
				out.append("替补：替补登场时触发一次技能效果")
	return out

# 技能/词条“自身标签”的中文短名（名字行挂的 [疾行 嘲讽 …]）
func hero_tag_text(def: HeroDef) -> String:
	var out := ""
	for s in def.skills:
		match s:
			Skill.TAUNT:
				out += "嘲讽 "
			Skill.SWIFT:
				out += "疾行 "
			Skill.INFILTRATE:
				out += "渗透 "
			Skill.LOGISTICS:
				out += "后勤 "
			Skill.BENCH:
				out += "替补 "
	if out != "":
		out = out.strip_edges()
	return out

# 技能原文里的“自身标签”只用于识别，展示前剔除：
# 最后一个“。”之后的 <远程>/<疾行>/<嘲讽>/<渗透>/<后勤>/<替补> 是本角色的关键词；
# 正文里出现的（如“目标有<嘲讽>”）是对他人关键词的引用，予以保留。
# <替补>：效果…… 的“<替补>：”前缀也一并去掉。
func clean_skill_desc(raw: String) -> String:
	if raw == "":
		return ""
	var dot := raw.rfind("。")
	var body := ""
	var tail := ""
	if dot >= 0:
		body = raw.substr(0, dot + 1)
		tail = raw.substr(dot + 1)
	else:
		# 只有标签没有技能正文（如“<远程>”），直接整段当尾部处理
		tail = raw
	# 尾部标签区里的自身关键词剔除（含整段只有标签的情况）
	for tag in ["<远程>", "<嘲讽>", "<疾行>", "<渗透>", "<后勤>", "<替补>"]:
		tail = tail.replace(tag, "")
	# <替补>：效果…… 的“<替补>：”前缀去掉
	if body.begins_with("<替补>"):
		body = body.trim_prefix("<替补>")
		body = body.trim_prefix("：")
		body = body.trim_prefix(":")
	var out := (body + tail).strip_edges()
	return out.replace("  ", " ")

# 技能正文中以 [方括号] 出现的状态词（对目标施加的减益/增益）-> 中文解释行。
# 与 keyword_lines 的"英雄自身关键词"互补：状态词是效果对象，不是英雄自带标签。
const STATUS_DESC := {
	"猛毒": "猛毒：任一回合开始时受1点伤害（圣盾可抵挡一次该伤害）",
	"重伤": "重伤：受到的伤害+1",
	"麻痹": "麻痹：攻击力-1",
	"冰冻": "冰冻：移动力-1",
	"沉默": "沉默：无法主动使用技能",
	"眩晕": "眩晕：无法移动与攻击",
	"圣盾": "圣盾：抵挡一次受到的伤害或异常状态",
	"附体": "附体（负面）：与施加者伤害绑定。施加者受到伤害时，目标受到同等伤害；目标方回合结束时解除（负墟免疫）",
}

# 从技能原文提取方括号状态词的解释行（按出现顺序、去重；未收录的词忽略）。
func desc_status_lines(raw: String) -> Array:
	var out: Array = []
	var text := clean_skill_desc(raw)
	var i := 0
	while i < text.length():
		var a := text.find("[", i)
		if a < 0:
			break
		var b := text.find("]", a + 1)
		if b < 0:
			break
		var status_word := text.substr(a + 1, b - a - 1)
		if STATUS_DESC.has(status_word) and not out.has(STATUS_DESC[status_word]):
			out.append(STATUS_DESC[status_word])
		i = b + 1
	return out

# 实际开局数值：注册表基础值 + 生成期加成（引擎在单位出生时叠加，属性表按实际值展示）。
# 疾行：移动+1；大骑士（hero_24 冲锋）：移动+6；血锁（hero_41 直线锁链）：射程+2。
func spawn_move(def: HeroDef) -> int:
	var m := def.move_range
	if def.skills.has(Skill.SWIFT):
		m += 1
	if def.id == "hero_24":
		m += 6
	return m

func spawn_attack_range(def: HeroDef) -> int:
	var r := def.attack_range
	if def.id == "hero_41":
		r += 2
	if def.id == "hero_45":
		r = 99   # 坠炮手：全场任意目标（弹道无视阻挡由 Unit/Battle 处理）
	return r

# 属性表内容分“显示区”：①名字+近/远程+词条标签 ②基础属性 ③“技能”+技能描述 ④词条解释。
# 各区由弹框负责用贴左短线分行；本函数只负责产出各区文本。
func hero_info_zones(def: HeroDef) -> Array[String]:
	var atk_type := "近战" if def.attack_type == AttackType.MELEE else "远程"
	var head := "%s  %s" % [def.display_name, atk_type]
	var tags := hero_tag_text(def)
	if tags != "":
		head += "　[%s]" % tags
	var zones: Array[String] = []
	zones.append(head)
	# 大骑士移动＝直线冲锋任意距离，按"无限"展示（实际可沿直线冲满棋盘）
	var move_txt := "移动 %d" % spawn_move(def)
	if def.id == "hero_24":
		move_txt = "移动 ∞"
	# 坠炮手射程=全场，按"∞"展示
	var range_n := spawn_attack_range(def)
	var range_txt := "射程 ∞" if def.id == "hero_45" else "射程 %d" % range_n
	zones.append("HP %d　攻击 %d　%s　%s" % [
		def.max_hp, def.atk, move_txt, range_txt])
	var desc := clean_skill_desc(def.desc)
	if desc != "":
		zones.append("技能\n%s" % desc)
	# 词条解释 = 自身关键词 + 技能正文里 [方括号] 状态词的解释（沉默/重伤/猛毒…）
	var lines := keyword_lines(def.skills, def.attack_type)
	lines.append_array(desc_status_lines(def.desc))
	if lines.size() > 0:
		zones.append("\n".join(lines))
	return zones

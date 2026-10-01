extends Node
## 英雄技能逐条对表：**裁判规则包里的每一位英雄** vs **我们本地英雄表**，把"数值 / 词条 / 技能描述"
## 三栏摆一起，差异直接点名。为什么要有它：桥只同步了"攻/血/速"这类静态数值，**技能行为**一直跑的是
## 我们引擎自己那套（`heroes/hero_XX_*.gd` + `BattleAI` 的模拟）—— 这条工具负责把"哪些英雄的
## 技能文字/数值跟裁判不一样"先列出来，再逐条判"是真差异还是只是措辞"。
##
## 起法：godot --headless --path <项目根> --scene res://arena/技能对表.tscn
## 输出：`arena/记录/技能对表.txt`（UTF-8）+ stdout 一行汇总。

class Stub:
	extends RefCounted
	func _log(m: String) -> void:
		print("SK|", m)

const REC := "res://arena/记录"


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	var rules := _load_rules()
	if rules.is_empty():
		print("SK|!! 读不到 arena/记录/规则包.json（引擎启动时会写一份）")
		get_tree().quit(1)
		return
	var bridge = load("res://arena/ArenaBridge.gd").new()
	bridge.setup(Stub.new(), rules, 3, 0, "ai", true)
	var kinds: Dictionary = bridge._kind2hero
	var lines: Array = []
	lines.append("规则版本 %s ｜ 英雄 %d 项 ｜ 能对上本地表的 %d 位" % [
		String(rules.get("rulesVersion", "?")), (rules.get("heroes", []) as Array).size(), kinds.size()])
	lines.append("")
	var n_num := 0
	var n_text := 0
	var n_feat := 0
	for h in rules.get("heroes", []):
		if not (h is Dictionary):
			continue
		var d: Dictionary = h
		var kind := int(d.get("kind", 0))
		if bool(d.get("isBarrier", false)):
			continue
		var nm := String(d.get("name", "?"))
		var hid := String(kinds.get(kind, ""))
		var local: DataRegistry.HeroDef = bridge._get_def(hid)
		var head := "【%s】kind=%d%s" % [nm, kind, ("" if hid != "" else "  ← 本地表里没有对应英雄")]
		lines.append(head)
		if local == null:
			lines.append("   裁判：%s" % String(d.get("desc", "")))
			lines.append("")
			continue
		# ① 数值
		var nums: Array = []
		var a_atk := int(d.get("attackPower", -1))
		if a_atk != int(local.atk):
			nums.append("攻 %d↔%d" % [a_atk, int(local.atk)])
		var a_hp := int(d.get("maxHealth", -1))
		if a_hp != int(local.max_hp):
			nums.append("血 %d↔%d" % [a_hp, int(local.max_hp)])
		var a_mv := int(d.get("mobility", -1))
		var l_mv := int(local.move_range) + (1 if (local.skills as Array).has(DataRegistry.Skill.SWIFT) else 0)
		if a_mv != l_mv:
			nums.append("速 %d↔%d" % [a_mv, l_mv])
		var a_type := String(d.get("attackType", ""))
		var l_range := int(DataRegistry.spawn_attack_range(local))
		var a_ranged := a_type == "range"
		var l_ranged := int(local.attack_type) == int(DataRegistry.AttackType.RANGED)
		if a_ranged != l_ranged:
			nums.append("远程 %s↔%s" % [a_type, "range" if l_ranged else "melee"])
		if a_type == "unable" and not (local.skills as Array).has(DataRegistry.Skill.LOGISTICS):
			nums.append("“不能主动攻击”↔本地没<后勤>")
		if String(d.get("defenseType", "")) == "taunt" and not (local.skills as Array).has(DataRegistry.Skill.TAUNT):
			nums.append("“嘲讽”↔本地没<嘲讽>")
		if bool(d.get("permeate", false)) and not (local.skills as Array).has(DataRegistry.Skill.INFILTRATE):
			nums.append("“渗透”↔本地没<渗透>")
		if bool(d.get("isSummon", false)) != bool(local.is_summon):
			nums.append("召唤物标记不一致")
		if l_range != 1 and l_range != 2 and l_range != 99:
			nums.append("本地射程 %d（裁判没给射程字段）" % l_range)
		if nums.is_empty():
			lines.append("   数值：一致")
		else:
			n_num += 1
			lines.append("   数值：**%s**" % "，".join(nums))
		# ② 词条（裁判 features vs 本地技能名）
		var feats: Array = d.get("features", [])
		if not feats.is_empty():
			n_feat += 1
			lines.append("   裁判词条：%s" % ", ".join(feats))
		# ③ 技能文字（最可能藏差异的地方：伤害数字、格数、持续到哪回合）
		var a_desc := _norm(String(d.get("desc", "")))
		var l_desc := _norm(String(local.desc))
		if a_desc == l_desc:
			lines.append("   技能文字：一致")
		else:
			n_text += 1
			lines.append("   技能文字：**不同**")
			lines.append("     裁判：%s" % a_desc)
			lines.append("     本地：%s" % l_desc)
		lines.append("")
	lines.append("—— 汇总：数值有差 %d 位｜技能文字有差 %d 位｜裁判带词条的 %d 位" % [n_num, n_text, n_feat])
	_write(lines)
	print("SK|汇总|数值差 %d｜文字差 %d｜带词条 %d" % [n_num, n_text, n_feat])
	print("SK|报告：arena/记录/技能对表.txt")
	print("SK|END")
	get_tree().quit(0)


## 去掉空白/引号差异，只比内容
func _norm(s: String) -> String:
	var t := s.replace("\\n", " ").replace("\n", " ").replace("\r", " ")
	while t.find("  ") >= 0:
		t = t.replace("  ", " ")
	return t.strip_edges()


func _load_rules() -> Dictionary:
	var p := "%s/规则包.json" % REC
	if not FileAccess.file_exists(p):
		return {}
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		return {}
	var o = JSON.parse_string(f.get_as_text())
	f.close()
	return o if o is Dictionary else {}


func _write(lines: Array) -> void:
	var f := FileAccess.open("%s/技能对表.txt" % REC, FileAccess.WRITE)
	if f == null:
		return
	f.store_string("\n".join(lines))
	f.close()

extends Node
## 临时探针：比较"单体评分"公式变体对阵容构成的影响。
func _ready() -> void:
	_run.call_deferred()

func score_of(id: String, hp_w: float, atk_w: float, ranged_w: float, taunt_w: float) -> float:
	var def: DataRegistry.HeroDef = DataRegistry.heroes[id]
	var s := float(def.atk) * atk_w + float(def.max_hp) * hp_w
	if def.attack_type == DataRegistry.AttackType.RANGED:
		s += ranged_w
	for sk in def.skills:
		match sk:
			DataRegistry.Skill.TAUNT:
				s += taunt_w
			DataRegistry.Skill.SWIFT:
				s += 1.0
			DataRegistry.Skill.INFILTRATE:
				s += 1.5
			DataRegistry.Skill.LOGISTICS:
				s += 1.0
	return s

func _dump(title: String, hp_w: float, atk_w: float, ranged_w: float, taunt_w: float) -> void:
	var rows: Array = []
	for id in DataRegistry.heroes.keys():
		var def: DataRegistry.HeroDef = DataRegistry.heroes[id]
		var is_tank := def.skills.has(DataRegistry.Skill.TAUNT)
		rows.append({ "n": def.display_name, "s": score_of(id, hp_w, atk_w, ranged_w, taunt_w), "tank": is_tank })
	rows.sort_custom(func(a, b): return a["s"] > b["s"])
	var top := rows.slice(0, 12)
	var tanks := 0
	for r in top:
		if r["tank"]:
			tanks += 1
	print(">> %s TOP12(坦克%d/12): %s" % [title, tanks, "、".join(top.map(func(r): return "%s(%.1f)" % [r["n"], float(r["s"])]))])

func _run() -> void:
	_dump("现公式(atk1.8+hp1.0+坦2)", 1.0, 1.8, 2.0, 2.0)
	_dump("变体1(atk1.8+hp0.5+坦1)", 0.5, 1.8, 2.0, 1.0)
	_dump("变体2(atk2.2+hp0.45+坦0.8)", 0.45, 2.2, 2.5, 0.8)
	print("FINAL PASS")
	get_tree().quit(0)

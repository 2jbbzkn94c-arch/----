extends Node
## 临时探针：列出全部英雄单体得分（便于人工评审）。
func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	var rows: Array = []
	for id in DataRegistry.heroes.keys():
		var def: DataRegistry.HeroDef = DataRegistry.heroes[id]
		rows.append({
			"n": def.display_name,
			"id": id,
			"rar": def.rarity,
			"atk": def.atk,
			"hp": def.max_hp,
			"role": DataRegistry.hero_role_name(id),
			"s": DataRegistry.hero_strength(id),
		})
	rows.sort_custom(func(a, b): return a["s"] > b["s"])
	for r in rows:
		print(">> %-4s %-5s %-2d/%-3d %s %6.1f" % [r["id"], r["n"], r["atk"], r["hp"], r["role"], float(r["s"])])
	print("FINAL DONE")
	get_tree().quit(0)

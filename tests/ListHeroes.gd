extends Node
## 列出所有英雄 id/名称/配合/有效行为/被克制，用于建立名称->ID映射。
## 运行：godot --headless --scene res://tests/ListHeroes.tscn
func _ready() -> void:
	for id in DataRegistry.heroes.keys():
		var d = DataRegistry.heroes[id]
		print("%s | %s" % [id, d.display_name])
	# 验证三列解析：synergy_note / counters 抽出
	print("--- 三列解析验证 ---")
	for id in ["hero_31", "hero_30", "hero_40", "hero_19", "hero_33", "hero_41", "hero_34", "hero_03"]:
		var d2 = DataRegistry.heroes[id]
		print("%s(%s): sy_note='%s' 朋友=%s 克制=%s" % [id, d2.display_name, d2.synergy_note, str(d2.sy_partners), str(d2.counters)])
	# counter_bonus: 沉默术士(hero_34)克制依赖技能的英雄文本里没明确ID，测一个明确关系
	# 血锁 hero_41 配合死神(hero_30) -> hero_41.sy_partners 应含 hero_30
	var blood = DataRegistry.heroes["hero_41"]
	print("血锁 sy_partners=", blood.sy_partners, " synergy_bonus(blood,死神)=", DataRegistry.synergy_bonus("hero_41", "hero_30"))
	# 战锤(hero_25)克制毒蛇淑女(hero_03)：counter_bonus(hero_25, hero_03) 应>0
	print("T1 战锤克毒蛇: counter_bonus=", DataRegistry.counter_bonus("hero_25", "hero_03"), " => PASS" if DataRegistry.counter_bonus("hero_25", "hero_03") > 0.0 else " => FAIL")
	get_tree().quit()

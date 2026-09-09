class_name HeroRegistry
extends RefCounted
## 把 hero_id 映射到对应英雄脚本（res://heroes/hero_XX.gd），并工厂化创建实例。
## 未登记或衍生物返回一个 HeroBase 新实例（覆盖不了任何技能＝无技能）。

const _SCRIPTS := {
	"hero_01": "res://heroes/hero_01_伐木工.gd",
	"hero_02": "res://heroes/hero_02_圣诞老人.gd",
	"hero_03": "res://heroes/hero_03_毒蛇淑女.gd",
	"hero_04": "res://heroes/hero_04_鼠队长.gd",
	"hero_05": "res://heroes/hero_05_傀儡师.gd",
	"hero_06": "res://heroes/hero_06_医护兵.gd",
	"hero_07": "res://heroes/hero_07_影丸.gd",
	"hero_08": "res://heroes/hero_08_德鲁伊.gd",
	"hero_09": "res://heroes/hero_09_火枪手.gd",
	"hero_10": "res://heroes/hero_10_白游侠.gd",
	"hero_11": "res://heroes/hero_11_塔盾.gd",
	"hero_12": "res://heroes/hero_12_巨剑.gd",
	"hero_13": "res://heroes/hero_13_独脚龟.gd",
	"hero_14": "res://heroes/hero_14_古拉博士.gd",
	"hero_15": "res://heroes/hero_15_小阴影.gd",
	"hero_16": "res://heroes/hero_16_波盾.gd",
	"hero_17": "res://heroes/hero_17_烛火.gd",
	"hero_18": "res://heroes/hero_18_长剑.gd",
	"hero_19": "res://heroes/hero_19_烈焰祭司.gd",
	"hero_20": "res://heroes/hero_20_赏金猎人.gd",
	"hero_21": "res://heroes/hero_21_超新星.gd",
	"hero_22": "res://heroes/hero_22_圣光.gd",
	"hero_23": "res://heroes/hero_23_复仇者.gd",
	"hero_24": "res://heroes/hero_24_大骑士.gd",
	"hero_25": "res://heroes/hero_25_战锤.gd",
	"hero_26": "res://heroes/hero_26_雪拳.gd",
	"hero_27": "res://heroes/hero_27_暗域.gd",
	"hero_28": "res://heroes/hero_28_古灵精怪.gd",
	"hero_29": "res://heroes/hero_29_太阳斩.gd",
	"hero_30": "res://heroes/hero_30_嬉皮死神.gd",
	"hero_31": "res://heroes/hero_31_末日.gd",
	"hero_32": "res://heroes/hero_32_长角.gd",
	"hero_33": "res://heroes/hero_33_死灵法师.gd",
	"hero_34": "res://heroes/hero_34_沉默术士.gd",
	"hero_35": "res://heroes/hero_35_炸弹人.gd",
	"hero_36": "res://heroes/hero_36_梅林.gd",
	"hero_37": "res://heroes/hero_37_锤头鲨.gd",
	"hero_38": "res://heroes/hero_38_涌电技师.gd",
	"hero_39": "res://heroes/hero_39_猎颅者.gd",
	"hero_40": "res://heroes/hero_40_红帽.gd",
	"hero_41": "res://heroes/hero_41_血锁.gd",
	"hero_42": "res://heroes/hero_42_黄金矿工.gd",
	"hero_43": "res://heroes/hero_43_风语者.gd",
	"hero_44": "res://heroes/hero_44_负墟.gd",
	"hero_45": "res://heroes/hero_45_坠炮手.gd",
	"hero_46": "res://heroes/hero_46_宿魂.gd",
	"hero_47": "res://heroes/hero_47_共鸣者.gd",
	"hero_48": "res://heroes/hero_48_装甲堡垒.gd",
	"hero_49": "res://heroes/hero_49_荆棘树人.gd",
}

## 创建某英雄的行为实例（不含 setup）。找不到脚本或衍生物时返回 HeroBase 空实例。
static func create(hero_id: String) -> HeroBase:
	var path: String = _SCRIPTS.get(hero_id, "")
	if path == "":
		return HeroBase.new()
	var script: GDScript = load(path)
	if script == null:
		return HeroBase.new()
	var inst: HeroBase = script.new()
	return inst

extends HeroBase
## 坠炮手：可攻击全场的任意目标，弹道无视障碍/单位/墓碑阻挡（被贴身时仍受远程限制：
## 射程压 1、基础攻击压 1，且受嘲讽吸引——见 Battle 的射程/目标判定）。
class_name HeroMortar

## 身份类状态位：全场射程(99)在 Unit 生成时置好；"无视阻挡"这个标志位需在变身后继续维持
func refresh_identity() -> void:
	super.refresh_identity()
	unit.los_ignore = true
	unit.attack_range = 99

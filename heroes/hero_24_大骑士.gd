extends HeroBase
## 大骑士：你的移动改为沿直线方向冲锋任意距离，然后攻击力上升等量于本次移动距离，直到回合结束。
class_name HeroCharger

func on_spawn() -> void:
	# 冲锋任意距离（近似大幅提升移动力）；冲锋加成/直线在移动逻辑中结算
	unit.move_range += 6

extends HeroBase
## 太阳斩：替补登场时攻击力+3。每次攻击或反击后攻击力-1，直到恢复正常攻击力。
class_name HeroSunsaber

func on_enter() -> void:
	fx()
	unit.sun_bonus = 3
	unit.refresh_stats()

func on_after_attack() -> void:
	if unit.sun_bonus > 0:
		unit.sun_bonus -= 1
		unit.refresh_stats()

func on_after_counter() -> void:
	if unit.sun_bonus > 0:
		unit.sun_bonus -= 1
		unit.refresh_stats()

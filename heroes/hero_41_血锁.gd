extends HeroBase
## 血锁：己方回合内，你的射程+2，但只能沿直线攻击（仍视为近战攻击）。攻击时将敌人拉到面前一格。
class_name HeroBloodlock

func on_spawn() -> void:
	unit.attack_range += 2
	unit.branch_override = true

# 每回合结束 _clear_statuses 会清掉 branch_override，故本回合开始时必须重新激活，
# 否则血锁从第二回合起不再受限（能攻击直线外目标）。
func on_turn_start() -> bool:
	unit.branch_override = true
	return false

func on_attack(target: Unit) -> void:
	if target and target.alive:
		battle._pull_to(unit, target)   # 链子勾拉演出在 _pull_to 内播放（唯一特效，不与通用光环叠加）

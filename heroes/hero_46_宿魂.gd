extends HeroBase
## 宿魂（hero_46）：攻击后，令敌人获得[附体]——施加者(宿魂)受伤时，附体目标受到同等伤害。
## 附体不叠加；目标方回合结束时解除。绑定与镜像结算在 Battle._possess_attach/_possess_mirror。
class_name HeroSoul

func on_attack(target: Unit) -> void:
	if target == null or not target.alive:
		return
	battle._possess_attach(unit, target)

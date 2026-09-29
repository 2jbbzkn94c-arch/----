extends HeroBase
## 宿魂（hero_46）：攻击后，令敌人获得[附体]——施加者(宿魂)受伤时，附体目标受到同等伤害。
## 附体不叠加；目标方回合结束时解除。绑定与镜像结算在 Battle._possess_attach/_possess_mirror。
class_name HeroSoul

func on_attack(target: Unit) -> void:
	if target == null or not target.alive:
		return
	battle._possess_attach(unit, target)

## 【2026-09-30·用户报「怎么宿魂打有圣盾的单位也能附体」】[附体] 是"命中附加的负面状态"
##   ⇒ 与毒蛇淑女[猛毒]/战锤麻痹/沉默术士同一类：认这一项，`Battle._apply_attack()` 才会在
##   "这一击被[圣盾]整段挡下 / 一点血都没打掉（[坚固]减到 0）"时置 `Unit._shield_block_status`；
##   `Battle._possess_attach()` 读那个标记 ⇒ 那两种情况下**不挂[附体]、不建魂线绑定**。
##   （宿魂的普攻伤害本身仍由 Battle 结算：打盾时盾照旧被消耗掉。）
func applies_status_on_hit() -> bool:
	return true

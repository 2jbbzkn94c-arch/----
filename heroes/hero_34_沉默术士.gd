extends HeroBase
## 沉默术士：远程攻击后，目标获得[沉默]。
## 目标被这一击打死时同样要挂上[沉默]（见 on_attack_dead）。
class_name HeroSilencer

func applies_status_on_hit() -> bool:
	return true

func on_attack(target: Unit) -> void:
	if target == null or not is_instance_valid(target) or not target.alive:
		return
	_silence(target)

## 目标被这一击打死：命中瞬间仍要挂上[沉默]。
## 为什么必须补这一钩子：单位阵亡的收尾（Unit.die 的淡出 tween → died 信号 →
## Battle._on_unit_died → 阵亡技）晚于本次攻击结算，若此处不施加，红帽扑街自爆
## 之类"被沉默期间不应触发"的阵亡技就会照常生效。
## 目标尸体对象此时仍有效（阵亡技就在它身上判定状态），故状态照常挂得住。
func on_attack_dead(target: Unit) -> void:
	if target == null or not is_instance_valid(target):
		return
	_silence(target)

func _silence(target: Unit) -> void:
	if not target._shield_block_status:   # 这一击一点血都没打掉（不算打中）：不播命中/机制演出
		fx()
		fx_on_target(target)   # 目标已亡时自身会跳过（HeroBase.fx_on_target 内判 alive）
	battle._add_status_msg(target, StatusDB.SILENCE)

extends HeroBase
## 古灵精怪：对方回合结束时，随机变为己方队伍中的一名其他角色，暂时获得其所有技能直到下次变化为止。
class_name HeroGremlin

func on_turn_start() -> bool:
	battle._transform(unit)
	return true

## 变回自身时不再补触发一次回合开始技（否则会立刻再变身一次，反复横跳）。
## 正常不会发生（变身的候选已排除自身），这里是防御。
func wants_turn_start_on_transform() -> bool:
	return false

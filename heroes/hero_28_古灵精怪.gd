extends HeroBase
## 古灵精怪：对方回合结束时，随机变为己方队伍中的一名其他角色，暂时获得其所有技能直到下次变化为止。
class_name HeroGremlin

func on_turn_start() -> bool:
	# 【2026-09-28·用户报「古灵精怪变身的技能音效怎么变成被变身那个人的」】
	#   `play_skill_sfx()` 是按 `unit.display_name` 查 `HERO_SFX` 的，而 `_transform()` 里有一行
	#   `u.display_name = def.display_name`（换成变身后英雄的名字）⇒ 放在它**后面**就会查到
	#   那个人的技能音效。必须在变身**之前**播 —— 那会儿名字还是"古灵精怪"。
	play_skill_sfx()   # 变身 = 技能发动
	battle._transform(unit)
	return true

## 变回自身时不再补触发一次回合开始技（否则会立刻再变身一次，反复横跳）。
## 正常不会发生（变身的候选已排除自身），这里是防御。
func wants_turn_start_on_transform() -> bool:
	return false

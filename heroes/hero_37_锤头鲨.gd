extends HeroBase
## 锤头鲨：**我方回合**内，每当敌人受到一次伤害（AOE 对每个受击目标各算一次），你的攻击力 +1。
## 这份加成撑过整个**对方回合**（对方回合里挨打/反击都还带着它），到**对方回合结束**才消失。
class_name HeroHammerhead

## 本轮累计的加成（自己记一份账，数值同时写进 atk_buff 参与面板与伤害结算）。
## 为什么要自己记：引擎在**我方回合结束**时会把全队 atk_buff 统一清零（Battle._clear_statuses），
## 而本加成要活到"对方回合结束"。所以清零之后在 refresh_identity() 里把自己这份补回去，
## 到本方下个回合开始时（on_own_turn_start_always）再精确减掉自己这份 —— 只动自己的账，
## 不碰烈焰祭司等别人临时加到 atk_buff 上的加成。
var bonus := 0

func on_someone_damaged(target: Unit, _amount: int) -> void:
	if target == null or not target.alive:
		return
	if target.faction == unit.faction:
		return   # 只对敌人受到的伤害计数
	if target._was_counter_damage:
		return   # 反击伤害不触发（新规则下敌方反击发生在其回合，本就被下面的回合判定拦掉，这里再兜一层）
	# 只在**我方回合**累积：对方回合里敌人挨打（我方反击/猛毒/烧血等）都不加攻
	if battle.side_faction(GameState.active_side) != unit.faction:
		return
	bonus += 1
	unit.atk_buff += 1
	unit.refresh_stats()

## 引擎清完临时状态之后（我方回合末清理 / 变身）调用：把"要撑过对方回合"的这份加成补回去。
func refresh_identity() -> void:
	super.refresh_identity()
	if bonus > 0:
		unit.atk_buff += bonus

## 我方回合开始 = 上一轮的加成到期（对方回合已经结束）：只减掉自己这份。
## 挂"不受沉默影响"的钩子而不是 on_turn_start：被沉默时回合开始技不触发，
## 挂在那儿会让上一轮的加成多留一整轮（对方回合结束该消失的没消失）。
func on_own_turn_start_always() -> void:
	if bonus > 0:
		unit.atk_buff = maxi(unit.atk_buff - bonus, 0)
		bonus = 0
		unit.refresh_stats()

extends HeroBase
## 炸弹人：移动后，在自己周围的一块空地放置一颗炸弹（炸弹人以外的角色停留在该格会引爆，受到5点伤害）。
## 单机：我方英雄移动后进入"选格"由玩家自己挑位置；敌方 AI 自动放在正前方空地。
## 联机：双方都是真人——只在本端（_my_faction）自己的单位移动后进入选格；
## 对端/回放端执行同一条 move 指令时不处理炸弹（等后续 bomb 指令广播后再统一放置），
## 避免把对方当成 AI 自动放、或两边各自乱放。
class_name HeroBomber

func on_move() -> void:
	fx()
	if GameState.is_online:
		# 联机：只有"本端真人所属阵营"的单位移动后才进入选格
		if unit.faction != battle._my_faction():
			return
		battle._pending_bomb_unit = unit
		return
	if unit.faction == DataRegistry.Faction.PLAYER:
		# 单机我方：进入选格状态，自行选择周围空地放炸弹
		battle._pending_bomb_unit = unit
	else:
		# 单机敌方 AI：自动放正前方空地
		var front: Vector2i = battle._front_cell(unit)
		if front != unit.cell and battle.grid.in_bounds(front) and not battle.occupancy.has(front) and not battle.bombs.has(front):
			battle.bombs[front] = true
			if battle.board_view:
				battle.board_view.bombs = battle.bombs
				battle.board_view.queue_redraw()
			battle.log_message.emit("%s 在 %s 放置了炸弹。" % [unit.display_name, str(front)])

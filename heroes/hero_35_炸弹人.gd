extends HeroBase
## 炸弹人：移动后，在自己周围的一块空地放置一颗炸弹（不免疫炸弹的角色停留在该格会引爆，受到 5 点伤害）。
##
## 本脚本负责**全部炸弹人规则**：能不能放、能放哪几格、自己免疫、放完的日志与演出。
## Battle 只保留"雷已经落在盘面上之后"的地形规则（踩到引爆、扣血、渲染、AI 避让），
## 并提供原语：bomb_cell_ok(cell) / place_bomb(cell, unit) / request_bomb_place(unit)。
##
## 单机：我方英雄移动后进入"选格"由玩家自己挑位置；敌方 AI 自动放在正前方空地。
## 联机：双方都是真人——只在本端（_my_faction）自己的单位移动后进入选格；
## 对端/回放端执行同一条 move 指令时不处理炸弹（等后续 bomb 指令广播后再统一放置），
## 避免把对方当成 AI 自动放、或两边各自乱放。
class_name HeroBomber

## 有放雷能力（联机 bomb 指令的合法性预检）。
## 被[沉默]/[眩晕]时技能失效（语义见 Unit.skill_allowed()），不再具备放雷能力。
## 保险：放雷窗口本来就只由已被闸的 on_move() 打开，这里是第二道——
## 联机 bomb 指令（Battle 的指令重演）与落点复检都会问本钩子，多这一道可防"其它入口"绕过。
func can_place_bomb() -> bool:
	if unit == null or not is_instance_valid(unit):
		return false
	return unit.skill_allowed()

## 自己放的雷不炸自己：经过/停在炸弹格都安然无恙
func immune_to_bombs() -> bool:
	return true

## 可放炸弹的空地：自己周围 6 格里**地形合法**的格。
## 地形合法性交给 Battle 的 bomb_cell_ok（界内、无单位/障碍/已有炸弹/增益道具/金矿），
## 保证与 UI 橙色高亮、落点复检、联机回放用的是同一套规则。
## 被[沉默]/[眩晕]时同样失效（返回空数组）：Battle 的落点复检 _apply_bomb_placement
## 会因此拒绝该次放置——两端单位状态一致，故判定在主机与回放端也一致，不会两端不同步。
func bomb_place_cells() -> Array:
	var out: Array = []
	if unit == null or not is_instance_valid(unit) or not unit.alive:
		return out
	if not unit.skill_allowed():
		return out
	for n in battle.grid.neighbors(unit.cell):
		if battle.bomb_cell_ok(n):
			out.append(n)
	return out

func on_move() -> void:
	fx()
	if GameState.is_online:
		# 联机：只有"本端真人所属阵营"的单位移动后才进入选格
		if unit.faction != battle._my_faction():
			return
		battle.request_bomb_place(unit)
		return
	if unit.faction == DataRegistry.Faction.PLAYER:
		# 单机我方：进入选格状态，自行选择周围空地放炸弹
		battle.request_bomb_place(unit)
		return
	# 单机敌方 AI：自动放正前方（朝对手底线方向）那块空地
	var cells := bomb_place_cells()
	if cells.size() == 0:
		return   # 周围没有空地：本回合不放
	battle.place_bomb(_frontest(cells), unit)

## 从可放格里挑"最靠对手底线"的那一格（玩家往上打、敌方往下打）。
## 只在这批已通过地形校验的格里挑，避免旧实现"只看有没有单位/炸弹"而把雷放到障碍或道具上。
func _frontest(cells: Array) -> Vector2i:
	var best: Vector2i = cells[0]
	var best_d := INF
	for n in cells:
		var d: float = battle.grid.cell_to_world(n).y
		if unit.faction != DataRegistry.Faction.PLAYER:
			d = -d   # 敌方从上方进攻：正前方朝下
		if d < best_d:
			best_d = d
			best = n
	return best

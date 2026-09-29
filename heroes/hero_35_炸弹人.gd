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
	# 【2026-09-28·用户问「炸弹人放炸弹是不是没音效」】技能音效**不在这里播**了：这一行是"移动结束、
	#   刚进入选格"，雷还没落地 ⇒ 听着像放下时没声音。改由 `Battle.place_bomb()` 在雷真正写进盘面时播
	#   （见那里的注释），与黄金矿工"真的丢下矿才响"同一口径，且玩家点格 / 敌方 AI / 联机 / 回放四条路径各响一次。
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
	# 单机敌方 AI：按**价值**挑一格放（2026-09-29·用户问「炸弹放哪有没有说法／和血锁没配合」）
	var cells := bomb_place_cells()
	if cells.size() == 0:
		return   # 周围没有空地：本回合不放
	battle.place_bomb(_best_bomb_cell(cells), unit)

## ---- AI 放雷的价值（**必须与 `src/BattleAI.gd` 里 `hero_35` 那段复刻同源**：改一边就得改两边）----
## 2026-09-29·用户要求「给雷按价值选格」：原来写死的 `_frontest()`（只看"离对手底线最近的空地"）
## 完全不看局面 ⇒ 血锁把人拉过来也踩不到雷、雷也很少落在敌人真会走的地方。现在按三项加权：
##   ① **踩得到谁**：敌人下回合**走得到**这一格 ⇒ 可能落停引爆（真实 5 点）⇒ 按"能炸掉的血"计
##      （`min(其血, 5)`，所以炸残血比蹭坦克值钱）；
##   ② **卡口/经过量**：走得到这一格**或其邻格**的敌人个数 ⇒ 这张格在它们通路上的程度；
##   ③ **血锁配合**：我方有活着且技能没被关掉的 `hero_41` 时，落在**它的邻格**上加权
##      （`Battle._pull_to()` 把目标拉到血锁邻格 ⇒ 拉过来正好踩雷）。
## 平手时仍按下一条 `_frontest()` 的"更靠对手底线"挑（行为连续、不抖）。
## ⚠️ 两侧的"走得到"各用现成尺子（真实 = `grid.distance` 六边形距离 · 模拟 = `walk_dist` 路网步数）——
##    只在 6 个候选格里挑一个，量级差异不会翻盘；要严格同源得把 Battle 的路网也搬进来（另说）。
const BOMB_DMG_REF := 5.0      ## 踩雷伤害（与 `Battle.BOMB_DAMAGE` 对齐，只作价值量纲）
const CHOKE_W := 1.0           ## ② 每个"会经过的敌人"值多少
const PULL_BONUS := 8.0        ## ③ 血锁邻格（拉人落点）额外加权

func _best_bomb_cell(cells: Array) -> Vector2i:
	var pull_ally: Unit = _pull_ally()
	var best: Vector2i = _frontest(cells)      # 兜底 / 平手基准 = 旧口径
	var best_s := -INF
	var best_front := INF
	for c in cells:
		var s := _bomb_cell_score(c, pull_ally)
		var front := _front_metric(c)
		# 分高的赢；**同分时选"更靠对手底线"的那格**（与旧口径连续、结果确定不抖）
		if s > best_s or (is_equal_approx(s, best_s) and front < best_front):
			best_s = s
			best_front = front
			best = c
	return best

## 旧的"离对手底线多近"度量（越小越靠前）——现在只当**同分裁决**用
func _front_metric(c: Vector2i) -> float:
	var d: float = battle.grid.cell_to_world(c).y
	return d if unit.faction == DataRegistry.Faction.PLAYER else -d

func _bomb_cell_score(cell: Vector2i, pull_ally: Unit) -> float:
	var s := 0.0
	for e in battle.units:
		if e == null or not is_instance_valid(e) or not e.alive:
			continue
		if e.faction == unit.faction:
			continue
		if battle._hero(e).immune_to_bombs():
			continue                           # 炸弹人自己免疫：放它脚下不算价值
		var d: int = battle.grid.distance(e.cell, cell)
		var reach: int = e.effective_move()
		if d <= reach:
			s += minf(float(e.hp), BOMB_DMG_REF)          # ① 它会踩：按这一炸能打掉的血计
		if d <= reach + 1:
			s += CHOKE_W                                   # ② 从旁边过 / 走向这里 = 通路
	if pull_ally != null and battle.grid.distance(pull_ally.cell, cell) == 1:
		s += PULL_BONUS                                    # ③ 血锁一拉就把它按到雷上
	return s

## 我方（与炸弹人同阵营）活着、且技能没被关掉的血锁；没有就返回 null
func _pull_ally() -> Unit:
	for u in battle.units:
		if u == null or not is_instance_valid(u) or not u.alive:
			continue
		if u.faction == unit.faction and u.hero_id == "hero_41" and u.skill_allowed():
			return u
	return null

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

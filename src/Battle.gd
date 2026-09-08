class_name Battle
extends Node2D
## 战斗主控制器。承载棋盘、单位、回合状态机、输入规则、简AI 与胜负判定
signal log_message(text: String)
signal action_info(text: String)        # HUD 侧信息条
signal highlight_changed                 # 高亮状态变化（HUD 可重绘提示）
signal match_result(win: bool)           # 对局结算（true=玩家胜利
signal sub_select_requested              # 触发替补选择（HUD 弹列表）
signal sub_placed                        # 替补成功落位（HUD 可关闭替补面板）
signal action_finished                   # 某单位一招（移动/攻击）动画完全结束后发出（敌方回放等待用
signal team_updated                      # 英雄阵容变化（上替补/变身/阵亡）——HUD 刷新下方队伍展示
signal enemy_turn_waiting                # 联机：敌方回合已开始，等待对端真人发行动指
signal peer_message(text: String)        # 联机:收到对端快捷喊话(顶栏下方弹气泡)
enum State { IDLE, PLAYER_INPUT, ANIMATING, ENEMY_TURN, DEPLOY, PLACE_DEPLOY, SUBSTITUTING, PLACE_SUB, PLACE_BOMB, ARENA_DRAFT, ENDED }

# 远程攻击的投掷物：飞向目标后命中
class Projectile:
	extends Node2D
	var color := Color(1.0, 0.78, 0.25)
	var radius := 7.0

	func _draw() -> void:
		# 防护：节点变换出现非有限值（NaN）时三角剖分会失败，直接跳过绘制
		if not (is_finite(position.x) and is_finite(position.y) and is_finite(rotation)):
			return
		# 外发
		draw_circle(Vector2.ZERO, radius * 2.0, Color(1.0, 0.72, 0.22, 0.18))
		# 拖尾（朝 -X 方向，节点朝向目标后自然形成彗星尾）
		var tail := PackedVector2Array([
			Vector2(-radius * 0.8, -radius * 0.5),
			Vector2(-radius * 4.2, 0.0),
			Vector2(-radius * 0.8, radius * 0.5),
		])
		draw_colored_polygon(tail, Color(1.0, 0.68, 0.18, 0.6))
		# 弹体
		draw_circle(Vector2.ZERO, radius, color)
		draw_arc(Vector2.ZERO, radius, 0.0, TAU, 40, Color(0.55, 0.32, 0.05), 2.0, true)
		draw_circle(Vector2.ZERO, radius * 0.5, Color(1.0, 0.97, 0.82))

# 长剑的剑气：一道弧形刃光沿直线飞出
class SwordQi:
	extends Node2D

	func _draw() -> void:
		# 防护：节点变换出现非有限值（NaN）时三角剖分会失败，直接跳过绘制
		if not (is_finite(position.x) and is_finite(position.y) and is_finite(rotation)):
			return
		# 弧形剑气（朝 +X 方向，节点旋转后即随直线飞出
		var blade := PackedVector2Array([
			Vector2(0, -8),
			Vector2(28, -5),
			Vector2(50, 0),
			Vector2(28, 5),
			Vector2(0, 8),
			Vector2(10, 0),
		])
		if _poly_ok(blade):
			draw_colored_polygon(blade, Color(0.65, 0.95, 1.0, 0.85))
		# 亮芯
		draw_polyline(PackedVector2Array([Vector2(-4, 0), Vector2(46, 0)]), Color(1.0, 1.0, 0.95, 0.95), 2.0, true)
		# 光晕
		draw_circle(Vector2(24, 0), 22, Color(0.6, 0.9, 1.0, 0.12))

	# 多边形可安全绘制？（顶点有限且能三角剖分，避免 C++ 层 triangulation failed 刷屏/中断）
	func _poly_ok(poly: PackedVector2Array) -> bool:
		for v in poly:
			if not (is_finite(v.x) and is_finite(v.y)):
				return false
		return Geometry2D.triangulate_polygon(poly).size() > 0

# 障碍受击冲击波：白色扩散圆环（障碍物被攻击时的命中演出）
class RingFlash:
	extends Node2D
	var color := Color(1.0, 0.95, 0.8, 0.9)

	func _draw() -> void:
		draw_arc(Vector2.ZERO, 22.0, 0.0, TAU, 32, color, 5.0)
		draw_circle(Vector2.ZERO, 10.0, Color(1.0, 0.97, 0.9, 0.55))

# 嬉皮死神的镰刀刃光：一道大而弯的紫黑色月牙刀刃，向目标横扫收割
class ScytheBlade:
	extends Node2D

	func _draw() -> void:
		# 防护：节点变换出现非有限值（NaN）时三角剖分会失败，直接跳过绘制
		if not (is_finite(position.x) and is_finite(position.y) and is_finite(rotation)):
			return
		# 弯月镰刀刃（+X，外侧长、内侧短，弧刃更弯更大）
		var blade := PackedVector2Array([
			Vector2(0, 3), Vector2(30, -22), Vector2(64, -16), Vector2(84, 0),
			Vector2(64, 16), Vector2(30, 22), Vector2(0, -3),
		])
		if _poly_ok(blade):
			draw_colored_polygon(blade, Color(0.4, 0.12, 0.55, 0.95))
		# 刃口亮紫弧线（刃尖亮、往刃柄渐暗
		draw_polyline(PackedVector2Array([Vector2(4, 0), Vector2(80, 0)]), Color(1.0, 0.6, 1.0, 0.98), 3.0, true)
		# 紫色拖尾刃气（内侧一束流光的弧；末点不再重复首点，避免退化多边形
		var wisp := PackedVector2Array([
			Vector2(10, 0), Vector2(46, -14), Vector2(76, -6), Vector2(46, 14),
		])
		if _poly_ok(wisp):
			draw_colored_polygon(wisp, Color(0.7, 0.35, 0.9, 0.35))
		# 光晕
		draw_circle(Vector2(40, 0), 34, Color(0.55, 0.2, 0.7, 0.18))

	# 多边形可安全绘制？（顶点有限且能三角剖分，避免 C++ 层 triangulation failed 刷屏/中断）
	func _poly_ok(poly: PackedVector2Array) -> bool:
		for v in poly:
			if not (is_finite(v.x) and is_finite(v.y)):
				return false
		return Geometry2D.triangulate_polygon(poly).size() > 0

# 血锁的链子：一长串鲜红链环，从血锁射向目标并被勾拉收拢
class BloodChain:
	extends Node2D
	var length := 60.0
	var color := Color(0.95, 0.16, 0.28)

	func _draw() -> void:
		# +X 延伸的节状链环（更粗、更鲜红，链环交错更像锁链）
		var seg := 11.0
		var n := int(length / seg)
		for i in n:
			var x := i * seg + seg * 0.5
			# 相邻环交错上下，更像锁链
			var oy := -3.0 if (i % 2 == 0) else 3.0
			draw_arc(Vector2(x, oy), 7.0, 0.0, TAU, 28, color, 3.5, true)
			draw_circle(Vector2(x, oy), 2.8, Color(0.5, 0.05, 0.12))
		# 链头（勾钩）
		var hx := length
		draw_arc(Vector2(hx, 0), 9.0, -1.2, 1.2, 20, Color(1.0, 0.25, 0.35), 3.0, true)
		draw_circle(Vector2(hx, 0), 4.0, Color(1.0, 0.3, 0.4))

var grid: HexGrid
var board_view: BoardView
var rng := RandomNumberGenerator.new()   # 统一随机源：单机默认随机，联机时由主机播种保证确定
var _session_id := 0   # 对局会话代：重开/重置时递增，让残留的异步协程（敌方回放等）检测到并安全退
var _ai_thread: Thread = null      # 敌方 AI 后台搜索线程（避免主线程卡死无法查看/操作）
var _ai_plan: Array = []           # 线程算出的敌方行动计划
var _ai_done := false              # 线程是否已完成
var _ai_used := false              # 是否已消费本次线程结果
var _ai_mutex := Mutex.new()       # 保护 _ai_plan/_ai_done 跨线程读写
var _ending_side := false   # 正在"结束回合/结算扣血"流程中：期间阵亡不立即替补（推迟到本方下回合
var _rematch_requested := false   # 客户端已请求"再来一局"（防重复发请求）
var _rematch_started := false     # 主机已发起联机重开（防重入，重载场景后新实例自动重置）

# 回合限时：本端可操作回合超过时限自动结束0 秒）= 未开始计时（部署/等待/选人阶段）
const TURN_TIME_LIMIT := 90.0
var turn_time_left := 0.0          # 本端可操作回合剩余秒数（从本端回合开始起算，演出/动画也算时间
var peer_turn_time_left := 0.0     # 对端行动回合剩余秒数（联机等待端本地递减 + 对端广播校准
var _turn_expired := false         # 本端回合已超时但正处于演动画，待回到可提交状态时自动结束
var _time_sync_acc := 0.0          # 行动方剩余时间广播节流累加器

## 设置随机种子（联机主机用）：同一输入+同种=> 双方结果一致。单机不调用则保持默认随机
func set_random_seed(seed_value: int) -> void:
	rng.seed = seed_value

# 用 rng 洗牌（替代 Array.shuffle 的全局随机，保证联机同种子下两端一致）
func _rng_shuffle(arr: Array) -> void:
	for i in range(arr.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp = arr[i]
		arr[i] = arr[j]
		arr[j] = tmp

var units: Array[Unit] = []
var occupancy: Dictionary = {}   # cell(Vector2i) -> Unit
var board_size := Vector2i(5, 7)  # 5 × 6 满行 + 顶部 2 格顶帽(总高 7 行;相对旧版删左右各 1 列)
const TOP_CAP_COLS: Array[int] = [1, 3]   # 顶帽行(row0)保留列:删左右各一列后居中 2 格(奇列),与下方偶列交错
var hex_size := 60.0   # 六边形外接半径(像素)。_ready 时按视口自动放大以铺满屏宽;想固定则注释 _fit 调用
var state := State.IDLE
var selected: Unit = null
var _unit_card_open := false   # 属性卡浮层是否打开（打开期间触摸全部交给卡层，避免重复查看/误触）
# 触屏手势（安卓/iOS）：短按=点击选中/行动；按住不动超时=查看属性；按住移动=拖动英雄。
# 桌面保留原鼠标逻辑（右键查看、左键点击/按下拖动），不走手势。
var _press_active := false
var _press_pos := Vector2.ZERO
var _press_cell := Vector2i(-99, -99)
var _press_unit: Unit = null      # 按下格的我方英雄（拖动候选）
var _press_time_ms := 0
var _press_viewed := false        # 已作为长按查看处理（抬起不再当点击）
var _press_drag_started := false  # 已从长按转为拖动
var _press_seen := false          # 本次抬手前是否收到过对应按下：
	# 属性浮层(GUI)消费掉按下后再抬起时,Godot 可能把"孤抬手"漏给本层;
	# 若没有对应按下就处理,会用上一次手势遗留的 _press_cell 在手指处误重新打开卡面(框"跟手")。
const _PRESS_LONG_MS := 450       # 长按判定时长
const _PRESS_DRAG_PX := 14.0      # 位移超过该值判定为拖动
var _last_attacked: Unit = null   # 最近一次攻击的目标（供攻击后技能使用）
var _attack_hp_before := 0   # 最近一次攻击结算前目标的生命值（攻击后技能用攻击前血量判定，如古拉吸血
# 拖拽撤下：按住己方英雄拖到出生点
var _drag_unit: Unit = null
var _drag_start_mouse := Vector2.ZERO
var _drag_orig_pos := Vector2.ZERO
var _dragging := false
const _DRAG_THRESHOLD = 12.0
var _pending_bomb_unit: Unit = null   # 炸弹人待放置（等待点选空地）
var _pending_player_subs := 0     # 我方阵亡待替补名额数（可 >1：同时阵亡多人时逐个替补
var _defer_side_skills := false   # 回合开始先补位：替补全部落位完成后才触发回合开始技
var _waiting_side_skills_round := -1   # 联机等待端：行动方补位完成后广播 side_skills,收到后本端才执行回合开始技(同步 rng)
var _in_begin_phase := false      # 回合开始演出期（技能逐个触发中）：此间阵亡先排队，演出结束再弹替补面板
var _start_placing_subs := false  # 正在"回合开始的先补位"阶段落位（跳过即时光环补发，技能阶段会统一触发）
var _pending_enemy_sub := 0        # 敌方阵亡待替补数量（轮到敌方回合时按此数量补位）
var bombs: Dictionary = {}        # cell -> true（炸弹陷阱）
var obstacles: Dictionary = {}    # cell -> 耐久（障碍物，阻挡移动，可被破坏
var buff_items: Dictionary = {}   # cell -> "atk"/"move"（圣诞老人等放置的增益道具
var graves: Dictionary = {}       # cell -> hero_id（阵亡单位的墓碑：替补可在此落位，落位后消失
var _possess_links: Dictionary = {}   # [附体] 绑定: target(Unit) -> 施加者 caster(Unit)
var _possess_depth := 0               # [附体] 镜像递归深度（多宿魂互附时防死循环）
var gold_left: Dictionary = {}        # cell -> 金矿剩余回合数（3→0 消失；每完整回合减1）
var _gold_tick_round := -1            # 已执行过金矿倒计时的回合号（每轮只减一次，两端同步）

# 开局增益道具：开局(第一个行动方回合开始技时)在候选 4 格放 2 个随机道具。
# 坐标由玩家编号(左下角=[1,1],x 右起,y 上起)换算为代码坐标(y0=顶行)：
# 玩家 [2,4][3,3][3,4][4,4] -> 代码 (1,3)(2,4)(2,3)(3,3)。
var _opening_items_spawned := false
const OPENING_ITEM_CELLS: Array = [Vector2i(1, 3), Vector2i(2, 4), Vector2i(2, 3), Vector2i(3, 3)]
const OPENING_ITEM_TYPES: Array = ["atk", "shield", "heal"]   # 攻击+1 / 圣盾 / 回复3血
var reachable_map: Dictionary = {}   # cell -> true (可移
var enemy_cells: Dictionary = {}     # cell -> true (可攻击高
var _preview_cells: Dictionary = {}  # cell -> Color（敌方预览范围）
var _preview_unit: Unit = null       # 当前预览描边的敌方单位（清除时移除其金边）

# 开局兜底阵容：取注册表前若干名可用角色（若非卡池进入对战
const DEPLOY_COUNT := 3
const DEFAULT_DECK_SIZE := 5
# 控制台日志分类开关（Godot 输出面板）：
# _CONSOLE_SUB_LOG = 替补流程日志（阵亡→待补→面板→落位→统计）：检查替补用，默认开
# _CONSOLE_AI_LOG  = AI 行为决策日志（行动方案评分/竞技场选人/首发部署/敌方AI替补上人）：默认关，避免刷屏
const _CONSOLE_SUB_LOG := true
const _CONSOLE_AI_LOG := false

func _default_deck() -> Array:
	var ids := DataRegistry.heroes.keys()
	ids.sort()
	var out: Array = []
	for i in mini(DEFAULT_DECK_SIZE, ids.size()):
		out.append(ids[i])
	return out
const LOSS_DEATH_COUNT := 3   # 一方累3 名英雄阵亡即判负

# 替补与阵亡统
var player_roster: Array = []   # 我方替补英雄 id（尚未上场）
var enemy_roster: Array = []    # 敌方替补英雄 id
var _sub_faction := -1          # 当前替补操作的目标阵营（-1=无；PLAYER/ENEMY
var player_dead := 0
var enemy_dead := 0

func _exit_tree() -> void:
	# 兜底：场景卸载前回收可能仍在跑的后台 AI 线程，避免节点释放后线程写成员报错
	if _ai_thread != null and _ai_thread.is_started():
		_ai_thread.wait_to_finish()
	_ai_thread = null

func _ready() -> void:
	NetBus.packet_received.connect(_on_net_packet)   # 联机收指
	NetBus.disconnected.connect(_on_net_disconnected)   # 联机对局中：对端退断线 -> 本端也退出回大厅
	hex_size = _fit_hex_size()   # 视口铺满自适应:棋盘宽基本占满屏幕,棋子内容随之等比放大
	grid = HexGrid.new(board_size.x, board_size.y, hex_size)
	grid.top_cap_cols = TOP_CAP_COLS   # 5列棋盘顶帽行为居中 2 格(奇列 1,3),保持与下方偶列交错
	# 联机访客：把棋盘绕中心旋180°，让"我方阵营"始终落在屏幕下方
	# 只影响渲鼠标回查，不改任何逻辑阵营，故两端确定性不受影响
	grid.view_flip = GameState.is_online and not GameState.is_host
	board_view = BoardView.new(grid, _board_origin())
	board_view.enemy_zone_cells = ENEMY_ZONE_CELLS.duplicate()   # 敌方出生区整片（底色上色用）
	board_view.bombs = bombs
	board_view.obstacles = obstacles
	board_view.buff_items = buff_items
	board_view.graves = graves
	board_view.gold_left = gold_left
	# 酒馆木地板背景（垫在棋盘下层；必须忽略鼠标，否则会吃掉棋盘点击）
	var wood := WoodFloor.new()
	var wsize := get_viewport().get_visible_rect().size
	wood.position = Vector2.ZERO
	wood.size = wsize
	wood.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(wood)
	add_child(board_view)
	if GameState.is_online:
		# 联机对局：两端使NetLobby 广播的同一随机种子（确定性）；使用双方选择的卡组（为空才用默认），
		# 走与单机一致的 _begin_deployment 轮流部署（敌轮改为等待对端真人发部署指令）
		# 竞技场联机：先由主机发牌双人 2 1 构建双方卡组（各 8 名），再进入同样的部署流程
		set_random_seed(GameState.online_seed)
		_place_obstacles()
		_spawn_opening_items()   # 进入战斗即刷新开局道具（障碍已定、单位未上，两端同种子同步）
		_setup_hud()
		if GameState.arena_mode:
			_begin_online_arena_draft()
		else:
			if GameState.player_deck.size() == 0:
				GameState.player_deck = ["hero_06", "hero_17", "hero_26"]
			if GameState.enemy_deck.size() == 0:
				GameState.enemy_deck = ["hero_13", "hero_12", "hero_23"]
			_begin_deployment()
	elif GameState.player_placement.size() > 0 or GameState.enemy_placement.size() > 0:
		# 测试场景直接指定放置：不上部署选人
		_place_units()
		_setup_hud()
		_start_match()
	else:
		_place_obstacles()
		_spawn_opening_items()   # 进入战斗即刷新开局道具（障碍已定、单位未上）
		_setup_hud()
		if GameState.arena_mode:
			_begin_arena_draft()   # 竞技场：先随构建双方卡组，再部署
		else:
			_begin_deployment()

# 每帧刷新"仍有行动英雄"的顶部标识（仅本端我方回合、且仅本端我方单位显示）
func _process(dt: float) -> void:
	# 开局选人限时：本端三轮共用一个共享预算；预算耗尽 -> 自动随机补人（每次补一人，换回本侧轮继续补到满
	if state == State.DEPLOY or state == State.PLACE_DEPLOY:
		if deploy_budget_active:
			deploy_budget_left = maxf(deploy_budget_left - dt, 0.0)
			if deploy_budget_left <= 0.0:
				deploy_budget_active = false   # 本侧本轮立即随机补人
				action_info.emit("选人时间到，自动随机上人")
				_auto_deploy_random()
	# 竞技场选人轮限时：本端正在 2 1"时倒计时（等待对方/敌方AI轮不限时
	if state == State.ARENA_DRAFT and arena_pick_time_left >= 0.0:
		if _my_arena_choosing():
			arena_pick_time_left -= dt
			if arena_pick_time_left <= 0.0:
				arena_pick_time_left = 0.0
				action_info.emit("选卡超时，自动选择第一张")
				_auto_pick_first()
	var match_live: bool = GameState.match_running and not GameState.match_over
	var my_turn_live: bool = match_live and GameState.active_side == _my_side()
	# 本端回合倒计时（从回合开始起算，演出/行动动画也算时间）；超时置标记，回到可提交状态时自动结束
	if my_turn_live and turn_time_left > 0.0:
		turn_time_left = maxf(turn_time_left - dt, 0.0)
		if turn_time_left <= 0.0:
			turn_time_left = 0.0
			_turn_expired = true
			action_info.emit("回合超时，自动结束回合")
	if _turn_expired and my_turn_live:
		# 替补/落位中卡住的超时：自动选出替补并落位，直到回到可提交状态再自动结束回合
		if state == State.SUBSTITUTING or state == State.PLACE_SUB:
			_auto_sub_on_timeout()
		elif state == State.PLAYER_INPUT:
			_turn_expired = false
			submit_end_turn()   # 客户端超-> 发主机；主机超时 -> 本地结束
	# 联机等待对端行动：对端广播只作为基准，本端每帧自行递减（对端演断包期间不消失）
	if GameState.is_online and match_live and not my_turn_live and peer_turn_time_left > 0.0:
		peer_turn_time_left = maxf(peer_turn_time_left - dt, 0.0)
	# 联机：本端行动时（含行动动画期间）把剩余秒数同步给对端；回合开始时也立即同步一
	if GameState.is_online and my_turn_live and _time_sync_acc >= 0.5:
		_time_sync_acc = 0.0
		_send_turn_time_left()
	elif GameState.is_online and my_turn_live:
		_time_sync_acc += dt
	if state == State.PLAYER_INPUT and my_turn_live:
		for u in units:
			if u == null or not is_instance_valid(u):
				continue
			if u.alive and u.faction == _my_faction():
				# 可移动=绿色、可攻击=红色；两者可独立显示（后勤不能攻击，攻击标识不亮）。
				# 规则：攻击后不能再移动 → 绿色可移动仅在"未移动且未攻击"时亮。
				u.set_action_markers(not u.moved_this_turn and not u.attacked_this_turn, not u.attacked_this_turn and _can_actively_attack(u))
			else:
				u.set_action_marker(false)   # 旧统一标识关闭，避免残留
				u.set_action_markers(false, false)
				u.set_action_marker(false)
	else:
		for u in units:
			if u == null or not is_instance_valid(u):
				continue
			u.set_action_markers(false, false)
			u.set_action_marker(false)
	# 触屏长按查看：按住不动超过阈值 -> 查看该格卡面/道具（不执行行动）
	if _press_active and not _press_viewed and not _press_drag_started:
		if Time.get_ticks_msec() - _press_time_ms >= _PRESS_LONG_MS:
			_press_viewed = true
			var cu = occupancy.get(_press_cell, null)
			if buff_items.has(_press_cell):
				item_view_requested.emit(buff_items[_press_cell])
			elif cu != null:
				card_view_requested.emit(cu)

func _send_turn_time_left() -> void:
	if not GameState.is_online or not NetBus.is_online:
		return
	NetBus.send_all(JSON.stringify({ "type": "turn_time", "left": int(ceil(turn_time_left)) }))

# 联机快捷喊话:把预置言论发给对端(仅联机对战中有意义)
func send_quick_chat(text: String) -> void:
	if text == "" or not GameState.is_online or not NetBus.is_online:
		return
	NetBus.send_all(JSON.stringify({ "type": "chat", "text": text }))

# ---- 竞技场模式：随机2构建双方卡组 ----
func _begin_arena_draft() -> void:
	state = State.ARENA_DRAFT   # 先进入选人态：顶部标签显示"竞技场选人"
	_prepare_first_side()   # 浮框提示"本局先手"，随后开2 1 选人
	arena_pick_time_left = -1.0   # 首轮展示时再置限
	# 候选池 = 全部英雄（去重，不含衍生物）
	_arena_pool = DataRegistry.heroes.keys().duplicate()
	_rng_shuffle(_arena_pool)   # rng 洗牌（同种子两端一致）
	_arena_picked = []
	_arena_enemy = []
	_arena_player_rounds = 0
	_arena_enemy_rounds = 0
	# 关键：选人一开始就清空上一局卡组。否则在 8 轮选完（才 set_decks）之前，
	# 任何读取 GameState.player_deck/enemy_deck 的地方（部署/队伍面板等）都会显示上一局阵容
	GameState.set_decks([], [])
	_notify_team()   # 立即刷新 HUD：已选阵容为-> 旧队伍面板随之收
	_show_arena_round()

func _show_arena_round() -> void:
	# 8 轮：4 轮玩2 1（自己拿 1、另 1 给敌方）；后 4 轮敌方选（敌方1、另 1 给你
	var total_done: int = _arena_player_rounds + _arena_enemy_rounds
	if total_done >= ARENA_PICKS_PER_SIDE * 2:
		# 8 轮选完：_arena_picked 累积了玩家拿到的全部 8 个（玩家4+敌轮归你4），
		# _arena_enemy 累积了敌方拿到的全部 8 个（玩家轮归+敌方自）
		# 保持 arena_mode=true：竞技场模式下"再来一局"会重新选人，直到玩家返回选人界面退出
		# 双方都把<替补> 标签的英雄排到卡组末尾（进替补席），保证3 = 首发英雄
		GameState.set_decks(_order_deck(_arena_picked), _order_deck(_arena_enemy))
		log_message.emit("竞技场选人完成：我方 %d 名，敌方 %d 名。" % [GameState.player_deck.size(), GameState.enemy_deck.size()])
		arena_draft_done.emit()
		_begin_deployment()
		return
	var remaining := _arena_pool.duplicate()
	if remaining.size() >= 2:
		# 取两个不重复
		var a: String = remaining.pop_front()
		var b: String = remaining.pop_front()
		_arena_pending = [a, b]
		if _arena_player_rounds < ARENA_PICKS_PER_SIDE:
			# 玩家轮（显示玩家自己操作的轮数：4 轮）
			arena_pick_time_left = ARENA_PICK_SECONDS   # 开始本轮限
			arena_draft_requested.emit(_arena_pending)
			action_info.emit("竞技场选人（第 %d/%d 轮，你的回合）：从两名英雄中选择 1 名加入你的队伍。" % [_arena_player_rounds + 1, ARENA_PICKS_PER_SIDE])
		else:
			# 敌方轮：先发空提示（HUD 显示"敌方选择），敌方自动选一个，个归你（不限时）
			arena_pick_time_left = -1.0
			arena_draft_requested.emit([])
			_action_arena_enemy_pick()
		return
	else:
		# 池不足（理论不会出现，兜底用默认卡组
		GameState.set_decks([], [])
		arena_draft_done.emit()
		_begin_deployment()

# 卡组排序：带 <替补> 标签的英雄（梅林/波盾/太阳猎颅者）排到末尾（进替补席）
# 保证3 = 首发型英雄。非替补保持相对顺序在前
func _order_deck(deck: Array) -> Array:
	var starts: Array = []
	var bench: Array = []
	for hid in deck:
		var def := DataRegistry.get_hero(hid)
		if def != null and def.skills.has(DataRegistry.Skill.BENCH):
			bench.append(hid)
		else:
			starts.append(hid)
	return starts + bench

# 英雄强度打分（单体基准，协同另行加分；与菜单选人共用口径
func _hero_strength(id: String) -> float:
	# 单体评分唯一实现在 DataRegistry.hero_strength()（避免两处公式漂移）
	return DataRegistry.hero_strength(id)

# 某英雄与"已选卡的机制协同总和（考虑已选英雄间的配合）
func _deck_synergy(deck: Array, hid: String) -> float:
	var s := 0.0
	for c in deck:
		s += DataRegistry.synergy_bonus(c, hid)
	return s

# 己方协同明细（日志用）：列出与已选卡里“谁”有协同、各自多少分
func _deck_synergy_note(deck: Array, hid: String) -> String:
	var parts: Array[String] = []
	for c in deck:
		var b := DataRegistry.synergy_bonus(c, hid)
		if b > 0.0:
			var nm: DataRegistry.HeroDef = DataRegistry.heroes.get(c, null)
			parts.append("%s+%.1f" % [nm.display_name if nm != null else c, b])
	return "、".join(parts)

# 敌方选人辅助：候选英雄能对玩家已选英雄的克制程度（从角色列表"被克列抽取的关系
func _counter_player_score(hid: String) -> float:
	var s := 0.0
	for pid in _arena_picked:
		var cr := DataRegistry.counter_bonus(hid, pid)
		if cr > 0.0:
			s += cr   # 该候选克制玩家某英雄 -> 敌方更值得
	return s

# 克玩家明细（日志用）：列出克制了玩家“哪些已选英雄”
func _counter_player_note(hid: String) -> String:
	var parts: Array[String] = []
	for pid in _arena_picked:
		var cr := DataRegistry.counter_bonus(hid, pid)
		if cr > 0.0:
			var nm: DataRegistry.HeroDef = DataRegistry.heroes.get(pid, null)
			parts.append("%s+%.1f" % [nm.display_name if nm != null else pid, cr])
	return "、".join(parts)

# 敌方轮：敌方自动个候选里个，个进玩家卡组
# 策略：与敌方已选卡组协同更高、且单体更强"的留给自己，把弱/难配合的让给玩家
# 同时结合一点随机性（top 1 若不够强则仍保前二），避免每次都拿同一批
func _action_arena_enemy_pick() -> void:
	if _arena_pending.size() < 2:
		_arena_pending = []
		_show_arena_round()
		return
	var a: String = _arena_pending[0]
	var b: String = _arena_pending[1]
	# 候选价值 = 单体强度 + 与敌方已选英雄的协同 + 对玩家已选英雄的克制。
	# （不再计入"双选协同"：本局只能选一张、另一张必给玩家，两张之间的配合分是同一个对称常数，
	#  不改变任何选择，只让日志虚高；送强组合给玩家的顾虑由"克玩家"分体现。）
	var sc_a := _hero_strength(a) + _deck_synergy(_arena_enemy, a) + _counter_player_score(a) + DataRegistry.role_balance_bonus(_arena_enemy, a)
	var sc_b := _hero_strength(b) + _deck_synergy(_arena_enemy, b) + _counter_player_score(b) + DataRegistry.role_balance_bonus(_arena_enemy, b)
	# 轻微随机：两个候选价值接近（差< 1.5）时随机决定，避免完全可预测
	var en_hid: String
	if abs(sc_a - sc_b) <= 1.5:
		en_hid = a if rng.randi() % 2 == 0 else b
	else:
		en_hid = a if sc_a >= sc_b else b
	var give_player: String = _arena_pending[1] if en_hid == _arena_pending[0] else _arena_pending[0]
	if _CONSOLE_AI_LOG:
		var nm_a := DataRegistry.get_hero(a).display_name
		var nm_b := DataRegistry.get_hero(b).display_name
		var rb_a: float = DataRegistry.role_balance_bonus(_arena_enemy, a)
		var rb_b: float = DataRegistry.role_balance_bonus(_arena_enemy, b)
		var tot_a: float = _hero_strength(a) + _deck_synergy(_arena_enemy, a) + _counter_player_score(a) + rb_a
		var tot_b: float = _hero_strength(b) + _deck_synergy(_arena_enemy, b) + _counter_player_score(b) + rb_b
		var pick_name := DataRegistry.get_hero(en_hid).display_name
		print("\n[AI竞技场选人] 敌方选人 第 %d/%d 轮（敌方此前已有 %d 名：前4轮玩家未选的自动归敌方）" % [_arena_enemy_rounds + 1, ARENA_PICKS_PER_SIDE, _arena_enemy.size()])
		var note_a := _deck_synergy_note(_arena_enemy, a)
		var note_b := _deck_synergy_note(_arena_enemy, b)
		var cnt_note_a := _counter_player_note(a)
		var cnt_note_b := _counter_player_note(b)
		print("  %s(%s)：单体%.1f + 己方协同%.1f%s + 克玩家%.1f%s + 职能配比%.1f = %.1f" % [nm_a, DataRegistry.hero_role_name(a), _hero_strength(a), _deck_synergy(_arena_enemy, a), ("(" + note_a + ")") if note_a != "" else "", _counter_player_score(a), ("(" + cnt_note_a + ")") if cnt_note_a != "" else "", rb_a, tot_a])
		print("  %s(%s)：单体%.1f + 己方协同%.1f%s + 克玩家%.1f%s + 职能配比%.1f = %.1f" % [nm_b, DataRegistry.hero_role_name(b), _hero_strength(b), _deck_synergy(_arena_enemy, b), ("(" + note_b + ")") if note_b != "" else "", _counter_player_score(b), ("(" + cnt_note_b + ")") if cnt_note_b != "" else "", rb_b, tot_b])
		print("[AI竞技场选人] → 敌方选择 %s（另一张 %s 归玩家）" % [pick_name, DataRegistry.get_hero(give_player).display_name])
	_arena_enemy.append(en_hid)
	_arena_picked.append(give_player)   # 敌方没拿的归
	for c in _arena_pending:
		_arena_pool.erase(c)   # 本轮两个候选离开候选池，避免重复抽取
	_arena_enemy_rounds += 1
	log_message.emit("敌方选择了 %s，%s 归你。" % [DataRegistry.get_hero(en_hid).display_name, DataRegistry.get_hero(give_player).display_name])
	_arena_pending = []
	_notify_team()   # 敌方轮归你的英雄也实时更新下方队
	_show_arena_round()

# 玩家在竞技场选人面板中点击某名英
func _on_arena_pick(hid: String) -> void:
	if state != State.ARENA_DRAFT:
		return
	if GameState.is_online and _oa_active:
		_oa_on_pick(hid)
		return
	if _arena_player_rounds >= ARENA_PICKS_PER_SIDE:
		return   # 玩家轮已结束（后续为敌方轮，通过 _action_arena_enemy_pick 自动推进
	if not _arena_pending.has(hid):
		return
	# 玩家1 个进自己的卡组，另一个自动进敌方卡组
	_arena_picked.append(hid)
	for c in _arena_pending:
		if c != hid:
			_arena_enemy.append(c)
		_arena_pool.erase(c)
	_arena_pending = []
	_arena_player_rounds += 1
	log_message.emit("你选择了 %s。敌方获得了 %s。" % [DataRegistry.get_hero(hid).display_name, DataRegistry.get_hero(_arena_enemy.back()).display_name if _arena_enemy.size() > 0 else ""])
	_notify_team()   # 竞技场选人实时更新下方队伍
	_show_arena_round()

# ---- 联机竞技场（双人各自 2 1，无先后、随时点选）----
# 规则（与单机竞技场同源，只是敌方为真人）
#   主机/客户端各拥有自己4 轮候选（每轮 2 名，由同一种子洗牌后确定性分配、互不重叠）
#   每轮从自己两张中1 张留用，1 张自动送给对方。共 4 轮后双方各得 8 名（自留 4 + 对方4）
#   选卡无先后：两端随时各自点选，先完成的一方等待另一方，全部完成后由主机汇总卡组广播，再进入普通部署
var _oa_active := false             # 联机竞技场选卡进行
var _oa_round := 0                  # 我已完成的轮数（0..ARENA_PICKS_PER_SIDE
var _oa_my_pairs: Array = []        # 我方 4 轮候选（每轮 2 hero id
var _oa_peer_pairs: Array = []      # 对端 4 轮候选（本地推导，用于主机校汇总）
var _oa_my_kept: Array = []         # 我方每轮留下的英
var _oa_peer_kept: Array = []       # 主机：对端每轮留下的英雄（按轮到达顺序收集）
var _oa_finished := false           # 选卡已全部完
var _oa_pending: Array = []         # 主机：draft 尚未启动时收到的客户pick 缓存（防乱序丢包
func _begin_online_arena_draft() -> void:
	state = State.ARENA_DRAFT
	_prepare_first_side()   # 联机竞技场：开局先手提示2 1 选人一起弹
	arena_pick_time_left = -1.0   # 本端轮到 2 1 _oa_show_round 再置限时
	_oa_active = true
	_oa_round = 0
	_oa_my_pairs = []
	_oa_peer_pairs = []
	_oa_my_kept = []
	_oa_peer_kept = []
	_oa_finished = false
	# 双方同种子洗整池后，8 名给主机半区、后 8 名给客户端半区（本地推导一致，无需网络发候选）
	var pool := DataRegistry.heroes.keys().duplicate()
	if pool.size() < ARENA_PICKS_PER_SIDE * 4:
		# 池不足（几乎不会发生）：两端走同一兜底卡组并直接进入部署（无需广播——两端确定性一致）
		log_message.emit("英雄池不足，联机竞技场改用默认卡组")
		GameState.player_deck = ["hero_06", "hero_17", "hero_26"]
		GameState.enemy_deck = ["hero_13", "hero_12", "hero_23"]
		_oa_finished = true
		_oa_active = false
		_oa_finish_to_deploy()
		return
	_rng_shuffle(pool)
	for r in ARENA_PICKS_PER_SIDE:
		if GameState.is_host:
			_oa_my_pairs.append([pool[r * 2], pool[r * 2 + 1]])
			_oa_peer_pairs.append([pool[8 + r * 2], pool[8 + r * 2 + 1]])
		else:
			_oa_my_pairs.append([pool[8 + r * 2], pool[8 + r * 2 + 1]])
			_oa_peer_pairs.append([pool[r * 2], pool[r * 2 + 1]])
	log_message.emit("竞技场选卡开始：4 轮，每轮从给你的两张中1 张留用，另一张送给对方")
	if GameState.is_host and _oa_pending.size() > 0:
		# 主机启动期间收到的客户端 pick 缓存：现在补
		var pend: Array = _oa_pending
		_oa_pending = []
		for p in pend:
			if p is Dictionary:
				_oa_on_peer_pick(int(p.get("round", -1)), String(p.get("hero", "")))
	_oa_show_round()

# 展示当前轮候选；已选满 4 轮则显示等待（等对方完成 / 主机汇总广播）
func _oa_show_round() -> void:
	if not _oa_active:
		return
	if _oa_round >= ARENA_PICKS_PER_SIDE:
		action_info.emit("你已完成选卡，等待对方完成…")
		arena_pick_time_left = -1.0   # 等待对方：本端不再限
		arena_draft_requested.emit([])   # 空候-> HUD 显示等待面板
		_oa_check_finish_host()
		return
	if _oa_round >= _oa_my_pairs.size():
		return
	arena_pick_time_left = ARENA_PICK_SECONDS   # 本端新一2 1：开始限
	arena_draft_requested.emit(_oa_my_pairs[_oa_round])
	action_info.emit("竞技场选卡（第 %d/%d 轮）：从两张中选择 1 张留下，另一张将送给对方。" % [_oa_round + 1, ARENA_PICKS_PER_SIDE])

# 本端是否正处于竞技2 1 且可点选（用于倒计时：单机玩家/ 联机本端轮）
func _my_arena_choosing() -> bool:
	if state != State.ARENA_DRAFT:
		return false
	if GameState.is_online and _oa_active:
		return _oa_round < ARENA_PICKS_PER_SIDE and _oa_round < _oa_my_pairs.size()
	return _arena_player_rounds < ARENA_PICKS_PER_SIDE and _arena_pending.size() >= 2

# 超时自动选当前轮第一张（单机_on_arena_pick；联机走 _oa_on_pick 并同步对端）
func _auto_pick_first() -> void:
	if state != State.ARENA_DRAFT:
		return
	if GameState.is_online and _oa_active:
		if _oa_round < _oa_my_pairs.size():
			var pair: Array = _oa_my_pairs[_oa_round]
			if pair.size() >= 2:
				_oa_on_pick(pair[0])
	else:
		if _arena_pending.size() >= 2:
			_on_arena_pick(_arena_pending[0])

# 我方点选当前轮的一
func _oa_on_pick(hid: String) -> void:
	if not _oa_active or state != State.ARENA_DRAFT:
		return
	if _oa_round >= ARENA_PICKS_PER_SIDE or _oa_round >= _oa_my_pairs.size():
		return
	var pair: Array = _oa_my_pairs[_oa_round]
	if not pair.has(hid):
		return
	_oa_my_kept.append(hid)
	var gift: String = pair[1] if pair[0] == hid else pair[0]
	_oa_round += 1
	log_message.emit("你留下了 %s，%s」将送给对方。" % [DataRegistry.get_hero(hid).display_name, DataRegistry.get_hero(gift).display_name])
	_notify_team()
	if GameState.is_host:
		_oa_check_finish_host()
		_oa_show_round()
	else:
		NetBus.send_to(1, JSON.stringify({ "type": "arena_pick", "round": _oa_round - 1, "hero": hid }))
		_oa_show_round()

# 主机收到客户端某一轮的选择（按轮顺序收集）
func _oa_on_peer_pick(rd: int, hero: String) -> void:
	if not _oa_active or not GameState.is_host:
		return
	if rd < 0 or rd >= ARENA_PICKS_PER_SIDE or rd != _oa_peer_kept.size():
		return   # 期望0..3 顺序到达，乱重复直接忽略
	if rd >= _oa_peer_pairs.size():
		return
	var pair: Array = _oa_peer_pairs[rd]
	if not pair.has(hero):
		return
	_oa_peer_kept.append(hero)
	_oa_check_finish_host()

# 主机在双方都选满后汇总卡组并广播（客户端收到广播后以广播为准
func _oa_check_finish_host() -> void:
	if not GameState.is_host or not _oa_active:
		return
	if _oa_round < ARENA_PICKS_PER_SIDE or _oa_peer_kept.size() < ARENA_PICKS_PER_SIDE:
		return
	if _oa_finished:
		return
	_oa_finished = true
	# 组装双方卡组：自4 + 对方每轮没选（送给我的张；对方同理
	var pdeck: Array = []   # 主机（PLAYER 半区）卡
	var edeck: Array = []   # 客户端（ENEMY 半区）卡
	for r in ARENA_PICKS_PER_SIDE:
		var mp: Array = _oa_my_pairs[r]
		var pp: Array = _oa_peer_pairs[r]
		pdeck.append(_oa_my_kept[r])
		pdeck.append(pp[1] if pp[0] == _oa_peer_kept[r] else pp[0])
		edeck.append(_oa_peer_kept[r])
		edeck.append(mp[1] if mp[0] == _oa_my_kept[r] else mp[0])
	GameState.player_deck = _order_deck(pdeck)
	GameState.enemy_deck = _order_deck(edeck)
	_oa_active = false
	NetBus.send_all(JSON.stringify({ "type": "arena_done", "pdeck": GameState.player_deck, "edeck": GameState.enemy_deck }))
	_oa_finish_to_deploy()

# 客户端收到主机广播的最终卡组后落位，然后两端都从这里进入部
func _oa_apply_done(pdeck: Array, edeck: Array) -> void:
	if _oa_finished:
		return
	_oa_finished = true
	_oa_active = false
	GameState.player_deck = pdeck
	GameState.enemy_deck = edeck
	_oa_finish_to_deploy()

# 选卡结束 -> 关闭选卡面板并进入与普通模式一致的部署流程
func _oa_finish_to_deploy() -> void:
	arena_draft_done.emit()
	state = State.IDLE
	log_message.emit("竞技场选卡完成：我方 %d 名 / 敌方 %d 名，开始部署。" % [GameState.player_deck.size(), GameState.enemy_deck.size()])
	_begin_deployment()


# ---- 开局部署（棋盘上进行，带演出动画----
const DEPLOY_COUNT_BATTLE := 3
const DEPLOY_BUDGET_SECONDS := 45.0   # 开局选人：本端全部选人的总预算（秒），不按轮重置
var deploy_budget_left := DEPLOY_BUDGET_SECONDS   # 剩余总时间（随时间流逝减少，不按轮重置）
var deploy_budget_active := false                 # 当前是否正处本端真人选人/放位（此时才倒计时）
# 敌方出生区整片（顶帽 row0 的 1,3 + 第一满行 row1 的 0,2,4 交错皇冠，共 5 格；居中窄顶宽底）
const ENEMY_ZONE_CELLS: Array = [
	Vector2i(1, 0), Vector2i(0, 1), Vector2i(2, 1), Vector2i(3, 0), Vector2i(4, 1),
]
var player_pool: Array = []
var enemy_pool: Array = []
var player_deployed: Array = []
var enemy_deployed: Array = []
var _deploy_side := 0   # 随机先手（选人顺序
var _first_side := GameState.SIDE_PLAYER   # 先选人= 开局先行动方
var _first_side_decided := false           # 本局先手是否已随机并提示过（重开/再来一局会重置再问）
var _pending_deploy := ""   # 已选中的部署英雄（等待点出生格放置
var _pending_enemy_deploy := ""   # 敌轮：客户端已选中的敌方英雄（等待点敌方出生格放置
# ---- 竞技场模式：随机2构建双方卡组（共8轮：轮玩家选、后4轮敌方选，最终双方各8名） ----
const ARENA_PICKS_PER_SIDE := 4   # 每边各
const ARENA_PICK_SECONDS := 15.0  # 竞技场选人每轮限时（秒），超时自动选第 1 
var arena_pick_time_left := -1.0  # 当前轮剩余选择秒数0=不限时，如等待对敌方AI轮）
var _arena_pending: Array = []       # 当前轮随机的2个候选英id
var _arena_pool: Array = []          # 剩余候选池（未被选走的英雄）
var _arena_picked: Array = []        # 玩家已选（进己方卡组）
var _arena_enemy: Array = []         # 敌方已选（进敌方卡组）
var _arena_player_rounds := 0        # 玩家已进行的轮数（前4
var _arena_enemy_rounds := 0         # 敌方已进行的轮数（后4
signal arena_draft_requested(pair: Array)   # 通知 HUD 显示本轮2
signal arena_draft_done                     # 8轮选完

signal deploy_refresh
signal card_view_requested(unit: Unit)   # 右键查看卡面
signal item_view_requested(type: String)  # 右键查看道具作用
signal touch_view_end_requested           # 触屏长按查看后松手：请求 HUD 关闭属性浮层

# 开局先手提示（单机）：先= 部署上首发先+ 开战先行动。短暂浮~1s 自动消失，不阻塞流程
signal first_side_notice(text: String)   # 请求 HUD 显示"本局先手"浮框

# 回合切换醒目提示：每方回合开始时屏幕中央弹横幅（我方"你的回合"、对方"敌方回合"）
signal turn_banner(text: String)

# 重开本局：清空场上单道具/状态并重新开局*不卸载场景树**，避reload 打断异步协程导致 get_tree() null 崩溃）
func reset_match() -> void:
	_session_id += 1   # 让上次对局的异步协程（敌方回放等）检测到会话已变并安全退
	# 若敌方 AI 后台线程仍在跑，等它结束并回收（搜索已限幅，耗时短；避免线程泄漏）
	if _ai_thread != null and _ai_thread.is_started():
		_ai_thread.wait_to_finish()
	_ai_thread = null
	_ai_done = false
	_ai_used = false
	_ending_side = false
	_clear_selection()   # 清掉选中单位 + 可移可攻击高亮：否则"点击英雄后重开"会把旧可行动范围带到新一局
	# 清场上单
	for u in units:
		if is_instance_valid(u):
			u.queue_free()
	units.clear()
	occupancy.clear()
	bombs.clear()
	buff_items.clear()
	obstacles.clear()
	graves.clear()
	gold_left.clear()
	_gold_tick_round = -1   # 重开新局：金矿倒计时重新从放置起算
	_possess_links.clear()
	_possess_depth = 0
	_preview_cells = {}
	_refresh_board()   # 同步棋盘显示：清空上一局的墓障碍/道具残留（board_view 缓存需要重绘）
	player_roster = []
	enemy_roster = []
	player_pool = []
	enemy_pool = []
	player_deployed = []
	enemy_deployed = []
	player_dead = 0
	enemy_dead = 0
	_pending_player_subs = 0
	_pending_enemy_sub = 0
	_pending_sub = ""
	_defer_side_skills = false   # 重开清除补位延标志（新局回合开始重走流程）
	_waiting_side_skills_round = -1   # 重开清除等待技能广播标记
	_opening_items_spawned = false   # 重开新局开局道具重新刷一次
	selected = null
	# 重置 GameState（按当前模式；重置后重新部署/竞技场选人
	if GameState.arena_mode:
		GameState.arena_mode = true   # 竞技场模式：重开后保持竞技场，重新随机选人（直到玩家返回选人界面退出）
	GameState.round_number = 1
	GameState.active_side = GameState.SIDE_PLAYER
	GameState.match_over = false
	GameState.match_running = false
	# 清掉旧对局的回等待倒计时与超时标记，避免重开后顶部还显示上一局剩余秒数"
	turn_time_left = 0.0
	peer_turn_time_left = 0.0
	_turn_expired = false
	deploy_budget_left = DEPLOY_BUDGET_SECONDS
	deploy_budget_active = false
	arena_pick_time_left = -1.0
	_first_side_decided = false   # 重开视为新开局：重新随机先手并弹框提示
	GameState.start_match(GameState.SIDE_PLAYER)
	if GameState.player_placement.size() > 0 or GameState.enemy_placement.size() > 0:
		# 自由部署：直接放置并开
		_place_units()
		_start_match()
	elif GameState.arena_mode and not GameState.is_online:
		# 单机竞技场重开：重新随机生成障碍并回到 2 1 选人（与 _ready 竞技场分支一致）
		# _begin_arena_draft 内部会清空卡组并刷新 HUD（旧队伍面板随之收起）
		_place_obstacles()
		_spawn_opening_items()   # 重开新局：开局道具同步重新刷新
		arena_pick_time_left = -1.0
		_begin_arena_draft()
	else:
		# 普通模式重开：重新随机生成障碍再进入部署（与 _ready 普通分支一致：先放障碍再部署）
		_place_obstacles()
		_spawn_opening_items()   # 重开新局：开局道具同步重新刷新
		_begin_deployment()

# 单机开局先手：每局随机一次并弹框告知后再选人/上首发
# 联机：用种子奇偶定先手，两端必然一致（不依赖两rng 调用是否对齐）
func _prepare_first_side() -> void:
	if _first_side_decided:
		return
	_first_side_decided = true
	if GameState.is_online:
		# 避免"两端各掷一rng 产生分歧"导致提示与状态栏先手不一
		_deploy_side = 1 if GameState.online_seed % 2 == 1 else 0
	else:
		_deploy_side = rng.randi() % 2
	_first_side = GameState.SIDE_PLAYER if _deploy_side == 0 else GameState.SIDE_ENEMY
	if DisplayServer.get_name() == "headless":
		return   # 无窗口测试：不提示直接继
	# 单机/联机都提示："我方/敌方"按本端阵营视角表
	var who := "我方" if _first_side == _my_side() else "敌方"
	first_side_notice.emit("本局先手：%s" % who)   # HUD 短暂浮框 ~1s 自动消失，不阻塞流程

func _begin_deployment() -> void:
	state = State.DEPLOY   # 先进入部署态：顶部标签显示"部署选人"而不是旧回合
	_prepare_first_side()
	player_pool = GameState.player_deck.duplicate()
	enemy_pool = GameState.enemy_deck.duplicate()
	player_deployed = []
	enemy_deployed = []
	player_roster = []
	enemy_roster = []
	# 高亮出生区（我方蓝、敌方红
	var pc := {}
	for c in _deploy_cells(DataRegistry.Faction.PLAYER):
		pc[c] = Color(0.2, 0.6, 0.95, 0.55)
	for c in _deploy_cells(DataRegistry.Faction.ENEMY):
		pc[c] = Color(0.95, 0.35, 0.3, 0.5)
	_preview_cells = pc
	_apply_highlights()
	deploy_refresh.emit()
	if _deploy_side == 1:
		if not GameState.is_online:
			_enemy_deploy.call_deferred()
		else:
			# 联机：敌轮由对端真人选人放置，本端等
			action_info.emit("等待对方选人…" if GameState.is_host else "轮到你（敌方）选人：点选下方英雄")
	_sync_deploy_timer()
	_deploy_banner_if_my_turn()   # 部署开始且轮到本端：中央提示"轮到你部署队伍"

func _deploy_cells(faction: int) -> Array:
	# 双方出生区整片高亮：玩家=底行整行，敌顶部顶帽第一满行
	return _spawn_cells(faction)

func _deploy_spawn(faction: int, hero_id: String) -> void:
	var cells := _deploy_cells(faction)
	var cell := Vector2i(-99, -99)
	for c in cells:
		if not occupancy.has(c):
			cell = c
			break
	if cell.x == -99:
		return
	var u := _spawn_unit(hero_id, faction, cell)
	# 演出：从登场点淡+ 放大
	u.modulate.a = 0.0
	u.scale = Vector2(0.2, 0.2)
	var t := create_tween()
	t.tween_property(u, "modulate:a", 1.0, 0.35)
	t.parallel().tween_property(u, "scale", Vector2.ONE, 0.35)

func _on_deploy_pick(hero_id: String) -> void:
	if state != State.DEPLOY or _deploy_side != 0:
		return
	if GameState.is_online and not GameState.is_host:
		return   # 联机玩家轮：只有主机可点选（客户端等待）
	if not player_pool.has(hero_id):
		return
	_pending_deploy = hero_id   # 不从卡池扣除，保持布局不动
	state = State.PLACE_DEPLOY
	# 高亮我方出生格（绿色敌方出生区（红）保留
	_show_deploy_zones(Color(0.2, 0.85, 0.5, 0.7))
	deploy_refresh.emit()
	action_info.emit("点击我方能上阵的位置（绿色格）")

# 联机敌轮：客户端（非主机）在 _deploy_side==1 时点选敌方英雄
func _on_enemy_deploy_pick(hero_id: String) -> void:
	if state != State.DEPLOY or _deploy_side != 1:
		return
	if not GameState.is_online or GameState.is_host:
		return   # 联机敌轮：只有客户端可点选（主机等待
	if not enemy_pool.has(hero_id):
		return
	_pending_enemy_deploy = hero_id   # 不从卡池扣除，保持布局不动
	state = State.PLACE_DEPLOY
	# 高亮敌方出生格（绿色我方出生区（蓝）保留
	_show_enemy_deploy_zones(Color(0.2, 0.85, 0.5, 0.7))
	deploy_refresh.emit()
	action_info.emit("点击敌方上阵的位置（绿色格）")

# 高亮敌方出生区（敌轮放位提示；我方出生区保持淡蓝
func _show_enemy_deploy_zones(enemy_color: Color) -> void:
	var pc := {}
	for c in _spawn_cells(DataRegistry.Faction.ENEMY):
		pc[c] = enemy_color
	for c in _spawn_cells(DataRegistry.Faction.PLAYER):
		pc[c] = Color(0.2, 0.6, 0.95, 0.45)
	_preview_cells = pc
	_apply_highlights()

func _try_place_deploy(cell: Vector2i) -> bool:
	if state != State.PLACE_DEPLOY or _pending_deploy == "":
		return false
	if not _in_spawn_cell(cell, DataRegistry.Faction.PLAYER):
		return false
	if occupancy.has(cell):
		return false
	var hid := _pending_deploy
	_pending_deploy = ""
	player_deployed.append(hid)
	player_pool.erase(hid)   # 上阵后才从卡池扣
	# 演出登场
	var u := _spawn_unit(hid, DataRegistry.Faction.PLAYER, cell)
	u.modulate.a = 0.0
	u.scale = Vector2(0.2, 0.2)
	var t := create_tween()
	t.tween_property(u, "modulate:a", 1.0, 0.35)
	t.parallel().tween_property(u, "scale", Vector2.ONE, 0.35)
	AudioManager.play("select")
	# 联机：把这次部署广播给对端（对端apply_deployment，保证两端一致）
	if GameState.is_online and NetBus.is_online:
		NetBus.send_all(JSON.stringify({ "type": "deploy", "faction": DataRegistry.Faction.PLAYER, "hero": hid, "cell": [cell.x, cell.y] }))
	_deploy_after_pick()
	return true

# 敌轮：客户端在敌轮（_deploy_side==1）把选中enemy 英雄放到敌方半场，并广播 ENEMY 部署给主机
func _try_place_enemy_deploy(cell: Vector2i) -> bool:
	if state != State.PLACE_DEPLOY or _pending_enemy_deploy == "":
		return false
	if not _in_spawn_cell(cell, DataRegistry.Faction.ENEMY):
		return false
	if occupancy.has(cell):
		return false
	var hid := _pending_enemy_deploy
	_pending_enemy_deploy = ""
	enemy_deployed.append(hid)
	enemy_pool.erase(hid)
	var u := _spawn_unit(hid, DataRegistry.Faction.ENEMY, cell)
	u.modulate.a = 0.0
	u.scale = Vector2(0.2, 0.2)
	var t := create_tween()
	t.tween_property(u, "modulate:a", 1.0, 0.35)
	t.parallel().tween_property(u, "scale", Vector2.ONE, 0.35)
	AudioManager.play("select")
	if GameState.is_online and NetBus.is_online:
		NetBus.send_all(JSON.stringify({ "type": "deploy", "faction": DataRegistry.Faction.ENEMY, "hero": hid, "cell": [cell.x, cell.y] }))
	_deploy_after_pick()
	return true

# 联机部署同步：网络收到对部署某单时调用，在本端对应阵营放置（faction/hero/cell）
# 主机/客户端双方各部署自己半场，最终主机汇总广-> 开战
func apply_deployment(faction: int, hero_id: String, cell: Vector2i) -> void:
	if not grid.in_bounds(cell) or occupancy.has(cell):
		return
	var u := _spawn_unit(hero_id, faction, cell)
	u.modulate.a = 0.0
	u.scale = Vector2(0.2, 0.2)
	var t := create_tween()
	t.tween_property(u, "modulate:a", 1.0, 0.35)
	t.parallel().tween_property(u, "scale", Vector2.ONE, 0.35)
	# 记录部署状态（供统收尾）——用同一deployed 列表
	if faction == DataRegistry.Faction.PLAYER:
		player_deployed.append(hero_id)
		player_pool.erase(hero_id)   # 与发起端 _try_place_deploy 一致：上阵后从卡池扣除（保证两roster 一致）
	else:
		enemy_deployed.append(hero_id)
		enemy_pool.erase(hero_id)

func _on_deploy_pick_again(hero_id: String) -> void:
	if state != State.PLACE_DEPLOY or _pending_deploy == "":
		return
	if hero_id == _pending_deploy:
		# 反悔：取消当前选中（英雄仍在卡池，位置不动
		_pending_deploy = ""
	elif player_pool.has(hero_id):
		# 切换：改选另一
		_pending_deploy = hero_id
		state = State.PLACE_DEPLOY
		_show_deploy_spawn_hint()
		deploy_refresh.emit()
		return
	else:
		return
	# 回到选人状态（取消当前选中
	state = State.DEPLOY
	# 恢复双方出生区提示（我方+ 敌方红），与开局一
	_show_deploy_zones(Color(0.2, 0.6, 0.95, 0.55))
	deploy_refresh.emit()
	action_info.emit("请点选要上阵的英雄（再次点击可反悔）")

# 联机敌轮：客户端放位阶段再次点敌方英雄可反悔/切换
func _on_enemy_deploy_pick_again(hero_id: String) -> void:
	if state != State.PLACE_DEPLOY or _pending_enemy_deploy == "":
		return
	if GameState.is_online and GameState.is_host:
		return
	if hero_id == _pending_enemy_deploy:
		# 反悔：取消当前选中（英雄仍在卡池，位置不动
		_pending_enemy_deploy = ""
	elif enemy_pool.has(hero_id):
		# 切换：改选另一
		_pending_enemy_deploy = hero_id
		state = State.PLACE_DEPLOY
		_show_enemy_deploy_zones(Color(0.2, 0.85, 0.5, 0.7))
		deploy_refresh.emit()
		return
	else:
		return
	# 回到选人状态（取消当前选中
	state = State.DEPLOY
	_show_deploy_zones(Color(0.2, 0.6, 0.95, 0.55))
	deploy_refresh.emit()
	action_info.emit("请点选要上阵的英雄（再次点击可反悔）")

# 高亮我方出生格（放位提示
func _show_deploy_spawn_hint() -> void:
	_show_deploy_zones(Color(0.2, 0.85, 0.5, 0.7))
	action_info.emit("点击我方能上阵的位置（绿色格）")

# 高亮双方出生区：我方player_color，敌方出生区固定红色（部署全程保留，放位阶段不消失）
func _show_deploy_zones(player_color: Color) -> void:
	var pc := {}
	for c in _spawn_cells(DataRegistry.Faction.PLAYER):
		pc[c] = player_color
	for c in _spawn_cells(DataRegistry.Faction.ENEMY):
		pc[c] = Color(0.95, 0.35, 0.3, 0.5)   # 敌方出生区红
	_preview_cells = pc
	_apply_highlights()

# 本端真人操作的部署轮判定：该轮需要本端真人上人（含已点英雄待放位）
# 单机=玩家（_deploy_side==0）；联机=本端对应半场轮（主机=玩家轮/0，客户端=敌轮/1）
func _my_deploy_turn() -> bool:
	if state != State.DEPLOY and state != State.PLACE_DEPLOY:
		return false
	if not GameState.is_online:
		return _deploy_side == 0 and player_deployed.size() < DEPLOY_COUNT_BATTLE
	if GameState.is_host:
		return _deploy_side == 0 and player_deployed.size() < DEPLOY_COUNT_BATTLE
	return _deploy_side == 1 and enemy_deployed.size() < DEPLOY_COUNT_BATTLE

# 轮次切换/开局时同步部署计时：本端全部选人共享一个总预算（30s，不按轮重置）
# 预算耗尽后：不再读秒；之后每次轮到自己上人，直接自动随机1 人（仍一轮一个、双方轮流）
func _sync_deploy_timer() -> void:
	if _my_deploy_turn():
		deploy_budget_active = true
		if deploy_budget_left <= 0.0:
			deploy_budget_active = false
			_auto_deploy_random()
	else:
		deploy_budget_active = false

# 预算耗尽的自动上人：从本端剩余卡*随机**挑一名未上阵英雄放到空格（时间结束随机上人）
# 已选中英雄待放位则先把该英雄放到空格；每次只上一人，回合轮换后继续补位直至上满
func _auto_deploy_random() -> void:
	if not _my_deploy_turn():
		return
	var fn := _my_faction()
	var cell := _free_spawn_cell(fn)
	if state == State.PLACE_DEPLOY:
		var sel := _pending_deploy if fn == DataRegistry.Faction.PLAYER else _pending_enemy_deploy
		if sel != "" and cell.x != -99:
			if fn == DataRegistry.Faction.PLAYER:
				_try_place_deploy(cell)
			else:
				_try_place_enemy_deploy(cell)
			return
		_pending_deploy = ""
		_pending_enemy_deploy = ""
		state = State.DEPLOY
	var pool: Array = player_pool if fn == DataRegistry.Faction.PLAYER else enemy_pool
	if pool.size() == 0:
		return
	var hid: String = pool[rng.randi_range(0, pool.size() - 1)]
	if fn == DataRegistry.Faction.PLAYER:
		_pending_deploy = hid
	else:
		_pending_enemy_deploy = hid
	state = State.PLACE_DEPLOY
	if cell.x != -99:
		if fn == DataRegistry.Faction.PLAYER:
			_try_place_deploy(cell)
		else:
			_try_place_enemy_deploy(cell)

# 首发专用评分：单体 + 与已首发协同 + 职能配比 + 首发阵容约束。
# 约束目标：① 别一次上两个坦克 ② 别全脆皮——前 3 首发要“输出+生存/控制”成组。
func _deploy_candidate_value(cand: String, deployed: Array) -> float:
	var s := _hero_strength(cand) + _deck_synergy(deployed, cand) + DataRegistry.role_balance_bonus(deployed, cand)
	var def := DataRegistry.get_hero(cand)
	if def == null:
		return s
	var role := DataRegistry.hero_role_name(cand)
	var cand_tank := role == "坦克"
	var cand_hard := _deploy_is_hard(cand)
	var tank_cnt := 0
	var hard_cnt := 0
	for id in deployed:
		var r := DataRegistry.hero_role_name(id)
		if r == "坦克":
			tank_cnt += 1
		if _deploy_is_hard(id):
			hard_cnt += 1
	# ① 已有坦克首发时，再上坦克大幅压价（避免双坦克开局）
	if cand_tank and tank_cnt >= 1:
		s -= 3.5
	# ② 防“全脆皮”：已首发两名且都脆 → 第三名必须是硬身板/控制，脆皮压价、硬身板加分
	if deployed.size() == 2:
		if hard_cnt == 0:
			s += 3.0 if cand_hard else -3.0
	# ③ 软性引导：前两手都是脆皮时，第三手优先硬身板（上面的强约束已覆盖），
	#    已有一名硬身板时再选坦克没必要地重复（交给职能配比整体压制）
	if cand_tank and tank_cnt >= 1 and hard_cnt >= 1:
		s -= 1.0
	return s

# “硬身板/控制型”判定：坦克 或 高血量(≥24) 或 功能（支援/光环/控制类）
func _deploy_is_hard(id: String) -> bool:
	var def := DataRegistry.get_hero(id)
	if def == null:
		return false
	if def.skills.has(DataRegistry.Skill.TAUNT) or def.skills.has(DataRegistry.Skill.LOGISTICS):
		return true
	if def.max_hp >= 24:
		return true
	return false

func _enemy_deploy() -> void:
	if state != State.DEPLOY or _deploy_side != 1:
		return
	if enemy_pool.size() > 0 and enemy_deployed.size() < DEPLOY_COUNT_BATTLE:
		# 上人策略：从卡池挑一与已上场敌人配合最的英雄作为首发，
		# 而不是简单按顺序 pop_front —保证首发阵容机制协同
		var best_i := -1
		var best_sc := -1e9
		for i in enemy_pool.size():
			var cand: String = enemy_pool[i]
			# 首发优先：带 <替补> 标签的英雄不主动首发（技能替补登场才触发，首发浪费）
			var cd: DataRegistry.HeroDef = DataRegistry.get_hero(cand)
			if cd != null and cd.skills.has(DataRegistry.Skill.BENCH):
				continue
			var sc := _deploy_candidate_value(cand, enemy_deployed)
			if sc > best_sc:
				best_sc = sc
				best_i = i
		# 若全部卡池都是替补型（best_i 无解），退而选协同最高的任意一
		if best_i < 0:
			best_i = 0
			var bs := -1e9
			for i in enemy_pool.size():
				var sc2 := _hero_strength(enemy_pool[i])
				if sc2 > bs:
					bs = sc2
					best_i = i
		var hid: String = enemy_pool[best_i]
		if _CONSOLE_AI_LOG:
			var rows: Array = []
			for i in enemy_pool.size():
				var cand2: String = enemy_pool[i]
				var cd2 := DataRegistry.get_hero(cand2)
				var is_bench: bool = cd2 != null and cd2.skills.has(DataRegistry.Skill.BENCH)
				var sc2 := _deploy_candidate_value(cand2, enemy_deployed) if not is_bench else _hero_strength(cand2)
				rows.append({ "n": cd2.display_name if cd2 != null else cand2, "role": DataRegistry.hero_role_name(cand2), "sc": sc2, "b": is_bench })
			rows.sort_custom(func(x, y): return x["sc"] > y["sc"])
			print("\n[AI首发部署] 第 %d 名首发（敌方，剩余 %d 人）" % [enemy_deployed.size() + 1, enemy_pool.size()])
			for r in rows.slice(0, mini(4, rows.size())):
				var mark := "（带<替补>标签，不首发）" if r["b"] else ""
				print("  - %s[%s]  价值%.1f%s" % [r["n"], r["role"], float(r["sc"]), mark])
			print("[AI首发部署] → 上阵 %s" % DataRegistry.get_hero(hid).display_name)
		enemy_pool.remove_at(best_i)
		enemy_deployed.append(hid)
		var cell := _free_spawn_cell(DataRegistry.Faction.ENEMY)
		if cell.x != -99 and cell.y != -99:
			_deploy_spawn_at(DataRegistry.Faction.ENEMY, hid, cell)
		_deploy_after_pick()

func _deploy_spawn_at(faction: int, hero_id: String, cell: Vector2i) -> void:
	var u := _spawn_unit(hero_id, faction, cell)
	u.modulate.a = 0.0
	u.scale = Vector2(0.2, 0.2)
	var t := create_tween()
	t.tween_property(u, "modulate:a", 1.0, 0.35)
	t.parallel().tween_property(u, "scale", Vector2.ONE, 0.35)

func _deploy_after_pick() -> void:
	state = State.DEPLOY   # 一次放置完成，回到"继续选人"模式
	if player_deployed.size() >= DEPLOY_COUNT_BATTLE and enemy_deployed.size() >= DEPLOY_COUNT_BATTLE:
		_begin_after_deploy()
		return
	if _deploy_side == 0:
		_deploy_side = 1
		if not GameState.is_online:
			_enemy_deploy.call_deferred()
		else:
			# 联机：敌轮轮到对端（客户端）真人选人，本端等
			action_info.emit("等待对方选人…" if GameState.is_host else "轮到你（敌方）选人：点选下方英雄")
	else:
		_deploy_side = 0
	deploy_refresh.emit()
	_sync_deploy_timer()   # 切换后的新轮是否本端真人决定是否限时
	_deploy_banner_if_my_turn()   # 队伍部署轮转：轮到本端时中央提示"轮到你部署队伍"

# 部署轮到本端真人操作时：屏幕中央弹横幅（与回合横幅同一通道/样式）。
# 预算耗尽后进入自动上人（deploy_budget_active=false），不再需要真人操作，不弹。
func _deploy_banner_if_my_turn() -> void:
	if _my_deploy_turn() and deploy_budget_active:
		turn_banner.emit("轮到你部署队伍")

func _begin_after_deploy() -> void:
	# 其余进入替补
	player_roster = player_pool.duplicate()
	enemy_roster = enemy_pool.duplicate()
	player_dead = 0
	enemy_dead = 0
	_preview_cells = {}
	_apply_highlights()
	log_message.emit("部署完成，对战开始！")
	state = State.IDLE
	_start_match()
	deploy_refresh.emit()   # 通知 HUD 收起部署界面
	_notify_team()          # 通知 HUD 显示下方队伍卡组

func _setup_hud() -> void:
	var hud := HUD.new()
	hud.bind(self)
	add_child(hud)

# ---- 棋盘自适应缩放:让 5 列棋盘宽基本占满屏幕宽度(同时高度不压到底部按钮)----
# 用 hex=1 的探针网格精确测量棋盘世界包围盒,按视口反推 hex(棋子文字随 hex 等比放大)
func _fit_hex_size() -> float:
	var probe := HexGrid.new(board_size.x, board_size.y, 1.0)
	probe.top_cap_cols = TOP_CAP_COLS
	var minx := INF
	var miny := INF
	var maxx := -INF
	var maxy := -INF
	for cell in probe.all_cells():
		var p := probe._raw_cell_to_world(cell)
		minx = min(minx, p.x)
		miny = min(miny, p.y)
		maxx = max(maxx, p.x)
		maxy = max(maxy, p.y)
	var w_units := (maxx - minx) + 2.0 * 1.0   # 左右各伸 横向顶点半宽(平顶 hex 顶点在 0°/180°,=1.0)
	var h_units := (maxy - miny) + 2.0 * 0.866   # 上下各伸 纵向顶点半高(60°/120° 顶点,=sin60°≈0.866)
	var vsize := get_viewport().get_visible_rect().size
	var margin := 10.0            # 棋盘距屏左右留白
	var top_reserve := 66.0       # 顶部回合栏(54) + 边距
	var bottom_reserve := 330.0   # 屏底: 替补队伍面板(高≈200 距底76)+按钮带,再留余量避免遮棋盘
	var fit_w := (vsize.x - margin * 2.0) / w_units
	var fit_h := (vsize.y - top_reserve - bottom_reserve) / h_units
	return clampf(minf(fit_w, fit_h), 40.0, 140.0)

# ---- 棋盘布局居中（按实际格子像素范围计算，兼容平顶布局----
func _board_origin() -> Vector2:
	var vsize := get_viewport().get_visible_rect().size
	var minx := INF
	var miny := INF
	var maxx := -INF
	var maxy := -INF
	# 用未翻转的原始几何算包围盒并居中（翻转是绕该包围盒中心旋180°，不改变包围盒，
	# 因此 origin 在翻/不翻下一致，棋盘保持居中不漂移）
	for cell in grid.all_cells():
		var p := grid._raw_cell_to_world(cell)
		minx = min(minx, p.x)
		miny = min(miny, p.y)
		maxx = max(maxx, p.x)
		maxy = max(maxy, p.y)
	var bw := (maxx - minx) + 2.0 * hex_size
	# 水平居中，顶部距屏幕90px
	return Vector2((vsize.x - bw) / 2.0 - minx + hex_size, 90.0 - miny + hex_size)

# ---- 开局放置：前 3 名上阵，其余进替补席 ----
func _place_units() -> void:
	player_roster = []
	enemy_roster = []
	# 若测试场景提供了自由放置，则按指定格直接放置
	if GameState.player_placement.size() > 0 or GameState.enemy_placement.size() > 0:
		for cell in GameState.player_placement.keys():
			if grid.in_bounds(cell):   # 防御：跳过越界格（棋盘尺寸不一致时避免开局失败/卡住）
				_spawn_unit(GameState.player_placement[cell], DataRegistry.Faction.PLAYER, cell)
		for cell in GameState.enemy_placement.keys():
			if grid.in_bounds(cell):
				_spawn_unit(GameState.enemy_placement[cell], DataRegistry.Faction.ENEMY, cell)
		_place_obstacles()
		_spawn_opening_items()   # 进入战斗即刷新开局道具（自由放置同样生效）
		log_message.emit("已按自由部署放置双方单位")
		if GameState.no_death_limit:
			# 自由部署沙箱：替补 = "该方队伍卡组里没上场的人"（我方为 8 人里未首发的 5 人）
			var used := {}
			for v in GameState.player_placement.values():
				used[v] = true
			for v in GameState.enemy_placement.values():
				used[v] = true
			_seed_sandbox_roster(GameState.player_deck, used, player_roster)
			_seed_sandbox_roster(GameState.enemy_deck, used, enemy_roster)
		return
	# —— placement 为空:走正常部署(默认卡组 3 上阵,其余替补)——
	var p_deck := GameState.player_deck
	var e_deck := GameState.enemy_deck
	if p_deck.size() == 0:
		p_deck = _default_deck()
	if e_deck.size() == 0:
		e_deck = _default_deck()
	player_roster = []
	enemy_roster = []
	# 玩家在下方最后一行；敌方在顶部出生区（顶帽行 + 最上面一排满行）
	var player_cells := [Vector2i(0, grid.height - 1), Vector2i(2, grid.height - 1), Vector2i(4, grid.height - 1)]
	# 3 名上阵（敌方_free_spawn_cell 在完整出生区依次落位
	for i in range(DEPLOY_COUNT):
		if i < p_deck.size():
			_spawn_unit(p_deck[i], DataRegistry.Faction.PLAYER, player_cells[i])
		if i < e_deck.size():
			var ec := _free_spawn_cell(DataRegistry.Faction.ENEMY)
			if ec.x != -99 and ec.y != -99:
				_spawn_unit(e_deck[i], DataRegistry.Faction.ENEMY, ec)
	# 其余进替补席
	for i in range(DEPLOY_COUNT, p_deck.size()):
		player_roster.append(p_deck[i])
	for i in range(DEPLOY_COUNT, e_deck.size()):
		enemy_roster.append(e_deck[i])
	_place_obstacles()
	_spawn_opening_items()   # 进入战斗即刷新开局道具（默认部署路径也刷一次；全局标志保证只放一次）
	log_message.emit("双方各上 %d 名英雄，另有 %d / %d 名替补待命。" % [DEPLOY_COUNT, player_roster.size(), enemy_roster.size()])

# 沙箱替补池：队伍里未上场的先进替补；若没给队伍卡组（兼容旧测试），退回"全英雄池减已上场"
func _seed_sandbox_roster(deck: Array, used: Dictionary, roster: Array) -> void:
	if deck.size() > 0:
		for hid in deck:
			if used.has(hid) or roster.has(hid):
				continue
			roster.append(hid)
		return
	var pool := DataRegistry.heroes.keys()
	pool.sort()
	for hid in pool:
		if used.has(hid):
			continue
		roster.append(hid)

const OBSTACLE_DUR := 3
func _place_obstacles() -> void:
	# 固定候选点随机 0-2 个障碍（按左下角=[1,1] 编号换算成代码坐标 y0=顶行）：
	# 你给的 [1,3][1,4][2,4][3,3][3,4][4,4][5,3][5,4] => (0,4)(0,3)(1,3)(2,4)(2,3)(3,3)(4,4)(4,3)
	var spots := [
		Vector2i(0, 4), Vector2i(0, 3), Vector2i(1, 3), Vector2i(2, 4),
		Vector2i(2, 3), Vector2i(3, 3), Vector2i(4, 4), Vector2i(4, 3),
	]
	_rng_shuffle(spots)
	var count := rng.randi_range(0, 2)
	var placed := 0
	for s in spots:
		if placed >= count:
			break
		if grid.in_bounds(s) and not occupancy.has(s) and not bombs.has(s) and not obstacles.has(s):
			obstacles[s] = OBSTACLE_DUR
			placed += 1
	_refresh_board()   # 新障碍绘制上屏（重开竞技场时旧障碍已reset 清空，此处同步显示新障碍
func _damage_obstacle(cell: Vector2i, amt: int) -> void:
	if not obstacles.has(cell):
		return
	var left: int = obstacles[cell] - amt
	if left <= 0:
		obstacles.erase(cell)
		log_message.emit("障碍物被摧毁")
	else:
		obstacles[cell] = left
	if board_view:
		board_view.obstacles = obstacles
		board_view.queue_redraw()

# 圣诞老人：在空地随机放置 n 个增益道具（"heal"/"atk"/"move"/"shield"
func _place_buff_items(u: Unit, n: int) -> void:
	var spots: Array = []
	for cell in grid.all_cells():
		if not occupancy.has(cell) and not obstacles.has(cell) and not bombs.has(cell) \
				and not buff_items.has(cell) and not graves.has(cell):   # 墓碑格不放道具
			spots.append(cell)
	_rng_shuffle(spots)
	var types: Array = ["heal", "atk", "move", "shield"]   # 圣诞老人的四种礼
	var placed := 0
	while placed < n and spots.size() > 0:
		var c: Vector2i = spots.pop_back()
		buff_items[c] = types[rng.randi() % types.size()]
		placed += 1
	if placed > 0:
		log_message.emit("%s 在空地放置了 %d 个增益道具。" % [u.display_name, placed])
		_refresh_board()

# 道具作用说明（右键查拾取用）
func item_desc(type: String) -> String:
	match type:
		"heal":
			return "恢复 3 点血"
		"atk":
			return "攻击+1"
		"move":
			return "移动+1"
		"shield":
			return "获得[圣盾]：抵挡一次受到的伤害"
		"gold":
			return "攻击+1（永久）、生命上限+3，并回复 3 点血（仅黄金矿工可拾取）"
	return "增益道具"

# 开局增益道具：开局时（首个行动方回合开始技执行点，两端同步同种子）在候选 4 格
# 放 2 个随机道具，类型为 攻击+1 / 圣盾 / 回复3血。跳过障碍/单位/炸弹/墓碑格，
# 保证不与障碍冲突；候选格被占不足 2 个时从其它空地补足（仍保证恰好 2 个且无冲突）。
func _spawn_opening_items() -> void:
	if _opening_items_spawned:
		return
	_opening_items_spawned = true
	var spots: Array = []
	for c in OPENING_ITEM_CELLS:
		if _opening_item_placeable(c):
			spots.append(c)
	_rng_shuffle(spots)
	var placed := 0
	while placed < 2 and spots.size() > 0:
		var c: Vector2i = spots.pop_back()
		buff_items[c] = OPENING_ITEM_TYPES[rng.randi() % OPENING_ITEM_TYPES.size()]
		placed += 1
	if placed < 2:
		# 候选格不够空（被障碍/单位挤占，少见）：从棋盘其它空地补足到 2 个
		var extra: Array = []
		for cell in grid.all_cells():
			if not OPENING_ITEM_CELLS.has(cell) and _opening_item_placeable(cell):
				extra.append(cell)
		_rng_shuffle(extra)
		while placed < 2 and extra.size() > 0:
			var c: Vector2i = extra.pop_back()
			buff_items[c] = OPENING_ITEM_TYPES[rng.randi() % OPENING_ITEM_TYPES.size()]
			placed += 1
	if placed > 0:
		log_message.emit("开局放置了 %d 个增益道具（攻击+1/圣盾/回复3血），走过即可拾取。" % placed)
		_refresh_board()

func _opening_item_placeable(c: Vector2i) -> bool:
	return grid != null and grid.in_bounds(c) and not occupancy.has(c) \
			and not obstacles.has(c) and not bombs.has(c) and not graves.has(c) and not buff_items.has(c)

# 黄金矿工：在随机空地放置一枚金矿（buff_items "gold" 类型
func _place_gold(u: Unit) -> void:
	var spots: Array = []
	for cell in grid.all_cells():
		if not occupancy.has(cell) and not obstacles.has(cell) and not bombs.has(cell) \
				and not buff_items.has(cell) and not graves.has(cell):   # 墓碑格不放金矿
			spots.append(cell)
	if spots.size() == 0:
		return
	var c: Vector2i = spots[rng.randi() % spots.size()]
	buff_items[c] = "gold"
	gold_left[c] = 3   # 金矿存在 3 个完整回合，每轮结束减 1，到 0 消失
	log_message.emit("%s 在 %s 丢下一块金矿（3 回合后消失）。" % [u.display_name, str(c)])
	_refresh_board()

# 金矿到期：每完整回合开始减 1；到 0 移除（只清理仍存在格上的金矿，防止与测试手清不一致）
func _tick_gold_age() -> void:
	if gold_left.size() == 0:
		return
	var changed := false
	for c in gold_left.keys():
		var left: int = gold_left[c] - 1
		if left <= 0:
			if buff_items.get(c, "") == "gold":
				buff_items.erase(c)
				log_message.emit("一块金矿风化消失了。")
			gold_left.erase(c)
			changed = true
		else:
			gold_left[c] = left
			changed = true
	if changed:
		_refresh_board()

func _refresh_board() -> void:
	if board_view:
		board_view.obstacles = obstacles
		board_view.bombs = bombs
		board_view.buff_items = buff_items
		board_view.graves = graves
		board_view.queue_redraw()

func _spawn_unit(hero_id: String, faction: int, cell: Vector2i) -> Unit:
	var def := DataRegistry.get_hero(hero_id)
	var u := Unit.new(def, faction, cell, hex_size * 0.9)
	# 技能：疾行 -> 移动+1
	if def.skills.has(DataRegistry.Skill.SWIFT):
		u.move_range += 1
	# 给单位挂上对应英雄的行为脚本（数值修技能逻辑），并调用出生钩
	u.behavior = HeroRegistry.create(hero_id)
	u.behavior.setup(self, u)
	u.behavior.on_spawn()
	u.position = board_view.cell_world_center(cell)
	u.hp_changed.connect(_on_unit_hp_changed)
	u.damaged.connect(_on_unit_damaged)
	u.died.connect(_on_unit_died)
	add_child(u)
	units.append(u)
	occupancy[cell] = u
	_sync_ranged_adjacent()   # 新单位上场：刷新远程被贴状
	return u

func _start_match() -> void:
	log_message.emit("对局开始！你率 3 名英雄迎战敌手")
	GameState.start_match(_first_side)
	if GameState.is_online:
		if GameState.is_host:
			# 联机：开局首回合由主机权威公布（与后续回合一致，begin_side 广播）
			# 否则客户端若按本地结果自行开首回合，可能与主机判定不一致，
			# 导致"先手提示写我方、状态栏却是敌方回合"
			NetBus.send_all(JSON.stringify({ "type": "begin_side", "side": _first_side, "round": GameState.round_number }))
			_begin_side(_first_side)
		# 联机客户端：不本地推进开局首回合，等主机的 begin_side 广播到达后再执行一次。
		# 必须在此 return：否则下方还会再执行一次 _begin_side（主机=同帧开两次首回合，
		# 客户端=本地开一次+广播到达再开一次），导致先手方回合开始技被触发两次
		# （如风语者光环给队友移动力 +2 而非 +1）。
		return
	# 单机：先选人方先行动（与部署阶段的选人顺序一致）
	_begin_side(_first_side)

# ---- 回合调度 ----
func _begin_side(side: int) -> void:
	if GameState.match_over:
		return   # 对局已结束（如烧死判负）：不再开新回替补界面
	_ending_side = false   # 新回合开始：解除"回合标记（含客方提交结束后的等待窗口
	AudioManager.play("turn")
	_turn_expired = false   # 新回合开始：清除上个回合的超时待提交标记
	state = State.ANIMATING   # 回合开始技能逐个演出期间锁定输入
	_in_begin_phase = true   # 演出期内阵亡先排队，结束再弹替补面板（避免面板插入回合开始流程）
	_clear_selection()       # 切回合：清除上回合选中单位及移攻击范围高亮（含客户端收begin_side 路径
	for u in units:
		u.reset_for_new_turn()
	# 古灵精怪：变身后的英雄在本方回合开始时还原为本源并重新变身
	# 只重即将开始回合的这一——变身后的形态应保持到下一次变
	# （对方回合结本方回合开始），而不是在我方回合结束时立刻打回原形
	# 必须连同行为脚本/技数名称一起还原：若只还原 hero_id
	# 行为脚本仍是上一变身的英雄（例如风语者），下一回合回合开始技
	# 就不会再触发 _transform，且风语者光环按 hero_id 的判定全部失效
	var side_fn := side_faction(side)
	for u in units:
		if u.alive and u.transform_base_id != "" and u.faction == side_fn:
			u.hero_id = u.transform_base_id
			_apply_base_hero(u, u.transform_base_id)
			u._update_name_label()
			u._update_tags_label()
			u.refresh_stats()
	_sync_ranged_adjacent()   # 回合切换：敌方移换位后刷新远程被贴身状
	_tick_statuses(side)   # 猛毒等：回合开始结
	# —— 回合开始顺序：先完成上一方回合阵亡留下的替补，再触发各英雄回合开始技 ——
	# 本端真人方（我方）的补位需要玩家点击选择，无法在此同步落位：
	# 打开替补面板并把"回合开始技"顺延到全部补位完成后再触发（见 _resume_after_sub）。
	# 必须走 _try_begin_next_sub 消费 1 个名额（否则落位完成后 more_subs 误判还有名额 → 重复弹面板）。
	if side == _my_side() and _pending_player_subs > 0 and _my_roster().size() > 0:
		# 先启动本端回合倒计时：等替补期间超时也能自动替补并结束回合（不会永久卡在面板）
		turn_time_left = TURN_TIME_LIMIT
		peer_turn_time_left = 0.0
		_time_sync_acc = 0.0
		if GameState.is_online:
			_send_turn_time_left()
		_defer_side_skills = true
		_try_begin_next_sub()
		return
	# 单机敌方（AI）待补位：先自动落位，再统一触发技能（联机敌方为对端真人，按其补位节奏同步）
	if not GameState.is_online and side != _my_side() and _pending_enemy_sub > 0 and enemy_roster.size() > 0:
		_start_placing_subs = true
		_place_enemy_sub()
		_start_placing_subs = false
	# —— 回合开始技（圣诞放道具/矿工放金矿等,内含 rng）——
	# 联机关键：两端的技能触发必须发生在"行动方补位全部完成"之后、且两端同一时点执行。
	# 若行动方还有待补,上面 1514 分支已 defer(先补位、后技能,return);此处只剩两种情况:
	#   1) 行动方=本端且无待补 → 本端执行技能,并广播 side_skills 让等待端在同一时机执行;
	#   2) 行动方≠本端(等待端) → 不自行执行,等 side_skills 广播到达后再执行(与行动端补位后的时点一致)。
	if GameState.is_online:
		if side == _my_side():
			if GameState.is_host:
				NetBus.send_all(JSON.stringify({ "type": "side_skills", "side": side, "round": GameState.round_number }))
			else:
				NetBus.send_to(1, JSON.stringify({ "type": "side_skills", "side": side, "round": GameState.round_number }))
			await _run_side_skills(side)
		else:
			_waiting_side_skills_round = GameState.round_number   # 等行动端广播后执行技能
		return
	await _run_side_skills(side)   # 单机:直接执行

# 回合开始技执行段（含演出、入场上/下文的计时/横幅）。
# 两端在同一触发点执行:行动方补位完成后(或无需补位时)由行动端广播 side_skills,两端同跑,
# 保证金矿/道具等 rng 落点与单位集合一致。单机/等待端均经由本函数统一收尾。
func _run_side_skills(side: int) -> void:
	# 金矿倒计时：每个完整回合（回合号变化）只减一次，两端同一时点同步执行
	if GameState.round_number != _gold_tick_round:
		_gold_tick_round = GameState.round_number
		_tick_gold_age()
	await _trigger_turn_start_all(side)   # 回合开始的角色技能（逐个触发+边框闪烁
	# 共鸣者：在回合开始技**之后**结算——死灵法师等召唤物、烈焰加攻等在技能阶段入场/生效，
	# 结算晚了会把它们算进"所有队友攻击之和"。
	_sync_echo(side_faction(side))
	# 让回合开始增益在牌面上可
	for u in units:
		if u.alive and u.faction == side_faction(side):
			u.refresh_stats()
	_in_begin_phase = false   # 演出结束：此间积压的阵亡已在队列中，下面统一开面板
	# 本端是否操作这一方：是我方回-> 进入我方输入；否则（对方回合）等AI
	if side == _my_side():
		# 我方回合
		turn_time_left = TURN_TIME_LIMIT   # 开始本端回合限
		peer_turn_time_left = 0.0
		_time_sync_acc = 0.0
		if GameState.is_online:
			_send_turn_time_left()   # 立即同步给对端（对方等待界面显示剩余时间）
		if _pending_player_subs > 0 and _my_roster().size() > 0:
			_try_begin_next_sub()
			return
		state = State.PLAYER_INPUT
		action_info.emit("你的回合（第 %d 回合）：点击一名己方英雄。" % GameState.round_number)
		turn_banner.emit("你的回合")
		# 不自动选中，由玩家点击选择
	else:
		# 敌方回合：不在本端操作，清零计时（等待对端真人行动时显示对端剩余
		turn_time_left = 0.0
		# 等待端初= 满额：行动方此刻也在开始自己的 90 秒计时，
		# 先以满额本地递减（回合切换演出期间对方广播未达也不消失），随后被广播校准
		if GameState.is_online:
			peer_turn_time_left = TURN_TIME_LIMIT
		# 敌方若有上一回合阵亡待替补：按阵亡数量在出生区自动落位，再开始敌方回
		if _pending_enemy_sub > 0 and enemy_roster.size() > 0:
			_place_enemy_sub()
		state = State.ENEMY_TURN
		if GameState.is_online:
			# 联机：敌方是真人，不AI，等待对端真人发指令
			action_info.emit("等待对方行动…")
			enemy_turn_waiting.emit()
		else:
			action_info.emit("敌方回合…")
			_run_enemy_turn.call_deferred()
		turn_banner.emit("敌方回合")

# 回合开始时结算永久/持续状
func _tick_statuses(faction: int) -> void:
	for u in units:
		if u == null or not is_instance_valid(u):
			continue
		if u.alive and u.faction == faction and u.has_status("poison"):
			var hp_before := u.hp
			u.take_damage(1, false, false, "猛毒")   # [猛毒]：圣盾可抵挡一次（抵挡则消耗圣盾不掉血）
			if u.hp < hp_before:
				log_message.emit("%s 受到[猛毒] 1 点伤害。" % u.display_name)
func side_faction(side: int) -> int:
	return DataRegistry.Faction.PLAYER if side == GameState.SIDE_PLAYER else DataRegistry.Faction.ENEMY

# ---- 视角辅助（联机：主机=玩家蓝，客户敌方/红；单机=玩家方）----
# 本端人类操作的是哪一方
func _my_faction() -> int:
	if GameState.is_online and not GameState.is_host:
		return DataRegistry.Faction.ENEMY
	return DataRegistry.Faction.PLAYER

func _my_side() -> int:
	return GameState.SIDE_ENEMY if _my_faction() == DataRegistry.Faction.ENEMY else GameState.SIDE_PLAYER

func _opp_side() -> int:
	return GameState.SIDE_ENEMY if _my_side() == GameState.SIDE_PLAYER else GameState.SIDE_PLAYER

# 对方（本端看到要打败的那一方）
func _opp_faction() -> int:
	return DataRegistry.Faction.ENEMY if _my_faction() == DataRegistry.Faction.PLAYER else DataRegistry.Faction.PLAYER

# 胜负判定用视角化的阵亡计数：本端"我方"阵亡 / "对方"阵亡
func _my_dead() -> int:
	return player_dead if _my_faction() == DataRegistry.Faction.PLAYER else enemy_dead
func _opp_dead() -> int:
	return enemy_dead if _my_faction() == DataRegistry.Faction.PLAYER else player_dead

# 本端"我方"替补/ "对方"替补/ 指定阵营替补席
func _my_roster() -> Array:
	return player_roster if _my_faction() == DataRegistry.Faction.PLAYER else enemy_roster

func _opp_roster() -> Array:
	return enemy_roster if _my_faction() == DataRegistry.Faction.PLAYER else player_roster

func _roster_of(fn: int) -> Array:
	return player_roster if fn == DataRegistry.Faction.PLAYER else enemy_roster

# 当前替补操作对应的替补席（HUD 选人面板用）
func _sub_roster() -> Array:
	return _roster_of(_sub_faction)

# 回合开始：该阵营单位的回合开始技能（逐个触发，带触发边框闪烁
func _trigger_turn_start_all(faction: int) -> void:
	# 遍历快照：触发中可能杀移除单位，避免抹除元素导致漏处理
	for u in units.duplicate():
		if u == null or not is_instance_valid(u):
			continue
		if u.alive and u.faction == faction:
			if _trigger_turn_start(u):
				u.flash_passive()
				if get_tree() == null:
					return   # 场景已释放（点击重开/reload）：安全退出，避免访问 null get_tree()
				await get_tree().create_timer(0.35).timeout

# 回合结束：该阵营单位的回合结束技能（逐个触发，带触发边框闪烁
func _trigger_turn_end_all(faction: int) -> void:
	# 遍历快照：触发中可能杀死单位（如骷髅兵消散），避免抹除元素导致漏处
	for u in units.duplicate():
		if u == null or not is_instance_valid(u):
			continue
		if u.alive and u.faction == faction:
			if _trigger_turn_end(u):
				u.flash_passive()
				if get_tree() == null:
					return   # 场景已释放：安全退出
				await get_tree().create_timer(0.35).timeout

# 共鸣者（hero_47）：己方回合开始时，"攻击力增加所有队友攻击力之和"直到我方回合结束。
# 先统一取样所有共鸣者的总和再逐个赋值（若有多名共鸣者，避免后者把前者的新加成又算进去）。
func _sync_echo(faction: int) -> void:
	var list: Array = []
	for u in units:
		if u == null or not is_instance_valid(u) or not u.alive:
			continue
		if u.faction == faction and u.hero_id == "hero_47" and u.skill_allowed():
			list.append(u)
	if list.size() == 0:
		return
	var sums := {}
	for u in list:
		var total := 0
		for v in units:
			if v == null or not is_instance_valid(v) or not v.alive:
				continue
			if v == u or v.faction != faction:
				continue
			total += v.effective_atk()
		sums[u] = total
	for u in list:
		u.echo_bonus = sums[u]
		u.refresh_stats()

# 单个共鸣者即时补算（替补登场/变身/任意入场）：立即按当前队友取和，插队也不耽误当回合。
func _sync_one_echo(u: Unit) -> void:
	if u == null or not is_instance_valid(u) or not u.alive or not u.skill_allowed():
		return
	var total := 0
	for v in units:
		if v == null or not is_instance_valid(v) or not v.alive:
			continue
		if v == u or v.faction != u.faction:
			continue
		total += v.effective_atk()
	u.echo_bonus = total
	u.refresh_stats()

# 己方回合结束时解除临时状态（含[附体]：被附体者属于该阵营的绑定一并解除）
func _clear_statuses(faction: int) -> void:
	for u in units:
		if u == null or not is_instance_valid(u):
			continue
		if u.alive and u.faction == faction:
			u.clear_temp_statuses()
			u.atk_buff = 0
			u.move_buff = 0
			u.echo_bonus = 0
			u.ramble_bonus = 0
			u.branch_override = false
			u.refresh_stats()
	# 附体：目标方（该阵营）回合结束时解除其身上的绑定
	if _possess_links.size() > 0:
		var keys := _possess_links.keys()
		for t in keys:
			if t == null or not is_instance_valid(t) or t.faction == faction:
				_possess_links.erase(t)

# 联机客户端：收到主机 turn_end 广播时补跑"刚结束方"的回合末结算
# （骷髅兵随回合结束消散、德鲁伊回合末治疗等），与主机 _end_side 里执行的一致。
# 原因：_end_side 是主机权威只在主机跑；若客户端不补，主机端骷髅消失而客户端端残留，
# 导致两端骷髅数量/占位不同步，进而后续召唤与行动全部错位。
func _apply_turn_end_sync(faction: int) -> void:
	if faction < 0 or get_tree() == null:
		return   # 场景已释放/无效：安全退
	await _trigger_turn_end_all(faction)
	if GameState.match_over:
		return
	_clear_statuses(faction)

# 对指定阵营的存活英雄统一扣血（回合结束伤害，只扣该方）
# 单机：直接本地扣；联机主机：本地扣后广播让客户端对同阵营重演（保持两端血量一致）
func _apply_round_damage_to(faction: int, amount: int) -> void:
	for u in units:
		if u.alive and u.faction == faction:
			u.take_damage(amount, false, false, "回合烧血")

# 某方（side）行动回合结束时的超回合扣血结算（第 11 回合起，扣血= 当前回合- 10）
# 每半回合结束各扣各：玩家回合结束扣玩家队、敌方回合结束扣敌方队（单机 AI 亦然）
func _settle_side_round_damage(side: int) -> void:
	if not GameState.should_apply_round_damage():
		return
	var amount := GameState.round_damage_amount()
	if amount < 1:
		return
	var fn := side_faction(side)
	if GameState.is_online and GameState.is_host:
		# 主机权威结算：本地扣 + 广播让客户端对同阵营执行相同扣血（不回环自身
		_apply_round_damage_to(fn, amount)
		NetBus.send_all(JSON.stringify({ "type": "round_damage", "faction": fn, "amount": amount }))
	else:
		# 单机：本地直接扣
		_apply_round_damage_to(fn, amount)

# ---- 胜负：一方累3 名英雄阵亡即判负 ----
func _check_win() -> bool:
	if GameState.no_death_limit:
		return _check_no_limit_end()
	# 一方累计阵3 人就判负（含替补阵亡）。用本端视角化计数：我方阵亡=判负，对方阵判胜
	var my_dead: int = _my_dead()
	var opp_dead: int = _opp_dead()
	if my_dead >= LOSS_DEATH_COUNT and opp_dead >= LOSS_DEATH_COUNT:
		# 同归于尽：判*对方负、本端胜**（全局赢家=本端阵营
		var winner := _my_side()
		GameState.end_match(winner)
		state = State.ENDED
		_clear_selection()
		log_message.emit("双方都阵亡达 %d 名，同归于尽——但判本端获胜（对方负）。" % LOSS_DEATH_COUNT)
		_emit_match_result(winner)
		return true
	if my_dead >= LOSS_DEATH_COUNT:
		var winner2 := _opp_side()
		GameState.end_match(winner2)
		state = State.ENDED
		_clear_selection()
		log_message.emit("败北……我方英雄阵亡达 %d 名。" % LOSS_DEATH_COUNT)
		AudioManager.play("win")
		_emit_match_result(winner2)
		return true
	if opp_dead >= LOSS_DEATH_COUNT:
		var winner3 := _my_side()
		GameState.end_match(winner3)
		state = State.ENDED
		_clear_selection()
		log_message.emit("胜利！敌方英雄阵亡达 %d 名。" % LOSS_DEATH_COUNT)
		AudioManager.play("win")
		_emit_match_result(winner3)
		return true
	return false

# 自由部署沙箱胜负：取消"3 名阵亡判负"；某方场上 0 存活且替补池已空 = 判负（另一方胜）。
func _check_no_limit_end() -> bool:
	var my_fn := _my_faction()
	var opp_fn := _opp_faction()
	var my_done: bool = _alive_count(my_fn) == 0 and _roster_of(my_fn).size() == 0
	var opp_done: bool = _alive_count(opp_fn) == 0 and _roster_of(opp_fn).size() == 0
	var winner := -1
	if my_done and opp_done:
		winner = _my_side()   # 同时打空：判本端胜（测试友好）
		log_message.emit("双方都无人可上——判本端获胜。")
	elif my_done:
		winner = _opp_side()
		log_message.emit("败北……我方已无人可上。")
	elif opp_done:
		winner = _my_side()
		log_message.emit("胜利！敌方已无人可上。")
	else:
		return false
	GameState.end_match(winner)
	state = State.ENDED
	_clear_selection()
	AudioManager.play("win")
	_emit_match_result(winner)
	return true

# 联机胜负展示：本端弹框，并把"全局赢家阵营"广播给对方，对方据此弹自己的胜负框
# 保证死亡即使只在一端结算，另一端也能立即显示对局结束。单机仅本地弹框
func _emit_match_result(winner_side: int) -> void:
	var local_win := (winner_side == _my_side())
	match_result.emit(local_win)
	if GameState.is_online and GameState.is_host:
		NetBus.send_all(JSON.stringify({ "type": "match_end", "winner": winner_side }))

func _dead_count(faction: int) -> int:
	return player_dead if faction == DataRegistry.Faction.PLAYER else enemy_dead

func _alive_count(faction: int) -> int:
	var n := 0
	for u in units:
		if u == null or not is_instance_valid(u):
			continue
		if u.alive and u.faction == faction:
			n += 1
	return n

# ---- 输入处理（全局鼠标点击---
func _unhandled_input(event: InputEvent) -> void:
	# 调试键（敌方回合测试替补用，仅在非本端回合生效）：
	#   F7 = 敌方回合，我方与敌方【所有】存活英雄各扣 20；
	#   F8 = 敌方回合，只给我方前 2 名存活英雄各扣 20；
	#   F9 = 敌方回合，直接击杀我方前 2 名存活英雄（扣 999）。
	if event is InputEventKey and event.pressed and not event.echo \
			and (event.keycode == KEY_F7 or event.keycode == KEY_F8 or event.keycode == KEY_F9):
		if GameState.match_running and GameState.active_side != _my_side():
			var ek: InputEventKey = event as InputEventKey
			var keycode := ek.keycode
			var dmg: int = 999 if keycode == KEY_F9 else 20
			var all_units: bool = keycode == KEY_F7
			var sides: Array = [DataRegistry.Faction.PLAYER, DataRegistry.Faction.ENEMY] if event.keycode == KEY_F7 else [_my_faction()]
			var log_parts: Array[String] = []
			for fn in sides:
				var hits := 0
				for u in units:
					if u != null and is_instance_valid(u) and u.alive and u.faction == fn:
						u.take_damage(dmg, false, false, "调试扣血")
						hits += 1
						if not all_units and hits >= 2:
							break
				log_parts.append("%s×%d" % ["敌方" if fn == DataRegistry.Faction.ENEMY else "我方", hits])
			log_message.emit("【调试】敌方回合扣血：%s 各 %d 伤" % ["、".join(log_parts), dmg])
		return
	# 右键查看卡面 / 生成物作用（任意时刻
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT:
		var cell := grid.world_to_cell(get_global_mouse_position() - board_view.board_origin)
		var u = occupancy.get(cell, null)
		if buff_items.has(cell):
			item_view_requested.emit(buff_items[cell])
		elif u != null:
			card_view_requested.emit(u)
		return
	# 非左键事件忽略（触屏拖拽用 motion 单独处理，放置类流程即时响应）
	if event is InputEventMouseButton and event.button_index != MOUSE_BUTTON_LEFT:
		return
	# 触屏手势（安卓/iOS）：短按=点击；按住不动=查看；按住移动=拖动英雄
	var is_touch := DisplayServer.is_touchscreen_available()
	# 放置类状态（部署/替补落位/炸弹选格）：即时放置，不做长按判定
	if state == State.PLACE_DEPLOY or state == State.PLACE_SUB or state == State.PLACE_BOMB:
		if event is InputEventMouseButton and event.pressed:
			var cell := grid.world_to_cell(get_global_mouse_position() - board_view.board_origin)
			if state == State.PLACE_DEPLOY:
				if _pending_enemy_deploy != "":
					_try_place_enemy_deploy(cell)   # 联机敌轮：客户端放敌方英雄
				else:
					_try_place_deploy(cell)
			elif state == State.PLACE_SUB:
				_try_place_sub(cell)
			else:
				_submit_bomb_place(cell)
		return
	if is_touch:
		# 属性卡浮层打开期间，落到本层的触摸分两类处理：
		# ① 长按查看后的松手(release)：_press_viewed 为真 → 请求 HUD 关闭浮层（松手自动收起）。
		# ② 点卡外的按下泄漏到本层：视为点外关闭，吞掉该按下（不在此格开始新手势）。
		# 其余（motion/无查看的孤 release）一律忽略，避免误动棋盘或重开卡面。
		if _unit_card_open:
			var rel := false
			if event is InputEventMouseButton:
				rel = not event.pressed and event.button_index == MOUSE_BUTTON_LEFT
			elif event is InputEventScreenTouch:
				rel = not event.pressed
			var press := false
			if event is InputEventMouseButton:
				press = event.pressed and event.button_index == MOUSE_BUTTON_LEFT
			elif event is InputEventScreenTouch:
				press = event.pressed
			if _press_viewed and rel:
				touch_view_end_requested.emit()   # 长按查看松手：自动关闭
				_press_active = false
				_press_seen = false
				_press_viewed = false
			elif press:
				touch_view_end_requested.emit()   # 点卡外的按下：关闭
				_press_active = false
				_press_seen = false
				_press_viewed = false
			return
		_handle_touch_gesture(event)
		return
	if state != State.PLAYER_INPUT:
		return
	# 硬门控：只有"当前行动== 本端阵营"时本端才能操作
	# 即使 state 被误置为 PLAYER_INPUT，本端也绝不响应（防止后手方在我方回合行动）
	if GameState.active_side != _my_side():
		return
	# 拖拽撤下：按住己方英雄（左键），拖到下方出生点释放即撤下
	if _drag_unit != null:
		if event is InputEventMouseButton and not event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			_finish_drag()
		elif event is InputEventMouseMotion:
			_drag_follow()
		return
	if event is InputEventMouseButton and event.pressed:
		var cell := grid.world_to_cell(get_global_mouse_position() - board_view.board_origin)
		var cu = occupancy.get(cell, null)
		if cu != null and cu.alive and cu.faction == _my_faction():
			_begin_drag(cu)
			return
		_on_cell_clicked(cell)

# ---- 触屏手势（安卓/iOS）----
# 短按=点击行动；按住不动超时=查看卡面/道具；按住移动=拖动我方英雄撤下。
# 按下时暂不执行任何操作，抬起/超时/移动后按判定分发。
func _handle_touch_gesture(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		# 属性浮层打开期间：新的按下应被浮层(GUI)消费(点外关闭)；落到本层的按下直接忽略，
		# 避免在旧格上开始新手势（与 _press_seen 配合杜绝"孤抬手重开卡面"）。
		if _unit_card_open:
			return
		# 长按查看在非我方回合也允许（等待时看敌方属性），但点击行动仅我方回合有效
		_press_seen = true
		_press_pos = get_global_mouse_position()
		_press_cell = grid.world_to_cell(_press_pos - board_view.board_origin)
		_press_time_ms = Time.get_ticks_msec()
		_press_unit = null
		var cu = occupancy.get(_press_cell, null)
		if cu != null and cu.alive and cu.faction == _my_faction():
			_press_unit = cu
		_press_active = true
		_press_viewed = false
		_press_drag_started = false
		return
	if event is InputEventMouseButton and not event.pressed:
		# 拖动中：交给拖拽收尾（撤下或取消）
		if _drag_unit != null:
			_finish_drag()
			_press_active = false
			_press_seen = false
			return
		# 没有对应按下的"孤抬起"（按下已被属性浮层 GUI 消费/在别处释放）：
		# 直接忽略，绝不用上次手势遗留的 _press_cell 误重开卡面（否则卡会"跟手"重弹）
		if not _press_seen:
			_press_active = false
			_press_viewed = false
			return
		_press_seen = false
		var was_viewed := _press_viewed
		var cell := _press_cell
		var drag_started := _press_drag_started
		_press_active = false
		if was_viewed:
			# 长按查看过：松手即关闭浮层（按住看、松手收起），不执行点击
			touch_view_end_requested.emit()
			return
		if drag_started:
			return   # 拖动过：抬起不当作点击
		if _press_active_clickable(cell):
			_on_cell_clicked(cell)
			return
		# 非我方回合（敌方回合/等待）：短按英雄/道具 = 直接查看属性，
		# 保持显示（不随松手关闭），关闭由点外部/点关闭按钮处理
		if state != State.ARENA_DRAFT and state != State.PLACE_DEPLOY and state != State.PLACE_SUB:
			var cu = occupancy.get(cell, null)
			if buff_items.has(cell):
				item_view_requested.emit(buff_items[cell])
			elif cu != null:
				card_view_requested.emit(cu)
		return
	if event is InputEventMouseMotion:
		if _drag_unit != null:
			_drag_follow()
			return
		if not _press_active or _press_viewed:
			return
		# 位移超过阈值 -> 拖动（仅按住我方英雄时），否则视为滑动取消本次点击
		if event.position.distance_to(_press_pos) > _PRESS_DRAG_PX:
			if _press_unit != null and GameState.active_side == _my_side():
				_begin_drag(_press_unit)
				_press_drag_started = true
				_drag_follow()
			else:
				_press_active = false   # 滑在空地/敌方上：取消，避免误操作
				_press_seen = false   # 取消的手势：其抬起不再当作有效手势处理

# 触屏：抬起时是否可当作点击（仅我方回合且处于可输入态）
func set_unit_card_open(open: bool) -> void:
	_unit_card_open = open
	if not open:
		# 卡面关闭 = 本次查看手势结束：清空触摸手势状态。
		# 否则长按查看中卡由 GUI 松手关闭时 Battle 收不到 release，残留的 _press_seen/
		# _press_cell 会让下一次"孤抬起"（点外部关卡的抬起漏到本层）误重开卡面。
		_press_active = false
		_press_seen = false
		_press_viewed = false
		_press_drag_started = false

func _press_active_clickable(_cell: Vector2i) -> bool:
	return state == State.PLAYER_INPUT and GameState.active_side == _my_side()

func _on_cell_clicked(cell: Vector2i) -> void:
	var clicked_unit = occupancy.get(cell, null)   # 可能null/单位；用真值判
	var my_f := _my_faction()
	# 点击己方单位 -> 选中（可继续行动者）；攻击过的英雄视为本回合已完成
	if clicked_unit != null and clicked_unit.alive and clicked_unit.faction == my_f:
		if _is_done(clicked_unit):
			action_info.emit("%s 本回合已完成行动。" % clicked_unit.display_name)
			return
		if selected == clicked_unit:
			_clear_selection()
			action_info.emit("已取消选择")
		else:
			_select(clicked_unit)
		return
	if selected != null:
		# 攻击：点击敌方单位且在合法目标内（含嘲讽限制），且本回合尚未攻击
		if clicked_unit != null and clicked_unit.alive and clicked_unit.faction != my_f and not selected.attacked_this_turn and _valid_targets(selected).has(clicked_unit) and _can_actively_attack(selected):
			submit_attack(units.find(selected), units.find(clicked_unit))
			return
		# 目标是敌方单位、可攻击、本回合未攻击，但不在当前格射程-> 显示该敌方可移动/攻击范围
		if clicked_unit != null and clicked_unit.alive and clicked_unit.faction != my_f and not selected.attacked_this_turn and _can_actively_attack(selected) and not _valid_targets(selected).has(clicked_unit):
			_preview_enemy(clicked_unit)
			return
		# 移动：点击可达空格（本回合尚未移动）
		if clicked_unit == null and not selected.moved_this_turn and reachable_map.has(cell):
			submit_move(units.find(selected), cell)
			return
		# 攻击障碍物：任何可主动攻击的英雄，点击射程内障碍即可-1血（伐木工额外-99
		if clicked_unit == null and not selected.attacked_this_turn and obstacles.has(cell) and enemy_cells.has(cell) and _can_actively_attack(selected):
			submit_attack_obstacle(units.find(selected), cell)
			return
	# 点击敌方单位：显示其移动/攻击范围（预览）+ 属
	if clicked_unit != null and clicked_unit.alive and clicked_unit.faction != _my_faction():
		_preview_enemy(clicked_unit)
		return
	_clear_selection()
	action_info.emit("请点击一名己方英雄")

func _skill_names(skills: Array) -> String:
	var out := ""
	for s in skills:
		match s:
			DataRegistry.Skill.TAUNT:
				out += " 嘲讽"
			DataRegistry.Skill.SWIFT:
				out += " 疾行"
			DataRegistry.Skill.INFILTRATE:
				out += " 渗"
			DataRegistry.Skill.LOGISTICS:
				out += " 后勤"
	return out

func _in_attack_range(a: Unit, b: Unit) -> bool:
	var d := grid.distance(a.cell, b.cell)
	if d < 1 or d > _effective_attack_range(a):
		return false
	# 血锁：只能沿直线攻击（6 条轴向方向），此处统一拦截直线外的目标
	if a.branch_override and not _is_straight_line_cells(a.cell, b.cell):
		return false
	# 障碍物阻挡攻击视线（血远程不能隔墙打；贴身攻击无中间格不受影响）
	# 坠炮手(hero_45)无视阻挡：弹道穿过障碍/单位/墓碑
	if not a.los_ignore and _attack_path_blocked(a.cell, b.cell):
		return false
	return true

# 从指定格出发、某单位能攻击到的目标（含嘲讽、远程动态）
# 与点击攻击判定(_valid_targets/_taunters_in_range)同口径：
# 嘲讽目标必须本身可被攻击到(视线通畅、血锁直线)才触发"只能打嘲讽"限制，
# 否则被墙挡住的嘲讽会把本可攻击的目标从高亮里误滤掉（"能打到的没标红"）。
func _attackable_from(u: Unit, from_cell: Vector2i) -> Array:
	var range_at := _effective_range_at(u, from_cell)
	# 坠炮手无视嘲讽：不收集嘲讽、不受"只能打嘲讽"限制
	var taunts: Array = []
	if not u.los_ignore:
		for v in units:
			if v.alive and v.faction != u.faction and v.skills.has(DataRegistry.Skill.TAUNT):
				var d := grid.distance(from_cell, v.cell)
				if d >= 1 and d <= range_at:
					if u.branch_override and not _is_straight_line_cells(from_cell, v.cell):
						continue
					if not u.los_ignore and _attack_path_blocked(from_cell, v.cell):
						continue
					taunts.append(v)
	var out: Array = []
	for v in units:
		if v.alive and v.faction != u.faction:
			var d := grid.distance(from_cell, v.cell)
			if d >= 1 and d <= range_at:
				if taunts.size() > 0 and not v.skills.has(DataRegistry.Skill.TAUNT):
					continue
				if u.branch_override and not _is_straight_line_cells(from_cell, v.cell):   # 血锁：只能直线攻击
					continue
				if not u.los_ignore and _attack_path_blocked(from_cell, v.cell):   # 障碍物阻挡视线（坠炮手无视）
					continue
				out.append(v)
	return out

func _effective_range_at(u: Unit, from_cell: Vector2i) -> int:
	if u.attack_type == DataRegistry.AttackType.RANGED and _enemy_adjacent_at(u, from_cell):
		return 1
	return u.attack_range

func _enemy_adjacent_at(u: Unit, from_cell: Vector2i) -> bool:
	for v in units:
		if v.alive and v.faction != u.faction and grid.distance(from_cell, v.cell) == 1:
			if _attack_path_blocked(from_cell, v.cell):
				continue   # 被障碍物隔断不算贴身
			return true
	return false

# 远程动态射程：有相邻敌人时射程降为 1；否则用基础射程(远程=2)
func _has_enemy_adjacent(a: Unit) -> bool:
	for v in units:
		if v.alive and v.faction != a.faction and grid.distance(a.cell, v.cell) == 1:
			# 被障碍物隔断的相邻攻击不被贴：只有彼此能实际交战(视线通畅)才算
			if _attack_path_blocked(a.cell, v.cell):
				continue
			return true
	return false

func _effective_attack_range(a: Unit) -> int:
	if a.attack_type == DataRegistry.AttackType.RANGED and _has_enemy_adjacent(a):
		return 1
	return a.attack_range

# 同步所有单位的"远程被贴标志（移攻击/回合切换后调用，用于面板与伤害结算）
func _sync_ranged_adjacent() -> void:
	for u in units:
		if u == null or not is_instance_valid(u):
			continue
		if u.alive and u.attack_type == DataRegistry.AttackType.RANGED:
			u.set_ranged_adjacent(_has_enemy_adjacent(u))
		else:
			u.set_ranged_adjacent(false)

# 下方队伍展示：只显示替补席（尚未上场、待替补的英雄）
# 已上阵的单位在棋盘上战斗、不在替补席；已死亡/已补位的也不在其中；
# 因此不会出现"百变精灵变身已上已死英雄混入下方队伍"的问题
# 竞技场选人阶段：返回我方已选英雄（实时更新）；否则返回替补席
func _player_team_ids() -> Array:
	if GameState.arena_mode and state == State.ARENA_DRAFT:
		if GameState.is_online:
			return _oa_my_kept.duplicate()   # 联机竞技场：显示自己已留下的英雄
		return _arena_picked.duplicate()
	# 永远显示本端"我方"的替补席（联机客户端=红方自己的替补，不随回合切换
	return _my_roster().duplicate()

# 单位/阵容变化后通知 HUD 刷新下方队伍展示
func _notify_team() -> void:
	team_updated.emit()

# ---- 部署期的本端视角 ----
# 本端"我方"部署卡池：主单机=PLAYER 池（蓝），客户端=ENEMY 池（红）
func _my_deploy_pool() -> Array:
	return player_pool if _my_faction() == DataRegistry.Faction.PLAYER else enemy_pool

# 本端"我方"已部署数量（部署面板标题用）
func _my_deployed_count() -> int:
	return player_deployed.size() if _my_faction() == DataRegistry.Faction.PLAYER else enemy_deployed.size()

func _opp_deployed_count() -> int:
	return enemy_deployed.size() if _my_faction() == DataRegistry.Faction.PLAYER else player_deployed.size()

# 攻击伤害：远程被贴身时基础攻击降为 1（buff 叠加，见 Unit.effective_atk
func _attack_damage(a: Unit) -> int:
	return a.effective_atk()

# 目标是否可被主动攻击（后勤不能主动攻击）
func _can_actively_attack(a: Unit) -> bool:
	return a.can_attack() and not _is_logistics(a)

# ---- 嘲讽规则：若攻击范围内存在带嘲讽的对立单位，则只能攻击嘲讽单----
func _taunters_in_range(a: Unit) -> Array:
	var out: Array = []
	for v in units:
		if v.alive and v.faction != a.faction and v.skills.has(DataRegistry.Skill.TAUNT) and _in_attack_range(a, v):
			out.append(v)
	return out

func _valid_targets(a: Unit) -> Dictionary:  # Unit -> true
	var taunts := _taunters_in_range(a) if not a.los_ignore else []   # 坠炮手无视嘲讽
	var out := {}
	for v in units:
		if v.alive and v.faction != a.faction and _in_attack_range(a, v):
			if taunts.size() > 0 and not v.skills.has(DataRegistry.Skill.TAUNT):
				continue
			if a.branch_override and not _is_straight_line(a, v):   # 血锁：只能直线攻击
				continue
			out[v] = true
	return out

# 血锁：判定 b 是否位于a 出发的某条六边形直线
func _is_straight_line(a: Unit, b: Unit) -> bool:
	return _is_straight_line_cells(a.cell, b.cell)

func _is_straight_line_cells(from_cell: Vector2i, to_cell: Vector2i) -> bool:
	var da := grid.axial_of(from_cell)
	var db := grid.axial_of(to_cell)
	var dx := db.x - da.x
	var dy := db.y - da.y
	if dx == 0 and dy == 0:
		return true
	# 归一化到基本步长，检查是否为 6 个轴向方向之一的整数
	var g := _gcd(abs(dx), abs(dy))
	var sx := int(dx / float(g))
	var sy := int(dy / float(g))
	var dirs: Array = [Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 1), Vector2i(-1, 0), Vector2i(0, -1), Vector2i(1, -1)]
	for d in dirs:
		if d.x == sx and d.y == sy:
			return true
	return false

func _gcd(a: int, b: int) -> int:
	while b != 0:
		var t := a % b
		a = b
		b = t
	return max(a, 1)

# 攻击视线：从 from 到 to 是否存在一条"全程无阻挡的最短路径"。
# 被 障碍物/单位/墓碑 阻挡：同轴唯一路径任一被挡即挡；斜向多条最短径只要还通一条就能打。
func _attack_path_blocked(from_cell: Vector2i, to_cell: Vector2i) -> bool:
	return grid.los_blocked(from_cell, to_cell, func(c):
		return obstacles.has(c) or graves.has(c) or occupancy.has(c))

# ---- 选中与高----
func _select(u: Unit) -> void:
	AudioManager.play("select")
	_do_select(u)

func _do_select(u: Unit) -> void:
	_clear_selection()
	selected = u
	u.set_selected(true)
	_compute_ranges(u)
	_apply_highlights()
	var info := "已选中 %s（HP %d，攻 %d）" % [u.display_name, u.hp, u.atk]
	if not u.moved_this_turn:
		info += "绿色可移动"
	if not u.attacked_this_turn:
		info += ("，可攻击" if not u.moved_this_turn else "") + "红色可攻击"
	# 展示该角色技能（含无关键词血锁等特殊效果
	var def := DataRegistry.get_hero(u.hero_id)
	if def != null and def.desc != "":
		info += "\n技能：%s" % def.desc
	action_info.emit(info)
	highlight_changed.emit()

func _clear_selection() -> void:
	if selected:
		selected.set_selected(false)
	selected = null
	if _preview_unit != null and is_instance_valid(_preview_unit):
		_preview_unit.set_highlight_ring(false)
	_preview_unit = null
	reachable_map = {}
	enemy_cells = {}
	_preview_cells = {}
	if board_view:
		board_view.clear_highlights()
	highlight_changed.emit()

# 敌方预览：点击敌方棋子显示其移动范围当前格可攻击范围"（不打断回合
func _preview_enemy(u: Unit) -> void:
	_clear_selection()
	_preview_unit = u   # 记录预览对象：其格由单位描边标识（与己方选中同粗细），不用格子黄底
	var pc := {}
	var reach := _move_reachable(u)
	for k in reach.keys():
		pc[k] = Color(0.35, 0.55, 0.95, 0.65)   # 蓝：敌方可移
	# 攻击范围：只显示"当前能直接攻击到的目
	var attack_cells := {}
	for v in _attackable_from(u, u.cell):
		attack_cells[v.cell] = true
	for c in attack_cells.keys():
		pc[c] = Color(1.0, 0.6, 0.25, 0.9)   # 橙：当前格可攻击
	_preview_cells = pc
	_apply_highlights()
	u.set_highlight_ring(true)   # 与选中己方同一细金边
	action_info.emit("%s（敌方）HP %d 攻击 %d · 可移动可攻击。" % [u.display_name, u.hp, u.effective_atk()])

func _compute_ranges(u: Unit) -> void:
	reachable_map = {}
	enemy_cells = {}
	# 移动（若本回合尚未移非眩晕）
	if not u.moved_this_turn and u.can_move():
		var reach := _move_reachable(u)
		for k in reach.keys():
			if not occupancy.has(k):
				reachable_map[k] = true
	# 攻击（若本回合尚未攻击、可攻击、且非后勤[不能主动攻击]
	if not u.attacked_this_turn and u.can_attack() and not _is_logistics(u):
		# 只显当前能直接攻击到的目标（无法自动移动后攻击，故不并集可达格）
		for v in _attackable_from(u, u.cell):
			if v.alive:
				enemy_cells[v.cell] = true
	# 可攻击射程内的障碍物（所有英雄都能攻击障碍）
	if not u.attacked_this_turn and u.can_attack() and not _is_logistics(u):
		for oc in obstacles.keys():
			var d := grid.distance(u.cell, oc)
			if d >= 1 and d <= _effective_attack_range(u):
				# 血锁：攻击障碍同样只能6 方向直线（与攻击敌方单位一致）
				if u.branch_override and not _is_straight_line_cells(u.cell, oc):
					continue
				if not u.los_ignore and _attack_path_blocked(u.cell, oc):
					continue   # 与攻击单位一致：中间有单位/障碍挡视线时打不到（坠炮手无视）
				enemy_cells[oc] = true

func _is_logistics(u: Unit) -> bool:
	return u.skills.has(DataRegistry.Skill.LOGISTICS)

# 计算单位可移动范围（考虑渗透技能：可穿越敌方格子但不可停靠；冻结尾生效；障碍物阻挡
func _move_reachable(u: Unit) -> Dictionary:
	# 大大骑士：冲锋——沿 6 *轴向**直线方向冲任意距离，直到被阻挡（移动力不封顶
	if u.hero_id == "hero_24":
		var out := {}
		var dirs: Array[Vector2i] = [Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 1), Vector2i(-1, 0), Vector2i(0, -1), Vector2i(1, -1)]
		for d in dirs:
			var ax := grid.axial_of(u.cell) + d
			while true:
				var off := grid.offset_of(ax)
				if not grid.in_bounds(off):
					break
				if occupancy.has(off) or obstacles.has(off) or graves.has(off):
					break
				out[off] = true
				ax += d
		return out
	var stop_forbidden := occupancy.duplicate()
	var path_blockers := occupancy.duplicate()
	if u.skills.has(DataRegistry.Skill.INFILTRATE):
		# 渗透：可穿过 双方单位 + 障碍/墓碑，只是不能停靠在任何被占/障碍/墓碑格
		path_blockers = {}
		for oc in obstacles.keys():
			stop_forbidden[oc] = true   # 障碍可穿行，但不可停靠
		for g in graves.keys():
			stop_forbidden[g] = true    # 墓碑可穿行，但不可停靠
	else:
		# 障碍墓碑同样阻挡通行——只写入本地拷贝，勿污染 occupancy
		for oc in obstacles.keys():
			stop_forbidden[oc] = true
			path_blockers[oc] = true
		for g in graves.keys():
			stop_forbidden[g] = true
			path_blockers[g] = true
	return grid.reachable(u.cell, u.effective_move(), stop_forbidden, path_blockers)

func _build_highlight_colors() -> Dictionary:
	var colors := {}
	for c in reachable_map.keys():
		colors[c] = Color(0.25, 0.75, 0.3, 0.7)
	for c in enemy_cells.keys():
		colors[c] = Color(1.0, 0.9, 0.45, 0.85)   # 可攻击：浅黄（与敌方单位的红区分开）
	if selected != null:
		colors[selected.cell] = Color(1.0, 0.85, 0.3, 0.9)
	for c in _preview_cells.keys():
		colors[c] = _preview_cells[c]   # 敌方预览覆盖
	return colors

func _apply_highlights() -> void:
	if board_view:
		board_view.set_highlights(_build_highlight_colors())

# ---- 网络指令（主机权威执行入口）----
# apply_command 由主机调用，按指令类型分发到对应 Battle 操作。cmd 形如
#   {"type":"move","u":int,"to":[x,y]}                  # u=units 索引，移动到 to
#   {"type":"attack","u":int,"t":int}                   # u 攻击 units[t]
#   {"type":"select","u":int}                           # 选中 units[u]
# 客户端不直接执行，只发指令给主机；主机执行后广播结果
func apply_command(cmd: Dictionary) -> void:
	var u_idx := int(cmd.get("u", -1))
	var u: Unit = units[u_idx] if u_idx >= 0 and u_idx < units.size() else null
	match String(cmd.get("type", "")):
		"move":
			var to: Vector2i = _v2(cmd.get("to"))
			if u != null and is_instance_valid(u) and u.alive:
				# 联机权威执行/回放：对端(敌方)操作按敌方回放处理(for_enemy=true)，
				# 避免主机把敌方英雄当作本端选中(金色选中框/行动范围不应出现在敌方单位上)
				_do_move(u, to, GameState.is_online and u.faction != _my_faction())
		"attack":
			var t_idx := int(cmd.get("t", -1))
			var t: Unit = units[t_idx] if t_idx >= 0 and t_idx < units.size() else null
			if u != null and t != null and is_instance_valid(u) and is_instance_valid(t) and u.alive and t.alive:
				_do_attack(u, t, GameState.is_online and u.faction != _my_faction())
		"select":
			if u != null and is_instance_valid(u) and u.alive:
				_select(u)
		"obstacle":
			var oc: Vector2i = _v2(cmd.get("cell"))
			if u != null and is_instance_valid(u) and u.alive and obstacles.has(oc):
				_do_attack_obstacle(u, oc)
		"bomb":
			# 炸弹人放置炸弹（联机主机执行 / 客户端回放重演同一条指令）
			var bc: Vector2i = _v2(cmd.get("cell"))
			if u != null and is_instance_valid(u) and u.alive and u.hero_id == "hero_35":
				_apply_bomb_cmd(u, bc)

# 攻击障碍物的完整副作用（两端重演一致）：扣行动 + 伤害 + AOE/穿透技+ 收尾
func _do_attack_obstacle(u: Unit, cell: Vector2i) -> void:
	if u == null or not is_instance_valid(u) or not u.alive:
		return
	if not obstacles.has(cell):
		return
	# 血锁：攻击障碍同样只能6 方向直线（权威执行处也校验，防绕UI 高亮
	if u.branch_override and not _is_straight_line_cells(u.cell, cell):
		return   # 非法目标直接忽略，不消耗行动（UI 高亮已过滤，此处为兜底）
	# 与攻击单位一致：中间有单位/障碍挡视线时打不到（权威兜底，防绕过高亮；坠炮手无视）
	if not u.los_ignore and _attack_path_blocked(u.cell, cell):
		return
	state = State.ANIMATING   # 演出期间锁定输入
	u.attacked_this_turn = true
	_clear_selection()
	# 演出：远1)投掷物飞向障碍命中；近战()攻击者向障碍轻挥一击。命中后统一结算
	var dist := grid.distance(u.cell, cell)
	if dist > 1:
		_launch_obstacle_projectile(u, cell)
	else:
		_melee_obstacle_hit(u, cell)

# 远程攻击障碍物：投掷物飞向障碍格，命中后结算
func _launch_obstacle_projectile(u: Unit, cell: Vector2i) -> void:
	var from := board_view.cell_world_center(u.cell)
	var to := board_view.cell_world_center(cell)
	var proj := Projectile.new()
	proj.position = from
	proj.rotation = (to - from).angle()
	add_child(proj)
	var flight := clampf(float(grid.distance(u.cell, cell)) * 0.08, 0.15, 0.4)
	var t := create_tween()
	t.tween_property(proj, "position", to, flight).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	t.tween_callback(func():
		proj.queue_free()
		_impact_obstacle(u, cell))

# 近战攻击障碍物：攻击者向障碍轻挥（小前冲+回位），命中后结算
func _melee_obstacle_hit(u: Unit, cell: Vector2i) -> void:
	var apos := board_view.cell_world_center(u.cell)
	var swing_to := apos.lerp(board_view.cell_world_center(cell), 0.3)
	var t := create_tween()
	t.tween_property(u, "position", swing_to, 0.1)
	t.tween_callback(func():
		if u == null or not is_instance_valid(u):
			return   # 攻击者在挥击演出期间被释放：中止
		var back := create_tween()
		back.tween_property(u, "position", apos, 0.08)
		back.tween_callback(func():
			if u != null and is_instance_valid(u):
				_impact_obstacle(u, cell)))

# 障碍受击命中：命中火花演+ 结算伤害（仅直接攻击的伤害，伐木工额99）
# 英雄技能（溅射/穿击退等）不再作用于障碍物，此处不触发任何英雄特技
func _impact_obstacle(u: Unit, cell: Vector2i) -> void:
	if u == null or not is_instance_valid(u) or not u.alive:
		return
	if not obstacles.has(cell):
		_after_player_action()
		return
	_obstacle_hit_fx(cell)
	var dmg := _hero(u).obstacle_damage()
	_damage_obstacle(cell, dmg)
	log_message.emit("%s 攻击障碍物。" % u.display_name)
	_after_player_action()

# 障碍受击火花：障碍格闪现一圈白色冲击波后消散
func _obstacle_hit_fx(cell: Vector2i) -> void:
	var center := board_view.cell_world_center(cell)
	var ring := RingFlash.new()
	ring.position = center
	add_child(ring)
	var t := ring.create_tween()
	t.tween_property(ring, "scale", Vector2(1.0, 1.0), 0.28).from(Vector2(0.2, 0.2))
	t.parallel().tween_property(ring, "modulate:a", 0.0, 0.28)
	t.tween_callback(ring.queue_free)

# 通用爆炸环演出（红帽自爆等）：在格心扩散一圈彩色冲击波后消散
func _boom_ring_fx(cell: Vector2i, color := Color(1.0, 0.6, 0.3), grow := 1.6, dur := 0.35) -> void:
	if board_view == null:
		return
	var ring := RingFlash.new()
	ring.color = color
	ring.position = board_view.cell_world_center(cell)
	add_child(ring)
	var t := ring.create_tween()
	t.tween_property(ring, "scale", Vector2(grow, grow), dur).from(Vector2(0.15, 0.15))
	t.parallel().tween_property(ring, "modulate:a", 0.0, dur)
	t.tween_callback(ring.queue_free)

# ---- 玩家操作提交（区单机 / 联机主机 / 联机客户端）----
# _on_cell_clicked 等界面输入调用：单机直接执行；联机客户端发指令给主机（不本地执行）；
# 联机主机本地执行并广播。返true 表示已提交
func submit_move(unit_idx: int, to: Vector2i) -> bool:
	var cmd := { "type": "move", "u": unit_idx, "to": [to.x, to.y] }
	return _dispatch_player_op(cmd)

func submit_attack(unit_idx: int, target_idx: int) -> bool:
	var cmd := { "type": "attack", "u": unit_idx, "t": target_idx }
	return _dispatch_player_op(cmd)

func submit_attack_obstacle(unit_idx: int, cell: Vector2i) -> bool:
	var cmd := { "type": "obstacle", "u": unit_idx, "cell": [cell.x, cell.y] }
	return _dispatch_player_op(cmd)

# 单机：本地执行。联机客户端：发主机（不本地执行）。联机主机：本地执行 + 广播
func _dispatch_player_op(cmd: Dictionary) -> bool:
	# 硬门控：当前行动== 本端阵营"才能提交行动（防止后手方走提交路径行动）
	if GameState.active_side != _my_side():
		return false
	if not GameState.is_online:
		apply_command(cmd)
		return true
	if GameState.is_host:
		apply_command(cmd)
		NetBus.send_all(JSON.stringify(cmd))
		return true
	# 客户端：只发指令给主机（主机 id=1），不本地执
	NetBus.send_to(1, JSON.stringify(cmd))
	return true

# 联机"再来一局"：不退出连接。主机权威重启——重随机种子并广播，双端重载 Main 场景重走部署/选卡
# 客户端点-> 发请求给主机；主机点击或收到请求 -> 广播 restart_new(新种+ 本端重载；客户端收到广播后重载
func request_rematch_online() -> void:
	if not GameState.is_online:
		return
	if GameState.is_host:
		_start_online_rematch()
	else:
		if not _rematch_requested:
			_rematch_requested = true
			NetBus.send_to(1, JSON.stringify({ "type": "restart_req" }))

func _start_online_rematch() -> void:
	if not GameState.is_host or _rematch_started:
		return
	_rematch_started = true
	# 复位对局级字段（保留 is_online/is_host/arena_mode/卡组；新场景 Battle._ready 据此重走正确分支
	GameState.round_number = 1
	GameState.match_over = false
	GameState.match_running = false
	GameState.surrender = false
	randomize()   # 全局 RNG 固定序列 -> 每局不同种子 -> 发牌/先后手随
	GameState.online_seed = randi()
	NetBus.send_all(JSON.stringify({ "type": "restart_new", "seed": GameState.online_seed }))
	get_tree().change_scene_to_file("res://scenes/Main.tscn")

func _apply_online_rematch(seed_value: int) -> void:
	# 客户端收到主机重启广播：同主机复位后重载 Main（同种子确定性开局
	GameState.online_seed = seed_value
	GameState.round_number = 1
	GameState.match_over = false
	GameState.match_running = false
	GameState.surrender = false
	get_tree().change_scene_to_file("res://scenes/Main.tscn")

# 对端退断线：联机对局中任一方离开（返回大关闭），另一端也要断开并回大厅，避免卡在对局里
func _on_net_disconnected() -> void:
	if not GameState.is_online:
		return
	if state == State.ENDED:
		return   # 已结算（胜负框在）：直接回大厅由结算按钮处理，不再额外跳
	GameState.reset_online()
	NetBus.stop()
	get_tree().change_scene_to_file("res://scenes/NetLobby.tscn")

# 收到对端消息：若是游戏指令，apply_command 执行/重演（主机收到客户端指令 -> 执行；客户端收到主机广播 -> 重演）
func _on_net_packet(_from_id: int, text: String) -> void:
	if not GameState.is_online:
		return
	var cmd: Variant = JSON.parse_string(text)
	if cmd is Dictionary:
		var t := String(cmd.get("type", ""))
		if t == "restart_req":
			# 客户端请再来一局" -> 主机权威重启（广播新种子；send_all 不回环，主机本地也重启）
			if GameState.is_host:
				_start_online_rematch()
			return
		if t == "restart_new":
			# 主机广播重启 -> 客户端应用新种子并重载（主机不接收自己的广播
			if not GameState.is_host:
				_apply_online_rematch(int(cmd.get("seed", 12345)))
			return
		if t == "turn_time":
			# 对端行动回合剩余秒数同步（本端等待时显示"对方 N 
			peer_turn_time_left = float(cmd.get("left", 0))
			return
		if t == "arena_pick":
			# 联机竞技场：客户端把每轮选择发给主机（主机收集齐双方后汇总广播）
			if GameState.is_host:
				if _oa_active:
					_oa_on_peer_pick(int(cmd.get("round", -1)), String(cmd.get("hero", "")))
				else:
					# 主机 draft 尚未初始化（同帧进入场景竞态）：缓存，启动时补
					_oa_pending.append({ "round": int(cmd.get("round", -1)), "hero": String(cmd.get("hero", "")) })
			return
		if t == "arena_done":
			# 主机已把双方卡组汇总好（选卡全部完成），客户端以广播为准进入部署
			if not GameState.is_host:
				_oa_apply_done(cmd.get("pdeck", []), cmd.get("edeck", []))
			return
		if t == "deploy":
			# 对端部署了一步：本端也放置，保证两端部署一致；随后按本地状态推进轮次（两端推进逻辑相同 -> 一致）
			apply_deployment(int(cmd.get("faction", 0)), String(cmd.get("hero", "")), _v2(cmd.get("cell")))
			if state == State.DEPLOY or state == State.PLACE_DEPLOY:
				_deploy_after_pick()
			return
		if t == "chat":
			# 联机快捷喊话:对端点选预置言论后发出,本端在顶部状态栏下方弹气泡
			var chat_txt := String(cmd.get("text", ""))
			if chat_txt != "":
				peer_message.emit(chat_txt)
			return
		if t == "begin_side":
			# 主机权威公布"当前行动回合：客户端据此同步 active_side/round 并执_begin_side
			# 主机本地已在 _end_side 里执行过 _begin_side，忽略自己的广播（broadcast 不回环，仍防御）
			GameState.sync_turn(int(cmd.get("side", GameState.active_side)), int(cmd.get("round", GameState.round_number)))
			if not GameState.is_host:
				_begin_side(GameState.active_side)
			return
		if t == "side_skills":
			# 行动方补位全部完成后广播：两端此刻才执行本回合回合开始技（同步 rng,金矿/道具落点一致）。
			# 行动方自己已在 _begin_side/_resume_after_sub 本地执行(广播不回环),这里处理"等待端"：
			# 等待端在 _begin_side 中登记了本回合,收到后执行并清除标记。
			var side2 := int(cmd.get("side", GameState.active_side))
			var rd2 := int(cmd.get("round", GameState.round_number))
			if rd2 == _waiting_side_skills_round and side2 != _my_side():
				_waiting_side_skills_round = -1
				_run_side_skills(side2)
			return
		if t == "turn_end":
			# 主机在开始回合末结算时广播：客户端同步消散该阵营骷髅等回合末技能，
			# 与主机同一时刻淡出（避免等 begin_side 才补、骷髅消失明显延迟）
			if not GameState.is_host:
				_apply_turn_end_sync(int(cmd.get("faction", -1)))
			return
		if t == "end_turn":
			# 只有主机执行回合推进；客户端不本地推进，等主机的 begin_side 广播
			if GameState.is_host:
				var s := int(cmd.get("side", -1))
				# 防重过期结束指令：指令对应的一方必须仍是当前行动方，且当前不在切回合结算中
				if s != GameState.active_side:
					return
				if state == State.ANIMATING:
					return
				_end_side(s)
			return
		if t == "sub":
			# 替补落位：两端重演同一"放置替补"逻辑。主机：本地执行 + 广播；客户端收到后重演
			# clear_side 由负责端判定（本次补完是否清该阵营墓碑），两端统一执行避免视角不同步
			_place_sub(int(cmd.get("faction", DataRegistry.Faction.PLAYER)), String(cmd.get("hero", "")), _v2(cmd.get("cell")), int(cmd.get("clear_side", -1)))
			if GameState.is_host:
				NetBus.send_all(text)
			return
		if t == "withdraw":
			# 主动撤下：两端一致把该单位撤下场（视为阵亡并可能触发替补）
			# 主机收到客户端指-> 权威执行 + 广播；客户端收到主机广播 -> 重演
			var w_idx := int(cmd.get("u", -1))
			var wu: Unit = units[w_idx] if w_idx >= 0 and w_idx < units.size() else null
			_apply_withdraw(wu)
			if GameState.is_host:
				NetBus.send_all(text)
			return
		if t == "round_damage":
			# 主机结算的本方回合超回合扣血广播：客户端对同阵营执行相同扣血（不回环主机，仅客户端收到）
			if not GameState.is_host:
				_apply_round_damage_to(int(cmd.get("faction", DataRegistry.Faction.PLAYER)), int(cmd.get("amount", 0)))
			return
		if t == "match_end":
			# 主机权威公布对局结束：客户端若尚未本地结算（死亡只发生在主机端），补结算并弹胜负框
			var winner := int(cmd.get("winner", GameState.SIDE_PLAYER))
			GameState.end_match(winner)
			if state != State.ENDED:
				state = State.ENDED
				_clear_selection()
				match_result.emit(winner == _my_side())
			return
		# 主机：收到客户端指令 -> 执行 + 广播；客户端：收到主机广-> 重演同一条指
		if GameState.is_host:
			apply_command(cmd)
			NetBus.send_all(text)
		else:
			apply_command(cmd)

# 数组字面[x,y] -> Vector2i
func _v2(a) -> Vector2i:
	if a is Array and (a as Array).size() >= 2:
		return Vector2i(int(a[0]), int(a[1]))
	return Vector2i.ZERO

# ---- 移动 ----
func _do_move(u: Unit, target_cell: Vector2i, for_enemy: bool) -> void:
	if u == null or not is_instance_valid(u):   # 防御：单位已释放则跳过
		return
	# 新规则：攻击后不能再移动（攻击是本回合最后动作；含联机对端指令兜底拦截）
	if u.attacked_this_turn:
		return
	# 目标已被其它单位占据 -> 拦截，避免覆盖 occupancy 造成重叠失联
	if occupancy.has(target_cell) and occupancy[target_cell] != u:
		_finish_move(u, for_enemy)
		return
	# AI 计划不应落到障碍格（防御性拦截）
	if obstacles.has(target_cell):
		_finish_move(u, for_enemy)
		return
	# 墓碑格阻挡移动（防御性拦截）
	if graves.has(target_cell):
		_finish_move(u, for_enemy)
		return
	state = State.ANIMATING
	# 记录移动距离（大大骑士冲锋加/ 风语者队友回血用）
	# 大大骑士的冲锋加成在下方路径算定后按"实际冲到格数"统一结算（含被阻挡剪裁的情况）
	u.last_move_dist = grid.distance(u.cell, target_cell)
	# 逐格路径（沿格子走；冲锋为直线格列；寻路失败则直奔目标）
	# 大骑士冲锋：逐格检查阻挡，途中遇障墓碑/其他单位即停在阻挡前—
	# 玩家 UI 的可达格本就挡墙（见 _move_reachable），此处兜底 AI/联机指令误算穿墙
	var path: Array
	if u.hero_id == "hero_24":
		path = []
		for c in _charge_line_cells(u.cell, target_cell):
			if occupancy.has(c) or obstacles.has(c) or graves.has(c):
				break
			path.append(c)
			if c == target_cell:
				break
	else:
		path = grid.find_path(u.cell, target_cell, _current_path_blockers(u))
		# 防御：find_path 在目标不可达时按约定也返回 [goal]（单格直跳）。
		# 若中间格在寻路后被新墓碑/新单位占据（敌方回放中我方英雄中途阵亡），
		# 禁止整段越过（否则敌方会穿过墓碑/单位）——保持墓碑/单位挡路规则一致：
		# 仅当目标确实相邻(距离1)才允许该"单步直跳"，否则本次移动放弃。
		if path.size() == 1 and grid.distance(u.cell, target_cell) > 1:
			path = []
		if path.size() == 0:
			_finish_move(u, for_enemy)
			return
	# 防御：无论调用方传入多远的目标，单次移动不得超过单位的实际移动力
	# 把路径截断到有效移动力步数，杜绝敌方 AI 计划偏差/偏移导致程移动
	var max_steps := u.effective_move()
	if u.hero_id == "hero_24":
		max_steps = 60   # 大骑士冲锋：直线冲任意距离，不截
	if path.size() > max_steps:
		path = path.slice(0, max_steps)
	if path.size() == 0:
		# 冲锋一步未动（面前被挡）：原地收尾，不传送；冲锋加成0 
		if u.hero_id == "hero_24":
			u.last_move_dist = 0
			u.ramble_bonus = 0
			u.refresh_stats()
		_finish_move(u, for_enemy)
		return
	var final_cell: Vector2i = path[path.size() - 1] if path.size() > 0 else target_cell
	# 冲锋被剪裁时实际冲到的格结算（避免穿墙落点前的加成虚高）
	if u.hero_id == "hero_24":
		u.last_move_dist = path.size()
		u.ramble_bonus = u.last_move_dist
		u.refresh_stats()
	occupancy.erase(u.cell)
	u.cell = final_cell
	occupancy[final_cell] = u
	_animate_step_path(u, path, 0, for_enemy)

# 沿路径逐格推进（每格一小步，走完再结算
func _animate_step_path(u: Unit, path: Array, idx: int, for_enemy: bool) -> void:
	if u == null or not is_instance_valid(u):   # 防御：单位已释放则停止
		return
	if idx >= path.size():
		_finish_move(u, for_enemy)
		return
	var cell: Vector2i = path[idx]
	var t := create_tween()
	t.tween_property(u, "position", board_view.cell_world_center(cell), 0.2)   # 每格移动略放
	t.tween_callback(func():
		# 炸弹：只有移动到路径终点(停下)才引爆；单纯经过中间的炸弹格不再爆炸
		var is_last := idx == path.size() - 1
		if not is_last or _bomb_enter_check(u, cell, for_enemy):
			_animate_step_path(u, path, idx + 1, for_enemy)
		else:
			_finish_move(u, for_enemy))

# 停在终点格时检测炸弹：非炸弹人停在炸弹格即引爆(经过不炸)。返回true表示单位仍可继续前进
func _bomb_enter_check(u: Unit, cell: Vector2i, _for_enemy: bool) -> bool:
	if u == null or not is_instance_valid(u):
		return true   # 单位已释放：不再继续判炸弹，安全退
	if u.hero_id == "hero_35":
		return true   # 炸弹人：经炸弹安
	if not bombs.has(cell):
		return true
	bombs.erase(cell)
	if board_view:
		board_view.bombs = bombs
		board_view.queue_redraw()
	log_message.emit("%s 踩中炸弹！" % u.display_name)
	u.take_damage(5, false, false, "踩中炸弹")
	return u.alive   # 爆炸致死 -> 停止前进（不再走完剩余路径）

# 统一炸弹触发：任意方式（击退/拉近/换位/瞬移/随机步…）让炸弹人以外的单位出现在炸弹格上都会引爆
# 检unit 当前所在格；若为炸弹格且非炸弹人则爆炸。供各位移落点调用
func _trigger_bomb(u: Unit) -> void:
	if u == null or not is_instance_valid(u) or u.hero_id == "hero_35":
		return   # 炸弹人安全；非单已释放跳
	if not bombs.has(u.cell):
		return
	bombs.erase(u.cell)
	if board_view:
		board_view.bombs = bombs
		board_view.queue_redraw()
	log_message.emit("%s 踩中炸弹！" % u.display_name)
	u.take_damage(5, false, false, "踩中炸弹")

# 冲锋（hero_24）：from 沿某*轴向**直线方向逐格直到 to 的直线格
func _charge_line_cells(from: Vector2i, to: Vector2i) -> Array:
	var dirs: Array[Vector2i] = [Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 1), Vector2i(-1, 0), Vector2i(0, -1), Vector2i(1, -1)]
	var fa := grid.axial_of(from)
	var ta := grid.axial_of(to)
	for d in dirs:
		var path: Array = []
		var cur := fa
		for i in range(60):
			cur += d
			var off := grid.offset_of(cur)
			if not grid.in_bounds(off):
				break
			path.append(off)
			if cur == ta:
				return path
	return [to]

# 计算当前单位移动时的通行阻挡（与 _move_reachable path_blockers 一致）
func _current_path_blockers(u: Unit) -> Dictionary:
	var blockers := occupancy.duplicate()
	if u.skills.has(DataRegistry.Skill.INFILTRATE):
		# 渗透：双方单位/障碍/墓碑都可穿行（不可停靠在别处控制），路径无阻挡
		blockers = {}
	else:
		for oc in obstacles.keys():
			blockers[oc] = true
		for g in graves.keys():
			blockers[g] = true
	return blockers

# 落到“增益道具/金矿”格时拾取（正常移动与强制位移共用：傀儡师推人、击退/换位等落点一致）
func _pickup_buff_at_cell(u: Unit) -> void:
	if u == null or not is_instance_valid(u):
		return
	if not buff_items.has(u.cell):
		return
	var btype: String = buff_items[u.cell]
	if btype == "gold" and u.hero_id != "hero_42":
		return   # 金矿只有黄金矿工可拾取：其他单位踩到不消费、金矿保留在格上
	buff_items.erase(u.cell)
	if btype == "gold":
		gold_left.erase(u.cell)   # 被拾取后不再倒计时
	if btype == "atk":
		u.atk_use_buff += 1   # 一次性：下一次攻1，攻击结算后消失
		u.refresh_stats()
		log_message.emit("%s 拾取攻击道具：下一次攻击 +1。" % u.display_name)
	elif btype == "move":
		u.move_use_buff += 1   # 一次性：下一次移1，移动后消失
		log_message.emit("%s 拾取移动道具：下一次移动力 +1。" % u.display_name)
	elif btype == "heal":
		# 回复3血可突破上限（溢出血：HP 暂时高于上限，受伤时先扣溢出的部分）
		u.hp += 3
		u.hp_changed.emit(u)
		u._update_hp_label()
		u.float_heal(3)
		log_message.emit("%s 拾取回血道具，恢复 3 点生命（可溢出上限）。" % u.display_name)
	elif btype == "shield":
		u.add_status("shield")   # 圣盾：抵挡一次受到的伤害（非叠加
		u.refresh_stats()
		log_message.emit("%s 拾取护盾道具，获得[圣盾]。" % u.display_name)
	elif btype == "gold":
		u.atk += 1
		u.perm_atk += 1   # 永久加成，变身时保留
		u.max_hp += 3
		u.hp = min(u.hp + 3, u.max_hp)
		u.refresh_stats()
		log_message.emit("%s 拾取金矿！攻击 +1（永久）、生命上限 +3 并回复 3 血。" % u.display_name)
	_refresh_board()

# 先移动到指定格、再攻击同一目标（合并的"移动+攻击"
func _finish_move(u: Unit, for_enemy: bool) -> void:
	if u == null or not is_instance_valid(u):   # 防御：单位已释放则跳过
		return
	var prev_move_buff := u.move_use_buff   # 移动开始前已有的移动 buff（本次移动应消耗的部分）
	u.moved_this_turn = true
	# 风语者光环：移动回血（自己不吃自己的光环，但场上另有风语者时互为"其他队友"可回血）
	if u.alive and u.last_move_dist > 0 and _has_other_wind_speaker(u):
		_heal(u, u.last_move_dist)
		log_message.emit("%s 移动 %d 格，风语者令其回复 %d 点生命。" % [u.display_name, u.last_move_dist, u.last_move_dist])
	# 炸弹爆炸：非炸弹人踏上炸弹格（已_bomb_enter_check 在逐格动画中处理：经过或停留均爆炸
	_pickup_buff_at_cell(u)   # 增益道具/金矿拾取（公共逻辑，强制位移也走这里）
	# 先刷远程被贴状态，再触发移动后技能——医护兵等用"移动攻击贴身状态结
	# （若贴身刷新在技能之后，远程医疗兵脱离贴身时的治疗会仍按贴身攻击算）
	_sync_ranged_adjacent()
	if u.alive:
		_trigger_on_move(u)   # 移动后技能（医护烛火/雪拳/末日等）
	# 圣诞老人移动 buff：只清掉"本次移动开始前已有（本次移动使用），本次才捡到的保留给下一次移动
	# 因为buff 靠走过去，此时本次移动已结算，不应把新捡的当作被本次移动用掉
	if prev_move_buff > 0:
		u.move_use_buff = maxi(u.move_use_buff - prev_move_buff, 0)
		u.refresh_stats()
	# 攻击道具的+1 只在攻击结算（主动攻击/反击）后消耗；后勤不能主动攻击，
	# 其整回合行动=移动，移动完成即视为该道具作废清掉，避免无限残留到以后回合
	if _is_logistics(u) and u.atk_use_buff > 0:
		u.atk_use_buff = 0
		u.refresh_stats()
	_clear_selection()
	if for_enemy:
		# 单机：action_finished 通知敌方 AI 回放循环继续下一招；
		# 联机：本端在回放"对端真人"的行动，没有 AI 回放循环——结束后回到"等待对方"状态，
		# 否则 state 会卡在 ANIMATING，随后对端发来的 end_turn 会被 state==ANIMATING 拦截而永远结束不了回合。
		if GameState.is_online:
			state = State.ENEMY_TURN
		else:
			action_finished.emit()   # 敌方移动动画+结算结束，通知回放继续
		return
	# 炸弹人：待选格放炸
	if _pending_bomb_unit == u:
		state = State.PLACE_BOMB
		_begin_bomb_place(u)
		return
	_continue_after_move(u)

# 移动后的通用收尾：还能攻击则继续选中该单位，否则进入回合结束判断
func _continue_after_move(u: Unit) -> void:
	# 替补面板已开/待落位期间：不恢复玩家输入（面板开着不能点其它英雄行动/再选中）。
	# 恢复交给替补落位完成后的 _resume_after_sub()。
	if _sub_faction != -1 or state == State.SUBSTITUTING or state == State.PLACE_SUB:
		return
	# 后勤不能主动攻击：移动后即完成，直接进入回合结束判断
	if _is_logistics(u):
		_after_player_action()
		return
	if not u.attacked_this_turn:
		state = State.PLAYER_INPUT
		_do_select(u)
		return
	_after_player_action()

# ---- 攻击（含近战反击---
func _do_attack(attacker: Unit, target: Unit, for_enemy: bool) -> void:
	state = State.ANIMATING
	_clear_selection()
	AudioManager.play("attack")
	log_message.emit("%s 攻击 %s。" % [attacker.display_name, target.display_name])
	# 远程且非贴身（距1）：发射投掷物飞向目标，命中后结算（不贴身突进）
	if attacker.attack_type == DataRegistry.AttackType.RANGED and grid.distance(attacker.cell, target.cell) > 1:
		_launch_projectile(attacker, target, for_enemy)
		return
	# 近战 / 远程贴身（距1）：原地出招（去掉突进冲锋），命中后结算（会被反击）
	_play_melee_hit(attacker, target, for_enemy)

# 近战出招：攻击者向目标小幅前冲做攻击动画，命中后结算伤害
# 结算完全结束后，才轮到反击（先攻击，后反击，动画与结算分开呈现）
func _play_melee_hit(attacker: Unit, target: Unit, for_enemy: bool) -> void:
	if attacker == null or not is_instance_valid(attacker) or target == null or not is_instance_valid(target):
		_finish_attack(attacker, for_enemy)
		return
	var apos := board_view.cell_world_center(attacker.cell)
	var hit_to := apos.lerp(board_view.cell_world_center(target.cell), 0.35)   # 攻击者轻冲接
	var t := create_tween()
	t.tween_property(attacker, "position", hit_to, 0.12)
	t.tween_callback(func():
		if attacker == null or not is_instance_valid(attacker):
			return   # 攻击者在出招演出期间被释放：中止本次近战动画
		# 命中：回到原位，再结算伤
		var back := create_tween()
		back.tween_property(attacker, "position", apos, 0.1)
		back.tween_callback(func(): _apply_attack(attacker, target, for_enemy)))

# 远程攻击演出：出生点生成投影物，沿直线飞到目标并命中
func _launch_projectile(attacker: Unit, target: Unit, for_enemy: bool) -> void:
	var from := board_view.cell_world_center(attacker.cell)
	var to := board_view.cell_world_center(target.cell)
	var proj := Projectile.new()
	proj.position = from
	# 朝向目标，拖尾自然指向飞行反方向
	proj.rotation = (to - from).angle()
	add_child(proj)
	var flight := clampf(grid.distance(attacker.cell, target.cell) * 0.08, 0.15, 0.4)
	var t := create_tween()
	t.tween_property(proj, "position", to, flight).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	t.tween_callback(func():
		proj.queue_free()
		_apply_attack(attacker, target, for_enemy))

func _apply_attack(attacker: Unit, target: Unit, for_enemy: bool) -> void:
	if attacker == null or not is_instance_valid(attacker) or target == null or not is_instance_valid(target):
		if for_enemy:
			# 单机：通知敌方 AI 回放继续；联机对端真人行动后回到等待状态，避免 state 卡 ANIMATING
			if GameState.is_online:
				state = State.ENEMY_TURN
			else:
				action_finished.emit()   # 捕获单位已释放：敌方回放仍须放行，避免卡
			return   # 捕获单位已释放（tween 回调期间free）：安全退
	var dmg := _attack_damage(attacker) * _bonus_damage(attacker, target)
	_attack_hp_before = target.hp   # 记录攻击前血量，供攻击后技能判定（古拉吸血等）
	# 攻击者专属战斗特效（贴合英雄机制
	if attacker.alive and attacker.hero_id == "hero_30" and target != null and is_instance_valid(target):
		# 嬉皮死神：专属镰刀弧形收割（唯一特效，不叠加通用光环，突死神镰刀"
		_spawn_scythe(attacker, target)
	if target.alive:
		# 长角未沉默：on_attack 统一结算基础伤害（击退倍，不能倍单次）
		# 长角被沉默：只做基础攻击伤害（技能击退/2倍失效）
		if not _hero(attacker).handles_base_damage() or not attacker.skill_allowed():
			target.take_damage(dmg, false, false, "被%s攻击" % attacker.display_name)
	_last_attacked = target
	# 攻击后技能在**命中瞬间**触发（如战锤麻痹/冰冻），让反击结算时已吃debuff
	_trigger_on_attack(attacker, _last_attacked, for_enemy)
	# 太阳斩：每次攻击后攻击力-1（立即显示，不等反击
	_hero(attacker).on_after_attack()
	# 反击：后勤单位也会反击（后勤不能主动攻击，但被近战攻击后会还手）
	# 普通单位默认每回合只能反击一次；复仇者（无限反击）不已用过一限制
	# 距离=1（近战互搏 / 贴身）：维持原规则，攻击范围内即可反击
	# 距离>1（远程对射）：仅当双方都是远程、且被攻击方没有被敌人贴身时，
	# 才以全额攻击力反击（被贴身=压制中：攻击降为1/技能失效，反击不了）
	var can_counter := false
	if target.alive and target.can_attack() and (not target.counter_used_this_turn or (target.skill_allowed() and _hero(target).infinite_counter())):
		var dist_c := grid.distance(attacker.cell, target.cell)
		if dist_c <= 1:
			can_counter = true
		elif attacker.attack_type == DataRegistry.AttackType.RANGED \
				and target.attack_type == DataRegistry.AttackType.RANGED \
				and not _has_enemy_adjacent(target) \
				and dist_c <= target.attack_range:
			can_counter = true   # 远程对射：目标未被贴身且攻击者在自己射程内，才可全额反击
	if can_counter:
		target.counter_used_this_turn = true
	_clear_selection()
	# 攻击结算完成：稍作停顿让攻击命中呈现完整，再开始反击（先攻击、后反击，动画与结算错开
	if can_counter:
		var gap := create_tween()
		gap.tween_interval(0.15)
		gap.tween_callback(func(): _play_counter(attacker, target, for_enemy))
	else:
		_finish_attack(attacker, for_enemy)

# 反击演出：反击者向攻击者轻冲一下再结算伤害，随后回到原
func _play_counter(attacker: Unit, target: Unit, for_enemy: bool) -> void:
	if not is_instance_valid(target) or not is_instance_valid(attacker):
		_finish_attack(attacker, for_enemy)
		return
	var counterer := target
	# 反击前先同步"远程被贴状态：战锤麻痹(-1)debuff 已在命中时施加，
	# 而远程被贴身时基础攻击应降（若不同步，反击者会按未贴身的基础攻击反击，伤害错误偏高）
	_sync_ranged_adjacent()
	var cdmg := counterer.effective_atk() * _counter_bonus(counterer, attacker)
	# 远程对射（距离>1）：反击者原地发射投掷物，不贴脸突进
	if grid.distance(counterer.cell, attacker.cell) > 1:
		_launch_counter_projectile(attacker, counterer, cdmg, for_enemy)
		return
	var cpos := board_view.cell_world_center(counterer.cell)   # 落点=自身格子中心（不受中途换瞬移影响
	var lunge_to := cpos.lerp(board_view.cell_world_center(attacker.cell), 0.62)   # 沿反向直线轻
	# 反击伤害 = 反击*实时攻击*（含buff/麻痹/冲锋加成，不套用远程相邻降攻
	AudioManager.play("attack")
	var ct := create_tween()
	ct.tween_property(counterer, "position", lunge_to, 0.1)
	ct.tween_callback(func():
		if not is_instance_valid(counterer):
			_finish_attack(attacker, for_enemy)
			return   # 反击者在演出期间被释放：跳过反击，正常收尾
		if is_instance_valid(attacker):
			log_message.emit("%s 反击 %s，造成 %d 伤害。" % [counterer.display_name, attacker.display_name, cdmg])
			attacker.take_damage(cdmg, false, true, "被%s反击" % counterer.display_name)
		# 反击也算一次攻击结算：消耗反击者携带的"攻击道具+1"（反击伤害已按该加成计入）
		if is_instance_valid(counterer) and counterer.atk_use_buff > 0:
			counterer.atk_use_buff = 0
			counterer.refresh_stats()
		var br := create_tween()
		br.tween_property(counterer, "position", cpos, 0.12)
		br.tween_callback(func():
			# 太阳斩：每次反击后攻击力-1，直到恢复正
			if is_instance_valid(counterer) and counterer.alive:
				_hero(counterer).on_after_counter()
			_finish_attack(attacker, for_enemy)))

# 远程对射反击演出：反击者原地发射投掷物飞向攻击者，命中全额结算（不贴脸）
func _launch_counter_projectile(attacker: Unit, counterer: Unit, cdmg: int, for_enemy: bool) -> void:
	if not is_instance_valid(counterer):
		_finish_attack(attacker, for_enemy)
		return
	var from := board_view.cell_world_center(counterer.cell)
	var to := board_view.cell_world_center(attacker.cell)
	var proj := Projectile.new()
	proj.position = from
	proj.rotation = (to - from).angle()
	add_child(proj)
	var flight := clampf(grid.distance(counterer.cell, attacker.cell) * 0.08, 0.15, 0.4)
	var t := create_tween()
	t.tween_property(proj, "position", to, flight).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	t.tween_callback(func():
		proj.queue_free()
		if is_instance_valid(attacker):
			log_message.emit("%s 反击 %s，造成 %d 伤害。" % [counterer.display_name, attacker.display_name, cdmg])
			attacker.take_damage(cdmg, false, true, "被%s反击" % counterer.display_name)
		# 反击也算一次攻击结算：消耗反击者携带的"攻击道具+1"（反击伤害已按该加成计入）
		if is_instance_valid(counterer) and counterer.atk_use_buff > 0:
			counterer.atk_use_buff = 0
			counterer.refresh_stats()
		# 太阳斩：每次反击后攻击力-1，直到恢复正
		if is_instance_valid(counterer) and counterer.alive:
			_hero(counterer).on_after_counter()
		_finish_attack(attacker, for_enemy))

func _finish_attack(attacker: Unit, for_enemy: bool) -> void:
	# 攻击者可能已在演出链中阵被释放（反击、炸弹、光环反伤等）：
	# 只在本步仍存活时改其状态；流程必须照常推进，否则敌方回放会卡死
	var alive_attacker := attacker != null and is_instance_valid(attacker) and attacker.alive
	if alive_attacker:
		attacker.attacked_this_turn = true
		# 圣诞老人攻击 buff：本次攻击已用掉，效果消
		if attacker.atk_use_buff > 0:
			attacker.atk_use_buff = 0
			attacker.refresh_stats()
	_sync_ranged_adjacent()   # 攻击后（换位/击退/拉近）相邻关系变化：刷新远程被贴身状
	if _check_win():
		return
	if for_enemy:
		# 单机：action_finished 通知敌方 AI 回放循环继续；联机对端真人行动后回到等待状态
		if GameState.is_online:
			state = State.ENEMY_TURN
		else:
			action_finished.emit()   # 敌方攻击（含反击）演出结束，通知回放继续
		return
	# 攻击后本回合行动结束：不再允许"攻击后还能移动"（规则：攻击过=行动完）
	_after_player_action()

func _after_player_action() -> void:
	# 替补面板已开/待落位期间：不在这里恢复玩家输入（否则面板开着还能点其它英雄行动）。
	# 恢复交给替补落位完成后的 _resume_after_sub() 统一处理。
	if _sub_faction != -1 or state == State.SUBSTITUTING or state == State.PLACE_SUB:
		return
	if _has_remaining_player():
		state = State.PLAYER_INPUT
		# 不自动选中下一个，由玩家点击（也可点结束回合提前结束）
		action_info.emit("还有英雄未完成行动：点击选择，或点「结束回合」")
	else:
		# 我方英雄全部行动完毕：不自动结束回合，提示玩家手动点「结束回合
		state = State.PLAYER_INPUT
		action_info.emit("所有英雄已完成行动，点「结束回合」交给敌方")

# 某单位是否已完成本回合行动。
# 新规则：攻击后不能再移动 → 普通单位攻击过即算完成（无论此前是否移动过）；
# 后勤不能攻击，只移动，移动后即完成。
func _is_done(u: Unit) -> bool:
	if _is_logistics(u):
		return u.moved_this_turn   # 后勤：只移动，移动后即算完成
	return u.attacked_this_turn    # 普通单位：攻击是最后动作，攻击过=本回合完成

func _has_remaining_player() -> bool:
	for u in units:
		if u.alive and u.faction == _my_faction() and not _is_done(u):
			return true
	return false

func _end_player_side() -> void:
	_end_side(GameState.SIDE_PLAYER)

# 结束某一方回合。side = 刚结束行动的一方
# 联机下仅在主机执行（主机是回合推进的唯一权威），随后广播 begin_side 给客户端同步
func _end_side(side: int) -> void:
	if _check_win():
		return
	_ending_side = true   # 结束/结算期间阵亡的替补一律推迟到本方下回合再
	state = State.ANIMATING   # 回合结束技能逐个触发期间锁定输入
	_clear_selection()       # 结束回合：清除选中单位及其移动/攻击范围高亮，避免残
	# 联机：开始回合末结算的同一时刻广播 turn_end，让客户端同步开始骷髅消散等
	# 回合末技能（与主机淡出同时进行，避免客户端等 begin_side 才补、消失明显延迟）
	if GameState.is_online and GameState.is_host:
		NetBus.send_all(JSON.stringify({ "type": "turn_end", "faction": side_faction(side) }))
	await _trigger_turn_end_all(side_faction(side))
	_clear_statuses(side_faction(side))
	# 11 回合起：本方回合结束只扣本方的血（双方各自回合结束各扣各，不一起扣
	_settle_side_round_damage(side)
	if GameState.match_over:
		_ending_side = false
		return   # 结算扣血导致本局已结束（如超回合烧死判负）：不再推进回合/开下回合界
	# 排空淡出中的死亡结算（与敌回合末一致）：先让本回合内死亡全部落定（墓碑/替补统计），
	# 再打印"回合结束"并切边，避免死亡结算撞上回合切换、日志/补位顺序错乱
	await _drain_pending_deaths()
	if _CONSOLE_SUB_LOG:
		print("[替补统计] 我方回合结束：我还可替补次数=%d" % _my_sub_quota())
	_ending_side = false   # 结算完毕：之后（含换边演出期间）的阵亡恢复正常替补规
	GameState.end_current_side(_first_side)
	# 换边停顿：让"上一方回合结束的演出"下一方回合开始被动的演出"之间
	# 有可感知间隔，不会首尾相连。停顿在 _begin_side 之前，故也先于下回合被动触发
	await get_tree().create_timer(0.8).timeout
	# 主机权威：先广播"新回合开（active_side 已推进、附当前回合号），再执行 _begin_side
	# 即使 _begin_side 内部因替补等提前 return，客户端也能正确同步并进入等操作
	if GameState.is_online and GameState.is_host:
		NetBus.send_all(JSON.stringify({ "type": "begin_side", "side": GameState.active_side, "round": GameState.round_number }))
	await _begin_side(GameState.active_side)

# 联机结束回合入口：我方点"结束回合"
func submit_end_turn() -> bool:
	# 仅当前行动方是我方时才可结束
	if GameState.active_side != _my_side():
		return false
	if state != State.PLAYER_INPUT:
		return false
	var cmd := { "type": "end_turn", "side": GameState.active_side }
	if not GameState.is_online:
		_end_side(GameState.active_side)
		return true
	# 联机：回合推进由主机唯一权威执行。客户端只把"我结束回发给主机，不本地推进
	if GameState.is_host:
		# 主机本地推进（_end_side 末尾会广begin_side 给客户端同步
		_end_side(GameState.active_side)
	else:
		NetBus.send_to(1, JSON.stringify(cmd))
		# 客户端也同步清掉本阵营回合临时状态（烈焰祭司 +1 攻等按回合结束生效的 buff），
		# 否则主机权威清除后，本端画面上的 buff 会跨回合残留叠加
		_clear_statuses(_my_faction())
		# 本端回合已提交结束：在收到主begin_side 广播前都视为"回合末窗
		# 此期间本阵营因烧血/结算死亡只计名额、不立即弹替补（避免替补通道在切回合中途被卡住）
		_ending_side = true
		state = State.ANIMATING   # 防止在主机回包前反复点击"结束回合"重复结算
	return true

func _on_unit_hp_changed(_u: Unit) -> void:
	pass

# 单位受到伤害时触发的被动机制（光环类：圣塔盾/锤头鲨，交由各英雄脚本处理）
func _on_unit_damaged(u: Unit, amount: int) -> void:
	for s in units:
		if s.alive and s.skill_allowed():
			_hero(s).on_someone_damaged(u, amount)

# 塔盾主动减免：在目标受伤害结*之前**调用
# 若目标相邻有同阵营塔hero_11)且本次伤1，则塔盾代替承受1点：
# 目标实际伤害，塔盾扣1血（直接扣，避免递归再触发塔盾）
# 返回目标应受到的实际伤害。塔盾未生效时返回原伤害
func _bulwark_absorb(target: Unit, dmg: int) -> int:
	if dmg <= 1:
		return dmg
	if target == null or not target.alive:
		return dmg
	for s in units:
		if s.alive and s != target and s.hero_id == "hero_11" and s.faction == target.faction \
				and grid.distance(s.cell, target.cell) == 1 and s.skill_allowed():
			# 塔盾代替承受1点（直接扣血，不触发塔盾递归/伤害后钩子）
			s.hp = max(s.hp - 1, 0)
			s.hp_changed.emit(s)
			s._update_hp_label()
			if s.hp <= 0:
				s.die()
			elif s.is_inside_tree():
				# 演出：塔盾亮起蓝色守护特效（扩散环+粒子+飘字），提示这次伤害被格挡
				s.burst_fx(DataRegistry.hero_fx("hero_11").color, "格挡")
			log_message.emit("%s 的塔盾代替承受 1 点伤害。" % s.display_name)
			return dmg - 1
	return dmg

# ============ 角色专属技能效果系============

# 返回某单位的行为脚本（英雄技能实现）。兜底返HeroBase 空实例
func _hero(u: Unit) -> HeroBase:
	if u == null or not is_instance_valid(u):
		return HeroBase.new()
	if u.behavior == null:
		u.behavior = HeroRegistry.create(u.hero_id)
		u.behavior.setup(self, u)
	return u.behavior


# 攻击/反击的伤害倍率（乘在基础伤害上）
func _bonus_damage(attacker: Unit, target: Unit) -> int:
	if not attacker.skill_allowed():   # 沉默：被动伤害倍率失效
		return 1
	if attacker.attack_type == DataRegistry.AttackType.RANGED and _has_enemy_adjacent(attacker):
		return 1   # 远程被贴身：不触发伤害倍率技
	return _hero(attacker).damage_mult(target)

func _counter_bonus(defender: Unit, _attacker: Unit) -> int:
	if not defender.skill_allowed():   # 沉默：反击倍率失效
		return 1
	return _hero(defender).counter_mult()

func _is_lowest_hp(u: Unit) -> bool:
	var lowest := u.hp
	for v in units:
		if v.alive and v.hp < lowest:
			return false
	return true

# 目标是否未与其他敌人相邻（排除攻击者自身）
func _is_isolated(target: Unit, attacker: Unit) -> bool:
	# 只考虑与目标同阵营其他敌人"（对攻击者是敌人）；不纳入攻击者队友与障碍
	for v in units:
		if v.alive and v != target and v != attacker and v.faction == target.faction and grid.distance(target.cell, v.cell) == 1:
			return false   # 有同阵营敌人相邻 目标不孤
	return true

# 攻击后的角色专属技能（target 可能null
func _trigger_on_attack(u: Unit, target: Unit, _for_enemy: bool) -> void:
	if target == null or not target.alive:
		if target != null and not u.skill_allowed():
			return
		if target != null and u.attack_type == DataRegistry.AttackType.RANGED and _has_enemy_adjacent(u):
			return   # 远程被贴身：技能效果无法造成（死亡目标也一样）
		if target != null:
			_hero(u).on_attack_dead(target)   # 目标被打死时的专属效果（暗域占据/长剑穿透/白游侠AOE/超新星击退）
			return
	if not u.skill_allowed():   # 沉默：无法触发攻击后技能
		return
	if u.attack_type == DataRegistry.AttackType.RANGED and _has_enemy_adjacent(u):
		return   # 远程被贴身：射程/攻击降为1，且技能效果无法造成
	_hero(u).on_attack(target)

func _add_status_msg(u: Unit, status: String, label: String) -> void:
	u.add_status(status)
	u.refresh_stats()   # 状态变化后刷新牌面数值（如麻痹导致攻击数字回落）
	log_message.emit("%s 获得[%s]。" % [u.display_name, label])

# [附体]：宿魂攻击后令敌人绑定。属负面标记（负墟免疫，命中计数攻+1）。
# 不叠加（后附覆盖先附）；目标方回合结束时由 _clear_statuses 解除（含单位状态与绑定表）。
func _possess_attach(caster: Unit, target: Unit) -> void:
	if caster == null or target == null or not is_instance_valid(caster) or not is_instance_valid(target):
		return
	if not target.alive or target.faction == caster.faction or target == caster:
		return
	target.add_status("possess")   # 负墟免疫时此处不会挂上状态（add_status 拦截并返回）
	if not target.has_status("possess"):
		return   # 免疫成功（负墟等）：不建立绑定
	_possess_links[target] = caster
	log_message.emit("%s 令 %s 获得[附体]。" % [caster.display_name, target.display_name])

# [附体] 镜像：施加者受伤 dmg>0 时，其所有被附体存活目标同受同等伤害。
# 目标侧圣盾/重伤按其自身规则结算；递归深度上限防两宿魂互附死循环。
func _possess_mirror(caster: Unit, dmg: int) -> void:
	if caster == null or dmg <= 0 or _possess_depth >= 8:
		return
	_possess_depth += 1
	var keys := _possess_links.keys()
	for t in keys:
		if _possess_links.get(t) != caster:
			continue
		if t == null or not is_instance_valid(t) or not t.alive:
			_possess_links.erase(t)   # 目标已死/失效：清除绑定
			continue
		t.take_damage(dmg, false, false, "附体")
	_possess_depth -= 1

# 某格相邻的对立阵营单
func _enemies_adjacent_to(cell: Vector2i, faction: int) -> Array:
	var out: Array = []
	for v in units:
		if v.alive and v.faction != faction and grid.distance(cell, v.cell) == 1:
			out.append(v)
	return out

# 某格相邻的障碍格
func _adjacent_obstacles_at(cell: Vector2i) -> Array:
	var out: Array = []
	for n in grid.neighbors(cell):
		if obstacles.has(n):
			out.append(n)
	return out

# 移动后的角色专属技
func _trigger_on_move(u: Unit) -> void:
	if not u.skill_allowed():   # 沉默：无法触发移动后技能
		return
	_hero(u).on_move()

# 回合开始时（该阵营）的角色技
func _trigger_turn_start(u: Unit) -> bool:
	if not u.skill_allowed():   # 沉默：无法触发回合开始技能
		return false
	var played := _hero(u).on_turn_start()
	if played:
		u.burst_fx(DataRegistry.hero_fx(u.hero_id).color, DataRegistry.hero_fx(u.hero_id).text)
	return played

# 回合结束时（该阵营）的角色技
func _trigger_turn_end(u: Unit) -> bool:
	# 骷髅兵：回合结束时消散（干净淡出，不弹伤害数字、不触发被动闪烁
	if u.hero_id == "summon_skeleton":
		log_message.emit("骷髅兵随回合结束而消散")
		if u.alive:
			u.alive = false
			var dt := create_tween()
			dt.tween_property(u, "modulate:a", 0.0, 0.25)
			dt.tween_callback(func(): _on_unit_died(u))
		return false
	if not u.skill_allowed():   # 沉默：无法触发回合结束技能（骷髅兵消散不受影响）
		return false
	return _hero(u).on_turn_end()

# 替补登场时触
func _trigger_on_enter(u: Unit) -> void:
	if not u.skill_allowed():   # 沉默：无法触发登场技能
		return
	# 只有带"<替补>"标签的英雄，替补登场时才触发技能（波盾/太阳斩/梅林/猎颅者的 on_enter 实现）。
	# 其它回合开始技（烈焰祭司加攻/圣诞老人放道具/黄金矿工丢矿等）不因替补登场触发，等下一个己方回合开始生效。
	_hero(u).on_enter()

# ============ 效果原语 ============
func _heal(u: Unit, amt: int) -> void:
	if not u.alive or u.hp >= u.max_hp:
		return
	u.hp = min(u.hp + amt, u.max_hp)
	u.hp_changed.emit(u)
	u._update_hp_label()
	u.float_heal(amt)

func _heal_adjacent_lowest(u: Unit) -> bool:
	var best: Unit = null
	for v in units:
		if v.alive and v.faction == u.faction and grid.distance(u.cell, v.cell) == 1 and v.hp < v.max_hp:
			if best == null or v.hp < best.hp:
				best = v
	if best != null:
		var heal := maxi(1, u.effective_atk())
		_heal(best, heal)
		return true
	return false   # 没有可治疗的受伤队友

func _adjacent_enemies(u: Unit) -> Array:
	var out: Array = []
	for v in units:
		if v.alive and v.faction != u.faction and grid.distance(u.cell, v.cell) == 1:
			out.append(v)
	return out

# x 同阵营且相邻的单位（用于"伤害/击退目标相邻的敌类溅射）
func _same_side_adjacent(x: Unit) -> Array:
	var out: Array = []
	for v in units:
		if v.alive and v != x and v.faction == x.faction and grid.distance(x.cell, v.cell) == 1:
			out.append(v)
	return out

# 场上是否存在"另一位"存活风语者（≠u）：移动回血按"其他队友"判定——
# 风语者本人吃不到自己发的光环，但两个风语者在场时互为队友、都可回血
func _has_other_wind_speaker(u: Unit) -> bool:
	for v in units:
		if v.alive and v.faction == u.faction and v.hero_id == "hero_43" and v != u:
			return true
	return false

func _adjacent_ally(u: Unit) -> Array:
	var out: Array = []
	for v in units:
		if v.alive and v.faction == u.faction and grid.distance(u.cell, v.cell) == 1:
			out.append(v)
	return out

func _lowest_enemy(u: Unit) -> Unit:
	var best: Unit = null
	for v in units:
		if v.alive and v.faction != u.faction:
			if best == null or v.hp < best.hp:
				best = v
	return best

func _adjacent_obstacles(u: Unit) -> Array:
	var out: Array = []
	for n in grid.neighbors(u.cell):
		if obstacles.has(n):
			out.append(n)
	return out

# 炸弹人：正前方（朝敌方底线方向）的相邻格
func _front_cell(u: Unit) -> Vector2i:
	var best := u.cell
	var best_d := INF
	for n in grid.neighbors(u.cell):
		var d: float
		if u.faction == DataRegistry.Faction.PLAYER:
			# 玩家从下方进攻，正前方朝上（包围敌方底线 y 最小）
			d = grid.cell_to_world(n).y
		else:
			# 敌方从上方进攻，正前方朝下（包围玩家底线 y 最大）
			d = -grid.cell_to_world(n).y
		if d < best_d:
			best_d = d
			best = n
	return best

# 炸弹人周围可放炸弹的空地（相邻、界内、无单位/障碍/已有炸弹
func _bomb_spots(u: Unit) -> Array:
	var out: Array = []
	for n in grid.neighbors(u.cell):
		if grid.in_bounds(n) and not occupancy.has(n) and not obstacles.has(n) and not bombs.has(n):
			out.append(n)
	return out

# 进入炸弹选格状态：高亮可用空地；无空位则走正常收尾
func _begin_bomb_place(u: Unit) -> void:
	var spots := _bomb_spots(u)
	if spots.size() == 0:
		_pending_bomb_unit = null
		_continue_after_move(u)
		return
	var pc := {}
	for c in spots:
		pc[c] = Color(0.95, 0.62, 0.15, 0.85)   # 橙色可放炸弹
	_preview_cells = pc
	_apply_highlights()
	action_info.emit("%s：选择一处空地放置炸弹。" % u.display_name)

# 点选放炸弹格（单机直接放；联机走指令流：主机权威执行并广播，客户端发给主机
func _submit_bomb_place(cell: Vector2i) -> bool:
	if _pending_bomb_unit == null:
		return false
	if not GameState.is_online:
		return _try_place_bomb(cell)
	var u := _pending_bomb_unit
	var cmd := { "type": "bomb", "u": units.find(u), "cell": [cell.x, cell.y] }
	if GameState.is_host:
		apply_command(cmd)
		NetBus.send_all(JSON.stringify(cmd))
	else:
		NetBus.send_to(1, JSON.stringify(cmd))
	return true

# 单机本地放置（保选错可重交互
func _try_place_bomb(cell: Vector2i) -> bool:
	if _pending_bomb_unit == null:
		return false
	var u := _pending_bomb_unit
	if _apply_bomb_placement(u, cell):
		_pending_bomb_unit = null
		_preview_cells = {}
		_apply_highlights()
		_continue_after_move(u)
		return true
	action_info.emit("请点击炸弹人相邻的空地放置炸弹")
	_pending_bomb_unit = u
	state = State.PLACE_BOMB
	_begin_bomb_place(u)
	return false

# 联机炸弹指令落地（主机执/ 客户端回放）：校验落点后放置并继续移动后流程
func _apply_bomb_cmd(u: Unit, cell: Vector2i) -> void:
	if u == null or not is_instance_valid(u) or not u.alive:
		return
	if not _apply_bomb_placement(u, cell):
		return   # 非法落点（UI 已过滤，此处兜底）：忽略，不推进流程
	_pending_bomb_unit = null
	_preview_cells = {}
	_apply_highlights()
	_continue_after_move(u)

# 炸弹落点公共校验并放置（单机 / 联机主机 / 回放端共用同一规则
func _apply_bomb_placement(u: Unit, cell: Vector2i) -> bool:
	if u == null or not is_instance_valid(u):
		return false
	if cell == u.cell or not grid.in_bounds(cell) or grid.distance(u.cell, cell) != 1 \
			or occupancy.has(cell) or obstacles.has(cell) or bombs.has(cell):
		return false
	bombs[cell] = true
	if board_view:
		board_view.bombs = bombs
		board_view.queue_redraw()
	log_message.emit("%s 在 %s 放置了炸弹。" % [u.display_name, str(cell)])
	return true

func _knockback(target: Unit, from_cell: Vector2i) -> bool:
	# 只认"from -> target"直线正后方那一格，并校验它确实紧邻目标且更远离攻击
	var from_axial := grid.axial_of(from_cell)
	var target_axial := grid.axial_of(target.cell)
	var step := target_axial - from_axial
	if step == Vector2i.ZERO:
		return false
	var best := grid.offset_of(target_axial + step)
	var target_dist := grid.distance(from_cell, target.cell)
	# 校验：best 须紧邻目距离1)，且比目标离攻击者更远一格（在正后方直线上）
	if not grid.in_bounds(best) or occupancy.has(best) or obstacles.has(best) or graves.has(best):
		return false
	if grid.distance(target.cell, best) != 1 or grid.distance(from_cell, best) != target_dist + 1:
		return false
	occupancy.erase(target.cell)
	target.cell = best
	occupancy[best] = target
	_trigger_bomb(target)   # 被击退到炸弹格：炸弹人以外即引
	var t := create_tween()
	t.tween_property(target, "position", board_view.cell_world_center(best), 0.18)
	return true

func _swap_units(a: Unit, b: Unit) -> void:
	var ca := a.cell
	var cb := b.cell
	occupancy.erase(ca)
	occupancy.erase(cb)
	a.cell = cb
	b.cell = ca
	occupancy[cb] = a
	occupancy[ca] = b
	_trigger_bomb(a)
	_trigger_bomb(b)
	var t := create_tween()
	t.tween_property(a, "position", board_view.cell_world_center(cb), 0.2)
	t.parallel().tween_property(b, "position", board_view.cell_world_center(ca), 0.2)

# 暗域：目标被攻击打死时，占据其空出的格子（近交换"
func _occupy_dead_cell(u: Unit, target: Unit) -> void:
	if u == null or not is_instance_valid(u) or not u.alive:
		return
	var c := target.cell
	if not grid.in_bounds(c):
		return
	# 目标刚死、尚未从 occupancy 移除（淡出动画中）：允许占据其原格；
	# 若该格被**其他存活单位**占据则放弃
	if occupancy.has(c) and occupancy[c] != target:
		return
	occupancy.erase(u.cell)
	# 目标已死，从 occupancy 移除其原格占用，再让暗域入位
	if occupancy.get(c) == target:
		occupancy.erase(c)
	u.cell = c
	occupancy[c] = u
	_trigger_bomb(u)   # 瞬移/占据到炸弹格：炸弹人以外即引
	var t := create_tween()
	t.tween_property(u, "position", board_view.cell_world_center(c), 0.2)

# 击退障碍：把 oc 处障碍沿"from_cell -> oc"直线推到下一空格（保留耐久）；推不动返false
func _knockback_obstacle(oc: Vector2i, from_cell: Vector2i) -> bool:
	if not obstacles.has(oc):
		return false
	var from_axial := grid.axial_of(from_cell)
	var oc_axial := grid.axial_of(oc)
	var step := oc_axial - from_axial
	if step == Vector2i.ZERO:
		return false
	var best := grid.offset_of(oc_axial + step)
	if not grid.in_bounds(best) or occupancy.has(best) or obstacles.has(best):
		return false
	var dur: int = obstacles[oc]
	obstacles.erase(oc)
	obstacles[best] = dur
	if board_view:
		board_view.obstacles = obstacles
		board_view.queue_redraw()
	return true

# 血锁拉障碍：把 oc 处障碍沿"血>障碍"反方向拉近一格（朝血锁方向；保留耐久）。拉不动返回 false
func _pull_obstacle(oc: Vector2i, from_cell: Vector2i) -> bool:
	if not obstacles.has(oc):
		return false
	var from_axial := grid.axial_of(from_cell)
	var oc_axial := grid.axial_of(oc)
	var step := oc_axial - from_axial
	if step == Vector2i.ZERO:
		return false
	var best := grid.offset_of(oc_axial - step)   # 反方向：朝血锁走一
	if not grid.in_bounds(best) or occupancy.has(best) or obstacles.has(best):
		return false
	var dur: int = obstacles[oc]
	obstacles.erase(oc)
	obstacles[best] = dur
	if board_view:
		board_view.obstacles = obstacles
		board_view.queue_redraw()
	return true

func _pull_to(u: Unit, target: Unit) -> void:
	# 目标已贴距离1)：已在血锁面前，无需再拉动（避免把已贴身的敌人再位移一格）
	if grid.distance(u.cell, target.cell) <= 1:
		return
	# 血>目标"连线方向，把目标拉到血锁面前（紧贴血锁、朝目标方向的那一格）
	var best: Vector2i = Vector2i(-99, -99)
	var best_d := 99999
	for n in grid.neighbors(u.cell):
		if occupancy.has(n) or obstacles.has(n) or graves.has(n):
			continue
		var d := grid.distance(n, target.cell)
		if d < best_d:
			best_d = d
			best = n
	if best.x == -99:
		return
	_spawn_chain(u, target)   # 血锁链子勾拉演出（从血锁射向目标）
	occupancy.erase(target.cell)
	target.cell = best
	occupancy[best] = target
	_trigger_bomb(target)   # 被拉近到炸弹格：炸弹人以外即引爆
	var t := create_tween()
	t.tween_property(target, "position", board_view.cell_world_center(best), 0.2)
	log_message.emit("血锁把 %s 拉到面前（%s）。" % [target.display_name, str(best)])

func _pierce_back(u: Unit, target: Unit) -> void:
	_pierce_line(u, target.cell)

# given_cell 为攻击目标，穿透其身后直线到棋盘边
func _pierce_line(u: Unit, target_cell: Vector2i) -> void:
	# 用轴向方向计目标身后"的直线，沿该轴向穿透到棋盘边缘
	# 伤害路径上的所有敌人（真正的六边形直线，不受列错位影响）
	# 障碍物不再被剑气破坏：剑气只是穿过，不造成技能对地形效果
	var a := grid.axial_of(u.cell)
	var t := grid.axial_of(target_cell)
	var step := t - a   # 目标相对攻击者的轴向基本步长（长剑为相邻攻击，步长为单步
	if step == Vector2i.ZERO:
		return
	_spawn_sword_qi(u, step)
	var cur := t + step   # 目标身后第一
	for _i in 60:
		var off := grid.offset_of(cur)
		if not grid.in_bounds(off):
			break
		var v = occupancy.get(off, null)
		if v != null and v.alive and v.faction != u.faction:
			v.take_damage(u.effective_atk(), false, false, "被%s剑气穿透" % u.display_name)
		cur += step

# 剑气演出：从攻击者沿目标直线方向飞到尽头后消
func _spawn_sword_qi(u: Unit, step: Vector2i) -> void:
	var start := board_view.cell_world_center(u.cell)
	var end_axial := grid.axial_of(u.cell) + step * 8
	var end := board_view.cell_world_center(grid.offset_of(end_axial))
	var dir := end - start
	var qi := SwordQi.new()
	qi.position = start
	qi.rotation = dir.angle()
	add_child(qi)
	var dur := clampf(dir.length() * 0.01, 0.22, 0.5)
	var t := create_tween()
	t.tween_property(qi, "position", end, dur).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	t.tween_callback(qi.queue_free)

# 嬉皮死神：镰刀弧形收割——一道弯月形紫黑色刀刃从死神扫向目标方向，划过弧线后淡出
func _spawn_scythe(u: Unit, target: Unit) -> void:
	var start := board_view.cell_world_center(u.cell)
	var to := board_view.cell_world_center(target.cell)
	var dir := to - start
	var scy := ScytheBlade.new()
	scy.position = start
	scy.rotation = dir.angle()
	add_child(scy)
	var dur := clampf(dir.length() * 0.012, 0.22, 0.45)
	var reach := dir.length() + hex_size * 0.6
	var t := create_tween()
	t.tween_property(scy, "position", start + dir.normalized() * reach, dur).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	t.parallel().tween_property(scy, "scale", Vector2(1.15, 0.7), dur)   # 收割时刀刃略微压
	t.parallel().tween_property(scy, "modulate:a", 0.0, dur)
	t.tween_callback(scy.queue_free)

# 血锁链子：从血锁射向目标、随目标被拉回而收拢的链状光条（贴链子勾过）
func _spawn_chain(u: Unit, target: Unit) -> void:
	var start := board_view.cell_world_center(u.cell)
	var tpos := board_view.cell_world_center(target.cell)
	var chain := BloodChain.new()
	chain.position = start
	chain.rotation = (tpos - start).angle()
	chain.length = (tpos - start).length()
	add_child(chain)
	var t := create_tween()
	t.tween_property(chain, "scale", Vector2(0.85, 0.5), 0.16).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)   # 拉近时链子收
	t.parallel().tween_property(chain, "modulate:a", 0.0, 0.4)
	t.tween_callback(chain.queue_free)

func _random_step(v: Unit) -> void:
	var nbrs := grid.neighbors(v.cell)
	var options: Array = []
	for n in nbrs:
		# 允许移动到界内、且未被单位/障碍/墓碑占据的格（炸弹格允许：与击退/换位等强制位移一致，可被推上炸弹引爆）
		if grid.in_bounds(n) and not occupancy.has(n) and not obstacles.has(n) and not graves.has(n):
			options.append(n)
	if options.size() > 0:
		var n: Vector2i = options[rng.randi() % options.size()]
		occupancy.erase(v.cell)
		v.cell = n
		occupancy[n] = v
		_trigger_bomb(v)   # 被推上炸弹格：非炸弹人即引爆（与其它强制位移统一）
		if v.alive:
			_pickup_buff_at_cell(v)   # 强制位移落点同样拾取增益/金矿
		_sync_ranged_adjacent()
		# 缓慢移动动画，而非瞬移
		var t := create_tween()
		t.tween_property(v, "position", board_view.cell_world_center(n), 0.35)

func _summon_skeletons(u: Unit) -> void:
	var slots: Array = []
	for n in grid.neighbors(u.cell):
		if not occupancy.has(n):
			slots.append(n)
	var count := mini(2, slots.size())
	for i in count:
		var def := DataRegistry.get_summon("summon_skeleton")
		if def == null:
			return
		var s := Unit.new(def, u.faction, slots[i], hex_size * 0.9)
		s.summon_owner = u.id   # 记录召唤者：死灵法师阵亡时其骷髅随之消散
		s.position = board_view.cell_world_center(slots[i])
		s.hp_changed.connect(_on_unit_hp_changed)
		s.died.connect(_on_unit_died)
		s.modulate.a = 0.0
		add_child(s)
		units.append(s)
		occupancy[slots[i]] = s
		_trigger_bomb(s)   # 召唤到炸弹格：炸弹人以外即引
		var st := create_tween()
		st.tween_property(s, "modulate:a", 1.0, 0.3)
		log_message.emit("召唤了骷髅兵")

func _heal_lowest_and_swap(u: Unit) -> bool:
	var best: Unit = null
	for v in units:
		if v.alive and v.faction == u.faction and v != u and v.hp < v.max_hp:
			if best == null or v.hp < best.hp:
				best = v
	if best != null:
		_heal(best, 8)
		_swap_units(u, best)
		return true
	return false   # 无可治疗的受伤队友：技能未生效

func _hurt_lowest_enemy_stun(u: Unit) -> bool:
	var best: Unit = null
	for v in units:
		if v.alive and v.faction != u.faction:
			if best == null or v.hp < best.hp:
				best = v
	if best != null:
		best.take_damage(3, false, false, "被%s锁定重创" % u.display_name)
		_add_status_msg(best, "stun", "眩晕")
		return true
	return false   # 没有敌方目标：技能未生效

# 古灵精怪：把单位完整还原为本源英雄（hero_id/数技行为脚本/名称），
# 回合开始回溯本每次变身前重共用。若只还hero_id
# 行为脚本会停留在上一变身的英雄上，导致下回合无法再次变身
# 风语者光环等hero_id 的判定全部失效
func _apply_base_hero(u: Unit, hid: String) -> void:
	var bdef := DataRegistry.get_hero(hid)
	if bdef == null:
		return
	u.skills = bdef.skills.duplicate()
	u.atk = bdef.atk + u.perm_atk   # 保留永久攻击加成（捡金块/攻击道具/涌电），不被重置
	u.move_range = bdef.move_range
	if bdef.skills.has(DataRegistry.Skill.SWIFT):
		u.move_range += 1
	u.attack_range = bdef.attack_range
	u.attack_type = bdef.attack_type
	u.los_ignore = (hid == "hero_45")   # 回到基础英雄：清理坠炮手的无视阻挡
	u.echo_bonus = 0   # 回到基础英雄：清空共鸣者加成
	u.display_name = bdef.display_name
	u.behavior = HeroRegistry.create(hid)
	u.behavior.setup(self, u)

# 古灵精怪：随机变为己方队伍中的一名其他角色，暂时获得其技能与数
func _transform(u: Unit, picked_override: String = "") -> void:
	# 候= 场上己方队友 + 本方替补池英
	var cand: Dictionary = {}
	for v in units:
		if v.alive and v.faction == u.faction and v != u:
			cand[v.hero_id] = true
	var roster: Array = player_roster if u.faction == DataRegistry.Faction.PLAYER else enemy_roster
	for hid in roster:
		cand[hid] = true
	if cand.size() == 0:
		return
	# 不重复变成上一次已变过的对象（若候选只剩它，则降级允许
	var ids: Array = cand.keys()
	var pool: Array = []
	if u.last_transform_id != "":
		for id in ids:
			if id != u.last_transform_id:
				pool.append(id)
	if pool.size() == 0:
		pool = ids
	if picked_override != "" and cand.has(picked_override):
		pool = [picked_override]   # 测试指定：强制变身为该英
	# 每次变身：先还原为古灵精怪基础数值，再随机变为一名（不叠加、每回合重新变）
	_apply_base_hero(u, "hero_28")
	u.transform_base_id = "hero_28"
	var picked_id: String = pool[rng.randi() % pool.size()]
	var def := DataRegistry.get_hero(picked_id)
	if def == null:
		return
	# 继承目标英雄的"词条+出生调整属性"：词条（嘲讽/疾行/渗透/后勤…）已复制进 skills；
	# 移动/射程按出生规则取值（血锁射程+2、大骑士冲锋+6、疾行+1 等），否则变身后面板对不上、
	# 血锁这类"射程加成型"会因只有 1 格射程而拉不到敌人。atk 数值仍保持古灵精怪自身。
	u.skills = def.skills.duplicate()
	u.attack_type = def.attack_type   # 继承远程/近战（影响能否打远处
	u.move_range = DataRegistry.spawn_move(def)          # 出生调整后的移动力
	u.attack_range = DataRegistry.spawn_attack_range(def)  # 出生调整后的射程（血锁=3）
	u.hero_id = def.id   # 关键：让英雄专属行为（换穿渗嘲讽等）按新英雄结算
	u.last_transform_id = def.id   # 记录本次变身的对象，避免下次重复
	# 变身：重新挂接对应英雄的行为脚本，使其后续技能按新英雄分
	u.behavior = HeroRegistry.create(u.hero_id)
	u.behavior.setup(self, u)
	# 血锁的直线限制状态位补上（数值加成已含在 spawn_attack_range；状态位在变身瞬间补，
	# 之后每回合由血锁 on_turn_start 维持）。不调用目标 on_spawn：其数值加成都已由 spawn_* 覆盖，
	# 直接调会重复叠加（大骑士/血锁会双倍）。
	if u.hero_id == "hero_41":
		u.branch_override = true
	# 坠炮手：变身后也获得全场射程与无视阻挡（数值已在 spawn_attack_range 覆盖为 99）
	u.los_ignore = (u.hero_id == "hero_45")
	# 共鸣者：变身即补算（或变回非共鸣者则清空共鸣加成）
	if u.hero_id == "hero_47":
		_sync_one_echo(u)
	else:
		u.echo_bonus = 0
		u.refresh_stats()
	# 变身后立即触发新英雄回合开效果（黄金矿工丢圣诞老人放道死灵法师召唤等）
	# 原因：古灵精怪在本方回合开始阶段才变身，_trigger_turn_start_all 已处理过本单位，
	# 若由外部再按 hero_id 触发会漏掉新英雄的回合开始技能
	# **注意：只触发"回合开类技能，绝不触发"替补登场"(on_enter)类效*—
	# 变身不是替补登场，波梅林/太阳猎颅者的替补效果不应因变身触发
	if u.hero_id == "hero_28":
		pass   # 变回自身：无额外效果（正常不会发生，候选排除自身）
	else:
		_hero(u).on_turn_start()   # 只继回合开类效
	log_message.emit("%s 变身 %s。" % [u.display_name, def.display_name])
	u.display_name = def.display_name   # 完整显示变身后的英雄名（曾误留孤立 "(" 致名字残缺）
	u._update_name_label()   # 卡面名字跟随变化
	u._update_tags_label()   # 技能词条标签跟随变
	u.refresh_stats()        # 攻击等数值也刷新
	_notify_team()           # 变身改变卡组：刷新下方队
# 我方“实际还需替补的次数”= 待补队列名额 + 当前正开着的替补面板（若有，队列名额已先消费）
func _my_sub_quota() -> int:
	var q := _pending_player_subs
	if (_sub_faction == _my_faction() and (state == State.SUBSTITUTING or state == State.PLACE_SUB)):
		q += 1
	return q

func _on_unit_died(u: Unit, leave_grave: bool = true) -> void:
	if u == null or not is_instance_valid(u):
		return   # 单位已释放：安全退
	var cause_txt := ""
	if u != null and u.death_cause != "":
		cause_txt = "（%s）" % u.death_cause
	log_message.emit("%s 阵亡%s。" % [u.display_name, cause_txt])
	# 专属阵亡效果（红帽扑街等
	_hero(u).on_died()
	if occupancy.get(u.cell) == u:
		occupancy.erase(u.cell)
	# 阵亡留下墓碑：替补可选择在该格落位（骷髅兵等召唤物不立碑；主动撤下不立碑
	var is_summon: bool = DataRegistry.summons.has(u.hero_id)
	if not is_summon and leave_grave:
		graves[u.cell] = { "hero": u.hero_id, "fn": u.faction }
		_refresh_board()
	if selected == u:
		_clear_selection()
	# 从单位列表移除，避免后续遍历触发已释放节点访
	units.erase(u)
	# 死灵法师阵亡：他召唤的骷髅兵一起消散（骷髅都带召唤者 id，逐个淡出离场）
	if u.hero_id == "hero_33" and not is_summon:
		for s in units.duplicate():
			if s == null or not is_instance_valid(s) or not s.alive:
				continue
			if s.hero_id == "summon_skeleton" and s.summon_owner == u.id:
				log_message.emit("%s 召唤的骷髅兵随之消散。" % s.display_name)
				s.alive = false
				var st := create_tween()
				st.tween_property(s, "modulate:a", 0.0, 0.25)
				st.tween_callback(_skeleton_owner_gone.bind(s))
	# 风语者离场：立即收回本回合发给队友的移动力 +1（光环只在他在场时存在）
	if u.hero_id == "hero_43" and not is_summon:
		for v in units:
			if v != null and is_instance_valid(v) and v.alive and v.faction == u.faction and v.hero_id != "hero_43":
				if v.move_buff > 0:
					v.move_buff -= 1
					v.refresh_stats()
	# 骷髅兵等召唤物死亡不计入胜负死亡人数
	if not is_summon:
		# 记录阵亡
		if u.faction == DataRegistry.Faction.PLAYER:
			player_dead += 1
		else:
			enemy_dead += 1
	# 让阵亡单位淡出后移除
	u.call_deferred("queue_free")
	if is_summon:
		return   # 召唤物死亡：仅消失，不判胜负、不补位
	# 阵亡次数达标 -> 输赢（不补位
	if _check_win():
		return
	# 替补：本我方"阵亡 -> 手动替补（联机我方是真人，单机玩家也是真人）
	# 对方阵亡 -> 单机敌方AI，自动补位；联机敌方是真人，由对端自行补位（我方等待其补位指令）
	if u.faction == _my_faction():
		var my_roster: Array = _my_roster()
		if my_roster.size() > 0:
			if GameState.active_side == _my_side() and not _ending_side and not _in_begin_phase:
				# 我方在回合行动中阵亡（如被反击击杀）：立即替补（回合开始演出期除外）
				# 同时阵亡多人则计数，逐个替补（落位后自动开下一个面板）
				_pending_player_subs += 1
				if _CONSOLE_SUB_LOG:
					print("[替补] 我方%s 即时阵亡，待补名额=%d" % [u.display_name, _pending_player_subs])
				_try_begin_next_sub()
			else:
				# 对方回合 / 本方"结束回合-结算扣血"期间阵亡：不立即替补，等本方下回合开始再逐个补位
				_pending_player_subs += 1
				if _CONSOLE_SUB_LOG:
					print("[替补] 我方%s 延迟阵亡（敌回合/结算/回合开始演出期），待补名额=%d" % [u.display_name, _pending_player_subs])
	elif not GameState.is_online:
		# 单机：敌AI)阵亡 -> 自动按阵亡数量补
		if enemy_roster.size() > 0:
			_pending_enemy_sub += 1   # 每阵亡一名，记录一个待补位名额（敌方回合开始才落位
			# 敌方回合内即阵亡：本回合立即补位，避免该敌方回合缺员行动后要拖到下一敌方回合
			if GameState.active_side == GameState.SIDE_ENEMY:
				_place_enemy_sub()
	if _CONSOLE_SUB_LOG:
		var cause_txt2 := ""
		if u != null and u.death_cause != "":
			cause_txt2 = " 死因：%s" % u.death_cause
		print("[替补统计] %s（%s）阵亡后%s：我可替补次数=%d" % [u.display_name, "我方" if u.faction == _my_faction() else "敌方", cause_txt2, _my_sub_quota()])
	_notify_team()   # 阵亡改变卡组：刷新下方队伍

# 骷髅随主人（死灵法师）消散：复用 _on_unit_died 的收尾（不立碑、不计胜负、淡出后释放）
func _skeleton_owner_gone(s: Unit) -> void:
	if s != null and is_instance_valid(s):
		_on_unit_died(s)

# 敌方替补：按阵亡数量在出生区自动落位（我方回合结束时、敌方回合开始前触发）
func _place_enemy_sub() -> void:
	while _pending_enemy_sub > 0 and enemy_roster.size() > 0:
		var next_id: String = enemy_roster.pop_at(_best_enemy_sub_idx())
		var cell := _free_spawn_cell(DataRegistry.Faction.ENEMY)
		if cell.x == -99 and cell.y == -99:
			enemy_roster.push_front(next_id)   # 出生区满了，留到下一轮再
			_pending_enemy_sub = 0
			break
		# 只清本次落位占用的这座墓；敌方其它墓碑保留到各自替补完成（同时阵亡多人时逐个补位
		if graves.has(cell):
			graves.erase(cell)
			_refresh_board()
		var eu := _spawn_unit(next_id, DataRegistry.Faction.ENEMY, cell)
		_grant_sub_aura_after_enter(eu)   # 替补补发光环（风语者等：中途上场才补；先补位再技能阶段跳过）
		_trigger_on_enter(eu)   # 敌方替补登场技能已触发
		_pending_enemy_sub -= 1
	# 全部敌方替补补完后：清理剩余敌方墓碑（安葬完毕）
	if _pending_enemy_sub == 0:
		_clear_side_graves(DataRegistry.Faction.ENEMY)

# 此刻最合的敌方替补：按当前战局需求给候选打分，取代按卡组顺序硬顶
# 需求依据：缺前嘲讽)优先补坦克；多人负伤时优先支光环；输出偏少时优先远程
# 远程/嘲讽兼顾正面战力；替补标签英雄登场本就能触发技能，小加分
func _best_enemy_sub_idx() -> int:
	var best_i := 0
	var best_s := -1e18
	var cand_rows: Array = []   # 分析日志用：候选价值明细
	var has_taunt := false
	var wounded := 0
	var live_melee := 0   # 存活且能上前线的敌方单位数（近战或嘲讽）
	for u in units:
		if u == null or not is_instance_valid(u) or not u.alive:
			continue
		if u.faction != DataRegistry.Faction.ENEMY:
			continue
		if u.skills.has(DataRegistry.Skill.TAUNT):
			has_taunt = true
			live_melee += 1
		elif u.attack_type == DataRegistry.AttackType.MELEE:
			live_melee += 1
		if u.hp < u.max_hp:
			wounded += 1
	var player_near := false
	for u in units:
		if u == null or not is_instance_valid(u) or not u.alive:
			continue
		if u.faction == DataRegistry.Faction.ENEMY:
			continue
		for n in grid.neighbors(u.cell):
			if occupancy.has(n) and occupancy[n].faction == DataRegistry.Faction.ENEMY:
				player_near = true
				break
	for i in enemy_roster.size():
		var hid: String = enemy_roster[i]
		var def := DataRegistry.get_hero(hid)
		if def == null:
			continue
		var s := float(def.atk) * 1.6 + float(def.max_hp) * 0.9
		var why: Array[String] = []
		if def.attack_type == DataRegistry.AttackType.RANGED:
			s += 2.5
			why.append("远程")
		if not has_taunt and def.skills.has(DataRegistry.Skill.TAUNT):
			s += 11.0   # 缺前排：嘲讽坦克优先补位
			why.append("缺前排坦克")
		elif def.skills.has(DataRegistry.Skill.TAUNT) and live_melee < 2:
			s += 3.0
			why.append("补坦克位")
		if def.skills.has(DataRegistry.Skill.LOGISTICS):
			# 后勤/支援：队伍伤员多或交战胶着时价值上升；平时不优先（不能主动输出
			if wounded > 0:
				s += float(wounded) * 1.2
				why.append("支援伤员")
			elif player_near:
				s -= 4.0
			else:
				s -= 1.5
		if def.skills.has(DataRegistry.Skill.BENCH):
			s += 0.5   # 替补标签：登场触发技能，小加
			why.append("替补技")
		match hid:
			"hero_16":   # 波盾：登场让己方全体获得圣盾
				s += 5.0 + (3.0 if wounded > 0 else 0.0)
				why.append("登场全队圣盾")
			"hero_36":   # 梅林：治疗最低血量队友并与其换位
				s += 5.0 if wounded > 0 else 1.0
				why.append("登场治疗换位")
			"hero_29":   # 太阳斩：登场攻击3（短时爆发）
				s += 3.0
				why.append("登场爆发")
			"hero_39":   # 猎颅者：登场锁定目标
				s += 2.0
				why.append("登场锁定")
		if _CONSOLE_AI_LOG:
			cand_rows.append({ "hid": hid, "n": def.display_name, "s": s, "why": why })
		if s > best_s:
			best_s = s
			best_i = i
	if _CONSOLE_AI_LOG and cand_rows.size() > 0:
		cand_rows.sort_custom(func(x, y): return x["s"] > y["s"])
		print("\n[AI替补上人] 敌方需要补位（现有 %d 人待选）" % cand_rows.size())
		for r in cand_rows.slice(0, mini(3, cand_rows.size())):
			var why_txt := "、".join(r["why"]) if (r["why"] as Array).size() > 0 else "常规"
			print("  - %s 价值%.1f（%s）" % [r["n"], float(r["s"]), why_txt])
		print("[AI替补上人] → 上 %s" % cand_rows[0]["n"])
	return best_i

# ---- 替补选择与落位（本端"我方"；联主机玩家/客户端敌方，单机=玩家----
var _pending_sub := ""   # 已选中的替hero_id（等待落位）

# 尝试开始下一个替补名额（同时阵亡多人时逐个替补）。仅在空闲且有名有替补时消费 1 个
func _try_begin_next_sub() -> void:
	if GameState.match_over:
		return   # 对局已结束：不再弹替补界
	if _pending_player_subs <= 0 or _my_roster().size() <= 0:
		return
	if state == State.SUBSTITUTING or state == State.PLACE_SUB:
		return   # 替补面板已在进行：本次落位后会自动开启下一个替补名额
	_pending_player_subs -= 1
	if _CONSOLE_SUB_LOG:
		print("[替补面板] 开新面板：本次后待补=%d，替补席=%d" % [_pending_player_subs, _my_roster().size()])
	_begin_substitution()

func _begin_substitution() -> void:
	_sub_faction = _my_faction()
	state = State.SUBSTITUTING
	sub_select_requested.emit()
	action_info.emit("有英雄阵亡！从替补队伍中选择一名上阵")

# 回合超时且卡在替补/落位面板：自动上替补席第 1 名（落本方墓碑优先，其次出生区空位），
# 直到补完回到输入态，再由 _turn_expired 自动结束回合。
func _auto_sub_on_timeout() -> void:
	var roster := _my_roster()
	if roster.size() <= 0:
		# 没有替补可上：收掉面板直接恢复（超时结束仍由 _turn_expired 兜底）
		_pending_sub = ""
		if state == State.SUBSTITUTING or state == State.PLACE_SUB:
			state = State.IDLE
			_resume_after_sub()
		return
	if state == State.SUBSTITUTING:
		_on_sub_pick(roster[0])
	if _pending_sub == "" or state != State.PLACE_SUB:
		return
	var cell := _auto_sub_cell()
	if cell.x == -99:
		return   # 暂无可落位点：下一帧继续尝试（超时标记仍在）
	_try_place_sub(cell)

# 自动落位点：本方墓碑（含旧格式墓碑）优先，其次本方出生区空格
func _auto_sub_cell() -> Vector2i:
	var my_fn := _my_faction()
	for c in graves.keys():
		var gd = graves[c]
		var mine := typeof(gd) != TYPE_DICTIONARY or int(gd.get("fn", -1)) == my_fn
		if mine and not occupancy.has(c):
			return c
	for c in _spawn_cells(my_fn):
		if not occupancy.has(c) and not graves.has(c):
			return c
	return Vector2i(-99, -99)

func _on_sub_pick(hero_id: String) -> void:
	if _CONSOLE_SUB_LOG:
		print("[subclick-battle] 收到点击 %s state=%d sub_faction=%d roster=%s" % [hero_id, state, _sub_faction, str(_roster_of(_sub_faction))])
	var roster := _roster_of(_sub_faction)
	if not roster.has(hero_id):
		return
	_pending_sub = hero_id   # 不从此处roster（落_place_sub 才扣，且两端一致）
	state = State.PLACE_SUB
	# 高亮可在出生地放置的格子 + **本方**墓碑格（不能落在对方墓碑上）
	var pc := {}
	for c in _spawn_cells(_sub_faction):
		pc[c] = Color(0.2, 0.85, 0.5, 0.7)
	for c in graves.keys():
		var gd = graves[c]
		var my_grave: bool = typeof(gd) != TYPE_DICTIONARY or int(gd.get("fn", -1)) == _sub_faction
		if my_grave and not pc.has(c):
			pc[c] = Color(0.75, 0.6, 0.35, 0.8)   # 本方墓碑格：土黄
	_preview_cells = pc
	_apply_highlights()
	action_info.emit("选择 %s 的登场位置（绿格=出生地，土黄色=本方阵亡墓碑处）。" % DataRegistry.get_hero(hero_id).display_name)

func _try_place_sub(cell: Vector2i) -> bool:
	if _pending_sub == "":
		return false
	# 墓碑可落位，但只允许本方墓碑（对方墓碑不能作为替补登场点
	var on_grave := false
	if graves.has(cell):
		var gd = graves[cell]
		on_grave = typeof(gd) != TYPE_DICTIONARY or int(gd.get("fn", -1)) == _sub_faction
	if not on_grave and not _in_spawn_cell(cell, _sub_faction):
		return false
	if occupancy.has(cell):
		return false
	var hid := _pending_sub
	var fn := _sub_faction
	_pending_sub = ""
	# 联机：主机权威。客户端只发指令（不本地执行），主机执行+广播，客户端收到再重演
	if GameState.is_online and not GameState.is_host:
		_apply_sub_ui_cleanup(fn)
		var cs := 1 if _sub_clear_side(fn, hid) else 0   # 负责端判定：本次补完是否应清该阵营墓碑
		NetBus.send_to(1, JSON.stringify({ "type": "sub", "faction": fn, "hero": hid, "cell": [cell.x, cell.y], "clear_side": cs }))
		return true
	# 主机/单机：本地落
	var clear_side := -1
	if GameState.is_online:
		clear_side = 1 if _sub_clear_side(fn, hid) else 0   # 主机同为负责端：结果随广播带给客户端
	_place_sub(fn, hid, cell, clear_side)
	if GameState.is_online:
		NetBus.send_all(JSON.stringify({ "type": "sub", "faction": fn, "hero": hid, "cell": [cell.x, cell.y], "clear_side": clear_side }))
	return true

# 本次替补落位后，该阵营是否应清空剩余墓碑（= 无更多待补名额 或 替补席已空）。
# 只由"负责端"（操作该阵营的那端）调用：其 _pending_player_subs 才是本阵营的真实待补计数。
func _sub_clear_side(fn: int, hid: String) -> bool:
	var r: Array = _roster_of(fn).duplicate()
	r.erase(hid)   # 本次即将上场的从替补席剔除后看还剩谁
	return r.size() == 0 or _pending_player_subs <= 0

# 客户端点"放置"后先清理本地选中/高亮/关闭面板（等待主机广播重演，不在本地真正落位）
func _apply_sub_ui_cleanup(fn: int) -> void:
	_preview_cells = {}
	_apply_highlights()
	if _sub_faction == fn:
		_sub_faction = -1
	sub_placed.emit()
	_resume_after_sub()   # 恢复回合状态（本端保持输入，等待主机广播回来）

# 权威落位（两端一致执行）：spawn + 收尾（清墓碑/恢复回合/广播）
# 替补落位时补发光环：风语者的移动力 +1 在回合开始时发给当时在场队友，
# 替补是在回合中/回合开始结算后才上场，会错过那一次发放 → 若本方场上仍有存活风语者则补 +1。
# 回合结束时 _clear_statuses 统一清零，不会与下回合重复叠加。
# 替补登场后的光环补发：仅"回合中途换人"需要（回合开始技能已触发过）；
# "回合开始先补位"阶段（_defer_side_skills / _start_placing_subs）由随后的回合开始技统一发放，避免 +2。
func _grant_sub_aura_after_enter(u: Unit) -> void:
	if _defer_side_skills or _start_placing_subs:
		return
	_grant_sub_aura(u)

func _grant_sub_aura(u: Unit) -> void:
	if u == null or not is_instance_valid(u) or not u.alive:
		return
	if u.hero_id == "hero_43":
		# 替补登场的是风语者本人：他的光环是"在场时所有其他队友移动力+1"。
		# 回合中途替补会错过回合开始的 on_turn_start，须在此给在场队友补发（风语者本人不吃）。
		for v in units:
			if v == null or not is_instance_valid(v) or not v.alive:
				continue
			if v.faction == u.faction and v.hero_id != "hero_43":
				v.move_buff += 1
				v.refresh_stats()
		return
	for v in units:
		if v == null or not is_instance_valid(v) or not v.alive:
			continue
		if v.faction == u.faction and v.hero_id == "hero_43":
			u.move_buff += 1
			u.refresh_stats()
			return

func _place_sub(fn: int, hero_id: String, cell: Vector2i, clear_side: int = -1) -> void:
	var roster := _roster_of(fn)
	roster.erase(hero_id)
	var nu := _spawn_unit(hero_id, fn, cell)
	_grant_sub_aura_after_enter(nu)   # 替补补发光环（风语者…中途上场才补；先补位再技能阶段跳过）
	_trigger_on_enter(nu)   # 替补登场技能（波盾/太阳梅林/猎颅者）
	_preview_cells = {}
	_apply_highlights()
	log_message.emit("替补登场：%s。" % DataRegistry.get_hero(hero_id).display_name)
	# 只清本次落位占用的这座墓；同阵营其他墓碑保留到其替补完成
	# （同时阵亡多人时逐个替补，第二人的墓碑不能提前消失）
	if graves.has(cell):
		graves.erase(cell)
		_refresh_board()
	_sub_faction = -1
	sub_placed.emit()   # 通知 HUD 关闭替补选人面板
	state = State.IDLE   # 清掉 PLACE_SUB 占位：允同时阵亡多人"时继续弹下一个替
	# 同时阵亡多名队友：本名额补完后若还有待补名额，继续弹下一个替补面板，而不是直接恢复回合
	# 注意：连续替补期*不刷*常驻"替补队伍"面板（避免它和替补面板重叠）
	# 常驻面板留到最后一个替补完成后再刷新
	var more_subs := _pending_player_subs > 0 and fn == _my_faction() and _my_roster().size() > 0
	if _CONSOLE_SUB_LOG and fn == _my_faction():
		print("[替补面板] 落位完成：待补=%d 替补席=%d → 再开=%s" % [_pending_player_subs, _my_roster().size(), more_subs])
	if more_subs:
		_try_begin_next_sub()
	else:
		_resume_after_sub()   # 恢复回合状（内部完成后刷新常驻队伍面板，避免与替补面板叠层）
	# 只有"确实没有下一个替时才清理该阵营剩余墓碑（否则第二人的墓碑会被提前抹掉）
	# 联机：clear_side>=0 时用负责端广播的结论（两端一致执行，避免墓碑只在本端视角消失）；
	# clear_side<0（单机/直接调用）才按本端视角推断。
	if not more_subs:
		var fn_done: bool
		if clear_side >= 0:
			fn_done = clear_side == 1
		else:
			fn_done = _roster_of(fn).size() == 0
			if fn == _my_faction():
				if fn_done:
					_pending_player_subs = 0   # 替补耗尽：清空剩余名额，避免残留
				fn_done = fn_done or _pending_player_subs <= 0
		if fn_done:
			_clear_side_graves(fn)

# 清除某一方的全部墓碑（该方替补已全部补完时调用）
func _clear_side_graves(fn: int) -> void:
	var changed := false
	for g in graves.keys():
		var gd = graves[g]
		if typeof(gd) == TYPE_DICTIONARY and int(gd.get("fn", -1)) == fn:
			graves.erase(g)
			changed = true
	if changed:
		_refresh_board()

func _resume_after_sub() -> void:
	# 回合开始先补位模式：全部替补落位完成后，此刻才统一触发回合开始技，
	# 再按"我方回合"正式入场（计时/横幅/可操作）。中途换人的补位不进此分支。
	if _defer_side_skills:
		_defer_side_skills = false
		_in_begin_phase = false   # 补位+技能演出期结束
		state = State.ANIMATING
		# 联机：行动方补位全部完成,此刻才广播"回合开始技开始"让等待端同步执行
		# (两端同一时点触发技能,避免 rng 分叉导致金矿/道具落点错位)
		if GameState.is_online:
			if GameState.is_host:
				NetBus.send_all(JSON.stringify({ "type": "side_skills", "side": _my_side(), "round": GameState.round_number }))
			else:
				NetBus.send_to(1, JSON.stringify({ "type": "side_skills", "side": _my_side(), "round": GameState.round_number }))
		# 技能演出 + 正式入场(计时/横幅/新阵亡再开面板)由 _run_side_skills 统一完成
		await _run_side_skills(_my_side())
		# _run_side_skills 行动方分支尾部已处理"技能期间新阵亡再开面板"；
		# 若它因还有待补而提前 return(开新面板),这里不再重复弹。
		_notify_team()   # 先补位再技能流程全部完成：此刻才刷新常驻"替补队伍"（避免与替补面板叠层/吞点击）
		return
	# 恢复流程（回合中途换人）：本轮是否我方行动。是我方回合 -> 回到我方输入；否则等待对AI
	if GameState.active_side == _my_side():
		state = State.PLAYER_INPUT
		if _has_remaining_player():
			action_info.emit("继续你的回合")
		else:
			# 所有英雄已行动完：不自动结束，提示玩家手动点「结束回合
			action_info.emit("所有英雄已完成行动，点「结束回合」交给敌方")
	else:
		state = State.ENEMY_TURN
		if GameState.is_online:
			action_info.emit("等待对方行动…")
			enemy_turn_waiting.emit()
		else:
			action_info.emit("敌方回合…")
	_notify_team()   # 中途换人恢复后刷新常驻"替补队伍"面板

# 主动撤下（提交入口，仅本端操作时调用）：校验后执行，联机走网令同步
func _withdraw_unit(u: Unit) -> void:
	if state != State.PLAYER_INPUT:
		return
	if u == null or not u.alive or u.faction != _my_faction():
		action_info.emit("请先选中一名我方英雄，再点击「撤下」")
		return
	if not GameState.is_online:
		_apply_withdraw(u)
		return
	# 联机：主机权威执广播；客户端只发指令给主机
	# 索引必须_apply_withdraw 之前取：执行u 已从 units 移除，再 find 只会得到 -1
	# 对端-1 找不到单-> 撤下不同步（但后sub 是内容寻址，照常同步，形成"只上了新英雄"的假象）
	var w_idx := units.find(u)
	if GameState.is_host:
		_apply_withdraw(u)
		if w_idx >= 0:
			NetBus.send_all(JSON.stringify({ "type": "withdraw", "u": w_idx }))
	else:
		if w_idx >= 0:
			NetBus.send_to(1, JSON.stringify({ "type": "withdraw", "u": w_idx }))

# 撤下的权威执行（两端一致）：仅本端回合可触发本端英雄撤下；真正移除单位_on_unit_died
# 死亡方属于谁、由谁替补，_on_unit_died 的视角化逻辑保证两端一致
func _apply_withdraw(u: Unit) -> void:
	if u == null or not is_instance_valid(u) or not u.alive:
		return
	log_message.emit("%s 被主动撤下（视为阵亡）。" % u.display_name)
	var mine := u.faction == _my_faction()
	if mine:
		_clear_selection()
		state = State.ANIMATING   # 仅撤下方需要锁输入；对端只是看到对方撤下，回合状态不
	u.alive = false
	_on_unit_died(u, false)   # 主动撤下：不立墓碑；补位/胜负_on_unit_died 处理
	if state == State.ENDED:
		return
	if not mine:
		return   # 对端视角：只移除该单位，不切换本端回合状态（等撤下方sub 广播
	# 撤下方收尾：_on_unit_died 在本方回合内已进入替补流程则直接返回，避免重复弹
	if state == State.SUBSTITUTING or state == State.PLACE_SUB:
		return
	if _my_roster().size() > 0:
		_pending_player_subs += 1
		_try_begin_next_sub()   # 撤下一人也算一个替补名额；不在替补流程中则直接开
	else:
		action_info.emit("已无替补，本阵减少一名英雄")
		_resume_after_sub()

# 按钮入口：撤下当前选中的我方英
func _withdraw_player_unit() -> void:
	_withdraw_unit(selected)

# ---- 拖拽撤下（点击英雄按住拖到出生点释放----
func _begin_drag(u: Unit) -> void:
	if _drag_unit != null or u == null or not u.alive:
		return
	_drag_unit = u
	_drag_start_mouse = get_global_mouse_position()
	_drag_orig_pos = u.position
	_dragging = false
	_clear_selection()
	u.z_index = 30

func _drag_follow() -> void:
	if _drag_unit == null or not is_instance_valid(_drag_unit) or not _drag_unit.alive:
		_cancel_drag()
		return
	if not _dragging and get_global_mouse_position().distance_to(_drag_start_mouse) > _DRAG_THRESHOLD:
		_dragging = true
		action_info.emit("把英雄完全拖出棋盘下边框（整个六边形出去）再松开即撤下")
		_show_drag_highlight()
	if _dragging:
		_drag_unit.position = get_global_mouse_position()

func _show_drag_highlight() -> void:
	# 高亮"本端我方"出生区（联机主机=客户红；单机=玩家），撤下到该区下方即可
	var pc := {}
	for c in _spawn_cells(_my_faction()):
		pc[c] = Color(0.2, 0.9, 0.5, 0.85)
	_preview_cells = pc
	_apply_highlights()

func _clear_drag_highlight() -> void:
	_preview_cells = {}
	_apply_highlights()

func _finish_drag() -> void:
	if _drag_unit == null:
		return
	var u := _drag_unit
	var was_dragging := _dragging
	_drag_unit = null
	_dragging = false
	if not is_instance_valid(u) or not u.alive:
		return
	u.z_index = 2
	_clear_drag_highlight()
	if was_dragging:
		# 整枚六边形完全越过棋盘下边框（最底行格子底边 + 单位自身半高）才撤下，
		# 避免只拖过一半/贴边时误触撤下
		if get_global_mouse_position().y >= _drag_release_y():
			u.position = _drag_orig_pos
			_withdraw_unit(u)
		else:
			u.position = _drag_orig_pos
			action_info.emit("未完全拖出棋盘，「撤下」已取消")
	else:
		# 没有拖动 -> 视为普通点击选中
		_on_cell_clicked(u.cell)

# 撤下判定线 y：棋盘整体在屏幕上的最低外缘（各格子六边形底边/翻转后的最下缘）
# 再往下加"单位自身垂直半高"，保证松手时整个单位六边形已完全越过棋盘下边框。
# cell_world_center 已含联机 180° 翻转，故对主机/客户端两种视角都取到屏幕最低边。
func _drag_release_y() -> float:
	var r := hex_size
	var bottom := -INF
	if grid != null:
		var half_h := 0.8660254 * r   # 平顶六边形垂直半高（底边为最下缘）
		for c in grid.all_cells():
			bottom = maxf(bottom, board_view.cell_world_center(c).y + half_h)
	if bottom == -INF:
		return INF   # 理论上不会走到（对局必有棋盘）；无棋盘时不判定撤下
	# 单位绘制半径 = hex*0.9，其垂直半高 = 0.866 * (0.9*hex)
	return bottom + 0.8660254 * (0.9 * r)

func _cancel_drag() -> void:
	if _drag_unit != null and is_instance_valid(_drag_unit):
		_drag_unit.z_index = 2
		_drag_unit.position = _drag_orig_pos
	_drag_unit = null
	_dragging = false
	_clear_drag_highlight()

func _free_spawn_cell(faction: int) -> Vector2i:
	# 优先在本方出生区内的本方墓碑格落位（阵亡原地补位），再取普通空
	for c in graves.keys():
		var info = graves[c]
		var fn := -1
		if typeof(info) == TYPE_DICTIONARY:
			fn = int(info.get("fn", -1))
		if fn == faction and _in_spawn_cell(c, faction) and not occupancy.has(c):
			return c
	var free: Array = []
	for c in _spawn_cells(faction):
		if not occupancy.has(c):
			free.append(c)
	if free.size() == 0:
		return Vector2i(-99, -99)
	# 敌方：分散落位——选与"已部署敌方单位所在列"最远的空列，横向拉开、避免扎堆从左到
	if faction == DataRegistry.Faction.ENEMY:
		var best: Vector2i = free[0]
		var best_d := -1
		for c in free:
			var mind := 999999
			for u in units:
				if u.alive and u.faction == DataRegistry.Faction.ENEMY and abs(u.cell.x - c.x) < mind:
					mind = abs(u.cell.x - c.x)
			# 无已部署单位时，优先取最外侧列（边缘），之后逐次向内
			if mind == 999999:
				mind = max(c.x, grid.width - 1 - c.x)
			if mind > best_d:
				best_d = mind
				best = c
		return best
	# 其他阵营：取第一个空
	return free[0]

func _in_spawn_cell(cell: Vector2i, faction: int) -> bool:
	return _spawn_cells(faction).has(cell)

func _spawn_cells(faction: int) -> Array:
	var out: Array = []
	if faction == DataRegistry.Faction.PLAYER:
		var row := grid.height - 1
		for c in grid.width:
			var cell := Vector2i(c, row)
			if grid.in_bounds(cell):
				out.append(cell)
	else:
		# 敌方出生区（顶部交错皇冠：row 0 顶帽 1,3 + row 1 偶列 0,2,4，共 5 格；删左右两列后的居中窄顶宽底）
		var ecells: Array = [
			Vector2i(1, 0), Vector2i(0, 1), Vector2i(2, 1), Vector2i(3, 0), Vector2i(4, 1),
		]
		for c in ecells:
			if grid.in_bounds(c) and not occupancy.has(c):
				out.append(c)
	return out

func _spawn_benchbackup(hero_id: String, side: int, grave: Vector2i) -> void:
	var def := DataRegistry.get_hero(hero_id)
	if def == null:
		return
	var u := Unit.new(def, side, grave, hex_size * 0.9)
	if def.skills.has(DataRegistry.Skill.SWIFT):
		u.move_range += 1
	u.position = board_view.cell_world_center(grave)
	u.hp_changed.connect(_on_unit_hp_changed)
	u.damaged.connect(_on_unit_damaged)
	u.died.connect(_on_unit_died)
	u.modulate = Color(0.6, 1.0, 0.6, 1.0)   # 替补入场的标记色
	var t := create_tween()
	u.modulate.a = 0.0
	add_child(u)
	units.append(u)
	occupancy[grave] = u
	t.tween_property(u, "modulate:a", 1.0, 0.3)
	log_message.emit("%s 替补登场（%s）。" % [def.display_name, "我方" if side == _my_faction() else "敌方"])
	# 替补登场效果
	_trigger_on_enter.call_deferred(u)

# ---- 强力 AI：搜索敌方本回合全部操作并打分，执行最优序----
func _run_enemy_turn() -> void:
	var my_session := _session_id   # 记录本次回放所属会话，重开后会
	if get_tree() == null:
		return   # 场景已释放（点击重开/reload）：安全退
	await get_tree().create_timer(0.5).timeout
	if my_session != _session_id:
		return   # 已重开：本会话作废，安全退
	# 构建模拟快照（与 units 顺序一致，用于回放映射
	var refs: Array = units.duplicate()
	var descs: Array = []
	var occ_snap := {}
	var uidx := {}   # Unit -> idx（附体绑定传给模拟用）
	for i in units.size():
		uidx[units[i]] = i
	for i in units.size():
		var u: Unit = units[i]
		var poss_by := -1
		if _possess_links.has(u) and is_instance_valid(_possess_links[u]):
			poss_by = uidx.get(_possess_links[u], -1)   # 被附体者记录施加它的宿魂
		descs.append({
			"fn": u.faction, "hero": u.hero_id, "cell": u.cell, "hp": u.hp, "max_hp": u.max_hp,
			"atk": u.atk, "eatk": u.effective_atk(), "move": u.move_range, "emove": u.effective_move(),
			"atk_range": u.attack_range,
			"atk_type": u.attack_type, "skills": u.skills, "name": u.display_name,
			"stunned": u.has_status("stun"), "silenced": u.has_status("silence"),
			"shield": u.has_status("shield"), "heavy": u.has_status("heavy"),
			"poisoned": u.has_status("poison"), "frozen": u.has_status("freeze"),
			"poss_by": poss_by,
		})
		occ_snap[u.cell] = i

	var ai := BattleAI.new(grid)
	ai.difficulty = GameState.ai_difficulty
	ai.log_decisions = _CONSOLE_AI_LOG   # AI 行动方案评分输出跟随 AI 行为日志总开关（默认关）
	# 金矿（buff_items[cell]=="gold"）供 AI 参考，让黄金矿工优先走过去拾取
	var gold_snap := {}
	for c in buff_items.keys():
		if buff_items[c] == "gold":
			gold_snap[c] = true
	# 墓碑（阵亡格）供 AI 参考：阻挡移动，不可落
	var grave_snap := {}
	for c in graves.keys():
		grave_snap[c] = true
	# 障碍物供 AI 参考：阻挡移动与攻击视
	var obstacle_snap := {}
	for c in obstacles.keys():
		obstacle_snap[c] = true
	# 后台线程搜索：AI 计算期间主线程保持响应（可点英雄查看属性），算完再回放。
	# BattleAI 只读 grid 几何与 DataRegistry 静态数据，不触碰场景节点，线程安全。
	_ai_plan = []
	_ai_done = false
	_ai_used = false
	if _ai_thread != null and _ai_thread.is_started():
		_ai_thread.wait_to_finish()   # 保险：不应有残留线程
	_ai_thread = Thread.new()
	_ai_thread.start(_enemy_ai_worker.bind(ai, descs, occ_snap, gold_snap, grave_snap, obstacle_snap))
	# 主线程等待期间每帧让出（UI 照常刷新/可点击查看），直到线程完成
	while true:
		if get_tree() == null or my_session != _session_id:
			return   # 场景已释放/已重开：安全退出（线程结果作废）
		_ai_mutex.lock()
		var finished := _ai_done
		_ai_mutex.unlock()
		if finished:
			break
		await get_tree().process_frame
	_ai_thread.wait_to_finish()   # 回收线程资源（结果已写入 _ai_plan）
	_ai_thread = null
	if _ai_done and not _ai_used:
		_ai_used = true
		_ai_mutex.lock()
		var plan: Array = _ai_plan
		_ai_mutex.unlock()
		await _replay_enemy_plan(plan, refs, my_session)
		if my_session != _session_id or get_tree() == null:
			return
		if not _check_win():
			await _trigger_turn_end_all(DataRegistry.Faction.ENEMY)
			_clear_statuses(DataRegistry.Faction.ENEMY)
			_settle_side_round_damage(GameState.SIDE_ENEMY)   # 1回合起：敌半回合结束只扣敌方
			# 排空淡出中的死亡结算：死在敌回合最后一步的单位其 died 晚 0.3s 触发，
			# 若在此切边，补位窗口（active_side==ENEMY）会错过、阵亡日志晚于"回合结束"打印。
			# 先把死亡全部结算完（墓碑/补位/统计），再打印回合结束并切边。
			await _drain_pending_deaths()
			if _CONSOLE_SUB_LOG:
				print("[替补统计] 敌方回合结束：我可替补次数=%d" % _my_sub_quota())
			GameState.end_current_side(_first_side)
			# 换边停顿：敌方行动完我方回合开始被动之间留出间隔（与玩家结束回合一致）
			await get_tree().create_timer(0.8).timeout
			_begin_side(GameState.SIDE_PLAYER)

# 后台线程入口：构建模拟状态并搜索敌方最优计划（不触碰场景，仅读 grid/DataRegistry）
func _enemy_ai_worker(ai: BattleAI, descs: Array, occ_snap: Dictionary, gold_snap: Dictionary, grave_snap: Dictionary, obstacle_snap: Dictionary) -> void:
	var sim := ai.build_state(descs, occ_snap, gold_snap, grave_snap, obstacle_snap)
	var result: Array = ai.search(sim, DataRegistry.Faction.ENEMY)
	_ai_mutex.lock()
	_ai_plan = result
	_ai_done = true
	_ai_mutex.unlock()

# 回放执行 AI 计划（主线程逐招执行并等待动画）
func _replay_enemy_plan(plan: Array, refs: Array, my_session: int) -> void:
	for step in plan:
		if GameState.match_over:
			break
		if my_session != _session_id:
			return   # 已重开：安全退出，避免访问已释放单位
		if get_tree() == null:
			return
		await _wait_sub_done()   # 若在替补流程则暂停，等玩家选好并落位
		var idx: int = step["idx"]
		if idx < 0 or idx >= refs.size():
			continue
		var raw_u: Variant = refs[idx]
		if raw_u == null or not is_instance_valid(raw_u):
			continue
		if not (raw_u is Unit):
			continue
		var u: Unit = raw_u as Unit
		if u == null or not u.alive:
			continue
		var a: Dictionary = step["action"]
		if a.has("move") and a["move"] != null:
			_do_move(u, a["move"], true)
			await _wait_action_done()   # 等待移动动画真正播完（与玩家侧节奏一致）
		if a.has("atk") and int(a["atk"]) >= 0:
			var t_idx := int(a["atk"])
			if t_idx >= 0 and t_idx < refs.size() and is_instance_valid(refs[t_idx]):
				var t: Unit = refs[t_idx]
				if t.alive and t.faction != DataRegistry.Faction.ENEMY and is_instance_valid(u):
					# 只允许攻击当前射程内的目标（防御AI计划偏差/移动失败导致越界攻击
					if _in_attack_range(u, t):
						_do_attack(u, t, true)
						await _wait_action_done()   # 等待攻击（含反击）演出完全结

# 替补流程期间暂停敌方 AI 执行（轮询直到替补结束）
func _wait_sub_done() -> void:
	var my_session := _session_id
	while state == State.SUBSTITUTING or state == State.PLACE_SUB:
		if my_session != _session_id:
			return   # 已重开：安全退出
		if get_tree() == null:
			return   # 已脱离场景树：停止轮询，避免访问 null get_tree()
		await get_tree().process_frame

# 等待敌方单位的一招动画播完（移动/攻击）。信号与超时竞速：
# 正常情况下 _finish_move/_finish_attack 会发射 action_finished，立即返回；
# 若防御路径漏发射（单位被释放、异常提前返回等），1.5s 超时兜底，避免回放永久挂起
func _wait_action_done() -> void:
	var my_session := _session_id
	var done := [false]   # 用数组承载：lambda 改元素不触发"重赋值捕获"混淆
	action_finished.connect(func(): done[0] = true, CONNECT_ONE_SHOT)
	if get_tree() == null:
		return   # 已脱离场景树：直接返回
	var limit := get_tree().create_timer(3.0)
	while not done[0] and not limit.time_left <= 0.0:
		if my_session != _session_id:
			return   # 已重开：安全退出
		if get_tree() == null:
			return   # 已脱离场景树：停止轮询
		await get_tree().process_frame

# 排空"淡出中的死亡结算"：die() 先淡出 0.3s 才发 died（墓碑/补位/阵亡日志都在 died 后执行）。
# 若回合末不等待，死在敌方回合最后一步的单位，其结算会撞上回合切换（补位窗口按 active_side
# 判断会错过、"敌方回合结束"日志先打印、墓碑晚一拍）。回合切边前调用，让死亡先结算完。
func _drain_pending_deaths() -> void:
	var my_session := _session_id
	var deadline := Time.get_ticks_msec() + 2500   # 兜底超时：异常卡住不永久阻塞回合
	while true:
		var pending := false
		for u in units:
			if u != null and is_instance_valid(u) and not u.alive:
				pending = true   # 还有已死未结算（淡出中）的单位
				break
		if not pending:
			return
		if get_tree() == null or my_session != _session_id or Time.get_ticks_msec() > deadline:
			return   # 场景已释放/已重开/超时：安全退出
		await get_tree().process_frame

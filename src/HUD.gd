class_name HUD
extends CanvasLayer
## 战斗界面浮层：显示回合/阵营、消息日志、操作提示，并放置结束回合/重开按钮。

var battle: Battle

var _round_label: Label
## 【2026-09-27】顶部中间那组的"上一次排版输入"（回合文字 + 倒计时文字 + 火焰是否亮 + 视口宽）——
##   用它挡掉重复的 `_fit_top_center()`（`_update_turn_timer()` 调得很勤）。
var _top_fit_key := ""
var _last_phase_state := -1
# 【2026-09-28·用户报「部署阶段选了英雄上场后，替补队伍没把那个英雄移除」】
#   部署面板盯一个「卡池指纹」（池子人数 + 两个待放位 + 已上阵数）：变了就重刷面板。
var _deploy_pool_key := ""   # 上次刷新时的 Battle.state（_process 检测阶段切换，补刷新顶部标签）
var _turn_banner: Label = null       # 回合切换中央大字横幅（短暂显示后自动消失）
var _turn_banner_tween: Tween = null
var _flame_icon: Control = null   # 扣血提醒火焰（第11回合起常驻脉动）
var _round_fire_tween: Tween = null   # 回合标签的"燃烧"颜色脉动 tween（第11回合起）
var _turn_timer_label: Label   # 本端回合剩余时间（对局中我方回合显示）
var _result_overlay: Control = null
var _netdown_overlay: CanvasLayer = null   # 联机对局断线提示层
var _team_panel: PanelContainer = null    # 下方常驻队伍展示（整支卡组，含替补）——替补阶段复用为"选人面板"
# 下方队伍卡行的半径上限（【2026-09-28】按可用宽度反算后再封顶）：
#   一行 n 张平顶六边形的总宽 = `2r + (n−1)·1.5r` ⇒ **8 张一行的物理上限 = 视口宽 / 12.5 ≈ 57**
#   （720 视口）。所以"8 个英雄占满宽度"时每张卡最大就这么大；想明显更大只能改两行（4+4）或让卡重叠。
const _TEAM_ROW_MAX_R := 56.0
var _arena_panel: PanelContainer = null   # 竞技场选人面板（2选1）
var _deck_pick_overlay: Control = null     # 普通模式"选择卡组"面板（进战斗后弹：卡组1/2/3 切换 + 随机英雄）
# 【2026-09-23】常驻战斗 UI 的根（`_build()` 里那个 Control）：`结束回合/重开/返回选人/暂停` 都在它下面。
# 临时遮罩挂到 HUD（CanvasLayer）会**盖住这些按钮** ⇒ 弹"选择卡组"时点不了重开/退出；
# 插进 `_ui_root` 的第 0 个子节点就两全：棋盘照旧被拦（HUD 层在棋盘之上），按钮仍在遮罩之上。
var _ui_root: Control = null
var _deck_pick_decks: Array = []           # 面板持有的 3 个已存卡组（下标0=卡组1）
var _deck_pick_slot := 1                   # 当前查看的卡组槽（1..3）
var _deck_pick_tabs: Dictionary = {}       # slot -> Button（卡组1/2/3 切换钮）
var _deck_pick_preview: Control = null     # 当前卡组的队伍预览宿主
var _deck_pick_info: Label = null          # 当前卡组信息行（人数/不足提示）
var _deck_pick_start_btn: Button = null     # 用当前卡组出战
# 【2026-09-21 用户定】选卡组限时大字（读 `battle.deck_pick_time_left`，15 秒，超时随机选一个）
var _deck_pick_timer_label: Label = null   # 【2026-09-29 已废】选卡组读秒改到状态栏（保留声明，恒为 null）
var _deck_pick_panel: PanelContainer = null # 面板本体（切换卡组后重算尺寸定位）
# 【2026-09-23 修·用户报"点击卡组切换后弹窗会左右移动"】面板尺寸**只在首次量一次**：
#   量的是"三个卡组里人最多的那支"（卡行最宽）+ 最宽形态的限时大字（两位数秒）。
#   原来每次点 卡组1/2/3 都按**当前**内容重算宽度并重新居中 ⇒ 卡行人头数 / 秒数位数一变，
#   弹窗就整体左右跳（而且 `reset_size()` 清不掉 `custom_minimum_size` ⇒ 宽度只增不减）。
var _deck_pick_panel_w := 0.0
var _deck_pick_panel_h := 0.0
var _arena_timer_label: Label = null      # 选人倒计时（选卡面板上方的大字）
var _arena_pair: Array = []               # 【2026-09-29】当前这一轮 2 选 1 的两张（选中演出/回放重演都要用）
var _arena_fly_tween: Tween = null        # 【2026-09-29】那一趟"飞卡"的 tween（回放跳段时要能掐掉）
# 【2026-09-23 改·用户要求"死亡时卡面破碎升天 → 引导到顶部阵亡标志 → 标志出现并摇晃"+ "空圈和骷髅一样大"】
#   原来每侧是一个 Label 拼字符串（`"我方 ☠☠☠"`）⇒ ① `○` 与 `☠` 字形不一样大、整行会漂；
#   ② 没法定位到"具体哪一个标记"去做飞行终点与单独摇晃。
#   现在拆成：每侧 = 一个名字 Label + `LOSS_DEATH_COUNT` 个 `DeathMark` 槽（固定尺寸、自绘圆环/骷髅）。
var _my_death_name: Label = null
var _op_death_name: Label = null
# 【2026-09-29·用户要求「将状态栏死亡标志移到名字下方」】两侧各是一个**竖排栈**（名字框在上、阵亡标志在下）
#   ⇒ 记下这两个 Control 供 `_fit_top_center()` 量"中间那组还剩多少宽度"用
#   （名字框现在只是栈里的一格，量它自己会漏掉下面那排标志的宽度）。
var _top_stack_blue: Control = null
var _top_stack_red: Control = null
var _my_marks: Array = []      # 本端视角的"我方"那排（左）
var _op_marks: Array = []      # 本端视角的"对方"那排（右）
var _death_fx: DeathFx = null  # 阵亡演出层（全屏，只画特效；比状态栏晚加入 ⇒ 画在状态栏之上）
# 【2026-09-28·用户要求·击杀演出】击杀特效层（全屏）：击杀者卡面滑进画面停一下 + 阵营色拖影
#   触发 = `Battle.kill_intro_requested`（**开打前**的预告）：Battle 会一直等到这里播完、调
#   `battle.kill_intro_finished()` 才继续 ⇒ 观感是"特效先滑完，英雄再动手击杀"。
var _kill_fx: Control = null
var _kill_fx_n := 0            # 同屏多次击杀时上下错开（AoE 一次死两个不会完全重叠）
# 【2026-09-29·用户报「失败爆炸效果有两次」】结算演出（骷髅震动 → 状态栏爆炸）正在播的标记：
#   重复触发时直接忽略（Battle 侧也有"结算只发一次"的闸门，这里是第二道保险）。
var _defeat_anim_running := false
# 延迟揭示：真实阵亡数（战斗逻辑）先涨，**标志等卡片落地才出现** ⇒ `_reveal_pending` = 已死亡但还没点亮的个数。
# 槽位 `filled` 的个数记在 `_mark_filled` 里（= 界面上看到的），两者相加 = 真实阵亡数。
var _reveal_pending := { "my": 0, "op": 0 }
var _mark_filled := { "my": 0, "op": 0 }
var _pause_btn: Button = null        # 暂停键（仅单机显示，放右上角）
var _pause_overlay: Control = null   # 暂停遮罩（暂停时显示"已暂停/继续游戏"）
var _ladder_confirm: Control = null  # 【天梯】"确定放弃本次天梯？"的再确认层（用户要求）
# 【2026-09-25 用户要求·天梯主动放弃】放弃确认后**也要弹结算面板**（提示"才X连胜，跑什么？去简单难度偷偷进步啊？"）
#   ⇒ 这个一次性标记让 `show_result()` 知道"这次是放弃、不是打输"（用它选文案 + 保持整棵树暂停）。
var _ladder_gave_up := false
# 【2026-09-23 深夜·用户贴的 `HUD.gd:54 UNUSED_PRIVATE_CLASS_VARIABLE`】这两行是老"整行文字"版阵亡栏
#   留下的计数器（`_last_pd`/`_last_ed`）—— 2026-09-23 改成**逐槽 DeathMark** 后，界面状态改由
#   `_reveal_pending` / `_mark_filled` 记录 ⇒ 这两个再没人读写，已删除（纯删死变量，行为零变化）。
var _last_my_text := ""   # 上次刷新的"我方"侧文字（联机=姓名；用于姓名变化时补刷新）
var _last_op_text := ""   # 上次刷新的"敌方"侧文字（联机=姓名）
var _end_btn: Button          # 结束回合（仅我方回合可点）
# 【2026-09-27·用户要求】替补队伍列表**默认收起**，由按钮行右贴边的箭头拉出/收回：
var _team_panel_open := false        # 用户是否把它拉出来了（真值 = 展开）
## 【2026-09-28·用户要求「竞技场开局默认打开替补队伍面板，直到部署完成再关闭」】
##   竞技场**部署期间**由系统强制展开。与用户自己的开关（`_team_panel_open`）分开记：
##   部署一过就自动收回，且不会把"用户手动开过"这件事记成永久展开。
var _team_panel_forced := false
var _team_toggle_btn: Button = null  # 那个按钮（`name = "TeamToggle"`，探针按名字找得到）
var _team_toggle_tex_open := false   # 按钮当前贴的是不是"收回"那张图（每帧刷新时用它挡掉重建）
## 【2026-09-28·用户报「点击替补队伍按钮的时候，会弹出一个属性框」】从右往左滑出的那 0.16s 里，
##   卡片会从鼠标底下掠过 ⇒ 卡片的悬停回调把**英雄属性框**弹了出来。滑出期间一律不响应悬停/点击，
##   滑完再清一次属性框（`_team_panel_sliding`）。
var _team_panel_sliding := false
# 【2026-09-28·用户要求】英雄死亡 / 主动撤下（= 自动进入替补流程）时，列表也要
#   **从右往左滑出来**（哪怕它此前已经开着）⇒ 这一个标志由阶段切换处置位，_refresh_team_panel() 用完即清。
var _team_panel_slide_next := false
# 【2026-09-27·用户要求】结束回合按钮换成图片（图缺失时自动退回原来的金色文字按钮）
const END_TURN_TEX := "res://assets/界面/结束回合.png"
const END_BTN_IMG_H := 112.0   # 图片按钮的高度（宽按图的比例 ⇒ 112 × 237/209 ≈ 127）
# 【2026-09-29·用户要求】顶部状态栏两侧的"我方/敌方"换成**名字框**素材，名字写在框里：
#   蓝方（= PLAYER）在左、红方（= ENEMY）在右（单机里本端就是 PLAYER ⇒ 正好"蓝左红右"；
#   联机客房是红方，框色仍按**绝对阵营**给，与下面那排阵亡标志同一套口径）。
#   素材是用户提供的 237×203 带透明通道 PNG；高度由 `NAME_PLATE_H` 定、宽度按原图比例（不会拉伸变形）。
#   【2026-09-29·用户要求「将状态栏死亡标志移到名字下方」】名字框与阵亡标志改成**竖着两行** ⇒
#   框高从 44 收到 **34**（两行加起来 34 + 1 + 20 = 55 ≤ 56，见 `_build()` 那段高度账）。
const NAME_FRAME_BLUE := preload("res://assets/界面/蓝方名字框.png")
const NAME_FRAME_RED := preload("res://assets/界面/红方名字框.png")
# 【2026-09-29·用户要求「单机敌方用难度+AI」】难度档名（下标 = `GameState.ai_difficulty`：
#   0 简单 / 1 普通 / 2 困难 / 3 噩梦）⇒ 单机右侧名字显示成「噩梦AI」这样。
const AI_DIFF_NAMES := ["简单", "普通", "困难", "噩梦"]
const NAME_PLATE_H := 34.0
# 【2026-09-29·用户要求「战斗中上方状态栏的背景增加透明度」】顶部状态栏那块底的**不透明度**：
#   0 = 完全透明（只剩名字框 / 阵亡标志 / 回合数浮在地面上）、1 = 完全不透明。
#   原来是 **0.85**（几乎实心、把地面压住了），现在调成 **0.55**；想更透继续往下调（0.35 已经很透）。
#   ⚠️ 只管这一条状态栏的底色：名字框与阵亡标志都是各自的素材，不受影响。
const TOP_BAR_BG_A := 0.55
# 【2026-09-29·用户报「第三枚和其他的间隔不一样」】顶部那排阵亡标记的**固定节距**：
#   每枚的 x = `i * (DeathMark.SLOT_D + MARK_GAP)`（不靠容器自动排列）⇒ 间隔恒定可拧。
#   想宽一点就加大（8~12 挺明显）；嫌挤就减小（4 很紧、0 会贴在一起）。
const MARK_GAP := 6.0
# 【2026-09-29·用户报「最右边那个空圈和骷髅都太贴边了」】这排标记**外缘还要再内缩**多少像素
#   （空圈和骷髅都算，两边对称：我方往右缩、敌方往左缩）。
#   ⚠️ 原来标记行是贴着**名字框最外沿**（离屏边 12px）摆的 ⇒ 最外面那枚离屏边只剩 12px，看着太挤。
#   现在额外内缩 `MARK_EDGE_PAD` ⇒ 最外面那枚离屏边 = 12 + 本值 = **24px**，
#   正好和名字框里文字的边距（`NAME_EDGE_PAD = 12`）对齐 ⇒ 三枚标记像"从名字下面开始排"。
#   嫌还是太贴边就加大（20 / 28），想更靠外就减小到 0（回到贴框沿）。
const MARK_EDGE_PAD := 12.0
# 【2026-09-29·用户要求「双方的名字都贴边显示」】框内文字离框沿留的边距（像素）
const NAME_EDGE_PAD := 12.0
# 【2026-09-29·用户要求「名字框太长了，给中间的回合数预留空间」】顶部第一行中间给「第 N 回合 ·
#   火焰 · 剩余时间」留的宽度（左右两条名字框各占 `(屏宽 − 24 − 本值) / 2`、等长）。
#   这组文字会随回合数/计时变长 ⇒ `_fit_top_center()` 仍会按实际宽度逐档缩字号兜底。
const TOP_MID_GAP := 250.0
# 【2026-09-29·用户要求】左下角「菜单」按钮的素材；**高度与「替补队伍」那个图标按钮一致**
#   （`TEAM_TOGGLE_ICON_H = 58`），宽度按原图比例 ⇒ 两个图标按钮同高、大小观感一致。
const MENU_TEX := "res://assets/界面/菜单_透明.png"
const MENU_IMG_H := 58.0
# 【2026-09-27·用户要求】「结束回合按钮往上移一点」+「那行右边贴边加一个箭头，点开拉出替补队伍列表」：
#   ① 按钮带离屏幕底边留 `BTN_ROW_FOOT_GAP`（原来是 10 ⇒ 现在抬起来 30px）；
#   ② 替补队伍列表**默认收起**，由右贴边的箭头按钮拉出/收回（`_team_panel_open`）；
#   ③ 棋盘那边（`Battle._fit_hex_size()`）**共用这两个常量**算"屏底要留多少" ⇒ 别再各写各的魔数。
const BTN_ROW_FOOT_GAP := 40.0
const TEAM_TOGGLE_CLOSED := "▲"   # 收起状态下**图缺失时**的退回文案：点它把替补列表拉出来
# 【2026-09-28·用户要求「加了关于替补队伍的图标，你替换上去」】图标本身就是语义：
#   收起时贴「展开替补队伍」、拉出后贴「收回替补队伍」（两张都是 216×221）。
const TEAM_TOGGLE_TEX_CLOSED := "res://assets/图标/展开替补队伍.png"
const TEAM_TOGGLE_TEX_OPEN := "res://assets/图标/收回替补队伍.png"
# 【2026-09-28·用户要求】「喊话按钮换成 assets/图标/喊话.png」：有图就**按钮本体用图标**（不写文字，
#   与上面那个「展开替补队伍」图标按钮同款口径）；图缺失 ⇒ 自动退回原来的文字按钮（不影响联机可玩性）。
const CHAT_ICON := "res://assets/图标/喊话.png"
const TEAM_TOGGLE_ICON_H := 58.0   # 图标按钮高度（宽按图的比例 ⇒ 58 × 216/221 ≈ 57）
const TEAM_TOGGLE_OPEN := "▼"     # 展开状态下的箭头：点它收回去
# 【2026-09-27】底部常驻行现在只有「结束回合」；`_restart_btn` 已随"重开/返回选人整合进暂停面板"移除。
# 【2026-09-28·用户要求】联机那枚「返回大厅」也删掉 ⇒ 底部行两种模式都只剩「结束回合」；
#   联机退出改走**右上角「认输」**：先喊一句完整的话给对端，再走认输结算（退出大厅走结算面板的按钮）。
var _surrender_btn: Button = null   # 【2026-09-28】联机：认输（单机恒为 null）
# 【2026-09-29·用户要求】联机结算面板的「再来一局」：点了要**等对方也点**才开局
var _rematch_btn: Button = null
var _warn_holder: Control = null   # 回合剩余时间不足警告：屏幕边缘浅红闪烁
var _warn_tween: Tween = null      # 边缘警告呼吸 tween
var _unit_card_overlay: Control = null   # 右键英雄信息卡（成员持有，避免 lambda 捕获被释放节点）
# 【2026-09-27·用户要求】开局"先手"提示整块删除（先文字、后图片都删了）：不再有任何提示 UI。
# 联机快捷喊话:左下角按钮 + 选言面板 + 顶部气泡
var _chat_btn: Button = null
var _chat_panel: PanelContainer = null
var _chat_overlay: Control = null   # 选言面板的全屏透明层：点面板以外任意处收起
var _chat_bubble: PanelContainer = null
var _chat_bubble_tween: Tween = null

func _ready() -> void:
	layer = 50
	_build()
	NetBus.disconnected.connect(_on_battle_disconnected)   # 对局中断线弹提示（不再直接跳场景）

# 联机对局断线：弹出"已断线，本局无法继续"提示，用户点按钮后回大厅
func _on_battle_disconnected() -> void:
	if not GameState.is_online or _netdown_overlay != null:
		return
	if battle == null or not is_instance_valid(battle):
		return
	if battle.state == Battle.State.ENDED:
		return   # 已结算：结算按钮处理
	var ovly := CanvasLayer.new()
	ovly.layer = 95
	add_child(ovly)
	_netdown_overlay = ovly
	var vsize := get_viewport().get_visible_rect().size
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	ovly.add_child(dim)
	var panel := PanelContainer.new()
	# 面板外观走主题里的"弹出框边框"（theme/panel_frame_dark.png）
	ovly.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	box.custom_minimum_size = Vector2(500, 0)
	panel.add_child(box)
	var title := Label.new()
	title.text = "连接已断开"
	title.add_theme_font_size_override("font_size", 28)
	title.add_theme_color_override("font_color", Color(1.0, 0.55, 0.45))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)
	var line := HSeparator.new()
	box.add_child(line)
	var note := Label.new()
	note.text = "对方已离开，本局无法继续。"
	note.add_theme_font_size_override("font_size", 20)
	note.add_theme_color_override("font_color", Color(0.92, 0.94, 1.0))
	note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.custom_minimum_size = Vector2(460, 0)
	note.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(note)
	var hint := Label.new()
	hint.text = "点「返回大厅」回到联机大厅，可重新开房或重新连接。"
	hint.add_theme_font_size_override("font_size", 17)
	hint.add_theme_color_override("font_color", Color(0.75, 0.8, 0.9))
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size = Vector2(460, 0)
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(hint)
	var bt := Button.new()
	bt.text = "返回大厅"
	bt.custom_minimum_size = Vector2(0, 60)
	bt.add_theme_font_size_override("font_size", 22)
	bt.pressed.connect(_on_netdown_back)
	box.add_child(bt)
	panel.reset_size()
	panel.position = Vector2((vsize.x - panel.size.x) / 2.0, (vsize.y - panel.size.y) / 2.0)

func _on_netdown_back() -> void:
	if _netdown_overlay != null:
		_netdown_overlay.queue_free()
		_netdown_overlay = null
	GameState.reset_online()
	NetBus.stop()
	get_tree().change_scene_to_file("res://scenes/NetLobby.tscn")

func bind(b: Battle) -> void:
	battle = b
	battle.match_result.connect(show_result)
	battle.sub_select_requested.connect(_refresh_team_panel)   # 替补阶段：同一队伍面板切换为可点选
	battle.sub_placed.connect(_on_sub_placed)
	battle.arena_draft_requested.connect(_show_arena_pair)
	battle.arena_draft_done.connect(_close_arena_panel)
	battle.deck_pick_requested.connect(_show_deck_pick_panel)
	battle.deck_pick_done.connect(_close_deck_pick_panel)
	# 【2026-09-23 新增】阵亡演出：死亡瞬间（比 match_result / 替补早 0.3s）播"破碎升天 → 飞向阵亡标志"
	battle.unit_dying.connect(_on_unit_dying)
	# 【2026-09-28·用户要求】击杀演出：**开打前的预告**（`Battle.kill_intro_requested`）——
	#   预判这一击致死时先播卡面，播完回调 `battle.kill_intro_finished()`，Battle 才继续结算
	#   ⇒ 观感是"击杀特效滑完（图案彻底消失）→ 英雄再动手击杀对方"。
	battle.kill_intro_requested.connect(_on_kill_intro)
	battle.team_updated.connect(_refresh_team_panel)
	battle.deploy_refresh.connect(_show_deploy_panel)
	battle.card_view_requested.connect(show_unit_card)
	battle.item_view_requested.connect(show_item_info)
	battle.touch_view_end_requested.connect(_close_unit_card)
	battle.turn_banner.connect(_show_turn_banner)
	# 【2026-09-29】联机结算：「再来一局」的双方意向变化 / 对端回大厅 ⇒ 刷新按钮或跟着回大厅
	battle.rematch_state_changed.connect(_refresh_rematch_ui)
	battle.peer_left_to_lobby.connect(_on_peer_left_to_lobby)
	battle.peer_message.connect(_show_peer_chat)
	# 用对象方法而非 lambda 连接 autoload 信号：场景释放时 Godot 自动断开连接，
	# 避免"全局信号在对象释放后仍回调其 lambda（Lambda capture freed）"。
	GameState.round_changed.connect(_on_round_changed)
	GameState.active_side_changed.connect(_on_round_changed)

# 右键查看生成物作用
func show_item_info(type: String, owner_faction: int = -1) -> void:
	_close_unit_card()   # 统一：若已有信息浮层先关闭（复用同一 overlay 槽，避免叠加/自捕获）
	var vsize := get_viewport().get_visible_rect().size
	var overlay := Control.new()
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	overlay.gui_input.connect(_on_unit_card_overlay_input)
	add_child(overlay)
	_unit_card_overlay = overlay
	if battle != null and is_instance_valid(battle):
		battle.set_unit_card_open(true)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.18)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.add_child(dim)
	var panel := PanelContainer.new()
	# 面板外观走主题里的"弹出框边框"（theme/panel_frame_dark.png），不再单独覆盖样式
	overlay.add_child(panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	panel.add_child(v)
	var title := Label.new()
	title.text = "增益道具"
	title.add_theme_font_size_override("font_size", 20)
	title.add_theme_color_override("font_color", Color(1, 0.9, 0.4))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(title)
	var desc := Label.new()
	# 【2026-09-21 用户定稿·圣诞老人】道具提示要**说明归属**：带归属的道具只有放置方能拾取，
	#   对方踩上去会直接消失（板面上也按归属描边：我方绿 / 敌方红）。
	var own_txt := "（中立道具：双方都能拾取）"
	if owner_faction == DataRegistry.Faction.PLAYER:
		own_txt = "（我方道具：只有我方能拾取，敌方踩到会消失）"
	elif owner_faction == DataRegistry.Faction.ENEMY:
		own_txt = "（敌方道具：只有敌方才能拾取，我方踩到会消失）"
	desc.text = battle.item_desc(type) + "\n" + own_txt
	# 标题也带上归属，一眼看清是谁的（配色与板面右下角圆点一致：我方蓝 / 敌方红）
	if owner_faction == DataRegistry.Faction.PLAYER:
		title.text = "增益道具 · 我方"
		title.add_theme_color_override("font_color", Color(0.45, 0.7, 1.0))
	elif owner_faction == DataRegistry.Faction.ENEMY:
		title.text = "增益道具 · 敌方"
		title.add_theme_color_override("font_color", Color(1.0, 0.45, 0.4))
	desc.add_theme_font_size_override("font_size", 16)
	desc.add_theme_color_override("font_color", Color(0.9, 0.93, 1.0))
	desc.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.custom_minimum_size = Vector2(200, 0)
	v.add_child(desc)
	var close := Button.new()
	close.text = "关闭"
	close.custom_minimum_size = Vector2(0, 38)
	close.pressed.connect(_close_unit_card)
	v.add_child(close)
	panel.custom_minimum_size = Vector2(220, 0)
	var anchor := get_viewport().get_mouse_position()
	panel.position = anchor
	panel.size = Vector2(220, 0)
	_position_unit_card(overlay, panel, vsize)

# 右键查看卡面：弹出该单位完整信息（出现在点击英雄附近，点面板外关闭）。
# 与其它属性浮层同格式：显示区分区 + 贴左短线 + 四周留白。
func show_unit_card(u: Unit) -> void:
	# 若目标单位已失效（正在消失/被释放），直接忽略，避免访问已释放对象导致崩溃
	if u == null or not is_instance_valid(u):
		return
	# 若已有打开的英雄卡：先关闭旧的（成员持有，避免重复叠加/泄漏）
	_close_unit_card()
	var vsize := get_viewport().get_visible_rect().size
	var overlay := Control.new()
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	# 点击面板外任意处即关闭（走成员方法，不捕获被释放节点）
	overlay.gui_input.connect(_on_unit_card_overlay_input)
	add_child(overlay)
	_unit_card_overlay = overlay
	if battle != null and is_instance_valid(battle):
		battle.set_unit_card_open(true)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.18)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE   # 点击穿透给 overlay 处理关闭
	overlay.add_child(dim)
	var panel := PanelContainer.new()
	# 面板外观走主题里的"弹出框边框"（theme/panel_frame_dark.png）
	overlay.add_child(panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 5)
	panel.add_child(v)
	# 显示区①：名字 + 阵营（按本端视角标注：联机客户端操作红方，红方是"我方"）
	var is_my := false
	if battle != null and is_instance_valid(battle):
		is_my = u.faction == battle._my_faction()
	var title := Label.new()
	title.text = "%s  ·  %s" % [u.display_name, "我方" if is_my else "敌方"]
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", Color(1, 0.85, 0.5))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART   # 名字较长时换行，避免显示不全
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_child(title)
	# 显示区②：实战属性（HP 现值/上限 + 有效数值 + 状态）
	v.add_child(_make_zone_sep())
	# 数值带增益时用黄色（与棋子上那两个数字同一口径，见 Unit.atk_is_buffed / Unit.hp_is_buffed）：
	# 用 RichTextLabel + BBCode 才能只给"攻击 4"/"HP 27/24"上色，其余文字保持原色。
	var stats := RichTextLabel.new()
	stats.bbcode_enabled = true
	stats.fit_content = true          # 高度随内容（面板无容器重排，避免留白）
	stats.scroll_active = false
	stats.custom_minimum_size = Vector2(270, 0)   # 限制换行宽度，避免撑满全屏
	stats.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	stats.add_theme_font_size_override("normal_font_size", 17)
	stats.add_theme_color_override("default_color", Color(0.9, 0.93, 1.0))
	# 与全局 Label 一致的黑描边（主题对 Label 设了 outline，RichTextLabel 要自己补）
	stats.add_theme_constant_override("outline_size", 3)
	stats.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.72))
	# 大骑士移动=直线冲锋任意距离、坠炮手射程=全场：按 ∞ 展示（由英雄脚本声明是否生效，
	# 被沉默失效时自动退回普通数值），不显示误导性的数值
	var move_txt := "%d" % u.effective_move()
	if battle != null and is_instance_valid(battle) and battle._hero(u).shows_infinite_move():
		move_txt = "∞"
	# 卡面射程取"有效射程"：被[沉默]/[眩晕]时被动失效的英雄（血锁的射程+2）要显示退化值。
	# 与 Battle 取用 suppressed_attack_range() 的口径完全一致（Battle.gd:2435-2443 / 2463-2471：
	# -1 = 用原始 attack_range，>=0 = 用该返回值），避免卡面与实际不符（用户实机反馈）。
	var shown_range: int = u.attack_range
	if battle != null and is_instance_valid(battle):
		var sup := battle._hero(u).suppressed_attack_range()
		if sup >= 0:
			shown_range = sup
	var range_txt: String = "%d" % shown_range
	if battle != null and is_instance_valid(battle) and battle._hero(u).shows_infinite_range():
		range_txt = "∞"   # 坠炮手"全场射程"特例仍然优先（不受上面退化值影响）
	# 带增益的数值用黄色（棋子上的同款口径）：HP 溢出上限 / 攻击力带 buff
	var hp_txt := "HP %d/%d" % [u.hp, u.max_hp]
	if u.hp_is_buffed():
		hp_txt = "[color=#ffe640]%s[/color]" % hp_txt
	var atk_txt := "攻击 %d" % u.effective_atk()
	if u.atk_is_buffed():
		atk_txt = "[color=#ffe640]%s[/color]" % atk_txt
	stats.text = "[center]%s   %s   移动 %s   射程 %s[/center]" % [hp_txt, atk_txt, move_txt, range_txt]
	v.add_child(stats)
	var def := DataRegistry.get_hero(u.hero_id)
	if def != null:
		# 显示区③：技能描述（清洗后，不含识别标签残留）
		var desc := DataRegistry.clean_skill_desc(def.desc)
		if desc != "":
			v.add_child(_make_zone_sep())
			var skill := Label.new()
			skill.text = "技能\n%s" % desc
			skill.add_theme_font_size_override("font_size", 16)
			skill.add_theme_color_override("font_color", Color(0.7, 0.95, 1.0))
			skill.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			skill.custom_minimum_size = Vector2(270, 0)
			skill.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			v.add_child(skill)
		# 显示区④：词条解释
		var kw := _keyword_lines(u)
		if kw.size() > 0:
			v.add_child(_make_zone_sep())
			var kw_label := Label.new()
			kw_label.text = "\n".join(kw)
			kw_label.add_theme_font_size_override("font_size", 16)
			kw_label.add_theme_color_override("font_color", Color(0.95, 0.85, 0.6))
			kw_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			kw_label.custom_minimum_size = Vector2(270, 0)
			kw_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			v.add_child(kw_label)
		# 显示区⑤：当前已挂状态的具体解释（名字只是状态行里的提示，这里补完整说明）
		var st_ex := _status_explain_lines(u)
		if st_ex.size() > 0:
			v.add_child(_make_zone_sep())
			var stl := Label.new()
			stl.text = "当前状态\n" + "\n".join(st_ex)
			stl.add_theme_font_size_override("font_size", 16)
			stl.add_theme_color_override("font_color", Color(1.0, 0.8, 0.7))
			stl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			stl.custom_minimum_size = Vector2(270, 0)
			stl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			v.add_child(stl)
	var close := Button.new()
	close.text = "关闭"
	close.custom_minimum_size = Vector2(0, 40)
	close.pressed.connect(_close_unit_card)
	v.add_child(close)
	panel.custom_minimum_size = Vector2(300, 0)
	panel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	# 先放好，下一帧用成员面板引用做屏内收敛（避免 tween/lambda 捕获被释放节点）
	panel.position = get_viewport().get_mouse_position()
	panel.size = Vector2(300, 0)
	_position_unit_card(overlay, panel, vsize)

func _close_unit_card() -> void:
	if _unit_card_overlay != null and is_instance_valid(_unit_card_overlay):
		_unit_card_overlay.queue_free()
		_unit_card_overlay = null
	if battle != null and is_instance_valid(battle):
		battle.set_unit_card_open(false)

# 回合切换横幅：屏幕中央弹出大字号提示（"你的回合"/"敌方回合"），放大浮现、短暂停留后淡出。
# 仅视觉层，不拦截任何输入（鼠标/触摸照常操作棋盘）。
## `color` / `hold` 都有默认值（对局那条信号路径一个字不改）：回放会传阵营色与更长的停留，
## 让"这一回合轮到哪一方"更显眼（用户 2026-09-27 要求）。
func _show_turn_banner(text: String, color: Variant = null, hold: float = 0.9) -> void:
	if _turn_banner_tween != null and _turn_banner_tween.is_valid():
		_turn_banner_tween.kill()
	if _turn_banner != null and is_instance_valid(_turn_banner):
		_turn_banner.queue_free()
	var vs := get_viewport().get_visible_rect().size
	var label := Label.new()
	label.name = "TurnBanner"
	label.text = text
	label.add_theme_font_size_override("font_size", 84)
	label.add_theme_color_override("font_color", (color as Color) if color != null else Color(1.0, 0.9, 0.45))
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	label.add_theme_constant_override("outline_size", 10)
	# 【2026-09-28·用户报「竞技场弹出的先手提示被 2 选 1 面板挡住了，往上移」】
	#   那一版把横幅改成"顶部通栏、距顶 22%"（所有横幅一起上移）。
	# 【2026-09-29·用户要求「回合切换提醒放到画面中间，加大」】改回**整屏铺满 + 文字竖直居中**
	#   ⇒ 文字正落在屏幕正中；字号 54 → **84**、描边 8 → **10**。
	#   ⚠️ 代价：中央那几块面板（竞技场 2 选 1 / 卡组三选一 / 部署卡片行）会与横幅叠着显示 ——
	#   当初上移 22% 就是为了躲它们。要单独豁免某一条（比如竞技场那句"本局谁先手"）或整体回到
	#   "上方 22%"，改这一处即可（把下面 4 行换成 TOP_WIDE + offset_top = vs.y * 0.22）。
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.set_anchors_preset(Control.PRESET_FULL_RECT)
	label.offset_top = 0.0
	label.offset_bottom = 0.0
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE   # 不拦截点击
	add_child(label)
	_turn_banner = label

	var t := create_tween()
	_turn_banner_tween = t
	label.modulate.a = 0.0
	label.scale = Vector2(1.4, 1.4)
	label.pivot_offset = Vector2(vs.x / 2.0, vs.y / 2.0)   # 缩放中心 = 屏幕中心（文字就在那儿）
	# 放大+淡入 → 停留 → 淡出并移除
	t.tween_property(label, "scale", Vector2.ONE, 0.16).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	t.parallel().tween_property(label, "modulate:a", 1.0, 0.16)
	t.tween_interval(hold)
	t.tween_property(label, "modulate:a", 0.0, 0.35)
	# 【2026-09-29·用户报 `Lambda capture at index 0 was freed`】捕获节点改走 **WeakRef**：
	#   引擎在**进入 lambda 体之前**就打印这条错（捕获已被换成 null）⇒ 体里写 `is_instance_valid()`
	#   拦不住。这里 `label` 可能先被别处 free（换横幅 / 清横幅 / 场景切换）而补间还活着。
	var w_label: WeakRef = weakref(label)
	t.tween_callback(func():
		var l: Object = w_label.get_ref()
		if l != null:
			(l as Node).queue_free()
		if _turn_banner != null and not is_instance_valid(_turn_banner):
			_turn_banner = null)

# 点面板外任意处关闭浮层。返回 true 表示本次事件已消费（阻止漏给 Battle 触发重复查看/行动）
func _on_unit_card_overlay_input(ev: InputEvent) -> bool:
	var close_now := false
	if ev is InputEventMouseButton:
		var mb := ev as InputEventMouseButton
		# 鼠标/触摸统一：按下或（触屏）抬起都关闭
		close_now = mb.pressed or DisplayServer.is_touchscreen_available()
	elif ev is InputEventScreenTouch:
		close_now = true   # 触摸事件（未模拟成鼠标时）同样关闭
	if close_now:
		var card_ctl := _unit_card_overlay
		_close_unit_card()
		if card_ctl != null and is_instance_valid(card_ctl):
			card_ctl.accept_event()   # 关键：消费事件，阻止其继续漏给 Battle 的触摸手势
		# 【2026-09-27 修·用户报「录像里右键英雄会弹出两次属性框」】`accept_event()` 只作用于 Control 树，
		#   管不住 `Battle._unhandled_input` —— 右键关掉浮层后那个事件还会漏到 Battle，被当成"右键查看"
		#   又开一张 ⇒ 看着就是弹两次。这里在**视口层**标成已处理，彻底止住。
		get_viewport().set_input_as_handled()
		return true
	return false

# 等 PanelContainer 完成布局后按内容尺寸定位并收敛到屏内（overlay/panel 由成员引用，安全判空）
func _position_unit_card(overlay: Control, panel: PanelContainer, vsize: Vector2) -> void:
	var wait := get_tree().create_timer(0.05, false)
	await wait.timeout
	if overlay == null or panel == null or not is_instance_valid(overlay) or not is_instance_valid(panel):
		return   # 卡片已被关闭：安全退出
	var anchor := get_viewport().get_mouse_position()
	var msz := panel.get_combined_minimum_size()
	panel.size = Vector2(maxf(msz.x, 300.0), msz.y)
	var pw := panel.size.x
	var ph := panel.size.y
	var px := anchor.x + 24
	var py := anchor.y + 16
	if px + pw > vsize.x - 8:
		px = anchor.x - pw - 24
	if py + ph > vsize.y - 8:
		py = anchor.y - ph - 16
	px = clampf(px, 8, maxf(8, vsize.x - pw - 8))
	py = clampf(py, 8, maxf(8, vsize.y - ph - 8))
	panel.position = Vector2(px, py)

func _keyword_lines(u: Unit) -> Array:
	var lines: Array = DataRegistry.keyword_lines(u.skills, u.attack_type)
	# 技能正文里 [方括号] 状态词（沉默/重伤/猛毒…）也补上解释
	var def := DataRegistry.get_hero(u.hero_id)
	if def != null:
		lines.append_array(DataRegistry.desc_status_lines(def.desc))
	return lines

# 状态行文本：名称与顺序都来自 StatusDB（以前这里又抄了一份"键→中文名"的表）
func _status_text(u: Unit) -> String:
	var s := ""
	for key in StatusDB.keys():
		if u.has_status(key):
			s += StatusDB.label(key) + " "
	return s if s != "" else "无"

# 当前每个状态的解释(属性框用)：名称取自 StatusDB，说明取自 DataRegistry.STATUS_DESC
func _status_explain_lines(u: Unit) -> Array:
	var out: Array = []
	for key in StatusDB.keys():
		if not u.has_status(key):
			continue
		var label := StatusDB.label(key)
		var desc: String = DataRegistry.STATUS_DESC.get(label, "")
		out.append("%s：%s" % [label, desc] if desc != "" else label)
	return out

# 开局部署面板（分步：点选英雄 -> 点击出生格放置）
var _deploy_overlay: Control = null
# 【2026-09-29·用户要求「部署阶段的倒计时放到上方状态栏」】原来这里还有 `_deploy_timer_label`
#   （面板上方的 64 号大字）—— 已删：部署读秒改由状态栏那枚计时器显示（`_update_deploy_pick_timer()`）。
func _show_deploy_panel() -> void:
	if _in_replay():
		_close_deploy_panel()   # 【录像回放】回放里永不显示"开局选人/部署"面板（含那行大字倒计时）
		return
	_refresh_round()   # 进入/退出部署阶段都刷新顶部标签（部署期显示"部署选人"）
	# 【2026-09-29·用户报「部署阶段，点击菜单后，队伍列表会弹出来」】暂停期间**不要重建这个面板**：
	#   重建 = `queue_free()` 旧的 + 末尾 `add_child` 新的 ⇒ 新面板会排在**暂停浮层之后**（画在它上面），
	#   于是"点了菜单，卡池/队伍那一行又冒出来盖在暂停黑底上"。暂停时局面本来就不动，
	#   等恢复（或下一次正常刷新）再建即可 ⇒ 这里直接让路。
	if get_tree() != null and get_tree().paused:
		return
	# 非部署阶段则收起
	if battle.state != Battle.State.DEPLOY and battle.state != Battle.State.PLACE_DEPLOY:
		_close_deploy_panel()
		return
	# 【2026-09-28·用户要求】竞技场部署期例外：那一段要**默认开着**替补队伍面板
	#   （见 `_team_panel_forced`），所以这里不能无条件收掉它。
	# 【2026-09-30·本次改动】判据由**缓存标志** `_team_panel_forced` 改成**现算** `_should_force_team_panel()`：
	#   缓存那份只在每帧 `_sync_arena_team_panel()` 里对齐，而竞技场"选人→部署"的交接是**同一帧**内
	#   完成（Battle 那边 `state = State.DEPLOY` 落旗 → 接着 `deploy_refresh.emit()` 喊到这里）
	#   ⇒ 拿旧值会把队伍面板再留一帧、和行动卡池叠着闪一下。现算就当场收干净。
	if not _should_force_team_panel():
		_team_panel_forced = false   # 与现算结果对齐：否则下一帧 `_sync_arena_team_panel()` 认为"没变化"、不再收
		_close_team_panel()   # 部署期只用"开局选人"面板，与常驻"替补队伍"面板互斥，避免重叠
	if _deploy_overlay:
		_deploy_overlay.queue_free()
	_deploy_overlay = null
	var vsize := get_viewport().get_visible_rect().size
	# 棋盘下方队伍列表：透明背景、一行六边形卡（与替补面板一致），不弹窗不遮罩
	var overlay := Control.new()
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(overlay)
	_deploy_overlay = overlay
	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0)   # 透明
	sb.content_margin_left = 6.0
	sb.content_margin_right = 6.0
	sb.content_margin_top = 3.0
	sb.content_margin_bottom = 3.0
	panel.add_theme_stylebox_override("panel", sb)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.add_child(panel)
	var wrapbox := VBoxContainer.new()
	wrapbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	wrapbox.add_theme_constant_override("separation", 2)
	panel.add_child(wrapbox)
	# 【2026-09-27·用户要求】原来这里有一行标题「开局选人 · 点选英雄部署 · 我方 x/3 对方 x/3」⇒ **整行删掉**，
	#   面板直接就是卡池那一行（`side_txt` / 标题 Label / 计数都随之消失）。
	# 当前轮是否轮到本端部署选人
	var my_pick := _deploy_my_pick()
	# 卡池：始终为本端"我方"部署卡池；轮到本端才可点选
	var ids: Array = battle._my_deploy_pool()
	var sel := battle._pending_deploy
	if battle._my_faction() == DataRegistry.Faction.ENEMY:
		sel = battle._pending_enemy_deploy
	# 【2026-09-28·用户报「部署阶段选了一个英雄之后，英雄卡面会变黑」】原来这里传的是
	#   `not my_pick or placing` —— `placing`（= 已点英雄、正在放位 PLACE_DEPLOY）也把整排卡池
	#   设成 `disabled_draw`（底色压暗 45% + 人物图只有 45% 不透明 ⇒ 看着就是"卡面变黑"）。
	#   但放位阶段**本来就是可以再点别的英雄反悔/切换**的（`_on_deploy_click` → `_on_deploy_pick_again`）⇒
	#   灰掉是错的（看着不能点、其实能点）。现在只在"不是本端选人轮"时灰。
	# 【2026-09-28·用户报「两处六边形大小不一样」】半径与替补队伍**共用** `_team_row_radius()`（原写死 48）
	var deploy_r: float = _team_row_radius(ids.size())
	var pool := _make_hex_pool(ids, _on_deploy_hover, _on_deploy_click, not my_pick, sel, true, deploy_r)
	# 【2026-09-27·用户报「队伍有点压着棋盘 / 太下了挡住结束按钮」】卡池宿主高度要按**交错排布**算：
	#   单行时奇数列的卡往下错半行 ⇒ 最低那张卡底边 = `r + √3·r`（r=48 ⇒ 131px），
	#   而 `_make_hex_pool` 给的是 2×行距（166px，多留的空白会把整排卡往上顶）；
	#   我第一次收紧到 1.15×行距（96px）又**太短** ⇒ 奇数列的卡溢出面板盒、正好压到结束回合按钮上。
	#   ⇒ 按实际用量收：`r + √3·r` 再留 6px 余量（卡片绝对定位、宿主不裁剪 ⇒ 只影响面板盒）。
	pool.custom_minimum_size.y = deploy_r * (1.0 + sqrt(3.0)) + 6.0   # 跟着半径走（原来写死 48）
	pool.size.y = pool.custom_minimum_size.y
	wrapbox.add_child(pool)
	var pw: float = pool.custom_minimum_size.x + 20.0
	var ph: float = pool.custom_minimum_size.y + 10.0
	panel.custom_minimum_size = Vector2(pw, ph)
	panel.size = Vector2(pw, ph)
	# 【2026-09-27】棋盘放大后（`Battle._fit_hex_size()` 不再为屏底留 330）卡片行**贴屏幕底边**摆：
	#   摆到"按钮行上方"就会压住棋盘最下面两行（玩家正是要点那些绿格放人）。部署期「结束回合」已隐藏
	#   （见 `_refresh_controls()`）⇒ 这条带子归卡片行用。
	panel.position = Vector2((vsize.x - pw) / 2.0, vsize.y - ph - 34.0)   # 【2026-09-28·用户要求「替补队伍往上移」】由贴屏底 6px 抬到 34px
	# 【2026-09-29·用户要求「部署阶段的倒计时放到上方状态栏」】棋盘中央那枚 64 号大字**撤掉** ——
	#   改由上方状态栏那枚计时器显示（与卡组三选一同一套做法：接管 `_turn_timer_label`，
	#   见 `_update_deploy_pick_timer()`）。原来这里建的 `_deploy_timer_label` 与 `_board_center_px()`
	#   一起删掉（后者只服务于它）。

# 本端当前轮是否轮到本端部署选人（主机=玩家轮，客户端=敌轮；单机=仅玩家轮）
func _deploy_my_pick() -> bool:
	if not GameState.is_online:
		return battle._deploy_side == 0   # 单机：仅玩家轮本端点，敌轮 AI 自动
	return battle._deploy_side == battle._my_side()

func _on_deploy_hover(hid: String) -> void:
	if hid == "":
		_set_score_tooltip_visible(false)
		return
	_set_score_tooltip_hero(hid)

# 统一的六边形卡池（开局选人/替补共用，保证样式一致）
func _make_hex_pool(ids: Array, on_hover: Callable, on_click: Callable, disabled: bool = false, selected_id: String = "", single_row: bool = false, card_radius: float = 38.0) -> Control:
	var host := Control.new()
	host.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	host.mouse_filter = Control.MOUSE_FILTER_IGNORE   # 宿主不拦截鼠标，卡牌各自响应
	var r := card_radius
	var col_step := 1.5 * r           # 平顶：列中心横向间距
	var row_step := sqrt(3.0) * r     # 平顶：行中心纵向间距
	var cols := ids.size() if single_row else 4
	var rows := 1 if single_row else int(ceil(float(ids.size()) / float(cols)))
	if rows < 1:
		rows = 1
	var total_w := 2.0 * r + float(cols - 1) * col_step
	var total_h := row_step * float(rows) + row_step
	host.custom_minimum_size = Vector2(total_w, total_h)
	host.size = Vector2(total_w, total_h)
	for i in ids.size():
		var hid: String = ids[i]
		var def := DataRegistry.get_hero(hid)
		var col := i
		var row := 0
		if not single_row:
			col = int(i / float(rows))
			row = i % rows
		var cx := r + float(col) * col_step
		var cy := r + float(row) * row_step + (row_step / 2.0 if col % 2 == 1 else 0.0)
		var card := HexCard.new(def, hid, r)
		card.position = Vector2(cx - r, cy - row_step / 2.0)
		card.disabled_draw = disabled
		card.selected = (hid == selected_id)
		card.hovered.connect(on_hover)
		card.clicked.connect(on_click)
		host.add_child(card)
	return host

func _on_deploy_click(hid: String) -> void:
	if not _deploy_my_pick():
		return   # 非本端点选轮（联机等待对端/单机敌轮AI）不响应
	if battle._my_faction() == DataRegistry.Faction.PLAYER:
		if battle.state == Battle.State.DEPLOY:
			battle._on_deploy_pick(hid)
		elif battle.state == Battle.State.PLACE_DEPLOY:
			# 放位阶段：再次点英雄可反悔/切换
			battle._on_deploy_pick_again(hid)
	else:
		if battle.state == Battle.State.DEPLOY:
			battle._on_enemy_deploy_pick(hid)
		elif battle.state == Battle.State.PLACE_DEPLOY:
			battle._on_enemy_deploy_pick_again(hid)
	_show_deploy_panel()

var _score_tooltip_wrap: PanelContainer = null   # 属性浮层面板（带背景，显示/隐藏及定位用）
var _score_tooltip_box: VBoxContainer = null     # 浮层内容（各显示区 + 短线）
var _tooltip_pin_rect := Rect2()                 # 非空=浮层固定到该矩形上方（触屏查看，避免手指遮挡）；空=跟随鼠标

# 竞技场选人触屏手势（安卓/iOS）：短按确认；长按查看；按住滑动切换查看卡；松手不确认。
var _arena_confirm_cb: Callable = Callable()   # 本轮竞技场选人确认回调（短按触发，触屏用手势层复用它）
var _arena_card_centers := {}    # hid -> 卡中心（层/宿主坐标系，命中判定用）
var _arena_touch_active := false
var _arena_touch_down_ms := 0
var _arena_touch_down_pos := Vector2.ZERO   # 按下起点（滑动判定）
var _arena_touch_id := ""          # 当前手指所在/查看的英雄
var _arena_touch_held := false     # 已判定长按查看（松手不确认）
var _arena_touch_moved := false    # 已滑动（抬起不确认）
var _arena_gesture_layer: Control = null   # 触屏手势拦截层（竞技场两张卡上）

# 贴左短分行线（属性弹框各显示区之间的分隔短线）
func _make_zone_sep() -> HSeparator:
	var sep := HSeparator.new()
	sep.custom_minimum_size = Vector2(260, 6)
	sep.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	var lnsb := StyleBoxLine.new()
	lnsb.color = Color(1.0, 0.85, 0.5, 0.3)
	lnsb.thickness = 1
	sep.add_theme_stylebox_override("separator", lnsb)
	return sep

# 显示区文字标签（各弹框共用：自动换行、限宽）
func _make_zone_label(text: String, font_size: int, color: Color, min_w: float) -> Label:
	var lb := Label.new()
	lb.text = text
	lb.add_theme_font_size_override("font_size", font_size)
	lb.add_theme_color_override("font_color", color)
	lb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lb.custom_minimum_size = Vector2(min_w, 0)
	lb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return lb

# 悬停详情浮层（挂在 HUD 自身，不遮罩棋盘）：与主菜单属性表同格式——
# 显示区分区 + 贴左短线分行 + 四周留白。单例复用（避免每次重建压到被面板盖住、且泄漏）。
func _ensure_score_tooltip() -> PanelContainer:
	if _score_tooltip_wrap != null and is_instance_valid(_score_tooltip_wrap):
		return _score_tooltip_wrap
	var wrap_box := PanelContainer.new()
	wrap_box.visible = false
	wrap_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 面板外观走主题里的"弹出框边框"（theme/panel_frame_dark.png）：不再覆盖样式
	wrap_box.z_index = 100   # 置于最顶，避免被下方队伍面板盖住
	add_child(wrap_box)
	_score_tooltip_wrap = wrap_box
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	wrap_box.add_child(box)
	_score_tooltip_box = box
	return wrap_box

# 按显示区重建悬停浮层内容（先清空旧区再重建，避免残留上一英雄的尺寸）
func _set_score_tooltip_zones(zones: Array) -> void:
	var wrap_box := _ensure_score_tooltip()
	for c in _score_tooltip_box.get_children():
		_score_tooltip_box.remove_child(c)
		c.queue_free()
	for i in zones.size():
		if i > 0:
			_score_tooltip_box.add_child(_make_zone_sep())
		var lb := _make_zone_label(zones[i], 20, Color(0.9, 0.93, 1.0), 380.0)
		lb.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_score_tooltip_box.add_child(lb)
	wrap_box.reset_size()   # 无容器重排：显式收敛到新内容的最小尺寸
	wrap_box.visible = true

# 悬停某英雄：按 DataRegistry 统一区格式显示其属性
func _set_score_tooltip_hero(hid: String) -> void:
	var def := DataRegistry.get_hero(hid)
	if def == null:
		return
	_set_score_tooltip_zones(DataRegistry.hero_info_zones(def))

# 属性浮层统一显隐（作用于带背景的 wrap 本身；仅设内层 Label.visible 会让 wrap 仍隐藏、位置也不收敛）
func _set_score_tooltip_visible(v: bool) -> void:
	if _score_tooltip_wrap and is_instance_valid(_score_tooltip_wrap):
		_score_tooltip_wrap.visible = v

# 替补落位成功：刷新队伍面板回只读态（连续替补会再次走 sub_select_requested 变回可选态）
func _on_sub_placed() -> void:
	_refresh_team_panel()

# 关闭开局部署面板（若有残留，防止旧面板盖在新流程上）
func _close_deploy_panel() -> void:
	if _deploy_overlay:
		_deploy_overlay.queue_free()
		_deploy_overlay = null

# 竞技场选人：面板中央展示本轮随机的 2 名英雄（2选1），点击即选择
func _show_arena_pair(pair: Array) -> void:
	_refresh_round()   # 进入竞技场选人：顶部标签显示"竞技场选人"
	_close_arena_panel()
	_close_deploy_panel()   # 进入选人：收掉可能残留的上一局部署面板
	var vsize := get_viewport().get_visible_rect().size
	# 大号六边形卡，画面正中、两卡同高且给下方留"飞入队伍"空间；透明背景只显示卡牌
	var card_r := 92.0
	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0)
	sb.content_margin_left = 12.0
	sb.content_margin_right = 12.0
	sb.content_margin_top = 12.0
	sb.content_margin_bottom = 12.0
	panel.add_theme_stylebox_override("panel", sb)
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(panel)
	_arena_panel = panel
	var wrapbox := VBoxContainer.new()
	wrapbox.add_theme_constant_override("separation", 10)
	panel.add_child(wrapbox)
	if pair.size() < 2:
		# 对方选择中 / 联机等待对方完成：显示等待提示（不可点击）
		var wait := Label.new()
		wait.text = "等待对方完成选卡……" if GameState.is_online else "敌方正在选择英雄……"
		wait.add_theme_font_size_override("font_size", 24)
		wait.add_theme_color_override("font_color", Color(1.0, 0.6, 0.55))
		wait.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		wrapbox.add_child(wait)
		panel.custom_minimum_size = Vector2(420, 120)
		panel.size = Vector2(420, 120)
		panel.position = Vector2((vsize.x - 420) / 2.0, (vsize.y - 120) / 2.0)
		return
	# 倒计时（选卡上方大字）：剩余秒数由 Battle 每帧递减，超时自动选第 1 张
	# 【2026-09-29·用户要求「竞技场二选一倒计时字号加大」】52 → **64**、描边 6 → **8**
	#   （与部署阶段那个大字倒计时**同一套字号/描边**，两处观感一致；配套把面板预留高度也加高，见下面 `ph`）。
	var timer := Label.new()
	timer.add_theme_font_size_override("font_size", 64)
	timer.add_theme_color_override("font_color", Color(1.0, 0.9, 0.4))
	timer.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	timer.add_theme_constant_override("outline_size", 8)
	timer.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	timer.text = ""
	wrapbox.add_child(timer)
	_arena_timer_label = timer
	# 手动摆放两张六边形卡：无文字、同高、居中、中间留 gap（不放 _make_hex_pool，避免错位/贴靠）
	var gap := 40.0
	var card_w := card_r * 2.0
	var card_h := sqrt(3.0) * card_r
	var total_w := card_w * 2 + gap
	var host := Control.new()
	host.mouse_filter = Control.MOUSE_FILTER_IGNORE
	host.custom_minimum_size = Vector2(total_w, card_h)
	host.size = Vector2(total_w, card_h)
	wrapbox.add_child(host)
	_arena_pair = pair.duplicate()   # 【2026-09-29】选中演出要用（原来闭包直接抓 pair，回放驱动时拿不到）
	var click_cb := func(hid: String): _arena_pick_anim(hid)
	for i in pair.size():
		var hid: String = pair[i]
		var def := DataRegistry.get_hero(hid)
		var card := HexCard.new(def, hid, card_r)
		# 同高（y=0），水平居中摆放，间距 gap
		card.position = Vector2(float(i) * (card_w + gap), 0)
		card.hovered.connect(func(hid2: String):
			if hid2 == "":
				_set_score_tooltip_visible(false)
				return
			if DataRegistry.get_hero(hid2) == null:
				return
			_set_score_tooltip_hero(hid2))
		card.clicked.connect(click_cb)
		host.add_child(card)
	# 触屏（安卓/iOS）：竞技场选人 = 短按确认、长按查看、按住滑动切换查看、松手不确认。
	# 桌面保留 HexCard 自身的 hover 查看 + 点击确认。
	if DisplayServer.is_touchscreen_available():
		_setup_arena_touch(pair, host, card_r, click_cb)
	var pw := total_w + 40.0
	# 【2026-09-29】顶部大字倒计时的预留高度 78 → **96**：字号 52 → 64 之后行高约 83px，
	#   原来的 78 会让大字贴到卡片上（面板高度是这里手算的，不靠容器的 min size 兜底）。
	var ph := card_h + 40.0 + 96.0   # 预留顶部大字倒计时空间
	panel.custom_minimum_size = Vector2(pw, ph)
	panel.size = Vector2(pw, ph)
	# 画面正中央（略偏上，给下方飞入路径留空间）
	panel.position = Vector2((vsize.x - pw) / 2.0, (vsize.y - ph) / 2.0 - 40)

## 竞技场 2 选 1 的"选中"演出（**点卡与回放重演共用同一段**）：被选的那张向下飞入我方队伍、
## 另一张（归敌方）向上飞出，0.45 秒演完才把结果交回 `Battle`（`_arena_pick_committed()`）。
## ⚠️ 【2026-09-28 用户报「竞技场 2 选 1 的音效和点击有间隔」】选人音必须挂在**最外层**（这里），
##   不能等飞卡动画演完才响。
func _arena_pick_anim(hid: String) -> void:
	if battle == null or not is_instance_valid(battle):
		return
	AudioManager.play("select_actor")
	# 点击即停表：选中动画期间不再倒计时，防止演出中触发自动选导致双选
	battle.arena_pick_time_left = -1.0
	var card := _find_arena_card(hid)
	var enemy_card: Control = null
	for phid in _arena_pair:
		if phid != hid:
			enemy_card = _find_arena_card(phid)
			break
	if card == null:
		battle._arena_pick_committed(hid)
		return
	var t := create_tween()
	# 【2026-09-29】留住这一趟（回放跳段时 `arena_replay_abort()` 要掐掉它 ⇒ 那记迟到回调不再落账）
	if _arena_fly_tween != null and _arena_fly_tween.is_valid():
		_arena_fly_tween.kill()
	_arena_fly_tween = t
	t.tween_property(card, "position", card.position + Vector2(0, 360), 0.45)
	t.parallel().tween_property(card, "modulate:a", 0.0, 0.45)
	if enemy_card != null:
		t.parallel().tween_property(enemy_card, "position", enemy_card.position + Vector2(0, -360), 0.45)
		t.parallel().tween_property(enemy_card, "modulate:a", 0.0, 0.45)
	t.tween_callback(func():
		if battle != null and is_instance_valid(battle):
			battle._arena_pick_committed(hid))

## 【2026-09-29 用户要求「竞技场模式录像需要将选牌流程加进去」】回放侧驱动**同一段**选中演出
##   （观众不用点，选哪张由录像说了算）。Battle 那边收尾走 `_arena_pick_committed()` 分流到重演那套。
func arena_replay_pick(hid: String) -> void:
	_arena_pick_anim(hid)

## 【2026-09-29 用户报「竞技场的录像，在 2 选 1 界面的时候，点击下回合。会错乱」】回放跳段 =
##   选牌演出整段收掉：**面板关掉**（否则它会一直盖在跳过去的战斗画面上）+ **还在飞的卡掐掉**
##   （那个 tween 0.45 秒后才会回调 `battle._arena_pick_committed()` ⇒ 不掐就是一记迟到的一手）。
##   `Battle._replay_draft_abort()` 调这里；实战那条路永远不调（面板归 `arena_draft_done`/点选收）。
func arena_replay_abort() -> void:
	if _arena_fly_tween != null and _arena_fly_tween.is_valid():
		_arena_fly_tween.kill()
	_arena_fly_tween = null
	_close_arena_panel()

# 竞技场触屏（安卓/iOS）：短按=确认选择；按住超时=查看属性；按住滑动=切换查看另一卡；
# 长按/滑动后松手均不确认（属性浮层固定显示在卡上方，不跟随手指）。
# 桌面不用本层：HexCard 自身 hover 查看 + 点击确认。
func _setup_arena_touch(pair: Array, host: Control, card_r: float, confirm: Callable) -> void:
	var gesture := Control.new()
	gesture.name = "ArenaTouchLayer"
	gesture.mouse_filter = Control.MOUSE_FILTER_STOP
	gesture.custom_minimum_size = host.size
	gesture.size = host.size
	gesture.gui_input.connect(_on_arena_touch_gui)
	host.add_child(gesture)   # 后加 → 位于两卡之上，拦截全部点击
	_arena_gesture_layer = gesture
	_arena_confirm_cb = confirm
	# 记录两张卡在层坐标系中的中心（层与 host 同位），供命中判定
	_arena_card_centers.clear()
	for i in pair.size():
		var hid: String = pair[i]
		var cx := float(i) * (card_r * 2.0 + 40.0) + card_r
		var cy := sqrt(3.0) * card_r / 2.0
		_arena_card_centers[hid] = Vector2(cx, cy)
	# 触屏下卡片自身不响应（hover/click 由拦截层接管）
	for c in host.find_children("*", "HexCard", true, false):
		c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_arena_touch_active = false
	_arena_touch_held = false
	_arena_touch_moved = false
	_arena_touch_id = ""

func _on_arena_touch_gui(ev: InputEvent) -> void:
	if ev is InputEventMouseMotion or ev is InputEventScreenDrag:
		# 手指/鼠标按住移动：若已进入查看则跟随切换；否则超阈值视为滑动（不再确认）
		if not _arena_touch_active:
			return
		var pos := (ev as InputEventMouseMotion).position if ev is InputEventMouseMotion else (ev as InputEventScreenDrag).position
		if _arena_touch_down_pos.distance_to(pos) > 20.0:
			_arena_touch_moved = true
		if _arena_touch_held:
			var hid := _arena_hit_card(pos)
			if hid != "" and hid != _arena_touch_id:
				_arena_touch_id = hid
				_show_arena_view(hid)
		return
	var mb := ev as InputEventMouseButton
	var st := ev as InputEventScreenTouch
	if mb != null and mb.button_index != MOUSE_BUTTON_LEFT:
		return
	if (ev is InputEventMouseButton and mb.pressed) or (st != null and st.pressed):
		# 按下：记录起点与时间。倒计时不暂停——长按查看期间正常走秒，不消失也不重置
		_arena_touch_down_ms = Time.get_ticks_msec()
		_arena_touch_down_pos = mb.position if mb != null else st.position
		_arena_touch_active = true
		_arena_touch_moved = false
		_arena_touch_held = false
		_arena_touch_id = _arena_hit_card(_arena_touch_down_pos)
		return
	# 抬起：松开位置落在某张卡上 -> 选择该英雄（含长按查看后手指仍停在卡上松开）
	# 否则（滑到空白处松开 / 未落在卡上）只收起浮层，不选择
	if not _arena_touch_active:
		return
	_arena_touch_active = false
	var up_pos := mb.position if mb != null else (st.position if st != null else _arena_touch_down_pos)
	var up_hid := _arena_hit_card(up_pos)
	_hide_arena_view()
	if up_hid != "" and _arena_confirm_cb.is_valid():
		_arena_confirm_cb.call(up_hid)

# 按住不动超时 → 长按查看（仅竞技场选人且存在手势层时）
func _update_arena_touch_hold() -> void:
	if _arena_gesture_layer == null or not is_instance_valid(_arena_gesture_layer):
		return
	if not _arena_touch_active or _arena_touch_held:
		return
	if Time.get_ticks_msec() - _arena_touch_down_ms < 250:
		return
	_arena_touch_held = true
	if _arena_touch_id != "":
		_show_arena_view(_arena_touch_id)

# 命中判定：点落在某张卡的外接圆内即视为该卡
func _arena_hit_card(pos: Vector2) -> String:
	for hid in _arena_card_centers.keys():
		if _arena_card_centers[hid].distance_to(pos) <= 88.0:
			return hid
	return ""

# 触屏查看某张卡：属性浮层固定显示在该卡上方（不跟随手指）
func _show_arena_view(hid: String) -> void:
	var def := DataRegistry.get_hero(hid)
	if def == null:
		return
	_set_score_tooltip_hero(hid)
	var card := _find_arena_card(hid)
	if card != null and is_instance_valid(card):
		_tooltip_pin_rect = card.get_global_rect()
	_set_score_tooltip_visible(true)

func _hide_arena_view() -> void:
	_tooltip_pin_rect = Rect2()
	_set_score_tooltip_visible(false)

# 在竞技场面板里按 hero_id 找对应 HexCard
func _find_arena_card(hid: String) -> Control:
	if _arena_panel == null:
		return null
	for c in _arena_panel.find_children("*", "HexCard", true, false):
		if c.hero_id == hid:
			return c
	return null

# 关闭竞技场选人面板
func _close_arena_panel() -> void:
	if _arena_panel:
		_arena_panel.queue_free()
		_arena_panel = null
	_arena_timer_label = null
	_arena_gesture_layer = null
	_arena_confirm_cb = Callable()
	_arena_card_centers.clear()
	_arena_touch_active = false
	_arena_touch_held = false
	_arena_touch_moved = false
	_arena_touch_id = ""
	_hide_arena_view()

# ---- 普通模式：进入战斗后弹"选择卡组"面板 ----
# 样式与普通模式编辑页一致：卡组1/2/3 切换钮（点哪个显示哪个队伍）+ 右侧"随机英雄"。
# 只展示已保存的卡组（场内不可编辑英雄），卡牌可悬停查看属性；不足 5 名时点出战弹提示。
func _show_deck_pick_panel(decks: Array) -> void:
	_refresh_round()   # 顶部标签显示"选择卡组"
	_close_deck_pick_panel()
	_close_arena_panel()
	_close_deploy_panel()
	_close_team_panel()
	_deck_pick_decks = decks
	_deck_pick_slot = 1
	# 全屏遮罩拦截棋盘输入（面板打开期间不允许操作棋盘）
	# 【2026-09-23 修·用户报"弹这个框时没法重开或者退出"】遮罩插进 `_ui_root` 的**第 0 个子节点**
	#   （常驻 UI 的最底层）—— 原来 `add_child` 到 HUD 这个 CanvasLayer 上，会连
	#   `结束回合/重开/返回选人/暂停` 一起盖住（看得见、点不到）。插进 root 之后：
	#   棋盘仍被拦住（HUD 层在棋盘之上），而常驻按钮在遮罩之上 ⇒ 照旧可点。
	var overlay := Control.new()
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	if _ui_root != null and is_instance_valid(_ui_root):
		_ui_root.add_child(overlay)
		_ui_root.move_child(overlay, 0)
	else:
		add_child(overlay)
	_deck_pick_overlay = overlay
	# 【2026-09-23 用户要求】弹窗背后加一层暗色遮罩（"背景淡化"）：与结算浮层同一套做法
	#   （全屏 ColorRect，**alpha 越接近 1 越黑**；0.45 = 棋盘看得清、只是压一层灰）。
	#   原来这里是纯透明 ⇒ 棋盘照旧亮着，弹窗像是"浮"在场上、读卡组信息时很跳；
	#   2026-09-28 用户口径「背景透明度」⇒ 由 0.7 调淡到 **0.45**（想更透/更暗只改这一个数）。
	#   ⚠️ 只负责变暗、不接输入（`MOUSE_FILTER_IGNORE`）：点棋盘仍由 overlay 拦，按钮照旧可点。
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.45)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.add_child(dim)
	var panel := PanelContainer.new()
	# 面板外观走主题里的"弹出框边框"（theme/panel_frame_dark.png）；
	# ⚠️ 原来这块面板是半透明"透出棋盘"的，换成牌子后变成不透明（弹窗更聚焦）。
	overlay.add_child(panel)
	_deck_pick_panel = panel
	# 【2026-09-28·用户口径「背景透明度」= 要透出棋盘的是**这块牌子本身**】⇒ 把主题那块边框**复制一份**、
	#   只压低它的 `modulate_color.a`（**主题与其它弹窗一律不动**）：牌子变透，而牌子里的字/卡/按钮
	#   仍是全不透明（它们不是样式的一部分，只受节点自身影响）。
	#   想更透/更实只改 `PLATE_ALPHA`：0.45 很透 / 0.65 现在 / 1.0 = 原样不透明。
	#   ⚠️ 必须在 `add_child` **之后**取样式：主题查找要沿节点树往上找（进树了才拿得到项目主题）。
	const PLATE_ALPHA := 0.65
	var base_sb := panel.get_theme_stylebox("panel")
	if base_sb is StyleBoxTexture:
		var plate: StyleBoxTexture = (base_sb as StyleBoxTexture).duplicate()
		plate.modulate_color = Color(1, 1, 1, PLATE_ALPHA)
		panel.add_theme_stylebox_override("panel", plate)
	var wrapbox := VBoxContainer.new()
	wrapbox.add_theme_constant_override("separation", 10)
	panel.add_child(wrapbox)
	var title := Label.new()
	title.text = "选择卡组出战"
	title.add_theme_font_size_override("font_size", 26)
	title.add_theme_color_override("font_color", Color(1.0, 0.85, 0.5))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	wrapbox.add_child(title)
	# 【2026-09-28·用户要求】原来这里有一行「先手：我方/敌方」（09-28 加的）⇒ **整行删掉**：
	#   用户口径「普通模式里卡组 3 选 1 界面的先手提示去掉」。
	# 【2026-09-29·用户要求】原来这里有一个 32 号大字读秒（"N 秒（超时随机选一个卡组）"）⇒
	#   **整个撤销**：时间提示改到**上方状态栏**正中（复用回合倒计时那个 Label，见
	#   `_update_deck_pick_timer()`），文案只留纯秒数。面板因此少一行、宽度也不再被那行大字撑开。
	# 卡组1/2/3 切换行（同编辑页 deck_bar 布局：tabs 占满整行，右侧放按钮）
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 8)
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	wrapbox.add_child(bar)
	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", 6)
	tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(tabs)
	for slot in [1, 2, 3]:
		var tab := Button.new()
		tab.text = "卡组 %d" % slot
		tab.toggle_mode = true
		tab.custom_minimum_size = Vector2(0, 34)
		tab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		tab.pressed.connect(_on_deck_pick_tab.bind(slot))
		tabs.add_child(tab)
		_deck_pick_tabs[slot] = tab
	# 卡组1/2/3 右边 = 随机英雄
	var rand_btn := Button.new()
	rand_btn.text = "随机英雄"
	rand_btn.add_theme_font_size_override("font_size", 15)
	rand_btn.custom_minimum_size = Vector2(130, 34)
	rand_btn.pressed.connect(_on_deck_pick_random_pressed)
	bar.add_child(rand_btn)
	# 当前卡组信息行
	_deck_pick_info = Label.new()
	_deck_pick_info.add_theme_font_size_override("font_size", 14)
	_deck_pick_info.add_theme_color_override("font_color", Color(0.8, 0.85, 0.95))
	_deck_pick_info.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	wrapbox.add_child(_deck_pick_info)
	# 当前卡组的队伍预览（点卡组1/2/3 切换显示；悬停卡牌看属性）
	var host := Control.new()
	host.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	wrapbox.add_child(host)
	_deck_pick_preview = host
	# 出战按钮
	_deck_pick_start_btn = Button.new()
	_deck_pick_start_btn.add_theme_font_size_override("font_size", 18)
	_deck_pick_start_btn.custom_minimum_size = Vector2(0, 42)
	_deck_pick_start_btn.pressed.connect(_on_deck_pick_confirm)
	wrapbox.add_child(_deck_pick_start_btn)
	# 【2026-09-23 修】先按"人最多的那支卡组"量一次面板尺寸（尺寸只在这次定下来，见 `_layout_deck_pick_panel`）
	#   ⇒ 之后点 卡组1/2/3 只换内容、不再重算尺寸，弹窗不会左右移动。
	var widest := 1
	for i in _deck_pick_decks.size():
		if (_deck_pick_decks[i] as Array).size() > (_deck_pick_decks[widest - 1] as Array).size():
			widest = i + 1
	_deck_pick_slot = widest
	_refresh_deck_pick_preview()
	_layout_deck_pick_panel()
	_on_deck_pick_tab(1)

# 点卡组1/2/3：切换到该槽并刷新队伍预览
func _on_deck_pick_tab(slot: int) -> void:
	_deck_pick_slot = slot
	for s in _deck_pick_tabs.keys():
		var t: Button = _deck_pick_tabs[s]
		t.set_pressed_no_signal(int(s) == slot)
	_refresh_deck_pick_preview()
	_layout_deck_pick_panel()

# 重建当前卡组的队伍预览（清空旧内容后按当前槽重建）
func _refresh_deck_pick_preview() -> void:
	if _deck_pick_preview == null:
		return
	for c in _deck_pick_preview.get_children():
		_deck_pick_preview.remove_child(c)
		c.queue_free()
	var idx := _deck_pick_slot - 1
	var ids: Array = _deck_pick_decks[idx] if (idx >= 0 and idx < _deck_pick_decks.size()) else []
	# 【2026-09-28·用户口径】预览顺序 = 部署时卡池顺序：卡组里带 `<替补>` 的英雄同样排到末尾
	#   （选定后 `Battle._commit_deck()` 落库时会 `_order_deck(...)`）⇒ 提前用同一把排序，两处一致。
	#   ⚠️ 只改这份**用于显示**的副本：`_deck_pick_decks` 原样不动（`_order_deck` 返回新数组，不改入参）。
	if battle != null and is_instance_valid(battle):
		ids = battle._order_deck(ids)
	if _deck_pick_start_btn != null:
		_deck_pick_start_btn.text = "用卡组 %d 出战" % _deck_pick_slot
	if ids.size() == 0:
		if _deck_pick_info != null:
			_deck_pick_info.text = "卡组 %d：空 —— 请到普通模式编辑页添加英雄。" % _deck_pick_slot
		_deck_pick_preview.custom_minimum_size = Vector2.ZERO
		_deck_pick_preview.size = Vector2.ZERO
		return
	if _deck_pick_info != null:
		_deck_pick_info.text = "卡组 %d（%d 名）%s" % [_deck_pick_slot, ids.size(), "" if ids.size() >= 5 else "  ⚠ 不足 5 名"]
	var pool := _make_deck_preview_cards(ids)
	_deck_pick_preview.add_child(pool)
	# 宿主要撑到队伍卡行的实际尺寸，否则面板宽度不随人数变化、卡牌会溢出面板
	_deck_pick_preview.custom_minimum_size = pool.custom_minimum_size
	_deck_pick_preview.size = pool.custom_minimum_size

# 卡组三选一界面的英雄卡块（与编辑页"卡组预览"同一套外观），悬停查看英雄属性
#   【2026-09-28·用户要求①】「卡组英雄队伍列表放大，8 个英雄占满宽度」：原来固定半径 30（8 个英雄只占半屏）；
#   【2026-09-28·用户要求②】「六边形改成 2 排、一排 4 个」⇒ 走 `_make_hex_pool` 的**网格模式**
#     （`single_row = false`：固定 **4 列**、**列优先**填充 ⇒ 8 名正好 4×2；5~8 名都是这个 4×2 蜂窝块）。
#   【2026-09-28·用户要求③】「太大了，把棋盘都挡住了」⇒ 半径**封顶 56**（沿用"一行版"那个大家都认可的卡大小）：
#     4 列要铺满宽度得 `r ≈ 96`，那样弹窗高 640、整块把棋盘盖住；封顶后块只有 364×291 ⇒ 弹窗小一圈、两侧透出棋盘。
#   半径 = `clampf(可用宽 / 6.5, 24, 56)`：窄屏按比例缩，宽屏由 56 兜住。想再小/再大只改这个上限
#   （48 更紧凑 / 64 更大）。可用宽 = 视口宽 − 80（面板最大宽是 `vsize.x − 24`，这里留出面板左右内边距）。
func _make_deck_preview_cards(ids: Array) -> Control:
	var hover_cb := func(hid: String):
		if hid == "":
			_set_score_tooltip_visible(false)
		else:
			_set_score_tooltip_hero(hid)
	var click_cb := func(_hid: String):
		pass
	var avail: float = get_viewport().get_visible_rect().size.x - 80.0
	# 4 列网格（列优先 ⇒ 8 名正好 4×2）；半径封顶 56（见上面函数头注释：96 会挡住棋盘）
	var rad := clampf(avail / 6.5, 24.0, 56.0)
	return _make_hex_pool(ids, hover_cb, click_cb, false, "", false, rad)

# 面板尺寸/位置。
# 【2026-09-23 修·用户报"点击卡组切换后弹窗会左右移动"】宽度/高度**只在第一次调用时量一次**
#   （那次的内容 = 人最多的卡组 + 最宽形态的限时大字，见 `_show_deck_pick_panel`）⇒ 之后切卡组
#   只换预览内容、尺寸与位置都不动。原来每次都按当前内容重算并重新居中 ⇒ 卡行人头数不同 /
#   秒数从两位数变一位数 ⇒ 宽度一变，居中的弹窗就整体左移或右移。
#   ⚠️ 量之前必须把 `custom_minimum_size` 清成 0：`reset_size()` 只重置 size，
#   `get_combined_minimum_size()` 仍会被上一轮写进去的 custom_minimum_size 垫高 ⇒ 宽度只增不减。
func _layout_deck_pick_panel() -> void:
	if _deck_pick_panel == null or not is_instance_valid(_deck_pick_panel):
		return
	var vsize := get_viewport().get_visible_rect().size
	var max_w: float = maxf(vsize.x - 24.0, 400.0)
	if _deck_pick_panel_w <= 0.0:
		_deck_pick_panel.custom_minimum_size = Vector2.ZERO
		_deck_pick_panel.reset_size()
		var min_sz := _deck_pick_panel.get_combined_minimum_size()
		_deck_pick_panel_w = clampf(maxf(min_sz.x, 400.0), 400.0, max_w)
		_deck_pick_panel_h = minf(min_sz.y, vsize.y - 16.0)
	var pw: float = clampf(_deck_pick_panel_w, 400.0, max_w)
	var ph: float = minf(_deck_pick_panel_h, vsize.y - 16.0)
	_deck_pick_panel.custom_minimum_size = Vector2(pw, ph)
	_deck_pick_panel.size = Vector2(pw, ph)
	_deck_pick_panel.position = Vector2((vsize.x - pw) / 2.0, maxf((vsize.y - ph) / 2.0, 8.0))

# 点"用卡组 N 出战"：取当前查看的卡组
func _on_deck_pick_confirm() -> void:
	_try_pick_deck(_deck_pick_slot)

# 点某卡组槽出战：不足 5 名则弹提示并保持面板
func _try_pick_deck(slot: int, ids_override: Array = []) -> void:
	var idx := slot - 1
	var ids: Array = ids_override
	if ids.is_empty() and idx >= 0 and idx < _deck_pick_decks.size():
		ids = _deck_pick_decks[idx]
	if ids.size() < 5:
		var d := AcceptDialog.new()
		d.title = "卡组人数不足"
		d.dialog_text = "卡组 %d 只有 %d 名英雄，至少需要 5 名才能出战。\n请到编辑页补足卡组，或点「随机英雄」。" % [slot, ids.size()]
		d.ok_button_text = "知道了"
		d.confirmed.connect(d.queue_free)
		add_child(d)
		d.popup_centered()
		return
	_close_deck_pick_panel()
	if battle != null and is_instance_valid(battle):
		battle._on_deck_pick(slot)

func _on_deck_pick_random_pressed() -> void:
	_close_deck_pick_panel()
	if battle != null and is_instance_valid(battle):
		battle._on_deck_pick_random()

func _close_deck_pick_panel() -> void:
	if _deck_pick_overlay != null:
		_deck_pick_overlay.queue_free()
		_deck_pick_overlay = null
	_deck_pick_panel = null
	_deck_pick_panel_w = 0.0   # 【2026-09-23】尺寸缓存随面板一起清（下次开面板重新量一次）
	_deck_pick_panel_h = 0.0
	_deck_pick_preview = null
	_deck_pick_info = null
	_deck_pick_start_btn = null
	_deck_pick_timer_label = null   # 【2026-09-29】那行大字已废（读秒移去状态栏），这里保留只为兼容旧引用
	_deck_pick_tabs.clear()
	_deck_pick_decks = []
	_set_score_tooltip_visible(false)

## 【2026-09-27·用户要求】底部按钮带的**顶边 y** —— 现在只有「结束回合」一行 + 右贴边的箭头。
##   `_build()`、替补列表、开局选人面板三处定位都走它 ⇒ 要挪整条带子只改 `BTN_ROW_FOOT_GAP` 一处。
func _btn_row_y() -> float:
	return get_viewport().get_visible_rect().size.y - END_BTN_IMG_H - BTN_ROW_FOOT_GAP

## 【2026-09-28·用户报「部署界面的六边形大小和替补队伍的六边形大小不一样」】两处卡池**共用这一个半径**：
##   原来部署那行写死 `48.0`、替补那行按可用宽度反算（8 张 ≈54、更少时封顶 56）⇒ 一个 48 一个 54~56，
##   看着就不是一套。现在两边都走它（`_TEAM_ROW_MAX_R` 封顶 ⇒ 张数少时都是 56、满 8 张 54 ⇒ 观感一致）。
func _team_row_radius(n: int) -> float:
	var vsize := get_viewport().get_visible_rect().size
	var tavail: float = maxf(vsize.x - 44.0, 320.0)
	return minf(_TEAM_ROW_MAX_R, maxf(tavail / (2.0 + float(maxi(n, 1) - 1) * 1.5), 18.0))

## 正在"选替补上阵"（这一阶段**必须**显示替补列表，与用户收没收起无关）
func _sub_picking() -> bool:
	# 【2026-09-28·用户报】「替补时点了英雄、还没落位 ⇒ 应该是**高亮选中**，而不是列表消失」：
	#   除了 SUBSTITUTING/PLACE_SUB 两个状态，**只要还握着没落位的 `_pending_sub` 就算在替补流程里**
	#   ⇒ 列表在整个"点人 → 找绿格落位"过程里都留着（落位后 `_pending_sub` 清空 ⇒ 自动收回）。
	if battle == null or not is_instance_valid(battle):
		return false
	if battle.state == Battle.State.SUBSTITUTING or battle.state == Battle.State.PLACE_SUB:
		return true
	return String(battle._pending_sub) != ""

## 【2026-09-27·用户要求】右贴边那个箭头的点击：拉出 / 收回替补队伍列表
func _on_team_toggle() -> void:
	# 【2026-09-28·用户报「主动拖下英雄后，点击替补队伍时替补队伍列会重新出来一次」】选替补阶段
	#   面板是**强制开**的（_sub_picking()），而 _team_panel_open 仍是 false ⇒ 这一点手就把它翻成
	#   true ⇒ _refresh_team_panel() 把面板**重建并再滑一次**（看着就是又出来一遍）。
	#   这一阶段列表本来就不能收（要靠它选人）⇒ 直接忽略这一下（不改状态、不重建 ⇒ 也不闪）。
	if _sub_picking():
		return
	_team_panel_open = not _team_panel_open
	if _team_panel_open:
		_refresh_team_panel()
	else:
		_close_team_panel()
	_refresh_team_toggle()

## 【2026-09-28·用户要求】把该显示的那张图标贴到"替补列表开关"按钮上：
##   收起 = `展开替补队伍.png`（点它拉出）· 拉出 = `收回替补队伍.png`（点它收回）。
##   ⚠️ `_refresh_team_toggle()` 挂在**每帧**的 `_refresh_controls()` 上 ⇒ 这里**只在状态下变时才重建**
##   （4 个 `StyleBoxTexture` 每帧新建会白烧）；图缺失时退回原来的文字箭头。
func _apply_team_toggle_icon(open_now: bool) -> void:
	if _team_toggle_btn == null or not is_instance_valid(_team_toggle_btn):
		return
	if _team_toggle_tex_open == open_now and _team_toggle_btn.text == "":
		return
	_team_toggle_tex_open = open_now
	var tex := load(TEAM_TOGGLE_TEX_OPEN if open_now else TEAM_TOGGLE_TEX_CLOSED) as Texture2D
	if tex == null:
		_team_toggle_btn.text = TEAM_TOGGLE_OPEN if open_now else TEAM_TOGGLE_CLOSED
		_team_toggle_tex_open = not open_now   # 强制下次再试（图可能后补上）
		return
	_team_toggle_btn.text = ""
	_team_toggle_btn.custom_minimum_size = Vector2(
		TEAM_TOGGLE_ICON_H * float(tex.get_width()) / float(tex.get_height()), TEAM_TOGGLE_ICON_H)
	var states := {
		"normal": Color(1.0, 1.0, 1.0, 1.0),
		"hover": Color(1.12, 1.12, 1.12, 1.0),
		"pressed": Color(0.85, 0.85, 0.85, 1.0),
		"disabled": Color(0.6, 0.6, 0.62, 0.85),
	}
	for st in states.keys():
		var sb := StyleBoxTexture.new()
		sb.texture = tex
		sb.modulate_color = states[st]
		_team_toggle_btn.add_theme_stylebox_override(String(st), sb)

## 【2026-09-28·用户要求「竞技场开局默认打开替补队伍面板，直到部署完成再关闭」】
##   竞技场**选人（2 选 1）+ 部署期**要强制展开替补队伍面板（其它模式、其它阶段一律照旧"点箭头才拉出"）。
##   ⚠️ 【2026-09-28 晚·用户报「竞技场 2 选 1 的时候，替补队伍还是没有默认打开」】第一版只认
##     `DEPLOY` / `PLACE_DEPLOY` 两个状态 ⇒ **2 选 1 那一段（`ARENA_DRAFT`）压根不展开** ——
##     而"竞技场开局"用户说的正是那一段（选人时就要看得到自己已选/已进替补席的牌）。
##     同一族还有第二处早退（`_refresh_team_panel()` 里那条 `DEPLOY/PLACE_DEPLOY` 提前 return）必须一起放行，
##     否则竞技场轮次里**部署那一段**照样会被早退吃掉（`_team_panel_forced` 拦不住它）。
func _should_force_team_panel() -> bool:
	if not GameState.arena_mode:
		return false
	if battle == null or not is_instance_valid(battle) or _in_replay():
		return false
	# 【2026-09-28·用户报「竞技场模式，部署阶段会有两个队伍列表」】**部署期不再强开**：
	#   部署阶段本来就有一列"开局选人"的池子，再叠一列队伍面板 = 两个列表；非竞技场的部署期
	#   也只留选人池（见下面 `_refresh_team_panel()` 那条早退）⇒ 这里只认 2 选 1 那一段。
	# 【2026-09-30·用户报「2 选 1 阶段有队伍在下面，然后又消失，等部署开始又出来。
	#   我希望是一直都在，不要一闪一闪的」】再加**交接窗口**（`battle._arena_to_deploy` =
	#   选人已完、部署卡池还没顶上来那 ≈2 秒：棋盘开场演出 + 战斗开始横幅，见 `_begin_deployment()`）：
	#   这一段继续摆着队伍面板（内容与部署卡池同序同半径 ⇒ 顶上来时看不出换块），
	#   部署一开张 Battle 就落旗、这里随之收回，所以不会又变成"两个队伍列表"。
	return battle.state == Battle.State.ARENA_DRAFT or battle._arena_to_deploy

## 每帧（`_refresh_controls()` 里）对齐"竞技场强制展开"：
##   进入竞技场部署 ⇒ 展开（首次照常从屏幕右缘滑入）；部署一完成 ⇒ 收回。
##   只在状态**变化**时动一次，避免每帧重建面板。
##   【2026-09-30·本次改动】强开期间面板若被别处收掉（`_on_restart()` 重开、`clear_transient_ui()`、
##   暂停期那条"不重建"的路）就**补建回来** —— 否则强开期一过没人再喊重建，屏底会一直空着，
##   而用户口径是「一直都要在」（报的就是"队伍消失一下、部署又出来"）。空卡组时这里只是空转
##   （`_refresh_team_panel()` 在 `ids` 为空时直接 return，不建面板）。
func _sync_arena_team_panel() -> void:
	var want := _should_force_team_panel()
	if want == _team_panel_forced and not (want and _team_panel == null):
		return
	_team_panel_forced = want
	if want:
		_team_panel_slide_next = true   # 首次展开走滑入动画
	_refresh_team_panel()               # 显隐统一由 `_refresh_team_panel()` 派生

## 开关按钮的图标/显隐刷新（部署期、回放里没有"常驻替补列表" ⇒ 藏起来）。
func _refresh_team_toggle() -> void:
	if _team_toggle_btn == null or not is_instance_valid(_team_toggle_btn):
		return
	var open_now: bool = _team_panel_open or _sub_picking()
	_apply_team_toggle_icon(open_now)
	# ⚠️ 这个局部变量别叫 `show`：会遮住基类（CanvasLayer）的 `show()`，Godot 报 SHADOWED_VARIABLE_BASE_CLASS
	var show_toggle := false
	if battle != null and is_instance_valid(battle) and not _in_replay():
		# 【2026-09-28 晚·本次改动】竞技场**选人（2 选 1）**也算"由系统强制展开"的阶段 ⇒ 同部署期一样藏箭头
		#   （面板已经开着，再摆一个"拉出"箭头会让玩家以为能收起它）。普通模式不受影响。
		# 【2026-09-29·用户要求「普通模式卡组 3 选 1 的时候，不要显示替补按钮」】卡组还没定、
		#   队伍面板本来就没有内容可看 ⇒ `DECK_PICK` 也一并藏箭头。
		# 【2026-09-29·用户要求「在棋盘演出效果的时候，也不要显示替补按钮」】开场那段棋盘演出
		#   （格子/障碍/道具从天上落下来，`Battle._board_intro_running`）期间也藏 —— 演出期间
		#   屏幕本该只有棋盘在动。演出结束（`_board_intro_running` 转假）后每帧刷新会自己把它放回来。
		show_toggle = battle.state != Battle.State.DEPLOY and battle.state != Battle.State.PLACE_DEPLOY \
			and battle.state != Battle.State.DECK_PICK \
			and not battle._board_intro_running \
			and not _should_force_team_panel()
	_team_toggle_btn.visible = show_toggle
	# 【2026-09-28·用户要求】「需要替补的时候……**替补按钮常暗**」：这一阶段置灰（disabled）
	#   ⇒ 走 disabled 那张压暗样式，且 Godot 的 disabled Button 不再发 pressed。
	_team_toggle_btn.disabled = _sub_picking()

# 下方常驻队伍面板：整支卡组（上阵 + 替补），一字行透明卡牌，随 team_updated 刷新。
# 同一面板双模式（避免"替补选人面板"与常驻面板重叠/互相遮盖）：
#  - 平时：只读展示本端替补席/队伍，悬停查看属性（⚠️ **默认收起**，2026-09-27 起由右贴边箭头拉出）；
#  - SUBSTITUTING / PLACE_SUB：同一面板变"选择替补上阵"，点击英雄=选中落位（battle._on_sub_pick）。
func _refresh_team_panel() -> void:
	if battle == null:
		return
	# 【2026-09-29·同 `_show_deploy_panel()` 那条】暂停期间不重建：重建会把面板挪到 HUD 子节点末尾
	#   ⇒ 画在暂停浮层**上面**（用户报的"点了菜单还有列表冒出来"就是这一族）。恢复后再刷新即可。
	if get_tree() != null and get_tree().paused:
		return
	if _in_replay():
		_close_team_panel()   # 回放里不摆常驻队伍卡（见 `_in_replay()` 的说明）
		_refresh_team_toggle()
		return
	# 部署期：只显示"开局选人"面板，不显示下方常驻面板（避免重叠）。
	# 【2026-09-28·用户要求「竞技场开局默认打开替补队伍面板，直到部署完成再关闭」】
	#   竞技场（选人 + 部署）是**例外**：`_team_panel_forced` 为真时照样摆出替补队伍面板。
	#   ⚠️ 这条早退**必须带 `_team_panel_forced` 这个例外**，否则 `_sync_arena_team_panel()` 刚置好标志、
	#      走到这里又被无脑收掉（竞技场部署那一段就会"强制展开"失效）。
	if (battle.state == Battle.State.DEPLOY or battle.state == Battle.State.PLACE_DEPLOY) \
			and not _team_panel_forced:
		_close_team_panel()
		_refresh_team_toggle()
		return
	var picking := _sub_picking()
	# 【2026-09-27·用户要求】"点击箭头才把替补队伍列表拉出" ⇒ 平时不再常驻摆在棋盘下面
	#   （它原来一直占着屏底 ~200px，也是棋盘长不大的原因之一）。
	# 【2026-09-28·用户要求】「**不需要替补的时候默认收回**」⇒ 可见性 = 用户的开关 or 正在选替补
	#   （前者默认 false ⇒ 平时收着；后者保证选替补期间恒在、阶段一过自动消失）。
	if not _team_panel_open and not picking and not _team_panel_forced:
		_close_team_panel()
		_refresh_team_toggle()
		return
	# 【2026-09-28·用户报「点击英雄会闪一下」】重建（点英雄刷新高亮）时**不要重新滑入**：
	#   只有「从无到有」那一次才从屏幕右缘滑出；已经有面板就直接落在目标位置。
	var had_panel: bool = _team_panel != null
	if _team_panel:
		_team_panel.queue_free()
		_team_panel = null
	# 替补选中阶段展示当前替补席；平时展示整队（含替补）
	var ids: Array = battle._sub_roster() if picking else battle._player_team_ids()
	if ids.size() == 0:
		return
	var vsize := get_viewport().get_visible_rect().size
	var panel := PanelContainer.new()
	# 透明背景（不遮界面），仅承载卡牌；布局（VBox + 标题 + 一行卡）
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0)
	sb.content_margin_left = 6.0
	sb.content_margin_right = 6.0
	sb.content_margin_top = 4.0
	sb.content_margin_bottom = 4.0
	panel.add_theme_stylebox_override("panel", sb)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(panel)
	_team_panel = panel
	var wrapbox := VBoxContainer.new()
	wrapbox.add_theme_constant_override("separation", 4)
	wrapbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(wrapbox)
	var title := Label.new()
	if picking:
		# 自由部署双控：可能是"敌方替补列表"（拖动敌方英雄撤下后弹出），标题要标明是谁的替补
		var sub_txt: String = battle._sub_faction_txt()
		if sub_txt != "":
			title.text = "选择替补上阵（%s）：点击英雄选中，再点击棋盘绿格落位" % sub_txt
		else:
			title.text = "选择替补上阵（点击英雄选中，再点击棋盘绿格落位）"
	else:
		title.text = "替补队伍"
	title.add_theme_font_size_override("font_size", 15)
	title.add_theme_color_override("font_color", Color(1, 0.85, 0.5) if picking else Color(0.6, 0.85, 1.0))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	wrapbox.add_child(title)
	# 悬停显示英雄属性（带背景浮层，位置由 _process 收敛)
	var hover_cb := func(hid: String):
		if _team_panel_sliding:
			return   # 滑出中：卡片只是从鼠标底下掠过，别弹属性框
		if hid == "":
			_set_score_tooltip_visible(false)
			return
		_set_score_tooltip_hero(hid)
	var click_cb := func(_h: String):
		pass
	if picking:
		click_cb = func(hid: String):
			if _team_panel_sliding:
				return   # 滑出中的误触不算选人
			battle._on_sub_pick(hid)   # 点击替补英雄：选中并进入落位阶段
			_refresh_team_panel()      # 立即刷新高亮（_pending_sub），后续动作仍可再点其他英雄
	# 【2026-09-28·用户要求】「卡组英雄队伍列表放大，8 个英雄占满宽度」：这一行原来固定半径 48
	#   （8 张只占 600/720 ≈ 83%）⇒ 改成**按可用宽度反算**：一行 n 张平顶六边形总宽 = `2r + (n−1)·1.5r`
	#   ⇒ `r = 可用宽 / (2 + 1.5·(n−1))`；可用宽 = 视口宽 − 面板左右内边距(6+6)与 20 的余量 − 两侧留白。
	#   ⚠️ 8 张一行的**物理上限**就是 `视口宽 / 12.5`（≈57）⇒ 再大必须改成两行，见下面 `_TEAM_ROW_MAX_R` 注释。
	var trad := _team_row_radius(ids.size())   # 【2026-09-28】与部署卡池共用同一半径
	var pool := _make_hex_pool(ids, hover_cb, click_cb, false, battle._pending_sub if picking else "", true, trad)
	wrapbox.add_child(pool)
	var pw := pool.custom_minimum_size.x + 20.0
	var ph := pool.custom_minimum_size.y + 34.0
	panel.custom_minimum_size = Vector2(pw, ph)
	panel.size = Vector2(pw, ph)
	# 【2026-09-27·用户要求】替补列表「**从右往左拉出**、**覆盖在结束回合按钮那行**」：
	#   ① 贴右对齐（改为**水平居中**，见 `target_x`；不再需要给右上角开关让位）；
	#   ② 竖直方向**以屏幕底为基准**（底边距 6px）⇒ 面板正落在按钮带上、向上多出的部分压在棋盘下沿；
	#   ③ 起点放在屏幕右缘外 `vsize.x`，再 tween 到目标 x ⇒ 就是"从右往左滑出来"。
	# 【2026-09-28·用户要求】弹出来的替补队伍**居中显示**（原来贴右）⇒ 水平居中；仍从屏幕右缘滑入。
	var target_x: float = (vsize.x - pw) * 0.5
	var do_slide: bool = (not had_panel) or _team_panel_slide_next
	_team_panel_slide_next = false
	if not do_slide:
		panel.position = Vector2(target_x, vsize.y - ph - 6.0)   # 就地更新（不滑、不闪）
	if do_slide:
		panel.position = Vector2(vsize.x, vsize.y - ph - 6.0)
		_team_panel_sliding = true
		var slide := create_tween()
		slide.tween_property(panel, "position:x", target_x, 0.16).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		slide.finished.connect(func():
			_team_panel_sliding = false
			_set_score_tooltip_visible(false))   # 滑完把被"掠过"留下的属性框清掉
	_refresh_team_toggle()   # 面板建成/收起后把箭头文案同步一次

# 关闭常驻队伍面板
func _close_team_panel() -> void:
	# 【2026-09-28·用户报「点击英雄会闪一下」】重建（点英雄刷新高亮）时**不要重新滑入**：
	#   只有「从无到有」那一次才从屏幕右缘滑出（由 `_team_panel_slide_next` 那个标志管），
	#   已经有面板就直接落在目标位置。
	# 【2026-09-29 消警告 `UNUSED_VARIABLE`】原来这里还有一句 `var had_panel := _team_panel != null`
	#   —— 那是在本函数（"关闭面板"这条路上）根本用不到的死变量：真正判"要不要滑入"的那份同名变量
	#   在 `_refresh_team_panel()` 里（`do_slide = (not had_panel) or _team_panel_slide_next`），那份保留。
	if _team_panel:
		_team_panel.queue_free()
		_team_panel = null
	_close_chat_panel()   # 阶段切换/重开时收起喊话选言面板
	# 【2026-09-27】收起面板的路径也要把箭头状态刷一遍：`_show_deploy_panel()`（进部署）走的就是这条
	#   ⇒ 部署期箭头必须跟着隐藏（`_refresh_team_toggle()` 内部按 state 判，不递归）。
	_refresh_team_toggle()

func _build() -> void:
	var vsize := get_viewport().get_visible_rect().size
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	_ui_root = root   # 【2026-09-23】给浮层用：临时遮罩要插在它**最底层**，别盖住常驻按钮（见 `_show_deck_pick_panel`）

	# 顶部：回合与阵营
	var top := PanelContainer.new()
	top.position = Vector2(0, 0)
	# 【2026-09-29·用户报「回合数的位置没改动啊」】病灶：`top` 是 **PanelContainer（容器）** ——
	#   它会把子节点 `toph` 强行摆进自己的内容区，我在 `toph` 上设的 `position/size/alignment`
	#   一律被覆盖 ⇒ 两条（回合数 / 计时器）挤在原来的 54 高里，怎么调都看不出变化。
	#   现在把这条顶栏加高到与"名字框 + 标志"两行同高（73），`toph` 的两行才真的排在条内：
	#   回合数贴顶、计时器在它下面。
	top.size = Vector2(vsize.x, NAME_PLATE_H + 1 + DeathMark.SLOT_D)
	# 【2026-09-29·用户报「回合数还是没有贴边」】再补一刀：这条顶栏用的是主题的弹出框底纹，
	#   它自带 content_margin（内边距）⇒ 里面的两行离顶边永远差那几像素。这里复制一份样式、
	#   把内边距清零（**底纹照旧保留**）⇒ 回合数真正贴顶。
	var top_sb := top.get_theme_stylebox("panel")
	if top_sb != null:
		var sb_top: StyleBox = top_sb.duplicate()
		sb_top.content_margin_left = 0.0
		sb_top.content_margin_right = 0.0
		sb_top.content_margin_top = 0.0
		sb_top.content_margin_bottom = 0.0
		top.add_theme_stylebox_override("panel", sb_top)
	# 【2026-09-29·用户要求「战斗中上方状态栏的背景增加透明度」】底色不透明度走常量 `TOP_BAR_BG_A`
	#   （0.85 → 0.55；这里本来覆盖的就是一块 StyleBoxFlat，不是主题底纹 ⇒ 直接调 alpha 即可）。
	top.add_theme_stylebox_override("panel", _make_panel(Color(0.08, 0.08, 0.12, TOP_BAR_BG_A)))
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(top)
	# 【2026-09-29·用户要求「状态栏的计时器放在回合数下面」】中间那组改成**竖排两行**：
	#   第一行 = 回合数（+ 火焰），第二行 = 计时器；整组仍在两行状态栏的**正中**。
	var toph := VBoxContainer.new()
	toph.add_theme_constant_override("separation", 0)
	# 【2026-09-29·用户要求「回合数的位置不要变，靠上」】整组**贴着第一行顶**排（不在两行里居中）
	#   ⇒ 回合数落在第一行（与两条名字框同一水平线），计时器紧贴它下面。
	toph.alignment = BoxContainer.ALIGNMENT_BEGIN
	var top_row_a := HBoxContainer.new()
	top_row_a.alignment = BoxContainer.ALIGNMENT_CENTER
	top_row_a.add_theme_constant_override("separation", 4)
	# 【2026-09-29·用户要求「将名字框延伸到画面中间，两边一样长」】名字框占满**第一行**（各半屏）
	#   ⇒ 中间那组（第 N 回合 · 火焰 · 剩余时间）从"整条居中"挪到**第二行**（与两排阵亡标志同一行、
	#   夹在它们中间居中）—— 否则它会正好压在那两条名字框上。
	toph.position = Vector2(0, 0)
	toph.size = Vector2(vsize.x, NAME_PLATE_H + 1 + DeathMark.SLOT_D)
	# 【2026-09-29·真凶】上一行原来是 `ALIGNMENT_CENTER` —— **它把上面那句 BEGIN 覆盖了**
	#   （同一帧里赋值两次，后者生效）⇒ 中间那组一直在 73 高的条里**垂直居中**：计时器一出现，
	#   整组高度从 34 变 70 ⇒ 重新居中 ⇒ **回合数跟着上下跳**（用户报的"上上下下"就是这个，
	#   不是字号问题）。探针实测：修前 `round` 的 y=19（= (73−34)/2），修后贴顶。
	toph.alignment = BoxContainer.ALIGNMENT_BEGIN
	top.add_child(toph)
	top_row_a.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	# 竖着**贴顶**（不让它去吃 VBox 的剩余高度 ⇒ 计时器显隐都不会让回合数挪位）
	top_row_a.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	toph.add_child(top_row_a)
	_round_label = Label.new()
	_round_label.add_theme_font_size_override("font_size", 24)
	_round_label.add_theme_color_override("font_color", Color(1, 0.85, 0.5))
	_round_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	top_row_a.add_child(_round_label)
	# 【2026-09-29·用户要求「把状态栏 11 回合后的火焰图案去掉」】原来这里 new 了一个 `FlameIcon`
	#   （第 11 回合起常驻脉动）⇒ **不再创建**（`_flame_icon` 恒为 null，下面那几处本来就有 null 守卫：
	#   `_fit_top_center()` 的 `flame_on` 恒 false、`_set_round_text()` 里那句 `visible=` 跳过）。
	#   ⚠️ 「回合标签变红脉动」那套（`_start_round_fire()` / `_stop_round_fire()`）**保留**，
	#   用户这次只点名去掉火焰图案。
	_flame_icon = null
	_turn_timer_label = Label.new()
	_turn_timer_label.add_theme_font_size_override("font_size", 26)
	_turn_timer_label.add_theme_color_override("font_color", Color(1.0, 0.9, 0.6))
	_turn_timer_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	_turn_timer_label.add_theme_constant_override("outline_size", 3)
	_turn_timer_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_turn_timer_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_turn_timer_label.visible = false
	toph.add_child(_turn_timer_label)

	# 顶部阵亡计数：左我方 / 右敌方（骷髅图标，放大版）
	# 联机对局这两行还要显示双方姓名（我方=本机名片姓名 / 敌方=对端姓名），
	# 字号收一档（27→18）免得和中间的"第 N 回合 / 剩余时间"挤在一起。
	# 【2026-09-23 改】每侧 = 名字 + 逐槽 DeathMark（不是拼字符串）⇒ 单槽可定位/摇晃。
	# 【2026-09-29·用户要求】改成**竖排两行**（名字框在上、标志在下），见下面那段高度账。
	var slot_n: int = battle.LOSS_DEATH_COUNT if battle != null else 3
	# 【2026-09-28·用户报「联机对战中，主机是蓝方，客房是红方。现在状态栏有点混乱」】
	#   这一行的名字色与下面两排阵亡标志原来**写死**成"我方=蓝 / 敌方=红"，而联机里
	#   **客房是红方**（主机 = PLAYER = 蓝 · 客房 = ENEMY = 红）⇒ 客房看到的是"自己的名字和
	#   阵亡标志是蓝的、对手反而是红的"，左右两行与棋盘上的阵营色对不上。
	#   ⇒ 一律按**绝对阵营色**上色（与棋子描边 `Unit._faction_color` 同一套口径）：PLAYER 蓝 · ENEMY 红。
	#   单机/双控里 我方 = PLAYER ⇒ 与改动前逐位相同。
	var my_fn: int = battle._my_faction() if battle != null else DataRegistry.Faction.PLAYER
	# （原来这里还有 `my_col`/`op_col` 两个局部变量；名字框与骷髅槽改成"按所在行的绝对阵营取色"之后没人用了 ⇒ 删）
	# 【2026-09-29·用户要求】名字不再直接写在状态栏上，而是**写在名字框素材里**。
	# 【2026-09-29·用户报「客房的红蓝色名字框的方向反了」】名字框的**左右是绝对的**：
	#   **左 = 蓝方（PLAYER）· 右 = 红方（ENEMY）**，不随主客视角对调 —— 素材本身是分左右的
	#   （蓝框给左边、红框给右边），跟着"我在左"翻过来在客房里就朝反了。
	#   框里写的仍是**本端视角**的名字（我这侧 = 「我方」、对面 = 「敌方」），框色/骷髅槽色按绝对阵营，
	#   这样客房里看到的就是"右边红框 + 我方、左边蓝框 + 敌方"，与棋盘上"自己是红"完全对得上。
	#   ⚠️ 阵亡骷髅那两排也跟着名字框走（同一行）：`_my_marks` 挂到**本端绝对阵营**所在的那一行
	#   （客房里就是右行）⇒ `_reveal_mark()` / 卡片飞行终点都不需要改（它们按数组取位置）。
	# 【2026-09-29·用户要求「名字字体放大点」】18 → **24**（框高 34、"我方"两字 ≈48px，
	#   框宽有半屏那么多 ⇒ 放得下；联机的长名字也还有余量）。
	var plate_font: int = 24
	# 【2026-09-29·用户要求「将状态栏死亡标志移到名字下方」】每侧改成**竖着两行**：
	#   第一行 = 名字框（素材里带字，框色按**绝对阵营**：左蓝 = PLAYER · 右红 = ENEMY），
	#   第二行 = 3 枚阵亡标志，**靠外缘对齐**（与名字框同侧：左行贴左、右行贴右）。
	#   ⚠️ 高度账（下面三个尺寸都由它定）：状态栏高 54，而右上角的「音量 / 暂停（联机是「认输」）」
	#   从 y≈58.5 起 ⇒ 两行加起来必须 ≤ 56：**名字框 34 + 间隔 1 + 标志槽 20 = 55**（起点 y=1 ⇒ 到 56 结束）。
	#   想让标志更大，得先动右上角那几个按钮（往下会压棋盘顶行、往左就离开角落）—— 要改说一声。
	# 【2026-09-29·用户要求三连】①「名字框延伸到画面中间，两边一样长」⇒ 框宽改成**外部给定**
	#   `bar_w = 半屏 − 12(起排缝) − 8(中间缝)`，左右等长；②「放大死亡标志」⇒ `SLOT_D` 20 → **38**
	#   （右上角那两个按钮搬走后不再受 y≤56 限制，两行合计 34+1+38 = 73 < 棋盘让出的 101）;
	#   ③ 暂停键 →「菜单」并搬到左下角（见 `_pause_btn` 那一段）。
	# 【2026-09-29·用户要求「名字框太长了，给中间的回合数预留空间」】框不再各占半屏：
	#   中间留出 `TOP_MID_GAP` 给「第 N 回合 · 火焰 · 剩余时间」（那组仍在**第一行**居中，
	#   但纵向跨越两行 ⇒ 视觉上落在整块的正中），左右两条等长。
	var bar_w: float = (vsize.x - 24.0 - TOP_MID_GAP) * 0.5
	_my_marks.clear()
	_op_marks.clear()
	for side_fn in [DataRegistry.Faction.PLAYER, DataRegistry.Faction.ENEMY]:
		var mine: bool = side_fn == my_fn
		var is_left: bool = side_fn == DataRegistry.Faction.PLAYER   # 左蓝右红（绝对阵营，不随主客视角翻）
		var col_box := VBoxContainer.new()
		col_box.add_theme_constant_override("separation", 1)
		col_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
		col_box.position = Vector2(12 if is_left else 0, 1)
		col_box.size = Vector2(vsize.x - 12, NAME_PLATE_H + 1 + DeathMark.SLOT_D)
		root.add_child(col_box)
		var plate := _make_name_plate(NAME_FRAME_BLUE if is_left else NAME_FRAME_RED,
			# 【2026-09-29·用户要求「把双方的名字都用白色」】名字不再按阵营上色，一律**白色**
			#   （框内文字带黑描边 ⇒ 蓝框/红框上都看得清）；`_faction_ui_color()` 仍给阵亡演出用。
			"我方" if mine else "敌方", Color(1.0, 1.0, 1.0), plate_font, bar_w,
			HORIZONTAL_ALIGNMENT_LEFT if is_left else HORIZONTAL_ALIGNMENT_RIGHT)
		# 框自己别被 VBox 拉宽（素材按原比例，拉宽就变形）：靠外缘摆
		plate.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN if is_left else Control.SIZE_SHRINK_END
		if mine:
			_my_death_name = plate.get_node_or_null("Name") as Label
		else:
			_op_death_name = plate.get_node_or_null("Name") as Label
		col_box.add_child(plate)
		# 【2026-09-29·用户报「第三枚和其他的间隔不一样」】**不用容器自动排列，改成固定节距**：
		#   原来是 `HBoxContainer` + `separation = 6` ⇒ 间距由容器算，任何容器/主题/分辨率的取整
		#   都可能让它不那么整齐。现在每枚标记的 x **按节距直接算**（`i * (SLOT_D + MARK_GAP)`），
		#   结构上不可能不匀。
		# 【同日·用户报「最右边那个空圈和骷髅都太贴边了」】再给整排加一个**外缘内缩** `MARK_EDGE_PAD`：
		#   做法是把这个 pad 算进本行的宽度里、并摆在**外侧**（左行摆左边、右行摆右边）
		#   ⇒ 三枚标记整体往里挪 pad 像素，最外面那枚离屏边 12 + pad = 24px（与名字框文字边距对齐）。
		#   ⚠️ 想调间隔只改 `MARK_GAP`、想调离屏边的远近只改 `MARK_EDGE_PAD`；大小改 `DeathMark.SLOT_D`。
		var marks_row := Control.new()
		marks_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var row_w: float = float(slot_n) * DeathMark.SLOT_D + float(maxi(slot_n - 1, 0)) * MARK_GAP
		marks_row.custom_minimum_size = Vector2(row_w + MARK_EDGE_PAD, DeathMark.SLOT_D)
		# 靠外缘摆（与名字框同一侧）：左行贴左、右行贴右 —— 与名字框的 SHRINK 口径一致
		marks_row.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN if is_left \
			else Control.SIZE_SHRINK_END
		col_box.add_child(marks_row)
		# 【2026-09-29】第二行的宽度约束是**这排标志**（名字框现在各占半屏、整行铺满，
		#   拿它去算"中间还剩多少"会得出 0）⇒ `_fit_top_center()` 量这一对
		if is_left:
			_top_stack_blue = marks_row
		else:
			_top_stack_red = marks_row
		for i in slot_n:
			var mk := DeathMark.new(side_fn)
			# pad 在外侧：左行的 pad 在左（标记从 pad 处起排）、右行的 pad 在右（标记从 0 起排）
			mk.position = Vector2((MARK_EDGE_PAD if is_left else 0.0)
				+ float(i) * (DeathMark.SLOT_D + MARK_GAP), 0.0)
			marks_row.add_child(mk)
			(_my_marks if mine else _op_marks).append(mk)
	# 阵亡演出层：加在状态栏之后 ⇒ 同 z_index 下画在状态栏之上（弹窗类浮层是更晚 join 的，仍在其上）
	_death_fx = DeathFx.new()
	_death_fx.z_index = 0
	add_child(_death_fx)
	_refresh_deaths()

	# 【2026-09-29·用户要求】「暂停」→ **「菜单」**，并**搬到左下角**（原来在右上角，正好压着状态栏
	#   那两排阵亡标志）。单机点开的是同一块暂停面板（冻结整棵树），**音量控件收进面板里**
	#   （用户口径「声音集合到菜单里」⇒ `_build()` 末尾那个浮动音量键已删）。
	_pause_btn = Button.new()
	# 【2026-09-29·用户要求】「菜单」按钮换成素材 `assets/界面/菜单.png`（与「结束回合」同一套做法：
	#   图 = 按钮本体、四个状态共用同一张图、缺图时退回文字按钮）。
	var menu_tex := load(MENU_TEX) as Texture2D
	_pause_btn.text = "菜单"
	_pause_btn.add_theme_font_size_override("font_size", 15)
	_pause_btn.custom_minimum_size = Vector2(50, 30)
	if menu_tex != null:
		_pause_btn.text = ""
		var menu_w: float = MENU_IMG_H * float(menu_tex.get_width()) / float(menu_tex.get_height())
		_pause_btn.custom_minimum_size = Vector2(menu_w, MENU_IMG_H)
		var menu_states := {
			"normal": Color(1.0, 1.0, 1.0, 1.0),
			"hover": Color(1.10, 1.10, 1.10, 1.0),
			"pressed": Color(0.84, 0.84, 0.84, 1.0),
			"disabled": Color(0.55, 0.55, 0.58, 0.85),
		}
		for state in menu_states.keys():
			var sb := StyleBoxTexture.new()
			sb.texture = menu_tex
			sb.modulate_color = menu_states[state]
			_pause_btn.add_theme_stylebox_override(String(state), sb)
		# 【2026-09-29·用户报「怎么有白边」】点过之后按钮进入 focus 态，主题默认那圈**浅色描边**
		#   会画在图标外侧 ⇒ 看着就是一圈白边。图标按钮不需要焦点框 ⇒ 用空样式盖掉。
		_pause_btn.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	_pause_btn.pressed.connect(_on_pause_pressed)
	root.add_child(_pause_btn)
	_pause_btn.reset_size()
	_pause_btn.position = Vector2(12.0, vsize.y - _pause_btn.size.y - 12.0)

	# 【2026-09-28·用户要求】联机：**认输**（与「暂停/菜单」同一个尺寸 —— 联机没有暂停，
	#   两个按钮互斥显示，见 `_refresh_controls()`）。点一下先喊一句完整的话给对端，再走认输结算。
	# 【2026-09-29】随状态栏变高（名字框 + 38px 标志）**往左挪**：避开右排标志所占的
	#   `vsize.x-138 … vsize.x-12` 那条带（否则会压在标志上）。
	_surrender_btn = Button.new()
	_surrender_btn.text = "认输"
	_surrender_btn.add_theme_font_size_override("font_size", 15)
	_surrender_btn.custom_minimum_size = Vector2(50, 30)
	_surrender_btn.pressed.connect(_on_surrender_pressed)
	root.add_child(_surrender_btn)
	_surrender_btn.reset_size()
	# 【2026-09-29·用户要求「将联机的认输按钮放在红方下面，贴边」】位置 = **红方（右）那一列的下方**、
	#   贴右边缘 12px（与名字框/标志那两行的 12px 口径一致）；y = 状态栏整块底下再留 8px。
	#   ⚠️ 这一带已经贴到棋盘上沿（棋盘从 y≈101 起）⇒ 按钮下缘会压住最上面那排棋格的右上角一点点。
	_surrender_btn.position = Vector2(vsize.x - _surrender_btn.size.x - 12.0,
		NAME_PLATE_H + 1.0 + DeathMark.SLOT_D + 8.0)

	# 底部常驻按钮行：**只剩「结束回合」**（居中）。「重开 / 返回选人」整合进暂停面板（2026-09-27 用户要求）；
	#   联机的「返回大厅」也已删（2026-09-28 用户要求）⇒ 两种模式的底部行现在一样，联机退出走右上角「认输」。
	var btn_row := HBoxContainer.new()
	btn_row.position = Vector2((vsize.x - 390) / 2.0, _btn_row_y())
	btn_row.size = Vector2(390, END_BTN_IMG_H)
	btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	btn_row.add_theme_constant_override("separation", 20)
	root.add_child(btn_row)

	var end_tex := load(END_TURN_TEX) as Texture2D
	var end_btn := Button.new()
	end_btn.custom_minimum_size = Vector2(190, 52)
	end_btn.add_theme_font_size_override("font_size", 19)
	end_btn.add_theme_color_override("font_color", Color(0.1, 0.08, 0.02))
	if end_tex != null:
		# 图 = 按钮本体（文案画在图里）⇒ 清空 text；四个状态共用这张图（悬停更亮 / 按下更暗 / 禁用压暗）。
		# **不能只改 normal**：不改的话悬停·按下·禁用会掉回主题默认样式（灰蓝方块），看着像换了个按钮。
		end_btn.text = ""
		end_btn.custom_minimum_size = Vector2(
				END_BTN_IMG_H * float(end_tex.get_width()) / float(end_tex.get_height()), END_BTN_IMG_H)
		end_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		var end_states := {
			"normal": Color(1.0, 1.0, 1.0, 1.0),
			"hover": Color(1.10, 1.10, 1.10, 1.0),
			"pressed": Color(0.84, 0.84, 0.84, 1.0),
			"disabled": Color(0.55, 0.55, 0.58, 0.85),
		}
		for state in end_states.keys():
			var sb := StyleBoxTexture.new()
			sb.texture = end_tex
			sb.modulate_color = end_states[state]
			end_btn.add_theme_stylebox_override(String(state), sb)
	else:
		# 图缺失：保持原来的金色文字按钮（安全退回，不影响可玩性）
		end_btn.text = "结束回合"
		var end_sb := StyleBoxFlat.new()
		end_sb.bg_color = Color(0.75, 0.55, 0.15, 1.0)
		end_sb.corner_radius_top_left = 12
		end_sb.corner_radius_top_right = 12
		end_sb.corner_radius_bottom_left = 12
		end_sb.corner_radius_bottom_right = 12
		end_sb.set_border_width_all(2)
		end_sb.border_color = Color(1.0, 0.9, 0.5)
		end_btn.add_theme_stylebox_override("normal", end_sb)
	end_btn.pressed.connect(_on_end_turn)
	# 【2026-09-27·用户要求】结束回合**不要骰子**悬停效果（按钮本体就是那张图）。
	#   `detach()` 会打 `no_dice` 标记 ⇒ 之后重新入树/重建也不会再挂上来；重复调用无副作用。
	UiDice.detach(end_btn)
	# 【2026-09-28·用户要求】结束回合按钮放**专用**点击音（原版 `Click_EndTurn`）：
	#   先打 `no_default_click` 标记（必须早于 add_child ⇒ 全局那一声不会被挂上），再自己接一声。
	end_btn.set_meta(AudioManager.NO_DEFAULT_CLICK_KEY, true)
	end_btn.pressed.connect(func() -> void: AudioManager.play("end_turn"))
	btn_row.add_child(end_btn)
	_end_btn = end_btn

	# 【2026-09-27·用户要求】「结束按钮那行右边贴边增加一个箭头，点击后可以把替补队伍列表拉出」：
	#   与按钮带**同一水平带**（垂直居中于图片按钮），右缘留 6px 贴边；点一下拉出、再点收回。
	# 【2026-09-28·用户要求】「加了关于替补队伍的图标，你替换上去」⇒ 按钮本体换成**图片**
	#   （收起 = 「展开替补队伍.png」/ 拉出 = 「收回替补队伍.png」，两张 216×221）；
	#   图缺失时自动退回文字箭头（安全降级，不影响可玩性）。显隐由 `_refresh_team_toggle()` 管。
	_team_toggle_btn = Button.new()
	_team_toggle_btn.name = "TeamToggle"
	_team_toggle_btn.text = TEAM_TOGGLE_CLOSED
	var tog_tex := load(TEAM_TOGGLE_TEX_CLOSED) as Texture2D
	if tog_tex != null:
		_team_toggle_btn.custom_minimum_size = Vector2(
			TEAM_TOGGLE_ICON_H * float(tog_tex.get_width()) / float(tog_tex.get_height()), TEAM_TOGGLE_ICON_H)
	else:
		_team_toggle_btn.custom_minimum_size = Vector2(44, 44)
	_team_toggle_btn.add_theme_font_size_override("font_size", 20)
	_team_toggle_btn.pressed.connect(_on_team_toggle)
	root.add_child(_team_toggle_btn)
	_apply_team_toggle_icon(false)
	_team_toggle_btn.reset_size()
	_team_toggle_btn.position = Vector2(vsize.x - _team_toggle_btn.size.x - 6.0,
		_btn_row_y() + (END_BTN_IMG_H - _team_toggle_btn.size.y) * 0.5)
	_refresh_team_toggle()

	# 【2026-09-27 用户报「刚进录像会有黄色字体弹出，被蓝方回合盖住」】建顶栏时就分清是不是回放局：
	#   回放局一进来就直接写"第 N 回合"，**不留那一帧**黄色对局文案（`_set_round_text(1, true)`
	#   会先写成"第 1 回合 · 你的回合"，回放里那句话既不对、又会被随后的横幅盖住 → 一闪而过看着很脏）。
	# 【2026-09-29·用户要求「中间那个『敌方回合 / 你的回合』字样去掉」】这里同样只留"第 N 回合"
	#   （回放里那种"蓝方回合/红方回合"也不写了；谁在行动看中间这行的颜色 + 换段横幅）。
	if GameState.replay_id != "":
		_round_label.text = "第 %d 回合" % GameState.round_number
		# 【2026-09-29·用户要求「状态栏中间的用黄色」】回放第一帧的颜色也统一成黄色
		_round_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.5))
		_top_fit_key = ""
		_fit_top_center()
	else:
		_set_round_text(1, true)
	_refresh_controls()
	_build_edge_warning(root, vsize)

	# 【2026-09-28·用户要求】「将音量键移到右上角，**暂停左边**」：与「暂停」（联机时那一格是「认输」）
	#   同一行、放在它**左边 8px**、垂直居中；弹层仍在按钮**下方**自动弹出（`_open_panel()` 里那条
	#   "放不下就向上弹"的逻辑照旧兜底）。原来它在右下角（`place_bottom_right`）。
	# 【2026-09-29·用户要求「声音集合到菜单里」】战斗界面的**浮动音量键删掉** —— 音量控件现在
	#   由「菜单」面板里那个 `VolumeControl` 提供（见 `_on_pause_pressed()`）。菜单键本身在**左下角**，
	#   与联机的「喊话」键同一角落（喊话在它右边，见 `_build_chat_button`）。

	# 左下角"喊话"按钮(仅联机对战中显示)
	_build_chat_button(root, vsize)

	# 【2026-09-28·用户要求·击杀演出】击杀特效层：**最后 add_child** ⇒ 同 z 下画在按钮/常驻面板之上；
	#   结算面板是更晚 join 的 ⇒ 仍在它下面（与 `_death_fx` 同一个道理）；只画特效、不接输入。
	_kill_fx = Control.new()
	_kill_fx.set_anchors_preset(Control.PRESET_FULL_RECT)
	_kill_fx.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_kill_fx)

# 屏幕边缘警告层：容器内四条浅红半透明边条；回合剩余时间不足时整体呼吸闪烁
func _build_edge_warning(root: Control, vsize: Vector2) -> void:
	_warn_holder = Control.new()
	_warn_holder.set_anchors_preset(Control.PRESET_FULL_RECT)
	_warn_holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_warn_holder.visible = false
	root.add_child(_warn_holder)
	var edge := 24.0   # 边缘条厚度
	# 【2026-09-21 修·四个角红色重叠】原来上/下两条是**整屏宽**、左/右两条是**整屏高** ⇒
	# 四个角各被"横条 + 竖条"叠了两次，alpha 0.5 叠成 0.75，四个角出现更深的红方块（用户报的现象）。
	# 现在左/右两条只占**扣掉上下条之后**的那段高度：四角不叠、也不留缝，整圈 alpha 一致。
	var mid_h := maxf(vsize.y - edge * 2.0, 0.0)
	var bars := [
		[Vector2(0, 0), Vector2(vsize.x, edge)],               # 上
		[Vector2(0, vsize.y - edge), Vector2(vsize.x, edge)],  # 下
		[Vector2(0, edge), Vector2(edge, mid_h)],              # 左（避开上下条，不再压角）
		[Vector2(vsize.x - edge, edge), Vector2(edge, mid_h)],  # 右（同上）
	]
	for b in bars:
		var rect := ColorRect.new()
		rect.color = Color(1.0, 0.3, 0.28, 0.5)
		rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		rect.position = b[0]
		rect.size = b[1]
		_warn_holder.add_child(rect)

func _make_panel(bg: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.corner_radius_top_left = 10
	sb.corner_radius_top_right = 10
	sb.corner_radius_bottom_left = 10
	sb.corner_radius_bottom_right = 10
	return sb

# ================= 联机快捷喊话 =================
# 左下角按钮:点开预置言论面板(嘲讽/友好各几条),点选后发给对端;
# 收到对端喊话时在顶部状态栏(回合栏)下方弹气泡条,短暂停留后自动淡出。
const _CHAT_TAUNTS := [
	"就这？",
	"投降吧，没机会了",
	"这步走得不太行哦",
	"嘿嘿，别跑呀",
	"胜负已定！",
	"快点吧，我等的花儿都谢了",
]
const _CHAT_FRIENDLY := [
	"打得不错！",
	"好险好险，精彩",
	"交个朋友，切磋愉快",
	"运气不错哈哈",
	"GG 打得漂亮",
]

func _build_chat_button(root: Control, vsize: Vector2) -> void:
	if not GameState.is_online:
		return
	var btn := Button.new()
	# 【2026-09-28·用户要求】喊话按钮：有「喊话.png」就用图标本体（44×44），没有才退回文字按钮
	var chat_ic := load(CHAT_ICON) as Texture2D
	if chat_ic != null:
		btn.icon = chat_ic
		btn.expand_icon = true                       # 图标铺满按钮（54×51 的图按比例缩放）
		btn.custom_minimum_size = Vector2(44, 44)
		# 【2026-09-28·用户报「喊话图标有两个重叠」】图标是**带白底的方形图**，压在深色圆角底板上
		#   会看成"两块叠着"（白方块 + 圆角底板）。与名片按钮同一口径：**去掉底板与边框**，只留图标
		#   （normal/hover/pressed/focus/disabled 五个状态全套 StyleBoxEmpty）。
		btn.flat = true
		for st in ["normal", "hover", "pressed", "focus", "disabled"]:
			btn.add_theme_stylebox_override(st, StyleBoxEmpty.new())
	else:
		btn.text = "喊话"
		btn.custom_minimum_size = Vector2(76, 44)
		btn.add_theme_font_size_override("font_size", 16)
	if chat_ic == null:
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0.16, 0.18, 0.26, 0.92)
		sb.corner_radius_top_left = 10
		sb.corner_radius_top_right = 10
		sb.corner_radius_bottom_left = 10
		sb.corner_radius_bottom_right = 10
		sb.border_color = Color(0.6, 0.7, 1.0, 0.5)
		sb.set_border_width_all(1)
		btn.add_theme_stylebox_override("normal", sb)
	btn.pressed.connect(_toggle_chat_panel)
	btn.position = Vector2(10, vsize.y - 56 - 10)
	root.add_child(btn)
	_chat_btn = btn

func _toggle_chat_panel() -> void:
	if _chat_panel != null and is_instance_valid(_chat_panel):
		_close_chat_panel()
		return
	var vsize := get_viewport().get_visible_rect().size
	# 全屏透明层：点"面板以外"的任意位置即收起（面板内的点击由面板/按钮自己吃掉，不会传到这一层）
	var overlay := Control.new()
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	overlay.gui_input.connect(_on_chat_overlay_input)
	add_child(overlay)
	_chat_overlay = overlay
	var panel := PanelContainer.new()
	# 面板外观走主题里的"弹出框边框"（theme/panel_frame_dark.png）
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 4)
	panel.add_child(v)
	var add_group := func(title: String, color: Color, items: Array):
		var lbl := Label.new()
		lbl.text = title
		lbl.add_theme_font_size_override("font_size", 13)
		lbl.add_theme_color_override("font_color", color)
		v.add_child(lbl)
		for txt in items:
			var b := Button.new()
			b.text = txt
			b.custom_minimum_size = Vector2(200, 34)
			b.add_theme_font_size_override("font_size", 15)
			b.add_theme_color_override("font_color", Color(0.95, 0.95, 1.0))
			var bs := StyleBoxFlat.new()
			bs.bg_color = Color(0.2, 0.22, 0.32, 0.95)
			bs.corner_radius_top_left = 8
			bs.corner_radius_top_right = 8
			bs.corner_radius_bottom_left = 8
			bs.corner_radius_bottom_right = 8
			b.add_theme_stylebox_override("normal", bs)
			b.pressed.connect(func():
				_send_chat(String(b.text)))
			v.add_child(b)
	add_group.call("嘲讽", Color(1.0, 0.55, 0.5), _CHAT_TAUNTS)
	add_group.call("友好", Color(0.5, 0.9, 0.6), _CHAT_FRIENDLY)
	var pw := 220.0
	overlay.add_child(panel)
	_chat_panel = panel   # 先登记：连点两下"喊话"不会叠出第二个面板
	await get_tree().process_frame
	if not is_instance_valid(panel):   # 这一帧内已被收起（点外部/切阶段）：不再定位
		return
	# 面板尺寸与定位用**同一个高度**：先按内容最小高度定死尺寸，再以它往上推，
	# 保证面板底边永远停在"喊话"按钮上沿之上（按钮高度受主题内边距影响，不硬编码）。
	var pmin := panel.get_combined_minimum_size()
	panel.size = Vector2(maxf(pw, pmin.x), pmin.y)
	var btn_top := vsize.y - 56.0 - 10.0
	if _chat_btn != null and is_instance_valid(_chat_btn):
		btn_top = _chat_btn.position.y
	panel.position = Vector2(10, maxf(6.0, btn_top - pmin.y - 6.0))

func _send_chat(txt: String) -> void:
	_close_chat_panel()
	if battle != null and is_instance_valid(battle):
		battle.send_quick_chat(txt)
		_show_chat_bubble(txt, true)   # 自己发的喊话本端也立刻回显（我方侧），不必等对端

func _close_chat_panel() -> void:
	if _chat_panel != null and is_instance_valid(_chat_panel):
		_chat_panel.queue_free()
	_chat_panel = null
	if _chat_overlay != null and is_instance_valid(_chat_overlay):
		_chat_overlay.queue_free()
	_chat_overlay = null

# 点选言面板以外的任意位置（全屏层拦到）即收起。
# 与音量弹层一致：只处理鼠标左键——触摸在安卓/iOS 由 Godot 转成鼠标事件，再判触摸会双触发。
func _on_chat_overlay_input(ev: InputEvent) -> void:
	var mb := ev as InputEventMouseButton
	if mb == null or not mb.pressed or mb.button_index != MOUSE_BUTTON_LEFT:
		return
	_close_chat_panel()

# 收到对端喊话 -> 对方气泡（顶部回合栏下方、靠敌方侧）
func _show_peer_chat(txt: String) -> void:
	_show_chat_bubble(txt, false)

# 喊话气泡：`own=true` = 本端发出、`own=false` = 对端喊话。
# 【2026-09-29·用户报「主机的喊话，在客房视角，跑到客房自己那一侧弹出」】气泡按**说话方的绝对阵营**摆：
#   **蓝方（PLAYER）贴左 · 红方（ENEMY）贴右** —— 与顶部名字框的左右口径完全一致（左蓝框右红框、
#   骷髅槽同理）。原来写死"自己=左、对端=右"，那是**主机视角**：客房是红方 ⇒ 自己喊话跑到左边
#   （对端名字框那一侧）、对端（主机）喊话跑到右边（自己名字框那一侧），正好反过来。
#   底色/描边/字色同样按"说话方是蓝还是红"给，两端看到的颜色与棋盘阵营色一致。
func _show_chat_bubble(txt: String, own: bool) -> void:
	if txt == "":
		return
	if _chat_bubble_tween != null and _chat_bubble_tween.is_valid():
		_chat_bubble_tween.kill()
	if _chat_bubble != null and is_instance_valid(_chat_bubble):
		_chat_bubble.queue_free()
	var vsize := get_viewport().get_visible_rect().size
	var my_fn: int = battle._my_faction() if battle != null else DataRegistry.Faction.PLAYER
	var speaker_fn: int = my_fn if own else (DataRegistry.Faction.ENEMY if my_fn == DataRegistry.Faction.PLAYER else DataRegistry.Faction.PLAYER)
	var is_blue: bool = speaker_fn == DataRegistry.Faction.PLAYER
	var bubble := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.1, 0.16, 0.24, 0.94) if is_blue else Color(0.24, 0.1, 0.12, 0.94)
	sb.corner_radius_top_left = 12
	sb.corner_radius_top_right = 12
	sb.corner_radius_bottom_left = 12
	sb.corner_radius_bottom_right = 12
	sb.content_margin_left = 16.0
	sb.content_margin_right = 16.0
	sb.content_margin_top = 8.0
	sb.content_margin_bottom = 8.0
	sb.border_color = Color(0.5, 0.85, 1.0, 0.9) if is_blue else Color(1.0, 0.4, 0.35, 0.9)
	sb.set_border_width_all(2)
	bubble.add_theme_stylebox_override("panel", sb)
	bubble.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var label := Label.new()
	label.text = txt
	label.add_theme_font_size_override("font_size", 26)
	label.add_theme_color_override("font_color", Color(0.85, 0.95, 1.0) if is_blue else Color(1.0, 0.78, 0.72))
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	label.add_theme_constant_override("outline_size", 4)
	label.custom_minimum_size = Vector2(0, 40)
	bubble.add_child(label)
	add_child(bubble)
	_chat_bubble = bubble
	await get_tree().process_frame
	var bs := bubble.get_combined_minimum_size()
	bubble.size = bs
	# 状态栏**整块**（名字框 34 + 间 1 + 标志槽 38 = 73）下方弹气泡；**按说话方的绝对阵营贴边**：
	#   蓝方贴左 12px、红方贴右 12px（与顶部名字框/骷髅槽的左右口径一致）。
	#   【2026-09-29·用户报「联机模式喊话的弹框有点挡住死亡标志了」】原来写死 y=62 —— 那是"状态栏 54 高"
	#   年代的值；状态栏改成两行（73）之后，62 正好压在**第二行那排阵亡标志**上 ⇒ 改成按状态栏底边算
	#   （`NAME_PLATE_H + 1 + DeathMark.SLOT_D`）再留 8px。
	var status_bottom: float = NAME_PLATE_H + 1.0 + DeathMark.SLOT_D
	bubble.position = Vector2(maxf(6.0, 12.0 if is_blue else vsize.x - bs.x - 12.0), status_bottom + 8.0)
	bubble.modulate.a = 0.0
	var t := create_tween()
	_chat_bubble_tween = t
	t.tween_property(bubble, "modulate:a", 1.0, 0.18)
	t.tween_interval(2.6)
	t.tween_property(bubble, "modulate:a", 0.0, 0.4)
	# 【2026-09-29·同横幅那条】气泡也可能在补间跑完前被换掉/释放 ⇒ 捕获走 WeakRef
	var w_bubble: WeakRef = weakref(bubble)
	t.tween_callback(func():
		var b: Object = w_bubble.get_ref()
		if b != null:
			(b as Node).queue_free()
		if _chat_bubble != null and not is_instance_valid(_chat_bubble):
			_chat_bubble = null)

## 【2026-09-27·录像回放】刷新顶部"第 N 回合 · 蓝方/红方回合"。回放里没有 `round_changed`／
## `active_side_changed` 这些信号（`_refresh_round()` 因此不会自己重画），换段/跳段后由 Battle 喊一次。
func refresh_round_label() -> void:
	# 【2026-09-28 护栏·用户贴的报错】`_set_round_text()` 末尾会 `_fit_top_center()`（里面用
	#   `get_viewport()`）；HUD 已经离开场景树时（正在切场景 / 已被释放）那是 null ⇒
	#   `Cannot call method 'get_visible_rect' on a null value`。这里直接不画。
	if not is_inside_tree():
		return
	_set_round_text(GameState.round_number, true)

## 【2026-09-28·用户报「联机对战中，主机是蓝方，客房是红方。现在状态栏有点混乱」】
##   状态栏的颜色一律按**绝对阵营**给（不再用"我方=蓝 / 敌方=红"）：PLAYER = 蓝 · ENEMY = 红 ——
##   与棋盘上棋子描边（`Unit._faction_color`）、出生区色罩同一套口径。
##   联机时主机 = PLAYER = 蓝、客房 = ENEMY = 红；单机/自由部署双控里本端 = PLAYER ⇒ 与改动前逐位相同。
func _faction_ui_color(fn: int) -> Color:
	if fn == DataRegistry.Faction.PLAYER:
		return Color(0.5, 0.85, 1.0)
	return Color(1.0, 0.5, 0.5)

func _set_round_text(round_num: int, _player_side: bool) -> void:
	# 【2026-09-29 消警告 `UNUSED_VARIABLE`】这里原来有一段 `my_turn`（"本端是不是当前行动方"），
	#   只服务于旧文案「你的回合 / 敌方回合」；那套文案按用户要求删掉之后它就没人读了 ⇒ 整段删除
	#   （连 `dual_control` / `active_side` 那两处读取一起去掉，逻辑零变化）。
	# 非回合阶段（开局部署/竞技场选人/卡组三选一/替补中）只显示阶段名：
	var phase_txt := ""
	if battle != null and is_instance_valid(battle) and not _in_replay():
		if battle.state == Battle.State.ARENA_DRAFT:
			phase_txt = "竞技场选人"
		elif battle.state == Battle.State.DECK_PICK:
			phase_txt = "选择卡组"
		elif battle.state == Battle.State.DEPLOY or battle.state == Battle.State.PLACE_DEPLOY:
			phase_txt = "部署选人"
		elif battle.state == Battle.State.SUBSTITUTING or battle.state == Battle.State.PLACE_SUB:
			phase_txt = "替补"
	var side := phase_txt
	# 【2026-09-29·用户要求「状态栏中间的用黄色」】正中这行的颜色**恒为黄色**（不再按"当前行动方"
	#   或"本端/对端"上色）⇒ 原来那套 `color_side` 判定已无用、整块删掉。
	if _in_replay():
		# 回放：按**正在播的那一段**判（`active_side` 是录像里的值，不能用）
		var rs: int = battle.replay_side_of(battle._replay_frame)
		if rs < 0:
			# 【2026-09-28 用户报「部署阶段的提示有问题」】部署那一帧（side = -1）不是任何一方的回合
			side = "部署"
	# 【2026-09-29·用户要求】「部署英雄就不要显示第 1 回合了」+「选择卡组也不要第 1 回合」+「竞技场选人也去掉」：
	#   这三个阶段**回合都还没开始**（第 1 回合要等双方卡组/首发都定下、报完"战斗开始"才走）
	#   ⇒ 只写阶段名，**不带"第 N 回合"前缀**；回放里部署那一帧同理（那边 `side` = "部署"）。
	if side == "部署选人" or side == "部署" or side == "选择卡组" or side == "竞技场选人":
		_round_label.text = side
	else:
		_round_label.text = "第 %d 回合%s" % [round_num, (" · " + side) if side != "" else ""]
	# 【2026-09-29·用户要求「状态栏中间的用黄色」】正中那行（回合数 / 阶段名）恒用**黄色**，
	#   不再按当前行动方的阵营蓝/红上色（谁在行动看下面的计时器与换段横幅就够了）。
	var normal_color := Color(1.0, 0.85, 0.5)
	_round_label.add_theme_color_override("font_color", normal_color)
	# 扣血阶段视觉提醒：进入超回合扣血（当前测试：第 1 回合起）后，回合标签"燃烧"+火焰图标常驻脉动。
	var burning := GameState.should_apply_round_damage() and GameState.match_running and not GameState.match_over
	if _flame_icon != null:
		_flame_icon.visible = burning
	if burning:
		_start_round_fire()
	else:
		_stop_round_fire(normal_color)
	_top_fit_key = ""          # 文字/火焰都变了 ⇒ 强制重算一次中间那组的字号
	_fit_top_center()

## 【2026-09-29·用户要求】"名字框 + 框内居中名字"：框是素材（`蓝方名字框.png` / `红方名字框.png`），
##   名字写在框里。返回外框 `Control`，里面的 `Label` 命名为 `Name`（"我方/敌方"由它显示，
##   联机换真名那条路仍改它的 `text` —— 见 `_refresh_deaths()` 里那两处 `_my_death_name.text = ...`）。
##   尺寸：高固定 `NAME_PLATE_H`、宽按原图比例（237×203 ⇒ 约 1.17 倍高）⇒ 不会拉伸变形。
func _make_name_plate(tex: Texture2D, txt: String, col: Color, font_size: int, w_override: float = -1.0,
		# 【2026-09-29·用户贴的 `INT_AS_ENUM_WITHOUT_CAST`】原来标注成 `int` ⇒ 赋给
		#   `lb.horizontal_alignment`（枚举 `HorizontalAlignment`）时报警 ⇒ 参数直接标成枚举类型。
		align: HorizontalAlignment = HORIZONTAL_ALIGNMENT_CENTER) -> Control:
	var h := NAME_PLATE_H
	# 【2026-09-29·用户要求「将名字框延伸到画面中间，两边一样长」】宽度不再按素材比例，而是**外部给定**
	#   （左右两条等长、各占半屏）；不给就仍按原图比例（老口径）。
	var w := w_override if w_override > 0.0 else h * float(tex.get_width()) / float(tex.get_height())
	var box := Control.new()
	box.custom_minimum_size = Vector2(w, h)
	box.size = Vector2(w, h)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	# 【2026-09-29·用户贴的 `SHADOWED_VARIABLE_BASE_CLASS`】这里原来叫 `tr` ⇒ 遮蔽了 `Object.tr()`
	#   （翻译函数），每次加载脚本都报一条警告 ⇒ 改名 `plate_bg`，只是换名字、行为不变。
	var plate_bg := TextureRect.new()
	plate_bg.texture = tex
	plate_bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	plate_bg.stretch_mode = TextureRect.STRETCH_SCALE
	plate_bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	plate_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(plate_bg)
	var lb := Label.new()
	lb.name = "Name"
	lb.text = txt
	lb.add_theme_font_size_override("font_size", font_size)
	lb.add_theme_color_override("font_color", col)
	lb.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	lb.add_theme_constant_override("outline_size", 3)
	lb.horizontal_alignment = align
	lb.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lb.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# 【2026-09-29·用户要求「状态栏上双方的名字都贴边显示」】名字不再框内居中，而是**贴外缘**：
	#   左框（蓝方）靠左、右框（红方）靠右；离框边留 `NAME_EDGE_PAD` 免得压在框沿的花纹上。
	if align == HORIZONTAL_ALIGNMENT_LEFT:
		lb.offset_left += NAME_EDGE_PAD
	elif align == HORIZONTAL_ALIGNMENT_RIGHT:
		lb.offset_right -= NAME_EDGE_PAD
	lb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(lb)
	return box

## 【2026-09-27·用户报「战斗中状态栏在 11 回合后，显示会挤到一起」】顶部中间那组
##   （`第 N 回合 · 阵营` + 火焰 + 剩余时间）是**整条居中**排的，而左右两侧的阵亡计数行是**绝对定位**
##   （左侧从 x=12 起排、右侧贴右缘）⇒ 三件事叠加后中间这组会压到两侧：
##     ① 回合数变成两位数（第 10 回合起多一个字）② **第 11 回合火焰亮起**（+34px）③ 剩余时间也在这组里。
##   这里按"两侧行的**实际内容宽度**"算出中间还剩多少，再**逐档缩字号**（24 → 22 → 20 → 18）、
##   必要时把火焰收小，直到放得下。⚠️ 纯布局：**不改任何文案**（不给自己加字/减字）。
##   很便宜，但没必要每帧算 ⇒ 用 `_top_fit_key`（文字+火焰状态）挡重复调用。
func _fit_top_center() -> void:
	if _round_label == null or not is_instance_valid(_round_label):
		return
	var flame_on: bool = _flame_icon != null and is_instance_valid(_flame_icon) and _flame_icon.visible
	var timer_on: bool = _turn_timer_label != null and is_instance_valid(_turn_timer_label) and _turn_timer_label.visible
	var key := "%s|%s|%s|%.0f" % [_round_label.text, (_turn_timer_label.text if timer_on else ""),
		str(flame_on), get_viewport().get_visible_rect().size.x]
	if key == _top_fit_key:
		return
	_top_fit_key = key
	var vsize := get_viewport().get_visible_rect().size
	var lw := 0.0
	var rw := 0.0
	# 【2026-09-29·两行布局】两侧各是一个**竖排栈**（名字框 + 下面那排标志）
	#   ⇒ 量栈的总宽（原来量的是 `_my_death_name` 的父亲 = 名字框自己，现在那只是栈里一格，
	#     会漏掉下面那排 3 枚标志的宽度，中间那组就会压上去）；同时左/右与"我/对"解耦
	#     （联机客房里"我方"在右边，按我/对取宽会把左右量反）。
	if _top_stack_blue != null and is_instance_valid(_top_stack_blue):
		lw = _top_stack_blue.get_combined_minimum_size().x
	if _top_stack_red != null and is_instance_valid(_top_stack_red):
		rw = _top_stack_red.get_combined_minimum_size().x
	var avail := vsize.x - lw - rw - 28.0        # 两侧各留 12px 起排缝 + 4px 余量
	var sep := 4.0
	if _round_label.get_parent() is HBoxContainer:
		sep = float((_round_label.get_parent() as HBoxContainer).get_theme_constant("separation"))
	var font := _round_label.get_theme_font("font")
	var outline := float(_round_label.get_theme_constant("outline_size"))
	var need := func(fs: int, fw: float) -> float:
		var w := font.get_string_size(_round_label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x + outline * 2.0
		if flame_on:
			w += sep + fw
		if timer_on:
			# 【2026-09-29·用户报「回合数随着计时器出现上上下下」】计时器现在在**自己那一行**
			#   ⇒ 它不再跟回合数抢宽度；宽度取"两行里较宽的那行"即可。原来按**横排相加**算 ⇒
			#   计时器一出现就判定"放不下"、把回合数字号缩一档 ⇒ 字号一变，视觉上就是上下跳。
			var tf := _turn_timer_label.get_theme_font("font")
			var tw := tf.get_string_size(_turn_timer_label.text, HORIZONTAL_ALIGNMENT_LEFT, -1,
				_turn_timer_label.get_theme_font_size("font_size")).x
			w = maxf(w, tw)
		return w
	var fs_use := 18
	for fs in [24, 22, 20, 18]:
		if float(need.call(int(fs), 34.0)) <= avail:
			fs_use = int(fs)
			break
	_round_label.add_theme_font_size_override("font_size", fs_use)
	if flame_on:
		var fw := 34.0
		if float(need.call(fs_use, fw)) > avail:
			fw = 26.0
		if float(need.call(fs_use, fw)) > avail:
			fw = 20.0
		_flame_icon.custom_minimum_size = Vector2(fw, fw)
		_flame_icon.size = Vector2(fw, fw)
		_flame_icon.set("size_px", fw * 0.76)

# ---- 回合标签"燃烧"效果（第 11 回合起）----

# 让"第 x 回合 · 你的回合"文字按火焰色循环跳动 + 暗火色描边
func _start_round_fire() -> void:
	if _round_fire_tween != null and _round_fire_tween.is_valid():
		return   # 已在燃烧，不重复开
	_round_label.add_theme_constant_override("outline_size", 8)
	_round_label.add_theme_color_override("font_outline_color", Color(0.5, 0.1, 0.0))
	var cols := [
		Color(1.0, 0.98, 0.55),   # 亮黄（焰芯）
		Color(1.0, 0.62, 0.12),   # 橙（焰中）
		Color(1.0, 0.32, 0.05),   # 赤红（焰底）
	]
	var t := create_tween().set_loops()
	_round_fire_tween = t
	for i in cols.size():
		t.tween_method(_apply_round_fire_color, cols[i], cols[(i + 1) % cols.size()], 0.22)

func _apply_round_fire_color(c: Color) -> void:
	if _round_label != null and is_instance_valid(_round_label):
		_round_label.add_theme_color_override("font_color", c)

func _stop_round_fire(restore: Color) -> void:
	if _round_fire_tween != null:
		if _round_fire_tween.is_valid():
			_round_fire_tween.kill()
		_round_fire_tween = null
	_round_label.add_theme_constant_override("outline_size", 0)
	_round_label.add_theme_color_override("font_color", restore)

func _refresh_round() -> void:
	_set_round_text(GameState.round_number, GameState.active_side == GameState.SIDE_PLAYER)

# GameState 回合信号回调（对象方法，便于释放时自动断开）
func _on_round_changed(_r: int) -> void:
	_refresh_round()

# 阵亡计数图标（骷髅）= 已阵亡，空心圆 = 尚未阵亡
# 【2026-09-23 改·用户要求】"标志出现"的时机 = **卡面飞行的卡片落地那一刻**，不是死亡瞬间：
#   真实阵亡数（战斗逻辑，判负/替补都读它）先涨 ⇒ 这里把它记进 `_reveal_pending`，
#   由 `_on_unit_dying` 播的 DeathFx 在落地回调里 `_reveal_mark()` 才点亮槽 + 摇晃。
#   ⚠️ headless（跑批/无窗口）不发 `dying`、也不会有 pending ⇒ 本函数立刻就点亮，**与改动前逐位一致**。
#   视角化与原来一致：联机客户端左右对调（用 `battle._my_dead()/_opp_dead()`，它们已经做过视角映射）。
func _refresh_deaths() -> void:
	if battle == null:
		return
	var my_dead: int = battle._my_dead()
	var op_dead: int = battle._opp_dead()
	# 重开/新局/被清零：槽位与 pending 一起归位（否则会残留上一局的骷髅）
	# ⚠️ 判据只看**已点亮**的槽数（不看 pending）：死亡瞬间 `dying` 会把 pending +1，而真实计数要
	#   0.3s 后才涨（`died`）⇒ 若把 pending 算进来，这 0.3s 里就会误判成"被清零"、把 pending 抹掉。
	if my_dead < int(_mark_filled["my"]):
		_reveal_pending["my"] = 0
		_set_marks_filled("my", my_dead)
	if op_dead < int(_mark_filled["op"]):
		_reveal_pending["op"] = 0
		_set_marks_filled("op", op_dead)
	# 真实数 > 已点亮 + 待点亮 ⇒ 多出来的先挂 pending（等特效落地；特效不存在时下一行会立刻补上）
	if my_dead > int(_mark_filled["my"]) + int(_reveal_pending["my"]):
		_reveal_pending["my"] = my_dead - int(_mark_filled["my"])
	if op_dead > int(_mark_filled["op"]) + int(_reveal_pending["op"]):
		_reveal_pending["op"] = op_dead - int(_mark_filled["op"])
	# 没有特效在飞的（headless / 特效被跳过 / 场景刚恢复）⇒ 立刻补齐，别让标志一直不出现
	if _death_fx == null or not is_instance_valid(_death_fx) or _death_fx.get_child_count() == 0:
		while int(_reveal_pending["my"]) > 0:
			_reveal_mark("my", false)
		while int(_reveal_pending["op"]) > 0:
			_reveal_mark("op", false)
	# 【2026-09-29·用户要求】「我方名字用联机的名字。单机敌方用难度+AI」⇒
	#   左侧（我方）= **名片名**（`Stats.display_name()`，联机与单机都用它，空则退回"我方"）；
	#   右侧 = 联机时是对端姓名（没发姓名写"对方"），**单机时是「难度 + AI」**（如「噩梦AI」）。
	var my_txt := Stats.display_name()
	if my_txt.strip_edges() == "":
		my_txt = "我方"
	var op_txt := "敌方"
	if GameState.is_online:
		op_txt = GameState.net_peer_name if GameState.net_peer_name != "" else "对方"
	else:
		var d: int = clampi(GameState.ai_difficulty, 0, AI_DIFF_NAMES.size() - 1)
		op_txt = "%sAI" % AI_DIFF_NAMES[d]
	if my_txt != _last_my_text and _my_death_name != null:
		_my_death_name.text = my_txt
		_last_my_text = my_txt
	if op_txt != _last_op_text and _op_death_name != null:
		_op_death_name.text = op_txt
		_last_op_text = op_txt

# 直接把某侧槽位按真实数归位（不播摇晃；重开/新局/读档恢复时用）
func _set_marks_filled(side: String, n: int) -> void:
	var marks: Array = _my_marks if side == "my" else _op_marks
	for i in marks.size():
		var mk: DeathMark = marks[i]
		if mk != null and is_instance_valid(mk):
			mk.set_filled(i < n)
	_mark_filled[side] = clampi(n, 0, marks.size())

# 点亮一个槽（`shake` = 播"标志出现 + 摇晃"；headless/补账时传 false 只置位）
func _reveal_mark(side: String, shake := true) -> void:
	var marks: Array = _my_marks if side == "my" else _op_marks
	var idx := int(_mark_filled[side])
	if idx < 0 or idx >= marks.size():
		_reveal_pending[side] = 0
		return
	var mk: DeathMark = marks[idx]
	_mark_filled[side] = idx + 1
	_reveal_pending[side] = maxi(int(_reveal_pending[side]) - 1, 0)
	if mk == null or not is_instance_valid(mk):
		return
	mk.set_filled(true)
	if shake:
		mk.pop_and_shake()

# 取该侧"下一个要出现的"标记槽（DeathFx 用它当飞行终点；槽还没出现也能拿到位置 ✓ 固定尺寸）
func _next_mark(side: String) -> Control:
	var marks: Array = _my_marks if side == "my" else _op_marks
	var idx := int(_mark_filled[side]) + int(_reveal_pending[side])
	if idx < 0 or idx >= marks.size():
		idx = marks.size() - 1
	if idx < 0:
		return null
	return marks[idx]

# 【2026-09-23 新增·用户要求】死亡瞬间：播"卡面破碎升天 → 飞向顶部阵亡标志 → 标志出现并摇晃"。
#   阵营 → 左/右那排标记：用 `battle._my_faction()`（联机客户端自动左右对调，与 `_refresh_deaths` 同口径）。
#   召唤物（骷髅兵等）：`DataRegistry.summons.has()` ⇒ 只破碎升天、不占阵亡标志位（传 target=null）。
func _on_unit_dying(u: Unit) -> void:
	if u == null or not is_instance_valid(u):
		return
	if _death_fx == null or not is_instance_valid(_death_fx):
		return
	var side := "my" if u.faction == battle._my_faction() else "op"
	var is_summon: bool = DataRegistry.summons.has(u.hero_id)
	# 死亡位置 → 屏幕坐标（单位在世界画布上；HUD 这一层没有位移 ⇒ 可直接当本层坐标用）
	var start: Vector2 = u.get_global_transform_with_canvas().origin
	# 【2026-09-28·联机状态栏】阵亡演出（破碎粒子 + 飞行小卡）的颜色也按**死者自己的绝对阵营**给：
	#   原来写死"我方=蓝"，联机客房（红方）自己的阵亡演出会是蓝的（用户报的同类问题）。
	var col := _faction_ui_color(u.faction)
	var target: Control = null if is_summon else _next_mark(side)
	# pending 先 +1：真实计数马上会涨（`_on_unit_died` 在 0.3s 后），这样 `_refresh_deaths` 不会提前点亮
	if not is_summon:
		_reveal_pending[side] = int(_reveal_pending[side]) + 1
	if _death_fx == null or not is_instance_valid(_death_fx):
		return
	var fx := DeathFx.new()
	_death_fx.add_child(fx)
	fx.play(start, target, col, func(): _reveal_mark(side, true))

# 【2026-09-28·用户要求】击杀演出：**开打前的预告** —— 把击杀者的卡面滑进画面正中停一下、再冲出去，
#   身后拖一条**阵营色**拖影（我方蓝 / 敌方红，与棋子阵营底色同一组色；按**绝对阵营**取，不由视角翻转）。
#   触发点 = `Battle.kill_intro_requested`（Battle 预判这一击致死时发的**预告**，普攻与反击各一处）；
#   播完必须回一个 `battle.kill_intro_finished()` —— Battle 一直在等它，等到才继续前冲/开火/结算
#   ⇒ 观感是"击杀特效滑完（图案彻底消失）→ 英雄再动手击杀对方"。
#   ⚠️ 纯演出：不读不改任何战斗状态；headless 在 `KillFx.play()` 里直接短路并立刻回调（跑批零开销）。
func _on_kill_intro(killer: Unit, _victim: Unit) -> void:
	var done := func():
		if battle != null and is_instance_valid(battle):
			battle.kill_intro_finished()
	if killer == null or not is_instance_valid(killer) or _kill_fx == null or not is_instance_valid(_kill_fx):
		done.call()   # 没得演也要放行，否则 Battle 要等到兜底超时
		return
	var tex: Texture2D = DataRegistry.hero_card_art(killer.display_name)
	if tex == null or DisplayServer.get_name() == "headless":
		done.call()
		return
	var col := Color(0.25, 0.55, 0.9) if killer.faction == DataRegistry.Faction.PLAYER else Color(0.85, 0.32, 0.28)
	var fx := KillFx.new()
	_kill_fx.add_child(fx)
	# 连杀/群杀：每张往上/往下错开一点（幅度 = 屏高的 6%），避免完全重叠
	var off := float(_kill_fx_n % 3 - 1) * 0.06
	_kill_fx_n += 1
	fx.play(tex, col, off, done)   # 播完回调 → Battle 放行，英雄随后才动手击杀

func _process(_dt: float) -> void:
	_refresh_deaths()
	_refresh_controls()
	# 检测战斗阶段切换（替补落位完成/部署完成/回输入态等）→ 补刷新顶部"第X回合·阶段"标签。
	# 阶段是本地状态机、无专门信号：仅在真正变化时刷新一次，避免每帧重写。
	if battle != null and is_instance_valid(battle):
		var st: int = battle.state
		# 【2026-09-28·用户报「选英雄上场后替补队伍没移除那个英雄」】部署期盯卡池指纹：
		#   上阵时 Battle 已经把英雄从池子里扣掉了（player_pool.erase），但面板未必被重建 ⇒ 这里兜一下。
		if st == Battle.State.DEPLOY or st == Battle.State.PLACE_DEPLOY:
			var dk := "%d|%s|%s|%d" % [battle._my_deploy_pool().size(), str(battle._pending_deploy), str(battle._pending_enemy_deploy), battle._my_deployed_count()]
			if dk != _deploy_pool_key:
				_deploy_pool_key = dk
				_show_deploy_panel()
		else:
			_deploy_pool_key = ""
		if st != _last_phase_state:
			var prev_st: int = _last_phase_state
			_last_phase_state = st
			_refresh_round()
			# 【2026-09-28·用户报「点击替补队伍时列表会重新出来一次」】改成：**进入选替补阶段时自动开一次**，
			#   之后完全听用户的开关（原来 _refresh_team_panel() 里用 picking 强制开 ⇒ 用户一点收起就被它翻回来）。
			# 【2026-09-28】显隐改由 _refresh_team_panel() 的派生条件负责（用户开关 or 正在选替补）；
			#   这里只在进入选替补时补刷一次（原来靠 prev_st 判离开，状态一帧内跳两次就会漏）。
			# 【2026-09-29·用户报「拉出替补队伍的时候拖下英雄，上了英雄之后替补队伍没有自动收回」】
			#   离开替补流程这一半**必须补回来**：显隐是派生条件（`_team_panel_open or _sub_picking()`），
			#   而"先自己拉出列表、再拖下英雄"这条路把**用户开关**置成了 true ⇒ 替补落位后派生条件仍为真
			#   ⇒ 面板不会自己收。所以离开替补阶段时，把用户开关一并清掉（他报的就是这个）。
			var was_sub: bool = prev_st == Battle.State.SUBSTITUTING or prev_st == Battle.State.PLACE_SUB
			var now_sub: bool = st == Battle.State.SUBSTITUTING or st == Battle.State.PLACE_SUB
			if now_sub:
				# 【2026-09-28·用户报「主动撤下后点替补英雄又闪一下」】只有**从替补流程之外**进来才滑：
				#   SUBSTITUTING → PLACE_SUB（= 点了英雄）是同一次替补里的状态推进 ⇒ 不能重滑。
				# 【2026-09-29·用户报「打开替补队伍的时候拖下英雄，替补队伍会闪一下」】再加一道：
				#   面板**本来就摆着**（用户自己开着的）时不要再让它"滑入一次" —— 拖下撤人时面板
				#   正是开着的那块 ⇒ 重滑 = 闪。`_refresh_team_panel()` 内部会原地更新（不重滑）。
				if not was_sub and _team_panel == null:
					_team_panel_slide_next = true
				_refresh_team_panel()
			elif was_sub:
				# 离开替补流程（替补已落位 / 撤下取消 / 超时自动补位完成）⇒ 收回列表：
				#   连"用户自己拉出来的那块"一起收（清掉用户开关，再走标准收起路径 ⇒ 不重建、不闪）。
				_team_panel_open = false
				_close_team_panel()
	_update_turn_timer()
	_update_arena_pick_timer()
	_update_deploy_pick_timer()
	_update_deck_pick_timer()
	_update_score_tooltip_pos()
	_update_arena_touch_hold()   # 竞技场触屏：按住不动超时 -> 转为查看模式（长按）

# 部署面板上方大字倒计时：本端真人选人轮（battle.deploy_budget_active）显示共享预算剩余秒
func _update_deploy_pick_timer() -> void:
	if battle == null or not is_instance_valid(battle):
		return
	if _turn_timer_label == null or not is_instance_valid(_turn_timer_label):
		return
	# 【2026-09-28·用户报「对端认输后，屏幕中央的大字倒计时还在跳」】对局已结束（认输/判负）就不显示。
	# 【2026-09-29·用户报「有时候普通模式的部署阶段没有时间提示了」】不能要求 `GameState.match_running`
	#   —— 它在**每会话第 1 局的部署期是 false**（`_start_match()` 才置 true）⇒ 判据用"正处在部署期"。
	# 【2026-09-29·用户要求「部署阶段的倒计时放到上方状态栏」】不再自己画大字，改成**接管状态栏那枚
	#   计时器**（`_turn_timer_label`）—— 与卡组三选一（`_update_deck_pick_timer()`）完全同一套做法：
	#   条件不满足就直接 return**不抢**（那会儿回合倒计时自己会隐藏）。
	if not (battle.deploy_budget_active and not GameState.match_over \
			and (battle.state == Battle.State.DEPLOY or battle.state == Battle.State.PLACE_DEPLOY)):
		return
	var secs := int(ceil(battle.deploy_budget_left))
	_turn_timer_label.visible = true
	# 【2026-09-29·用户报「怎么部署阶段还有那个闹钟图案」】这里原来也带 `⏱` 前缀
	#   （上一轮只改了回合计时器那一处）⇒ 一并去掉，只留纯秒数。
	_turn_timer_label.text = "%d 秒" % maxi(secs, 0)
	_turn_timer_label.add_theme_color_override("font_color",
		Color(1.0, 0.3, 0.25) if secs <= 5 else Color(1.0, 0.9, 0.4))
	_fit_top_center()

# 【2026-09-21 用户定】选卡组限时：读 `battle.deck_pick_time_left`（15 秒，超时随机选一个）。
# 【2026-09-29·用户要求】「将卡组 3 选 1 的时间提示放到上方状态栏，不需要写随机选择」：
#   面板里那个 32 号大字**撤掉**（见 `_show_deck_pick_panel()`），改在**状态栏正中那行下面**显示，
#   文案只留纯秒数（不再写"（超时随机选一个卡组）"）。
#   ⚠️ `_process()` 里本函数排在 `_update_turn_timer()` **之后** ⇒ 那会儿若不在对局中，
#   回合计时器已被它隐藏，这里正好接管同一个 Label；不满足条件就直接 return（不抢）。
func _update_deck_pick_timer() -> void:
	if battle == null or not is_instance_valid(battle):
		return
	if _turn_timer_label == null or not is_instance_valid(_turn_timer_label):
		return
	if battle.state != Battle.State.DECK_PICK or battle.deck_pick_time_left <= 0.0:
		return
	var secs := int(ceil(battle.deck_pick_time_left))
	_turn_timer_label.visible = true
	_turn_timer_label.text = "%d 秒" % secs
	_turn_timer_label.add_theme_color_override("font_color",
		Color(1.0, 0.3, 0.25) if secs <= 5 else Color(1.0, 0.9, 0.4))
	_fit_top_center()

# 选人面板上方的大字倒计时：仅当本端正在 2 选 1（battle.arena_pick_time_left >= 0）
func _update_arena_pick_timer() -> void:
	if _arena_timer_label == null or not is_instance_valid(_arena_timer_label):
		return
	if battle == null or not is_instance_valid(battle):
		return
	if battle.state != Battle.State.ARENA_DRAFT or battle.arena_pick_time_left < 0.0:
		_arena_timer_label.text = ""
		return
	var secs := int(ceil(battle.arena_pick_time_left))
	_arena_timer_label.text = str(secs)
	# 剩 ≤3 秒变红警示
	_arena_timer_label.add_theme_color_override("font_color",
		Color(1.0, 0.3, 0.25) if secs <= 3 else Color(1.0, 0.9, 0.4))

# 顶部回合倒计时：仅对局中"本端可操作回合"显示（部署/等待/敌方回合隐藏）。
# 剩余 ≤15 秒时屏幕边缘浅红闪烁提醒。
func _update_turn_timer() -> void:
	if _turn_timer_label == null:
		return
	var show_timer := false
	var low_time := false
	var secs := 0
	if battle != null and is_instance_valid(battle):
		var match_live := GameState.match_running and not GameState.match_over
		if match_live and GameState.active_side == battle._my_side() and battle.turn_time_left > 0.0:
			# 本端行动（含行动动画期间，不做 state==PLAYER_INPUT 判定，避免每次演出闪烁）：
			# 显示本地倒计时
			show_timer = true
			secs = int(ceil(battle.turn_time_left))
			low_time = secs <= 15   # 仅本端行动倒计时触发边缘警告
		elif GameState.is_online and match_live and GameState.active_side != battle._my_side():
			# 联机等待对端行动：显示对端剩余时间。
			# 值由 Battle 维护：切回合瞬间置满额、本地每帧递减、对端广播校准 -> 不会消失。
			show_timer = true
			secs = int(ceil(battle.peer_turn_time_left))
	if show_timer:
		_turn_timer_label.visible = true
		# 【2026-09-29·用户要求「时间前面不要加个闹钟图案」】去掉 `⏱` 前缀，只留秒数
		_turn_timer_label.text = "%d 秒" % secs
		_turn_timer_label.add_theme_color_override("font_color",
			Color(1.0, 0.35, 0.3) if secs <= 10 else Color(1.0, 0.9, 0.6))
	else:
		_turn_timer_label.visible = false
	_set_edge_warning(low_time)
	_fit_top_center()          # 【2026-09-27】倒计时的文字/显隐也在中间那组里 ⇒ 跟着重算一次（内部有去重）

# 屏幕边缘浅红闪烁：剩余时间 ≤15 秒开启（呼吸效果），否则隐藏
func _set_edge_warning(on: bool) -> void:
	if _warn_holder == null:
		return
	if on and not _warn_holder.visible:
		_warn_holder.visible = true
		if _warn_tween != null and _warn_tween.is_valid():
			_warn_tween.kill()
		_warn_tween = create_tween().set_loops()
		_warn_tween.tween_property(_warn_holder, "modulate:a", 0.65, 0.55).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		_warn_tween.tween_property(_warn_holder, "modulate:a", 0.2, 0.55).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	elif not on and _warn_holder.visible:
		_warn_holder.visible = false
		if _warn_tween != null and _warn_tween.is_valid():
			_warn_tween.kill()
			_warn_tween = null
		_warn_holder.modulate.a = 1.0   # 复位，避免下次显示时残留透明度

# 按钮可用性/可见性刷新：
# 1) 结束回合：仅当本端操作方 == 当前行动方且处于我方输入状态时可点（非我方回合禁用）；
# 2) 重开：联机（含联机竞技场）不需要，隐藏；
# 3) 返回：联机返回大厅，单机返回选人界面。
## 本局是否在放录像（`Battle._replay_mode`）。回放里战场按钮全部收起 —— 用户 2026-09-27 报
## 「怎么录像功能可以点击下方的按钮」：回放本来就不该有"结束回合/重开/返回选人"这些入口，
## 退出回放走回放控制条自己的「返回」。
## 【录像回放】进回放时把"临时提示"一次清干净：回合横幅（含还在淡出的）、部署面板、常驻队伍面板。
## 由 `Battle._replay_begin()` 调用；对局路径不调（一个字不变）。
func clear_transient_ui() -> void:
	if _turn_banner_tween != null and _turn_banner_tween.is_valid():
		_turn_banner_tween.kill()
	if _turn_banner != null and is_instance_valid(_turn_banner):
		_turn_banner.queue_free()
	_turn_banner = null
	_close_deploy_panel()
	_close_team_panel()

func _in_replay() -> bool:
	# ⚠️ 除了 `Battle._replay_mode`，还要看 `GameState.replay_id`：回放分支里 **HUD 先建、`_replay_mode` 后置**
	#   （`_replay_begin()` 的顺序），中间那段空窗期里 `state` 还是录像里残留的 `DEPLOY` ⇒ 部署面板会被建出来
	#   （用户报的"黄字、什么部署什么的"就是这么漏的，实测：`_show_deploy_panel：replay=false state=4`）。
	return GameState.replay_id != "" \
			or (battle != null and is_instance_valid(battle) and bool(battle._replay_mode))

func _refresh_controls() -> void:
	if _in_replay():
		if _end_btn != null:
			_end_btn.visible = false
		if _surrender_btn != null:
			_surrender_btn.visible = false
		if _pause_btn != null:
			_pause_btn.visible = false   # 回放用控制条的「暂停/继续」（对局暂停是 tree.paused，会把回放一起冻住）
		return
	var my_turn := false
	if battle != null:
		if GameState.dual_control:
			# 自由部署双控：当前行动方都由本端操控(已在 _begin_side 设为 PLAYER_INPUT)，可结束回合
			my_turn = battle.state == Battle.State.PLAYER_INPUT
		else:
			my_turn = battle.state == Battle.State.PLAYER_INPUT and GameState.active_side == battle._my_side()
	if _end_btn != null:
		# 【2026-09-28·用户要求】替补队伍列表弹出时，结束回合**熄灭且不可点**
		#   （判据与列表的可见条件同源；图片按钮的 disabled 状态本来就是压暗那张）。
		var team_out: bool = _team_panel_open or _sub_picking()
		_end_btn.disabled = (not my_turn) or team_out
		# 【2026-09-27·用户要求「棋盘放大到宽度接近填满」的配套】部署阶段屏底那条带子**让给"开局选人"
		#   卡片行**：棋盘放大后卡片行只能贴屏底摆（摆在上方就会压住棋盘最下面两行 —— 那正是玩家要
		#   点绿格放人的地方）。部署期本来也用不到「结束回合」（`disabled` 恒真）⇒ 直接藏起来。
		# 【2026-09-28·用户报「竞技场 2 选 1 结束后，如果是我方先手，一开始就把结束回合按钮显示出来了，
		#   到我方部署时才消失」】原来只**黑名单**了部署两个态，而"选完人 → 部署"中间还夹着一整段
		#   `IDLE`（`_oa_finish_to_deploy()` 先置 IDLE 再走 `_begin_deployment()`，那里面还有开场演出 +
		#   「战斗开始」横幅 + 停一拍）⇒ 那一段按钮一直露着。卡组三选一（`DECK_PICK`）同样是这个毛病。
		#   ⇒ 改成**白名单**：只有"回合真的在跑"的几个状态才出现（不是本端回合时照旧显示但压暗不可点，
		#   见上面那句 `disabled`），其余（IDLE / 部署两态 / 竞技场选人 / 卡组三选一 / 已结束）一律藏。
		var st: int = battle.state if battle != null else -1
		_end_btn.visible = battle == null \
			or st == Battle.State.PLAYER_INPUT or st == Battle.State.ANIMATING \
			or st == Battle.State.ENEMY_TURN or st == Battle.State.SUBSTITUTING \
			or st == Battle.State.PLACE_SUB or st == Battle.State.PLACE_BOMB
	if _pause_btn != null:
		_pause_btn.visible = not GameState.is_online   # 暂停仅单机（联机暂停会与对端不同步）
	if _surrender_btn != null:
		# 【2026-09-28·用户要求】「认输」只在联机显示（与「暂停」同一角落、互斥）：
		#   联机没有暂停，退出入口就从底部那枚「返回大厅」换成这里。
		_surrender_btn.visible = GameState.is_online
	# 【2026-09-27】箭头（替补列表开关）的显隐也挂在这条每帧刷新的路上：它跟 `battle.state` 走
	#   （部署期藏、对局/选替补时显示）⇒ 跟状态机不会脱节（`_show_deploy_panel()` 那条早退路径
	#   压根不会走到 `_close_team_panel()`，光靠那边刷会漏掉"部署结束"这一下）。
	_refresh_team_toggle()
	# 【2026-09-28·用户要求「竞技场开局默认打开替补队伍面板，直到部署完成再关闭」】
	#   同理挂在这条每帧刷新的路上：进竞技场部署 ⇒ 展开；部署一完成 ⇒ 自动收回（只在状态变化时动一次）。
	_sync_arena_team_panel()

# 【2026-09-28·用户要求】联机认输：先喊**完整的一句**给对端（本端也回显气泡），再走认输结算。
func _on_surrender_pressed() -> void:
	if battle == null or not is_instance_valid(battle):
		return
	_send_chat(battle.SURRENDER_LINE)
	battle.surrender_online()

# 属性浮层实时跟随鼠标，并收敛到屏幕内（避免被底部/右侧挡住）
# 触屏长按查看时 _tooltip_pin_rect 非空：固定显示在目标卡上方，不跟随手指（避免被手指遮挡）。
# 竞技场倒计时在屏幕中央上方：查看左卡则浮层靠左、查看右卡则靠右，中央让位给倒计时。
func _update_score_tooltip_pos() -> void:
	if _score_tooltip_wrap == null or not _score_tooltip_wrap.visible:
		return
	var vs := get_viewport().get_visible_rect().size
	var tw := _score_tooltip_wrap.size.x
	var th := _score_tooltip_wrap.size.y
	var pos: Vector2
	if not _tooltip_pin_rect.size.is_zero_approx():
		# 纵向：优先显示在卡上方（避免手指遮挡）；上方不够则贴顶/卡下方兜底
		pos = Vector2.ZERO
		pos.y = _tooltip_pin_rect.position.y - th - 10.0
		if pos.y < 8.0:
			pos.y = 8.0
		# 横向：按查看卡所在半边贴边，中央让给倒计时
		var mid := vs.x / 2.0
		var pin_cx := _tooltip_pin_rect.position.x + _tooltip_pin_rect.size.x / 2.0
		if pin_cx < mid:
			# 查看左侧卡 -> 浮层靠左，右缘不越过中央
			pos.x = 8.0
			if pos.x + tw > mid - 6.0:
				pos.x = maxf(8.0, mid - 6.0 - tw)
		else:
			# 查看右侧卡 -> 浮层靠右，左缘不越过中央
			pos.x = vs.x - tw - 8.0
			if pos.x < mid + 6.0:
				pos.x = mid + 6.0
		pos.x = clampf(pos.x, 8.0, maxf(8.0, vs.x - tw - 8.0))
		pos.y = clampf(pos.y, 8.0, maxf(8.0, vs.y - th - 8.0))
		_score_tooltip_wrap.position = pos
		return
	var mp := get_viewport().get_mouse_position()
	# 默认在鼠标右上方；若右缘/上方越界则翻转/收敛
	pos = mp + Vector2(16, 18)
	if pos.x + tw > vs.x - 4:
		pos.x = mp.x - tw - 10   # 翻到鼠标左侧
	if pos.y + th > vs.y - 190:   # 底部留出按钮行，改为弹到鼠标上方
		pos.y = mp.y - th - 10
	pos.x = clampf(pos.x, 4, vs.x - tw - 4)
	pos.y = clampf(pos.y, 4, vs.y - th - 4)
	_score_tooltip_wrap.position = pos

# ---- 暂停（仅单机）：冻结整棵场景树，弹"已暂停"遮罩，可继续 ----
func _on_pause_pressed() -> void:
	if GameState.is_online:
		return   # 联机不可暂停（会影响与对端的同步）
	if _pause_overlay != null and is_instance_valid(_pause_overlay):
		return   # 已暂停
	var vsize := get_viewport().get_visible_rect().size
	var overlay := Control.new()
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	# 暂停后引擎不再处理 PAUSABLE 节点：遮罩与按钮必须能在暂停中工作
	overlay.process_mode = Node.PROCESS_MODE_WHEN_PAUSED
	add_child(overlay)
	_pause_overlay = overlay
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 1.0)   # 暂停时背景全黑（遮住棋盘）
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.add_child(dim)
	var panel := PanelContainer.new()
	# 面板外观走主题里的"弹出框边框"（theme/panel_frame_dark.png）
	overlay.add_child(panel)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 14)
	panel.add_child(vb)
	var title := Label.new()
	title.text = "已暂停"
	title.add_theme_font_size_override("font_size", 30)
	title.add_theme_color_override("font_color", Color(1, 0.85, 0.5))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(title)
	var hint := Label.new()
	hint.text = "对局已冻结（计时与动画都停下）"
	hint.add_theme_font_size_override("font_size", 13)
	hint.add_theme_color_override("font_color", Color(0.75, 0.8, 0.9))
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(hint)
	# 【2026-09-29·用户要求「声音集合到菜单里」】音量控件搬进菜单面板（原来浮在右上角）；
	#   面板居中一行、与按钮同宽，省得缩在角落。
	# 【2026-09-29·用户要求「音量调节不要再弹框，就在菜单栏里可以拉动」】菜单面板里直接摆一条
	#   **常驻、可直接拖的滑条**（原来塞进去的是 `VolumeControl` —— 那是"喇叭按钮 + 弹出小面板"
	#   那一套 ⇒ 在菜单里还得再点一次才出滑条）。这里只要滑条本体：拖动即生效，右边写百分比。
	#   ⚠️ 暂停面板是 `PROCESS_MODE_WHEN_PAUSED`，滑条是它的子节点 ⇒ 暂停期间照样能拖。
	var vol_row := HBoxContainer.new()
	vol_row.add_theme_constant_override("separation", 10)
	vb.add_child(vol_row)
	var vol_title := Label.new()
	vol_title.text = "音量"
	vol_title.add_theme_font_size_override("font_size", 18)
	vol_title.add_theme_color_override("font_color", Color(0.9, 0.93, 1.0))
	vol_title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	vol_title.custom_minimum_size = Vector2(46, 36)
	vol_row.add_child(vol_title)
	var vol_slider := HSlider.new()
	vol_slider.min_value = 0.0
	vol_slider.max_value = 100.0
	vol_slider.step = 1.0
	vol_slider.custom_minimum_size = Vector2(150, 36)
	vol_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vol_slider.value = clampf(roundf(AudioManager.get_volume() * 100.0), 0.0, 100.0)
	vol_row.add_child(vol_slider)
	var vol_pct := Label.new()
	vol_pct.text = "静音" if int(vol_slider.value) <= 0 else "%d%%" % int(vol_slider.value)
	vol_pct.add_theme_font_size_override("font_size", 18)
	vol_pct.add_theme_color_override("font_color", Color(0.9, 0.93, 1.0))
	vol_pct.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	vol_pct.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	vol_pct.custom_minimum_size = Vector2(52, 36)
	vol_row.add_child(vol_pct)
	vol_slider.value_changed.connect(func(p: float):
		AudioManager.set_volume(clampf(p / 100.0, 0.0, 1.0))
		vol_pct.text = "静音" if int(roundf(p)) <= 0 else "%d%%" % int(roundf(p)))
	vol_slider.drag_ended.connect(func(_changed: bool): AudioManager.play("select"))
	var resume := Button.new()
	resume.text = "继续游戏"
	resume.add_theme_font_size_override("font_size", 20)
	resume.custom_minimum_size = Vector2(240, 50)
	resume.pressed.connect(_on_resume_pressed)
	vb.add_child(resume)
	# 【2026-09-27·用户要求】「重开 / 返回选人」已整合进暂停面板（底部常驻行只剩结束回合）：
	#   单机普通模式给这两个；**天梯**仍只给「保存并退出 / 放弃本次天梯」（重开会作废本局，口径冲突）。
	if GameState.ladder_mode != "":
		var save_quit := Button.new()
		save_quit.text = "保存并退出"
		save_quit.add_theme_font_size_override("font_size", 20)
		save_quit.custom_minimum_size = Vector2(240, 50)
		save_quit.pressed.connect(_on_ladder_save_quit)
		vb.add_child(save_quit)
		var give_up := Button.new()
		give_up.text = "放弃本次天梯"
		give_up.add_theme_font_size_override("font_size", 20)
		give_up.custom_minimum_size = Vector2(240, 50)
		give_up.pressed.connect(_on_ladder_give_up)
		vb.add_child(give_up)
		# 【2026-09-24 用户要求】原来按钮下面还有一块小字（"天梯普通模式 · 第 N 局 · 当前连胜 M 场" + 两行按钮说明）
		#   ⇒ 已删；暂停面板现在就三行：继续游戏 / 保存并退出 / 放弃本次天梯。
	else:
		var p_restart := Button.new()
		p_restart.text = "重开"
		p_restart.add_theme_font_size_override("font_size", 20)
		p_restart.custom_minimum_size = Vector2(240, 50)
		p_restart.pressed.connect(_on_restart)
		vb.add_child(p_restart)
		var p_back := Button.new()
		# 【2026-09-27·用户要求】普通模式暂停里的这个按钮 = **返回主菜单**（文案原写"返回选人"，
		#   但 `_on_back_to_menu` 走的就是 `change_scene_to_file(Menu.tscn)`、落点是主菜单页
		#   —— Menu 的组队页只有 `net_edit_mode` 才会直接进 ⇒ 这里只是把文案改成与实际一致）。
		p_back.text = "返回主菜单"
		p_back.add_theme_font_size_override("font_size", 20)
		p_back.custom_minimum_size = Vector2(240, 50)
		p_back.pressed.connect(_on_back_to_menu)
		vb.add_child(p_back)
	panel.reset_size()
	var pw: float = clampf(maxf(panel.get_combined_minimum_size().x, 300.0), 300.0, maxf(vsize.x - 40.0, 300.0))
	var ph: float = panel.get_combined_minimum_size().y
	panel.size = Vector2(pw, ph)
	panel.position = Vector2((vsize.x - pw) / 2.0, (vsize.y - ph) / 2.0)
	get_tree().paused = true

func _on_resume_pressed() -> void:
	_resume()

# 【天梯·保存并退出】存档已经在"每次回合开始"落过盘了（见 `Battle._ladder_autosave()`），
#   这里只做两件事：确认手上这份快照确实在（没有就现补一份），然后回主菜单。
#   ⚠️ 补不补由 `Battle._ladder_can_save()` 判：**部署阶段要补**（快照含"已经上了哪几个人"，
#      续档时接着部署），选卡组 / 竞技场选人阶段不补（那会儿双方卡组都没定，没有可回的局面）。
#   本轮存档**保留** ⇒ 下次进天梯可以继续。
func _on_ladder_save_quit() -> void:
	if battle != null and not LadderStore.has_snapshot() and battle._ladder_can_save():
		battle._ladder_autosave(GameState.active_side)
	_resume()
	GameState.ladder_mode = ""
	GameState.arena_mode = false
	get_tree().change_scene_to_file("res://scenes/Menu.tscn")

# 【天梯·放弃】用户要求先**再确认**一次（这一步会清当前连胜 + 删本轮存档，误触代价太大）：
#   这里只负责弹确认层；真正确认后走 `_ladder_do_give_up()`。
func _on_ladder_give_up() -> void:
	if _ladder_confirm != null and is_instance_valid(_ladder_confirm):
		return
	var vsize := get_viewport().get_visible_rect().size
	var ov := Control.new()
	ov.set_anchors_preset(Control.PRESET_FULL_RECT)
	ov.mouse_filter = Control.MOUSE_FILTER_STOP
	# 暂停后引擎不再处理 PAUSABLE 节点：确认层与按钮必须能在暂停中工作（与暂停遮罩同一处理）
	ov.process_mode = Node.PROCESS_MODE_WHEN_PAUSED
	add_child(ov)
	_ladder_confirm = ov
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.75)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	ov.add_child(dim)
	var panel := PanelContainer.new()
	ov.add_child(panel)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 14)
	panel.add_child(vb)
	var title := Label.new()
	title.text = "确定放弃本次天梯？"
	title.add_theme_font_size_override("font_size", 26)
	title.add_theme_color_override("font_color", Color(1, 0.6, 0.5))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(title)
	# ⚠️ 这里**不要**再加说明小字（用户 2026-09-24：「你不要自己乱加这种描述，显得很乱，需要的话我会让你加的」）
	var yes := Button.new()
	yes.text = "确定放弃"
	yes.add_theme_font_size_override("font_size", 20)
	yes.custom_minimum_size = Vector2(240, 50)
	yes.pressed.connect(_ladder_do_give_up)
	vb.add_child(yes)
	var no := Button.new()
	no.text = "取消"
	no.add_theme_font_size_override("font_size", 20)
	no.custom_minimum_size = Vector2(240, 50)
	no.pressed.connect(_close_ladder_confirm)
	vb.add_child(no)
	panel.reset_size()
	var pw: float = clampf(maxf(panel.get_combined_minimum_size().x, 320.0), 320.0, maxf(vsize.x - 40.0, 320.0))
	var ph: float = panel.get_combined_minimum_size().y
	panel.size = Vector2(pw, ph)
	panel.position = Vector2((vsize.x - pw) / 2.0, (vsize.y - ph) / 2.0)

func _close_ladder_confirm() -> void:
	if _ladder_confirm != null and is_instance_valid(_ladder_confirm):
		_ladder_confirm.queue_free()
	_ladder_confirm = null

# 【天梯·放弃】确认之后才真的执行：当前连胜清零、删档（最高连胜保留）
# 【2026-09-25 用户要求】不再直接回主菜单，而是**弹结算面板**：
#   「才X连胜，跑什么？去简单难度偷偷进步啊？」（X = 放弃那一刻的当前连胜）
#   ⚠️ 面板弹出期间**整棵树保持暂停**（`_resume()` 不在这里调）⇒ 战斗冻结，AI 不会在面板后面接着跑；
#      结算浮层自己按 `PROCESS_MODE_WHEN_PAUSED` 收输入（见 `show_result()`），点「返回主菜单」才真的换场景。
func _ladder_do_give_up() -> void:
	_close_ladder_confirm()
	GameState.ladder_final_streak = Stats.current_streak(Stats.current_mode_key())
	Stats.reset_streak(Stats.current_mode_key())
	LadderStore.finish_run()
	_ladder_gave_up = true
	show_result(false, false)   # 【2026-09-29】放弃这条路不播胜负音（保持原样；真打输/打赢才播）

# 解除暂停（幂等）：收起遮罩并恢复场景树
func _resume() -> void:
	if _pause_overlay != null and is_instance_valid(_pause_overlay):
		_pause_overlay.queue_free()
	_pause_overlay = null
	if is_inside_tree():
		get_tree().paused = false

# 场景退出兜底：若在暂停中离开（返回选人等），务必恢复，避免整个引擎一直暂停。
# 这里**不能**用 get_tree()：节点被判离场景树时 get_tree() 会报 Parameter "data.tree" is null，
# 拿不到 SceneTree 就恢复不了暂停。Engine.get_main_loop() 与节点是否在树里无关，始终有效。
func _exit_tree() -> void:
	var loop := Engine.get_main_loop()
	if loop is SceneTree:
		(loop as SceneTree).paused = false

func _on_end_turn() -> void:
	if battle and battle.state == Battle.State.PLAYER_INPUT:
		battle.submit_end_turn()

# redraft=true = 对局结束后"再战一局"（竞技场需重新 2 选 1 选人）；
# 对局中的"重开"用默认 false（竞技场沿用同队伍，普通模式重新选卡组）。
func _on_restart(redraft := false) -> void:
	_resume()   # 若正处于暂停：先恢复，否则重开流程全被冻结
	# 【2026-09-29·用户要求】联机：「再来一局」**不立刻开局**，只表达意向并留在结算面板上等对方；
	#   对方也点了才开局（主机权威），对方退出则回联机大厅（见 `_on_peer_left_to_lobby`）。
	if GameState.is_online:
		if battle != null and is_instance_valid(battle):
			battle.request_rematch_online()
			_refresh_rematch_ui()
		else:
			_on_peer_left_to_lobby()
		return
	if _result_overlay != null:
		# 关闭结算浮层（场景不卸载，需手动收起，否则遮住重开的选人/部署界面）
		_result_overlay.queue_free()
		_result_overlay = null
	# 重开前收起棋盘下方的全部临时面板：常驻"替补队伍/替补选人"与开局部署面板。
	# 否则在替补阶段（SUBSTITUTING/PLACE_SUB）点重开时，reset_match 只重置战斗数据，
	# 已打开的面板不会随 deploy_refresh 收起，上一局的英雄行会残留在屏底。
	_close_team_panel()
	_close_deploy_panel()
	_close_arena_panel()     # 竞技场选人阶段重开：收掉 2 选 1 面板，避免残留挡住新一轮选人
	_close_deck_pick_panel()
	if battle != null and is_instance_valid(battle):
		if GameState.is_online:
			battle.request_rematch_online()   # 联机：请求再来一局（不退出连接/大厅）
		else:
			battle.reset_match(redraft)   # 重置本局（不卸载场景，避免 reload 打断异步导致 get_tree() null 崩溃）
	elif GameState.is_online:
		# 异常兜底（Battle 已失效）：退回联机大厅
		NetBus.stop()
		GameState.reset_online()
		get_tree().change_scene_to_file("res://scenes/NetLobby.tscn")
	else:
		get_tree().reload_current_scene()

# 【2026-09-29·用户要求】结算演出：**失败方的三枚阵亡标志先震动 → 那一侧状态栏处爆炸 →
#   然后才弹结算面板**（面板在 `show_result()` 里等这段跑完）。
#   · 失败方 = 本端输了（`win == false`）就是**我方那一排**，否则是**对端那一排**；
#   · 震动复用 `DeathMark.pop_and_shake()`（死亡时同一套"弹出+摇晃"，三枚逐枚错开 0.06s）；
#   · 爆炸 = 在那一排的状态栏位置上炸一圈碎片（`_StatusBurst`，自绘、纯演出、不接输入）；
#   · headless/回放：直接返回（跑批与回放时序逐位不变）。
func _defeat_anim(win: bool) -> void:
	var my_fn: int = battle._my_faction() if battle != null else DataRegistry.Faction.PLAYER
	var loser_fn: int = (DataRegistry.Faction.PLAYER if my_fn == DataRegistry.Faction.ENEMY else DataRegistry.Faction.ENEMY) if win else my_fn
	await _defeat_anim_side(loser_fn)

## 【2026-09-29·用户报「录像里还是没看到失败的效果」】回放的结局**不走 `show_result()`**
##   （那边是 `Battle._replay_show_result()` 只弹一条"蓝方/红方获胜"横幅）⇒ 给它一个入口：
##   按"输的是哪一方"播同一段演出（震动 → 爆炸）。`loser_is_blue` = 输的是蓝方吗。
func replay_defeat_anim(loser_is_blue: bool) -> void:
	await _defeat_anim_side(DataRegistry.Faction.PLAYER if loser_is_blue else DataRegistry.Faction.ENEMY)

func _defeat_anim_side(loser_fn: int) -> void:
	var my_fn: int = battle._my_faction() if battle != null else DataRegistry.Faction.PLAYER
	var lost: bool = loser_fn == my_fn
	# 【2026-09-29·用户要求「录像里也要看到」】只跳过 headless（跑批/无窗口）；
	#   **回放里照播**（这段是纯本地视觉、不碰任何判定与网络；`is_inside_tree()` 守卫都在）。
	if DisplayServer.get_name() == "headless":
		return
	# 【2026-09-29·用户报「失败爆炸效果有两次」】这段演出正在播时再被触发就忽略（双保险：
	#   Battle 侧已加"结算只发一次"的闸门，这里保证即使有人重复调也只演一遍）。
	if _defeat_anim_running:
		return
	_defeat_anim_running = true
	var marks: Array = _my_marks if lost else _op_marks
	var anchor: Control = _my_death_name if lost else _op_death_name
	for i in marks.size():
		var mk = marks[i]
		if mk == null or not is_instance_valid(mk):
			continue
		if i > 0:
			await get_tree().create_timer(0.06).timeout
			if not is_inside_tree():
				_defeat_anim_running = false
				return
		mk.pop_and_shake()
		AudioManager.play("select")
	# 【2026-09-29·用户要求】「震动有点短，要循序渐进，越来越爆炸的感觉」⇒ 弹完再叠**三段渐强震动**：
	#   幅度 3 → 7 → 11px、每段次数 4 → 7 → 10、单次时长 0.10 → 0.075 → 0.05s（越来越快越猛），
	#   三枚一起（首枚已先弹过），总时长约 1.6 秒，然后才炸。
	# 【2026-09-29·用户要求「给骷髅头爆炸加点音效：骷髅头震动的时候 → 骷髅头震动.mp3」】
	#   渐强震动这一段起手就播（素材 1.31 秒，正好盖住下面 1.65 秒的 ramp）。
	AudioManager.play("skull_shake")
	for mk2 in marks:
		if mk2 == null or not is_instance_valid(mk2):
			continue
		var base_pos: Vector2 = mk2.position
		var tw: Tween = mk2.create_tween()
		var amp := 3.0
		for seg in 3:
			var step: float = 0.10 - float(seg) * 0.025
			var n: int = 4 + seg * 3
			for j in n:
				var dx: float = amp if j % 2 == 0 else -amp
				var rot: float = (0.05 + 0.05 * float(seg)) * (1.0 if j % 2 == 0 else -1.0)
				tw.tween_property(mk2, "position", base_pos + Vector2(dx, 0.0), step)
				tw.parallel().tween_property(mk2, "rotation", rot, step)
			amp += 4.0
		tw.tween_property(mk2, "position", base_pos, 0.08)
		tw.parallel().tween_property(mk2, "rotation", 0.0, 0.08)
	await get_tree().create_timer(1.65).timeout
	if not is_inside_tree():
		_defeat_anim_running = false
		return
	# 爆炸：落点 = 那一侧名字框/标志一带的中心（取名字框所在竖排栈的矩形）
	var center := Vector2(get_viewport().get_visible_rect().size.x * 0.5, 40.0)
	if anchor != null and is_instance_valid(anchor):
		var plate: Control = anchor.get_parent() as Control
		if plate != null:
			var r: Rect2 = plate.get_global_rect()
			center = r.position + r.size * 0.5
	var burst := _StatusBurst.new()
	burst.z_index = 5
	if _kill_fx != null and is_instance_valid(_kill_fx):
		_kill_fx.add_child(burst)
	else:
		add_child(burst)
	burst.play(center, Color(1.0, 0.45, 0.35) if lost else Color(0.6, 0.85, 1.0))
	# 【2026-09-29·用户要求「给骷髅头爆炸加点音效：失败爆炸音.mp3」】爆炸那一下出声
	#   （原来这里是 `play("death")` —— `SFX_STREAMS` 里根本没有 `death` 这个键 ⇒ 一直静音）。
	AudioManager.play("defeat_blast")
	await get_tree().create_timer(0.75).timeout
	_defeat_anim_running = false   # 演出播完：下一次结算（重开一局 / 回放再看一遍）照常演

## 【2026-09-29】失败演出用的一次性爆炸：从中心向外炸一圈碎片 + 一圈冲击环，0.7 秒后自毁。
##   纯自绘、`MOUSE_FILTER_IGNORE`（不挡任何点击），加在 `_kill_fx` 层上（画在按钮之上）。
## 【2026-09-29·用户问「爆炸有没有更好的效果」】把原来"18 个圆点 + 一圈环"升级成**四层叠加**的爆炸
##   （全部自绘、零素材、固定种子可复现）：
##     ① **白闪**：0~0.08s 一枚白色大圆瞬间铺开又收（爆炸的"亮"）；
##     ② **火球**：核心亮黄 → 橙红的两层圆快速涨大淡出（温度梯度，内亮外暗）；
##     ③ **冲击环**：一圈带厚度的环向外扩张、越扩越细越淡（原来那圈保留但更细更快）；
##     ④ **碎块 + 火星**：14 块不规则碎块（四边形，各自旋转、受"重力"下坠）+ 20 道火星拖尾
##        （短线，比碎块更快更细、拖尾随速度方向拉长）；再补 5 团**余烟**（大而淡的圆，慢速上飘）。
class _StatusBurst extends Control:
	var _t := 0.0
	var _life := 1.15
	var _center := Vector2.ZERO
	var _col := Color(1.0, 0.45, 0.35)
	var _chunks: Array = []
	var _sparks: Array = []
	var _smoke: Array = []

	func play(c: Vector2, col: Color) -> void:
		_center = c
		_col = col
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		set_anchors_popup()
		var rng := RandomNumberGenerator.new()
		rng.seed = 20260929      # 固定种子 ⇒ 每次爆炸形状一致（可复现、联机两端同观感）
		for i in 14:             # 碎块
			var a := TAU * float(i) / 14.0 + rng.randf_range(-0.15, 0.15)
			_chunks.append({ "d": Vector2(cos(a), sin(a)), "v": rng.randf_range(150.0, 330.0),
				"s": rng.randf_range(5.0, 11.0), "rot": rng.randf_range(-6.0, 6.0) })
		for i in 20:             # 火星
			var a2 := TAU * float(i) / 20.0 + rng.randf_range(-0.25, 0.25)
			_sparks.append({ "d": Vector2(cos(a2), sin(a2)), "v": rng.randf_range(260.0, 520.0),
				"len": rng.randf_range(10.0, 26.0) })
		for i in 5:              # 余烟
			var a3 := TAU * float(i) / 5.0 + rng.randf_range(-0.4, 0.4)
			_smoke.append({ "d": Vector2(cos(a3), sin(a3)), "v": rng.randf_range(30.0, 70.0),
				"r": rng.randf_range(26.0, 52.0) })
		queue_redraw()

	func set_anchors_popup() -> void:
		set_anchors_preset(Control.PRESET_FULL_RECT)

	func _process(dt: float) -> void:
		_t += dt
		if _t >= _life:
			queue_free()
			return
		queue_redraw()

	func _draw() -> void:
		var k: float = clampf(_t / _life, 0.0, 1.0)
		var fade: float = 1.0 - k
		# ② 余烟（最底层，先画）：慢速上飘、越飘越大越淡
		for s in _smoke:
			var ps: Vector2 = _center + (s["d"] as Vector2) * float(s["v"]) * k - Vector2(0.0, 26.0 * k)
			draw_circle(ps, float(s["r"]) * (0.6 + 0.9 * k), Color(0.32, 0.3, 0.34, 0.22 * fade))
		# ② 火球：内亮黄 → 外橙红两层，快速涨大后淡出（只在前 45% 寿命里）
		var kf: float = clampf(_t / (_life * 0.45), 0.0, 1.0)
		if kf < 1.0:
			var ff: float = 1.0 - kf
			draw_circle(_center, 16.0 + 78.0 * kf, Color(1.0, 0.75, 0.28, 0.85 * ff))
			draw_circle(_center, 10.0 + 44.0 * kf, Color(1.0, 1.0, 0.92, 0.95 * ff))
		# ③ 碎块：飞出去 + 旋转 + 受"重力"下坠（y 额外 +220·k²）
		for f in _chunks:
			var pc: Vector2 = _center + (f["d"] as Vector2) * float(f["v"]) * k + Vector2(0.0, 220.0 * k * k)
			var r: float = maxf(float(f["s"]) * fade, 0.6)
			var ang: float = float(f["rot"]) * k
			var pts := PackedVector2Array()
			for q in 4:
				var qa: float = ang + TAU * float(q) / 4.0
				pts.append(pc + Vector2(cos(qa), sin(qa)) * r)
			draw_colored_polygon(pts, Color(_col.r, _col.g, _col.b, fade))
		# ④ 火星拖尾：短线沿速度方向拉长（比碎块更快更细）
		for sp in _sparks:
			var pv: Vector2 = _center + (sp["d"] as Vector2) * float(sp["v"]) * k
			var tail: Vector2 = pv - (sp["d"] as Vector2) * float(sp["len"]) * fade
			draw_line(tail, pv, Color(1.0, 0.9, 0.6, fade), maxf(3.0 * fade, 0.6), true)
		# ① 白闪：最前 8%（盖在最上面）
		if _t < 0.08:
			var kw: float = 1.0 - _t / 0.08
			draw_circle(_center, 40.0 + 90.0 * (1.0 - kw), Color(1, 1, 1, 0.9 * kw))
		# ⑤ 冲击环：扩张 + 变细变淡
		draw_arc(_center, 18.0 + 190.0 * k, 0.0, TAU, 48,
			Color(_col.r, _col.g, _col.b, fade * 0.85), maxf(7.0 * fade, 1.0), true)
		draw_arc(_center, 10.0 + 120.0 * k, 0.0, TAU, 40,
			Color(1.0, 1.0, 0.95, fade * 0.55), maxf(3.0 * fade, 0.8), true)

func show_result(win: bool, play_sound: bool = true) -> void:
	# 【2026-09-25】主动放弃天梯时**不能**解暂停（战斗要冻在面板后面）⇒ 只收掉暂停遮罩，保持 paused。
	if _ladder_gave_up:
		if _pause_overlay != null and is_instance_valid(_pause_overlay):
			_pause_overlay.queue_free()
		_pause_overlay = null
	else:
		_resume()   # 结算时确保不在暂停态（否则结算浮层按钮点不动）
	# 【2026-09-23 新增·配套阵亡演出】判负/判胜的那一刻（第 3 名阵亡后 0.3s）结算浮层就会弹出来，
	#   正好压在"卡面飞向阵亡标志"的演出上 ⇒ 若还有演出在飞，先等它落地再弹（只延迟面板，不改判定）。
	#   headless（跑批/无窗口）没有演出 ⇒ 这段不生效、时序与改动前逐位一致。
	# 【2026-09-28·击杀预告】等击杀卡面演完才让 Battle 继续（见 `_on_kill_intro`）——
	#   这里只要等"飞行中的死亡特效"落地即可（预告那段已经在开打前等过了）。
	if _death_fx != null and is_instance_valid(_death_fx) and _death_fx.get_child_count() > 0:
		await get_tree().create_timer(0.75).timeout
		if not is_inside_tree():
			return
	# 【2026-09-29·用户要求】「为失败增加演出效果：失败时三个骷髅头震动 → 失败方状态栏处爆炸 →
	#   再弹结算界面」⇒ 面板前先播这段（`_defeat_anim()` 内部按步 await，headless 直接跳过）。
	await _defeat_anim(win)
	if not is_inside_tree():
		return
	# 【2026-09-29·用户报「胜利音效比骷髅头爆炸还早」】胜负音**挪到这里播**：原来由 `Battle._check_win()`
	#   在"第 3 名阵亡"那一刻就放（那时死亡卡片还在飞、骷髅头还没炸）⇒ 听着是"声先到、演出后到"。
	#   现在放在阵亡/失败演出（`_defeat_anim()`：骷髅头震动 → 状态栏爆炸）**跑完之后**，
	#   与结算面板同时出现。`play_sound = false` 给"主动放弃天梯"那条路用（它本来就没有这一声）。
	#   ⚠️ 回放的结局不走本函数（`Battle._replay_show_result()` 另有入口）⇒ 回放里照旧不播胜负音。
	if play_sound:
		AudioManager.play("win" if win else "lose")
	if _result_overlay != null:
		_result_overlay.queue_free()
	var vsize := get_viewport().get_visible_rect().size
	var overlay := Control.new()
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	if _ladder_gave_up:
		# 放弃天梯：树是暂停的 ⇒ 面板必须能在暂停中收输入（与再确认层同一处理）。
		overlay.process_mode = Node.PROCESS_MODE_WHEN_PAUSED
	add_child(overlay)
	_result_overlay = overlay

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.7)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.add_child(dim)

	var box := VBoxContainer.new()
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 20)
	box.position = Vector2(vsize.x / 2 - 160, vsize.y / 2 - 150)
	box.size = Vector2(320, 300)
	overlay.add_child(box)

	var title := Label.new()
	title.text = "胜　利！" if win else "败　北……"
	title.add_theme_font_size_override("font_size", 52)
	title.add_theme_color_override("font_color", Color(1, 0.85, 0.4) if win else Color(1, 0.45, 0.4))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)

	var sub := Label.new()
	sub.add_theme_font_size_override("font_size", 18)
	# 【2026-09-24 用户要求·天梯模式】结算面板显示连胜：赢了显示"当前连胜"（可点继续挑战）。
	# 【2026-09-25 用户要求·天梯失败面板】失败那一面**只留一句调侃**：
	#   用户原话「我方英雄阵亡达3名和下面那行去掉。最下面那行本轮已结束（...）也去掉。
	#   就写"才x连胜就不行了？你适合打简单难度"」⇒ sub 只写这一句、`qhint`（本轮已结束…）整块删掉。
	#   x = `GameState.ladder_final_streak`（失败那一刻的当前连胜，见 `Battle._ladder_on_match_result()`）。
	var ladder := GameState.ladder_mode != ""
	if ladder:
		var lk := Stats.current_mode_key()
		if win:
			sub.text = "%s · 当前连胜：%d 场" % [LadderStore.mode_name(), Stats.current_streak(lk)]
			sub.add_theme_color_override("font_color", Color(1, 0.86, 0.5))
		else:
			# 【2026-09-25 用户要求】0 连胜单独一句「你好歹赢一场啊」（打输 / 主动放弃都一样 —— 一场没赢，
			#   说"才0连胜"没意思）；有连胜才用下面两种调侃：
			#   打输 = 「才X连胜就不行了？你适合打简单难度」；主动放弃 = 「才X连胜，跑什么？去简单难度偷偷进步啊？」
			#   X 都是"结束那一刻的当前连胜"（= `GameState.ladder_final_streak`）。
			var st := GameState.ladder_final_streak
			if st <= 0:
				sub.text = "你好歹赢一场啊"
			elif _ladder_gave_up:
				sub.text = "才%d连胜，跑什么？去简单难度偷偷进步啊？" % st
			else:
				sub.text = "才%d连胜就不行了？你适合打简单难度" % st
			_ladder_gave_up = false
			sub.add_theme_color_override("font_color", Color(1, 0.7, 0.6))
	else:
		sub.text = "敌方英雄阵亡达 3 名。" if win else "我方英雄阵亡达 3 名。"
		sub.add_theme_color_override("font_color", Color(0.85, 0.9, 1.0))
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(sub)

	box.add_child(_vspacer(12))

	# 【2026-09-24 用户要求·天梯模式】天梯里**不要**「重开 / 返回选人」这两个按钮
	#   （用户原话：「把天梯模式的重开和返回选人按钮删除」）⇒ 结算面板只留：
	#   赢了 =「继续挑战」+「保存并退出」；输了 = 本轮结束，只给「返回主菜单」（退出/结束走暂停界面那两个）。
	if ladder and win:
		# 【2026-09-29·用户贴的 `CONFUSABLE_LOCAL_DECLARATION`】这里原来叫 `again`，而下面**父块**
		#   还有一个 `again`（「再来一局」那颗）⇒ 报警 ⇒ 本块这颗改名 `challenge_btn`（纯换名）。
		var challenge_btn := Button.new()
		challenge_btn.text = "继续挑战"
		challenge_btn.custom_minimum_size = Vector2(260, 52)
		challenge_btn.add_theme_font_size_override("font_size", 20)
		challenge_btn.pressed.connect(_on_restart.bind(true))   # 连胜继续，下一局重新选人/选卡组
		box.add_child(challenge_btn)
		# 【2026-09-24 用户要求·补】胜利面板也要能"存着走"（原来只有继续挑战 ⇒ 想退出只能先进下一局再暂停）
		var save_quit := Button.new()
		save_quit.text = "保存并退出"
		save_quit.custom_minimum_size = Vector2(260, 50)
		save_quit.add_theme_font_size_override("font_size", 20)
		save_quit.pressed.connect(_on_ladder_save_quit)
		box.add_child(save_quit)
		return   # 天梯：结算面板不再有"返回"类按钮（退出走这里或暂停键）
	if ladder and not win:
		# 输了 = 本轮已经结束（存档在 `_ladder_on_match_result()` 里删掉了）⇒ 只剩"回主菜单"一条路；
		# 「保存并退出 / 放弃本次天梯」在**暂停界面**（对局中退出用那两个）。
		var back := Button.new()
		back.text = "返回主菜单"
		back.custom_minimum_size = Vector2(260, 50)
		back.add_theme_font_size_override("font_size", 20)
		back.pressed.connect(_on_back_to_menu)
		box.add_child(back)
		# 【2026-09-25 用户要求】原来这里还有一行小字「本轮已结束（最高连胜 N 场保留）」⇒ **整块删掉**
		#   （用户原话「最下面那行本轮已结束（...）也去掉」）。
		return

	var again := Button.new()
	again.text = "再来一局" if GameState.is_online else "再战一局"
	again.custom_minimum_size = Vector2(260, 52)
	again.add_theme_font_size_override("font_size", 20)
	again.pressed.connect(_on_restart.bind(true))   # 结束后再战一局：竞技场重新选人
	box.add_child(again)
	_rematch_btn = again   # 【2026-09-29】联机"等对方也点再来一局"要改它的文案/可用性
	# 单机/联机都显示：联机由主机权威广播重启（不退出大厅连接）

	var to_menu := Button.new()
	to_menu.text = "返回选卡" if not GameState.is_online else "返回大厅"
	to_menu.custom_minimum_size = Vector2(260, 48)
	to_menu.add_theme_font_size_override("font_size", 18)
	to_menu.pressed.connect(_on_back_to_menu)
	box.add_child(to_menu)

func _vspacer(h: float) -> Control:
	var s := Control.new()
	s.custom_minimum_size = Vector2(0, h)
	return s

# 【2026-09-29·用户要求】联机结算面板「再来一局」的状态文案：
#   双方都没点 = 「再来一局」（可点）· 只有本端点了 = 「等待对方…」（置灰不可重复点）·
#   对方先点了 = 「对方已同意 · 再来一局」（点一下就开局）· 双方都点了 = 「开始新一局…」
func _refresh_rematch_ui() -> void:
	if _rematch_btn == null or not is_instance_valid(_rematch_btn):
		return
	if not GameState.is_online or battle == null or not is_instance_valid(battle):
		return
	var mine: bool = battle.local_rematch_want()
	var peer: bool = battle.peer_rematch_want()
	if mine and peer:
		_rematch_btn.text = "开始新一局…"
		_rematch_btn.disabled = true
	elif mine:
		_rematch_btn.text = "等待对方…"
		_rematch_btn.disabled = true
	elif peer:
		_rematch_btn.text = "对方已同意 · 再来一局"
		_rematch_btn.disabled = false
	else:
		_rematch_btn.text = "再来一局"
		_rematch_btn.disabled = false

# 【2026-09-29·用户要求】「如果有一方退出，则返回联机大厅」：结算后对端回了大厅 ⇒ 本端也回
#   （与「返回大厅」按钮同一条路，只是**不再**回头喊 `leave`，避免两边互相喊）。
func _on_peer_left_to_lobby() -> void:
	if not GameState.is_online:
		return
	GameState.reset_online()
	NetBus.stop()
	get_tree().change_scene_to_file("res://scenes/NetLobby.tscn")

func _on_back_to_menu() -> void:
	if GameState.is_online:
		# 联机（含联机竞技场）：先通知对方"本端离开本局"，再断开并回联机大厅
		if NetBus.is_online:
			NetBus.send_all(JSON.stringify({ "type": "leave" }))
			await get_tree().create_timer(0.2, false).timeout   # 给对方一点时间收包
		GameState.reset_online()
		NetBus.stop()
		get_tree().change_scene_to_file("res://scenes/NetLobby.tscn")
		return
	GameState.arena_mode = false   # 返回选人界面：退出竞技场模式（再来一局时不再走竞技场）
	# 【天梯】回主菜单**不算放弃**（用户拍板）：存档留着，下次进天梯可以继续；
	#   只把"本局属于天梯"这个标记清掉，免得之后玩普通/竞技场被当成天梯局。
	GameState.ladder_mode = ""
	get_tree().change_scene_to_file("res://scenes/Menu.tscn")

# 扣血提醒火焰图标：纯代码自绘（不依赖 emoji 字体），在 _process 里脉动跳动。
class FlameIcon extends Control:
	var _t := 0.0
	var size_px := 30.0

	func _process(dt: float) -> void:
		_t += dt
		queue_redraw()

	func _draw() -> void:
		var c := size / 2.0
		var w := size_px
		var sway := sin(_t * 7.0) * 1.5   # 左右摆动
		var flick := 0.85 + 0.15 * sin(_t * 11.0)   # 亮度抖动
		# 外焰（红橙）— 底部宽圆 + 顶部尖角
		var outer := PackedVector2Array([
			Vector2(c.x - w * 0.34 + sway, c.y + w * 0.42),
			Vector2(c.x - w * 0.18 + sway, c.y + w * 0.08),
			Vector2(c.x, c.y - w * 0.52),
			Vector2(c.x + w * 0.18 + sway, c.y + w * 0.08),
			Vector2(c.x + w * 0.34 + sway, c.y + w * 0.42),
		])
		draw_colored_polygon(outer, Color(1.0, 0.3, 0.1, 0.95 * flick))
		# 内焰（金黄）
		var inner := PackedVector2Array([
			Vector2(c.x - w * 0.14 + sway, c.y + w * 0.3),
			Vector2(c.x - w * 0.05 + sway, c.y - w * 0.1),
			Vector2(c.x, c.y - w * 0.28),
			Vector2(c.x + w * 0.06 + sway, c.y - w * 0.05),
			Vector2(c.x + w * 0.14 + sway, c.y + w * 0.3),
		])
		draw_colored_polygon(inner, Color(1.0, 0.85, 0.3, 0.95 * flick))
		# 焰心（白亮）
		var core := PackedVector2Array([
			Vector2(c.x - w * 0.04 + sway, c.y + w * 0.18),
			Vector2(c.x, c.y - w * 0.05),
			Vector2(c.x + w * 0.05 + sway, c.y + w * 0.18),
		])
		draw_colored_polygon(core, Color(1.0, 1.0, 0.85, 0.9))

# 【2026-09-23 新增·用户要求】顶部阵亡标志的**单个槽**（原来是 `src/DeathMark.gd`，按用户要求
#   改成 HUD 的嵌套类 —— 与 `FlameIcon` 同一写法：界面自己的小控件就写在这里，不另开文件）。
#
# 为什么不是一个拼字符串的 Label（原来是 `"我方 ☠☠☠"`）：
#   ① 用户要求"死亡时卡面飞过去 → **标志出现** → 标志震动摇晃几下" ⇒ 需要能定位到**具体哪一个**
#      要出现的标记（拿它的屏幕矩形当飞行终点）、并只晃它一个；
#   ② 用户要求"**无死亡和有死亡要一样大**" ⇒ 字符串里的 `○`（U+25CB）与 `☠`（U+2620）字形尺寸不同，
#      拼在一起会让整行宽度/圆心位置漂。现在每槽是**固定尺寸方框**、两种标记都**自绘/自算尺寸**
#      （空圈 = `RING_D` 的圆环；骷髅按槽内径缩放）⇒ 整行永不漂。
#      ⚠️ 尺寸口径后来按用户反馈改过两次：先"骷髅太小"（槽 26→34、占比 0.86→0.92），
#      再"圆圈缩小点"（空圈直径单独给 `RING_D = 22`）⇒ **现在骷髅比空圈大**，不再是等大。
#   ③ 用户口径"**有骷髅头死亡标志就不要那个红圈了**" ⇒ 满槽只画骷髅（连淡圆底都不画）。
# `filled` 由 HUD 控制（延迟揭示：卡片落地后才置 true）。尺寸微调改下面 const。
class DeathMark extends Control:
	# 【2026-09-29·用户要求】改用**用户新增的三个素材**（`assets/界面/`）：
	#   **已阵亡 = `死亡标志.png`**；**未阵亡 = `蓝方未死亡标志.png` / `红方未死亡标志.png`**
	#   （按这一行所属的**绝对阵营**取 ⇒ 联机客房里"我方"那排拿到的就是红的那张）。
	#   ⇒ 原来"自绘空圈 + 用 `☠` 字形画骷髅"那一套（连同 `RING_D` / `RING_W` / `RING_PAD` /
	#     `SKULL_FILL` 四个旋钮）**整段退休**：那套是当年为了"空圈与骷髅一样大、整行不漂"手写的，
	#     现在尺寸由素材自己保证。
	# ⚠️ `SLOT_D` 只决定**画多大**：素材等比贴进这个方框（取短边，不拉伸变形）。
	const TEX_DEAD := preload("res://assets/界面/死亡标志.png")
	const TEX_ALIVE_BLUE := preload("res://assets/界面/蓝方未死亡标志.png")
	const TEX_ALIVE_RED := preload("res://assets/界面/红方未死亡标志.png")
	const SLOT_D := 38.0        ## 每槽边长（像素）：素材等比贴进来（2026-09-29 用户「放大死亡标志」20 → 38）
	const SHAKE_PX := 3.0       ## 摇晃幅度（像素）
	const SHAKE_TIMES := 4      ## 摇晃几下（左右各算一下）

	var filled := false          ## false = 未死亡标志（素材：蓝/红）；true = 死亡标志
	var faction := DataRegistry.Faction.PLAYER   ## 这一行属于哪个**绝对阵营**（决定用蓝的还是红的那张）

	# 【2026-09-29·用户贴的 `INT_AS_ENUM_WITHOUT_CAST`】`faction` 是枚举类型（下面那行 `:=`
	#   从 `DataRegistry.Faction.PLAYER` 推出）⇒ 入参原来标 `int` 时赋值会报警 ⇒ 入参也标成枚举。
	func _init(fn: DataRegistry.Faction = DataRegistry.Faction.PLAYER) -> void:
		faction = fn
		custom_minimum_size = Vector2(SLOT_D, SLOT_D)
		size = Vector2(SLOT_D, SLOT_D)
		mouse_filter = Control.MOUSE_FILTER_IGNORE   # 纯显示，不拦鼠标（不挡棋盘点击）
		pivot_offset = Vector2(SLOT_D * 0.5, SLOT_D * 0.5)   # 缩放/摇晃绕中心

	func set_filled(v: bool) -> void:
		if filled == v:
			return
		filled = v
		queue_redraw()

	## HUD 在"卡片落地"那一刻调用：标志先出现（弹出）再摇晃几下。
	func pop_and_shake() -> void:
		if not is_inside_tree():
			return
		pivot_offset = size * 0.5
		var base := position
		scale = Vector2(0.35, 0.35)
		rotation = 0.0
		var t := create_tween()
		t.set_parallel(false)
		# ① 弹出：0.35 → 1.26 → 1.0（BACK 缓动，像"啪"地盖章）
		t.tween_property(self, "scale", Vector2(1.26, 1.26), 0.14).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		t.tween_property(self, "scale", Vector2.ONE, 0.10).set_trans(Tween.TRANS_SINE)
		# ② 摇晃：左右各几下 + 轻微旋转（"震动摇晃几下"）
		for i in SHAKE_TIMES:
			var dx := SHAKE_PX if i % 2 == 0 else -SHAKE_PX
			var rot := 0.16 if i % 2 == 0 else -0.16
			t.tween_property(self, "position", base + Vector2(dx, 0.0), 0.045)
			t.parallel().tween_property(self, "rotation", rot, 0.045)
		# ③ 回中
		t.tween_property(self, "position", base, 0.05)
		t.parallel().tween_property(self, "rotation", 0.0, 0.05)

	func _draw() -> void:
		# 【2026-09-29】直接贴素材：已阵亡 = 死亡标志；未阵亡 = 按**绝对阵营**取蓝/红那张。
		#   等比缩放（取短边）⇒ 68×83 与 81×102 两种素材都不会被拉变形。
		var tex: Texture2D = TEX_DEAD if filled else (TEX_ALIVE_BLUE if faction == DataRegistry.Faction.PLAYER else TEX_ALIVE_RED)
		if tex == null:
			return
		var ts := tex.get_size()
		if ts.x <= 0.0 or ts.y <= 0.0:
			return
		var k := minf(size.x / ts.x, size.y / ts.y)
		var d := ts * k
		draw_texture_rect(tex, Rect2((size - d) * 0.5, d), false)

# 【2026-09-23 新增·用户要求】英雄阵亡演出（一次性节点，演完自毁；同样按用户要求写成 HUD 的嵌套类）：
#   ① **卡面破碎升天**：原地炸成一堆六边形碎片，碎片向上飘散、旋转、淡出；
#   ② **一路引导到上方状态栏的阵亡标志位置**：一枚小卡片（六边形）先升空，再沿弧线飞向状态栏里
#      "下一个要出现的"阵亡标记槽（终点由 HUD 传进来的 Control 决定）；
#   ③ **落地回调**：卡片到达那一刻调用 `on_land` —— HUD 把那个槽置为"已阵亡"（标志出现）并播
#      弹出 + 摇晃。⇒ "标志出现"的时机 = 卡片落地，而不是死亡瞬间。
#
# ⚠️ **headless（RL 跑批 / 无窗口自检）直接跳过整段演出、立刻回调** ⇒ 跑批零额外开销、
#    行为与加这个特效之前**逐位一致**（HUD 那边也会立刻落格，不做延迟揭示）。
# ⚠️ 召唤物（骷髅兵等）不占阵亡标志位：HUD 传 `target = null` ⇒ 只做破碎升天、不飞、不回调。
# 视觉参数微调改下面 const。
class DeathFx extends Control:
	const SHARD_N := 12           ## 碎片个数
	const SHARD_LIFE := 0.5       ## 碎片寿命（秒）
	const SHARD_SPREAD := 46.0    ## 碎片横向散开距离
	const RISE_H := 62.0          ## "升天"高度（像素）
	const RISE_TIME := 0.34       ## 升空时间
	const FLY_TIME := 0.55        ## 从升空顶点飞到标记槽的时间
	const CARD_R := 13.0          ## 飞行卡片（六边形）半径
	const CARD_END_SCALE := 0.5   ## 飞到终点时卡片缩到多小（像被标记"吸进去"）
	const ARC_H := 46.0           ## 飞行弧线向上凸起的高度

	func play(start: Vector2, target: Control, color: Color, on_land: Callable) -> void:
		# 无窗口/跑批：不做演出，直接"落格"（HUD 的延迟揭示因此退化成立即显示 = 老行为）
		if DisplayServer.get_name() == "headless":
			if on_land.is_valid():
				on_land.call()
			queue_free()
			return
		set_anchors_preset(Control.PRESET_FULL_RECT)
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		_make_shards(start, color)
		var token := _make_card(start, color)
		var apex := start + Vector2(0.0, -RISE_H)
		var t := create_tween()
		# ① 升空（碎片同时在飘）
		t.tween_property(token, "position", apex, RISE_TIME).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		t.parallel().tween_property(token, "rotation", 0.55, RISE_TIME)
		t.parallel().tween_property(token, "scale", Vector2.ONE, RISE_TIME).from(Vector2(0.6, 0.6))
		if target == null or not is_instance_valid(target):
			# 召唤物：只破碎升天，不飞、不占标志位
			t.tween_interval(0.12)
			t.tween_callback(queue_free)
			return
		# ② 弧线飞向标记槽
		var dest: Vector2 = target.get_global_transform_with_canvas().origin + target.size * 0.5
		var mid: Vector2 = apex.lerp(dest, 0.5) + Vector2(0.0, -ARC_H)
		t.tween_callback(func(): _burst(dest, color))
		t.tween_method(func(k: float): token.position = _bezier(apex, mid, dest, k), 0.0, 1.0, FLY_TIME) \
			.set_trans(Tween.TRANS_SINE)
		t.parallel().tween_property(token, "scale", Vector2(CARD_END_SCALE, CARD_END_SCALE), FLY_TIME)
		t.parallel().tween_property(token, "rotation", 2.2, FLY_TIME)
		# ③ 落地：标志出现 + 摇晃（交给 HUD），卡片与特效节点收尾
		t.tween_callback(func():
			if on_land.is_valid():
				on_land.call())
		t.tween_interval(0.05)
		t.tween_callback(queue_free)

	# ---- 碎片：把"卡面"炸成一堆小六边形，向上飘散 ----
	func _make_shards(start: Vector2, color: Color) -> void:
		for i in SHARD_N:
			var sh := Polygon2D.new()
			var r := randf_range(3.0, 6.5)
			var pts := PackedVector2Array()
			for k in 6:
				var a := TAU * float(k) / 6.0 + randf() * 0.25
				pts.append(Vector2(cos(a), sin(a)) * r)
			sh.polygon = pts
			var c := color
			sh.color = Color(minf(c.r * randf_range(0.9, 1.35), 1.0), minf(c.g * randf_range(0.9, 1.35), 1.0),
				minf(c.b * randf_range(0.9, 1.35), 1.0), 1.0)
			sh.position = start + Vector2(randf_range(-8.0, 8.0), randf_range(-8.0, 8.0))
			sh.rotation = randf() * TAU
			add_child(sh)
			# 方向：主要向上（-90° 附近散开），带一点横向
			var ang := -PI * 0.5 + randf_range(-0.85, 0.85)
			var dist := SHARD_SPREAD * randf_range(0.6, 1.25)
			var to := sh.position + Vector2(cos(ang), sin(ang)) * dist + Vector2(0.0, -RISE_H * randf_range(0.4, 0.9))
			var st := create_tween()
			st.set_parallel(true)
			st.tween_property(sh, "position", to, SHARD_LIFE).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
			st.tween_property(sh, "rotation", sh.rotation + randf_range(-2.4, 2.4), SHARD_LIFE)
			st.tween_property(sh, "modulate:a", 0.0, SHARD_LIFE).set_delay(SHARD_LIFE * 0.35)
			st.chain().tween_callback(sh.queue_free)

	# ---- 飞行卡片：小六边形（外圈暗、内圈亮，像一枚徽记）----
	func _make_card(start: Vector2, color: Color) -> Node2D:
		var host := Node2D.new()
		host.position = start
		host.scale = Vector2(0.6, 0.6)
		add_child(host)
		var outer := Polygon2D.new()
		outer.polygon = _hex_pts(CARD_R)
		outer.color = Color(color.r * 0.55, color.g * 0.55, color.b * 0.55, 0.95)
		host.add_child(outer)
		var inner := Polygon2D.new()
		inner.polygon = _hex_pts(CARD_R * 0.62)
		inner.color = color
		host.add_child(inner)
		return host

	func _hex_pts(r: float) -> PackedVector2Array:
		var pts := PackedVector2Array()
		for i in 6:
			var a := TAU * float(i) / 6.0 - PI * 0.5   # 尖顶朝上（与棋盘六边形同朝向）
			pts.append(Vector2(cos(a), sin(a)) * r)
		return pts

	# ---- 落地小爆点：6 颗火星向外一闪（让"标志出现"更有手感）----
	func _burst(at: Vector2, color: Color) -> void:
		for i in 6:
			var sp := Polygon2D.new()
			sp.polygon = PackedVector2Array([Vector2(-1.6, -1.6), Vector2(1.6, -1.6), Vector2(1.6, 1.6), Vector2(-1.6, 1.6)])
			sp.color = color
			sp.position = at
			add_child(sp)
			var ang := TAU * float(i) / 6.0 + randf() * 0.3
			var st := create_tween()
			st.set_parallel(true)
			st.tween_property(sp, "position", at + Vector2(cos(ang), sin(ang)) * 15.0, 0.22)
			st.tween_property(sp, "modulate:a", 0.0, 0.22)
			st.chain().tween_callback(sp.queue_free)

	func _bezier(a: Vector2, b: Vector2, c: Vector2, k: float) -> Vector2:
		var u := 1.0 - k
		return u * u * a + 2.0 * u * k * b + k * k * c

# 【2026-09-23 搬家·用户口径「这种小功能不要另起文件」】音量调节控件：原来是 `src/VolumeControl.gd`
#   （带 `class_name VolumeControl`），现在收进 HUD 当嵌套类。**两处宿主**都在用：
#     · 战斗界面：本文件 `_build()` 末尾 `var volume := VolumeControl.new()`（右下角，与左下角喊话按钮对称）
#     · 主菜单：`src/Menu.gd` 里写 `HUD.VolumeControl.new()`（外层类名.嵌套类名 —— 跨文件访问嵌套类就这么写）
#   功能一字未改：自绘喇叭图标（音量 0-3 道声波弧、静音画红斜杠），点击弹出音量滑条面板
#   （独立 `CanvasLayer(70)` 保证盖过宿主 UI，点面板外收起）；音量由 `AudioManager` 统一读写并持久化
#   （`user://audio.cfg`），本控件只是它的界面。
class VolumeControl extends Control:
	const BTN_W := 76.0
	const BTN_H := 40.0
	const PANEL_W := 250.0
	const LAYER := 70

	var _layer: CanvasLayer = null
	var _panel: PanelContainer = null
	var _slider: HSlider = null
	var _val_label: Label = null
	var _vol := 1.0

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP
		custom_minimum_size = Vector2(BTN_W, BTN_H)
		size = Vector2(BTN_W, BTN_H)
		_vol = AudioManager.get_volume()
		queue_redraw()

	# 放视口右上角（宿主为满屏 Control/CanvasLayer 时坐标即视口坐标）
	func place_top_right(vsize: Vector2, margin_x := 8.0, margin_y := 7.0) -> void:
		position = Vector2(vsize.x - margin_x - BTN_W, margin_y)
		size = Vector2(BTN_W, BTN_H)

	# 放视口右下角（如战斗界面，与左下角喊话按钮对称）
	func place_bottom_right(vsize: Vector2, margin_x := 10.0, margin_b := 22.0) -> void:
		position = Vector2(vsize.x - margin_x - BTN_W, vsize.y - margin_b - BTN_H)
		size = Vector2(BTN_W, BTN_H)

	# ---- 自绘喇叭图标 ----
	func _draw() -> void:
		var muted := _vol <= 0.001
		var icon_c := Color(1.0, 0.9, 0.55, 0.95)
		if muted:
			icon_c = Color(1.0, 0.5, 0.45, 0.95)
		var midy := size.y / 2.0
		# 喇叭箱体 + 出声锥口
		var body := PackedVector2Array([
			Vector2(6, midy - 9), Vector2(17, midy - 9), Vector2(17, midy + 9), Vector2(6, midy + 9),
		])
		draw_colored_polygon(body, icon_c)
		var mouth := PackedVector2Array([
			Vector2(17, midy - 9), Vector2(26, midy - 14), Vector2(26, midy + 14), Vector2(17, midy + 9),
		])
		draw_colored_polygon(mouth, icon_c)
		if muted:
			# 静音：红色斜杠
			draw_line(Vector2(29, midy - 11), Vector2(55, midy + 11), Color(1.0, 0.4, 0.35, 0.95), 3.0, true)
			return
		# 按音量画 0-3 道声波弧
		var arcs := clampi(int(ceil(_vol * 3.0)), 0, 3)
		var from := -0.62
		var to := 0.62
		for i in arcs:
			var rad := 7.0 + float(i) * 5.0
			var col := Color(icon_c.r, icon_c.g, icon_c.b, maxf(0.95 - float(i) * 0.22, 0.35))
			draw_arc(Vector2(34.0, midy), rad, from, to, 14, col, 2.0, true)

	func _gui_input(ev: InputEvent) -> void:
		# 与全项目一致：触摸由 Godot 转成鼠标左键事件（安卓/iOS 默认开启），只处理鼠标事件避免双触发
		var mb := ev as InputEventMouseButton
		if mb == null or not mb.pressed or mb.button_index != MOUSE_BUTTON_LEFT:
			return
		_toggle()
		accept_event()

	func _toggle() -> void:
		if _layer != null and is_instance_valid(_layer):
			_close_panel()
		else:
			_open_panel()

	# ---- 弹层（独立 CanvasLayer，全屏遮罩点外面即收起）----
	func _open_panel() -> void:
		if _layer != null and is_instance_valid(_layer):
			return
		var layer := CanvasLayer.new()
		layer.layer = LAYER
		add_child(layer)
		_layer = layer
		var overlay := Control.new()
		overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
		overlay.mouse_filter = Control.MOUSE_FILTER_STOP
		overlay.gui_input.connect(_on_overlay_input)
		layer.add_child(overlay)
		# 半透明压暗背景（只轻微压暗，聚焦滑条）
		var dim := ColorRect.new()
		dim.color = Color(0, 0, 0, 0.22)
		dim.set_anchors_preset(Control.PRESET_FULL_RECT)
		dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
		overlay.add_child(dim)
		# 面板：右上角喇叭按钮下方
		var panel := PanelContainer.new()
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0.08, 0.1, 0.16, 0.95)
		sb.corner_radius_top_left = 10
		sb.corner_radius_top_right = 10
		sb.corner_radius_bottom_left = 10
		sb.corner_radius_bottom_right = 10
		sb.set_border_width_all(1)
		sb.border_color = Color(1.0, 0.85, 0.5, 0.8)
		sb.content_margin_left = 14.0
		sb.content_margin_right = 14.0
		sb.content_margin_top = 12.0
		sb.content_margin_bottom = 12.0
		panel.add_theme_stylebox_override("panel", sb)
		panel.mouse_filter = Control.MOUSE_FILTER_STOP
		overlay.add_child(panel)
		_panel = panel
		var v := VBoxContainer.new()
		v.add_theme_constant_override("separation", 10)
		panel.add_child(v)
		var title := Label.new()
		title.text = "音效音量"
		title.add_theme_font_size_override("font_size", 17)
		title.add_theme_color_override("font_color", Color(1.0, 0.85, 0.5))
		title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		v.add_child(title)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		v.add_child(row)
		var slider := HSlider.new()
		slider.min_value = 0.0
		slider.max_value = 100.0
		slider.step = 1.0
		slider.custom_minimum_size = Vector2(150, 40)
		slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		slider.value = clampf(roundf(_vol * 100.0), 0.0, 100.0)
		slider.value_changed.connect(_on_volume_changed)
		# 松手后播一声"选择"音效，让玩家听到调节效果
		slider.drag_ended.connect(func(_changed: bool): AudioManager.play("select"))
		row.add_child(slider)
		_slider = slider
		var val := Label.new()
		val.text = _pct_text(int(slider.value))
		val.add_theme_font_size_override("font_size", 18)
		val.add_theme_color_override("font_color", Color(0.9, 0.93, 1.0))
		val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		val.custom_minimum_size = Vector2(52, 40)
		val.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		row.add_child(val)
		_val_label = val
		var hint := Label.new()
		hint.text = "0 为静音 · 点喇叭/面板外收起"
		hint.add_theme_font_size_override("font_size", 12)
		hint.add_theme_color_override("font_color", Color(0.7, 0.75, 0.85))
		hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		v.add_child(hint)
		# 定位：与喇叭按钮同侧对齐；按钮贴近上/下边缘时弹层自动改向另一侧，避免出屏
		panel.reset_size()
		var pw: float = maxf(panel.get_combined_minimum_size().x, PANEL_W)
		panel.custom_minimum_size = Vector2(pw, 0)
		panel.size = Vector2(pw, panel.get_combined_minimum_size().y)
		var gp := get_global_position()
		var gv := get_viewport().get_visible_rect().size
		var px := gp.x + BTN_W - pw
		px = clampf(px, 6.0, maxf(6.0, gv.x - pw - 6.0))
		var ph: float = panel.size.y
		var py := gp.y + BTN_H + 6.0
		if py + ph > gv.y - 6.0:
			py = maxf(6.0, gp.y - ph - 6.0)   # 贴底时向上弹
		panel.position = Vector2(px, py)

	func _pct_text(p: int) -> String:
		if p <= 0:
			return "静音"
		return "%d%%" % p

	func _on_volume_changed(v: float) -> void:
		var vol := clampf(v / 100.0, 0.0, 1.0)
		AudioManager.set_volume(vol)
		_vol = vol
		if _val_label != null and is_instance_valid(_val_label):
			_val_label.text = _pct_text(int(roundf(v)))
		queue_redraw()

	func _on_overlay_input(ev: InputEvent) -> void:
		var mb := ev as InputEventMouseButton
		if mb == null or not mb.pressed or mb.button_index != MOUSE_BUTTON_LEFT:
			return
		_close_panel()
		accept_event()

	func _close_panel() -> void:
		if _layer != null and is_instance_valid(_layer):
			_layer.queue_free()
		_layer = null
		_panel = null
		_slider = null
		_val_label = null
		queue_redraw()

# 【2026-09-28·新增·用户要求】击杀演出：击杀者的**卡面**从屏幕左外滑进画面**正中央**，在画面里**停顿一下**，
#   再加速冲出右外并淡掉；身后拖一条**阵营色拖影**（本色残影 + 一条渐隐色带 + 一层同色柔光）。
#   【同日第二次口径】「英雄滑出来之后要在画面里停顿一下」⇒ 由"一路滑过"改成三段：
#     ① 滑入 `SLIDE_IN`（缓出，到位自然减速）→ ② 停住 `HOLD`（画面正中不动，拖影在 `TRAIL_OFF` 内收掉）
#     → ③ 冲出去 `SLIDE_OUT`（缓入加速 + 淡出）。
#   【同日第三次口径】「先出动画，然后在击杀」+「等击杀特效结束、滑出的英雄图案彻底消失后，英雄再开始击杀对方」
#     ⇒ 改成**开打前的预告**：由 `Battle._kill_intro()` 预判致死时发 `kill_intro_requested`，Battle 停在原地等
#     本节点整段播完、回调 `battle.kill_intro_finished()` 之后才继续前冲/开火/结算（死亡演出因此天然在后）。
#   【同日第五次口径】「拖影不要一整块，增加点层次感」+「残影不要斜线」⇒ 拖影拆成**三层等宽色带 +
#     速度线 + 同水平线的分层残影**（没有斜边、没有斜向排布），见 `_draw()` / `_band()` / `SPEED_LINES`。
#   · 建房与触发见 `HUD._on_kill_intro()`；触发点 = `Battle._do_attack()`（普攻）与 `_play_counter()`（反击）。
#   · headless（跑批 / 无窗口自检）在建的时候就短路自毁 ⇒ 零开销、时序不变。
#   · 想调观感全在这个类顶部：`H_MUL` 卡面多高 / 三段时长 `SLIDE_IN`·`HOLD`·`SLIDE_OUT` /
#     `TRAIL_OFF` 到位后多久收掉拖影 / `GHOST_N` 残影个数 / `GHOST_STEP` 残影间距（卡面宽倍数）/
#     `TRAIL_A` 色带最亮处的透明度。想让"停顿"更久只改 `HOLD`。
class KillFx extends Control:
	const H_MUL := 0.42         # 卡面高 = 屏高 × 该值（再按"宽不超过半屏"收一次）
	const Y_CENTER := 0.575     # 卡面**纵向中心** = 屏高 × 该值（0.5 = 正中）。【2026-09-28·用户口径「位置再往下走一点」】0.5 → 0.575；想更低就加大（0.65 就到队伍栏那一带了）
	const SLIDE_IN := 0.40      # ① 从左外滑到画面正中
	const HOLD := 0.50          # ② 在画面里停顿
	const SLIDE_OUT := 0.26     # ③ 冲出右外（同时淡出）
	const TRAIL_OFF := 0.16     # 到位后多久把拖影收干净（这段时间算在 `HOLD` 里）
	const GHOST_N := 5          # 身后本色残影个数
	const GHOST_STEP := 0.055   # 残影间距 = 卡面宽 × 该值
	const TRAIL_A := 0.55       # （旧口径：单块色带的透明度；现在拖影分三层，见 `_draw()` 里的 `_band` 调用）
	# 【2026-09-28·用户口径「不要一整块，增加点层次感」】速度线：`x` = 纵向偏移（卡面高的倍数）、
	#   `y` = 长度（卡面宽的倍数）—— 几条长短不一的高光细线，上下错开 ⇒ 有"擦过去"的层次。
	const SPEED_LINES: Array[Vector2] = [
		Vector2(-0.30, 1.35), Vector2(0.22, 0.95), Vector2(-0.12, 1.10), Vector2(0.34, 0.72)]
	var _tex: Texture2D = null
	var _col := Color.WHITE
	var _p := 0.0               # 位置参数：0 = 屏幕左外，0.5 = 画面正中，1 = 右外
	var _trail := 1.0           # 拖影强度（停住时为 0）
	var _yoff := 0.0            # 纵向错开（连杀/群杀时用，单位 = 屏高比例）

	func play(tex: Texture2D, col: Color, yoff: float = 0.0, on_done: Callable = Callable()) -> void:
		_tex = tex
		_col = col
		_yoff = yoff
		if DisplayServer.get_name() == "headless":
			if on_done.is_valid():
				on_done.call()   # 跑批/无窗口：不演，但要立刻放行 Battle 的等待
			queue_free()
			return
		set_anchors_preset(Control.PRESET_FULL_RECT)
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		var t := create_tween()
		# ① 滑入：缓出（快到位置时慢下来，像"刹住"）
		t.tween_method(_set_p, 0.0, 0.5, SLIDE_IN).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		# ② 到位就把拖影收掉（"停住了"的视觉信号），剩下的时间原地**停顿**
		t.tween_method(_set_trail, 1.0, 0.0, TRAIL_OFF)
		t.tween_interval(maxf(HOLD - TRAIL_OFF, 0.05))
		# ③ 再冲出去：缓入加速 + 拖着拖影淡出；**整段播完**才回调（`Battle` 等这个回调才继续击杀）
		t.tween_method(_set_p, 0.5, 1.0, SLIDE_OUT).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
		t.parallel().tween_method(_set_trail, 0.0, 1.0, 0.12)
		t.parallel().tween_property(self, "modulate:a", 0.0, SLIDE_OUT)
		t.tween_callback(func():
			if on_done.is_valid():
				on_done.call()
			queue_free())

	func _set_p(v: float) -> void:
		_p = v
		queue_redraw()

	func _set_trail(v: float) -> void:
		_trail = clampf(v, 0.0, 1.0)
		queue_redraw()

	func _draw() -> void:
		if _tex == null:
			return
		var vs := size
		if vs.x <= 1.0 or vs.y <= 1.0:
			vs = get_viewport().get_visible_rect().size
		var ts := _tex.get_size()
		if ts.x <= 0.0 or ts.y <= 0.0:
			return
		# 卡面尺寸：高 = 屏高 × H_MUL，同时宽不超过半屏（个别英雄图很宽）
		var fit := minf((vs.y * H_MUL) / ts.y, (vs.x * 0.5) / ts.x)
		var dsz := ts * fit
		var cy := vs.y * (Y_CENTER + _yoff)
		# 位置：`_p = 0.5` 时左边缘 = (屏宽 − 卡宽)/2 ⇒ **正好居中**
		var pos := Vector2(lerpf(-dsz.x, vs.x, _p), cy - dsz.y * 0.5)
		# 【2026-09-29·同 `_make_name_plate` 那条】`tr` 会遮蔽 `Object.tr()` ⇒ 改名 `trail`（纯换名）
		var trail := _trail
		if trail > 0.001:
			# 【2026-09-28·用户口径「拖影不要一整块，增加点层次感」】拖影改成**五层**：
			#   ① 外层柔光带（最高最淡最长）→ ② 主体色带（中层）→ ③ 亮芯（窄而亮，压在最上面）
			#   → ④ 几条长短不一的速度线（上下错开，给"擦过去"的质感）→ ⑤ 卡面本色残影（逐张变淡）。
			#   【同日再一句「残影不要斜线」】三块色带一律**等宽矩形**（原来头高尾细 ⇒ 上下两条斜边），
			#   残影也一律同一水平线 ⇒ 整个拖影只有水平方向的层次，没有斜线。想更干净就删掉 ①/④ 或调小 GHOST_N。
			var x_head := pos.x + dsz.x * 0.30
			_band(x_head - dsz.x * 2.4, x_head, cy, dsz.y * 0.26, 0.20 * trail)
			_band(x_head - dsz.x * 1.8, x_head, cy, dsz.y * 0.17, 0.40 * trail)
			_band(x_head - dsz.x * 1.2, x_head, cy, dsz.y * 0.055, 0.75 * trail)
			for s: Vector2 in SPEED_LINES:
				var sy := cy + dsz.y * s.x
				var slen := dsz.x * s.y
				draw_line(Vector2(x_head - dsz.x * 0.15 - slen, sy), Vector2(x_head, sy),
					Color(_col.r, _col.g, _col.b, 0.45 * trail), maxf(1.5, dsz.y * 0.012), true)
			for i in range(GHOST_N, 0, -1):
				var gx := pos.x - dsz.x * GHOST_STEP * float(i)
				var ga := 0.34 * (1.0 - float(i - 1) / float(GHOST_N)) * trail
				# 【2026-09-28·用户口径「残影不要斜线」】残影一律**同一水平线**排开（原来每张往下错 1.2% 卡高，
				#   叠起来像一条往下的斜线）⇒ y 恒等于卡面 y。
				draw_texture_rect(_tex, Rect2(Vector2(gx, pos.y), dsz), false, Color(_col.r, _col.g, _col.b, ga))
		# ③ 身后同色柔光（让卡面边缘带一圈阵营色）+ ④ 卡面本体（不染色，保持原色；停顿时就靠它撑住画面）
		draw_texture_rect(_tex, Rect2(pos - dsz * 0.03, dsz * 1.06), false, Color(_col.r, _col.g, _col.b, 0.5))
		draw_texture_rect(_tex, Rect2(pos, dsz), false, Color.WHITE)

	## 一条**等宽**的水平渐隐色带（`hh` = 半高、`a` = 头端最亮处的透明度，尾巴渐隐到 0）。
	## 【2026-09-28·用户口径「残影不要斜线」】原来这里是头高尾细的锥形（上下两条斜边）⇒ 改成矩形。
	func _band(x_tail: float, x_head: float, y: float, hh: float, a: float) -> void:
		draw_polygon(PackedVector2Array([
				Vector2(x_tail, y - hh), Vector2(x_head, y - hh),
				Vector2(x_head, y + hh), Vector2(x_tail, y + hh)]),
			PackedColorArray([
				Color(_col.r, _col.g, _col.b, 0.0), Color(_col.r, _col.g, _col.b, a),
				Color(_col.r, _col.g, _col.b, a), Color(_col.r, _col.g, _col.b, 0.0)]))

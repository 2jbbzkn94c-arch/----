class_name Unit
extends Node2D
## 棋盘上的英雄单位。负责绘制自身外形、记录属性/所在格、承担伤害与死亡。

signal died(unit: Unit)
# 【2026-09-23 新增·用户要求】死亡**瞬间**发的信号（`died` 是 0.3s 后发的那一个，挂的是墓碑/替补/胜负）；
#   HUD 接它播"卡面破碎升天 → 飞向顶部阵亡标志"的特效。headless 不发（跑批零开销）。
signal dying(unit: Unit)
signal hp_changed(unit: Unit)
signal damaged(unit: Unit, amount: int)   # 实际受到伤害（含重伤加成）

static var _id_counter := 0

var id := ""
var hero_id := ""
var display_name := ""
var faction: int = DataRegistry.Faction.PLAYER
var attack_type: int = DataRegistry.AttackType.MELEE
var max_hp := 10
var hp := 10
var atk := 4
var move_range := 3
var attack_range := 1
var skills: Array = []

var cell := Vector2i(0, 0)
var alive := true
var moved_this_turn := false
var attacked_this_turn := false
var counter_used_this_turn := false  # 近战被动阶段每回合只能反击一次
var last_move_dist := 0              # 最近一次移动的距离（风语者回血用）
var once_this_turn := false          # 每回合限一次类技能（圣光等）
var death_cause := ""                # 死因描述（阵亡排查用）：take_damage 记录最后一次有效伤害来源

# 状态效果（字典：状态名 -> 值）。见 DataRegistry.Status / Effects
var statuses: Dictionary = {}
# 本回合临时增益/减益（攻击、移动力增减，回合结束时重置）
var atk_buff := 0
var move_buff := 0
var echo_set := -1              # 共鸣者：本回合攻击力"变为"所有队友攻击力之和(-1=未激活)。己方回合结束重置
var branch_override := false   # 血锁：射程+2 且只能直线攻击
var ramble_bonus := 0          # 大大骑士冲锋后攻击上升量
var sun_bonus := 0             # 太阳斩：登场攻击+3，每次攻击/反击后-1，直到恢复正常
var perm_atk := 0              # 永久攻击加成（金矿 hero_42 / 涌电技师 hero_38 各 +1），变身重置攻击力时保留
# 圣诞老人道具的一次性 buff：拾取后在下一次对应动作时生效，用掉即消失
# 【2026-09-30·用户口径「将攻击力buff的加成为2」】攻击道具那笔 = `Battle.ATK_ITEM_BUFF`（现役 **2**，
#   原来写死 1）——见 `Battle._pickup_buff_at_cell()` 的 `"atk"` 分支；AI 模拟侧读同一个常量。
var atk_use_buff := 0          # 攻击道具 buff：下一次攻击伤害 + 该项（现役 2），攻击结算后清零
var move_use_buff := 0         # 移动 buff：下一次移动力+ 该项，移动后自减
var transform_base_id := ""    # 古灵精怪：变身后回溯本源（hero_28），便于每回合重新变身
var last_transform_id := ""    # 古灵精怪：上一次变身后为了不重复变成同一对象
var summon_owner := ""         # 召唤者的单位 id（死灵法师召唤的骷髅兵：主人阵亡时随之消散）
var behavior: HeroBase = null  # 该单位所属英雄的行为脚本（HeroRegistry 创建），技能逻辑分发用
var los_ignore := false    # 坠炮手(hero_45)：攻击弹道无视障碍/单位/墓碑阻挡
var grave_moved := false  # 暗域占据死亡格时：墓碑已回退到暗域原格，避免在死亡格重复立碑

var hex_radius := 44.0

# 【2026-09-29·用户报「英雄背景的颜色没有填满六边形」】阵营**底色那一层**要铺到格子边界：
#   病灶：`Battle` 建棋子时给的是 `hex_size * 0.9`（棋子本体故意比格子小一圈），而底色与本体共用
#   同一个多边形 ⇒ 底色边缘离格子边界还差 10%（≈8px），露出的那圈地面看着就是"颜色没填满"。
#   ⇒ 底色单独放大 `FACTION_HEX_FILL` 倍，**本体（人物图）与所有标记仍按 `hex_radius` 走**（人物大小不变）。
#   ⚠️ 原来取 1.10（≈0.99 格半径，只给格线留 0.69px）：当时底色是半透明的 ⇒ 压住格线也只是"发浑"一点；
#     底色改**不透明**之后（见 `_faction_color`）就变成**真的把格线吃掉一块**：
#     黑线宽 2.8px、画在格边上（两侧各 1.4px），而棋子边离格边只有 0.69px ⇒ 每枚棋子各吃掉格线 0.71px。
#   【2026-09-30·用户报「两个棋子交界处的线和其他线粗细不一样了」】就是上面这条：两枚棋子夹着的那条线
#     被两边各吃 0.71px ⇒ 只剩 **1.38px**（一边有棋子 2.09px、两边都没棋子 2.80px）—— 三种粗细。
#   ⇒ 收到 **1.08**：棋子 apothem 66.85px、格边 68.79px ⇒ 让出 **1.94px ≥ 格线半宽 1.4px**
#     ⇒ 任何情况下棋子都碰不到格线，全场格线一律 2.8px（棋子半径只少了 1.2px，肉眼几乎看不出）。
#     想再收一点就调小（1.0 = 与人物一样大、退回改动前），想更满就调到 1.111（会重新吃线）。
const FACTION_HEX_FILL := 1.08

# 【2026-09-28·用户口径】棋子内部的**图层契约**：
#   · **0 = 背景**：`_hex`（阵营色六边形）与 `_art_hex`（人物图）；
#   · `FRAME_Z`（相对）**= 框/标识**：选中金框、被动光环、行动(红橙)描边、治疗/变身粒子环；
#   · `MARKER_Z`（相对）**= 前景标记**：状态字 / 攻击图标+数字 / 血量图标+数字；
#   · `ACTION_Z`（**绝对**）**= 行动点**：可移动绿点 / 可攻击红点 / 旧的 ● 单点（见下面的例外说明）；
#   · 附体魂线（在 `Battle.gd` 里 `_possess_link_view.z_index = 13`）压在标记之上。
#   ⇒ 顺序：背景 < 框 < 标记 < 魂线 < 行动点。依据：
#     ① 2026-09-28 用户报「高亮框压到攻击/血量上」——图标贴到六边形斜边时会被选中金框切一道 ⇒ 标记必须在框之上；
#     ② 用户口径「标记要在背景之上、附体射线之下」⇒ 魂线仍压在标记之上（比选中棋子的 10+MARKER_Z 高一档）；
#     ③ 行动点（绿/红/●）**例外**：它画在六边形**顶部内侧**（`0.58r`）而不是外面 —— 六边形外面那块空隙
#        会被"上邻的特性字"吃掉（字挂在上邻牌面下沿 `0.72r~1.0r`，换算到我们头顶 ≈ `0.53r~0.73r`），
#        用户 2026-09-28 两次口径「不要被上面英雄的特性挡住」「下面点啊」⇒ 位置下移、层再给到最高。
#   调层只改这三个常量 + Battle 里那一个值；`_build_visual()` 末尾按名单统一套 `MARKER_Z`。
const FRAME_Z := 1
const MARKER_Z := 2
# 行动点专用：**绝对**层（配合 `z_as_relative = false`）⇒ 任何棋子自己的东西都盖不住它
# （选中抬到 10 的棋子最高也才 12），也高于魂线(13)；仍低于礼物(20)/远程射线(30)/飘字(120)。
const ACTION_Z := 14

var _hex: Polygon2D
var _art_hex: Polygon2D          # 【2026-09-27】人物本体那一层（贴在纯色六边形之上；没出图的英雄为 null 效果）
var _shadow: Polygon2D = null    # 【2026-09-30】棋子投影（相对 −1：垫在底色之下，**只画轮廓外的月牙带**；`SHADOW_DROP = 0` 时不建）
var _dome: Polygon2D = null      # 【2026-09-30】穹顶渐变（上亮下暗、无轮廓；见 `DOME_*` 常量）
var _art: Texture2D = null       # 英雄卡面图（`DataRegistry.hero_card_art`）；null = 还没出图 ⇒ 保持原来的纯色棋子
var _label: Label
var _atk_label: Label
var _hp_label: Label
var _status_label: Label
var _debuff_label: Label   # 减益小字(紫)：毒/伤/麻/冻/默/晕/附
var _shield_aura: ShieldAura = null   # [圣盾] 金黄透明罩（演出节点，类在本文件末尾）
var _tags_label: Label
var _passive_border: Line2D
var _passive_tween: Tween
var _sel_border: Line2D = null   # 金色选中描边（选中时叠加在单位六边形上）
var _atk_icon_center := Vector2.ZERO   # 攻击图标中心（_init 按棋盘缩算好，变身换图时复用）
var _atk_icon_box := 0.0               # 攻击图标框大小（同上）
var _acting_border: Line2D = null     # 敌方AI"正在行动"描边（红橙脉冲，区别于金色选中边）
var _acting_tween: Tween
var _action_dot: Label   # 本回合仍有行动的顶部标识（旧，保留兼容）
var _move_dot: Label      # 可移动标识（绿色）
var _attack_dot: Label    # 可攻击标识（红色）
var _marker_host: Control # 红绿标识容器（整体居中）
var _was_counter_damage := false   # 本次受伤是否为反击伤害
var _dmg_style := 0                # 本次受击伤害数字样式：0=普通 2=重击(紫/放大), Battle 施加前标记
var _shield_block_status := false  # 本次"带状态攻击"被圣盾整段挡下:伤害与后续状态都不生效

func _init(def: DataRegistry.HeroDef, faction_ := 0, cell_ := Vector2i.ZERO, radius: float = 44.0) -> void:
	hero_id = def.id
	display_name = def.display_name
	faction = faction_
	attack_type = def.attack_type
	max_hp = def.max_hp
	atk = def.atk
	move_range = def.move_range
	attack_range = def.attack_range
	skills = def.skills.duplicate()
	# 坠炮手：射程=全场(99)、弹道无视阻挡（无视阻挡判定由 Battle 各视线入口读 los_ignore）
	if def.id == "hero_45":
		attack_range = 99
		los_ignore = true
	hp = max_hp
	cell = cell_
	hex_radius = radius
	_id_counter += 1
	id = "unit_%d" % _id_counter

func _ready() -> void:
	z_index = 2
	_build_visual()
	_refresh_shield_aura()   # 开局就带 [圣盾] 的（波盾全队盾 / 开局圣盾道具）也要有罩

func _build_visual() -> void:
	var fs := hex_radius / 39.0   # 字号缩放系数：棋子随 hex_size 放大时文字等比放大（基准 48*0.82≈39）
	_hex = Polygon2D.new()
	# 【2026-09-29·用户报「英雄背景的颜色没有填满六边形」】底色单独放大到铺满格子（见 `FACTION_HEX_FILL`）
	_hex.polygon = _hex_points(hex_radius * FACTION_HEX_FILL)
	_hex.color = _faction_color(faction)
	add_child(_hex)
	# 【2026-09-30·用户口径「将英雄的棋子立体感增加」】投影：垫在底色**之下**（相对 −1 ⇒ 绝对 1，
	#   低于本棋子的 2），整体往下偏一点 ⇒ 看着像"立"在棋盘上（`SHADOW_DROP = 0` 时整块不建）。
	if SHADOW_DROP > 0.0:
		_shadow = Polygon2D.new()
		# 【2026-09-30·用户报「六边形里面还有一个六边形形状的阴影」】⚠️ 投影**不能画成"整体下移的六边形"**：
		#   压在棋子底下那一块毫无用处（今天底色不透明 ⇒ 被盖住；今天之前底色半透明 ⇒ 会**透出来**，
		#   它的边就是一条"错位的小六边形"轮廓，正是用户原话「阴影的外框没有贴合实际六边形格子」）。
		#   ⇒ 只画**棋子轮廓外面那一圈**（月牙带 = 下移后的下半圈 − 原下半圈），棋子底下一点都不画。
		_shadow.polygon = _shadow_crescent(_hex_points(hex_radius * FACTION_HEX_FILL), SHADOW_DROP * fs)
		_shadow.color = Color(0.02, 0.01, 0.01, SHADOW_ALPHA)
		_shadow.z_index = -1
		add_child(_shadow)

	# 【2026-09-27·用户要求】棋子上也放"人物本体"：在纯色六边形**之上**再贴一层同多边形的贴图
	#   （`Polygon2D` 自带"按多边形裁剪" ⇒ 放大到顶满也不溢出卡边）。
	#   底下那层纯色没撤 ⇒ **阵营色（我方蓝 / 敌方红）仍从人物四周透出来**，与选人卡一个观感；
	#   贴图层用白色（= 不染色），人物保持原色。
	_art = DataRegistry.hero_card_art(display_name)
	_art_hex = Polygon2D.new()
	# 【2026-09-29】人物图这一层**仍按 `hex_radius`**（不再跟着底色放大）——
	#   与底色的多边形解耦：底色铺满整格，人物保持原来大小（取景/`HERO_ART_FIT` 微调口径不变）。
	_art_hex.polygon = _hex_points(hex_radius)
	_art_hex.color = Color(1, 1, 1, 1)
	# 【2026-09-27·用户报"糊 + 锯齿"】图带 mipmap，必须显式开 `LINEAR_WITH_MIPMAPS` 才会用到；
	#   棋子只有 ~146px 宽而图是 512 ⇒ 无 mipmap 的缩小采样就是锯齿+发糊的来源。
	_art_hex.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	# 图被多边形裁掉的那两条边（顶/底，因为人顶满了）也做抗锯齿
	_art_hex.antialiased = true
	add_child(_art_hex)
	_apply_hex_art()
	# 【2026-09-30·用户口径「将英雄的棋子立体感增加 / 不要有那么明显的一个框」】穹顶渐变：
	#   贴着六边形（`_hex_points`，与人物图同一形状）铺一层竖向渐变 —— 上亮 → 中间透明 → 下暗，
	#   **只按上下打光、不勾任何轮廓** ⇒ 整块看着是凸起来的，而不是"描了个框"。
	#   UV 按六边形的包围盒归一化（Ⅴ 从上到下 0→1），所以渐变正好铺满这一格。
	# 【2026-09-30·用户口径「把卡面 上面白 下面黑的效果去掉」】⇒ 竖向那两段（`DOME_TOP_A` / `DOME_BOTTOM_A`）
	#   都写成 **0**，这层现在**只剩左右那点收边暗部**（`DOME_SIDE_A`）。⚠️ 因此这里的开关必须把
	#   `DOME_SIDE_A` 也算上 —— 否则竖向一归零、整层不建，左右分量会跟着一起消失（用户要的是"只去掉上下"）。
	#   三个都写 0 = 整层不建（棋子 = 平的阵营底色 + 投影）。
	if DOME_TOP_A > 0.0 or DOME_BOTTOM_A > 0.0 or DOME_SIDE_A > 0.0:
		_dome = Polygon2D.new()
		# ⚠️ 【2026-09-30·用户报「六边形里面还有一个六边形形状的阴影」】多边形必须与底色**完全同形同大**
		#   （也乘 `FACTION_HEX_FILL`）：原来用的是 `hex_radius` ⇒ 渐变只铺到"人物图那一圈"（底色的 0.909），
		#   底色外圈没被压暗 ⇒ 底下那圈亮边又读成一个内嵌的小六边形（用户说"像之前背景没占满格子"）。
		var poly := _hex_points(hex_radius * FACTION_HEX_FILL)
		_dome.polygon = poly
		var gt := _make_dome_texture()
		_dome.uv = _bbox_uv(poly, Vector2(gt.get_width(), gt.get_height()))   # ⚠️ uv 单位 = 贴图像素（见 `_bbox_uv`）
		_dome.texture = gt
		_dome.z_index = FRAME_Z   # 压人物图(0)之上、标记(MARKER_Z)之下
		add_child(_dome)
	# 【2026-09-30·用户报「为什么六边形里面还有一个六边形形状的阴影」】⚠️ **凡是"按到六边形边界的
	#   距离"算的明暗，都会在棋子里面画出一个小一号的六边形**（第四/五版那层 `_edge` 就是这么来的：
	#   它沿着六条边铺一圈渐变 ⇒ 看着像"六边形里套了个六边形"；改成方向权重也只是淡一点，形状还在）。
	#   ⇒ **整层删掉**，立体感只由"竖向渐变（`_dome`）+ 投影"两样给：
	#   明暗只随**上下**变化，完全不跟六边形的轮廓走 ⇒ 里面不会再出现第二个六边形。

	# 名字行（**只在"这张卡还没有卡面图"时建**，规则见 `_update_name_label`）
	_update_name_label()

	# 数值图标簇：【2026-09-27·用户要求「攻击和血量图标分别往左上和右上移动」】原来是左下/右下，
	#   会压在人物身上 ⇒ 现在摆在**上排两侧**（左=攻击、右=爱心），中间留给人物。
	#   ⚠️ y 取 −0.52r 是"还在六边形内"的极限：六边形在高度 y 处的半宽 = r − y/√3，
	#   而图标框半宽 = 0.35r ⇒ 0.52r/√3 = 0.30r ⇒ 0.70r > 0.69r，刚好不探出斜边。
	var num_icon_w := hex_radius * 0.55   # 剑（攻击）的框大小
	var hp_icon_w := num_icon_w * 1.3   # 爱心单独放大：比剑大 10%；想更大就加大系数并配合把 hp_c.x 往左调
	var atk_c := Vector2(-hex_radius * 0.7, hex_radius * 0.3)
	var hp_c := Vector2(hex_radius * 0.7, hex_radius * 0.3)   # 爱心中心（大爱心需稍左移避免出右边框）
	# 攻击图标：后勤角色用齿轮图，其次远程用弩图，最后近战用原剑图。
	# 位置/尺寸记到成员上，变身改了词条或攻击类型后 update_atk_icon() 才能就地换图不跑位。
	_atk_icon_center = atk_c
	_atk_icon_box = num_icon_w
	var atk_icon := _make_stat_icon(_atk_icon_path(), atk_c, num_icon_w)
	if atk_icon != null:
		atk_icon.name = "AtkIcon"
		add_child(atk_icon)
	_atk_label = Label.new()
	_atk_label.add_theme_font_size_override("font_size", int(17.0 * fs))
	_atk_label.add_theme_font_override("font", DataRegistry.stat_bold_font())   # 数字加粗
	_atk_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_atk_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_atk_label.size = Vector2(num_icon_w, num_icon_w * 0.8)
	_atk_label.position = atk_c - _atk_label.size / 2.0 + Vector2(0, -num_icon_w * 0.1)
	_atk_label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0))
	_atk_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.95))
	_atk_label.add_theme_constant_override("outline_size", maxi(4, int(5.0 * fs)))
	add_child(_atk_label)
	_update_atk_label()

	var hp_icon := _make_stat_icon(DataRegistry.ICON_HEART, hp_c, hp_icon_w)
	if hp_icon != null:
		hp_icon.name = "HpHeart"
		add_child(hp_icon)
	_hp_label = Label.new()
	_hp_label.add_theme_font_size_override("font_size", int(17.0 * fs))
	_hp_label.add_theme_font_override("font", DataRegistry.stat_bold_font())   # 数字加粗
	_hp_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hp_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_hp_label.size = Vector2(hp_icon_w , hp_icon_w * 0.8)
	# 血量数字相对爱心中心：右移 0.12×爱心框、下移 0.06×爱心框
	_hp_label.position = hp_c - _hp_label.size / 2.0 + Vector2(hp_icon_w * 0.001, hp_icon_w * 0.06)
	_hp_label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0))
	_hp_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.95))
	_hp_label.add_theme_constant_override("outline_size", maxi(4, int(5.0 * fs)))
	add_child(_hp_label)
	_update_hp_label()

	# 技能词条（嘲/疾/渗/勤/候）——放在卡面名字上方（六边形顶部区域）
	if _skill_tags() != "":
		_ensure_tags_label()

	# 增益状态标签（坚固 金色，居中）+ 减益紫(debuff_label) 分开；[圣盾] 不画字（表现是那圈金黄罩）
	_status_label = Label.new()
	_status_label.add_theme_font_size_override("font_size", int(11.0 * fs))
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.position = Vector2(-hex_radius, hex_radius * 0.44)
	_status_label.size = Vector2(hex_radius * 2.0, 14.0 * fs)
	_status_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.4))
	add_child(_status_label)
	_debuff_label = Label.new()
	_debuff_label.add_theme_font_size_override("font_size", int(11.0 * fs))
	_debuff_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_debuff_label.position = Vector2(-hex_radius, hex_radius * 0.44)
	# 【2026-09-30·用户口径「英雄卡面，负面效果起始点太靠右了」】右端从"贴牌面右缘 `+R`"收到
	#   `R × (0.866 − DEBUFF_RIGHT_INSET)` ⇒ 整行往左挪、待在平顶六边形的直边段里
	#   （原来那一行右端到 `+R`，而六边形在那个高度只有 `±0.866R` ⇒ 字压在斜边上）。
	_debuff_label.size = Vector2(hex_radius * (1.0 + HEX_HALF_W_AT_ROW - DEBUFF_RIGHT_INSET), 14.0 * fs)
	_debuff_label.add_theme_color_override("font_color", Color(0.78, 0.5, 1.0))
	_debuff_label.visible = false
	add_child(_debuff_label)

	# 【2026-09-28·用户口径】前景标记层（常量 `MARKER_Z`，见文件头图层契约）：名字 / 词条 / 攻击图标+数字 /
	#   血量图标+数字 / 状态字都摆在**这一层**——压在背景（`_hex`/`_art_hex`）和框（`FRAME_Z`）之上、
	#   附体魂线之下。这里最后一次性设，免得以后往这段里加标记时忘了设 z
	#   （变身时补建的攻击图标在 `update_atk_icon()` 里自己设）。
	for c: CanvasItem in get_children():
		if c == _hex or c == _art_hex or c == _shadow or c == _dome:
			continue   # 背景(0) / 投影(−1) / 穹顶(`FRAME_Z`) 的层级各自已经定好，不套 MARKER_Z
		c.z_index = MARKER_Z


## 【2026-09-30·用户口径「将棋子立体化 / 不要有那么明显的一个框」】造那张"穹顶"贴图：
##   顶 `DOME_TOP_A` 的暖白 → `DOME_TOP_STOP` 处透明 → `DOME_BOTTOM_STOP` 起转黑 → 底 `DOME_BOTTOM_A` 的纯黑。
## 【同日第十二版·用户问「现在是只有上下有立体效果吗？左右怎么没有」】⚠️ 上一版只按**上下**打光（贴图是 1 列
##   的竖向渐变）⇒ 左右两条边毫无明暗，棋子读成"一根管子"。现在补上**左右分量**：
##   按 |x|（0 = 中线 / 1 = 最左最右）从 `DOME_SIDE_INNER` 起、往两边加到 `DOME_SIDE_A` 的压暗。
##   ⚠️ 为什么这样补**不会**再画出"内层六边形"（第四/五版那个坑）：那张贴图是"**位置**的二维函数"
##   —— 竖着的一段 + 横着的一段，等值线是"竖线/横线拼出来的圆角曲线"，**不是六条边**；
##   而当年那层是按"到六边形边界的距离"算的 ⇒ 等值线必然是六边形。**这条界线不能越**。
##   ⚠️ 贴图是 96×96 的二维图（旧版 4×96 的横竖都够用？不够：横向只有 4 列，铺开后左右分量会被采样成 4 段），
##   所以改成逐像素生成 + `static` 缓存（全参数都是常量 ⇒ 整局只算一次，所有棋子共用一张）。
static var _dome_tex_cache: Texture2D = null
func _make_dome_texture() -> Texture2D:
	if _dome_tex_cache != null:
		return _dome_tex_cache
	var n := 96
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	for iy in n:
		var v := float(iy) / float(n - 1)                              # 0 = 顶 / 1 = 底
		var vert := _dome_vertical(v)
		for ix in n:
			var nx := absf(float(ix) / float(n - 1) * 2.0 - 1.0)        # 0 = 中线 / 1 = 最左·最右
			var s := DOME_SIDE_A * smoothstep(DOME_SIDE_INNER, 1.0, nx)
			var a := vert.a + s * (1.0 - vert.a)                       # 黑色压在竖向明暗之上
			if a <= 0.0001:
				img.set_pixel(ix, iy, Color(0, 0, 0, 0))
				continue
			# 预乘还原：颜色 = (竖向着色 × 它的 α) / 总 α
			img.set_pixel(ix, iy, Color(vert.r * vert.a / a, vert.g * vert.a / a, vert.b * vert.a / a, a))
	_dome_tex_cache = ImageTexture.create_from_image(img)
	return _dome_tex_cache

## 竖向那一维的明暗（= 旧版 `GradientTexture2D` 的四段折线，逐段线性）。
func _dome_vertical(v: float) -> Color:
	if v <= DOME_TOP_STOP:
		var c := DOME_COLOR
		c.a = DOME_TOP_A * (1.0 - v / maxf(DOME_TOP_STOP, 0.0001))
		return c
	if v < DOME_BOTTOM_STOP:
		return Color(0, 0, 0, 0)
	return Color(0, 0, 0, DOME_BOTTOM_A * (v - DOME_BOTTOM_STOP) / maxf(1.0 - DOME_BOTTOM_STOP, 0.0001))

## 把一组点按"自己的包围盒"映射成 UV（Ⅴ：从上 0 → 下 `texture_size.y`）⇒ 贴图正好铺满这个多边形。
## ⚠️ 【2026-09-30·用户报「英雄卡面被糊了一层白色」】**`Polygon2D.uv` 的单位是"贴图像素"而不是 0~1**
##   （它的 `texture_scale = 1` 就是"贴图按原像素大小贴上去"）——第一版返回 0~1 的归一化 UV，
##   而渐变贴图只有 4×96 ⇒ 所有顶点都落在贴图**第 0 个像素**上，整块面取到的都是渐变最顶端的白色
##   ⇒ 卡面被糊了一层均匀的白。现在按贴图尺寸缩放后再交出去。
func _bbox_uv(pts: PackedVector2Array, tex_size: Vector2) -> PackedVector2Array:
	var mn := Vector2(INF, INF)
	var mx := Vector2(-INF, -INF)
	for p in pts:
		mn = Vector2(minf(mn.x, p.x), minf(mn.y, p.y))
		mx = Vector2(maxf(mx.x, p.x), maxf(mx.y, p.y))
	var span := Vector2(maxf(mx.x - mn.x, 0.001), maxf(mx.y - mn.y, 0.001))
	var out := PackedVector2Array()
	for p in pts:
		out.append(Vector2((p.x - mn.x) / span.x * maxf(tex_size.x, 1.0),
				(p.y - mn.y) / span.y * maxf(tex_size.y, 1.0)))
	return out


## 【2026-09-30·用户报「六边形里面还有一个六边形形状的阴影」】算"整体下移 drop 像素后露在**轮廓之外**的那条月牙带"：
##   把六边形下移 `drop`，与原来的六边形相减 —— 留下的只是**下半圈外面**的一条带（左右两个尖角附近收成 0 宽）。
##   用途：投影。棋子底色半透明 ⇒ 只要投影有哪怕一点压在棋子下面，都会从底色里透出一条"错位的六边形边"。
##   ⚠️ 顶点顺序按 `_hex_points()`：0=右尖 · 1=右下 · 2=左下 · 3=左尖 · 4=左上 · 5=右上（平边朝上/下）。
##   顺序不对（返回空多边形）= 不画投影，不会画出乱七八糟的东西。
func _shadow_crescent(pts: PackedVector2Array, drop: float) -> PackedVector2Array:
	if pts.size() != 6 or drop <= 0.0:
		return PackedVector2Array()
	# 平边必须朝上/下（1、2 是最低的两点；0、3 是最左/最右点），否则不画
	if pts[1].y < pts[0].y or pts[2].y < pts[3].y or pts[0].x < pts[3].x:
		return PackedVector2Array()
	var off := PackedVector2Array()
	for p in pts:
		off.append(p + Vector2(0.0, drop))
	# 两个"收口"点：内圈的下半圈边界（3→2 / 0→1）与外圈的上半圈边界（4'→3' / 5'→0'）的交点
	var cl = Geometry2D.segment_intersects_segment(pts[3], pts[2], off[4], off[3])
	var cr = Geometry2D.segment_intersects_segment(pts[0], pts[1], off[5], off[0])
	if cl == null or cr == null:
		return PackedVector2Array()
	var out := PackedVector2Array()
	out.append(cl)         # 左收口点
	out.append(off[3])     # 左尖（下移后）
	out.append(off[2])     # 左下
	out.append(off[1])     # 右下
	out.append(off[0])     # 右尖（下移后）
	out.append(cr)         # 右收口点
	out.append(pts[1])     # 右下（原位）
	out.append(pts[2])     # 左下（原位）
	return out


# 数值图标（攻击/血量）：素材白底已在 DataRegistry 抠透明并记录主体尺寸(w/h/cx/cy)。
# 保持长宽比缩放到"外接框边长=box"内（宽高谁大以谁定基准），并把主体中心精确放到 center。
# 生成/更新一个数值图标 Sprite：reuse=null 时新建，传已有节点则**就地换贴图与缩放**
# （通用：攻击图标变身要换图，又必须保持原来的绘制次序，所以不能删了重建）
func _make_stat_icon(path: String, center: Vector2, box: float, reuse: Sprite2D = null) -> Sprite2D:
	var info := DataRegistry.stat_icon(path)
	var tex: Texture2D = info.get("tex")
	var bw := int(info.get("w", 0))
	var bh := int(info.get("h", 0))
	if tex == null or bw <= 0 or bh <= 0:
		return null   # 资源未导入/缺失：退回无图标
	var spr: Sprite2D = reuse
	if spr == null:
		spr = Sprite2D.new()
	spr.texture = tex
	var sc := box / float(maxi(bw, bh))
	spr.scale = Vector2(sc, sc)
	var tsz := tex.get_size()
	spr.position = center - Vector2(float(info.get("cx", tsz.x / 2.0)) - tsz.x / 2.0,
			float(info.get("cy", tsz.y / 2.0)) - tsz.y / 2.0) * sc
	return spr

# 攻击力图标按"当前词条 / 攻击类型"选：后勤=齿轮，其次远程=弩，最后近战=剑。
# 抽成函数供 _init 与 update_atk_icon() 共用（变身会改这两者）。
func _atk_icon_path() -> String:
	if skills.has(DataRegistry.Skill.LOGISTICS):
		return DataRegistry.ICON_ATK_LOGISTICS
	if attack_type == DataRegistry.AttackType.RANGED:
		return DataRegistry.ICON_ATK_RANGED
	return DataRegistry.ICON_ATK

# 刷新攻击力图标（古灵精怪变身/还原、词条或攻击类型变化后必须调用，否则图标还是旧英雄的）。
# 已建则就地换贴图；原先缺资源没建起来时补建一个，并保持画在攻击数字下面。
func update_atk_icon() -> void:
	var spr := get_node_or_null("AtkIcon") as Sprite2D
	var made := _make_stat_icon(_atk_icon_path(), _atk_icon_center, _atk_icon_box, spr)
	if made == null:
		return   # 目标贴图缺失：保持现状，不做半截替换
	if spr == null:
		made.name = "AtkIcon"
		made.z_index = MARKER_Z   # 前景标记层：补建的图标也要在背景之上、附体魂线之下（见常量说明）
		add_child(made)
		if _atk_label != null:
			move_child(made, _atk_label.get_index())   # 与 _init 的加入次序一致：图标在数字下面

func _skill_tags() -> String:
	var out := ""
	for s in skills:
		match s:
			DataRegistry.Skill.TAUNT:
				out += "嘲"
			DataRegistry.Skill.SWIFT:
				out += "疾"
			DataRegistry.Skill.INFILTRATE:
				out += "渗"
			DataRegistry.Skill.LOGISTICS:
				out += "勤"
			DataRegistry.Skill.BENCH:
				out += "候"
	# 【2026-09-26 用户要求】原来这里给"有移动增益（`move_buff > 0`）"的队友补一个绿字「疾」——
	#   那是借 <疾行> 的招牌，与**本来就有 <疾行>** 的队友撞车（看不出这一格移动力是风语者给的）。
	#   现在风语者光环是**独立状态 [风语]**（`StatusDB.WIND`，牌面金字「风」，见 `heroes/hero_43_风语者.gd`）
	#   ⇒ 本行删除，`<疾行>` 只代表英雄自己的词条。
	return out

func _hex_points(r: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in 6:
		var a := deg_to_rad(60.0 * i)   # flat-top：平边朝上
		pts.append(Vector2(cos(a), sin(a)) * r)
	return pts

# 【2026-09-27·用户要求】棋子六边形的阵营底色**浓度**：
#   原来 alpha = 1.0 ⇒ 六边形把木纹整块盖死；卡面图上线后下面还垫着一层实心色，看着很重。
#   只改**底色这一层**（`_hex.color`）——卡面贴图（`_art_hex`）不受影响，仍是不透明的原色。
#   想更淡就往下调（0.40 ≈ 很淡 / 0.70 ≈ 只压一层淡色），只改这一个常量。
# 【2026-09-30·用户报「英雄走的时候，棋盘线条的图层在英雄的上面」】⚠️ 根因不是图层顺序（棋子 z=2 > 棋盘 z=1），
#   而是**底色是半透明的**：英雄卡面图里人像之外大块是透明的（实测透明面积 51%~78%），
#   透过底色的那 45% 正好把**棋盘的黑格线**露出来 ⇒ 棋子走过格线时那条黑线就"画在英雄身上"。
#   ⇒ 底色改成**不透明**，但把浓度**预混**进颜色里（`C×mix + 地面平均色×(1−mix)`）⇒ 观感与半透明时一模一样，
#     而棋盘（格线/地面）再也透不上来。地面平均色 = 地图 `地面贴图_酒馆木地板_美化版.jpg` 实测 (0.461, 0.296, 0.219)。
#   ⚠️ 以后想让棋子更亮/更艳就调 `FACTION_FILL_MIX` 往 1.0 走（1.0 = 原色、完全实心），
#     换地图（`Battle.BATTLE_BG_MAPS`）后想再贴合地面就把 `FACTION_FLOOR_TONE` 重新量一次。
const FACTION_FILL_MIX := 0.72
const FACTION_FLOOR_TONE := Color(0.461, 0.296, 0.219)

# ---- 牌面状态字那一行的横向摆位（减益紫字右对齐用）----
# ⚠️ 几何口径（`_hex_points`：顶点在 0°/60°…，即**上下平边、左右尖角**的六边形）：
#   它在高度 y 处的半宽 = `R − |y|/√3`。两行状态字落在 y = 0.44R ⇒ 那一行的半宽 = R × 0.746。
const HEX_HALF_W_AT_ROW := 0.7459        # 1 − 0.44/√3：状态字那一行（y=0.44R）处六边形的半宽（单位 = hex_radius）
## 【2026-09-30·用户口径「英雄卡面，负面效果起始点太靠右了」】**减益紫字那一行右端内缩多少**
##   （单位 = hex_radius）。原来那一行右对齐到牌面右缘 `+R` —— 而六边形在那个高度只有 `±0.746R`
##   ⇒ 字压在/探出斜边上、看着"太靠右"。现在右端收到 `R × (0.746 − 这个数)` = `0.686R`：
##   整行往左挪、待在牌面里。想再往中间挪就加大（0.20 / 0.35），写 0 = 回到贴右缘（旧观感）。
const DEBUFF_RIGHT_INSET := 0.06

# ---- 【2026-09-30·用户口径「将英雄的棋子立体感增加」】棋子的"厚度"：投影 + 一层**穹顶渐变** ----
# 画在**人物图之上、标记之下**：
#   · 投影：垫在阵营底色**之下**（相对 −1），整体往下偏一点 ⇒ 棋子像一块"立"在棋盘上的牌子；
#     ⚠️ 只画"轮廓之外的那条月牙带"（`_shadow_crescent`）—— 底色是半透明的，投影压在棋子底下会透出来。
#   · 穹顶渐变：贴着六边形铺一层"上亮 → 中间透明 → 下暗"的竖向渐变 ⇒ 整块看着是**凸起来的**；
#     ⚠️ 多边形与底色**同形同大**（都乘 `FACTION_HEX_FILL`）—— 小一圈就会露一圈没压暗的亮边。
# 【同日第二版·「棋子的边缘过渡效果不好，太突兀了，要循序渐进的凸起来」】第一版"一条硬棱 + 一条柔光"
#   （只有两级过渡）⇒ 突兀；第二版改成 6 条分段渐变的内棱。
# 【同日第三版·「不要有那么明显的一个框啊」】第二版那一圈渐变内棱**整体删掉** —— 它沿六条边说一圈，
#   不管多柔和都读成"给棋子描了个框"。换成**没有轮廓线的**穹顶渐变（只按上下打光），
#   `PieceBevel` 那个嵌类与 `BEVEL_*` 常量一并删除。
# 【同日第四版·「边缘过渡还是差一点，我要那种从最外层往里缓慢升高的感觉」】在穹顶渐变之上再加一层
#   **"边棱明暗"贴图**：按"到六边形边界的距离"算明暗，从最外一圈往里 18px 平滑收掉
#   （贴图用六边形 SDF 逐像素生成，整局按尺寸缓存）。
# 【同日第五版·「六边形的边上有一个框，这个框和框里面的颜色递进不好」】第四版把**六条边一起压暗**
#   ⇒ 绕一圈闭合，读成"框"；改成只在朝上/朝下两条边做明暗（上高光 0.16 / 下暗部 0.24）。
# 【同日第六版·「为什么六边形里面还有一个六边形形状的阴影」】⚠️ 根因：**只要明暗是"到边界距离"的函数，
#   等值线就一定是小一号的六边形** —— 第五版把它调淡只是让那个影子变浅，形状还在。
#   ⇒ 那一层**整个删掉**（含贴图生成函数与 `EDGE_*` 常量）。立体感只留"竖向渐变（`_dome`）+ 投影"：
#   明暗只随**上下**变、完全不跟六边形轮廓走 ⇒ 棋子里面不会再出现第二个六边形。
# 【同日第七版·「还是有啊…阴影的外框没有贴合实际六边形格子，像之前背景没占满格子」】⚠️ 删掉边棱层之后
#   里面那个六边形**还剩两处**、都不是"明暗跟着轮廓走"，而是**"画的尺寸/位置与底色对不上"**：
#   ① 穹顶渐变只铺到 `hex_radius`（人物图那圈 = 底色的 0.909）⇒ 底色外圈没被压暗、底下露出一圈亮边
#      ——就是用户说的"像背景没占满格子"；改成与底色**同形同大**。
#   ② 投影是"整体下移的六边形"⇒ 它的边从**底色**里透出来（当时底色还是半透明的 `FACTION_FILL_ALPHA = 0.55`），
#      看着就是"错位的小六边形"；改成只画轮廓**之外**的月牙带（`_shadow_crescent`），棋子底下一点不画。
# ⚠️ 全部随 `hex_radius` 缩放（基准 39）。`SHADOW_DROP = 0` 关投影，`DOME_*_A` 都写 0 关穹顶渐变。
# 【同日第八版·用户口径「能不能让棋子的立体感比棋盘强，把棋盘立体感弄低点」】棋盘那层压到约 4 成
#   （见 `src/BoardView.gd` 的 `EDGE_*`），棋子这边**顺带各加约 1/4** ⇒ 两者从"棋盘强于棋子"翻过来：
#   起伏幅度（硬棱峰值，白+黑）棋子 0.48 / 棋盘 0.26 ≈ **1.85 倍**（改前是 0.38 / 0.62 ≈ 0.61 倍，棋盘更强）；
#   把棋盘那两道淡柔光也算进去是 0.48 / 0.35 ≈ 1.37 倍。想再拉大就动这四个数。
# 【同日第九版·用户报「英雄走的时候，棋盘线条的图层在英雄的上面」】⚠️ 不是图层顺序（棋子 2 > 棋盘 1），
#   是**底色半透明**：人像之外大块透明（实测 51%~78% 面积）⇒ 棋盘黑格线从那里透上来，棋子一走动
#   那条线就像画在英雄身上。⇒ 底色改成**不透明**（并把浓度预混进颜色，见 `_faction_color`）。
# 【同日第十版·用户问「棋子下面为什么会有阴影伸到下方格子」】⚠️ 因为棋子几乎占满整格、底下没有余量：
#   格子 apothem 68.79px、棋子底色 apothem 68.10px ⇒ **只差 0.69px**；黑格线宽 2.8px（画在格边上、两侧各
#   1.4px）⇒ 棋子底边到"格线外沿"总共只有 **2.09px**。原来 `SHADOW_DROP = 3.6`（×fs = 6.60px）⇒ 越过本格
#   边界 **5.91px**，其中 1.40px 被黑线盖住、**剩下 4.51px 直接铺在下方格子的地面上**（就是用户看到的那条）。
#   ⇒ 压到 **1.1**（×fs = 2.02px ≤ 2.09px）：整条投影都落进"自己这一格的格线范围内" ⇒ 一格都不越界，
#     只把贴身那一圈地面/格线压暗一点（接触阴影）。想让投影再露出来只能先给格子留余量
#     （`FACTION_HEX_FILL` 调小）——但用户要的就是"棋子铺满格子"，所以这里只能贴地。
#   【2026-09-30 后补】`FACTION_HEX_FILL` 后因"格线粗细不一"收到 **1.08**（见文件头那个常量）⇒
#     棋子边离格边 0.69 → **1.93px**、到格线外沿 2.09 → **3.33px** ⇒ 投影其实又可以放大了
#     （上限 `SHADOW_DROP ≤ 3.33 / fs ≈ 1.81`）；现值仍留 1.1（保守、贴地），要更明显的投影再往上加。
# 【同日第十一版·用户口径「增加棋子的立体感」】⚠️ 投影那边**动不了**（第十版已顶到格线外沿，再大就伸进下方格子）
#   ⇒ 立体感全压在穹顶渐变上：顶端 0.20 → **0.28**、底端 0.28 → **0.40**，并把覆盖范围拉开
#   （高光 `TOP_STOP` 0.10 → **0.14**、暗部 `BOTTOM_STOP` 0.56 → **0.50**）；接触阴影 0.32 → **0.40**。
#   起伏幅度（上亮+下暗）棋子 0.48 → **0.68** / 棋盘 0.26 ⇒ 比值 **1.85 → 2.6 倍**。
#   ⚠️ 再要更立体就继续动这四个数（0.34 / 0.48 已很"圆"）；**别去动"按到边界距离"的明暗**（会画出内层六边形，见第六版）。
# 【同日第十三版·用户口径「现在棋子的颜色有点暗」】⚠️ 上一版把"暗"堆在**下半部一大片**上（`BOTTOM_STOP = 0.50`
#   起就转黑、到底 0.40）＋左右各 0.18 ⇒ 棋子下半截比地面还暗（实测底色亮度 0.43、压完只剩 **0.26**，而地面 0.33）。
#   ⇒ 改法**不是简单调淡**，而是把明暗"**挪**"：中间那一大片（v 0.20~0.62）保持原色不压，
#     高光加浓并往上多铺（0.28 → **0.34**、`TOP_STOP` 0.14 → **0.20**），
#     黑只留在**最下面 1/3**（`BOTTOM_STOP` 0.50 → **0.62**）且减淡（0.40 → **0.26**），两侧 0.18 → **0.08**；
#     底色本身也提亮（`FACTION_FILL_MIX` 0.55 → **0.72** —— 阵营色更足、不再被地面色拉灰）。
#   起伏幅度 0.68 → **0.60**（棋盘 0.26 ⇒ 仍 **2.3 倍**），但整枚棋子的**平均亮度上去了**。
# 【同日第十五版·用户口径「把卡面 上面白 下面黑的效果去掉」】⇒ `DOME_TOP_A` 0.34 → **0.0**、
#   `DOME_BOTTOM_A` 0.26 → **0.0**：竖向那两段**关掉**（人像上不再有白顶/黑底）。**只关上下** ——
#   左右那点收边暗部（`DOME_SIDE_A = 0.08`）留着（它是第十二版用户专门要的，量也小）；
#   要把左右也一起关掉，就把 `DOME_SIDE_A` 也写 0（三个都 0 ⇒ 整层不建，棋子 = 平的阵营底色 + 投影）。
#   `DOME_TOP_STOP` / `DOME_BOTTOM_STOP` 留着不动：哪天想把上下加回来，改这两个 alpha 就行。
const DOME_TOP_A := 0.0                 ## 渐变顶端（白）的浓度（0 = 关掉"上面白"）
const DOME_TOP_STOP := 0.20             ## 白 → 透明 的过渡位置（0 = 顶 / 1 = 底）
const DOME_BOTTOM_STOP := 0.62          ## 透明 → 黑 的起点
const DOME_BOTTOM_A := 0.0              ## 渐变底端（黑）的浓度（0 = 关掉"下面黑"）
const DOME_COLOR := Color(1.0, 0.99, 0.96)   ## 顶端的高光色（微微偏暖；底端固定用纯黑）
const DOME_SIDE_A := 0.08               ## 【第十二版】左右两侧往里的暗部浓度（0 = 只按上下打光，回到上一版）
const DOME_SIDE_INNER := 0.55           ## 从多靠边开始起暗：|x| ≤ 这个值不压暗（0 = 中线 / 1 = 最左·最右）
const SHADOW_DROP := 1.1                ## 投影往下偏多少（像素 × fs；0 = 不画投影）
const SHADOW_ALPHA := 0.40              ## 投影浓度

## 阵营底色：**不透明**（`FACTION_FILL_MIX` 是"阵营色 vs 地面平均色"的配比，不是 alpha）。
## ⚠️ 别改回半透明：底下的棋盘（黑格线 / 地面）会从人像的透明区透上来，看着像"格线画在英雄身上"。
func _faction_color(f: int) -> Color:
	var pure := Color(0.25, 0.55, 0.9) if f == DataRegistry.Faction.PLAYER else Color(0.85, 0.32, 0.28)
	var m := FACTION_FILL_MIX
	return Color(pure.r * m + FACTION_FLOOR_TONE.r * (1.0 - m),
			pure.g * m + FACTION_FLOOR_TONE.g * (1.0 - m),
			pure.b * m + FACTION_FLOOR_TONE.b * (1.0 - m), 1.0)

# Battle 在造成重击(如嬉皮死神双倍)前调用：本次受击的伤害数字用紫粉放大样式
func set_big_hit_style() -> void:
	_dmg_style = 2

func is_shield_hit_blocked() -> bool:
	return _shield_block_status

# 【2026-09-28·用户要求·击杀预告】"这一击过门之后会扣多少血 / 会不会致死"的**纯计算**（不改任何状态）：
#   · `damage_amount()`：重伤 +1、坚固（仅攻击伤害）−1，最低 0 —— `take_damage()` 与预告共用同一把尺；
#   · `would_be_lethal()`：圣盾在身 ⇒ 这一击被完全挡下、不掉血 ⇒ 不是击杀。
#   ⚠️ **塔盾代扛**（`_bulwark_absorb`，相邻塔盾替挡 1 点）**不在本函数里**：那个钩子有副作用
#      （扣塔盾的血 / 消耗它的圣盾 / 还会发声），不能预演 ⇒ 由调用方 `Battle._kill_intro()` 先用
#      纯查询 `_bulwark_preview_reduction()` 减掉那 1 点再问（2026-09-28 用户实机报过
#      「塔盾帮人抗伤害、被抗的没死只剩 1 血，但依旧跳击杀特效」）。
func damage_amount(amount: int, is_attack: bool = false) -> int:
	var dmg := amount + (1 if has_status(StatusDB.HEAVY) else 0)
	if has_status(StatusDB.SOLID) and is_attack:
		dmg = max(dmg - 1, 0)
	return max(dmg, 0)

func would_be_lethal(amount: int, is_attack: bool = false) -> bool:
	if not alive or has_status(StatusDB.SHIELD):
		return false
	return hp - damage_amount(amount, is_attack) <= 0

func take_damage(amount: int, ignore_shield: bool = false, counter: bool = false, cause: String = "", is_attack: bool = false) -> void:
	if not alive:
		return
	_was_counter_damage = counter   # 记录本次是否为反击伤害
	# 圣盾：防止一次受到的伤害，消费后解除
	if not ignore_shield and has_status(StatusDB.SHIELD):
		_dmg_style = 0
		remove_status(StatusDB.SHIELD)
		_float_text("[圣盾]", Color(0.5, 0.8, 1.0), -24, -46)
		return
	# 重伤：受到的伤害 +1；坚固：受到的伤害 -1（只减攻击伤害，猛毒/烧血/炸弹等非攻击伤害不减）
	# 两者可共存，先加后减，最低为0——可完全免疫1点攻击
	# 【2026-09-28】这一段抽成 `damage_amount()`：与"击杀预告"（`would_be_lethal()`）**共用同一把尺**，
	#   免得预告与实际结算各写一份、以后改一处漏一处。
	var dmg := damage_amount(amount, is_attack)
	# 塔盾：伤害结算前，相邻塔盾代替承受1点（队友实际伤害减1）
	var battle_node := get_parent()
	if battle_node != null and battle_node.has_method("_bulwark_absorb"):
		dmg = battle_node._bulwark_absorb(self, dmg)
	hp = max(hp - dmg, 0)
	# 记录本次伤害来源（死因排查用）：无显式 cause 时按反击/普通受击兜底
	if cause == "":
		cause = "被反击" if counter else "受击"
	if dmg > 0:
		death_cause = cause
	hp_changed.emit(self)
	_update_hp_label()
	if dmg <= 0:
		# 坚固把攻击完全挡下（1点伤害-1=0）：不算受伤——不 emit damaged(避免锤头鲨等误触发)、
		# 不播受击闪屏/音效，只弹"防住"提示
		_float_text("防住", Color(1.0, 0.9, 0.5), -24, -46)
		_dmg_style = 0
		return
	damaged.emit(self, dmg)
	_flash()
	_shake()
	# 伤害数字统一红色、水平居中在卡面中心；**只有重击**(_dmg_style=2，如嬉皮死神双倍)
	# 靠字号放大区分。反击一律用普通字号——否则 1 点反击也显示成大字，看起来像重击。
	if _dmg_style == 2:
		_float_text("-%d" % dmg, Color(1.0, 0.18, 0.12), -32, -52, true, NUMBER_FONT_MUL)
	else:
		_float_text("-%d" % dmg, Color(1.0, 0.18, 0.12), -32, -46, false, NUMBER_FONT_MUL)
	_dmg_style = 0   # 一次伤害只套用一种样式
	AudioManager.play("hit")
	# [附体]镜像：宿魂受到的伤害 >0 时，其被附体目标同受同等伤害（Battle 统一结算）
	if dmg > 0:
		var bnode := get_parent()
		if bnode != null and bnode.has_method("_possess_mirror"):
			bnode._possess_mirror(self, dmg)
	if hp <= 0:
		die()

# ---- 状态效果 ----
# 状态的"键名 / 中文名 / 是否负面 / 是否随回合末解除 / 显示"全部集中在 StatusDB（唯一真相表）。
# 负面免疫由英雄脚本自己声明（HeroBase.immune_to_negative），Unit 不认识具体英雄；
# 判定用状态 key（与 add/remove 同 key）。[附体] 同为负面标记，负墟同样免疫（命中计数攻+1）。
#
# 圣盾的语义：**挡住"那一次带伤害的攻击"**——伤害不结算，该次攻击附带的状态也不生效
# （见 Battle._apply_attack 的 _shield_block_status）。而"纯状态施加"（雪拳移动后冰冻这种
# 没有伤害的）用 pierce_shield=true 穿过圣盾：盾保留、状态照常挂上。
func add_status(s: String, pierce_shield: bool = false) -> void:
	# 圣盾：负面状态施加时消费掉圣盾并抵消本次负面（不带伤害的"纯状态施加"用 pierce_shield 越过）
	# 圣盾判定在负墟免疫之前：带盾的负墟被负面命中先被盾挡下，不算"被负面命中"，不触发 +1 攻
	if StatusDB.is_negative(s) and has_status(StatusDB.SHIELD) and not pierce_shield:
		remove_status(StatusDB.SHIELD)
		_float_text("[圣盾]", Color(0.5, 0.8, 1.0), -32, -92)   # 文字抬高，避免压住伤害数字
		return
	# 负面免疫（负墟 hero_44 等）：规则全在英雄脚本自己的钩子里，这里只负责问一句、通知一声。
	# 免疫者同样不挂状态；on_negative_blocked() 由英雄决定收益（负墟：同帧去重后攻击力+1）。
	if behavior != null and StatusDB.is_negative(s) and behavior.immune_to_negative():
		behavior.on_negative_blocked()
		return
	statuses[s] = true
	_update_status_label()
	# 【2026-09-28·用户口径「圣盾音效 = 生成圣盾的时候，比如吃 buff、比如圣光技能」】
	#   所有发盾来源（拾取圣盾道具 / 波盾全队盾 / 圣光受伤后补盾）都经过这个挂点 ⇒ 只在这里响一声。
	#   开局初始化就带着的盾走的是 `_refresh_shield_aura()`（只刷表现）⇒ 不响。
	if s == StatusDB.SHIELD:
		AudioManager.play("shield")

func remove_status(s: String) -> void:
	statuses.erase(s)
	_update_status_label()

func has_status(s: String) -> bool:
	return statuses.has(s)

func has_any_status(list: Array) -> bool:
	for s in list:
		if statuses.has(s):
			return true
	return false

# 刷新牌面数值（攻击/血量/血上限变化后调用，让增益可见）
func refresh_stats() -> void:
	_update_atk_label()
	_update_hp_label()
	_update_status_label()
	# 【2026-09-23 深夜·用户报「风语者光环生效后队友牌面没有疾行标志」】词条标签也要跟着刷：
	#   移动光环（`move_buff`）与它一样是"数值增益" ⇒ 不刷的话「疾」不会出现/不会消失。
	_update_tags_label()

# 刷新名字标签（用于古灵精怪变身等）
# 【2026-09-27·用户口径】名字**只画在"还没出图的英雄"上**：
#   · 有卡面图（`DataRegistry.hero_card_art` 找得到）⇒ 靠棋子上的人物本体认人，**不画名字**；
#   · 没出图 ⇒ 照旧画名字（否则纯色棋子认不出是谁）。
#   变身会换 `display_name` ⇒ 这里把"名字 / 人物本体"两者一起对齐（永远只留一个）。
func _update_name_label() -> void:
	var art := DataRegistry.hero_card_art(display_name)
	if art != _art:
		_art = art
		_apply_hex_art()
	if _art != null:
		if _label != null:
			_label.visible = false
		return
	if _label == null:
		_build_name_label()
	else:
		_label.visible = true
		_label.text = display_name

# 名字行（**只给还没出图的英雄**）：与改动前逐项一致（白字 + 黑描边，位置/字号按 `hex_radius` 缩放）
func _build_name_label() -> void:
	var fs := hex_radius / 39.0
	_label = Label.new()
	_label.text = display_name
	_label.add_theme_font_size_override("font_size", int(12.0 * fs))
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.position = Vector2(-hex_radius, -hex_radius * 0.10)
	_label.size = Vector2(hex_radius * 2.0, 15.0 * fs)
	_label.add_theme_color_override("font_color", Color.WHITE)
	_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_label.add_theme_constant_override("outline_size", maxi(3, int(4.5 * fs)))
	add_child(_label)

# 把人物本体贴到棋子六边形上：等比放大到**顶到六边形上下边**，UV 按同一条比例算 ⇒
#   贴图恰好填满这个多边形（Polygon2D 按多边形裁剪）；`_art == null` 时摘掉贴图、退回纯色棋子。
#   不会出现"边缘拉伸"：抠图四周留了 2% 全透明边，越界采样钳到的是透明像素。
#   【2026-09-28·用户要求】再叠一层**个别英雄的取景微调**（`DataRegistry.HERO_ART_FIT`：zoom/dx/dy）——
#   放大后被多边形裁掉的部分就是"不需要完全显示"的长武器，`dx/dy` 用来把人物挪正。
func _apply_hex_art() -> void:
	if _art_hex == null:
		return
	if _art == null:
		# ⚠️ 没图时**必须把这一层藏起来**：`Polygon2D` 没有贴图时会用 `color` 把多边形填成实心，
		#   而本层 color 是白色（贴图不染色用的）⇒ 不藏的话所有没出图的英雄都会变成**白色棋子**，
		#   把下面的阵营色（我方蓝 / 敌方红）整个盖掉。
		_art_hex.texture = null
		_art_hex.uv = PackedVector2Array()
		_art_hex.visible = false
		return
	_art_hex.visible = true
	var ts := _art.get_size()
	if ts.x <= 0.0 or ts.y <= 0.0:
		return
	var fit := minf((hex_radius * 2.0) / ts.x, (sqrt(3.0) * hex_radius) / ts.y)
	# 【2026-09-28·用户要求】个别英雄的取景微调（放大 / 平移）—— 表在 `DataRegistry.HERO_ART_FIT`，
	#   与卡面 `HexCard._draw()` 共用；没登记的英雄 = 1.0 / 0 / 0（原样）。`dx`/`dy` 以棋子半径为单位。
	var adj: Dictionary = DataRegistry.hero_art_fit(display_name)
	fit *= float(adj.get("zoom", 1.0))
	var dsz := ts * fit
	var dpos := -dsz * 0.5 + Vector2(float(adj.get("dx", 0.0)), float(adj.get("dy", 0.0))) * hex_radius
	var uv := PackedVector2Array()
	for p in _art_hex.polygon:
		uv.append(Vector2((p.x - dpos.x) / dsz.x * ts.x, (p.y - dpos.y) / dsz.y * ts.y))
	_art_hex.texture = _art
	_art_hex.uv = uv

# 刷新技能词条标签（疾/嘲/渗/勤/候，用于变身继承技能后）
# 古灵精怪变身等场景可能从"无词条"变到"有词条"：节点可能尚未创建，按需补建。
func _update_tags_label() -> void:
	var tags := _skill_tags()
	if tags == "":
		if _tags_label:
			_tags_label.visible = false
			_tags_label.text = ""
		return
	_ensure_tags_label()
	_tags_label.text = tags
	_tags_label.visible = true

# 确保词条标签节点存在（初始无词条的单位首次获得词条时创建）
func _ensure_tags_label() -> void:
	if _tags_label:
		return
	var fs := hex_radius / 39.0
	var tag_label := Label.new()
	tag_label.add_theme_font_size_override("font_size", int(10.0 * fs))
	tag_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tag_label.position = Vector2(-hex_radius, hex_radius * 0.72)
	tag_label.size = Vector2(hex_radius * 2.0, hex_radius * 0.34)
	# 绿字+深色描边：特性标签(嘲/疾/渗/勤/候)，不撞本方蓝/敌方红/紫减益/金黄盾
	tag_label.add_theme_color_override("font_color", Color(0.5, 0.9, 0.45))
	tag_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	tag_label.add_theme_constant_override("outline_size", 3)
	tag_label.text = _skill_tags()
	add_child(tag_label)
	_tags_label = tag_label

func clear_temp_statuses() -> void:
	# 哪些状态随回合末解除由 StatusDB.clears_on_turn_end 决定：
	# 猛毒永久（不解除）；坚固(装甲堡垒)是自己回合开始时挂的增益、要撑过整个对方回合，
	# 由英雄自己 on_turn_start 清理，故也不在此自动清。
	for key in StatusDB.keys():
		if StatusDB.clears_on_turn_end(key):
			statuses.erase(key)
	_update_status_label()

# 有效攻击力（含 buff / ** / 冲锋加成；远程被贴身时：基础攻击压为1，buff 照常叠加）
# ranged_adjacent 由 Battle 在局面变化时更新（true=有敌人紧邻=远程被贴身）
var ranged_adjacent := false

func effective_atk() -> int:
	# 共鸣者：攻击力"变为"队友攻击力之和(echo_set>=0),覆盖自身基础/加成,直到回合结束
	# 【2026-09-20 修 bug·用户报「共鸣者吃攻击buff无效」】原来这里是 `return max(echo_set, 0)` ⇒ **把
	#   `atk_use_buff` 短路掉了**：共鸣者吃【攻击】道具伤害不变，而 `Battle._finish_attack` 照样把它清零
	#   ⇒ **吃了白吃、道具白白浪费**。现在把"下一次攻击 +1"这份**一次性道具加成**叠在共鸣值上 ——
	#   道具的语义是"这一下更疼"，不是"改我的攻击力面板"，所以不该被"攻击力 = 队友之和"覆盖。
	#   而 `atk_buff` / `ramble_bonus` / `sun_bonus` / 远程被贴身压 1 / 麻痹 仍然**照旧被覆盖**：
	#   那些才是"自身攻击力"的修正，符合「共鸣值覆盖自身基础与加成」这句话。
	#   回退：把下面这行改回 `return max(echo_set, 0)`。
	if echo_set >= 0:
		return max(echo_set + atk_use_buff, 0)
	var base := atk
	if attack_type == DataRegistry.AttackType.RANGED and ranged_adjacent:
		base = 1   # 远程被贴身：默认攻击力变为 1（buff 不受影响）
	var a := base + atk_buff + ramble_bonus + sun_bonus + atk_use_buff
	if has_status(StatusDB.ATKDOWN):
		a -= 1
	return max(a, 0)

func effective_move() -> int:
	if has_status(StatusDB.STUN) or has_status(StatusDB.THORN):
		return 0
	var m := move_range + move_buff + move_use_buff
	if has_status(StatusDB.FREEZE):
		m -= 1
	return max(m, 0)

# 远程被贴身状态变化时更新（Battle 在局面变化后调用），并刷新面板攻击显示
func set_ranged_adjacent(adj: bool) -> void:
	if ranged_adjacent == adj:
		return
	ranged_adjacent = adj
	_update_atk_label()

func can_move() -> bool:
	return alive and not has_status(StatusDB.STUN) and not has_status(StatusDB.THORN)

func can_attack() -> bool:
	# 【2026-09-26 修·用户要求】被降到 0 攻（麻痹/共鸣者等）就**不能攻击**（原来只判眩晕）。
	return alive and not has_status(StatusDB.STUN) and effective_atk() > 0

func skill_allowed() -> bool:
	# 眩晕：不能移动/攻击，也不能触发任何技能（回合开始/结束、登场、光环等）
	return alive and not has_status(StatusDB.SILENCE) and not has_status(StatusDB.STUN)

# 坠炮手"全场狙击"被动是否生效：仅在本单位存活且未被沉默/眩晕时。
# 被沉默时退化为普通远程(射程2/受视线阻挡/受嘲讽约束,见 Battle 各判定处)，但仍能攻击。
func mortar_active() -> bool:
	return alive and los_ignore and skill_allowed()

# 坠炮手是否"豁免嘲讽"：全场狙击生效 **且未被贴身**。
# 被贴身（有敌人紧邻）时按普通远程处理 —— 必须优先攻击射程内的嘲讽单位。
func mortar_ignores_taunt() -> bool:
	return mortar_active() and not ranged_adjacent

func _update_status_label() -> void:
	# 在单位牌面下加状态小字(减益紫 + 增益金)，单字/分组/顺序全部查 StatusDB，
	# 本函数不再出现任何状态名硬编码。
	# 【2026-09-28·用户要求】[圣盾] **不画牌面小字**：它的表现是棋子上那圈金黄罩（见 `_refresh_shield_aura()`）
	#   ⇒ 这里显式跳过 shield 组，否则会落进 `_` 变成紫字减益。
	var dtxt := ""
	var gtxt := ""
	for key in StatusDB.keys():
		if not has_status(key):
			continue
		match StatusDB.group_of(key):
			"shield":
				pass
			"buff":
				gtxt += StatusDB.glyph(key)
			_:
				dtxt += StatusDB.glyph(key)
	if _status_label:
		_status_label.text = gtxt
		_status_label.visible = gtxt != ""
		if _debuff_label:
			_debuff_label.text = dtxt
			_debuff_label.visible = dtxt != ""
	# 【2026-09-28·新增·用户要求】[圣盾] 的"金黄透明罩"跟着同一处状态刷新走（挂盾就出现、被消费/解除就收）
	_refresh_shield_aura()

# 【2026-09-28·用户要求】[圣盾] 罩：`StatusDB.SHIELD` 在身时，棋子外面套一个**金黄半透明的罩**、整圈一闪一闪。
#   唯一入口是本函数（由 `_update_status_label()` 在每次状态变化后调用）+ `_ready()`（开局就带盾的）。
#   ⚠️ 纯演出：不读不改任何战斗状态；headless（RL 跑批 / 无窗口自检）**不建节点** ⇒ 跑批零开销、逐位不变。
func _refresh_shield_aura() -> void:
	var want := alive and has_status(StatusDB.SHIELD)
	if want and _shield_aura == null:
		if DisplayServer.get_name() == "headless" or not is_inside_tree():
			return
		_shield_aura = ShieldAura.new()
		_shield_aura.radius = hex_radius
		_shield_aura.z_index = FRAME_Z   # 框/光环层：压在人物图之上、攻血数字与状态字之下
		add_child(_shield_aura)
		_shield_aura.modulate.a = 0.0    # 上罩时轻轻淡入，别硬闪
		var t := _shield_aura.create_tween()
		t.tween_property(_shield_aura, "modulate:a", 1.0, 0.22)
	if _shield_aura != null and is_instance_valid(_shield_aura):
		_shield_aura.visible = want
		_shield_aura.set_process(want)   # 收罩后不再每帧重画（再挂盾时这里会重新打开）

# 受击震屏：仅抖动六边形本体，不影响单位移动坐标
func _shake() -> void:
	if _hex == null:
		return
	var t := create_tween()
	var d := Vector2(4, -3)
	t.tween_property(_hex, "position", d, 0.05)
	t.tween_property(_hex, "position", Vector2.ZERO, 0.12)

# 伤害/治疗飘字（挂在父节点以固定在棋盘坐标，上浮并淡出）
# 【2026-09-29·用户要求「将伤害数字放大点」】数值飘字（伤害/治疗）的字号与描边在这里单独乘一个系数
#   —— 只放大**数字**，"圣盾/被动/免疫负面"这类词条飘字维持原样。嫌大嫌小只改这一个数。
const NUMBER_FONT_MUL := 1.35
## 【2026-09-29·用户要求】拖拽撤下时跟随鼠标那枚**虚化影子**的不透明度（1 = 不虚化）。
const DRAG_GHOST_ALPHA := 0.5
func _float_text(text: String, color: Color, xoff: int = -32, yoff: int = -46, big := false, size_mul := 1.0) -> void:
	var parent := get_parent()
	if parent == null or not is_inside_tree():
		return
	var k := hex_radius / 54.0   # 视觉反馈随棋盘放大(基准:旧 hex60 → radius54)
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", maxi(14, int((26.0 if big else 21.0) * k * size_mul)))
	lbl.add_theme_color_override("font_color", color)
	lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	lbl.add_theme_constant_override("outline_size", maxi(2, int((5.0 if big else 4.0) * k * (1.0 + (size_mul - 1.0) * 0.6))))
	lbl.z_index = 120
	# 【2026-09-30·用户报「伤害数字有点歪」】⚠️ 原来把 label 的**左上角**钉在 `(xoff, yoff)` 上、盒子宽度
	#   写死 `64×k`：字号一放大（`size_mul = NUMBER_FONT_MUL = 1.35`）盒子只往**右**长，
	#   而文字是在盒子里**居中**的 ⇒ 整串数字跟着**往右偏（盒子增量的一半）≈ 15px**（就是"歪"）。
	#   ⇒ 先算盒子，再把**横向**按盒子中心摆（纵向仍钉在 `yoff`、与改动前一致；`Label` 的文字是
	#     **顶端对齐**的，盒子往下长不会挪动文字）⇒ `size_mul = 1` 时与改动前逐像素一致
	#     （所以「圣盾/被动」这类词条飘字一点没变），放大时数字是"原地变大、横向居中对齐棋子"。
	var box := Vector2(64.0 * k * size_mul, 28.0 * k * size_mul)
	lbl.size = box
	lbl.position = Vector2(global_position.x + (xoff + 32.0) * k - box.x * 0.5, global_position.y + yoff * k)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	parent.add_child(lbl)
	# 把 tween 绑到 label 上，避免单位被释放时终止动画导致飘字残留。
	# 扣血/回血数字停留更久：先完整上浮 1.0s（期间不透明），再 0.7s 淡出。
	var rise := 0.5
	var fade := 0.7
	var t := lbl.create_tween()
	t.tween_property(lbl, "position", lbl.position + Vector2(0, -30.0 * k), rise)
	t.tween_property(lbl, "modulate:a", 0.0, fade)
	t.tween_callback(lbl.queue_free)

# 治疗飘字（供 Battle 调用）：被治疗者显示 +血量数值，并冒一圈绿色粒子
func float_heal(amount: int) -> void:
	_float_text("+%d" % amount, HEAL_COLOR, -32, -46, false, NUMBER_FONT_MUL)   # 与伤害数字同字号
	heal_fx()

# 治疗主色（与被治疗飘字同色）
const HEAL_COLOR := Color(0.45, 0.95, 0.5)

# 被治疗目标的绿色粒子：从脚下升起的小绿点，边上飘边淡出。
# 刻意不做白闪/光环（那是技能爆发的语言），免得盖住 +N 飘字、也避免和技能演出混淆。
# 随机数用全局 randf()，**不要**动 battle.rng —— 那是联机同步用的确定性随机源。
func heal_fx() -> void:
	if not is_inside_tree():
		return
	var k := hex_radius / 54.0   # 随棋盘缩放（基准：旧 hex60 → radius54）
	for i in 14:
		var s := (2.6 + randf() * 2.0) * k
		var dot := Polygon2D.new()
		dot.polygon = PackedVector2Array([Vector2(-s, -s), Vector2(s, -s), Vector2(s, s), Vector2(-s, s)])
		dot.z_index = FRAME_Z
		dot.color = HEAL_COLOR.lerp(Color(0.78, 1.0, 0.62), randf() * 0.6)
		var from := Vector2((randf() - 0.5) * hex_radius * 1.5, hex_radius * (0.3 + randf() * 0.4))
		dot.position = from
		add_child(dot)
		var dt := dot.create_tween()
		var rise := hex_radius * (1.0 + randf() * 0.8)
		dt.tween_property(dot, "position", from + Vector2((randf() - 0.5) * hex_radius * 0.6, -rise), 0.5 + randf() * 0.25)
		dt.parallel().tween_property(dot, "modulate:a", 0.0, 0.6 + randf() * 0.25)
		dt.tween_callback(dot.queue_free)

# 机制文字（挂在单位头顶小字，如施加治疗方弹"治疗"）
func float_tag_text(text: String, color: Color) -> void:
	_float_text(text, color, -32, -88)

# 数值"带增益"的判定口径（棋子上的数字 / 战斗内属性卡用黄色都看这两个函数）
# 攻击力：回合增益（烈焰祭司/锤头鲨/负墟）+ 一次性道具增益（攻击道具，下一次攻击 +`Battle.ATK_ITEM_BUFF`）
#   + 共鸣/太阳斩/冲锋
func atk_is_buffed() -> bool:
	return atk_buff > 0 or atk_use_buff > 0 or echo_set >= 0 or sun_bonus > 0 or ramble_bonus > 0

# 血量：回血道具可突破上限，高于 max_hp 的那部分就是增益（受伤先扣这部分）
func hp_is_buffed() -> bool:
	return hp > max_hp

func _update_hp_label() -> void:
	if _hp_label:
		_hp_label.text = str(hp)
		# 血量带增益（溢出上限）时数字用黄色突出
		_hp_label.add_theme_color_override("font_color",
				Color(1.0, 0.9, 0.25) if hp_is_buffed() else Color(1.0, 1.0, 1.0))

func _update_atk_label() -> void:
	if _atk_label:
		_atk_label.text = str(effective_atk())
		# 增益状态(道具/攻击加成/共鸣/太阳斩/冲锋加成等临时增益)下数字用黄色突出
		_atk_label.add_theme_color_override("font_color",
				Color(1.0, 0.9, 0.25) if atk_is_buffed() else Color(1.0, 1.0, 1.0))

func _flash() -> void:
	var t := create_tween()
	t.tween_property(_hex, "color", Color.WHITE, 0.06)
	t.tween_property(_hex, "color", _faction_color(faction), 0.16)

# 技能爆发特效（贴合英雄机制的可复用演出）：扩散光环 + 飞散粒子 + 闪白脉冲 + 专属飘字。
# color: 该技能的主色；text: 机制标签文案（如"猛毒/麻痹/收割/爆破/回血"）。
func burst_fx(color: Color, text: String) -> void:
	if not is_inside_tree():
		return
	# 扩散光环（沿六边形外沿一圈，向外扩张并淡出）
	var ring := Line2D.new()
	ring.points = _hex_points(hex_radius + 3.0)
	ring.closed = true
	ring.width = 5.0
	ring.z_index = FRAME_Z
	ring.default_color = color
	ring.position = Vector2.ZERO
	add_child(ring)
	var rt := ring.create_tween()
	rt.tween_property(ring, "scale", Vector2(1.7, 1.7), 0.5)
	rt.parallel().tween_property(ring, "modulate:a", 0.0, 0.5)
	rt.tween_callback(ring.queue_free)
	# 飞散粒子：沿 6 个方向飞出的小圆点
	for i in 6:
		var ang := deg_to_rad(60.0 * i + 30.0)
		var dot := Polygon2D.new()
		dot.polygon = PackedVector2Array([Vector2(-3, -3), Vector2(3, -3), Vector2(3, 3), Vector2(-3, 3)])
		dot.z_index = FRAME_Z
		dot.color = color
		dot.position = Vector2.ZERO
		add_child(dot)
		var dt := dot.create_tween()
		var off := Vector2(cos(ang), sin(ang)) * (hex_radius * 0.7)
		dt.tween_property(dot, "position", off, 0.42)
		dt.parallel().tween_property(dot, "modulate:a", 0.0, 0.42)
		dt.tween_callback(dot.queue_free)
	# 闪白脉冲
	_flash()
	# 专属机制飘字
	if text != "":
		_float_text(text, color)

# 被动技能触发提示：给该单位描一圈亮边并闪烁 + 飘字，便于分辨是谁的被动生效
# 【2026-09-23 深夜·用户报「风语者开局被动怎么会弹两个字样」】`with_text := false` = **只闪边框、不飘"被动"**：
#   回合开始技在 `Battle._trigger_turn_start()` 里已经走过一次 `burst_fx(..., 专属飘字)`
#   （风语者 = 「风语」）⇒ 这里再飘一个"被动"就成了**两个字样叠在一起**。
#   调用方（`Battle._trigger_turn_start_all()`）会在"该英雄已有专属飘字"时传 false；
#   没有专属飘字的英雄照旧飘"被动"（回合结束那条路仍用默认 true）。
func flash_passive(with_text := true) -> void:
	if _passive_border == null:
		_passive_border = Line2D.new()
		_passive_border.points = _hex_points(hex_radius + 2.0)
		_passive_border.closed = true
		_passive_border.width = 4.0
		_passive_border.z_index = FRAME_Z
		_passive_border.default_color = Color(1.0, 0.92, 0.35)
		_passive_border.modulate.a = 0.0
		add_child(_passive_border)
	if with_text:
		_float_text("被动", Color(1.0, 0.92, 0.35))
	if _passive_tween:
		_passive_tween.kill()
	_passive_border.visible = true
	var t := create_tween()
	_passive_tween = t
	t.tween_property(_passive_border, "modulate:a", 1.0, 0.08)
	t.tween_property(_passive_border, "modulate:a", 0.0, 0.5)
	t.tween_callback(func():
		_passive_border.modulate.a = 0.0
		_passive_border.visible = false)

## 【2026-09-29·用户要求】拖拽撤下时，**场上的棋子留在原地**、跟着鼠标走的是一个**虚化的影子**；
##   撤下之后再让棋子播一段**消失动画**（不是"啪一下没了"）。
##   本函数造的就是那份"只有外观"的副本：投影 / 阵营底色 / 人物图 / 穹顶四层，**不带**名字、
##   数值图标、状态字、选中/行动描边与任何标识（所以看着是"影子"而不是第二枚棋子）。
##   调用方负责 `add_child()` / 摆位置 / 压 `modulate.a` / 演完 `queue_free()`；
##   本函数**不改单位自身的任何状态**（位置、z、alive 都不动）。
func make_visual_copy() -> Node2D:
	var g := Node2D.new()
	# ⚠️ 名字**留给调用方起**（`Battle._start_drag_ghost()` = "DragGhost" / `_play_vanish_copy()` = "WithdrawFx"）：
	#   同名同父的节点会被引擎改名（"@Xxx@N"）⇒ 调试/探针按名字找就会找错人。
	for n in [_shadow, _hex, _art_hex, _dome]:
		if n == null or not is_instance_valid(n):
			continue                 # `_shadow` / `_dome` 是开关项（常量为 0 时不建）⇒ 允许缺
		var c := (n as Polygon2D).duplicate() as Polygon2D
		g.add_child(c)
	return g

func die() -> void:
	if not alive:
		return
	alive = false
	# 【2026-09-23 新增·用户要求"死亡时卡面破碎升天"】死亡瞬间先发 `dying`（HUD 接它播破碎/飞行特效），
	#   本体**立刻隐藏**（原来的"淡出 0.3s"是唯一视觉，现在交给特效；不隐藏的话会与碎片重叠）。
	#   ⚠️ **时序一字不动**：仍然 0.3s 之后才发 `died` —— 墓碑/替补/胜负判定/阵亡日志全挂在 `died` 上，
	#   提前或延后都会改变游戏节奏（见 `Battle._on_unit_died` 与那行"die() 先淡出 0.3s 才发 died"的注释）。
	if DisplayServer.get_name() != "headless":
		dying.emit(self)
		modulate.a = 0.0        # 本体立刻让位给碎片（特效由 HUD 的 DeathFx 画）
	var t := create_tween()
	t.tween_interval(0.3)
	t.tween_callback(func():
		if is_instance_valid(self):
			died.emit(self))   # 单位已释放则不再 emit，避免访问已释放 self

func reset_for_new_turn() -> void:
	moved_this_turn = false
	attacked_this_turn = false
	counter_used_this_turn = false
	once_this_turn = false

func set_selected(sel: bool) -> void:
	if alive:
		if sel:
			z_index = 10
			scale = Vector2(1.08, 1.08)
		else:
			z_index = 2
			scale = Vector2.ONE
	set_highlight_ring(sel)

# 【2026-09-30·用户报「可攻击目标显示没了」】⚠️ 根因：阵营底色改成**不透明**之后（见 `_faction_color`），
#   棋盘画在**格子上**的"可攻击黄格"被棋子整个盖住（棋子 z=2 > 棋盘 z=1）⇒ 选中英雄后看不出能打谁。
#   ⇒ 由 `Battle._refresh_target_rings()` 把"被占住的目标格"标到**棋子自己身上**。
# 【2026-09-30·用户口径「把可攻击目标黄色改为框选」】第一版是往人像上糊一层**黄色薄罩**（`Polygon2D`，
#   α 0.32）—— 用户要的是**框选**：现在改成**六边形描边**（`Line2D`），与金色选中边（`set_highlight_ring`）
#   同一套画法：半径 `hex_radius + 5.0`（**比金边的 +2 靠外**，两圈能同时看到、不互相压）、
#   线宽 `3.5 × fs`（与金边一致）、层 `FRAME_Z`。颜色仍由调用方给（黄=可攻击 / 橙·金=敌方预览）。
#   ⚠️ 框是"贴着棋子边沿"画的：`+5` 那圈的外接半径 76.5px、apothem 66.3px，而棋子底色 apothem 66.9px
#   ⇒ 正好压在棋子边缘内侧一线，不会探到隔壁格子里去。
const TARGET_RING_A := 0.9
var _target_ring: Line2D = null      # 可攻击/可预览的"框选"描边（没被标记过则为 null）
func set_target_ring(on: bool, col := Color(1.0, 0.9, 0.45)) -> void:
	if not on:
		if _target_ring != null:
			_target_ring.visible = false
		return
	if not is_inside_tree():
		return   # 未入树（已释放/尚未加入场景）：不建特效，安全退（与 `set_acting_ring` 同款）
	if _target_ring == null:
		_target_ring = Line2D.new()
		_target_ring.points = _hex_points(hex_radius + 5.0)
		_target_ring.closed = true
		_target_ring.width = 3.5 * (hex_radius / 54.0)   # 与金色选中边同宽
		_target_ring.z_index = FRAME_Z
		add_child(_target_ring)
	_target_ring.default_color = Color(col.r, col.g, col.b, TARGET_RING_A)
	_target_ring.visible = true

# 高亮描边（选中己方 / 预览敌方共用同一粗细的金边，保证视觉一致）
func set_highlight_ring(on: bool) -> void:
	if not on:
		if _sel_border != null:
			_sel_border.visible = false
		return
	# 金色选中描边：棋盘层高亮的黄格会被单位自身实心六边形盖住，
	# 故在单位上叠加金边；与点击己方/敌方统一粗细
	if _sel_border == null:
		_sel_border = Line2D.new()
		_sel_border.points = _hex_points(hex_radius + 2.0)
		_sel_border.closed = true
		_sel_border.width = 3.5 * (hex_radius / 54.0)   # 金边线宽随棋盘放大
		_sel_border.z_index = FRAME_Z
		_sel_border.default_color = Color(1.0, 0.85, 0.3)
		add_child(_sel_border)
	_sel_border.visible = true

# 敌方 AI 行动指示：正在行动的单位外圈套一层红橙脉冲描边。
# 与金色选中边（set_highlight_ring）区分：颜色更暖、线更粗，让玩家一眼看出"这一步是谁在动"，
# 多名敌人连招时不会看串。on=false 立即熄灭（回合结束/重开时必须清掉）。
func set_acting_ring(on: bool) -> void:
	if not on:
		if _acting_tween != null:
			_acting_tween.kill()
			_acting_tween = null
		if _acting_border != null:
			_acting_border.modulate.a = 0.0
			_acting_border.visible = false
		return
	if not is_inside_tree():
		return   # 未入树（已释放/尚未加入场景）：不建特效，安全退
	if _acting_border == null:
		_acting_border = Line2D.new()
		_acting_border.points = _hex_points(hex_radius + 5.0)
		_acting_border.closed = true
		_acting_border.width = 5.0 * (hex_radius / 54.0)   # 线宽随棋盘放大，比选中边粗
		_acting_border.z_index = FRAME_Z
		_acting_border.default_color = Color(1.0, 0.42, 0.22)
		_acting_border.modulate.a = 0.0
		add_child(_acting_border)
	if _acting_tween != null:
		_acting_tween.kill()
	_acting_border.visible = true
	_acting_border.modulate.a = 1.0
	# 呼吸式脉冲：持续闪烁到该英雄行动结束（set_acting_ring(false) 时 kill）
	var t := create_tween().set_loops()
	_acting_tween = t
	t.tween_property(_acting_border, "modulate:a", 0.25, 0.42)
	t.tween_property(_acting_border, "modulate:a", 1.0, 0.42)

# 本回合仍有行动（未完成移动+攻击）的标识：顶部亮点
func set_action_marker(show_dot: bool) -> void:
	if _action_dot == null:
		_action_dot = Label.new()
		_action_dot.text = "●"
		_action_dot.add_theme_font_size_override("font_size", 26)
		_action_dot.add_theme_color_override("font_color", Color(1.0, 0.85, 0.2))
		_action_dot.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
		_action_dot.add_theme_constant_override("outline_size", 3)
		_action_dot.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_action_dot.size = Vector2(24, 24)
		_action_dot.position = Vector2(-12, -hex_radius * 0.58)   # 六边形顶部内侧（见 set_action_markers 的说明）
		_action_dot.z_as_relative = false
		_action_dot.z_index = ACTION_Z   # 行动点例外层（见文件头契约③）：谁的东西都盖不住它
		add_child(_action_dot)
	_action_dot.visible = show_dot

# 分离的行动标识：可移动=绿色，可攻击=红色。整体在六边形**顶部内侧**居中显示（位置/层见下面那几行说明）。
func set_action_markers(has_move: bool, has_attack: bool) -> void:
	if _marker_host == null:
		_marker_host = Control.new()
		_marker_host.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_marker_host.z_as_relative = false
		_marker_host.z_index = ACTION_Z   # 行动点例外层（见文件头契约③）：谁的东西都盖不住它
		add_child(_marker_host)
		_move_dot = _make_dot(Color(0.3, 0.95, 0.35))
		_attack_dot = _make_dot(Color(1.0, 0.3, 0.25))
		_marker_host.add_child(_move_dot)
		_marker_host.add_child(_attack_dot)
	_move_dot.visible = has_move
	_attack_dot.visible = has_attack
	# 居中：容器宽 = 可见点数*24 并对齐 hex 顶部内侧的中点；绿(移动)占左格、红(攻击)占右格，
	# 只亮红时红点单独在容器中央（即 hex 顶部内侧正中）。
	var n := (1 if has_move else 0) + (1 if has_attack else 0)
	_marker_host.size = Vector2(n * 24, 24)
	# 【2026-09-28·用户两次口径「可行动提示点被上面英雄的特性字挡住」→「下面点啊，不要被上面英雄的特性挡住」】
	#   位置：**六边形顶部内侧**（`0.58r`），不再挂在六边形**外面** —— 外面那块空隙会被同列上邻的特性字
	#   吃掉（行距 √3·r，上邻的字挂它牌面下沿 `0.72r~1.0r` ⇒ 换算到我们头顶就是 `0.53r~0.73r`），
	#   0.58r 处正好在那行字下面（r≈73 时留 ~9px），也在本棋子人物头顶之上、不压攻血数字与状态字。
	#   层：仍走 `ACTION_Z` 的**绝对层**做保险（`z_as_relative = false`）⇒ 任何情况下都不会被别的棋子盖住。
	#   想再低/再高（更靠中间）只改这一个系数：`0.50` 更居中、`0.66` 更贴顶。
	_marker_host.position = Vector2(-_marker_host.size.x / 2.0, -hex_radius * 1.05)
	_move_dot.position = Vector2(0, 0)
	_attack_dot.position = Vector2(24 if has_move else 0, 0)

func _make_dot(col: Color) -> Label:
	var d := Label.new()
	d.text = "●"
	d.add_theme_font_size_override("font_size", 24)
	d.add_theme_color_override("font_color", col)
	d.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	d.add_theme_constant_override("outline_size", 3)
	d.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	d.size = Vector2(24, 24)
	d.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return d

# 【2026-09-28·新增·用户要求】[圣盾] 演出：一个**金黄半透明的罩**罩住棋子，整圈**一闪一闪**。
#   · 只在有 `StatusDB.SHIELD` 时存在/可见 —— 建与收都在 `Unit._refresh_shield_aura()`；
#   · 画在 `FRAME_Z`（框/光环层，见文件头图层契约）⇒ 压在六边形底色与人物图**之上**、攻血数字与状态字**之下**；
#   · headless（RL 跑批 / 无窗口自检）**不建这个节点** ⇒ 零绘制开销、跑批行为逐位不变；
#   · 所有视觉旋钮在这个类顶部：`R_MUL` 罩多大 / `FILL_A` 罩面多透 / `RIM_A` 边圈多亮 / `RIM_W` 边圈多粗 /
#     `BLINK` 闪多快 / `BLINK_MIN` 暗下来时还剩多少亮度。位置/角度全用固定算式，不占随机源。
class ShieldAura extends Node2D:
	const R_MUL := 1.04       # 罩半径 = 棋子半径 × 该值（1.0 = 正好外接六边形）
	const FILL_A := 0.10      # 罩面金黄透明度（越小越像一层气泡）
	const RIM_A := 0.55       # 边圈基础亮度（会被闪烁调制）
	const RIM_W := 3.2        # 边圈线宽（按棋子半径等比放大）
	const BLINK := 3.4        # 闪烁快慢（越大闪得越快；一整个明暗周期 ≈ 2π / 该值 秒）
	const BLINK_MIN := 0.25   # 最暗时保留的亮度比例（0 = 直接灭掉，1 = 不闪）
	var radius := 44.0
	var _t := 0.0

	func _process(delta: float) -> void:
		_t += delta
		queue_redraw()

	func _draw() -> void:
		var k := radius / 44.0                       # 随棋子尺寸等比缩放（基准 radius 44）
		var r := radius * R_MUL
		var gold := Color(1.0, 0.84, 0.32)
		var bl := 0.5 + 0.5 * sin(_t * BLINK)        # 0~1 闪烁相位
		bl = pow(bl, 1.5)                            # 亮得尖、暗得柔 ⇒ 读起来是"闪"而不是"呼吸"
		var glow := BLINK_MIN + (1.0 - BLINK_MIN) * bl
		# 罩面：三层同心圆叠出"中间透、边上亮"的气泡感（整层跟着一起明暗）
		draw_circle(Vector2.ZERO, r, Color(gold.r, gold.g, gold.b, FILL_A * glow))
		draw_arc(Vector2.ZERO, r * 0.82, 0.0, TAU, 48, Color(1.0, 0.90, 0.50, FILL_A * 0.9 * glow), 6.0 * k, true)
		draw_arc(Vector2.ZERO, r * 0.94, 0.0, TAU, 56, Color(1.0, 0.88, 0.45, FILL_A * 1.4 * glow), 5.0 * k, true)
		# 金色边圈：外发光 + 主圈两层，整圈一起一闪一闪
		draw_arc(Vector2.ZERO, r, 0.0, TAU, 64, Color(gold.r, gold.g, gold.b, RIM_A * 0.35 * glow), (RIM_W + 4.0) * k, true)
		draw_arc(Vector2.ZERO, r, 0.0, TAU, 64, Color(gold.r, gold.g, gold.b, RIM_A * glow), RIM_W * k, true)
		# 左上角高光弧（气泡反光）跟着一起闪
		draw_arc(Vector2.ZERO, r * 0.88, PI * 1.02, PI * 1.42, 18, Color(1.0, 1.0, 0.92, 0.30 * glow), 3.0 * k, true)

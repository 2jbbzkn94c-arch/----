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
var perm_atk := 0              # 永久攻击加成（攻击道具/金矿/涌电技师+1），变身重置攻击力时保留
# 圣诞老人道具的一次性 buff：拾取后在下一次对应动作时生效，用掉即消失
var atk_use_buff := 0          # 攻击 buff：下一次攻击伤害+ 该项，攻击结算后自减
var move_use_buff := 0         # 移动 buff：下一次移动力+ 该项，移动后自减
var transform_base_id := ""    # 古灵精怪：变身后回溯本源（hero_28），便于每回合重新变身
var last_transform_id := ""    # 古灵精怪：上一次变身后为了不重复变成同一对象
var summon_owner := ""         # 召唤者的单位 id（死灵法师召唤的骷髅兵：主人阵亡时随之消散）
var behavior: HeroBase = null  # 该单位所属英雄的行为脚本（HeroRegistry 创建），技能逻辑分发用
var los_ignore := false    # 坠炮手(hero_45)：攻击弹道无视障碍/单位/墓碑阻挡
var grave_moved := false  # 暗域占据死亡格时：墓碑已回退到暗域原格，避免在死亡格重复立碑

var hex_radius := 44.0

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
	_hex.polygon = _hex_points(hex_radius)
	_hex.color = _faction_color(faction)
	add_child(_hex)

	# 【2026-09-27·用户要求】棋子上也放"人物本体"：在纯色六边形**之上**再贴一层同多边形的贴图
	#   （`Polygon2D` 自带"按多边形裁剪" ⇒ 放大到顶满也不溢出卡边）。
	#   底下那层纯色没撤 ⇒ **阵营色（我方蓝 / 敌方红）仍从人物四周透出来**，与选人卡一个观感；
	#   贴图层用白色（= 不染色），人物保持原色。
	_art = DataRegistry.hero_card_art(display_name)
	_art_hex = Polygon2D.new()
	_art_hex.polygon = _hex.polygon
	_art_hex.color = Color(1, 1, 1, 1)
	# 【2026-09-27·用户报"糊 + 锯齿"】图带 mipmap，必须显式开 `LINEAR_WITH_MIPMAPS` 才会用到；
	#   棋子只有 ~146px 宽而图是 512 ⇒ 无 mipmap 的缩小采样就是锯齿+发糊的来源。
	_art_hex.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	# 图被多边形裁掉的那两条边（顶/底，因为人顶满了）也做抗锯齿
	_art_hex.antialiased = true
	add_child(_art_hex)
	_apply_hex_art()

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
	_debuff_label.size = Vector2(hex_radius * 2.0, 14.0 * fs)
	_debuff_label.add_theme_color_override("font_color", Color(0.78, 0.5, 1.0))
	_debuff_label.visible = false
	add_child(_debuff_label)

	# 【2026-09-28·用户口径】前景标记层（常量 `MARKER_Z`，见文件头图层契约）：名字 / 词条 / 攻击图标+数字 /
	#   血量图标+数字 / 状态字都摆在**这一层**——压在背景（`_hex`/`_art_hex`）和框（`FRAME_Z`）之上、
	#   附体魂线之下。这里最后一次性设，免得以后往这段里加标记时忘了设 z
	#   （变身时补建的攻击图标在 `update_atk_icon()` 里自己设）。
	for c: CanvasItem in get_children():
		if c == _hex or c == _art_hex:
			continue
		c.z_index = MARKER_Z

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

# 【2026-09-27·用户要求】棋子六边形的阵营底色**透明度**：
#   原来 alpha = 1.0 ⇒ 六边形把木纹整块盖死；卡面图上线后下面还垫着一层实心色，看着很重。
#   只改**底色这一层**（`_hex.color`）——卡面贴图（`_art_hex`）不受影响，仍是不透明的原色。
#   想更透就往下调（0.40 ≈ 很透 / 0.70 ≈ 只压一层淡色），只改这一个常量。
const FACTION_FILL_ALPHA := 0.55

func _faction_color(f: int) -> Color:
	if f == DataRegistry.Faction.PLAYER:
		return Color(0.25, 0.55, 0.9, FACTION_FILL_ALPHA)
	return Color(0.85, 0.32, 0.28, FACTION_FILL_ALPHA)

# Battle 在造成重击(如嬉皮死神双倍)前调用：本次受击的伤害数字用紫粉放大样式
func set_big_hit_style() -> void:
	_dmg_style = 2

func is_shield_hit_blocked() -> bool:
	return _shield_block_status

# 【2026-09-28·用户要求·击杀预告】"这一击过门之后会扣多少血 / 会不会致死"的**纯计算**（不改任何状态）：
#   · `damage_amount()`：重伤 +1、坚固（仅攻击伤害）−1，最低 0 —— `take_damage()` 与预告共用同一把尺；
#   · `would_be_lethal()`：圣盾在身 ⇒ 这一击被完全挡下、不掉血 ⇒ 不是击杀。
#   ⚠️ **塔盾代扛**（`_bulwark_absorb`，相邻塔盾替挡 1 点）不在里面：那个钩子会**消耗塔盾的盾**（有副作用），
#      不能预演 ⇒ 预告按"没有塔盾"估。唯一的偏差方向是"预告了却没打死（被塔盾救下）"，是安全的。
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
		_float_text("-%d" % dmg, Color(1.0, 0.18, 0.12), -32, -52, true)
	else:
		_float_text("-%d" % dmg, Color(1.0, 0.18, 0.12), -32, -46)
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
func _float_text(text: String, color: Color, xoff: int = -32, yoff: int = -46, big := false) -> void:
	var parent := get_parent()
	if parent == null or not is_inside_tree():
		return
	var k := hex_radius / 54.0   # 视觉反馈随棋盘放大(基准:旧 hex60 → radius54)
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", maxi(14, int((26.0 if big else 21.0) * k)))
	lbl.add_theme_color_override("font_color", color)
	lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	lbl.add_theme_constant_override("outline_size", maxi(2, int((5.0 if big else 4.0) * k)))
	lbl.z_index = 120
	lbl.position = global_position + Vector2(xoff * k, yoff * k)
	lbl.size = Vector2(64.0 * k, 28.0 * k)
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
	_float_text("+%d" % amount, HEAL_COLOR)
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
# 攻击力：回合增益（攻击道具/烈焰祭司/锤头鲨/负墟）+ 一次性道具增益（下一次攻击+1）+ 共鸣/太阳斩/冲锋
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

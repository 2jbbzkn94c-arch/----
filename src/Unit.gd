class_name Unit
extends Node2D
## 棋盘上的英雄单位。负责绘制自身外形、记录属性/所在格、承担伤害与死亡。

signal died(unit: Unit)
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
var _neg_immune_frame := -1    # 负墟：免疫负面时记录处理帧，同一帧（同一次攻击的多个负面）只计一次

var hex_radius := 44.0

var _hex: Polygon2D
var _label: Label
var _atk_label: Label
var _hp_label: Label
var _status_label: Label
var _tags_label: Label
var _passive_border: Line2D
var _passive_tween: Tween
var _sel_border: Line2D = null   # 金色选中描边（选中时叠加在单位六边形上）
var _action_dot: Label   # 本回合仍有行动的顶部标识（旧，保留兼容）
var _move_dot: Label      # 可移动标识（绿色）
var _attack_dot: Label    # 可攻击标识（红色）
var _marker_host: Control # 红绿标识容器（整体居中）
var _was_counter_damage := false   # 本次受伤是否为反击伤害

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
	hp = max_hp
	cell = cell_
	hex_radius = radius
	_id_counter += 1
	id = "unit_%d" % _id_counter

func _ready() -> void:
	z_index = 2
	_build_visual()

func _build_visual() -> void:
	var fs := hex_radius / 39.0   # 字号缩放系数：棋子随 hex_size 放大时文字等比放大（基准 48*0.82≈39）
	_hex = Polygon2D.new()
	_hex.polygon = _hex_points(hex_radius)
	_hex.color = _faction_color(faction)
	add_child(_hex)

	_label = Label.new()
	_label.text = display_name
	_label.add_theme_font_size_override("font_size", int(12.0 * fs))
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.position = Vector2(-hex_radius, -hex_radius * 0.5)
	_label.size = Vector2(hex_radius * 2.0, 15.0 * fs)
	_label.add_theme_color_override("font_color", Color.WHITE)
	_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_label.add_theme_constant_override("outline_size", maxi(3, int(4.5 * fs)))
	add_child(_label)

	# 数值图标簇：左下=攻击.png、右下=爱心.png，数字居中压在图标内（先加图标、后加文字）
	var num_icon_w := hex_radius * 0.7   # 剑（攻击）的框大小
	var hp_icon_w := num_icon_w * 1.0   # 爱心单独放大：比剑大 10%；想更大就加大系数并配合把 hp_c.x 往左调
	var atk_c := Vector2(-hex_radius * 0.34, hex_radius * 0.6)
	var hp_c := Vector2(hex_radius * 0.36, hex_radius * 0.6)   # 爱心中心（大爱心需稍左移避免出右边框）
	var atk_icon := _make_stat_icon(DataRegistry.ICON_ATK, atk_c, num_icon_w)
	if atk_icon != null:
		atk_icon.name = "AtkIcon"
		add_child(atk_icon)
	_atk_label = Label.new()
	_atk_label.add_theme_font_size_override("font_size", int(17.0 * fs))
	_atk_label.add_theme_font_override("font", DataRegistry.stat_bold_font())   # 数字加粗
	_atk_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_atk_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_atk_label.size = Vector2(num_icon_w, num_icon_w * 0.8)
	_atk_label.position = atk_c - _atk_label.size / 2.0 + Vector2(0, num_icon_w * 0.06)
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

	# 状态标签（猛伤攻冻默晕盾）——放在六边形中部、界内
	_status_label = Label.new()
	_status_label.add_theme_font_size_override("font_size", int(11.0 * fs))
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.position = Vector2(-hex_radius, -hex_radius * 0.15)
	_status_label.size = Vector2(hex_radius * 2.0, 14.0 * fs)
	# 减益用紫色（原粉红与敌方红卡面太接近）；仅圣盾时淡蓝（见 _update_status_label 覆盖）
	_status_label.add_theme_color_override("font_color", Color(0.78, 0.5, 1.0))
	add_child(_status_label)

# 数值图标（攻击/血量）：素材白底已在 DataRegistry 抠透明并记录主体尺寸(w/h/cx/cy)。
# 保持长宽比缩放到"外接框边长=box"内（宽高谁大以谁定基准），并把主体中心精确放到 center。
func _make_stat_icon(path: String, center: Vector2, box: float) -> Sprite2D:
	var info := DataRegistry.stat_icon(path)
	var tex: Texture2D = info.get("tex")
	var bw := int(info.get("w", 0))
	var bh := int(info.get("h", 0))
	if tex == null or bw <= 0 or bh <= 0:
		return null   # 资源未导入/缺失：退回无图标
	var spr := Sprite2D.new()
	spr.texture = tex
	var sc := box / float(maxi(bw, bh))
	spr.scale = Vector2(sc, sc)
	var tsz := tex.get_size()
	spr.position = center - Vector2(float(info.get("cx", tsz.x / 2.0)) - tsz.x / 2.0,
			float(info.get("cy", tsz.y / 2.0)) - tsz.y / 2.0) * sc
	return spr

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
	return out

func _hex_points(r: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in 6:
		var a := deg_to_rad(60.0 * i)   # flat-top：平边朝上
		pts.append(Vector2(cos(a), sin(a)) * r)
	return pts

func _faction_color(f: int) -> Color:
	if f == DataRegistry.Faction.PLAYER:
		return Color(0.25, 0.55, 0.9, 1.0)
	return Color(0.85, 0.32, 0.28, 1.0)

func take_damage(amount: int, ignore_shield: bool = false, counter: bool = false, cause: String = "") -> void:
	if not alive:
		return
	_was_counter_damage = counter   # 记录本次是否为反击伤害
	# 圣盾：防止一次受到的伤害，消费后解除
	if not ignore_shield and has_status("shield"):
		remove_status("shield")
		_float_text("[圣盾]", Color(0.5, 0.8, 1.0), -24, -46)
		return
	# 重伤：受到的伤害 +1
	var dmg := amount + (1 if has_status("heavy") else 0)
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
	damaged.emit(self, dmg)
	_update_hp_label()
	_flash()
	_shake()
	# 反击伤害用蓝色，居中落在被反击对象身上，与普通攻击伤害（橙红）区分
	if counter:
		_float_text("-%d" % dmg, Color(0.35, 0.8, 1.0), -22, -44)
	else:
		_float_text("-%d" % dmg, Color(1.0, 0.45, 0.4), -24, -46)
	AudioManager.play("hit")
	if hp <= 0:
		die()

# ---- 状态效果 ----
# 负墟：所有负面效果对其无效。判定用状态 key（与 add/remove 同 key）。
func _is_negative_status(s: String) -> bool:
	return s == "heavy" or s == "atkdown" or s == "freeze" or s == "silence" or s == "stun" or s == "poison"

func add_status(s: String) -> void:
	# 负墟（hero_44）：免疫负面效果——不挂状态，改为"被负面攻击命中"计数 +1 攻击
	# （一次攻击内连续施加多个负面只计一次：同帧去重）
	if hero_id == "hero_44" and _is_negative_status(s):
		_neg_immune_on_hit()
		return
	statuses[s] = true
	_update_status_label()

func _neg_immune_on_hit() -> void:
	var f := Engine.get_process_frames()
	if f == _neg_immune_frame:
		return   # 同一帧（同一次攻击的多个负面）只算一次
	_neg_immune_frame = f
	atk_buff += 1
	refresh_stats()
	_float_text("免疫负面 攻+1", Color(0.8, 0.75, 1.0), -22, -48)

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

# 刷新名字标签（用于古灵精怪变身等）
func _update_name_label() -> void:
	if _label:
		_label.text = display_name

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
	tag_label.position = Vector2(-hex_radius, -hex_radius * 0.84)
	tag_label.size = Vector2(hex_radius * 2.0, hex_radius * 0.34)
	# 绿字+深色描边：特性标签(嘲/疾/渗/勤/候)，不撞本方蓝/敌方红/紫减益/金黄盾
	tag_label.add_theme_color_override("font_color", Color(0.5, 0.9, 0.45))
	tag_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	tag_label.add_theme_constant_override("outline_size", 3)
	tag_label.text = _skill_tags()
	add_child(tag_label)
	_tags_label = tag_label

func clear_temp_statuses() -> void:
	for s in ["heavy", "atkdown", "freeze", "silence", "stun"]:
		statuses.erase(s)
	_update_status_label()

# 有效攻击力（含 buff / ** / 冲锋加成；远程被贴身时：基础攻击压为1，buff 照常叠加）
# ranged_adjacent 由 Battle 在局面变化时更新（true=有敌人紧邻=远程被贴身）
var ranged_adjacent := false

func effective_atk() -> int:
	var base := atk
	if attack_type == DataRegistry.AttackType.RANGED and ranged_adjacent:
		base = 1   # 远程被贴身：默认攻击力变为 1（buff 不受影响）
	var a := base + atk_buff + ramble_bonus + sun_bonus + atk_use_buff
	if has_status("atkdown"):
		a -= 1
	return max(a, 0)

func effective_move() -> int:
	if has_status("stun"):
		return 0
	var m := move_range + move_buff + move_use_buff
	if has_status("freeze"):
		m -= 1
	return max(m, 0)

# 远程被贴身状态变化时更新（Battle 在局面变化后调用），并刷新面板攻击显示
func set_ranged_adjacent(adj: bool) -> void:
	if ranged_adjacent == adj:
		return
	ranged_adjacent = adj
	_update_atk_label()

func can_move() -> bool:
	return alive and not has_status("stun")

func can_attack() -> bool:
	return alive and not has_status("stun")

func skill_allowed() -> bool:
	# 眩晕：不能移动/攻击，也不能触发任何技能（回合开始/结束、登场、光环等）
	return alive and not has_status("silence") and not has_status("stun")

func _update_status_label() -> void:
	# 在单位牌面下加状态小字
	var txt := ""
	var has_debuff := false
	if has_status("poison"):
		txt += "毒"
		has_debuff = true
	if has_status("heavy"):
		txt += "伤"
		has_debuff = true
	if has_status("atkdown"):
		txt += "麻"
		has_debuff = true
	if has_status("freeze"):
		txt += "冻"
		has_debuff = true
	if has_status("silence"):
		txt += "默"
		has_debuff = true
	if has_status("stun"):
		txt += "晕"
		has_debuff = true
	if has_status("shield"):
		txt += "盾"
	if _status_label:
		_status_label.text = txt
		# 配色：减益=紫色（勿与敌方红色卡面混淆）；仅剩圣盾(增益)=金黄（勿用蓝，与本方蓝卡面接近）
		var col := Color(1.0, 0.85, 0.4)
		if has_debuff:
			col = Color(0.78, 0.5, 1.0)
		_status_label.add_theme_color_override("font_color", col)

# 受击震屏：仅抖动六边形本体，不影响单位移动坐标
func _shake() -> void:
	if _hex == null:
		return
	var t := create_tween()
	var d := Vector2(4, -3)
	t.tween_property(_hex, "position", d, 0.05)
	t.tween_property(_hex, "position", Vector2.ZERO, 0.12)

# 伤害/治疗飘字（挂在父节点以固定在棋盘坐标，上浮并淡出）
func _float_text(text: String, color: Color, xoff: int = -24, yoff: int = -46) -> void:
	var parent := get_parent()
	if parent == null or not is_inside_tree():
		return
	var k := hex_radius / 54.0   # 视觉反馈随棋盘放大(基准:旧 hex60 → radius54)
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", maxi(12, int(18.0 * k)))
	lbl.add_theme_color_override("font_color", color)
	lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	lbl.add_theme_constant_override("outline_size", maxi(2, int(4.0 * k)))
	lbl.z_index = 120
	lbl.position = global_position + Vector2(xoff * k, yoff * k)
	lbl.size = Vector2(48.0 * k, 24.0 * k)
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

# 治疗飘字（供 Battle 后勤调用）
func float_heal(amount: int) -> void:
	_float_text("+%d" % amount, Color(0.45, 0.95, 0.5))

func _update_hp_label() -> void:
	if _hp_label:
		_hp_label.text = str(hp)

func _update_atk_label() -> void:
	if _atk_label:
		_atk_label.text = str(effective_atk())

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
	ring.z_index = 14
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
		dot.z_index = 14
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
func flash_passive() -> void:
	if _passive_border == null:
		_passive_border = Line2D.new()
		_passive_border.points = _hex_points(hex_radius + 2.0)
		_passive_border.closed = true
		_passive_border.width = 4.0
		_passive_border.z_index = 15
		_passive_border.default_color = Color(1.0, 0.92, 0.35)
		_passive_border.modulate.a = 0.0
		add_child(_passive_border)
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
	var t := create_tween()
	t.tween_property(self, "modulate:a", 0.0, 0.3)   # 完全淡出，避免残留显示
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
		_sel_border.z_index = 16
		_sel_border.default_color = Color(1.0, 0.85, 0.3)
		add_child(_sel_border)
	_sel_border.visible = true

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
		_action_dot.position = Vector2(-12, -hex_radius - 16)
		add_child(_action_dot)
	_action_dot.visible = show_dot

# 分离的行动标识：可移动=绿色，可攻击=红色。整体在六边形正上方居中显示。
func set_action_markers(has_move: bool, has_attack: bool) -> void:
	if _marker_host == null:
		_marker_host = Control.new()
		_marker_host.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(_marker_host)
		_move_dot = _make_dot(Color(0.3, 0.95, 0.35))
		_attack_dot = _make_dot(Color(1.0, 0.3, 0.25))
		_marker_host.add_child(_move_dot)
		_marker_host.add_child(_attack_dot)
	_move_dot.visible = has_move
	_attack_dot.visible = has_attack
	# 居中：容器宽 = 可见点数*24 并对齐 hex 顶边中点；绿(移动)占左格、红(攻击)占右格，
	# 只亮红时红点单独在容器中央（即 hex 中央上方）。
	var n := (1 if has_move else 0) + (1 if has_attack else 0)
	_marker_host.size = Vector2(n * 24, 24)
	_marker_host.position = Vector2(-_marker_host.size.x / 2.0, -hex_radius - 18)
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

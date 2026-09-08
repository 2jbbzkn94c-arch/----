class_name HexCard
extends Control
## 可点击的六边形卡牌（选人界面用）。自绘六边形、可悬停/选中，点击发信号。

signal hovered(id: String)
signal clicked(id: String)

var hero_id := ""
var def: DataRegistry.HeroDef
var selected := false
var disabled_draw := false   # 灰暗显示（非本人回合）
var radius := 45.0

var _label: Label

func _init(def_: DataRegistry.HeroDef, id: String, r: float = 45.0) -> void:
	def = def_
	hero_id = id
	radius = r
	# 控制区尺寸（平顶六边形：宽=2r，高=√3r）
	custom_minimum_size = Vector2(2.0 * radius, sqrt(3.0) * radius)
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_entered.connect(func(): hovered.emit(hero_id))
	mouse_exited.connect(func(): hovered.emit(""))
	set_process_input(true)

func _ready() -> void:
	_build_label()

func _build_label() -> void:
	var c := size / 2.0
	# 名称行：放在卡面中上（颜色沿用稀有度色）。字号随卡片缩放，下限 12 保证小卡也清晰
	var name_fs := int(clampf(radius * 0.34, 12.0, 36.0))
	_label = Label.new()
	_label.text = def.display_name
	_label.add_theme_font_override("font", DataRegistry.stat_bold_font())   # 名字加粗
	_label.add_theme_font_size_override("font_size", name_fs)
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.add_theme_color_override("font_color", _rarity_color())
	_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	_label.add_theme_constant_override("outline_size", 2)
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 名字整体略下移（原顶部 -0.72r → -0.66r），更贴近卡面中上部视觉重心
	_label.position = c + Vector2(-radius, -radius * 0.5)
	_label.size = Vector2(radius * 2.0, radius * 0.52)
	add_child(_label)
	# 词条标签（嘲/疾/渗/勤/候）：顶部小字，与棋盘棋子一致；无词条则省略
	var tags := _card_tags()
	if tags != "":
		var tagl := Label.new()
		tagl.text = tags
		tagl.add_theme_font_size_override("font_size", int(clampf(radius * 0.2, 9.0, 20.0)))
		tagl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		tagl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		# 绿字（与棋盘棋子特性标签一致：不撞蓝/红卡面、紫减益、金黄盾）
		tagl.add_theme_color_override("font_color", Color(0.5, 0.9, 0.45))
		tagl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
		tagl.add_theme_constant_override("outline_size", 2)
		tagl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tagl.position = c + Vector2(-radius, -radius * 0.84)
		tagl.size = Vector2(radius * 2.0, radius * 0.3)
		add_child(tagl)
	# 数值图标：左下=攻击.png，右下=爱心.png；数字压在图标主体中心，图标放大到数字完全在内
	var icon_w := clampf(radius * 0.7, 24.0, 96.0)
	var num_fs := int(clampf(icon_w * 0.56, 12.0, 44.0))
	var atk_c := c + Vector2(-radius * 0.32, radius * 0.5)
	var hp_c := c + Vector2(radius * 0.36, radius * 0.5)
	var atk_icon := _make_stat_icon(DataRegistry.ICON_ATK, atk_c, icon_w)
	var hp_icon := _make_stat_icon(DataRegistry.ICON_HEART, hp_c, icon_w)
	if atk_icon == null and hp_icon == null:
		# 素材缺失兜底：退回"HP… 攻…"文字
		_label.text = def.display_name + "\nHP%d 攻%d" % [def.max_hp, def.atk]
		_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		return
	if atk_icon != null:
		add_child(atk_icon)
		_add_stat_number(atk_c, icon_w, num_fs, str(def.atk))
	if hp_icon != null:
		add_child(hp_icon)
		# 血量数字相对爱心再右移一点（爱心视觉中心偏左）
		_add_stat_number(hp_c + Vector2(icon_w * 0.001, 0.0), icon_w, num_fs, str(def.max_hp))

# 词条标签文字（与棋盘棋子 Unit._skill_tags 同一套缩写）
func _card_tags() -> String:
	var out := ""
	for s in def.skills:
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

# 数字标签：与图标同中心、同主体宽；白字+黑描边（图标底色上仍清晰）
func _add_stat_number(center: Vector2, box_w: float, font_size: int, text: String) -> void:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_override("font", DataRegistry.stat_bold_font())   # 数字加粗
	lbl.add_theme_font_size_override("font_size", font_size)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0))
	lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.95))
	lbl.add_theme_constant_override("outline_size", maxi(4, int(font_size / 4.0)))
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lbl.size = Vector2(box_w, box_w * 0.7)
	lbl.position = center - lbl.size / 2.0 + Vector2(0, box_w * 0.05)
	add_child(lbl)

# 抠白后的图标 Sprite：保持长宽比放入"边长=box"的方框内（宽高谁大以谁定基准），主体中心对准 center
func _make_stat_icon(path: String, center: Vector2, box: float) -> Sprite2D:
	var info := DataRegistry.stat_icon(path)
	var tex: Texture2D = info.get("tex")
	var bw := int(info.get("w", 0))
	var bh := int(info.get("h", 0))
	if tex == null or bw <= 0 or bh <= 0:
		return null
	var spr := Sprite2D.new()
	spr.texture = tex
	var sc := box / float(maxi(bw, bh))
	spr.scale = Vector2(sc, sc)
	var tsz := tex.get_size()
	spr.position = center - Vector2(float(info.get("cx", tsz.x / 2.0)) - tsz.x / 2.0,
			float(info.get("cy", tsz.y / 2.0)) - tsz.y / 2.0) * sc
	return spr

func _rarity_color() -> Color:
	match def.rarity:
		DataRegistry.Rarity.SILVER:
			return Color(0.72, 0.75, 0.8)
		DataRegistry.Rarity.GOLD:
			return Color(0.95, 0.8, 0.4)
		DataRegistry.Rarity.MASTER:
			return Color(0.6, 0.85, 1.0)
		DataRegistry.Rarity.LEGEND:
			return Color(1.0, 0.55, 0.5)
	return Color.WHITE

func _rarity_bg() -> Color:
	match def.rarity:
		DataRegistry.Rarity.SILVER:
			return Color(0.20, 0.22, 0.28, 0.95)
		DataRegistry.Rarity.GOLD:
			return Color(0.30, 0.24, 0.12, 0.95)
		DataRegistry.Rarity.MASTER:
			return Color(0.12, 0.24, 0.34, 0.95)
		DataRegistry.Rarity.LEGEND:
			return Color(0.34, 0.12, 0.12, 0.95)
	return Color(0.2, 0.2, 0.24, 0.95)

func set_selected(sel: bool) -> void:
	if selected != sel:
		selected = sel
		# 选中卡提到兄弟卡之上：即使与邻卡接近/接触，高亮描边也不被后画的邻居盖住
		z_index = 2 if sel else 0
		queue_redraw()

func _draw() -> void:
	var c := size / 2.0
	var pts := PackedVector2Array()
	for i in 6:
		var a := deg_to_rad(60.0 * i)   # 平顶六边形（横线朝上）
		pts.append(c + Vector2(cos(a), sin(a)) * radius)
	var bg := _rarity_bg()
	if disabled_draw:
		bg = bg.darkened(0.45)
	draw_colored_polygon(pts, bg)
	# 选中高亮：粗黑描边（比绿色边框更醒目；宽度随卡片尺寸稍放大）
	var border := Color(0.04, 0.04, 0.06, 1.0) if selected else (_rarity_color().darkened(0.2) if disabled_draw else _rarity_color())
	draw_polyline(_closed(pts), border, (6.0 + radius * 0.05) if selected else 2.0, true)

func _closed(pts: PackedVector2Array) -> PackedVector2Array:
	var o := pts.duplicate()
	o.append(pts[0])
	return o

# 判断点是否落在六边形内（射线法，避免相邻矩形控件的点击误判）
func _point_in_hex(p: Vector2) -> bool:
	var local := p - size / 2.0
	var verts: Array[Vector2] = []
	for i in 6:
		var a := deg_to_rad(60.0 * i)
		verts.append(Vector2(cos(a), sin(a)) * radius)
	var inside := false
	var j := verts.size() - 1
	for i in verts.size():
		var vi := verts[i]
		var vj := verts[j]
		if ((vi.y > local.y) != (vj.y > local.y)) and (local.x < (vj.x - vi.x) * (local.y - vi.y) / (vj.y - vi.y) + vi.x):
			inside = not inside
		j = i
	return inside

# 触屏/鼠标：按下记起点，松开才算点击；若按下后发生拖动（滚动英雄池等）则不视为点击。
var _press_pos := Vector2(-1e6, -1e6)
var _press_moved := false
const _CLICK_DRAG_TOL := 16.0   # 按下后移动超过该距离视为拖动

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_press_pos = event.position
			_press_moved = false
		else:
			# 松开才算点击：要求按住期间基本没移动、且松开点仍在本卡内
			if not _press_moved and _point_in_hex(event.position):
				clicked.emit(hero_id)
			_press_moved = false
			accept_event()
	elif event is InputEventMouseMotion and (event.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
		if _press_pos.distance_to(event.position) > _CLICK_DRAG_TOL:
			_press_moved = true

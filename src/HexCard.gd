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
	_label = Label.new()
	_label.text = def.display_name + "\nHP%d 攻%d" % [def.max_hp, def.atk]
	# 字号随卡片尺寸缩放：小卡≈12，竞技场大卡(半径64)≈20，避免大卡面里字过小
	var fs := maxi(11, int(radius * 0.32))
	_label.add_theme_font_size_override("font_size", fs)
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.add_theme_color_override("font_color", _rarity_color())
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.position = Vector2(0, -6)
	_label.size = size
	add_child(_label)

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
		queue_redraw()

func _draw() -> void:
	var c := size / 2.0
	var pts := PackedVector2Array()
	for i in 6:
		var a := deg_to_rad(60.0 * i)   # 平顶六边形（横线朝上）
		pts.append(c + Vector2(cos(a), sin(a)) * (radius * 0.97))
	var bg := _rarity_bg()
	if disabled_draw:
		bg = bg.darkened(0.45)
	draw_colored_polygon(pts, bg)
	var border := Color(0.30, 1.0, 0.45) if selected else (_rarity_color().darkened(0.2) if disabled_draw else _rarity_color())
	draw_polyline(_closed(pts), border, 3.0 if selected else 2.0, true)

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
		verts.append(Vector2(cos(a), sin(a)) * (radius * 0.97))
	var inside := false
	var j := verts.size() - 1
	for i in verts.size():
		var vi := verts[i]
		var vj := verts[j]
		if ((vi.y > local.y) != (vj.y > local.y)) and (local.x < (vj.x - vi.x) * (local.y - vi.y) / (vj.y - vi.y) + vi.x):
			inside = not inside
		j = i
	return inside

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if _point_in_hex(event.position):
			clicked.emit(hero_id)
			accept_event()

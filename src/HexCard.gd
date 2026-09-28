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
# 【2026-09-28 用户要求】「录像列表就不需要显示血量攻击和特性了」⇒ 这两个开关给**只看"是谁"**的场合用：
#   关闭后卡面只剩六边形（种族底色）+ 人物卡面图（没出图的英雄仍画名字），不画攻/血图标与词条标签。
var show_stats := true       # 攻/血图标 + 数字
var show_tags := true        # 词条标签（嘲/疾/渗/勤/候）

var _label: Label            # 卡面**名字**行（只在"这张卡还没有卡面图"时才建，见 `_build_overlay`）
var _art: Texture2D = null   # 英雄卡面图（人物本体）；null = 该英雄还没出图 ⇒ 退回纯色六边形

func _init(def_: DataRegistry.HeroDef, id: String, r: float = 45.0) -> void:
	def = def_
	hero_id = id
	radius = r
	# 【2026-09-27·用户要求】卡面里放"人物本体"：按中文名找图（查表见 DataRegistry.hero_card_art）
	if def != null:
		_art = DataRegistry.hero_card_art(def.display_name)
	# 【2026-09-27·用户报"糊 + 锯齿"】图带 mipmap ⇒ 必须显式开 `LINEAR_WITH_MIPMAPS` 才会用到；
	#   卡实际只有 ~184px 宽（竞技场 `card_r=92`）而图是 512 ⇒ 无 mipmap 的缩小采样就是锯齿+发糊的来源。
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	# 控制区尺寸（平顶六边形：宽=2r，高=√3r）
	custom_minimum_size = Vector2(2.0 * radius, sqrt(3.0) * radius)
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_entered.connect(func(): hovered.emit(hero_id))
	mouse_exited.connect(func(): hovered.emit(""))
	set_process_input(true)

func _ready() -> void:
	_build_overlay()

# 名字行（**只给还没出图的英雄**）：放在卡面中上，颜色沿用种族色。
# 字号随卡片缩放，下限 12 保证小卡也清晰。
func _build_name_label(c: Vector2) -> void:
	var name_fs := int(clampf(radius * 0.34, 12.0, 36.0))
	_label = Label.new()
	_label.text = def.display_name
	_label.add_theme_font_override("font", DataRegistry.stat_bold_font())   # 名字加粗
	_label.add_theme_font_size_override("font_size", name_fs)
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.add_theme_color_override("font_color", _race_color())
	_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	_label.add_theme_constant_override("outline_size", 2)
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 【2026-09-27】名字（只给"还没出图"的英雄）挪到**卡面中部**：上排现在是攻/血图标、下排是词条
	_label.position = c + Vector2(-radius, -radius * 0.10)
	_label.size = Vector2(radius * 2.0, radius * 0.52)
	add_child(_label)

# 【2026-09-27·用户口径】名字**只画在"还没出图的英雄"上**：
#   · `_art != null`（已经有卡面图）⇒ 靠卡里的人物本体认人，**不画名字**；
#   · `_art == null`（还没出图）⇒ 照旧画名字（否则纯色六边形认不出是谁）。
func _build_overlay() -> void:
	var c := size / 2.0
	if _art == null:
		_build_name_label(c)
	# 词条标签（嘲/疾/渗/勤/候）：顶部小字，与棋盘棋子一致；无词条则省略
	var tags := _card_tags()
	if tags != "" and show_tags:
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
		# 【2026-09-27·用户要求】词条标签从"卡面顶部"挪到**最下面**（原来顶部会挡人物头部）
		tagl.position = c + Vector2(-radius, radius * 0.6)
		tagl.size = Vector2(radius * 2.0, radius * 0.3)
		add_child(tagl)
	# 数值图标：【2026-09-27·用户要求】攻击 → **左上**、血量 → **右上**（原在左下/右下，压着人物身体）；
	#   数字压在图标主体中心，图标放大到数字完全在内。y 取 −0.52r：六边形在该高度的半宽 ≈0.70r，
	#   而图标框半宽 ≈0.35r ⇒ 刚好不探出斜边。
	if not show_stats:
		return   # 只看"是谁"的场合（录像列表）：攻/血一概不画，卡面只剩六边形 + 人物图（见成员开关）
	var icon_w := clampf(radius * 0.6, 24.0, 96.0)
	var atk_icon_w := icon_w * 0.8   # ← 只改攻击图标（剑/弩/齿轮）；1.0 = 和爱心一样大
	var num_fs := int(clampf(icon_w * 0.56, 12.0, 44.0))
	var atk_c := c + Vector2(-radius * 0.4, radius * 0.55)
	var hp_c := c + Vector2(radius * 0.4, radius * 0.55)
	# 攻击图标：后勤角色用齿轮图，其次远程用弩图，最后近战用原剑图
	var atk_icon_path := DataRegistry.ICON_ATK_LOGISTICS if def.skills.has(DataRegistry.Skill.LOGISTICS) else (
		DataRegistry.ICON_ATK_RANGED if def.attack_type == DataRegistry.AttackType.RANGED else DataRegistry.ICON_ATK)
	var atk_icon := _make_stat_icon(atk_icon_path, atk_c, atk_icon_w)
	var hp_icon := _make_stat_icon(DataRegistry.ICON_HEART, hp_c, icon_w)
	if atk_icon == null and hp_icon == null:
		# 素材缺失兜底：另起一行只报数值（**不动名字行** —— 有卡面图的卡本来就没名字）
		var statl := Label.new()
		statl.text = "HP%d 攻%d" % [def.max_hp, def.atk]
		statl.add_theme_font_override("font", DataRegistry.stat_bold_font())
		statl.add_theme_font_size_override("font_size", int(clampf(radius * 0.30, 12.0, 32.0)))
		statl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		statl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		statl.add_theme_color_override("font_color", Color(1, 1, 1))
		statl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.95))
		statl.add_theme_constant_override("outline_size", 2)
		statl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		statl.position = c + Vector2(-radius, -radius * 0.5)
		statl.size = Vector2(radius * 2.0, radius * 1.0)
		add_child(statl)
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

func _race_color() -> Color:
	match def.race:
		DataRegistry.Race.HUMAN:   # 人族：金色
			return Color(0.95, 0.8, 0.4)
		DataRegistry.Race.MECH:    # 机械：金属银
			return Color(0.75, 0.78, 0.82)
		DataRegistry.Race.BEAST:   # 兽族：浅绿色
			return Color(0.55, 0.9, 0.5)
		DataRegistry.Race.ELF:     # 精灵：天蓝色
			return Color(0.45, 0.8, 1.0)
		DataRegistry.Race.DEMON:   # 魔族：红色
			return Color(0.9, 0.35, 0.3)
	return Color.WHITE

func _race_bg() -> Color:
	match def.race:
		DataRegistry.Race.HUMAN:
			return Color(0.30, 0.24, 0.12, 0.95)
		DataRegistry.Race.MECH:
			return Color(0.20, 0.22, 0.26, 0.95)
		DataRegistry.Race.BEAST:   # 兽族（浅绿）：深绿底
			return Color(0.10, 0.24, 0.10, 0.95)
		DataRegistry.Race.ELF:     # 精灵（天蓝）：深蓝底
			return Color(0.12, 0.24, 0.36, 0.95)
		DataRegistry.Race.DEMON:   # 魔族（红）：深红底
			return Color(0.32, 0.11, 0.11, 0.95)
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
	var bg := _race_bg()
	if disabled_draw:
		bg = bg.darkened(0.45)
	draw_colored_polygon(pts, bg)
	# 【2026-09-27·用户要求】卡面人物本体：**顶满卡面**（等比放大到顶到六边形上下边），
	#   并**按六边形裁剪**（`draw_polygon` + 逐顶点 UV ⇒ 只画六边形以内那部分，放大也不溢出卡边）。
	#   为什么不会出现"边缘拉伸"：抠图四周本来就留了 2% 全透明边 ⇒ 越界采样（UV<0 / >1）钳到的是透明像素。
	#   六边形的种族底色仍从人物四周透出来；描边照旧压在最上层（下面是 draw_polyline）。
	if _art != null:
		var ts := _art.get_size()
		if ts.x > 0.0 and ts.y > 0.0:
			var fit := minf((radius * 2.0) / ts.x, (sqrt(3.0) * radius) / ts.y)
			# 【2026-09-28·用户要求】个别英雄的取景微调（放大 / 平移）—— 表在 `DataRegistry.HERO_ART_FIT`，
			#   与棋盘棋子共用；没登记的英雄 = 1.0 / 0 / 0（原样）。`dx`/`dy` 以卡半径为单位（+x 右 / +y 下）。
			var adj: Dictionary = DataRegistry.hero_art_fit(def.display_name)
			fit *= float(adj.get("zoom", 1.0))
			var dsz := ts * fit
			var dpos := c - dsz * 0.5 + Vector2(float(adj.get("dx", 0.0)), float(adj.get("dy", 0.0))) * radius
			var uvs := PackedVector2Array()
			for p in pts:
				uvs.append(Vector2((p.x - dpos.x) / dsz.x, (p.y - dpos.y) / dsz.y))
			var cols := PackedColorArray()
			var mc := Color(1, 1, 1, 0.45) if disabled_draw else Color(1, 1, 1, 1)
			for _i in pts.size():
				cols.append(mc)
			draw_polygon(pts, cols, uvs, _art)
	# 选中高亮：绿色描边（比最初 3px 略粗更醒目，但比黑色粗框细）
	var border := Color(0.30, 1.0, 0.45) if selected else (_race_color().darkened(0.2) if disabled_draw else _race_color())
	draw_polyline(_closed(pts), border, clampf(radius * 0.07, 4.0, 8.0) if selected else 2.0, true)

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

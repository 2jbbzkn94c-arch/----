extends Node
## 截图探针：把 Menu.tscn 的两个页面真实渲染并存成 PNG，
## 用于检查封面背景与 UI 的实际叠合效果（主菜单 + 普通模式选人页）。
## 注意：必须用真实窗口跑（headless 是 dummy 渲染器，截不到画面）。
## 运行：godot --path . res://tests/CoverShotProbe.tscn
const OUT_MAIN := "res://log/cover_shot.png"
const OUT_TEAM := "res://log/cover_team_shot.png"

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	var m := (load("res://scenes/Menu.tscn") as PackedScene).instantiate()
	add_child(m)
	await _shot(OUT_MAIN)
	m.call("_show_team_view")   # 切到普通模式（卡池选人页）
	await _shot(OUT_TEAM)
	get_tree().quit()

func _shot(path: String) -> void:
	for i in 15:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw   # 等本帧画完再取画面
	var img := get_viewport().get_texture().get_image()
	var err := img.save_png(path)
	print(">> 截图 %s  %d x %d  (save err=%d)" % [path, img.get_width(), img.get_height(), err])

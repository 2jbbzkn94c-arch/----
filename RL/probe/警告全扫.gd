extends Node
## 【2026-10-03 一次性探针】把工程里**所有 .gd** 都 `load()` 一遍（**只编译、不实例化**）⇒
##   让 Godot 把编译期警告（`UNUSED_PARAMETER` / `SHADOWED_*` / `INTEGER_DIVISION` / `UNUSED_VARIABLE` …）
##   一次性打到 stderr —— 用户就是**启动游戏时**看到这些 `W 0:00:0x` 行的。
##   ⚠️ 为什么不用 `--check-only --script`：实测那样跑 80 个脚本**一条警告都不报**（警告只在"真的把它
##   加载进项目上下文"时才出）⇒ 必须走 `load()`。
##   输出：每行 `WARNSCAN|...`，末尾 `WARNSCAN|END`；**警告本体在 stderr**（`W 0:...` 那些行）。
func _ready() -> void:
	var roots := ["res://src", "res://autoload", "res://heroes"]
	var all: Array = []
	for r in roots:
		all.append_array(_walk(r))
	var ok := 0
	var bad: Array = []
	for p in all:
		var res = load(p)          # 只编译脚本资源，不 new、不进场景树
		if res == null:
			bad.append(p)
		else:
			ok += 1
	print("WARNSCAN|已加载 %d 个脚本（失败 %d 个）" % [ok, bad.size()])
	for b in bad:
		print("WARNSCAN|加载失败 %s" % b)
	print("WARNSCAN|END")
	get_tree().quit(0)

func _walk(dir: String) -> Array:
	var out: Array = []
	var d := DirAccess.open(dir)
	if d == null:
		return out
	d.list_dir_begin()
	var n := d.get_next()
	while n != "":
		var p := dir.path_join(n)
		if d.current_is_dir():
			if not n.begins_with("."):
				out.append_array(_walk(p))
		elif n.ends_with(".gd"):
			out.append(p)
		n = d.get_next()
	d.list_dir_end()
	return out

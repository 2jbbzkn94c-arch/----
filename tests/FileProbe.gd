extends Node
func _ready() -> void:
	var f := FileAccess.open("D:/Game creating/战旗/tests/probe_result.txt", FileAccess.WRITE)
	if f:
		f.store_string("PROBE_RUNNING\n")
		f.close()
	get_tree().quit()

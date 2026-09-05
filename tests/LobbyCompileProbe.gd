extends Node
var _result_path := "D:/Game creating/战旗/tests/probe_result.txt"
func _write(s: String) -> void:
	var f := FileAccess.open(_result_path, FileAccess.READ_WRITE)
	if f:
		f.seek_end()
		f.store_string(s)
		f.close()
	else:
		f = FileAccess.open(_result_path, FileAccess.WRITE)
		if f:
			f.store_string(s)
			f.close()
func _ready() -> void:
	_run.call_deferred()
func _run() -> void:
	var lobby = load("res://scenes/NetLobby.tscn").instantiate()
	add_child(lobby)
	await get_tree().process_frame
	_write("lobby ok\n")
	lobby.queue_free()
	get_tree().quit()

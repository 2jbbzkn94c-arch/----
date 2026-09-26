extends Node
## 音效管理器（全局自动加载）：播放程序化生成的 WAV 音效 + 音效音量调节与持久化。
## preload 静态引用音效：导出时 Godot 会自动把导入后的音频资源打进 pck，
## 避免运行时按路径动态加载在导出包里找不到文件。
## 音量范围 0..1（线性），持久化到 user://audio.cfg，重启不丢。

var _streams: Dictionary = {}   # key -> AudioStreamWAV
var _players: Array[AudioStreamPlayer] = []
var _enabled := true
var _volume := 1.0

const SAVE_PATH := "user://audio.cfg"

const SFX_STREAMS := {
	"attack": preload("res://assets/audio/attack.wav"),
	"hit": preload("res://assets/audio/hit.wav"),
	"turn": preload("res://assets/audio/turn.wav"),
	"select": preload("res://assets/audio/select.wav"),
	"win": preload("res://assets/audio/win.wav"),
	"click": preload("res://assets/音效/按钮点击.ogg"),
	# 【2026-09-26 用户要求】原有 5 个音效已整体换成重新生成的版本，并补上事件缺口（破盾/重击/毒/替补/失败）
	"crit": preload("res://assets/audio/crit.wav"),
	"shield_break": preload("res://assets/audio/shield_break.wav"),
	"poison": preload("res://assets/audio/poison.wav"),
	"sub_enter": preload("res://assets/audio/sub_enter.wav"),
	"lose": preload("res://assets/audio/lose.wav"),
}

func _ready() -> void:
	_load_settings()
	_streams = SFX_STREAMS
	# 【2026-09-26 用户要求】按钮点击音效：
	#   用 node_added 统一接管 —— 静态按钮与运行时新建的面板按钮都能覆盖，不用去每个 Button.new() 那里接。
	get_tree().node_added.connect(_on_node_added)
	# 预备几个播放器
	for i in 4:
		var pl := AudioStreamPlayer.new()
		pl.volume_db = _to_db(_volume)
		add_child(pl)
		_players.append(pl)

# 当前音量（0..1 线性）
func get_volume() -> float:
	return _volume

# 设置音量（0..1 线性）：立即作用于所有播放器并持久化
func set_volume(v: float) -> void:
	_volume = clampf(v, 0.0, 1.0)
	for pl in _players:
		if is_instance_valid(pl):
			pl.volume_db = _to_db(_volume)
	_save_settings()

# 线性音量 -> dB（0 处理成 -80 静音，避免 linear_to_db(0)=-inf）
func _to_db(v: float) -> float:
	if v <= 0.0001:
		return -80.0
	return linear_to_db(v)

func _load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) != OK:
		return
	_volume = clampf(float(cfg.get_value("audio", "volume", 1.0)), 0.0, 1.0)

func _save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("audio", "volume", _volume)
	var err := cfg.save(SAVE_PATH)
	if err != OK:
		print("音量存档跳过（无法写入 user://）: ", err)

func play(sfx: String) -> void:
	if not _enabled:
		return
	if not _streams.has(sfx):
		return
	# 找一个空闲播放器
	for pl in _players:
		if not pl.playing:
			pl.stream = _streams[sfx]
			pl.play()
			return
	# 全部占用则用第一个
	_players[0].stream = _streams[sfx]
	_players[0].play()

func set_enabled(on: bool) -> void:
	_enabled = on
# ---- 【2026-09-26 用户要求】按钮点击音效（全局）----
# 用 node_added 接管：静态按钮与运行时新建的面板按钮都覆盖，不用去每个 Button.new() 处接线。
func _on_node_added(n: Node) -> void:
	var b := n as BaseButton
	if b != null and not b.pressed.is_connected(_play_click):
		b.pressed.connect(_play_click)

func _play_click() -> void:
	play("click")
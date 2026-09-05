extends Node
## 简易音效管理器（全局自动加载）。播放程序化生成的 WAV 音效。
## 用 preload 静态引用音效：导出时 Godot 会自动把导入后的音频资源打进 pck，
## 避免运行时按路径动态加载在导出包里找不到文件。

var _streams: Dictionary = {}   # key -> AudioStreamWAV
var _players: Array[AudioStreamPlayer] = []
var _enabled := true

const SFX_STREAMS := {
	"attack": preload("res://assets/audio/attack.wav"),
	"hit": preload("res://assets/audio/hit.wav"),
	"turn": preload("res://assets/audio/turn.wav"),
	"select": preload("res://assets/audio/select.wav"),
	"win": preload("res://assets/audio/win.wav"),
}

func _ready() -> void:
	_streams = SFX_STREAMS
	# 预备几个播放器
	for i in 4:
		var pl := AudioStreamPlayer.new()
		add_child(pl)
		_players.append(pl)

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

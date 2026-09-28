extends Node
## 音效管理器（全局自动加载）：播放程序化生成的 WAV 音效 + 音效音量调节与持久化。
## preload 静态引用音效：导出时 Godot 会自动把导入后的音频资源打进 pck，
## 避免运行时按路径动态加载在导出包里找不到文件。
## 音量范围 0..1（线性），持久化到 user://audio.cfg，重启不丢。

var _streams: Dictionary = {}   # key -> AudioStreamWAV
var _players: Array[AudioStreamPlayer] = []
# 【2026-09-28·用户口径「移动应该是在移动中都连续播放」】行走音专用播放器：
#   循环播、且**不进 `_players` 池**（否则会被别的音效抢走/打断）
var _walk_player: AudioStreamPlayer = null
var _walk_timer: Timer = null   # 行走音的节奏定时器（`WALK_STEP_SEC` 一响一停）
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

# ---- 【2026-09-28·用户要求「把伐木工的配音加上，我听听看」】英雄语音（原版游戏音效）----
# 【2026-09-28·用户改名】文件名已改成中文：`登场1.ogg` / `登场2.ogg` / `阵亡.ogg`
#   （原版叫 `VO_<代号>_<事件>_<编号>.ogg`，代号 ↔ 中文名的对照表见匹配表）。
#   · 键 = 英雄显示名（`HeroDef.display_name`），事件 = line(登场) / move(移动) / attack(攻击) / death(阵亡)；
#   · **没登记的英雄 = 静默跳过** ⇒ 加新英雄只要在这里加一段 + 丢 ogg 进 `assets/audio/heroes/`；
#   · 用 `preload`（与 `SFX_STREAMS` 同理：只有静态引用才会被打进导出包）。
const HERO_VOICE := {
	"伐木工": {
		"line": [
			preload("res://assets/audio/heroes/伐木工/登场1.ogg"),
			preload("res://assets/audio/heroes/伐木工/登场2.ogg"),
		],
		"death": [
			preload("res://assets/audio/heroes/伐木工/阵亡.ogg"),
		],
	},
}

# ---- 【2026-09-28·用户指出「Woodcutter_Walk 这不是移动吗」】英雄**音效**（非语音）----
#   原版是两套文件：语音 `VO_<代号>_<事件>_<编号>`、音效 `<键>_<事件>`。这里放音效，键同样是英雄显示名；
#   文件名同样已中文化：`移动.ogg`（原版 Walk）/ `普通攻击.ogg`（原版 MeleeAttack）。
#   移动时：先按 `HERO_VOICE` 喊（没有就静默），再放这里的行走音效。
const HERO_SFX := {
	"伐木工": {
		"walk": [
			preload("res://assets/audio/heroes/伐木工/移动.ogg"),
		],
		# 【2026-09-28·用户口径「Woodcutter_MeleeAttack 伐木工攻击全部改为这个」】
		#   他的**所有攻击**（打单位 / 砍障碍）都用这条原版攻击音，替掉通用 `attack.wav`
		"attack": [
			preload("res://assets/audio/heroes/伐木工/普通攻击.ogg"),
		],
	},
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
	# 行走音专用播放器 + 节奏定时器（用户报「太密」⇒ 音频不循环，按 `WALK_STEP_SEC` 一响一停）
	_walk_player = AudioStreamPlayer.new()
	_walk_player.volume_db = _to_db(_volume)
	add_child(_walk_player)
	_walk_timer = Timer.new()
	_walk_timer.one_shot = false
	_walk_timer.timeout.connect(_on_walk_tick)
	add_child(_walk_timer)

# 当前音量（0..1 线性）
func get_volume() -> float:
	return _volume

# 设置音量（0..1 线性）：立即作用于所有播放器并持久化
func set_volume(v: float) -> void:
	_volume = clampf(v, 0.0, 1.0)
	for pl in _players:
		if is_instance_valid(pl):
			pl.volume_db = _to_db(_volume)
	if _walk_player != null and is_instance_valid(_walk_player):
		_walk_player.volume_db = _to_db(_volume)
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
	_play_stream(_streams[sfx])

# 【2026-09-28】英雄语音：同一种事件有多条时随机挑一条；没登记/没文件 = 什么都不做。
#   返回值 = 这条语音的时长（秒；没播就是 0）—— 部署登场要"等它播完"才放行
#   （见 `Battle._deploy_wait_entrance()`：用户口径「登场音效结束后才能行动或者登场下一个」）。
func play_hero_voice(display_name: String, kind: String) -> float:
	if not _enabled:
		return 0.0
	var by_kind: Dictionary = HERO_VOICE.get(display_name, {})
	var arr: Array = by_kind.get(kind, [])
	if arr.is_empty():
		return 0.0
	var s: AudioStream = arr[randi() % arr.size()]
	_play_stream(s)
	if s == null:
		return 0.0
	return s.get_length()

# 【2026-09-28·用户口径「移动应该是在移动中都连续播放」】整段移动期间都有行走音，
#   到 `Battle._finish_move()` 喊 `stop_hero_walk()` 才停。
#   【2026-09-28·用户报「移动的音效有点太密了」】**不再无缝循环**那个 0.18 秒的音频，
#   改成**按固定间隔重播**（一响一停 = 脚步节奏）⇒ 密度由 `WALK_STEP_SEC` 决定：
#   觉得密就往上调（0.4 → 0.5 / 0.6），觉得空就往下调；`Battle` 那边不用动。
const WALK_MAX_SEC := 6.0      ## 兜底：起播后最多响这么久（万一哪条路径漏了喊停）
const WALK_STEP_SEC := 0.4     ## 脚步间隔（秒）—— 调它就是调节奏密度
var _walk_token := 0
var _walk_active := false

func play_hero_walk(display_name: String) -> void:
	if not _enabled or _walk_player == null:
		return
	var by_kind: Dictionary = HERO_SFX.get(display_name, {})
	var arr: Array = by_kind.get("walk", [])
	if arr.is_empty():
		return
	_walk_player.stream = arr[randi() % arr.size()]
	_walk_player.play()
	_walk_active = true
	if _walk_timer != null:
		_walk_timer.start(WALK_STEP_SEC)   # 之后每 `WALK_STEP_SEC` 秒补一声脚步
	_walk_token += 1
	var tok := _walk_token
	get_tree().create_timer(WALK_MAX_SEC).timeout.connect(func() -> void:
		if tok == _walk_token:
			stop_hero_walk())

# 脚步节奏到点：再响一声（音频本身不循环 ⇒ 一响一停）
func _on_walk_tick() -> void:
	if not _walk_active or _walk_player == null:
		return
	_walk_player.play()

# 停行走音（没在移动时是空操作）
func stop_hero_walk() -> void:
	_walk_active = false
	if _walk_timer != null:
		_walk_timer.stop()
	if _walk_player != null and _walk_player.playing:
		_walk_player.stop()

# 【2026-09-28】英雄音效（非语音，原版 `<键>_<事件>` 那一类）：同样随机挑一条。
#   返回值 = 这次有没有真的播（调用方用它决定"要不要退回通用音"，见 `Battle._do_attack`）
func play_hero_sfx(display_name: String, kind: String) -> bool:
	if not _enabled:
		return false
	var by_kind: Dictionary = HERO_SFX.get(display_name, {})
	var arr: Array = by_kind.get(kind, [])
	if arr.is_empty():
		return false
	_play_stream(arr[randi() % arr.size()])
	return true

# 挑一个空闲播放器播这条流（全占用则用第一个）
func _play_stream(s: AudioStream) -> void:
	if s == null:
		return
	for pl in _players:
		if not pl.playing:
			pl.stream = s
			pl.play()
			return
	_players[0].stream = s
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

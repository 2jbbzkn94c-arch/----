extends Node
## 对战统计（全局自动加载）：按模式记录胜/败场，持久化到 user://，关闭游戏不丢。
## 只统计"一方累计 3 名英雄阵亡"判定出的正式对局；中途退出/断线/自由部署（测试）不计入。
## 同时保存「名片」姓名（联机大厅左上角名片框可改；联机对局顶部状态栏显示）。

const SAVE_PATH := "user://stats.cfg"
const MODES := ["sp_normal", "sp_arena", "mp_normal", "mp_arena", "sp_ladder", "sp_ladder_arena"]
const LADDER_MODES := ["sp_ladder", "sp_ladder_arena"]   # 这两项额外统计"最高连胜 / 当前连胜"
const NAME_SEC := "profile"     # 名片姓名存档段
const NAME_MAX := 6             # 姓名最长 6 字（对局顶部状态栏一行放得下）
const DEFAULT_NAME := "玩家"    # 未填姓名时显示的名字
const MODE_NAMES := {
	"sp_normal": "单机普通模式",
	"sp_arena": "单机竞技场模式",
	"mp_normal": "联机普通模式",
	"mp_arena": "联机竞技场模式",
	"sp_ladder": "天梯普通模式",
	"sp_ladder_arena": "天梯竞技场模式",
}

var wins: Dictionary = {}     # mode -> int
var losses: Dictionary = {}   # mode -> int
var best_streaks: Dictionary = {}   # 【天梯】mode -> 历史最高连胜
var cur_streaks: Dictionary = {}    # 【天梯】mode -> 当前连胜（没有进行中的天梯时为 0）
var player_name := ""         # 名片姓名（本地保存；空串=用默认名"玩家"）

func _ready() -> void:
	_ensure()
	_load()

func _ensure() -> void:
	for m in MODES:
		if not wins.has(m):
			wins[m] = 0
		if not losses.has(m):
			losses[m] = 0
		if not best_streaks.has(m):
			best_streaks[m] = 0
		if not cur_streaks.has(m):
			cur_streaks[m] = 0

# 当前对局属于哪个统计模式（联机/单机 × 普通/竞技场；天梯另算两项）
func current_mode_key() -> String:
	if GameState.ladder_mode != "":
		return "sp_ladder_arena" if GameState.ladder_mode == "arena" else "sp_ladder"
	var net := "mp" if GameState.is_online else "sp"
	var arena := "arena" if GameState.arena_mode else "normal"
	return "%s_%s" % [net, arena]

# 【天梯】当前模式的统计键（没有进行中的天梯时按 arena_mode 取天梯变体，仅用于展示）
func ladder_key(arena: bool = false) -> String:
	return "sp_ladder_arena" if arena else "sp_ladder"

func best_streak(key: String) -> int:
	return int(best_streaks.get(key, 0))

func current_streak(key: String) -> int:
	return int(cur_streaks.get(key, 0))

# 【天梯】赢一局：当前连胜 +1，并刷新最高连胜
func note_streak_win(key: String) -> void:
	_ensure()
	if not best_streaks.has(key):
		return
	cur_streaks[key] = current_streak(key) + 1
	if current_streak(key) > best_streak(key):
		best_streaks[key] = current_streak(key)
	_save()

# 【天梯】本轮结束（失败/放弃）：当前连胜清零（最高连胜保留）
func reset_streak(key: String) -> void:
	_ensure()
	if not cur_streaks.has(key):
		return
	cur_streaks[key] = 0
	_save()

func mode_name(key: String) -> String:
	return String(MODE_NAMES.get(key, key))

# 记录一局结果（win=true 胜场 / false 败场）。自由部署测试等非统计模式自动忽略。
func record(win: bool) -> void:
	if GameState.no_death_limit:
		return   # 自由部署（测试）沙箱：不计入统计
	_ensure()
	var key := current_mode_key()
	if not wins.has(key):
		return   # 非四种统计模式：忽略
	if win:
		wins[key] = int(wins[key]) + 1
	else:
		losses[key] = int(losses[key]) + 1
	_save()

func win_count(key: String) -> int:
	return int(wins.get(key, 0))

func loss_count(key: String) -> int:
	return int(losses.get(key, 0))

func games(key: String) -> int:
	return win_count(key) + loss_count(key)

# 胜率（0.0 ~ 1.0）；无对局时返回 0
func win_rate(key: String) -> float:
	var n := games(key)
	if n <= 0:
		return 0.0
	return float(win_count(key)) / float(n)

func win_rate_text(key: String) -> String:
	var n := games(key)
	if n <= 0:
		return "—"
	return "%.1f%%" % (win_rate(key) * 100.0)

# ---- 名片姓名（本地）----
# 显示用姓名：没填就返回"玩家"
func display_name() -> String:
	var s := player_name.strip_edges()
	return DEFAULT_NAME if s == "" else s

# 保存姓名（空白=恢复默认显示）；超长截断；存 user://，关游戏不丢
func set_player_name(n: String) -> void:
	var s := n.strip_edges()
	if s.length() > NAME_MAX:
		s = s.substr(0, NAME_MAX)
	player_name = s
	_save()

# 联机战绩一行文案（供名片框显示）：胜/败/胜率
func online_record_text(key: String) -> String:
	return "%d 胜 %d 负 · 胜率 %s" % [win_count(key), loss_count(key), win_rate_text(key)]

func reset_all() -> void:
	wins.clear()
	losses.clear()
	best_streaks.clear()
	cur_streaks.clear()
	_ensure()
	_save()

func _save() -> void:
	var cfg := ConfigFile.new()
	for m in MODES:
		cfg.set_value("stats", "win_" + m, win_count(m))
		cfg.set_value("stats", "loss_" + m, loss_count(m))
		cfg.set_value("stats", "best_" + m, best_streak(m))
		cfg.set_value("stats", "cur_" + m, current_streak(m))
	cfg.set_value(NAME_SEC, "name", player_name)
	var err := cfg.save(SAVE_PATH)
	if err != OK:
		print("统计存档跳过（无法写入 user://）: ", err)

func _load() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) != OK:
		return
	for m in MODES:
		wins[m] = int(cfg.get_value("stats", "win_" + m, 0))
		losses[m] = int(cfg.get_value("stats", "loss_" + m, 0))
		best_streaks[m] = int(cfg.get_value("stats", "best_" + m, 0))
		cur_streaks[m] = int(cfg.get_value("stats", "cur_" + m, 0))
	player_name = String(cfg.get_value(NAME_SEC, "name", ""))

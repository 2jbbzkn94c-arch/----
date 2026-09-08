extends Node
## 对局级状态管理（全局自动加载）。
## 负责：回合计数、当前行动方、胜负判定、超回合掉血加速结束。

signal match_started
signal round_changed(round_num: int)
signal active_side_changed(side: int)
signal match_ended(winner_side: int)  # -1 平局

const SIDES := 2
const SIDE_PLAYER := 0
const SIDE_ENEMY := 1

# 对局超过 10 回合后，第 11 回合起每方在自己的行动回合结束时，本方存活英雄扣血，
# 伤害随回合递增：第 11 回合扣 1、第 12 回合扣 2……扣血量 = round_number - ROUND_LIMIT。
const ROUND_LIMIT := 10   # 第 11 回合（round_number ≥ 11）起开始扣血

var round_number := 1
var active_side := SIDE_PLAYER
var match_running := false
var match_over := false
var surrender := false

# 双方阵登（由选卡界面写入）：英雄 id 数组（我方/敌方各 3 名）
var player_deck: Array = []
var enemy_deck: Array = []

# 自由放置（测试场景用）：cell(Vector2i) -> hero_id。若非空，Battle 部署时按此直接放置
var player_placement: Dictionary = {}
var enemy_placement: Dictionary = {}

# 自由部署沙箱（测试场景）：取消"3 名阵亡判负"，改为一方无人可上（场上为 0 且替补池空）才算负；
# 场上阵亡/撤下后可从全英雄池自由替补。
var no_death_limit := false

# AI 难度：0=简单 1=普通 2=困难
var ai_difficulty := 1

# 普通模式选人页：上次编辑的卡组槽（1/2/3），再次进入时自动载入
var last_deck_slot := 1

# 竞技场模式：进入对战后随机2选1构建双方卡组（各4名，共8英雄），无需预选队伍
var arena_mode := false

# 联机对战：true 时敌方是真人，敌方回合不跑 AI，改为等待对端真人指令（网络层驱动）
var is_online := false
# 联机：true = 本机是主机（权威执行方）；false = 客户端（发指令方）
var is_host := false
# 联机对局随机种子：主机在开局时随机生成并随 start 消息广播，两端 Battle 用同一种子（确定性）。
var online_seed := 12345

# 退出联机界面/对局：清空联机标志与上一局卡组，避免残留状态影响下次进入。
func reset_online() -> void:
	is_online = false
	is_host = false
	online_seed = 12345
	arena_mode = false
	player_deck = []
	enemy_deck = []
	player_placement.clear()
	enemy_placement.clear()
	match_running = false
	match_over = false
	no_death_limit = false

func clear_placement() -> void:
	player_placement.clear()
	enemy_placement.clear()

func start_match(first_side: int = SIDE_PLAYER) -> void:
	round_number = 1
	active_side = first_side
	match_running = true
	match_over = false
	surrender = false
	match_started.emit()
	round_changed.emit(round_number)
	active_side_changed.emit(active_side)

func set_decks(player: Array, enemy: Array) -> void:
	player_deck = player.duplicate()
	enemy_deck = enemy.duplicate()

# 推进到对方行动方。first_side = 本局先手方（谁先行动）。
# 回合数只在"先手之后的第二位行动方结束"时 +1：保证第 N 回合 = 双方各完整行动一轮。
# 例：先手=PLAYER → 玩家结束不+1、敌方结束+1；先手=ENEMY → 敌方(先手)结束不+1、玩家结束+1。
func end_current_side(first_side: int = SIDE_PLAYER) -> void:
	var ended := active_side
	if active_side == SIDE_PLAYER:
		active_side = SIDE_ENEMY
	else:
		active_side = SIDE_PLAYER
	# 默认沿用旧口径（先手=玩家时等价）；显式传入后手顺序时按上述规则推进
	if first_side == SIDE_PLAYER:
		if ended == SIDE_ENEMY:
			_advance_round()
	else:
		if ended == SIDE_PLAYER:
			_advance_round()
	active_side_changed.emit(active_side)

func _advance_round() -> void:
	round_number += 1
	round_changed.emit(round_number)

# 联机：客户端收到主机的回合权威广播时同步本端行动方与回合号，
# 并发出与单机推进一致的信号（HUD 回合标签/轮次显示依赖这些信号刷新）。
func sync_turn(side: int, round_num: int) -> void:
	active_side = side
	if round_num != round_number:
		round_number = round_num
		round_changed.emit(round_number)
	active_side_changed.emit(active_side)

# 每回合结束时对存活单位应用超回合伤害（由 Battle 调用）。
# 第 11 回合起进入扣血；第 R 回合结束扣 (R - ROUND_LIMIT) 点。
func should_apply_round_damage() -> bool:
	return round_number > ROUND_LIMIT

func round_damage_amount() -> int:
	return maxi(round_number - ROUND_LIMIT, 0)

func end_match(winner_side: int) -> void:
	if match_over:
		return
	match_over = true
	match_running = false
	match_ended.emit(winner_side)

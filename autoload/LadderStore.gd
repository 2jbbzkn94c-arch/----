extends Node
## 【2026-09-24 用户要求·天梯模式】天梯存档（全局自动加载）：一轮"天梯挑战"的进度 + 中局快照。
##
## 天梯是什么（用户口径）：
##   · 玩法与「普通模式 / 竞技场模式」完全一样，两个变体 = **天梯普通模式 / 天梯竞技场模式**
##   · 目的 = 打连胜；**对局失败 = 本次天梯结束**（当前连胜清零，最高连胜写进 `Stats`）
##   · **可以退**：退出（正常关游戏 / 崩溃 / 强杀）后再进来，载入**退出前那次回合开始**的局面，
##     而不是把对局重开
##   · 难度**锁死噩梦**（`GameState.ai_difficulty = 3`）
##
## 实现要点：
##   · 快照由 `Battle` 在**每次回合开始**（`_begin_side()` 开头）写一次 ⇒ 覆盖式自动存档，
##     所以"非正常退出"不需要额外处理：磁盘上永远是最近一次回合开始的状态
##   · 写盘 = 先写 `user://ladder.cfg.tmp` 再改名 ⇒ 写一半被杀死也不会把存档写坏
##   · **两个变体各存各的**（用户 2026-09-24 要求「天梯普通场和竞技场状态分开」）：
##     `normal` 与 `arena` 各有自己的"轮次 + 局数 + 卡组 + 快照" ⇒ 互相不会顶掉、切换不用先放弃
##   · 连胜数**不在这里**（唯一真源在 `Stats`：`best_streak` / `current_streak`，同样按变体分开）
##
## 对外 API（`m` 省略 = 当前这局的天梯变体 `GameState.ladder_mode`）：
##   `has_run(m) / match_no(m) / player_deck(m) / info(m) / mode_name(m)`
##   `begin(m) / begin_next_match(m) / note_player_deck(ids, m) / finish_run(m)`
##   `save_snapshot(s, m) / has_snapshot(m) / snapshot(m) / clear_snapshot(m)`
##   `save_draft(d, m) / has_draft(m) / draft(m) / clear_draft(m)`（**竞技场 2 选 1 选人阶段**的中途存档：
##     退出去再进来看到**同一批候选**、同一位先手，不靠重洗池子碰运气）

const SAVE_PATH := "user://ladder.cfg"
const TMP_PATH := "user://ladder.cfg.tmp"
const MODE_NORMAL := "normal"      # 天梯普通模式（= 普通模式机制）
const MODE_ARENA := "arena"        # 天梯竞技场模式（= 竞技场模式机制）
const MODES := ["normal", "arena"]
const LOCKED_DIFFICULTY := 4       # 【2026-10-03·用户口径「天梯模式难度改成噩梦+」】3（噩梦）→ **4（噩梦+）**。
#   ⚠️ 4 读 `RL/weights/噩梦1.json`（实验档）；若那个文件不在，`Battle._nightmare_weights_path()` 会自动降级回
#   `噩梦.json` ⇒ 天梯**不会崩**，只是当场退化成噩梦档（判据里带 `FileAccess.file_exists`）。

var _runs: Dictionary = {}    # mode -> {"mode":…, "difficulty":3, "match_no":局数, "player_deck":[…],
                              #          "in_match":本局是否已开打（部署一开就 true）, "enemy_deck":[…]}
var _snaps: Dictionary = {}   # mode -> 中局快照（Battle._ladder_snapshot() 的产物）；缺 = 当前不在对局中
var _drafts: Dictionary = {}  # mode -> 竞技场选人阶段的中途存档（Battle._arena_draft_snapshot() 的产物）；缺 = 选人不在途

func _ready() -> void:
	_load()

# 省略 m 时取"当前这局的天梯变体"
func _m(m: String = "") -> String:
	return m if m != "" else String(GameState.ladder_mode)

# ---- 查询 ----
func has_run(m: String = "") -> bool:
	return not _run_of(m).is_empty()

func match_no(m: String = "") -> int:
	return int(_run_of(m).get("match_no", 1))

func player_deck(m: String = "") -> Array:
	var d = _run_of(m).get("player_deck", [])
	return (d as Array).duplicate() if d is Array else []

func enemy_deck(m: String = "") -> Array:
	var d = _run_of(m).get("enemy_deck", [])
	return (d as Array).duplicate() if d is Array else []

# 本局是否已开打（= 已经进过部署）但**还没有回合快照** ⇒ 部署/选人阶段退出的情形：
#   下次进来直接用 `player_deck()/enemy_deck()` 回到部署，不再让玩家重选卡组。
func has_pending_match(m: String = "") -> bool:
	var r := _run_of(m)
	if r.is_empty() or not bool(r.get("in_match", false)):
		return false
	return (r.get("player_deck", []) as Array).size() > 0 and (r.get("enemy_deck", []) as Array).size() > 0

func info(m: String = "") -> Dictionary:
	return _run_of(m).duplicate(true)

func has_snapshot(m: String = "") -> bool:
	return not _snap_of(m).is_empty()

func snapshot(m: String = "") -> Dictionary:
	return _snap_of(m)

# 模式中文名（给菜单/结算面板用）
func mode_name(m: String = "") -> String:
	return "天梯竞技场模式" if _m(m) == MODE_ARENA else "天梯普通模式"

func mode_short(m: String = "") -> String:
	return "天梯竞技场" if _m(m) == MODE_ARENA else "天梯普通"

func _run_of(m: String) -> Dictionary:
	var k := _m(m)
	var v = _runs.get(k, {})
	return v if v is Dictionary else {}

func _snap_of(m: String) -> Dictionary:
	var k := _m(m)
	var v = _snaps.get(k, {})
	return v if v is Dictionary else {}
func _draft_of(m: String) -> Dictionary:
	var k := _m(m)
	var v = _drafts.get(k, {})
	return v if v is Dictionary else {}

# ---- 竞技场选人中途存档（2026-09-25 修「天梯竞技场选人阶段退出去，能选的人就变了」）----
# 【病灶】候选池是 `Battle._rng_shuffle(_arena_pool)` 洗出来的，而天梯存档点是"每次回合开始"
#   （`Battle._begin_side()`）—— 2 选 1 选人**还没到回合** ⇒ 选人阶段一个存档都没有，重进就重新
#   洗牌：候选全变（而且能靠反复退出来"重摇"选人）。⇒ 这里给选人阶段单开一格存档，`Battle` 在
#   每轮开始写、选完即撤（撤掉之后由 `has_pending_match` / `has_snapshot` 两条老路接手）。
func save_draft(d: Dictionary, m: String = "") -> void:
	var k := _m(m)
	if k == "" or not _runs.has(k):
		return
	_drafts[k] = d
	_save()

func has_draft(m: String = "") -> bool:
	return not _draft_of(m).is_empty()

func draft(m: String = "") -> Dictionary:
	return _draft_of(m).duplicate(true)

func clear_draft(m: String = "") -> void:
	var k := _m(m)
	if k == "":
		return
	_drafts.erase(k)
	_save()


# ---- 生命周期 ----
# 开始新一轮天梯（连胜由调用方清零：`Stats.reset_streak(key)`）。⚠️ 只动这个变体的槽，另一个不受影响。
func begin(m: String, player_deck_ids: Array = []) -> void:
	var k := _m(m)
	if k == "":
		return
	_runs[k] = { "mode": k, "difficulty": LOCKED_DIFFICULTY, "match_no": 1, "player_deck": player_deck_ids.duplicate(),
		"in_match": false, "enemy_deck": [] }
	_snaps.erase(k)
	_drafts.erase(k)
	_save()

# 本局胜利、点「继续挑战」/ 直接重进：轮次 +1，快照清空（下一局从选人/部署重新开始）
func begin_next_match(m: String = "") -> void:
	var k := _m(m)
	if not _runs.has(k):
		return
	(_runs[k] as Dictionary)["match_no"] = int((_runs[k] as Dictionary).get("match_no", 1)) + 1
	(_runs[k] as Dictionary)["in_match"] = false
	(_runs[k] as Dictionary)["enemy_deck"] = []
	_snaps.erase(k)
	_drafts.erase(k)
	_save()

# 【天梯】本局开打（进部署时由 Battle 调用）：记住双方卡组 ⇒ 部署阶段退出也能原样回来
func note_match_started(player_ids: Array, enemy_ids: Array, m: String = "") -> void:
	var k := _m(m)
	if not _runs.has(k):
		return
	(_runs[k] as Dictionary)["player_deck"] = player_ids.duplicate()
	(_runs[k] as Dictionary)["enemy_deck"] = enemy_ids.duplicate()
	(_runs[k] as Dictionary)["in_match"] = true
	_save()

# 记住本轮用的我方卡组（开局选完卡组时由 Battle 调用 ⇒ 中途退出后能原样续上）
func note_player_deck(ids: Array, m: String = "") -> void:
	var k := _m(m)
	if not _runs.has(k):
		return
	(_runs[k] as Dictionary)["player_deck"] = ids.duplicate()
	_save()

# 这个变体的本轮结束（对局失败 / 主动放弃）：只删这个变体的档
func finish_run(m: String = "") -> void:
	var k := _m(m)
	if k == "":
		return
	_runs.erase(k)
	_snaps.erase(k)
	_drafts.erase(k)
	_save()

func abandon(m: String = "") -> void:
	finish_run(m)

# ---- 快照 ----
func save_snapshot(s: Dictionary, m: String = "") -> void:
	var k := _m(m)
	if k == "" or not _runs.has(k):
		return
	_snaps[k] = s
	_save()

func clear_snapshot(m: String = "") -> void:
	var k := _m(m)
	if k == "":
		return
	_snaps.erase(k)
	_drafts.erase(k)
	_save()

# ---- 持久化（原子写：先 .tmp 再改名）----
func _save() -> void:
	if _runs.is_empty() and _snaps.is_empty() and _drafts.is_empty():
		_delete()
		return
	var cfg := ConfigFile.new()
	for k in MODES:
		if _runs.has(k):
			cfg.set_value("runs", k, _runs[k])
		if _snaps.has(k):
			cfg.set_value("snaps", k, _snaps[k])
		if _drafts.has(k):
			cfg.set_value("drafts", k, _drafts[k])
	var err := cfg.save(TMP_PATH)
	if err != OK:
		print("天梯存档跳过（无法写入 user://）: ", err)
		return
	var d := DirAccess.open("user://")
	if d == null:
		return
	if d.file_exists("ladder.cfg"):
		d.remove("ladder.cfg")
	var rerr := d.rename("ladder.cfg.tmp", "ladder.cfg")
	if rerr != OK:
		print("天梯存档改名失败: ", rerr)

func _delete() -> void:
	var d := DirAccess.open("user://")
	if d == null:
		return
	if d.file_exists("ladder.cfg"):
		d.remove("ladder.cfg")
	if d.file_exists("ladder.cfg.tmp"):
		d.remove("ladder.cfg.tmp")

func _load() -> void:
	_runs.clear()
	_snaps.clear()
	_drafts.clear()
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) != OK:
		return
	for k in MODES:
		var r = cfg.get_value("runs", k, {})
		if r is Dictionary and not (r as Dictionary).is_empty():
			_runs[k] = r
		var s = cfg.get_value("snaps", k, {})
		if s is Dictionary and not (s as Dictionary).is_empty():
			_snaps[k] = s
		var dr = cfg.get_value("drafts", k, {})
		if dr is Dictionary and not (dr as Dictionary).is_empty():
			_drafts[k] = dr

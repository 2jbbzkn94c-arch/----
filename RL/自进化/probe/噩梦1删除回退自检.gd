extends Node
## 【2026-10-02 一次性探针·只读】「删掉 `RL/weights/噩梦1.json` ⇒ 难度4 **完全回退**成难度3」的
## **运行期**验证 —— 走的是**生产链路**（`Battle._make_battle_ai()` 读 `GameState.ai_difficulty`），
## 不是读代码、也不是跑仿真。
##
## 每个档位打印四项：`_nightmare_weights_path()` · `_nightmare_weights_tag()` · **实际挂的是哪个 AI 脚本**
##   · 关键键的**实际生效值**（`w_form_escape_escapable` / `w_beam`）。
##
## 判据（本探针要跑**两遍**，中间把 `RL/weights/噩梦1.json` 改名/删掉）：
##   · 文件**在**   ⇒ 难度4：path = `噩梦1.json`、tag = "噩梦1"、esc 键 = **1**
##   · 文件**不在** ⇒ 难度4：path = `噩梦.json` 、tag = "噩梦" 、esc 键 = **0**
##     ⇒ 与难度3 的四项读数**逐字相同**（这就是"删掉即完全回退"）
##   · **两遍里难度 0/1/2/3 的读数必须一个字都不变**（= 删文件不影响它们）
##
## 用法：
##   & RL\train\跑Godot隔离.ps1 -Tag nm1del -TimeoutSec 300 -Args @('--headless','--path',(Get-Location).Path,'--scene','res://RL/probe/噩梦1删除回退自检.tscn')
## 输出：每行 `PROBE|…`，末尾 `PROBE|END`。
const BATTLE := preload("res://src/Battle.gd")

var _grid: HexGrid

func _ready() -> void:
	# 看门狗：脚本中途抛错时 `quit()` 到不了 ⇒ 场景空转（把这套探针变成"假仪器"）。
	get_tree().create_timer(120.0).timeout.connect(func() -> void:
		print("PROBE|WATCHDOG|120s 到点，强制退出")
		get_tree().quit(2))
	_run.call_deferred()

func _run() -> void:
	_grid = HexGrid.new(5, 7, 48.0)
	_grid.top_cap_cols = [1, 3]
	# ⚠️ **不进树**：只 new 出来塞个 `grid`（`_make_battle_ai()` 只用 `grid` + 全局档位 + 文件 IO）
	#   —— 进树会触发 `Battle._ready()` 真的开一局。
	var b: Node2D = BATTLE.new()
	b.grid = _grid

	var nm1_exists := FileAccess.file_exists("res://RL/weights/噩梦1.json")
	var ev_exists := FileAccess.file_exists("res://RL/自进化/权重.json")
	print("PROBE|前置|噩梦1.json 存在=%s｜难度5 权重（RL/自进化/权重.json）存在=%s｜HUD 档名表=%s｜AI_DIFFICULTY_MAX=%d" % [
		str(nm1_exists), str(ev_exists), str(HUD.AI_DIFF_NAMES), GameState.AI_DIFFICULTY_MAX])

	var keep: int = GameState.ai_difficulty
	for d in [0, 1, 2, 3, 4, 5]:
		var path := "-"
		var tag := "-"
		if d >= Battle.NIGHTMARE_DIFFICULTY:
			path = String(b.call("_nightmare_weights_path", d))
			tag = String(b.call("_nightmare_weights_tag", d))
		GameState.ai_difficulty = int(d)
		var ai = b.call("_make_battle_ai")
		if ai == null:
			print("PROBE|难度 %d|**构造失败**" % int(d))
			continue
		var sc := ""
		var s = ai.get_script()
		if s != null:
			sc = String((s as Script).resource_path)
		print("PROBE|难度 %d|档名=%s|权重文件=%s|AI脚本=%s|esc 键 w_form_escape_escapable=%s|BEAM=%s" % [
			int(d), tag, path, sc,
			str(ai.get("w_form_escape_escapable")), str(ai.get("w_beam"))])
		# ⚠️ **不能 `ai.free()`**：`BattleAI` 继承 RefCounted（不是 Node）⇒ 会抛
		#   `Attempted to free a RefCounted object` 并**中断本函数**（第一版就是这么被卡住的，
		#   后面的难度一个都没打出来、只剩看门狗超时）。置 null 交给引用计数回收即可。
		ai = null
	GameState.ai_difficulty = keep
	b.free()
	print("PROBE|END")
	get_tree().quit(0)

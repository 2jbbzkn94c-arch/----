extends Node
## 【2026-10-02·一次性探针·只读·用户「竞技场难度也开噩梦1」】
##   验竞技场那个「选择 AI 难度」弹层：① 列出的档位 = `HUD.AI_DIFF_NAMES`（含第 5 档「噩梦1」）
##   ② **按下「噩梦1」真的生效**：`GameState.ai_difficulty = 4` ＋ `arena_mode = true`。
##   ⚠️ 按下之后 `_start_arena()` 会 `change_scene_to_file()`（下一帧才换场景）⇒ 本探针**同步**读状态、
##      读完立刻 quit（不等帧、不 await），否则探针自己会被换掉。
##   输出：AD|… / AD|END

var menu: Node

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	GameState.ladder_mode = ""      # 天梯会把难度锁死噩梦，这里必须清掉
	GameState.ai_difficulty = 3
	menu = (load("res://scenes/Menu.tscn") as PackedScene).instantiate()
	add_child(menu)
	for i in 5:
		await get_tree().process_frame
	menu._ask_arena_difficulty()
	for i in 3:
		await get_tree().process_frame
	var texts: Array = []
	var btns: Array = []
	if menu._arena_dif_overlay != null:
		_collect(menu._arena_dif_overlay, texts, btns)
	var labels: Array = []
	for t in texts:
		if t != "返回" and t != "竞技场模式 · 选择 AI 难度":
			labels.append(t)
	var want: Array = HUD.AI_DIFF_NAMES
	print("AD|档位|弹层列出的档位=%s｜期望（HUD.AI_DIFF_NAMES）=%s ⇒ %s" % [
		str(labels), str(want), ("**PASS**" if labels == want else "**FAIL**")])
	var target: Button = null
	for b in btns:
		if (b as Button).text == "噩梦1":
			target = b
			break
	if target == null:
		print("AD|按下|弹层里没有「噩梦1」按钮 ⇒ **FAIL**")
	else:
		target.pressed.emit()   # 同步执行 `_start_arena(4)`：设状态 + 排一次换场景（下一帧才发生）
		var ok := GameState.ai_difficulty == 4 and GameState.arena_mode
		print("AD|按下|按「噩梦1」⇒ ai_difficulty=%d、arena_mode=%s、no_death_limit=%s ⇒ %s" % [
			GameState.ai_difficulty, str(GameState.arena_mode), str(GameState.no_death_limit),
			("**PASS**" if ok else "**FAIL**")])
	print("AD|END")
	get_tree().quit(0)

func _collect(node: Node, texts: Array, btns: Array) -> void:
	for c in node.get_children():
		if c is Button:
			texts.append(String((c as Button).text))
			btns.append(c)
		_collect(c, texts, btns)

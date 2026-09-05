extends Node
## 部署出生区高亮检查：打印部署时敌方(红)/我方(蓝)出生格及其用户坐标[列,行]。
## 运行：godot --headless --scene res://tests/DeployHighlightInspect.tscn
var battle: Battle

func _ready() -> void:
	battle = load("res://scenes/Main.tscn").instantiate() as Battle
	add_child(battle)
	_run.call_deferred()

func _run() -> void:
	GameState.clear_placement()
	GameState.arena_mode = false
	GameState.player_deck = ["hero_06", "hero_17", "hero_26"]
	GameState.enemy_deck = ["hero_13", "hero_13", "hero_13"]
	# 强制进入部署
	battle._begin_deployment()
	# 敌方出生格（红的方向标）
	var enemy_cells := battle._spawn_cells(DataRegistry.Faction.ENEMY)
	print("敌方出生区grid格:")
	for c in enemy_cells:
		var ucol: int = c.x + 1
		var urow: int = battle.grid.height - c.y
		print("  grid(", c.x, ",", c.y, ") -> 用户[", ucol, ",", urow, "]")
	var player_cells := battle._spawn_cells(DataRegistry.Faction.PLAYER)
	print("我方出生区grid格:")
	for c in player_cells:
		var ucol: int = c.x + 1
		var urow: int = battle.grid.height - c.y
		print("  grid(", c.x, ",", c.y, ") -> 用户[", ucol, ",", urow, "]")
	# 当前预览里敌方红格
	print("预览格总览:")
	for c in battle._preview_cells.keys():
		var col: Color = battle._preview_cells[c]
		var is_red := col.r > 0.7 and col.b < 0.5
		print("  grid(", c.x, ",", c.y, ") 红=", is_red)
	get_tree().quit()

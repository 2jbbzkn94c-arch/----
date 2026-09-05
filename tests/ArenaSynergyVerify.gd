extends Node
## 竞技场敌方选人/上人协同验证：
## 1) 敌方从2候选里选"与已选英雄协同更高"的留自己，弱/难配合的给玩家；
## 2) 敌方上人(首发)从卡池挑与已上场配合最好的。
## 运行：godot --headless --scene res://tests/ArenaSynergyVerify.tscn
var battle: Battle

func _ready() -> void:
	battle = load("res://scenes/Main.tscn").instantiate() as Battle
	add_child(battle)
	_run.call_deferred()

func _run() -> void:
	# T1: 敌方已选 hero_23(复仇者)。候选 a=hero_11(塔盾,与复仇者协同2.0)、b=hero_10(无协同)。
	# 敌方应选协同更高的 hero_11 留自己，hero_10 给玩家。
	battle._arena_enemy = ["hero_23"]
	battle._arena_pending = ["hero_11", "hero_10"]
	GameState.arena_mode = true
	battle.state = Battle.State.ARENA_DRAFT
	var before_enemy: int = battle._arena_enemy.size()
	battle._action_arena_enemy_pick()
	var enemy_got: String = battle._arena_enemy.back()
	var player_got: String = battle._arena_picked.back()
	print("T1 敌方选协同强卡: 敌拿=%s 玩家得=%s => %s" % [enemy_got, player_got, "PASS" if enemy_got == "hero_11" and player_got == "hero_10" else "FAIL"])

	# T2: 敌方上人优先协同。enemy_deployed=[]，pool 含 hero_37(锤头鲨)与 hero_10(协同2.0)。
	# 首发第一个应挑协同最高的组合（hero_37 与 hero_10 是已知协同对）。
	battle.enemy_pool = ["hero_37", "hero_10", "hero_42"]
	battle.enemy_deployed = []
	battle.state = Battle.State.DEPLOY
	battle._deploy_side = 1
	var deploy_side := battle._deploy_side
	# 手动模拟：只调一次 _enemy_deploy 看首发放谁
	battle._enemy_deploy()
	# （enemy_deployed 可能因 _deploy_after_pick 切换 side 而不继续，检查首个上榜者）
	var first: String = battle.enemy_deployed[0] if battle.enemy_deployed.size() > 0 else ""
	# 若是 hero_37 或 hero_10 之一（二者协同），且都排在有/无协同优先级前，视为考虑协同
	var synergies := DataRegistry.synergy_bonus("hero_37", "hero_10") > 0.0
	print("T2 敌方上人首选协同组合: 首放=%s(协同对 hero_37/hero_10=%s) => %s" % [first, str(synergies), "PASS" if first in ["hero_37", "hero_10"] else "FAIL"])

	get_tree().quit()

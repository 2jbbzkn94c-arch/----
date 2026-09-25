extends Node
## 【2026-09-25 一次性探针】"挨打合计"（`_incoming_total_on()`）里新加的 **①.7 对手回合开始将召唤的骷髅兵**。
##
## 起因（用户原话）：「阈值比较伤害里还是没有骷髅，是因为骷髅是后面召唤的吗」⇒ 是，见 `src/BattleAI.gd` ①.7 段注释。
## 本探针直接读**四/五个盘面**的 `out["parts"]`（挨打合计的逐笔来源），看骷髅那两笔在不在：
##   **A 能召唤到**：敌方死灵法师(hero_33) 离我方目标 2 格，周围有空格 ⇒ 应出现 2 笔「骷髅兵·召唤」1.0；
##   **B 够不到**：死灵法师在棋盘另一头 ⇒ 0 笔（对照：证明不是"只要场上有死灵法师就加分"）；
##   **C 被沉默**：同 A 但 `silenced=true` ⇒ 0 笔（真实侧 `_trigger_turn_start()` 那道门：沉默/眩晕不召）；
##   **D 真的站着骷髅**（把 `summon_skeleton` 当普通单位放进盘面）⇒ 那笔照旧算（证明不是"过滤器把骷髅滤掉了"）。
##
## 用法：
##   cmd /c "set "APPDATA=<根>\.godot_userdata" && godot.exe --headless --path <根> --scene res://RL/probe/未来召唤估值自检.tscn"
## 输出：每行 `PROBE|...`，末尾 `PROBE|END`。

const SRC := preload("res://src/BattleAI.gd")     # 改动的正本（顺带把它的语法解析过一遍）
const FORK := preload("res://RL/ai/AI_Battle.gd")  # 噩梦档真正加载的那份（同步后应给出同一读数）

var _grid: HexGrid

func _ready() -> void:
	_grid = HexGrid.new(5, 7, 48.0)
	_run.call_deferred()

func _run() -> void:
	print("PROBE|CFG|src=%s" % _sha("res://src/BattleAI.gd"))
	_case("A 能召唤到", Vector2i(2, 1), Vector2i(2, 3), false, Vector2i(-9, -9))
	_case("B 够不到", Vector2i(0, 0), Vector2i(4, 6), false, Vector2i(-9, -9))
	_case("C 被沉默", Vector2i(2, 1), Vector2i(2, 3), true, Vector2i(-9, -9))
	_case("D 已有骷髅", Vector2i(0, 0), Vector2i(2, 3), false, Vector2i(1, 3))
	# 噩梦档实际用的是 fork（`RL/ai/AI_Battle.gd`）⇒ 同一盘面再跑一遍，读数应与 src 完全一致
	print("PROBE|CFG|fork=%s" % _sha("res://RL/ai/AI_Battle.gd"))
	_case("A·fork", Vector2i(2, 1), Vector2i(2, 3), false, Vector2i(-9, -9), FORK)
	print("PROBE|END")
	get_tree().quit(0)

## necro = 敌方死灵法师位置 · target = 我方被估单位位置 · silenced = 死灵法师是否被沉默 ·
## existing_skel = 额外放一只**已经站着**的骷髅兵的位置（(-9,-9) = 不放）· script = 用哪份 AI（缺省 src）
func _case(tag: String, necro: Vector2i, target: Vector2i, silenced: bool, existing_skel: Vector2i, script = SRC) -> void:
	var descs: Array = []
	var d_necro := _desc(DataRegistry.Faction.ENEMY, "hero_33", necro, "死灵法师")
	d_necro["silenced"] = silenced
	descs.append(d_necro)
	var t := _desc(DataRegistry.Faction.PLAYER, "hero_18", target, "我方目标")
	descs.append(t)
	if existing_skel.x >= 0:
		descs.append(_desc_summon(existing_skel, "骷髅兵(已在场)"))
	var occ := {}
	for d in descs:
		occ[d["cell"]] = true
	var ai = script.new(_grid)
	ai.log_decisions = false
	var sim = ai.build_state(descs, occ, {}, {}, {}, {}, {})
	var out := {}
	var total: float = ai._incoming_total_on(sim, sim.units[1], target, out)
	var skel := 0.0
	var skel_n := 0
	for p in (out.get("parts", []) as Array):
		if String(p[0]).begins_with("骷髅兵"):
			skel += float(p[1])
			skel_n += 1
	print("PROBE|%s|距离=%d|笔数=%d|合计=%.1f|骷髅笔数=%d|骷髅合计=%.1f|明细=%s" % [
		tag, _grid.distance(necro, target), int(out.get("n", 0)), total, skel_n, skel, _parts_txt(out)])

func _parts_txt(out: Dictionary) -> String:
	var txt: Array = []
	for p in (out.get("parts", []) as Array):
		txt.append("%s %.1f" % [String(p[0]), float(p[1])])
	return "[%s]" % ", ".join(txt)

func _desc(fn: int, hid: String, cell: Vector2i, nm: String) -> Dictionary:
	var hd = DataRegistry.heroes[hid]
	var emove := 2
	if (hd.skills as Array).has(DataRegistry.Skill.SWIFT):
		emove = 3
	return {
		"fn": fn, "hero": hid, "cell": cell, "hp": int(hd.max_hp), "max_hp": int(hd.max_hp),
		"atk": int(hd.atk), "eatk": int(hd.atk), "move": emove, "emove": emove,
		"atk_range": maxi(int(hd.attack_range), 1), "atk_type": int(hd.attack_type),
		"skills": (hd.skills as Array).duplicate(), "name": nm,
	}

## 召唤物（骷髅兵）在 `DataRegistry.summons` 里，不在 `heroes` 里
func _desc_summon(cell: Vector2i, nm: String) -> Dictionary:
	var hd = DataRegistry.get_summon("summon_skeleton")
	return {
		"fn": DataRegistry.Faction.ENEMY, "hero": "summon_skeleton", "cell": cell,
		"hp": int(hd.max_hp), "max_hp": int(hd.max_hp), "atk": int(hd.atk), "eatk": int(hd.atk),
		"move": int(hd.move_range), "emove": int(hd.move_range),
		"atk_range": maxi(int(hd.attack_range), 1), "atk_type": int(hd.attack_type),
		"skills": (hd.skills as Array).duplicate(), "name": nm,
	}

func _sha(path: String) -> String:
	var c := FileAccess.get_file_as_bytes(path)
	var h := HashingContext.new()
	h.start(HashingContext.HASH_SHA256)
	h.update(c)
	return h.finish().hex_encode().substr(0, 12)

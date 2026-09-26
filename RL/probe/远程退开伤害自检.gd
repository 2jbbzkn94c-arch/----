extends Node
## 【2026-09-26 一次性探针·临时】"被贴身的远程会退开再打"——**挨打合计里那一下按几算** ——
##   用户实机日志原话：「红帽：下回合在这一格会挨 2 伤（沉默术士1＋影丸1）」，
##   用户指出「沉默术士和影丸虽然被贴身，但都可以往后退。之前不是修过吗」。
##
## 病灶：`_threat_hit_value()` 里那条"退开再打"的判据原来只有 `d <= 1`（= 打的就是贴着我那个目标）
##   ⇒ **被我们别的单位贴住的远程**（目标在 d ≥ 2）仍按压 1 估。
## 盘面：我方(AI) 红帽(2,4) + 雪拳(4,4)（负责把对面的远程贴住）；玩家 沉默术士(4,5)（攻3·疾行）+
##   影丸(5,4)（攻5·疾行）—— 两只都贴着雪拳、离红帽 d=2/3 ⇒ 退开一步就是满额伤害。
## 两臂：`能动`（正常）· `动不了`（把两只的 emove 改 0 = 荆棘/眩晕，退不掉 ⇒ 才该按压 1 算）。
##
## 输出：每行 `PROBE|...`，末尾 `PROBE|END`。

const FORK := preload("res://RL/ai/AI_Battle.gd")

var _grid: HexGrid

func _ready() -> void:
	_grid = HexGrid.new(5, 7, 48.0)
	_grid.top_cap_cols = [1, 3]
	_run.call_deferred()

func _run() -> void:
	print("PROBE|CFG|fork=%s" % _sha("res://RL/ai/AI_Battle.gd"))
	_arm("能动（退得掉 ⇒ 应算满额）", 1)
	_arm("动不了（emove=0 ⇒ 该按压 1 算）", 0)
	print("PROBE|END")
	get_tree().quit(0)

func _arm(tag: String, can_move: int) -> void:
	var descs: Array = []
	descs.append(_desc(DataRegistry.Faction.ENEMY, "hero_40", Vector2i(2, 4), "红帽"))
	descs.append(_desc(DataRegistry.Faction.ENEMY, "hero_26", Vector2i(4, 4), "雪拳"))
	descs.append(_desc(DataRegistry.Faction.PLAYER, "hero_34", Vector2i(4, 5), "沉默术士"))
	descs.append(_desc(DataRegistry.Faction.PLAYER, "hero_07", Vector2i(5, 4), "影丸"))
	if can_move == 0:
		descs[2]["emove"] = 0
		descs[3]["emove"] = 0
	var occ := {}
	for d in descs:
		occ[d["cell"]] = true
	var ai = FORK.new(_grid)
	ai.difficulty = 3
	ai.log_decisions = false
	var sim = ai.build_state(descs, occ, {}, {}, {}, {}, {})
	var cap = sim.units[0]
	var info := {}
	var inc: float = ai._incoming_total_on(sim, cap, cap.cell, info)
	var parts: Array[String] = []
	for row in (info.get("parts", []) as Array):
		var r: Array = row
		parts.append("%s=%.1f" % [String(r[0]), float(r[1])])
	var detail: Array[String] = []
	for i in [2, 3]:
		var e = sim.units[i]
		var d: int = _grid.distance(e.cell, cap.cell)
		detail.append("%s d%d 贴身=%s 退得掉=%s 退开能打=%s 贴身值=%d 满额值=%d" % [
			String(e.hero_id), d, str(ai._sim_enemy_adjacent(sim, e, e.cell)), str(ai._sim_pin_escapable(sim, e)),
			str(ai._sim_pin_escape_fire_cell(sim, e, cap.cell, cap)), int(ai._sim_pinned_atk(e)), int(ai._sim_free_atk(e))])
	print("PROBE|%s|红帽挨打合计=%.1f（逐笔：%s）" % [tag, inc, "、".join(parts)])
	print("PROBE|%s|逐敌：%s" % [tag, " ／ ".join(detail)])

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

func _sha(path: String) -> String:
	var c := FileAccess.get_file_as_bytes(path)
	var h := HashingContext.new()
	h.start(HashingContext.HASH_SHA256)
	h.update(c)
	return h.finish().hex_encode().substr(0, 12)
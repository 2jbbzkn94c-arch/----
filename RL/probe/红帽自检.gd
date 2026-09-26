extends Node
## 【2026-09-26 一次性探针·临时】红帽（hero_40）「扑街自爆」那几条用法自检 ——
##   用户 2026-09-26 口述四条 + 补的第五条（见 `src/BattleAI.gd` 的 `const REDCAP_HP_FLOOR_W` 处说明）：
##     ①保命血线（廉价解真实单击合计 + 1 − 末态血）②击杀回合防替补（墓碑格 + 替补名单·最坏一张）
##     ③有沉默就保护 ④没有廉价解时反过来蓄爆 ⑤保不住时队友别贴着她
##
## 每臂打三样：**原始输入**（①普攻逐笔是谁打的/打多少）＋**探针自算的"线"**（独立复现一遍筛选口径，
##   用来对拍引擎里那份）＋**五项分账**（`_redcap_terms()`）＋完整分（`_evaluate(sim, true)`）。
##   键按臂注入 `hero_40` 段（真实读取走 `_wh(红帽, ...)` ⇒ 段里的值优先）。
##
## 输出：每行 `PROBE|...`，末尾 `PROBE|END`。

const FORK := preload("res://RL/ai/AI_Battle.gd")
const W1 := 1.0        # 每臂只开它要测的那一个键（值 1.0 ⇒ 读数就是那一项本身）

var _grid: HexGrid

func _ready() -> void:
	_grid = HexGrid.new(5, 7, 48.0)
	_grid.top_cap_cols = [1, 3]
	_run.call_deferred()

func _run() -> void:
	print("PROBE|CFG|fork=%s" % _sha("res://RL/ai/AI_Battle.gd"))
	print("PROBE|CFG|盘面：红帽 hero_40 恒在 (2,4)；火枪手 hero_09(攻4·<远程>) 在 (4,4)；长剑 hero_18(攻3) 在 (1,4)")
	# 生产权重文件那一份也读一遍：确认 `hero_40` 段真的进了 AI 的 w_redcap_*（不只是探针手注入）
	var nm := _load_json("res://RL/weights/噩梦.json")
	print("PROBE|CFG|噩梦.json hero_40 段 = %s" % str(nm.get("hero_40", {})))
	var ai_nm = FORK.new(_grid)
	ai_nm.set_weights(nm)
	print("PROBE|CFG|AI 里的值 = 门:%s ①%.1f 残血线%.0f ②%.1f ③%.1f ④%.1f ⑤%.1f" % [
		str(ai_nm._redcap_on()), ai_nm.w_redcap_hp_floor, ai_nm.w_redcap_cheap_hp, ai_nm.w_redcap_sub_risk,
		ai_nm.w_redcap_silence_guard, ai_nm.w_redcap_trade, ai_nm.w_redcap_blast_ally])
	_arm("① 全 0（关）⇒ 应「不进分账」", 3, {}, [], {})
	_arm("① 满血13 · 只挨火枪手4 ⇒ 4+1−13<0 ⇒ 0", 13, {"REDCAP_HP_FLOOR_W": W1}, [F("hero_09", 4, 4)], {})
	_arm("① 残血3 · 只挨火枪手4 ⇒ −(4+1−3) = −2.00", 3, {"REDCAP_HP_FLOOR_W": W1}, [F("hero_09", 4, 4)], {})
	_arm("① 残血3 · +5血长剑(攻3，残血线内) ⇒ 线7 ⇒ −(7+1−3) = −5.00", 3, {"REDCAP_HP_FLOOR_W": W1},
			[F("hero_09", 4, 4), F("hero_18", 1, 4, 5)], {})
	_arm("① 同盘但长剑满血18 ⇒ 不算廉价解 ⇒ 线仍4 ⇒ −2.00（与上一臂对照）", 3, {"REDCAP_HP_FLOOR_W": W1},
			[F("hero_09", 4, 4), F("hero_18", 1, 4, 18)], {})
	_arm("① 残血3 · 带盾 + 火枪手4 ⇒ 盾抵最大一笔 ⇒ 线0 ⇒ 0", 3, {"REDCAP_HP_FLOOR_W": W1},
			[F("hero_09", 4, 4)], {"u40_shield": true})
	_arm("③ 满血13 · 沉默术士 hero_34 够得到 ⇒ 沉默风险 −(1+全额3)×1.0 = −4.00", 13,
			{"REDCAP_SILENCE_GUARD_W": W1}, [F("hero_34", 4, 4)], {})
	_arm("④ 血2 · 相邻 复仇者(攻2×2=4反击)+长剑(满血18) ⇒ 血≤反击、线0 ⇒ 蓄爆=净赚(13+13−21.25)=4.75", 2,
			{"REDCAP_TRADE_W": W1}, [F("hero_23", 1, 4), F("hero_18", 3, 4)], {})
	_arm("④ 同盘但血13 > 反击4 ⇒ 主动权不在自己手里 ⇒ 0", 13, {"REDCAP_TRADE_W": W1},
			[F("hero_23", 1, 4), F("hero_18", 3, 4)], {})
	_arm("④ 同盘但长剑残血5 ⇒ 出现廉价解 ⇒ 整条门关 ⇒ 0", 2, {"REDCAP_TRADE_W": W1},
			[F("hero_23", 1, 4), F("hero_18", 3, 4, 5)], {})
	var dead_near: Array = [F("hero_09", 3, 4)]
	var dead_far: Array = [F("hero_09", 0, 0)]
	_arm("② 血3(我方最低) · 墓碑(3,4) · 名单=[猎颅者] ⇒ 登场3+单击3=6 ⇒ clamp(6/3)=1.5 ⇒ −1.50", 3,
			{"REDCAP_SUB_RISK_W": W1}, [], {"dead": dead_near, "roster": ["hero_39"]})
	_arm("② 同上但**拿不到名单**（RL 跑批/默认）⇒ 恒 0", 3, {"REDCAP_SUB_RISK_W": W1}, [], {"dead": dead_near})
	_arm("② 同上但墓碑在 (0,0)（走不到）⇒ 只剩登场技3 ⇒ −1.00", 3, {"REDCAP_SUB_RISK_W": W1}, [],
			{"dead": dead_far, "roster": ["hero_39"]})
	_arm("② 同上但红帽不是血最低（队友2血）⇒ 登场技不打她、单击仍在3 ⇒ −1.00", 3,
			{"REDCAP_SUB_RISK_W": W1}, [], {"dead": dead_near, "roster": ["hero_39"], "ally_low": true})
	_arm("② 对照：没打死人（没有墓碑）⇒ 0", 3, {"REDCAP_SUB_RISK_W": W1}, [], {"roster": ["hero_39"]})
	_arm("⑤ 血3 · 挨打合计4≥3 · 队友(满血)相邻 ⇒ 止损 = −身价/20", 3, {"REDCAP_BLAST_ALLY_W": W1},
			[F("hero_09", 4, 4)], {"ally_adj": true})
	_arm("⑤ 同盘但队友**不**相邻 ⇒ 0", 3, {"REDCAP_BLAST_ALLY_W": W1}, [F("hero_09", 4, 4)], {"ally_far": true})
	_arm("⑤ 同盘 · 相邻队友只剩5血（会被13炸死）⇒ 那份再 +1 ⇒ ≈ −1.94", 3, {"REDCAP_BLAST_ALLY_W": W1},
			[F("hero_09", 4, 4)], {"ally_adj_weak": true})
	_arm("⑤ 对照：挨打合计 4 < 血 13 ⇒ 0（她还不会炸）", 13, {"REDCAP_BLAST_ALLY_W": W1},
			[F("hero_09", 4, 4)], {"ally_adj": true})
	print("PROBE|END")
	get_tree().quit(0)

func F(hid: String, x: int, y: int, hp: int = -1) -> Array:
	return [hid, Vector2i(x, y), hp]

func _arm(tag: String, hp: int, w40: Dictionary, foes: Array, opt: Dictionary) -> void:
	var descs: Array = []
	var cap := _desc(DataRegistry.Faction.ENEMY, "hero_40", Vector2i(2, 4), "红帽")
	cap["hp"] = hp
	if bool(opt.get("u40_shield", false)):
		cap["shield"] = true
	descs.append(cap)
	if bool(opt.get("ally_adj", false)) or bool(opt.get("ally_adj_weak", false)):
		var a := _desc(DataRegistry.Faction.ENEMY, "hero_18", Vector2i(2, 5), "队友长剑")
		if bool(opt.get("ally_adj_weak", false)):
			a["hp"] = 5
		descs.append(a)
	elif bool(opt.get("ally_far", false)):
		descs.append(_desc(DataRegistry.Faction.ENEMY, "hero_18", Vector2i(2, 6), "队友长剑(远)"))
	if bool(opt.get("ally_low", false)):
		var wl := _desc(DataRegistry.Faction.ENEMY, "hero_11", Vector2i(0, 6), "塔盾(2血)")
		wl["hp"] = 2
		descs.append(wl)
	for f in foes:
		var e := _desc(DataRegistry.Faction.PLAYER, String(f[0]), f[1] as Vector2i, String(f[0]))
		if int(f[2]) > 0:
			e["hp"] = int(f[2])
		descs.append(e)
	var dead_idx: Array = []
	for f in (opt.get("dead", []) as Array):
		descs.append(_desc(DataRegistry.Faction.PLAYER, String(f[0]), f[1] as Vector2i, String(f[0]) + "(已阵亡)"))
		dead_idx.append(descs.size() - 1)
	var occ := {}
	for d in descs:
		occ[d["cell"]] = true
	var ai = FORK.new(_grid)
	ai.difficulty = 3
	ai.log_decisions = false
	var rosters := {}
	if opt.has("roster"):
		rosters = { DataRegistry.Faction.PLAYER: (opt["roster"] as Array).duplicate() }
	ai.set_weights({ "hero_40": w40 })
	var sim = ai.build_state(descs, occ, {}, {}, {}, {}, {}, -1, rosters)
	for k in dead_idx:
		sim.units[k].alive = false
	var u = sim.units[0]
	var info := {}
	var inc: float = ai._incoming_total_on(sim, u, u.cell, info)
	var bits: Array[String] = []
	var line := 0.0
	var top_cheap := 0.0
	var sil_reach := false
	for row in (info.get("pos", []) as Array):
		var r: Array = row
		var idx := int(r[0])
		var who := "骷髅·召唤"
		var sil := false
		var cheap := false
		if idx >= 0 and idx < sim.units.size():
			var e2 = sim.units[idx]
			who = String(e2.name)
			sil = String(e2.hero_id) == "hero_34"
			cheap = sil or int(e2.atk_type) == int(DataRegistry.AttackType.RANGED) or float(e2.hp) <= 5.0
		bits.append("%s %.0f%s" % [who, float(r[1]), ("(廉价)" if cheap else "")])
		if cheap:
			line += float(r[1])
			top_cheap = maxf(top_cheap, float(r[1]))
		if sil:
			sil_reach = true
	if top_cheap > 0.0 and ai._shield_next_turn(sim, u) and top_cheap >= float(info.get("max", 0.0)) - 0.0001:
		line = maxf(line - top_cheap, 0.0)
	var sub_t: float = ai._redcap_sub_threat(sim, u)
	var on: bool = ai._redcap_on()
	var terms: Dictionary = ai._redcap_terms(sim) if on else {}
	var shown := "（不进分账）"
	if not terms.is_empty():
		shown = "血线=%.2f 替补=%.2f 沉默=%.2f 蓄爆=%.2f 止损=%.2f" % [
			float(terms.get("血线", 0.0)), float(terms.get("替补风险", 0.0)), float(terms.get("沉默风险", 0.0)),
			float(terms.get("蓄爆", 0.0)), float(terms.get("止损", 0.0))]
	print("PROBE|%s|血%d｜①普攻=%s｜探针线=%.1f(沉默者在程=%s)｜挨打合计=%.1f｜替补威胁=%.1f ⇒ %s｜分=%.2f" % [
		tag, int(u.hp), (("、".join(bits)) if bits.size() > 0 else "∅"), line, str(sil_reach), inc, sub_t,
		shown, float(ai._evaluate(sim, true))])

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

func _load_json(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var d = JSON.parse_string(f.get_as_text())
	f.close()
	return d if d is Dictionary else {}

func _sha(path: String) -> String:
	var c := FileAccess.get_file_as_bytes(path)
	var h := HashingContext.new()
	h.start(HashingContext.HASH_SHA256)
	h.update(c)
	return h.finish().hex_encode().substr(0, 12)
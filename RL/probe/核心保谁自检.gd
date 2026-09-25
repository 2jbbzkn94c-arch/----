extends Node
## 【2026-09-25 一次性探针·用户口径】⑦核心风险里"核心系数取谁"：
##   现役 = 静态**身价**（含面板血 `max_hp × 0.45`）⇒ 实测倒挂：塔盾(1攻/40血) > 白游侠(2攻/19血/技能4.4)。
##   用户原话：「我觉得还要考虑血量，让低血量的延缓死亡时间，增加输出机会」
## ⇒ 核心系数改成**几何混合** `身价^(1−w) × 输出潜力^w`，键 = `RISK_CORE_OUTPUT_W`（w 默认 0 = 现役逐位不变）。
##   （先试过二选一硬切纯输出潜力：A/B `c1 − c0 = −3.13 [−7.26,+1.01]` ⇒ 那个键已删，登记在 `1_通用策略.md` §四。）
## 本探针验六件事：
##   ① 现役身价确实倒挂（倒挂还在 ⇒ 这个键有用武之地）
##   ② 输出潜力把倒挂翻回来（塔盾 < 白游侠）
##   ③ w = 0 ⇒ `_core_raw()` 与 `_unit_value()` 逐位相同（现役行为不变）
##   ④ w = 1 ⇒ `_core_raw()` 与 `_output_potential()` 逐位相同（混合的两个端点）
##   ⑤ w = 0.5 ⇒ "塔盾/白游侠"的比值落在 输出比 与 身价比 之间（既被拉低、又没翻过头）
##   ⑥ ⑦ 罚分随 w 变化（w = 0 / 0.25 / 0.5 / 1 打出阶梯）
## 用法：godot --headless --path . --scene res://RL/probe/核心保谁自检.tscn

const AI := preload("res://src/BattleAI.gd")

var _fail := 0

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	var grid := HexGrid.new(5, 7, 60.0)
	var ai = AI.new(grid)
	# 造一个"双方各若干人"的最小局面（核心系数是按**我方存活均值**归一 ⇒ 需要几个人）
	var ids_mine := ["hero_11", "hero_10", "hero_25", "hero_13"]   # 塔盾 / 白游侠 / 战锤 / 独脚龟
	var ids_foe := ["hero_23", "hero_37"]
	var sim: AI.Sim = AI.Sim.new()
	var cells := [Vector2i(1, 4), Vector2i(2, 4), Vector2i(3, 4), Vector2i(1, 5), Vector2i(1, 2), Vector2i(3, 2)]
	var i := 0
	for hid in ids_mine:
		var u: AI.SimUnit = AI.SimUnit.new()
		u.hero_id = hid
		u.fn = DataRegistry.Faction.ENEMY
		u.cell = cells[i]
		u.alive = true
		sim.units.append(u)
		sim.occ[cell_key(u.cell)] = i
		i += 1
	for hid in ids_foe:
		var u: AI.SimUnit = AI.SimUnit.new()
		u.hero_id = hid
		u.fn = DataRegistry.Faction.PLAYER
		u.cell = cells[i]
		u.alive = true
		sim.units.append(u)
		sim.occ[cell_key(u.cell)] = i
		i += 1

	var u_ta: AI.SimUnit = null      # 塔盾
	var u_bai: AI.SimUnit = null     # 白游侠
	for u in sim.units:
		if u.hero_id == "hero_11":
			u_ta = u
		elif u.hero_id == "hero_10":
			u_bai = u

	# ③ 默认关：核心量必须与身价逐位相同（现役行为不变）
	ai.w_risk_core_output_w = 0.0
	var same := true
	for u in sim.units:
		var a: float = ai._core_raw(sim, u)
		var b: float = ai._unit_value(sim, u)
		if absf(a - b) > 0.0001:
			same = false
	print("PROBE|③ 默认（w=0）：_core_raw 与身价逐位相同 = %s" % str(same))
	if not same:
		_fail += 1
		print("PROBE|  ❌ 默认档行为变了")

	# ④ 另一端：w=1 必须逐位等于输出潜力
	ai.w_risk_core_output_w = 1.0
	var same1 := true
	for u in sim.units:
		var a: float = ai._core_raw(sim, u)
		var b: float = ai._output_potential(u.hero_id)
		if absf(a - b) > 0.0001:
			same1 = false
	print("PROBE|④ w=1：_core_raw 与输出潜力逐位相同 = %s" % str(same1))
	if not same1:
		_fail += 1
		print("PROBE|  ❌ w=1 没有等价于纯输出潜力")

	# ① 两把尺子对同一批人的排序
	var price_ta: float = ai._unit_value(sim, u_ta)
	var price_bai: float = ai._unit_value(sim, u_bai)
	print("PROBE|① 现役身价：塔盾(1攻/40血) = %.2f · 白游侠(2攻/19血/技能4.4) = %.2f ⇒ 塔盾更高 = %s（倒挂）" % [
		price_ta, price_bai, str(price_ta > price_bai)])
	var out_map := {}
	for u in sim.units:
		if u.fn != DataRegistry.Faction.ENEMY:
			continue
		out_map[u.hero_id] = ai._output_potential(u.hero_id)
	var out_ta: float = float(out_map.get("hero_11", 0.0))
	var out_bai: float = float(out_map.get("hero_10", 0.0))
	print("PROBE|② 输出潜力：塔盾 = %.2f · 白游侠 = %.2f ⇒ 塔盾更低 = %s（符合用户口径）" % [
		out_ta, out_bai, str(out_ta < out_bai)])
	# 全部我方英雄的输出潜力排序（看看谁会被优先保护）
	var rows: Array = []
	for hid in out_map.keys():
		rows.append("%s=%.1f" % [DataRegistry.get_hero(hid).display_name, float(out_map[hid])])
	rows.sort()
	print("PROBE|② 输出潜力排序：%s" % " · ".join(rows))
	if not (price_ta > price_bai):
		_fail += 1
		print("PROBE|  ⚠️ 现役身价这里没出现倒挂（英雄表数据可能变了，探针前提不再成立）")
	if not (out_ta < out_bai):
		_fail += 1
		print("PROBE|  ❌ 换成输出潜力后塔盾仍不低于白游侠")

	# ⑤ 混合（w=0.5）：比值必须落在"输出比"与"身价比"之间
	ai.w_risk_core_output_w = 0.5
	var mix_ta: float = ai._core_raw(sim, u_ta)
	var mix_bai: float = ai._core_raw(sim, u_bai)
	var r_price := price_ta / price_bai
	var r_out := out_ta / out_bai
	var r_mix := mix_ta / mix_bai
	var between := (r_mix < r_price and r_mix > r_out)
	print("PROBE|⑤ 混合 w=0.5：塔盾 = %.2f · 白游侠 = %.2f ⇒ 比值 %.3f（输出比 %.3f < 混合比 < 身价比 %.3f）= %s" % [
		mix_ta, mix_bai, r_mix, r_out, r_price, str(between)])
	if not between:
		_fail += 1
		print("PROBE|  ❌ 混合比值没落在两端之间")

	# ⑥ ⑦ 罚分阶梯：同样挨 6 点，w 越大越偏向"能输出的人"
	ai.w_risk = 3.0
	ai.w_risk_core_pow = 1.0
	var incs: Array = []
	for u in sim.units:
		incs.append(6.0 if u.fn == DataRegistry.Faction.ENEMY else 0.0)   # 假设每人挨 6 点
	var ladder: Array = []
	var risk0 := 0.0
	for w in [0.0, 0.25, 0.5, 1.0]:
		ai.w_risk_core_output_w = w
		ai._v_parts.clear()
		var r: float = ai._exposure_risk(sim, incs)
		if w == 0.0:
			risk0 = r
		ladder.append("w=%.2f→%.2f" % [w, r])
	print("PROBE|⑥ ⑦ 罚分（同样挨 6 点）：%s" % " · ".join(ladder))
	ai.w_risk_core_output_w = 0.5
	ai._v_parts.clear()
	var risk_mid: float = ai._exposure_risk(sim, incs)
	if absf(risk0 - risk_mid) < 0.0001:
		_fail += 1
		print("PROBE|  ❌ 换了核心系数权重，⑦ 罚分却没变")

	ai.w_risk_core_output_w = 0.0   # 收尾复位成现役值
	print("PROBE|%s" % ("全部通过 ✅" if _fail == 0 else "有 %d 项不对 ❌" % _fail))
	print("PROBE|END")
	get_tree().quit(0 if _fail == 0 else 1)

func cell_key(c: Vector2i) -> Vector2i:
	return c

extends Node
## 【2026-10-02 一次性探针·只读】「剥夺」计价体检 —— **不改任何生产代码、不进任何评分**。
##
## 起因（用户实机）：「对面的 AI 让人玩得不得劲，**想打的人伤害打不满**」，而我们比它弱。
## 待验证的假设：我们的账本里**没有一条项的值是"对方的输出总量掉了"** ——
##   ⑥规则B / ⑦核心风险 / ㉖暴露总量 / ㉛AoE形状 全都是「**我怕挨打**」（按**我方单位**求和），
##   ⑤位置拉力只有"够不着就压上"这一半；而 `Σ_player _outgoing_threat_on`
##   （= 玩家这一回合能打出的总伤害）在引擎里**已经存在**，却只当**并列裁决第 3 顺位**
##   （`_cmp_state()` 里 `w_tiebreak_mode >= 2` 才 append），**不进 `_evaluate`**。
##
## 本探针做的事：同一块盘上**只改我方那一步的落点**，读四个数：
##   玩家总输出 = Σ_player `_outgoing_threat_on` · 我方总威胁 = Σ_enemy 同式 ·
##   威胁差 = 前两者之差（引擎里那把并列裁决尺子）· 我方挨打合计 = Σ_enemy `_incoming_total_on` · `_evaluate`
##   两组的差别只在"玩家瞄准的目标是谁"：影丸(14 血 ⇒ 进 ㉖ 的门) / 长剑(18 血 ⇒ 不进 ㉖ 的门)。
##
## 三臂：
##   A 远      压制者站在够不到的地方（玩家输出不受影响）
##   B 贴身    压制者贴住玩家火枪手 ⇒ 远程攻 4→1（但**退得掉就按满额算**，现行口径）
##   C A/B 之外再加**一个障碍**堵退路 —— 探针自动遍历所有空格找"能把玩家输出压到最低"的那一格
##     （B 与 C 的差 = "退得掉" 与 "退不掉" 的差；C 才是玩家真正感受到的那种"打不满"）
##
## 用法：
##   & RL\train\跑Godot隔离.ps1 -Tag depr -TimeoutSec 900 -Args @('--headless','--path',(Get-Location).Path,'--scene','res://RL/probe/对方总输出自检.tscn')
## 输出：每行 `PROBE|...`，末尾 `PROBE|END`。

const FORK := preload("res://RL/ai/AI_Battle.gd")
const WEIGHTS_NM := "res://RL/weights/噩梦.json"
const WEIGHTS_NM1 := "res://RL/weights/噩梦1.json"
## 【2026-10-02 加】权重文件由命令行 user args 选：`… -- nm1` ⇒ 用 `噩梦1.json`（esc 门 **开**），
## 不带 ⇒ `噩梦.json`（esc 门 **关**）⇒ 同一次对拍就能看出"㉑ 那笔税拆掉之后，剥夺值多少分"。
var WEIGHTS := WEIGHTS_NM

# 盘面（都用 odd-q 平顶：row0 只有 x∈{1,3}，row1..6 满行）
#   火枪手放**角落**（0,1）——它的邻格只有 3 个，才可能真把它"围死"⇒ 退不掉。
const GUNNER_CELL := Vector2i(0, 1)     # 玩家的「想打的人」：火枪手（攻4/20血/<远程>）
const TARGET_CELL := Vector2i(0, 3)     # 我方被它瞄准的目标（距火枪手 2 格）
const PIN_FAR := Vector2i(0, 5)         # 压制者：**中性格** —— 离目标 2 格（算抱团 ⇒ ⑳㉓ 不罚）、
                                        # 离火枪手 4 格（不贴脸）⇒ A→B 的差才归因得到"剥夺"上
const PIN_NEAR := Vector2i(1, 1)        # 压制者：贴住火枪手（(1,1)-(0,1) 相邻）

var _grid: HexGrid
var _nm: Dictionary = {}

func _ready() -> void:
	_grid = HexGrid.new(5, 7, 48.0)
	_grid.top_cap_cols = [1, 3]
	_run.call_deferred()

func _run() -> void:
	# 看门狗：脚本中途抛错时 `quit()` 到不了 ⇒ 场景会空转（曾经把探针跑成"假仪器"），
	# 这里硬性兜底。
	get_tree().create_timer(180.0).timeout.connect(func() -> void:
		print("PROBE|WATCHDOG|180s 到点，强制退出")
		get_tree().quit(2))
	for _ua in OS.get_cmdline_user_args():
		if String(_ua) == "nm1":
			WEIGHTS = WEIGHTS_NM1
	_nm = _load_json(WEIGHTS)
	print("PROBE|CFG|fork=%s|weights=%s(%d 键)|BEAM=%s|SEARCH_MODE=%s|RISK_W=%s|EXPOSURE_TOTAL_W=%s|AOE_RIDER_TOTAL_W=%s" % [
		_sha("res://RL/ai/AI_Battle.gd"), WEIGHTS, _nm.size(),
		str(_nm.get("BEAM", "-")), str(_nm.get("SEARCH_MODE", "-")),
		str(_nm.get("RISK_W", "-")), str(_nm.get("EXPOSURE_TOTAL_W", "-")), str(_nm.get("AOE_RIDER_TOTAL_W", "-"))])
	print("PROBE|盘|火枪手@%s｜目标@%s｜压制者 远=%s 近=%s｜两处相邻判据=%s / %s" % [
		str(GUNNER_CELL), str(TARGET_CELL), str(PIN_FAR), str(PIN_NEAR),
		str(_grid.distance(GUNNER_CELL, PIN_FAR)), str(_grid.distance(GUNNER_CELL, PIN_NEAR))])

	_group("组1·目标=影丸(14血·进㉖的门)", "hero_07")
	_group("组2·目标=长剑(18血·不进㉖的门)", "hero_18")
	_group3()   # 【2026-10-02 加】攻防定价不对称（同盘只改一个数）

	print("PROBE|END")
	get_tree().quit(0)

func _group(tag: String, target_hero: String) -> void:
	print("PROBE|—— %s ——" % tag)
	var bd: Array = []
	var a := _arm(tag, "A 远", target_hero, PIN_FAR, {})
	bd.append(a)
	var b := _arm(tag, "B 贴身(退得掉)", target_hero, PIN_NEAR, {})
	bd.append(b)
	var c := _arm_best_block(tag, target_hero)
	bd.append(c)
	var ai_ref = a["ai"]
	var d_ac := float(c["ev"]) - float(a["ev"])
	print("PROBE|Δ(A→C) %s|%s" % [tag, ai_ref._breakdown_line(a["bd"], c["bd"], d_ac)])
	var d_ab := float(b["ev"]) - float(a["ev"])
	print("PROBE|Δ(A→B) %s|%s" % [tag, ai_ref._breakdown_line(a["bd"], b["bd"], d_ab)])

## 一臂：压制者站 pin_cell，障碍 obs
func _arm(tag: String, arm: String, target_hero: String, pin_cell: Vector2i, obs: Dictionary) -> Dictionary:
	# 顺序固定：0 = 玩家火枪手（gunner）· 1 = 我方目标 · 2 = 我方压制者
	var descs: Array = []
	descs.append(_desc(DataRegistry.Faction.PLAYER, "hero_09", GUNNER_CELL, "火枪手(攻4/血20/<远程>)"))
	descs.append(_desc(DataRegistry.Faction.ENEMY, target_hero, TARGET_CELL, "我方目标"))
	descs.append(_desc(DataRegistry.Faction.ENEMY, "hero_04", pin_cell, "鼠队长(攻4/血18/<疾行>·无技能)"))
	var built := _build(descs, obs)
	var ai = built["ai"]
	var sim = built["sim"]
	var gun = sim.units[0]
	var pin = sim.units[2]
	var p_out: float = _out_total(ai, sim, DataRegistry.Faction.PLAYER)
	var e_out: float = _out_total(ai, sim, DataRegistry.Faction.ENEMY)
	var inc: float = _inc_total(ai, sim)
	var ev: float = ai._evaluate(sim, true)
	var bd: Dictionary = ai._eval_breakdown(sim, true)
	var obs_note := "-" if obs.is_empty() else str(obs.keys()[0])
	print("PROBE|%s|%s|火枪手 atk=%d eatk=%d 与压制者相邻=%s｜玩家总输出=%.1f｜我方总威胁=%.1f｜威胁差=%+.1f｜挨打合计=%.1f｜_evaluate=%+.2f｜障碍=%s" % [
		tag, arm, int(gun.atk), int(gun.eatk), str(ai._sim_enemy_adjacent(sim, gun, gun.cell)),
		p_out, e_out, e_out - p_out, inc, ev, obs_note])
	return { "ev": ev, "bd": bd, "p_out": p_out, "inc": inc, "ai": ai }

## C 臂：在 B 的基础上把火枪手**其余的邻格**全用障碍堵上 ⇒ 它一步都挪不了 = 真·退不掉。
## （上一版试过"只加一个障碍、遍历 29 格"——一格都压不下来，因为远程有 emove≥2、
##   5 列棋盘上总还有路可退 ⇒ 必须把它围死才造得出"打不满"。）
func _arm_best_block(tag: String, target_hero: String) -> Dictionary:
	var nbrs: Array = _grid.neighbors(GUNNER_CELL)
	var obs := {}
	for cell in nbrs:
		var c: Vector2i = cell
		if c == PIN_NEAR or c == TARGET_CELL:
			continue
		obs[c] = true
	print("PROBE|%s|C 围死：火枪手 %s 的邻格 %s ⇒ 堵 %s" % [
		tag, str(GUNNER_CELL), str(nbrs), str(obs.keys())])
	return _arm(tag, "C 贴身+围死", target_hero, PIN_NEAR, obs)

# ---------------------------------------------------------------- 组3 · 存量/流量与攻防定价
## 【2026-10-02 加】**同一块盘、同一个位置、只改血量账的几个数**，量下面六件事的价 ——
## 起因：用户说竞品 AI「让你**想打的人伤害打不满**」= 它靠**剥夺输出/消耗**赢；要照做，我们的账本
##   就得按同样的价钱给"掉血"和"杀人"记账。
## ⚠️ **第一版探针在这里踩过一个坑，值得记住**：当时靠改 `desc` 的血量来造"本回合被打掉 4"，
##   量出"多打 4 点 = +0.00"——那不是"引擎看不见血量"，而是 `build_state()` 里是 `u.hp0 = u.hp`
##   ⇒ 改 desc 会**同时改起点**，于是"本回合流量"= 0；而且**存量在同一回合的所有候选里是常数**，
##   本来就**不该**影响排序（影响排序的是流量 ③ 与"流量 ÷ 起点"④）。
## 所以本组**直接改 Sim 的 `hp0/hp/alive`**，把"本回合的流量"造出来：
##   A 基准（敌满血 20）· B 敌被打掉 4（hp0=20→hp=16）· C 敌本来就残、被同样打掉 4（hp0=5→hp=1）
##   D 敌被收掉（hp0=5→hp=0, alive=false）· E 我方被打掉 4 · F 我方阵亡（hp0=6→0）
## 六组差：`B−A` 多打 4 点 · `C−B` **打残的溢价**（④ 集火按 `hp0` 归一）· `D−C` 收掉的价（②⑩）·
##   `E−A` 我方掉 4 点（应与 B−A **对称**）· `F−E` 我方阵亡的价（应与 D−C 对称）。
func _group3() -> void:
	print("PROBE|—— 组3·存量/流量与攻防定价（同盘·位置一格没动）——")
	var base: Array = [
		_desc(DataRegistry.Faction.ENEMY, "hero_04", Vector2i(2, 3), "我方鼠队长(攻4/血18)"),
		_desc(DataRegistry.Faction.ENEMY, "hero_07", Vector2i(4, 6), "我方影丸(14血·远处不挨打)"),
		_desc(DataRegistry.Faction.PLAYER, "hero_09", Vector2i(2, 1), "玩家火枪手(攻4/远程2/血20)"),
	]
	var a := _eval_mut(base, [], "A 基准（敌满血 20·本回合双方都没掉血）")
	var b := _eval_mut(base, [{ "i": 2, "hp0": 20, "hp": 16 }], "B 敌被本回合打掉 4（目标满血）")
	var c := _eval_mut(base, [{ "i": 2, "hp0": 5, "hp": 1 }], "C 敌被本回合打掉 4（它本来就残 ⇒ 打残）")
	var d := _eval_mut(base, [{ "i": 2, "hp0": 5, "hp": 0, "alive": false }], "D 敌被收掉（hp0=5 一击打死）")
	var e := _eval_mut(base, [{ "i": 0, "hp0": 18, "hp": 14 }], "E 我方被本回合打掉 4")
	var f := _eval_mut(base, [{ "i": 0, "hp0": 6, "hp": 0, "alive": false }], "F 我方阵亡（6 血被打死）")
	var ai = a["ai"]
	_p3(ai, a, b, "① 多打 4 点（满血目标）")
	_p3(ai, b, c, "② 同样打 4 点、但目标本来就残 ⇒ **打残的溢价**")
	_p3(ai, c, d, "③ 由「打残」变成「收掉」⇒ **击杀的价**")
	_p3(ai, a, e, "④ 我方掉 4 点（应与 ① 对称）")
	_p3(ai, e, f, "⑤ 我方由「掉 4」变成「阵亡」（应与 ③ 对称）")
	var d1 := float(b["ev"]) - float(a["ev"])
	var d4 := float(e["ev"]) - float(a["ev"])
	print("PROBE|结论|① 敌掉4 = %+.2f · ④ 我掉4 = %+.2f ⇒ **攻防比 = %.2f**｜② 打残溢价 = %+.2f · ③ 收掉 = %+.2f｜⑤ 我阵亡 = %+.2f" % [
		d1, d4, (d4 / d1 if absf(d1) > 0.0001 else 0.0),
		float(c["ev"]) - float(b["ev"]), float(d["ev"]) - float(c["ev"]), float(f["ev"]) - float(e["ev"])])

func _p3(ai, lo: Dictionary, hi: Dictionary, label: String) -> void:
	var dlt := float(hi["ev"]) - float(lo["ev"])
	print("PROBE|Δ %s|%s" % [label, ai._breakdown_line(lo["bd"], hi["bd"], dlt)])

## 造一块盘，再**直接改 Sim 的血量字段**（`hp0` / `hp` / `alive`）后评分。
## `muts` 每项 = `{ "i": 单位下标, "hp0": …, "hp": …, "alive": … }`（缺的键不动）。
func _eval_mut(descs: Array, muts: Array, label: String) -> Dictionary:
	var built := _build(descs)
	var ai = built["ai"]
	var sim = built["sim"]
	for m in muts:
		var u = sim.units[int(m["i"])]
		if (m as Dictionary).has("hp0"):
			u.hp0 = int(m["hp0"])
		if (m as Dictionary).has("hp"):
			u.hp = int(m["hp"])
		if (m as Dictionary).has("alive"):
			u.alive = bool(m["alive"])
	var ev: float = ai._evaluate(sim, true)
	var bd: Dictionary = ai._eval_breakdown(sim, true)
	print("PROBE|%s|_evaluate=%+.2f" % [label, ev])
	return { "ev": ev, "bd": bd, "ai": ai }

# ---------------------------------------------------------------- 尺子
## 某一方「这一回合能打出的总伤害」= Σ 该方单位 `_outgoing_threat_on`（对每个可达目标取最疼的一击）
func _out_total(ai, sim, fn: int) -> float:
	var tot := 0.0
	for i in sim.units.size():
		var u = sim.units[i]
		if u == null or not u.alive or u.fn != fn:
			continue
		tot += float(ai._outgoing_threat_on(sim, u))
	return tot

## 我方「下回合会挨到的总伤害」= Σ 我方单位 `_incoming_total_on`（现有唯一的防守尺子）
func _inc_total(ai, sim) -> float:
	var tot := 0.0
	for i in sim.units.size():
		var u = sim.units[i]
		if u == null or not u.alive or u.fn != DataRegistry.Faction.ENEMY:
			continue
		tot += float(ai._incoming_total_on(sim, u, u.cell))
	return tot

# ---------------------------------------------------------------- 工具
func _build(descs: Array, obs: Dictionary = {}) -> Dictionary:
	var occ := {}
	for i in descs.size():
		occ[descs[i]["cell"]] = i
	var ai = FORK.new(_grid)
	ai.difficulty = 3
	ai.log_decisions = false
	ai.set_weights(_nm)
	var sim = ai.build_state(descs, occ, {}, {}, obs, {}, {})
	return { "sim": sim, "ai": ai }

func _desc(fn: int, hid: String, cell: Vector2i, nm: String, over: Dictionary = {}) -> Dictionary:
	var hd = DataRegistry.heroes[hid]
	var emove := 2
	if (hd.skills as Array).has(DataRegistry.Skill.SWIFT):
		emove = 3
	var d := {
		"fn": fn, "hero": hid, "cell": cell, "hp": int(hd.max_hp), "max_hp": int(hd.max_hp),
		"atk": int(hd.atk), "eatk": int(hd.atk), "move": emove, "emove": emove,
		"atk_range": maxi(int(hd.attack_range), 1), "atk_type": int(hd.attack_type),
		"skills": (hd.skills as Array).duplicate(), "name": nm,
	}
	for k in over.keys():
		d[k] = over[k]
	return d

func _load_json(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var d = JSON.parse_string(f.get_as_text())
	f.close()
	if d is Dictionary:
		return d
	return {}

func _sha(path: String) -> String:
	var c := FileAccess.get_file_as_bytes(path)
	var h := HashingContext.new()
	h.start(HashingContext.HASH_SHA256)
	h.update(c)
	return h.finish().hex_encode().substr(0, 12)

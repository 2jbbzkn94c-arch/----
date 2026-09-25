extends Node
## 【2026-09-24 一次性探针】替补技（登场技）计价改动 A 的前后对照。
##
## 背景：`DataRegistry.sub_hero_score()` 原来给〈替补〉标签写死 `+0.5`（判出需求时等于白送）。
## 用户实机：需求 = 缺前排 ⇒ 小阴影(血18) 24.9 · 白游侠(血19) 24.6 · 太阳斩(血16) 23.9 ⇒ 它选了小阴影，
## 用户认为**太阳斩（有登场技）更该上**。⇒ 改成 `max(0.5, 1.0×(技能评分+补强))`（与"缺治疗"档同口径）。
##
## 本探针：拿一个代表局面（缺前排）分别打印三个候选的
##   技能评分 / 补强 / 新替补技分 / **旧口径下的分**（= 新分 − 新替补技分 + 0.5）⇒ 直接看名次有没有翻。
## 输出：`PROBE|...` 行 + `PROBE|END`。

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	# 代表局面：我方（AI）场上 = 宿魂/复仇者/炸弹人；对手 = 雪拳/赏金猎人/医护兵（取自用户最近那局）
	var ctx := {
		"ally_heroes": ["hero_46", "hero_23", "hero_35"],
		"foe_heroes": ["hero_26", "hero_20", "hero_06"],
		"wounded": 0,
		"player_near": false,
		"core": "hero_26",
	}
	var need: String = DataRegistry.sub_need(ctx)
	print("PROBE|CFG|need=%s(%s)|DataRegistry=%s" % [
		need, DataRegistry.sub_need_label(need), _sha("res://autoload/DataRegistry.gd")])
	var cands := ["hero_15", "hero_10", "hero_29"]   # 小阴影 / 白游侠 / 太阳斩
	var rows: Array = []
	for hid in cands:
		var def = DataRegistry.heroes[hid]
		var r: Dictionary = DataRegistry.sub_hero_score(hid, need, ctx)
		var bench_new: float = maxf(0.5, 1.0 * (float(def.ai_skill_score) + float(def.ai_boost)))
		var has_bench: bool = def.skills.has(DataRegistry.Skill.BENCH)
		var term: float = bench_new if has_bench else 0.0
		var old_s: float = float(r["s"]) - term + (0.5 if has_bench else 0.0)
		rows.append({ "n": def.display_name, "hp": def.max_hp, "skill": def.ai_skill_score,
			"boost": def.ai_boost, "bench": has_bench, "new": float(r["s"]), "old": old_s,
			"why": " / ".join(r["why"]) })
	for row in rows:
		print("PROBE|%s|血%d 技能评分%.1f 补强%.1f 有〈替补〉=%s|**改后 %.1f** / 改前 %.1f（差 %+.1f）|%s" % [
			row["n"], row["hp"], row["skill"], row["boost"], str(row["bench"]),
			row["new"], row["old"], float(row["new"]) - float(row["old"]), row["why"]])
	rows.sort_custom(func(a, b): return float(b["new"]) > float(a["new"]))
	print("PROBE|改后名次|%s" % " > ".join(rows.map(func(r): return "%s(%.1f)" % [r["n"], r["new"]])))
	var rows2 := rows.duplicate()
	rows2.sort_custom(func(a, b): return float(b["old"]) > float(a["old"]))
	print("PROBE|改前名次|%s" % " > ".join(rows2.map(func(r): return "%s(%.1f)" % [r["n"], r["old"]])))
	# ---- 场景二：用户第二例（黄金矿工已死 ⇒ 只剩 赏金猎人+负墟、伤员 2、名单里没有治疗族）----
	# 旧口径判"缺治疗"（healers=0 且 wounded>=2），可名单里一个治疗族都没有 ⇒ 三名非治疗英雄白拿加分、还印"补续航"。
	var ctx2 := {
		"taunt": 1, "healers": 0, "dps": 1, "ranged": 1, "wounded": 2,
		"core": "", "countered": false,
		"ally_heroes": ["hero_20", "hero_44"], "foe_heroes": ["hero_26", "hero_20", "hero_06"],
		"player_near": false,
	}
	var bench := ["hero_25", "hero_28", "hero_23", "hero_12", "hero_13"]   # 战锤/古灵精怪/复仇者 + 两个填充
	var need_old: String = DataRegistry.sub_need(ctx2)
	var need_new: String = DataRegistry.sub_need_for(bench, ctx2)
	print("PROBE|场景二·需求|旧口径=%s ｜ 新口径（带名单）=%s" % [
		DataRegistry.sub_need_label(need_old), DataRegistry.sub_need_label(need_new)])
	for hid in bench.slice(0, 3):
		var def2 = DataRegistry.heroes[hid]
		var r_old: Dictionary = DataRegistry.sub_hero_score(hid, need_old, ctx2)
		var r_new: Dictionary = DataRegistry.sub_hero_score(hid, need_new, ctx2)
		print("PROBE|场景二·%s|旧 %.1f（%s）⇒ 新 %.1f（%s）" % [
			def2.display_name, float(r_old["s"]), "、".join(r_old["why"]),
			float(r_new["s"]), "、".join(r_new["why"])])
	print("PROBE|END")
	get_tree().quit(0)

func _sha(path: String) -> String:
	var c := FileAccess.get_file_as_bytes(path)
	var h := HashingContext.new()
	h.start(HashingContext.HASH_SHA256)
	h.update(c)
	return h.finish().hex_encode().substr(0, 12)

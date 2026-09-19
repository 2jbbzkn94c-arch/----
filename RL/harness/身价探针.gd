extends Node
## 身价探针（2026-09-18）——**只读**，不改任何游戏状态，不建战斗。
## 目的：回答用户的问题「核心应该由公式算出来，而不是靠 HERO_VALUE 这种手写表」。
## 于是把 `DataRegistry.battle_unit_value_parts()` 的三项分量在**真实阵容语境**下全打出来：
##   身价 = VALUE_SOLO_W × solo + VALUE_RELATION_W × (synergy + counter)
## 看两件事：① 49 个英雄的 solo/配合/克制各有多大、区分度多少；
##          ② 8 支队伍**队内**的身价区分度（= "核心 vs 杂兵"到底差多少）。
## 用法：godot --headless --path <项目> res://RL/harness/身价探针.tscn

const TEAMS := {
	"A": ["hero_06", "hero_17", "hero_26"],
	"B": ["hero_11", "hero_04", "hero_13"],
	"C": ["hero_49", "hero_07", "hero_30"],
	"D": ["hero_28", "hero_34", "hero_42"],
	"E": ["hero_22", "hero_23", "hero_31"],
	"F": ["hero_25", "hero_26", "hero_10"],
	"G": ["hero_45", "hero_37", "hero_48"],
	"H": ["hero_16", "hero_33", "hero_47"],
}

func _ready() -> void:
	print("PROBE|begin|heroes=", DataRegistry.heroes.size())
	_dump_all()
	_dump_teams()
	_dump_tables()
	print("PROBE|end")
	get_tree().quit()

## ③ 两张关系表的"密度"：49×49 对里有几对非零？
## 这决定了公式里的 `(我克制对面 − 对面克制我)` 与 `Σ配合分` 到底能不能提供区分度。
func _dump_tables() -> void:
	var ids: Array = []
	for hid in DataRegistry.heroes.keys():
		ids.append(String(hid))
	ids.sort()
	var syn_pairs := 0
	var cnt_pairs := 0
	var cnt_pos := 0
	var cnt_neg := 0
	var syn_max := 0.0
	var cnt_max := 0.0
	var cnt_min := 0.0
	var syn_examples: Array = []
	var cnt_examples: Array = []
	for a in ids:
		for b in ids:
			if String(a) == String(b):
				continue
			var sb := float(DataRegistry.synergy_bonus(String(a), String(b)))
			if absf(sb) > 1e-9:
				syn_pairs += 1
				syn_max = maxf(syn_max, sb)
				if syn_examples.size() < 8:
					syn_examples.append("%s+%s=%.2f" % [String(a), String(b), sb])
			var cb := float(DataRegistry.counter_bonus(String(a), String(b)))
			if absf(cb) > 1e-9:
				cnt_pairs += 1
				if cb > 0.0:
					cnt_pos += 1
					cnt_max = maxf(cnt_max, cb)
				else:
					cnt_neg += 1
					cnt_min = minf(cnt_min, cb)
				if cnt_examples.size() < 12:
					cnt_examples.append("%s>%s=%.2f" % [String(a), String(b), cb])
	var n := ids.size()
	print("PROBE|density|heroes=%d|pairs=%d|syn_nonzero=%d (%.1f%%)|cnt_nonzero=%d (%.1f%%)|cnt_pos=%d|cnt_neg=%d|cnt_range=%.2f..%.2f|syn_max=%.2f"
			% [n, n * (n - 1), syn_pairs, 100.0 * syn_pairs / float(n * (n - 1)),
			   cnt_pairs, 100.0 * cnt_pairs / float(n * (n - 1)), cnt_pos, cnt_neg, cnt_min, cnt_max, syn_max])
	print("PROBE|syn_examples|", " ; ".join(syn_examples))
	print("PROBE|cnt_examples|", " ; ".join(cnt_examples))

## ① 全英雄：以一个固定语境算三项分量（队友 = A 队前两人，对面 = B 队三人）
func _dump_all() -> void:
	var allies: Array = ["hero_06", "hero_17"]
	var foes: Array = ["hero_11", "hero_04", "hero_13"]
	var ids: Array = []
	for hid in DataRegistry.heroes.keys():
		ids.append(String(hid))
	ids.sort()
	print("PROBE|all|allies=", allies, "|foes=", foes)
	var solo_min := 1e9; var solo_max := -1e9
	var tot_min := 1e9; var tot_max := -1e9
	for hid in ids:
		var p: Dictionary = DataRegistry.battle_unit_value_parts(String(hid), allies, foes, null)
		var solo := float(p["solo"])
		var syn := float(p["synergy"])
		var cnt := float(p["counter"])
		var tot := solo * 1.0 + (syn + cnt) * 0.6
		solo_min = minf(solo_min, solo); solo_max = maxf(solo_max, solo)
		tot_min = minf(tot_min, tot); tot_max = maxf(tot_max, tot)
		print("PROBE|hero|%s|solo=%.2f|syn=%.2f|cnt=%.2f|tot=%.2f" % [String(hid), solo, syn, cnt, tot])
	print("PROBE|all_range|solo=%.2f..%.2f|tot=%.2f..%.2f|solo_ratio=%.2f|tot_ratio=%.2f"
			% [solo_min, solo_max, tot_min, tot_max,
			   (solo_max / maxf(solo_min, 0.01)), (tot_max / maxf(tot_min, 0.01))])

## ② 8 支队伍：队内三人（队友 = 同队另两人，对面 = 下一队的三人）的身价
func _dump_teams() -> void:
	var keys: Array = TEAMS.keys()
	keys.sort()
	for i in keys.size():
		var t: String = keys[i]
		var deck: Array = TEAMS[t]
		var foe: Array = TEAMS[keys[(i + 1) % keys.size()]]
		var rows: Array = []
		var lo := 1e9; var hi := -1e9
		for hid in deck:
			var allies: Array = []
			for other in deck:
				if other != hid:
					allies.append(other)
			var p: Dictionary = DataRegistry.battle_unit_value_parts(String(hid), allies, foe, null)
			var tot := float(p["solo"]) * 1.0 + (float(p["synergy"]) + float(p["counter"])) * 0.6
			lo = minf(lo, tot); hi = maxf(hi, tot)
			rows.append("%s solo=%.2f syn=%.2f cnt=%.2f tot=%.2f" % [String(hid), float(p["solo"]), float(p["synergy"]), float(p["counter"]), tot])
		print("PROBE|team|%s|foe=%s|spread=%.2f..%.2f (ratio %.2f)|%s"
				% [t, str(foe), lo, hi, hi / maxf(lo, 0.01), " || ".join(rows)])

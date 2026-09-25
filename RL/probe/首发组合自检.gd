extends Node
## 【2026-09-24 一次性探针】验证首发部署 C「枚举组合看整套分」。
##
## 卡池用用户那局日志里的敌方池：复仇者 hero_23 / 炸弹人 hero_35 / 嬉皮死神 hero_30 /
##   小阴影 hero_15 / 圣诞老人 hero_02 / 血锁 hero_41（前 6 名可见的那些）。
## 打印：① 每个候选「上它 + 其余按最优补齐 ⇒ 整套首发」的总分（= 新日志口径）；
##       ② 三人组排行榜前 5；③ 旧口径（逐槽贪心）会挑出谁 —— 对比两者是否不同。
## 输出：每行 `PROBE|...`，末尾 `PROBE|END`。

var _b: Battle = null
const POOL := ["hero_23", "hero_35", "hero_30", "hero_15", "hero_02", "hero_41"]

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	GameState.reset_online()
	GameState.dual_control = false
	GameState.arena_mode = false
	GameState.pick_deck_in_battle = false
	_b = load("res://scenes/Main.tscn").instantiate() as Battle
	_b.set_random_seed(777001)
	get_tree().root.add_child(_b)
	var pool: Array = POOL.duplicate()
	print("PROBE|CFG|pool=%s|首发人数=%d" % [str(pool), int(_b.DEPLOY_COUNT_BATTLE)])
	# ① 旧口径：逐槽贪心连挑 3 次
	var dep_old: Array = []
	var pool_old: Array = pool.duplicate()
	for k in 3:
		var bi := -1
		var bsc := -1e9
		for i in pool_old.size():
			var h: String = pool_old[i]
			var sc: float = _b._deploy_candidate_value(h, dep_old)
			if sc > bsc:
				bsc = sc
				bi = i
		print("PROBE|旧口径·第%d槽|→ %s（该槽价值 %.1f）" % [k + 1, _nm(pool_old[bi]), bsc])
		dep_old.append(pool_old[bi])
		pool_old.remove_at(bi)
	print("PROBE|旧口径|三人组=%s|整套分=%.1f" % [_names(dep_old), _b._deploy_set_value(dep_old)])
	# ② 新口径：每个候选的"边际贡献"（上它 + 其余补齐）
	print("PROBE|新口径·候选|（后面数是「上它 + 其余按最优补齐 ⇒ 整套首发」的总分）")
	var cand_rows: Array = []
	for hc in pool:
		var rest: Array = pool.duplicate()
		rest.erase(hc)
		var best_have := -1e9
		var best_tail: Array = []
		for tail in _b._combos_of(rest, 2):
			var ids: Array = [hc]
			ids.append_array(tail)
			var v: float = _b._deploy_set_value(ids)
			if v > best_have:
				best_have = v
				best_tail = tail
		cand_rows.append({ "h": hc, "sc": best_have, "tail": best_tail })
	cand_rows.sort_custom(func(x, y): return float(x["sc"]) > float(y["sc"]))
	for r in cand_rows:
		print("PROBE|新口径·候选|%s  整套%.1f（搭配 %s）" % [
			_nm(String(r["h"])), float(r["sc"]), _names(r["tail"])])
	# ③ 三人组排行榜
	var all_rows: Array = []
	for c in _b._combos_of(pool, 3):
		all_rows.append({ "c": c, "sc": _b._deploy_set_value(c) })
	all_rows.sort_custom(func(x, y): return float(x["sc"]) > float(y["sc"]))
	print("PROBE|新口径|组合数=%d" % all_rows.size())
	for r in all_rows.slice(0, mini(5, all_rows.size())):
		print("PROBE|新口径·前三|%s = %.1f" % [_names(r["c"]), float(r["sc"])])
	var best: Array = all_rows[0]["c"]
	print("PROBE|判定|新口径最优=%s（%.1f）｜旧口径=%s ⇒ %s" % [
		_names(best), float(all_rows[0]["sc"]), _names(dep_old),
		("不同 ✓ 组合搜索真的改变了选择" if str(best) != str(dep_old) else "相同（这套卡池里组合分不足以翻盘）")])
	# ④ 端到端：真的连点三次「敌方部署」，看落子（`_enemy_deploy()` = 线上路径）
	#   ⚠️ `_CONSOLE_AI_LOG` 是 const，探针里改不了 ⇒ 这一步只验"实际选谁"，不打印 AI 日志。
	_b.enemy_pool = pool.duplicate()
	_b.enemy_deployed = []
	for k in 3:
		_b.state = Battle.State.DEPLOY
		_b._deploy_side = 1
		_b._enemy_deploy()
		print("PROBE|端到端·第%d槽|→ %s（已上阵 %d 人）" % [k + 1,
			_nm(String(_b.enemy_deployed[k])), _b.enemy_deployed.size()])
	print("PROBE|端到端|三次部署后 = %s" % _names(_b.enemy_deployed))
	print("PROBE|END")
	get_tree().quit(0)

func _nm(h: String) -> String:
	var d = DataRegistry.get_hero(h)
	return d.display_name if d != null else h

func _names(arr: Array) -> String:
	var out: Array[String] = []
	for h in arr:
		out.append(_nm(String(h)))
	return "+".join(out)

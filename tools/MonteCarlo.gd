extends SceneTree
## 轻量蒙特卡洛对局模拟器：自解析角色表，跑很多局统计英雄/卡组胜率。
## 运行：godot --headless --script res://tools/MonteCarlo.gd  结果写 user://winrate_database.cfg

const GRID_W := 7
const GRID_H := 10
const LOSS := 3
const DEPLOY := 3
const DECK := 5
const MATCHES := 8000
const F_PLAYER := 0
const F_ENEMY := 1

var HEROES := {}   # hid -> dict

class U:
	var hid := ""
	var name := ""
	var atk := 1
	var max_hp := 1
	var hp := 1
	var rng := 1
	var mv := 2
	var ranged := false
	var skills: Array = []
	var cell := Vector2i.ZERO
	var faction := 0
	var alive := true
	var poison := false
	var heavy := false
	var freeze := false
	var stun := false
	var shield := false
	var atkdown := false
	var atkd := 0
	var moved := false
	var attacked := false

class Sim:
	var units: Array = []
	var occ := {}
	var player_bench: Array = []
	var enemy_bench: Array = []

# ---- 坐标工具（odd-q 平顶六边形）----
func _axial(c: Vector2i) -> Vector2i:
	var half := int((c.x - (c.x % 2)) / 2.0)
	return Vector2i(c.x, c.y - half)

func _hex_dist(a: Vector2i, b: Vector2i) -> int:
	var ax := _axial(a)
	var bx := _axial(b)
	return (abs(ax.x - bx.x) + abs(ax.x + ax.y - bx.x - bx.y) + abs(ax.y - bx.y)) / 2

func _neighbors(c: Vector2i) -> Array:
	var nbrs: Array = []
	var ax := _axial(c)
	var dirs := [Vector2i(1,0),Vector2i(0,1),Vector2i(-1,1),Vector2i(-1,0),Vector2i(0,-1),Vector2i(1,-1)]
	for d in dirs:
		var na := ax + Vector2i(d)
		var off := Vector2i(na.x, na.y + int((na.x - (na.x % 2)) / 2.0))
		nbrs.append(off)
	return nbrs

func _inb(c: Vector2i) -> bool:
	return c.x >= 0 and c.x < GRID_W and c.y >= 0 and c.y < GRID_H

# ---- 解析角色表 ----
func _load_heroes() -> void:
	var f := FileAccess.open("res://角色列表.md", FileAccess.READ)
	if f == null:
		print("无法读取角色列表.md")
		return
	var lines := f.get_as_text().split("\n")
	f.close()
	for raw in lines:
		var line := raw.strip_edges()
		if not line.begins_with("|"):
			continue
		var cells := line.split("|")
		if cells.size() < 7:
			continue
		var no := cells[1].strip_edges().to_int()
		if no <= 0:
			continue
		var name := cells[3].strip_edges()
		var atk := cells[4].strip_edges().to_int()
		var hp := cells[5].strip_edges().to_int()
		var skill := cells[6].strip_edges()
		var hid := "hero_%02d" % no
		HEROES[hid] = {
			"name": name, "atk": atk, "hp": hp, "skill": skill,
			"ranged": skill.contains("远程"), "taunt": skill.contains("嘲讽"),
			"swift": skill.contains("疾行"), "infiltrate": skill.contains("渗透"),
			"logistics": skill.contains("后勤"), "bench": skill.contains("替补"),
		}

func _make_unit(hid: String, faction: int, cell: Vector2i) -> U:
	var d: Dictionary = HEROES[hid]
	var u := U.new()
	u.hid = hid
	u.name = d["name"]
	u.atk = d["atk"]
	u.max_hp = d["hp"]
	u.hp = d["hp"]
	u.ranged = d["ranged"]
	u.rng = 2 if u.ranged else 1
	u.mv = 2
	if d["swift"]:
		u.mv += 1
	if hid == "hero_24":
		u.mv += 6
	u.skills = []
	if d["taunt"]: u.skills.append("taunt")
	if d["infiltrate"]: u.skills.append("infiltrate")
	if d["logistics"]: u.skills.append("logistics")
	u.cell = cell
	u.faction = faction
	return u

func _eff_atk(u: U) -> int:
	var a := u.atk + u.atkd
	if u.atkdown:
		a -= 1
	return max(a, 0)

func _damage(s: Sim, u: U, amt: int) -> void:
	if not u.alive:
		return
	if u.shield:
		u.shield = false
		return
	u.hp = max(u.hp - amt, 0)
	if u.hp <= 0:
		u.alive = false
		s.occ.erase(u.cell)

func _dead(s: Sim, faction: int) -> int:
	var n := 0
	for u in s.units:
		if not u.alive and u.faction == faction:
			n += 1
	return n

func _check_win(s: Sim) -> int:
	if _dead(s, F_PLAYER) >= LOSS:
		return 2
	if _dead(s, F_ENEMY) >= LOSS:
		return 1
	return 0

func _nearest_enemy(s: Sim, u: U) -> U:
	var best: U = null
	var bd := 1 << 30
	for v in s.units:
		if v.alive and v.faction != u.faction:
			var d := _hex_dist(u.cell, v.cell)
			if d < bd:
				bd = d
				best = v
	return best

func _enemy_adjacent(s: Sim, u: U, cell: Vector2i) -> bool:
	for n in _neighbors(cell):
		if s.occ.has(n):
			var v: U = s.occ[n]
			if v.alive and v.faction != u.faction:
				return true
	return false

func _attackable(s: Sim, u: U) -> Array:
	var out := []
	var range_at := u.rng
	if u.ranged and _enemy_adjacent(s, u, u.cell):
		range_at = 1
	for v in s.units:
		if v.alive and v.faction != u.faction:
			var d := _hex_dist(u.cell, v.cell)
			if d >= 1 and d <= range_at:
				out.append(v)
	return out

func _step_toward(s: Sim, u: U, target: U) -> void:
	var best: Vector2i = u.cell
	var bd := _hex_dist(u.cell, target.cell)
	for n in _neighbors(u.cell):
		if not _inb(n) or s.occ.has(n):
			continue
		var d := _hex_dist(n, target.cell)
		if d < bd:
			bd = d
			best = n
	if best != u.cell:
		s.occ.erase(u.cell)
		u.cell = best
		s.occ[best] = u

func _is_lowest(s: Sim, t: U) -> bool:
	for v in s.units:
		if v.alive and v.hp < t.hp:
			return false
	return true

func _is_isolated(s: Sim, t: U) -> bool:
	for n in _neighbors(t.cell):
		if s.occ.has(n):
			var v: U = s.occ[n]
			if v.alive and v.faction != t.faction:
				return false
	return true

func _mult(s: Sim, u: U, t: U) -> int:
	var mult := 1
	if u.hid == "hero_15" and _is_lowest(s, t):
		mult = 2
	if u.hid == "hero_20" and u.ranged and t.skills.has("taunt"):
		mult = 2
	if u.hid == "hero_30" and _is_isolated(s, t):
		mult = 2
	return mult

# 单位一回合行动
func _act(s: Sim, u: U) -> void:
	u.moved = false
	u.attacked = false
	if not u.alive or u.stun:
		return
	var targets := _attackable(s, u)
	if targets.size() > 0:
		var low: U = targets[0]
		var taunt := false
		for t in targets:
			if t.skills.has("taunt"):
				low = t
				taunt = true
				break
			if t.hp < low.hp:
				low = t
		var dmg := _eff_atk(u) * _mult(s, u, low)
		if u.ranged and _enemy_adjacent(s, u, u.cell):
			dmg = mini(dmg, 1)
		_damage(s, low, dmg)
		u.attacked = true
		_on_attack_hit(s, u, low)
		return
	var target := _nearest_enemy(s, u)
	if target == null:
		return
	for i in u.mv:
		_step_toward(s, u, target)
	u.moved = true
	_on_move(s, u)

func _on_attack_hit(s: Sim, u: U, t: U) -> void:
	match u.hid:
		"hero_03": t.poison = true
		"hero_12": t.heavy = true
		"hero_25": t.atkdown = true; t.freeze = true
		"hero_14": if t.hp > u.hp: u.hp = min(u.hp + u.atk, u.max_hp)
		"hero_29": if u.atkd > 0: u.atkd -= 1

func _on_move(s: Sim, u: U) -> void:
	match u.hid:
		"hero_06": _heal_lowest_adj(s, u)
		"hero_26": _freeze_adj(s, u)
		"hero_43":
			for v in s.units:
				if v.alive and v.faction == u.faction and v != u:
					v.atkd = max(v.atkd, 1)

func _heal_lowest_adj(s: Sim, u: U) -> void:
	var best: U = null
	var bhp := 1 << 30
	for n in _neighbors(u.cell):
		if s.occ.has(n):
			var v: U = s.occ[n]
			if v.alive and v.faction == u.faction and v.hp < v.max_hp and v.hp < bhp:
				bhp = v.hp
				best = v
	if best != null:
		best.hp = min(best.hp + u.atk, best.max_hp)

func _freeze_adj(s: Sim, u: U) -> void:
	for n in _neighbors(u.cell):
		if s.occ.has(n):
			var v: U = s.occ[n]
			if v.alive and v.faction != u.faction:
				v.freeze = true

# 一场对局（双方随机卡组）
func _play(player_deck: Array, enemy_deck: Array) -> int:
	var s := Sim.new()
	for i in DEPLOY:
		var pc := Vector2i(1 + i * 2, GRID_H - 1)
		var ec := Vector2i(1 + i * 2, 0)
		var pu := _make_unit(player_deck[i], F_PLAYER, pc)
		var eu := _make_unit(enemy_deck[i], F_ENEMY, ec)
		s.units.append(pu); s.occ[pc] = pu
		s.units.append(eu); s.occ[ec] = eu
	s.player_bench = player_deck.slice(DEPLOY)
	s.enemy_bench = enemy_deck.slice(DEPLOY)
	var turn := 0
	var guard := 0
	while guard < 300:
		guard += 1
		var faction := F_PLAYER if turn % 2 == 0 else F_ENEMY
		for u in s.units.duplicate():
			if u.alive and u.faction == faction:
				_act(s, u)
		for u in s.units:
			if u.alive and u.poison:
				_damage(s, u, 1)
		var w := _check_win(s)
		if w != 0:
			return w
		_fill_bench(s, faction)
		turn += 1
	return 0

func _fill_bench(s: Sim, faction: int) -> void:
	var bench: Array = s.player_bench if faction == F_PLAYER else s.enemy_bench
	if bench.size() == 0:
		return
	var row := GRID_H - 1 if faction == F_PLAYER else 0
	var cells := [Vector2i(0,row),Vector2i(1,row),Vector2i(3,row),Vector2i(5,row),Vector2i(6,row)]
	for c in cells:
		if _inb(c) and not s.occ.has(c):
			var hid: String = bench.pop_front()
			var u := _make_unit(hid, faction, c)
			s.units.append(u)
			s.occ[c] = u
			return

# ---- 主流程 ----
func _initialize() -> void:
	randomize()
	_load_heroes()
	print("heroes parsed: ", HEROES.size())
	if HEROES.size() == 0:
		print("解析失败，退出")
		quit(1)
		return
	var hero_ids: Array = HEROES.keys()
	var perhero := {}   # hid -> [wins, games]
	var percombo := {}
	var perpairs := {}  # "a|b" -> [wins, games]
	var pertriples := {}  # "a|b|c" -> [wins, games]
	for m in MATCHES:
		var pdeck := _rand_deck(hero_ids)
		var edeck := _rand_deck(hero_ids)
		var w := _play(pdeck, edeck)
		for hid in pdeck:
			if not perhero.has(hid): perhero[hid] = [0,0]
			perhero[hid][1] += 1
			if w == 1: perhero[hid][0] += 1
		for hid in edeck:
			if not perhero.has(hid): perhero[hid] = [0,0]
			perhero[hid][1] += 1
			if w == 2: perhero[hid][0] += 1
		var pk := _combo_key(pdeck)
		var ek := _combo_key(edeck)
		_record(percombo, pk, w == 1)
		_record(percombo, ek, w == 2)
		_record_pairs(perpairs, pdeck, w == 1)
		_record_pairs(perpairs, edeck, w == 2)
		_record_triples(pertriples, pdeck, w == 1)
		_record_triples(pertriples, edeck, w == 2)
	var lines := ["=== 英雄胜率（%d 局，双方各 %d 人，%d 阵亡判负）===" % [MATCHES, DECK, LOSS]]
	for hid in perhero.keys():
		var g = perhero[hid]
		lines.append("%s %s  %.1f%%  (%d/%d)" % [hid, HEROES[hid]["name"], 100.0*g[0]/g[1], g[0], g[1]])
	lines.append("=== 卡组组合胜率（胜方基准；展示 >=5 次出现的）===")
	for k in percombo.keys():
		var g = percombo[k]
		if g[1] >= 5:
			lines.append("%s  %.1f%%  (%d/%d)" % [k, 100.0*g[0]/g[1], g[0], g[1]])
	lines.append("=== 双人组合胜率（同队的 2 人组合；展示 >=40 次出现的 Top/Bottom）===")
	var pairs_sorted: Array = []
	for k in perpairs.keys():
		var g = perpairs[k]
		if g[1] >= 40:
			pairs_sorted.append([k, g[0], g[1]])
	pairs_sorted.sort_custom(func(a, b): return float(a[1])/a[2] > float(b[1])/b[2])
	for p in pairs_sorted.slice(0, 20):
		lines.append("  [高] %s  %.1f%%  (%d/%d)" % [_pair_name(p[0]), 100.0*p[1]/p[2], p[1], p[2]])
	for p in pairs_sorted.slice(max(0, pairs_sorted.size()-20), pairs_sorted.size()):
		lines.append("  [低] %s  %.1f%%  (%d/%d)" % [_pair_name(p[0]), 100.0*p[1]/p[2], p[1], p[2]])
	lines.append("=== 三人组合胜率（同队 3 人；展示 >=10 次出现的 Top/Bottom）===")
	var triples_sorted: Array = []
	for k in pertriples.keys():
		var g = pertriples[k]
		if g[1] >= 10:
			triples_sorted.append([k, g[0], g[1]])
	triples_sorted.sort_custom(func(a, b): return float(a[1])/a[2] > float(b[1])/b[2])
	for p in triples_sorted.slice(0, 15):
		lines.append("  [高] %s  %.1f%%  (%d/%d)" % [_triple_name(p[0]), 100.0*p[1]/p[2], p[1], p[2]])
	for p in triples_sorted.slice(max(0, triples_sorted.size()-15), triples_sorted.size()):
		lines.append("  [低] %s  %.1f%%  (%d/%d)" % [_triple_name(p[0]), 100.0*p[1]/p[2], p[1], p[2]])
	var out := "\n".join(lines)
	print(out)
	var f := FileAccess.open("user://winrate_database.cfg", FileAccess.WRITE)
	if f:
		f.store_string(out)
		f.close()
		print("已写 user://winrate_database.cfg")
	quit(0)

func _rand_deck(hero_ids: Array) -> Array:
	var pool := hero_ids.duplicate()
	pool.shuffle()
	return pool.slice(0, DECK)

func _combo_key(deck: Array) -> String:
	var names := []
	for hid in deck:
		names.append(HEROES[hid]["name"])
	names.sort()
	return " + ".join(names)

func _record(percombo: Dictionary, k: String, won: bool) -> void:
	if not percombo.has(k): percombo[k] = [0,0]
	percombo[k][1] += 1
	if won: percombo[k][0] += 1

# 记录卡组中所有二人组合的同队胜率
func _record_pairs(perpairs: Dictionary, deck: Array, won: bool) -> void:
	for i in deck.size():
		for j in range(i + 1, deck.size()):
			var a: String = deck[i]
			var b: String = deck[j]
			var key: String = a if a < b else b
			key += "|" + (b if a < b else a)
			if not perpairs.has(key): perpairs[key] = [0,0]
			perpairs[key][1] += 1
			if won: perpairs[key][0] += 1

func _pair_name(key: String) -> String:
	var parts := key.split("|")
	return "%s+%s" % [HEROES[parts[0]]["name"], HEROES[parts[1]]["name"]]

# 记录卡组中所有三人组合的同队胜率
func _record_triples(pertriples: Dictionary, deck: Array, won: bool) -> void:
	for i in deck.size():
		for j in range(i + 1, deck.size()):
			for k in range(j + 1, deck.size()):
				var arr: Array = [deck[i], deck[j], deck[k]]
				arr.sort()
				var key: String = str(arr[0]) + "|" + str(arr[1]) + "|" + str(arr[2])
				if not pertriples.has(key): pertriples[key] = [0,0]
				pertriples[key][1] += 1
				if won: pertriples[key][0] += 1

func _triple_name(key: String) -> String:
	var parts := key.split("|")
	return "%s+%s+%s" % [HEROES[parts[0]]["name"], HEROES[parts[1]]["name"], HEROES[parts[2]]["name"]]

extends Node
## 离线对账复盘器：把 `arena/记录/<局号>.jsonl` 里**每一手的真观察 + 我们当时交的动作**重新走一遍
## 桥的决策/对账逻辑，逐手打印"我们算的 vs 裁判给的"，把规则差异钉到具体单位/具体项。
##
## 为什么要有它：`预测 vs 实际` 只在**当局实时**能看到（面板只留最近 40 手），打完就没了；
## 而 `.jsonl` 把每一手的真观察都存下来了 ⇒ 任何时候都能重建那条对账链。
##
## 起法：
##   godot --headless --path <项目根> --scene res://arena/对账复盘.tscn -- --match=arena_xxxxxxxx-...
##   （不给 --match 就取 arena/记录/ 下最新的一份 .jsonl）

class Stub:
	extends RefCounted
	func _log(m: String) -> void:
		print("RA|", m)

const REC_DIR := "res://arena/记录"

var _bridge = null


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	var mid := _arg("--match=")
	if mid == "":
		mid = _latest_match()
	if mid == "":
		print("RA|!! arena/记录 下没有 .jsonl，先打一局")
		get_tree().quit(1)
		return
	var rules := _load_rules()
	if rules.is_empty():
		print("RA|!! 读不到 arena/记录/规则包.json（引擎启动时会写一份）")
		get_tree().quit(1)
		return
	_bridge = load("res://arena/ArenaBridge.gd").new()
	_bridge.setup(Stub.new(), rules, 3, 0, "ai", true)
	var lines := _read_lines(mid)
	if lines.is_empty():
		print("RA|!! 记录是空的：%s" % mid)
		get_tree().quit(1)
		return
	var tasks: Array = []
	var chosen := {}
	for ln in lines:
		var o = JSON.parse_string(ln)
		if not (o is Dictionary):
			continue
		var tag := String((o as Dictionary).get("tag", ""))
		var d: Dictionary = (o as Dictionary).get("data", {})
		if tag == "task":
			tasks.append(d)
		elif tag == "chosen":
			chosen[int(d.get("stateSeq", -1))] = d
	print("RA|局 %s｜记录 %d 手｜我方 side=%s" % [mid, tasks.size(), String(tasks[0].get("side", "?")) if not tasks.is_empty() else "?"])
	var n_bad := 0
	var n_skip := 0
	var rep: Array = []
	for i in tasks.size():
		var t: Dictionary = tasks[i]
		var obs: Dictionary = t.get("observation", {})
		var legal: Array = t.get("legalActions", [])
		var cs := int(t.get("stateSeq", -1))
		var c: Dictionary = chosen.get(cs, {})
		if c.is_empty():
			continue
		# ⚠️【顺序 + 取值都必须与引擎逐字一致】`choose()` 是先钉 `_cur_match/_cur_turn` 再进
		#   `_choose_gameplay`，而 `_choose_gameplay` 是**先对账（写台账 `_countered`）再建 sim**。
		#   这里原来有**两处**与引擎不同：
		#   ① `_cur_turn` 取的是 `task.turnCount` —— 但协议的任务体里**根本没有这个字段**
		#      （回合号只在 `observation.turnCount` 里）⇒ 每一手的台账都写成 `|0|`，
		#      于是"某单位在第 2 回合反击过"会被之后**每一回合**都当成"它本回合已反击过" ⇒
		#      凭空撤防、白挨反击（报告里那几条 `?!意外挨打`）。引擎侧取的是 observation，没这毛病。
		#   ② 造预测用的那份 sim 是**台账更新前**建的 ⇒ 引擎侧刚修掉的"白怕一次反击"在这里复现。
		#   两处都是复现器自己的锅，不是引擎行为。
		_bridge._cur_match = String(t.get("matchId", ""))
		_bridge._cur_turn = int(obs.get("turnCount", 0))
		var pre: Dictionary = _bridge._build_sim(obs)
		if pre.is_empty():
			continue
		# ① 先拿这一手去对**上一手**的预测（对账会更新台账）
		var diff: Dictionary = _bridge._diff_prediction(String(t.get("matchId", "")), obs, pre)
		# 台账更新之后再建这一手真正用的 sim（与引擎同序）
		var built: Dictionary = _bridge._build_sim(obs)
		if built.is_empty():
			continue
		var head := "t%s %s %s" % [str(int(obs.get("turnCount", 0))), String(obs.get("phase", "?")),
			String((c.get("chosen", {}) as Dictionary).get("note", ""))]
		# 账本（本回合我们已判明"它反击过了"的敌人）—— 用来判"未见过的挨打"是不是被自己的账误导了
		var ledger: Array = []
		for k in _bridge._countered.keys():
			var ks := String(k)
			if ks.begins_with("%s|%d|" % [String(t.get("matchId", "")), int(obs.get("turnCount", 0))]):
				ledger.append(ks.substr(ks.rfind("|") + 1))
		if not diff.is_empty() and String(diff.get("skip", "")) == "":
			if int(diff.get("n_mine", 0)) > 0:
				n_bad += 1
				rep.append("✗ %s" % head)
				rep.append("   上一手我交的：%s" % String(diff.get("act", "")))
				if String(diff.get("why", "")) != "":
					rep.append("   我的预计：%s" % String(diff.get("why", "")))
				for it in diff.get("items", []):
					rep.append("   [%s] %s·%s：我算 %s → 裁判 %s" % [String((it as Dictionary).get("side", "?")),
						String((it as Dictionary).get("who", "?")), String((it as Dictionary).get("field", "?")),
						String((it as Dictionary).get("want", "?")), String((it as Dictionary).get("got", "?"))])
				if not ledger.is_empty():
					rep.append("   （本手之前，我们已把 %s 记成「本回合反击过」）" % ", ".join(ledger))
				var probe := String(_bridge._pred.get("tgt_probe", ""))
				if probe != "":
					rep.append("   （预测当时被我打的那个：%s）" % probe)
			elif not (diff.get("items", []) as Array).is_empty():
				n_skip += 1
		# ② 再拿这一手生成"给下一手对的预测"
		var start_sim = (built["sim"] as Object).clone()
		var act := {"actionId": String((c.get("chosen", {}) as Dictionary).get("actionId", "")),
			"note": String((c.get("chosen", {}) as Dictionary).get("note", ""))}
		_bridge._pred = _bridge._make_prediction(String(t.get("matchId", "")), obs, legal, built, start_sim, act)
	var head2 := ["局 %s｜记录 %d 手｜我方出错 %d 次｜只有对手/环境侧差异 %d 手" % [mid, tasks.size(), n_bad, n_skip], ""]
	_write_report(mid, head2 + rep)
	print("RA|汇总|我方出错 %d 次｜只有对手/环境侧差异 %d 手｜总手数 %d" % [n_bad, n_skip, tasks.size()])
	print("RA|报告：arena/记录/%s.对账.txt" % mid)
	print("RA|END")
	get_tree().quit(0)


## 报告落文件（UTF-8）：stdout 在 Windows 控制台会乱码，读文件才看得清
func _write_report(mid: String, lines: Array) -> void:
	var p := "%s/%s.对账.txt" % [REC_DIR, mid]
	var f := FileAccess.open(p, FileAccess.WRITE)
	if f == null:
		return
	f.store_string("\n".join(lines))
	f.close()


func _arg(key: String) -> String:
	for a in OS.get_cmdline_user_args():
		var s := String(a)
		if s.begins_with(key):
			return s.substr(key.length())
	return ""


func _latest_match() -> String:
	var d := DirAccess.open(REC_DIR)
	if d == null:
		return ""
	var best := ""
	var best_t := 0
	for f in d.get_files():
		var s := String(f)
		if not s.ends_with(".jsonl"):
			continue
		var t := FileAccess.get_modified_time("%s/%s" % [REC_DIR, s])
		if t > best_t:
			best_t = t
			best = s.substr(0, s.length() - 6)
	return best


func _load_rules() -> Dictionary:
	var p := "%s/规则包.json" % REC_DIR
	if not FileAccess.file_exists(p):
		return {}
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		return {}
	var o = JSON.parse_string(f.get_as_text())
	f.close()
	return o if o is Dictionary else {}


func _read_lines(mid: String) -> Array:
	var p := "%s/%s.jsonl" % [REC_DIR, mid]
	if not FileAccess.file_exists(p):
		return []
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		return []
	var out: Array = []
	while not f.eof_reached():
		var ln := f.get_line()
		if ln.strip_edges() != "":
			out.append(ln)
	f.close()
	return out

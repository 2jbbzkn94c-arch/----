extends Node
## 录像库（全局自动加载）：单机对局的录像落盘 / 列表 / 读取 / 删除。
##
## 【2026-09-27 用户要求】"录像回放功能：可以暂停，可以到上下回合，可以倍速"。
##   录像本体（每半回合一份局面快照 + 招式流水）比较大，**单独存放**：`user://replays/<id>.json`；
##   小份的索引（时间/模式/难度/双方卡组/胜负/回合数）另存一份 `user://replays.cfg`，
##   主菜单的"录像回放"列表只读索引，不必为一屏列表解析整份快照。
##
## 与 `LadderStore` 的分工：那份是**天梯进度**（一局一档、可续打）；这份是**录像**（只读回放），
## 两者互不影响、互不覆盖（录像落盘发生在结算那一刻，天梯存档在每回合开始，路径也不同）。
##
## 清理口径（用户没点名，取保守值）：最多保留 `MAX_KEEP` 份、最新优先，超出的从最旧删起。

const DIR := "user://replays"
const CFG := "user://replays.cfg"
const TMP := "user://replays.cfg.tmp"
const KEY := "replays"
const MAX_KEEP := 30
const SessionScript := preload("res://src/ReplaySession.gd")   # 只为读录像格式版本号（不依赖全局类缓存）

var _idx: Array = []   # 录像索引，最新的在前：{id,ts,mode,diff,player,enemy,win,rounds,frames,steps,dur,ver}

func _ready() -> void:
	_load()

## 落盘一份录像：data = `ReplaySession.end()` 的产物（{meta, frames}）。成功返回 id，失败返回 ""。
func save(data: Dictionary) -> String:
	if data.is_empty():
		return ""
	var m: Dictionary = data.get("meta", {})
	if (data.get("frames", []) as Array).is_empty():
		return ""   # 一个回合都没打完（选人阶段就退了）：没有可回放的内容
	if not DirAccess.dir_exists_absolute(DIR):
		DirAccess.make_dir_recursive_absolute(DIR)
	var id := "rp%d" % Time.get_unix_time_from_system()
	var path := "%s/%s.json" % [DIR, id]
	var txt := JSON.stringify(data)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("录像保存失败（写不进 %s）" % path)
		return ""
	f.store_string(txt)
	f.close()
	# 【2026-09-27】索引里**只留轻量字段**：`deploy_snap`（整份快照）与 `deploy_steps`（逐手明细）
	#   只写进录像文件本体，不塞进 `replays.cfg`（那会让索引膨胀几十倍，列表读它只为列个名）。
	var rec := {
		"id": id, "ts": int(m.get("ts", Time.get_unix_time_from_system())),
		"mode": String(m.get("mode", "对局")), "diff": int(m.get("diff", -1)),
		"player": (m.get("player_deck", []) as Array).duplicate(),
		"enemy": (m.get("enemy_deck", []) as Array).duplicate(),
		"win": bool(m.get("win", false)), "rounds": int(m.get("rounds", 0)),
		"frames": int(m.get("frames", 0)), "steps": int(m.get("steps", 0)),
		"dur": float(m.get("dur", 0.0)), "ver": int(m.get("ver", 0)),
	}
	_idx.push_front(rec)
	_prune()
	_save()
	return id

## 索引列表（最新在前）：主菜单"录像回放"读它。
func list() -> Array:
	return _idx.duplicate(true)

func has_any() -> bool:
	return _idx.size() > 0

## 读一份录像的完整内容（快照 + 流水）。文件缺失/解析失败/版本不认 ⇒ 空字典。
func load_replay(id: String) -> Dictionary:
	var path := "%s/%s.json" % [DIR, id]
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var txt := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(txt)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("录像解析失败：%s" % path)
		return {}
	var d: Dictionary = parsed
	var m: Dictionary = d.get("meta", {})
	if int(m.get("ver", 0)) != int(SessionScript.VER):
		push_warning("录像格式版本不认（文件 %d · 本版 %d）：%s" % [int(m.get("ver", 0)), int(SessionScript.VER), path])
		return {}
	if not d.has("frames") or (d["frames"] as Array).is_empty():
		return {}
	return d

func find(id: String) -> Dictionary:
	for r in _idx:
		if String((r as Dictionary).get("id", "")) == id:
			return (r as Dictionary).duplicate(true)
	return {}

func remove(id: String) -> void:
	var path := "%s/%s.json" % [DIR, id]
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	var keep: Array = []
	for r in _idx:
		if String((r as Dictionary).get("id", "")) != id:
			keep.append(r)
	_idx = keep
	_save()

## 【2026-10-03·用户要求「录像加个一键清空录像列表」】把**全部**录像一次清掉（列表条目 + 磁盘上的 json）。
##   为什么要专门一个函数、而不是在 UI 里循环 `remove()`：那样每删一条都要重写一遍索引文件（N 次落盘）；
##   这里删文件一遍、索引只写一次。⚠️ **不可撤销** ⇒ UI 侧（`Menu._open_replays()` 的那枚「清空」）先弹一次确认。
func clear_all() -> int:
	var n := _idx.size()
	for r in _idx:
		var p := "%s/%s.json" % [DIR, String((r as Dictionary).get("id", ""))]
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))
	# 兜底：索引之外还可能留着孤儿 json（历史版本的异常退出）⇒ 整个目录扫一遍
	if DirAccess.dir_exists_absolute(DIR):
		var d := DirAccess.open(DIR)
		if d != null:
			for f in d.get_files():
				if f.ends_with(".json"):
					DirAccess.remove_absolute(ProjectSettings.globalize_path("%s/%s" % [DIR, f]))
	_idx = []
	_save()
	return n

## 超出 `MAX_KEEP` 的从最旧删起（同时删文件，避免目录里留下孤儿 json）。
func _prune() -> void:
	while _idx.size() > MAX_KEEP:
		var oldest: Dictionary = _idx.pop_back()
		var p := "%s/%s.json" % [DIR, String(oldest.get("id", ""))]
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))

func _save() -> void:
	var f := FileAccess.open(TMP, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify({ KEY: _idx }))
	f.close()
	DirAccess.rename_absolute(ProjectSettings.globalize_path(TMP), ProjectSettings.globalize_path(CFG))

func _load() -> void:
	_idx = []
	if not FileAccess.file_exists(CFG):
		return
	var f := FileAccess.open(CFG, FileAccess.READ)
	if f == null:
		return
	var txt := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(txt)
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var arr = (parsed as Dictionary).get(KEY, [])
	if arr is Array:
		_idx = arr

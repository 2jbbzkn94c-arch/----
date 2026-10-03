extends Node
## 【2026-10-03 一次性探针】天梯"回合开始存档"的耗时拆账（用户报「天梯模式点进入游戏 / 点结束回合明显卡顿」）。
##   嫌疑链 = `Battle._ladder_autosave()` → `_ladder_snapshot()`（`_snap_take()` ＋ **`_rec_pack()` 把整局录像深拷贝**）
##   → `LadderStore.save_snapshot()` → `_save()`：`ConfigFile.set_value` ＋ `cfg.save(临时文件)` ＋ 删旧 ＋ 改名。
##   本探针**合成**不同规模的录像包，逐档量三段：① 深拷贝（= `_rec_pack()` 的成本）② 写盘（= `save_snapshot` 的成本）
##   ③ 读回（= 进入游戏续档的成本）。
##   ⚠️ **只写沙箱**：跑它的进程 APPDATA 被指到临时目录 ⇒ `user://` 也在那里；而且用一个假模式键
##      （`probe_ladder_cost`）⇒ **绝不碰真实天梯档**。跑完 `abandon()` 清掉假 run。
const MODE := "probe_ladder_cost"
const UNIT_N := 6          # 场上单位数（双方各 3）
const STEP_N := 4          # 每帧的招式流水条数
const VAR_N := 8           # 每个单位的"英雄脚本成员变量"条数（拍脑袋贴近真实）

func _ready() -> void:
	get_tree().create_timer(120.0).timeout.connect(func() -> void:
		print("PROBE|WATCHDOG|120s"); get_tree().quit(2))
	_run.call_deferred()

func _run() -> void:
	print("PROBE|保存路径（沙箱）= %s" % ProjectSettings.globalize_path("user://ladder.cfg"))
	LadderStore.begin(MODE)          # 建一个假 run（写在沙箱里）
	print("PROBE|%s | 帧数 | 深拷贝 ms | 写盘 ms | 读回 ms | 包体积 KB | 读回帧数" % "档位")
	for n in [10, 40, 120, 300]:
		var rec := _fake_rec(n)
		var t0 := Time.get_ticks_usec()
		var copy: Dictionary = rec.duplicate(true)          # ① _rec_pack() 干的事
		var t1 := Time.get_ticks_usec()
		LadderStore.save_snapshot({ "ver": 9, "side": 0, "units": _fake_units(), "rec": copy }, MODE)   # ② 写盘
		var t2 := Time.get_ticks_usec()
		var back: Dictionary = LadderStore.snapshot(MODE)    # ③ 读回
		var t3 := Time.get_ticks_usec()
		var got := 0
		if back.has("rec"):
			got = int(((back["rec"] as Dictionary).get("frames", []) as Array).size())
		print("PROBE|%-12s n=%-4d 深拷贝 %6.2f ms · 写盘 %6.2f ms · 读回 %6.2f ms · %5d KB · 读回 %d 帧" % [
			"档", n, (t1 - t0) / 1000.0, (t2 - t1) / 1000.0, (t3 - t2) / 1000.0, _kb(copy), got])
	# 再量一次"同一档连写两次"（半回合一次 ⇒ 一回合两次的实际节奏）
	var big := _fake_rec(120)
	LadderStore.save_snapshot({ "ver": 9, "side": 0, "rec": big }, MODE)
	var t4 := Time.get_ticks_usec()
	for i in 3:
		LadderStore.save_snapshot({ "ver": 9, "side": 0, "rec": big }, MODE)
	var t5 := Time.get_ticks_usec()
	print("PROBE|连写 3 次（n=120）合计 %.2f ms ⇒ 单次约 %.2f ms" % [(t5 - t4) / 1000.0, (t5 - t4) / 3000.0])
	LadderStore.abandon(MODE)        # 清掉假 run（沙箱）
	print("PROBE|END")
	get_tree().quit(0)

## 合成一帧（贴近真实快照的形状：units/occ/graves/buff/steps ＋ 英雄脚本变量）
func _fake_frame(i: int) -> Dictionary:
	return {
		"side": i % 2, "round": i / 2 + 1, "ver": 9,
		"units": _fake_units(),
		"occ": _fake_occ(),
		"graves": {}, "obstacles": { "3,4": true, "3,5": true }, "bombs": {}, "buff": {},
		"steps": _fake_steps(),
	}

func _fake_units() -> Array:
	var out: Array = []
	for k in UNIT_N:
		var vars := {}
		for v in VAR_N:
			vars["svar_%d" % v] = [k, v, "text_%d_%d" % [k, v], Vector2i(k, v)]
		out.append({
			"hero": "hero_%02d" % (k + 1), "fn": k % 2, "cell": Vector2i(k % 5, k % 7),
			"hp": 18 - k, "max_hp": 20, "atk": 3, "eatk": 3, "move": 2, "emove": 2,
			"atk_range": 1, "atk_type": 0, "skills": ["SWIFT"], "name": "单位%d" % k,
			"statuses": { "SOLID": 1, "POISON": 2 }, "svar": vars,
		})
	return out

func _fake_occ() -> Dictionary:
	var out: Dictionary = {}
	for k in UNIT_N:
		out["%d,%d" % [k % 5, k % 7]] = k
	return out

func _fake_steps() -> Array:
	var out: Array = []
	for s in STEP_N:
		out.append({ "idx": s, "kind": "move", "cell": Vector2i(s, s + 1), "act": "atk", "target": s,
			"ms": 320 + s, "fp": "abcdef%02d" % s, "extra": "x".repeat(60) })
	return out

func _fake_rec(n: int) -> Dictionary:
	var frames: Array = []
	for i in n:
		frames.append(_fake_frame(i))
	return { "meta": { "ts": 1790000000, "frames": n, "steps": n * STEP_N,
		"player_deck": ["hero_01", "hero_02", "hero_03"], "enemy_deck": ["hero_04", "hero_05", "hero_06"],
		"deploy_steps": [] }, "frames": frames }

func _kb(d: Dictionary) -> int:
	return JSON.stringify(d).length() / 1024

extends Node
## 【2026-10-03·一次性探针·只读】核对 5×7 盘上"界面 (2,4)"这一格的六个邻格、以及三个玩家单位到这些格的六角距离。
##   起因：用户看 AI 日志「下回合在这一格会挨 5 伤（圣诞老人2＋巨剑2＋毒蛇淑女1）」提出
##   「白游侠旁边是障碍啊，能打到就一格」—— 用引擎自己的 `HexGrid` 把这一格的几何摊开，
##   再对一遍"哪些格能开火 / 谁走得到"。纯读数，不改任何东西。
##   盘面（界面口径）：白游侠 (2,4) · 荆棘树人(嘲讽) (3,4)
##     障碍 = 本回合开始时 (1,4)(1,5)(5,4)(5,5)；AI 这回合把 (1,5)（日志写 0 基 (0,4)）与 (5,4) 敲掉了
##     ⇒ 末态只剩 (1,4)(5,5)。**两张表都打**（"开火位数"与"敲墙"的关系就在这两张表的差里）。
##   玩家：圣诞老人 (5,7) mv3 · 巨剑 (3,7) mv2 · 毒蛇淑女 (1,7) mv2

const BASE := Vector2i(1, 3)      # 界面 (2,4) − 1
const TAUNT := Vector2i(2, 3)     # 界面 (3,4) − 1（荆棘树人）
const OBST_START := [Vector2i(0, 3), Vector2i(0, 4), Vector2i(4, 3), Vector2i(4, 4)]   # 界面 (1,4)(1,5)(5,4)(5,5)
const OBST_END := [Vector2i(0, 3), Vector2i(4, 4)]                                    # 界面 (1,4)(5,5)
const FOES := [
	["圣诞老人", Vector2i(4, 6), 3],   # 界面 (5,7) − 1
	["巨剑", Vector2i(2, 6), 2],       # 界面 (3,7) − 1
	["毒蛇淑女", Vector2i(0, 6), 2],   # 界面 (1,7) − 1
]

func _ready() -> void:
	var g := HexGrid.new(5, 7)
	print("HEX|盘 = %d 列 × %d 行（0 基；界面 = +1）" % [g.width, g.height])
	print("HEX|白游侠 界面(2,4) → 0 基 %s ｜ 荆棘树人(嘲讽) 界面(3,4) → 0 基 %s" % [str(BASE), str(TAUNT)])
	_table(g, "本回合开始（障碍含 (1,4)(1,5)(5,4)(5,5)）", OBST_START)
	_table(g, "末态（(1,5) 与 (5,4) 已被自己的单位敲掉）", OBST_END)
	print("HEX|END")
	get_tree().quit(0)

func _table(g: HexGrid, title: String, obst: Array) -> void:
	print("HEX|—— %s ——" % title)
	var fires: Array[Vector2i] = []
	for n in g.neighbors(BASE):
		var tag := ""
		if obst.has(n):
			tag = " ← 障碍（不能站）"
		elif n == TAUNT:
			tag = " ← 荆棘树人自己站着"
		else:
			var dt := g.distance(n, TAUNT)
			if dt <= 1:
				tag = " ← 空，但离荆棘树人 %d 格 ⇒ 嘲讽门拦下" % dt
			else:
				tag = " ← **开火位**（离荆棘树人 %d 格 ⇒ 嘲讽门放行）" % dt
				fires.append(n)
		print("HEX|   界面(%d,%d)%s" % [n.x + 1, n.y + 1, tag])
	print("HEX|   ⇒ 开火位 %d 个：%s" % [fires.size(), _cells_txt(fires)])
	for f in FOES:
		var nm := String(f[0])
		var c: Vector2i = f[1]
		var mv := int(f[2])
		var rows: Array[String] = []
		for n in fires:
			var d := g.distance(c, n)
			rows.append("界面(%d,%d) 距%d %s" % [n.x + 1, n.y + 1, d, "✓走得到" if d <= mv else "✗超移动力"])
		print("HEX|   %s（mv%d）：%s" % [nm, mv, (" ｜ ".join(rows)) if rows.size() > 0 else "（没有开火位）"])

func _cells_txt(arr: Array) -> String:
	var out: Array[String] = []
	for c in arr:
		out.append("界面(%d,%d)" % [c.x + 1, c.y + 1])
	return "、".join(out) if out.size() > 0 else "—"

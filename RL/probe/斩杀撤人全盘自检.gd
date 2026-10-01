extends Node
## 【2026-09-29 一次性探针·只读·用户点名要求】**「主动撤人把对面最后一个人斩杀」全盘枚举**
##   用户原话：「你自己能不能跑一下测试。把所有可以主动撤人把对方最后一个人斩杀的情况都跑一下。
##   哪些没有斩杀你自己修一下啊，我就没成功过一次」
##
## 做法：每条局面都在**真 Battle** 上摆盘（棋盘 5×7：x 0..4、y 0..6；AI 出生格 =
## (1,0)(0,1)(2,1)(3,0)(4,1)，玩家出生格在 y=6），然后：
##   ① `_ai_finish_withdraw_pick()` 看它**该不该撤**（期望"撤"的局面：`_finish_withdraw_target != null`）；
##   ② 该撤的再 `await _ai_finish_withdraw_apply()`，跑完"撤下 → 替补落位 → 补那一手"，
##      检查**目标是不是真被收掉**（`目标还在=false`）。
## 每条打一行 `T|名字|期望|实际|PASS/FAIL`，末尾 `T|END` + 汇总。
##
## ⚠️ 探针自己的三个坑（都已经写进 helper，别再踩）：① 挪单位必须同步 `occupancy`；
##    ② `Main.tscn` 会自己摆上双方首发 ⇒ 先清场；③ 格子别越界（5×7）。

var battle: Battle
var _pass := 0
var _fail := 0

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	# ① 相邻换位（近战替补）
	await _case("S1 目标相邻·近战替补", true, Vector2i(2, 3), 3, Vector2i(2, 2),
			["hero_07", "hero_16", "hero_18"], 2, 0, false, false)
	# ② 目标在中场（出生区走+打够得到）
	await _case("S2 目标中场·出生区够得到", true, Vector2i(2, 3), 3, Vector2i(0, 0),
			["hero_40"], 2, 0, false, false)
	# ③ 目标缩在玩家深处，但**前方有本方墓碑格**
	await _case("S3 目标深处·有前方墓碑格", true, Vector2i(2, 6), 3, Vector2i(0, 0),
			["hero_07"], 2, 0, false, true)
	# ④ 目标缩在玩家深处、没有墓碑、也没有相邻单位（替补走+射刚好够）
	await _case("S4 目标深处·只靠走+射够到", true, Vector2i(2, 6), 3, Vector2i(0, 0),
			["hero_07"], 2, 0, false, false)
	# ⑤ 目标深处 + 替补腿短（移动2/射程1 ⇒ 够不到）⇒ **不该撤**（撤了也白撤）
	await _case("S5 目标太远·替补够不到（期望不撤）", false, Vector2i(2, 6), 3, Vector2i(0, 0),
			["hero_11"], 2, 0, false, false)
	# ⑥ 【2026-09-29 晚·口径放宽后】**对面已死 2 个 + 场上还剩 2 个、其中一个 3 血能被替补一刀收**
	#   ⇒ 该撤 + 真收掉（打死他场上任何一个都到判负线 3 ⇒ 直接赢，不必非等到"只剩 1 个"）。
	await _case("S6 对面还剩2人·其中一个能收（期望撤+收掉）", true, Vector2i(2, 3), 3, Vector2i(2, 2),
			["hero_07"], 2, 0, false, false, 1)
	# ⑦ 我方已死 2 个 ⇒ 不该撤（再撤就是丢第 3 个判负）
	await _case("S7 我方已死2（期望不撤）", false, Vector2i(2, 3), 3, Vector2i(2, 2),
			["hero_07"], 2, 2, false, false)
	# ⑧ ③ 门：我方有人**站着就能一击打死**它 ⇒ 不该撤（直接普攻收）
	await _case("S8 有人站着能一发收（期望不撤）", false, Vector2i(2, 3), 1, Vector2i(2, 2),
			["hero_07"], 2, 0, false, false)
	# ⑨ ③ 门：我方有个单位**站着就够得到**它（紧邻），但**它这一刀打不死**（塔盾 1 攻 vs 目标 5 血）
	#   ⇒ 仍该撤：靠替补（红帽 5 攻）一刀收掉。这一条才是"够得到但打不死"的正确测法。
	await _case("S9 够得到但打不死（期望仍撤·靠替补收）", true, Vector2i(2, 3), 5, Vector2i(2, 2),
			["hero_40", "hero_18", "hero_07"], 2, 0, false, false)
	# ⑩ 远程替补落到被撤下那一格（贴身 ⇒ 射程/伤害被压）⇒ 走一步再打仍应收掉
	await _case("S10 远程替补贴脸（走一步再打）", true, Vector2i(2, 3), 3, Vector2i(2, 2),
			["hero_07"], 2, 0, true, false)
	# ⑪ 目标带 [圣盾] ⇒ 一刀收不掉 ⇒ 不该撤
	await _case("S11 目标带圣盾（期望不撤）", false, Vector2i(2, 3), 3, Vector2i(2, 2),
			["hero_07"], 2, 0, false, false, 0, true)
	# ⑫ 已有一个待补名额没落位 ⇒ 不该撤（别把两个挤在一拍里）
	await _case("S12 已有待补名额（期望不撤）", false, Vector2i(2, 3), 3, Vector2i(2, 2),
			["hero_07"], 2, 0, false, false, 0, false, 1)
	# ⑬ 配方档：没有预设替补席、走**动态替补池** ⇒ 仍该撤 + 收掉
	await _case("S13 配方档·无预设席（动态池）", true, Vector2i(2, 3), 3, Vector2i(2, 2),
			[], 2, 0, false, false, 0, false, 0, true)
	# ⑭ 【用户那张图的现场】对面已死 2 个、场上还剩 2 个，其中一个**只有 2 血**、我方两个单位都够不到
	#   它（都在 (4,5)/(4,6) 那一角）⇒ 该撤 + 靠替补从出生区走过去一刀收掉。
	await _case("S14 对手2血·我方够不到（期望撤+收掉）", true, Vector2i(2, 2), 2, Vector2i(4, 5),
			["hero_40"], 2, 0, false, false, 1)
	# ⑮ 放宽之后**不能**变成"见谁都撤"：对面 2 个、谁都收不掉（目标 20 血、替补影丸只有 1 攻）⇒ 不撤
	await _case("S15 对手都收不掉（期望不撤）", false, Vector2i(2, 3), 20, Vector2i(2, 2),
			["hero_07"], 2, 0, false, false, 1)
	# ⑯ 对面只死 1 个（**没到赛点**）⇒ 不撤（撤下 = 白送自己一个阵亡）
	await _case("S16 对面只死1个·非赛点（期望不撤）", false, Vector2i(2, 3), 2, Vector2i(2, 2),
			["hero_40"], 1, 0, false, false, 1)
	# ⑰ 对面已死 2 个、场上 2 个，但**我方站着就能一发收掉**其中一个（1 血、贴着 (4,6)）
	#   ⇒ 不撤（计划自己就会赢，没必要送一个阵亡）
	await _case("S17 本回合有人能一发收（期望不撤）", false, Vector2i(2, 3), 20, Vector2i(2, 2),
			["hero_07"], 2, 0, false, false, 1, false, 0, false, 1, Vector2i(4, 5))
	# ⑱ **无死限局（自由部署测试）不能跟着放宽**：那边判"对面还有没有人可上"，打死一个不算赢
	#   ⇒ 对面还有 2 个时不撤（放宽只对死限局生效）
	await _case("S18 无死限局·对面还剩2个（期望不撤）", false, Vector2i(2, 3), 2, Vector2i(2, 2),
			["hero_40"], 2, 0, false, false, 1, false, 0, false, 0, Vector2i(-99, -99), true)
	# ⑲ 无死限局 + 对面场上就剩这 1 个（且他没牌可上了）⇒ 打死他就是赢 ⇒ 照旧撤 + 收掉
	await _case("S19 无死限局·对面只剩1个（期望撤+收掉）", true, Vector2i(2, 3), 2, Vector2i(2, 2),
			["hero_40"], 2, 0, false, false, 0, false, 0, false, 0, Vector2i(-99, -99), true)
	# ⑳ 【用户 2026-09-29 晚的现场】"**本回合被打死了 2 个，剩最后一个**"：判定挪到计划回放**之后**跑，
	#   此刻我方该出手的都出手完了（`attacked_this_turn = true`）、对面只剩这 1 个 ⇒ 该撤 + 一刀收掉。
	#   （①②两道门这时读到的 `player_dead` 才是这一回合打完的真实数字。）
	await _case("S20 本回合刚打死两个·只剩最后1个（期望撤+收掉）", true, Vector2i(2, 3), 3, Vector2i(2, 2),
			["hero_40"], 2, 0, false, false, 0, false, 0, false, 0, Vector2i(-99, -99), false, true)
	# ---- 【2026-10-01·用户口径】"不是每回合都试着斩杀"的那道门槛（`_finish_hp_gate_ok()`）----
	#   用户订正口径（三档都是**小于等于**）：「0 名是小于等于 9 · 1 名是小于等于 6」；
	#   加上原来的「已死 2 人 ⇒ 单个最低血 ≤ 8」= 前 `3 − player_dead` 个之和 ≤ `[9, 6, 9]`。
	# S21 对面已死 2 名、场上这 1 个 19 血（> 9）⇒ **门槛拦住**，不撤。
	await _case("S21 已死2名·单个血19（>9）⇒ 门槛拦住", false, Vector2i(2, 3), 19, Vector2i(2, 2),
			["hero_40"], 2, 0, false, false)
	# S22 对面已死 2 名、场上这 1 个 8 血（= 用户口径的上界 ≤8，也 ≤9）⇒ 门槛放行，但 8 血红帽（5 攻）收不掉
	#   ⇒ 仍不撤（**这一条的期望是"不撤"**：它验的是"门槛不再是拦路的那道门"）。
	await _case("S22 已死2名·单个血8（门槛放行，但5攻收不掉）", false, Vector2i(2, 3), 8, Vector2i(2, 2),
			["hero_40"], 2, 0, false, false)
	# S23 对面已死 1 名、场上 2 个（2 血 + 满血 33）⇒ 两个最低之和 = 35 > 6 ⇒ 门槛拦住。
	await _case("S23 已死1名·两个最低之和35（>6）⇒ 门槛拦住", false, Vector2i(2, 3), 2, Vector2i(2, 2),
			["hero_40"], 1, 0, false, false, 1)
	# S24 对面已死 1 名、场上 2 个都残（2 + 3 = 5）⇒ 门槛放行 ⇒ 撤 + 收掉。
	# ⚠️ 【2026-10-01·T95 那道"能不能赢"的硬门之后】这两块盘面**确实收不掉这一局**：
	#   玩家已死 1 名、场上 3 个（血 2 / 15 / 15）⇒ 要赢还得收 **2** 个，可只有血 2 那个能一刀收
	#   ⇒ 硬门拦住 ⇒ **不撤**（血线门槛本来放行）。期望随之改成"不撤"。
	await _case("S24 已死1名·和=5（门槛放行，但收不掉这一局）⇒ 硬门拦住不撤", false, Vector2i(2, 3), 2, Vector2i(2, 2),
			["hero_40"], 1, 0, false, false, 1, false, 0, false, 3)
	# S25 **边界**：已死 1 名、两个最低之和正好 = 6 ⇒ 按"小于等于"应当放行 ⇒ 撤 + 收掉（2 血目标红帽收得掉）。
	await _case("S25 已死1名·和=6（边界·门槛放行，但同样收不掉）⇒ 硬门拦住不撤", false, Vector2i(2, 3), 2, Vector2i(2, 2),
			["hero_40"], 1, 0, false, false, 1, false, 0, false, 4)
	# S26 **边界**：已死 0 名、场上 3 个（2 + 4 + 4 = 10 > 9）⇒ 门槛拦住。
	#   ⚠️ 探针的 `extra_hp` 把"额外对手"**统一压成同一个血**（`hero_05` 只有这一个旋钮）⇒ 想要
	#      "2+3+4 = 正好 9"这种组合做不到；这里就取 2+4+4 = 10 当"刚过界"的样本。
	# S26 已死 0 名、三个之和 2 + 9 + 9 = 20 > 18（新界 = 9 × 本回合可撤 2 次）⇒ 门槛拦住。
	#   ⚠️ 原来这里用的是 extra_hp=4（2+4+4=10 > 旧的 9）—— 门槛按可撤次数放大到 18 之后，10 已经**不再越界**。
	await _case("S26 已死0名·三个最低之和=20（>18）⇒ 门槛拦住", false, Vector2i(2, 3), 2, Vector2i(2, 2),
			["hero_40"], 0, 0, false, false, 2, false, 0, false, 9)
	# S27 已死 0 名、三个都残（2 + 3 + 3 = 8 ≤ 9）⇒ 门槛放行 ⇒ 撤 + 收掉 2 血那个。
	# ⚠️ 【2026-10-01·新规则】"已死 0 名 ⇒ 要收 3 个、本回合最多撤 2 次 ⇒ 收不掉这一局 ⇒ 不撤"
	#   ⇒ 本用例的期望从"撤+收掉"改成"不撤"（门槛本来放行，是被那道**硬门**拦住的）。
	await _case("S27 已死0名·和=8（门槛放行，但收不掉这一局）⇒ 硬门拦住不撤", false, Vector2i(2, 3), 2, Vector2i(2, 2),
			["hero_40"], 0, 0, false, false, 2, false, 0, false, 3)
	# ㉘ 【2026-10-01·用户实机「沉默术士只有 7 血，AI 没死人。随便替补两个就能斩杀，但没有」】**两刀合力**：
	#    目标 7 血 > 名单里最高的那一击（太阳斩 6 攻、影丸 5 攻）⇒ **一个替补一刀收不掉**，
	#    改前 ④ 会判"没人做得到" ⇒ pick 返回空 ⇒ **一次都不撤**（用户那局就是这么走的）。
	#    改后：第一刀（削得最多的那位）被放行，剩下的血交给第二轮再撤一个收 ⇒ 期望"决定撤 + 目标没死但掉血"。
	# S29 【2026-10-01·用户「这 9 血线的要求…现在 AI 可以替补两个人」】**门槛随"本回合可撤几次"放大**的边界：
	#   已死 0 名 ⇒ 自己一个没死 ⇒ 本回合可撤 2 次 ⇒ 界 = 9 × 2 = 18；这里 2 + 8 + 8 = 18（正好 ≤）⇒ 放行、撤+收掉。
	await _case("S29 已死0名·和=18（=9×2 边界）⇒ 同样被硬门拦住不撤", false, Vector2i(2, 3), 2, Vector2i(2, 2),
			["hero_40"], 0, 0, false, false, 2, false, 0, false, 8)
	# S30 倍率**不是死的 2**：我方（AI）已死 1 名 ⇒ 本回合只剩 1 次可撤（第 2 次踩判负线）⇒ 界回到 9，
	#   同样的 2 + 8 + 8 = 18 就该被拦住（与 ①b 同一把尺子：①b 放行几次，这里放大几倍）。
	await _case("S30 已死0名但我方已死1名·和=18 ⇒ 拦住（硬门先拦）", false, Vector2i(2, 3), 2, Vector2i(2, 2),
			["hero_40"], 0, 1, false, false, 2, false, 0, false, 8)
	print("T|S28准备|hero_29 攻=%d｜hero_07 攻=%d" % [
		int(DataRegistry.get_hero("hero_29").atk), int(DataRegistry.get_hero("hero_07").atk)])
	# S32 【2026-10-01·用户实机「替补出来烛火点位不对，走不到他想走的2，4」「替补到了2,1，就被队友挡住了」】
	#   **复刻"路被队友堵住"这个原始报障**：烛火（近战、移动 3）落在出生区 (1,0)，想去 (1,3) 开火，
	#   而队友 hero_12 站在 (1,1) —— 正是那条路的下一格。改前 ④ 用**直线格距**判"走得到"（3 格 ≤ 移动 3）
	#   ⇒ 认下 (1,0) 这个落点，替补实际走到一半被队友挡住、打空（决定撤了却没斩掉 = 白撤）。
	#   改后 ④ 先算斩杀格、再按**真实路网**判落点能不能走进斩杀格 ⇒ 应当改挑 (0,1) 那类能绕过去的落点。
	print("T|S32准备|hero_17 烛火 移动=%d 射程=%d" % [
		DataRegistry.spawn_move(DataRegistry.get_hero("hero_17")),
		DataRegistry.spawn_attack_range(DataRegistry.get_hero("hero_17"))])
	await _case("S32 烛火·去路被队友堵住（期望撤+收掉）", true, Vector2i(1, 4), 3, Vector2i(2, 2),
			["hero_17"], 2, 0, false, false, 0, false, 0, false, 0, Vector2i(-99, -99), false, false, false,
			Vector2i(1, 1))
	# S33 【2026-10-01·用户「你检测那个点位可以斩杀对方的时候，**要把 AI 自己站的点位也算进去**：
	#   如果只有站在 AI 站的点位可以斩杀玩家，那就需要**把那个点位的英雄给撤下**，然后找个**真正能走到
	#   那个点位**的出生点替补」】
	#   摆法：目标 (2,3) 只有 3 血，**我方巨剑就站在它旁边那一格 (2,2)** —— 那一格正是"走过去一刀收掉"的
	#   唯一落点（巨剑占了，替补就没法站）。巨剑本回合**已经出手**（`all_acted`，所以 ②b"有人站着能一发收"
	#   那道门会跳过它）⇒ 要收尾只能**把它撤下腾出那一格**，让替补从出生点落位、按真实路网走过去再开火。
	#   ⚠️ 另一个候选（塔盾，摆在 (4,6) 离得远）先被试，判不出来才会轮到占位的巨剑。
	await _case("S33 斩杀位被我方占着（撤掉占位的人、替补走过去收）", true, Vector2i(2, 3), 3, Vector2i(4, 6),
			["hero_40"], 2, 0, false, false, 0, false, 0, false, 0, Vector2i(-99, -99), false, true, false,
			Vector2i(2, 2))
	# S34 【2026-10-01 晚·用户「他已经替补出一个杀了第一个英雄，只能再替补 1 个，他怎么又想替补 2 个人
	#   把这个 7 血杀掉？…违背了我之前说的，不能斩杀玩家累计 3 人就不能主动撤人的原则」】
	#   **赢面账**：玩家已死 1 名 ⇒ 这一轮必须收掉 **2** 个才赢；本回合能撤 2 次。
	#   盘面：白游侠 3 血（**单刀**可收 = 1 个名额）＋ 傀儡师 6 血（单刀谁都收不掉、**只能两刀合力**
	#   = 2 个名额）⇒ 两者是**替代**关系：收掉前者之后只剩 1 个名额，合力做不了 ⇒ 这一轮最多收 1 个
	#   ⇒ 1 + 1 = 2 < 3 ⇒ **不该撤**（撤了就是白送自己一个阵亡，还把下回合名额压成 1）。
	#   老账把"合力"也按 1 个名额记 ⇒ 算成能收 2 个 ⇒ 放行 ⇒ 白撤。期望：**不撤**。
	await _case("S34 只能收1个却要收2个（合力要花2个名额）⇒ 不撤", false, Vector2i(2, 3), 3, Vector2i(4, 6),
			["hero_07", "hero_17"], 1, 0, false, false, 1, false, 0, false, 6, Vector2i(2, 5), false, false, false)
	# S35 【2026-10-01 晚·用户「11 血的红帽，你从高攻往下排，找一个 6 攻、1 个 5 攻，不就收掉了吗？
	#   为什么第一刀限定死了长剑？」】**登场 +攻 两把尺子不同源**：搜索侧 `_sim_spawn_sub()` 给太阳斩
	#   `eatk += 3`（登场那一刀 3+3 = 6），而 ④ 体检用的 `_sub_probe_unit()` 没给 ⇒ 模拟里太阳斩只有 3 攻
	#   ⇒ 「太阳斩 6 + 影丸 5 = 11」这种合力被判成「第一刀削 3 ⇒ 第二刀没人做得到」。
	#   摆法：目标 11 血（玩家已死 2 名 ⇒ 这一轮再收 1 个就赢，本回合能撤 2 次）；席 = 太阳斩 + 影丸。
	#   期望：**决定撤**，且第一刀削掉一部分（合力要两轮，本探针只跑一轮 ⇒ 用 `expect_cut` 判"撤了且削到了"）。
	await _case("S35 11血目标·太阳斩(6)+影丸(5)合力（改前判成收不掉）", false, Vector2i(2, 3), 11, Vector2i(2, 2),
			["hero_29", "hero_07"], 2, 0, false, false, 0, false, 0, false, 0, Vector2i(-99, -99), false, false, true)
	# S36 【2026-10-01 晚·用户「**坠炮手只有 3 攻，为什么说可以收掉 4 血的红帽**」】
	#   **"被贴身"缓存污染探针的攻**：④ 的斩杀格是**逐格扫**的，扫之前会 `_sim_refresh_pins()`；
	#   而探针单位 `pin_init = false` ⇒ `pin_buffs` 按**第一格**反推（`eatk − base_atk`，被贴身时 base=1）
	#   ⇒ 只要第一格是贴身格，`pin_buffs` 就被记成 `atk − 1` ⇒ 之后每一格都按 `atk + (atk−1)` 算
	#   （3 攻 → 5 攻）。摆法：**玩家多一个人站在 (1,0)**（扫描的第一格 (0,0) 与它相邻 ⇒ 先被"贴身"），
	#   目标 5 血、席只有坠炮手（3 攻）⇒ **正确结论 = 收不掉（不该撤）**；污染时会被算成 5 攻 ⇒ 误判能收。
	await _case("S36 贴身缓存不该污染探针攻（3攻的坠炮手收不掉5血）⇒ 不撤", false, Vector2i(2, 3), 5, Vector2i(2, 2),
			["hero_45"], 2, 0, false, false, 1, false, 0, false, 0, Vector2i(1, 0), false, false, false)
	# S37 【2026-10-01 晚·用户「为什么**又**出现替补一个人，收掉玩家 1 个英雄后，剩下一个英雄没收？」】
	#   **两个名额 ≠ 两杀**：还要**两个不同的替补**。摆法：玩家已死 1 名（这一轮要收 2 个才赢）、
	#   我方 0 阵亡 ⇒ 能撤 2 次；场上两个目标（5 血 + 6 血）**都只有太阳斩能一刀收**（席里只放太阳斩）
	#   ⇒ 正确结论 = 只能收 1 个 ⇒ `1 + 1 = 2 < 3` ⇒ **不撤**（老账把两个目标各记一次"能收" ⇒ 算成 2 ⇒ 放行 ⇒ 白撤）。
	await _case("S37 两个目标只有同一个替补能收（两个名额≠两杀）⇒ 不撤", false, Vector2i(2, 3), 5, Vector2i(2, 2),
			["hero_29"], 1, 0, false, false, 1, false, 0, false, 6, Vector2i(1, 4), false, false, false)
	# S38 【2026-10-01 晚③·用户「他可以用太阳斩去收风语者，然后**很多英雄都能斩杀红帽**，你觉得呢」】
	#   **"留人"**：目标 A（5 血，能收它的替补很多）＋ 目标 B（6 血，**只有太阳斩**能收）。
	#   ④ 给 A 挑的是"够格的人里面板攻最低的" = 太阳斩 ⇒ 若照它打，太阳斩就被用掉、B 收不掉（S37 那种白撤）。
	#   正确做法：**这一刀改用影丸收 A，把太阳斩留给 B** ⇒ 两个名额 = 两杀 ⇒ 该撤 ✓。
	#   期望：**决定撤**，且第一轮就把 A 收掉（影丸 5 伤 ≥ A 的 5 血 ⇒ 这一轮真的收掉一个；
	#   本探针只跑一轮 ⇒ 用 `expect_kill`；第二个目标留给"下一轮换太阳斩"）。
	await _case("S38 把'只有它能收'的太阳斩留给另一个目标（改用影丸收A）⇒ 撤+收掉A", true, Vector2i(2, 3), 5, Vector2i(2, 2),
			["hero_29", "hero_07"], 1, 0, false, false, 1, false, 0, false, 6, Vector2i(1, 4), false, false, false)
	# S31 【2026-10-01·用户报「AI 已经死了 1 个了，他主动替补上来一个人，没有斩杀」】**同一块盘面、只把我方阵亡数改成 1**：
	#   本回合只能撤 1 次（第 2 次踩判负线）⇒ "两刀合力"根本不成立 ⇒ ④ 只该找"一刀收掉"的方案，
	#   而 7 血 > 名单里最高的那一击（太阳斩 6 / 影丸 5）⇒ **不撤**。
	#   改前：照样认"削 6 + 收 3"的假方案 ⇒ 白撤一个（用户实机日志就是这句：第一刀打完，
	#   第二轮被 ①b 拦住「不撤：我方已阵亡 2 名，再撤就是丢第 3 个」）。
	await _case("S31 我方已死1名·7血目标（只能撤1次 ⇒ 合力不成立 ⇒ 不撤）", false, Vector2i(2, 3), 7, Vector2i(2, 2),
			["hero_29", "hero_07"], 0, 1, false, false, 0, false, 0, false, 0, Vector2i(-99, -99), false, false, false)
	# ⚠️ 【2026-10-01·新规则】`pdead = 0` ⇒ 硬门拦（要收 3 个、最多撤 2 次）⇒ 改成"不撤"。
	#   ⚠️ "两刀合力"的**真正**适用场景是 `pdead = 1`（要收 2 个、得能撤 2 次）—— 那个场景本探针**没有覆盖**
	#   （它要在同一块盘面上摆两个残血目标 + 验证两轮各收一个，属于另一支）。
	await _case("S28 两刀合力盘面·已死0名 ⇒ 同样被硬门拦住不撤", false, Vector2i(2, 3), 7, Vector2i(2, 2),
			["hero_29", "hero_07"], 0, 0, false, false, 0, false, 0, false, 0, Vector2i(-99, -99), false, false, false)
	print("T|END|PASS=%d FAIL=%d" % [_pass, _fail])
	get_tree().quit(0)

## 一条局面。[with_grave] = 在目标前一格立一座本方墓碑；[ranged] = 替补席换成远程影丸；
## [target_shield] = 目标带圣盾；[pending] = 预置待补名额；[extra_foe] = 玩家场上额外站几个人；
## [dynamic] = 走配方档（无预设席、动态替补池）；
## 【2026-09-29 晚追加】[extra_hp] > 0 = 把这些"额外的对手"血量压到这么多（0 = 满血）；
## [extra_cell] 给定时，第 1 个额外对手摆在这一格（默认 (0,6)、(0,5)…）。
## 【2026-10-01 追加】[block_cell] 给定时，把**我方第二个人**（hero_12）摆在这一格 ——
##   用来复刻用户那句「替补到了 2,1，就被队友挡住了」：队友站在替补要走的那条路上。
## ⚠️ 口径已于 2026-09-29 晚放宽：**对面已死 2 个 ⇒ 打死他场上任何一个都算赢**，所以"场上还剩几个"
##   不再是拦门的条件（判负线是累计 3 名阵亡）。
func _case(nm: String, expect_kill: bool, tgt_cell: Vector2i, tgt_hp: int, victim_cell: Vector2i,
		bench: Array, pdead: int, edead: int, ranged: bool, with_grave: bool,
		extra_foe: int = 0, target_shield: bool = false, pending: int = 0, dynamic: bool = false,
		extra_hp: int = 0, extra_cell: Vector2i = Vector2i(-99, -99), nodelim: bool = false,
		all_acted: bool = false, expect_cut: bool = false, block_cell: Vector2i = Vector2i(-99, -99)) -> void:
	var hurt := await _fresh()
	GameState.no_death_limit = nodelim
	if dynamic:
		GameState.enemy_recipe = { "dynamic_bench": true }
		battle.enemy_roster = []
	else:
		GameState.enemy_recipe = {}
		battle.enemy_roster = (["hero_07"] if ranged else bench).duplicate()
	if with_grave:
		battle.graves[Vector2i(2, 5)] = { "fn": DataRegistry.Faction.ENEMY, "hero": "hero_11" }
	battle.player_dead = pdead
	battle.enemy_dead = edead
	battle._pending_enemy_sub = pending
	# 玩家最后一人
	var tgt := _spawn("hero_10", DataRegistry.Faction.PLAYER, tgt_cell)
	tgt.hp = tgt_hp
	if target_shield:
		tgt.add_status(StatusDB.SHIELD)
	else:
		# ⚠️ 自带牌组里有**圣光(hero_22)**：它 `call_deferred()` 发的盾会飘到探针摆的目标身上 ⇒ 判据当场
		#    变成"一刀收不掉"（S12 曾因此打出过自相矛盾的结果）。没有点名要盾的局面先把盾摘干净。
		tgt.remove_status(StatusDB.SHIELD)
	for i in extra_foe:
		var ec: Vector2i = (extra_cell if extra_cell.x >= 0 else Vector2i(0, 6 - i))
		var ef := _spawn("hero_05", DataRegistry.Faction.PLAYER, ec)
		if ef != null and extra_hp > 0:
			ef.hp = extra_hp
	# 我方两名单位：先摆的那个是"要撤的人"（`_finish_withdraw_victim()` 会挑没出手的第一个）
	var victim := _spawn("hero_11", DataRegistry.Faction.ENEMY, victim_cell)
	_spawn("hero_12", DataRegistry.Faction.ENEMY,
			(block_cell if block_cell.x >= 0 else Vector2i(4, 6)))
	# [all_acted] = 复刻"计划回放已经跑完"那一刻：我方该出手的都出手完了（判定现在挂在回放之后）
	if all_acted:
		for u in battle.units:
			if u != null and is_instance_valid(u) and u.alive and u.faction == DataRegistry.Faction.ENEMY:
				u.attacked_this_turn = true
	for i in 3:
		await get_tree().process_frame
	var units0 := battle.units.size()
	var hp_before := int(tgt.hp)
	battle._ai_finish_withdraw_pick()
	var decided := battle._finish_withdraw_target != null
	# ⚠️ 这几个字段要在**此刻**抄下来：apply 跑完会把自己清空（重置成 -99/-1/""）⇒ 之前读的是"被清空后"的值
	#   （S13 日志里出现过"决定撤=true 但 落点=(-99,-99)"这种自相矛盾的读法）。
	var picked_cell: Vector2i = battle._finish_withdraw_cell
	var picked_hero: String = battle._finish_withdraw_hero
	var picked_idx: int = battle._finish_withdraw_idx
	var killed := not (tgt != null and is_instance_valid(tgt) and tgt.alive)
	if decided:
		await battle._ai_finish_withdraw_apply()
		for i in 10:
			await get_tree().process_frame
		killed = not (tgt != null and is_instance_valid(tgt) and tgt.alive)
	# 判读：期望"该收掉"的局面 = 必须决定撤 + 真收掉；期望"不该撤"的局面 = 不能**真的撤掉**
	#   ⚠️ 注意：pick 阶段只看四道门，"已有待补名额"那道门在 apply 阶段才拦 ⇒ 这里判"有没有真的减员"。
	var ok := false
	if expect_cut:
		# 【2026-10-01·两刀合力】期望"**决定撤**、且目标这一轮只被削掉、没收掉"（第二刀留给下一轮）
		ok = decided and (not killed) and tgt != null and is_instance_valid(tgt) and int(tgt.hp) < hp_before
	elif expect_kill:
		ok = decided and killed
	else:
		ok = not decided or (not killed and battle.units.size() >= units0)
	if ok:
		_pass += 1
	else:
		_fail += 1
	print("T|%s|期望=%s|决定撤=%s|目标被收=%s|%s|撤谁=%s 落点=%s 换谁=%s(席次%d)" % [
		nm, ("两刀合力（本轮只削一刀）" if expect_cut else ("撤+收掉" if expect_kill else "不撤")), str(decided), str(killed),
		("PASS" if ok else "FAIL"),
		(str(victim.display_name) if victim != null and is_instance_valid(victim) else "—"),
		str(picked_cell), picked_hero, picked_idx])
	GameState.enemy_recipe = {}

## 起一局干净盘面（清掉 Main.tscn 自带的首发与地形），只留探针自己摆的人
func _fresh() -> Unit:
	if battle != null and is_instance_valid(battle):
		battle.queue_free()
		for i in 4:
			await get_tree().process_frame
	battle = (load("res://scenes/Main.tscn") as PackedScene).instantiate() as Battle
	add_child(battle)
	for i in 3:
		await get_tree().process_frame
	_clear()
	battle.player_roster = []
	battle.enemy_roster = []
	GameState.no_death_limit = false
	GameState.match_over = false
	GameState.active_side = GameState.SIDE_ENEMY
	battle.state = battle.State.ENEMY_TURN
	for i in 2:
		await get_tree().process_frame
	return null

func _clear() -> void:
	for u in battle.units:
		if is_instance_valid(u):
			u.queue_free()
	battle.units.clear()
	battle.occupancy.clear()
	battle.graves.clear()
	battle.obstacles.clear()
	battle.bombs.clear()
	battle.enemy_dead = 0
	battle.player_dead = 0

func _spawn(hid: String, faction: int, cell: Vector2i) -> Unit:
	var u := battle._spawn_unit(hid, faction, cell)
	if u == null:
		print("T|WARN|spawn_failed|%s" % hid)
	return u

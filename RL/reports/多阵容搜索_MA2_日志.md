[23:22:19] ===== 多阵容搜索 Tag=MA2 =====
[23:22:19]   英雄池: 49 个（hero_01..hero_49）
[23:22:19]   参数: 轮数=1 候选=3 σ=0.2 阵容=2 并发=4 分级seeds=1/1/1 搜索档beam=100 阵容种子=20260914
[23:22:19]   起点比例: "KILL_BONUS": 35, "FOCUS_FIRE_WEIGHT": 30, "GOLD_TAKE_VALUE": 26, "GOLD_TAKE_VALUE_LOW": 34, "GOLD_LOW_ATK": 4, "BUFF_TAKE_WEIGHT": 3, "THREAT_MOVE_DISCOUNT": 0.7, "OBSTACLE_DETOUR_WEIGHT": 4, "ENGAGE_PULL_PER_CELL": 1.2, "MAX_MOVE_OPTIONS": 16
[23:22:19]   初始化 multi_best = RL/weights/噩梦.json 副本 → D:\Game creating\战旗\RL\weights\multi_best_MA2.json
[23:22:19] ===== 第 1 轮 开始 =====
[23:22:19]   L1  我方=[hero_12,hero_06,hero_48]  敌方=[hero_28,hero_14,hero_13]
[23:22:19]   L2  我方=[hero_06,hero_47,hero_49]  敌方=[hero_33,hero_34,hero_15]
[23:22:19]   候选 3 个 + 控制组 r1_best（围绕默认比例）
[23:22:19]   --- 轮1 阶段1（1 seeds = 4 局/臂）---
[23:22:19]     L1 阶段1 → run=MA2_R1_L1_s1 臂=4
[23:23:51]       | [league] arm consistency OK: every (seed, first) has ONE opponent identity across all 4 config(s) x 1 seed(s)
[23:23:51]       | [par] accounting: cells planned=8 completed=8 | games planned=16 produced=16
[23:23:51]       | [run] completeness: rows=16 duplicates=0 missing=0
[23:23:51]       | [run] completeness: rows=16 duplicates=0 missing=0
[23:23:51]   ✓ 阵容固定断言通过（轮1 L1，8 批全部 E=["hero_28", "hero_14", "hero_13"] P=["hero_12", "hero_06", "hero_48"]）
[23:23:51]     L2 阶段1 → run=MA2_R1_L2_s1 臂=4
[23:26:54]       | [league] arm consistency OK: every (seed, first) has ONE opponent identity across all 4 config(s) x 1 seed(s)
[23:26:54]       | [par] accounting: cells planned=8 completed=8 | games planned=16 produced=16
[23:26:54]       | [run] completeness: rows=16 duplicates=0 missing=0
[23:26:54]       | [run] completeness: rows=16 duplicates=0 missing=0
[23:26:54]   ✓ 阵容固定断言通过（轮1 L2，8 批全部 E=["hero_33", "hero_34", "hero_15"] P=["hero_06", "hero_47", "hero_49"]）
[23:26:54]     阶段1 存活: r1_c3(0.06) | r1_c1(-11.82)
[23:26:54]   --- 轮1 阶段2（1 seeds = 4 局/臂）---
[23:26:54]     L1 阶段2 → run=MA2_R1_L1_s2 臂=3
[23:28:26]       | [league] arm consistency OK: every (seed, first) has ONE opponent identity across all 3 config(s) x 1 seed(s)
[23:28:26]       | [par] accounting: cells planned=6 completed=6 | games planned=12 produced=12
[23:28:26]       | [run] completeness: rows=12 duplicates=0 missing=0
[23:28:26]       | [run] completeness: rows=12 duplicates=0 missing=0
[23:28:26]   ✓ 阵容固定断言通过（轮1 L1，6 批全部 E=["hero_28", "hero_14", "hero_13"] P=["hero_12", "hero_06", "hero_48"]）
[23:28:26]     L2 阶段2 → run=MA2_R1_L2_s2 臂=3
[23:31:28]       | [league] arm consistency OK: every (seed, first) has ONE opponent identity across all 3 config(s) x 1 seed(s)
[23:31:28]       | [par] accounting: cells planned=6 completed=6 | games planned=12 produced=12
[23:31:28]       | [run] completeness: rows=12 duplicates=0 missing=0
[23:31:28]       | [run] completeness: rows=12 duplicates=0 missing=0
[23:31:28]   ✓ 阵容固定断言通过（轮1 L2，6 批全部 E=["hero_33", "hero_34", "hero_15"] P=["hero_06", "hero_47", "hero_49"]）
[23:31:28]     阶段2 存活: r1_c3(0.06) | r1_c1(-11.82)
[23:31:28]   --- 轮1 阶段3（1 seeds = 4 局/臂）---
[23:31:28]     L1 阶段3 → run=MA2_R1_L1_s3 臂=3
[23:33:01]       | [league] arm consistency OK: every (seed, first) has ONE opponent identity across all 3 config(s) x 1 seed(s)
[23:33:01]       | [par] accounting: cells planned=6 completed=6 | games planned=12 produced=12
[23:33:01]       | [run] completeness: rows=12 duplicates=0 missing=0
[23:33:01]       | [run] completeness: rows=12 duplicates=0 missing=0
[23:33:01]   ✓ 阵容固定断言通过（轮1 L1，6 批全部 E=["hero_28", "hero_14", "hero_13"] P=["hero_12", "hero_06", "hero_48"]）
[23:33:01]     L2 阶段3 → run=MA2_R1_L2_s3 臂=3
[23:36:33]       | [league] arm consistency OK: every (seed, first) has ONE opponent identity across all 3 config(s) x 1 seed(s)
[23:36:33]       | [par] accounting: cells planned=6 completed=6 | games planned=12 produced=12
[23:36:33]       | [run] completeness: rows=12 duplicates=0 missing=0
[23:36:33]       | [run] completeness: rows=12 duplicates=0 missing=0
[23:36:33]   ✓ 阵容固定断言通过（轮1 L2，6 批全部 E=["hero_33", "hero_34", "hero_15"] P=["hero_06", "hero_47", "hero_49"]）
[23:36:33]     阶段3 存活: r1_c3(0.06)
[23:39:20] ===== 多阵容搜索 Tag=MA2 =====
[23:39:20]   英雄池: 49 个（hero_01..hero_49）
[23:39:20]   参数: 轮数=1 候选=3 σ=0.2 阵容=2 并发=4 分级seeds=1/1/1 搜索档beam=100 阵容种子=20260914
[23:39:20]   起点比例: "KILL_BONUS": 35, "FOCUS_FIRE_WEIGHT": 30, "GOLD_TAKE_VALUE": 26, "GOLD_TAKE_VALUE_LOW": 34, "GOLD_LOW_ATK": 4, "BUFF_TAKE_WEIGHT": 3, "THREAT_MOVE_DISCOUNT": 0.7, "OBSTACLE_DETOUR_WEIGHT": 4, "ENGAGE_PULL_PER_CELL": 1.2, "MAX_MOVE_OPTIONS": 16
[23:39:20] ===== 第 1 轮 开始 =====
[23:39:20]   L1  我方=[hero_12,hero_06,hero_48]  敌方=[hero_28,hero_14,hero_13]
[23:39:20]   L2  我方=[hero_06,hero_47,hero_49]  敌方=[hero_33,hero_34,hero_15]
[23:39:20]   候选 3 个 + 控制组 r1_best（围绕默认比例）
[23:39:20]   --- 轮1 阶段1（1 seeds = 4 局/臂）---
[23:39:20]     L1 阶段1 → run=MA2_R1_L1_s1 臂=4
[23:40:52]       | [league] arm consistency OK: every (seed, first) has ONE opponent identity across all 4 config(s) x 1 seed(s)
[23:40:52]       | [par] accounting: cells planned=8 completed=8 | games planned=16 produced=16
[23:40:52]       | [run] completeness: rows=16 duplicates=0 missing=0
[23:40:52]       | [run] completeness: rows=16 duplicates=0 missing=0
[23:40:52]       | [league] arm consistency OK: every (seed, first) has ONE opponent identity across all 4 config(s) x 1 seed(s)
[23:40:52]       | [par] accounting: cells planned=8 completed=8 | games planned=16 produced=16
[23:40:52]       | [run] completeness: rows=16 duplicates=0 missing=0
[23:40:52]       | [run] completeness: rows=16 duplicates=0 missing=0
[23:40:52]   ✓ 阵容固定断言通过（轮1 L1，16 批全部 E=["hero_28", "hero_14", "hero_13"] P=["hero_12", "hero_06", "hero_48"]）
[23:40:52]     L2 阶段1 → run=MA2_R1_L2_s1 臂=4
[23:43:55]       | [league] arm consistency OK: every (seed, first) has ONE opponent identity across all 4 config(s) x 1 seed(s)
[23:43:55]       | [par] accounting: cells planned=8 completed=8 | games planned=16 produced=16
[23:43:55]       | [run] completeness: rows=16 duplicates=0 missing=0
[23:43:55]       | [run] completeness: rows=16 duplicates=0 missing=0
[23:43:55]       | [league] arm consistency OK: every (seed, first) has ONE opponent identity across all 4 config(s) x 1 seed(s)
[23:43:55]       | [par] accounting: cells planned=8 completed=8 | games planned=16 produced=16
[23:43:55]       | [run] completeness: rows=16 duplicates=0 missing=0
[23:43:55]       | [run] completeness: rows=16 duplicates=0 missing=0
[23:43:55]   ✓ 阵容固定断言通过（轮1 L2，16 批全部 E=["hero_33", "hero_34", "hero_15"] P=["hero_06", "hero_47", "hero_49"]）
[23:43:55]     阶段1 存活: r1_c3(0.06) | r1_c1(-11.82)
[23:43:55]   --- 轮1 阶段2（1 seeds = 4 局/臂）---
[23:43:55]     L1 阶段2 → run=MA2_R1_L1_s2 臂=3
[23:45:27]       | [league] arm consistency OK: every (seed, first) has ONE opponent identity across all 3 config(s) x 1 seed(s)
[23:45:27]       | [par] accounting: cells planned=6 completed=6 | games planned=12 produced=12
[23:45:27]       | [run] completeness: rows=12 duplicates=0 missing=0
[23:45:27]       | [run] completeness: rows=12 duplicates=0 missing=0
[23:45:27]       | [league] arm consistency OK: every (seed, first) has ONE opponent identity across all 3 config(s) x 1 seed(s)
[23:45:27]       | [par] accounting: cells planned=6 completed=6 | games planned=12 produced=12
[23:45:27]       | [run] completeness: rows=12 duplicates=0 missing=0
[23:45:27]       | [run] completeness: rows=12 duplicates=0 missing=0
[23:45:27]   ✓ 阵容固定断言通过（轮1 L1，12 批全部 E=["hero_28", "hero_14", "hero_13"] P=["hero_12", "hero_06", "hero_48"]）
[23:45:27]     L2 阶段2 → run=MA2_R1_L2_s2 臂=3
[23:48:30]       | [league] arm consistency OK: every (seed, first) has ONE opponent identity across all 3 config(s) x 1 seed(s)
[23:48:30]       | [par] accounting: cells planned=6 completed=6 | games planned=12 produced=12
[23:48:30]       | [run] completeness: rows=12 duplicates=0 missing=0
[23:48:30]       | [run] completeness: rows=12 duplicates=0 missing=0
[23:48:30]       | [league] arm consistency OK: every (seed, first) has ONE opponent identity across all 3 config(s) x 1 seed(s)
[23:48:30]       | [par] accounting: cells planned=6 completed=6 | games planned=12 produced=12
[23:48:30]       | [run] completeness: rows=12 duplicates=0 missing=0
[23:48:30]       | [run] completeness: rows=12 duplicates=0 missing=0
[23:48:30]   ✓ 阵容固定断言通过（轮1 L2，12 批全部 E=["hero_33", "hero_34", "hero_15"] P=["hero_06", "hero_47", "hero_49"]）
[23:48:30]     阶段2 存活: r1_c3(0.06) | r1_c1(-11.82)
[23:48:30]   --- 轮1 阶段3（1 seeds = 4 局/臂）---
[23:48:30]     L1 阶段3 → run=MA2_R1_L1_s3 臂=3
[23:57:42] ===== 多阵容搜索 Tag=MA2 =====
[23:57:42]   英雄池: 49 个（hero_01..hero_49）
[23:57:42]   参数: 轮数=1 候选=3 σ=0.2 阵容=2 并发=4 分级seeds=1/1/1 搜索档beam=100 阵容种子=20260914
[23:57:42]   起点比例: "KILL_BONUS": 35, "FOCUS_FIRE_WEIGHT": 30, "GOLD_TAKE_VALUE": 26, "GOLD_TAKE_VALUE_LOW": 34, "GOLD_LOW_ATK": 4, "BUFF_TAKE_WEIGHT": 3, "THREAT_MOVE_DISCOUNT": 0.7, "OBSTACLE_DETOUR_WEIGHT": 4, "ENGAGE_PULL_PER_CELL": 1.2, "MAX_MOVE_OPTIONS": 16
[23:57:42] ===== 第 1 轮 开始 =====
[23:57:42]   L1  我方=[hero_12,hero_06,hero_48]  敌方=[hero_28,hero_14,hero_13]
[23:57:42]   L2  我方=[hero_06,hero_47,hero_49]  敌方=[hero_33,hero_34,hero_15]
[23:57:42]   候选 3 个 + 控制组 r1_best（围绕默认比例）
[23:57:42]   --- 轮1 阶段1（1 seeds = 4 局/臂）---
[23:57:42]     L1 阶段1 → run=MA2_R1_L1_s1 臂=4
[23:59:14]       | [league] arm consistency OK: every (seed, first) has ONE opponent identity across all 4 config(s) x 1 seed(s)
[23:59:14]       | [par] accounting: cells planned=8 completed=8 | games planned=16 produced=16
[23:59:14]       | [run] completeness: rows=16 duplicates=0 missing=0
[23:59:14]       | [run] completeness: rows=16 duplicates=0 missing=0
[23:59:14]       | [league] arm consistency OK: every (seed, first) has ONE opponent identity across all 4 config(s) x 1 seed(s)
[23:59:14]       | [par] accounting: cells planned=8 completed=8 | games planned=16 produced=16
[23:59:14]       | [run] completeness: rows=16 duplicates=0 missing=0
[23:59:14]       | [run] completeness: rows=16 duplicates=0 missing=0
[23:59:14]       | [league] arm consistency OK: every (seed, first) has ONE opponent identity across all 4 config(s) x 1 seed(s)
[23:59:14]       | [par] accounting: cells planned=8 completed=8 | games planned=16 produced=16
[23:59:14]       | [run] completeness: rows=16 duplicates=0 missing=0
[23:59:14]       | [run] completeness: rows=16 duplicates=0 missing=0
[23:59:14]   ✓ 阵容固定断言通过（轮1 L1，24 批全部 E=["hero_28", "hero_14", "hero_13"] P=["hero_12", "hero_06", "hero_48"]）
[23:59:14]     L2 阶段1 → run=MA2_R1_L2_s1 臂=4
[00:02:17]       | [league] arm consistency OK: every (seed, first) has ONE opponent identity across all 4 config(s) x 1 seed(s)
[00:02:17]       | [par] accounting: cells planned=8 completed=8 | games planned=16 produced=16
[00:02:17]       | [run] completeness: rows=16 duplicates=0 missing=0
[00:02:17]       | [run] completeness: rows=16 duplicates=0 missing=0
[00:02:17]       | [league] arm consistency OK: every (seed, first) has ONE opponent identity across all 4 config(s) x 1 seed(s)
[00:02:17]       | [par] accounting: cells planned=8 completed=8 | games planned=16 produced=16
[00:02:17]       | [run] completeness: rows=16 duplicates=0 missing=0
[00:02:17]       | [run] completeness: rows=16 duplicates=0 missing=0
[00:02:17]       | [league] arm consistency OK: every (seed, first) has ONE opponent identity across all 4 config(s) x 1 seed(s)
[00:02:17]       | [par] accounting: cells planned=8 completed=8 | games planned=16 produced=16
[00:02:17]       | [run] completeness: rows=16 duplicates=0 missing=0
[00:02:17]       | [run] completeness: rows=16 duplicates=0 missing=0
[00:02:17]   ✓ 阵容固定断言通过（轮1 L2，24 批全部 E=["hero_33", "hero_34", "hero_15"] P=["hero_06", "hero_47", "hero_49"]）
[00:02:17]     阶段1 存活: r1_c3(0.06) | r1_c1(-11.82)
[00:02:17]   --- 轮1 阶段2（1 seeds = 4 局/臂）---
[00:02:17]     L1 阶段2 → run=MA2_R1_L1_s2 臂=3
[00:03:49]       | [league] arm consistency OK: every (seed, first) has ONE opponent identity across all 3 config(s) x 1 seed(s)
[00:03:49]       | [par] accounting: cells planned=6 completed=6 | games planned=12 produced=12
[00:03:49]       | [run] completeness: rows=12 duplicates=0 missing=0
[00:03:49]       | [run] completeness: rows=12 duplicates=0 missing=0
[00:03:49]       | [league] arm consistency OK: every (seed, first) has ONE opponent identity across all 3 config(s) x 1 seed(s)
[00:03:49]       | [par] accounting: cells planned=6 completed=6 | games planned=12 produced=12
[00:03:49]       | [run] completeness: rows=12 duplicates=0 missing=0
[00:03:49]       | [run] completeness: rows=12 duplicates=0 missing=0
[00:03:49]       | [league] arm consistency OK: every (seed, first) has ONE opponent identity across all 3 config(s) x 1 seed(s)
[00:03:49]       | [par] accounting: cells planned=6 completed=6 | games planned=12 produced=12
[00:03:49]       | [run] completeness: rows=12 duplicates=0 missing=0
[00:03:49]       | [run] completeness: rows=12 duplicates=0 missing=0
[00:03:49]   ✓ 阵容固定断言通过（轮1 L1，18 批全部 E=["hero_28", "hero_14", "hero_13"] P=["hero_12", "hero_06", "hero_48"]）
[00:03:49]     L2 阶段2 → run=MA2_R1_L2_s2 臂=3
[00:07:22]       | [league] arm consistency OK: every (seed, first) has ONE opponent identity across all 3 config(s) x 1 seed(s)
[00:07:22]       | [par] accounting: cells planned=6 completed=6 | games planned=12 produced=12
[00:07:22]       | [run] completeness: rows=12 duplicates=0 missing=0
[00:07:22]       | [run] completeness: rows=12 duplicates=0 missing=0
[00:07:22]       | [league] arm consistency OK: every (seed, first) has ONE opponent identity across all 3 config(s) x 1 seed(s)
[00:07:22]       | [par] accounting: cells planned=6 completed=6 | games planned=12 produced=12
[00:07:22]       | [run] completeness: rows=12 duplicates=0 missing=0
[00:07:22]       | [run] completeness: rows=12 duplicates=0 missing=0
[00:07:22]       | [league] arm consistency OK: every (seed, first) has ONE opponent identity across all 3 config(s) x 1 seed(s)
[00:07:22]       | [par] accounting: cells planned=6 completed=6 | games planned=12 produced=12
[00:07:22]       | [run] completeness: rows=12 duplicates=0 missing=0
[00:07:22]       | [run] completeness: rows=12 duplicates=0 missing=0
[00:07:22]   ✓ 阵容固定断言通过（轮1 L2，18 批全部 E=["hero_33", "hero_34", "hero_15"] P=["hero_06", "hero_47", "hero_49"]）
[00:07:22]     阶段2 存活: r1_c3(0.06) | r1_c1(-11.82)
[00:07:22]   --- 轮1 阶段3（1 seeds = 4 局/臂）---
[00:07:22]     L1 阶段3 → run=MA2_R1_L1_s3 臂=3
[00:08:54]       | [league] arm consistency OK: every (seed, first) has ONE opponent identity across all 3 config(s) x 1 seed(s)
[00:08:54]       | [par] accounting: cells planned=6 completed=6 | games planned=12 produced=12
[00:08:54]       | [run] completeness: rows=12 duplicates=0 missing=0
[00:08:54]       | [run] completeness: rows=12 duplicates=0 missing=0
[00:08:54]       | [league] arm consistency OK: every (seed, first) has ONE opponent identity across all 3 config(s) x 1 seed(s)
[00:08:54]       | [league] arm consistency OK: every (seed, first) has ONE opponent identity across all 3 config(s) x 1 seed(s)
[00:08:54]       | [par] accounting: cells planned=6 completed=6 | games planned=12 produced=12
[00:08:54]       | [run] completeness: rows=12 duplicates=0 missing=0
[00:08:54]       | [run] completeness: rows=12 duplicates=0 missing=0
[00:08:54]   ✓ 阵容固定断言通过（轮1 L1，16 批全部 E=["hero_28", "hero_14", "hero_13"] P=["hero_12", "hero_06", "hero_48"]）
[00:08:54]     L2 阶段3 → run=MA2_R1_L2_s3 臂=3
[00:11:57]       | [league] arm consistency OK: every (seed, first) has ONE opponent identity across all 3 config(s) x 1 seed(s)
[00:11:57]       | [par] accounting: cells planned=6 completed=6 | games planned=12 produced=12
[00:11:57]       | [run] completeness: rows=12 duplicates=0 missing=0
[00:11:57]       | [run] completeness: rows=12 duplicates=0 missing=0
[00:11:57]       | [league] arm consistency OK: every (seed, first) has ONE opponent identity across all 3 config(s) x 1 seed(s)
[00:11:57]       | [par] accounting: cells planned=6 completed=6 | games planned=12 produced=12
[00:11:57]       | [run] completeness: rows=12 duplicates=0 missing=0
[00:11:57]       | [run] completeness: rows=12 duplicates=0 missing=0
[00:11:57]   ✓ 阵容固定断言通过（轮1 L2，12 批全部 E=["hero_33", "hero_34", "hero_15"] P=["hero_06", "hero_47", "hero_49"]）
[00:11:57]     阶段3 存活: r1_c3(0.06)
[00:11:57]   ✓ 配对完整性：1 个候选 × 2 套阵容，配对局数一致
[00:11:57]   ==== 轮1 聚合排名（跨 2 套阵容）====
[00:11:57]     r1_c3      均值Δpts=   0.065  95%CI=[-0.376, 0.506]  min/max=-0.04/0.17
[00:11:57]   报告: D:\Game creating\战旗\RL\reports\多阵容_MA2_R1.md
[00:11:57]   比例池: D:\Game creating\战旗\RL\reports\多阵容_比例池.csv（追加 1 行）
[00:11:57]   ✔ 轮1 新的历史最优: r1_c3 均值Δpts=0.065 → D:\Game creating\战旗\RL\weights\multi_best_MA2.json
[00:11:57] ===== 全部轮次结束 =====
[00:11:57]   历史最优比例: D:\Game creating\战旗\RL\weights\multi_best_MA2.json
[00:11:57]   比例池（用于挑 top-k 做留出集验收）: D:\Game creating\战旗\RL\reports\多阵容_比例池.csv
[00:11:57]   提醒: 验收必须用正式档 beam 400 + 留出集面板（困难档 800/100、上一代自己、镜像自对弈），
[00:11:57]         并把"每局从 top-k 随机取一个"的混合物当成一个整体测，不要只看单比例。

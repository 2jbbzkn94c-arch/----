[21:43:03] ===== 多阵容搜索 Tag=MS =====
[21:43:03]   英雄池: 0 个（..）
[21:43:03]   参数: 轮数=1 候选=4 σ=0.2 阵容=2 并发=4 分级seeds=1/1/1 搜索档beam=100 阵容种子=20260914
[21:43:03]   起点比例: "KILL_BONUS": 35, "FOCUS_FIRE_WEIGHT": 30, "GOLD_TAKE_VALUE": 26, "GOLD_TAKE_VALUE_LOW": 34, "GOLD_LOW_ATK": 4, "BUFF_TAKE_WEIGHT": 3, "THREAT_MOVE_DISCOUNT": 0.7, "OBSTACLE_DETOUR_WEIGHT": 4, "ENGAGE_PULL_PER_CELL": 1.2, "MAX_MOVE_OPTIONS": 16
[21:43:03]   初始化 multi_best = RL/weights/噩梦.json 副本 → D:\Game creating\战旗\RL\weights\multi_best_MS.json
[21:43:03] ===== 第 1 轮 开始 =====
[21:43:03]   L  我方=[]  敌方=[]
[21:43:03]   候选 4 个 + 控制组 r1_best（围绕默认比例）
[21:43:03]   --- 轮1 阶段1（1 seeds = 4 局/臂）---
[21:43:03]     L 阶段1 → run=MS_R1_L_s1 臂=5
[21:43:36]   ✗ 轮1 L 阶段1 run 失败 exit=1，原始输出（末尾 30 行）:
[21:43:36]       | [cell] !! b_r1_c1_s10001_fp produced 0 game rows (exit=0)
[21:43:36]       | [godot] start seeds=10001..10001 first=p opp=base beamA=100 e= p=
[21:43:36]       | [godot] done exit=0 wall=1.6s out_bytes=2294
[21:43:36]       | [cell] !! b_r1_c3_s10001_fp produced 0 game rows (exit=0)
[21:43:36]       | [par]   Job5: @{Worker=w3; Games=0; WallSec=3.3130835; Cells=2; Expected=2; PSComputerName=localhost; RunspaceId=6ee720
[21:43:36]       | f7-5c10-42fd-b3fb-dbc84e49fd6c; PSShowComputerName=False}
[21:43:36]       | [par]   w4: start cfg=5 cells=2/2
[21:43:36]       | [par]   w4: cfgMap=[r1_best,r1_c4,r1_c2,r1_c3,r1_c1]
[21:43:36]       | [godot] start seeds=10001..10001 first=e opp=base beamA=100 e= p=
[21:43:36]       | [godot] done exit=0 wall=1.7s out_bytes=2294
[21:43:36]       | [cell] !! b_r1_c1_s10001_fe produced 0 game rows (exit=0)
[21:43:36]       | [godot] start seeds=10001..10001 first=e opp=base beamA=100 e= p=
[21:43:36]       | [godot] done exit=0 wall=1.6s out_bytes=2294
[21:43:36]       | [cell] !! b_r1_c3_s10001_fe produced 0 game rows (exit=0)
[21:43:36]       | [par]   Job7: @{Worker=w4; Games=0; WallSec=3.3074769; Cells=2; Expected=2; PSComputerName=localhost; RunspaceId=c7f3ad
[21:43:36]       | 6b-5088-41b5-b3ec-ce86482a2663; PSShowComputerName=False}
[21:43:36]       | [par] all workers done in 31s
[21:43:36]       | [par] accounting: cells planned=10 completed=10 | games planned=20 produced=0
[21:43:36]       | [par] !! cell count matches (10) but games differ: planned=20 produced=0 (a cell can legitimately produce 0 rows when t
[21:43:36]       | he harness dies on that lineup)
[21:43:36]       | [league] league block present but enabled=false -> using the fixed opponent for every cell
[21:43:36]       | [merge] appended 0 row(s) from 4 worker run(s)
[21:43:36]       | FATAL: RuntimeException :: repair: raw log has no parsable game rows for run MS_R1_L_s1
[21:43:36]       |   at D:\Game creating\战旗\RL\train\RlTrain.ps1:1545
[21:43:36]       |   stmt: if ($rows.Count -eq 0) { throw ('repair: raw log has no parsable game rows for run ' + $Run) }
[21:43:36]       |   stack: at Repair-MeasureCsv, D:\Game creating\战旗\RL\train\RlTrain.ps1: line 1545
[21:43:36]       | at Merge-WorkerResults, D:\Game creating\战旗\RL\train\RlTrain.ps1: line 2090
[21:43:36]       | at Start-MeasureRun, D:\Game creating\战旗\RL\train\RlTrain.ps1: line 2383
[21:43:36]       | at <ScriptBlock>, D:\Game creating\战旗\RL\train\Train.ps1: line 430
[21:43:36]       | at <ScriptBlock>, <No file>: line 1
[21:48:22] ===== 多阵容搜索 Tag=MS =====
[21:48:22]   英雄池: 49 个（hero_01..hero_49）
[21:48:22]   参数: 轮数=1 候选=4 σ=0.2 阵容=2 并发=4 分级seeds=1/1/1 搜索档beam=100 阵容种子=20260914
[21:48:22]   起点比例: "KILL_BONUS": 35, "FOCUS_FIRE_WEIGHT": 30, "GOLD_TAKE_VALUE": 26, "GOLD_TAKE_VALUE_LOW": 34, "GOLD_LOW_ATK": 4, "BUFF_TAKE_WEIGHT": 3, "THREAT_MOVE_DISCOUNT": 0.7, "OBSTACLE_DETOUR_WEIGHT": 4, "ENGAGE_PULL_PER_CELL": 1.2, "MAX_MOVE_OPTIONS": 16
[21:48:22]   初始化 multi_best = RL/weights/噩梦.json 副本 → D:\Game creating\战旗\RL\weights\multi_best_MS.json
[21:48:22] ===== 第 1 轮 开始 =====
[21:55:41] ===== 多阵容搜索 Tag=MS =====
[21:55:41]   英雄池: 49 个（hero_01..hero_49）
[21:55:41]   参数: 轮数=1 候选=4 σ=0.2 阵容=2 并发=4 分级seeds=1/1/1 搜索档beam=100 阵容种子=20260914
[21:55:41]   起点比例: "KILL_BONUS": 35, "FOCUS_FIRE_WEIGHT": 30, "GOLD_TAKE_VALUE": 26, "GOLD_TAKE_VALUE_LOW": 34, "GOLD_LOW_ATK": 4, "BUFF_TAKE_WEIGHT": 3, "THREAT_MOVE_DISCOUNT": 0.7, "OBSTACLE_DETOUR_WEIGHT": 4, "ENGAGE_PULL_PER_CELL": 1.2, "MAX_MOVE_OPTIONS": 16
[21:55:41]   初始化 multi_best = RL/weights/噩梦.json 副本 → D:\Game creating\战旗\RL\weights\multi_best_MS.json
[21:55:41] ===== 第 1 轮 开始 =====
[21:59:47] ===== 多阵容搜索 Tag=MS =====
[21:59:47]   英雄池: 49 个（hero_01..hero_49）
[21:59:47]   参数: 轮数=1 候选=4 σ=0.2 阵容=8 并发=4 分级seeds=1/1/1 搜索档beam=100 阵容种子=20260914
[21:59:47]   起点比例: "KILL_BONUS": 35, "FOCUS_FIRE_WEIGHT": 30, "GOLD_TAKE_VALUE": 26, "GOLD_TAKE_VALUE_LOW": 34, "GOLD_LOW_ATK": 4, "BUFF_TAKE_WEIGHT": 3, "THREAT_MOVE_DISCOUNT": 0.7, "OBSTACLE_DETOUR_WEIGHT": 4, "ENGAGE_PULL_PER_CELL": 1.2, "MAX_MOVE_OPTIONS": 16
[21:59:47]   初始化 multi_best = RL/weights/噩梦.json 副本 → D:\Game creating\战旗\RL\weights\multi_best_MS.json
[21:59:47] ===== 第 1 轮 开始 =====
[21:59:47]   L1  我方=[hero_12,hero_06,hero_48]  敌方=[hero_28,hero_14,hero_13]
[21:59:47]   L2  我方=[hero_06,hero_47,hero_49]  敌方=[hero_33,hero_34,hero_15]
[21:59:47]   L3  我方=[hero_03,hero_47,hero_22]  敌方=[hero_31,hero_20,hero_07]
[21:59:47]   L4  我方=[hero_08,hero_02,hero_48]  敌方=[hero_29,hero_24,hero_21]
[21:59:47]   L5  我方=[hero_28,hero_37,hero_22]  敌方=[hero_43,hero_07,hero_15]
[21:59:47]   L6  我方=[hero_17,hero_43,hero_22]  敌方=[hero_27,hero_31,hero_32]
[21:59:47]   L7  我方=[hero_20,hero_29,hero_35]  敌方=[hero_45,hero_23,hero_41]
[21:59:47]   L8  我方=[hero_07,hero_25,hero_31]  敌方=[hero_03,hero_29,hero_36]
[21:59:47]   候选 4 个 + 控制组 r1_best（围绕默认比例）
[21:59:47]   --- 轮1 阶段1（1 seeds = 4 局/臂）---
[21:59:47]     L1 阶段1 → run=MS_R1_L1_s1 臂=5
[22:02:19]       | [league] arm consistency OK: every (seed, first) has ONE opponent identity across all 5 config(s) x 1 seed(s)
[22:02:19]       | [par] accounting: cells planned=10 completed=10 | games planned=20 produced=20
[22:02:19]       | [run] completeness: rows=20 duplicates=0 missing=0
[22:02:19]       | [run] completeness: rows=20 duplicates=0 missing=0
[22:02:19]   ✓ 阵容固定断言通过（轮1 L1，10 批全部 E=["hero_28", "hero_14", "hero_13"] P=["hero_12", "hero_06", "hero_48"]）
[22:02:20]     L2 阶段1 → run=MS_R1_L2_s1 臂=5
[22:07:22]       | [league] arm consistency OK: every (seed, first) has ONE opponent identity across all 5 config(s) x 1 seed(s)
[22:07:22]       | [par] accounting: cells planned=10 completed=10 | games planned=20 produced=20
[22:07:22]       | [run] completeness: rows=20 duplicates=0 missing=0
[22:07:22]       | [run] completeness: rows=20 duplicates=0 missing=0
[22:07:22]   ✓ 阵容固定断言通过（轮1 L2，10 批全部 E=["hero_33", "hero_34", "hero_15"] P=["hero_06", "hero_47", "hero_49"]）
[22:07:22]     L3 阶段1 → run=MS_R1_L3_s1 臂=5
[22:10:25]       | [league] arm consistency OK: every (seed, first) has ONE opponent identity across all 5 config(s) x 1 seed(s)
[22:10:25]       | [par] accounting: cells planned=10 completed=10 | games planned=20 produced=20
[22:10:25]       | [run] completeness: rows=20 duplicates=0 missing=0
[22:10:25]       | [run] completeness: rows=20 duplicates=0 missing=0
[22:10:25]   ✓ 阵容固定断言通过（轮1 L3，10 批全部 E=["hero_31", "hero_20", "hero_07"] P=["hero_03", "hero_47", "hero_22"]）
[22:10:25]     L4 阶段1 → run=MS_R1_L4_s1 臂=5
[22:14:28]       | [league] arm consistency OK: every (seed, first) has ONE opponent identity across all 5 config(s) x 1 seed(s)
[22:14:28]       | [par] accounting: cells planned=10 completed=10 | games planned=20 produced=20
[22:14:28]       | [run] completeness: rows=20 duplicates=0 missing=0
[22:14:28]       | [run] completeness: rows=20 duplicates=0 missing=0
[22:14:28]   ✓ 阵容固定断言通过（轮1 L4，10 批全部 E=["hero_29", "hero_24", "hero_21"] P=["hero_08", "hero_02", "hero_48"]）
[22:14:28]     L5 阶段1 → run=MS_R1_L5_s1 臂=5
[22:17:30]       | [league] arm consistency OK: every (seed, first) has ONE opponent identity across all 5 config(s) x 1 seed(s)
[22:17:30]       | [par] accounting: cells planned=10 completed=10 | games planned=20 produced=20
[22:17:30]       | [run] completeness: rows=20 duplicates=0 missing=0
[22:17:30]       | [run] completeness: rows=20 duplicates=0 missing=0
[22:17:30]   ✓ 阵容固定断言通过（轮1 L5，10 批全部 E=["hero_43", "hero_07", "hero_15"] P=["hero_28", "hero_37", "hero_22"]）
[22:17:30]     L6 阶段1 → run=MS_R1_L6_s1 臂=5
[22:19:33]       | [league] arm consistency OK: every (seed, first) has ONE opponent identity across all 5 config(s) x 1 seed(s)
[22:19:33]       | [par] accounting: cells planned=10 completed=10 | games planned=20 produced=20
[22:19:33]       | [run] completeness: rows=20 duplicates=0 missing=0
[22:19:33]       | [run] completeness: rows=20 duplicates=0 missing=0
[22:19:33]   ✓ 阵容固定断言通过（轮1 L6，10 批全部 E=["hero_27", "hero_31", "hero_32"] P=["hero_17", "hero_43", "hero_22"]）
[22:19:33]     L7 阶段1 → run=MS_R1_L7_s1 臂=5
[22:23:05]       | [league] arm consistency OK: every (seed, first) has ONE opponent identity across all 5 config(s) x 1 seed(s)
[22:23:05]       | [par] accounting: cells planned=10 completed=10 | games planned=20 produced=20
[22:23:05]       | [run] completeness: rows=20 duplicates=0 missing=0
[22:23:05]       | [run] completeness: rows=20 duplicates=0 missing=0
[22:23:05]   ✓ 阵容固定断言通过（轮1 L7，10 批全部 E=["hero_45", "hero_23", "hero_41"] P=["hero_20", "hero_29", "hero_35"]）
[22:23:05]     L8 阶段1 → run=MS_R1_L8_s1 臂=5
[22:25:08]       | [league] arm consistency OK: every (seed, first) has ONE opponent identity across all 5 config(s) x 1 seed(s)
[22:25:08]       | [par] accounting: cells planned=10 completed=10 | games planned=20 produced=20
[22:25:08]       | [run] completeness: rows=20 duplicates=0 missing=0
[22:25:08]       | [run] completeness: rows=20 duplicates=0 missing=0
[22:25:08]   ✓ 阵容固定断言通过（轮1 L8，10 批全部 E=["hero_03", "hero_29", "hero_36"] P=["hero_07", "hero_25", "hero_31"]）
[22:25:08]     阶段1 存活: r1_c1(5.98) | r1_c4(0.48)
[22:25:08]   --- 轮1 阶段2（1 seeds = 4 局/臂）---
[22:25:08]     L1 阶段2 → run=MS_R1_L1_s2 臂=3
[22:26:40]       | [league] arm consistency OK: every (seed, first) has ONE opponent identity across all 3 config(s) x 1 seed(s)
[22:26:40]       | [par] accounting: cells planned=6 completed=6 | games planned=12 produced=12
[22:26:40]       | [run] completeness: rows=12 duplicates=0 missing=0
[22:26:40]       | [run] completeness: rows=12 duplicates=0 missing=0
[22:26:40]   ✓ 阵容固定断言通过（轮1 L1，6 批全部 E=["hero_28", "hero_14", "hero_13"] P=["hero_12", "hero_06", "hero_48"]）
[22:26:40]     L2 阶段2 → run=MS_R1_L2_s2 臂=3
[22:29:43]       | [league] arm consistency OK: every (seed, first) has ONE opponent identity across all 3 config(s) x 1 seed(s)
[22:29:43]       | [par] accounting: cells planned=6 completed=6 | games planned=12 produced=12
[22:29:43]       | [run] completeness: rows=12 duplicates=0 missing=0
[22:29:43]       | [run] completeness: rows=12 duplicates=0 missing=0
[22:29:43]   ✓ 阵容固定断言通过（轮1 L2，6 批全部 E=["hero_33", "hero_34", "hero_15"] P=["hero_06", "hero_47", "hero_49"]）
[22:29:43]     L3 阶段2 → run=MS_R1_L3_s2 臂=3
[22:31:46]       | [league] arm consistency OK: every (seed, first) has ONE opponent identity across all 3 config(s) x 1 seed(s)
[22:31:46]       | [par] accounting: cells planned=6 completed=6 | games planned=12 produced=12
[22:31:46]       | [run] completeness: rows=12 duplicates=0 missing=0
[22:31:46]       | [run] completeness: rows=12 duplicates=0 missing=0
[22:31:46]   ✓ 阵容固定断言通过（轮1 L3，6 批全部 E=["hero_31", "hero_20", "hero_07"] P=["hero_03", "hero_47", "hero_22"]）
[22:31:46]     L4 阶段2 → run=MS_R1_L4_s2 臂=3
[22:34:48]       | [league] arm consistency OK: every (seed, first) has ONE opponent identity across all 3 config(s) x 1 seed(s)
[22:34:48]       | [par] accounting: cells planned=6 completed=6 | games planned=12 produced=12
[22:34:48]       | [run] completeness: rows=12 duplicates=0 missing=0
[22:34:48]       | [run] completeness: rows=12 duplicates=0 missing=0
[22:34:48]   ✓ 阵容固定断言通过（轮1 L4，6 批全部 E=["hero_29", "hero_24", "hero_21"] P=["hero_08", "hero_02", "hero_48"]）
[22:34:48]     L5 阶段2 → run=MS_R1_L5_s2 臂=3
[22:36:51]       | [league] arm consistency OK: every (seed, first) has ONE opponent identity across all 3 config(s) x 1 seed(s)
[22:36:51]       | [par] accounting: cells planned=6 completed=6 | games planned=12 produced=12
[22:36:51]       | [run] completeness: rows=12 duplicates=0 missing=0
[22:36:51]       | [run] completeness: rows=12 duplicates=0 missing=0
[22:36:51]   ✓ 阵容固定断言通过（轮1 L5，6 批全部 E=["hero_43", "hero_07", "hero_15"] P=["hero_28", "hero_37", "hero_22"]）
[22:36:51]     L6 阶段2 → run=MS_R1_L6_s2 臂=3
[22:38:24]       | [league] arm consistency OK: every (seed, first) has ONE opponent identity across all 3 config(s) x 1 seed(s)
[22:38:24]       | [par] accounting: cells planned=6 completed=6 | games planned=12 produced=12
[22:38:24]       | [run] completeness: rows=12 duplicates=0 missing=0
[22:38:24]       | [run] completeness: rows=12 duplicates=0 missing=0
[22:38:24]   ✓ 阵容固定断言通过（轮1 L6，6 批全部 E=["hero_27", "hero_31", "hero_32"] P=["hero_17", "hero_43", "hero_22"]）
[22:38:24]     L7 阶段2 → run=MS_R1_L7_s2 臂=3
[22:40:26]       | [league] arm consistency OK: every (seed, first) has ONE opponent identity across all 3 config(s) x 1 seed(s)
[22:40:26]       | [par] accounting: cells planned=6 completed=6 | games planned=12 produced=12
[22:40:26]       | [run] completeness: rows=12 duplicates=0 missing=0
[22:40:26]       | [run] completeness: rows=12 duplicates=0 missing=0
[22:40:26]   ✓ 阵容固定断言通过（轮1 L7，6 批全部 E=["hero_45", "hero_23", "hero_41"] P=["hero_20", "hero_29", "hero_35"]）
[22:40:26]     L8 阶段2 → run=MS_R1_L8_s2 臂=3
[22:41:59]       | [league] arm consistency OK: every (seed, first) has ONE opponent identity across all 3 config(s) x 1 seed(s)
[22:41:59]       | [par] accounting: cells planned=6 completed=6 | games planned=12 produced=12
[22:41:59]       | [run] completeness: rows=12 duplicates=0 missing=0
[22:41:59]       | [run] completeness: rows=12 duplicates=0 missing=0
[22:41:59]   ✓ 阵容固定断言通过（轮1 L8，6 批全部 E=["hero_03", "hero_29", "hero_36"] P=["hero_07", "hero_25", "hero_31"]）
[22:41:59]     阶段2 存活: r1_c1(5.98) | r1_c4(0.46)
[22:41:59]   --- 轮1 阶段3（1 seeds = 4 局/臂）---
[22:41:59]     L1 阶段3 → run=MS_R1_L1_s3 臂=3
[22:43:31]       | [league] arm consistency OK: every (seed, first) has ONE opponent identity across all 3 config(s) x 1 seed(s)
[22:43:31]       | [par] accounting: cells planned=6 completed=6 | games planned=12 produced=12
[22:43:31]       | [run] completeness: rows=12 duplicates=0 missing=0
[22:43:31]       | [run] completeness: rows=12 duplicates=0 missing=0
[22:43:31]   ✓ 阵容固定断言通过（轮1 L1，6 批全部 E=["hero_28", "hero_14", "hero_13"] P=["hero_12", "hero_06", "hero_48"]）
[22:43:31]     L2 阶段3 → run=MS_R1_L2_s3 臂=3
[22:46:34]       | [league] arm consistency OK: every (seed, first) has ONE opponent identity across all 3 config(s) x 1 seed(s)
[22:46:34]       | [par] accounting: cells planned=6 completed=6 | games planned=12 produced=12
[22:46:34]       | [run] completeness: rows=12 duplicates=0 missing=0
[22:46:34]       | [run] completeness: rows=12 duplicates=0 missing=0
[22:46:34]   ✓ 阵容固定断言通过（轮1 L2，6 批全部 E=["hero_33", "hero_34", "hero_15"] P=["hero_06", "hero_47", "hero_49"]）
[22:46:34]     L3 阶段3 → run=MS_R1_L3_s3 臂=3
[22:48:36]       | [league] arm consistency OK: every (seed, first) has ONE opponent identity across all 3 config(s) x 1 seed(s)
[22:48:36]       | [par] accounting: cells planned=6 completed=6 | games planned=12 produced=12
[22:48:36]       | [run] completeness: rows=12 duplicates=0 missing=0
[22:48:36]       | [run] completeness: rows=12 duplicates=0 missing=0
[22:48:36]   ✓ 阵容固定断言通过（轮1 L3，6 批全部 E=["hero_31", "hero_20", "hero_07"] P=["hero_03", "hero_47", "hero_22"]）
[22:48:36]     L4 阶段3 → run=MS_R1_L4_s3 臂=3
[22:51:08]       | [league] arm consistency OK: every (seed, first) has ONE opponent identity across all 3 config(s) x 1 seed(s)
[22:51:08]       | [par] accounting: cells planned=6 completed=6 | games planned=12 produced=12
[22:51:08]       | [run] completeness: rows=12 duplicates=0 missing=0
[22:51:08]       | [run] completeness: rows=12 duplicates=0 missing=0
[22:51:08]   ✓ 阵容固定断言通过（轮1 L4，6 批全部 E=["hero_29", "hero_24", "hero_21"] P=["hero_08", "hero_02", "hero_48"]）
[22:51:09]     L5 阶段3 → run=MS_R1_L5_s3 臂=3
[22:53:11]       | [league] arm consistency OK: every (seed, first) has ONE opponent identity across all 3 config(s) x 1 seed(s)
[22:53:11]       | [par] accounting: cells planned=6 completed=6 | games planned=12 produced=12
[22:53:11]       | [run] completeness: rows=12 duplicates=0 missing=0
[22:53:11]       | [run] completeness: rows=12 duplicates=0 missing=0
[22:53:11]   ✓ 阵容固定断言通过（轮1 L5，6 批全部 E=["hero_43", "hero_07", "hero_15"] P=["hero_28", "hero_37", "hero_22"]）
[22:53:11]     L6 阶段3 → run=MS_R1_L6_s3 臂=3
[22:54:43]       | [league] arm consistency OK: every (seed, first) has ONE opponent identity across all 3 config(s) x 1 seed(s)
[22:54:43]       | [par] accounting: cells planned=6 completed=6 | games planned=12 produced=12
[22:54:43]       | [run] completeness: rows=12 duplicates=0 missing=0
[22:54:43]       | [run] completeness: rows=12 duplicates=0 missing=0
[22:54:43]   ✓ 阵容固定断言通过（轮1 L6，6 批全部 E=["hero_27", "hero_31", "hero_32"] P=["hero_17", "hero_43", "hero_22"]）
[22:54:43]     L7 阶段3 → run=MS_R1_L7_s3 臂=3
[22:56:46]       | [league] arm consistency OK: every (seed, first) has ONE opponent identity across all 3 config(s) x 1 seed(s)
[22:56:46]       | [par] accounting: cells planned=6 completed=6 | games planned=12 produced=12
[22:56:46]       | [run] completeness: rows=12 duplicates=0 missing=0
[22:56:46]       | [run] completeness: rows=12 duplicates=0 missing=0
[22:56:46]   ✓ 阵容固定断言通过（轮1 L7，6 批全部 E=["hero_45", "hero_23", "hero_41"] P=["hero_20", "hero_29", "hero_35"]）
[22:56:46]     L8 阶段3 → run=MS_R1_L8_s3 臂=3
[22:58:18]       | [league] arm consistency OK: every (seed, first) has ONE opponent identity across all 3 config(s) x 1 seed(s)
[22:58:18]       | [par] accounting: cells planned=6 completed=6 | games planned=12 produced=12
[22:58:18]       | [run] completeness: rows=12 duplicates=0 missing=0
[22:58:18]       | [run] completeness: rows=12 duplicates=0 missing=0
[22:58:18]   ✓ 阵容固定断言通过（轮1 L8，6 批全部 E=["hero_03", "hero_29", "hero_36"] P=["hero_07", "hero_25", "hero_31"]）
[22:58:18]     阶段3 存活: r1_c1(5.98)
[22:59:23] ===== 多阵容搜索 Tag=MS =====
[22:59:23]   英雄池: 49 个（hero_01..hero_49）
[22:59:23]   参数: 轮数=1 候选=4 σ=0.2 阵容=8 并发=4 分级seeds=1/1/1 搜索档beam=100 阵容种子=20260914
[22:59:23]   起点比例: "KILL_BONUS": 35, "FOCUS_FIRE_WEIGHT": 30, "GOLD_TAKE_VALUE": 26, "GOLD_TAKE_VALUE_LOW": 34, "GOLD_LOW_ATK": 4, "BUFF_TAKE_WEIGHT": 3, "THREAT_MOVE_DISCOUNT": 0.7, "OBSTACLE_DETOUR_WEIGHT": 4, "ENGAGE_PULL_PER_CELL": 1.2, "MAX_MOVE_OPTIONS": 16
[22:59:23] ===== 第 1 轮 开始 =====
[22:59:23]   L1  我方=[hero_12,hero_06,hero_48]  敌方=[hero_28,hero_14,hero_13]
[22:59:23]   L2  我方=[hero_06,hero_47,hero_49]  敌方=[hero_33,hero_34,hero_15]
[22:59:23]   L3  我方=[hero_03,hero_47,hero_22]  敌方=[hero_31,hero_20,hero_07]
[22:59:23]   L4  我方=[hero_08,hero_02,hero_48]  敌方=[hero_29,hero_24,hero_21]
[22:59:23]   L5  我方=[hero_28,hero_37,hero_22]  敌方=[hero_43,hero_07,hero_15]
[22:59:23]   L6  我方=[hero_17,hero_43,hero_22]  敌方=[hero_27,hero_31,hero_32]
[22:59:23]   L7  我方=[hero_20,hero_29,hero_35]  敌方=[hero_45,hero_23,hero_41]
[22:59:23]   L8  我方=[hero_07,hero_25,hero_31]  敌方=[hero_03,hero_29,hero_36]
[22:59:23]   候选 4 个 + 控制组 r1_best（围绕默认比例）
[22:59:23]   --- 轮1 阶段1（1 seeds = 4 局/臂）---
[22:59:23]     L1 阶段1 → run=MS_R1_L1_s1 臂=5
[23:01:56]       | [league] arm consistency OK: every (seed, first) has ONE opponent identity across all 5 config(s) x 1 seed(s)
[23:01:56]       | [par] accounting: cells planned=10 completed=10 | games planned=20 produced=20
[23:01:56]       | [run] completeness: rows=20 duplicates=0 missing=0
[23:01:56]       | [run] completeness: rows=20 duplicates=0 missing=0
[23:01:56]       | [league] arm consistency OK: every (seed, first) has ONE opponent identity across all 5 config(s) x 1 seed(s)
[23:01:56]       | [par] accounting: cells planned=10 completed=10 | games planned=20 produced=20
[23:01:56]       | [run] completeness: rows=20 duplicates=0 missing=0
[23:01:56]       | [run] completeness: rows=20 duplicates=0 missing=0
[23:01:56]   ✓ 阵容固定断言通过（轮1 L1，20 批全部 E=["hero_28", "hero_14", "hero_13"] P=["hero_12", "hero_06", "hero_48"]）
[23:01:56]     L2 阶段1 → run=MS_R1_L2_s1 臂=5
[23:06:29]       | [league] arm consistency OK: every (seed, first) has ONE opponent identity across all 5 config(s) x 1 seed(s)
[23:06:29]       | [par] accounting: cells planned=10 completed=10 | games planned=20 produced=20
[23:06:29]       | [run] completeness: rows=20 duplicates=0 missing=0
[23:06:29]       | [run] completeness: rows=20 duplicates=0 missing=0
[23:06:29]       | [league] arm consistency OK: every (seed, first) has ONE opponent identity across all 5 config(s) x 1 seed(s)
[23:06:29]       | [par] accounting: cells planned=10 completed=10 | games planned=20 produced=20
[23:06:29]       | [run] completeness: rows=20 duplicates=0 missing=0
[23:06:29]       | [run] completeness: rows=20 duplicates=0 missing=0
[23:06:29]   ✓ 阵容固定断言通过（轮1 L2，20 批全部 E=["hero_33", "hero_34", "hero_15"] P=["hero_06", "hero_47", "hero_49"]）
[23:06:29]     L3 阶段1 → run=MS_R1_L3_s1 臂=5

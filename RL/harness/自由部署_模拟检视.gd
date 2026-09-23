extends Node2D
## 【仿真检视器】在**真实 scenes/Main.tscn** 上开一局"自由部署"沙箱，并让你亲手考它：
## 把 RL/ai/AI_Battle.gd（候选版：内部模拟已与真实规则对齐）的**预测局面**，与真实 Battle
## 结算出的**实际局面**逐字段对拍，逐招给出 MATCH / DIFF。
##
## 为什么做成游戏内场景而不是又一个离线脚本：
##   离线脚本只告诉你最终比分，看不到"这一招之后我预测的盘面"长什么样。
##   这里把每一招的预测/实际并排摊开，还能自己摆位、自己出题（双控），
##   出问题时能当场看到是哪一格、哪一条字段先歪的。
##
## 默认 = 现在的"自由部署"原样（双控、玩家自己操作双方），本场景**不干预任何操作**；
## 只有把「敌方控制」切成某个 AI 之后，才接管敌方回合。
##
## 只读依赖 src/（BattleSnapshot.collect、Battle 的动作层、GameState 标志），本文件不实现任何规则。
##
## 手动：Godot 编辑器打开本场景 → F6 运行。
## 自检（无头，跑完自动退出）：
##   godot --headless --path <proj> --log-file <log> \
##       --scene res://RL/harness/自由部署_模拟检视.tscn -- --selftest 20

const FORK_PATH := "res://RL/ai/AI_Battle.gd"        # 候选版（内部模拟已与真实规则对齐）
const ORIG_PATH := "res://RL/ai/AI_Battle_原版.gd"    # 与 src/BattleAI.gd 字节一致（困难档口径）
const MAIN_SCENE := "res://scenes/Main.tscn"
const SNAP := preload("res://src/BattleSnapshot.gd")

# 演出节奏：数值照 src/EnemyReplay.gd 的常量抄（那个文件只读，不引用也不修改）。
# 只影响"看起来像不像生产"，不影响对拍正确性。
const TELL_GAP := 0.3    # 本回合第一招：亮起行动描边后、出手前的起手停顿
const HERO_GAP := 0.7    # 相邻两名不同英雄之间
const STEP_GAP := 0.25   # 同一名英雄"移动→出手"之间
const ACT_WALL_MS := 3000    # 等一招动画的上限（正常约 0.2~0.6s）
const ACT_WALL_FRAMES := 900
const SIDE_WALL_MS := 30000  # 等 _end_side 全程（回合末技能 + 0.8s 换边停顿）的上限
const SIDE_WALL_FRAMES := 4000
const READY_WALL_MS := 30000 # 等 Battle 开出第一个回合
const MAX_STEPS := 20000     # 驱动循环总步数上限（异常时空转也要能退出）
const BUSY_WALL_MS := 60000  # AI 出手超过该时长 → 看门狗把档位退回"手动"

const AI_MANUAL := 0
const AI_FORK := 1
const AI_ORIG := 2

# 沙箱默认摆位（与 RL/harness/对局.gd 一致，便于两边对照着看；想换人直接改这两行）
const E_DECK: Array[String] = ["hero_06", "hero_17", "hero_26"]
const P_DECK: Array[String] = ["hero_13", "hero_12", "hero_23"]
const E_CELLS: Array[Vector2i] = [Vector2i(1, 2), Vector2i(3, 2), Vector2i(1, 1)]
const P_CELLS: Array[Vector2i] = [Vector2i(1, 4), Vector2i(3, 4), Vector2i(1, 5)]

# 对拍用的状态位：[SimUnit 的布尔字段名, StatusDB 的状态名, 界面短名]。
# 注意字段名必须与 RL/ai/AI_Battle.gd 里 SimUnit 的成员一致（是 poisoned 不是 poison），
# 否则 s.get() 取到 null，会被误判成"预测没有这个状态"。
const STATUSES := [
	["stunned", StatusDB.STUN, "晕"], ["silenced", StatusDB.SILENCE, "默"],
	["shield", StatusDB.SHIELD, "盾"], ["heavy", StatusDB.HEAVY, "伤"],
	["poisoned", StatusDB.POISON, "毒"], ["frozen", StatusDB.FREEZE, "冻"],
	["atkdown", StatusDB.ATKDOWN, "麻"], ["thorn", StatusDB.THORN, "棘"],
]

var _battle: Battle = null
var _rng := RandomNumberGenerator.new()
var _first_side := GameState.SIDE_PLAYER
var _desc_keys: Array = []      # 本回合 plan 对应的单位列表（下标 = plan 里的 idx）
var _plan_hero: Array = []      # 计划建立时刻各下标的 hero_id：用来识别"下标已位移"
var _ai = null                  # 当前 AI 模块实例（含本局注入的权重）
var _plan: Array = []
var _pi := 0
var _cur_act: Dictionary = {}
var _cur_idx := -1              # 当前这一招的单位下标（plan 里的 idx → _desc_keys 的下标）
var _new_hero := true           # 下一招是否换人（决定用 TELL_GAP/HERO_GAP 还是 STEP_GAP）
var _ai_busy := false           # AI 正在算/正在出手
var _ai_elapsed_ms := 0
var _recover := 0               # 驱动循环连续异常次数（防死循环）
var _steps := 0

# ---- 自检 ----
var _selftest := false
var _panecheck := false         # 只建面板并退出（用来验证 UI 代码本身不报错）
var _st_goal := 0
var _st_done := 0
var _st_match := 0
var _st_diff := 0
var _st_nopred := 0
var _st_process := 0            # 过程差异计数（绝对状态一致、仅时序/路径不同；不计入 DIFF）
var _st_span := 0               # 场外变化计数（本招期间有替补登场/延迟效果等；判"不可比"，不计入 DIFF）
var _st_timing := 0             # 已知采样时机差计数（差异**全部**是墓碑类；不计入 DIFF）
var _st_seen := {}              # 去重：同一步只计一次
## 交互状态"没人驱动"的看门狗阈值：某方专属的等交互状态持续超过这么久还没人管 → 告警。
## 8s 的取法：一次 AI 搜索最多约 6~8s（实测），所以"8 秒还没人动"已经明显不正常，
## 而正常的人工点击/自动接管都在毫秒级完成，不会误报。
const INTERACT_WALL_MS := 8000
var _sub_ev_key := ""           # 替补面板证据去重键（面板归属/档位/接管决定不变就不重复打）
var _sub_panel_open_ms := 0     # 本次替补面板的开启时刻（0=无面板）；用于"接管是否及时"报警
var _sub_panel_fn := -1         # 该面板归属阵营
var _sub_panel_mode := AI_MANUAL # 该面板阵营当时的档位
var _sub_panel_take := false    # 该面板当时是否由我们接管
var _bomb_ev_key := ""          # 炸弹接管证据去重键
var _interact_key := ""         # 交互状态看门狗：当前"状态|归属|接管"签名
var _interact_since := 0        # 该签名开始的时刻（ms）
var _interact_warned := false   # 当前签名是否已经告警过（只报一次，不刷屏）

# ---- 面板 ----
var _mode := AI_MANUAL           # 我方控制：手动（默认）/ RL候选AI
var _emode := AI_MANUAL          # 敌方控制：手动（默认）/ RL候选AI / 原版困难档
## 入口模式：true = 先显示英雄池选人界面（QuickTest）；false = 直接固定 3v3 快速沙箱。
## --selftest / --fixed3v3 走 false；手动游玩（F6）默认 true。
var _picker_mode := true
var _picker: QuickTest = null     # 嵌入的英雄池选人界面（QuickTest 实例）
var _randpicks := false           # `--randpicks`：随双方各 5 人（与界面按钮共用 _randomize_picks）
var _rand_btn: Button = null      # 选人界面上的「随机双方各5人」按钮（运行时挂到 QuickTest 上）
# ★ 「自动循环」按钮（用户新需求）：在「仿真检视器」面板里点一下就**一直自动打**——
#   每局双方各随机 5 人（10 人互不重复），一局打完自动回选人界面换一批再开；再点一下停。
#   复用现成路径：回选人 = `_on_back_to_select()`；新随机 5v5 + 开打 = `_randomize_picks(true)`
#   （与「随机双方各5人」按钮、`--randpicks` 是同一个函数），循环里没有第二份建局逻辑。
var _auto_loop := false           # 循环开关（按钮切换；循环协程每帧都检查，关掉就立刻退出）
var _auto_loop_n := 0             # 本次循环已打完并换局的局数（只用于显示与日志）
var _auto_btn: Button = null      # 面板里的「自动循环」按钮
var _beam_override := 0           # `--beam N`：命令行覆盖搜索宽度（0 = 用面板 SpinBox / 默认 800）
# 【2026-09-23 新增】`--weights <res://…json>`：命令行指定权重文件。
# 为什么必须有：本场景的默认权重是 `res://RL/weights/base.json`（= src/BattleAI.gd 的 const 抄录，
# 困难档 12 项），而**无头自检不建面板** ⇒ 没有这个开关时，`verify_heroes.ps1` 的 L3 永远跑困难档基线，
# `噩梦.json` 的那 21 个通用键 + 7 个英雄段（尤其是只从权重读的 `SEARCH_MODE`）压根不生效。
# 空串 = 不覆盖，行为与以前逐位一致。
var _weights_cli := ""
var _auto_cli := false            # `--autoloop`：无头验证入口（启动即开循环，与按钮同一回调）
var _auto_rounds := 0             # `--autoloop-rounds N`：跑完 N 局就停并退出（0 = 一直跑）
const AUTO_LOOP_BEAM := 50        # 自动循环（= 扫 DIFF，不训练）默认的搜索宽度
var _picker_sel_p: Array[String] = []   # 上一轮我方勾选：拆除选人界面时留存，回来时还原
var _picker_sel_e: Array[String] = []   # 上一轮敌方勾选
var _deployed := false           # 战场已建好、进入正式对局（部署阶段不能当回合推进）
var _run_gen := 0                # 驱动循环代际号：重建沙箱 +1，旧 _run() 协程据此自行作废
var _restarting := false         # 正在重建沙箱（防止重入、防止两套 _run() 并行）
var _demo_counter := false       # 演示/取证：每回合人为造一次近战攻击，用来产出含反击的对拍块
var _test_picks := false         # 取证：脚本化走"英雄池勾选 → 开始对局"并核对勾选是否真的上场
var _test_back := 0              # 取证（--test-back N）：打完 N 招后，在 AI 正在后台搜索时点「返回选人」
var _test_back_fired := false    # 取证：返回选人只触发一次
var _align_checked := false      # descs ↔ units 下标对齐自检是否已做
var _hb_ms := 0                  # 心跳节流（长跑自证在推进）
var _test_play := false          # 取证（--test-play）：脚本化开一局并驱动到对局结束，然后打机读断言
var _test_restart := false       # 取证（--test-restart）：跑到一局结束后触发「再来一局」，验证新局 AI 继续动
var _restart_keep_decks := false # "再来一局"语义：沿用本局双方卡组（不重新选人）
var _sim_panel_clicks := false   # 取证（--sim-panel-clicks）：程序化点面板档位按钮，验交互路径真的改了档位
var _rehook_acc := 0             # 结算期间周期性重挂「再战一局」的节流计数
var _deploy_wait_key := ""       # 部署等待看门狗：当前"轮到谁|状态"签名
var _deploy_wait_ms := 0         # 该签名开始的时刻（ms）
var _deploy_wait_logged := false # 是否已经提示过（只提示一次，不刷屏）
var _hold_key := ""              # "回合限时抑制"证据去重键（回合|行动方，见 _hold_driven_turn_timer）
var _build_tag := ""             # 构建戳（脚本 sha 前 12 位）：控制台第一行 + 面板状态行
var _sub_signal_fn := -1         # 游戏通过 `sub_select_requested` 通知"替补面板开了"的阵营（-1=无）
var _sub_signal_ms := 0          # 该通知的时刻（ms）
var _sub_diag_key := ""          # 替补诊断去重键
var _sub_state_seq: Array = []   # 本面板期间 state 变化序列（带相对 ms）
var _sub_last_state := -1
var _sub_first_try_ms := 0       # 本面板第一次驱动尝试的时刻（0=还没试过）
var _sub_first_try_txt := "未尝试"
var _sub_place_ok_ms := 0        # 本面板落位成功的时刻（0=未成功）
var _sub_last_hero := "-"        # 本面板选中的人
var _sub_last_cell := "-"        # 本面板落的格
var _sub_sample_ms := 0          # [替补·采样] 节流
var _sub_said_key := ""          # [替补] 控制台行去重键（每面板一行）
var _rt_dir := ""                # 带时间戳的本局日志目录（res://RL/reports/rt）
var _rt_stamped_path := ""       # 本局日志文件（带时间戳）
var _rt_fixed_path := ""         # 固定名镜像（始终=最新一局）
var _rt_mirror: FileAccess = null # 固定名那份的文件句柄
var _rt_no_mirror := false       # 环境变量 `ZB_NO_MIRROR=1` → 关掉固定名镜像（并行验证用）
var _rt_explicit := false        # 命令行**显式**给了 `--rtlog <路径>`（该路径是调用方点名要的证据文件）
var _prog_key := ""              # 停摆看门狗：推进指纹（回合|行动方|已出块数|代际）
var _prog_ms := 0                # 上次"有推进"的时刻（ms）
var _rt_battles_opened := 0      # 已经开过几局（>0 时建新局要**换一个新日志文件**）
var _sim_audit_done := false     # sim 字段存在性自检是否已做
var _audit_probe := ""           # 取证（--audit-probe <字段名>）：故意塞一个假字段名，证明自检非空跑
var _last_verdict := ""          # 刚打完那一招的判定（供"盘面分叉重算"用）
var _replan_on_diff := true      # 开关：字段级 DIFF 时作废剩余计划并立刻重算（默认开）
var _replan_count := 0           # 本回合已重算次数
const REPLAN_MAX_PER_TURN := 3   # 每回合重算上限（防止"一直分叉一直重算"烧时间）
var _chk_count := 0              # 产出的对拍块总数（各路径通用，供 --test-play/--test-restart 断言）
var _play_wall := 600            # 取证：驱动到对局结束的时限（秒），--play-wall 可改
var _sub_placed := 0             # 累计替补落位数（Battle.sub_placed 信号，含所有路径）
var _last_winner := -99          # 最近一次对局结果（GameState.match_ended 信号，-1=平局）
var _picks_p: Array[String] = [] # 取证（--picks "a,b,c" "d,e,f"）：指定的双方卡组（逗号分隔，3~5 人）
var _picks_e: Array[String] = []
var _watch_locked := false       # 当前是否处于"观战锁"（= 行动方由 AI 驱动，玩家不可操作）
var _watch_side_locked := -1     # 当前锁住的是哪一边（-1 = 未锁）；用于避免重复打日志
var _rt_file: FileAccess = null  # 运行时日志文件：除对拍块外的一切自有输出都写这里（不进控制台）
var _panel: Control = null
var _panel_expanded_size := Vector2.ZERO   # 展开态面板尺寸（折叠时缩到标题行、展开时还原）
var _scroll: ScrollContainer = null
var _fold_btn: Button = null
var _mode_btns: Array = []
var _emode_btns: Array = []
var _speed_check: CheckBox = null
var _speed_hint: Label = null
var _w_cache: Dictionary = {}     # 权重 JSON 缓存（键 = 路径+mtime+长度，见 _load_weights）
var _w_cache_key := ""

# ---- 后台搜索（照抄 src/Battle.gd:5033-5047 的线程范式，避免主线程被 beam 搜索冻住）----
var _ai_thread: Thread = null      # 正在跑 search() 的后台线程
var _search_lock := Mutex.new()    # 保护 _search_holder（也传给 worker 用，见 _search_worker）
var _search_active := false        # 是否正在思考（面板显示"AI 思考中…"）
var _search_start_ms := 0          # 本次搜索起始时刻（面板显示"已 X ms"）
var _search_side := 0              # 本次搜索属于哪一方
var _search_mode := 0              # 本次搜索用的档位
var _search_holder := SearchHolder.new()   # 线程 → 主线程的结果搬运箱（见 _search_async）
var _w_path_edit: LineEdit = null
var _w_path_label: Label = null
var _beam_spin: SpinBox = null
var _jitter_spin: SpinBox = null
var _status_label: Label = null


## 打开运行时日志文件（每次运行覆盖写）。默认 res://RL/reports/对拍_运行时.log，
## 可用 --rtlog <路径> 覆盖。所有"不给用户看、但必须留证据"的输出都写这里（如 SIMCHK 机读行、
## 锁断言、替补链路、状态/调试信息），控制台只留对拍块。
## 打开运行时日志。**每局一份带时间戳的文件** + 一份固定名的"最新一局"镜像：
##   · `res://RL/reports/rt/对拍_运行时_<MMDD_HHMMSS>.log` —— 本局的完整证据（不再被下一局覆盖）；
##   · `res://RL/reports/对拍_运行时.log`（或 `--rtlog <路径>`）—— 始终指向**最新一局**，方便随时看。
## 为什么（用户踩过）：原来每次运行都覆盖同一个文件，用户"上一局的输出"与"这一局的日志"对不上，
## 排查时证据已经丢了。现在三方都能"回到那一局"。
## 保留最近 20 份，旧的自动删（删前不问）。
func _open_runtime_log(ua: Array) -> void:
	_rt_fixed_path = "res://RL/reports/对拍_运行时.log"
	for i in ua.size():
		if String(ua[i]) == "--rtlog" and i + 1 < ua.size():
			_rt_fixed_path = String(ua[i + 1])
			_rt_explicit = true
	_rt_dir = "res://RL/reports/rt"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_rt_dir))
	_rt_stamped_path = "%s/对拍_运行时_%s.log" % [_rt_dir, _stamp_txt()]
	_rt_file = FileAccess.open(_rt_stamped_path, FileAccess.WRITE)
	# ★ 并行验证开关（环境变量门控）：`ZB_NO_MIRROR=1` 时**跳过固定名镜像**。
	# 为什么：固定名 `RL/reports/对拍_运行时.log` 是"最新一局"的镜像，**也是并行实例的唯一共享写点**
	# （多开会互相覆盖）。关掉它之后，多个验证实例各自的证据都只落在自己的时间戳日志里 → 可并行。
	# 默认（不设该变量）行为与以前**完全一致**：用户手动 F6 仍能看到固定名镜像，方便找日志。
	# ★★ 但**显式 `--rtlog <路径>` 不受这个开关影响**（本轮修正的回归）：
	#   调用方（`Data/Hero/Source/verify_heroes.ps1` 的 sweep 层，每个英雄一个独立文件名）点名要的那份文件是
	#   它随后要解析的**唯一**机读证据源；把它当成"共享写点"一起关掉，解析端就只能读到
	#   不存在的文件 → `simChecks=0`（实测：ZB_NO_MIRROR=1 时 `--rtlog` 那份**根本没被创建**）。
	#   显式路径本来就由调用方自己保证不撞车（并行实例给不同文件名），所以照写。
	_rt_no_mirror = OS.get_environment("ZB_NO_MIRROR") == "1"
	_rt_mirror = FileAccess.open(_rt_fixed_path, FileAccess.WRITE) if (_rt_explicit or not _rt_no_mirror) else null
	if _rt_file == null:
		push_warning("[检视器] 运行时日志无法写入：%s（机读证据会缺失，但不影响对拍）" % _rt_stamped_path)
		return
	_write_both("# ===== 本局运行时日志（每局一份，带时间戳）=====")
	_write_both("# 本局文件：%s" % _rt_stamped_path)
	var mirror_note := "（可用 --rtlog <路径> 覆盖，覆盖后本行末会写明）"
	if _rt_explicit:
		mirror_note = "（命令行 --rtlog **显式指定** → 即使 ZB_NO_MIRROR=1 也照写）"
	elif _rt_no_mirror:
		mirror_note = "　**已按 ZB_NO_MIRROR=1 关闭**（并行验证用：避免多实例互相覆盖）"
	_write_both("# 固定名镜像：%s%s" % [_rt_fixed_path, mirror_note])
	_write_both("# 构建戳：%s（脚本 sha256 前 12 位；与面板状态行/控制台首行一致）" % _build_tag)
	_write_both("# 启动时间：%s" % Time.get_datetime_string_from_system(false, true))
	_write_both("# 规则：先看下面的 [规则] 行（正常对战 / 沙箱）")
	_write_both("# 控制台只打这几类短行：构建戳 / [驱动] 启动 / [替补] / [部署] 完成 / [告警] / 对拍块；")
	_write_both("# 其余（[替补·接管] 逐步、[替补·采样]、[耗时]、[每回合状态注入]、[一致性]、部署逐手明细）只在本文件。")
	_write_both("# 机器可读对拍证据：下面的 SIMCHK| 逐招行 + SIMCHK|SUMMARY| 汇总行。")
	_prune_rt_files()


## 时间戳（MMDD_HHMMSS）用于文件名。
func _stamp_txt() -> String:
	var d := Time.get_datetime_dict_from_system(false)
	return "%02d%02d_%02d%02d%02d" % [int(d["month"]), int(d["day"]), int(d["hour"]),
		int(d["minute"]), int(d["second"])]


## 新一局（含"再来一局"/重建沙箱）：**换一个新日志文件**，别把上一局的证据覆盖掉。
## 注意：同一秒内连续换局会撞同名文件（第二次会截断第一次）——极端情况，实际不会遇到。
func _rotate_runtime_log(tag: String) -> void:
	if _rt_file != null:
		_rt_file.flush()
		_rt_file.close()
		_rt_file = null
	if _rt_mirror != null:
		_rt_mirror.flush()
		_rt_mirror.close()
		_rt_mirror = null
	_rt_stamped_path = "%s/对拍_运行时_%s.log" % [_rt_dir, _stamp_txt()]
	_rt_file = FileAccess.open(_rt_stamped_path, FileAccess.WRITE)
	# 换局时同样遵守 `ZB_NO_MIRROR`（并行验证：固定名是唯一共享写点，必须能整体关掉）；
	# 但**显式 `--rtlog` 那条不算共享写点**（路径由调用方点名、并行实例各不相同）→ 照旧重开，
	# 否则"第 2 局起"的 SIMCHK 机读证据又会消失（与 `_open_runtime_log` 同一条回归）。
	_rt_mirror = FileAccess.open(_rt_fixed_path, FileAccess.WRITE) if (_rt_explicit or not _rt_no_mirror) else null
	if _rt_file == null:
		push_warning("[检视器] 新一局日志无法写入：%s" % _rt_stamped_path)
		return
	_write_both("# ===== 新一局运行时日志（%s）=====" % tag)
	_write_both("# 本局文件：%s" % _rt_stamped_path)
	var mirror_note2 := "（=最新一局）"
	if _rt_explicit:
		mirror_note2 = "（命令行 --rtlog 显式指定 → 照写）"
	elif _rt_no_mirror:
		mirror_note2 = "　**已按 ZB_NO_MIRROR=1 关闭**"
	_write_both("# 固定名镜像：%s%s" % [_rt_fixed_path, mirror_note2])
	_write_both("# 构建戳：%s  开新局时间：%s" % [_build_tag, Time.get_datetime_string_from_system(false, true)])
	_prune_rt_files()


## 只保留最近 20 份带时间戳的运行时日志（按文件名排序 = 时间序）。
func _prune_rt_files() -> void:
	var dir := DirAccess.open(_rt_dir)
	if dir == null:
		return
	var names: Array = []
	for f in dir.get_files():
		if String(f).begins_with("对拍_运行时_") and String(f).ends_with(".log"):
			names.append(String(f))
	names.sort()
	while names.size() > 20:
		var old := String(names.pop_front())
		dir.remove(old)


func _ready() -> void:
	var ua := OS.get_cmdline_user_args()
	_selftest = _has_switch(ua, "--selftest")
	_st_goal = _arg_after(ua, "--selftest", 20) if _selftest else 0
	_first_side = _arg_after(ua, "--first-side", GameState.SIDE_PLAYER)
	_rng.seed = _arg_after(ua, "--seed", 20250911)
	# ★ 构建戳要先算：日志文件头里也要写它（踩过：先开日志后算戳 → 文件头那行是空的）。
	_build_tag = _compute_build_tag()
	_open_runtime_log(ua)
	# ★ 构建戳：**控制台第一行**（用户就靠它确认"我跑的是哪一版"——踩过"用户跑的是旧构建、
	# 我一直在新代码里找修复"的坑）。取脚本自身 sha 前 12 位；读不到（导出后 .gd 不可读）
	# 就退回编译期常量，绝不因此不打印。
	_say_console("=== 模拟检视 构建=%s ===" % _build_tag)
	_log("[构建] 脚本 res://RL/harness/自由部署_模拟检视.gd 的 sha256 前 12 位 = %s" % _build_tag)
	_panecheck = _has_switch(ua, "--panecheck")   # 只建面板做个自检，然后退出
	if _has_switch(ua, "--gate-check"):
		# 取证（不用开战场）：TIMING 硬闸门 + 分桶的离线自检（用用户那一招的真实数据）
		_run_gate_check()
		return
	# ★ 默认档位（用户口径 2026-09-13）：**双方都默认「RL候选AI」**，不必每次进场景手动设一遍。
	#   CLI 仍可覆盖：`--pai 0/1`（我方）、`--ai 0/1/2`（敌方）。
	var st_ai := _arg_after(ua, "--ai", AI_FORK)     # 敌方档（1=候选 2=原版），默认=候选
	var st_pai := _arg_after(ua, "--pai", AI_FORK)   # 我方档（0=手动 1=候选 2=原版），默认=候选
	# 加速档（用户口径：默认 ×4）：`--speed <倍率>` 覆盖；只缩放 `Engine.time_scale`（观感），
	# **不碰任何规则/结算顺序**。0/1 = 正常速度；面板上那个勾选框仍是"开=×4 / 关=×1"。
	var st_speed := _arg_after(ua, "--speed", 4)
	st_speed = clampi(st_speed, 0, 20)
	var speed_from_cli := _arg_given(ua, "--speed")
	# `--beam N`：命令行覆盖搜索宽度（用户口径：**只是扫 DIFF 时不必用大 beam**）。
	# 无头模式不建面板（`_build_panel` 直接返回），所以必须留一个独立覆盖值，否则永远吃默认 800。
	# 注意它只影响"AI 选哪一招"，不影响对拍判定（判定比的是"选中那招的预测 vs 真实"）。
	var beam_from_cli := _arg_given(ua, "--beam")
	_beam_override = clampi(_arg_after(ua, "--beam", 0), 0, 8000)
	var fixed3v3 := _has_switch(ua, "--fixed3v3")  # 显式走固定 3v3 快速沙箱
	_demo_counter = _has_switch(ua, "--demo-counter")  # 取证：人为造近战攻击以产出含反击的对拍块
	_test_picks = _has_switch(ua, "--test-picks")      # 取证：脚本化走一遍"勾选→开始对局"并核对
	_test_play = _has_switch(ua, "--test-play")        # 取证：脚本化开一局并驱动到对局结束
	_test_restart = _has_switch(ua, "--test-restart")  # 取证：一局结束后触发「再来一局」，验证新局 AI 继续动
	_sim_panel_clicks = _has_switch(ua, "--sim-panel-clicks")  # 取证：程序化点档位按钮（验证交互路径）
	_randpicks = _has_switch(ua, "--randpicks")                # 随机双方各 5 人（与界面按钮同一函数）
	_auto_cli = _has_switch(ua, "--autoloop")                  # 无头验证：启动即开「自动循环」（与面板按钮同一回调）
	_auto_rounds = _arg_after(ua, "--autoloop-rounds", 0)      # 自动循环跑完 N 局就停并退出（0 = 一直跑）
	# 自动循环是"扫 DIFF"用的（不训练）→ 没显式给 `--beam` 就默认小 beam，省机器：
	# 搜索宽度只决定"AI 选哪一招"，判定仍然是"选中那招的预测 vs 真实"，扫 DIFF 不需要大 beam。
	if _auto_cli and _beam_override <= 0:
		_beam_override = AUTO_LOOP_BEAM
	_audit_probe = _arg_str_after(ua, "--audit-probe", "")     # 取证：给 sim 字段自检塞一个假字段名
	# `--weights <res://…json>`（2026-09-23 新增）：命令行指定权重文件；空 = 用面板默认（base.json）。
	# 只影响"AI 选哪一招"，不影响对拍判定口径（判定仍是"选中那招的预测 vs 真实"），
	# 但它决定**新键（SEARCH_MODE / SPLIT_W / FORM_* / hero_XX 段）到底有没有生效**。
	_weights_cli = _arg_str_after(ua, "--weights", "")
	if _weights_cli != "":
		_log("[取证] --weights 指定权重文件：%s（存在=%s）" % [
			_weights_cli, str(FileAccess.file_exists(_weights_cli))])
	_play_wall = _arg_after(ua, "--play-wall", 600)    # 取证：驱动到结束的时限（秒）
	# 取证（--picks "我方1,我方2,..." "敌方1,敌方2,..."）：指定双方卡组，
	# 配合 --test-picks / --test-play 做"英雄轮换扫描"（没有它就只能扫固定那 6 个英雄）。
	var pr := _arg_pair_after(ua, "--picks")
	if pr.size() == 2:
		_picks_p = _split_ids(String(pr[0]))
		_picks_e = _split_ids(String(pr[1]))
		_log("[取证] --picks 指定阵容：我方=%s（%d 人）/ 敌方=%s（%d 人）" % [
			str(_picks_p), _picks_p.size(), str(_picks_e), _picks_e.size()])
	# --test-back N：打完 N 招后在"AI 正在后台搜索"时点「返回选人」（见 _on_back_to_select）
	_test_back = _arg_after(ua, "--test-back", 0)
	# 入口（用户口径）：**一进来就是英雄池选人界面**——嵌的是用户自己的自由部署界面
	# res://scenes/QuickTest.tscn（自己给自己/对方挑英雄），不是 Battle 的"开局部署·轮流上首发"。
	# 例外：--selftest 无头跑不了真人点选、且要求确定性，一律固定 3v3；--fixed3v3 同。
	# **再例外**：给了 `--picks "我方" "敌方"` 就一定要走英雄池那条路（那才是用户实际流程），
	# 这样 `--selftest --picks …` 也能扫"指定阵容"（49 英雄轮换扫描就靠它）。
	var use_picks := _picks_p.size() > 0 or _picks_e.size() > 0 or _randpicks or _auto_cli
	_picker_mode = not (_selftest or fixed3v3) or use_picks
	_build_panel()
	# `--beam`：面板已建好 → 把覆盖值同步进 SpinBox（面板显示的就是实际生效值；用 no_signal 避免
	# 在建局前触发 `_apply_weights()`），并留一行证据。
	if _beam_override > 0:
		if _beam_spin != null:
			_beam_spin.set_value_no_signal(float(_beam_override))
		_log("[检视器] --beam %d：本次搜索宽度=%d（来自 %s；只影响 AI 选招，不影响对拍判定）" % [
			_beam_override, _beam_override,
			"命令行" if beam_from_cli else "自动循环默认（扫 DIFF 不必用大 beam）"])
	# ★ 档位必须在这里应用，**不能只放在 `if _selftest:` 里**：
	# 否则 `--test-picks --pai 1 --ai 1` 这种非自检的取证运行会静默地两边都按"手动"跑
	# （踩过：部署只上了敌方 1 个人就卡住，查了半天才发现 `_mode/_emode` 还是 0）。
	# 默认值已按用户口径改成"双方=RL候选AI"（见上面 st_ai / st_pai 的注释）。
	_apply_emode(clampi(st_ai, AI_MANUAL, AI_ORIG))
	_apply_mode(clampi(st_pai, AI_MANUAL, AI_FORK))
	# 加速档：默认 ×4（`--speed` 可覆盖）。`Engine.time_scale` 只影响演出/等待时长，不改规则。
	Engine.time_scale = 1.0 if st_speed <= 1 else float(st_speed)
	if _speed_check != null:
		_speed_check.button_pressed = Engine.time_scale > 1.0
	# ★ 生效设置一行（控制台 + 文件各一行）：一眼验证"默认值真的生效 / CLI 覆盖也对"
	_say_console("[设置] 我方档=%s 敌方档=%s 加速=x%s（来源：我方=%s 敌方=%s 加速=%s）" % [
		_ai_name(_mode), _ai_name(_emode), ("%.0f" % Engine.time_scale),
		"CLI" if _arg_given(ua, "--pai") else "默认",
		"CLI" if _arg_given(ua, "--ai") else "默认",
		"CLI" if speed_from_cli else "默认"])
	if _selftest:
		if _panel != null:
			_panel.visible = false      # 自检不摆面板
		_log("[检视器] selftest 参数：我方档=%d 敌方档=%d（user_args=%s）" % [
			clampi(st_pai, AI_MANUAL, AI_FORK), clampi(st_ai, AI_MANUAL, AI_ORIG), str(ua)])
	if _picker_mode:
		# 选人模式：**先不建战场**，只显示英雄池选人界面；点它的「开始对局」才在检视器内部建战场
		_log("[检视器] 入口=英雄池选人界面（QuickTest）：挑好双方队伍后点「开始对局」")
		_show_picker()
		if _sim_panel_clicks:
			# 取证（交互路径）：程序化点面板的档位按钮，验证"点了按钮档位真的变了"。
			# 为什么需要它：`--selftest` 里手动那方的替补面板会被 `_auto_sub_on_timeout()` 强推完，
			# **掩盖了交互路径的真实问题**（用户遇到的正是交互路径）→ 必须单独取证。
			await _sim_click_mode_buttons()
		if _test_picks:
			# 取证用：脚本化地"勾选"英雄再点开始，用来证明勾选结果真的上场（见 _test_picks_run）
			_test_picks_run()
		elif _picks_p.size() > 0 or _picks_e.size() > 0:
			# `--picks "我方" "敌方"`：**走英雄池路径本身**（_on_quicktest_start 那套 GameState 组装，
			# 不另开旁路），只是把"勾选"换成命令行给的名单 → 随后由 _run() 正常驱动。
			# 与 `--selftest` 组合时同样走这里：自检循环照旧计数/打 SUMMARY，阵容换成指定的。
			_apply_picks_and_start()
		elif _randpicks:
			# `--randpicks`：与界面上的「随机双方各5人」按钮**同一个函数**（同一路径），并直接开打
			# （无头验证用：按钮只是它的 UI 入口）。
			_randomize_picks(true)
		elif _auto_cli:
			# `--autoloop`：无头验证入口 —— 与面板按钮**同一个回调** `_on_auto_toggle()`，只是不用手点。
			# 它内部自己会"随机 5v5 + 开打"，所以这里不再单独随机。
			_on_auto_toggle()
	else:
		_setup()
		_deployed = true     # 固定 3v3/自检：建局即已进入对局（选人模式要等点「开始对局」）
	if _panecheck:
		# 面板结构自检：与入口模式无关，所以放在两条分支**之后**统一做（否则选人模式下永远不退出）
		_log("[检视器] panecheck：面板已建（%s，入口=%s）" % [
			"有" if _panel != null else "无", "英雄池选人" if _picker_mode else "固定3v3"])
		# 容器布局要到下一帧才跑完：不等的话 head/_scroll 的全局矩形全是 0 尺寸，
		# "遮挡"判定会退化成"两个空矩形不相交"的假绿。等两帧再断言。
		await get_tree().process_frame
		await get_tree().process_frame
		# _fold_assert 现在含 await（改尺寸后要等帧再量矩形），所以必须 await 调用：
		# 不 await 的话协程只跑到第一个 await 就返回，断言日志会一行都不打（踩过）。
		await _fold_assert()
		_log("[检视器] panecheck 完成（详情见本文件上面的 fold-check 行）")
		# 控制台只留一行"面板自检完成"，不违反"控制台只放对拍块"的口径（用户要看的是对拍块）。
		print("[panecheck] 面板自检完成，详见运行时日志")
		get_tree().quit(0)
		return
	if not _picker_mode:
		_run.call_deferred()


# ================= 建局 =================

## 就地重建沙箱（"自己选人"勾选/取消、点「返回选人」都走这里）。
## 为什么要**代际号**：_run() 是个长驻协程，重建时若只是把 _battle 换掉，旧协程还会继续跑，
## 于是出现"两套驱动并行"——旧循环拿着已释放的 Battle 乱走、新循环同时推进同一个对局。
## 做法：先 _run_gen += 1，旧循环在每轮开头与各 await 之后都比对代际号，不一致即自行 return。
## 顺序很重要：
##   ① 作废旧循环 → ② 先回收后台搜索线程（否则线程还会往旧 holder 写结果）→ ③ 清实例状态
##   → ④ queue_free 旧 Battle 并**等它真的离开场景树**（HUD/按钮都是它的子节点，必须等干净）
##   → ⑤ 重置 GameState → ⑥ 要么重新建局(_setup())、要么回到英雄池选人界面 → ⑦ 重启驱动循环。
## 入口模式是"选人"时**不建战场**：只把选人界面重新显示出来（并在点「开始对局」时才建）。
func _rebuild_sandbox() -> void:
	if _restarting:
		return
	_restarting = true
	_run_gen += 1                       # ① 作废旧驱动循环
	# ①.5 显式解锁：**任何"解锁/重建"的入口都不许依赖锁本身**。
	# 用户实机踩过：锁生效时「返回选人」被禁用 → 他唯一的出路没了。现在按钮永远可点，
	# 这里再保证"点下去之后锁一定被释放"（输入开关恢复、按钮恢复、两个锁变量复位），
	# 不依赖"新一局 _sync_watch_lock 会自然过渡"这种间接路径。
	_release_watch_lock()
	_stop_search_thread()               # ② 线程先落地：回收 + 作废其待用结果
	_reset_instance_state()             # ③ 清实例状态（含代际号之外的一切运行痕迹）
	if _battle != null and is_instance_valid(_battle):
		_battle.queue_free()
		_battle = null
		# 等旧 Battle（连同它的 HUD 与按钮）真正离开场景树：否则新局的 HUD 会和残留的叠在一起
		for i in 60:
			if get_tree() == null:
				break
			await get_tree().process_frame
			if _old_battle_gone():
				break
	_deployed = false
	# ⑤ 清对局状态。
	# ★ "再来一局"要**沿用本局双方卡组**（游戏自己的语义：`battle.reset_match()` 就地重开、
	#   不重新选人），所以这条路上先把卡组存下来，`reset_online()` 之后原样放回。
	var keep_p: Array = GameState.player_deck.duplicate() if _restart_keep_decks else []
	var keep_e: Array = GameState.enemy_deck.duplicate() if _restart_keep_decks else []
	GameState.reset_online()            # 清对局状态（match_over/arena_mode/active_side/回合数/decks…）
	if _restart_keep_decks:
		GameState.player_deck = keep_p
		GameState.enemy_deck = keep_e
		_log("[检视器] 再来一局：沿用本局卡组（我方 %d 人 / 敌方 %d 人），重新走一遍部署" % [
			keep_p.size(), keep_e.size()])
	GameState.match_over = false
	GameState.round_number = 1
	GameState.active_side = GameState.SIDE_PLAYER
	_restarting = false
	if _restart_keep_decks:
		# ⑥ "再来一局"：不换场景、不回选人界面，就地重建战场并重走部署
		_rebuild_for_rematch()
		return
	if _picker_mode:
		# 回到英雄池选人界面（保留上次勾选，方便微调）；战场等点「开始对局」再建
		_show_picker()
		_log("[检视器] 已回到英雄池选人界面（战场已拆除）")
		return
	_setup()                            # ⑥ 固定 3v3 快速沙箱
	_hook_hud_back_button()             # ⑦ HUD/按钮是新实例，必须重新挂接
	_hook_restart_buttons()             # 「重开」/「再战一局」也要重新拦截
	_reapply_modes_after_rebuild()      # 档位重挂牌（新一局必须还在 AI 档上，否则"AI 不动"）
	_deployed = true
	_log("[检视器] 已重建沙箱：固定 3v3 快速沙箱")
	_run.call_deferred()                # ⑧ 新代际的驱动循环


## "再来一局"的重建：沿用本局卡组 → 重建战场 → **重新走 Battle 自己的部署流程** → 重启驱动。
## 与"返回选人"的区别只有一个：不回英雄池界面，直接开新一局（游戏原本的语义）。
func _rebuild_for_rematch() -> void:
	_picker_mode = false                # 在打对局：入口不是选人界面（否则重建会退回英雄池）
	_setup(true)                        # keep_picks=true：不覆盖刚放回的卡组；规则=正常对战
	_hook_hud_back_button()
	_hook_restart_buttons()
	_reapply_modes_after_rebuild()
	_deployed = false                   # 新一局要从部署开始：_deployment_tick 驱动 AI 那一边
	_log("[检视器] 再来一局：已重建战场（重新走部署流程），代际=%d，驱动已重启" % _run_gen)
	_run.call_deferred()


## 重建之后把档位重新"挂牌"：新一局 _mode/_emode 必须还在原来选的档上，
## 否则会出现"新一局 AI 不动"——根因就是档位只在 `_ready()` 里设过一次，
## 而「再来一局」是**就地重开**（不重新加载场景、不会再跑 _ready）。
func _reapply_modes_after_rebuild() -> void:
	_apply_mode(_mode)
	_apply_emode(_emode)
	_log("[检视器] 档位重挂牌：我方=%s 敌方=%s（重建后必须重新应用，否则新一局 AI 不动）" % [
		_ai_name(_mode), _ai_name(_emode)])


## 旧 Battle 是否已经真正离开场景树（queue_free 后要等一帧以上才生效）
func _old_battle_gone() -> bool:
	return _battle == null


# ================= 英雄池选人界面（嵌入 QuickTest） =================
#
# 用户口径：检视器的入口就是"能从英雄池里给自己和对方挑英雄"的界面——也就是用户自己的
# 自由部署界面 src/QuickTest.gd（res://scenes/QuickTest.tscn）。**不是** Battle 的
# "开局部署·轮流上首发"（_begin_deployment）。
#
# 为什么必须就地替换它的两个按钮：QuickTest._on_start() 末尾是
#   get_tree().change_scene_to_file("res://scenes/Main.tscn")（QuickTest.gd:245），
# _on_menu() 是跳 Menu.tscn（:211）。在检视器里点它们会把整个检视器场景换掉、我们的驱动循环
# 与面板全部消失。所以：
#   · 「开始对局」→ 断开 _on_start，改连 _on_quicktest_start：按 QuickTest._on_start 同一口径
#     组装 GameState，然后**在检视器内部**建战场（不换场景）；
#   · 「返回选卡」→ 断开 _on_menu 并隐藏该按钮（在检视器里它没有去处：选人界面本来就在屏幕上）。
# 一律运行时挂接，不改 src/。

## 显示英雄池选人界面（没有就 new 一个；已存在则恢复上次勾选并显示）
func _show_picker() -> void:
	if _picker == null or not is_instance_valid(_picker):
		var ps := load("res://scenes/QuickTest.tscn") as PackedScene
		if ps == null:
			push_error("[检视器] 无法加载 res://scenes/QuickTest.tscn：入口选人界面不可用")
			return
		_picker = ps.instantiate() as QuickTest
		if _picker == null:
			push_error("[检视器] QuickTest.tscn 根节点不是 QuickTest：入口选人界面不可用")
			return
		add_child(_picker)              # 先入树（它的 _ready 会 _build() 出界面与按钮）
		_picker._sel_p = _picker_sel_p.duplicate()
		_picker._sel_e = _picker_sel_e.duplicate()
		_hook_quicktest_buttons()
	_picker.visible = true
	if _panel != null:
		_panel.visible = true           # 选人时也留着面板，方便先调档位/权重
	if _status_label != null:
		_status_label.text = "英雄池选人：给自己和对方挑人后点「开始对局」"


## 拦截 QuickTest 的「开始对局」/「返回选卡」
func _hook_quicktest_buttons() -> void:
	if _picker == null or not is_instance_valid(_picker):
		return
	var sb: Button = _picker._start_btn
	if sb != null:
		_rewire_button(sb, "_on_start", Callable(self, "_on_quicktest_start"))
	var mb: Button = _find_button_by_text(_picker, "返回选卡")
	if mb != null:
		var cut := _rewire_button(mb, "_on_menu", Callable(self, "_on_quicktest_leave_picker"))
		mb.visible = false   # 在检视器里"返回选卡"没有去处（选人界面本来就在屏幕上），直接隐藏
		_log("[检视器] 已隐藏 QuickTest 的「返回选卡」（断开 %d 条原连接，避免跳 Menu）" % cut)
	# ★ 「随机双方各5人」按钮（用户新需求）：与 `--randpicks` **共用同一个函数** `_randomize_picks()`，
	#   按钮只是它的 UI 入口。放在「开始对局」按钮同一区域（同父容器则随容器排版；否则贴它下方 8px）。
	if _rand_btn == null or not is_instance_valid(_rand_btn):
		var rb := Button.new()
		rb.text = "随机双方各5人"
		rb.pressed.connect(func() -> void: _randomize_picks(false))
		if sb != null and sb.get_parent() != null:
			var par: Node = sb.get_parent()
			par.add_child(rb)
			if par is Container:
				rb.custom_minimum_size = sb.custom_minimum_size
				rb.size_flags_horizontal = sb.size_flags_horizontal
			else:
				rb.size = sb.size
				rb.position = sb.position + Vector2(0, sb.size.y + 8.0)
			_log("[检视器] 已加「随机双方各5人」按钮（与「开始对局」同区域：%s）" % par.get_class())
		else:
			add_child(rb)                     # 兜底：找不到开始按钮就挂在场景根上，仍可用
			rb.position = Vector2(24, 24)
			_log("[检视器] 已加「随机双方各5人」按钮（兜底挂到场景根：未找到「开始对局」按钮）")
		_rand_btn = rb


## 把按钮上"方法名为 old_method"的原连接全部断开，改连新的 Callable。
## 用 pressed.get_connections() 枚举而不是硬编码 Callable：不依赖对象实例是否同一个。
## 返回断开条数（0 = 没找到原连接，调用方据此决定是否降级告警）。
func _rewire_button(btn: Button, old_method: String, new_cb: Callable) -> int:
	if btn == null:
		return 0
	var cut := 0
	for c in btn.pressed.get_connections():
		var cb = c.get("callable", null)
		if cb is Callable and String((cb as Callable).get_method()) == old_method:
			btn.pressed.disconnect(cb as Callable)
			cut += 1
	if cut > 0 and not btn.pressed.is_connected(new_cb):
		btn.pressed.connect(new_cb)
	return cut


## 「开始对局」：按 QuickTest._on_start() 的同一口径组装 GameState，然后在检视器内部建战场。
## 口径逐条对齐 src/QuickTest.gd:213-244，**但规则换成正常对战**（用户 2024 明确要求）：
##   · 每队卡组上限 = `Battle.DEFAULT_DECK_SIZE`（=5 = 3 首发 + 2 替补），超出**拒绝开始并提示**，
##     **不静默截断**（用户勾了 6 个就该被告知，而不是被悄悄砍掉一个）；
##   · `no_death_limit = false` → **累计阵亡 3 名即判负、对局结束**（正常胜负规则）。
## --selftest / --fixed3v3 那条无头沙箱路径**保持原样**（不判负、8 人卡组），因为它是多随机种子
## 扫描的回归基准；两条路径的规则差异会在 `[规则]` 行里明写，不做隐藏差异。
func _on_quicktest_start() -> void:
	var sel_p: Array = _picker._sel_p.duplicate()
	var sel_e: Array = _picker._sel_e.duplicate()
	# 与 QuickTest 相同的准入校验 + 正常规则的卡组上限
	var limit := int(Battle.DEFAULT_DECK_SIZE)      # 5 = 3 首发 + 2 替补
	if sel_p.size() < QuickTest.MIN_PLAYER:
		var m1 := "正常对战规则：我方至少 %d 人（首发），当前 %d 人，未开始" % [QuickTest.MIN_PLAYER, sel_p.size()]
		_log("[拒绝] %s" % m1)
		push_warning("[检视器] %s" % m1)
		return
	if sel_p.size() > limit:
		var m2 := "正常对战规则：每队最多 %d 人（3 首发 + 2 替补），我方当前 %d 人 —— 请取消勾选后再点「开始对局」（不会替你截断）" % [limit, sel_p.size()]
		_log("[拒绝] %s" % m2)
		push_warning("[检视器] %s" % m2)
		return
	if sel_e.size() > limit:
		var m3 := "正常对战规则：每队最多 %d 人（3 首发 + 2 替补），敌方当前 %d 人 —— 请取消勾选后再点「开始对局」（不会替你截断）" % [limit, sel_e.size()]
		_log("[拒绝] %s" % m3)
		push_warning("[检视器] %s" % m3)
		return
	var edeck: Array = sel_e.duplicate()
	if edeck.size() == 0:
		# 敌方未选：从全英雄池随机 `limit` 名（排除我方已选）——与 QuickTest 同做法，人数按正常规则
		var pool: Array = DataRegistry.heroes.keys()
		var excl: Dictionary = {}
		for id in sel_p:
			excl[id] = true
		var cand: Array = []
		for id in pool:
			if not excl.has(id):
				cand.append(id)
		cand.shuffle()
		for i in mini(limit, cand.size()):
			edeck.append(cand[i])
	# ★ 英雄池只负责"定义双方卡组"（用户口径）：前 3 名是首发候选（其余进替补席）。
	# 部署（谁上阵、放哪格）交给 **Battle 自己那套轮流部署流程**（_begin_deployment）——
	# 所以这里**不写 placement**：写了就变成"直接放置、跳过部署界面"。
	GameState.clear_placement()
	GameState.no_death_limit = false    # ★ 正常对战：累计阵亡 3 名即判负（不再"替补用完才算负"）
	GameState.dual_control = true       # 双控；恒 true（敌方轮不跑生产 AI，见 _sync_dual_control）
	GameState.player_deck = sel_p.duplicate()
	GameState.enemy_deck = edeck.duplicate()
	# 记住勾选，方便"返回选人"时还原
	_picker_sel_p = _to_str_array(sel_p)
	_picker_sel_e = _to_str_array(edeck)
	if _picker != null and is_instance_valid(_picker):
		_picker.visible = false         # 隐藏选人界面，露出战场
	_log("[检视器] 开始对局（检视器内部建战场，不换场景）：卡组 我方 %d 人 / 敌方 %d 人 → 进入 Battle 的轮流部署" % [
		sel_p.size(), edeck.size()])
	# ★ 断言：建局前核对"勾选的卡组"是否真的进了 GameState（防"选了人被覆盖"再次发生）
	if not _verify_picks(sel_p, edeck, sel_p, edeck):
		_warn("选人结果与 GameState 不一致：拒绝建局（避免上场的是默认阵容）")
		if _picker != null and is_instance_valid(_picker):
			_picker.visible = true      # 把选人界面露回来，让用户重挑
		return
	# ★ 关键：keep_picks = true。
	# 不能走 _setup() 的默认分支——那条会 reset_online()（它会清 player_deck/enemy_deck/
	# player_placement/enemy_placement，见 autoload/GameState.gd:78-90）+ clear_placement()
	# + 写回固定 3v3，把刚勾选的卡组全部覆盖（实机 bug：选了人进去还是默认 6 人）。
	_setup(true)
	_hook_hud_back_button()
	_deployed = false                   # 部署还没走完：由 _deployment_tick 驱动 / 等真人点选
	_run_gen += 1
	_run.call_deferred()
	# 复查：建局后 GameState 仍应等于勾选结果（deck 没被覆盖）
	_verify_picks(sel_p, edeck, sel_p, edeck, true)


## 正常对战规则的判负阵亡数（= src/Battle.gd:173 `LOSS_DEATH_COUNT` = 3，含替补阵亡）。
## 单独抽一个函数是为了让"规则说明"与判据同源：以后对方改常量，我们的话术跟着变。
func _death_limit_normal() -> int:
	return int(Battle.LOSS_DEATH_COUNT)


## 对局结束（GameState.match_ended 信号）→ 记下获胜方，供 --test-play 的机读断言用。
func _on_match_ended(winner_side: int) -> void:
	_last_winner = int(winner_side)
	_log("[检视器] 对局结束：获胜方 side=%d（%s；本端=我方的视角）" % [
		int(winner_side), "平局" if int(winner_side) < 0 else _side_txt(int(winner_side))])


## 核对"勾选的卡组"是否真的写进了 GameState（防"选了人被覆盖"）。
## 现在部署由 Battle 自己走，所以这里**只比卡组**（placement 在部署完成前本来就该是空的，
## 布置结果由 _assert_deploy_done() 在部署结束时断言）。
## after_setup=true 时是"建局后复查"，只记日志不改流程（建局已经发生）。
func _verify_picks(_p_ignored: Array, _e_ignored: Array, sel_p: Array, edeck: Array,
		after_setup: bool = false) -> bool:
	var ok := true
	if GameState.player_deck != sel_p:
		ok = false
		_warn("player_deck 不符：勾选 %s / GameState %s" % [str(sel_p), str(GameState.player_deck)])
	if GameState.enemy_deck != edeck:
		ok = false
		_warn("enemy_deck 不符：勾选 %s / GameState %s" % [str(edeck), str(GameState.enemy_deck)])
	if GameState.player_deck.size() == 0 or GameState.enemy_deck.size() == 0:
		ok = false
		_warn("卡组为空：我方 %d 人 / 敌方 %d 人" % [
			GameState.player_deck.size(), GameState.enemy_deck.size()])
	_log("[选人核对%s] %s：我方卡组 %d 人 %s / 敌方卡组 %d 人 %s" % [
		"（建局后）" if after_setup else "（建局前）", "一致" if ok else "不一致",
		GameState.player_deck.size(), str(GameState.player_deck),
		GameState.enemy_deck.size(), str(GameState.enemy_deck)])
	return ok


## 「返回选卡」的新行为：留在检视器里（选人界面本来就在屏幕上，等于无操作）
func _on_quicktest_leave_picker() -> void:
	_log("[检视器] 「返回选卡」已被拦截：留在检视器内（不跳 Menu）")
	_show_picker()


## 把无类型数组转成 Array[String]（GDScript 没有直接的类型转换，逐个 append 最稳）
func _to_str_array(src: Array) -> Array[String]:
	var out: Array[String] = []
	for v in src:
		out.append(String(v))
	return out


## 回收后台搜索线程，并作废它待用的结果（重建/退出都要走这条，避免残留 Thread）
func _stop_search_thread() -> void:
	if _ai_thread != null and _ai_thread.is_started():
		_ai_thread.wait_to_finish()
	_ai_thread = null
	if _search_lock != null:
		_search_lock.lock()
		_search_holder.plan = []
		_search_holder.done = false
		_search_lock.unlock()
	_search_active = false


## 清掉上一局的运行痕迹（重建时用）。代际号与 _restarting 由 _rebuild_sandbox 自己管，不动。
func _reset_instance_state() -> void:
	_plan = []
	_pi = 0
	_cur_act = {}
	_cur_idx = -1
	_desc_keys = []
	_plan_hero = []
	_new_hero = true
	_ai = null
	_ai_busy = false
	_ai_elapsed_ms = 0
	_recover = 0
	_steps = 0
	_deployed = false       # 是否已建好战场由调用方（_setup/点开始对局）置位
	_st_done = 0
	_st_match = 0
	_st_diff = 0
	_st_nopred = 0
	_st_process = 0
	_st_span = 0
	_st_timing = 0
	_st_seen = {}
	# 替补面板计时也清零：换局时不能把上一局的面板时长带过来。
	_sub_panel_open_ms = 0
	_sub_panel_fn = -1
	_sub_panel_take = false
	# 锁变量一并复位：重建/换局时不能把"上一局的锁"带过来（那是"用户被困住"的另一条来路）。
	_watch_locked = false
	_watch_side_locked = -1


## 场景退出（quit/重开）时回收后台搜索线程，避免 "Thread must be disposed" 之类报错。
## 照 Battle.gd:176-180 的 _exit_tree 写法。搜索最长约 8s（BEAM=800 实测），
## 这里等它跑完再回收——能保证不泄漏；注释里如实说明这是"退出时可能等几秒"的取舍。
## 另外把运行时日志文件句柄显式关掉：FileAccess 不关会拖到引擎退出时才回收，
## 会在控制台尾部留下 "ObjectDB instances were leaked / resources still in use" 这类噪声。
func _exit_tree() -> void:
	_run_gen += 1        # 作废驱动循环，避免它继续 await 一个正在拆除的场景
	_stop_search_thread()
	if _rt_file != null:
		_rt_file.flush()
		_rt_file.close()
		_rt_file = null

# 建战场。
# keep_picks = false（默认：固定 3v3 快速沙箱 / --selftest / --fixed3v3）：
#   清空并写入固定 3v3 阵容（行为与以前一字不差）。
# keep_picks = true（英雄池选人路径）：**保留调用方已经写好的** placement/deck。
#   ⚠️ 注意 `GameState.reset_online()` 内部就会把 player_deck/enemy_deck/player_placement/
#   enemy_placement 全部清空（autoload/GameState.gd:78-90），所以这条路径**绝不能调它**，
#   否则用户刚勾选的英雄会被清光——这正是实机报的"选了人进去却是默认 6 人"的根因。
func _setup(keep_picks: bool = false) -> void:
	# 开新一局就换一个新日志文件（"再来一局"/重建沙箱也算新一局）：上一局的证据不再被覆盖。
	_rt_battles_opened += 1
	if _rt_battles_opened > 1:
		_rotate_runtime_log("第 %d 局（重建/再来一局）" % _rt_battles_opened)
	if not keep_picks:
		GameState.reset_online()
	GameState.dual_control = true        # 敌方回合也由玩家操控（不跑生产 AI：它会自己开后台线程）
	# ★ 规则跟着入口走（**必须晚于**调用方设的规则，所以这里统一说了算）：
	#   keep_picks = true  → 英雄池路径 = **正常对战规则**（累计阵亡 3 名判负、卡组 ≤5）；
	#   keep_picks = false → 固定 3v3 / --selftest / --fixed3v3 = **沙箱规则**（不判负、8 人卡组）。
	# 踩过：这里原来无条件写 `no_death_limit = true`，把 `_on_quicktest_start()` 刚设的 false 又翻回去了
	# → 英雄池路径根本没进正常规则。
	GameState.no_death_limit = not keep_picks
	GameState.arena_mode = false
	GameState.pick_deck_in_battle = false
	GameState.match_over = false
	GameState.ai_difficulty = 2          # 困难档口径（fork 另按权重注入）
	if not keep_picks:
		GameState.clear_placement()
		# 3v3 固定摆位：placement 非空 → _place_units() 直接放置，跳过部署选人
		for i in P_CELLS.size():
			GameState.player_placement[P_CELLS[i]] = P_DECK[i]
		for i in E_CELLS.size():
			GameState.enemy_placement[E_CELLS[i]] = E_DECK[i]
		GameState.player_deck = _full_deck(P_DECK)
		GameState.enemy_deck = _full_deck(E_DECK)
	_battle = (load(MAIN_SCENE) as PackedScene).instantiate() as Battle
	_battle.set_random_seed(_rng.randi())
	_battle._first_side = _first_side
	add_child(_battle)
	_hook_hud_back_button()   # HUD 随 Battle 一起新建：每次建局都要重新拦截「返回选人」
	# 取证用计数（无副作用，只是把 Battle 自己的信号转成机读证据）：
	#   · sub_placed        → 替补落位数（正常规则下每队最多 2）
	#   · GameState.match_ended → 对局结果（谁赢）
	_sub_placed = 0
	_last_winner = -99
	_battle.sub_placed.connect(func() -> void: _sub_placed += 1)
	# 替补面板"开了"的权威信号（比 state 更靠前）+ 落位成功 → 作废悬着的面板请求
	if not _battle.sub_select_requested.is_connected(_on_sub_panel_requested):
		_battle.sub_select_requested.connect(_on_sub_panel_requested)
	if not _battle.sub_placed.is_connected(_on_sub_placed):
		_battle.sub_placed.connect(_on_sub_placed)
	if not GameState.match_ended.is_connected(_on_match_ended):
		GameState.match_ended.connect(_on_match_ended)
	if keep_picks:
		_log("[规则] 本局规则：正常对战（**累计阵亡 %d 名即判负**、每队卡组 ≤%d 人）" % [
			_death_limit_normal(), int(Battle.DEFAULT_DECK_SIZE)])
	else:
		_log("[规则] 本局规则：**沙箱规则**（不判负、每队 %d 人卡组，替补用完才算负）——这是 --selftest/--fixed3v3 的回归基准，与英雄池路径的正常规则不同" % 8)


## 队伍 = 首发 3 人 + 其余英雄凑到 8 人（替补池），与沙箱"每队 8 人"的口径一致（固定 3v3 用）。
## （no_death_limit 下替补池语义 = "卡组里没上场的人"，见 Battle.gd 的 _seed_sandbox_roster）。
func _full_deck(first: Array) -> Array:
	var out: Array = first.duplicate()
	var ids: Array = DataRegistry.heroes.keys()
	ids.sort_custom(func(a: String, b: String): return a < b)
	for id in ids:
		if out.size() >= 8:
			break
		if not out.has(id):
			out.append(id)
	return out


# ================= 驱动主循环 =================

# ================= 停摆看门狗（防止"无声占实例"） =================
#
# 现场（上层处置通报）：某个 AI vs AI、5 人卡组的无头实例停在第 10 回合，
# 日志只剩 `[替补·采样] state=1 _sub_faction=-1 待补P=0 待补E=0 面板阵营=无 已尝试驱动=是 位已落=是`，
# 之后**再没有任何 `[对拍]` 块**，CPU 10 分钟只涨 ~57s（空转）→ 它是**停摆**，不是"跑得慢"。
# 这种状态会一直占着窗口（之前那几次"跑了 30~40 分钟"很可能都是它）→ 必须**自己干净中止**。
const STALL_WALL_MS := 100000     # 推进指纹 100 秒不变 = 停摆（比游戏自己的 90 秒回合超时略长）


## 推进指纹（回合 | 行动方 | 已出对拍块数 | 代际）：任一变化即"有推进"，刷新计时。
func _progress_tick(now_ms: int) -> void:
	var key := "%d|%d|%d|%d" % [GameState.round_number, int(GameState.active_side), _chk_count, _run_gen]
	if key != _prog_key:
		_prog_key = key
		_prog_ms = now_ms


## 停摆中止：先写**诊断**（把当时所有可能"在等谁"的状态摊开），再打机读 SUMMARY 并以非 0 退出。
## 诊断里连 `_production_ai_busy()` 的三个分量一起写 —— 下次停摆一眼就能看出卡在哪一条：
##   `_enemy_plan_running` / Battle 自己的 `_ai_thread` / `state==ENEMY_TURN`。
func _stall_abort(reason: String) -> void:
	var alive: bool = _battle != null and is_instance_valid(_battle)
	var st := int(_battle.state) if alive else -1
	var plan_running: bool = bool(_battle._enemy_plan_running) if alive else false
	var t = _battle._ai_thread if alive else null
	var thread_started: bool = t != null and t is Thread and (t as Thread).is_started()
	_log("[停摆] %s：state=%d _sub_faction=%d 待补P=%d 待补E=%d 面板阵营=%s 出手单位=%s 已出对拍块=%d 代际=%d" % [
		reason, st, int(_battle._sub_faction) if alive else -1,
		int(_battle._pending_subs_of(DataRegistry.Faction.PLAYER)) if alive else -1,
		int(_battle._pending_subs_of(DataRegistry.Faction.ENEMY)) if alive else -1,
		"无" if _sub_panel_faction() < 0 else _side_txt(_side_of_faction(_sub_panel_faction())),
		_cur_hero_or_dash(), _chk_count, _run_gen])
	_log("[停摆] 归因分量：_production_ai_busy=%s（_enemy_plan_running=%s / Battle._ai_thread 已启动=%s / state==ENEMY_TURN=%s）" % [
		str(_production_ai_busy()), str(plan_running), str(thread_started),
		str(st == int(Battle.State.ENEMY_TURN))])
	_log("[停摆] 其它：_deployed=%s AI忙=%s 搜索中=%s match_over=%s 回合=%d 行动方=%s 本回合已重算=%d" % [
		str(_deployed), str(_ai_busy), str(_search_active), str(GameState.match_over),
		GameState.round_number, _side_txt(int(GameState.active_side)), _replan_count])
	_say_console("[停摆] 驱动停摆 → 干净中止（%s）：已出对拍块=%d，回合=%d" % [reason, _chk_count, GameState.round_number])
	_log("SIMCHK|SUMMARY|ABORTED|reason=stall|%s|goal=%d|acts=%d|MATCH=%d|DIFF=%d|NOPRED=%d|round=%d|PROCESS=%d|SPAN=%d|TIMING=%d" % [
		reason.replace(" ", ""), _st_goal, _st_done, _st_match, _st_diff, _st_nopred,
		GameState.round_number, _st_process, _st_span, _st_timing])
	if get_tree() != null:
		get_tree().quit(3)     # 非 0：外部脚本据此判"这局停摆，不是通过"


## 当前出手单位的可读标识（停摆诊断用；拿不到给 "-"）。
func _cur_hero_or_dash() -> String:
	if _cur_idx < 0 or _cur_idx >= _desc_keys.size():
		return "-"
	return _hero_of(_desc_keys, _cur_idx)


func _run() -> void:
	var gen := _run_gen        # 本循环所属代际：重建沙箱会把 _run_gen +1，本协程据此自行作废
	# ★ 英雄池路径要经过 Battle 自己的轮流部署：部署期间状态是 DEPLOY / PLACE_DEPLOY，
	# `_battle_ready()` 只认 PLAYER_INPUT/ENEMY_TURN，所以这里先单独把部署阶段走完
	# （AI 那边的每一手由 _deployment_tick 驱动；手动那边等真人点，或自检时由超时兜底）。
	var waited := 0
	# `READY_WALL_MS / 100`：两个都是 int → Godot 报 `INTEGER_DIVISION`（"小数部分会被丢掉"）。
	# 这里本来就想要整数商，写成浮点再取整：数值不变、警告消失（与本文件其它同类写法一致）。
	while not _battle_ready() and waited < int(float(READY_WALL_MS) / 100.0):
		if gen != _run_gen or not _battle_alive():
			return
		# 部署期：先把 AI 那边的手走完（一手一手），再回来等"进入可行动状态"
		if not _deployed:
			_deployment_tick()
			if _deploy_finished():
				_deployed = true
				_assert_deploy_done()
				_log("[部署] 完成：进入正式对局")
		waited += 1
		await get_tree().process_frame
	var ok := _battle_ready()
	if gen != _run_gen:
		return
	_sync_dual_control()
	# 驱动启停（分层规则第 ② 类）：每次 `_run()` 起来都打一行，
	# 一眼就能判断"新一局（再来一局）到底有没有驱动在跑"。
	_say_console("[驱动] 启动（代际=%d，我方档=%s，敌方档=%s）" % [_run_gen, _ai_name(_mode), _ai_name(_emode)])
	if ok and _selftest and _deployed and not _is_enemy_side_active() \
			and int(_mode) == int(AI_MANUAL):
		# 自检：我方没有 AI 驱动时才需要把回合让给敌方（否则玩家方会一直等点击）。
		# 我方=RL候选AI 时由 AI 自己出手，这里不能让，否则就测不到我方 AI 了。
		_log("[检视器] selftest：把行动方交给敌方（先结束玩家方这一手）")
		_battle.state = Battle.State.ANIMATING
		await _battle._end_side(GameState.active_side)
		await _wait_until(func():
			return GameState.match_over or not _battle_alive() or _battle_ready(),
			SIDE_WALL_MS, SIDE_WALL_FRAMES)
	if not ok or not _battle_alive():
		push_error("[检视器] 场景未就绪：Battle 没进入可操作状态")
		if _selftest:
			_finish_selftest()
		return
	while _battle_alive() and not GameState.match_over and _steps < MAX_STEPS:
		if gen != _run_gen:
			return   # 已被重建沙箱取代：本代循环退出，避免两套 _run() 并行
		_steps += 1
		_tick_watchdog()
		# 部署阶段（Battle 自己的轮流部署）单独处理：AI 边一手一手上人，手动边等真人点。
		# 判据直接用 Battle 的 state（DEPLOY/PLACE_DEPLOY）——**不要**用 PLAYER_INPUT 去猜
		# （历史上踩过 state 判断的坑：dual_control 下敌方轮也会是 PLAYER_INPUT）。
		if not _deployed:
			_deployment_tick()
			if _deploy_finished():
				_deployed = true
				_assert_deploy_done()
				_log("[部署] 完成：进入正式对局")
				_say_console("[部署] 完成：我方 %d/3 敌方 %d/3" % [
					_battle.player_deployed.size(), _battle.enemy_deployed.size()])
			await get_tree().process_frame
			continue
		_sync_watch_lock()          # 按"哪一方用 AI"维护观战锁（屏蔽输入 + 禁用 HUD 按钮）
		_refresh_status()
		# 结算浮层是动态建的：对局结束后周期性重挂它的「再战一局」（幂等，节流 30 帧一次）
		_rehook_acc += 1
		if _rehook_acc >= 30:
			_rehook_acc = 0
			_rehook_restart_buttons_if_needed()
		if _selftest and _st_done >= _st_goal:
			break
		# 替补（按"哪一方用 AI"分别处理，用户口径）：
		#   · AI 那一方：工具替它把面板走完（生产口径选人 + 同一条落位 API），否则没人点会死等；
		#   · 手动那一方：**面板留着让玩家自己点**，工具绝不替玩家决定（只有 --selftest 无头跑时，
		#     因为压根没有真人，才借 Battle 自己的超时补位把它推完）。
		# ★ 判据是**面板自己的归属阵营**（`_sub_faction`），不是"当前行动方"——
		# 面板属于哪个阵营与"当前行动方"无关——AI 那方的单位可能在**玩家回合**里被打死
		# （反击反杀/炸弹/AOE），于是面板为 AI 阵营打开，而 active_side 仍是玩家。
		# 旧写法 `_ai_drive_sub(active_side)` 会把**行动方**的 roster 喂给这个面板：
		# `_on_sub_pick` 发现人选不在该面板的 roster 里就静默 return（src/Battle.gd:4556-4558），
		# 接着 `_try_place_sub` 因 `_pending_sub==""` 也 return（同文件 :4575）→ 面板一直挂着，
		# 只能干等**回合 90 秒限时**耗尽才 `_auto_sub_on_timeout()`（Battle 没有独立的替补短超时，
		# src/Battle.gd:275-284）→ 用户报的"替补选人时间特别长"。
		# ★ 交互接管（替补/放炸弹/看门狗）现在统一由 `_process` 里的 `_interaction_tick()` 每帧做：
		# 驱动循环会被搜索轮询与动作动画 await 长时间挂住，而替补面板正是在动作执行中打开的
		# （用户实测"等了 96 秒才替补"=回合 90 秒限时兜底）→ 放在循环里必然迟到。
		# 这里只保留计算 pfn，用于下面"手动那方借超时补位"的自检分支。
		var pfn := _sub_panel_faction()
		if pfn < 0:
			pfn = _sub_signal_pending_faction()
		# 心跳（只进文件，每 10 秒一行）：长跑要能自证"在推进"，否则外部只能靠 CPU 猜
		# （踩过：一个卡在等待里的实例被当成"跑得慢"，把整条流水线堵了 10 分钟）。
		var now_ms := Time.get_ticks_msec()
		if now_ms - _hb_ms >= 10000:
			_hb_ms = now_ms
			_log("[心跳] t=%s 代际=%d 回合=%d 行动方=%s 已出对拍块=%d _deployed=%s AI忙=%s 搜索中=%s state=%d" % [
				_clock_txt(now_ms), _run_gen, GameState.round_number, _side_txt(int(GameState.active_side)),
				_chk_count, str(_deployed), str(_ai_busy), str(_search_active),
				int(_battle.state) if _battle != null and is_instance_valid(_battle) else -1])
		# ★ 停摆看门狗（最高优先，防止再无声占实例）：只要"比赛推进"的指纹长时间不变就干净中止。
		#   现场依据（上层处置通报）：PID 30428 停在第 10 回合，日志只剩 `[替补·采样] state=1 …
		#   待补P=0 待补E=0 面板阵营=无`，CPU 10 分钟只涨 57s —— 典型"循环在等一个永远不会来的条件"。
		#   推进指纹 = 回合 | 行动方 | 已出对拍块数（三者任一变化即算推进；搜索期间最长十几秒不变化，
		#   所以阈值取 100s，比游戏自己的 90 秒回合超时略长）。
		_progress_tick(now_ms)
		if now_ms - _prog_ms > STALL_WALL_MS:
			_stall_abort("连续 %dms 无推进" % (now_ms - _prog_ms))
			return
		if not _need_ai_turn():
			# 自检要在无头模式下一路推进：轮到没有 AI 的一方（手动档）就直接结束这一手；
			# 阵亡后弹出的替补面板也一样——借 Battle 自己的"超时自动补位"把面板走完。
			# 手动游玩时不会走到这里（_selftest=false），玩家照常自己点。
			if _selftest and _battle_alive() and not GameState.match_over:
				var st := int(_battle.state)
				if pfn >= 0 and not _ai_driven_by_us(_side_of_faction(pfn)):
					# 只有"手动那一方"才借超时补位；AI 那边上面已经由 _ai_drive_sub 走生产口径了，
					# 两边同时动同一个面板会打架。
					_battle._auto_sub_on_timeout()
					await get_tree().process_frame
					continue
				if _deployed and int(_mode) == int(AI_MANUAL) \
						and not _is_enemy_side_active() and st == int(Battle.State.PLAYER_INPUT):
					_battle.state = Battle.State.ANIMATING
					await _battle._end_side(GameState.active_side)
					await _wait_until(func():
						return GameState.match_over or not _battle_alive() or _battle_ready(),
						SIDE_WALL_MS, SIDE_WALL_FRAMES)
					continue
			await get_tree().process_frame
			continue
		if _ai_busy:
			# 正在等动画/等结算：这一帧不推进（看门狗负责把卡死的档位退回手动）
			await get_tree().process_frame
			continue
		_ai_busy = true
		var r: String = await _drive_turn()
		_ai_busy = false
		if r == "error":
			_recover += 1
			push_error("[检视器] 驱动异常，已把 AI 档位退回「手动（原样）」。")
			_log("[检视器] 驱动异常，已退回手动档")
			if _selftest:
				_finish_selftest()
				return
			_apply_emode(AI_MANUAL)
			_apply_mode(AI_MANUAL)
			if _recover > 3:
				break
	if _selftest:
		_finish_selftest()
		return
	# 非自检：驱动循环只会因为"战场离开场景树"或"对局结束"退出。
	# 前者=关闭窗口／停止运行／按重开／切换场景的拆除阶段，这里明确打一行，避免看起来像静默失效。
	if not GameState.match_over and not _battle_alive():
		_log("[检视器] 战场已离开场景树（关闭窗口／停止运行／重开／切换场景）→ 退出驱动循环")


## 正式对局是否已经开场、且当前处于"某一方可以行动"的状态。
## 与 _need_ai_turn 同口径：PLAYER_INPUT **或** ENEMY_TURN 都算（dual_control=false 时敌方轮
## 是 ENEMY_TURN，见 _need_ai_turn 注释）。部署阶段不算（那时 state 可能是 PLAYER_INPUT，
## 若当回合推进就会去 _end_side，把部署流程整个掀翻——调用方一律配 _deployed 守卫）。
func _battle_ready() -> bool:
	if not _battle_alive():
		return false
	if GameState.match_over:
		return true
	var st := int(_battle.state)
	return st == int(Battle.State.PLAYER_INPUT) or st == int(Battle.State.ENEMY_TURN)


## 当前行动方是不是敌方。
## 为什么要 int() 夹一层：GameState.active_side 可能是 float（0.0/1.0）——**带类型的 != 会把
## 0.0 和 int 0 判成不等**，直接用会得出"轮到敌方了"的错误结论（自检里就是这么栽的）。
## 统一转成 int 再比，避免这类静默错判。
func _is_enemy_side_active() -> bool:
	return int(GameState.active_side) == int(_enemy_side())


## 当前行动方用哪个档位（0=手动 / 1=候选 / 2=原版）。两侧档位互相独立。
func _mode_of_side(side: int) -> int:
	return _emode if side == _enemy_side() else _mode


## 阵营 → 行动方（side）。纯换算，与"谁在行动"无关。
## 为什么需要它：**替补面板是按阵营归属的**，而面板可以在"对面回合"里打开，
## 所以"面板属于哪一方"必须能独立换算成 side，才能查该阵营的档位（见 _sub_panel_faction）。
func _side_of_faction(fn: int) -> int:
	if int(fn) == int(DataRegistry.Faction.ENEMY):
		return int(_enemy_side())
	return int(GameState.SIDE_PLAYER)


## 某**阵营**的档位（0=手动 / 1=候选 / 2=原版）。
func _mode_of_faction(fn: int) -> int:
	return _mode_of_side(_side_of_faction(fn))


## 当前替补面板/落位属于哪个**阵营**（没有面板时返回 -1）。
##
## 依据是 Battle 自己的 `_sub_faction` —— 它本来就是"当前替补面板属于哪一方"的权威标识
## （src/Battle.gd:3254 / 4257 / 4506 `_sub_faction_txt()` 都按它判断），由 `_begin_substitution()`
## 赋值、`_place_sub()` 收尾时置回 -1。
##
## **绝不用 `GameState.active_side` 推**：那是"谁在行动"，与"面板归谁"是两件事。
## 反例（用户实机就是这个）：玩家回合里 AI 那方的一个单位被反击打死 →
## `_on_unit_died` 认出"阵亡方=可手动方（双控下双方都算）且 active_side==阵亡方"这条不成立，
## 走**延迟阵亡**分支排队，等**本方**回合开始才弹面板；而"本方回合里自己阵亡"时面板更是直接
## 在**该阵营行动中**弹出。两种情形下面板归属都与当时的 active_side 无关。
func _sub_panel_faction() -> int:
	if not _battle_alive():
		return -1
	var st := int(_battle.state)
	if st != int(Battle.State.SUBSTITUTING) and st != int(Battle.State.PLACE_SUB):
		return -1
	var fn := int(_battle._sub_faction)
	if fn < 0:
		# 兜底：正常路径 `_begin_substitution()` 会先赋值再切 state，这里是防"先切态后赋值"
		# 的极端顺序。退回本端阵营并如实记一行，宁可多试一次也不要让面板无人接管干等 90 秒。
		fn = int(_battle._my_faction())
		_log("[替补面板·归属] `_sub_faction` 未赋值但 state=%d → 兜底按本端阵营 %s 处理" % [
			st, _side_txt(_side_of_faction(fn))])
	return fn


## 面板开启起表：**幂等**（已开着就不重开表），由每帧的交互 tick 调用。
##
## ⚠️ 计时口径的坑（用户看到 `耗时=96548ms` 就是这么来的）：驱动循环里"起表/收表"都在 `while`
## 的同一轮，而 `_drive_turn()`（一次搜索 + 整回合出招）会**长时间阻塞** → 收表要等下一轮，
## 量出来的是"面板 + 后面那一整个回合"。所以现在：
##   起表 = 每帧 tick 第一次**看到**面板（或 `sub_select_requested` 事件，两者都带绝对时间）；
##   收表 = `sub_placed` 事件（落位成功）或 state 离开替补态（未落位），见 _sub_close_panel_timing。
func _sub_open_panel_timing(fn: int) -> void:
	if _sub_panel_open_ms > 0:
		return
	_sub_panel_open_ms = Time.get_ticks_msec()
	_sub_panel_fn = fn
	_sub_panel_mode = _mode_of_faction(fn)
	_sub_panel_take = _ai_driven_by_us(_side_of_faction(fn))
	_sub_state_seq = []
	_sub_last_state = -1
	_sub_first_try_ms = 0
	_sub_first_try_txt = "未尝试"
	_sub_place_ok_ms = 0
	_log("[替补·时间戳] 面板出现（第一次看到）绝对时间=%s state=%d 归属=%s" % [
		_clock_txt(_sub_panel_open_ms), int(_battle.state) if _battle != null else -1,
		_side_txt(_side_of_faction(fn))])


## 该面板期间每一次 state 变化记一条（带相对毫秒），收表时一起打出来（便于对账 6→7→1）。
func _sub_note_state(st: int) -> void:
	if _sub_panel_open_ms <= 0 or st == _sub_last_state:
		return
	_sub_last_state = st
	_sub_state_seq.append("%d@+%dms" % [st, Time.get_ticks_msec() - _sub_panel_open_ms])


## 绝对时间文本（HH:MM:SS.mmm）：96 秒这种数字必须能一眼对账，所以绝对时间一起打。
func _clock_txt(_ms_abs: int) -> String:
	var d := Time.get_datetime_dict_from_system(false)
	return "%02d:%02d:%02d.%03d" % [int(d["hour"]), int(d["minute"]), int(d["second"]),
		Time.get_ticks_msec() % 1000]


## 面板收尾：打印**真实**面板时长 + 绝对时间 + state 序列 + 关键时间戳，并按真实时长判是否告警。
## reason：`sub_placed`=落位成功收尾；`left_state`=state 离开替补态但没落位（如 90 秒超时兜底）。
func _sub_close_panel_timing(reason: String = "left_state", hero: String = "-", cell_txt: String = "-") -> void:
	if _sub_panel_open_ms <= 0:
		return
	var ms := Time.get_ticks_msec() - _sub_panel_open_ms
	var open_at := _sub_panel_open_ms
	var take_txt := "是" if _sub_panel_take else "否"
	var who := _side_txt(_side_of_faction(_sub_panel_fn)) if _sub_panel_fn >= 0 else "未知"
	var seq := "→".join(_sub_state_seq)
	_say_console("[替补] 面板归属=%s 接管=%s 耗时=%dms 收尾=%s" % [who, take_txt, ms, reason])
	_log("[替补] 面板完成：归属=%s 档位=%s 接管=%s 选中=%s 落位=%s 收尾=%s 真实耗时=%dms 打开=%s 关闭=%s state序列=%s" % [
		who, _ai_name(_sub_panel_mode), take_txt, hero, cell_txt, reason, ms,
		_clock_txt(open_at), _clock_txt(Time.get_ticks_msec()), seq])
	_log("[替补·时间戳] 面板出现=%s 首次驱动尝试=%s 落位成功=%s 关闭=%s（真实面板时长 %dms）" % [
		_clock_txt(open_at), _sub_first_try_txt,
		_clock_txt(_sub_place_ok_ms) if _sub_place_ok_ms > 0 else "未成功",
		_clock_txt(Time.get_ticks_msec()), ms])
	# 判据用**真实面板时长**（事件驱动量出来的），不是"循环两轮之间的间隔"
	if _sub_panel_take and ms > 2000:
		_warn("替补面板接管失败或过慢：归属=%s（档位=%s、已宣布接管）真实耗时 %d ms（阈值 2000ms）、收尾方式=%s" % [
			who, _ai_name(_sub_panel_mode), ms, reason])
	_sub_panel_open_ms = 0
	_sub_panel_fn = -1
	_sub_panel_take = false
	_sub_said_key = ""


## 面板开启当场的那一行（控制台，每面板一行）：用户**立刻**能看到"面板出现了、归谁、谁接管"。
func _sub_say_open(fn: int, take: bool) -> void:
	var key := "%d|%d|%s" % [int(_battle.state), fn, str(take)]
	if key == _sub_said_key:
		return
	_sub_said_key = key
	if take:
		_say_console("[替补] 面板归属=%s 接管=是（工具立刻按生产口径补位）" % _side_txt(_side_of_faction(fn)))
	else:
		_say_console("[替补] 面板归属=%s 接管=否（面板留给你点：先点英雄卡，再点出生格）" % _side_txt(_side_of_faction(fn)))


## 游戏通过 `sub_select_requested` 通知"替补面板开了"（阵营在 `_sub_faction`）。
## ★ 这是**事件驱动**的接管入口：面板是在**某个动作执行中**（有人阵亡）打开的，
## 而那时驱动循环正被 `_call_action` 的动画 await 挂住 → 只靠循环要等这一整个回合。
## 所以这里收到信号就**立刻**（本帧）尝试驱动，不等主循环。
func _on_sub_panel_requested() -> void:
	if _battle == null or not is_instance_valid(_battle):
		return
	_ev_sub_req += 1        # SPAN 事件计数：本招窗口内是否开过替补面板
	_sub_signal_fn = int(_battle._sub_faction)
	_sub_signal_ms = Time.get_ticks_msec()
	_log("[替补·诊断] 收到 sub_select_requested：面板阵营=%s state=%d 待补 我方=%d 敌方=%d（立刻尝试驱动）" % [
		_side_txt(_side_of_faction(_sub_signal_fn)) if _sub_signal_fn >= 0 else "未知",
		int(_battle.state), int(_battle._pending_subs_of(DataRegistry.Faction.PLAYER)),
		int(_battle._pending_subs_of(DataRegistry.Faction.ENEMY))])
	if _sub_signal_fn >= 0:
		_sub_open_panel_timing(_sub_signal_fn)
		_sub_say_open(_sub_signal_fn, _ai_driven_by_us(_side_of_faction(_sub_signal_fn)))
		_interaction_tick()


## 替补落位成功 → 面板请求信号作废，并按**事件**收表（真实面板时长在这一刻结算）。
func _on_sub_placed() -> void:
	_ev_sub_placed += 1     # SPAN 事件计数：本招窗口内是否完成过替补落位
	_sub_signal_fn = -1
	_sub_diag_key = ""
	_sub_close_panel_timing("sub_placed", _sub_last_hero, _sub_last_cell)


## 面板请求信号还"悬着"的阵营（-1 = 没有）：用于放宽判据——state 不在这两态时也认面板。
func _sub_signal_pending_faction() -> int:
	if _sub_signal_fn < 0 or _battle == null or not is_instance_valid(_battle):
		return -1
	# 演出中/已结束不动它：那种时刻强插替补会打断回合流程（宁可等它走完这一帧）。
	var st := int(_battle.state)
	if st == int(Battle.State.ANIMATING) or st == int(Battle.State.ENDED):
		return -1
	return _sub_signal_fn


## 诊断（只进文件）：还有"待补名额"但 state 不在这两态 → 面板可能开了却没被认出。
## 这条专治"用户等到 90 秒超时兜底"那类问题：以后扫日志一眼能看到。
func _sub_diagnose_pending() -> void:
	if _battle == null or not is_instance_valid(_battle):
		return
	var st := int(_battle.state)
	if st == int(Battle.State.SUBSTITUTING) or st == int(Battle.State.PLACE_SUB):
		return
	for fn in [DataRegistry.Faction.PLAYER, DataRegistry.Faction.ENEMY]:
		if int(_battle._pending_subs_of(fn)) <= 0:
			continue
		var key := "diag|%d|%d" % [fn, st]
		if key == _sub_diag_key:
			return
		_sub_diag_key = key
		_log("[替补·诊断] 有待补名额但 state=%d（归属阵营=%s，待补=%d，_sub_faction=%d）→ 可能面板已开却未被认出；将按面板请求信号驱动" % [
			st, _side_txt(_side_of_faction(fn)), int(_battle._pending_subs_of(fn)),
			int(_battle._sub_faction)])


## ================= 每帧交互 tick（**不受驱动循环阻塞**） =================
#
# 为什么接管必须放在 `_process` 而不是驱动循环里（用户报的"等了 96 秒才替补"的根因）：
# 驱动循环 `_run()` 会被两种 await **长时间挂住**——
#   ① `_search_async()` 的搜索轮询（一次搜索实测 0.3~8s，慢时更久）；
#   ② `_call_action()` 等动画/结算（一次动作 ~1~3s，连着几招就更久）。
# 而替补面板恰恰是在 ②（某个动作里有人阵亡 → `_on_unit_died` → `_try_begin_next_sub`）打开的
# → 放在循环里就只能等**这一整个回合**（一次搜索 + 全部出招）跑完才有机会驱动，
# 用户看到的就是"一直挂着，直到回合 90 秒限时兜底才自动上人"。
# `_process` 每帧都会被引擎调用，与任何 await 无关 → 面板一开就在**同一帧内**被接管。
func _process(_delta: float) -> void:
	if not _battle_alive():
		return
	_interaction_tick()
	_hold_driven_turn_timer()


## ★★ 抑制 harness 自己引入的"回合限时"（第 2 大族的根因，见下）。
##
## 为什么必须抑制：`_sync_dual_control()` 把 `GameState.dual_control` 设成 true（工具要替双方出手），
## 于是 `Battle._process`（src/Battle.gd:288）里的 `my_turn_live = active_side == _operable_side()`
## 对**双方**都成立 → **AI 驱动的那一方也被挂上了 90 秒回合限时**（`TURN_TIME_LIMIT`）。
## 生产对局里 AI 的回合**没有**这个限时（那时 `active_side != _operable_side()`）——
## 也就是说这是 harness 自己造出来的伪规则，真实规则里不存在。
##
## 危害（实测 · `--speed 20` 时 90 游戏秒 = 4.5 真实秒）：一次 beam50 搜索 ~1.6s（≈32 游戏秒）
## 加一次动画等待兜底 3s（=60 游戏秒）就把限时吃满 → 限时到点后 `submit_end_turn()` 在**本招窗口内**
## 结束掉这一回合 → `Battle._begin_side` 把**全场**单位的 moved/attacked/counter 旗标清零
## （src/Battle.gd:1733-1734）、`_clear_statuses` 清掉本方 atk_buff（:3546 → :1998）。
## 出招后快照于是读到"真实侧已移动/已攻击=否"、有效攻 -1，而模拟侧算的是对的 → 假 DIFF。
## 实测那一块（`RL/reports/rt/对拍_运行时_0913_165830.log`，第 2 回合我方第 1 招）：
##   位置 (0,5)→(2,4) / 障碍 3→2 / 道具被拾取 **两侧逐项一致**，只有旗标行写
##   `红帽(hero_40)#0 已移动（预测 是 / 实际 否）；已攻击（预测 是 / 实际 否）`，
##   块头写"第2回合·**敌方**"而计划行写"第 2 回合·**我方**" ← 限时就发生在这一招之内，铁证。
##
## 边界（只动"工具正在替它驱动"的那一方）：`AI_MANUAL`（真人自己操作）的回合一律不碰 ——
## 限时是"防玩家卡死"的规则，harness 无权替玩家取消。
## 实现：每帧把剩余时间顶回上限；顺手撤掉已经置上的 `_turn_expired`（不撤的话，
## 下一帧回到 `State.PLAYER_INPUT` 时 Battle 仍会 `submit_end_turn()`）。
func _hold_driven_turn_timer() -> void:
	if not _deployed or GameState.match_over or not GameState.match_running:
		return
	if _mode_of_side(int(GameState.active_side)) == AI_MANUAL:
		return
	var expired: bool = bool(_battle._turn_expired)
	if _battle.turn_time_left >= _battle.TURN_TIME_LIMIT and not expired:
		return
	_battle.turn_time_left = _battle.TURN_TIME_LIMIT
	if expired:
		_battle._turn_expired = false
	var key := "%d|%d" % [GameState.round_number, GameState.active_side]
	if key == _hold_key:
		return
	_hold_key = key
	_log("[回合限时] 第%d回合·%s 由工具驱动 → 已抑制 harness 伪限时（dual_control 让 AI 的回合也有 90 秒限时，生产里没有；不抑制会在本招窗口内翻面并清全体旗标/本方 buff）" % [
		GameState.round_number, _side_txt(GameState.active_side)])


## 每帧的交互接管总入口：替补面板 → 放炸弹选格 → 无人接管看门狗。
## 幂等：重复调用不会重复落位（`_try_place_sub` 内部有 `_pending_sub` 守卫）。
func _interaction_tick() -> void:
	if _battle == null or not is_instance_valid(_battle):
		return
	var pfn := _sub_panel_faction()
	if pfn < 0:
		# 放宽判据：state 不在这两态，但游戏确实开过替补面板且尚未落位 → 也认它
		pfn = _sub_signal_pending_faction()
	_sub_diagnose_pending()
	if pfn < 0:
		if _sub_panel_open_ms > 0:
			# state 已经离开替补态但没等到 `sub_placed`（例如没有替补可用/超时兜底直接收面板）
			_sub_close_panel_timing("left_state", _sub_last_hero, _sub_last_cell)
		_sub_signal_sample_throttled(pfn)
		_bomb_takeover_tick()
		_interact_watchdog()
		return
	_sub_open_panel_timing(pfn)
	_sub_note_state(int(_battle.state))
	_sub_signal_sample_throttled(pfn)
	var take := _ai_driven_by_us(_side_of_faction(pfn))
	_sub_say_open(pfn, take)
	_sub_panel_evidence(pfn)
	if take:
		if _sub_first_try_ms == 0:
			_sub_first_try_ms = Time.get_ticks_msec()
			_sub_first_try_txt = _clock_txt(_sub_first_try_ms)
			_log("[替补·时间戳] 首次驱动尝试=%s（面板出现后 %dms）state=%d" % [
				_sub_first_try_txt, _sub_first_try_ms - _sub_panel_open_ms, int(_battle.state)])
		_ai_drive_sub(pfn)
	_bomb_takeover_tick()
	_interact_watchdog()


## 每 500ms 一行的采样（只进文件）：直接把"我们有没有进去驱动 / 驱动了有没有生效"摊开。
## 采样项：绝对时间 / state / _sub_faction / 双方待补名额 / 是否已尝试驱动 / `_turn_expired`。
func _sub_signal_sample_throttled(pfn: int) -> void:
	var now := Time.get_ticks_msec()
	if now - _sub_sample_ms < 500:
		return
	_sub_sample_ms = now
	_log("[替补·采样] t=%s state=%d _sub_faction=%d 待补P=%d 待补E=%d 面板阵营=%s 已尝试驱动=%s 位已落=%s 回合超时=%s" % [
		_clock_txt(now), int(_battle.state), int(_battle._sub_faction),
		int(_battle._pending_subs_of(DataRegistry.Faction.PLAYER)),
		int(_battle._pending_subs_of(DataRegistry.Faction.ENEMY)),
		_side_txt(_side_of_faction(pfn)) if pfn >= 0 else "无",
		"是" if _sub_first_try_ms > 0 else "否",
		"是" if _sub_place_ok_ms > 0 else "否",
		str(bool(_battle._turn_expired))])


## 该阵营待补/面板是否由我们驱动（供报告与断言）。
func _sub_takeover_state(fn: int) -> String:
	if fn < 0:
		return "无面板"
	return "接管=%s" % ("是" if _ai_driven_by_us(_side_of_faction(fn)) else "否")


## 替换面板归属的机读证据（运行时文件）：面板归属阵营 + 该阵营档位 + 我们是否接管。
## 只在"面板归属/档位/接管决定"发生变化时打一行，避免每帧刷屏。
func _sub_panel_evidence(fn: int) -> void:
	var side := _side_of_faction(fn)
	var mode := _mode_of_faction(fn)
	var take := _ai_driven_by_us(side)
	var key := "%d|%d|%s" % [fn, mode, str(take)]
	if key == _sub_ev_key:
		return
	_sub_ev_key = key
	var active_side := int(GameState.active_side)
	_log("[替补面板·归属] 面板阵营=%s 该阵营档位=%s 当前行动方=%s 接管=%s%s" % [
		_side_txt(side), _ai_name(mode), _side_txt(active_side),
		"是（立刻按生产口径驱动，不等 90 秒回合超时）" if take else "否（面板留给玩家自己点）",
		"" if active_side == side else "  ★面板阵营≠当前行动方：旧口径会按行动方 roster 选人 → 静默 no-op → 面板干等"])


## 把 GameState.dual_control 设成"本场景此刻真正需要的值"。
##
## 为什么要动它：dual_control=true 会让 Battle._is_manual_sub_faction() 对**双方**都返回 true
## （src/Battle.gd:1922-1923），于是阵亡一律走"手动替补"分支——打开替补面板等真人点击，
## 而生产侧的敌方 AI 替补链条（_on_unit_died→_pending_enemy_sub→_begin_side→_place_enemy_sub→
## _best_enemy_sub_idx，src/Battle.gd:4311-4317 / 4363-4383）**根本不会执行**。
## 无人点击时旧 harness 只能靠 _auto_sub_on_timeout() 顶，而那是"替补席第 1 名 + _auto_sub_cell"，
## **不等于**生产困难档的选人逻辑（而且会先弹出 [替补面板] 日志）。
##
## dual_control **必须恒为 true**，本场景永远不要把它设成 false。
##
## 为什么（血的教训）：这一个标志同时管两件互不相干的事——
##   ① src/Battle.gd:1834-1848：dual_control=true 时敌方轮**不跑生产 AI**（直接 return）；
##      false 才走到底部 `_run_enemy_turn.call_deferred()`，生产 AI 自己开后台线程。
##   ② src/Battle.gd:1922-1923：`_is_manual_sub_faction()` 在 true 时对双方都返回 true，
##      阵亡走"手动替补面板"，生产替补链（_place_enemy_sub/_best_enemy_sub_idx）被跳过。
## 曾经为了拿到 ② 的生产链而把 dual_control 关掉 → 连带打开了 ① → **同一回合出现两个驱动者**
## （检视器 + 生产 _run_enemy_turn），实机报错：
##   `Battle._run_enemy_turn: Cannot call method 'wait_to_finish' on a null value`（Battle.gd:5047）
## ——两个 _run_enemy_turn 协程并行，后一个把 _ai_thread 置 null，前一个随后 wait_to_finish() 撞 null。
##
## 正确做法：dual_control 恒 true（保证"一边只有一个驱动者"），
## 敌方替补改由 harness 按**生产口径**补位（见 _ai_drive_sub，用 _best_enemy_sub_idx 选人、
## 走 _auto_sub_on_timeout 同一条落位 API）。
func _sync_dual_control() -> void:
	if not _battle_alive():
		return
	if bool(GameState.dual_control):
		return
	GameState.dual_control = true
	_log("[检视器] 强制 dual_control=true：敌方轮不由 Battle 自动跑 AI（避免两个驱动者）")


## 生产 AI 是否正在自己跑这一边（判断依据全部来自 Battle 的公开状态，不猜）：
##   ① _enemy_plan_running：Battle._replay_enemy_plan 回放期间为 true；
##   ② _ai_thread 已启动：Battle._run_enemy_turn 的后台搜索线程在跑；
##   ③ state == ENEMY_TURN：dual_control=false 时 _begin_side 会走生产 AI 那条路。
## 命中任一条 → 检视器**退让**，绝不并排驱动（实机崩过一次：`wait_to_finish` on null value）。
func _production_ai_busy() -> bool:
	if not _battle_alive():
		return false
	if bool(_battle._enemy_plan_running):
		return true
	var t = _battle._ai_thread
	if t != null and t is Thread and (t as Thread).is_started():
		return true
	return int(_battle.state) == int(Battle.State.ENEMY_TURN)


## AI 操作的那一方阵亡后，按**生产口径**替它补位（用户要求：陪练对手行为必须与困难档一致）。
##
## 生产在"手动"口径下会弹替补面板等真人点选（_is_manual_sub_faction 在 dual_control=true 时对双方
## 都成立，而 dual_control 必须恒 true，见 _sync_dual_control）；AI 那一侧没有真人可点，
## 所以本函数就替那一次点击：
##   · **选谁**用生产自己的 `_best_enemy_sub_idx()`（"此刻最合"的评分，src/Battle.gd:4388），
##     不自己发明优先级；
##   · **怎么落位**用 `_auto_sub_on_timeout()` 走的同一条 API：
##     `_on_sub_pick(hero)` → `_auto_sub_cell(fn)` → `_try_place_sub(cell)`（src/Battle.gd:4508-4526）。
## 差别只有一个：它挑 `roster[0]`，我们挑生产最优下标。落点/费用/墓碑清理/光环全走 Battle 自己的。
##
## 参数是**阵营**（不是行动方）：替补面板属于哪个阵营与"谁在行动"无关（见 _sub_panel_faction）。
## 传错阵营**不会报错**——`_on_sub_pick` 会因"人选不在该面板 roster 里"静默 return
## （src/Battle.gd:4556-4558），然后 `_try_place_sub` 因 `_pending_sub==""` 也 return
## （同文件 :4575）→ 面板就这么挂着，这正是本次要修的 bug。
func _ai_drive_sub(fn: int) -> void:
	if _battle == null or not is_instance_valid(_battle):
		return
	var st := int(_battle.state)
	# ★ 放宽判据（见 _sub_signal_pending_faction）：state 不在那两态、但游戏确实开过替补面板
	# 且尚未落位、且不是演出中 → 也接管（否则只能等 90 秒回合超时兜底，就是用户报的现象）。
	var relaxed := false
	if st != int(Battle.State.SUBSTITUTING) and st != int(Battle.State.PLACE_SUB):
		if _sub_signal_pending_faction() == int(fn):
			relaxed = true
		else:
			return
	var roster: Array = _battle._roster_of(fn)
	if roster.size() <= 0:
		return
	var idx: int = _battle._best_enemy_sub_idx() if fn == DataRegistry.Faction.ENEMY else 0
	idx = clampi(idx, 0, roster.size() - 1)
	var hero: String = String(roster[idx])
	var in_roster: bool = roster.has(hero)
	var pick_ret := ""
	var place_txt := "-"
	var place_ok := false
	if st == int(Battle.State.SUBSTITUTING):
		_log("[检视器] AI 那方（%s）替补：按生产口径 _best_enemy_sub_idx=%d → 选 %s" % [
			_side_txt(_side_of_faction(fn)), idx, hero])
		_battle._on_sub_pick(hero)
		# 逐步取证：`_on_sub_pick` 会校验"人选必须在该面板 roster 里"，不合格会**静默 return**，
		# 所以必须把返回后的 `_pending_sub` 与 state 都打出来（否则失败是无声的，用户只看到"等了很久"）。
		pick_ret = "state=%d _pending_sub=%s" % [int(_battle.state), String(_battle._pending_sub)]
	var cell: Vector2i = _battle._auto_sub_cell(fn)
	if cell.x == -99 and cell.y == -99:
		_log("[替补·接管] 面板阵营=%s roster=%d 选中=%s（在 roster 内=%s）%s；落位格=暂无（下一帧重试）" % [
			_side_txt(_side_of_faction(fn)), roster.size(), hero, str(in_roster), pick_ret])
		return               # 暂无落位点：下一帧再试（与 _auto_sub_on_timeout 同处理）
	var cell_txt: String = _cell(cell)
	# ★ 接管当场的那一行（控制台）：归属 / 接管 / 选了谁 / 落哪格。
	# **不在这里算耗时**——`_try_place_sub` 内部会发 `sub_placed`，那时 `_sub_panel_open_ms`
	# 已被收尾清零，再用它减就等于把"绝对 tick 数"当耗时打出来（用户看到的
	# `耗时=96548ms` 就是这个假数字）。真实耗时统一由 `_on_sub_placed` 那条算。
	_say_console("[替补] 面板归属=%s 接管=是 选中=%s 落位=%s 结果=落位中 state=%d" % [
		_side_txt(_side_of_faction(fn)), hero, cell_txt, int(_battle.state)])
	place_txt = cell_txt
	place_ok = bool(_battle._try_place_sub(cell))
	_sub_last_hero = hero
	_sub_last_cell = place_txt
	if place_ok and _sub_place_ok_ms == 0:
		_sub_place_ok_ms = Time.get_ticks_msec()
		_log("[替补·时间戳] 落位成功=%s（面板出现后 %dms）" % [
			_clock_txt(_sub_place_ok_ms), _sub_place_ok_ms - _sub_panel_open_ms])
	_log("[替补·接管] 面板阵营=%s roster=%d 选中=%s（在 roster 内=%s）%s；落位格=%s → _try_place_sub=%s（放宽判据=%s，观察state=%d）" % [
		_side_txt(_side_of_faction(fn)), roster.size(), hero, str(in_roster), pick_ret,
		place_txt, "成功" if place_ok else "失败（下一帧重试）", str(relaxed), int(_battle.state)])


## 这一边是不是"由检视器驱动"（档位非手动 + 不在部署期 + 没被生产 AI 抢走）
func _ai_driven_by_us(side: int) -> bool:
	if not _battle_alive() or not _deployed:
		return false
	if _mode_of_side(int(side)) == AI_MANUAL:
		return false
	return not _production_ai_busy()


# ================= 交互状态（某方专属的"等你点"状态） =================
#
# 这一节处理一类共同的坑：**"等你点一下"的状态属于哪一方，与"当前行动方"是两件事**，
# 而凡是"AI 那一方"的这类状态，都必须由工具按**生产口径**接管，否则没人点 → 卡到回合限时。
#
# 状态清单（本场景逐个明确处置，不靠"应该不会出现"糊过去）：
#   | 状态          | 本场景是否出现 | 归属怎么判                     | AI 方谁接管                  | 手动方 |
#   |---------------|----------------|--------------------------------|------------------------------|--------|
#   | SUBSTITUTING  | 会             | `_battle._sub_faction`         | `_ai_drive_sub(fn)`          | 留着   |
#   | PLACE_SUB     | 会             | 同上（落位阶段 `_sub_faction` 仍有效） | 同上（选人+落位同一函数） | 留着 |
#   | PLACE_BOMB    | 会             | `_battle._pending_bomb_unit.faction` | `_bomb_takeover_tick()` | 留着 |
#   | PLACE_DEPLOY  | 会             | `_battle._deploy_side` / `_pending_enemy_deploy` | `_deployment_tick()`（已有） | 留着 |
#   | DEPLOY        | 会             | 同上                           | 同上                         | 留着   |
#   | DECK_PICK     | **不会**       | —                              | —（`GameState.pick_deck_in_battle` 恒 false） | — |
#   | ARENA_DRAFT   | **不会**       | —                              | —（`GameState.arena_mode` 恒 false）         | — |
#   | ENDED         | 会             | —                              | 对局已结束，无人需要驱动     | —      |
#
# "归属怎么判"一律**不读 GameState.active_side**：那是"谁在行动"。反例见 _sub_panel_faction 注释。

## 炸弹人"选格放炸弹"（State.PLACE_BOMB）的接管：**按待放置单位的阵营**判谁负责。
##
## 为什么必须接管（用户撞到的真缺口）：`heroes/hero_35_炸弹人.gd:42-50` 里，
## 单机**我方**走 `battle.request_bomb_place(u)`（src/Battle.gd:3831）→ 进 `PLACE_BOMB` **等真人点格**，
## **只有敌方**才会自动放"正前方"那一格。检视器里"我方=AI"时**没人点格**：
##   · 炸弹根本没落盘 → 对拍出现 `炸弹@(x,y) 预测有→实际无`（AI 的能力凭空消失）；
##   · 更糟：`PLACE_BOMB` 一直挂着，回合推进不下去（潜在卡死点）。
##
## 落格规则**全部复用游戏自己的**，不自己发明：
##   · 可放格 = 英雄脚本的 `bomb_place_cells()`（内部走 `battle.bomb_cell_ok`，与 UI 高亮/落点复检同一套）；
##   · 挑哪一格 = 与敌方 AI 同口径的"最靠对手底线"（英雄脚本的 `_frontest`，能调就调它）；
##   · 落盘 = `battle._try_place_bomb(cell)`（单机本地放置那条，内部会收尾 `_continue_after_move`）。
func _bomb_takeover_tick() -> void:
	if _battle == null or not is_instance_valid(_battle):
		return
	var via_state: bool = int(_battle.state) == int(Battle.State.PLACE_BOMB)
	var u: Unit = _battle._pending_bomb_unit
	if u == null or not is_instance_valid(u):
		if not via_state:
			_bomb_ev_key = ""
		return
	# ★ 为什么不能只看 `state == PLACE_BOMB`（扫描撞到的漏接管，用户侧表现=炸弹没落地）：
	# 检视器驱动时走的是 `_call_action(a, true)`（for_enemy=true），而 `src/Battle.gd` 的
	# `_finish_move()` 在 `if for_enemy:` 分支里**先 return**，于是后面那段
	# `if _pending_bomb_unit == u: state = PLACE_BOMB; _begin_bomb_place(u)` **根本不会执行** →
	# `state` 永远不进 PLACE_BOMB，只有 `_pending_bomb_unit` 被 `on_move()` 设上了。
	# 只认 state 的话接管永不触发 → 我方炸弹人的雷凭空消失（而模拟照预测一颗 → `炸弹@(x,y) 预测有→实际无`）。
	# 所以判据改成"**待放单位非空**"（state 只是额外信息），并在文件里留一行诊断。
	if not via_state:
		_log("[炸弹接管·诊断] state=%d 不是 PLACE_BOMB，但 _pending_bomb_unit=%s 非空（for_enemy 驱动下 _finish_move 提前 return，跳过了 state 转换）→ 仍按待放单位接管" % [
			int(_battle.state), (u as Unit).hero_id])
	var fn := int((u as Unit).faction)
	var side := _side_of_faction(fn)
	if not _ai_driven_by_us(side):
		# 手动那方：选格界面留给玩家自己点（工具绝不替他决定）
		_bomb_evidence(fn, false, "-", false)
		return
	var hero: HeroBase = _battle._hero(u)
	if hero == null:
		_warn("炸弹接管：拿不到 %s 的英雄脚本 → 无法取可放格" % (u as Unit).hero_id)
		return
	var cells: Array = hero.bomb_place_cells()
	if cells.size() == 0:
		# 周围没有合法空地：与敌方 AI 的 `if cells.size() == 0: return` 同处理——本回合不放雷。
		# 但不能就这么不管：`PLACE_BOMB` 是"等点选"的状态，没人点就卡住，所以按游戏自己
		# `_begin_bomb_place` 的"没空位"分支收尾（清 pending + 走正常移动收尾）。
		_battle._pending_bomb_unit = null
		_bomb_evidence(fn, true, "无合法空地", false)
		_log("[炸弹接管] %s(%s) 周围无合法空地 → 取消本次放雷并按游戏自身路径收尾" % [
			(u as Unit).display_name, (u as Unit).hero_id])
		if via_state:
			_battle._continue_after_move(u)
		return
	var best: Vector2i = _bomb_frontest(hero, u, cells)
	var placed: bool = bool(_battle._try_place_bomb(best))
	_bomb_evidence(fn, true, _cell(best), placed)
	if not placed:
		_warn("炸弹接管：落格 %s 被 Battle 拒绝（_try_place_bomb=false）→ 下一帧重试" % _cell(best))


## 挑"最靠对手底线"的可放格：**优先调英雄脚本自己的 `_frontest`**（同一条规则，不重复实现），
## 拿不到（脚本改名/换实现）时退回本函数内的同语义实现：
## 玩家朝上打 → world y 最小；敌方朝下打 → world y 最大（即 -y 最小）。
func _bomb_frontest(hero: HeroBase, u: Unit, cells: Array) -> Vector2i:
	if hero.has_method("_frontest"):
		var r = hero.call("_frontest", cells)
		if r is Vector2i and (cells as Array).has(r):
			return r
	var best: Vector2i = cells[0]
	var best_d := INF
	var is_player: bool = int((u as Unit).faction) == int(DataRegistry.Faction.PLAYER)
	for n in cells:
		var d: float = _battle.grid.cell_to_world(n).y
		if not is_player:
			d = -d
		if d < best_d:
			best_d = d
			best = n
	_log("[炸弹接管] 英雄脚本没有可用的 `_frontest` → 用同口径的内置实现挑格（最靠对手底线）")
	return best


## 炸弹接管的机读证据（运行时文件）：单位/阵营/档位/选了哪格/是否成功。
func _bomb_evidence(fn: int, take: bool, cell_txt: String, placed: bool) -> void:
	var key := "%d|%s|%s|%s" % [fn, str(take), cell_txt, str(placed)]
	if key == _bomb_ev_key:
		return
	_bomb_ev_key = key
	var side := _side_of_faction(fn)
	_log("[炸弹接管·归属] 阵营=%s 档位=%s 当前行动方=%s 接管=%s 落格=%s 成功=%s" % [
		_side_txt(side), _ai_name(_mode_of_faction(fn)), _side_txt(int(GameState.active_side)),
		"是（按生产口径自动放雷）" if take else "否（选格界面留给玩家）", cell_txt, str(placed)])
	if take:
		# 分层规则：接管**结果**一行进控制台（用户不用翻文件就能确认雷落地了）
		_say_console("[炸弹] 阵营=%s 接管=是 落格=%s 结果=%s" % [
			_side_txt(side), cell_txt, "成功" if placed else "失败"])


## 当前"某方专属的等交互状态"（没有则返回空字典）。
## 看门狗与报告都用它，避免"每处各判一遍"导致口径不一致。
func _interact_state_info() -> Dictionary:
	if _battle == null or not is_instance_valid(_battle):
		return {}
	var st := int(_battle.state)
	if st == int(Battle.State.SUBSTITUTING) or st == int(Battle.State.PLACE_SUB):
		var fn := _sub_panel_faction()
		if fn < 0:
			return {}
		return { "name": "替补面板/落位", "fn": fn }
	if st == int(Battle.State.PLACE_BOMB):
		var u: Unit = _battle._pending_bomb_unit
		if u == null or not is_instance_valid(u):
			return {}
		return { "name": "放炸弹选格", "fn": int((u as Unit).faction) }
	if st == int(Battle.State.PLACE_DEPLOY) or st == int(Battle.State.DEPLOY):
		# 部署阶段归属看 Battle 自己的落位方（_deploy_side）与 pending 归属，不读 active_side。
		var dside := int(_battle._deploy_side)
		var pending_enemy := String(_battle._pending_enemy_deploy) != ""
		var dfn: int = int(DataRegistry.Faction.ENEMY) if pending_enemy \
				else _battle.side_faction(dside)
		return { "name": "部署/落位", "fn": dfn }
	if st == int(Battle.State.DECK_PICK) or st == int(Battle.State.ARENA_DRAFT):
		# 本场景**不该出现**（arena_mode / pick_deck_in_battle 恒 false）。
		# 真出现就说明有别的入口把它打开了：如实报，不静默。
		return { "name": "选卡/选秀（本场景不该出现）", "fn": -1 }
	return {}


## 交互状态看门狗：AI 那方的交互状态挂着超过 INTERACT_WALL_MS 且没人驱动 → 告警（进运行时文件）。
## 目的：把"AI 少做一个环节"这类问题在批量扫描里自动暴露，不用等用户一个个撞。
## 判据只看"归属阵营的档位 + 我们有没有接管"，不读 active_side（见上）。
func _interact_watchdog() -> void:
	var info := _interact_state_info()
	if info.is_empty():
		_interact_key = ""
		_interact_since = 0
		return
	var st_name := String(info.get("name", ""))
	var fn := int(info.get("fn", -1))
	var take := false
	if fn >= 0:
		take = _ai_driven_by_us(_side_of_faction(fn))
	var key := "%s|%d|%s" % [st_name, fn, str(take)]
	var now := Time.get_ticks_msec()
	if key != _interact_key:
		_interact_key = key
		_interact_since = now
		_interact_warned = false
		return
	if take or _interact_warned:
		return
	if now - _interact_since < INTERACT_WALL_MS:
		return
	_interact_warned = true
	# 手动那方"没人点"是设计（真人自己点），但**无头自检里没有真人**，一样是无人驱动 → 也报，
	# 只是把两种原因分开写清楚，免得看告警的人猜。
	var why := "该阵营档位=AI 但我们没接管（驱动权判定漏了这一路）"
	if fn >= 0 and _mode_of_faction(fn) == AI_MANUAL:
		why = "该阵营档位=手动且无人点（无头自检里没有真人；手动游玩时属正常，等玩家点）"
	_warn("交互状态无人接管：%s（%s / 档位=%s）已持续 %dms" % [
		st_name, _side_txt(_side_of_faction(fn)) if fn >= 0 else "归属未知",
		_ai_name(_mode_of_faction(fn)) if fn >= 0 else "?", now - _interact_since])
	_warn("交互状态无人接管原因：%s" % why)


# ================= 观战锁（按"哪一方用 AI"分别锁） =================
#
# 用户口径：点哪一方用 AI，就锁哪一方的操作（不能替那一方点棋子、HUD 的结束回合/撤下在那一方回合禁用）；
# 档位=手动的那一方**照常由玩家自己打**，工具不插手、也不自动结束它的回合。
# 两边都 AI = 整局观战。
#
# 为什么不用 dual_control 去锁：dual_control=false 会在 Battle._begin_side 里放出**生产 AI**
# （src/Battle.gd:1834-1848），于是同一回合两个驱动者 → 上次实机崩的
# `wait_to_finish on null`（Battle.gd:5047）。所以 dual_control 恒 true（见 _sync_dual_control），
# 锁输入走"屏蔽输入 + 禁用 HUD 按钮"这一路。

## 当前是否应当锁住玩家输入（= 正在行动的那一方由 AI 驱动）
func _watch_lock_active() -> bool:
	return _deployed and _ai_driven_by_us(int(GameState.active_side))


## 每帧同步观战锁状态：进/出锁时各做一次显式动作（屏蔽输入、禁用 HUD 按钮），
## 并刷新 Battle 自己的高亮/棋盘表现，避免"过时高亮"留在场上。
func _sync_watch_lock() -> void:
	var want := _watch_lock_active()
	# 只在"开始锁 / 换边锁 / 解锁"时打日志：否则每次我方回合都会刷一行"进入观战"，
	# 看起来像反复进出锁（其实只是 active_side 在我方回合把它算成不锁）。
	var cur := int(GameState.active_side) if want else -1
	if cur == _watch_side_locked:
		if want:
			# 自愈：重建沙箱/换过 Battle 实例后，新实例的未处理输入默认是开的，
			# 而这里会因为"锁的边没变"提前 return → 那一局就漏锁了。所以锁着的时候每帧确认一次。
			if _battle != null and is_instance_valid(_battle) and _battle.is_processing_unhandled_input():
				_battle.set_process_unhandled_input(false)
			_ensure_back_btn_clickable()   # 锁着也保证「返回选人」可点（用户唯一出路）
			_refresh_action_highlights()   # 锁着的时候也持续保持正确（AI 每出一招后都会调用）
		return
	_watch_locked = want
	_watch_side_locked = cur
	_apply_hud_watch_state(want)
	_assert_watch_lock_state(want)
	if want:
		_log("[锁] 进锁：%s回合（%s）→ set_process_unhandled_input(false)、HUD 操作按钮禁用" % [
			_side_txt(GameState.active_side), _ai_name(_mode_of_side(int(GameState.active_side)))])
	elif _deployed:
		_log("[锁] 解锁：本回合由玩家自己打（%s）" % _side_txt(GameState.active_side))
	_refresh_action_highlights()


## 取本脚本的构建戳：优先读文件 sha256 前 12 位（改了脚本就变），读不到用编译期常量兜底。
## 为什么要它：用户与我在不同构建上排查过很久——"日志 mtime 是新的"并不代表"跑的是新代码"
## （编辑器不热更脚本）。有了这行，5 秒就能判断跑的是哪一版。
const BUILD_TAG_FALLBACK := "BUILDTAG-NA"
## 本脚本自身的资源路径（构建戳取它的 sha）。
const SCRIPT_PATH := "res://RL/harness/自由部署_模拟检视.gd"
func _compute_build_tag() -> String:
	if FileAccess.file_exists(SCRIPT_PATH):
		var h := FileAccess.get_sha256(SCRIPT_PATH)
		if h.length() >= 12:
			return h.substr(0, 12).to_upper()
	return BUILD_TAG_FALLBACK


## 运行时日志：**除对拍块外，我们自己的所有输出都走这里（写文件，不进控制台）**。
##
## ============================ 两层输出规则（务必遵守） ============================
## 控制台（stdout）**只允许**这几类，每类保持"短、一行"，且**不许插进某个对拍块中间**
## （对拍块是在 `_print_chk` 里一次性同步打印的，所以只要不在那里插别的输出就不会撕裂）：
##   ① 构建戳（启动第一行）：`=== 模拟检视 构建=<脚本 sha 前12位> ===`
##   ② 驱动启停：`[驱动] 启动（代际=N，我方档=…，敌方档=…）`
##   ③ 替补接管结果（一行）：`[替补] 面板归属=我方 接管=是 耗时=123ms 观察state=4`
##   ④ 部署结果（一行）：`[部署] 完成：我方 3/3 敌方 3/3`
##   ⑤ **任何 `[告警]`**（接管失败/过慢、无人接管、字段层漏报、TIMING 判据写错…）
##   ⑥ 对拍块原样（用户要靠它复制粘贴）
## 只进文件（不进控制台）：`[替补·接管]` 逐步结果、`[替补·诊断]`、`[替补面板·归属]` 详细行、
##   `[耗时]`、`[每回合状态注入]`、`[一致性]` 复核、部署逐手明细、看门狗明细、其它调试信息。
## 实现：进控制台走 `_say_console()`（**同时写文件**，文件仍是全量证据），只进文件走 `_log()`。
## ================================================================================
##
## 路径：默认 res://RL/reports/对拍_运行时.log，可用 `--rtlog <路径>` 覆盖；每次运行覆盖写。
func _log(msg: String) -> void:
	if _rt_file == null:
		return
	_rt_file.store_line(msg)
	_rt_file.flush()
	# 固定名那份是"最新一局的镜像"：内容与带时间戳那份一致，方便随时看最新一局。
	if _rt_mirror != null:
		_rt_mirror.store_line(msg)
		_rt_mirror.flush()


## 写两处（带时间戳的本局文件 + 固定名镜像），只在开日志时用于写文件头（此时 _build_tag 可能还没算）。
func _write_both(msg: String) -> void:
	_log(msg)


## 两层输出的"控制台那一层"：打控制台**并**写文件（文件保持全量，便于对账）。
## 只给"短、一行、用户需要一眼看到"的东西用（见文件顶部的分层规则）。
func _say_console(msg: String) -> void:
	print(msg)
	_log(msg)


## 告警统一出口：告警必须**同时**进控制台（用户要一眼看到）与文件（机器可读）。
func _warn(msg: String) -> void:
	_say_console("[告警] %s" % msg)


## 让高亮始终等于真实行动点状态：直接复用 Battle 自己的刷新 API，不在 harness 里重画。
## Battle._clear_selection() 会清掉选中与 move/attack 高亮；_refresh_board() 重绘棋盘与单位表现。
## AI 每出一招（_step 结束）与每次锁状态变化后都调一次，避免"AI 行动后高亮不消失"。
func _refresh_action_highlights() -> void:
	if _battle == null or not is_instance_valid(_battle):
		return
	_battle._clear_selection()
	_battle._refresh_board()


## 按观战锁禁用/恢复 HUD 的那几个操作按钮（结束回合 / 重开 / 撤下等），
## 并同时开关 Battle 的未处理输入（真正拦住棋盘点击）。
func _apply_hud_watch_state(locked: bool) -> void:
	# 真正拦住棋盘点击：Battle 读点击的入口**只有** _unhandled_input（src/Battle.gd:2126），
	# 关掉该节点的未处理输入即可。harness 自己驱动 AI 走 _do_move/_do_attack，不经过输入，不受影响。
	# **不能靠 state 拦**：dual_control=true 时敌方回合 Battle 也把 state 设成 PLAYER_INPUT
	# （src/Battle.gd:1834-1840，它本来就设计成"敌方回合你来点"），从 state 区分不出该不该锁。
	if _battle != null and is_instance_valid(_battle):
		_battle.set_process_unhandled_input(not locked)
	var hud: Node = _find_child_by_class(_battle, "HUD") if _battle != null and is_instance_valid(_battle) else null
	if hud == null:
		return
	# ★ 「返回选人」(`_back_btn`) **绝不在这里禁用**（本次修的 bug）：
	#   它是**工具导航**（拆战场 → 回英雄池），不是"替 AI 出手"的操作。
	#   旧实现把三个按钮一起禁用 → 只要锁生效它就点不动；两边都选 AI（观战）时锁几乎永不释放
	#   （active_side 每回合都在 AI 手里）→ 用户**永远回不到选人界面**，只能停掉整个运行。
	#   真正需要禁的是"会让玩家替 AI 行动"的东西：结束回合(`_end_btn`)、以及同类的操作按钮。
	# `_restart_btn`（重开）保持禁用：它同样是"会打断正在跑的 AI"的操作，但**不走**本工具的
	#   代际作废+线程回收路径（那是"返回选人"专用的），没验证过的打断面不放开——解锁后它照常可用。
	#   若以后要放开，必须先把它接到 `_rebuild_sandbox()` 这条安全路径上再验证。
	for btn_name in ["_end_btn", "_restart_btn"]:
		var b = hud.get(btn_name)
		if b is Button:
			(b as Button).disabled = locked


## 自愈 + 机读断言：锁着的时候「返回选人」必须始终可点。
## 为什么要有自愈：任何一处（包括我以后新加的按钮批量处理）误禁了它，用户就会被困住，
## 而他唯一的出路就是这个按钮 —— 所以锁期间每帧确认一次，发现被禁就当场恢复并留一行证据。
func _ensure_back_btn_clickable() -> void:
	if _battle == null or not is_instance_valid(_battle):
		return
	var hud: Node = _find_child_by_class(_battle, "HUD")
	if hud == null:
		return
	var bb: Button = _find_button_by_text(hud, "返回选人")
	if bb == null:
		return
	if (bb as Button).disabled:
		(bb as Button).disabled = false
		_log("[锁自愈] 「返回选人」被误禁用 → 已当场恢复（否则用户回不去选人界面）")


## 机读断言：锁生效期间「返回选人」必须是可点的（写运行时文件，不进控制台）。
func _assert_back_btn_state() -> void:
	if _battle == null or not is_instance_valid(_battle):
		return
	var hud: Node = _find_child_by_class(_battle, "HUD")
	var bb: Button = _find_button_by_text(hud, "返回选人") if hud != null else null
	if bb == null:
		_log("[锁断言] 未找到「返回选人」按钮，无法断言其可用性（按钮可能改名）")
		return
	_log("[锁断言] 锁生效=%s：_back_btn.disabled=%s %s（「返回选人」是工具导航，锁期间必须可点）" % [
		str(_watch_locked), str((bb as Button).disabled),
		"OK" if not (bb as Button).disabled else "!! 被禁用 → 用户回不去选人界面 !!"])


## 显式解锁：把输入与 HUD 按钮都恢复回去。
## 为什么单独有一个函数：解锁的触发点不止"锁状态变化"一处（切档回手动、回合换到手动方、
## 重建沙箱、场景退出），任何一条路径漏掉都会让玩家整局点不动。所以统一走这里 + 每条路径都调。
func _release_watch_lock() -> void:
	if _battle != null and is_instance_valid(_battle):
		_battle.set_process_unhandled_input(true)
	_watch_locked = false
	_watch_side_locked = -1
	_apply_hud_watch_state(false)
	_log("[锁] 解锁：set_process_unhandled_input(true)，HUD 操作按钮恢复")


## 机读断言（写进运行时文件，不进控制台）：锁的状态必须与 Battle 的实际输入开关一致。
func _assert_watch_lock_state(expect_locked: bool) -> void:
	if _battle == null or not is_instance_valid(_battle):
		return
	var processing := _battle.is_processing_unhandled_input()
	var ok := processing != expect_locked     # 锁住时 processing 应为 false
	_log("[锁断言] 期望%s → is_processing_unhandled_input()=%s %s" % [
		"锁住" if expect_locked else "解锁", str(processing), "OK" if ok else "!! 不一致 !!"])
	_assert_back_btn_state()


## 部署是否已结束（双方各上满 3 人 → Battle 自己会 _begin_after_deploy → _start_match）。
## **判据不能用 `GameState.match_running`**：英雄池路径走 keep_picks=true，不再调 reset_online()，
## 于是上一局的 `match_running=true` 会残留在 GameState 里，导致这里第一帧就误判"部署已完成"
## （实测后果：部署只上了 1 个人就进对局）。所以严格按 Battle 自己的部署状态判断。
func _deploy_finished() -> bool:
	if _battle == null or not is_instance_valid(_battle):
		return false
	if GameState.match_over:
		return true
	var st := int(_battle.state)
	var not_deploying: bool = st != int(Battle.State.DEPLOY) and st != int(Battle.State.PLACE_DEPLOY)
	return not_deploying \
			and _battle.player_deployed.size() >= Battle.DEPLOY_COUNT_BATTLE \
			and _battle.enemy_deployed.size() >= Battle.DEPLOY_COUNT_BATTLE


## 部署阶段每帧调用：**只驱动"档位=AI"的那些边**，一手一手地部署（用生产自己的选人逻辑）。
## 手动那边（档位=手动）完全交给玩家点游戏自己的部署界面，工具不插手、也不替它结束。
##
## 为什么走生产那条路：
##   · 生产单机在 `_deploy_after_pick()` 里就是 `_enemy_deploy.call_deferred()` 让敌方 AI 上人
##     （src/Battle.gd:1346-1349），而 `_enemy_deploy()`（:1281）用的正是"按 `_deploy_candidate_value`
##     打分挑最合适首发"的生产逻辑——用户要求陪练对手与单机困难档一致，所以直接复用该评估口径，
##     **不自己写"按勾选顺序取前 3"**。
##   · 敌方轮（`_deploy_side==1`）且敌方档位=AI：Battle 自己已经会自动跑（上面那句 call_deferred），
##     这里不重复驱动，只让生产自己走。
##   · 我方轮（`_deploy_side==0`）且我方档位=AI：Battle 不会自动上人（那是留给真人点的），
##     所以由这里按**同一套生产评估**挑人 + 调游戏自己的部署 API 落位（选人→落位两步）。
func _deployment_tick() -> void:
	if _battle == null or not is_instance_valid(_battle):
		return
	var st := int(_battle.state)
	var side := int(_battle._deploy_side)     # 0 = 我方轮，1 = 敌方轮
	var ai_side: bool = (_mode != AI_MANUAL) if side == 0 else (_emode != AI_MANUAL)
	if not ai_side:
		return                          # 手动那一边：玩家自己点
	# —— 情况 A：上一个 AI 手已经"选好人"，现在卡在"选落点"（PLACE_DEPLOY）——
	# 必须把落点替他选完，否则这一手永远悬着（实测：只选人不落位 → 部署停在第 1 手）。
	# 依据（HUD 的真实两步序列，src/HUD.gd:628-642 + Battle.gd:2166-2173）：
	#   ① 点英雄卡：state==DEPLOY 时调 _on_deploy_pick(hid) → 写入 `_pending_deploy`、state=PLACE_DEPLOY；
	#   ② 点棋盘格：state==PLACE_DEPLOY 时，**看 `_pending_enemy_deploy` 是否为空**决定放哪一方
	#      （空→_try_place_deploy，非空→_try_place_enemy_deploy），落格必须是"该方出生格且空格"。
	# 所以这里就是"替 AI 点那一下棋盘格"。
	if st == int(Battle.State.PLACE_DEPLOY):
		var fn_a: int = DataRegistry.Faction.PLAYER if side == 0 else DataRegistry.Faction.ENEMY
		var cell_a: Vector2i = _battle._free_spawn_cell(fn_a)
		var has_p: bool = String(_battle._pending_deploy) != ""
		var has_e: bool = String(_battle._pending_enemy_deploy) != ""
		if cell_a.x == -99 and cell_a.y == -99:
			return                      # 没空格：下一帧再试
		var placed := false
		if has_p and side == 0:
			placed = _battle._try_place_deploy(cell_a)
		elif has_e and side == 1:
			placed = _battle._try_place_enemy_deploy(cell_a)
		elif has_e:
			# 上一手是敌方选的（pending 在敌方侧），但轮次已回到我方：先把敌方那一手落完，
			# 否则这个 pending 会一直挂着、state 永远出不去 PLACE_DEPLOY。
			placed = _battle._try_place_enemy_deploy(cell_a)
		elif has_p:
			placed = _battle._try_place_deploy(cell_a)
		_log("[部署] %s落位（AI）：%s → %s 结果=%s" % [
			_side_txt(side), "(pending p)" if has_p else ("(pending e)" if has_e else "(无 pending)"),
			str(cell_a), str(placed)])
		return
	if st != int(Battle.State.DEPLOY):
		return                          # 已开打：不插手
	if side == 1:
		return                          # 敌方轮且敌方=AI：生产自己会跑 _enemy_deploy，别重复驱动
	var pool: Array = _battle.player_pool
	var deployed: Array = _battle.player_deployed
	if pool.size() <= 0 or deployed.size() >= Battle.DEPLOY_COUNT_BATTLE:
		return
	# —— 选谁：复用生产 _enemy_deploy 的评估口径（首发按 _hero_strength，之后按协同）——
	var best_i := -1
	var best_sc := -1e18
	for i in pool.size():
		var cand: String = pool[i]
		var cd: DataRegistry.HeroDef = DataRegistry.get_hero(cand)
		if cd != null and cd.skills.has(DataRegistry.Skill.BENCH):
			continue                    # 带<替补>标签的不主动首发（与生产一致）
		var sc: float = _battle._hero_strength(cand) if deployed.size() == 0 \
				else float(_battle._deploy_candidate_value(cand, deployed))
		if sc > best_sc:
			best_sc = sc
			best_i = i
	if best_i < 0:
		best_i = 0                      # 全是替补型：退回第一个（与生产同兜底）
	var hid: String = pool[best_i]
	# —— 落在哪格：用生产自己的空格搜索 ——
	var cell: Vector2i = _battle._free_spawn_cell(DataRegistry.Faction.PLAYER)
	if cell.x == -99 and cell.y == -99:
		return                          # 出生区满了：下一帧再试
	# —— 调游戏自己的部署 API（选人 → 落位两步）——
	_battle._on_deploy_pick(hid)
	_battle._try_place_deploy(cell)
	_log("[部署] %s第 %d 手（AI）：选 %s，落 %s；进度 我方 %d/%d 敌方 %d/%d" % [
		_side_txt(side), deployed.size() - 1, hid, str(cell),
		_battle.player_deployed.size(), Battle.DEPLOY_COUNT_BATTLE,
		_battle.enemy_deployed.size(), Battle.DEPLOY_COUNT_BATTLE])


## 部署结束后的机读断言：双方各 3 人上阵，且都来自各自卡组（勾选的卡组必须真的用上）
func _assert_deploy_done() -> void:
	if _battle == null or not is_instance_valid(_battle):
		return
	var ok := true
	if _battle.player_deployed.size() != Battle.DEPLOY_COUNT_BATTLE:
		ok = false
		_warn("我方上阵人数 %d ≠ %d" % [_battle.player_deployed.size(), Battle.DEPLOY_COUNT_BATTLE])
	if _battle.enemy_deployed.size() != Battle.DEPLOY_COUNT_BATTLE:
		ok = false
		_warn("敌方上阵人数 %d ≠ %d" % [_battle.enemy_deployed.size(), Battle.DEPLOY_COUNT_BATTLE])
	for hid in _battle.player_deployed:
		if not GameState.player_deck.has(hid):
			ok = false
			_warn("我方上阵的 %s 不在卡组里" % hid)
	for hid2 in _battle.enemy_deployed:
		if not GameState.enemy_deck.has(hid2):
			ok = false
			_warn("敌方上阵的 %s 不在卡组里" % hid2)
	# 正常对战规则下再补一条：卡组人数必须 ≤ 上限（3 首发 + 2 替补）。
	# 这条是"选人校验漏了"的兜底——部署都跑完了才发现超编，说明前面那道门没拦住。
	if not GameState.no_death_limit:
		var limit := int(Battle.DEFAULT_DECK_SIZE)
		if GameState.player_deck.size() > limit or GameState.enemy_deck.size() > limit:
			ok = false
			_warn("正常对战规则下卡组超上限 %d：我方 %d 人 / 敌方 %d 人" % [
				limit, GameState.player_deck.size(), GameState.enemy_deck.size()])
	_log("[部署断言] %s：我方上阵 %s（卡组 %d 人）/ 敌方上阵 %s（卡组 %d 人）" % [
		"通过" if ok else "不通过", str(_battle.player_deployed), GameState.player_deck.size(),
		str(_battle.enemy_deployed), GameState.enemy_deck.size()])


## 是否需要本场景接管：当前行动方那一侧开着 AI + 已进入可操作状态。
## 注意 _deployed：部署阶段 state 也可能是 PLAYER_INPUT，那时若接管就会去 _end_side，
## 把部署流程整个掀翻（部署必须走完 Battle 自己的 _begin_after_deploy）。
##
## 关于 state：dual_control 恒 true 时，敌方轮也是 PLAYER_INPUT（src/Battle.gd:1834-1840）；
## 这里仍同时接受 ENEMY_TURN，是为了在**任何**配置下一旦敌方轮交给生产 AI，我们也认得出来
## （那时由 _production_ai_busy() 让路，见下）。
##
## 硬保护：真正开跑前还要确认 Battle 没在自己跑生产 AI（_production_ai_busy），
## 任何情况下都不允许"同一边两个驱动者"。
func _need_ai_turn() -> bool:
	if not _battle_alive() or not _deployed:
		return false
	if _mode_of_side(int(GameState.active_side)) == AI_MANUAL:
		return false
	if GameState.match_over:
		return false
	if _production_ai_busy():
		return false        # 生产 AI 已在跑这一边 → 退让，不介入
	var st := int(_battle.state)
	if st == int(Battle.State.PLAYER_INPUT) or st == int(Battle.State.ENEMY_TURN):
		return true
	return false             # 替补面板/部署/演出中：等它自己走完


## 一趟完整的行动回合（我方或敌方，由 active_side 决定）：建计划 → 逐招对拍 → _end_side 交回对面
func _drive_turn() -> String:
	var side := GameState.active_side
	var fn := _battle.side_faction(side)
	var ai_mode := _mode_of_side(int(side))
	if ai_mode == AI_MANUAL:
		return "side_end"     # 手动档：本场景不插手（真人自己点）
	# 演示/取证：人为造一次近战攻击，产出"含反击的对拍块"（AI 对局里撞不到，见 _demo_counter 注释）
	if _demo_counter:
		await _run_demo_counter(side)
		if not _battle_alive() or GameState.match_over:
			return "side_end"
		_battle.state = Battle.State.ANIMATING
		await _battle._end_side(side)
		return "side_end"
	_desc_keys = _battle.units.duplicate()
	_plan_hero = []
	for u in _desc_keys:
		_plan_hero.append((u as Unit).hero_id if u != null and is_instance_valid(u) else "")
	_new_hero = true
	_replan_count = 0           # 新回合：重算次数清零（上限是"每回合"的）
	# _build_plan 现在是协程（内部 await 后台搜索），**必须 await 调用**：
	# 否则 GDScript 报 'Function "_build_plan()" is a coroutine, so it must be called with "await"'，
	# 而且不 await 时拿到的是协程状态而不是 bool，会连锁搞乱本回合的推进。
	if not await _build_plan(fn, ai_mode):
		return "error"
	if _plan.is_empty():
		_log("[检视器] 第 %d 回合·%s：AI=%s 计划为空（无可行动作）" % [
			GameState.round_number, _side_txt(side), _ai_name(ai_mode)])
	while _pi < _plan.size():
		if not _battle_alive() or GameState.match_over:
			break
		# 计划元素是 { idx, action }：idx 是 _desc_keys 里的下标，action 才是喂给 _apply/_do_* 的字典
		var step: Dictionary = _plan[_pi] as Dictionary
		_pi += 1
		_cur_idx = int(step.get("idx", -1))
		_cur_act = step.get("action", {}) as Dictionary
		# ★ 空过（act-noop）：候选 fork 把"什么都不做"当**合法候选**
		#   （`RL/ai/AI_Battle.gd:679/686/701/876`，AI 有时会选它）→ 计划元素存在但没有任何动作键。
		#   这在模拟里是**平凡可预测**的（局面不变），不是"未建模的动作"，所以：
		#   不出对拍块、不建 sim、不计入 printedBlocks/simChecks、也不报 NOPRED；**继续驱动下一招**
		#   （绝不能因为空过就停在这一步）。旧行为是走到 `_predict` 报
		#   `NOPRED：动作类型超出模拟支持：none` —— 那是分类错误。
		if _is_noop_action(_cur_act):
			_log("[检视器] 第%d回合·%s：%s 本招为**空过**（act-noop，计划里没有动作）→ 按设计跳过对拍、继续下一招" % [
				GameState.round_number, _side_txt(side), _view_name(_desc_keys, _cur_idx)])
			continue
		var r: String = await _step(_cur_act)
		if r == "changed":
			_log("[检视器] 单位集合已变化（阵亡出列/替补落位），本回合剩余计划作废")
			break
		# ★ 盘面分叉重算（用户要求）：本招判定为**字段级 DIFF**（= 模拟把这块盘面算错了）时，
		# 作废剩余计划并**立刻用当前真实盘面重新建计划**，别带着错假设走完后面几手。
		# 不触发的情形（都不是"模拟算错盘面"）：TIMING 墓碑采样差 / PROCESS 仅过程差异 /
		# SPAN 场外变化（重算也没用，下一招本来就会重新取快照）/ MATCH。
		if _replan_on_diff and _last_verdict == "DIFF" and not _replan_noise_only(_last_diffs):
			if _replan_count < REPLAN_MAX_PER_TURN:
				_replan_count += 1
				var left := _plan.size() - _pi
				_log("[重算] 第%d回合 第%d次：原因=字段级 DIFF；触发差异=%s；旧计划剩余 %d 招作废；开始重算" % [
					GameState.round_number, _replan_count, str(_last_diffs), left])
				_say_console("[重算] 第%d回合 第%d次：字段级 DIFF → 作废剩余 %d 招，立刻用真实盘面重算" % [
					GameState.round_number, _replan_count, left])
				var t_re := Time.get_ticks_msec()
				_desc_keys = _battle.units.duplicate()
				_plan_hero = []
				for u2 in _desc_keys:
					_plan_hero.append((u2 as Unit).hero_id if u2 != null and is_instance_valid(u2) else "")
				var ok_re: bool = await _build_plan(fn, ai_mode)
				_log("[耗时] 盘面分叉重算：search+建计划 %dms（第%d回合第%d次）→ 新计划 %d 招" % [
					Time.get_ticks_msec() - t_re, GameState.round_number, _replan_count, _plan.size()])
				if not ok_re:
					_log("[重算] 重算失败 → 停止本回合剩余动作")
					break
				continue
			else:
				_warn("本回合重算已达上限（%d/%d），剩余动作仍按旧计划执行" % [
					_replan_count, REPLAN_MAX_PER_TURN])
		elif _replan_on_diff and _last_verdict == "DIFF" and _replan_noise_only(_last_diffs):
			# 触发差异全部属于"判定层已知噪声类"（见 REPLAN_NOISE_PREFIXES）→ **不重算**，
			# 只登记一行，避免"为一条假 DIFF 白算一次搜索、还打满每回合上限"。
			_log("[重算] 跳过：字段级差异全部属于判定层已知噪声类（%s），不重算（判定照旧按 DIFF 如实报）" % str(_last_diffs))
	_ai_busy = false                 # _end_side 内部有 0.8s 换边停顿：别让看门狗把它算成"AI 卡住"
	if not _battle_alive() or GameState.match_over:
		return "side_end"
	_battle.state = Battle.State.ANIMATING   # 锁住输入，直到 _end_side 走完
	await _battle._end_side(side)
	await _wait_until(func():
		return GameState.match_over or not _battle_alive() or _battle_ready(),
		SIDE_WALL_MS, SIDE_WALL_FRAMES)
	return "side_end"


## 让 ai_mode 档位替 side 这一方规划并建好本回合计划。
## fork 永远把 ENEMY 当"我方"，所以替**玩家方**规划时必须镜像 fn 标签（见 _relabel）。
func _build_plan(fn: int, ai_mode: int) -> bool:
	_ai = _make_ai(ai_mode)
	if _ai == null:
		return false
	var snap: Dictionary = SNAP.collect(_battle)
	var descs: Array = snap["descs"]
	# ★ 回合开始规划用的那份 descs 也要注入（口径与 _predict 完全一致）。
	#   回合开始时这三项一般全 false，但"中途重建计划"或"换边后本回合已行动过"的情况下就不是了——
	#   统一注入，避免两处口径不一致。
	_inject_turn_flags(descs, _battle.units)
	if fn != DataRegistry.Faction.ENEMY:
		descs = _relabel(descs)   # 替我（玩家）方规划：对调 fn 标签
	# 按回合开始的真实局面建一份 sim 交给 AI 搜索（这是 AI "自己那份世界"的起点）。
	# active_fn 必须传**真实**行动方阵营：缺省值 = ENEMY，它只影响"圣光只在敌方回合护己方"
	# 这类看回合归属的技能；替我（玩家）方规划时不传就会按错的回合归属判定。
	# 只有 RL候选 fork 有第 8 参：「原版困难档」是 src/BattleAI.gd 的逐字节副本，
	# build_state 只收 7 个参数，多传会直接报 "Expected 7 argument(s)"。所以先探能力再传。
	var tb0 := Time.get_ticks_msec()
	var sim
	# 第 9 参 rosters（只有 RL候选 fork 有）：传了才能预测"本招击杀 → 该方替补登场"。
	# 第 10 参 auto_sub（只有本轮之后的 fork 有）：**按阵营**说明"这一方的替补由工具按生产口径点"，
	# 见 `_auto_sub_sides`。不传（老 fork/原版副本）= 谁都不预测替补 = 改动前行为。
	if _ai_supports_auto_sub(_ai):
		sim = _ai.build_state(descs, snap["occ"], snap["gold"], snap["grave"],
				snap["obstacle"], snap["bomb"], snap["buff"], fn, snap.get("rosters", {}), _auto_sub_sides())
	elif _ai_supports_rosters(_ai):
		sim = _ai.build_state(descs, snap["occ"], snap["gold"], snap["grave"],
				snap["obstacle"], snap["bomb"], snap["buff"], fn, snap.get("rosters", {}))
	elif _ai_supports_active_fn(_ai):
		sim = _ai.build_state(descs, snap["occ"], snap["gold"], snap["grave"],
				snap["obstacle"], snap["bomb"], snap["buff"], fn)
	else:
		sim = _ai.build_state(descs, snap["occ"], snap["gold"], snap["grave"],
				snap["obstacle"], snap["bomb"], snap["buff"])
	# 这里本来还有一行 `var tb := Time.get_ticks_msec()`（取完 sim、search 之前的时间戳），
	# 但线程化后 search 的耗时改由 _search_async 内部用 t_build 自行计时，这个变量再没被用到，
	# 于是编辑报 UNUSED_VARIABLE —— 直接删掉，对行为无影响。
	# 这一句以前是**主线程同步搜索**：time_budget_ms=0 + BEAM 决定它能跑几秒，
	# 期间整个界面冻住（用户："卡面不要卡死"）。现在照抄 src/Battle.gd:5033-5047 的范式
	# 挪到后台线程，主线程只轮询 process_frame —— 结果完全一样，只是不再挡界面。
	var t_build := Time.get_ticks_msec()
	_plan = await _search_async(_ai, sim, fn, ai_mode, tb0, t_build)
	_pi = 0
	_cur_act = {}
	_log("[检视器] 第 %d 回合·%s：AI=%s 计划 %d 招" % [
		GameState.round_number, _side_txt(GameState.active_side), _ai_name(ai_mode), _plan.size()])
	return true


## 回收后台搜索线程（**必须判空**）。
## 为什么：`_ai_thread` 在本协程轮询期间可能已被别的路径置空/回收（`_exit_tree`、重建、点「返回选人」
## 跳出检视器…），此时再无条件 `wait_to_finish()` 会报
## `Cannot call method 'wait_to_finish' on a null value`（用户实机踩到：跳出检视器后旧协程恢复执行）。
func _join_ai_thread() -> void:
	if _ai_thread == null:
		return
	if _ai_thread.is_started():
		_ai_thread.wait_to_finish()
	_ai_thread = null


## 后台跑 _ai.search()，主线程只轮询等待（不阻塞 UI）。
## 线程安全前提（已逐条核对 RL/ai/AI_Battle.gd）：整个 search/_apply/_evaluate 只读 grid 几何
## （HexGrid，RefCounted）与 DataRegistry 静态表，**不碰场景节点、不发信号、无 await**——与
## BattleSnapshot.gd:10 注释所述"BattleAI 零场景依赖，所以照旧能丢进后台线程"是同一套设计。
## 分工：线程只做"算"并把结果写进静态 SearchHolder；所有实例状态（_search_*、_plan）只在主线程动。
## 返回空数组 = 本次搜索作废（场景已释放/已重开）。
func _search_async(ai, sim, fn: int, ai_mode: int, t_snap0: int, t_snap1: int) -> Array:
	if get_tree() == null:
		return []
	_search_side = fn
	_search_mode = ai_mode
	_search_start_ms = Time.get_ticks_msec()
	_search_active = true
	_search_lock.lock()
	_search_holder.plan = []
	_search_holder.done = false
	_search_lock.unlock()
	if _ai_thread != null and _ai_thread.is_started():
		_ai_thread.wait_to_finish()   # 保险：上一轮不该留残留线程
	_ai_thread = Thread.new()
	_ai_thread.start(_search_worker.bind(ai, sim, _search_lock, _search_holder))
	while true:
		if get_tree() == null:
			# 场景已释放：不再等（回收交给 _exit_tree；线程结果作废）
			_join_ai_thread()
			_search_active = false
			return []
		_search_lock.lock()
		var finished := _search_holder.done
		_search_lock.unlock()
		if finished:
			break
		# 取证（`--test-back N`）：在 **AI 正在后台搜索**的时候点「返回选人」，
		# 验证"打断正在跑的 AI"是安全的（作废旧代际 → 回收搜索线程 → 释放锁 → 回英雄池）。
		# 判据用 `_chk_count`（各路径通用；`_st_done` 只在 --selftest 里累加，用它会让非自检路径永不触发）。
		if _test_back > 0 and _chk_count >= _test_back and not _test_back_fired:
			_test_back_fired = true
			_log("[取证·返回选人] 触发点=AI 正在后台搜索（已产出对拍块 %d）" % _chk_count)
			await _on_back_to_select()
			await _verify_back_to_select()
			return []
		# 主线程只轮询这一帧：面板/折叠/状态行照常响应，界面不会卡死
		await get_tree().process_frame
	_join_ai_thread()                 # 回收线程资源（结果已写入 holder）
	var t_end := Time.get_ticks_msec()
	_search_lock.lock()
	var plan: Array = _search_holder.plan
	_search_lock.unlock()
	_search_active = false
	_log("[检视器] [耗时] 本回合决策：快照+建 sim %dms / search %dms（后台线程）/ 合计 %dms（BEAM=%d，时间预算=%s）" % [
		t_snap1 - t_snap0, t_end - _search_start_ms, t_end - t_snap0, _beam_val(),
		"不限" if int(ai.time_budget_ms) <= 0 else "%dms" % int(ai.time_budget_ms)])
	return plan


## 线程入口：只调 AI 的纯数据 search()，结果加锁写进 holder。
## 锁与 holder 都由主线程显式传入（不在线程里读实例成员，避免跨线程碰场景对象）。
## 参数名故意不叫 lock：那会遮蔽 GDScript 内建函数名。
static func _search_worker(ai, sim, mtx: Mutex, holder: SearchHolder) -> void:
	var plan: Array = ai.search(sim, DataRegistry.Faction.ENEMY)
	mtx.lock()
	holder.plan = plan
	holder.done = true
	mtx.unlock()


## 线程 → 主线程的结果搬运箱（见 _search_async/_search_worker）
class SearchHolder:
	var plan: Array = []
	var done := false


## 拦下 Battle 里 HUD 的「返回选人」按钮：在检视器里它**不该**换场景跳主菜单，
## 而应当回到本场景自己的选人部署界面。
## 单机下原实现是 HUD._on_back_to_menu()（src/HUD.gd:1997-2008）→ change_scene_to_file(Menu.tscn)，
## 点一下会把整个检视器换掉，所以必须先断开它原本的连接再挂我们自己的。
## 断连方式：用 pressed.get_connections() 枚举，按 callable 名字识别 _on_back_to_menu——
## 比硬编码 Callable 稳（不依赖对象实例是否同一个）。
## 安全降级：找不到 HUD / 找不到按钮 / 断不开原连接时**不崩、也不硬改游戏节点**，只打警告说明
## "返回选人仍会离开检视器（跳主菜单）"，并把这个事实如实写进报告。
## 每次 _setup()（含重建）之后都要重新调用：HUD 与按钮都是新实例。
## 【自动循环实测】重建那一刻 HUD 的原连接**可能还没建好**（HUD 自己稍后才连 `_on_back_to_menu`），
## 于是"断不开原连接"→ 告警且**真的没拦住**（用户点一下就跑出检视器 → 自动循环也跟着断）。
## 所以改成**逐帧重试**，并把"已经是我们接的线"（重复挂接/同一 HUD 被钩两次）当成成功，不再误报：
##   · 断开原连接成功 或 发现已由检视器接管 → 成功；
##   · 否则等一帧再试，最多 30 帧；仍失败才告警（并明说"点它会离开检视器（跳主菜单）"）。
func _hook_hud_back_button() -> void:
	if _hook_hud_back_button_once():
		return
	_rehook_back_btn_retry()


## 重试协程：调用方不需要 await（挂接是"尽力而为"的副作用），所以这里自己跑完。
func _rehook_back_btn_retry() -> void:
	for i in 30:
		await get_tree().process_frame
		if _battle == null or not is_instance_valid(_battle):
			return
		if _hook_hud_back_button_once():
			_log("[检视器] 「返回选人」拦截成功（第 %d 帧重试拿到）" % (i + 1))
			return
	push_warning("[检视器] 「返回选人」30 帧内都没能拦截（HUD 未就绪/按钮或方法改名）→ 点它仍会离开检视器（跳主菜单）")
	_warn("「返回选人」30 帧内都没能拦截：该按钮仍会离开检视器")


## 单次尝试：true = 已接管（断掉了原连接，或本来就是我们接的线）。
func _hook_hud_back_button_once() -> bool:
	if _battle == null or not is_instance_valid(_battle):
		return false
	var hud: Node = _find_child_by_class(_battle, "HUD")
	if hud == null:
		return false          # HUD 还没建好：交给重试，不在这里刷告警
	var btn: Button = _find_button_by_text(hud, "返回选人")
	if btn == null:
		return false          # 按钮还没建好：同上
	var cut := 0
	for c in btn.pressed.get_connections():
		var cb = c.get("callable", null)
		if cb is Callable and String((cb as Callable).get_method()) == "_on_back_to_menu":
			btn.pressed.disconnect(cb as Callable)
			cut += 1
	var ours := btn.pressed.is_connected(_on_back_to_select)
	if cut == 0:
		return ours             # 已接管 = 成功；否则原连接还没建好 → 交给重试
	if not ours:
		btn.pressed.connect(_on_back_to_select)
	_log("[检视器] 已拦截「返回选人」（断开 %d 条原连接）：改为回到检视器自己的选人界面" % cut)
	return true


## 取证（`--sim-panel-clicks`）：**程序化点档位按钮**，证明"点按钮 → 档位真的变了"。
## 为什么必须单独验：`--selftest` 里手动那方的替补面板会被 `_auto_sub_on_timeout()` 强行推完，
## 这会**掩盖交互路径的真实问题**（用户遇到的正是交互路径：点「RL候选AI」后 AI 却不动）。
## 点法：直接 `Button.pressed.emit()`（等价于真点击触发的信号），再念一遍档位供对账。
func _sim_click_mode_buttons() -> void:
	if _mode_btns.size() == 0 or _emode_btns.size() == 0:
		_log("[取证·交互] 档位按钮不存在（我方 %d 个 / 敌方 %d 个）→ 无法取证" % [
			_mode_btns.size(), _emode_btns.size()])
		return
	var before := "我方=%s 敌方=%s" % [_ai_name(_mode), _ai_name(_emode)]
	# 我方 → RL候选AI（下标 1 = AI_FORK）；敌方 → 原版困难档（下标 2 = AI_ORIG）
	if _mode_btns.size() > AI_FORK:
		(_mode_btns[AI_FORK] as Button).pressed.emit()
	if _emode_btns.size() > AI_ORIG:
		(_emode_btns[AI_ORIG] as Button).pressed.emit()
	await get_tree().process_frame
	var after := "我方=%s 敌方=%s" % [_ai_name(_mode), _ai_name(_emode)]
	var ok := int(_mode) == AI_FORK and int(_emode) == AI_ORIG \
			and int(_mode_of_side(GameState.SIDE_PLAYER)) == AI_FORK \
			and int(_mode_of_side(_enemy_side())) == AI_ORIG
	_log("[取证·交互] 程序化点档位按钮：点前 %s → 点后 %s；_mode_of_side(我方)=%s _mode_of_side(敌方)=%s → VERDICT=%s" % [
		before, after, _ai_name(_mode_of_side(GameState.SIDE_PLAYER)),
		_ai_name(_mode_of_side(_enemy_side())), "PASS" if ok else "FAIL"])


## 拦下「重开」与结算浮层的「再战一局/再来一局」。
##
## 为什么必须拦（用户实机 bug）：游戏的「再来一局」是在**原场景里就地重开**
## （`HUD._on_restart(redraft)` → `battle.reset_match()`，不 reload 场景）→
## **`_ready()` 不会再跑** → 而我们的驱动协程 `_run()` 在 `match_over` 时就已经 return 了、
## 档位也只在 `_ready()` 里应用过一次 → 新一局**没有任何驱动**：AI 不部署、不出手、不接管替补，
## 一切都只能等游戏的超时兜底（用户："新的一局 AI 就不会操作了"）。
##
## 挂接方式与「返回选人」完全一样：枚举 `pressed.get_connections()` 断掉原回调 → 连我们自己的。
## 结算浮层是**对局结束时才动态创建**的（HUD.show_result），所以除了建局时挂一次，
## 还要在 `match_over` 期间周期性重挂（见 `_rehook_restart_buttons_if_needed`）。
func _hook_restart_buttons() -> void:
	if _battle == null or not is_instance_valid(_battle):
		return
	var hud: Node = _find_child_by_class(_battle, "HUD")
	if hud == null:
		return
	var n := 0
	# ① HUD 上常驻的「重开」
	var rb = hud.get("_restart_btn")
	if rb is Button:
		if _rewire_button(rb as Button, "_on_restart", Callable(self, "_on_restart_intercepted")) > 0:
			n += 1
	# ② 结算浮层里的「再战一局 / 再来一局」（用文案找，不依赖私有成员名）
	for txt in ["再战一局", "再来一局"]:
		var ab: Button = _find_button_by_text(hud, txt)
		if ab != null:
			if _rewire_button(ab, "_on_restart", Callable(self, "_on_restart_intercepted")) > 0:
				n += 1
	if n > 0:
		_log("[检视器] 已拦截「重开/再战一局」（%d 个按钮）：改为走检视器自己的重开路径" % n)


## 对局结束期间周期性重挂：结算浮层是动态建的，"再战一局"按钮出现得比建局晚。
## 幂等：`_rewire_button` 只在发现原回调时才算一次，重复调用不会叠加连接。
func _rehook_restart_buttons_if_needed() -> void:
	if _battle == null or not is_instance_valid(_battle):
		return
	if not GameState.match_over:
		return
	_hook_restart_buttons()


## 「重开 / 再战一局」的新行为：**走检视器自己的重开路径**（作废旧代际 → 回收线程 → 释放锁 →
## 重置实例状态 → 沿用本局卡组重建战场 → 重挂按钮 → 重新应用档位 → 重启驱动）。
## 为什么不信游戏的就地重开：那条路不会重新拉起我们的驱动协程，也不重挂牌档位（见 _hook_restart_buttons）。
func _on_restart_intercepted() -> void:
	if _restarting:
		_log("[检视器] 重开已在处理中：忽略重复点击（防两套重建并行）")
		return
	_log("[检视器] 「重开/再战一局」被拦截：代际 %d → %d，走检视器自己的重开路径" % [_run_gen, _run_gen + 1])
	_restart_keep_decks = true
	await _rebuild_sandbox()
	_restart_keep_decks = false


## 「返回选人」的新行为：拆掉战场 → 回到检视器的**英雄池选人界面**（不换场景、不跳 Menu）。
## 上次勾选会被保留（_picker_sel_p/_picker_sel_e），方便微调。
## _rebuild_sandbox 是协程（内部 await 等旧 Battle 离开场景树），**必须 await 调用**。
## 机读证据：一条记录"已回到英雄池界面 + 勾选是否保留 + 锁已释放"（进运行时文件）。
func _on_back_to_select() -> void:
	_log("[检视器] 返回选人：开始打断（作废旧驱动循环 → 回收搜索线程 → 释放观战锁 → 拆战场）")
	_picker_mode = true
	await _rebuild_sandbox()
	# 断言式记录：回到英雄池 + 勾选保留 + 锁已释放（缺一条就写告警，别让"看起来回去了"蒙混过关）
	var picker_ok: bool = _picker != null and is_instance_valid(_picker) and _picker.visible
	var sel_ok: bool = picker_ok and _picker._sel_p == _picker_sel_p and _picker._sel_e == _picker_sel_e
	var lock_ok: bool = not _watch_locked and _watch_side_locked == -1
	var stale: Node = _find_child_by_class(self, "Battle")
	var thread_ok: bool = _ai_thread == null or not _ai_thread.is_started()
	_log("[检视器] 返回选人完成：回到英雄池=%s 勾选保留=%s（我方 %s / 敌方 %s）锁已释放=%s 旧战场残留=%s 残留搜索线程=%s" % [
		str(picker_ok), str(sel_ok), str(_picker_sel_p), str(_picker_sel_e), str(lock_ok),
		"无" if stale == null else "有", "无" if thread_ok else "有"])
	if not picker_ok or not sel_ok or not lock_ok or stale != null or not thread_ok:
		_warn("返回选人后状态不干净：picker=%s sel=%s lock=%s stale=%s thread=%s" % [
			str(picker_ok), str(sel_ok), str(lock_ok), str(stale != null), str(not thread_ok)])


## 按类名找子节点（HUD 是 Battle 的运行时子节点，没有固定节点名，用类名最稳）
func _find_child_by_class(root: Node, cls: String) -> Node:
	for c in root.get_children():
		if c.is_class(cls) or (c.get_script() != null and String(c.get_script().get_global_name()) == cls):
			return c
		var deep := _find_child_by_class(c, cls)
		if deep != null:
			return deep
	return null


## 递归找文案匹配的 Button（不依赖 src/HUD.gd 的私有成员名 _back_btn，避免对方改名后我们失联）
func _find_button_by_text(root: Node, text: String) -> Button:
	for c in root.get_children():
		if c is Button and String((c as Button).text).strip_edges() == text:
			return c as Button
		var deep := _find_button_by_text(c, text)
		if deep != null:
			return deep
	return null


## 演示/取证（`--demo-counter`）：**人为造一次近战攻击**，专门用来产出"含反击的对拍块"。
## 为什么需要它：实测（多组种子 × `--pai 1` × 20 招）**AI 对局里撞不到反击**——反击触发条件是
## "被打者存活 + can_attack + effective_atk>0 + 本回合未反击过 + 距离≤1"（src/Battle.gd:3363-3375），
## 而 AI 优先收残血/打必杀，剩下的近战互殴又常被打死。靠随机跑很难出现，所以给一个显式取证入口。
##
## 做法只两步：① 把攻击方挪到紧贴被攻击方（空格才挪）；② 直接调 Battle 的攻击入口 `_do_attack`
## 走**完整真实链路**（_apply_attack → can_counter → _play_counter → take_damage）。
## 之后本回合不再跑常规计划，照常 `_end_side` 交回，保证对拍格式与非演示路径完全一致。
func _run_demo_counter(side: int) -> void:
	if _battle == null or not is_instance_valid(_battle):
		return
	var fn: int = _battle.side_faction(side)
	var mine: Unit = null
	var foe: Unit = null
	for u in _battle.units:
		if u == null or not is_instance_valid(u) or not u.alive:
			continue
		if u.faction != fn and mine == null:
			mine = u            # 攻击方 = 非当前行动方（让"当前行动方"挨打，好触发它的反击）
		elif u.faction == fn and foe == null:
			foe = u
	if mine == null or foe == null or mine == foe:
		_log("[演示] 凑不齐攻守双方（mine=%s foe=%s），跳过" % [
			"?" if mine == null else mine.hero_id, "?" if foe == null else foe.hero_id])
		return
	if _battle.grid.distance(mine.cell, foe.cell) > 1:
		for c in _battle.grid.neighbors(foe.cell):
			if not _battle.occupancy.has(c) and not _battle.obstacles.has(c) \
					and not _battle.graves.has(c):
				_battle.occupancy.erase(mine.cell)
				mine.cell = c
				_battle.occupancy[c] = mine
				mine.position = _battle.board_view.cell_world_center(c)
				break
	_log("[演示] 反击取证：%s(%s) 攻击 %s(%s)，距离 %d，守方有效攻 %d" % [
		mine.display_name, mine.hero_id, foe.display_name, foe.hero_id,
		_battle.grid.distance(mine.cell, foe.cell), foe.effective_atk()])
	# ★ 关键：**走 _step() 同一条报告链路**，而不是直接调 _do_attack ——
	# 否则这次攻击不会生成对拍块（_step 才是"取前后快照 + 预测 + 执行 + 打印"的地方）。
	# 把本步的基准设成"攻击方"（它在 _desc_keys 里的下标），动作字典写成一次攻击。
	_desc_keys = _battle.units.duplicate()
	var ai_idx: int = _desc_keys.find(mine)
	if ai_idx < 0:
		_log("[演示] 攻击方不在单位列表里，跳过")
		return
	if _ai == null:
		_ai = _make_ai(AI_FORK)          # 预测侧需要一个 sim 构造器
	_cur_idx = ai_idx
	_new_hero = true
	await _step({ "atk": _desc_keys.find(foe) })


## ===================== 「自动循环」：一直自动打 =====================
## 用户口径：面板里点一下就不管了 —— 每局**双方各随机 5 人**（10 人互不重复），一局打完自动换一批、
## 一直跑；再点一下按钮即停（当前这局打完后不再开新局）。
## 为什么循环里没有第二份"选人/建局"逻辑：两条都复用现成入口 ——
##   · 回英雄池选人界面 = `_on_back_to_select()`（拆战场 / 回收搜索线程 / 释放观战锁，并断言状态干净）；
##   · 新随机 5v5 + 开打 = `_randomize_picks(true)`（与「随机双方各5人」按钮、`--randpicks` 同一函数）。
## 所以"手动点按钮"与"自动循环"走的永远是同一条路（同款日志/断言）。
func _on_auto_toggle() -> void:
	_auto_loop = not _auto_loop
	if _auto_loop:
		_auto_loop_n = 0
		_refresh_auto_btn()
		_say_console("[自动循环] 开：每局双方各随机 5 人，打完自动换一批继续")
		_log("[自动循环] 开（当前状态：%s；上限=%s）" % [
			"对局进行中" if (_battle_alive() and not GameState.match_over) else "未在对局中",
			"不限局数" if _auto_rounds <= 0 else ("跑完 %d 局停" % _auto_rounds)])
		_auto_loop_run()      # 协程：不 await（按钮回调不能阻塞）
	else:
		_refresh_auto_btn()
		_say_console("[自动循环] 关：本局打完后不再自动开新局")
		_log("[自动循环] 关：本次自动循环共跑完 %d 局" % _auto_loop_n)


## 按钮文案：把"开关状态 + 已换几局"写在按钮上（不另占一行，面板已经很挤）。
func _refresh_auto_btn() -> void:
	if _auto_btn == null or not is_instance_valid(_auto_btn):
		return
	if _auto_loop:
		_auto_btn.text = "自动循环：开（已换 %d 局）— 点此停" % _auto_loop_n
	else:
		_auto_btn.text = "自动循环：每局随机5人（点此开始）"


## 循环本体：① 等本局结束 → ② 回选人界面 → ③ 换一批随机 5v5 并开打 → 回到 ①。
## 每个等待点都检查 `_auto_loop`，所以"点停"能立刻生效（最迟在下一帧）。
func _auto_loop_run() -> void:
	while _auto_loop and get_tree() != null:
		# ① 等当前这局打完；若此刻根本没在对局中（刚点开循环/刚从选人界面来）→ 直接去开一局
		if _battle_alive() and not GameState.match_over:
			await get_tree().process_frame
			continue
		if GameState.match_over:
			_auto_loop_n += 1
			_refresh_auto_btn()
			_log("[自动循环] 第 %d 局结束（本局对拍块累计 %d，代际=%d）→ 回选人界面换一批英雄" % [
				_auto_loop_n, _chk_count, _run_gen])
			_say_console("[自动循环] 第 %d 局结束 → 换一批随机 5v5 再开" % _auto_loop_n)
			if _auto_rounds > 0 and _auto_loop_n >= _auto_rounds:
				_auto_loop = false
				_refresh_auto_btn()
				_log("[自动循环] 已达上限 %d 局 → 停止（本次共跑完 %d 局，对拍块累计 %d）" % [
					_auto_rounds, _auto_loop_n, _chk_count])
				_say_console("[自动循环] 跑完 %d 局，停止" % _auto_loop_n)
				if _auto_cli:
					get_tree().quit(0)
				return
			# 留 1.5s：让结算浮层/日志落定，也给用户"点停"的机会
			var t_wait := Time.get_ticks_msec()
			while _auto_loop and get_tree() != null and Time.get_ticks_msec() - t_wait < 1500:
				await get_tree().process_frame
			if not _auto_loop or get_tree() == null:
				return
			await _on_back_to_select()      # 拆战场、回英雄池（勾选保留）
		if not _auto_loop or get_tree() == null:
			return
		# ② 换一批随机 5v5 并开打（与「随机双方各5人」按钮同一函数；内含"选人界面不存在"的保护）
		if _picker == null or not is_instance_valid(_picker):
			_warn("[自动循环] 选人界面不可用 → 停循环（避免空转刷日志）")
			_auto_loop = false
			_refresh_auto_btn()
			_say_console("[自动循环] 异常停止：选人界面不可用")
			return
		_log("[自动循环] 第 %d 局开局：随机双方各 5 人" % (_auto_loop_n + 1))
		_randomize_picks(true)
		# ③ 等新一局真的起来（战场建好且 match_over 复位），否则下一轮会立刻又判"已结束"→ 空转
		var t_up := Time.get_ticks_msec()
		while _auto_loop and get_tree() != null and (not _battle_alive() or GameState.match_over):
			if Time.get_ticks_msec() - t_up > 60000:
				_warn("[自动循环] 新一局 60s 内没起来 → 停循环")
				_auto_loop = false
				_refresh_auto_btn()
				_say_console("[自动循环] 异常停止：新一局未起来")
				return
			await get_tree().process_frame


## 随机双方各 5 人（**界面按钮与 `--randpicks` 共用这一个函数**）：
##   · 从 `DataRegistry.heroes` 全池（49）随机抽 **10 个互不重复**的英雄 → 前 5 我方、后 5 敌方
##     （两边不会出现同名英雄，省掉镜像边界情况）；
##   · 写进 `_picker._sel_p / _sel_e` —— **与手动勾选完全同一条路径**，所以随后的
##     `[picks] 阵容已生效`、`[选人核对（建局前/后）]` 两条断言照旧成立；
##   · 再点一次换一套（`shuffle()` 每次重洗）；
##   · `start_now=true`（= `--randpicks` 无头入口）时立刻走 `_apply_picks_and_start()` 开打。
func _randomize_picks(start_now: bool) -> void:
	if _picker == null or not is_instance_valid(_picker):
		_log("[randpicks] 选人界面不存在 → 无法随机（按钮只该在选人界面可用）")
		return
	var pool: Array = DataRegistry.heroes.keys()
	pool.sort()                 # 先排序再洗牌：与字典遍历顺序解耦（便于事后复现同一批）
	pool.shuffle()
	var limit := int(Battle.DEFAULT_DECK_SIZE)      # 5 = 3 首发 + 2 替补（正常规则）
	var want := limit * 2
	var picked: Array[String] = []
	var seen := {}
	for id in pool:
		var sid := String(id)
		if seen.has(sid):
			continue
		seen[sid] = true
		picked.append(sid)
		if picked.size() >= want:
			break
	if picked.size() < want:
		_log("[randpicks] 英雄池不足：需要 %d 个，只抽到 %d 个（池=%d）" % [want, picked.size(), pool.size()])
	var p: Array[String] = []
	var e: Array[String] = []
	for i in picked.size():
		if i < limit:
			p.append(picked[i])
		else:
			e.append(picked[i])
	_picker._sel_p = p.duplicate()
	_picker._sel_e = e.duplicate()
	# ★ 复用**手动点选那条刷新路径**（`QuickTest._toggle()` 调的就是它）：
	#   它一次刷全 —— 当前编辑方的英雄卡高亮（`_btns[id].set_selected(_cur().has(id))`）、
	#   `我方 N/5 敌方 M/5` 计数标签、`当前编辑：我方/敌方`、`开始对局` 的 disabled 态、状态行。
	#   用户实机报的"点了随机没效果、再点一下英雄池才出现选中"就是**只改了状态、没走这条路**。
	#   刻意**不自己零散 set 各控件**：这样手动/随机两条路的显示永远一致。
	#   （注意 `_refresh()` 只高亮"当前编辑方"的卡——与手动点选完全同款行为；切到另一方即见。）
	if _picker.has_method("_refresh"):
		_picker._refresh()
		_log("[randpicks] 已应用并刷新：我方=%s / 敌方=%s；刷新入口=QuickTest._refresh()" % [str(p), str(e)])
	else:
		_log("[randpicks] 已应用但**未刷新**（QuickTest 无 _refresh，可能改名）：我方=%s / 敌方=%s" % [str(p), str(e)])
		_warn("随机选人后无法刷新界面：QuickTest._refresh() 不存在（选人卡高亮要等下一次交互）")
	# 同步写进命令行口径的两个字段：`_apply_picks_and_start()` 读的就是它们（复用同一条路径）
	_picks_p = p.duplicate()
	_picks_e = e.duplicate()
	var uniq := {}
	for id2 in picked:
		uniq[id2] = true
	_log("[randpicks] 本次随机（池=%d 抽=%d 去重后=%d）：我方=%s / 敌方=%s；start_now=%s" % [
		pool.size(), picked.size(), uniq.size(), str(p), str(e), str(start_now)])
	_say_console("[picks] 随机双方各 %d 人：我方=%s / 敌方=%s（去重=%s）" % [
		limit, str(p), str(e), str(uniq.size() == picked.size())])
	if start_now:
		_apply_picks_and_start()


## `--picks "我方" "敌方"`：把命令行给的名单当成"用户在英雄池里勾好的人"，然后走**英雄池路径本身**
## （`_on_quicktest_start`，与真人点「开始对局」完全同一条路）→ 之后由 `_run()` 正常驱动。
## 这是"49 英雄轮换扫描"的入口：没有它，扫描阵容永远只有固定那 6 个英雄。
func _apply_picks_and_start() -> void:
	if _picker == null or not is_instance_valid(_picker):
		_log("[picks] 选人界面不存在 → 无法应用 --picks")
		return
	_picker._sel_p = _picks_p.duplicate() if _picks_p.size() > 0 else _default_picks(0)
	_picker._sel_e = _picks_e.duplicate() if _picks_e.size() > 0 else _default_picks(1)
	_log("[picks] 应用指定阵容：我方=%s（%d 人）/ 敌方=%s（%d 人）→ 走英雄池路径开始对局" % [
		str(_picker._sel_p), _picker._sel_p.size(), str(_picker._sel_e), _picker._sel_e.size()])
	_on_quicktest_start()
	# 控制台一行（关键事件）：让扫描的人一眼确认"跑的真是我指定的那两组人"
	_say_console("[picks] 阵容已生效：我方=%s / 敌方=%s（规则见 [规则] 行）" % [
		str(GameState.player_deck), str(GameState.enemy_deck)])


## 取证默认阵容（没给 --picks 时用）：0=我方，1=敌方。
## 用显式 append 构造 Array[String]，避免"混合类型字面量 + 类型推断"那类坑（见 _terrain_changes 注释）。
func _default_picks(which: int) -> Array[String]:
	var out: Array[String] = []
	var src: Array = ["hero_01", "hero_02", "hero_03"] if which == 0 else ["hero_04", "hero_05", "hero_06"]
	for id in src:
		out.append(String(id))
	return out


## 取证（`--test-picks`）：脚本化地模拟"用户在英雄池勾选 → 点开始对局"，然后核对
## GameState 与场上单位是否真的是勾选的那几个。用来证明"选了人却被 _setup() 覆盖"已被修掉。
## 全走 UI 按钮的原连接路径（调用 _on_quicktest_start，即被 _rewire_button 接上的那个回调）。
## 阵容：`--picks "我方" "敌方"` 给了就用给的（3~5 人，正常规则上限），否则用固定的那两组 3 人。
func _test_picks_run() -> void:
	if _picker == null or not is_instance_valid(_picker):
		_log("[取证] 选人界面不存在，无法测试")
		get_tree().quit(1)
		return
	# 挑两组明确不同的英雄，便于肉眼/日志对照；--picks 给了就用给的
	var want_p: Array[String] = _picks_p.duplicate() if _picks_p.size() > 0 else _default_picks(0)
	var want_e: Array[String] = _picks_e.duplicate() if _picks_e.size() > 0 else _default_picks(1)
	# ★ 先试一次"超编"（仅当调用方要求）：勾选数 > 上限必须被**拒绝**且给出提示，不静默截断。
	if _picks_p.size() > int(Battle.DEFAULT_DECK_SIZE):
		_log("[取证] 超编拒绝测试：我方勾选 %d 人 > 上限 %d" % [
			_picks_p.size(), int(Battle.DEFAULT_DECK_SIZE)])
		_picker._sel_p = want_p.duplicate()
		_picker._sel_e = want_e.duplicate()
		_on_quicktest_start()            # 应被拒绝：不建局、给提示
		var rejected: bool = _battle == null
		_log("[取证] 超编拒绝：%s（Battle 实例=%s）" % [
			"通过 ✔（未建局，已给提示）" if rejected else "不通过 ✘（居然建局了）",
			"null" if _battle == null else "已建"])
		if _test_play:
			get_tree().quit(0)
			return
		# 截到上限继续（显式重建，不用 slice：避免类型化数组的返回类型不确定）
		var trimmed: Array[String] = []
		for i in mini(want_p.size(), int(Battle.DEFAULT_DECK_SIZE)):
			trimmed.append(want_p[i])
		want_p = trimmed
		_log("[取证] 超编拒绝已验 → 截到上限 %d 人继续：%s" % [want_p.size(), str(want_p)])
	_picker._sel_p = want_p.duplicate()
	_picker._sel_e = want_e.duplicate()
	_log("[取证] 模拟勾选：我方=%s 敌方=%s → 点「开始对局」" % [str(want_p), str(want_e)])
	_on_quicktest_start()
	# 核对（新流程）：卡组必须等于勾选；部署则由 Battle 自己走，部署完毕后 _assert_deploy_done()
	# 会断言"双方各 3 人上阵且都来自卡组"。这里先确认"没被 _setup() 覆盖"。
	var ok := true
	if GameState.player_deck != want_p:
		ok = false
		_warn("player_deck 被覆盖：勾选 %s / 实际 %s" % [str(want_p), str(GameState.player_deck)])
	if GameState.enemy_deck != want_e:
		ok = false
		_warn("enemy_deck 被覆盖：勾选 %s / 实际 %s" % [str(want_e), str(GameState.enemy_deck)])
	# 部署界面必须真的被打开（state 应为 DEPLOY，或已轮到某一边落位）
	var st := int(_battle.state) if _battle != null else -1
	var deploy_opened: bool = st == int(Battle.State.DEPLOY) or st == int(Battle.State.PLACE_DEPLOY)
	if not deploy_opened:
		ok = false
		_warn("没有进入 Battle 的部署流程：state=%d" % st)
	_log("[取证] 结论：%s\n  勾选我方卡组 %s / GameState %s\n  勾选敌方卡组 %s / GameState %s\n  部署已打开=%s（state=%d）" % [
		"卡组未被覆盖 ✔" if ok else "卡组异常 ✘",
		str(want_p), str(GameState.player_deck), str(want_e), str(GameState.enemy_deck),
		str(deploy_opened), st])
	# 让部署继续跑（AI 边由 _deployment_tick 驱动），跑一会儿后核对部署断言，再退出
	await _wait_until(func(): return _deploy_finished(), READY_WALL_MS, 4000)
	_assert_deploy_done()
	var on_board: Array = []
	if _battle != null:
		for u3 in _battle.units:
			if u3 != null and is_instance_valid(u3):
				on_board.append("%s@%s" % [(u3 as Unit).hero_id, str((u3 as Unit).cell)])
	_log("[取证] 部署后场上单位 %s" % str(on_board))
	# 取证运行允许控制台留这一行（与 --panecheck 的口径一致：一行结论，不污染对拍块）
	print("[test-picks] %s" % ("PASS" if ok else "FAIL"))
	if _test_play:
		await _test_play_until_end(ok)
		return
	if _test_back > 0:
		# ★ 取证（`--test-back N`）：**不在这里退出**——要让它继续打到第 N 招，
		# 才能在"AI 正在后台搜索"时触发「返回选人」并写出 `[取证·返回选人] VERDICT=…`。
		# 踩过：原来这里无条件 `quit()`，对局还没打到第 5 招就退出 → 触发点永远没机会执行，
		# `--test-back` 跑出来只有 `[test-picks] PASS`、没有 VERDICT（那次验收因此报红）。
		_log("[取证·返回选人] 跳过 test-picks 的收尾 quit：继续打到 %d 招，在搜索中触发返回选人" % _test_back)
		return
	get_tree().quit(0 if ok else 1)


## 取证（`--test-play`）：把这一局驱动到**对局结束**，然后打机读断言并退出。
## 用来验"正常对战规则"：累计阵亡 3 名即判负、每队卡组 ≤5、替补最多补 2 个。
## 上限可调：`--play-wall <秒>`（默认 600s）；到点没结束就如实报"未结束"。
func _test_play_until_end(_ok_at_deploy: bool) -> void:
	var wall := _play_wall
	var t0 := Time.get_ticks_msec()
	_log("[取证·正常规则] 开始驱动到对局结束（上限 %ds）" % wall)
	while Time.get_ticks_msec() - t0 < wall * 1000:
		if get_tree() == null:
			return
		if GameState.match_over:
			break
		await get_tree().process_frame
	# `_report_test_play()` 体内没有 await（不是协程）→ 这里**不能**写 `await`，
	# 否则 Godot 报 `REDUNDANT_AWAIT` 警告（"await keyword is unnecessary…"）。去掉语义完全一样。
	_report_test_play()
	if _test_restart:
		await _test_restart_after_match()
		return
	get_tree().quit(0)


## 取证（`--test-restart`）：一局结束后触发「再来一局」，验证**新一局 AI 继续动**。
## 这正是用户报的 bug：游戏的「再来一局」就地重开、不再跑 `_ready()`，
## 于是驱动协程与档位都没了 → 新一局 AI 不动。这里断言"新一局确实在动"。
func _test_restart_after_match() -> void:
	if get_tree() == null:
		return
	var gen_before := _run_gen
	var chk_before := _chk_count
	_log("[取证·再来一局] 旧局结束：代际=%d 已产出对拍块=%d → 触发「重开/再战一局」" % [gen_before, chk_before])
	# 走与按钮完全相同的入口（按钮连的就是这个回调）
	await _on_restart_intercepted()
	# 新一局要能自己推进：等到"部署完成 + 产出新对拍块"，或到时限
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 240000:
		if get_tree() == null:
			return
		if _deployed and _chk_count > chk_before:
			break
		await get_tree().process_frame
	var gen_after := _run_gen
	var new_chk := _chk_count - chk_before
	var n_battle := _count_battles()
	var ok := gen_after > gen_before and _deployed and new_chk > 0 and n_battle == 1 \
			and (_ai_thread == null or not _ai_thread.is_started())
	_log("[取证·再来一局] VERDICT=%s" % ("PASS" if ok else "FAIL"))
	_log("[取证·再来一局] 代际 %d → %d；新一局部署完成=%s；新一局产出对拍块=%d；档位 我方=%s 敌方=%s；残留搜索线程=%s" % [
		gen_before, gen_after, str(_deployed), new_chk, _ai_name(_mode), _ai_name(_emode),
		"无" if (_ai_thread == null or not _ai_thread.is_started()) else "有"])
	_log("[取证·再来一局] 场上 Battle 实例数=%d（必须恰好 1，防两套战场/两套驱动叠加）；卡组沿用 我方 %d 人 / 敌方 %d 人" % [
		n_battle, GameState.player_deck.size(), GameState.enemy_deck.size()])
	print("[test-restart] %s" % ("PASS" if ok else "FAIL"))
	get_tree().quit(0 if ok else 1)


## 取证（`--test-back N`）：在 AI 正在搜索时点「返回选人」后，断言状态干净并退出。
## 判据：回到英雄池界面 + 勾选保留 + 观战锁已释放 + 无残留 Battle + 无残留搜索线程。
func _verify_back_to_select() -> void:
	if get_tree() == null:
		return
	for i in 6:
		await get_tree().process_frame
	var picker_ok: bool = _picker != null and is_instance_valid(_picker) and _picker.visible
	var sel_p: Array = _picker._sel_p if picker_ok else []
	var lock_ok: bool = not _watch_locked and _watch_side_locked == -1
	var battles := _count_battles()
	var thread_ok: bool = _ai_thread == null or not _ai_thread.is_started()
	var keep_p: bool = sel_p == _picker_sel_p
	var ok := picker_ok and lock_ok and battles == 0 and thread_ok and keep_p
	_log("[取证·返回选人] VERDICT=%s" % ("PASS" if ok else "FAIL"))
	_log("[取证·返回选人] 回到英雄池=%s；勾选保留=%s（我方 %s / 敌方 %s）；观战锁已释放=%s；场上 Battle 实例数=%d；残留搜索线程=%s；代际=%d" % [
		str(picker_ok), str(keep_p), str(sel_p), str(_picker_sel_e), str(lock_ok),
		battles, "有" if not thread_ok else "无", _run_gen])
	print("[test-back] %s" % ("PASS" if ok else "FAIL"))
	get_tree().quit(0 if ok else 1)


## 场上挂着几个 Battle 实例（"再来一局"防叠加的断言依据）。
func _count_battles() -> int:
	var n := 0
	for c in get_children():
		if c.get_script() != null and String(c.get_script().get_global_name()) == "Battle":
			n += 1
	return n


## 正常规则的机读断言（进运行时文件）：卡组 ≤5 / no_death_limit==false / 3 阵亡 → 对局结束 / 替补数。
func _report_test_play() -> void:
	var limit := int(Battle.DEFAULT_DECK_SIZE)
	var no_limit := bool(GameState.no_death_limit)
	var deck_p := GameState.player_deck.size()
	var deck_e := GameState.enemy_deck.size()
	var over := bool(GameState.match_over)
	var alive: bool = _battle != null and is_instance_valid(_battle)
	var my_dead := int(_battle._my_dead()) if alive else -1
	var opp_dead := int(_battle._opp_dead()) if alive else -1
	var ros_p := _battle.player_roster.size() if alive else -1
	var ros_e := _battle.enemy_roster.size() if alive else -1
	# 替补补位数 = 卡组人数 - 首发 3 - 替补席剩余
	var placed_p := deck_p - Battle.DEPLOY_COUNT_BATTLE - ros_p if (alive and ros_p >= 0) else -1
	var placed_e := deck_e - Battle.DEPLOY_COUNT_BATTLE - ros_e if (alive and ros_e >= 0) else -1
	var a1 := not no_limit
	var a2 := deck_p <= limit and deck_e <= limit
	var a3 := over and (my_dead >= int(Battle.LOSS_DEATH_COUNT) or opp_dead >= int(Battle.LOSS_DEATH_COUNT))
	var a4 := (placed_p <= limit - Battle.DEPLOY_COUNT_BATTLE) and (placed_e <= limit - Battle.DEPLOY_COUNT_BATTLE)
	var ok := a1 and a2 and a3 and a4
	_log("[取证·正常规则] VERDICT=%s" % ("PASS" if ok else "FAIL"))
	_log("[取证·正常规则] ① 判负规则：no_death_limit=%s（应 false）%s" % [str(no_limit), "OK" if a1 else "✘"])
	_log("[取证·正常规则] ② 卡组上限 ≤%d：我方 %d 人 / 敌方 %d 人 %s" % [limit, deck_p, deck_e, "OK" if a2 else "✘"])
	_log("[取证·正常规则] ③ 3 阵亡判负：match_over=%s 我方阵亡 %d / 敌方阵亡 %d（阈值 %d）%s" % [
		str(over), my_dead, opp_dead, int(Battle.LOSS_DEATH_COUNT), "OK" if a3 else "✘"])
	_log("[取证·正常规则] ④ 替补补位数 ≤%d：我方补 %d 个（替补席剩 %d）/ 敌方补 %d 个（剩 %d）%s" % [
		limit - Battle.DEPLOY_COUNT_BATTLE, placed_p, ros_p, placed_e, ros_e, "OK" if a4 else "✘"])
	_log("[取证·正常规则] 本局获胜方 side=%d（-1=平局）；累计触发的替补落位数=%d" % [
		_last_winner, _sub_placed])


## 重算触发差异的"判定层已知噪声类"前缀：命中这些**不触发重算**（只登记一行）。
##
## 为什么要有这道保险（用户/上层扫描发现的）：判定层自己可能产出**假 DIFF**
## （最典型的就是"sim 字段没被维护 → 读成 null → 恒判预测否"这一族，如曾经的 `状态[麻]`）。
## 假 DIFF 会白触发一次重算（多算一次搜索、还能打满每回合 3 次上限）。
## 注意：**这只影响"要不要重算"，绝不影响判定**——判定照旧如实报 DIFF，一行都不放宽。
const REPLAN_NOISE_PREFIXES := ["状态[麻]", "状态[棘]"]
## 刚打完那一招的字段级差异原文（供重算归因）
var _last_diffs: Array = []


## 这些差异是否**全部**属于判定层已知噪声类（是 → 不重算）。
func _replan_noise_only(diffs: Array) -> bool:
	if diffs.size() == 0:
		return false
	for d in diffs:
		var s := String(d)
		var hit := false
		for p in REPLAN_NOISE_PREFIXES:
			if s.contains(String(p)):
				hit = true
				break
		if not hit:
			return false
	return true


## ================= 等"世界落定"（修"取实际取得太早"） =================
#
# 根因（用户那一招，代码证据）：
#   · `heroes/hero_40_红帽.gd:6-19`：红帽阵亡时对**相邻所有单位（含己方）**造成 13 伤害；
#   · `src/Unit.gd:634-642`：`die()` **先播 0.3s 淡出**，**之后**才 `died.emit(self)`；
#   · 而写墓碑（`Battle._on_unit_died`）与英雄 `on_died`（红帽自爆）都在这个信号**之后**；
#   · 模拟侧 `RL/ai/AI_Battle.gd:1687/1698-1706` 是**同步**结算（死亡→墓碑→红帽自爆）。
# 于是检视器原来在动作窗口末尾**立刻**采样时：模拟已经算出"红帽死 → 自爆带走烛火/共鸣者"，
# 真实侧红帽还没淡出完、自爆还没派发 → 一大片"预测死/实际活 + 墓碑预测有/实际无"的假 DIFF，
# 并白触发一次 `[重算]`。**修法不是放宽判定，而是"等世界落定再采样"。**
const SETTLE_STABLE_FRAMES := 5    # 连续多少帧满足"已落定"才算落定
const SETTLE_WALL_MS := 600        # 上限（约两倍淡出时长 0.3s），到点照常采样并如实记录

## 世界是否"已落定"：
## ① **`_battle.units` 里再没有任何 `hp<=0` 的单位**（不论 `alive`）——
##    ★ 这条是"用户随便开一局一堆 DIFF"的主因修正，依据真实时序（`src/Unit.gd:634-642`）：
##      `die()` 里 `alive = false` 是**掉血那一刻立刻**发生的，而**淡出 0.3s 之后**才 `died.emit(self)`；
##      红帽自爆（`heroes/hero_40_红帽.gd`）、写墓碑、单位出列（`Battle._on_unit_died`，`src/Battle.gd:4280/4302`）
##      全都挂在这个信号**之后**。所以旧判据"没有 `hp<=0` **且** `alive==true` 的单位"在死亡发生瞬间就成立
##      → 落定**根本没等那 0.3 秒** → 采样早于死亡连锁 → 模拟（同步结算）看起来"抢跑"：
##      假墓碑、模拟多杀人、血量差正好等于阵亡技的量（用户 seed 7/11/23 各 1 条，全是同一条）。
##      改成"只要还有 `hp<=0` 的单位就没落定"= 一直等到它真的从 `units` 里消失（`units.erase` 在 `_on_unit_died` 里）。
## ② 不在交互状态（SUBSTITUTING / PLACE_SUB / PLACE_BOMB / PLACE_DEPLOY）。
func _world_settled() -> bool:
	if _battle == null or not is_instance_valid(_battle):
		return true
	for u in _battle.units:
		if u == null or not is_instance_valid(u) or not (u is Unit):
			continue
		var uu: Unit = u
		if uu.hp <= 0:
			return false          # 有单位血已归 0（淡出/派发 died/立碑/出列尚未走完）→ 还没落定
	var st := int(_battle.state)
	# ⚠️ 只看**交互状态**，**不看 ANIMATING**：检视器驱动时 `state` 常常整段停在 ANIMATING
	#    （harness 自己在出招前/交回合前设为 ANIMATING，动作结束后不会自动复原），
	#    把它当"还在播动画"会让这里永远判"未落定" → 每次都吃满 600ms 上限
	#    （实测 27/29、42/51 条都是"上限到点"）。真正的落定语义由上面那条
	#    "没有 hp<=0 的单位" + 墓碑/单位数连续若干帧不变承担。
	if st == int(Battle.State.SUBSTITUTING) || st == int(Battle.State.PLACE_SUB) \
			or st == int(Battle.State.PLACE_BOMB) || st == int(Battle.State.PLACE_DEPLOY):
		return false
	return true


## 等落定：**事件驱动优先**（每帧查 `_world_settled` + 墓碑数/单位数连续 N 帧不变），
## 上限 `SETTLE_WALL_MS` 兜底；**不用固定 sleep**。到点照常采样，但如实写一行 `[落定]`。
func _await_settled(tag: String) -> int:
	var t0 := Time.get_ticks_msec()
	var stable := 0
	var last_grave := -1
	var last_units := -1
	# 注：循环里每条出口都 return；末尾再兜一个 return（GDScript 的"所有路径都要有返回值"
	# 静态检查不认 `while true` 里的 return，不加这句会报 Parse Error: Not all code paths return a value，踩过）。
	while true:
		var now := Time.get_ticks_msec()
		var g := _battle.graves.size() if _battle != null and is_instance_valid(_battle) else -1
		var n := _battle.units.size() if _battle != null and is_instance_valid(_battle) else -1
		if _world_settled() and g == last_grave and n == last_units:
			stable += 1
		else:
			stable = 0
		last_grave = g
		last_units = n
		if stable >= SETTLE_STABLE_FRAMES:
			_log("[落定] 用时=%dms（自然：连续 %d 帧无变化，墓碑=%d 单位=%d）%s" % [
				now - t0, SETTLE_STABLE_FRAMES, g, n, tag])
			return now - t0
		if now - t0 > SETTLE_WALL_MS:
			_log("[落定] 用时=%dms（**上限到点**：可能仍有未落定的结算，本招快照按现状取）%s" % [
				now - t0, tag])
			return now - t0
		await get_tree().process_frame
	return Time.get_ticks_msec() - t0      # 静态检查兜底（正常永不走到）


## 该 AI 模块的 build_state 是否收第 8 个参数 active_fn（只有 RL 候选 fork 有，原版副本只有 7 个）。
func _ai_supports_active_fn(ai) -> bool:
	if ai == null:
		return false
	for m in ai.get_method_list():
		if String(m.get("name", "")) == "build_state" and int(m.get("args", []).size()) >= 8:
			return true
	return false


## 该 AI 模块的 build_state 是否收第 9 个参数 rosters（只有 RL 候选 fork 有；原版副本没有）。
## 传了它，模拟才能预测"本招击杀 → 该方替补登场"（真实 src/Battle.gd:4338/4388）。
func _ai_supports_rosters(ai) -> bool:
	if ai == null:
		return false
	for m in ai.get_method_list():
		if String(m.get("name", "")) == "build_state" and int(m.get("args", []).size()) >= 9:
			return true
	return false


## 该 AI 模块的 build_state 是否收第 10 个参数 auto_sub（只有 RL 候选 fork 有；原版副本没有）。
## 传了它，模拟才会**按阵营**预测替补登场；不传 = 与加这一参之前逐位相同（谁都不预测）。
func _ai_supports_auto_sub(ai) -> bool:
	if ai == null:
		return false
	for m in ai.get_method_list():
		if String(m.get("name", "")) == "build_state" and int(m.get("args", []).size()) >= 10:
			return true
	return false


## 【RL 修正】"哪些阵营的替补**不需要真人点选**、以及**按什么规则选人**"
## （`build_state` 第 10 参，见 AI_Battle.Sim.auto_sub / `_sim_sub_rule`）。
##
## 为什么要按阵营答：`GameState.dual_control` 在本场景恒 true（见 _sync_dual_control），
## 而它让 `Battle._is_manual_sub_faction()` 对**双方**都返回 true。模拟原来据此"一律不预测替补"，
## 于是工具自己替某一方按生产口径补位时，那一次登场反而被判"场外变化"→ 本招判**不可比**、覆盖率被吃掉
## （用户实测：`[替补] 面板归属=敌方 接管=是 选中=hero_46 落位=(0,4) …` 那一招
##   `判定 不可比（…模拟侧未预测出登场：模拟新增 0、真实新增 1）`，而两个字段差异全由这次登场解释）。
##
## 判据 = `_ai_drive_sub(fn)` 的**选人规则**与模拟侧同规则 —— 只有规则一致，预测才可能对上：
##   · **敌方** `"score"`：工具调的就是生产同一个 `_battle._best_enemy_sub_idx()`（src/Battle.gd:4413，
##     `_ai_drive_sub` 里那一句 `var idx := _battle._best_enemy_sub_idx() if fn == ENEMY else 0`）
##     → 与模拟 `_sim_best_sub_idx` 同源同式 → 可预测（这正是用户实测那条"不可比被吃掉"的那一方）。
##   · **玩家方** `"first"`【本轮新增】：工具走的是 `roster[0]`（同上一行的 `else 0`）——
##     那是"派谁上都行"的兜底，**不是**生产打分。上一轮因此只能把玩家方标成"不可预测"，
##     代价是"玩家方在他方回合阵亡开出的替补面板"永远判"不可比"。现在把**规则本身**告进 sim
##     （`"first"` → 模拟也取替补席第一张），两边同一条规则 → 那类登场也能对上、可比。
##     ⚠️ 绝不能把玩家方标成 `"score"`：模拟按打分选、工具按第一张选 → 选到不同英雄 → 凭空造 DIFF（实测 12 条）。
##   手动档那一方（`_ai_driven_by_us` 为假）更不在列：面板留给玩家自己点。
func _auto_sub_sides() -> Dictionary:
	var out := {}
	for fn in [DataRegistry.Faction.PLAYER, DataRegistry.Faction.ENEMY]:
		if not _ai_driven_by_us(_side_of_faction(fn)):
			continue
		# 规则必须与 `_ai_drive_sub` 里真正用的那一行**同一条**（见那里的 `_best_enemy_sub_idx() ... else 0`）
		out[fn] = "score" if fn == DataRegistry.Faction.ENEMY else "first"
	return out


## 【RL 修正】墓碑的**阵营**要带进 sim。
## `BattleSnapshot.collect` 把真实 `battle.graves`（src 里本来就是 `{ "hero", "fn" }`，
## 见 src/Battle.gd:3983 / 4297）压成 `cell → true`——那是 src 的公开契约，不动它——
## 于是模拟只认得"这格有墓碑"、认不出**是谁的**墓碑，而真实两处都按阵营判：
##   · `_free_sub_cell_for(fn)`（src/Battle.gd:4561）：只挑**本方**墓碑格落位（"阵亡原地补"）；
##   · `_clear_side_graves(fn)`（src/Battle.gd:4710，由 `_place_enemy_sub` 收尾调用:4408）：
##     只清**本方**墓碑（安葬完毕时把剩余墓碑一起清掉）。
## 这里按真实 `battle.graves` 重建一份带 fn 的（值形状与 sim 自己 `_sim_kill` 写入的一致），
## 让模拟能按同一口径判；**取不到 fn 的格保持原样**（`true` = 阵营未知 → sim 侧保守不动，
## 见 `_sim_clear_side_graves`：宁可少清一座，也不凭猜清掉别人的墓碑）。
func _grave_fns(snap_grave: Dictionary) -> Dictionary:
	var out := {}
	for c in snap_grave.keys():
		out[c] = snap_grave[c]
	if _battle == null or not is_instance_valid(_battle):
		return out
	var live: Dictionary = _battle.graves
	for c in live.keys():
		if not out.has(c):
			continue   # 快照里有、战场已没有的格：维持原值（本招窗口内不会用到）
		var gd = live[c]
		if typeof(gd) == TYPE_DICTIONARY:
			out[c] = {
				"hero": String((gd as Dictionary).get("hero", "")),
				"fn": int((gd as Dictionary).get("fn", -1)),
			}
	return out


## 【临时插桩 · env 门控】ZB_PINDBG=1 时，每个对拍块打印"远程被贴身"两侧对照：
## 真实侧的缓存标记 `Unit.ranged_adjacent` + 有效攻，模拟侧的 `pin_flag` + `eatk` + 相邻敌人清单。
## 用途：`_sim_refresh_pins`（= 真实 `Battle._sync_ranged_adjacent`）的**刷新时机**若与真实不一致，
## 就会出现"一侧按缓存标记、一侧按当前位置"的有效攻差异（hero_40 sweep #22/#23 那两个反向 DIFF）。
## 默认零开销（不设该环境变量时连函数都不会被调用）。
func _pin_diag(sim, rec: Dictionary) -> void:
	if _battle == null:
		return
	_log("[PINDBG] #%s 远程被贴身对照（真实 | 模拟）" % str(rec.get("n", -1)))
	for u in _battle.units:
		if u == null or not is_instance_valid(u) or not u.alive:
			continue
		if u.attack_type != DataRegistry.AttackType.RANGED:
			continue
		_log("  真实 %s@%s 贴=%s 有效攻=%d 基础攻=%d 道具=%d" % [String(u.hero_id), str(u.cell),
			str(u.ranged_adjacent), u.effective_atk(), int(u.atk), int(u.atk_use_buff)])
	if sim == null:
		_log("  模拟 sim=null")
		return
	for su in sim.units:
		if su == null or not su.alive or su.atk_type != DataRegistry.AttackType.RANGED:
			continue
		var adj := ""
		for t in sim.units:
			if t != null and t.alive and t.fn != su.fn and _battle.grid.distance(su.cell, t.cell) == 1:
				adj += "%s@%s " % [String(t.hero_id), str(t.cell)]
		_log("  模拟 %s@%s 贴=%s 有效攻=%d 基础攻=%d 麻痹=%d pin_buffs=%d pin_init=%s 道具=%d 相邻敌人=%s" % [
			String(su.hero_id), str(su.cell), str(su.pin_flag), int(su.eatk), int(su.atk),
			int(su.atk_mod), int(su.pin_buffs), str(su.pin_init), int(su.atk_use_buff), adj])


## 【RL 修正】风语者(hero_43) 移动光环的"真实账本份数"：按**接收者 instance_id** 数出
## "本回合被几位存活风语者发过光环"（真实 `hero_43._aura_given` 只记真发过的队友）。
## 模拟在风语者阵亡时要据此收回 +1 移动力；快照的 `emove` 只是合计、看不出"谁真拿过"。
func _windspeaker_aura_counts() -> Dictionary:
	var out := {}
	if _battle == null or not is_instance_valid(_battle):
		return out
	for u in _battle.units:
		if u == null or not is_instance_valid(u) or not u.alive:
			continue
		if String(u.hero_id) != "hero_43":
			continue
		var hb = _battle._hero(u)
		if hb == null:
			continue
		var given = hb.get("_aura_given")
		if typeof(given) != TYPE_DICTIONARY:
			continue
		for k in (given as Dictionary).keys():
			# ★ 真实 `hero_43.on_died`（heroes/hero_43_风语者.gd:81）只对 `move_buff > 0` 的队友各 -1；
			#   账本里记过名但 move_buff 已被 `_clear_statuses()`（src/Battle.gd:1999，本方回合结束清零）
			#   的单位，真实**不会**被扣。这里也必须不计数，否则模拟凭空 -1 移动力（有效移族）。
			var ru := instance_from_id(int(k)) as Unit
			if ru == null or not is_instance_valid(ru) or ru.move_buff <= 0:
				continue
			out[k] = int(out.get(k, 0)) + 1
	return out


## ================= 每回合状态注入（counter_used / moved / attacked） =================
#
# 为什么必须注入：`build_state()` 的老口径**不从 descs 读**这三项，而本检视器是
# **每一招都从真实盘面重建一份新 sim** → "本回合已经反击过 / 已经移动过 / 已经攻击过"
# 这类**同一回合内累积**的状态全丢，于是模拟会算出真实里不会发生的事。
#
# 实测（用户撞到 · 我方第 3 招）：赏金猎人本回合**已经反击过一次**，真实侧直接不反击
# （每回合只能反击一次，src/Battle.gd:3359-3360），而模拟拿着一份"没反击过"的新 sim 照算一次
# → `鼠队长(hero_04)#5 血量 预测14→实际15` 的假 DIFF。
#
# 键名（**与模拟层同步交付，两边必须一致**，缺省 false = 老口径）：
#   `counter_used` / `moved` / `attacked`
# 取值来源：真实 `Unit.counter_used_this_turn` / `moved_this_turn` / `attacked_this_turn`
# （旗标行读的就是这三个，说明在真实侧随时取得到）。
#
# 注入用**同一个 descs 数组**（就地加键），所以必须在 `build_state()` **之前**调用；
# 喂完之后 descs 里就带着这份状态，build_state 读不读由模拟层决定（不读则行为不变）。

## 把真实单位的每回合状态注入 descs。desc_list 与 units 必须**下标对齐**
## （两者都来自同一次 `BattleSnapshot.collect(battle, pool)`：descs[i] ↔ pool[i]）。
func _inject_turn_flags(desc_list: Array, units: Array) -> void:
	var n := mini(desc_list.size(), units.size())
	# ★ 下标对齐自检（上来先验一遍，把"注入串位"这类隐患变成机读结论）：
	#   两处调用点的 pool 不同但都必须与传入的 descs 同源——
	#     · `_build_plan`：`SNAP.collect(_battle)`（空 pool → `battle.units`）↔ `_battle.units`
	#     · `_predict`   ：`SNAP.collect(_battle, view)`（pool=view）  ↔ `view`
	#   逐项比 `hero` / `cell` 即可证明"desc_list[i] 就是 units[i]"。
	if not _align_checked:
		_align_checked = true
		var bad := 0
		for i in n:
			var d0 = desc_list[i]
			var u0 = units[i]
			if not (d0 is Dictionary) or u0 == null or not is_instance_valid(u0) or not (u0 is Unit):
				continue
			var dd0: Dictionary = d0
			if String(dd0.get("hero", "?")) != String((u0 as Unit).hero_id) or dd0.get("cell", null) != (u0 as Unit).cell:
				bad += 1
		if bad > 0:
			_warn("descs 与 units 下标未对齐：%d/%d 项对不上（注入 moved/attacked/counter_used 会串到别的单位上）" % [bad, n])
		else:
			_log("[自检·对齐] descs ↔ units 下标对齐 OK（%d 人：逐项比 hero/cell 全一致）" % n)
	# 【RL 修正】风语者光环"真发过几份"的账本（下一循环逐单位注入，见 `ws_aura` 那行）。
	var _ws_counts := _windspeaker_aura_counts()
	for i in n:
		var d = desc_list[i]
		if not (d is Dictionary):
			continue
		var u = units[i]
		var ok: bool = u != null and is_instance_valid(u) and (u is Unit)
		var dd: Dictionary = d
		dd["counter_used"] = (u as Unit).counter_used_this_turn if ok else false
		dd["moved"] = (u as Unit).moved_this_turn if ok else false
		dd["attacked"] = (u as Unit).attacked_this_turn if ok else false
		# ★ 第 4 个"每回合状态"键：`once_this_turn`（"每回合限一次"类技能的名额，`src/Unit.gd:29`）。
		#   圣光的名额就存在它上面（`heroes/hero_22_圣光.gd` 读写它），而 `BattleSnapshot.unit_desc`
		#   没把它带进 descs；检视器**每一招都新建一份 sim** → 名额永远从 false 起 →
		#   真实这一回合前面某招已发过盾，模拟却以为名额还在 → **多发一面盾**
		#   （`状态[盾] 预测是→实际否`，伤者己方 + 发盾方圣光 + 本招不是圣光的动作 = 特征全同向）。
		#   与上面三键同语义：逐单位状态、就地注入 descs、必须在 `build_state()` 之前；
		#   缺省 false = 改动前行为（键名与模拟侧读取端一致：`once_this_turn`）。
		dd["once_this_turn"] = (u as Unit).once_this_turn if ok else false
		# ★ 第 5 个键：`ranged_adjacent`（远程"被贴身"的**缓存标记**，真实 `src/Unit.gd` 的字段）。
		#   模拟侧 `SimUnit.pin_flag` 读它（缺省 false），再按快照 `eatk` 反推 `pin_buffs`：
		#   不注入时，"真实标记=被贴、有效攻已被压成 1"的远程单位会被反推成
		#   `pin_buffs = 1 - 3 = -2` → 之后无论按标记算、还是刷新后按位置算，有效攻都停在 1。
		#   实测（全量矩阵 hero_40 sweep #23 那一块）：真实 贴=false 有效攻=3，模拟 贴=false 有效攻=1、
		#   pin_buffs=-2 → 字段级 DIFF。`技能对拍._build_sim` 一直有注入这一键（见那里的注释与
		#   `descs[i]["ranged_adjacent"] = ru.ranged_adjacent`），检视器这条路漏了。
		if ok:
			dd["ranged_adjacent"] = (u as Unit).ranged_adjacent
			# ★ 第 7 个键：`solid`（[坚固]，hero_48 装甲堡垒）。
			#   `BattleSnapshot.unit_desc` **不产出**这个键，只有矩阵 harness 注了（技能对拍.gd:1407）——
			#   检视器这条路径漏了 → 模拟里 `t.solid` 恒 false → 坚固目标被多打 1 点，
			#   并且会连带把「塔盾替扛」的门槛（dmg>1）推过线，导致塔盾也少 1 血。
			dd["solid"] = (u as Unit).has_status(StatusDB.SOLID)
		# ★ 第 6 个键：`ws_aura`（风语者移动光环"真发过几份"的真实账本，见 `_windspeaker_aura_counts`）。
		#   风语者阵亡时模拟要按它收回 +1 移动力；快照 `emove` 只是合计、看不出"谁真拿过"。
		#   不注入（键缺失 = -1）时模拟退回"同阵营存活队友全减"的近似 —— 那种近似在
		#   "单位是本回合中途 spawn 出来的（风语者 on_turn_start 没跑过）"场面上会多扣 1 点移动力。
		dd["ws_aura"] = int(_ws_counts.get((u as Unit).get_instance_id(), 0)) if ok else -1


## 机读断言：每招重建 sim 前，把"出手单位 + 场上已反击/已移动/已攻击的单位数"写进运行时文件。
## 目的：以后再出现"每回合状态丢失"类的假 DIFF，一眼能看出当时真实侧的累积状态。
func _turn_flags_evidence(view: Array, idx: int) -> void:
	var n_cu := 0
	var n_mv := 0
	var n_at := 0
	var n_alive := 0
	for k in view.size():
		var u = view[k]
		if u == null or not is_instance_valid(u) or not (u is Unit):
			continue
		n_alive += 1
		if (u as Unit).counter_used_this_turn:
			n_cu += 1
		if (u as Unit).moved_this_turn:
			n_mv += 1
		if (u as Unit).attacked_this_turn:
			n_at += 1
	_log("[每回合状态注入] 出手单位=%s 视图 %d 人：已反击 %d / 已移动 %d / 已攻击 %d（三项都从真实 Unit 注入 descs，喂 build_state 前）" % [
		_view_name(view, idx), n_alive, n_cu, n_mv, n_at])


## ================= sim 字段存在性自检（一次掐死"读不存在的字段→null→判定错"） =================
#
# 为什么要有它：本项目已经踩过三次同类事故——
#   · `s.atkdown` / `s.thorn` 在候选 fork 里不存在 → 读成 null → `状态[麻] 预测否→实际是` 假 DIFF；
#   · 快照里少地形键 → 印出 `0→3` 幻影；
#   · 单位集合变化后按下标硬比 → 整体错位。
# 共同点都是"字段名漂移/字段缺失 → 静默 null → 判定错但不报错"。所以在拿到第一份 sim 之后
# 做一次**字段审计**：把我们读/比对过的字段逐个确认存在，缺失就告警（控制台 + 文件）。

## 我们会从 `Sim` 读的所有字段。
const SIM_FIELDS := ["units", "obstacles", "bombs", "graves", "gold_cells", "buff_cells"]
## 我们会从 `SimUnit` 读的所有字段（不含下面两个"可选"的）。
const SIM_UNIT_FIELDS := ["cell", "hp", "max_hp", "alive", "eatk", "atk", "emove", "stunned",
	"silenced", "shield", "heavy", "poisoned", "frozen", "moved", "attacked", "counter_used",
	"atk_use_buff", "move_use_buff", "atk_mod"]
## 可选字段：sim 有就读 sim，没有就退回"真实侧注入"（见 _sim_status_value）。缺失只报信息、不算故障。
const SIM_UNIT_OPTIONAL := ["atkdown", "thorn"]


## 某个属性在对象上**真实存在**吗。`Object.get()` 读不存在的属性会静默返回 null，
## 所以判定前必须先问"有没有"，否则会把"读不到"当成 false。
func _sim_field_exists(obj, field: String) -> bool:
	if obj == null:
		return false
	for p in obj.get_property_list():
		if String(p.get("name", "")) == field:
			return true
	return false


## 状态位取值：sim 有真字段就用 sim，没有就退回真实侧 `has_status`（与可读层同源）。
func _sim_status_value(s, key: String, u: Unit) -> bool:
	if key == "atkdown" or key == "thorn":
		if _sim_field_exists(s, key):
			return _truth(s.get(key))
		var st: String = StatusDB.ATKDOWN if key == "atkdown" else StatusDB.THORN
		return u != null and is_instance_valid(u) and (u as Unit).has_status(st)
	return _truth(s.get(key))


## 拿到第一份 sim 后审计字段存在性（只做一次）。缺字段 → 控制台 + 文件各一条告警。
## 取证（`--audit-probe <字段名>`）：故意加一个假字段名，证明审计**不是空跑**。
func _audit_sim_fields(sim) -> void:
	if _sim_audit_done or sim == null:
		return
	_sim_audit_done = true
	var missing: Array = []
	var checked := 0
	for f in SIM_FIELDS:
		checked += 1
		if not _sim_field_exists(sim, String(f)):
			missing.append("Sim.%s" % f)
	var u0 = null
	if (sim.units as Array).size() > 0:
		u0 = sim.units[0]
	for f2 in SIM_UNIT_FIELDS:
		checked += 1
		if not _sim_field_exists(u0, String(f2)):
			missing.append("SimUnit.%s" % f2)
	var opt_missing: Array = []
	for f3 in SIM_UNIT_OPTIONAL:
		if not _sim_field_exists(u0, String(f3)):
			opt_missing.append("SimUnit.%s" % f3)
	# 取证探针：证明"缺失能被检出来"（不是空跑）
	if _audit_probe != "":
		checked += 1
		if not _sim_field_exists(u0, _audit_probe):
			missing.append("SimUnit.%s（--audit-probe 故意塞的假字段）" % _audit_probe)
	_log("[自检·sim字段] 审计 %d 个字段，缺失 %d 个" % [checked, missing.size()])
	if opt_missing.size() > 0:
		_log("[自检·sim字段] 可选字段缺失（按设计走真实侧注入兜底）：%s" % str(opt_missing))
	if missing.size() > 0:
		_warn("sim 字段不存在：%s（比对/读取会恒为 null，判定会错）" % str(missing))
	else:
		_log("[自检·sim字段] 全部存在 ✔（SimUnit %d + Sim %d + 可选 %d）" % [
			SIM_UNIT_FIELDS.size(), SIM_FIELDS.size(), SIM_UNIT_OPTIONAL.size()])


## 把喂给 AI 的 descs 的阵营标签对调，让"我方"在 AI 眼里变成 ENEMY（它天然以 ENEMY 为视角）。
## refs / 下标一个都不动：动作照旧作用在正确的真实单位上。
## 注意：对局.gd 里那句 `dd["row"] = ...` 是**死代码**——fork 的 build_state 不读 "row"，
## 推进度是拿 u.cell.y 现算的，所以这里不抄它。
func _relabel(descs: Array) -> Array:
	var out: Array = []
	for d in descs:
		var dd: Dictionary = (d as Dictionary).duplicate()
		var f := int(dd["fn"])
		dd["fn"] = DataRegistry.Faction.PLAYER if f == DataRegistry.Faction.ENEMY else DataRegistry.Faction.ENEMY
		out.append(dd)
	return out


## 面板/日志用的"我方/敌方"字样（按 SIDE 常量，不是按阵营标签）。
func _side_txt(side: int) -> String:
	return "我方" if int(side) == int(GameState.SIDE_PLAYER) else "敌方"


# ================= 逐招：预测 vs 实际 =================

## 本步的"快照下标基准"：把回合开始时冻结的 _desc_keys 过滤成**现在还活着、能参与对拍**的单位。
## 返回 { units, src }：units 的下标就是喂给 SNAP.collect / _predict / _compare 的下标，
## src[k] = units[k] 在 _desc_keys 里的原下标。
## _desc_keys 本身一个字节都不动：执行侧 _call_action / _cur_hero / _next_hero / _plan_hero
## 全都依赖"回合开始那份原下标"。
##
## 为什么必须过滤：回合中途有人阵亡时，单位先在 units 里 alive=false 淡出 0.3s（src/Unit.gd die()），
## 再被 Battle._on_unit_died 从 units.erase + queue_free（src/Battle.gd:4278 / 4288）。
## 这份冻结名单里留下的"已释放实例"一旦被当成 SNAP.collect 的 pool，就会在
## BattleSnapshot.gd:45 的类型化赋值处报 "Trying to assign invalid previously freed instance"。
##
## 为什么"过滤"就等于"当前真实盘面"：Battle.units 全生命周期只有 append / erase、从不重排
## （src/Battle.gd:1677 / 4108 / 4278 / 5002），回合中途落位的替补与召唤只会 append 到末尾；
## 而"回合中途新落位"的单位本来就不在这份 plan 的下标空间里（计划是按回合开始的名单编的）。
## 所以"回合开始的名单去掉已离场者"与 units 里的在场顺序逐一对应，按下标换算不会张冠李戴。
##
## ★★ 但"新落位者不在这份 plan 的下标空间里"**不等于"模拟世界也该没有它"**（本轮修的最大族）：
##   回合中途登场的替补/召唤会**留在场上继续参与后面每一招**，而这份名单是回合开始冻结的 →
##   后面每一招的"模拟世界"都比真实少一个单位。实测（`--autoloop --autoloop-rounds 4 --beam 50
##   --speed 20` 第 2 局，`RL/reports/rt/对拍_运行时_0913_165719.log`）：
##     #2 窗口内敌方替补 hero_12 落位 (0,2)（已按生产口径预测、判 MATCH）；
##     #3 同一回合的下一招：[每回合状态注入] 出手单位=负墟(hero_44)#1 **视图 5 人**，而 [落定] 写
##        **单位=6**、[快照] 写"本招窗口内新登场 1 个单位（hero_12）" → sim 只有 5 个、
##        `_compare` 数的是 ext_view 的 6 个 → `在场单位数 预测5→实际6`。
##   它既不是"模拟多算"也不是"模拟漏算"：**是工具没把人给模拟**（SPAN 闸门也看不见它——
##   这一招窗口内没有替补事件、场上单位数也没变，两个判据都不成立）→ 只能判成 DIFF。
##   修法：把"此刻已在场、但不在 _desc_keys 里"的单位**追加在名单末尾**。
##   为什么追加在末尾是安全的：计划里的 idx / 攻击目标下标都是"原下标的化"，`vsrc.find()` 取到的
##   位置不变；`build_state` 按 descs 顺序 append SimUnit → `sim.units[k] ↔ view[k]` 的对齐契约不变；
##   `_collect_units` / `ext_view` / `_snap_sim` 三处都按同一份 view 走 → 两侧"在场单位数"口径重新对齐。
##   代价/边界：这些人不在本回合的计划里（不会替它们出手），只是**作为世界的一部分**参与后面每一招的
##   模拟与比较（挡路、光环、被 AOE 波及都能算对了）；出场那一招本身仍走原有的"窗口内新登场"通路。
##
## 注意区分两种"0 血"：alive 已为 false = 已阵亡（要过滤掉）；hp<=0 但 alive 仍为 true
## = 延迟阵亡结算中（src/Battle.gd:4310），它还留在 units 里（_drain_pending_deaths 就是按这个
## 判据等的），照旧留在名单里，由 _collect_units 的 zero 表按"出招前就 0 血"跳过比对。
func _step_view() -> Dictionary:
	var units: Array = []
	var src: Array = []
	for i in _desc_keys.size():
		# 故意不写类型标注：这里可能是已释放实例，带类型的赋值当场就会报错（就是本次崩的那一句）
		var u = _desc_keys[i]
		if u == null or not is_instance_valid(u) or not (u is Unit):
			continue
		if not (u as Unit).alive:
			continue      # 已阵亡（淡出中或已结算）：它不再行动、格位也已让出，不该进模拟
		units.append(u)
		src.append(i)
	# ★★ 追加"**回合中途已经登场、但不在 _desc_keys 里**"的单位（根因见上面的长注释）：
	#   它们此刻就在场上（`battle.units` 里、alive=true），必须一起进模拟世界，否则后面每一招都会
	#   把"模拟世界少一个人"报成 `在场单位数 预测N→实际N+1`（而 SPAN 两个判据都看不见这次登场）。
	#   只认**alive=true** 的：淡出中的阵亡者（alive=false）不算在场，不该被追加进来。
	#   顺序固定按 `battle.units`（只 append、从不重排），且在原有名单**之后**追加 →
	#   `src` 里补 -1 占位（它们没有 _desc_keys 原下标），`vsrc.find()` 对原有下标的换算完全不变。
	var seen := {}
	for u0 in units:
		seen[u0] = true
	if _battle != null and is_instance_valid(_battle):
		for un in _battle.units:
			if un == null or not is_instance_valid(un) or not (un is Unit):
				continue
			if seen.has(un) or not (un as Unit).alive:
				continue
			seen[un] = true
			units.append(un)
			src.append(-1)
	return { "units": units, "src": src }


func _step(a: Dictionary) -> String:
	# 0) 生产节奏：换人 0.7s / 起手 0.3s / 同人下一招 0.25s
	await _sleep(TELL_GAP if _new_hero else STEP_GAP)
	_new_hero = false
	# 0.5) 取本步的下标基准。必须卡在"停顿之后、快照之前"：这段停顿（0.25~0.7s）刚好够一个
	#      阵亡单位淡出并被释放（实机那次就是崩在停顿之后的出招前快照）；而从这里到出招前快照
	#      之间没有 await，不会再有单位离场，所以这份 view 拿来打包是安全的。
	var lv := _step_view()
	var view: Array = lv["units"]
	var vsrc: Array = lv["src"]
	var idx: int = vsrc.find(_cur_idx)
	if idx < 0:
		# 本招要出手的单位在出招前就已离场：与 _call_action 里"单位已离场"同路，
		# 交回 _drive_enemy_turn 走既有的"本回合剩余计划作废"，不静默跳过、也不打错人。
		return "changed"
	# 计划里的 action 是按 _desc_keys 原下标写的：喂模拟前把攻击目标换算到 view 下标。
	# （move / atk_obs 是格子坐标，与单位下标无关，不用动。）
	var a_pred: Dictionary = a
	var no_pred := ""
	var ti := int(a["atk"]) if (a.has("atk") and a["atk"] != null and int(a["atk"]) >= 0) else -1
	if ti >= 0:
		var tidx: int = vsrc.find(ti)
		if tidx < 0:
			# 计划要打的人已经离场：真实规则会拦下这一击（_call_action 里有同款判定），
			# 模拟里也没有这个人可打。不硬凑一个"这招没打人"的预测——那会把已经过期的计划
			# 洗成 MATCH——如实报"无法预测"。
			no_pred = "本招的攻击目标（回合开始下标 %d）已离场：真实规则会拦下这一击，模拟无法复现" % ti
		else:
			a_pred = a.duplicate()
			a_pred["atk"] = tidx
	# 1) 出招前：打包真实局面，用同一动作问模拟"这招打完长什么样"
	#    ★ 同时取"场外事件指纹"（SPAN 主判据用）：比较出招前/后的差值即本招窗口内发生过什么。
	var ev_pre: Dictionary = _window_events_now()
	var before: Dictionary = SNAP.collect(_battle, view)
	var before_units := _collect_units(view)
	var pred: Dictionary = _predict(view, before, idx, a_pred, no_pred)
	# ★ 出招前就冻好两份"前"快照：
	#   · pre_real：出招前的真实局面（before 这一份，含出招前地形五键）
	#   · pre_pred：**预测前**的模拟局面——直接用 _predict 在 _apply 之前冻好的那份，
	#     而不是这里再 _snap_sim(pred["sim"], view)（那读到的是 _apply 之后的同一个对象）。
	var pre_real: Dictionary = _snap_of(before, view)
	var pre_pred: Dictionary = pred.get("sim_pre", {})
	# 2) 真·执行这一招（等动画播完）
	var hero_before := _cur_hero()
	# for_enemy 用的是**驱动口径**而非单位阵营：本场景替哪一方出手，就必须按"回放"口径执行，
	# 否则玩家方永远不发 action_finished（见 _call_action 注释），每招都会吃满 3s 超时。
	var res: Dictionary = await _call_action(a, true)
	if String(res["status"]) == "changed":
		return "changed"
	# ★ 在取"出招后快照"**之前**把"AI 那方待放的炸弹"落下去。
	# 为什么必须放在这里（而不是只靠 `_process` 的每帧 tick）：`_finish_move` 在 for_enemy 分支里
	# 提前 return，`state` 不进 PLACE_BOMB，而且 `action_finished` 已经发出、`_step` 马上要继续
	# 取快照 —— 放到快照之后就变成"雷落在两次采样之间"，本招仍会报 `炸弹@(x,y) 预测有→实际无`。
	# 放在这里，雷就落在**本招窗口内**，两侧快照都能看到它 → 该 DIFF 归零。
	_bomb_takeover_tick()
	# ★★ 等"世界落定"再取"出招后快照"（根因见 _await_settled 注释）：
	#    必须卡在**采样之前**——真实死亡要淡出 0.3s 之后才 `died.emit`，而写墓碑 / 红帽自爆都在那之后。
	await _await_settled("n=%d" % _selftest_seq())
	# 3) 出招后：再打包一次真实局面，逐字段对比。
	#    pool 必须**重新**过滤：这一招里阵亡的单位可能已经淡出并被释放，直接拿 view 当 pool
	#    会重演同一处崩溃（无头自检那次就是崩在出招后这一句）。
	#    下标基准仍然是出招前那份 view（本招内不会变），keys/src/zero 三者同源 → 不会错位。
	# ★★ 出招后快照必须**容纳"本招窗口内新登场的单位"**（用户拍板的盲区）：
	#   原来 pool = 出招前那份 `view`（回合开始冻结的名单）→ **中途落位的替补根本不在快照里**
	#   → 只能整块判"不可比"（覆盖率被吃掉一大截）。
	#   现在 pool = 「出招前 view 里仍有效的单位」**+**「`_battle.units` 里出招前 view 没有的新单位」，
	#   且**新单位按 `battle.units` 的顺序追加在末尾** —— 这样与模拟侧"把登场者 append 进 `sim.units`"
	#   的下标顺序一致，`_snap_sim` 的下标配对（view[k] ↔ sim.units[k]）对新单位同样成立。
	#   （契约：模拟的"动作后状态"把窗口内登场的替补当正常单位追加在末尾，并施加登场效果如波盾给盾。）
	var after_units := _collect_units(view)
	var ext_view: Array = view.duplicate()
	var seen_u := {}
	for i0 in after_units["keys"]:
		seen_u[i0] = true
	var new_units: Array = []
	if _battle != null and is_instance_valid(_battle):
		for un in _battle.units:
			if un == null or not is_instance_valid(un) or not (un is Unit):
				continue
			if seen_u.has(un):
				continue
			seen_u[un] = true
			ext_view.append(un)
			new_units.append(un)
	if new_units.size() > 0:
		_log("[快照] 本招窗口内新登场 %d 个单位（已纳入出招后快照末尾，供与模拟侧同下标配对）：%s" % [
			new_units.size(), str(new_units.map(func(x): return (x as Unit).hero_id))])
	var after: Dictionary = SNAP.collect(_battle, after_units["keys"])
	after["keys"] = after_units["keys"]
	after["src"] = after_units["src"]
	after["zero"] = before_units["zero"]
	res["atk_idx"] = vsrc.find(int(res.get("atk_idx", -1)))   # 攻击目标下标同样换算到 view 基准
	var rec := _compare(pred, after, idx, view, a, res, ext_view)
	# ★ 场外事件指纹要在 rec 建好之后才能挂上去（踩过：写在 _compare 之前 → "Identifier rec not declared"）
	rec["window_ev"] = { "pre": ev_pre, "post": _window_events_now() }
	rec["new_units"] = new_units.size()     # SPAN 闸门用：真实侧本窗口内新登场几个
	# 对拍块所需的"前后快照"：两侧后果都由**出招前真实局面 → 出招后**逐单位/逐格对比得出，
	# 不依赖动作字典里写了什么（AOE/连锁/光环/点燃障碍这样才不会漏）。
	# 预测侧 = pre_real → pre_pred；实际侧 = pre_real → post_real（两侧**同一份前快照**，口径一致）。
	rec["pre"] = { "real": pre_real, "pred": pre_pred }
	rec["post"] = {
		"real": _snap_of(after, ext_view),
		"pred": _snap_sim(pred.get("sim", null), ext_view),
		# 绝对状态（按名字索引），供"可读层有差异、字段层为空"时就地复核定性用（见 _abs_state_differs）
		"real_abs": _abs_of(_snap_of(after, ext_view)),
		"pred_abs": _abs_of(_snap_sim(pred.get("sim", null), ext_view)),
	}
	rec["round"] = GameState.round_number
	rec["side"] = _side_txt(GameState.active_side)
	rec["atk_target_name"] = _view_name(view, int(res.get("atk_idx", -1)))
	rec["atk_obs_cell"] = a.get("atk_obs", Vector2i.ZERO)
	rec["moves"] = _moves_of(rec["pre"]["real"], rec["post"]["real"], String(rec["hero"]))
	_show(rec)
	_print_chk(rec)
	_tally(rec)
	if String(res["status"]) == "timeout":
		_log("[检视器] 第 %d 招动画等待超时 → 已用超时兜底继续（盘面仍照常对拍）" % int(rec["n"]))
	_new_hero = _next_hero() != hero_before
	# 每出一招都按真实行动点重刷高亮（用户报过"AI 行动后高亮没消失"）：
	# AI 出手时 Battle 不会走玩家那条 _after_player_action 路径，没人清高亮，所以要在这里补一次。
	_refresh_action_highlights()
	return String(res["status"])


## 用「同一个动作」在模拟里推一步，得到预测局面。
## 关键：从**出招前的真实局面**重建 sim 再 _apply，而不是复用别处的模拟状态——
## 这样每一招都是独立干净的对拍：上一招若因计划外事件（有人阵亡出列导致下标位移）失准，
## 不会污染这一招的判定。
## descs/idx 都是"本步 view"的下标（见 _step_view）；why 非空 = 这一步模拟无从下手
## （计划里的目标已经离场等），直接如实报"无法预测"，不伪造结果。
func _predict(descs: Array, snap: Dictionary, idx: int, a: Dictionary, why: String = "") -> Dictionary:
	if why != "":
		return { "ok": false, "why": why }
	if _ai == null:
		return { "ok": false, "why": "AI 模块未就绪" }
	if idx < 0 or idx >= descs.size():
		return { "ok": false, "why": "下标越界 idx=%d（单位数=%d）" % [idx, descs.size()] }
	if not _act_supported(a):
		return { "ok": false, "why": "动作类型超出模拟支持：%s" % _act_kind(a) }
	# ★ 重建 sim 之前必须先注入"每回合状态"（本回合已反击/已移动/已攻击），见 _inject_turn_flags 注释。
	#   不注入就会出现用户撞到的那种假 DIFF：真实侧"本回合已反击过"→不再反击，模拟却照算一次。
	_inject_turn_flags(snap["descs"], descs)
	_turn_flags_evidence(descs, idx)
	# ★★ 第 8 参 `active_fn` = **这一击结算时的真实行动方阵营**。
	# 不传的后果（"矩阵绿、扫描红"的盾族根因）：fork 的 `build_state` 缺省 `active_fn = ENEMY`，
	# 于是圣光 `heroes/hero_22_圣光.gd` 的条件②（"只在**敌方**回合给盾"，即伤者阵营≠行动方阵营）
	# 在我方回合被误判 → 模拟多发一面盾 → `状态[盾] 预测是→实际否`（同族 5 条方向全同）。
	# 矩阵 harness 是显式传的，所以那边一直绿。
	# ★★ 取值口径（本次修正）：英雄脚本判"回合归属"读的是 `battle.side_faction(GameState.active_side)`
	# （锤头鲨 hero_37 `on_someone_damaged`、圣光 hero_22 `on_someone_damaged` 都是这一句），
	# 所以这里必须传**同一个表达式的实时值**，而**不能**用"出手单位的阵营"顶替
	# —— 改动前传的是 `snap["descs"][idx].fn`（出手方阵营），只在"这一招确实还跑在自己回合里"时相等。
	# 为什么两者会不等：本检视器把双方都设成 AI 驱动（`dual_control` 恒 true），于是**每一方**的回合
	# 都有 90 秒限时（src/Battle.gd:288 `my_turn_live = active_side == _operable_side()`）；
	# `--speed 20` 时 90 游戏秒 = 4.5 真实秒，而一次 beam 800~3000 的后台搜索要 3~20 秒 →
	# 搜索期间限时到点，Battle 自己 `submit_end_turn()` 把行动方翻面（src/Battle.gd:296-302），
	# 本工具随后仍按旧计划直接调 `_do_*` 出招 → **这一招实际跑在"对面回合"上**，
	# 真实侧所有看回合归属的技能都按新行动方判定。
	# 实测（`--selftest 10 --pai 1 --ai 1 --seed 7 --speed 20 --beam 3000
	#   --picks "hero_27,hero_13,hero_01" "hero_37,hero_23,hero_03"`）：
	#   块头写"第3回合·我方"、同一次计划里的空过行却写"第3回合·敌方"（`_side_txt(side)` 用的是
	#   `_drive_turn` 开头抓的旧值）→ 出手单位是敌方卡组的 复仇者/毒蛇淑女/锤头鲨，
	#   真实锤头鲨不加攻、模拟按"出手方阵营"加 → `锤头鲨(hero_37)#4 有效攻 预测3→实际2`（同族 3 块）。
	# 换成实时行动方之后：没翻面时取值与改动前**逐位相同**（出手方阵营 ⟺ 行动方阵营），
	# 翻面时与真实引擎读的是同一个值 → 消除该族 DIFF。
	var act_fn := int(_battle.side_faction(GameState.active_side))
	var sim
	# 第 10 参 auto_sub（本轮扩成"按规则"）：把"哪一方的替补由工具按**哪条规则**补位"告进 Sim，
	# 模拟才会预测那一方的登场（否则每次替补落位都把这一招判成"不可比"，见 _auto_sub_sides）。
	# 墓碑改用 `_grave_fns(...)`：把每座墓碑的**阵营**带进 sim（快照把它压成了 cell→true），
	# 模拟才能按真实口径判"这座碑是谁的"（本方墓碑格可落位 / 该方替补补完时清本方剩余墓碑）。
	var graves_fns: Dictionary = _grave_fns(snap["grave"])
	if _ai_supports_auto_sub(_ai):
		sim = _ai.build_state(snap["descs"], snap["occ"], snap["gold"], graves_fns,
				snap["obstacle"], snap["bomb"], snap["buff"], act_fn, snap.get("rosters", {}), _auto_sub_sides())
	elif _ai_supports_rosters(_ai):
		sim = _ai.build_state(snap["descs"], snap["occ"], snap["gold"], graves_fns,
				snap["obstacle"], snap["bomb"], snap["buff"], act_fn, snap.get("rosters", {}))
	elif _ai_supports_active_fn(_ai):
		sim = _ai.build_state(snap["descs"], snap["occ"], snap["gold"], graves_fns,
				snap["obstacle"], snap["bomb"], snap["buff"], act_fn)
	else:
		# 「原版困难档」是 src/BattleAI.gd 的逐字节副本：build_state 只收 7 参，多传会
		# 报 "Expected 7 argument(s)"，所以这里必须退回 7 参调用（行为与改动前一致）。
		sim = _ai.build_state(snap["descs"], snap["occ"], snap["gold"], snap["grave"],
				snap["obstacle"], snap["bomb"], snap["buff"])
	_audit_sim_fields(sim)      # 第一次拿到 sim 时审计字段存在性（只做一次）
	if idx >= sim.units.size():
		return { "ok": false, "why": "模拟单位数不足（%d）" % sim.units.size() }
	# ★ 必须在 _apply **之前**把"预测前"局面冻下来：
	# _apply 是**原地修改** sim，而返回给调用方的 "sim" 就是同一个对象，
	# 所以调用方若在之后才 _snap_sim(pred["sim"])，拿到的永远是"预测后"的状态
	# → 预测侧两份快照内容相同 → 恒定"无变化"、判定恒 MATCH（踩过一次）。
	# 关键不是相对 _call_action 的位置，而是相对 _apply 的位置，钉在这里就与调用顺序彻底解耦。
	var sim_pre: Dictionary = _snap_sim(sim, descs)
	_ai._apply(sim, idx, a)
	var cells: Array = []
	for i in sim.units.size():
		cells.append(sim.units[i].cell)
	return { "ok": true, "sim": sim, "sim_pre": sim_pre, "cells": cells, "idx": idx }


## 真实局面的"按 plan 下标对着看"的一份索引：keys=在场单位，src=它对应的 descs 下标。
## 为什么要 src：出招过程中可能有单位被移除（阵亡出列），那时 keys 会比 sim.units 短，
## 直接按顺序对比就会整体错位、报出一堆假 DIFF。
func _collect_units(descs: Array) -> Dictionary:
	# 局部变量不叫 log：会遮蔽内置函数 log()（编辑器警告 SHADOWED_GLOBAL_IDENTIFIER）
	var log_lines := { "keys": [], "src": [], "zero": {} }
	for i in descs.size():
		var u = descs[i]
		if u == null or not is_instance_valid(u):
			continue
		var un := u as Unit
		log_lines["keys"].append(un)
		log_lines["src"].append(i)                       # 真实单位对应的 descs 下标
		# 出招前就 0 血 = 正在淡出结算（还没从 units 出列）：对拍时不算"预测偏差"
		log_lines["zero"][i] = un.hp <= 0
	return log_lines


## Variant → bool（GDScript 没有 bool()/is_true() 这类转换，自己判一下）
func _truth(v) -> bool:
	return v != null and v != false


## 模拟侧下标 si（>= 本招开始时 view 的长度）是不是"**已预测到的**本招窗口内新登场单位"：
## 按 `hero_id + cell` 与 `full_view` 末尾的新登场者配对（与 `_snap_sim` 的新单位配对同款口径）。
## 配对成功 = 这次登场模拟预测到了（SPAN 也按同一事实判"已预测"）→ 不该被当成"模拟凭空多一个单位"。
func _sim_new_arrival_matched(sim, si: int, full_view: Array, view: Array) -> bool:
	if full_view.size() <= view.size():
		return false
	if si < 0 or si >= sim.units.size():
		return false
	var s = sim.units[si]
	var k := int(view.size())
	while k < full_view.size():
		var ru = full_view[k]
		k += 1
		if ru == null or not is_instance_valid(ru) or not (ru is Unit):
			continue
		if String((ru as Unit).hero_id) == String(s.hero_id) and (ru as Unit).cell == s.cell:
			return true
	return false


## 只认 Battle 的三种动作：移动 / 攻击单位 / 攻击障碍。
## 别的（召唤、放炸弹、变身…）不猜——宁可显示"无法预测"，也不伪造结果。
## 注意：**空过不算"未建模的动作"**（见 `_is_noop_action`）——它由调用方在 `_drive_turn` 里
## 提前跳过（不出块、不报 NOPRED）；这里保持"空过 = 不受支持"，是给 `_predict` 兜底用的。
func _act_supported(a: Dictionary) -> bool:
	return (a.has("move") and a["move"] != null) or a.has("atk_obs") \
		or (a.has("atk") and a["atk"] != null and int(a["atk"]) >= 0)


func _act_kind(a: Dictionary) -> String:
	var out: Array = []
	if a.has("move") and a["move"] != null:
		out.append("move")
	if a.has("atk_obs"):
		out.append("atk_obs")
	if a.has("atk") and a["atk"] != null and int(a["atk"]) >= 0:
		out.append("atk")
	return "+".join(out) if out.size() > 0 else "noop（空过）"


## 「空过」（act-noop）：计划元素存在，但**没有任何动作**（`move` 为空 / `atk` < 0 / 无 `atk_obs`）。
## 依据：候选 fork 明确把"什么都不做"当**合法候选**（`RL/ai/AI_Battle.gd:679/686/701/876`），
## AI 有时会选它。它不是"未建模的动作"——模拟里平凡可预测（局面不变）——
## 所以调用方应当**跳过对拍、不出块、不报 NOPRED**，只继续驱动下一招。
## `_act_supported()` 与它同源（= 非空过才算受支持的动作）。
func _is_noop_action(a: Dictionary) -> bool:
	if a.is_empty():
		return true
	var has_move: bool = a.has("move") and a["move"] != null
	var has_atk: bool = a.has("atk") and a["atk"] != null and int(a["atk"]) >= 0
	var has_obs: bool = a.has("atk_obs") and a["atk_obs"] != null
	return not has_move and not has_atk and not has_obs


## 逐字段对比。vidx/view 都是"本步 view"的下标基准（见 _step_view）：
## 出招前预测、出招后实际、以及 res 里的 atk_idx 必须用同一套下标，否则会把真 DIFF 判成 MATCH。
func _compare(pred: Dictionary, after: Dictionary, vidx: int, view: Array,
		a: Dictionary, res: Dictionary, full_view: Array = []) -> Dictionary:
	var rec := {
		# idx 仍记 _desc_keys 原下标（与修复前一致）：_tally 的去重键按它算，
		# 而 view 下标会在"回合中途有人阵亡"时整体前移，拿它去重会漏计招数。
		"n": _selftest_seq(), "act": _act_kind(a), "hero": _cur_hero(), "idx": _cur_idx,
		"diffs": [], "verdict": "MATCH", "note": "",
	}
	if String(res.get("status", "")) == "timeout":
		rec["note"] = "动画等待超时（已兜底继续）；"
	if not _truth(pred.get("ok", false)):
		rec["verdict"] = "NOPRED"
		rec["note"] += String(pred.get("why", "未知原因"))
		return rec
	if not after.has("keys") or not after.has("src"):
		rec["verdict"] = "NOPRED"
		rec["note"] += "真实局面打包失败"
		return rec
	var sim = pred["sim"]
	rec["sim"] = sim   # 【临时插桩 · env 门控 ZB_PINDBG】诊断函数要用它（只存引用，不参与判定）
	var keys: Array = after["keys"]
	var srcs: Array = after["src"]
	var zero: Dictionary = after["zero"]
	var pcells: Array = pred["cells"]
	if srcs.is_empty() and keys.size() > 0:
		rec["verdict"] = "NOPRED"
		rec["note"] += "真实局面打包失败"
		return rec
	# ★★ 单位数比较改成"**在场单位数**"口径（用户撞到的那条 `单位数 预测6→实际5` 的根因）：
	#   真实侧：阵亡单位在淡出结束后会被 `units.erase` + `queue_free` → 从 `_collect_units` 里消失；
	#   模拟侧：fork **从不删单位**（阵亡的 SimUnit 仍留在 `sim.units`，只是 `alive=false`）；
	#   于是"只要本招有单位阵亡"，拿"列表长度"比就必然 6 vs 5 —— 那是**口径不对等**，不是算错。
	#   现在两边都只数 `alive==true` 的：真实侧本来就只有在场者，模拟侧排除阵亡残留 → 对等。
	#   ⚠️ 但这**不能吞掉真差异**：谁死了仍由下面的"存活 预测是→实际否"逐单位抓（见 src_set 那段），
	#      即"模拟以为活着、真实侧已离场"照旧报 DIFF（真实侧死亡被漏删/模拟多杀都跑不掉）。
	var sim_alive := 0
	for s0 in sim.units:
		if _truth((s0 as Object).get("alive")):
			sim_alive += 1
	# 【RL 修正】真实侧"在场单位数"的口径必须与模拟侧**对称**（追加C 那一族）。
	#   模拟的 `sim.units` 里含"本招窗口内新登场的替补"（已被预测 → append 在末尾），
	#   而 `keys` 只来自**本招开始时**的 view（`after_units = _collect_units(view)`，不含新登场者）
	#   → 直接拿 keys 数，就会把**已经预测到的新登场**报成
	#     `在场单位数 预测6→实际5` + `? 存活 预测是→实际否（真实侧已离场/被移除）`（名字还是 "?"）。
	#   用户实测（15:44:32 #2）：窗口内真登场 1 个、模拟侧也新增 1 个，`[SPAN·诊断]` 已判"已预测、
	#   照常比较"，却仍被这两条判 DIFF 并触发一次无意义的重算。
	#   改成数 `full_view`（= view + 本招窗口内新登场的真实单位，见 `_step` 的 ext_view）：
	#   与 `_snap_sim`/`_snap_of` 用的单位集合一致，两边才是同一个"在场"口径。
	var real_src: Array = full_view if full_view.size() > 0 else keys
	var real_alive := 0
	for k0 in real_src:
		if k0 != null and is_instance_valid(k0) and (k0 is Unit) and (k0 as Unit).alive:
			real_alive += 1
	if sim_alive != real_alive:
		rec["diffs"].append("在场单位数 预测%d→实际%d（出招后有单位阵亡/离场/下标位移）" % [
			sim_alive, real_alive])
	# 反向侦测：**模拟里还活着、真实侧却已经不在了**（被移除）→ 真差异，必须报。
	# （正向"模拟死/真实也死"不报：两边一致；出招前就 0 血的 `zero` 也跳过。）
	var src_set := {}
	for i0 in srcs:
		src_set[int(i0)] = true
	for si in sim.units.size():
		var s1 = sim.units[si]
		if not _truth((s1 as Object).get("alive")):
			continue
		if src_set.has(si):
			continue
		if _truth(zero.get(si, false)):
			continue
		# 【RL 修正】"本招窗口内**已预测到**的新登场单位"不算"模拟多出一个单位"（追加C 同族）：
		#   模拟按契约把登场者 append 在 `sim.units` 末尾（下标 >= 本招开始时的 view 长度），
		#   真实侧则按 `hero_id + cell` 配对（与 `_snap_sim` 的新单位配合同一款）。
		#   不排除的话，`_hero_of(view, si)` 越界返回 "?" → 打出
		#   `? 存活 预测是→实际否（真实侧已离场/被移除）` —— 而它其实**活着、而且正是模拟预测的那次登场**。
		if si >= view.size() and _sim_new_arrival_matched(sim, si, full_view, view):
			continue
		rec["diffs"].append("%s 存活 预测是→实际否（真实侧已离场/被移除）" % _hero_of(view, si))
	for j in keys.size():
		# 单位已彻底离场（阵亡出列）：这一条不算预测偏差，改由上面的"单位数"体现
		var raw = keys[j]
		if raw == null or not is_instance_valid(raw) or not (raw is Unit):
			continue
		var u: Unit = raw
		if u.get_tree() == null:
			continue
		var i := int(srcs[j])          # 真实单位的来源下标：跳过离场者也不会错位
		if i < 0 or i >= sim.units.size():
			continue
		var s = sim.units[i]
		var pre: String = _hero_of(view, i)
		if _truth(zero.get(i, false)) and s.alive:
			continue      # 出招前就是 0 血（待结算阵亡）：不算预测偏差
		if not s.alive and not u.alive:
			# ★ 两边都判死**也要**比一次血量（本轮修正）：以前这里直接 `continue`（"一致，不看别的"），
			#   于是"本招内阵亡"的单位在字段层**永远不产生任何条目** —— 而可读层照样会为它印
			#   `预测 | X：HP 3→0（-3）；阵亡` / `实际 | X 消失（阵亡/离场）` 这一对条目；
			#   字段层为空 → `_classify_process_diffs` 只能按绝对状态逐条定性，这一对里的
			#   `HP …；阵亡` 会被打成 `[告警] 字段层漏报`（**文案误导**：字段层不是漏抓，
			#   而是主动跳过了"两边都判死"的单位，见用户实测 15:44:32 那条
			#   `[告警] 字段层漏报：#2 ["炸弹人(hero_35)#1：HP 1→0（-1）；阵亡"]`）。
			#   现在：**血量数值确实不同**就如实写进字段级（带"本招阵亡，两侧都判死"字样），
			#   数值相同（绝大多数情形：两边都 0）则照旧不报 —— 判定口径与计数不受影响。
			if s.hp != u.hp:
				rec["diffs"].append("%s 血量 预测%d→实际%d（本招阵亡，两侧都判死）" % [pre, s.hp, u.hp])
			continue
		if s.alive != u.alive:
			rec["diffs"].append("%s 存活 预测%s→实际%s" % [pre, _yn(s.alive), _yn(u.alive)])
			continue
		if i < pcells.size() and s.cell != pcells[i]:
			rec["diffs"].append("%s 位置 预测%s→实际%s" % [pre, _cell(s.cell), _cell(pcells[i])])
		if s.cell != u.cell:
			rec["diffs"].append("%s 位置 预测%s→实际%s" % [pre, _cell(s.cell), _cell(u.cell)])
		if s.hp != u.hp:
			rec["diffs"].append("%s 血量 预测%d→实际%d" % [pre, s.hp, u.hp])
		if s.max_hp != u.max_hp:
			rec["diffs"].append("%s 血上限 预测%d→实际%d" % [pre, s.max_hp, u.max_hp])
		var ea := u.effective_atk()
		if s.eatk != ea:
			rec["diffs"].append("%s 有效攻 预测%d→实际%d" % [pre, s.eatk, ea])
		var em := u.effective_move()
		if s.emove != em:
			rec["diffs"].append("%s 有效移 预测%d→实际%d" % [pre, s.emove, em])
		for pair in STATUSES:
			var key := String(pair[0])
			var real := u.has_status(String(pair[1]))
			# ★ 比对源必须与可读层同源（用户实机撞到的假 DIFF：`状态[麻] 预测否→实际是`）：
			#   候选 fork 的 SimUnit **没有** `atkdown`/`thorn` 两个字段（麻痹记在 atk_mod 的降攻
			#   记账上、荆棘根本没模拟）→ `s.get("atkdown")` 恒 null → 恒判"预测否"，
			#   而真实侧挂了麻就报一条**假 DIFF**。
			#   这里的取值统一走 `_sim_status_value()`：sim 有真字段就读 sim（模拟层已补字段后自动切回），
			#   没有就退回"真实侧 has_status"（与可读层 `_snap_sim` 的注入口径完全一致）。
			var pv: bool = _sim_status_value(s, key, u)
			if pv != real:
				rec["diffs"].append("%s 状态[%s] 预测%s→实际%s" % [
					pre, String(pair[2]), _yn(pv), _yn(real)])
		# 行动旗标只比"本招确实做过的那几项"，并且**只比本招出手的那个单位**：
		# 本招的预测是从"本招之前的真实局面"新建的，别的英雄留下的痕迹在 sim 里天然是空的，
		# 拿去比就会把上一招的痕迹误报成本招偏差。
		if i == vidx and _truth(res.get("moved", false)) and s.moved != u.moved_this_turn:
			rec["diffs"].append("%s 已移动 预测%s→实际%s" % [
				pre, _yn(s.moved), _yn(u.moved_this_turn)])
		if i == vidx and _truth(res.get("attacked", false)) and s.attacked != u.attacked_this_turn:
			rec["diffs"].append("%s 已攻击 预测%s→实际%s" % [
				pre, _yn(s.attacked), _yn(u.attacked_this_turn)])
		# 反击旗标只在"本招确实打了这个单位"时才有意义。
		# 只报"预测有、实际没有"这一向：反向（预测否/实际是）是**本工具自身的取样方式**造成的——
		# 每招的预测都是从"该招之前的真实局面"新建的，看不到更早那招留下的反击痕迹；
		# AI 自己那份连续模拟是带着这个旗标的（见 _sim_counter_check），不是模拟的缺口。
		# res["atk_idx"] 已在 _step 里换算到 view 下标，这里两边同基准。
		if i == int(res.get("atk_idx", -1)) and s.counter_used and not u.counter_used_this_turn:
			rec["diffs"].append("%s 已反击 预测%s→实际%s" % [
				pre, _yn(s.counter_used), _yn(u.counter_used_this_turn)])
	# 地形/道具：键名照 BattleSnapshot.collect 的返回（obstacle/bomb/grave/gold/buff）
	rec["diffs"].append_array(_terrain_diffs("障碍耐久", sim.obstacles, after.get("obstacle", {}), true))
	rec["diffs"].append_array(_terrain_diffs("炸弹", sim.bombs, after.get("bomb", {}), false))
	rec["diffs"].append_array(_terrain_diffs("墓碑", sim.graves, after.get("grave", {}), false))
	rec["diffs"].append_array(_terrain_diffs("金矿", sim.gold_cells, after.get("gold", {}), false))
	rec["diffs"].append_array(_terrain_diffs("道具", sim.buff_cells, after.get("buff", {}), false))
	if (rec["diffs"] as Array).size() > 0:
		rec["verdict"] = "DIFF"
	return rec


## 地形/道具对比：障碍比"耐久值"，其它比"在不在"。
## 参数名用 field_name 而不是 name：name 会遮蔽 Node 基类属性（编辑器警告）。
func _terrain_diffs(field_name: String, pred: Dictionary, real: Dictionary, by_val: bool) -> Array:
	var out: Array = []
	var seen := {}
	for c in pred.keys():
		seen[c] = true
	for c in real.keys():
		seen[c] = true
	var list: Array = seen.keys()
	list.sort_custom(func(a: Vector2i, b: Vector2i):
		if a.x != b.x:
			return a.x < b.x
		return a.y < b.y)
	for c in list:
		var pv = pred.get(c, null)
		var rv = real.get(c, null)
		if by_val:
			var p := int(pv) if pv != null else 0
			var r := int(rv) if rv != null else 0
			if p != r:
				out.append("%s@%s 预测%d→实际%d" % [field_name, _cell(c), p, r])
		elif (pv == null) != (rv == null):
			out.append("%s@%s 预测%s→实际%s" % [
				field_name, _cell(c), ("有" if pv != null else "无"), ("有" if rv != null else "无")])
	return out


# ================= 真·执行一招 =================

## 按动作顺序执行并等动画播完（等待口径照搬 EnemyReplay.run：action_finished + 3s 兜底）。
## 返回 { status, moved, attacked, atk_obs, atk_idx }：status = done/timeout/changed；
## moved/attacked 表示"这一招里真的走位/出手了没有"，atk_idx 是本招攻击的目标下标
## （**回合开始的原下标**，_step 里换算到本步 view 下标后再交给 _compare）——
## 对拍时只比这几项，其余同名旗标（同回合别的英雄留下的）不比，否则会把上一招的痕迹误报成本招偏差。
##
## for_enemy：必须传 true —— 它是"这招是否按 AI/回放口径执行"的开关，**不是**"单位属不属于敌方"。
## src/Battle.gd 里只有 for_enemy=true 分支才 emit action_finished（移动见 3236、攻击见 3476），
## 传 false 会走 _continue_after_move/_after_player_action 的玩家输入分支、**整个回合都不发这个信号**，
## 于是 _await_action 每次都只能吃满 3s 超时（ACT_WALL_MS），同时 state 会被恢复成 PLAYER_INPUT。
## 与 RL/harness/对局.gd 的写法一致（它传 fn == ENEMY，但那边只替真实敌方驱动，等价于恒 true）。
##
## 已知取舍：联机（is_online）时该分支只把 state 置回 ENEMY_TURN、依然不发信号。
## 本检视器是单机沙箱（_setup 里 is_online=false），不涉及这条路径。
func _call_action(a: Dictionary, for_enemy: bool = true) -> Dictionary:
	var out := { "status": "done", "moved": false, "attacked": false, "atk_obs": false, "atk_idx": -1 }
	var u := _acting_ref()
	if u == null:
		out["status"] = "changed"    # 单位已离场：本回合剩余计划作废
		return out
	if _cur_idx >= 0 and _cur_idx < _plan_hero.size() and u.hero_id != String(_plan_hero[_cur_idx]):
		out["status"] = "changed"    # 下标已位移（有人阵亡出列）：宁可不打，也不打错人
		return out
	if a.has("move") and a["move"] != null:
		var mc: Vector2i = a["move"]
		if mc != u.cell:
			# ★ 走得到吗？先按**真实可达格**复查（`Battle._move_reachable` 就是玩家点选/AI 指令的
			#   同一个入口：内部含 `effective_move()`、障碍/墓碑阻挡、渗透豁免、大骑士冲锋自定义）。
			#   为什么必须查：模拟的 `_apply` 移动分支只按"距离 ≤ emove"截断，**没有**真实那套
			#   障碍绕行/不可停靠格/自定义移动范围（大骑士沿直线冲锋）——于是计划里"走不到"的落点
			#   在真实侧会被 `_do_move` 拦下或截断到最近可达格，而模拟当成走到了 → 位置族 DIFF。
			#   本 patch 只**如实标记**"这一招真实走不到"，不改 AI_Battle 的移动分支（那条会动搜索行为）。
			var reach: Dictionary = _battle._move_reachable(u)
			if not reach.has(mc):
				_log("[检视器] %s 的移动落点 %s 不在真实可达格内（emove=%d，可达 %d 格）→ 真实会截断/放弃，本招不按模拟结果对拍" % [
					_cur_hero(), str(mc), u.effective_move(), reach.size()])
				out["status"] = "changed"
				return out
			var r: String = await _await_action(func() -> void: _battle._do_move(u, mc, for_enemy))
			if r != "done":
				out["status"] = r
				return out
			out["moved"] = true
	if a.has("atk_obs"):
		var oc: Vector2i = a["atk_obs"]
		if _battle.obstacles.has(oc):
			if _truth(out["moved"]):
				await _sleep(STEP_GAP)
			var r2: String = await _await_action(func() -> void:
				_battle._do_attack_obstacle(u, oc, for_enemy))   # for_enemy 必须传：与移动/攻击同款，敌方回放靠它收 action_finished（2026-09-23 补）
			if r2 != "done":
				out["status"] = r2
				return out
			out["attacked"] = true
			out["atk_obs"] = true
	if a.has("atk") and a["atk"] != null and int(a["atk"]) >= 0:
		var ti := int(a["atk"])
		var refs: Array = _desc_keys     # 执行侧一律用回合开始的原下标
		out["atk_idx"] = ti              # 原下标（_step 会换算成 view 下标再拿去做对拍）
		# 目标可能已被释放（这份名单是回合开始时冻结的）：带类型的赋值会当场报
		# "Trying to assign invalid previously freed instance"，所以先无类型取值、逐层验，
		# 验不过就当"被真实规则拦下"，照下面的分支如实记下（不崩、也不伪造出手）。
		var raw_t = refs[ti] if ti >= 0 and ti < refs.size() else null
		var t: Unit = null
		if raw_t != null and is_instance_valid(raw_t) and raw_t is Unit:
			t = raw_t
		if t != null and t.alive and t.faction != u.faction \
				and is_instance_valid(u) and _battle._in_attack_range(u, t):
			if _truth(out["moved"]):
				await _sleep(STEP_GAP)
			var r3: String = await _await_action(func() -> void: _battle._do_attack(u, t, for_enemy))
			if r3 != "done":
				out["status"] = r3
				return out
			out["attacked"] = true
		else:
			# 计划里的攻击被真实规则拦下（目标已死/不在射程/被挡）：如实记下，不伪造"已出手"
			_log("[检视器] %s 的攻击被真实规则拦下（目标已死/不在射程/被挡视线）" % _cur_hero())
	return out


func _acting_ref() -> Unit:
	if _cur_idx < 0 or _cur_idx >= _desc_keys.size():
		return null
	var u = _desc_keys[_cur_idx]
	if u == null or not is_instance_valid(u) or not (u is Unit):
		return null
	return u as Unit


## 本招是谁（用于对拍标签与节奏判断）
func _cur_hero() -> String:
	return _hero_of(_desc_keys, _cur_idx)


## 下一招是不是换人（只用于节奏停顿）
func _next_hero() -> String:
	if _pi >= _plan.size():
		return ""
	return _hero_of(_desc_keys, int((_plan[_pi] as Dictionary).get("idx", -1)))


# ================= 面板 =================

func _build_panel() -> void:
	if DisplayServer.get_name() == "headless" and not _panecheck:
		# 无头模式没有真实显示服务：不建任何 UI（自检只要能跑对拍即可）
		_log("[检视器] headless：跳过面板，只跑对拍")
		return
	var layer := CanvasLayer.new()
	layer.layer = 128
	layer.name = "检视器UI"
	add_child(layer)
	_panel = Control.new()
	_panel.name = "检视器面板"
	_panel.position = Vector2(6, 6)
	_panel.size = Vector2(292, 760)
	_panel_expanded_size = _panel.size   # 记住展开态尺寸，供折叠后还原（见 _on_fold）
	layer.add_child(_panel)

	var bg := PanelContainer.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP   # 吃掉面板范围内的点击，别穿透到底下棋盘
	_panel.add_child(bg)

	# PanelContainer 会把**每一个**子节点都拉满自己的矩形，所以 bg 只能有一个子节点。
	# 曾经把标题行和滚动区并列挂在 bg 下 → 后加的标题行整块盖住滚动区，面板里的按钮全部点不到
	# （Container 默认 MOUSE_FILTER_PASS：事件只往上传给 bg，不会落到下面的兄弟节点；
	#  用户实机反馈"点不到里面的按键了"）。正确结构：bg → col(VBox) → [head, _scroll]。
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 0)
	bg.add_child(col)

	# 标题行必须留在 _scroll **外面**：_on_fold 折叠的正是 _scroll，若「折」按钮是它的后代，
	# 收起时按钮连同滚动区一起被隐藏 → 再也点不到（用户实机反馈"点了折之后就调不出来了"）。
	var head := HBoxContainer.new()
	head.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_child(head)
	var title := Label.new()
	title.text = "仿真检视器"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	_fold_btn = Button.new()
	_fold_btn.text = "折"
	_fold_btn.tooltip_text = "收起/展开面板（不挡棋盘）"
	_fold_btn.pressed.connect(_on_fold)
	head.add_child(_fold_btn)

	# 滚动区放在标题行**之后**加进 col，所以 col.get_child(0) 恒为 head（_fold_assert 依赖这点）。
	# size_flags_vertical=EXPAND_FILL：只吃标题行以下的剩余空间，不会和标题行重叠。
	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(_scroll)

	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 6)
	_scroll.add_child(box)

	var row_p := HBoxContainer.new()
	box.add_child(_line("一、我方控制（默认：手动原样）"))
	box.add_child(row_p)
	for i in 2:
		var pb := Button.new()
		pb.text = ["手动（原样）", "RL候选AI"][i]
		pb.toggle_mode = true
		pb.button_pressed = i == AI_MANUAL
		pb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		pb.add_theme_font_size_override("font_size", 12)
		pb.pressed.connect(_on_mode_pick.bind(i))
		row_p.add_child(pb)
		_mode_btns.append(pb)

	box.add_child(_line("二、敌方控制（默认：手动原样）"))
	var mg := HBoxContainer.new()
	box.add_child(mg)
	var names := ["手动（原样）", "RL候选AI", "原版困难档"]
	for i in 3:
		var b := Button.new()
		b.text = names[i]
		b.toggle_mode = true
		b.button_pressed = i == AI_MANUAL
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.add_theme_font_size_override("font_size", 12)
		b.pressed.connect(_on_emode_pick.bind(i))
		mg.add_child(b)
		_emode_btns.append(b)
	box.add_child(_line("想让新旧 AI 对打：我方选「RL候选AI」、敌方选「原版困难档」（或两边都选 RL候选AI）。"
		+ "两侧都选手动 = 和现在的自由部署完全一样，本场景不插手。"))

	box.add_child(_line("三、入口"))
	box.add_child(_line("入口固定为**英雄池选人界面**（QuickTest）：给自己和对方挑人后点「开始对局」。"
		+ "无需开关；无头测试可用命令行 --fixed3v3 / --selftest 直接进固定 3v3。"))
	# ★ 「自动循环」按钮（用户新需求）：放在"入口"这一节。面板挂在 CanvasLayer(128) 上、常驻，
	#   所以打对局时也看得见/点得到（随时能停）。无头验证入口 = `--autoloop`（同一回调）。
	var ar := HBoxContainer.new()
	box.add_child(ar)
	_auto_btn = Button.new()
	_auto_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_auto_btn.add_theme_font_size_override("font_size", 12)
	_auto_btn.tooltip_text = "点一下：每局双方各随机 5 人（10 人互不重复），一局打完自动回选人界面换一批再开，一直跑；再点一下停"
	_auto_btn.pressed.connect(_on_auto_toggle)
	ar.add_child(_auto_btn)
	_refresh_auto_btn()
	box.add_child(_line("自动循环：每局双方各随机 5 人（互不重复），打完自动回选人界面换一批再开；再点一下按钮即停"
		+ "（当前这局打完就不再开新局）。命令行等价入口：--autoloop［--autoloop-rounds N］。"))
	box.add_child(_line("只扫 DIFF 的话 **BEAM 可以调很小（例如 50）**：它只决定 AI 选哪一招，判定比的仍是"
		+ "「选中那招的预测 vs 真实」，所以不影响对拍结论；命令行用 --beam N 覆盖（--autoloop 默认 50）。"))

	box.add_child(_line("四、权重文件（只对 RL候选AI 生效）"))
	var wr := HBoxContainer.new()
	box.add_child(wr)
	_w_path_edit = LineEdit.new()
	_w_path_edit.text = "res://RL/weights/base.json"
	_w_path_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_w_path_edit.text_submitted.connect(func(_t: String): _apply_weights())
	wr.add_child(_w_path_edit)
	var browse := Button.new()
	browse.text = "选…"
	browse.pressed.connect(_on_browse)
	wr.add_child(browse)
	var quick := HBoxContainer.new()
	box.add_child(quick)
	var quick_items := [["base.json（困难档数值）", "res://RL/weights/base.json"],
			["候选默认（内置常量）", ""]]
	for item in quick_items:
		var qb := Button.new()
		qb.text = String(item[0])
		qb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		qb.add_theme_font_size_override("font_size", 11)
		qb.pressed.connect(_on_quick_weight.bind(String(item[1])))
		quick.add_child(qb)
	var beam_row := HBoxContainer.new()
	box.add_child(beam_row)
	beam_row.add_child(_tiny("BEAM"))
	_beam_spin = SpinBox.new()
	_beam_spin.min_value = 1
	_beam_spin.max_value = 8000
	_beam_spin.step = 1
	_beam_spin.value = 800
	_beam_spin.value_changed.connect(func(_v: float): _apply_weights())
	beam_row.add_child(_beam_spin)
	beam_row.add_child(_tiny("JITTER"))
	_jitter_spin = SpinBox.new()
	_jitter_spin.min_value = 0.0
	_jitter_spin.max_value = 50.0
	_jitter_spin.step = 0.5
	_jitter_spin.value = 0.0
	_jitter_spin.value_changed.connect(func(_v: float): _apply_weights())
	beam_row.add_child(_jitter_spin)
	_w_path_label = _line("")
	box.add_child(_w_path_label)

	box.add_child(_line("五、观感"))
	_speed_check = CheckBox.new()
	_speed_check.text = "加速 ×4（默认关，用眼睛看时别开）"
	_speed_check.button_pressed = false
	_speed_check.tooltip_text = "仅缩放演出/等待的时长（Engine.time_scale），不改任何规则与结算顺序。"
	_speed_check.toggled.connect(_on_speed_toggled)
	box.add_child(_speed_check)
	_speed_hint = _line("")
	box.add_child(_speed_hint)

	box.add_child(_line("五、状态"))
	_status_label = _line("")
	box.add_child(_status_label)

	box.add_child(_line("对拍已从画面移到**控制台**：每出一招打一个纯文本块（谁做了什么 / 预测 / 实际 / 判定 / 字段级），"
		+ "直接整段复制即可。机读证据（SIMCHK| 逐招行 + SUMMARY 汇总）写进 RL/reports/对拍_运行时.log，"
		+ "可用 --rtlog <路径> 改。控制台不会再出现其它自有输出。"))
	box.add_child(_line("自己出题：先在「手动」档用鼠标操作任意一方摆出局面（含障碍/道具/金矿格），"
		+ "再切到某个 AI；轮到那一方时它就会在你的题面上出手。"))

	_apply_weights()
	_refresh_status()


## 无头自检：证明「折/展」按钮可用，**并且面板里的控件没有被遮挡**。
## 用户两次实机反馈分别对应两个曾经真实存在的 bug：
##   ① "点了折之后就调不出来了" → _fold_btn 曾挂在 _scroll 内部（_on_fold 折叠的正是 _scroll），
##      收起时按钮连同滚动区一起被隐藏 → visible_in_tree=false。
##   ② "点不到里面的按键了"     → 标题行与滚动区被并列挂在 PanelContainer 下，容器把两个子节点
##      都拉满整块矩形，后加的标题行整块盖住滚动区（事件只往上传给父节点，不落兄弟节点）
##      → 按钮看得见但点不到。判据：head 与 _scroll 的全局矩形**必须不相交**。
## 注意：无头下视口仍有尺寸，且**不要求** DisplayServer 有真实窗口。
func _fold_assert() -> void:
	if _fold_btn == null:
		_log("[检视器] fold-check 1/2 visible_in_tree=false rect=(0,0,0,0) → FAIL（按钮不存在）")
		_log("[检视器] fold-check 2/2 visible_in_tree=false rect=(0,0,0,0) → FAIL（按钮不存在）")
		_log("[检视器] fold-check VERDICT=FAIL（无折叠按钮）")
		return
	# 标题行 = col 的第一个子节点（_build_panel 里 head 先于 _scroll 加入 col）
	var head_row: Node = null
	var col := _scroll.get_parent()
	if col != null and col.get_child_count() > 0:
		head_row = col.get_child(0)
	var vp := get_viewport().get_visible_rect()
	var no_cover := true      # 标题行没有压住滚动区（只在展开态判定：折叠态滚动区本来就不可见）
	var shrink_ok := true     # 折叠后面板矩形是否已缩到只剩标题行
	var restore_ok := true    # 展开后是否恢复成原尺寸
	var expanded_h := 0.0
	for k in 2:
		_on_fold()
		# 布局要等帧：刚改可见性/尺寸时合并最小尺寸与全局矩形可能还没算完（否则是"两个 0 矩形"的假绿）
		await get_tree().process_frame
		var r := _fold_btn.get_global_rect()
		var on_screen: bool = r.size.x > 0.0 and r.size.y > 0.0 \
				and r.intersects(Rect2(Vector2.ZERO, vp.size))
		var hr := Rect2()
		if head_row is Control:
			hr = (head_row as Control).get_global_rect()
		var sr := _scroll.get_global_rect()
		var pr := _panel.get_global_rect() if _panel != null else Rect2()
		# 展开态必须真的量到尺寸：全 0 说明容器还没跑布局（断言会退化成永远不相交的假绿）
		var laid_out: bool = sr.size.y > 0.0
		if _scroll.visible and (not laid_out or hr.intersects(sr)):
			no_cover = false
		var folded: bool = not _scroll.visible
		if folded:
			# 折叠态：面板高度必须≈标题行高度（容差 2px：样式边距/取整），且面板矩形下方不许再压到"棋盘点"
			var dh: float = absf(pr.size.y - hr.size.y)
			var below_y: float = pr.position.y + pr.size.y + 20.0
			var board_pt := Vector2(pr.position.x + 10.0, below_y)
			var covers_board: bool = pr.has_point(board_pt) or pr.size.y > (hr.size.y + 4.0)
			if dh > 6.0 or covers_board or pr.size.y <= 0.0 or pr.size.x <= 0.0:
				shrink_ok = false
			_log("[检视器] fold-check %d/2 折叠态 面板矩形=(%.0f,%.0f,%.0f,%.0f) 标题行=(%.0f,%.0f,%.0f,%.0f) 高差=%.1f 面板底+20 是否仍被面板覆盖=%s" % [
				k + 1, pr.position.x, pr.position.y, pr.size.x, pr.size.y,
				hr.position.x, hr.position.y, hr.size.x, hr.size.y, dh, str(covers_board)])
		else:
			# 展开态：高度应恢复成折叠前记下的值（或至少明显大于标题行）
			expanded_h = pr.size.y
			if pr.size.y <= hr.size.y + 4.0:
				restore_ok = false
			_log("[检视器] fold-check %d/2 展开态 面板矩形=(%.0f,%.0f,%.0f,%.0f)（已还原，应远高于标题行 %.0f）" % [
				k + 1, pr.position.x, pr.position.y, pr.size.x, pr.size.y, hr.size.y])
		_log("[检视器] fold-check %d/2 folded=%s visible_in_tree=%s rect=(%.0f,%.0f,%.0f,%.0f) on_screen=%s head=(%.0f,%.0f,%.0f,%.0f) scroll=(%.0f,%.0f,%.0f,%.0f) 布局=%s 遮挡=%s" % [
			k + 1, str(folded), str(_fold_btn.is_visible_in_tree()),
			r.position.x, r.position.y, r.size.x, r.size.y, str(on_screen),
			hr.position.x, hr.position.y, hr.size.x, hr.size.y,
			sr.position.x, sr.position.y, sr.size.x, sr.size.y,
			str(laid_out), str(_scroll.visible and hr.intersects(sr))])
	_log("[检视器] fold-check 恢复尺寸=%.0f（折叠前记住的展开高度=%.0f）" % [
		expanded_h, _panel_expanded_size.y])
	_log("[检视器] fold-check VERDICT=%s（按钮 visible_in_tree=true 且在视口内；展开态滚动区有高度且不被标题行遮挡；折叠后面板缩到只剩标题行、不再覆盖棋盘；展开后尺寸还原）" % [
		"PASS" if (_fold_btn.is_visible_in_tree() and no_cover and shrink_ok and restore_ok) else "FAIL"])


## 面板上的"权重 / BEAM / JITTER"是否真的被用上。
## 只有 RL候选AI（fork）有 set_weights()/w_beam/w_jitter；「原版困难档」是 src/BattleAI.gd 的
## 逐字节副本，没有这些接口；「手动」档压根不建 AI 模块。两侧**任一**用到 RL 候选，这组控件就有意义
## （两边都用 RL 时共用同一份权重与 BEAM/JITTER，本期不做每侧一份）。
func _weights_in_use() -> bool:
	return _mode == AI_FORK or _emode == AI_FORK


## 折叠/展开。
## 关键：**折叠时必须把面板矩形缩到只剩标题行**。
## 只藏 `_scroll` 是不够的——`_panel`（固定 292×760）与 `bg`（PanelContainer + FULL_RECT）
## 默认都是 mouse_filter = STOP，折叠后仍占着那一整块矩形，于是棋盘上这片区域的点击被吃掉
## （用户实机："点折之后还是有个背景挡住棋盘"——不是看得见的背景，是看不见的挡板）。
## 缩法：`_scroll` 隐藏后，容器的合并最小高度自然只剩 head 那一行（含 PanelContainer 样式边距），
## 直接采用它；展开时还原成折叠前记住的尺寸。
func _on_fold() -> void:
	_scroll.visible = not _scroll.visible
	if _panel != null:
		if _scroll.visible:
			# 展开：还原折叠前记下的尺寸（没有记过就用当前合并最小尺寸兜底）
			var restore: Vector2 = _panel_expanded_size
			if restore.y <= 0.0:
				restore = Vector2(_panel.size.x, _panel.get_combined_minimum_size().y)
			_panel.size = restore
		else:
			# 折叠：先记住展开态尺寸，再缩到"只剩标题行"。
			# 注意：**不能**用 `_panel.get_combined_minimum_size().y` —— `_scroll` 一隐藏，
			# 容器的合并最小高度会变成 0，面板就缩成 292×0（标题行跟着不可见、按钮也点不到）。
			# 实测值：折叠态 combined_min=(292, 0)，而 head 的全局矩形高 37。
			# 所以高度取"标题行自己的高度 + 容器 separation"，再兜一个下限。
			if _panel.size.y > 0.0:
				_panel_expanded_size = _panel.size
			var col_nd := _scroll.get_parent()
			var head_nd: Node = col_nd.get_child(0) if col_nd != null and col_nd.get_child_count() > 0 else null
			var h_row: float = 0.0
			if head_nd is Control:
				h_row = (head_nd as Control).size.y
			if h_row <= 0.0 and head_nd is Control:
				h_row = (head_nd as Control).get_combined_minimum_size().y
			if h_row <= 0.0:
				h_row = 37.0          # 兜底：实测标题行高
			var sep: float = 0.0
			if col_nd is BoxContainer:
				sep = float((col_nd as BoxContainer).get_theme_constant("separation"))
			_panel.size = Vector2(_panel.size.x, h_row + sep)
	_refresh_fold_btn()


## 「折/展」按钮文案：按钮在 _scroll 外面（见 _build_panel），所以折叠后它自己仍在，
## 这里只负责把文字切回「展」，提示"再点一下就能展开"。
func _refresh_fold_btn() -> void:
	if _fold_btn == null or _scroll == null:
		return
	_fold_btn.text = "展" if not _scroll.visible else "折"


func _line(t: String) -> Label:
	var l := Label.new()
	l.text = t
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_font_size_override("font_size", 12)
	l.custom_minimum_size = Vector2(250, 0)
	return l


func _tiny(t: String) -> Label:
	var l := Label.new()
	l.text = t
	l.add_theme_font_size_override("font_size", 11)
	return l


func _on_mode_pick(i: int) -> void:
	_apply_mode(i)


func _on_emode_pick(i: int) -> void:
	_apply_emode(i)


## 我方控制档位（0=手动 / 1=RL候选AI）
func _apply_mode(i: int) -> void:
	_mode = i
	for k in _mode_btns.size():
		(_mode_btns[k] as Button).button_pressed = k == i
	_ai = null                  # 换档：下次决策重建模块（权重/实现都可能不同）
	_ai_busy = false
	_sync_dual_control()        # 档位变了 → 替补该由谁负责也跟着变（见 _sync_dual_control）
	_refresh_weight_controls()  # 档位决定"权重/BEAM/JITTER"是否真的生效（原版/手动档要禁用+明说）
	_refresh_status()


## 敌方控制档位（0=手动 / 1=RL候选AI / 2=原版困难档）
func _apply_emode(i: int) -> void:
	_emode = i
	for k in _emode_btns.size():
		(_emode_btns[k] as Button).button_pressed = k == i
	_ai = null
	_ai_busy = false
	_sync_dual_control()
	_refresh_weight_controls()
	_refresh_status()


## 加速开关：只改 Engine.time_scale（观感），不碰任何规则/结算顺序。
func _on_speed_toggled(on: bool) -> void:
	Engine.time_scale = 4.0 if on else 1.0
	_refresh_speed_hint()
	_log("[检视器] 演出加速 %s（Engine.time_scale=%.1f）" % ["开" if on else "关", Engine.time_scale])


func _refresh_speed_hint() -> void:
	if _speed_hint == null:
		return
	var both_ai: bool = _mode != AI_MANUAL and _emode != AI_MANUAL
	if _speed_check != null and _speed_check.button_pressed:
		_speed_hint.text = "当前：加速 ×%.0f（演出变快，规则不受影响）" % Engine.time_scale
	elif both_ai:
		_speed_hint.text = "两侧都由 AI 出手、人只需旁观时可以开加速；要逐招看画面时保持关闭。"
	else:
		_speed_hint.text = "当前：正常速度（×1）"


func _on_browse() -> void:
	var dlg := FileDialog.new()
	dlg.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	dlg.access = FileDialog.ACCESS_RESOURCES
	dlg.filters = PackedStringArray(["*.json ; 权重 JSON"])
	dlg.size = Vector2i(700, 500)
	dlg.file_selected.connect(func(p: String):
		_w_path_edit.text = p
		_apply_weights())
	_panel.add_child(dlg)
	dlg.popup_centered()


func _on_quick_weight(p: String) -> void:
	_w_path_edit.text = p
	_apply_weights()


## 立刻按面板上的权重设置重建 AI（下一次决策生效，不用重开一局）。
## 计时：这里只做"读 JSON + 刷新文案"，不建 AI 实例（决策时才建）——用户反馈"每次切 RL 都会卡一下"，
## 需要按段量出来才能判断是这一步还是那一次同步搜索。
func _apply_weights() -> void:
	var t0 := Time.get_ticks_msec()
	_ai = null
	var p := _weight_path()
	var t_rd := Time.get_ticks_msec()
	var n := _load_weights(p).size()
	var t_load := Time.get_ticks_msec()
	var txt := ""
	if not _weights_in_use():
		# 两侧都没用到 RL 候选（手动 / 原版困难档）：权重、BEAM、JITTER 一个都不会被用上。
		# 这里必须明说，不能沿用"权重：xxx（N 项）"那种看起来已生效的文案（原来的静默假象）。
		if _emode == AI_ORIG or _mode == AI_ORIG:
			txt = "当前档位不使用权重（「原版困难档」是 src/BattleAI.gd 的逐字节副本）：权重文件 / BEAM / JITTER 均不生效"
		else:
			txt = "两侧都是手动档、不建 AI 模块：权重文件 / BEAM / JITTER 均不生效"
	else:
		var warn := ""
		if p != "" and not FileAccess.file_exists(p):
			warn = "  ⚠ 文件不存在，将用内置常量"
		var who := []
		if _mode == AI_FORK:
			who.append("我方")
		if _emode == AI_FORK:
			who.append("敌方")
		txt = "权重：%s（%d 项）%s  BEAM=%d JITTER=%.1f  生效于：%s" % [
			p if p != "" else "（无 / 内置常量）", n, warn, _beam_val(), _jitter_val(),
			"、".join(who)]
	if _w_path_label != null:
		_w_path_label.text = txt
	_log("[检视器] " + txt)
	_refresh_weight_controls()
	var t_end := Time.get_ticks_msec()
	_log("[检视器] [耗时] 切换档位/权重：总计 %dms（读权重 JSON %dms，其余 %dms；不建 AI 实例）" % [
		t_end - t0, t_load - t_rd, t_end - t_load])


## 按当前档位禁用/启用"权重文件 + BEAM + JITTER"这一组控件，并刷新说明文字。
## 禁用而不是隐藏：让用户看得见"这些东西存在、但在当前档位下不生效"。
## （无头自检不建面板，这些控件为 null，全部跳过——见 _build_panel 开头的 headless 分支。）
func _refresh_weight_controls() -> void:
	var use := _weights_in_use()
	var tip := "" if use else "当前两侧档位都不使用权重"
	if _w_path_edit != null:
		_w_path_edit.editable = use
		_w_path_edit.tooltip_text = tip
	if _beam_spin != null:
		_beam_spin.editable = use
		_beam_spin.tooltip_text = tip
	if _jitter_spin != null:
		_jitter_spin.editable = use
		_jitter_spin.tooltip_text = tip


## 面板参数取值：无头模式下面板不存在，用内置默认（= fork 的困难档口径）。
## `--beam N` 优先（无头扫 DIFF 用；`--autoloop` 不给时自动取 AUTO_LOOP_BEAM）。
func _beam_val() -> int:
	if _beam_override > 0:
		return _beam_override
	return int(_beam_spin.value) if _beam_spin != null else 800


func _jitter_val() -> float:
	return float(_jitter_spin.value) if _jitter_spin != null else 0.0


func _weight_path() -> String:
	# `--weights` 优先（无头自检唯一能指定权重文件的路子）；没给才退回面板输入框 / 默认 base.json。
	if _weights_cli != "":
		return _weights_cli
	return _w_path_edit.text.strip_edges() if _w_path_edit != null else "res://RL/weights/base.json"


func _load_weights(path: String) -> Dictionary:
	var out := {}
	if path == "" or not FileAccess.file_exists(path):
		return out
	# 带缓存（键 = 路径 + 修改时间 + 长度）：同一文件反复切档位不必反复读盘+解析，
	# 文件真被改了会自动失效重读，行为不变。
	var mt := FileAccess.get_modified_time(path)
	var sz := 0
	var fsz := FileAccess.open(path, FileAccess.READ)
	if fsz != null:
		sz = fsz.get_length()
		fsz.close()
	var ckey := "%s|%d|%d" % [path, mt, sz]
	if _w_cache_key == ckey:
		return _w_cache
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return out
	var txt := f.get_as_text()
	f.close()
	var d = JSON.parse_string(txt)
	if typeof(d) != TYPE_DICTIONARY:
		return out
	# 平铺 JSON：键就是 KILL_BONUS / BEAM / …；"_" 开头是说明字段，跳过
	for k in (d as Dictionary).keys():
		var key := String(k)
		if key.begins_with("_"):
			continue
		out[key] = d[key]
	_w_cache_key = ckey
	_w_cache = out
	return out


func _refresh_status() -> void:
	if _status_label == null or not _battle_alive():
		return
	var side := _side_txt(GameState.active_side)
	var dep := "" if _deployed else "  ·  （选人中）"
	var tail := _state_hint(int(_battle.state))
	if _watch_locked:
		tail = "  ·  观战模式（AI 接管）：%s回合不接玩家操作" % side
	elif _search_active:
		# 搜索在后台线程跑：这里每帧刷新"已 X ms"，既是给用户看的状态，也是"主线程仍活着"的证据
		tail = "  ·  AI 思考中…（%s/%s，已 %d ms）" % [
			_side_txt(_search_side), _ai_name(_search_mode),
			Time.get_ticks_msec() - _search_start_ms]
	elif not _deployed:
		# ★ 部署阶段：状态行必须说清"轮到谁 + 那方档位 + 在等什么"（用户就靠这行判断是不是卡住了）。
		# 实测困惑：用户只把"我方"设成 AI，敌方仍是手动 → 部署是**双方交替**的，
		# 轮到手动那一手没人点 → 我方的 AI 也永远轮不到 → 看起来像"我方 RL 也不上人"。
		tail = "\n" + _deploy_status_text()
	_status_label.text = "构建=%s · 回合 %d · 行动方 %s%s · 我方=%s，敌方=%s%s" % [
		_build_tag, GameState.round_number, side, dep,
		_ai_name(_mode), _ai_name(_emode), tail]
	_refresh_speed_hint()


## 部署阶段的状态文案：**轮到哪一方 + 该方档位 + 在等什么**（手动那方必须明写"等你点"）。
func _deploy_status_text() -> String:
	if _battle == null or not is_instance_valid(_battle):
		return "部署中：战场未就绪"
	var dside := int(_battle._deploy_side)          # 0=我方轮 / 1=敌方轮
	var dmode := _mode if dside == 0 else _emode
	var n_p := _battle.player_deployed.size()
	var n_e := _battle.enemy_deployed.size()
	var in_place := int(_battle.state) == int(Battle.State.PLACE_DEPLOY)
	var wait_txt := ""
	if dmode == AI_MANUAL:
		wait_txt = "正在选落点·**等你点出生格**" if in_place else "**等你点**它的英雄卡 → 出生格"
	else:
		wait_txt = "工具落位中…" if in_place else "工具自动上人中…"
	var other_txt := ""
	if dside == 0:
		other_txt = "｜敌方（%s，已上 %d/3）" % [_ai_name(_emode), n_e]
	else:
		other_txt = "｜我方（%s，已上 %d/3）" % [_ai_name(_mode), n_p]
	return "部署中：轮到%s（%s，已上 %d/3）%s %s%s" % [
		_side_txt(dside), _ai_name(dmode), n_p if dside == 0 else n_e,
		other_txt, wait_txt, _deploy_wait_hint(dside, dmode)]


## 部署等真人超过 10 秒 → 给一次提示（状态行 + 运行时日志各一条），到 60 秒游戏会自己随机补人。
## **不替玩家点**（用户明确要求手动那方自己打），只是把"为什么卡着"说清楚。
func _deploy_wait_hint(dside: int, dmode: int) -> String:
	var key := "%d|%d" % [dside, int(_battle.state)]
	if dmode != AI_MANUAL:
		_deploy_wait_key = ""
		_deploy_wait_ms = 0
		return ""
	if key != _deploy_wait_key:
		_deploy_wait_key = key
		_deploy_wait_ms = Time.get_ticks_msec()
		_deploy_wait_logged = false
		return ""
	var secs := int(float(Time.get_ticks_msec() - _deploy_wait_ms) / 1000.0)   # 等价写法：不触发 INTEGER_DIVISION，数值不变
	if secs < 10:
		return ""
	if not _deploy_wait_logged:
		_deploy_wait_logged = true
		_log("[部署] %s档在等你点，已等 %d 秒：请点它的英雄卡 → 出生格；否则游戏的 60 秒部署预算耗尽后会**随机补人**" % [
			_side_txt(dside), secs])
	return "  ·  已等 %d 秒：另一方是手动档，请点它的英雄卡 → 出生格（否则 60 秒后自动随机补人）" % secs


func _state_hint(st: int) -> String:
	match st:
		Battle.State.PLAYER_INPUT:
			return "  ·  可操作"
		Battle.State.ANIMATING:
			return "  ·  演出中"
		Battle.State.DEPLOY, Battle.State.PLACE_DEPLOY:
			return "  ·  部署选人"
		Battle.State.SUBSTITUTING, Battle.State.PLACE_SUB:
			return "  ·  替补流程"
	return ""


## 档位名。i 传 -1 = 取敌方档位（历史上 _ai_name() 无参就是敌方口径，保留兼容）。
func _ai_name(i: int = -1) -> String:
	var m: int = _emode if i < 0 else i
	if m == AI_FORK:
		return "RL候选AI"
	if m == AI_ORIG:
		return "原版困难档"
	return "手动（原样）"


## 画面输出已按用户要求整块移除（对拍改到控制台）。**保留这个调用点与空实现**：
## 一是调用顺序/时机不变，二是以后若要恢复画面输出只需在这里补。
## 参数加下划线前缀表示"有意不使用"，避免编辑器报 UNUSED_PARAMETER。
func _show(_rec: Dictionary) -> void:
	pass


func _print_chk(rec: Dictionary) -> void:
	# ★ 顺序要紧：**先**算好块内容（`_report_lines` 会把细分判定写回 rec["verdict"]，如 TIMING），
	# **再**打机读行。反过来的话 SIMCHK 行里的 verdict 会与块内文字不一致
	# （踩过：TIMING 块在机读行里仍写成 DIFF，两边对不上账）。
	var rlines: Array = _report_lines(rec)
	_last_verdict = String(rec["verdict"])   # 供"盘面分叉重算"判断（见 _drive_turn）
	_last_diffs = (rec.get("diffs", []) as Array).duplicate()   # 重算归因：触发它的是哪几条差异
	# 机器可读证据进文件（每招一行 + SUMMARY 都在那里）
	var v := String(rec["verdict"])
	var short: Array = []
	for d in (rec["diffs"] as Array):
		short.append(String(d).replace(" ", "").replace("预测", "p=").replace("→实际", ">a="))
	var tail := "|".join(short) if short.size() > 0 else "-"
	if v == "NOPRED":
		tail = String(rec["note"]).replace(" ", "")
	_log("SIMCHK|n=%d|u=%s|act=%s|verdict=%s|diffs=%s" % [
		int(rec["n"]), String(rec["hero"]), String(rec["act"]), v, tail])
	_chk_count += 1
	# 控制台：只打对拍块（用户要复制），纯文本、无颜色、块间空行。
	# **逐行**打印（而不是先拼成一大串再打）：万一某一行触发崩溃，控制台最后出现的那一行
	# 就是定位线索；也避免大字符串一次性构造带来的额外风险。
	# ★ 同一份内容**镜像进本局日志文件**（控制台一个字都不加、分层不动）：
	#   上层要能直接从 `RL/reports/rt/…log` 复核 DIFF 原文，不必每次让人贴控制台。
	for line in rlines:
		print(String(line))
		_log(String(line))
	_log("")
	print("")


## 组装对拍块：① 谁做了什么（动作类型**如实照抄**，不把 move 写成攻击）
## ② 预测发生什么 ③ 实际发生什么 ④ 判定 ⑤ 字段级原始差异
## 后果一律来自"前后快照逐单位/逐格对比"，所以 AOE/连锁/光环/点燃障碍都会逐个列全，
## 不会因为动作字典里只写了一个目标而漏掉其它被波及的单位。
func _report_lines(rec: Dictionary) -> Array:
	var n := int(rec["n"])
	var pre: Dictionary = rec.get("pre", {})
	var post: Dictionary = rec.get("post", {})
	var act_kind := String(rec["act"])
	var who := String(rec["hero"])
	var moves: Array = rec.get("moves", [])
	# 先算好动作描述，避免把多参数函数调用塞进 %[...] 里（那种写法在某些版本上会解析出错）
	var act_txt := _act_desc(act_kind, moves, pre, rec)
	var head := "[对拍] #%d 第%d回合·%s  %s  %s" % [
		n, int(rec.get("round", 0)), String(rec.get("side", "")), who, act_txt]
	var lines: Array = [head]
	# 预测侧 = 出招前 → 预测局面；实际侧 = 出招前 → 出招后。两侧共用同一份"前"，口径一致。
	# 逐段 append 后**立刻**返回给调用方逐行打印（见 _print_chk）：万一某一段触发崩溃，
	# 控制台上"最后打印成功的那一行"就能指出崩在哪个阶段。
	var pred_lines: Array = _dir_lines("预测", pre.get("pred", {}), post.get("pred", {}))
	var real_lines: Array = _dir_lines("实际", pre.get("real", {}), post.get("real", {}))
	lines.append_array(pred_lines)
	lines.append_array(real_lines)
	# ★ 旗标行（只在"出手单位"与"两侧旗标不一致的单位"上列；沿用字段级原名；无差异不打）
	var flagline := _flag_line(rec)
	if flagline != "":
		lines.append(flagline)
	# 判定分三类（裁决口径）：
	#   DIFF      = 字段级查出真差异（绝对状态确实不同）
	#   过程差异  = 可读层有差异、但**就地复核绝对状态一致**（纯时序/路径不同，如墓碑晚 0.3s 立）
	#   MATCH     = 两侧逐项一致
	var diffs: Array = rec["diffs"]
	var verdict := String(rec["verdict"])
	var pred_ok := bool(pre.get("pred", {}).get("allkeys", false))
	if OS.has_environment("ZB_PINDBG"):
		_pin_diag(rec.get("sim", null), rec)   # 【临时插桩 · env 门控】诊断"远程被贴身"两侧差异
	# 先把"可读层有差异、字段层为空"的项逐条复核绝对状态定性（写进 rec）
	rec["_lines"] = lines
	_classify_process_diffs(rec)
	var missed: Array = rec.get("field_missed", [])
	var process: Array = rec.get("process_diffs", [])
	rec["turn_span"] = _turn_span_reasons(rec)
	var span: Array = rec["turn_span"]
	if verdict == "NOPRED" or not pred_ok:
		var why := String(rec.get("note", ""))
		lines.append("  判定 NOPRED：%s" % (why if why != "" else "本招无法预测（预测侧 sim 不可用）"))
	elif span.size() > 0:
		# 场外变化：本招前后两个采样点之间发生了"动作之外"的盘面变动（替补登场/延迟给盾…），
		# 两边的可比性被破坏 → 标"不可比"，**不计入 DIFF**，但内容照旧如实展示（用户仍看得到）。
		lines.append("  判定 不可比（本招期间有场外变化：%s）" % "；".join(span))
	elif diffs.size() > 0 and _timing_sampling_only(diffs, rec):
		# ★ TIMING（带硬闸门，见 _timing_sampling_only）：
		#   全块差异每一条都是"采样时机差"——墓碑写入时机（真实 0.3s 淡出后才立碑、模拟立刻立碑），
		#   或"存活"差异且该单位**两侧绝对 hp 都 ≤0**（真延迟阵亡窗口）。
		# ⚠️ 绝不降级"模拟多杀人"：真实 hp>0 而模拟 hp≤0 时 `_timing_sampling_only` 直接 false，
		#    该块照旧判 DIFF 并触发重算（用户那一招就是这种情况）。
		rec["verdict"] = "TIMING"
		lines.append("  判定 TIMING（已知采样时机差：墓碑写入时机 / 延迟阵亡窗口；不计入 DIFF）")
	elif diffs.size() > 0:
		lines.append("  判定 DIFF：%s" % "；".join(diffs))
	elif _detail_only(pred_lines) == _detail_only(real_lines):
		lines.append("  判定 MATCH（两侧逐项一致）")
	elif missed.size() > 0:
		lines.append("  判定 DIFF（字段层漏报）：%s" % "；".join(missed))
	elif process.size() > 0:
		# 只有过程差异：保留这些行（诚实展示），但判定写 MATCH 并标注"仅过程差异"，不计入 DIFF
		lines.append("  判定 MATCH（绝对状态一致；仅过程差异：%s）" % "；".join(process))
	else:
		# 两侧明细条数不同、但逐条复核后既非字段漏报也无过程差异（例如"无变化"标记行）：
		# 不硬凑理由，按 MATCH 收尾并说明"差异仅为无变化标记"
		lines.append("  判定 MATCH（绝对状态一致；差异仅为「无变化」标记行）")
	var diff_txt := "-" if diffs.size() == 0 else str(diffs)
	lines.append("  字段级：diffs=%s" % diff_txt)
	# 自检：可读层列出的差异 与 字段层 diffs 必须一致；不一致只进运行时文件（不进控制台）
	_check_readable_vs_field(rec, lines)
	return lines


## TIMING 判据（带**硬闸门**）：全块差异**每一条**都必须是"采样时机差"才成立：
##   ① `墓碑@…`（真实 0.3s 淡出后才立碑、模拟立刻立碑）；或
##   ② `存活 预测X→实际Y`（延迟阵亡窗口）——**且硬闸门**：该单位**两侧绝对 hp 都 ≤0**。
##   ★ 真实侧 hp > 0 而模拟侧 hp ≤0 = **模拟多杀了人**，必须照旧判 DIFF 并允许触发重算。
##     用户那一招（末日 #4：模拟把两个 13 血单位算成 0/阵亡、真实只掉到 9）正是这种 → 绝不降级。
## 混入任何其它项（血量/位置/状态/道具/障碍/炸弹/金矿/单位数…）立即返回 false。
func _timing_sampling_only(diffs: Array, rec: Dictionary) -> bool:
	if diffs.size() == 0:
		return false
	var abs_pred: Dictionary = rec.get("post", {}).get("pred_abs", {})
	var abs_real: Dictionary = rec.get("post", {}).get("real_abs", {})
	for d in diffs:
		var s := String(d)
		if s.begins_with("墓碑"):
			continue
		if s.contains("存活") and _alive_diff_is_delayed_death(s, abs_pred, abs_real):
			continue
		return false
	return true


## "存活"差异是否落在**延迟阵亡窗口**（两侧绝对 hp 都 ≤0）→ 是才算采样时机差。
## 拿不到绝对状态一律返回 false（宁可按真差异报，也不静默降级）。
## 关键断言：`h1 <= 0 and h2 <= 0`；真实 hp>0 而模拟 hp≤0 必须 false（那是"模拟多杀"）。
func _alive_diff_is_delayed_death(item: String, abs_pred: Dictionary, abs_real: Dictionary) -> bool:
	var sp := item.find(" ")
	var who := item.substr(0, sp) if sp > 0 else item
	var d1 = abs_pred.get(who, null)
	var d2 = abs_real.get(who, null)
	if d1 == null or d2 == null:
		return false
	var h1 := int((d1 as Dictionary).get("hp", 1))
	var h2 := int((d2 as Dictionary).get("hp", 1))
	return h1 <= 0 and h2 <= 0


## 取证（`--gate-check`）：用**用户那一招的真实数据**离线自检硬闸门与分桶，不需要开战场。
## 数据来源 `RL/reports/rt/对拍_运行时_0913_012311.log` 第 2 回合末日的 #1 块：
##   预测：烛火/共鸣者 HP 13→0 阵亡 + 立三座碑；实际：两者 HP 13→**9**（存活）+ 无碑。
func _run_gate_check() -> void:
	var diffs: Array = [
		"烛火(hero_17)#1 存活 预测否→实际是", "共鸣者(hero_47)#5 存活 预测否→实际是",
		"墓碑@(0,3) 预测有→实际无", "墓碑@(0,4) 预测有→实际无", "墓碑@(1,3) 预测有→实际无",
	]
	var abs_pred := {
		"grave": { Vector2i(0, 3): true, Vector2i(0, 4): true, Vector2i(1, 3): true },
		"units": [], "obstacle": {}, "bomb": {}, "gold": {}, "buff": {},
		"烛火(hero_17)#1": { "hp": 0, "alive": false, "cell": Vector2i(0, 3) },
		"共鸣者(hero_47)#5": { "hp": 0, "alive": false, "cell": Vector2i(1, 3) },
	}
	var abs_real := {
		"grave": {},
		"units": [], "obstacle": {}, "bomb": {}, "gold": {}, "buff": {},
		"烛火(hero_17)#1": { "hp": 9, "alive": true, "cell": Vector2i(0, 3) },
		"共鸣者(hero_47)#5": { "hp": 9, "alive": true, "cell": Vector2i(1, 3) },
	}
	var fake := { "post": { "pred_abs": abs_pred, "real_abs": abs_real } }
	var timing: bool = _timing_sampling_only(diffs, fake)
	_say_console("[闸门自检] 用户那一招 5 项：墓碑×3=采样时机候选；存活×2（模拟 hp=0 / 真实 hp=9）→ 必须留 DIFF")
	_say_console("[闸门自检] _timing_sampling_only=%s（期望 false：模拟多杀了人，不许降级）%s" % [
		str(timing), "OK" if not timing else "!! 闸门失效 !!"])
	var bucket_ok := true
	for d in diffs:
		if not _abs_state_differs(fake, String(d)):
			bucket_ok = false
	_say_console("[闸门自检] 分桶：5 项 _abs_state_differs 全 true=%s（期望 true → 全部进 field_confirmed，不进 process_diffs）" % str(bucket_ok))
	var ok_diffs: Array = ["烛火(hero_17)#1 存活 预测否→实际是", "墓碑@(0,3) 预测有→实际无"]
	var abs_pred2 := { "烛火(hero_17)#1": { "hp": 0, "alive": false } }
	var abs_real2 := { "烛火(hero_17)#1": { "hp": 0, "alive": true } }
	var timing2: bool = _timing_sampling_only(ok_diffs, { "post": { "pred_abs": abs_pred2, "real_abs": abs_real2 } })
	_say_console("[闸门自检] 反向对照（两侧 hp 都 0 + 纯墓碑）=%s（期望 true → 判 TIMING）%s" % [
		str(timing2), "OK" if timing2 else "!! 该判 TIMING 却没判 !!"])
	var all_ok := (not timing) and bucket_ok and timing2
	_say_console("[闸门自检] VERDICT=%s" % ("PASS" if all_ok else "FAIL"))
	get_tree().quit(0 if all_ok else 1)


## 旧名保留（注释里仍会引用）：纯墓碑判据——**已被带硬闸门的 `_timing_sampling_only` 取代**。
func _timing_grave_only(diffs: Array) -> bool:
	if diffs.size() == 0:
		return false
	for d in diffs:
		if not String(d).begins_with("墓碑"):
			return false
	return true


## 取" 预测 | xxx" 这类行的"xxx"部分（去掉侧别前缀），用于两侧逐条比对
func _detail_only(lits: Array) -> Array:
	var out: Array = []
	for l in lits:
		var s := "%s" % l
		var i := s.find(" | ")
		out.append(s.substr(i + 3) if i >= 0 else s.strip_edges())
	return out


## 两侧第一处不同：返回便于人读的理由（预测什么 / 实际什么）
func _first_mismatch(a: Array, b: Array) -> Array:
	var da := _detail_only(a)
	var db := _detail_only(b)
	for i in maxi(da.size(), db.size()):
		var x := "%s" % (da[i] if i < da.size() else "（无）")
		var y := "%s" % (db[i] if i < db.size() else "（无）")
		if x != y:
			return ["预测 %s / 实际 %s" % [x, y]]
	return ["两侧存在差异（明细见上）"]


## 可读层/字段层一致性自检（结果写运行时文件，不污染控制台）。**两个方向都保留**，
## 但按裁决调整语义：真正要报的告警只有"**字段层漏报**（绝对状态确实不同）"这一种。
##
## 为什么两层会不一致（裁决解释，写在这里免得后人再困惑）：
##   · 字段层（_compare）比的是**绝对状态**：模拟终局盘面 vs 真实终局盘面；
##   · 可读层比的是**前后增量（delta）**：预测 pre→post 的变化 vs 真实 pre→post 的变化。
## 墓碑就是典型：模拟早一步把它算死了、碑早就在（绝对状态两边一致 → 字段层无差异），
## 而真实是 0.3s 淡出后才立碑（增量上"现在才出现" → 可读层 delta 有差异）。两条都对，问题不同。
## 但**不能简单把反方向降级**：道具被拾取那条也是"可读层有、字段层空"，而它是**真模拟缺口**
## （模拟盘面上道具还在）。所以这里对每条"可读层有差异、字段层为空"的项**就地复核绝对状态**，
## 分开定性（见 _recheck_abs）。判定与计数由 _classify_process_diffs 落进 rec。
func _check_readable_vs_field(rec: Dictionary, lines: Array) -> void:
	_log("[一致性] #%d 绝对状态复核：%s" % [
		int(rec["n"]), "字段层漏报 %s" % str(rec.get("field_missed", [])) if (rec.get("field_missed", []) as Array).size() > 0 \
		else "无（可读层与字段层一致）"])
	if (rec.get("process_diffs", []) as Array).size() > 0:
		_log("[一致性] #%d 过程差异（绝对状态一致，仅时序/路径不同，不计入 DIFF）：%s" % [
			int(rec["n"]), str(rec.get("process_diffs", []))])
	# ★ 方向③（本次新增）：可读层某侧的"地形/道具"delta 说有变化，而字段级绝对状态为空
	# → 两侧的 delta 与绝对状态**不自洽**（用户贴过这种三方矛盾的块：预测侧写"无变化"、
	# 实际侧写"炸弹(1,2)（出现）"、字段级却 `diffs=-`）。根因是预测侧那份快照的地形字典
	# 与 sim 的活字典同引用 → `_apply` 一改，"前"那份跟着变 → delta 恒空（已在 `_snap_sim` 修）。
	# 这条断言是防回归：以后谁再把引用漏回去，日志里会立刻出现。
	if (rec.get("diffs", []) as Array).size() == 0:
		var terrain_delta := false
		for l in lines:
			var s := String(l)
			var is_terrain: bool = s.begins_with("  预测 | 地形/道具") or s.begins_with("  实际 | 地形/道具")
			if is_terrain and not s.contains("无变化"):
				terrain_delta = true
				break
		if terrain_delta:
			_warn("可读层 delta 与绝对状态不一致：可读层列出了地形/道具变化、但字段级绝对状态为空（#%d %s）" % [
				int(rec["n"]), String(rec.get("hero", "?"))])
	var pre: Dictionary = rec.get("pre", {})
	# NOPRED 块（无法预测）本来就没有有效的预测快照，不做"缺地形键"告警——那是设计如此，不是故障。
	var pred_valid: bool = bool(pre.get("pred", {}).get("allkeys", false))
	for side in ["real", "pred"]:
		var snap: Dictionary = pre.get(side, {})
		if side == "pred" and not pred_valid:
			continue
		if not snap.has("obstacle") or not snap.has("bomb") or not snap.has("grave") \
				or not snap.has("gold") or not snap.has("buff"):
			_warn("前快照缺少地形键（side=%s）：会印出 0→N 幻影，本块内容不可信" % side)


## 对"可读层列出、字段层为空"的差异**逐条复核绝对状态**并定性：
##   · 绝对状态不同 → 真缺口（字段层漏报）→ 记进 rec["field_missed"]，判定保持 DIFF；
##   · 绝对状态相同 → 纯过程/时序差异 → 记进 rec["process_diffs"]，不计入 DIFF。
## 绝对状态来源：地形五项 `sim.<dict>` vs `after[<key>]`；单位字段 `SimUnit` vs 真实 `Unit`。
func _classify_process_diffs(rec: Dictionary) -> void:
	# NOPRED 块不做定性：它压根没有有效预测快照，可读层只有"无法预测"的说明文字，
	# 拿去比会报出 `[告警] 字段层漏报：#N ["无"]` 这种假告警（踩过）。
	if String(rec.get("verdict", "")) == "NOPRED" \
			or not bool(rec.get("pre", {}).get("pred", {}).get("allkeys", false)):
		rec["field_missed"] = []
		rec["process_diffs"] = []
		return
	var pred_det := _detail_only(_dir_of(rec.get("_lines", []), "预测"))
	var real_det := _detail_only(_dir_of(rec.get("_lines", []), "实际"))
	var base: Array = pred_det if pred_det.size() >= real_det.size() else real_det
	var other: Array = real_det if pred_det.size() >= real_det.size() else pred_det
	var missed: Array = []
	var process: Array = []
	for x in base:
		if other.has(x):
			continue
		var sx := String(x)
		# "无变化"/"无"（NOPRED 块的说明行）只是"这一侧我没列任何项"的标记，不是一项差异，
		# 不参与定性（否则合法差异会被误判成"字段层漏报"，踩过两次：一次是 `地形/道具：无变化`，
		# 一次是 NOPRED 块的 "无"）。
		if sx.contains("无变化") or sx == "无" or sx.begins_with("无（"):
			continue
		if _abs_state_differs(rec, sx):
			missed.append(sx)
		else:
			process.append(sx)
	# 定性只在"**字段层为空**"时才叫"漏报"：字段层已经有差异说明它抓到了，
	# 此时可读层的这些条目只是补充说明，不算漏报（否则 #3 那种合法 DIFF 会被重复计成漏报）。
	# ★ 分桶纠正（上层裁决）：`missed`（**绝对状态确实不同**）**不再并进 `process_diffs`**——
	#   那会让日志把"绝对状态不同"的项贴上"绝对状态一致"的错标签（用户那一招的 5 项就是这么矛盾的：
	#   3 条墓碑 + 2 条存活全是"绝对状态不同"，却被写成"仅过程差异"）。
	#   它们单独进 `field_confirmed`：语义 = "字段层已经抓到，不算新增漏报"，**仍属真差异**（判 DIFF 不变）。
	var field_all: Array = rec.get("diffs", [])
	rec["field_confirmed"] = missed if field_all.size() > 0 else []
	rec["field_missed"] = [] if field_all.size() > 0 else missed
	rec["process_diffs"] = process
	if (rec["field_confirmed"] as Array).size() > 0:
		_log("[一致性] #%d 字段层已抓到（绝对状态确实不同，非新增漏报）：%s" % [
			int(rec["n"]), str(rec["field_confirmed"])])
	# ★ 告警只看 `field_missed`（**字段层确实没抓到**的新缺口），不看 `missed`：
	#   字段层已经抓到的那批已归入 `field_confirmed`（上面那行 `[一致性]` 已如实记录），
	#   再叫它"漏报"是**误导**——用户日志里 `diffs=["坠炮手#5 血量 预测4→实际1", …]` 明明抓到了，
	#   却还打出 `[告警] 字段层漏报：#20 ["坠炮手(hero_45)#5：HP 7→4（-3）"]`。
	#   语义定为：**漏报 = 字段层确实没抓到**（`field_missed` 非空）。
	var fmiss: Array = rec.get("field_missed", [])
	if fmiss.size() > 0:
		_warn("字段层漏报：#%d %s（字段级 diffs 为空，说明这一项确实没被抓到）" % [
			int(rec["n"]), str(fmiss)])


## ============ SPAN：本招窗口内的"场外变化"事件（事件驱动，主判据） ============
#
# 事件来源全部是 Battle 自己的：`sub_select_requested` / `sub_placed` 两个信号 + 场上 `units` 数。
# 在出招前、出招后各取一次指纹，比较差值就是"本招窗口内发生过什么场外事件"。
var _ev_sub_req := 0             # 累计：收到过多少次 sub_select_requested（替补面板开）
var _ev_sub_placed := 0          # 累计：替补落位成功过多少次


## 记录"此刻"的事件指纹（出招前 / 出招后各一次）。
func _window_events_now() -> Dictionary:
	var cells := {}
	var units: Array = []
	if _battle != null and is_instance_valid(_battle):
		units = _battle.units
	for u in units:
		if u == null or not is_instance_valid(u) or not (u is Unit):
			continue
		cells[(u as Unit).get_instance_id()] = (u as Unit).cell
	return {
		"sub_req": _ev_sub_req, "sub_placed": _ev_sub_placed,
		"units": units.size(), "cells": cells,
	}


## 比较两个指纹 → 本招窗口内的场外事件原因列表（空 = 没发生）。
##
## ★ SPAN 硬闸门（用户拍板的新契约）：**只有"模拟侧没预测出这次登场"才算场外**。
##   模拟的"动作后状态"会把窗口内登场的替补当正常单位追加在 `sim.units` 末尾（与真实侧同顺序），
##   于是"模拟侧单位数也涨了同样多"就说明这次登场**已被预测** → 照常比较（含血量/状态/墓碑/单位数），
##   不再一律判"不可比"。反之（模拟没涨、或涨得比真实少）才判 `不可比` 并如实写明是"模拟未预测"。
func _window_event_reasons(rec: Dictionary) -> Array:
	var out: Array = []
	var ev: Dictionary = rec.get("window_ev", {})
	if ev.is_empty():
		return out
	var pre: Dictionary = ev.get("pre", {})
	var post: Dictionary = ev.get("post", {})
	# 真实侧/模拟侧各新增了几个单位（模拟侧取的是"预测快照"里 units 的条数差；新单位已纳入快照末尾）
	var real_new := int(rec.get("new_units", 0))
	var sim_new := 0
	var spre: Dictionary = rec.get("pre", {}).get("pred", {})
	var spost: Dictionary = rec.get("post", {}).get("pred", {})
	if bool(spre.get("allkeys", false)) and bool(spost.get("allkeys", false)):
		sim_new = maxi(0, (spost.get("units", []) as Array).size() - (spre.get("units", []) as Array).size())
	var sub_happened: bool = int(post.get("sub_req", 0)) > int(pre.get("sub_req", 0)) \
			or int(post.get("sub_placed", 0)) > int(pre.get("sub_placed", 0))
	var predicted_entry: bool = real_new > 0 and sim_new >= real_new
	if sub_happened:
		if predicted_entry:
			# 模拟已预测登场 → **正常比较**（不判不可比），只留一行诊断便于事后核对
			_log("[SPAN·诊断] #%d 本招窗口内有替补登场（sub_select_requested/sub_placed），但**模拟侧也新增了 %d 个单位（真实新增 %d）** → 判定为「已预测」→ **照常比较，不判不可比**" % [
				int(rec["n"]), sim_new, real_new])
		else:
			out.append("本招窗口内收到替补面板请求/替补落位完成（模拟侧未预测出登场：模拟新增 %d、真实新增 %d）" % [
				sim_new, real_new])
	var nu := int(post.get("units", 0))
	var ou := int(pre.get("units", 0))
	if nu > ou:
		if predicted_entry:
			_log("[SPAN·诊断] #%d 窗口内真实单位数 %d→%d，模拟侧同步新增 %d → 已预测，**不计 SPAN**" % [
				int(rec["n"]), ou, nu, sim_new])
		else:
			out.append("本招窗口内有新单位登场（场上单位数 %d→%d：替补/召唤，模拟未预测）" % [ou, nu])
	elif nu < ou:
		# ★ "少了"**不算场外**：单位从 `battle.units` 里消失几乎总是"本招击杀的收尾"
		#   （阵亡 → 淡出 0.3s → `units.erase` + `queue_free`），那是**本招自己的后果**，
		#   判成"不可比"会把真差异（例如同招落下的墓碑）一起吞掉。所以只写诊断。
		_log("[SPAN·诊断] #%d 本招窗口内场上单位数 %d→%d（减少）：多为本招击杀的收尾，**不计 SPAN**" % [
			int(rec["n"]), ou, nu])
	# ③ 墓碑格上出现新单位（替补在墓碑处落位）：新 id 且它站的格在出招前是墓碑
	var pcells: Dictionary = pre.get("cells", {})
	var qcells: Dictionary = post.get("cells", {})
	var pre_grave: Dictionary = rec.get("pre", {}).get("real", {}).get("grave", {})
	for id in qcells.keys():
		if pcells.has(id):
			continue
		var c = qcells[id]
		if pre_grave.has(c):
			out.append("替补在墓碑 %s 处落位" % _cell(c))
			break
	return out


## 降级判据：其它"疑似场外"的情形**只写文件诊断**（不计 SPAN、不改判定）。
## 目前只有一条：实际侧凭空获得[圣盾]而预测侧没有、且本招没有拾取道具——
## 它可能是"同一招内的延迟给盾"，也可能是道具/盾的建模缺口 → 证据不足以判场外，只登记。
func _suspect_span_diagnostics(rec: Dictionary) -> Array:
	var out: Array = []
	var post: Dictionary = rec.get("post", {})
	var pre_real: Dictionary = rec.get("pre", {}).get("real", {})
	var picked := false
	for t in _terrain_changes(pre_real, post.get("real", {})):
		if String(t).contains("道具") and String(t).contains("被拾取"):
			picked = true
			break
	if picked:
		return out
	for d in post.get("real", {}).get("units", []):
		var rd: Dictionary = d
		if not _truth(rd.get("shield", false)):
			continue
		var pd := _find_unit(post.get("pred", {}), "%s" % rd.get("key", "?"))
		if pd.size() > 0 and not _truth(pd.get("shield", false)):
			out.append("实际侧凭空获得[圣盾]（非本招拾取）：%s" % String(rd.get("name", "?")))
			break
	return out


## 本招期间是否发生了"**动作之外**的场外变化"——命中则本块判"不可比"，不计入 DIFF。
##
## ★ 主判据 = **事件驱动**（本招窗口内是否真的发生过场外事件），见 `_window_event_reasons`：
##   ① `sub_select_requested` / `sub_placed`（替补面板开 / 替补落位完成）
##      —— 用户实机撞到的正是它：同一招内替补落位 → 波盾 `on_enter` 给全队挂盾；
##   ② 场上**单位数**变化（新增=替补/召唤登场；减少=撤下/离场）；
##   ③ 墓碑格上出现新单位（替补在墓碑处落位）。
##   全部来自 Battle 自己的信号/状态，机读可证。
##
## 为什么废弃了旧的"比较回合开始冻结的 `view`"判据：那份 `view` 冻结在回合开始，
## **中途落位的替补/召唤物永远不会出现在里面** → "新增"结构性不可达；"移除"则要求单位在
## 本招窗口内被释放，而实测证明"出招后快照早于死亡结算" → 也不可达（机制形同虚设）。
##
## 证据不足的"疑似场外"（例如"实际侧凭空多出[圣盾]"）**只写文件诊断、不计 SPAN**：
## 宁可漏计，也**不许**用它吞掉真差异（`_suspect_span_diagnostics`）。
func _turn_span_reasons(rec: Dictionary) -> Array:
	var reasons: Array = _window_event_reasons(rec)
	var diag: Array = _suspect_span_diagnostics(rec)
	if diag.size() > 0 and reasons.is_empty():
		_log("[SPAN·诊断] #%d 疑似场外但证据不足（**不计 SPAN**、判定照常）：%s" % [
			int(rec["n"]), str(diag)])
	return reasons


## 该差异对应的**绝对状态**是否真的不同（不同 = 真缺口；相同 = 仅过程差异）。
## 解析条目文本里的"类别 + 坐标/单位名"，再去比绝对数据。
func _abs_state_differs(rec: Dictionary, item: String) -> bool:
	var abs_pred: Dictionary = rec.get("post", {}).get("pred_abs", {})
	var abs_real: Dictionary = rec.get("post", {}).get("real_abs", {})
	if abs_pred.is_empty() or abs_real.is_empty():
		return true     # 拿不到绝对状态：宁可按"真缺口"报，也不静默降级
	for pair in [["障碍", "obstacle"], ["炸弹", "bomb"], ["墓碑", "grave"], ["金矿", "gold"], ["道具", "buff"]]:
		# ★ 必须要求"地形词 + 分隔符（`@` 或空格）"，**不能**只判前缀：
		#   地形条目的格式是固定的 —— `_terrain_diffs` 出 `"%s@%s 预测…"`（如 `墓碑@(4,1) 预测有→实际无`），
		#   `_terrain_changes` 出 `"%s %s 耐久…"` / `"%s %s%s"`（如 `墓碑 (4,3)（出现）`）；
		#   而**单位条目**是 `"<名字>：…"`。只判 `begins_with(地形词)` 会把**名字以地形词开头**的单位
		#   误当成地形条目 → 去解析坐标 → 从 `(hero_35)` 里解析不出 `(x, y)` → 直接判"真差异"。
		#   实测（用户实例 2026-09-13 15:44:32，hero_35 就叫「炸弹人」）：
		#     `[告警] 字段层漏报：#2 ["炸弹人(hero_35)#1：HP 1→0（-1）；阵亡"]`
		#   同一块里形状完全相同的 `雪拳(hero_26)#4：HP 2→0（-2）；阵亡` 走的是单位分支，
		#   还留下了 `[定性·诊断] … branch=两侧都无` 一行；「炸弹人」那条**没有任何定性行**
		#   —— 它就是被这里的前缀命中截走的（既不是"字段层真漏抓"，也不是"分层 bug"）。
		var word := String(pair[0])
		if not (item.begins_with(word + "@") or item.begins_with(word + " ")):
			continue
		# 取条目里的坐标文本 "(x, y)"，用两侧绝对字典比"该格在不在 / 耐久"。
		# ★★ 结构修正（编辑器警告 UNREACHABLE_CODE，2026-09-13 本轮）：
		#   原来这里是 `if c.x == -99: return true` 紧跟着坐标比对 —— 那个 `return` 把下面
		#   整段（obstacle 比耐久 / 其它比"在不在"）吃成**永不执行的死代码**，于是
		#   **所有地形条目**（障碍/炸弹/墓碑/金矿/道具）都被无条件判成"真差异"，
		#   `_classify_process_diffs` 里"可读层有差异、字段层为空 → 就地按格复核绝对状态"
		#   这半条对地形项从来没生效过（全都落进 `field_missed` 的 `[告警] 字段层漏报`）。
		#   恢复原意：**解析得出坐标才比**；解析不出（拿不到该格）才保守判"真差异"
		#   （与上面"拿不到绝对状态 → 按真缺口报"同一条口径）。
		#   两种地形条目格式都解析得出（`_parse_cell` 取**第一对 ASCII 括号**）：
		#     · `墓碑@(4,1) 预测有→实际无`（`_terrain_diffs`）
		#     · `墓碑 (4,3)（出现）`（`_terrain_changes`；"（出现）"是全角括号，不会被当成坐标括号）
		var c := _parse_cell(item)
		if c.x != -99:
			var k := String(pair[1])
			var a1 = (abs_pred.get(k, {}) as Dictionary).get(c, null)
			var a2 = (abs_real.get(k, {}) as Dictionary).get(c, null)
			if k == "obstacle":
				# ★ 真 bug 修复（编辑器警告 INCOMPATIBLE_TERNARY）：原写法
				#   `return int(a1) if a1 != null else 0 != (int(a2) if a2 != null else 0)`
				# 因**运算符优先级**被解析成 `int(a1) if (a1 != null) else (0 != …)`：
				# a1 非 null 时**直接返回耐久数值本身**（非 0 即真）→ 障碍项几乎永远判"不同"，
				# 会伪造 `[告警] 字段层漏报`、把过程差误判成真缺口。
				# 正确语义：两侧各自缺省按 0，再比"耐久是否相同"。
				var v1 := int(a1) if a1 != null else 0
				var v2 := int(a2) if a2 != null else 0
				return v1 != v2
			return (a1 == null) != (a2 == null)
		return true     # 坐标解析不出：无法核验该格 → 保守按"真差异"报，不当成"过程差异"吞掉
	# 单位相关（HP/位置/状态/攻移）：用绝对状态里的同名单位比
	return _abs_unit_differs(abs_pred, abs_real, item)


## 从 "(3, 4)" 这类文本里解析坐标；解析不出返回 (-99,-99)
func _parse_cell(s: String) -> Vector2i:
	var i := s.find("(")
	var j := s.find(")", i + 1)
	if i < 0 or j <= i:
		return Vector2i(-99, -99)
	var parts := s.substr(i + 1, j - i - 1).split(",")
	if parts.size() != 2:
		return Vector2i(-99, -99)
	return Vector2i(int(parts[0].strip_edges()), int(parts[1].strip_edges()))


## 单位类差异的绝对状态比对：按条目里的"名字：#"定位两侧绝对单位数据，比 HP/位置/状态
func _abs_unit_differs(abs_pred: Dictionary, abs_real: Dictionary, item: String) -> bool:
	var sep := item.find("：")
	if sep < 0:
		return true
	var who := item.substr(0, sep)
	var pa = abs_pred.get(who, null)
	var ra = abs_real.get(who, null)
	# ★ 口径对齐（"真实侧已移除" ≡ "模拟里已阵亡"）：
	#   真实侧阵亡单位淡出结束就被 `units.erase + queue_free`，**不再出现在 `abs_real` 里**；
	#   而模拟侧的单位还在（`alive=false`）。以前一律 `pa==null or ra==null → true`，
	#   于是"预测侧报了它阵亡+挂盾"会被判成"字段层漏报"（用户撞到的 `[告警] 字段层漏报`）。
	#   现在按**四种组合**分别定性（依据用户实机那块"血锁#2 HP 1→0 阵亡、真实侧已消失、墓碑两侧一致"）：
	#     · 两侧都查不到 → **两侧一致地"它不在场上"** → 一致（false），不是真缺口；
	#     · 只有真实侧查不到 → 模拟判死=一致(false)；模拟判活=真差异(true)；
	#     · 只有模拟侧查不到、真实侧还有 → 真差异（true，"模拟没有它"）。
	if ra == null and pa == null:
		_log("[定性·诊断] item=\"%s\" pa=无 ra=无 branch=两侧都无 → 判一致（它已不在场上）" % item)
		return false
	if ra == null and pa != null:
		var d1a: Dictionary = pa
		var dead_sim: bool = (not _truth(d1a.get("alive", true))) or int(d1a.get("hp", 1)) <= 0
		_log("[定性·诊断] item=\"%s\" pa=有(hp=%s alive=%s) ra=无 branch=只真实侧无 → %s" % [
			item, str(d1a.get("hp", "?")), str(d1a.get("alive", "?")),
			"判一致（模拟也已阵亡）" if dead_sim else "判真差异（模拟仍判活）"])
		return not dead_sim
	if pa == null and ra != null:
		var d2a: Dictionary = ra
		_log("[定性·诊断] item=\"%s\" pa=无 ra=有(hp=%s alive=%s) branch=只模拟侧无 → 判真差异（模拟缺了这个单位）" % [
			item, str(d2a.get("hp", "?")), str(d2a.get("alive", "?"))])
		return true
	var d1: Dictionary = pa
	var d2: Dictionary = ra
	if int(d1.get("hp", -1)) != int(d2.get("hp", -2)):
		return true
	# ★ 防"真缺口被降级"：hp 都 >0 时 `alive` 也必须比（不同 = 真差异）。
	#   hp≤0 的情形交给"延迟阵亡窗口"（真实侧 hp=0 但 `alive` 尚未翻）——那条由 TIMING 硬闸门处理，
	#   而且只有在**两侧 hp 都 ≤0** 时才允许降级（见 _alive_diff_is_delayed_death）。
	if int(d1.get("hp", -1)) > 0 and int(d2.get("hp", -2)) > 0 \
			and _truth(d1.get("alive", true)) != _truth(d2.get("alive", true)):
		return true
	if "%s" % d1.get("cell", "?") != "%s" % d2.get("cell", "?"):
		return true
	for st in STATUSES:
		var k := String(st[0])
		if _truth(d1.get(k)) != _truth(d2.get(k)):
			return true
	return false


## 从整块行里挑出某一侧（"预测"/"实际"）的明细行
func _dir_of(lines: Array, tag: String) -> Array:
	var out: Array = []
	var prefix := "  %s | " % tag
	for l in lines:
		var s := "%s" % l
		if s.begins_with(prefix):
			out.append(s)
	return out


## 把快照转成"按名字索引的绝对状态"，供 _abs_state_differs 复核用
func _abs_of(snap: Dictionary) -> Dictionary:
	var m := {}
	for d in snap.get("units", []):
		m["%s" % (d as Dictionary).get("name", "?")] = d
	return m


## 旗标行：只在"出手单位"与"两侧旗标不一致的单位"上列，沿用字段级原名，无差异不打这一行。
## 关键限制（否则刷屏且无意义）：
##   · **旗标差异只对"本招出手的那个单位"比**。预测侧的 sim 是"本招之前"重建的，其它单位的
##     moved/attacked 天然是 false，拿去跟真实侧（已累积整回合动作）比，永远全是"预测否/实际是"——
##     这与字段级 `_compare` 的口径一致（它也只比 `i == vidx` 的旗标）。
##   · 非出手单位只列它**实际已做过的动作**（不带"预测/实际"对比）。
## 出手单位的判定按**下标**（`rec["idx"]` 即 view 下标）而不是名字——
## 同名英雄（如两个烛火）按名字会撞车。
func _flag_line(rec: Dictionary) -> String:
	var post: Dictionary = rec.get("post", {})
	var actor_key := _ukey(int(rec.get("idx", -1)))
	var flag_names: Array = [["moved", "已移动"], ["attacked", "已攻击"], ["counter_used", "已反击"]]
	var parts: Array = []
	# 以真实侧名单为准（顺序稳定），逐一处理
	for d in post.get("real", {}).get("units", []):
		var nm := "%s" % (d as Dictionary).get("name", "?")
		var kk := "%s" % (d as Dictionary).get("key", "?")
		var is_actor: bool = kk == actor_key
		var rd := _find_unit(post.get("real", {}), kk)
		var on: Array = []
		var diffs_on: Array = []
		for pair in flag_names:
			var k := String(pair[0])
			var lb := String(pair[1])
			if rd.has(k) and _truth(rd[k]):
				on.append(lb)
			if is_actor:
				var pd := _find_unit(post.get("pred", {}), kk)
				if pd.has(k) and rd.has(k) and _truth(pd[k]) != _truth(rd[k]):
					diffs_on.append("%s（预测 %s / 实际 %s）" % [lb, _yn(_truth(pd[k])), _yn(_truth(rd[k]))])
		if not is_actor and on.size() == 0 and diffs_on.size() == 0:
			continue
		var seg := nm
		if on.size() > 0:
			seg += " " + ",".join(on)
		if diffs_on.size() > 0:
			seg += " " + "；".join(diffs_on)
		parts.append(seg)
	if parts.size() == 0:
		return ""
	return "  旗标：%s" % " | ".join(parts)


## 在某一侧快照里按 key（view 下标）找单位条目；给名字时退回按名字找
func _find_unit(snap: Dictionary, key_or_name: String) -> Dictionary:
	for d in snap.get("units", []):
		var dd: Dictionary = d
		if "%s" % dd.get("key", "?") == key_or_name:
			return dd
	for d2 in snap.get("units", []):
		var d3: Dictionary = d2
		if "%s" % d3.get("name", "?") == key_or_name:
			return d3
	return {}





## 动作类型如实照抄（动作字典只有 move / atk / atk_obs），并把移动的起止格写清。
## 注意：`atk` 只表示"动作字典里有攻击意图"，真实是否打得到、打到谁，看下面"实际"那一行。
## 特别地：靠移动触发范围技的英雄（如烛火的移动后灼烧）在字典里只有 move，
## 绝不写成"攻击某人"——它的波及目标全部出现在"实际/预测"的逐单位对比里。
func _act_desc(kind: String, moves: Array, _pre: Dictionary, rec: Dictionary) -> String:
	var parts: Array = []
	if kind.contains("move"):
		if moves.size() > 0:
			var m: Dictionary = moves[0]
			parts.append("移动 %s→%s" % [_cell(m["from"]), _cell(m["to"])])
		else:
			parts.append("移动")
	if kind.contains("atk"):
		var tn := String(rec.get("atk_target_name", ""))
		parts.append("攻击 %s" % (tn if tn != "" and tn != "?" else "（目标已离场/未命中）"))
	if kind.contains("atk_obs"):
		parts.append("攻击障碍 %s" % _cell(rec.get("atk_obs_cell", Vector2i.ZERO)))
	return " + ".join(parts) if parts.size() > 0 else kind


## 快照单位的键：**用 view 下标**，不用对象。
## 血的教训：曾经拿 Unit 节点对象当字典键，结果 key 全部塌掉（Unit 对象作 Variant 键在这里不可靠），
## `_by_key()` 只剩一项 → 逐单位对比恒等于"无变化"、判定恒 MATCH。
## 下标在同一招内是不变的（view 就是本招的下标基准），两侧（真实/预测）也用它对齐，简单可靠。
func _ukey(k: int) -> String:
	return "u%d" % k


## 某一侧的后果逐项列出（侧 = "预测" 或 "实际"）。
## 严格口径：快照不完整（缺地形五键）或来源不可用（sim 缺失）时**拒绝输出**，
## 打印"快照无效"而不是印出 `0→3`、`单位消失` 这类幻影——宁可不给，也不给错的。
func _dir_lines(tag: String, snap: Dictionary, other: Dictionary) -> Array:
	var why := _snap_invalid_reason(snap, other)
	if why != "":
		return ["  %s | 快照无效，本侧不列项（%s）" % [tag, why]]
	var out: Array = []
	var units: Array = _unit_changes(snap, other)
	if units.size() == 0:
		out.append("  %s | 单位：无变化" % tag)
	else:
		for u in units:
			out.append("  %s | %s" % [tag, String(u)])
	var terr: Array = _terrain_changes(snap, other)
	if terr.size() == 0:
		out.append("  %s | 地形/道具：无变化" % tag)
	else:
		for t in terr:
			out.append("  %s | %s" % [tag, String(t)])
	return out


## 快照是否可用于前后对比；返回 "" = 可用，否则返回拒绝原因。
func _snap_invalid_reason(a: Dictionary, b: Dictionary) -> String:
	if a.is_empty() or b.is_empty():
		return "一侧快照为空"
	if not bool(a.get("allkeys", false)) or not bool(b.get("allkeys", false)):
		return "预测侧 sim 不可用（本招无法预测）"
	for key in ["obstacle", "bomb", "grave", "gold", "buff"]:
		if not a.has(key) or not b.has(key):
			return "缺少地形键 %s" % key
	return ""


## 逐单位对比两份快照，列出变化（HP / 位置 / 存活 / 状态 / 有效攻移）
## 注意：格位一率用 `%s` 格式化（"%s" % v），**不要**写 String(v)。
## 本文件里 String(<Object>) 会报 "Nonexistent 'String' constructor" 并返回 null，
## 一旦某个 cell 取值意外为 null/Object，整段报告就会连报错带错值。`%s` 对 Variant 一律安全。
func _unit_changes(a: Dictionary, b: Dictionary) -> Array:
	var out: Array = []
	var ak := _by_key(a)
	var bmap := _by_key(b)
	for k in ak.keys():
		var ua: Dictionary = ak[k]
		var ub: Dictionary = bmap.get(k, {})
		var nm := "%s" % ua.get("name", "?")
		if ub.is_empty():
			out.append("%s 消失（阵亡/离场）" % nm)
			continue
		var bits: Array = []
		if int(ua.get("hp", 0)) != int(ub.get("hp", 0)):
			bits.append("HP %d→%d（%+d）" % [
				int(ua.get("hp", 0)), int(ub.get("hp", 0)),
				int(ub.get("hp", 0)) - int(ua.get("hp", 0))])
		if "%s" % ua.get("cell", "?") != "%s" % ub.get("cell", "?"):
			bits.append("位置 %s→%s" % [ua.get("cell", "?"), ub.get("cell", "?")])
		if bool(ua.get("alive", true)) and not bool(ub.get("alive", true)):
			bits.append("阵亡")
		for st in STATUSES:
			var kn := "%s" % st[0]
			if _truth(ua.get(kn)) != _truth(ub.get(kn)):
				bits.append("状态[%s] %s→%s" % ["%s" % st[2],
					_yn(_truth(ua.get(kn))), _yn(_truth(ub.get(kn)))])
		if int(ua.get("eatk", 0)) != int(ub.get("eatk", 0)):
			bits.append("有效攻 %d→%d" % [int(ua.get("eatk", 0)), int(ub.get("eatk", 0))])
		if int(ua.get("emove", 0)) != int(ub.get("emove", 0)):
			bits.append("有效移 %d→%d" % [int(ua.get("emove", 0)), int(ub.get("emove", 0))])
		if bits.size() > 0:
			out.append("%s：%s" % [nm, "；".join(bits)])
	if out.size() == 0:
		out.append("无")
	return out


## 逐格对比地形/道具（障碍比耐久，其它比有无）
## 注意：这里**不写** `var pairs := [[...],[...]]`——那种"混合类型嵌套数组"的字面量会让
## 类型推断去构造嵌套容器类型，在本项目的 Godot 版本上实测直接把脚本编译搞崩（无任何报错、
## 只有 signal 11）。改成平铺数组 + 显式 Array 类型，行为完全一样。
func _terrain_changes(a: Dictionary, b: Dictionary) -> Array:
	var out: Array = []
	var keys: Array = ["obstacle", "bomb", "grave", "gold", "buff"]
	var names: Array = ["障碍", "炸弹", "墓碑", "金矿", "道具"]
	var by_val: Array = [true, false, false, false, false]
	for pi in keys.size():
		var ka := String(keys[pi])
		var nm := String(names[pi])
		var da: Dictionary = a.get(ka, {})
		var db: Dictionary = b.get(ka, {})
		var seen := {}
		for c in da.keys():
			seen[c] = true
		for c in db.keys():
			seen[c] = true
		for c in seen.keys():
			var va = da.get(c, null)
			var vb = db.get(c, null)
			if bool(by_val[pi]):
				var ia := int(va) if va != null else 0
				var ib := int(vb) if vb != null else 0
				if ia != ib:
					out.append("%s %s 耐久 %d→%d" % [nm, _cell(c), ia, ib])
			elif (va == null) != (vb == null):
				var how := "（被拾取）" if va != null else "（出现）"
				out.append("%s %s%s" % [nm, _cell(c), how])
	return out


func _by_key(snap: Dictionary) -> Dictionary:
	var m := {}
	for d in snap.get("units", []):
		# key 是 _ukey(k) 生成的**字符串下标**（见 _ukey 注释：不要用 Unit 对象当键，也不要用 String(对象)）。
		m["%s" % d.get("key", "?")] = d
	return m


## 打包一份"真实局面"快照用于前后对比：单位（以 Unit 对象为键，跨出招存活不变）+ 地形五项
func _snap_of(snapshot: Dictionary, view: Array) -> Dictionary:
	var units: Array = []
	for k in view.size():
		var u = view[k]
		if u == null or not is_instance_valid(u) or not (u is Unit):
			continue
		var un := u as Unit
		units.append({
			"key": _ukey(k), "name": _view_name(view, k), "cell": un.cell, "hp": un.hp,
			"max_hp": un.max_hp, "alive": un.alive, "eatk": un.effective_atk(),
			"emove": un.effective_move(),
			"stunned": un.has_status(StatusDB.STUN), "silenced": un.has_status(StatusDB.SILENCE),
			"shield": un.has_status(StatusDB.SHIELD), "heavy": un.has_status(StatusDB.HEAVY),
			"poisoned": un.has_status(StatusDB.POISON), "frozen": un.has_status(StatusDB.FREEZE),
			"atkdown": un.has_status(StatusDB.ATKDOWN), "thorn": un.has_status(StatusDB.THORN),
			# 行动旗标：必须与 _snap_sim 同名带上，否则"旗标行"两侧永远都取不到值（踩过：旗标行空着）
			"moved": un.moved_this_turn, "attacked": un.attacked_this_turn,
			"counter_used": un.counter_used_this_turn,
		})
	return {
		"units": units, "allkeys": true, "obstacle": snapshot.get("obstacle", {}),
		"bomb": snapshot.get("bomb", {}), "grave": snapshot.get("grave", {}),
		"gold": snapshot.get("gold", {}), "buff": snapshot.get("buff", {}),
	}


## 打包一份"预测局面"（SimUnit 侧）用于前后对比：键与真实侧一致（用 view 里的 Unit 对象）
##
## 字段可用性（已逐个核对 RL/ai/AI_Battle.gd 的 SimUnit，别凭印象加字段）：
##   存在且可用：cell / hp / max_hp / alive / eatk / emove / stunned / silenced / shield
##              / heavy / poisoned / frozen / moved / attacked / counter_used
##   **不存在**：atkdown（fork 里麻痹记在 atk_mod 的降攻记账上，不是布尔位）
##              thorn（fork 根本没模拟[荆棘]）
## 以前直接读 s.atkdown / s.thorn → GDScript 报 "Invalid access to property or key ..." 后求值成 null
## → [麻痹]/[荆棘] 两列永远错、还每次刷一条错污染控制台。现在这两项**从真实侧注入**：
## 麻痹用真实 Unit 的 has_status(ATKDOWN)，荆棘用 has_status(THORN)（预测侧与真实侧同口径）。
## key 可能已失效（本招内阵亡后被释放）——必须先 is_instance_valid 再读，否则又是崩。
##
## sim 不可用时（NOPRED 那条路径没有 sim）返回**无效快照**（allkeys=false），
## 由调用方拒绝对它做前后对比 —— 否则会拿空单位表当"预测"，印出"单位消失/0→3"这种幻影。
func _snap_sim(sim, view: Array) -> Dictionary:
	var units: Array = []
	if sim == null:
		return { "units": units, "allkeys": false, "obstacle": {}, "bomb": {}, "grave": {},
				"gold": {}, "buff": {} }
	# ★ 新登场单位按 **hero_id + cell 配对**（两侧同规则）：
	#   `view` 的前段（出招前就有的）照旧按下标一一对应；超出的尾部是"本招窗口内新登场的单位"，
	#   模拟侧把登场者追加在 `sim.units` 末尾，但为了不依赖"追加顺序完全一致"，这里显式按
	#   `hero_id + cell` 去找（落点一致即视为同一人）；找不到就**不列这一项**
	#   （模拟没预测出登场 → 后面由"在场单位数"和 SPAN 闸门体现，绝不因此静默对齐到错的人）。
	var used := {}
	var base := mini(view.size(), sim.units.size())
	for k in view.size():
		var ru0 = view[k]
		var real_ok0: bool = ru0 != null and is_instance_valid(ru0) and (ru0 is Unit)
		var s = null
		if k < base:
			s = sim.units[k]
			used[k] = true
		elif real_ok0 and _sim_field_exists(sim.units[0] if sim.units.size() > 0 else null, "hero_id"):
			for j in sim.units.size():
				if used.has(j):
					continue
				var sj = sim.units[j]
				if String(sj.hero_id) == String((ru0 as Unit).hero_id) and sj.cell == (ru0 as Unit).cell:
					s = sj
					used[j] = true
					break
		if s == null:
			continue
		var ru = view[k]
		var real_ok: bool = ru != null and is_instance_valid(ru) and (ru is Unit)
		units.append({
			"key": _ukey(k), "name": _view_name(view, k), "cell": s.cell, "hp": s.hp,
			"max_hp": s.max_hp, "alive": s.alive, "eatk": s.eatk, "emove": s.emove,
			"stunned": s.stunned, "silenced": s.silenced, "shield": s.shield, "heavy": s.heavy,
			"poisoned": s.poisoned, "frozen": s.frozen,
			"atkdown": (ru as Unit).has_status(StatusDB.ATKDOWN) if real_ok else false,
			"thorn": (ru as Unit).has_status(StatusDB.THORN) if real_ok else false,
			# 行动旗标（供"旗标行"比对；字段级也一直在比这三项）
			"moved": s.moved, "attacked": s.attacked, "counter_used": s.counter_used,
		})
	return {
		"units": units, "allkeys": true,
		# ★ 地形五键必须**复制**，不能直接交引用（踩过的显示缺陷，用户贴的那块就是它）：
		# `sim.graves/bombs/...` 是 sim 里的**活字典**，`_apply()` 会就地改它们。
		# 不复制的话，"预测前"那份快照的 `炸弹/道具` 会跟着一起变 → 预测侧 delta 恒"无变化"，
		# 而实际侧（`BattleSnapshot.collect` 每次新造字典）却显示"炸弹(1,2)（出现）"
		# → 出现"预测说无变化、实际说有变化、字段级却为空"这种三方自相矛盾的块。
		# 复制之后两侧 delta 都能从各自的 pre/post 推出，与字段级的绝对状态结论一致。
		"obstacle": (sim.obstacles as Dictionary).duplicate(),
		"bomb": (sim.bombs as Dictionary).duplicate(),
		"grave": (sim.graves as Dictionary).duplicate(),
		"gold": (sim.gold_cells as Dictionary).duplicate(),
		"buff": (sim.buff_cells as Dictionary).duplicate(),
	}


## view 下标 → "中文名(hero_id)#下标"；越界/失效返回 "?"
func _view_name(view: Array, i: int) -> String:
	if i < 0 or i >= view.size():
		return "?"
	return _hero_of(view, i)


## 本招的移动（从预测/实际两侧的"位置变化"里取，而不是照抄动作字典）：
## 只有出手单位的格位真的变了才算移动；没变就是"没动"。
func _moves_of(pre: Dictionary, post: Dictionary, who: String) -> Array:
	var out: Array = []
	for d in pre.get("units", []):
		if String(d["name"]) != who:
			continue
		for e in post.get("units", []):
			# key 是 Unit 本体，按引用比较；**不要** String(key)（String(Node) 报错并返回 null，
			# 于是两边都变 null、条件恒不成立 → 会错配到列表里第一个单位）。
			if e["key"] != d["key"]:
				continue
			if d["cell"] != e["cell"]:
				out.append({ "from": d["cell"], "to": e["cell"] })
			break
		break
	return out



func _tally(rec: Dictionary) -> void:
	if not _selftest:
		return
	# 去重键：一回合内同一个索引只会出一招，用它保证"同一步不重复计数"
	var key := "%d|%d|%d" % [GameState.round_number, GameState.active_side, int(rec["idx"])]
	if _st_seen.has(key):
		return
	_st_seen[key] = true
	_st_done += 1
	# 判定分三类：DIFF（真差异）/ 过程差异（绝对状态一致、仅时序不同）/ MATCH。
	# 过程差异单独计数，**不计入 DIFF**（用户要的是一份干净的"我该修什么"清单）。
	var verdict := String(rec["verdict"])
	var line := ""
	var lines: Array = rec.get("_lines", [])
	for l in lines:
		if String(l).begins_with("  判定 "):
			line = String(l)
			break
	# 判据用"绝对状态一致"这个短语（而不是"仅过程差异"）：过程列表为空时那句话里没有后者
	# （踩过：3 条"绝对状态一致；仅过程差异："空列表的块被漏计成普通 MATCH）。
	if line.contains("不可比"):
		_st_span += 1
	elif line.contains("已知采样时机差"):
		# TIMING：全部差异都是墓碑类（采样时机差）→ 与 DIFF 并列单独计数，**不计入 DIFF**。
		# 机读自检：万一判据写错、让非墓碑差异混进来，必须当场暴露（不许拿 TIMING 掩盖）。
		var dts: Array = rec.get("diffs", [])
		var bad: Array = []
		for d in dts:
			if not String(d).begins_with("墓碑"):
				bad.append(String(d))
		if bad.size() > 0:
			_warn("TIMING 判定混入非墓碑差异：%s（判据写错了，必须修正）" % str(bad))
		_st_timing += 1
	elif line.contains("绝对状态一致"):
		_st_process += 1
		_st_match += 1
	else:
		match verdict:
			"MATCH":
				_st_match += 1
			"DIFF":
				_st_diff += 1
			_:
				_st_nopred += 1


# ================= 工具 =================

## 按 ai_mode 建一个 AI 模块实例（0=手动不该走到这里 / 1=RL候选 fork / 2=原版困难档副本）。
## 每次决策重建：权重、档位、实现都可能和上一回合不同。
## 计时：用户反馈"每次切 RL 都卡一下"，这里把可分离的三段（load 脚本 / new 实例 / 注入权重）
## 分别报毫秒，且**报告是否命中权重 JSON 缓存**（缓存只省读盘+解析，不改变注入结果）。
func _make_ai(ai_mode: int):
	var t0 := Time.get_ticks_msec()
	var path := FORK_PATH if ai_mode == AI_FORK else ORIG_PATH
	var scr = load(path)
	if scr == null:
		push_error("[检视器] 加载 AI 模块失败：%s（退回手动）" % path)
		if ai_mode == AI_FORK:
			_apply_mode(AI_MANUAL)
		else:
			_apply_emode(AI_MANUAL)
		return null
	var t_load := Time.get_ticks_msec()
	var ai = scr.new(_battle.grid)
	ai.difficulty = 2          # 困难档口径：抖动用 w_jitter（默认 0 = 可复现）
	ai.log_decisions = false
	ai.time_budget_ms = 0      # 不限时：自然搜完 → 同一局面必得同一计划
	if ai_mode != AI_FORK:
		# 明说一次：原版档位没有 set_weights/w_beam/w_jitter 这些接口，
		# 面板上的权重设置对它一个字节都不生效（不静默假装生效）。
		_log("[检视器] 档位=%s：不使用权重 / BEAM / JITTER（无这些接口）" % _ai_name(ai_mode))
	var t_new := Time.get_ticks_msec()
	var cached := _w_cache_key != ""
	var w := _load_weights(_weight_path())
	if ai.has_method("set_weights"):
		ai.set_weights(w)      # 原版没有这个方法（它没有可注入权重），跳过
	if "w_beam" in ai:
		ai.w_beam = _beam_val()
	if "w_jitter" in ai:
		ai.w_jitter = _jitter_val()
	var t_w := Time.get_ticks_msec()
	_log("[检视器] [耗时] 建 AI（%s）：load脚本 %dms / new实例 %dms / 注入权重(%d项) %dms / 合计 %dms%s" % [
		_ai_name(ai_mode), t_load - t0, t_new - t_load, w.size(), t_w - t_new, t_w - t0,
		"（权重命中缓存）" if cached else "（权重首次读盘）"])
	return ai


## 敌方对应哪个 SIDE 常量。
## 为什么不在启动时按 _first_side 反推：沙箱开局有"先选人/先手"的随机化，
## 我们传进去的 _first_side 不一定是最终拿到先手的那一方（实测 --first-side 1 时，
## 先手仍然是 0 号边）。所以这里直接问战场：哪个 SIDE 的阵营是 ENEMY。
## 另外 GameState.active_side 可能是 float，比较一律 int 化。
func _enemy_side() -> int:
	if _battle_alive() and _battle.units.size() > 0:
		return int(_battle._faction_side(DataRegistry.Faction.ENEMY))
	return GameState.SIDE_ENEMY if int(_first_side) == int(GameState.SIDE_PLAYER) else GameState.SIDE_PLAYER


## 战场是否还"活着可以驱动"。
## **不要用 `_battle.get_tree() != null` 判断**：节点在关闭窗口／停止运行／按重开／切换场景的
## 拆除过程中会**先被移出场景树、再被释放**，夹在这一帧里调 `get_tree()`，引擎会报
## `Parameter "data.tree" is null`（`scene/main/node.h:559`）——用户实机看到过这条。
## `is_inside_tree()` 对"已脱离场景树"返回 false，且不做任何引擎侧取值，无副作用。
func _battle_alive() -> bool:
	return _battle != null and is_instance_valid(_battle) and _battle.is_inside_tree()


## 轻量看门狗：AI 出手长时间不收尾时把**当前行动方那一侧**的档位退回"手动"，场景不会卡死
func _tick_watchdog() -> void:
	if not _ai_busy:
		_ai_elapsed_ms = 0
		return
	_ai_elapsed_ms += int(get_process_delta_time() * 1000.0)
	if _ai_elapsed_ms > BUSY_WALL_MS:
		var cur := _mode_of_side(int(GameState.active_side))
		if cur == AI_MANUAL:
			return
		# 不改数值：60000ms / 1000 = 60s。写成浮点除法是为了不触发 INTEGER_DIVISION 警告
		# （int/int 会先把小数丢掉；这里改成 float 除法再取整，结果仍是 60）。
		push_error("[检视器] AI 出手超过 %ds 未收尾，退回「手动（原样）」" % int(float(BUSY_WALL_MS) / 1000.0))
		_log("[检视器] 看门狗：AI 出手超时，已把%s档退回手动" % _side_txt(GameState.active_side))
		if int(GameState.active_side) == int(_enemy_side()):
			_apply_emode(AI_MANUAL)
		else:
			_apply_mode(AI_MANUAL)
		if _selftest:
			_finish_selftest()


## 等一招动画播完：action_finished 优先，另有"用时上限 + 帧数上限"双兜底
func _await_action(cb: Callable) -> String:
	if _battle == null or not is_instance_valid(_battle):
		return "changed"
	var done: Array = [false]
	var h := func() -> void: done[0] = true
	_battle.action_finished.connect(h, CONNECT_ONE_SHOT)
	var sess: int = _battle._session_id
	cb.call()
	var t0 := Time.get_ticks_msec()
	var frames := 0
	while not done[0]:
		if not _battle_alive() or _battle._session_id != sess:
			_free_handler(h)
			return "changed"
		if Time.get_ticks_msec() - t0 > ACT_WALL_MS or frames > ACT_WALL_FRAMES:
			_free_handler(h)
			return "timeout"
		frames += 1
		await get_tree().process_frame
	_free_handler(h)
	return "done"


func _free_handler(h: Callable) -> void:
	if _battle != null and is_instance_valid(_battle) and _battle.action_finished.is_connected(h):
		_battle.action_finished.disconnect(h)


## 通用等待：条件成立 / 超时 / 帧数上限 → 返回是否成立
func _wait_until(cond: Callable, ms: int, frames: int) -> bool:
	var t0 := Time.get_ticks_msec()
	var n := 0
	while true:
		if cond.call():
			return true
		if Time.get_ticks_msec() - t0 > ms or n > frames:
			return false
		n += 1
		await get_tree().process_frame
	return false


func _sleep(sec: float) -> void:
	if sec <= 0.0:
		return
	await get_tree().create_timer(sec, false).timeout


## 对拍序号：自检按"已计数招数"排，便于和 SUMMARY 对齐；手玩时用计划内序号
func _selftest_seq() -> int:
	if _selftest:
		return _st_done + 1
	return _pi


func _hero_of(descs: Array, i: int) -> String:
	if i < 0 or i >= descs.size():
		return "?"
	var u = descs[i]
	if u == null or not is_instance_valid(u):
		# 可读文案：`gone#0` 这种占位符容易被误读成某个英雄名（用户就问过），
		# 改成明确说明"这个下标上的单位已离场/被移除"，并保留下标便于对齐排查。
		# ⚠️ 注意**出手单位本人也会落到这里**：它在"本招窗口内"被反击/自爆打死、淡出后被移除
		# → 于是块头会显示成 `[对拍] #N …  已离场单位（下标 3）  攻击 圣光(hero_22)#1`
		# （用户实机撞到过：伐木工打出攻击 → 圣光反击把它打死，旗标行 `圣光#1 已反击` 可证）。
		# 这不是查表失败，而是**如实反映"它已经不在场上了"**，别当成 bug。
		return "已离场单位（下标 %d）" % i
	# 中文名 + hero_id 一起给：中文名给人看，hero_id 是排查/grep 的抓手（两种都要留）。
	# 表格里读不到名字时退回纯 id，不编造。
	var hid: String = (u as Unit).hero_id
	var def = DataRegistry.get_hero(hid)
	var dn: String = String(def.display_name) if def != null else ""
	if dn == "" or dn == hid:
		return "%s#%d" % [hid, i]
	return "%s(%s)#%d" % [dn, hid, i]


func _cell(c) -> String:
	if c is Vector2i:
		return "(%d,%d)" % [(c as Vector2i).x, (c as Vector2i).y]
	if c is Vector2:
		return "(%.0f,%.0f)" % [(c as Vector2).x, (c as Vector2).y]
	return str(c)


func _yn(b: bool) -> String:
	return "是" if b else "否"


## 参数名用 sw（不叫 name）：name 会遮蔽 Node 基类属性（编辑器警告 SHADOWED_VARIABLE_BASE_CLASS）
func _has_switch(ua: Array, sw: String) -> bool:
	for a in ua:
		var s := String(a)
		if s == sw or s.begins_with(sw + "=") or (s.begins_with(sw) and s.length() > sw.length()):
			return true
	return false


## 取 "名称 值" / "名称=值" 两种写法的整数参数（没有则用默认）。
## **刻意不支持**"名称紧贴值"（如 --selftest20）——那会让前缀相同的开关互相误吞：
## 实测 `--panecheck` 会被 `--pai` 命中（"--panecheck".begins_with("--pai") 为真），
## 于是 `_arg_after(ua, "--pai", 0)` 去取它后面那个参数（`--selftest 20` 的 "20"）当值，
## 结果默认档位被静默设成"我方=RL候选AI"，默认行为全变（敌方一出手就对不上基线）。
## 严格匹配后，`--pai1` 这类连写不再被识别，需要写成 `--pai 1`。
## 参数名用 sw（不叫 name）：name 会遮蔽 Node 基类属性（编辑器警告 SHADOWED_VARIABLE_BASE_CLASS）
func _arg_after(ua: Array, sw: String, def: int) -> int:
	for i in ua.size():
		var s := String(ua[i])
		if s == sw and i + 1 < ua.size():
			return int(String(ua[i + 1]))
		if s.begins_with(sw + "="):
			return int(s.substr(sw.length() + 1))
	return def


# ================= 自检收尾 =================

## 该开关/参数**在命令行里出现过**吗（用来区分"默认值"与"CLI 显式给值"）。
## 与 `_arg_after` 同样严格匹配（`--x v` 或 `--x=v`），不与前缀相同的其它开关混淆。
func _arg_given(ua: Array, sw: String) -> bool:
	for i in ua.size():
		var s := String(ua[i])
		if s == sw or s.begins_with(sw + "="):
			return true
	return false


## 取 "名称 值" 写法的**字符串**参数（没有则用默认）。严格匹配，理由同 _arg_after。
func _arg_str_after(ua: Array, sw: String, def: String) -> String:
	for i in ua.size():
		if String(ua[i]) == sw and i + 1 < ua.size():
			return String(ua[i + 1])
	return def


## 取 "名称 值1 值2" 这种**两个连续字符串参数**的写法（`--picks "我方" "敌方"`）。
## 找不到返回空数组。严格匹配，理由同 _arg_after（前缀相同的开关会互相误吞）。
func _arg_pair_after(ua: Array, sw: String) -> Array:
	for i in ua.size():
		if String(ua[i]) == sw and i + 2 < ua.size():
			return [String(ua[i + 1]), String(ua[i + 2])]
	return []


## "hero_01,hero_02" → ["hero_01","hero_02"]（去空白、丢空项）。
## 供 --picks 指定阵容用，也是"英雄轮换扫描"的入口。
func _split_ids(s: String) -> Array[String]:
	var out: Array[String] = []
	for part in s.split(",", false):
		var t := String(part).strip_edges()
		if t != "":
			out.append(t)
	return out

func _finish_selftest() -> void:
	# 老数字（goal/acts/MATCH/DIFF/NOPRED/round）保持**同一行、同名字**，便于基线脚本继续解析；
	# 新增的"过程差异"计数追加在同一行末尾：绝对状态一致、仅时序/路径不同，不计入 DIFF。
	_log("SIMCHK|SUMMARY|goal=%d|acts=%d|MATCH=%d|DIFF=%d|NOPRED=%d|round=%d|PROCESS=%d|SPAN=%d|TIMING=%d" % [
		_st_goal, _st_done, _st_match, _st_diff, _st_nopred, GameState.round_number, _st_process, _st_span, _st_timing])
	_log("[检视器] selftest 结束")
	get_tree().quit(0)

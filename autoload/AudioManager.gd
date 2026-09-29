extends Node
## 音效管理器（全局自动加载）：播放通用音效与英雄音效 + 音效音量调节与持久化。
## preload 静态引用音效：导出时 Godot 会自动把导入后的音频资源打进 pck，
## 避免运行时按路径动态加载在导出包里找不到文件。
## 音量范围 0..1（线性），持久化到 user://audio.cfg，重启不丢。

var _streams: Dictionary = {}   # key -> AudioStream（wav / ogg / mp3 混用）
var _players: Array[AudioStreamPlayer] = []
# 【2026-09-28·用户口径「移动应该是在移动中都连续播放」】行走音专用播放器：
#   循环播、且**不进 `_players` 池**（否则会被别的音效抢走/打断）
var _walk_player: AudioStreamPlayer = null
# 【2026-09-28·用户报「一堆音效在打架」】语音专用播放器：人声不跟音效抢同一个池
#   （抢池会被互相打断），且同一时刻只出一条人声 —— 新语音直接打断旧语音。
var _voice_player: AudioStreamPlayer = null
var _walk_timer: Timer = null   # 行走音的节奏定时器（`WALK_STEP_SEC` 一响一停）
var _enabled := true
var _volume := 1.0

const SAVE_PATH := "user://audio.cfg"

const SFX_STREAMS := {
	# 【2026-09-28·用户口径】通用音效从 `assets/audio/` 挪到 `assets/音效/`：
	#   `默认音效/` = 英雄音效的默认回退，`其他音效/` = 界面/事件音（含按钮点击）。
	#   注：`默认音效/移动.ogg` · `阵亡.ogg` 是英雄音效的**默认回退**（见下面的 `DEFAULT_STREAMS`）。
	"attack": preload("res://assets/音效/默认音效/普通攻击.ogg"),
	"click": preload("res://assets/音效/其他音效/按钮点击.ogg"),
	# 【2026-09-28·用户口径】圣盾音效 = **生成圣盾**的那一刻（吃圣盾道具 / 波盾全队盾 /
	#   圣光受伤后发盾…所有来源共用 `Unit.add_status()` 那一个挂点，见那里）。
	"shield": preload("res://assets/音效/默认音效/圣盾音效.ogg"),
	# 【2026-09-28·用户要求「把这几个删了」】受击 / 选中 两个事件音**已撤回**（素材也删了）⇒ 这两个事件
	#   现在**没有声音**（`play()` 找不到键 = 静默跳过，不报错、不崩）。以后要补就放素材 + 加一行。
	# "hit": preload("res://assets/音效/其他音效/受击.ogg"),      # 受击：每次掉血
	# "select": preload("res://assets/音效/其他音效/选中.ogg"),    # 选中 / 音量滑条松手 / 开录
	# 【2026-09-28·用户挑定】事件音（原版素材**直接搬进来、没有重编码**，所以是 mp3）：
	#   胜利 = 原版 `Quest_Win` · 失败 = `Quest_Fail` · 部署开始 = `Alert_BattleStart`
	#   我方回合 = `Alert_MyTurn`（原来那条 `Alert_TurnOver` 已按用户要求换掉）
	"win": preload("res://assets/音效/其他音效/胜利.mp3"),             # 对局胜利（Battle._check_win / _check_no_limit_end / ReplayPanel）
	"lose": preload("res://assets/音效/其他音效/失败.mp3"),            # 对局失败（Battle 两处）+ 录像导出失败（ReplayExporter 两处）
	"battle_start": preload("res://assets/音效/其他音效/部署开始.mp3"),   # 部署阶段开始（Battle._begin_deployment）
	# 【2026-09-29·用户口径「把敌方回合的音效也换成我方回合，删除敌方回合音效」】只留这一条：
	#   双方回合开始都响它（`Battle._begin_side()` / 回放换段那处都直接 `play("turn_my")`）。
	#   原来那条 `turn_enemy`（`Alert_EnemyTurn`）**连素材带键一起删掉** —— 要回退：
	#   把 `D:\资源\音效_mp3\Alert_EnemyTurn.mp3` 拷回 `assets/音效/其他音效/敌方回合.mp3` 再加一行键即可。
	"turn_my": preload("res://assets/音效/其他音效/我方回合.mp3"),       # 回合开始（我方/敌方共用，Battle._begin_side）
	# 【2026-09-28·用户口径「BattleStart.mp3 部署完毕演这个」】部署完毕（双方首发站好）那一声：
	#   原版 `BattleStart`，与上面那条 `Alert_BattleStart`（卡组三选一之后报"战斗开始"）**不是同一条**。
	"deploy_done": preload("res://assets/音效/其他音效/部署完毕.mp3"),   # 部署完毕（Battle._begin_after_deploy）
	# 【2026-09-28·用户挑定】点击类（原版 `Click_*`）：
	"enter_game": preload("res://assets/音效/其他音效/进入游戏.mp3"),     # 进入游戏（原版 Click_BattleModeButton）
	"end_turn": preload("res://assets/音效/其他音效/结束回合.mp3"),       # 结束回合按钮（原版 Click_EndTurn）
	"select_actor": preload("res://assets/音效/其他音效/选中人物.mp3"),    # 选人（原版 Click_SelectActor）
	# 【2026-09-28·用户挑定「Bomb_RangedAttack_Hit.mp3 炸弹爆炸加这个音效」】炸弹引爆那一下：
	#   原版 `音效_英雄/Bomb_RangedAttack_Hit.wav`（44.1k 单声道 PCM）⇒ ffmpeg libvorbis -q:a 6 转 ogg，
	#   并把开头 47ms 静音裁到 8ms（起播不拖）。原来 `Battle._explode_bomb_at()` 是**静音**的。
	"bomb": preload("res://assets/音效/其他音效/炸弹爆炸.ogg"),           # 炸弹引爆（Battle._explode_bomb_at）
	# （另：`crit` / `shield_break` / `poison` / `sub_enter` 四个键**代码里从未调用**，不登记）
}

# ---- 【2026-09-28·用户口径「没有类似音效的用默认」】英雄音效的**默认回退** ----
# 英雄没登记某一类时，用 `assets/音效/默认音效/` 里对应的那条顶上（而不是静音）。
#   · `walk`  → `play_hero_walk()` 里英雄查不到就用它；
#   · `death` → `play_hero_voice(..., "death")` 查不到就用它；
#   · `attack`→ 由调用方回退（`Battle._do_attack` 那两行 `AudioManager.play("attack")`，
#     指的就是同一条 `普通攻击.ogg`）⇒ 这里不再重复登记。
const DEFAULT_STREAMS := {
	"walk": preload("res://assets/音效/默认音效/移动.ogg"),
	"death": preload("res://assets/音效/默认音效/阵亡.ogg"),
}

# ---- 【2026-09-28·用户要求「把伐木工的配音加上，我听听看」】英雄语音 ----
# 【2026-09-28·用户整理素材】44 个英雄全套落到 `assets/音效/英雄音效_整理后/<英雄>/`：
#   语音 = `登场1.ogg` / `登场2.ogg`（原版 `VO_<代号>_Line_<编号>`）、`阵亡.ogg`；
#   音效 = `移动.ogg` / `普通攻击.ogg` / `技能音效.ogg`（见下面的 `HERO_SFX`）。
#   · 键 = 英雄显示名（`HeroDef.display_name`），事件 = line(登场) / move(移动) / attack(攻击) / death(阵亡)；
#   · **没登记的英雄 = 静默跳过** ⇒ 加新英雄只要在这里加一段 + 把 ogg 丢进对应英雄目录；
#   · 用 `preload`（与 `SFX_STREAMS` 同理：只有静态引用才会被打进导出包）。
#   · 缺项（原版就没有素材，不是漏登记）：骷髅兵无登场台词；涌电技师无普通攻击（后勤）。
const HERO_VOICE := {
	"伐木工": {
		"line": [
			preload("res://assets/音效/英雄音效_整理后/伐木工/登场1.ogg"),
			preload("res://assets/音效/英雄音效_整理后/伐木工/登场2.ogg"),
		],
		"death": [
			preload("res://assets/音效/英雄音效_整理后/伐木工/阵亡.ogg"),
		],
	},
	"傀儡师": {
		"line": [
			preload("res://assets/音效/英雄音效_整理后/傀儡师/登场1.ogg"),
			preload("res://assets/音效/英雄音效_整理后/傀儡师/登场2.ogg"),
		],
		"death": [
			preload("res://assets/音效/英雄音效_整理后/傀儡师/阵亡.ogg"),
		],
	},
	"医护兵": {
		"line": [
			preload("res://assets/音效/英雄音效_整理后/医护兵/登场1.ogg"),
			preload("res://assets/音效/英雄音效_整理后/医护兵/登场2.ogg"),
		],
		"death": [
			preload("res://assets/音效/英雄音效_整理后/医护兵/阵亡.ogg"),
		],
	},
	"古拉博士": {
		"line": [
			preload("res://assets/音效/英雄音效_整理后/古拉博士/登场1.ogg"),
			preload("res://assets/音效/英雄音效_整理后/古拉博士/登场2.ogg"),
		],
		"death": [
			preload("res://assets/音效/英雄音效_整理后/古拉博士/阵亡.ogg"),
		],
	},
	"古灵精怪": {
		"line": [
			preload("res://assets/音效/英雄音效_整理后/古灵精怪/登场1.ogg"),
			preload("res://assets/音效/英雄音效_整理后/古灵精怪/登场2.ogg"),
		],
		"death": [
			preload("res://assets/音效/英雄音效_整理后/古灵精怪/阵亡.ogg"),
		],
	},
	"圣光": {
		"line": [
			preload("res://assets/音效/英雄音效_整理后/圣光/登场1.ogg"),
			preload("res://assets/音效/英雄音效_整理后/圣光/登场2.ogg"),
		],
		"death": [
			preload("res://assets/音效/英雄音效_整理后/圣光/阵亡.ogg"),
		],
	},
	"圣诞老人": {
		"line": [
			preload("res://assets/音效/英雄音效_整理后/圣诞老人/登场1.ogg"),
			preload("res://assets/音效/英雄音效_整理后/圣诞老人/登场2.ogg"),
		],
		"death": [
			preload("res://assets/音效/英雄音效_整理后/圣诞老人/阵亡.ogg"),
		],
	},
	"塔盾": {
		"line": [
			preload("res://assets/音效/英雄音效_整理后/塔盾/登场1.ogg"),
			preload("res://assets/音效/英雄音效_整理后/塔盾/登场2.ogg"),
		],
		"death": [
			preload("res://assets/音效/英雄音效_整理后/塔盾/阵亡.ogg"),
		],
	},
	"复仇者": {
		"line": [
			preload("res://assets/音效/英雄音效_整理后/复仇者/登场1.ogg"),
			preload("res://assets/音效/英雄音效_整理后/复仇者/登场2.ogg"),
		],
		"death": [
			preload("res://assets/音效/英雄音效_整理后/复仇者/阵亡.ogg"),
		],
	},
	"大骑士": {
		"line": [
			preload("res://assets/音效/英雄音效_整理后/大骑士/登场1.ogg"),
			preload("res://assets/音效/英雄音效_整理后/大骑士/登场2.ogg"),
		],
		"death": [
			preload("res://assets/音效/英雄音效_整理后/大骑士/阵亡.ogg"),
		],
	},
	"太阳斩": {
		"line": [
			preload("res://assets/音效/英雄音效_整理后/太阳斩/登场1.ogg"),
			preload("res://assets/音效/英雄音效_整理后/太阳斩/登场2.ogg"),
		],
		"death": [
			preload("res://assets/音效/英雄音效_整理后/太阳斩/阵亡.ogg"),
		],
	},
	"嬉皮死神": {
		"line": [
			preload("res://assets/音效/英雄音效_整理后/嬉皮死神/登场1.ogg"),
			preload("res://assets/音效/英雄音效_整理后/嬉皮死神/登场2.ogg"),
		],
		"death": [
			preload("res://assets/音效/英雄音效_整理后/嬉皮死神/阵亡.ogg"),
		],
	},
	"小阴影": {
		"line": [
			preload("res://assets/音效/英雄音效_整理后/小阴影/登场1.ogg"),
			preload("res://assets/音效/英雄音效_整理后/小阴影/登场2.ogg"),
		],
		"death": [
			preload("res://assets/音效/英雄音效_整理后/小阴影/阵亡.ogg"),
		],
	},
	"巨剑": {
		"line": [
			preload("res://assets/音效/英雄音效_整理后/巨剑/登场1.ogg"),
			preload("res://assets/音效/英雄音效_整理后/巨剑/登场2.ogg"),
		],
		"death": [
			preload("res://assets/音效/英雄音效_整理后/巨剑/阵亡.ogg"),
		],
	},
	"影丸": {
		"line": [
			preload("res://assets/音效/英雄音效_整理后/影丸/登场1.ogg"),
			preload("res://assets/音效/英雄音效_整理后/影丸/登场2.ogg"),
		],
		"death": [
			preload("res://assets/音效/英雄音效_整理后/影丸/阵亡.ogg"),
		],
	},
	"德鲁伊": {
		"line": [
			preload("res://assets/音效/英雄音效_整理后/德鲁伊/登场1.ogg"),
			preload("res://assets/音效/英雄音效_整理后/德鲁伊/登场2.ogg"),
		],
		"death": [
			preload("res://assets/音效/英雄音效_整理后/德鲁伊/阵亡.ogg"),
		],
	},
	"战锤": {
		"line": [
			preload("res://assets/音效/英雄音效_整理后/战锤/登场1.ogg"),
			preload("res://assets/音效/英雄音效_整理后/战锤/登场2.ogg"),
		],
		"death": [
			preload("res://assets/音效/英雄音效_整理后/战锤/阵亡.ogg"),
		],
	},
	"暗域": {
		"line": [
			preload("res://assets/音效/英雄音效_整理后/暗域/登场1.ogg"),
			preload("res://assets/音效/英雄音效_整理后/暗域/登场2.ogg"),
		],
		"death": [
			preload("res://assets/音效/英雄音效_整理后/暗域/阵亡.ogg"),
		],
	},
	"末日": {
		"line": [
			preload("res://assets/音效/英雄音效_整理后/末日/登场1.ogg"),
			preload("res://assets/音效/英雄音效_整理后/末日/登场2.ogg"),
		],
		"death": [
			preload("res://assets/音效/英雄音效_整理后/末日/阵亡.ogg"),
		],
	},
	"梅林": {
		"line": [
			preload("res://assets/音效/英雄音效_整理后/梅林/登场1.ogg"),
			preload("res://assets/音效/英雄音效_整理后/梅林/登场2.ogg"),
		],
		"death": [
			preload("res://assets/音效/英雄音效_整理后/梅林/阵亡.ogg"),
		],
	},
	"死灵法师": {
		"line": [
			preload("res://assets/音效/英雄音效_整理后/死灵法师/登场1.ogg"),
			preload("res://assets/音效/英雄音效_整理后/死灵法师/登场2.ogg"),
		],
		"death": [
			preload("res://assets/音效/英雄音效_整理后/死灵法师/阵亡.ogg"),
		],
	},
	"毒蛇淑女": {
		"line": [
			preload("res://assets/音效/英雄音效_整理后/毒蛇淑女/登场1.ogg"),
			preload("res://assets/音效/英雄音效_整理后/毒蛇淑女/登场2.ogg"),
		],
		"death": [
			preload("res://assets/音效/英雄音效_整理后/毒蛇淑女/阵亡.ogg"),
		],
	},
	"沉默术士": {
		"line": [
			preload("res://assets/音效/英雄音效_整理后/沉默术士/登场1.ogg"),
			preload("res://assets/音效/英雄音效_整理后/沉默术士/登场2.ogg"),
		],
		"death": [
			preload("res://assets/音效/英雄音效_整理后/沉默术士/阵亡.ogg"),
		],
	},
	"波盾": {
		"line": [
			preload("res://assets/音效/英雄音效_整理后/波盾/登场1.ogg"),
			preload("res://assets/音效/英雄音效_整理后/波盾/登场2.ogg"),
		],
		"death": [
			preload("res://assets/音效/英雄音效_整理后/波盾/阵亡.ogg"),
		],
	},
	"涌电技师": {
		"line": [
			preload("res://assets/音效/英雄音效_整理后/涌电技师/登场1.ogg"),
			preload("res://assets/音效/英雄音效_整理后/涌电技师/登场2.ogg"),
		],
		"death": [
			preload("res://assets/音效/英雄音效_整理后/涌电技师/阵亡.ogg"),
		],
	},
	"火枪手": {
		"line": [
			preload("res://assets/音效/英雄音效_整理后/火枪手/登场1.ogg"),
			preload("res://assets/音效/英雄音效_整理后/火枪手/登场2.ogg"),
		],
		"death": [
			preload("res://assets/音效/英雄音效_整理后/火枪手/阵亡.ogg"),
		],
	},
	"炸弹人": {
		"line": [
			preload("res://assets/音效/英雄音效_整理后/炸弹人/登场1.ogg"),
			preload("res://assets/音效/英雄音效_整理后/炸弹人/登场2.ogg"),
		],
		"death": [
			preload("res://assets/音效/英雄音效_整理后/炸弹人/阵亡.ogg"),
		],
	},
	"烈焰祭司": {
		"line": [
			preload("res://assets/音效/英雄音效_整理后/烈焰祭司/登场1.ogg"),
			preload("res://assets/音效/英雄音效_整理后/烈焰祭司/登场2.ogg"),
		],
		"death": [
			preload("res://assets/音效/英雄音效_整理后/烈焰祭司/阵亡.ogg"),
		],
	},
	"烛火": {
		"line": [
			preload("res://assets/音效/英雄音效_整理后/烛火/登场1.ogg"),
			preload("res://assets/音效/英雄音效_整理后/烛火/登场2.ogg"),
		],
		"death": [
			preload("res://assets/音效/英雄音效_整理后/烛火/阵亡.ogg"),
		],
	},
	"独脚龟": {
		"line": [
			preload("res://assets/音效/英雄音效_整理后/独脚龟/登场1.ogg"),
			preload("res://assets/音效/英雄音效_整理后/独脚龟/登场2.ogg"),
		],
		"death": [
			preload("res://assets/音效/英雄音效_整理后/独脚龟/阵亡.ogg"),
		],
	},
	"猎颅者": {
		"line": [
			preload("res://assets/音效/英雄音效_整理后/猎颅者/登场1.ogg"),
			preload("res://assets/音效/英雄音效_整理后/猎颅者/登场2.ogg"),
		],
		"death": [
			preload("res://assets/音效/英雄音效_整理后/猎颅者/阵亡.ogg"),
		],
	},
	"白游侠": {
		"line": [
			preload("res://assets/音效/英雄音效_整理后/白游侠/登场1.ogg"),
			preload("res://assets/音效/英雄音效_整理后/白游侠/登场2.ogg"),
		],
		"death": [
			preload("res://assets/音效/英雄音效_整理后/白游侠/阵亡.ogg"),
		],
	},
	"红帽": {
		"line": [
			preload("res://assets/音效/英雄音效_整理后/红帽/登场1.ogg"),
			preload("res://assets/音效/英雄音效_整理后/红帽/登场2.ogg"),
		],
		"death": [
			preload("res://assets/音效/英雄音效_整理后/红帽/阵亡.ogg"),
		],
	},
	"血锁": {
		"line": [
			preload("res://assets/音效/英雄音效_整理后/血锁/登场1.ogg"),
			preload("res://assets/音效/英雄音效_整理后/血锁/登场2.ogg"),
		],
		"death": [
			preload("res://assets/音效/英雄音效_整理后/血锁/阵亡.ogg"),
		],
	},
	"赏金猎人": {
		"line": [
			preload("res://assets/音效/英雄音效_整理后/赏金猎人/登场1.ogg"),
			preload("res://assets/音效/英雄音效_整理后/赏金猎人/登场2.ogg"),
		],
		"death": [
			preload("res://assets/音效/英雄音效_整理后/赏金猎人/阵亡.ogg"),
		],
	},
	"超新星": {
		"line": [
			preload("res://assets/音效/英雄音效_整理后/超新星/登场1.ogg"),
			preload("res://assets/音效/英雄音效_整理后/超新星/登场2.ogg"),
		],
		"death": [
			preload("res://assets/音效/英雄音效_整理后/超新星/阵亡.ogg"),
		],
	},
	"锤头鲨": {
		"line": [
			preload("res://assets/音效/英雄音效_整理后/锤头鲨/登场1.ogg"),
			preload("res://assets/音效/英雄音效_整理后/锤头鲨/登场2.ogg"),
		],
		"death": [
			preload("res://assets/音效/英雄音效_整理后/锤头鲨/阵亡.ogg"),
		],
	},
	"长剑": {
		"line": [
			preload("res://assets/音效/英雄音效_整理后/长剑/登场1.ogg"),
			preload("res://assets/音效/英雄音效_整理后/长剑/登场2.ogg"),
		],
		"death": [
			preload("res://assets/音效/英雄音效_整理后/长剑/阵亡.ogg"),
		],
	},
	"长角": {
		"line": [
			preload("res://assets/音效/英雄音效_整理后/长角/登场1.ogg"),
			preload("res://assets/音效/英雄音效_整理后/长角/登场2.ogg"),
		],
		"death": [
			preload("res://assets/音效/英雄音效_整理后/长角/阵亡.ogg"),
		],
	},
	"雪拳": {
		"line": [
			preload("res://assets/音效/英雄音效_整理后/雪拳/登场1.ogg"),
			preload("res://assets/音效/英雄音效_整理后/雪拳/登场2.ogg"),
		],
		"death": [
			preload("res://assets/音效/英雄音效_整理后/雪拳/阵亡.ogg"),
		],
	},
	"风语者": {
		"line": [
			preload("res://assets/音效/英雄音效_整理后/风语者/登场1.ogg"),
			preload("res://assets/音效/英雄音效_整理后/风语者/登场2.ogg"),
		],
		"death": [
			preload("res://assets/音效/英雄音效_整理后/风语者/阵亡.ogg"),
		],
	},
	"骷髅兵": {
		"death": [
			preload("res://assets/音效/英雄音效_整理后/骷髅兵/阵亡.ogg"),
		],
	},
	"黄金矿工": {
		"line": [
			preload("res://assets/音效/英雄音效_整理后/黄金矿工/登场1.ogg"),
			preload("res://assets/音效/英雄音效_整理后/黄金矿工/登场2.ogg"),
		],
		"death": [
			preload("res://assets/音效/英雄音效_整理后/黄金矿工/阵亡.ogg"),
		],
	},
	"鼠队长": {
		"line": [
			preload("res://assets/音效/英雄音效_整理后/鼠队长/登场1.ogg"),
			preload("res://assets/音效/英雄音效_整理后/鼠队长/登场2.ogg"),
		],
		"death": [
			preload("res://assets/音效/英雄音效_整理后/鼠队长/阵亡.ogg"),
		],
	},
}

# ---- 【2026-09-28·用户指出「Woodcutter_Walk 这不是移动吗」】英雄**音效**（非语音）----
#   原版是两套文件：语音 `VO_<代号>_<事件>_<编号>`、音效 `<键>_<事件>`。这里放音效，键同样是英雄显示名。
#   文件名已中文化，事件 ↔ 文件：walk=移动 / attack=普通攻击 / pinned=被贴身近战 / skill=技能音效
#   （skill = 原版 `<代号>_Triggered`；所有英雄统一文件名 `技能音效.ogg`，素材已全部是 ogg）。
#   · 移动时：先按 `HERO_VOICE` 喊（没有就静默），再放这里的行走音效（`play_hero_walk`）。
#   · `attack` 同时是**反击**的音（见 `Battle._play_counter` / `_launch_counter_projectile`）。
#   · `pinned`：**远程单位被贴身**时改用它（`Battle._do_attack` 里判 `RANGED` + 相邻有敌人）；
#     只有那 12 个远程英雄有这条，近战英雄不登记。
#   · `skill` 由 `Battle` 在各技能触发入口调 `play_hero_sfx(名字, "skill")`（见 `Battle._hero_skill`）。
const HERO_SFX := {
	"伐木工": {
		"walk": [
			preload("res://assets/音效/英雄音效_整理后/伐木工/移动.ogg"),
		],
		"attack": [
			preload("res://assets/音效/英雄音效_整理后/伐木工/普通攻击.ogg"),
		],
	},
	"傀儡师": {
		"walk": [
			preload("res://assets/音效/英雄音效_整理后/傀儡师/移动.ogg"),
		],
		"attack": [
			preload("res://assets/音效/英雄音效_整理后/傀儡师/普通攻击.ogg"),
		],
		"pinned": [
			preload("res://assets/音效/英雄音效_整理后/傀儡师/被贴身近战.ogg"),
		],
		"skill": [
			preload("res://assets/音效/英雄音效_整理后/傀儡师/技能音效.ogg"),
		],
	},
	"医护兵": {
		"walk": [
			preload("res://assets/音效/英雄音效_整理后/医护兵/移动.ogg"),
		],
		"attack": [
			preload("res://assets/音效/英雄音效_整理后/医护兵/普通攻击.ogg"),
		],
		"pinned": [
			preload("res://assets/音效/英雄音效_整理后/医护兵/被贴身近战.ogg"),
		],
		"skill": [
			preload("res://assets/音效/英雄音效_整理后/医护兵/技能音效.ogg"),
		],
	},
	"古拉博士": {
		"walk": [
			preload("res://assets/音效/英雄音效_整理后/古拉博士/移动.ogg"),
		],
		"attack": [
			preload("res://assets/音效/英雄音效_整理后/古拉博士/普通攻击.ogg"),
		],
	},
	"古灵精怪": {
		"walk": [
			preload("res://assets/音效/英雄音效_整理后/古灵精怪/移动.ogg"),
		],
		"attack": [
			preload("res://assets/音效/英雄音效_整理后/古灵精怪/普通攻击.ogg"),
		],
		"skill": [
			preload("res://assets/音效/英雄音效_整理后/古灵精怪/技能音效.ogg"),
		],
	},
	"圣光": {
		"walk": [
			preload("res://assets/音效/英雄音效_整理后/圣光/移动.ogg"),
		],
		"attack": [
			preload("res://assets/音效/英雄音效_整理后/圣光/普通攻击.ogg"),
		],
	},
	"圣诞老人": {
		"walk": [
			preload("res://assets/音效/英雄音效_整理后/圣诞老人/移动.ogg"),
		],
		"attack": [
			preload("res://assets/音效/英雄音效_整理后/圣诞老人/普通攻击.ogg"),
		],
		"skill": [
			preload("res://assets/音效/英雄音效_整理后/圣诞老人/技能音效.ogg"),
		],
	},
	"塔盾": {
		"walk": [
			preload("res://assets/音效/英雄音效_整理后/塔盾/移动.ogg"),
		],
		"attack": [
			preload("res://assets/音效/英雄音效_整理后/塔盾/普通攻击.ogg"),
		],
		"skill": [
			preload("res://assets/音效/英雄音效_整理后/塔盾/技能音效.ogg"),
		],
	},
	"复仇者": {
		"walk": [
			preload("res://assets/音效/英雄音效_整理后/复仇者/移动.ogg"),
		],
		"attack": [
			preload("res://assets/音效/英雄音效_整理后/复仇者/普通攻击.ogg"),
		],
	},
	"大骑士": {
		"walk": [
			preload("res://assets/音效/英雄音效_整理后/大骑士/移动.ogg"),
		],
		"attack": [
			preload("res://assets/音效/英雄音效_整理后/大骑士/普通攻击.ogg"),
		],
	},
	"太阳斩": {
		"walk": [
			preload("res://assets/音效/英雄音效_整理后/太阳斩/移动.ogg"),
		],
		"attack": [
			preload("res://assets/音效/英雄音效_整理后/太阳斩/普通攻击.ogg"),
		],
	},
	"嬉皮死神": {
		"walk": [
			preload("res://assets/音效/英雄音效_整理后/嬉皮死神/移动.ogg"),
		],
		"attack": [
			preload("res://assets/音效/英雄音效_整理后/嬉皮死神/普通攻击.ogg"),
		],
		"skill": [
			preload("res://assets/音效/英雄音效_整理后/嬉皮死神/技能音效.ogg"),
		],
	},
	"小阴影": {
		"walk": [
			preload("res://assets/音效/英雄音效_整理后/小阴影/移动.ogg"),
		],
		"attack": [
			preload("res://assets/音效/英雄音效_整理后/小阴影/普通攻击.ogg"),
		],
		"skill": [
			preload("res://assets/音效/英雄音效_整理后/小阴影/技能音效.ogg"),
		],
	},
	"巨剑": {
		"walk": [
			preload("res://assets/音效/英雄音效_整理后/巨剑/移动.ogg"),
		],
		"attack": [
			preload("res://assets/音效/英雄音效_整理后/巨剑/普通攻击.ogg"),
		],
	},
	"影丸": {
		"walk": [
			preload("res://assets/音效/英雄音效_整理后/影丸/移动.ogg"),
		],
		"attack": [
			preload("res://assets/音效/英雄音效_整理后/影丸/普通攻击.ogg"),
		],
		"pinned": [
			preload("res://assets/音效/英雄音效_整理后/影丸/被贴身近战.ogg"),
		],
	},
	"德鲁伊": {
		"walk": [
			preload("res://assets/音效/英雄音效_整理后/德鲁伊/移动.ogg"),
		],
		"attack": [
			preload("res://assets/音效/英雄音效_整理后/德鲁伊/普通攻击.ogg"),
		],
		"pinned": [
			preload("res://assets/音效/英雄音效_整理后/德鲁伊/被贴身近战.ogg"),
		],
		"skill": [
			preload("res://assets/音效/英雄音效_整理后/德鲁伊/技能音效.ogg"),
		],
	},
	"战锤": {
		"walk": [
			preload("res://assets/音效/英雄音效_整理后/战锤/移动.ogg"),
		],
		"attack": [
			preload("res://assets/音效/英雄音效_整理后/战锤/普通攻击.ogg"),
		],
	},
	"暗域": {
		"walk": [
			preload("res://assets/音效/英雄音效_整理后/暗域/移动.ogg"),
		],
		"attack": [
			preload("res://assets/音效/英雄音效_整理后/暗域/普通攻击.ogg"),
		],
	},
	"末日": {
		"walk": [
			preload("res://assets/音效/英雄音效_整理后/末日/移动.ogg"),
		],
		"attack": [
			preload("res://assets/音效/英雄音效_整理后/末日/普通攻击.ogg"),
		],
		"skill": [
			preload("res://assets/音效/英雄音效_整理后/末日/技能音效.ogg"),
		],
	},
	"梅林": {
		"walk": [
			preload("res://assets/音效/英雄音效_整理后/梅林/移动.ogg"),
		],
		"attack": [
			preload("res://assets/音效/英雄音效_整理后/梅林/普通攻击.ogg"),
		],
		"skill": [
			preload("res://assets/音效/英雄音效_整理后/梅林/技能音效.ogg"),
		],
	},
	"死灵法师": {
		"walk": [
			preload("res://assets/音效/英雄音效_整理后/死灵法师/移动.ogg"),
		],
		"attack": [
			preload("res://assets/音效/英雄音效_整理后/死灵法师/普通攻击.ogg"),
		],
		"pinned": [
			preload("res://assets/音效/英雄音效_整理后/死灵法师/被贴身近战.ogg"),
		],
		"skill": [
			preload("res://assets/音效/英雄音效_整理后/死灵法师/技能音效.ogg"),
		],
	},
	"毒蛇淑女": {
		"walk": [
			preload("res://assets/音效/英雄音效_整理后/毒蛇淑女/移动.ogg"),
		],
		"attack": [
			preload("res://assets/音效/英雄音效_整理后/毒蛇淑女/普通攻击.ogg"),
		],
	},
	"沉默术士": {
		"walk": [
			preload("res://assets/音效/英雄音效_整理后/沉默术士/移动.ogg"),
		],
		"attack": [
			preload("res://assets/音效/英雄音效_整理后/沉默术士/普通攻击.ogg"),
		],
		"pinned": [
			preload("res://assets/音效/英雄音效_整理后/沉默术士/被贴身近战.ogg"),
		],
	},
	"波盾": {
		"walk": [
			preload("res://assets/音效/英雄音效_整理后/波盾/移动.ogg"),
		],
		"attack": [
			preload("res://assets/音效/英雄音效_整理后/波盾/普通攻击.ogg"),
		],
	},
	"涌电技师": {
		"walk": [
			preload("res://assets/音效/英雄音效_整理后/涌电技师/移动.ogg"),
		],
		"skill": [
			preload("res://assets/音效/英雄音效_整理后/涌电技师/技能音效.ogg"),
		],
	},
	"火枪手": {
		"walk": [
			preload("res://assets/音效/英雄音效_整理后/火枪手/移动.ogg"),
		],
		"attack": [
			preload("res://assets/音效/英雄音效_整理后/火枪手/普通攻击.ogg"),
		],
		"pinned": [
			preload("res://assets/音效/英雄音效_整理后/火枪手/被贴身近战.ogg"),
		],
	},
	"炸弹人": {
		"walk": [
			preload("res://assets/音效/英雄音效_整理后/炸弹人/移动.ogg"),
		],
		"attack": [
			preload("res://assets/音效/英雄音效_整理后/炸弹人/普通攻击.ogg"),
		],
		"pinned": [
			preload("res://assets/音效/英雄音效_整理后/炸弹人/被贴身近战.ogg"),
		],
		"skill": [
			preload("res://assets/音效/英雄音效_整理后/炸弹人/技能音效.ogg"),
		],
	},
	"烈焰祭司": {
		"walk": [
			preload("res://assets/音效/英雄音效_整理后/烈焰祭司/移动.ogg"),
		],
		"attack": [
			preload("res://assets/音效/英雄音效_整理后/烈焰祭司/普通攻击.ogg"),
		],
		"pinned": [
			preload("res://assets/音效/英雄音效_整理后/烈焰祭司/被贴身近战.ogg"),
		],
		"skill": [
			preload("res://assets/音效/英雄音效_整理后/烈焰祭司/技能音效.ogg"),
		],
	},
	"烛火": {
		"walk": [
			preload("res://assets/音效/英雄音效_整理后/烛火/移动.ogg"),
		],
		"attack": [
			preload("res://assets/音效/英雄音效_整理后/烛火/普通攻击.ogg"),
		],
		"skill": [
			preload("res://assets/音效/英雄音效_整理后/烛火/技能音效.ogg"),
		],
	},
	"独脚龟": {
		"walk": [
			preload("res://assets/音效/英雄音效_整理后/独脚龟/移动.ogg"),
		],
		"attack": [
			preload("res://assets/音效/英雄音效_整理后/独脚龟/普通攻击.ogg"),
		],
	},
	"猎颅者": {
		"walk": [
			preload("res://assets/音效/英雄音效_整理后/猎颅者/移动.ogg"),
		],
		"attack": [
			preload("res://assets/音效/英雄音效_整理后/猎颅者/普通攻击.ogg"),
		],
		"skill": [
			preload("res://assets/音效/英雄音效_整理后/猎颅者/技能音效.ogg"),
		],
	},
	"白游侠": {
		"walk": [
			preload("res://assets/音效/英雄音效_整理后/白游侠/移动.ogg"),
		],
		"attack": [
			preload("res://assets/音效/英雄音效_整理后/白游侠/普通攻击.ogg"),
		],
		"pinned": [
			preload("res://assets/音效/英雄音效_整理后/白游侠/被贴身近战.ogg"),
		],
	},
	"红帽": {
		"walk": [
			preload("res://assets/音效/英雄音效_整理后/红帽/移动.ogg"),
		],
		"attack": [
			preload("res://assets/音效/英雄音效_整理后/红帽/普通攻击.ogg"),
		],
		"skill": [
			preload("res://assets/音效/英雄音效_整理后/红帽/技能音效.ogg"),
		],
	},
	"血锁": {
		"walk": [
			preload("res://assets/音效/英雄音效_整理后/血锁/移动.ogg"),
		],
		"attack": [
			preload("res://assets/音效/英雄音效_整理后/血锁/普通攻击.ogg"),
		],
		"skill": [
			preload("res://assets/音效/英雄音效_整理后/血锁/技能音效.ogg"),
		],
	},
	"赏金猎人": {
		"walk": [
			preload("res://assets/音效/英雄音效_整理后/赏金猎人/移动.ogg"),
		],
		"attack": [
			preload("res://assets/音效/英雄音效_整理后/赏金猎人/普通攻击.ogg"),
		],
		"pinned": [
			preload("res://assets/音效/英雄音效_整理后/赏金猎人/被贴身近战.ogg"),
		],
	},
	"超新星": {
		"walk": [
			preload("res://assets/音效/英雄音效_整理后/超新星/移动.ogg"),
		],
		"attack": [
			preload("res://assets/音效/英雄音效_整理后/超新星/普通攻击.ogg"),
		],
		"pinned": [
			preload("res://assets/音效/英雄音效_整理后/超新星/被贴身近战.ogg"),
		],
	},
	"锤头鲨": {
		"walk": [
			preload("res://assets/音效/英雄音效_整理后/锤头鲨/移动.ogg"),
		],
		"attack": [
			preload("res://assets/音效/英雄音效_整理后/锤头鲨/普通攻击.ogg"),
		],
	},
	"长剑": {
		"walk": [
			preload("res://assets/音效/英雄音效_整理后/长剑/移动.ogg"),
		],
		"attack": [
			preload("res://assets/音效/英雄音效_整理后/长剑/普通攻击.ogg"),
		],
	},
	"长角": {
		"walk": [
			preload("res://assets/音效/英雄音效_整理后/长角/移动.ogg"),
		],
		"attack": [
			preload("res://assets/音效/英雄音效_整理后/长角/普通攻击.ogg"),
		],
	},
	"雪拳": {
		"walk": [
			preload("res://assets/音效/英雄音效_整理后/雪拳/移动.ogg"),
		],
		"attack": [
			preload("res://assets/音效/英雄音效_整理后/雪拳/普通攻击.ogg"),
		],
		"skill": [
			preload("res://assets/音效/英雄音效_整理后/雪拳/技能音效.ogg"),
		],
	},
	"风语者": {
		"walk": [
			preload("res://assets/音效/英雄音效_整理后/风语者/移动.ogg"),
		],
		"attack": [
			preload("res://assets/音效/英雄音效_整理后/风语者/普通攻击.ogg"),
		],
		"skill": [
			preload("res://assets/音效/英雄音效_整理后/风语者/技能音效.ogg"),
		],
	},
	"骷髅兵": {
		"walk": [
			preload("res://assets/音效/英雄音效_整理后/骷髅兵/移动.ogg"),
		],
		"attack": [
			preload("res://assets/音效/英雄音效_整理后/骷髅兵/普通攻击.ogg"),
		],
	},
	"黄金矿工": {
		"walk": [
			preload("res://assets/音效/英雄音效_整理后/黄金矿工/移动.ogg"),
		],
		"attack": [
			preload("res://assets/音效/英雄音效_整理后/黄金矿工/普通攻击.ogg"),
		],
		"skill": [
			preload("res://assets/音效/英雄音效_整理后/黄金矿工/技能音效.ogg"),
		],
	},
	"鼠队长": {
		"walk": [
			preload("res://assets/音效/英雄音效_整理后/鼠队长/移动.ogg"),
		],
		"attack": [
			preload("res://assets/音效/英雄音效_整理后/鼠队长/普通攻击.ogg"),
		],
	},
}

func _ready() -> void:
	_load_settings()
	_streams = SFX_STREAMS
	# 【2026-09-26 用户要求】按钮点击音效：
	#   用 node_added 统一接管 —— 静态按钮与运行时新建的面板按钮都能覆盖，不用去每个 Button.new() 那里接。
	get_tree().node_added.connect(_on_node_added)
	# 【2026-09-28·用户报「一堆音效在打架」】音效池 4 → 16：
	#   一次攻击链上会连着出好几个音（普攻音 + 攻击喊话 + 命中技能音 + 圣盾音 + 反击音 + 阵亡…），
	#   池子只有 4 个时**第 5 个音会把第 1 个掐断**（见 `_play_stream` 的兜底）⇒ 听着就是打架。
	#   16 个够一屏混战同时发声，内存开销可忽略。
	for i in 16:
		var pl := AudioStreamPlayer.new()
		pl.volume_db = _to_db(_volume)
		add_child(pl)
		_players.append(pl)
	# 语音专用播放器（人声不占音效池，见 `_play_voice`）
	_voice_player = AudioStreamPlayer.new()
	_voice_player.volume_db = _to_db(_volume)
	add_child(_voice_player)
	# 行走音专用播放器 + 节奏定时器（用户报「太密」⇒ 音频不循环，按 `WALK_STEP_SEC` 一响一停）
	_walk_player = AudioStreamPlayer.new()
	_walk_player.volume_db = _to_db(_volume) + WALK_BOOST_DB   # 脚步音额外抬一点，免得被盖住
	add_child(_walk_player)
	_walk_timer = Timer.new()
	_walk_timer.one_shot = false
	_walk_timer.timeout.connect(_on_walk_tick)
	add_child(_walk_timer)
	# 【2026-09-28·用户要求】背景音乐播放器（单独一个，循环；不进音效池 ⇒ 不会被音效抢断，
	#   也不参与"等语音"那套计时）
	_music_player = AudioStreamPlayer.new()
	_music_player.volume_db = _to_db(_volume) + MUSIC_TRIM_DB
	add_child(_music_player)

# 当前音量（0..1 线性）
func get_volume() -> float:
	return _volume

# 设置音量（0..1 线性）：立即作用于所有播放器并持久化
func set_volume(v: float) -> void:
	_volume = clampf(v, 0.0, 1.0)
	for pl in _players:
		if is_instance_valid(pl):
			pl.volume_db = _to_db(_volume)
	if _walk_player != null and is_instance_valid(_walk_player):
		_walk_player.volume_db = _to_db(_volume) + WALK_BOOST_DB
	if _music_player != null and is_instance_valid(_music_player):
		_music_player.volume_db = _to_db(_volume) + MUSIC_TRIM_DB   # 音乐跟着同一个音量，再压 MUSIC_TRIM_DB
	if _voice_player != null and is_instance_valid(_voice_player):
		_voice_player.volume_db = _to_db(_volume)
	_save_settings()

# 线性音量 -> dB（0 处理成 -80 静音，避免 linear_to_db(0)=-inf）
func _to_db(v: float) -> float:
	if v <= 0.0001:
		return -80.0
	return linear_to_db(v)

func _load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) != OK:
		return
	_volume = clampf(float(cfg.get_value("audio", "volume", 1.0)), 0.0, 1.0)

func _save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("audio", "volume", _volume)
	var err := cfg.save(SAVE_PATH)
	if err != OK:
		print("音量存档跳过（无法写入 user://）: ", err)

func play(sfx: String) -> void:
	if not _enabled:
		return
	if not _streams.has(sfx):
		return
	_play_stream(_streams[sfx])

# 【2026-09-28】英雄语音：同一种事件有多条时随机挑一条；没登记/没文件 = 什么都不做。
#   返回值 = 这条语音的时长（秒；没播就是 0）—— 部署登场要"等它播完"才放行
#   （见 `Battle._deploy_wait_entrance()`：用户口径「登场音效结束后才能行动或者登场下一个」）。
func play_hero_voice(display_name: String, kind: String) -> float:
	if not _enabled:
		return 0.0
	var by_kind: Dictionary = HERO_VOICE.get(display_name, {})
	var arr: Array = by_kind.get(kind, [])
	if arr.is_empty():
		# 【2026-09-28·用户口径「没有类似音效的用默认」】阵亡查不到 ⇒ 用默认阵亡音。
		#   `line` 不设默认：登场台词没有"通用版"这种东西（没登记就是安静登场）。
		if kind != "death":
			return 0.0
		var d: AudioStream = DEFAULT_STREAMS["death"]
		_play_voice(d)
		if d == null:
			return 0.0
		_note_voice(d)
		return d.get_length()
	var s: AudioStream = arr[randi() % arr.size()]
	_play_voice(s)
	if s == null:
		return 0.0
	_note_voice(s)
	return s.get_length()

# 【2026-09-28·用户口径「移动应该是在移动中都连续播放」】整段移动期间都有行走音，
#   到 `Battle._finish_move()` 喊 `stop_hero_walk()` 才停。
#   【2026-09-28·用户报「移动的音效有点太密了」】**不再无缝循环**那个 0.18 秒的音频，
#   改成**按固定间隔重播**（一响一停 = 脚步节奏）⇒ 密度由 `WALK_STEP_SEC` 决定：
#   觉得密就往上调（0.4 → 0.5 / 0.6），觉得空就往下调；`Battle` 那边不用动。
const WALK_MAX_SEC := 6.0      ## 兜底：起播后最多响这么久（万一哪条路径漏了喊停）
# 【2026-09-28·用户报「移动音怎么很难听见」】0.4 → 0.25：
#   移动是**逐格滑行、每格 0.2 秒**（`Battle.gd` 的 `tween_property(..., 0.2)`），
#   间隔 0.4 秒时走 1 格只响 1 声、0.185 秒的音一晃就没 ⇒ 听着像"没响"。
#   0.25 秒 ≈ 一步一声（走 2 格 ≈ 2 声），又不会回到当初"无缝循环"那种每秒 5.5 次的密。
const WALK_STEP_SEC := 0.25    ## 脚步间隔（秒）—— 调它就是调节奏密度（嫌密往上调、嫌空往下调）
## 行走音的额外增益（dB）：这条音频本身短促（≈0.18 秒），与普攻/喊话同音量时容易被盖住。
const WALK_BOOST_DB := 4.0
var _walk_token := 0
var _walk_active := false

func play_hero_walk(display_name: String) -> void:
	if not _enabled or _walk_player == null:
		return
	var by_kind: Dictionary = HERO_SFX.get(display_name, {})
	var arr: Array = by_kind.get("walk", [])
	# 【2026-09-28·用户口径「没有类似音效的用默认」】英雄没有行走音 ⇒ 用默认行走音顶上
	var s: AudioStream = arr[randi() % arr.size()] if not arr.is_empty() else DEFAULT_STREAMS["walk"]
	if s == null:
		return
	_walk_player.stream = s
	_walk_player.play()
	_walk_active = true
	if _walk_timer != null:
		_walk_timer.start(WALK_STEP_SEC)   # 之后每 `WALK_STEP_SEC` 秒补一声脚步
	_walk_token += 1
	var tok := _walk_token
	get_tree().create_timer(WALK_MAX_SEC).timeout.connect(func() -> void:
		if tok == _walk_token:
			stop_hero_walk())

# 脚步节奏到点：再响一声（音频本身不循环 ⇒ 一响一停）
func _on_walk_tick() -> void:
	if not _walk_active or _walk_player == null:
		return
	_walk_player.play()

# 停行走音（没在移动时是空操作）
func stop_hero_walk() -> void:
	_walk_active = false
	if _walk_timer != null:
		_walk_timer.stop()
	if _walk_player != null and _walk_player.playing:
		_walk_player.stop()

## 【2026-09-28·用户报「点击认输后背后还有其他音效」】立即**掐掉所有还在响的声音**：
##   行走音是循环节奏（最长 `WALK_MAX_SEC`）、语音/技能音还有一两秒尾巴 —— 认输是"立即收场"，
##   胜负框弹出来时背后不该还夹着打斗声。对局结束（认输）那条路调它，然后再放胜负音。
##   ⚠️ 只用在"收场"场合：正常战斗里别调（会把该放的招式音一起掐掉）。
func stop_all_audio() -> void:
	if _walk_timer != null:
		_walk_timer.stop()
	_walk_active = false
	if _walk_player != null and is_instance_valid(_walk_player):
		_walk_player.stop()
	if _voice_player != null and is_instance_valid(_voice_player):
		_voice_player.stop()
	for pl in _players:
		if is_instance_valid(pl) and pl.playing:
			pl.stop()
	_voice_until_ms = 0   # 顺手清掉"声音播完时刻"，免得 AI 回放等一条已经被掐掉的音

# 【2026-09-28】英雄音效（非语音，原版 `<键>_<事件>` 那一类）：同样随机挑一条。
#   kind = walk(移动) / attack(普通攻击+反击) / skill(技能音效)。
#   返回值 = 这次有没有真的播（调用方用它决定"要不要退回通用音"，见 `Battle._do_attack` /
#   反击两条路径；`skill` 没有通用回退 —— 没登记的英雄就是静默）。
func play_hero_sfx(display_name: String, kind: String) -> bool:
	if not _enabled:
		return false
	var by_kind: Dictionary = HERO_SFX.get(display_name, {})
	var arr: Array = by_kind.get(kind, [])
	if arr.is_empty():
		return false
	var s: AudioStream = arr[randi() % arr.size()]
	_play_stream(s)
	_note_voice(s)
	return true

# ---- 【2026-09-28·用户口径「AI 在没有结束语音之前，玩家不能行动」】----
# 「英雄声音」还剩多久播完的记账：喊话（`play_hero_voice`）与英雄音效（`play_hero_sfx` 的
# attack / skill）都记；`EnemyReplay` 在每一步演出结束后等它，等完才放行下一步 / 交还控制权。
#   ⚠️ **行走音不算**：它是循环节奏（`WALK_MAX_SEC` 最长 6 秒），算进去 AI 走一步就要白等。
#   ⚠️ 时间戳用 `Time.get_ticks_msec()`（真实时间）：音频本来就按真实时间播，不吃 `Engine.time_scale`。
var _voice_until_ms := 0

func _note_voice(s: AudioStream) -> void:
	if s == null:
		return
	_voice_until_ms = maxi(_voice_until_ms, Time.get_ticks_msec() + int(s.get_length() * 1000.0))

## 英雄声音还要多久播完（秒；0 = 现在没有在播的）。
## 按 `Engine.time_scale` 折算成"回放秒"：快进时按倍速缩短，不会让倍速被真实音频时长拖平
## （与 `Battle._replay_wait_action()` 的倍速折算同一口径）。
func voice_time_left() -> float:
	var left := float(_voice_until_ms - Time.get_ticks_msec()) / 1000.0
	if left <= 0.0:
		return 0.0
	return left / maxf(Engine.time_scale, 0.001)

# 【2026-09-28·用户报「一堆音效在打架」】语音走**专用播放器**：
#   同一时刻只出一条人声，新语音打断旧语音 —— 两条喊话叠在一起谁也听不清（两个英雄同时
#   登场/阵亡时原来就会叠）。音效仍走 `_players` 池，两边互不抢占。
func _play_voice(s: AudioStream) -> void:
	if s == null or _voice_player == null:
		return
	_voice_player.stream = s
	_voice_player.play()

# ---- 【2026-09-28·用户要求】背景音乐（BGM）----
#   · 单独一个常驻播放器、循环播；**不进 `_players` 池** ⇒ 不会被音效抢断，也不参与
#     `wait_until_quiet()` / `voice_time_left()`（音乐不该让"等语音"白等）；
#   · 音量跟设置里那一个一起走，再叠固定的 `MUSIC_TRIM_DB`（让音乐压在音效下面）。
const MUSIC_STREAMS := {
	"menu": preload("res://assets/音效/音乐/主菜单.mp3"),    # 菜单页（原版 BGM_Main）
	"battle": preload("res://assets/音效/音乐/战斗.mp3"),    # 战斗中（原版 BGM_BattleJiuGuan）
	"final": preload("res://assets/音效/音乐/决战.mp3"),     # 第 11 回合起烧血阶段（原版 BGM_Final）
}
## 【2026-09-28·用户报「背景音乐太小了」】原来 -8（当初口径"让音乐压在音效下面"）。
##   实测 BGM 素材本身已经比音效低 ~6 dB（战斗 BGM mean −25 vs 普攻 −19），再压 8 dB
##   ⇒ 比音效低 14 dB，几乎听不见。改成 **0**：不再人为压低，响度关系交给素材自己。
##   还嫌小就往正数调（+2 / +4），嫌吵再往负数调。
const MUSIC_TRIM_DB := 0.0
const NO_DEFAULT_CLICK_KEY := "no_default_click"   # 打这个标记的按钮：不挂全局"按钮点击"音
var _music_player: AudioStreamPlayer = null
var _music_key := ""

## 播背景音乐（同一条正在放 ⇒ 什么都不做；换曲直接切）
func play_music(key: String) -> void:
	if _music_player == null or not MUSIC_STREAMS.has(key):
		return
	if _music_key == key and _music_player.playing:
		return
	_music_key = key
	var s: AudioStream = MUSIC_STREAMS[key]
	var mp3 := s as AudioStreamMP3
	if mp3 != null:
		mp3.loop = true   # 原版 BGM 是循环曲
	_music_player.stream = s
	_music_player.play()

func stop_music() -> void:
	_music_key = ""
	if _music_player != null and _music_player.playing:
		_music_player.stop()

## 当前在放哪一条（""= 没放）；探针用
func current_music() -> String:
	return _music_key

## 【2026-09-28·用户口径「快进时候静音」】当前是否在快进（`Engine.time_scale > 1`）。
##   游戏里只有**录像回放 / 录像导出**会把它调大于 1（正常对局与 RL 跑批之外恒为 1）。
func _is_fast_forward() -> bool:
	return Engine.time_scale > 1.01

# 挑一个空闲播放器播这条流（全占用则掐断第一个重播）
func _play_stream(s: AudioStream) -> void:
	if s == null:
		return
	# 【2026-09-28·用户口径「快进时候静音」】快进中**音效一律不播**：
	#   音频按真实时间播（不吃 `time_scale`），60× 下每秒要过几十步 ⇒ 每步都触发一遍招式音，
	#   16 个通道瞬间占满、后面的把前面的掐断 ⇒ 糊成一片噪音。
	#   BGM 不走这里（`play_music` 用独立播放器、单条循环）⇒ 快进时照常放。
	if _is_fast_forward():
		return
	for pl in _players:
		if not pl.playing:
			pl.stream = s
			pl.play()
			return
	_players[0].stream = s
	_players[0].play()

func set_enabled(on: bool) -> void:
	_enabled = on
# ---- 【2026-09-26 用户要求】按钮点击音效（全局）----
# 用 node_added 接管：静态按钮与运行时新建的面板按钮都覆盖，不用去每个 Button.new() 处接线。
func _on_node_added(n: Node) -> void:
	var b := n as BaseButton
	# 【2026-09-28·用户要求】个别按钮要放**专用**点击音（结束回合 = `Click_EndTurn`）：
	#   建按钮时先打 `no_default_click` 标记，这里就不挂全局那一声（挂点必须早于 add_child）。
	if b != null and not b.has_meta(NO_DEFAULT_CLICK_KEY) and not b.pressed.is_connected(_play_click):
		b.pressed.connect(_play_click)

func _play_click() -> void:
	play("click")

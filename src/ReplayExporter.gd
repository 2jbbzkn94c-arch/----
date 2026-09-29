extends RefCounted
## 【2026-09-28 用户要求】把回放**录成能分享的视频**（回放控制条的「开始录制 / 停止录制」按钮）。
##
## 为什么这么做（不依赖任何外部程序）：Godot 运行期**没有**暴露视频编码器 —— 引擎自带的 Movie Writer
##   只能在启动时用 `--write-movie` 打开、运行中切不过去；GDScript 也没有"写子进程 stdin"的接口。
##   但 `Image` 自带 JPEG 编码器 ⇒ 逐帧抓画面编成 JPEG、按 **AVI(MJPEG)** 容器写成一个 `.avi` 文件
##   （Windows 播放器 / 微信 / QQ / 剪辑软件都能直接播）。本机若装了 ffmpeg（PATH 或项目内
##   `tools/ffmpeg.exe`），顺便转成体积更小的 `mp4`（H.264 / yuv420p / +faststart）。
##
## 【2026-09-29 用户要求「导出的视频没有声音」】**必须带声音**，而且**必须有 ffmpeg**：
##   · 声音：录制期间在 **Master 总线**上挂一个 `AudioEffectRecord` ⇒ BGM + 台词 + 音效全录下来，
##     停止时落成一个**临时 wav**，转码时作为第二路输入并进 mp4（`-c:a aac`），转完**立刻删掉**
##     （用户明确「不需要保留 wav」）；
##   · 没有 ffmpeg ⇒ **这次录像一概不保存**（用户原话「没有ffmpeg都不能保存录像」）：收尾后把 avi 与
##     临时 wav 一起删掉，只在画面上给一句「保存录像功能需要下载 ffmpeg 软件」。
##
## 口径（**2026-09-28 用户要求改成"录制开关"**）：
##   · 「开始录制」= 从**按下那一刻**起抓帧（不回到开头、不等开场动画演完、**不动倍速**），
##     「停止录制」（或 ESC）= 收尾存盘；控制条照常留在画面上，也照常录进视频
##     （用户要求「录像的时候状态栏也要出来」）；
##   · 帧率固定 `FPS`（**用户报「录像帧率感觉不高」后由 30 提到 60**），录制期间把**引擎帧率上限
##     也钉到 `FPS`**，再逐帧把 `Engine.time_scale` 调成"观众当时的速度 × 这一帧该推进的游戏时间"
##     （见 `_drive_time_scale()`）⇒ 视频重放出来的速度 == 屏幕上看到的速度，且与帧率无关；
##   · 边抓边写（不落盘帧序列，内存里只有当前一帧）；进度写在**窗口标题**上（不进画面）；
##   · 停止后**弹"保存位置"**（`ReplayPanel.show_saved_popup()`）而不是自动打开文件夹；位置**有记忆**
##     （`rec_dir()` / `set_rec_dir()`，落 `user://replay_video.cfg`）。
##
## 依赖方向：ReplayExporter → Battle（动态调用其回放方法，battle 故意未定型）。

const FPS := 60.0              # 目标帧率（视频帧率）【2026-09-28 用户报「录像帧率感觉不高」】30 → 60：
							   #   30fps 是当初为了修「太快」钉下的，但那样画面本身就是 30fps 的顿感。
							   #   时长仍由逐帧 `time_scale` 补偿保证（见 `_drive_time_scale()`），与帧率无关。
const JPG_QUALITY := 0.9       # JPEG 质量（【2026-09-28 用户报「导出的 MP4 好糊啊」】0.8 → 0.9：
							   #   中间那层 MJPEG 的压缩痕在卡面文字上很明显。体积靠最后那步 x264 压，这层别抠）
const MAX_LONG_SIDE := 1600    # 抓帧后长边**只在这个尺寸之上才缩**（原来写 720，把 720×1280 的窗口缩成
							   #   405×720 ⇒ 用户报「好糊」）。1600 = 用户窗口（720×1280）**原样抓**、
							   #   窗口再放大也只是轻缩；中间 avi 会更大（q0.9 约 300~500KB/帧），
							   #   但它在转出 mp4 之后就被删掉 ⇒ 最终交付的 mp4 大小不受影响。
const MAX_FRAMES := 36000      # 硬上限（60fps × 10 分钟）：异常情况下别把磁盘写满
# 【2026-09-28】AVI 的 `RIFF size` 是**32 位**（见 `_avi_patch_header()`）⇒ 文件一旦逼近 4GB，
#   声明长度就会溢出、整份文件作废。60fps + 原生分辨率下每帧约 200KB ⇒ 约 5 分钟就到坎上。
#   到这里就**主动收尾**（把已抓的部分正常转成 mp4），不硬写出一份坏文件。
const MAX_BYTES := 3800000000
const MUX_TIMEOUT_MS := 1800000   # 转 mp4 的兜底上限（30 分钟）：异常时别把玩家永远按在"保存中"
const NOTICE_HOLD := 3600.0        # 收尾大字横幅的停留秒数：**长到"下一条提示把它替换掉"为止**
								   #   （"录像保存中…"要一直挂到"录像已保存"出现；`_show_turn_banner` 会
								   #    kill 旧 tween + 释放旧标签 ⇒ 后一条提示一定覆盖前一条）
const PATCH_EVERY := 30        # 每这么多帧回填一次头部（≈1 秒）：中途被杀也不会留下"头部全 0"的坏文件
# 【2026-09-29 用户要求「导出的视频没有声音」】录制时**同时录 Master 总线的声音**：
#   挂在总线上 = 背景音乐 + 英雄台词 + 技能音效**全都进**（用户 2026-09-28 确认「要」）。
#   引擎的 `AudioEffectRecord` 就是干这个的：录下来是一段 `AudioStreamWAV`，先落一个**临时 wav**，
#   转码时与画面一起喂给 ffmpeg（`-c:a aac`），转完**立刻删掉 wav**（用户明确「不需要保留 wav」）。
const AUDIO_BUS := "Master"
const AAC_BITRATE := "160k"    # mp4 音轨码率（人声/音效足够；比视频小两个数量级，体积几乎没影响）
# 【2026-09-29 用户要求「完整走完的保存录像只需要 MP4 视频，不需要保存音频和 avi 文件」】
#   中间产物（临时 wav + 抓帧用的 avi）现在放在**游戏自己的 user:// 目录**里，不再丢进保存目录：
#   ⇒ 保存目录里从头到尾**只有最终那一个 mp4**（原来保存过程中会在用户眼前出现 avi/wav，
#     被当成"导出了音频和 avi"）。⚠️ avi 例外地**先留在保存目录、抓完帧才搬进来**：
#     用户早先要求过「中途被杀也要能播」—— 录到一半被杀时，保存目录里那份 avi 是唯一能播的成品。
const TMP_DIR := "user://replay_tmp"

var battle = null
var _dir := ""                 # 本次保存目录（= `rec_dir()`，绝对路径）
var _frames := 0
var _stopped := false
var _prev_max_fps := 0         # 录制前的帧率上限（收尾要还原：见 `run()` 里"钉帧率"的说明）
var _t_start := 0              # 抓帧开始时刻（标题里显示"实际 fps"用）
var _mux_aborted := false      # 转 mp4 被 ESC 中止（保留 avi）
# 录音状态（见 `_audio_start()` / `_audio_stop()`）
var _rec_fx: AudioEffectRecord = null   # 挂在 Master 总线上的录音效果器
var _rec_bus := -1                      # 它挂在第几条总线上
var _wav_abs := ""                      # 临时 wav 的绝对路径（转完 mp4 即删）
var _w := 0
var _h := 0
# AVI 写入状态
var _f: FileAccess = null
var _idx: Array = []           # 每帧 [movi 内偏移, jpg 长度]
var _movi_start := 0           # 'movi' 四字符之后的位置（idx1 的偏移基准）
var _pos_riff := 0
var _pos_hdrl := 0
var _pos_strl := 0
var _pos_movi_size := 0
var _pos_total_frames := 0
var _pos_length := 0
var _pos_avih_flags := 0
var _pos_avih_w := 0
var _pos_avih_h := 0
var _pos_strf_w := 0
var _pos_strf_h := 0
var _pos_strf_img := 0
var _pos_movi_next := 0        # 回填时"movi 数据写到哪了"（收尾时不含 idx1）
var _pos_file_end := 0         # 回填时"整份文件写到哪了"（收尾时含 idx1）—— RIFF 长度用这个

func _init(battle_) -> void:
	battle = battle_

# ---- 保存位置（**有记忆**）----
# 【2026-09-28 用户要求】「停止录制后弹出保存录像位置，录像位置需要有记忆」：
#   记在 `user://replay_video.cfg` 的 `[video] dir` 里（绝对路径）。没记过就用系统"视频"目录下的
#   `酒馆纷争录像`（取不到系统目录再退回 `user://replay_video`）—— 放在"视频"里是为了让用户找得到，
#   那个位置也会在停止录制后的弹框里显示出来，并且可以点「改保存位置…」改掉。
const CFG_PATH := "user://replay_video.cfg"

static func default_rec_dir() -> String:
	var vids := OS.get_system_dir(OS.SYSTEM_DIR_MOVIES)   # Godot 的枚举名是 MOVIES（"视频"目录）
	if vids.strip_edges() != "":
		return vids.path_join("酒馆纷争录像")
	return ProjectSettings.globalize_path("user://replay_video")

static func rec_dir() -> String:
	var cf := ConfigFile.new()
	if cf.load(CFG_PATH) == OK:
		var d := String(cf.get_value("video", "dir", "")).strip_edges()
		if d != "":
			return d
	return default_rec_dir()

static func set_rec_dir(d: String) -> void:
	var cf := ConfigFile.new()
	cf.load(CFG_PATH)   # 有旧内容就照读（只改这一项）；文件不存在也无所谓，save() 会新建
	cf.set_value("video", "dir", d.strip_edges())
	cf.save(CFG_PATH)

## 同名文件已存在就退到 `_2` / `_3` …（同一条录像可以录很多次，别互相覆盖）。
func _unique_path(dir: String, base: String, ext: String) -> String:
	var p := "%s/%s%s" % [dir, base, ext]
	if not FileAccess.file_exists(p):
		return p
	for i in range(2, 100):
		var q := "%s/%s_%d%s" % [dir, base, i, ext]
		if not FileAccess.file_exists(q):
			return q
	return "%s/%s_%d%s" % [dir, base, Time.get_ticks_msec(), ext]

## 让"这一帧"在**游戏时间**轴上正好推进 `倍速 / FPS` 秒：抓帧是"每个渲染帧抓一张"、AVI 又按 `FPS` 播，
## 只有这样重放出来的速度才等于**观众当时屏幕上的那个速度**（1× ⇒ 实时；录的时候按 2× ⇒ 视频里也是 2×）。
## ⚠️ 必须配合"把引擎帧率上限钉在 `FPS`"（`run()` 里做）：否则机器渲染多快、每帧就要多推进多少游戏时间
## （144fps ⇒ 4.8 倍），补偿上限一到视频就整体变快 —— 用户 2026-09-28 报的「默认倍速，太快了」就是这个。
func _drive_time_scale(last_real: float) -> float:
	if not is_instance_valid(battle):
		return last_real
	var scaled: float = battle.get_process_delta_time()   # 已经乘过 time_scale
	var ts: float = maxf(Engine.time_scale, 0.001)
	var real_dt: float = scaled / ts                      # 反推这一帧的真实耗时
	if real_dt <= 0.0:
		return last_real
	var lr: float = real_dt if last_real <= 0.0 else lerpf(last_real, real_dt, 0.25)
	var want: float = maxf(float(battle._replay_speed), 0.1) / FPS
	Engine.time_scale = clampf(want / lr, 0.1, 8.0)
	return lr

## 一次**录制**：从**按下「开始录制」那一刻**起抓帧（不回到开头、不等开场动画、不动倍速），
## 一直录到观众按「停止录制」（或 ESC）为止，然后收尾成 avi（有 ffmpeg 再转 mp4）。
## 返回成品绝对路径（一帧都没抓到/写不出文件则返回空串）。保存位置见 `rec_dir()`（**有记忆**）。
func run(replay_id: String) -> String:
	if not is_instance_valid(battle):
		return ""
	# 保存位置：**上次用的那一处**（用户 2026-09-28 要求「录像位置需要有记忆」）
	_dir = rec_dir()
	if not DirAccess.dir_exists_absolute(_dir):
		DirAccess.make_dir_recursive_absolute(_dir)
	if not DirAccess.dir_exists_absolute(_dir):
		_title("")
		log_msg("录制失败：目录建不出来（%s）" % _dir)
		AudioManager.play("lose")
		return ""
	var avi_abs := _unique_path(_dir, "replay_%s" % replay_id, ".avi")
	_sweep_tmp()   # 【2026-09-29】先把上一次留下的临时文件清掉（崩溃/被杀时可能还留着）
	if not _avi_open(avi_abs):
		_title("")
		log_msg("录制失败：写不出文件（%s）" % avi_abs)
		AudioManager.play("lose")
		return ""
	AudioManager.play("select")   # 开录：给一声
	# 【2026-09-29 用户要求「导出的视频没有声音」】画面开抓的同时开始录音（Master 总线，含 BGM/台词/音效）；
	#   ⚠️ 临时 wav 落在 `user://replay_tmp/`（不进保存目录，见 `TMP_DIR` 的说明）。
	_audio_start(_tmp_abs("replay_%s.wav" % replay_id))
	# 【2026-09-28 用户报「怎么默认倍速，太快了」·真因】画面帧率**必须钉在 `FPS`**：
	#   抓帧是"每个渲染帧抓一张"、AVI 又按 `FPS` 播；每帧推进多少游戏时间靠 `_drive_time_scale()` 补偿。
	#   机器渲染得比 `FPS` 快多少，需要的 `time_scale` 就是那个倍数（`FPS`=60 时：120fps ⇒ 2.0），
	#   而补偿有个上限 ⇒ 高刷屏（或关垂直同步）**顶到上限**后每帧多推进一截 ⇒ 视频整体变快
	#   （用户看到的就是"默认倍速，太快了"）。钉到 `FPS` 之后稳态 `time_scale ≈ 倍速`，正好是屏幕上那个速度。
	_prev_max_fps = Engine.max_fps
	Engine.max_fps = int(FPS)
	_title("录制中…（点「停止录制」或按 ESC 结束）")
	# 一直抓到"你说停"为止：**不看回放循环有没有结束**（录的就是"从现在起的这一段"，
	#   回放演完了就继续录终局画面 —— 用户自己决定什么时候停）。
	var last_real := 0.0
	_t_start = Time.get_ticks_msec()
	while is_instance_valid(battle) and battle.is_inside_tree() and not _stopped:
		await battle.get_tree().process_frame
		if not is_instance_valid(battle) or not battle.is_inside_tree():
			break
		_grab()
		if _frames >= MAX_FRAMES:
			log_msg("录制收尾：已达帧数上限（%d 帧）。" % MAX_FRAMES)
			break
		if _pos_movi_next >= MAX_BYTES:
			log_msg("录制收尾：文件接近 AVI 的 4GB 上限，先存到这里的 %.0f 秒。" % (float(_frames) / FPS))
			break
		last_real = _drive_time_scale(last_real)
	# 【2026-09-29 用户要求「导出的视频没有声音」】抓帧一停，录音也**同时停**（两者时长对齐）。
	#   返回值 = 临时 wav 的绝对路径（没录到声音/没有音频设备则是空串）。
	var wav_abs := _audio_stop()
	# 【2026-09-28 用户要求】停止录制后要给个明示："录像保存中"。
	#   停抓之后还有两段**可能很久**的活：`_avi_finish()` 写 idx1 索引、`_mux()` 用 x264 转 mp4
	#   （文件越大越久，几十秒到几分钟）⇒ 原来这段时间屏幕上什么都不显示，看着像按了没反应。
	#   ⚠️ 标题不进画面，此刻也已经**停止抓帧** ⇒ 不会录进视频。
	_title("录像保存中…（已停止录制，正在写文件，请稍候）")
	# 【2026-09-28 用户要求】光有窗口标题不够醒目 ⇒ 同时在画面中央打一条大字横幅。
	#   ⚠️ 用 HUD 现成的横幅通道（与"蓝方/红方回合""蓝方获胜"同一条，见 `HUD._show_turn_banner`）：
	#   此刻**抓帧已经停了** ⇒ 这行字不会出现在录下来的视频里。
	#   （顺带说明：`log_msg()` 走的是 `Battle.log_message` 信号，而全项目**没有任何界面在听**它，
	#    所以那种"提示"是看不见的 —— 只有探针会连。）
	#   【2026-09-28 用户要求】没找到 ffmpeg：**一点保存就提示**「保存录像功能需要下载 ffmpeg 软件」
	#   （他给的原话）。
	#   【2026-09-29 用户口径更新】没有 ffmpeg ⇒ **这次录像一概不保存**（他原话「没有ffmpeg都不能保存录像」）：
	#   画面 + 声音都收尾（关掉 avi、摘掉录音效果器），把 avi 与临时 wav **一起删掉**，只留那句提示。
	#   （原先"留个 avi 先放着"的兜底按这个口径取消；「不需要没 ffmpeg 时保留 wav」也是同一件事。）
	var ff := _find_ffmpeg()
	# 【2026-09-29】先把 avi 正常收尾（写 idx1 索引 + 回填头部 + **关掉文件句柄**），再把它**搬进临时目录**：
	#   搬完保存目录就干净了（只剩最终那个 mp4），而"录到一半被杀"那份仍然留在保存目录里能播（见 `TMP_DIR`）。
	_avi_finish()
	avi_abs = _move_to_tmp(avi_abs)
	Engine.max_fps = _prev_max_fps
	if ff == "":
		DirAccess.remove_absolute(avi_abs)
		if wav_abs != "":
			DirAccess.remove_absolute(wav_abs)
			log_msg("删除临时音频：%s" % wav_abs)
		_title("")
		_ui_notice("保存录像功能需要下载 ffmpeg 软件")
		log_msg("没有 ffmpeg：这次录像没有保存。保存录像功能需要下载 ffmpeg 软件。")
		AudioManager.play("lose")
		return ""
	_ui_notice("录像保存中…")
	# 收尾：帧率上限还原（倍速**不还原**：那是观众自己的设置，录制只是"记录当时的速度"）
	Engine.max_fps = _prev_max_fps
	AudioManager.play("click")   # 【2026-09-28】录完了：再给一声
	# ⚠️ 标题**不在这里清**：下面转 mp4 还挂着"录像保存中…"（清早了用户就看不到保存进度了），
	#   统一在最后（成品出来之后）清空 —— 见函数末尾。
	# 一帧都没抓到（headless / 无渲染）：删掉空文件、如实报告
	if _frames <= 0:
		DirAccess.remove_absolute(avi_abs)
		if wav_abs != "":
			DirAccess.remove_absolute(wav_abs)
		_title("")
		_ui_notice("这次没录到画面")
		log_msg("录制失败：这一遍没抓到画面（无渲染环境？）")
		return ""
	var out_path := ""   # ⚠️ 只有**验过是能打开的 mp4**才赋值（见下面的 `_mp4_ok()`）
	# ⚠️ 【2026-09-28】进入"转码"这一段时把中止标志**清掉**：`_stopped` 的语义是"中止**当前**这一段" ——
	#   用户刚才按 ESC / 点「停止录制」停的是**录制**，那之后要照常把已录的部分**保存**成 mp4
	#   （这正是他说的"保存中"）；若不清，`_mux()` 轮询的第一帧就会把 ffmpeg 杀掉、只剩 avi。
	#   转码期间再按一次 ESC 才算中止保存。
	_stopped = false
	_title("录像保存中…（正在转 mp4，%.0f 秒素材）" % (float(_frames) / FPS))
	var mp4_abs := _unique_path(_dir, "replay_%s" % replay_id, ".mp4")
	# 【2026-09-29 用户要求「导出的视频没有声音」】把刚录下来的 wav 作为**第二路输入**给 ffmpeg
	#   （`-c:a aac` 压进 mp4）；不管转成功还是失败，这段**临时 wav 一律删掉**（用户明确「不需要保留 wav」）。
	var muxed: bool = await _mux(ff, avi_abs, mp4_abs, wav_abs)
	# 【2026-09-29 用户报「而且无法打开」·真凶】原来只要"文件不是 0 字节"就当成转成功了 ——
	#   可**转码被中途打断**（转码期间按了 ESC / 游戏被杀）时，那个 mp4 是**半截**的：没有 `moov` 原子，
	#   播放器一律报"无法打开"（实测用户目录里那份 8.1MB 的 mp4：`moov atom not found`），
	#   于是"打不开的 mp4"就这样留在保存目录里。现在**结构验一遍**：没有 `moov` 就当失败处理。
	if muxed and _mp4_ok(mp4_abs):
		out_path = mp4_abs
		DirAccess.remove_absolute(avi_abs)      # 转成功：中间 avi 也删掉（它本来就在临时目录里）
	elif FileAccess.file_exists(mp4_abs):
		DirAccess.remove_absolute(mp4_abs)      # 半截 mp4 一律删掉：宁可不留，也不给一个打不开的文件
		log_msg("删除打不开的半截 mp4：%s" % mp4_abs)
	if wav_abs != "":
		DirAccess.remove_absolute(wav_abs)
	_title("")            # 成品出来了：清掉"录像保存中…"
	# 收工提示（此刻抓帧早已结束 ⇒ 不会录进视频）：让"保存中…"有一个明确的结束。
	# ⚠️ 这里**不再自动打开文件夹**：保存位置由 `ReplayPanel.show_saved_popup()` 弹框给出，
	#   用户想打开就点弹框里的「打开文件夹」（用户 2026-09-28 要求"弹出保存录像位置"）。
	#   （"没找到 ffmpeg"那条分支已经在上面**直接返回**了：那种情况什么都不保存，走不到这里。）
	if out_path != "":
		_ui_notice("录像已保存")
		log_msg("录像已保存：%s" % out_path)
	elif _mux_aborted:
		_ui_notice("已中止保存（这次没有成品）")
		log_msg("已中止保存：半截 mp4 已删掉；中间 avi 还在 %s（下次开录会清掉）。" % avi_abs)
	else:
		_ui_notice("转 mp4 失败（这次没有保存）")
		log_msg("转 mp4 失败或成品不完整（缺 moov）：已删掉打不开的 mp4；中间 avi 还在 %s。" % avi_abs)
	return out_path

# ---- 临时文件（中间 avi / 临时 wav）都放这儿，保存目录里从头到尾只有最终那个 mp4 ----

## `user://replay_tmp/` 下的绝对路径（目录不存在就建）。
func _tmp_abs(name: String) -> String:
	var d := ProjectSettings.globalize_path(TMP_DIR)
	if not DirAccess.dir_exists_absolute(d):
		DirAccess.make_dir_recursive_absolute(d)
	return "%s/%s" % [d, name]

## 把文件搬进临时目录（搬不动就原样返回 —— 只是"不好看"，不影响功能）。
## ⚠️ 必须在**关掉文件句柄之后**搬（Windows 上开着句柄改名会失败，见 `_avi_finish()`）。
func _move_to_tmp(path: String) -> String:
	if not FileAccess.file_exists(path):
		return path
	var dst := _tmp_abs(path.get_file())
	var err := DirAccess.rename_absolute(path, dst)
	if err == OK and FileAccess.file_exists(dst):
		return dst
	log_msg("中间文件搬进临时目录失败（err=%d），就地处理：%s" % [err, path])
	return path

## 开录前清一次临时目录：上一次崩溃/被杀留下的中间文件不该越积越多。
## ⚠️ **只清临时目录**，绝不碰保存目录里的东西（那里的 avi 可能是"录到一半被杀"的唯一成品）。
func _sweep_tmp() -> void:
	var d := ProjectSettings.globalize_path(TMP_DIR)
	if not DirAccess.dir_exists_absolute(d):
		return
	var da := DirAccess.open(d)
	if da == null:
		return
	for f in da.get_files():
		DirAccess.remove_absolute("%s/%s" % [d, String(f)])

## 【2026-09-29 用户报「而且无法打开」】成品自检：**不只看大小，还要看结构** ——
##   转码被中途打断留下的 mp4 是半截的（没有 `moov` 原子），播放器一律报"无法打开"
##   （实测用户那份 8.1MB 的产物：ffprobe 原话 `moov atom not found`；同一目录里能播的那份则含 moov）。
##   ffmpeg 是**收尾时才写 moov**、`+faststart` 再把它搬到文件最前面 ⇒ 只看**开头 2MB** 就够，
##   而且不必整份扫（几十上百 MB 的成品也秒回）。
##   ⚠️ 只做"有没有 moov"这一件事：真正的解码校验交给 ffprobe（不保证装了）。
func _mp4_ok(path: String) -> bool:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	var total := f.get_length()
	if total <= 0:
		f.close()
		return false
	var head := f.get_buffer(mini(total, 2 << 20))
	f.close()
	return _has_marker(head, 109, 111, 111, 118)   # 'm','o','o','v'

## 在字节流里找四字符标记（用原生 `PackedByteArray.find()` 定位首字节，别在 GDScript 里逐字节遍历）。
func _has_marker(buf: PackedByteArray, a: int, b: int, c: int, d: int) -> bool:
	var i := buf.find(a)
	while i >= 0 and i + 3 < buf.size():
		if buf[i + 1] == b and buf[i + 2] == c and buf[i + 3] == d:
			return true
		i = buf.find(a, i + 1)
	return false

## 画面中央的大字提示（走 HUD 现成的回合横幅通道）。抓帧已停时才调用 ⇒ 不会录进视频。
## 只给"保存中/已保存"这类**导出收尾**用（用户 2026-09-28 要求按 ESC 后要有提示）。
## ⚠️ 【2026-09-28 用户贴的报错】必须确认 HUD **还在场景树里**再叫它：`_show_turn_banner()` 第一行就
##   用 `get_viewport()`，而"已经离开树/正在释放"的节点 `get_viewport()` 是 null ⇒
##   `Cannot call method 'get_visible_rect' on a null value`（用户那次是"结果横幅那 6 秒里点了导出"，
##   场景被 `_replay_auto_back()` 切走 —— 那边也一并修了）。提示本身是锦上添花，**绝不该让它报错**。
func _ui_notice(txt: String) -> void:
	if not is_instance_valid(battle) or not battle.is_inside_tree():
		return
	var hud = battle._hud
	if hud == null or not is_instance_valid(hud) or not hud.is_inside_tree():
		return
	if hud.get_viewport() == null:
		return
	if hud.has_method("_show_turn_banner"):
		hud._show_turn_banner(txt, Color(1.0, 0.88, 0.5), NOTICE_HOLD)

func stop() -> void:
	_stopped = true

func frame_count() -> int:
	return _frames

func out_dir() -> String:
	return _dir

# ---- 抓帧 ----

## 抓当前画面编成 JPEG 写进 AVI。⚠️ headless（无渲染）取不到图 ⇒ 静默跳过，不让导出流程炸掉。
func _grab() -> void:
	if _f == null or not is_instance_valid(battle):
		return
	var vp: Viewport = battle.get_viewport()
	if vp == null:
		return
	var tex: ViewportTexture = vp.get_texture()
	if tex == null:
		return
	var img: Image = tex.get_image()
	if img == null or img.get_width() <= 0 or img.get_height() <= 0:
		return
	# 【2026-09-28 用户报「怎么这么大」→ 又报「导出的 MP4 好糊啊」】缩放口径的最终折中：
	#   只按**长边超过 `MAX_LONG_SIDE`** 才缩（用户窗口 720×1280 ⇒ 原尺寸抓，不再缩成 405×720），
	#   真缩的时候用 LANCZOS（双线性在 0.56× 这种比例下会糊成一团）。
	#   ⚠️ 原生尺寸时 `get_width()` 与 `_w` 相等 ⇒ 下面那次 `resize()` 整段跳过，零额外开销。
	if _frames == 0:
		var long_side: int = maxi(img.get_width(), img.get_height())
		if long_side > MAX_LONG_SIDE:
			var sc := float(MAX_LONG_SIDE) / float(long_side)
			_w = maxi(int(round(float(img.get_width()) * sc)), 2)
			_h = maxi(int(round(float(img.get_height()) * sc)), 2)
		else:
			_w = img.get_width()
			_h = img.get_height()
		# ⚠️⚠️ 【2026-09-28 用户报「mp4 大小是 0」·真因】x264（yuv420p）**要求宽高都是偶数**：
		#   720×1280 缩到长边 720 时算出 405×720，宽是奇数 ⇒ ffmpeg 建好输出文件后编码器初始化失败、
		#   留下一个 **0 字节的 mp4**。这里把宽高都压到偶数（缩一两个像素，肉眼无差别）。
		_w -= _w % 2
		_h -= _h % 2
		_w = maxi(_w, 2)
		_h = maxi(_h, 2)
	if img.get_width() != _w or img.get_height() != _h:
		img.resize(_w, _h, Image.INTERPOLATE_LANCZOS)   # 首帧缩放 / 窗口尺寸中途变了：统一到 _w×_h
	_avi_frame(img.save_jpg_to_buffer(JPG_QUALITY))
	if _frames % 15 == 0:
		# 【2026-09-28】标题里带上**实际抓帧速率**：用户报「帧率感觉不高」时要能一眼看出
		#   "机器到底跟不跟得上 60fps"（跟不上 ⇒ 视频仍是实时、但每秒只有更少张不同的画面）。
		var el := float(Time.get_ticks_msec() - _t_start) / 1000.0
		var real_fps := float(_frames) / el if el > 0.5 else 0.0
		_title("导出中… %d 帧（%.0f 秒视频 · %d×%d · 实际 %.0f fps）" % [
			_frames, float(_frames) / FPS, _w, _h, real_fps])

func _title(s: String) -> void:
	DisplayServer.window_set_title("酒馆纷争（战棋原型）" if s == "" else "酒馆纷争 · %s" % s)

func log_msg(s: String) -> void:
	if is_instance_valid(battle) and battle.has_signal("log_message"):
		battle.log_message.emit(s)

# ---- AVI(MJPEG) 写入 ----
# 结构：RIFF('AVI ') → LIST(hdrl: avih + LIST(strl: strh + strf)) → LIST(movi: 每帧 '00dc'+JPEG) → idx1
# 所有"写的时候还不知道"的长度/尺寸都**记下位置**、收尾时按位置回填（不写死偏移，免得布局一改就错）。

func _avi_open(path: String) -> bool:
	_f = FileAccess.open(path, FileAccess.WRITE)
	if _f == null:
		return false
	_idx.clear()
	_f.store_buffer(_fcc("RIFF"))
	_pos_riff = _f.get_position()
	_f.store_32(0)                      # RIFF size（回填）
	_f.store_buffer(_fcc("AVI "))
	_f.store_buffer(_fcc("LIST"))
	_pos_hdrl = _f.get_position()
	_f.store_32(0)                      # hdrl LIST size（回填）
	_f.store_buffer(_fcc("hdrl"))
	_f.store_buffer(_fcc("avih"))
	_f.store_32(56)
	_f.store_32(int(1000000.0 / FPS))   # dwMicroSecPerFrame
	_f.store_32(0)                      # dwMaxBytesPerSec
	_f.store_32(0)                      # dwPaddingGranularity
	_pos_avih_flags = _f.get_position()
	_f.store_32(0x10)                   # dwFlags：见 `_avi_patch_header()` 的说明（收尾时才置 HASINDEX）
	_pos_total_frames = _f.get_position()
	_f.store_32(0)                      # dwTotalFrames（回填）
	_f.store_32(0)                      # dwInitialFrames
	_f.store_32(1)                      # dwStreams
	_f.store_32(0)                      # dwSuggestedBufferSize
	_pos_avih_w = _f.get_position()
	_f.store_32(0)                      # dwWidth（回填）
	_pos_avih_h = _f.get_position()
	_f.store_32(0)                      # dwHeight（回填）
	for i in 4:
		_f.store_32(0)                  # dwReserved[4]
	_f.store_buffer(_fcc("LIST"))
	_pos_strl = _f.get_position()
	_f.store_32(0)                      # strl LIST size（回填）
	_f.store_buffer(_fcc("strl"))
	_f.store_buffer(_fcc("strh"))
	_f.store_32(56)
	_f.store_buffer(_fcc("vids"))
	_f.store_buffer(_fcc("MJPG"))
	_f.store_32(0)                      # dwFlags
	_f.store_16(0)                      # wPriority
	_f.store_16(0)                      # wLanguage
	_f.store_32(0)                      # dwInitialFrames
	_f.store_32(1)                      # dwScale
	_f.store_32(int(FPS))               # dwRate
	_f.store_32(0)                      # dwStart
	_pos_length = _f.get_position()
	_f.store_32(0)                      # dwLength（回填：帧数）
	_f.store_32(0)                      # dwSuggestedBufferSize
	_f.store_32(0xFFFFFFFF)             # dwQuality = -1（默认）
	_f.store_32(0)                      # dwSampleSize
	for i in 4:
		_f.store_16(0)                  # rcFrame
	_f.store_buffer(_fcc("strf"))
	_f.store_32(40)                     # strf 这个块的 data 长度
	# ⚠️⚠️ BITMAPINFOHEADER 的**第一个字段是 `biSize`（本体长度 = 40）**。2026-09-28 少写了这一行 ⇒
	#   后面全体错位 4 字节：ffmpeg 把 biHeight 读成 `planes|bits` 拼出来的 1572865、把编码器读成
	#   `[0]0[42][0]` ⇒ "unknown codec"、播放器说"打不开"。ffmpeg 的原话：
	#   `Could not find codec parameters for stream 0 (Video: none, none, 1280x1572865): unknown codec`。
	_f.store_32(40)                     # biSize
	_pos_strf_w = _f.get_position()
	_f.store_32(0)                      # biWidth（回填）
	_pos_strf_h = _f.get_position()
	_f.store_32(0)                      # biHeight（回填）
	_f.store_16(1)                      # biPlanes
	_f.store_16(24)                     # biBitCount
	_f.store_buffer(_fcc("MJPG"))       # biCompression
	_pos_strf_img = _f.get_position()
	_f.store_32(0)                      # biSizeImage（回填）
	_f.store_32(0)                      # biXPelsPerMeter
	_f.store_32(0)                      # biYPelsPerMeter
	_f.store_32(0)                      # biClrUsed
	_f.store_32(0)                      # biClrImportant
	_f.store_buffer(_fcc("LIST"))
	_pos_movi_size = _f.get_position()
	_f.store_32(0)                      # movi LIST size（回填）
	_f.store_buffer(_fcc("movi"))
	_movi_start = _f.get_position()
	return true

func _avi_frame(jpg: PackedByteArray) -> void:
	if _f == null or jpg.is_empty():
		return
	_frames += 1
	# 【2026-09-28 用户报「录像文件损坏」】idx1 的偏移基准 = 'movi' 四字符的位置（业界口径）。
	#   ⚠️ 索引本身**只在收尾时写一次**；为了让"中途被杀"的文件也能播，头每 `PATCH_EVERY` 帧回填一次
	#   （见 `_avi_patch_header()`）。
	var off := _f.get_position() - (_movi_start - 4)
	_f.store_buffer(_fcc("00dc"))
	_f.store_32(jpg.size())
	_f.store_buffer(jpg)
	if jpg.size() % 2 == 1:
		_f.store_8(0)                  # 块按偶数对齐（size 字段仍是真实长度）
	_idx.append([off, jpg.size()])
	_pos_movi_next = _f.get_position()
	if _frames % PATCH_EVERY == 0:
		_avi_patch_header(false)

## 【2026-09-28 用户报「录像文件损坏」·真因】导出**中途被杀/关掉游戏**时，原来的写法从没回填过头
##   ⇒ 文件开头 `RIFF size / dwTotalFrames / movi size` 全是 0、也没有 idx1 ⇒ 播放器一律报"文件损坏"
##   （实测他那两份 100MB / 804MB 的 avi 就是这个状态）。现在：每 `PATCH_EVERY` 帧把长度/帧数/宽高
##   回填一次，并且**在收尾之前不声明 `AVIF_HASINDEX`**（索引是收尾才写的）⇒ 任何时刻被中断，
##   文件都是"能播到上一处回填点"的合法 AVI。`final = true` 时才写 idx1、置 HASINDEX。
func _avi_patch_header(final: bool) -> void:
	if _f == null:
		return
	var saved := _f.get_position()          # 记住当前写到哪里（回填完要跳回来继续写帧）
	var movi_end := _pos_movi_next
	# ⚠️ RIFF 长度 = **整个文件**（收尾时含 idx1）；movi 长度只到 movi 数据末尾。两者混用会让文件
	#   "声明长度比实际短"，Windows Media Player 直接判损坏 —— 2026-09-28 用户报的「打不开」就是这个：
	#   实测声明值比实际短 **61320 字节 = idx1 的大小**。
	var file_end: int = maxi(_pos_file_end, movi_end)
	_f.seek(_pos_riff);          _f.store_32(file_end - 8)                            # RIFF size（含 idx1）
	_f.seek(_pos_hdrl);          _f.store_32(_hdrl_data_end() - (_pos_hdrl + 8))
	_f.seek(_pos_strl);          _f.store_32(_hdrl_data_end() - (_pos_strl + 8))
	_f.seek(_pos_total_frames);  _f.store_32(_frames)                                 # dwTotalFrames
	_f.seek(_pos_length);        _f.store_32(_frames)                                 # strh.dwLength
	_f.seek(_pos_movi_size);     _f.store_32(movi_end - (_movi_start - 4))            # movi LIST size
	_f.seek(_pos_avih_w);        _f.store_32(_w)
	_f.seek(_pos_avih_h);        _f.store_32(_h)
	_f.seek(_pos_strf_w);        _f.store_32(_w)
	_f.seek(_pos_strf_h);        _f.store_32(_h)
	_f.seek(_pos_strf_img);      _f.store_32(_w * _h * 3)
	_f.seek(_pos_avih_flags);    _f.store_32(0x10 if final else 0)                    # AVIF_HASINDEX
	_f.seek(saved)
	_f.flush()

func _hdrl_data_end() -> int:
	return _pos_movi_size - 4               # movi 的 'LIST' 四字符位置

func _avi_finish() -> void:
	if _f == null:
		return
	var movi_end := _f.get_position()
	# idx1（帧索引）：**只有走到收尾才写**，写完才敢在 avih 里声明 AVIF_HASINDEX
	_f.store_buffer(_fcc("idx1"))
	_f.store_32(_idx.size() * 16)
	for e in _idx:
		_f.store_buffer(_fcc("00dc"))
		_f.store_32(0x10)              # AVIIF_KEYFRAME
		_f.store_32(int(e[0]))
		_f.store_32(int(e[1]))
	_pos_movi_next = movi_end          # 回填用：movi 数据到此为止（idx1 不算进 movi）
	_pos_file_end = _f.get_position()  # 回填用：**整份文件**到此为止（含 idx1）—— RIFF 长度用它
	_avi_patch_header(true)
	_f.close()
	_f = null

func _fcc(s: String) -> PackedByteArray:
	return s.to_ascii_buffer()

# ---- 录音（Master 总线 → 临时 wav → 转码时并进 mp4）----

## 【2026-09-29 用户要求「导出的视频没有声音」】开始录 Master 总线上的声音。
## 挂在 **Master** 上 ⇒ 背景音乐 + 英雄台词 + 技能音效**全录**（用户确认「要」，没有要求排除 BGM）。
## ⚠️ 录的是**总线输出**（含玩家设的音量），"观众在扬声器里听到什么"就录到什么。
## ⚠️ 不用 `OS.execute` 之类外部程序：`AudioEffectRecord` 是引擎自带的，headless/无音频设备时静默降级
##   （`get_recording()` 返回 null ⇒ 这次录像不带音轨，不报错、不中断录制）。
func _audio_start(wav_abs: String) -> void:
	_wav_abs = ""
	var bus := AudioServer.get_bus_index(AUDIO_BUS)
	if bus < 0:
		log_msg("录音启动失败：找不到 %s 总线 —— 这次录像不会带音轨。" % AUDIO_BUS)
		return
	var fx := AudioEffectRecord.new()
	AudioServer.add_bus_effect(bus, fx)   # ⚠️ 这个 API 不返回序号：效果器是**追加在末尾**的
	_rec_fx = fx
	_rec_bus = bus
	_wav_abs = wav_abs
	fx.set_recording_active(true)

## 停录 + 落成 wav，返回 wav 的绝对路径（没录到声音/写不出则空串）。
## ⚠️ 效果器**必须摘掉**：不摘的话下次录制会在总线上再叠一个（而且一直挂着白耗性能）。
func _audio_stop() -> String:
	var fx := _rec_fx
	_rec_fx = null
	if fx == null:
		return ""
	fx.set_recording_active(false)
	var out := ""
	var wav: AudioStreamWAV = fx.get_recording()
	if wav != null and wav.data.size() > 0:
		var bpf := 2 if wav.format == AudioStreamWAV.FORMAT_16_BITS else 1   # 每采样字节
		if wav.stereo:
			bpf *= 2
		log_msg("录音完成：%.1f 秒（%d Hz，%d 字节）。" % [
			float(wav.data.size()) / maxf(float(wav.mix_rate * bpf), 1.0), wav.mix_rate, wav.data.size()])
		if wav.save_to_wav(_wav_abs) == OK and FileAccess.file_exists(_wav_abs):
			out = _wav_abs
		else:
			log_msg("录音落盘失败：%s" % _wav_abs)
	else:
		log_msg("录音里没有声音（无音频设备 / headless？）——这次录像不带音轨。")
	if _rec_bus >= 0:
		for i in AudioServer.get_bus_effect_count(_rec_bus):
			if AudioServer.get_bus_effect(_rec_bus, i) == fx:
				AudioServer.remove_bus_effect(_rec_bus, i)
				break
	_rec_bus = -1
	return out

# ---- ffmpeg（**必须有**：没有就一概不保存，见 `run()`）----

## 找 ffmpeg。**没有它就一概不保存**（见 `run()` —— 用户 2026-09-28 口径）。顺序：项目内 `tools/` → 项目根下的 `ffmpeg*` 目录 →
## PATH 里的目录 → winget / chocolatey / scoop / `C:\ffmpeg\bin` 等常见位置。
## ⚠️ 【2026-09-28 用户贴的报错】**不要**直接 `OS.execute("ffmpeg", …)` 拿裸名字试 PATH ——
##   找不到时 Godot 会打一条红字：`Could not create child process: ffmpeg -version` + `ERR_CANT_FORK`
##   （`platform/windows/os_windows.cpp: execute()`）。改成**先按 PATH 拼出完整路径、`FileAccess.file_exists()`
##   命中才执行**，整条探测路径一声不响。
func _find_ffmpeg() -> String:
	var cands: Array = ["res://tools/ffmpeg.exe", "res://tools/ffmpeg"]
	# 项目根目录下解压的 ffmpeg 发行包（用户把 full build 解压在 `战旗\ffmpeg-9.0-full_build\`）：
	#   目录名带版本号 ⇒ 扫一遍项目根下以 `ffmpeg` 开头的目录，取它们里面的 `bin/ffmpeg.exe`。
	var root := DirAccess.open("res://")
	if root != null:
		var subs: Array = root.get_directories()
		subs.sort()
		for sub in subs:
			if String(sub).to_lower().begins_with("ffmpeg"):
				cands.append("res://%s/bin/ffmpeg.exe" % String(sub))
	# PATH 里的每个目录（不执行裸名字，只查文件在不在）
	for dir in OS.get_environment("PATH").split(";"):
		var d := String(dir).strip_edges()
		if d != "":
			cands.append(d.path_join("ffmpeg.exe"))
	var local := OS.get_environment("LOCALAPPDATA")
	if local != "":
		cands.append(local + "/Microsoft/WinGet/Links/ffmpeg.exe")   # winget 装的
	var home := OS.get_environment("USERPROFILE")
	if home != "":
		cands.append(home + "/scoop/shims/ffmpeg.exe")               # scoop 装的
	cands.append_array(["C:/ffmpeg/bin/ffmpeg.exe", "C:/Program Files/ffmpeg/bin/ffmpeg.exe",
			"C:/ProgramData/chocolatey/bin/ffmpeg.exe"])
	var seen := {}
	for p in cands:
		# ⚠️ 别叫 `abs`：那会遮住内置函数 `abs()`，Godot 报 SHADOWED_GLOBAL_IDENTIFIER
		var exe_path: String = String(p)
		if exe_path.begins_with("res://"):
			if not FileAccess.file_exists(exe_path):
				continue
			exe_path = ProjectSettings.globalize_path(exe_path)
		elif not FileAccess.file_exists(exe_path):
			continue
		if seen.has(exe_path):
			continue
		seen[exe_path] = true
		var out: Array = []
		if OS.execute(exe_path, ["-version"], out, true) == 0:
			return exe_path
	return ""

## 转 mp4（画面来自中间 avi，**声音来自录音落下的临时 wav**）。⚠️ 【2026-09-28 用户要求「点击 ESC 后需要提示录像保存中」】**不能再用 `OS.execute()`**：
##   那个是**阻塞**的，转码几十秒里窗口会变成"无响应"，标题上的"录像保存中…"根本刷不出来
##   （Windows 对无响应窗口不重绘标题栏）。所以改成 `OS.create_process()` + 逐帧轮询：
##   窗口全程可响应、标题里的秒数一直在走，**按 ESC 还能把转码一并中止**（保留 avi）。
## 返回 true = 转码成功且成品非空。
func _mux(ff: String, in_abs: String, out_abs: String, wav_abs := "") -> bool:
	var args := ["-y", "-i", in_abs]
	# 【2026-09-29 用户要求「导出的视频没有声音」】有录音就作为第二路输入：`-c:a aac` 压进 mp4。
	#   `-shortest` = 以**短的那一路**为准收尾（画面和声音是两次独立计时，尾部差个零点几秒很正常，
	#   不加这句 mp4 会被音频拖出一条黑尾）。没录到声音（空串 / 文件不在）就照旧出**无声**视频。
	var has_audio := wav_abs != "" and FileAccess.file_exists(wav_abs)
	if has_audio:
		args.append_array(["-i", wav_abs])
	args.append_array([
		# 保险：宽高若有奇数（x264 + yuv420p 不吃奇数）就裁掉 1 像素 —— 抓帧那边已经压成偶数了，
		# 这一句是防"窗口中途改尺寸/其它来源"再踩同一个坑（否则会留下一个 0 字节的 mp4）。
		"-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2",
		"-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "18", "-movflags", "+faststart",
	])
	if has_audio:
		args.append_array(["-c:a", "aac", "-b:a", AAC_BITRATE, "-ac", "2", "-shortest"])
	args.append(out_abs)
	var loc := ProjectSettings.localize_path(out_abs)
	var pid := OS.create_process(ff, args)
	if pid <= 0:
		log_msg("转 mp4 失败：起不了 ffmpeg 进程。")
		return false
	var t0 := Time.get_ticks_msec()
	while OS.is_process_running(pid):
		if _stopped:
			OS.kill(pid)   # ESC：连转码一起停（avi 原文件保留，照样能播）
			_mux_aborted = true
			break
		if Time.get_ticks_msec() - t0 > MUX_TIMEOUT_MS:
			OS.kill(pid)
			log_msg("转 mp4 超时（%d 秒），保留 avi。" % int(MUX_TIMEOUT_MS / 1000.0))
			break
		_title("录像保存中…（正在转 mp4：已 %d 秒，%.0f 秒素材）" % [
			int((Time.get_ticks_msec() - t0) / 1000.0), float(_frames) / FPS])
		if is_instance_valid(battle) and battle.is_inside_tree():
			await battle.get_tree().process_frame
		else:
			var ml := Engine.get_main_loop()
			if ml is SceneTree:
				await (ml as SceneTree).process_frame
			else:
				break   # 没有场景树（理论到不了）：别死等
	if _mux_aborted:
		return false
	var ok := FileAccess.file_exists(loc) and _file_size(loc) > 0
	if not ok:
		# 转失败：**删掉那个 0 字节的残file**（用户报过"mp4 大小是 0"），avi 留着照样能播
		if FileAccess.file_exists(loc):
			DirAccess.remove_absolute(loc)
		log_msg("转 mp4 失败：%s" % loc)
	return ok

func _file_size(path: String) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return -1
	var n := f.get_length()
	f.close()
	return n

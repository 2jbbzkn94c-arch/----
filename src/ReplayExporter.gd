extends RefCounted
## 【2026-09-28 用户要求】把一条录像**导出成能分享的视频**（回放控制条的「导出」按钮）。
##
## 为什么这么做（不依赖任何外部程序）：Godot 运行期**没有**暴露视频编码器 —— 引擎自带的 Movie Writer
##   只能在启动时用 `--write-movie` 打开、运行中切不过去；GDScript 也没有"写子进程 stdin"的接口。
##   但 `Image` 自带 JPEG 编码器 ⇒ 逐帧抓画面编成 JPEG、按 **AVI(MJPEG)** 容器写成一个 `.avi` 文件
##   （Windows 播放器 / 微信 / QQ / 剪辑软件都能直接播）。本机若装了 ffmpeg（PATH 或项目内
##   `tools/ffmpeg.exe`），顺便转成体积更小的 `mp4`（H.264 / yuv420p / +faststart）。
##
## 口径：
##   · 导出 = 把回放**从头重播一遍**（控制条照常留在画面上——用户 2026-09-28 要求「录像的时候状态栏也要出来」），
##     跑到末段结束为止；
##   · 帧率固定 `FPS`，导出期间把**引擎帧率上限也钉到 `FPS`**（钉不住的话机器渲染多快、每帧就要多推进
##     多少游戏时间，补偿上限一到视频就整体变快，见 `run()` 里那段说明），再逐帧把 `Engine.time_scale`
##     调成"这一帧真实耗时 → 目标帧长"的比例 ⇒ 动画/停顿都按固定步长推进，视频时长 ≈ 回放时长；
##   · 边抓边写（不落盘帧序列，内存里只有当前一帧）；进度写在**窗口标题**上（不进画面）；
##   · 结束后把成品所在目录打开（`OS.shell_open`）。
##
## 依赖方向：ReplayExporter → Battle（动态调用其回放方法，battle 故意未定型）。

const FPS := 30.0              # 目标帧率（视频帧率）
const JPG_QUALITY := 0.9       # JPEG 质量（【2026-09-28 用户报「导出的 MP4 好糊啊」】0.8 → 0.9：
							   #   中间那层 MJPEG 的压缩痕在卡面文字上很明显。体积靠最后那步 x264 压，这层别抠）
const MAX_LONG_SIDE := 1600    # 抓帧后长边**只在这个尺寸之上才缩**（原来写 720，把 720×1280 的窗口缩成
							   #   405×720 ⇒ 用户报「好糊」）。1600 = 用户窗口（720×1280）**原样抓**、
							   #   窗口再放大也只是轻缩；中间 avi 会更大（q0.9 约 300~500KB/帧），
							   #   但它在转出 mp4 之后就被删掉 ⇒ 最终交付的 mp4 大小不受影响。
const MAX_FRAMES := 36000      # 硬上限（30fps × 20 分钟）：异常情况下别把磁盘写满
const PATCH_EVERY := 30        # 每这么多帧回填一次头部（≈1 秒）：中途被杀也不会留下"头部全 0"的坏文件
const OUT_DIR := "user://replay_video"

var battle = null
var _rel_dir := ""
var _dir := ""
var _frames := 0
var _stopped := false
var _prev_max_fps := 0         # 导出前的帧率上限（收尾要还原：见 `run()` 里"钉 30fps"的说明）
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

## 跑完一次导出。返回成品绝对路径（avi 或 mp4）；失败返回空串。
func run(replay_id: String) -> String:
	if not is_instance_valid(battle):
		return ""
	# 【2026-09-28 用户报「部署阶段点击导出，部署阶段上人还是会乱」】先给一声反馈 + 窗口标题提示，
	#   **然后等回放开场流程跑完**（`replay_is_ready()`）再动手：开场那段自带"部署逐手动画"，
	#   它还没结束时导出这边会 seek 回第 0 段 ⇒ 两趟上人抢盘面（就是用户看到的"乱"）。
	_title("导出准备中…（按 ESC 可取消）")
	AudioManager.play("select")
	var tw := Time.get_ticks_msec()
	while is_instance_valid(battle) and not bool(battle.replay_is_ready()) and not _stopped \
			and Time.get_ticks_msec() - tw < 60000:
		await battle.get_tree().process_frame
	if not is_instance_valid(battle):
		_title("")
		return ""
	if _stopped:
		_title("")
		log_msg("已取消导出。")
		return ""
	var stamp := Time.get_datetime_string_from_system().replace(":", "").replace("-", "").replace("T", "_")
	_rel_dir = "%s/%s" % [OUT_DIR, stamp]
	_dir = ProjectSettings.globalize_path(_rel_dir)
	if not DirAccess.dir_exists_absolute(_rel_dir):
		DirAccess.make_dir_recursive_absolute(_rel_dir)
	var avi_abs := "%s/replay_%s.avi" % [_dir, replay_id]
	if not _avi_open(avi_abs):
		_title("")
		log_msg("导出失败：写不出文件（%s）" % avi_abs)
		return ""
	# 【2026-09-28 用户要求】导出期间控制条**不藏了**（用户原话「录像的时候状态栏也要出来」）。
	#   原来这里把它 `visible = false`（怕录进画面）⇒ 导出的视频里没有任何操作条。
	# 倍速先归 1×（下面逐帧自己调 time_scale）。
	battle.replay_set_paused(true)
	battle.replay_set_speed(1.0)
	# 【2026-09-28 用户报「怎么默认倍速，太快了」·真因】画面帧率**必须钉在 30**：
	#   抓帧是"每个渲染帧抓一张"、AVI 又按 30fps 播；每帧推进多少游戏时间靠下面的 `time_scale` 补偿。
	#   机器渲染得比 30fps 快多少，需要的 `time_scale` 就是那个倍数（60fps ⇒ 2.0、144fps ⇒ 4.8），
	#   而补偿有个 `clampf(..., 0.1, 4.0)` 上限 ⇒ 高刷屏（或关垂直同步）**顶到上限**后每帧多推进一截
	#   ⇒ 视频与屏幕上的导出过程一起"快了 4 倍"（用户看到的就是这个）。把上限帧率钉到 30 之后，
	#   稳态所需 `time_scale ≈ 1.0`，既不再顶上限，屏幕上看到的也正好是真实速度。
	_prev_max_fps = Engine.max_fps
	Engine.max_fps = int(FPS)
	_title("导出中…（按 ESC 可中止）")
	# 回到第 0 段（整局从头演）并等跳段落地
	var seq: int = int(battle._replay_seek_seq)
	battle.replay_seek_frame(0)
	var t_wait := Time.get_ticks_msec()
	while int(battle._replay_seek_seq) == seq and Time.get_ticks_msec() - t_wait < 30000:
		await battle.get_tree().process_frame
		if not is_instance_valid(battle):
			break
	if is_instance_valid(battle):
		battle.replay_set_paused(false)
	# 逐帧抓图（直到回放循环收工）
	var last_real := 0.0
	while is_instance_valid(battle) and battle.is_inside_tree() and not _stopped:
		await battle.get_tree().process_frame
		if not is_instance_valid(battle) or not battle.is_inside_tree():
			break
		var live: bool = bool(battle._replay_loop_running) or bool(battle._replay_seeking)
		_grab()
		if _frames >= MAX_FRAMES:
			break
		if not live:
			break   # 回放已跑完（末段演完 → 结果横幅那一拍也照录）
		# 帧时长补偿：让"这一帧"在引擎时间轴上正好等于 1/FPS 秒（掉帧也不会让视频变快）
		var scaled: float = battle.get_process_delta_time()     # 已经乘过 time_scale
		var ts: float = maxf(Engine.time_scale, 0.001)
		var real_dt: float = scaled / ts                        # 反推这一帧的真实耗时
		if real_dt > 0.0:
			last_real = real_dt if last_real <= 0.0 else lerpf(last_real, real_dt, 0.25)
			# 上限从 4.0 放到 8.0：钉了 30fps 之后稳态就在 1.0 附近，这个上限只兜"偶发卡顿"
			# （掉一帧 ⇒ 每帧多推进一点补回来，视频总长仍 ≈ 回放时长）。
			Engine.time_scale = clampf((1.0 / FPS) / last_real, 0.1, 8.0)
	_avi_finish()
	# 收尾：时间尺度、帧率上限、控制条、标题全部还原（中止/正常结束都走这里）
	Engine.time_scale = 1.0
	Engine.max_fps = _prev_max_fps
	if is_instance_valid(battle):
		battle.replay_set_speed(1.0)
	_title("")
	AudioManager.play("click")   # 【2026-09-28】录完了（或中止了）：再给一声，表示导出收工
	# 一帧都没抓到（headless / 无渲染）：删掉空文件、如实报告
	if _frames <= 0:
		DirAccess.remove_absolute(avi_abs)
		log_msg("导出失败：这一遍没抓到画面（无渲染环境？）")
		return ""
	var out_path := avi_abs
	var ff := _find_ffmpeg()
	if ff != "" and _frames > 0:
		_title("正在转 mp4…")
		var mp4_abs := "%s/replay_%s.mp4" % [_dir, replay_id]
		if _mux(ff, avi_abs, mp4_abs):
			DirAccess.remove_absolute(avi_abs)   # 转成功就只留 mp4（更小、更好分享）
			out_path = mp4_abs
	OS.shell_open(_dir)   # 打开成品所在目录，方便直接拖去分享
	return out_path

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
		_title("导出中… %d 帧（%.0f 秒视频 · %d×%d）" % [
			_frames, float(_frames) / FPS, _w, _h])

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

# ---- ffmpeg（可选：有就转 mp4，没有就留 avi）----

## 找 ffmpeg（有就转 mp4，没有就留 avi）。顺序：项目内 `tools/` → 项目根下的 `ffmpeg*` 目录 →
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
		var abs: String = String(p)
		if abs.begins_with("res://"):
			if not FileAccess.file_exists(abs):
				continue
			abs = ProjectSettings.globalize_path(abs)
		elif not FileAccess.file_exists(abs):
			continue
		if seen.has(abs):
			continue
		seen[abs] = true
		var out: Array = []
		if OS.execute(abs, ["-version"], out, true) == 0:
			return abs
	return ""

func _mux(ff: String, in_abs: String, out_abs: String) -> bool:
	var args := [
		"-y", "-i", in_abs,
		# 保险：宽高若有奇数（x264 + yuv420p 不吃奇数）就裁掉 1 像素 —— 抓帧那边已经压成偶数了，
		# 这一句是防"窗口中途改尺寸/其它来源"再踩同一个坑（否则会留下一个 0 字节的 mp4）。
		"-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2",
		"-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "18", "-movflags", "+faststart",
		out_abs,
	]
	var out: Array = []
	var code := OS.execute(ff, args, out, true)
	var loc := ProjectSettings.localize_path(out_abs)
	var ok := code == 0 and FileAccess.file_exists(loc) and _file_size(loc) > 0
	if not ok:
		# 转失败：**删掉那个 0 字节的残file**（用户报过"mp4 大小是 0"），avi 留着照样能播
		if FileAccess.file_exists(loc):
			DirAccess.remove_absolute(loc)
		if out.size() > 0:
			log_msg("转 mp4 失败（%d）：%s" % [code, String(out[out.size() - 1]).strip_edges()])
	return ok

func _file_size(path: String) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return -1
	var n := f.get_length()
	f.close()
	return n

extends Control
## 剧情内容主控 (cutscene_content.tscn)
## ─────────────────────────────────────────────────
## 前三个分镜：播放 AI 生成的剧情视频 (assets/cutscene_video.webm, 9:16 带黑边)
## 后三个分镜：程序化动画 (fx_cutscene_draw.gd 自绘) 弥补
##   镜头4 时间倒流 → 镜头5 系统觉醒 → 镜头6 K线标题
## 播完调用 Cutscene.finish_cutscene() 进入交易界面
## ─────────────────────────────────────────────────

const VIDEO_PATH := "res://assets/cutscene_video.ogv"

# 阶段
const PH_VIDEO := 0
const PH_CALENDAR := 1
const PH_SYSTEM := 2
const PH_KLINE := 3

# 时间表(秒)
const T_VIDEO := 10.0      # 视频总长(可灵 10s 版)
const T_CALENDAR := 5.5
const T_SYSTEM := 5.5
const T_KLINE := 5.8

# 视频阶段字幕 [文本, 开始秒, 持续秒]
const SUBS := [
	["2026年7月 · 天台 —— 他失去了所有", 0.9, 3.2],
	["坠入黑暗之前，他做了一个决定", 4.2, 3.0],
	["「用我的灵魂…换一次重来的机会」", 7.3, 2.7],
]

var _elapsed: float = 0.0    # 总时间
var _phase: int = PH_VIDEO
var _phase_t: float = 0.0
var _fx: Control = null               # 自绘层 (fx_cutscene_draw.gd)
var _video: VideoStreamPlayer = null
var _flash: float = 0.0               # 阶段切换黑场
var _finished: bool = false

# 系统觉醒打字机文本
const SYS_TEXT := "剩余生命天数：220\n目标：5倍本金\n\n在死亡之前\n赚回你失去的一切"


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_build_video()
	_build_fx()
	# 视频直接开播
	if _video != null:
		_video.play()


func _process(delta: float) -> void:
	_elapsed += delta
	_phase_t += delta
	if _flash > 0.0:
		_flash = maxf(_flash - delta * 3.0, 0.0)

	match _phase:
		PH_VIDEO:
			_update_video()
		PH_CALENDAR:
			_update_calendar()
		PH_SYSTEM:
			_update_system()
		PH_KLINE:
			_update_kline()

	# 状态同步给自绘层
	_fx.set("phase", _phase)
	_fx.set("t_phase", _phase_t)
	_fx.set("flash_alpha", _flash)


# ── 构建 ──
func _build_video() -> void:
	_video = VideoStreamPlayer.new()
	# 横屏 16:9 视频居中放置(460 宽 → 高 259), 下方黑边区放字幕
	_video.position = Vector2(0, 170)
	_video.size = Vector2(460, 259)
	_video.expand = true
	_video.audio_track = 0
	var stream: VideoStream = load(VIDEO_PATH) as VideoStream
	if stream == null:
		push_warning("剧情视频缺失: " + VIDEO_PATH)
	else:
		_video.stream = stream
		_video.autoplay = false
	add_child(_video)


func _build_fx() -> void:
	_fx = preload("res://scripts/fx_cutscene_draw.gd").new()
	_fx.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_fx)


# ── 阶段更新 ──
func _update_video() -> void:
	# 字幕
	var st := ""
	var sa := 0.0
	for s in SUBS:
		var start: float = float(s[1])
		var dur: float = float(s[2])
		var tt: float = _phase_t - start
		if tt >= 0.0 and tt <= dur:
			st = str(s[0])
			sa = clampf(minf(tt / 0.5, (dur - tt) / 0.5), 0.0, 1.0)
			break
	_fx.set("subtitle_text", st)
	_fx.set("subtitle_alpha", sa)
	# 视频结束前 0.4s 开始淡出视频
	if _video != null and _video.is_playing():
		var remain: float = T_VIDEO - _phase_t
		var va := clampf(remain / 0.4, 0.0, 1.0)
		_video.modulate.a = va
	# 切阶段
	if _phase_t >= T_VIDEO:
		_switch_phase(PH_CALENDAR)


func _update_calendar() -> void:
	var t := _phase_t
	# 年份数字倒转: 前 2s 个位跳动, 2s 后定格 2022
	if t < 2.0:
		var digit: int = int(floor((_phase_t * 60.0))) % 10
		if t >= 1.6:
			digit = 2
		_fx.set("year_now", 2020 + digit)
	else:
		_fx.set("year_now", 2022)
	if t >= T_CALENDAR:
		_switch_phase(PH_SYSTEM)


func _update_system() -> void:
	var t := _phase_t
	# 打字机: 每字 0.06s
	var tc: int = clampi(int(t / 0.06), 0, SYS_TEXT.length())
	_fx.set("type_count", tc)
	# 进度条: 2s 后开始 2.5s 填满
	var p: float = 0.0
	if t > 2.0:
		p = clampf((t - 2.0) / 2.5, 0.0, 1.0)
	_fx.set("sys_progress", p)
	if t >= T_SYSTEM:
		_switch_phase(PH_KLINE)


func _update_kline() -> void:
	var t := _phase_t
	# K线逐根亮起 3.4s
	var kp: float = clampf(t / 3.4, 0.0, 1.0)
	_fx.set("kline_progress", kp)
	# 标题 2.4s 起淡入
	var ta: float = clampf((t - 2.4) / 2.2, 0.0, 1.0)
	_fx.set("title_alpha", ta)
	if t >= T_KLINE:
		_finish()


# ── 阶段切换(黑场闪切) ──
func _switch_phase(p: int) -> void:
	_phase = p
	_phase_t = 0.0
	_flash = 1.0
	if _video != null:
		_video.stop()


func _finish() -> void:
	if _finished:
		return
	_finished = true
	if has_node("/root/Cutscene") and get_node("/root/Cutscene").has_method("finish_cutscene"):
		get_node("/root/Cutscene").finish_cutscene()
	else:
		# 独立测试时直接切主场景
		if get_tree() != null:
			get_tree().change_scene_to_file("res://scenes/main.tscn")

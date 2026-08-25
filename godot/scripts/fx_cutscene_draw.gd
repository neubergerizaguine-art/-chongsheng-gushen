extends Control
const GF := preload("res://scripts/fonts.gd")
## 剧情动画自绘层
## ─────────────────────────────────────────────────
## 负责后三个分镜的程序化动画（视频部分播完后的衔接）：
##   阶段1 时间倒流：2026 数字倒转回 2022 + 金色粒子
##   阶段2 系统觉醒：金色面板打字机文字 + 进度条 + 粒子爆发
##   阶段3 K线标题：K线逐根亮起 + 金色粒子汇聚「重生股神」标题
## 数据由 cutscene_content.gd 主控驱动，本类只负责绘制与粒子自更新
## ─────────────────────────────────────────────────

# ── 阶段常量 ──
const PH_VIDEO := 0
const PH_CALENDAR := 1
const PH_SYSTEM := 2
const PH_KLINE := 3

# ── 主控传入的状态 ──
var phase: int = PH_VIDEO          # 当前阶段
var t_phase: float = 0.0           # 当前阶段内时间(秒)
var year_now: int = 2026           # 镜头4: 正在显示的年
var type_count: int = 0            # 镜头5: 已打出的字符数
var sys_progress: float = 0.0      # 镜头5: 进度条 0~1
var kline_progress: float = 0.0    # 镜头6: K线亮起进度 0~1
var title_alpha: float = 0.0       # 镜头6: 标题透明度 0~1
var subtitle_text: String = ""     # 视频阶段底部字幕
var subtitle_alpha: float = 0.0    # 字幕透明度
var flash_alpha: float = 0.0       # 阶段切换黑场覆盖

# ── 金色粒子(平行数组, 避免 Dictionary 类型推断坑) ──
var _px: PackedFloat32Array = PackedFloat32Array()
var _py: PackedFloat32Array = PackedFloat32Array()
var _pv: PackedFloat32Array = PackedFloat32Array()   # 上升速度
var _ps: PackedFloat32Array = PackedFloat32Array()   # 尺寸
var _pa: PackedFloat32Array = PackedFloat32Array()   # 透明度
var _ptw: PackedFloat32Array = PackedFloat32Array()  # 相位

const P_COUNT := 46
const P_GOLD := Color(0.95, 0.78, 0.35, 1.0)
const P_GOLD_DIM := Color(0.72, 0.55, 0.22, 1.0)

var _font: Font
var _font_big: Font


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_font = _make_font(22, 500)
	_font_big = _make_font(64, 800)
	for i in P_COUNT:
		_px.append(randf_range(0.0, 1.0))
		_py.append(randf_range(0.0, 1.0))
		_pv.append(randf_range(0.02, 0.07))
		_ps.append(randf_range(1.0, 3.2))
		_pa.append(randf_range(0.2, 0.9))
		_ptw.append(randf_range(0.0, TAU))


func _process(delta: float) -> void:
	var w: float = size.x
	var h: float = size.y
	for i in P_COUNT:
		_py[i] -= _pv[i] * delta
		_ptw[i] += delta * 2.0
		# 回到底部并随机横向漂移
		if _py[i] < -0.05:
			_py[i] = 1.05
			_px[i] = randf_range(0.0, 1.0)
		_px[i] += sin(_ptw[i]) * 0.0008
	# 粒子透明度呼吸
	queue_redraw()
	if phase == PH_SYSTEM and t_phase < 6.0:
		pass  # 呼吸效果统一在 _draw 里用 _ptw


func _draw() -> void:
	match phase:
		PH_VIDEO:
			_draw_subtitle()
		PH_CALENDAR:
			_draw_calendar()
		PH_SYSTEM:
			_draw_system()
		PH_KLINE:
			_draw_kline_title()
	# 阶段切换黑场覆盖
	if flash_alpha > 0.001:
		draw_rect(Rect2(0, 0, size.x, size.y), Color(0.0, 0.0, 0.0, flash_alpha))


# ── 阶段0: 视频底部字幕 ──
func _draw_subtitle() -> void:
	if subtitle_text == "" or subtitle_alpha <= 0.001:
		return
	var w: float = size.x
	var h: float = size.y
	var col := Color(P_GOLD.r, P_GOLD.g, P_GOLD.b, subtitle_alpha)
	_draw_string_center(_font, Vector2(0, h * 0.82), subtitle_text, w, col, 22)


# ── 阶段1: 时间倒流 2026→2022 ──
func _draw_calendar() -> void:
	var w: float = size.x
	var h: float = size.y
	# 背景渐变(深蓝黑)
	_draw_vignette(w, h, Color(0.02, 0.015, 0.03, 0.9))
	# 年份大数字(中间偏上)
	var year_str: String = str(year_now)
	var yp: Vector2 = Vector2(0, h * 0.30)
	_draw_string_center(_font_big, yp, year_str, w, Color(0.92, 0.75, 0.32, 0.95), 64)
	# 年份下划线 + 日期小字
	var date_str := "7月1日 · 星期四 · 晴"
	var dp := Vector2(0, h * 0.30 + 74)
	_draw_string_center(_font, dp, date_str, w, Color(0.85, 0.72, 0.5, 0.75), 22)
	# 倒转刻度线(两侧)
	var tick_y := h * 0.30 + 40
	var tk_col := Color(0.9, 0.75, 0.35, 0.35)
	for i in 8:
		var tx := w * (0.15 + i * 0.10)
		var th := 6.0 + sin(_ptw[i % P_COUNT]) * 3.0
		draw_line(Vector2(tx, tick_y - th), Vector2(tx, tick_y + th), tk_col, 1.2)
	# 提示文字
	var tip := "时间…在倒退"
	var tip_alpha := clampf(sin(t_phase * 1.4), 0.0, 1.0) * 0.85
	_draw_string_center(_font, Vector2(0, h * 0.52), tip, w,
		Color(0.9, 0.8, 0.55, tip_alpha), 22)
	# 粒子
	_draw_particles(w, h)


# ── 阶段2: 系统觉醒 ──
func _draw_system() -> void:
	var w: float = size.x
	var h: float = size.y
	_draw_vignette(w, h, Color(0.015, 0.012, 0.02, 0.9))
	# 面板
	var pw := w * 0.86
	var ph := h * 0.40
	var pr := Rect2((w - pw) * 0.5, h * 0.24, pw, ph)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.06, 0.045, 0.02, 0.82)
	sb.set_corner_radius_all(14)
	sb.border_color = Color(0.9, 0.72, 0.3, 0.55)
	sb.set_border_width_all(1.5)
	sb.shadow_color = Color(0.9, 0.7, 0.3, 0.18)
	sb.shadow_size = 10
	draw_style_box(sb, pr)
	# 面板顶部标题
	var title := "重生股神系统"
	var tp := Vector2(0, pr.position.y + 40)
	_draw_string_center(_font, tp, title, w, Color(0.95, 0.82, 0.45, 0.95), 22)
	# 打字机正文(内容由主控按 type_count 截断, draw_string 不支持换行须逐行画)
	var body := _typed_body()
	var bcol := Color(0.88, 0.8, 0.62, 0.92)
	var by := pr.position.y + 92
	for line in body.split("\n"):
		_draw_string_center(_font, Vector2(0, by), line, w, bcol, 22)
		by += 30
	# 进度条
	var bar_w := pw * 0.78
	var bar_h := 8.0
	var bar_x := (w - bar_w) * 0.5
	var bar_y := pr.position.y + ph - 40
	draw_rect(Rect2(bar_x, bar_y, bar_w, bar_h), Color(0.3, 0.22, 0.1, 0.7))
	draw_rect(Rect2(bar_x, bar_y, bar_w * clampf(sys_progress, 0.0, 1.0), bar_h),
		Color(0.95, 0.75, 0.3, 0.95))
	# 进度百分比
	var pct: int = int(clampf(sys_progress, 0.0, 1.0) * 100.0)
	_draw_string_center(_font, Vector2(0, bar_y + 34), "觉醒进度 " + str(pct) + "%", w,
		Color(0.85, 0.7, 0.45, 0.85), 22)
	# 粒子
	_draw_particles(w, h)


func _typed_body() -> String:
	var full := "剩余生命天数：220\n目标：5倍本金\n\n在死亡之前\n赚回你失去的一切"
	if type_count <= 0:
		return ""
	return full.substr(0, type_count)


# ── 阶段3: K线 + 标题 ──
func _draw_kline_title() -> void:
	var w: float = size.x
	var h: float = size.y
	_draw_vignette(w, h, Color(0.01, 0.01, 0.015, 0.92))
	# K线区(下半部分)
	var base_y := h * 0.68
	var k_w := w * 0.72
	var k_x0 := (w - k_w) * 0.5
	var n := 21
	var bw := k_w / float(n) * 0.52
	var step := k_w / float(n)
	var y_scale := h * 0.16
	var center_y := base_y - y_scale * 0.5
	var shown := int(floor(kline_progress * float(n)))
	# 网格线
	var grid_col := Color(0.5, 0.45, 0.35, 0.12)
	for i in 5:
		var gy := center_y - y_scale + i * y_scale * 0.5
		draw_line(Vector2(k_x0, gy), Vector2(k_x0 + k_w, gy), grid_col, 1.0)
	# 蜡烛(伪随机但固定, 用 i 做种子)
	var ma_pts := PackedVector2Array()
	for i in shown:
		var seed_v: float = (sin(float(i) * 12.9898) * 43758.5453)
		var rnd: float = seed_v - floorf(seed_v)
		var up: bool = rnd > 0.42
		var body_h: float = 6.0 + rnd * 26.0
		var body_y: float = center_y - body_h * 0.5 + (rnd - 0.5) * 14.0
		if not up:
			body_y = center_y + (0.5 - rnd) * 12.0 - body_h * 0.5
		var cx := k_x0 + float(i) * step + step * 0.5
		var col := Color(0.92, 0.28, 0.22, 0.95) if up else Color(0.2, 0.72, 0.4, 0.95)
		draw_rect(Rect2(cx - bw * 0.5, body_y, bw, body_h), col)
		# 影线
		var wick_top: float = body_y - 6.0 - rnd * 8.0
		var wick_bot: float = body_y + body_h + 5.0 + rnd * 8.0
		draw_line(Vector2(cx, wick_top), Vector2(cx, wick_bot), col, 1.0)
		ma_pts.append(Vector2(cx, body_y + body_h * 0.5))
	# 均线
	if ma_pts.size() > 1:
		draw_polyline(ma_pts, Color(0.95, 0.8, 0.4, 0.6), 1.5)
	# 标题(金色粒子汇聚感: 标题透明度受 kline 后半段控制)
	if title_alpha > 0.002:
		var ta := clampf(title_alpha, 0.0, 1.0)
		var title_col := Color(0.95, 0.78, 0.32, ta)
		var ty := h * 0.22
		# 标题描边(多层偏移模拟)
		var tw := w * 0.95
		_draw_string_center(_font_big, Vector2(0, ty), "重生股神", w,
			Color(0.1, 0.07, 0.02, ta * 0.9), 64, 3.0)
		_draw_string_center(_font_big, Vector2(0, ty), "重生股神", w, title_col, 64)
		# 副标题
		var sub := "—— 与恶魔的交易 ——"
		_draw_string_center(_font, Vector2(0, ty + 54), sub, w,
			Color(0.85, 0.7, 0.45, ta * 0.85), 22)
	# 粒子(标题出现时粒子更亮)
	_draw_particles(w, h)


# ── 通用绘制 ──
func _draw_particles(w: float, h: float) -> void:
	for i in P_COUNT:
		var a := _pa[i] * (0.65 + sin(_ptw[i]) * 0.35)
		var col := Color(P_GOLD.r, P_GOLD.g, P_GOLD.b, a * (0.5 + title_alpha * 0.5))
		draw_circle(Vector2(_px[i] * w, _py[i] * h), _ps[i], col)


func _draw_vignette(w: float, h: float, col: Color) -> void:
	draw_rect(Rect2(0, 0, w, h), col)


func _draw_string_center(font: Font, pos: Vector2, text: String, width: float, col: Color, font_size: int, outline: float = 0.0) -> void:
	if outline > 0.0:
		font.draw_string_outline(get_canvas_item(), pos, text,
			HORIZONTAL_ALIGNMENT_CENTER, width, font_size, int(outline),
			Color(0.08, 0.05, 0.01, col.a))
	font.draw_string(get_canvas_item(), pos, text,
		HORIZONTAL_ALIGNMENT_CENTER, width, font_size, col)


func _make_font(_font_size: int, weight: int) -> Font:
	return GF.bold() if weight >= 600 else GF.regular()

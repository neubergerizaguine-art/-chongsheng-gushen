extends Control
## 背景特效层: 静态K线(轻微闪烁) + 红眼脉动
## 作为独立绘制层, 重写 _draw() 按顺序绘制

var _t := 0.0
var _breath := 0.0
var _pulse := 0.0
var _candles: Array[Dictionary] = []

const CANDLE_COUNT := 28
const CANDLE_W := 10.0
const CANDLE_GAP := 4.0


func _ready() -> void:
	_gen_candles()


func _process(delta: float) -> void:
	_t += delta
	_breath += delta * 1.3
	_pulse += delta * 2.5
	queue_redraw()


func _draw() -> void:
	_draw_klines()
	_draw_eyes()


# ── K线数据 ──
func _gen_candles() -> void:
	_candles.clear()
	var price: float = 100.0
	for i in range(CANDLE_COUNT):
		var change: float = randf_range(-4.5, 4.5)
		var o: float = price
		var c: float = price * (1.0 + change / 100.0)
		var hi: float = maxf(o, c) + randf_range(0.3, 2.5)
		var lo: float = minf(o, c) - randf_range(0.3, 2.5)
		var is_up: bool = c >= o
		_candles.append({
			open = o, close = c, high = hi, low = lo,
			up = is_up,
			color = Color("#cc3333") if is_up else Color("#22aa44"),
			body_color = Color("#dd4444") if is_up else Color("#22bb44"),
		})
		price = c


# ── 绘制K线 (静态, 仅轻微闪烁) ──
func _draw_klines() -> void:
	if _candles.is_empty():
		return
	var sz := size
	var total_w: float = float(CANDLE_COUNT) * (CANDLE_W + CANDLE_GAP)
	var start_x: float = (sz.x - total_w) / 2.0

	var min_price: float = 99999.0
	var max_price: float = 0.0
	for cd in _candles:
		var d: Dictionary = cd
		var lo: float = float(d.low)
		var hi: float = float(d.high)
		if lo < min_price: min_price = lo
		if hi > max_price: max_price = hi
	var price_range: float = max_price - min_price
	if price_range < 0.01: price_range = 1.0

	var chart_h: float = sz.y * 0.52
	var chart_top: float = sz.y * 0.08
	var price_scale: float = chart_h / price_range

	for i in range(_candles.size()):
		var d: Dictionary = _candles[i]
		var cx: float = start_x + float(i) * (CANDLE_W + CANDLE_GAP)
		if cx < -CANDLE_W or cx > sz.x + CANDLE_W:
			continue

		var yo: float = chart_top + (max_price - float(d.open)) * price_scale
		var yc: float = chart_top + (max_price - float(d.close)) * price_scale
		var yh: float = chart_top + (max_price - float(d.high)) * price_scale
		var yl: float = chart_top + (max_price - float(d.low)) * price_scale

		draw_line(Vector2(cx + CANDLE_W / 2.0, yh),
			Vector2(cx + CANDLE_W / 2.0, yl), d.color, 1.2, false)

		var body_top: float = minf(yo, yc)
		var body_h: float = absf(yc - yo)
		if body_h < 1.0: body_h = 1.0
		var col: Color = Color(d.body_color, 0.35 + sin(float(i) * 0.3 + _t * 0.8) * 0.12)
		draw_rect(Rect2(cx, body_top, CANDLE_W, body_h), col, false)

	# MA5 / MA10
	_draw_ma(start_x, chart_top, max_price, price_scale, 5, Color(0.95, 0.82, 0.25, 0.18))
	_draw_ma(start_x, chart_top, max_price, price_scale, 10, Color(0.25, 0.60, 0.95, 0.14))


func _draw_ma(start_x: float, chart_top: float, max_p: float,
		scale: float, period: int, col: Color) -> void:
	if _candles.size() <= period:
		return
	var pts: PackedVector2Array = []
	for i in range(period - 1, _candles.size()):
		var s: float = 0.0
		for j in range(i - period + 1, i + 1):
			s += float((_candles[j] as Dictionary).close)
		var ma: float = s / float(period)
		var px: float = start_x + float(i) * (CANDLE_W + CANDLE_GAP) + CANDLE_W / 2.0
		var py: float = chart_top + (max_p - ma) * scale
		pts.append(Vector2(px, py))
	if pts.size() >= 2:
		draw_polyline(pts, col, 1.4 if period == 5 else 1.2, false)


# ── 绘制红眼 ──
func _draw_eyes() -> void:
	var cx: float = size.x / 2.0
	var cy: float = size.y * 0.34
	var breath_scale: float = 1.0 + sin(_breath) * 0.025

	var eye_y: float = cy
	var eye_spacing: float = 52.0 * breath_scale
	var eye_w: float = 14.0 * breath_scale
	var eye_h: float = 6.0 * breath_scale

	var pulse: float = 0.55 + sin(_pulse) * 0.30
	var glow_r: float = 28.0 + sin(_pulse * 0.7) * 8.0

	_draw_one_eye(cx - eye_spacing, eye_y, eye_w, eye_h, glow_r, pulse)
	_draw_one_eye(cx + eye_spacing, eye_y, eye_w, eye_h, glow_r, pulse)


func _draw_one_eye(ex: float, ey: float, w: float, h: float,
		gr: float, pulse: float) -> void:
	draw_circle(Vector2(ex, ey), gr, Color(0.85, 0.08, 0.06, pulse * 0.35))
	draw_circle(Vector2(ex, ey), gr * 0.6, Color(1.0, 0.2, 0.1, pulse * 0.5))
	draw_rect(Rect2(ex - w, ey - h, w * 2, h * 2), Color(1.0, 0.25, 0.1, pulse * 0.9))
	draw_circle(Vector2(ex - 3, ey - 1.5), 2.2, Color(1.0, 0.6, 0.3, pulse * 0.95))

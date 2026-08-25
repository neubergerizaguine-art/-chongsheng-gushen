extends Control
class_name KlineChart
## K线蜡烛图(自绘): 红涨绿跌 + 影线 + 量柱 + MA5/MA10 + 时间标签

const UP_COLOR := Color(0.90, 0.15, 0.15)     # A股红涨
const DOWN_COLOR := Color(0.16, 0.62, 0.27)   # 绿跌
const MA5_COLOR := Color(0.89, 0.55, 0.10)
const MA10_COLOR := Color(0.20, 0.45, 0.85)

var klines: Array = []   # [{o,h,l,c,v,label}]


func set_data(ks: Array) -> void:
	klines = ks
	queue_redraw()


func _draw() -> void:
	var n := klines.size()
	if n <= 0:
		return
	var w := size.x
	var h := size.y
	if w <= 2 or h <= 2:
		return
	var pad_l := 52.0
	var pad_r := 10.0
	var pad_t := 8.0
	var chart_h := h * 0.74
	var vol_h := h - chart_h - pad_t - 4.0
	var pw := w - pad_l - pad_r
	# 价格范围
	var lo := 1e18
	var hi := -1e18
	for k in klines:
		lo = minf(lo, float(k.l))
		hi = maxf(hi, float(k.h))
	if not is_finite(lo) or not is_finite(hi) or hi - lo < 1e-9:
		lo = 0.0
		hi = 1.0
	var range_v := hi - lo
	lo -= range_v * 0.05
	hi += range_v * 0.05
	range_v = hi - lo
	if range_v < 1e-9:
		range_v = 1.0
	# 网格 + 价格刻度
	var grid_col := Color(0.85, 0.87, 0.92)
	for gi in 5:
		var y := pad_t + chart_h * gi / 4.0
		draw_line(Vector2(pad_l, y), Vector2(w - pad_r, y), grid_col, 1.0)
		var val := hi - range_v * gi / 4.0
		draw_string(ThemeDB.fallback_font, Vector2(4, y + 4), "%0.2f" % val,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.45, 0.48, 0.55))
	# 蜡烛
	var bw := pw / float(n)
	var body_w := bw * 0.6
	var max_v := 0.0
	for k in klines:
		max_v = maxf(max_v, float(k.v))
	for i in range(n):
		var k: Dictionary = klines[i]
		var o := float(k.o)
		var c := float(k.c)
		var hh := float(k.h)
		var ll := float(k.l)
		var x := pad_l + bw * (float(i) + 0.5)
		var y_hi := pad_t + (hi - hh) / range_v * chart_h
		var y_lo := pad_t + (hi - ll) / range_v * chart_h
		var y_o := pad_t + (hi - o) / range_v * chart_h
		var y_c := pad_t + (hi - c) / range_v * chart_h
		var up := c >= o
		var col := UP_COLOR if up else DOWN_COLOR
		draw_line(Vector2(x, y_hi), Vector2(x, y_lo), col, 1.0)   # 影线
		var body_y := minf(y_o, y_c)
		var body_h := maxf(absf(y_c - y_o), 1.0)
		draw_rect(Rect2(x - body_w * 0.5, body_y, body_w, body_h), col)
		if max_v > 0:
			var vh := vol_h * (float(k.v) / max_v)
			var vbase := pad_t + chart_h + 4
			draw_rect(Rect2(x - body_w * 0.5, vbase + vol_h - vh, body_w, vh),
				Color(col.r, col.g, col.b, 0.4))
	# 均线
	_draw_ma(5, MA5_COLOR, pad_l, pad_t, chart_h, bw, hi, range_v)
	_draw_ma(10, MA10_COLOR, pad_l, pad_t, chart_h, bw, hi, range_v)
	# 时间标签
	if n > 0:
		draw_string(ThemeDB.fallback_font, Vector2(pad_l, h - 2), str(klines[0].label),
			HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(0.55, 0.55, 0.6))
		draw_string(ThemeDB.fallback_font, Vector2(pad_l + pw / 2 - 22, h - 2),
			str(klines[n / 2].label), HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(0.55, 0.55, 0.6))
		draw_string(ThemeDB.fallback_font, Vector2(w - pad_r - 32, h - 2),
			str(klines[n - 1].label), HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(0.55, 0.55, 0.6))


func _draw_ma(period: int, col: Color, pad_l: float, pad_t: float, chart_h: float,
		bw: float, hi: float, range_v: float) -> void:
	var n := klines.size()
	if n < period:
		return
	var pts := PackedVector2Array()
	for i in range(period - 1, n):
		var sum := 0.0
		for j in range(i - period + 1, i + 1):
			sum += float(klines[j].c)
		var ma := sum / float(period)
		var x := pad_l + bw * (float(i) + 0.5)
		var y := pad_t + (hi - ma) / range_v * chart_h
		pts.append(Vector2(x, y))
	if pts.size() >= 2:
		draw_polyline(pts, col, 1.1, true)

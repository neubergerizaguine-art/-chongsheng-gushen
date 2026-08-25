extends Control
class_name MinuteChart
## 分时图(自绘): 价格线 + 均价线 + 昨收虚线 + 成交量柱

const UP_COLOR := Color(0.90, 0.15, 0.15)     # A股红涨
const DOWN_COLOR := Color(0.16, 0.62, 0.27)   # 绿跌
const FLAT_COLOR := Color(0.55, 0.55, 0.55)
const AVG_COLOR := Color(0.89, 0.55, 0.10)

var prices: PackedFloat32Array = []
var avg: PackedFloat32Array = []
var vols: PackedFloat32Array = []
var prev_close := 0.0
var has_prev := false


func set_data(p: PackedFloat32Array, a: PackedFloat32Array, v: PackedFloat32Array,
		pc: float, has_pc: bool) -> void:
	prices = p
	avg = a
	vols = v
	prev_close = pc
	has_prev = has_pc
	queue_redraw()


func _draw() -> void:
	if prices.is_empty():
		return
	var w := size.x
	var h := size.y
	if w <= 2 or h <= 2:
		return
	var n := prices.size()
	var pad_l := 52.0
	var pad_r := 10.0
	var pad_t := 8.0
	var chart_h := h * 0.72
	var vol_h := h - chart_h - pad_t - 6.0
	var pw := w - pad_l - pad_r
	# 价格范围
	var lo := 1e18
	var hi := -1e18
	for i in n:
		if is_nan(prices[i]):
			continue
		lo = minf(lo, prices[i])
		hi = maxf(hi, prices[i])
	if has_prev:
		lo = minf(lo, prev_close)
		hi = maxf(hi, prev_close)
	if not is_finite(lo) or not is_finite(hi) or hi - lo < 1e-9:
		lo = 0.0
		hi = 1.0
	var range_v := hi - lo
	lo -= range_v * 0.06
	hi += range_v * 0.06
	range_v = hi - lo
	# 网格
	var grid_col := Color(0.85, 0.87, 0.92)
	for gi in 5:
		var y := pad_t + chart_h * gi / 4.0
		draw_line(Vector2(pad_l, y), Vector2(w - pad_r, y), grid_col, 1.0)
		var val := hi - range_v * gi / 4.0
		draw_string(ThemeDB.fallback_font, Vector2(4, y + 4), "%0.2f" % val,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.45, 0.48, 0.55))
	# 时间刻度
	var mid := n / 2
	draw_string(ThemeDB.fallback_font, Vector2(pad_l, h - 2), "09:30",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.55, 0.55, 0.6))
	draw_string(ThemeDB.fallback_font, Vector2(pad_l + pw / 2 - 18, h - 2), "11:30/13:01",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.55, 0.55, 0.6))
	draw_string(ThemeDB.fallback_font, Vector2(w - pad_r - 28, h - 2), "15:00",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.55, 0.55, 0.6))
	# 昨收虚线
	if has_prev:
		var y := pad_t + (hi - prev_close) / range_v * chart_h
		draw_line(Vector2(pad_l, y), Vector2(w - pad_r, y), Color(0.6, 0.6, 0.65),
			1.0, true)
	# 成交量柱
	var max_v := 0.0
	for i in n:
		max_v = maxf(max_v, vols[i])
	if max_v > 0:
		for i in n:
			var x := pad_l + pw * i / maxf(n - 1, 1)
			var bh := vol_h * (vols[i] / max_v)
			var base_y := pad_t + chart_h + 4
			var col := UP_COLOR if (prices[i] >= prev_close and has_prev) else DOWN_COLOR
			col.a = 0.45
			draw_rect(Rect2(x - pw / n * 0.32, base_y + vol_h - bh, pw / n * 0.64, bh), col)
	# 价格线
	var pts := PackedVector2Array()
	var first_valid := -1
	for i in n:
		if is_nan(prices[i]):
			continue
		var x := pad_l + pw * i / maxf(n - 1, 1)
		var y := pad_t + (hi - prices[i]) / range_v * chart_h
		pts.append(Vector2(x, y))
		if first_valid < 0:
			first_valid = i
	if pts.size() >= 2:
		var col := UP_COLOR
		if has_prev and prices[n - 1] < prev_close - 0.001:
			col = DOWN_COLOR
		draw_polyline(pts, col, 1.6, true)
	# 均价线
	var apts := PackedVector2Array()
	for i in n:
		if is_nan(avg[i]):
			continue
		var x := pad_l + pw * i / maxf(n - 1, 1)
		var y := pad_t + (hi - avg[i]) / range_v * chart_h
		apts.append(Vector2(x, y))
	if apts.size() >= 2:
		draw_polyline(apts, AVG_COLOR, 1.2, true)

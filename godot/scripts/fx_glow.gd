extends Control
## 选中按钮金色光效层 (绘制在 UI 之上)
## 通过 target 引用跟踪当前选中按钮, 绘制金色脉动边框

var target: Control = null
var _phase := 0.0


func _process(delta: float) -> void:
	_phase += delta * 3.0
	queue_redraw()


func _draw() -> void:
	if not is_instance_valid(target):
		return
	var r: Rect2 = target.get_global_rect()
	# 全局坐标 -> 本节点本地坐标 (两者都在同一画布, 直接相减)
	var lp: Vector2 = r.position - global_position

	var intensity: float = 0.45 + sin(_phase) * 0.20

	# 外圈金色光晕
	var glow_rect := Rect2(lp.x - 6, lp.y - 4, r.size.x + 12, r.size.y + 8)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(1.0, 0.82, 0.2, intensity * 0.18)
	sb.set_corner_radius_all(14)
	sb.border_color = Color(1.0, 0.80, 0.25, intensity * 0.6)
	sb.set_border_width_all(1.5)
	draw_style_box(sb, glow_rect)

	# 两侧竖线装饰
	var line_alpha: float = intensity * 0.7
	var ly_top: float = lp.y + 4
	var ly_bot: float = lp.y + r.size.y - 4
	draw_line(Vector2(lp.x - 10, ly_top), Vector2(lp.x - 10, ly_bot),
		Color(1.0, 0.82, 0.2, line_alpha), 2.0, false)
	draw_line(Vector2(lp.x + r.size.x + 10, ly_top), Vector2(lp.x + r.size.x + 10, ly_bot),
		Color(1.0, 0.82, 0.2, line_alpha), 2.0, false)

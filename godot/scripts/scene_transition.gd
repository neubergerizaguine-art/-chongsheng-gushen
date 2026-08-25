extends CanvasLayer
## 全局场景过渡: 淡出黑屏 → 切换场景 → 淡入
## 用法: Transition.to_scene("res://scenes/xxx.tscn")

const FADE_TIME := 0.35

var _rect: ColorRect
var _busy := false


func _ready() -> void:
	layer = 90
	_rect = ColorRect.new()
	_rect.color = Color(0, 0, 0, 0)
	_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_rect)


## 渐隐切换场景 (调用方无需 await, 自动完成)
func to_scene(path: String) -> void:
	if _busy:
		return
	_busy = true
	var tw := create_tween()
	tw.tween_property(_rect, "color:a", 1.0, FADE_TIME)
	await tw.finished
	get_tree().change_scene_to_file(path)
	_rect.color.a = 1.0
	var tw2 := create_tween()
	tw2.tween_property(_rect, "color:a", 0.0, FADE_TIME)
	await tw2.finished
	_busy = false


## 只淡入到黑 (供剧情中途使用)
func fade_out() -> void:
	if _busy:
		return
	_busy = true
	var tw := create_tween()
	tw.tween_property(_rect, "color:a", 1.0, FADE_TIME)
	await tw.finished


## 从黑淡入 (供剧情中途使用)
func fade_in() -> void:
	var tw := create_tween()
	tw.tween_property(_rect, "color:a", 0.0, FADE_TIME)
	await tw.finished
	_busy = false

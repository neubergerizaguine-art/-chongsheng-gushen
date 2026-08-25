extends Control
## 引导框遮罩层 — 半透明深色遮罩, 让交易界面隐约可见
## 引导卡片浮在其上, 避免整屏花哨背景

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _draw() -> void:
	# 半透明遮罩(深棕黑, 可透出背后界面)
	draw_rect(Rect2(0, 0, size.x, size.y), Color(0.03, 0.02, 0.015, 0.72))

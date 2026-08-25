extends Control
const GF := preload("res://scripts/fonts.gd")
## 剧情动画容器 (占位/插槽)
## ─────────────────────────────────────────────────
## 使用方法:
##   1. 把你的剧情动画制作成 res://cutscene_content.tscn (任意场景)
##      - 场景根节点任意, 会自动实例化到内容层
##      - 动画播放完调用: Cutscene.finish_cutscene() 进入交易界面
##      - 或直接调用: Transition.to_scene("res://scenes/main.tscn")
##   2. 不需要写任何代码, 本场景自动加载并显示
##   3. 玩家任何时候点击「跳过」/ 按 Esc 立即进入交易界面
## ─────────────────────────────────────────────────

const CONTENT_SCENE := "res://cutscene_content.tscn"

var _content_root: Control  # 剧情内容挂载点 (插槽)
var _skip_btn: Button
var _placeholder: Label    # 未放置内容时的占位提示


func _ready() -> void:
	_build_shell()
	_load_content()
	# 淡入开场
	Transition.fade_in()


func _process(_delta: float) -> void:
	# 跳过按钮悬停反馈 (简单闪烁吸引注意)
	if _placeholder != null and _placeholder.visible:
		_placeholder.modulate.a = 0.5 + sin(Time.get_ticks_msec() * 0.003) * 0.2


## 公开接口: 动画播完调用此方法进入交易界面
func finish_cutscene() -> void:
	if _skip_btn != null:
		_skip_btn.disabled = true
	Transition.to_scene("res://scenes/main.tscn")


func _build_shell() -> void:
	# 黑色底
	var bg := ColorRect.new()
	bg.color = Color(0.005, 0.003, 0.005, 1)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	# 内容挂载层 (剧情动画放这里, 在跳过按钮之下)
	_content_root = Control.new()
	_content_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_content_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_content_root)

	# 占位提示 (当没有内容时显示)
	_placeholder = Label.new()
	_placeholder.text = "剧情动画区域\n(将你的动画保存为 cutscene_content.tscn)"
	_placeholder.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_placeholder.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_placeholder.add_theme_font_size_override("font_size", 16)
	_placeholder.add_theme_color_override("font_color", Color(0.6, 0.55, 0.45, 0.6))
	_placeholder.add_theme_font_override("font", _font(false))
	_placeholder.set_anchors_preset(Control.PRESET_FULL_RECT)
	_content_root.add_child(_placeholder)

	# 跳过按钮 (右上角, 醒目)
	_skip_btn = Button.new()
	_skip_btn.text = "跳过 ▸▸"
	_skip_btn.add_theme_font_size_override("font_size", 15)
	_skip_btn.add_theme_font_override("font", _font(true))
	_skip_btn.add_theme_color_override("font_color", Color("#e8c96a"))

	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.1, 0.07, 0.03, 0.75)
	sb.set_corner_radius_all(8)
	sb.border_color = Color(0.85, 0.68, 0.3, 0.6)
	sb.set_border_width_all(1.5)
	_skip_btn.add_theme_stylebox_override("normal", sb)

	var sb_h := StyleBoxFlat.new()
	sb_h.bg_color = Color(0.22, 0.14, 0.05, 0.85)
	sb_h.set_corner_radius_all(8)
	sb_h.border_color = Color(1.0, 0.82, 0.3, 0.9)
	sb_h.set_border_width_all(2)
	_skip_btn.add_theme_stylebox_override("hover", sb_h)
	_skip_btn.add_theme_stylebox_override("pressed", sb_h)

	_skip_btn.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_skip_btn.position = Vector2(-110, 30)
	_skip_btn.custom_minimum_size = Vector2(96, 40)
	_skip_btn.pressed.connect(finish_cutscene)
	add_child(_skip_btn)

	# Esc 键跳过
	var esc_handler := _EscSkip.new()
	esc_handler.cutscene = self
	add_child(esc_handler)


func _load_content() -> void:
	if ResourceLoader.exists(CONTENT_SCENE):
		var cs: Node = load(CONTENT_SCENE).instantiate()
		_content_root.add_child(cs)
		# 有内容时隐藏占位提示
		_placeholder.visible = false


func _font(bold: bool) -> Font:
	return GF.bold() if bold else GF.regular()


# ── Esc 跳过处理器 (内嵌类) ──
class _EscSkip:
	extends Node

	var cutscene: Control = null

	func _unhandled_input(event: InputEvent) -> void:
		if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
			if cutscene != null and cutscene.has_method("finish_cutscene"):
				cutscene.finish_cutscene()
			get_viewport().set_input_as_handled()

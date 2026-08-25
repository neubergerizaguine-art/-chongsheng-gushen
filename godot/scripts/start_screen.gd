extends Control
const GF := preload("res://scripts/fonts.gd")
## 重生股神主菜单 — 恶魔契约主题
## 暗金渐变 + 静态K线 + 红眼脉动 + 金色标题
## 难度选择: 左右箭头切换 (难度一~七), 默认难度一
## 特效层: fx_background (K线+红眼) + fx_glow (选中光效)

var diff := 0  # 默认难度一
var diff_label: Label
var _selected_idx := 0
var _regions: Array[Control] = []   # 可选区域(难度区/恶魔/开始), 用于光效
var _btns: Array[Button] = []       # 仅文字按钮(恶魔/开始), 用于文字高亮
var _glow: Control = null


func _ready() -> void:
	ThemeDB.fallback_font = GF.regular()
	ThemeDB.fallback_font_size = 14
	_build()


func _build() -> void:
	# ── Layer 0: 暗金渐变底 ──
	var bg := TextureRect.new()
	bg.texture = _make_gradient()
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_SCALE
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	# ── Layer 1: 背景特效 (静态K线 + 红眼) ──
	var fx: Control = preload("res://scripts/fx_background.gd").new()
	fx.set_anchors_preset(Control.PRESET_FULL_RECT)
	fx.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(fx)

	# ── Layer 2: 金色粒子 ──
	var particles := CPUParticles2D.new()
	particles.amount = 55
	particles.lifetime = 7.0
	particles.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
	particles.emission_rect_extents = Vector2(260, 16)
	particles.direction = Vector2(0, -1)
	particles.spread = 45.0
	particles.gravity = Vector2(0, -8)
	particles.initial_velocity_min = 15.0
	particles.initial_velocity_max = 50.0
	particles.scale_amount_min = 0.6
	particles.scale_amount_max = 2.8
	particles.color = Color(0.95, 0.80, 0.30, 0.65)
	particles.position = Vector2(230, 920)
	add_child(particles)
	particles.emitting = true

	# ── Layer 3: UI内容 ──
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 28)
	margin.add_theme_constant_override("margin_right", 28)
	margin.add_theme_constant_override("margin_top", 24)
	margin.add_theme_constant_override("margin_bottom", 24)
	add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	margin.add_child(vbox)

	var top_sp := Control.new()
	top_sp.size_flags_vertical = Control.SIZE_EXPAND_FILL
	top_sp.custom_minimum_size = Vector2(0, 20)
	vbox.add_child(top_sp)

	# 标题「重生股神」
	var title := Label.new()
	title.text = "重生股神"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 52)
	title.add_theme_color_override("font_color", Color("#ffd66b"))
	title.add_theme_color_override("font_outline_color", Color("#4a3000"))
	title.add_theme_constant_override("outline_size", 12)
	title.add_theme_color_override("font_shadow_color", Color(0.05, 0.02, 0, 0.8))
	title.add_theme_constant_override("shadow_offset_x", 4)
	title.add_theme_constant_override("shadow_offset_y", 5)
	title.add_theme_font_override("font", _mk_font(true))
	vbox.add_child(title)

	var sub := Label.new()
	sub.text = "—— 与恶魔的交易 ——"
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.add_theme_font_size_override("font_size", 13)
	sub.add_theme_color_override("font_color", Color(0.85, 0.72, 0.40, 0.7))
	vbox.add_child(sub)

	var mid_sp := Control.new()
	mid_sp.size_flags_vertical = Control.SIZE_EXPAND_FILL
	mid_sp.custom_minimum_size = Vector2(0, 36)
	vbox.add_child(mid_sp)

	# 按钮容器
	var btn_box := VBoxContainer.new()
	btn_box.add_theme_constant_override("separation", 18)
	btn_box.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_child(btn_box)

	# 难度选择: 左右箭头切换
	var diff_row := HBoxContainer.new()
	diff_row.alignment = BoxContainer.ALIGNMENT_CENTER
	diff_row.add_theme_constant_override("separation", 12)
	btn_box.add_child(diff_row)
	_regions.append(diff_row)

	var prev_btn := _make_arrow_btn("◀", func(): _shift_diff(-1))
	diff_row.add_child(prev_btn)

	diff_label = Label.new()
	diff_label.text = _diff_text()
	diff_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	diff_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	diff_label.add_theme_color_override("font_color", Color("#ffd966"))
	diff_label.add_theme_color_override("font_outline_color", Color("#6a4a00"))
	diff_label.add_theme_constant_override("outline_size", 1)
	diff_label.add_theme_font_override("font", _mk_font(true))
	diff_label.custom_minimum_size = Vector2(200, 56)
	diff_row.add_child(diff_label)

	var next_btn := _make_arrow_btn("▶", func(): _shift_diff(1))
	diff_row.add_child(next_btn)

	# 恶魔果实
	var skill_btn := _make_button("恶魔果实", func(): _use_skill())
	btn_box.add_child(skill_btn)
	_regions.append(skill_btn)
	_btns.append(skill_btn)


	# 开始游戏
	var start_btn := _make_button("开始游戏", func(): _start_game())
	start_btn.custom_minimum_size = Vector2(260, 54)
	btn_box.add_child(start_btn)
	_regions.append(start_btn)
	_btns.append(start_btn)

	var bot_sp := Control.new()
	bot_sp.size_flags_vertical = Control.SIZE_EXPAND_FILL
	bot_sp.custom_minimum_size = Vector2(0, 16)
	vbox.add_child(bot_sp)

	# ── Layer 4: 选中光效层 (UI之上) ──
	_glow = preload("res://scripts/fx_glow.gd").new()
	_glow.set_anchors_preset(Control.PRESET_FULL_RECT)
	_glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_glow)

	_update_selected(0)


# ── 选中状态更新 ──
func _update_selected(idx: int) -> void:
	_selected_idx = idx
	if _glow != null and idx < _regions.size():
		_glow.target = _regions[idx]
	for i in range(_btns.size()):
		var b: Button = _btns[i]
		# _btns[0]=恶魔(区域1) _btns[1]=开始(区域2)
		var region_idx: int = i + 1
		if region_idx == idx:
			b.add_theme_color_override("font_color", Color("#ffd966"))
			b.add_theme_color_override("font_outline_color", Color("#6a4a00"))
			b.add_theme_constant_override("outline_size", 1)
		else:
			b.add_theme_color_override("font_color", Color("#d8d0c4"))
			b.add_theme_constant_override("outline_size", 0)


# ── 难度切换 (左右箭头) ──
func _shift_diff(step: int) -> void:
	var total: int = GameManager.DIFFICULTIES.size()
	diff = (diff + step + total) % total
	Global.difficulty = diff
	if is_instance_valid(diff_label):
		diff_label.text = _diff_text()


func _diff_text() -> String:
	var cfg: Dictionary = GameManager.DIFFICULTIES[diff]
	var t: float = 1_000_000.0 * float(cfg.target)
	return "%s\n第%d日 · 目标%s" % [cfg.name, int(cfg.death), _fmt_money(t)]


func _fmt_money(v: float) -> String:
	if v >= 1_000_000.0:
		var w: float = v / 10_000.0
		return ("%.0f万" % w) if w == floor(w) else ("%.1f万" % w)
	return str(int(v))


func _make_arrow_btn(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(46, 56)
	b.add_theme_font_size_override("font_size", 20)
	b.add_theme_font_override("font", _mk_font(true))

	var sb_n := StyleBoxFlat.new()
	sb_n.bg_color = Color(0.08, 0.05, 0.02, 0.55)
	sb_n.set_corner_radius_all(10)
	sb_n.border_color = Color(0.72, 0.56, 0.26, 0.55)
	sb_n.set_border_width_all(1.5)
	b.add_theme_stylebox_override("normal", sb_n)

	var sb_h := StyleBoxFlat.new()
	sb_h.bg_color = Color(0.18, 0.12, 0.05, 0.65)
	sb_h.set_corner_radius_all(10)
	sb_h.border_color = Color(1.0, 0.82, 0.30, 0.85)
	sb_h.set_border_width_all(2)
	b.add_theme_stylebox_override("hover", sb_h)
	b.add_theme_stylebox_override("pressed", sb_h)

	b.add_theme_color_override("font_color", Color("#e8c96a"))
	b.pressed.connect(cb)
	return b


# ── 按钮工厂 ──
func _make_button(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(250, 52)
	b.add_theme_font_size_override("font_size", 17)
	b.add_theme_font_override("font", _mk_font(true))
	b.pressed.connect(cb)

	var sb_n := StyleBoxFlat.new()
	sb_n.bg_color = Color(0.08, 0.05, 0.02, 0.55)
	sb_n.set_corner_radius_all(10)
	sb_n.border_color = Color(0.55, 0.42, 0.20, 0.35)
	sb_n.set_border_width_all(1)
	b.add_theme_stylebox_override("normal", sb_n)

	var sb_h := StyleBoxFlat.new()
	sb_h.bg_color = Color(0.15, 0.10, 0.04, 0.60)
	sb_h.set_corner_radius_all(10)
	sb_h.border_color = Color(0.75, 0.58, 0.25, 0.55)
	sb_h.set_border_width_all(1.5)
	b.add_theme_stylebox_override("hover", sb_h)
	b.add_theme_stylebox_override("pressed", sb_h)

	var sb_f := StyleBoxFlat.new()
	sb_f.bg_color = Color(0.12, 0.08, 0.03, 0.50)
	sb_f.set_corner_radius_all(10)
	sb_f.border_color = Color(0.90, 0.72, 0.28, 0.6)
	sb_f.set_border_width_all(1.5)
	b.add_theme_stylebox_override("focus", sb_f)

	return b


# ── 辅助 ──
func _make_gradient() -> GradientTexture2D:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.35, 0.7, 1.0])
	g.colors = PackedColorArray([
		Color("#1a1208"), Color("#2a1e0c"), Color("#140c04"), Color("#080600"),
	])
	var t := GradientTexture2D.new()
	t.gradient = g
	t.fill_from = Vector2(0, 0)
	t.fill_to = Vector2(0, 1)
	return t


func _mk_font(bold: bool) -> Font:
	return GF.bold() if bold else GF.regular()


var _fruit_panel: Control = null   # 恶魔果实面板

func _use_skill() -> void:
	if _fruit_panel != null:
		return
	var ov := Control.new()
	ov.set_anchors_preset(Control.PRESET_FULL_RECT)
	ov.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(ov)
	_fruit_panel = ov
	# 半透明遮罩
	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.6)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	ov.add_child(bg)
	# 黑金卡片
	var card := PanelContainer.new()
	var cs := StyleBoxFlat.new()
	cs.bg_color = Global.GOLD_BG
	cs.set_corner_radius_all(16)
	cs.border_color = Global.GOLD_DARK
	cs.set_border_width_all(2)
	cs.shadow_color = Color(0, 0, 0, 0.5)
	cs.shadow_size = 14
	card.add_theme_stylebox_override("panel", cs)
	card.set_anchors_preset(Control.PRESET_CENTER)
	card.custom_minimum_size = Vector2(380, 0)
	card.position = Vector2(-190, -160)
	ov.add_child(card)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 14)
	vb.offset_left = 22
	vb.offset_right = -22
	vb.offset_top = 22
	vb.offset_bottom = -22
	card.add_child(vb)
	# 标题
	var title := Label.new()
	title.text = "恶魔果实"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 28)
	title.add_theme_color_override("font_color", Global.GOLD)
	title.add_theme_constant_override("outline_size", 8)
	title.add_theme_color_override("font_outline_color", Global.GOLD_OUTLINE)
	vb.add_child(title)
	# 余额(大字醒目)
	var coin := Label.new()
	coin.text = "恶魔交易币  ×%d" % Global.demon_coins
	coin.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	coin.add_theme_font_size_override("font_size", 22)
	coin.add_theme_color_override("font_color", Global.GOLD)
	coin.add_theme_constant_override("outline_size", 4)
	coin.add_theme_color_override("font_outline_color", Global.GOLD_OUTLINE)
	vb.add_child(coin)
	# 说明
	var desc := Label.new()
	desc.text = "与恶魔签订契约后获得的能力：\n完成交易任务可抽取随机技能或奖励\n用于辅助你在股海翻盘"
	desc.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.add_theme_font_size_override("font_size", 14)
	desc.add_theme_color_override("font_color", Color(0.9, 0.84, 0.68, 1.0))
	vb.add_child(desc)
	var tip := Label.new()
	tip.text = "（技能系统开发中，敬请期待）"
	tip.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tip.add_theme_font_size_override("font_size", 12)
	tip.add_theme_color_override("font_color", Color(0.7, 0.62, 0.42, 0.9))
	vb.add_child(tip)
	# 关闭按钮
	var close := _make_button("收下", func(): _close_fruit_panel())
	close.custom_minimum_size = Vector2(0, 46)
	vb.add_child(close)
	# 淡入
	ov.modulate.a = 0.0
	var tw := create_tween()
	tw.tween_property(ov, "modulate:a", 1.0, 0.2)


func _close_fruit_panel() -> void:
	if _fruit_panel == null:
		return
	_fruit_panel.queue_free()
	_fruit_panel = null


func _start_game() -> void:
	Global.difficulty = diff
	Transition.to_scene("res://scenes/cutscene.tscn")


# ── Toast 提示 ──
var _toast: Label = null

func _show_toast(text: String) -> void:
	if is_instance_valid(_toast):
		_toast.queue_free()
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_font_size_override("font_size", 14)
	l.add_theme_color_override("font_color", Global.GOLD)
	l.set_anchors_preset(Control.PRESET_CENTER)
	# 向上偏移(避免与底部恶魔果实/开始按钮重叠被挡住)
	l.position = Vector2(-200, -140)
	l.custom_minimum_size = Vector2(400, 0)
	add_child(l)
	_toast = l
	var tw := create_tween()
	tw.tween_interval(3.5)
	tw.tween_callback(func(): l.queue_free())

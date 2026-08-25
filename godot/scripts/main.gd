extends Control
const GF := preload("res://scripts/fonts.gd")
## 《重生股神》主界面 — 移动端竖屏券商 APP 风格
## 布局: 顶部导航栏 | 页面内容 | 时间悬浮块(右下) | 底部TabBar
## 底部导航: 行情 / 能力 / 交易 / 系统 ; 个股详情为覆盖层

var loader: DataLoader
var gm: GameManager

var page := "trade"
var cur_tab := "持仓"          # 交易页当前 Tab: 买入/卖出/撤单/持仓/查询
var cur_code := ""
var watch := {}                 # 自选集合 (code -> true)

# shell 引用
var nav_title: Label
var date_label: Label
var content: Control
var tab_btns: Dictionary = {}   # name -> Button
var nav_btns: Dictionary = {}   # name -> Button
var detail_overlay: Control = null
var time_float: Control = null  # 右下角时间悬浮块
var cal_overlay: Control = null # 事件日历覆盖层

# 交易页引用
var asset_total: Label
var asset_pnl: Label
var asset_day: Label
var asset_mv: Label
var asset_cash: Label
var asset_cnt: Label
var time_label: Label
var time_btn_15: Button
var time_btn_1h: Button
var time_btn_1d: Button
var trade_scroll: ScrollContainer
var trade_list: VBoxContainer
var market_box: VBoxContainer = null
var pick_box: VBoxContainer = null
var _quote_cache: Dictionary = {}   # 行情页数据缓存(时间推进才重算)
var _sect_state: Dictionary = {}    # 展开条状态 title->bool
var _sector_cache: Array = []       # 板块匹配结果缓存
var _watch_body: VBoxContainer = null  # 行情页自选列表内容(局部更新)
var _watch_count: Label = null         # 自选列表计数

# 引导框
var _guide: Control = null
var _guide_idx := 0
var _guide_title: Label
var _guide_body: Label
var _guide_dots: Array = []     # 页码点
var _guide_prev: Button
var _guide_next: Button

# 详情页下单表单
var _order_otype := "MARKET"    # MARKET / LIMIT
var _order_mk: Button = null     # 市价按钮(详情/快速共用)
var _order_lp: Button = null     # 限价按钮
var _order_price: LineEdit = null  # 价格输入
var _detail_price_edit: LineEdit
var _detail_qty_edit: LineEdit
var _qb_qty_edit: LineEdit = null
var _add_btns: Dictionary = {}    # code -> Button(行情页+自选按钮, 局部更新用)
var _wm_btn: Button = null        # 详情页加/删自选按钮


func _ready() -> void:
	ThemeDB.fallback_font = GF.regular()
	ThemeDB.fallback_font_size = 15

	loader = DataLoader.new()
	if loader.pool.is_empty():
		_fatal("数据包加载失败: 检查 game_data/game 路径")
		return
	gm = GameManager.new(loader)
	gm.state_changed.connect(_on_state_changed)
	gm.game_ended.connect(_on_game_ended)
	gm.setup_run(Global.difficulty)

	_build_shell()
	_show_page("trade")
	# 进入即刷新资产/持仓数据(默认展示, 无需先推进时间)
	_refresh_asset_board()
	# 剧情动画结束后进入, 稍等淡入完成再展示引导框
	await get_tree().create_timer(0.8).timeout
	_show_guide()


func _fatal(msg: String) -> void:
	var l := Label.new()
	l.text = msg
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.set_anchors_preset(Control.PRESET_CENTER)
	l.size = Vector2(300, 80)
	add_child(l)


# ================= 基础构建 =================
func _font(bold: bool = false) -> Font:
	return GF.bold() if bold else GF.regular()


func _lbl(text: String, size: int = 15, color: Color = Global.C_TEXT,
		bold: bool = false) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	if bold:
		l.add_theme_font_override("font", _font(true))
	return l


func _btn(text: String, cb: Callable, fg := Global.C_TEXT,
		bg := Global.C_CARD) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_color_override("font_color", fg)
	b.add_theme_font_size_override("font_size", 15)
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(8)
	b.add_theme_stylebox_override("normal", sb)
	var sb2 := StyleBoxFlat.new()
	sb2.bg_color = Color("#e9ebf0")
	sb2.set_corner_radius_all(8)
	b.add_theme_stylebox_override("hover", sb2)
	b.add_theme_stylebox_override("pressed", sb2)
	b.pressed.connect(cb)
	return b


func _card_style() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Global.C_CARD
	s.set_corner_radius_all(10)
	s.set_border_width_all(1)
	s.border_color = Global.C_LINE
	return s


func _pct_color(v: float) -> Color:
	if v > 0.0001:
		return Global.C_RED
	if v < -0.0001:
		return Global.C_GREEN
	return Global.C_SUB


func _fmt(v: float) -> String:
	var a := absf(v)
	if a >= 1e8:
		return "%0.2f亿" % (v / 1e8)
	if a >= 1e4:
		return "%0.1f万" % (v / 1e4)
	return "%0.0f" % v


func _pct_str(p: float) -> String:
	return ("+" if p >= 0 else "") + "%0.2f%%" % p


func _fmt_date(d: String) -> String:
	# "20240301" -> "2024-03-01"
	if d.length() == 8:
		return "%s-%s-%s" % [d.substr(0, 4), d.substr(4, 2), d.substr(6, 2)]
	return d


func _code_disp(code: String) -> String:
	# "600519.SH" -> "600519"
	var i := code.find(".")
	if i >= 0:
		return code.substr(0, i)
	return code


# ================= Shell =================
func _build_shell() -> void:
	var bg := ColorRect.new()
	bg.color = Global.C_BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(root)

	# 顶部导航栏(主色红底)
	var nav := ColorRect.new()
	nav.color = Global.C_MAIN
	nav.custom_minimum_size = Vector2(0, 60)
	root.add_child(nav)
	var nav_hb := HBoxContainer.new()
	nav_hb.set_anchors_preset(Control.PRESET_FULL_RECT)
	nav_hb.offset_left = 16
	nav_hb.offset_right = -12
	nav_hb.add_theme_constant_override("separation", 10)
	nav.add_child(nav_hb)
	nav_title = _lbl("天堂证券", 22, Color.WHITE, true)
	nav_hb.add_child(nav_title)
	nav_hb.add_spacer(false)
	# 快进30日按钮(日期左边): 正常逐日推进 30 次
	_fast30_btn = Button.new()
	var fast30 := _fast30_btn
	fast30.text = "快进30日"
	fast30.add_theme_font_size_override("font_size", 12)
	fast30.add_theme_color_override("font_color", Color.WHITE)
	var fsb := StyleBoxFlat.new()
	fsb.bg_color = Color(0.55, 0.35, 0.1, 0.95)
	fsb.set_corner_radius_all(6)
	fsb.border_color = Color(1, 0.85, 0.5, 0.7)
	fsb.set_border_width_all(1)
	fast30.add_theme_stylebox_override("normal", fsb)
	var fsb_h := StyleBoxFlat.new()
	fsb_h.bg_color = Color(0.72, 0.48, 0.15, 1.0)
	fsb_h.set_corner_radius_all(6)
	fsb_h.border_color = Color(1, 0.9, 0.6, 0.9)
	fsb_h.set_border_width_all(1)
	fast30.add_theme_stylebox_override("hover", fsb_h)
	fast30.add_theme_stylebox_override("pressed", fsb_h)
	fast30.custom_minimum_size = Vector2(0, 38)
	fast30.pressed.connect(_advance_30d)
	nav_hb.add_child(fast30)
	date_label = _lbl("", 15, Color(1, 1, 1, 0.95), true)
	nav_hb.add_child(date_label)
	# 事件日历按钮
	var cal_btn := Button.new()
	cal_btn.text = "事件日历"
	cal_btn.add_theme_font_size_override("font_size", 13)
	cal_btn.add_theme_color_override("font_color", Color.WHITE)
	var csb := StyleBoxFlat.new()
	csb.bg_color = Color(1, 1, 1, 0.15)
	csb.set_corner_radius_all(6)
	csb.border_color = Color(1, 1, 1, 0.55)
	csb.set_border_width_all(1)
	cal_btn.add_theme_stylebox_override("normal", csb)
	var csb_h := StyleBoxFlat.new()
	csb_h.bg_color = Color(1, 1, 1, 0.3)
	csb_h.set_corner_radius_all(6)
	csb_h.border_color = Color(1, 1, 1, 0.8)
	csb_h.set_border_width_all(1)
	cal_btn.add_theme_stylebox_override("hover", csb_h)
	cal_btn.add_theme_stylebox_override("pressed", csb_h)
	cal_btn.custom_minimum_size = Vector2(0, 38)
	cal_btn.pressed.connect(_open_calendar)
	nav_hb.add_child(cal_btn)

	# 内容区
	content = Control.new()
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(content)

	# 底部 TabBar
	var dock := PanelContainer.new()
	var ds := StyleBoxFlat.new()
	ds.bg_color = Global.C_CARD
	ds.set_border_width_all(1)
	ds.border_color = Global.C_LINE
	ds.border_width_top = 1
	dock.add_theme_stylebox_override("panel", ds)
	root.add_child(dock)
	var dock_hb := HBoxContainer.new()
	dock_hb.add_theme_constant_override("separation", 0)
	dock.add_child(dock_hb)
	for item in [["行情", "market"], ["能力", "ability"], ["交易", "trade"], ["系统", "system"]]:
		var b := Button.new()
		b.text = item[0]
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.custom_minimum_size = Vector2(0, 62)
		b.flat = true
		b.add_theme_color_override("font_color", Global.C_SUB)
		b.add_theme_font_size_override("font_size", 17)
		b.pressed.connect(func(p = item[1]): _show_page(p))
		nav_btns[item[1]] = b
		dock_hb.add_child(b)

	# 时间推进悬浮块(右下角固定)
	_build_time_float()


func _update_nav() -> void:
	for k in nav_btns:
		var b: Button = nav_btns[k]
		var on: bool = (k == page)
		b.add_theme_color_override("font_color",
			Global.C_MAIN if on else Global.C_SUB)
		b.add_theme_font_override("font", _font(on))


func _show_page(p: String) -> void:
	page = p
	_close_detail()
	_update_nav()
	for ch in content.get_children():
		ch.queue_free()
	# 时间悬浮块仅交易页显示
	if time_float != null:
		time_float.visible = (p == "trade")
	match p:
		"trade":
			_build_trade_page()
			_refresh_asset_board()
		"market":
			_build_market_page()
		"ability":
			_build_placeholder_page("能力", "觉醒技能与任务奖励将在这里展示", "敬请期待 · 完成系统任务解锁")
		"system":
			_build_placeholder_page("系统", "恶魔赐予你的重生股神系统", "任务 · 技能 · 物品 即将上线")
	# 右上角当前日期
	date_label.text = _fmt_date(gm.real_day())


# ================= 交易页 =================
func _build_trade_page() -> void:
	var vb := VBoxContainer.new()
	vb.set_anchors_preset(Control.PRESET_FULL_RECT)
	content.add_child(vb)

	# 5 Tab
	var tabs := PanelContainer.new()
	var ts := StyleBoxFlat.new()
	ts.bg_color = Global.C_CARD
	tabs.add_theme_stylebox_override("panel", ts)
	vb.add_child(tabs)
	var tab_hb := HBoxContainer.new()
	tab_hb.add_theme_constant_override("separation", 0)
	tabs.add_child(tab_hb)
	for t in ["买入", "卖出", "撤单", "持仓", "查询"]:
		var b := Button.new()
		b.text = t
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.flat = true
		b.custom_minimum_size = Vector2(0, 54)
		b.add_theme_font_size_override("font_size", 17)
		b.pressed.connect(func(tn = t): _set_tab(tn))
		tab_btns[t] = b
		tab_hb.add_child(b)

	# 资产看板(默认展示账户与盈亏, 无需点击)
	vb.add_child(_build_asset_board())

	# 明细列表(可滚动)
	trade_scroll = ScrollContainer.new()
	trade_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vb.add_child(trade_scroll)
	trade_list = VBoxContainer.new()
	trade_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	trade_list.add_theme_constant_override("separation", 6)
	# 底部留白, 避免列表末尾被右下时间悬浮块遮挡
	trade_list.offset_bottom = -120
	trade_scroll.add_child(trade_list)

	_set_tab("持仓")


func _set_tab(t: String) -> void:
	cur_tab = t
	for k in tab_btns:
		var b: Button = tab_btns[k]
		b.add_theme_color_override("font_color",
			Global.C_MAIN if k == t else Global.C_SUB)
		b.add_theme_font_override("font", _font(k == t))
	_refresh_trade_list()
	if t == "买入":
		_tut_on_buy_tab()


func _build_asset_board() -> Control:
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", _card_style())
	card.offset_left = 10
	card.offset_right = -10
	card.offset_top = 8
	card.offset_bottom = -8
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 13)
	card.add_child(vb)

	# 子标题: 账户类别(死期信息已移至事件日历)
	var head := HBoxContainer.new()
	vb.add_child(head)
	head.add_child(_lbl("普通账户", 15, Global.C_SUB, true))
	head.add_spacer(false)

	# 第一行(核心指标, 大字号)
	var row1 := HBoxContainer.new()
	row1.add_theme_constant_override("separation", 4)
	vb.add_child(row1)
	# 总资产
	var cell1 := VBoxContainer.new()
	cell1.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row1.add_child(cell1)
	cell1.add_child(_lbl("总资产", 14, Global.C_HINT))
	asset_total = _lbl("", 36, Global.C_TEXT, true)
	cell1.add_child(asset_total)
	# 浮动盈亏
	var cell2 := VBoxContainer.new()
	cell2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row1.add_child(cell2)
	cell2.add_child(_lbl("浮动盈亏", 14, Global.C_HINT))
	asset_pnl = _lbl("", 26, Global.C_RED, true)
	cell2.add_child(asset_pnl)
	# 当日收益
	var cell3 := VBoxContainer.new()
	cell3.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row1.add_child(cell3)
	cell3.add_child(_lbl("当日收益", 14, Global.C_HINT))
	asset_day = _lbl("", 26, Global.C_RED, true)
	cell3.add_child(asset_day)

	# 分隔
	var sep := HSeparator.new()
	vb.add_child(sep)

	# 第二行(次级指标)
	var row2 := HBoxContainer.new()
	row2.add_theme_constant_override("separation", 4)
	vb.add_child(row2)
	var mv_cell := VBoxContainer.new()
	mv_cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row2.add_child(mv_cell)
	mv_cell.add_child(_lbl("总市值", 14, Global.C_HINT))
	asset_mv = _lbl("", 21, Global.C_SUB)
	mv_cell.add_child(asset_mv)
	var cash_cell := VBoxContainer.new()
	cash_cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row2.add_child(cash_cell)
	cash_cell.add_child(_lbl("可用资金", 14, Global.C_HINT))
	asset_cash = _lbl("", 21, Global.C_SUB)
	cash_cell.add_child(asset_cash)
	var cnt_cell := VBoxContainer.new()
	cnt_cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row2.add_child(cnt_cell)
	cnt_cell.add_child(_lbl("持仓", 14, Global.C_HINT))
	asset_cnt = _lbl("", 21, Global.C_SUB)
	cnt_cell.add_child(asset_cnt)
	return card


func _build_time_float() -> void:
	# 右下角固定悬浮块: 时间显示 + 三个推进按钮
	var box := PanelContainer.new()
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.07, 0.045, 0.015, 0.93)
	s.set_corner_radius_all(12)
	s.border_color = Color(0.85, 0.68, 0.3, 0.85)
	s.set_border_width_all(1.5)
	s.shadow_color = Color(0, 0, 0, 0.4)
	s.shadow_size = 10
	box.add_theme_stylebox_override("panel", s)
	box.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	box.offset_left = -220
	box.offset_top = -152
	box.offset_right = -10
	box.offset_bottom = -70
	box.visible = false
	add_child(box)
	time_float = box

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 7)
	vb.offset_left = 10
	vb.offset_right = -10
	vb.offset_top = 8
	vb.offset_bottom = -8
	box.add_child(vb)
	time_label = _lbl("", 15, Color("#f0c75e"), true)
	time_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(time_label)
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 6)
	vb.add_child(hb)
	time_btn_15 = _btn_dark("▶▶15分", func(): _advance("15m"))
	time_btn_1h = _btn_dark("▶▶1时", func(): _advance("1h"))
	time_btn_1d = _btn_dark("▶▶1日", func(): _advance("1d"))
	for b in [time_btn_15, time_btn_1h, time_btn_1d]:
		(b as Button).size_flags_horizontal = Control.SIZE_EXPAND_FILL
		(b as Button).custom_minimum_size = Vector2(0, 40)
		hb.add_child(b)


func _btn_dark(text: String, cb: Callable) -> Button:
	# 暗金风格小按钮(悬浮块用)
	var b := Button.new()
	b.text = text
	b.add_theme_color_override("font_color", Color("#f0c75e"))
	b.add_theme_font_size_override("font_size", 15)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.16, 0.11, 0.04, 0.95)
	sb.set_corner_radius_all(8)
	sb.border_color = Color(0.8, 0.62, 0.28, 0.7)
	sb.set_border_width_all(1)
	b.add_theme_stylebox_override("normal", sb)
	var sb_h := StyleBoxFlat.new()
	sb_h.bg_color = Color(0.30, 0.20, 0.06, 1.0)
	sb_h.set_corner_radius_all(8)
	sb_h.border_color = Color(1.0, 0.85, 0.4, 0.9)
	sb_h.set_border_width_all(1)
	b.add_theme_stylebox_override("hover", sb_h)
	b.add_theme_stylebox_override("pressed", sb_h)
	b.pressed.connect(cb)
	return b


func _advance(step: String) -> void:
	gm.advance(step)
	_refresh_all()
	if step == "1d":
		_show_day_flash()


## 快进 30 个交易日: 分帧批量推进(每帧6天, 中间天跳过数据加载仅末帧读盘, UI不冻结)
var _advancing := false   # 快进进行中(防重入)
var _pending_days := 0     # 连点累计天数(合并一次跑完)
var _fast30_btn: Button = null  # 快进30日按钮(快进中禁用)
func _advance_30d() -> void:
	if _advancing:
		# 连点合并: 累计天数, 当前快进完成后一次跑完(避免多个协程排队叠加卡顿)
		_pending_days += 30
		return
	_advancing = true
	if _fast30_btn != null:
		_fast30_btn.disabled = true   # 快进中禁用按钮防误触
	var total := 30 + _pending_days
	_pending_days = 0
	var left := total
	# 循环内持续消费连点累计: 狂点时一次协程跑完全部天数(不会多协程叠加)
	while (left > 0 or _pending_days > 0) and not gm.run_over:
		if left <= 0 and _pending_days > 0:
			left = _pending_days
			_pending_days = 0
		var n := mini(left, 6)
		gm.advance_bulk(n)
		left -= n
		await get_tree().process_frame   # 分帧: 每帧推进6天, 界面保持响应
	_refresh_all()
	_advancing = false
	if _fast30_btn != null:
		_fast30_btn.disabled = false
	_show_day_flash()
	_toast("已快进 %d 个交易日 · %s" % [gm.day_idx + 1, _fmt_date(gm.real_day())], true)


## 翻天提示: 显示剩余天数与目标差值, 1秒后渐隐, 不拦截任何操作
func _show_day_flash() -> void:
	if gm.run_over:
		return
	if _flash_label != null and is_instance_valid(_flash_label):
		_flash_label.queue_free()
	var l := Label.new()
	l.set_anchors_preset(Control.PRESET_CENTER_TOP)
	l.position = Vector2(-230, 300)
	l.custom_minimum_size = Vector2(460, 0)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", 18)
	l.add_theme_color_override("font_color", Color("#f0c75e"))
	l.add_theme_color_override("font_outline_color", Color(0.25, 0.16, 0.03, 1.0))
	l.add_theme_constant_override("outline_size", 6)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var left := maxi(gm.days_left(), 0)
	var diff := gm.target_asset - gm.total_asset()
	if diff > 0:
		l.text = "剩余 %d 天 · 距目标还差 %s" % [left, _fmt(diff)]
	else:
		l.text = "剩余 %d 天 · 已达成目标! 超额 %s" % [left, _fmt(-diff)]
	add_child(l)
	_flash_label = l
	var tw := create_tween()
	tw.tween_interval(1.0)
	tw.tween_property(l, "modulate:a", 0.0, 0.5)
	tw.tween_callback(func():
		# 防御: 连续翻天时旧 label 可能已被释放, 避免二次 queue_free
		if is_instance_valid(l):
			l.queue_free()
		if _flash_label == l:
			_flash_label = null)


func _refresh_asset_board() -> void:
	var ta := gm.total_asset()
	asset_total.text = _fmt(ta)
	var pnl := ta - 1000000.0
	asset_pnl.text = ("+" if pnl >= 0 else "") + _fmt(pnl)
	asset_pnl.add_theme_color_override("font_color", _pct_color(pnl))
	var dp := gm.day_pnl()
	asset_day.text = ("+" if dp >= 0 else "") + _fmt(dp) + "  " + _pct_str(dp / maxf(gm.base_asset, 1.0) * 100.0)
	asset_day.add_theme_color_override("font_color", _pct_color(dp))
	asset_mv.text = _fmt(gm.market_value())
	asset_cash.text = _fmt(gm.cash)
	asset_cnt.text = "%d 只" % gm.positions.size()
	time_label.text = "%s  %s" % [_fmt_date(gm.real_day()), gm.time_str()]
	# 右上角日期随推进同步刷新(修复"右上角时间永不变")
	if date_label != null:
		date_label.text = _fmt_date(gm.real_day())
	_refresh_time_btns()


func _refresh_time_btns() -> void:
	## 跨天/越界时禁用对应时间推进按钮
	if time_float == null:
		return
	time_btn_15.disabled = not gm.can_advance("15m")
	time_btn_1h.disabled = not gm.can_advance("1h")
	time_btn_1d.disabled = not gm.can_advance("1d")


func _refresh_trade_list() -> void:
	for ch in trade_list.get_children():
		ch.queue_free()
	match cur_tab:
		"持仓":
			_build_positions()
		"买入":
			_build_order_form("BUY")
		"卖出":
			_build_order_form("SELL")
		"撤单":
			_build_orders()
		"查询":
			_build_trades()
	# 底部留白: 列表滚到底也不被右下时间悬浮块遮挡
	var pad := Control.new()
	pad.custom_minimum_size = Vector2(0, 120)
	trade_list.add_child(pad)


func _build_positions() -> void:
	if gm.positions.is_empty():
		trade_list.add_child(_empty("暂无持仓，去「买入」下单吧"))
		return
	for r in gm.position_rows():
		var code := str(r.code)
		var card := PanelContainer.new()
		card.add_theme_stylebox_override("panel", _card_style())
		card.custom_minimum_size = Vector2(0, 80)
		trade_list.add_child(card)
		var vb := VBoxContainer.new()
		vb.add_theme_constant_override("separation", 4)
		card.add_child(vb)
		var r1 := HBoxContainer.new()
		vb.add_child(r1)
		r1.add_child(_lbl("%s %s" % [r.name, _code_disp(code)], 16, Global.C_TEXT, true))
		r1.add_spacer(false)
		r1.add_child(_lbl(_fmt(float(r.market_value)), 16, Global.C_TEXT, true))
		var r2 := HBoxContainer.new()
		vb.add_child(r2)
		r2.add_child(_lbl("持有 %d · 可用 %d" % [r.shares, r.avail], 14, Global.C_SUB))
		r2.add_spacer(false)
		# 当日涨跌(红绿)
		var dp := float(r.day_pnl)
		r2.add_child(_lbl("当日 %s (%s)" % [_fmt(dp), _pct_str(float(r.day_pct))], 15,
			_pct_color(dp), true))
		var r3 := HBoxContainer.new()
		vb.add_child(r3)
		r3.add_child(_lbl("成本 %0.3f · 现价 %0.2f" % [float(r.avg_cost), float(r.price)],
			14, Global.C_HINT))
		r3.add_spacer(false)
		# 累计盈亏(小字, 总涨跌幅在资产看板)
		var tp := float(r.pnl)
		r3.add_child(_lbl("累计 %s (%s)" % [_fmt(tp), _pct_str(float(r.pnl_pct))], 13,
			_pct_color(tp)))
		# 点击查看个股
		card.gui_input.connect(func(ev, c = code):
			if ev is InputEventMouseButton and ev.pressed:
				_open_detail(c))


func _build_order_form(side: String) -> void:
	if side == "BUY":
		# 买入: 仅支持自选股
		_build_buy_watchlist()
		return
	# 卖出: 仅显示当前持仓 + 快速卖出
	_build_sell_positions()


## 卖出页: 当前持仓股票列表 + 快速卖出按钮
func _build_sell_positions() -> void:
	if gm.positions.is_empty():
		var tip := _empty("暂无持仓可卖\n先去「买入」建仓吧")
		tip.custom_minimum_size = Vector2(0, 140)
		trade_list.add_child(tip)
		return
	for r in gm.position_rows():
		var code := str(r.code)
		var avail := int(r.avail)
		var card := PanelContainer.new()
		card.add_theme_stylebox_override("panel", _card_style())
		card.custom_minimum_size = Vector2(0, 88)
		trade_list.add_child(card)
		var vb := VBoxContainer.new()
		vb.add_theme_constant_override("separation", 4)
		card.add_child(vb)
		var r1 := HBoxContainer.new()
		vb.add_child(r1)
		r1.add_child(_lbl("%s %s" % [r.name, _code_disp(code)], 17, Global.C_TEXT, true))
		r1.add_spacer(false)
		var sell := _btn("卖出", func(cd = code): _open_quick_sell(cd),
			Color.WHITE, Global.C_GREEN)
		sell.custom_minimum_size = Vector2(80, 44)
		r1.add_child(sell)
		var r2 := HBoxContainer.new()
		vb.add_child(r2)
		r2.add_child(_lbl("持有 %d · 可用 %d" % [int(r.shares), avail], 14, Global.C_SUB))
		r2.add_spacer(false)
		var dp := float(r.day_pnl)
		r2.add_child(_lbl("现价 %0.2f  当日 %s (%s)" % [float(r.price), _fmt(dp),
			_pct_str(float(r.day_pct))], 15, _pct_color(dp), true))
		card.gui_input.connect(func(ev, c = code):
			if ev is InputEventMouseButton and ev.pressed:
				_open_detail(c))


## 买入页: 自选股列表
func _build_buy_watchlist() -> void:
	if watch.is_empty():
		var tip := _empty("请先添加自选股\n去「行情」页点击股票即可加入自选")
		tip.custom_minimum_size = Vector2(0, 140)
		trade_list.add_child(tip)
		return
	# 现价/涨跌映射
	var quote := {}
	for r in gm.market_rows(-1):
		quote[str(r.code)] = r
	for code in watch:
		var c := str(code)
		var row := PanelContainer.new()
		row.add_theme_stylebox_override("panel", _card_style())
		row.custom_minimum_size = Vector2(0, 64)
		trade_list.add_child(row)
		var hb := HBoxContainer.new()
		hb.add_theme_constant_override("separation", 8)
		hb.offset_left = 12
		hb.offset_right = -8
		hb.offset_top = 6
		hb.offset_bottom = -6
		row.add_child(hb)
		var nv := VBoxContainer.new()
		nv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		nv.add_theme_constant_override("separation", 2)
		hb.add_child(nv)
		nv.add_child(_lbl("%s %s" % [loader.stock_name(c), _code_disp(c)], 15, Global.C_TEXT, true))
		if quote.has(c):
			var q: Dictionary = quote[c]
			nv.add_child(_lbl("现价 %0.2f    %s" % [float(q.price), _pct_str(float(q.pct))],
				12, _pct_color(float(q.pct))))
		# 快速购买
		var buy := _btn("买入", func(cd = c): _open_quick_buy(cd), Color.WHITE, Global.C_RED)
		buy.custom_minimum_size = Vector2(64, 38)
		hb.add_child(buy)
		row.gui_input.connect(func(ev, cd = c):
			if ev is InputEventMouseButton and ev.pressed:
				_open_detail(cd))


func _build_pick_list(q: String, side: String) -> void:
	var pb: VBoxContainer = pick_box
	if pb == null:
		return
	for ch in pb.get_children():
		ch.queue_free()
	var rows := gm.market_rows(80)
	var shown := 0
	for r in rows:
		var code := str(r.code)
		var name := str(r.name)
		if q != "" and not code.contains(q) and not name.to_lower().contains(q.to_lower()):
			continue
		var card := PanelContainer.new()
		card.add_theme_stylebox_override("panel", _card_style())
		pb.add_child(card)
		var hb := HBoxContainer.new()
		hb.add_theme_constant_override("separation", 8)
		card.add_child(hb)
		hb.add_child(_lbl(name, 14, Global.C_TEXT, true))
		hb.add_child(_lbl(_code_disp(code), 13, Global.C_HINT))
		hb.add_spacer(false)
		hb.add_child(_lbl("%0.2f" % float(r.price), 14, Global.C_TEXT))
		hb.add_child(_lbl(_pct_str(float(r.pct)), 14, _pct_color(float(r.pct))))
		# 快捷买卖
		var b := _btn("买入" if side == "BUY" else "卖出",
			func(c = code): _quick_order(c, side))
		b.custom_minimum_size = Vector2(52, 26)
		hb.add_child(b)
		shown += 1
		if shown >= 12:
			break
	if shown == 0:
		pb.add_child(_empty("无匹配结果"))


func _quick_order(code: String, side: String) -> void:
	cur_code = code
	_open_detail(code)


func _build_orders() -> void:
	var has := false
	for o in gm.orders:
		if o.status == "PENDING":
			has = true
			break
	if not has:
		trade_list.add_child(_empty("暂无挂单"))
		return
	for o in gm.orders:
		if o.status != "PENDING":
			continue
		var card := PanelContainer.new()
		card.add_theme_stylebox_override("panel", _card_style())
		card.custom_minimum_size = Vector2(0, 80)
		trade_list.add_child(card)
		var hb := HBoxContainer.new()
		hb.add_theme_constant_override("separation", 10)
		hb.offset_left = 12
		hb.offset_right = -8
		hb.offset_top = 8
		hb.offset_bottom = -8
		card.add_child(hb)
		var nv := VBoxContainer.new()
		nv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		nv.add_theme_constant_override("separation", 3)
		hb.add_child(nv)
		var side_txt := "买入" if o.side == "BUY" else "卖出"
		var col := Global.C_RED if o.side == "BUY" else Global.C_GREEN
		nv.add_child(_lbl("%s %s %s" % [side_txt, o.name, _code_disp(str(o.code))],
			16, col, true))
		nv.add_child(_lbl("%d股 @%0.2f    %s" % [int(o.qty), float(o.price),
			str(o.reason)], 13, Global.C_HINT))
		var cancel := _btn("撤单", func(o2 = o): gm.cancel_order(int(o2.id)); _refresh_trade_list(),
			Color.WHITE, Global.C_MAIN)
		cancel.custom_minimum_size = Vector2(68, 42)
		hb.add_child(cancel)


func _build_trades() -> void:
	if gm.trades.is_empty():
		trade_list.add_child(_empty("暂无成交记录"))
		return
	var n := mini(gm.trades.size(), 100)
	for i in range(gm.trades.size() - n, gm.trades.size()):
		var tr: Dictionary = gm.trades[i]
		var side_txt := "买入" if tr.side == "BUY" else "卖出"
		var col := Global.C_RED if tr.side == "BUY" else Global.C_GREEN
		trade_list.add_child(_lbl(
			"第%d日 %s  %s %s %d股 @%0.2f 费%0.2f" % [
				int(tr.day) + 1, tr.time, side_txt, _code_disp(str(tr.code)), int(tr.qty),
				float(tr.price), float(tr.fee)], 13, col))


func _empty(text: String) -> Control:
	var l := _lbl(text, 14, Global.C_HINT)
	l.custom_minimum_size = Vector2(0, 40)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return l


# ================= 占位页(能力/系统) =================
func _build_placeholder_page(title: String, sub: String, tip: String) -> void:
	var vb := VBoxContainer.new()
	vb.set_anchors_preset(Control.PRESET_FULL_RECT)
	vb.offset_left = 12
	vb.offset_right = -12
	vb.offset_top = 40
	vb.add_theme_constant_override("separation", 10)
	content.add_child(vb)
	var t := _lbl(title, 32, Global.C_TEXT, true)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(t)
	var s := _lbl(sub, 16, Global.C_SUB)
	s.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(s)
	var tip_l := _lbl(tip, 15, Global.C_HINT)
	tip_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tip_l.custom_minimum_size = Vector2(0, 60)
	vb.add_child(tip_l)


# ================= 首页 =================
func _build_home_page() -> void:
	var vb := VBoxContainer.new()
	vb.set_anchors_preset(Control.PRESET_FULL_RECT)
	vb.offset_left = 12
	vb.offset_right = -12
	vb.offset_top = 12
	vb.add_theme_constant_override("separation", 10)
	content.add_child(vb)

	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", _card_style())
	vb.add_child(card)
	var cv := VBoxContainer.new()
	cv.add_theme_constant_override("separation", 10)
	card.add_child(cv)
	cv.add_child(_lbl("本局目标", 13, Global.C_TEXT, true))
	cv.add_child(_lbl("在死期前，将 100 万本金做到 %s（%d 倍）" % [
		_fmt(gm.target_asset), int(gm.target_asset / 1000000.0)], 15, Global.C_MAIN, true))
	cv.add_child(_lbl("当前总资产 %s · 距死期 %d 天 · 已进行第 %d 个交易日" % [
		_fmt(gm.total_asset()), maxi(gm.days_left(), 0), gm.day_idx + 1], 12, Global.C_SUB))
	# 进度条
	var prog := ProgressBar.new()
	prog.max_value = maxf(gm.target_asset, 1.0)
	prog.value = clampf(gm.total_asset(), 0.0, gm.target_asset)
	prog.custom_minimum_size = Vector2(0, 16)
	prog.show_percentage = true
	cv.add_child(prog)

	var card2 := PanelContainer.new()
	card2.add_theme_stylebox_override("panel", _card_style())
	vb.add_child(card2)
	var cv2 := VBoxContainer.new()
	cv2.add_theme_constant_override("separation", 8)
	card2.add_child(cv2)
	cv2.add_child(_lbl("系统提示", 13, Global.C_TEXT, true))
	cv2.add_child(_lbl(
		"· 点击「交易」页进行买卖，用 +15分/+1时/+1日 推进时间\n" +
		"· 真实 A 股规则：T+1、涨停买不进、跌停卖不出\n" +
		"· 数据为真实历史行情，但月份顺序已打乱，别想背答案\n" +
		"· 恶魔在看着你……", 12, Global.C_SUB))


# ================= 行情页 =================
# ================= 行情页 (五大可展开条) =================
const SECTORS := [
	["白酒", ["茅台", "五粮液", "汾酒", "泸州", "酒鬼", "舍得", "古井", "今世缘", "水井坊", "金种子", "老白干", "口子窖"]],
	["半导体", ["半导体", "芯片", "集成电路", "微电子", "中芯", "华虹", "北方华创", "兆易", "韦尔", "澜起", "长电科技", "通富"]],
	["AI 算力", ["人工智能", "智能", "算力", "讯飞", "曙光", "浪潮", "紫光", "海光", "寒武纪", "龙芯", "万兴"]],
	["新能源", ["新能源", "锂", "宁德", "比亚迪", "亿纬", "阳光电源", "隆基", "通威", "天合", "晶澳", "正泰"]],
	["医药", ["医药", "医疗", "药业", "生物", "同仁堂", "恒瑞", "迈瑞", "片仔癀", "云南白药", "白云山"]],
	["金融", ["银行", "证券", "保险", "平安", "招商银行", "工商银行", "建设银行", "农业银行", "中国银行", "中信证券", "东方财富"]],
	["军工", ["军工", "航天", "航空", "船舶", "兵器", "中航", "航发"]],
	["汽车", ["汽车", "长安", "长城", "吉利", "江淮", "江铃", "赛力斯", "北汽", "上汽", "广汽"]],
	["通信", ["通信", "中兴", "烽火", "光迅", "旭创", "新易盛", "天孚"]],
	["消费", ["食品", "饮料", "乳业", "伊利", "双汇", "海天", "金龙鱼", "农夫", "东鹏"]],
]


func _build_market_page() -> void:
	_add_btns.clear()
	var sc := ScrollContainer.new()
	sc.set_anchors_preset(Control.PRESET_FULL_RECT)
	content.add_child(sc)
	market_box = VBoxContainer.new()
	market_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	market_box.add_theme_constant_override("separation", 8)
	market_box.offset_left = 10
	market_box.offset_right = -10
	market_box.offset_top = 10
	market_box.offset_bottom = -10
	sc.add_child(market_box)
	if _quote_cache.is_empty():
		_quote_cache = _load_quote()
		_sector_cache = _build_sector_members(_quote_cache)
	var quote := _quote_cache
	_section_search(market_box, quote)
	_section_rank(market_box, quote)
	_section_sector(market_box, quote)
	_section_special(market_box)
	_section_watchlist(market_box, quote)


func _load_quote() -> Dictionary:
	var q := {}
	for r in gm.market_rows(-1):
		q[str(r.code)] = r
	return q


## 可展开条: 返回 {"body": VBoxContainer, "count": Label}
func _mk_section(parent: VBoxContainer, title: String, default_open: bool) -> Dictionary:
	var open: bool = bool(_sect_state.get(title, default_open))
	var head := PanelContainer.new()
	var hs := StyleBoxFlat.new()
	hs.bg_color = Global.C_CARD
	hs.set_corner_radius_all(10)
	hs.set_border_width_all(1)
	hs.border_color = Global.C_LINE
	head.add_theme_stylebox_override("panel", hs)
	parent.add_child(head)
	var hb := HBoxContainer.new()
	hb.offset_left = 16
	hb.offset_right = -16
	hb.offset_top = 15
	hb.offset_bottom = -15
	head.add_child(hb)
	var arrow := _lbl("▸" if not open else "▾", 22, Global.C_SUB)
	hb.add_child(arrow)
	hb.add_child(_lbl(title, 22, Global.C_TEXT, true))
	hb.add_spacer(false)
	var count := _lbl("", 14, Global.C_HINT)
	hb.add_child(count)
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 6)
	body.offset_left = 6
	body.offset_right = -6
	body.offset_top = 6
	body.visible = open
	parent.add_child(body)
	head.gui_input.connect(func(ev):
		if ev is InputEventMouseButton and ev.pressed:
			body.visible = not body.visible
			arrow.text = "▸" if not body.visible else "▾"
			_sect_state[title] = body.visible)
	return {"body": body, "count": count}


## 通用股票行: 名称/代码/现价涨跌 + 右侧按钮; 点击行打开详情
func _mk_stock_row(parent: VBoxContainer, code: String, quote: Dictionary,
		btn_mode: String, rebuild: Callable) -> void:
	var row := PanelContainer.new()
	row.add_theme_stylebox_override("panel", _card_style())
	row.set_meta("code", code)
	parent.add_child(row)
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 8)
	hb.offset_left = 12
	hb.offset_right = -8
	hb.offset_top = 8
	hb.offset_bottom = -8
	row.add_child(hb)
	var nv := VBoxContainer.new()
	nv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	nv.add_theme_constant_override("separation", 2)
	hb.add_child(nv)
	nv.add_child(_lbl("%s %s" % [loader.stock_name(code), _code_disp(code)],
		19, Global.C_TEXT, true))
	if quote.has(code):
		var qd: Dictionary = quote[code]
		# 右侧: 现价 + 涨跌幅 醒目红绿显示(券商APP风格)
		var pv := VBoxContainer.new()
		pv.add_theme_constant_override("separation", 2)
		hb.add_child(pv)
		pv.add_child(_lbl("%0.2f" % float(qd.price), 20, _pct_color(float(qd.pct)), true))
		pv.add_child(_lbl(_pct_str(float(qd.pct)), 17, _pct_color(float(qd.pct))))
	if btn_mode == "add":
		var on := watch.has(code)
		var b := _btn("已选" if on else "+自选", func(cd = code):
			if not watch.has(cd):
				_toggle_watch(cd)
				_watch_add_row(cd)
			var btn: Button = _add_btns.get(cd) if _add_btns.has(cd) else null
			if btn != null:
				btn.text = "已选"
				btn.disabled = true)
		b.add_theme_color_override("font_color", Global.C_GREEN if on else Global.C_MAIN)
		b.disabled = on
		b.custom_minimum_size = Vector2(72, 44)
		hb.add_child(b)
		_add_btns[code] = b
	elif btn_mode == "del":
		var b := _btn("删除", func():
			watch.erase(code)
			rebuild.call())
		b.add_theme_color_override("font_color", Global.C_AMBER)
		b.custom_minimum_size = Vector2(66, 44)
		hb.add_child(b)
	row.gui_input.connect(func(ev, cd = code):
		if ev is InputEventMouseButton and ev.pressed:
			_open_detail(cd))


func _toggle_watch(code: String) -> void:
	if watch.has(code):
		watch.erase(code)
	else:
		watch[code] = true
		_tut_on_watch_added()


## 自选列表局部加行(不重建整个行情页, 保持展开与滚动位置)
func _watch_add_row(code: String) -> void:
	# 防御: 页面已重建/释放则跳过(自选列表下次进入时自动重建)
	if _watch_body == null or not is_instance_valid(_watch_body):
		return
	# 移除空态提示
	for ch in _watch_body.get_children():
		if ch.has_meta("empty_tip"):
			ch.queue_free()
	var quote := _quote_cache
	if quote.is_empty():
		quote = _load_quote()
	_mk_stock_row(_watch_body, code, quote, "del", func(cd = code): _watch_del_row(cd))
	if _watch_count != null and is_instance_valid(_watch_count):
		_watch_count.text = "%d 只" % watch.size()


## 自选列表局部删行
func _watch_del_row(code: String) -> void:
	if _watch_body == null or not is_instance_valid(_watch_body):
		return
	for ch in _watch_body.get_children():
		if ch is PanelContainer and ch.has_meta("code") and str(ch.get_meta("code")) == code:
			ch.queue_free()
			break
	if _watch_count != null and is_instance_valid(_watch_count):
		_watch_count.text = "%d 只" % watch.size()
	# 删空后显示空态提示
	if watch.is_empty():
		var tip := _empty("暂无自选 · 点击列表右侧「+自选」添加")
		tip.custom_minimum_size = Vector2(0, 80)
		tip.set_meta("empty_tip", true)
		_watch_body.add_child(tip)


func _refresh_market_page() -> void:
	if page == "market":
		_show_page("market")


# ── 搜索 ──
func _section_search(parent: VBoxContainer, quote: Dictionary) -> void:
	var sec: Dictionary = _mk_section(parent, "搜索", false)
	var body: VBoxContainer = sec["body"]
	var count: Label = sec["count"]
	count.text = "%d 只" % quote.size()
	var search := LineEdit.new()
	search.placeholder_text = "输入代码或名称搜索"
	search.custom_minimum_size = Vector2(0, 52)
	search.add_theme_font_size_override("font_size", 17)
	body.add_child(search)
	var list := VBoxContainer.new()
	list.add_theme_constant_override("separation", 6)
	body.add_child(list)
	search.text_changed.connect(func(t):
		for ch in list.get_children():
			ch.queue_free()
		var shown := 0
		for code in quote:
			var qd: Dictionary = quote[code]
			if t != "" and not code.contains(t) and not str(qd.name).to_lower().contains(t.to_lower()):
				continue
			_mk_stock_row(list, str(code), quote, "add", func(): _refresh_market_page())
			shown += 1
			if shown >= 30:
				break
		if shown == 0:
			list.add_child(_empty("无匹配结果")))
	var shown2 := 0
	for code in quote:
		_mk_stock_row(list, str(code), quote, "add", func(): _refresh_market_page())
		shown2 += 1
		if shown2 >= 10:
			break


# ── 排行 ──
func _section_rank(parent: VBoxContainer, quote: Dictionary) -> void:
	var sec: Dictionary = _mk_section(parent, "排行", false)
	var body: VBoxContainer = sec["body"]
	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", 8)
	body.add_child(tabs)
	var list := VBoxContainer.new()
	list.add_theme_constant_override("separation", 6)
	body.add_child(list)
	var b_up := _btn("涨幅榜", func(): _build_rank_list(list, quote, "up"))
	b_up.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b_up.custom_minimum_size = Vector2(0, 40)
	tabs.add_child(b_up)
	var b_down := _btn("跌幅榜", func(): _build_rank_list(list, quote, "down"))
	b_down.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b_down.custom_minimum_size = Vector2(0, 40)
	tabs.add_child(b_down)
	var b_amt := _btn("成交额", func(): _build_rank_list(list, quote, "amt"))
	b_amt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b_amt.custom_minimum_size = Vector2(0, 40)
	tabs.add_child(b_amt)


func _build_rank_list(list: VBoxContainer, quote: Dictionary, mode: String) -> void:
	var arr := []
	for code in quote:
		arr.append([code, quote[code]])
	if mode == "up":
		arr.sort_custom(func(a, b): return float(a[1].pct) > float(b[1].pct))
	elif mode == "down":
		arr.sort_custom(func(a, b): return float(a[1].pct) < float(b[1].pct))
	else:
		arr.sort_custom(func(a, b): return float(a[1].amount) > float(b[1].amount))
	for ch in list.get_children():
		ch.queue_free()
	var shown := 0
	for it in arr:
		_mk_stock_row(list, str(it[0]), quote, "add", func(): _refresh_market_page())
		shown += 1
		if shown >= 20:
			break


# ── 板块精选 ──
func _build_sector_members(quote: Dictionary) -> Array:
	var out := []
	for sector in SECTORS:
		var sname := str(sector[0])
		var kws: Array = sector[1]
		var members := []
		var sum_pct := 0.0
		for code in quote:
			var qd: Dictionary = quote[code]
			var nm := str(qd.name)
			for kw in kws:
				if nm.contains(str(kw)):
					members.append(str(code))
					sum_pct += float(qd.pct)
					break
		if members.is_empty():
			continue
		out.append({"name": sname, "members": members,
			"avg": sum_pct / float(members.size())})
	return out


func _section_sector(parent: VBoxContainer, quote: Dictionary) -> void:
	var sec: Dictionary = _mk_section(parent, "板块精选", false)
	var body: VBoxContainer = sec["body"]
	var count: Label = sec["count"]
	if _sector_cache.is_empty():
		_sector_cache = _build_sector_members(quote)
	var sectors_shown := 0
	for secd in _sector_cache:
		var sname := str(secd.name)
		var members: Array = secd.members
		var avg := float(secd.avg)
		sectors_shown += 1
		var row := PanelContainer.new()
		row.add_theme_stylebox_override("panel", _card_style())
		body.add_child(row)
		var hb := HBoxContainer.new()
		hb.offset_left = 14
		hb.offset_right = -14
		hb.offset_top = 10
		hb.offset_bottom = -10
		row.add_child(hb)
		var arrow := _lbl("▸", 20, Global.C_SUB)
		hb.add_child(arrow)
		hb.add_child(_lbl(sname, 19, Global.C_TEXT, true))
		hb.add_child(_lbl("%d只" % members.size(), 14, Global.C_HINT))
		hb.add_spacer(false)
		hb.add_child(_lbl(_pct_str(avg), 16, _pct_color(avg), true))
		var mlist := VBoxContainer.new()
		mlist.add_theme_constant_override("separation", 6)
		mlist.offset_left = 8
		mlist.visible = false
		body.add_child(mlist)
		row.gui_input.connect(func(ev):
			if ev is InputEventMouseButton and ev.pressed:
				var was_open := mlist.visible
				# 懒加载: 首次展开才构建成员行(避免整页几百节点卡顿)
				if not was_open and mlist.get_child_count() == 0:
					for code in members:
						_mk_stock_row(mlist, code, quote, "add", func(): _refresh_market_page())
				mlist.visible = not was_open
				arrow.text = "▸" if not mlist.visible else "▾")
	count.text = "%d 个板块" % sectors_shown


# ── 特殊股票 (占位, 与能力相关) ──
func _section_special(parent: VBoxContainer) -> void:
	var sec: Dictionary = _mk_section(parent, "特殊股票", false)
	var body: VBoxContainer = sec["body"]
	var tip := _lbl("特殊股票与能力系统相关\n完成系统任务解锁后开放", 14, Global.C_HINT)
	tip.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tip.custom_minimum_size = Vector2(0, 70)
	body.add_child(tip)


# ── 自选列表 ──
func _section_watchlist(parent: VBoxContainer, quote: Dictionary) -> void:
	var sec: Dictionary = _mk_section(parent, "自选列表", true)
	var body: VBoxContainer = sec["body"]
	var count: Label = sec["count"]
	_watch_body = body
	_watch_count = count
	count.text = "%d 只" % watch.size()
	_rebuild_watch_body(body, quote)


func _rebuild_watch_body(body: VBoxContainer, quote: Dictionary) -> void:
	for ch in body.get_children():
		ch.queue_free()
	if watch.is_empty():
		var tip := _empty("暂无自选 · 点击列表右侧「+自选」添加")
		tip.custom_minimum_size = Vector2(0, 80)
		tip.set_meta("empty_tip", true)
		body.add_child(tip)
		return
	for code in watch:
		_mk_stock_row(body, str(code), quote, "del", func(cd = code): _watch_del_row(cd))


# ================= 自选页 =================
func _build_watch_page() -> void:
	var vb := VBoxContainer.new()
	vb.set_anchors_preset(Control.PRESET_FULL_RECT)
	vb.offset_left = 12
	vb.offset_right = -12
	vb.offset_top = 12
	vb.add_theme_constant_override("separation", 6)
	content.add_child(vb)
	if watch.is_empty():
		vb.add_child(_empty("暂无自选 · 在行情页点击股票可加入自选"))
		return
	var sc := ScrollContainer.new()
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vb.add_child(sc)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	sc.add_child(box)
	for code in watch:
		var c := gm.latest_close(str(code))
		var row := PanelContainer.new()
		row.add_theme_stylebox_override("panel", _card_style())
		box.add_child(row)
		var hb := HBoxContainer.new()
		hb.add_theme_constant_override("separation", 6)
		row.add_child(hb)
		hb.add_child(_lbl("%s %s" % [loader.stock_name(str(code)), code], 15,
			Global.C_TEXT, true))
		hb.add_spacer(false)
		if not is_nan(c):
			hb.add_child(_lbl("%0.2f" % c, 15, Global.C_TEXT))
		var rm := _btn("删除", func(c2 = code): watch.erase(c2); _build_watch_page())
		rm.custom_minimum_size = Vector2(50, 24)
		hb.add_child(rm)
		row.gui_input.connect(func(ev, c2 = code):
			if ev is InputEventMouseButton and ev.pressed:
				_open_detail(c2))


# ================= 个股详情(覆盖层) =================
func _open_detail(code: String) -> void:
	cur_code = code
	_close_detail()
	var ov := Control.new()
	ov.set_anchors_preset(Control.PRESET_FULL_RECT)
	content.add_child(ov)
	detail_overlay = ov
	var bg := ColorRect.new()
	bg.color = Global.C_BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	ov.add_child(bg)

	# 内容可滚动(分时+五档+公司信息+表单较长, 底部留白防悬浮块遮挡)
	var sc := ScrollContainer.new()
	sc.set_anchors_preset(Control.PRESET_FULL_RECT)
	ov.add_child(sc)
	var vb := VBoxContainer.new()
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb.add_theme_constant_override("separation", 6)
	vb.offset_bottom = -110
	sc.add_child(vb)

	# 顶部: 返回 + 名称价格
	var head := PanelContainer.new()
	head.add_theme_stylebox_override("panel", _card_style())
	vb.add_child(head)
	var hh := HBoxContainer.new()
	hh.add_theme_constant_override("separation", 10)
	head.add_child(hh)
	var back := _btn("← 返回", func(): _close_detail())
	back.flat = true
	hh.add_child(back)
	hh.add_child(_lbl("%s %s" % [loader.stock_name(code), _code_disp(code)], 17, Global.C_TEXT, true))
	hh.add_spacer(false)
	# 加自选 / 删自选 (显式切换, 成员引用避免 lambda 捕获 Nil)
	_wm_btn = _btn("加自选" if not watch.has(code) else "删自选", func(cd = code):
		_toggle_watch(cd)
		if _wm_btn != null:
			_wm_btn.text = "加自选" if not watch.has(cd) else "删自选",
		Global.C_AMBER, Global.C_CARD)
	_wm_btn.flat = true
	_wm_btn.add_theme_color_override("font_color", Global.C_AMBER)
	hh.add_child(_wm_btn)
	var c := gm.latest_close(code)
	var lp := gm.limit_prices(code)
	var pct := (c / float(lp.prev) - 1.0) * 100.0 if (not is_nan(float(lp.prev)) and float(lp.prev) > 0) else 0.0
	hh.add_child(_lbl("%0.2f" % c, 21, _pct_color(pct), true))
	hh.add_child(_lbl(_pct_str(pct), 14, _pct_color(pct)))

	# 图表类型切换: 分时/日K/周K/月K
	var ctabs := HBoxContainer.new()
	ctabs.add_theme_constant_override("separation", 8)
	vb.add_child(ctabs)
	var chart_box := PanelContainer.new()
	chart_box.add_theme_stylebox_override("panel", _card_style())
	chart_box.custom_minimum_size = Vector2(0, 250)
	vb.add_child(chart_box)
	var cbody := VBoxContainer.new()
	chart_box.add_child(cbody)
	# 注意: VBox 容器布局忽略锚点, 槽位须给最小尺寸(否则图表 size=0 画不出)
	var chart_slot := Control.new()
	chart_slot.custom_minimum_size = Vector2(0, 240)
	cbody.add_child(chart_slot)
	# 构建图表(切换时重建)
	var chart_code := code
	var chart_cb: Callable = func(ct: String):
		for ch in chart_slot.get_children():
			ch.queue_free()
		if ct == "分时":
			var mc := MinuteChart.new()
			mc.set_anchors_preset(Control.PRESET_FULL_RECT)
			chart_slot.add_child(mc)
			var st := gm.stock_chart(chart_code)
			mc.set_data(st.prices, st.avg, st.vols,
				float(lp.prev), not is_nan(float(lp.prev)))
		else:
			var kc: Control = preload("res://scripts/fx_kline.gd").new()
			kc.set_anchors_preset(Control.PRESET_FULL_RECT)
			chart_slot.add_child(kc)
			var period := "D" if ct == "日K" else ("W" if ct == "周K" else "M")
			var kd: Dictionary = loader.kline_data(chart_code, period, 60, gm.day_idx)
			kc.set_data(kd.get("klines", []))
	# 四个切换按钮(选中红底白字, 未选中白底深字)
	var ctab_order := ["分时", "日K", "周K", "月K"]
	for ctn in ctab_order:
		var tb := _btn(ctn, func(t = ctn): chart_cb.call(t),
			Color.WHITE if ctn == "分时" else Global.C_TEXT,
			Global.C_MAIN if ctn == "分时" else Global.C_CARD)
		tb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		tb.custom_minimum_size = Vector2(0, 38)
		ctabs.add_child(tb)
	chart_cb.call("分时")

	# 涨跌停/状态
	var info := _lbl("涨停 %s · 跌停 %s" % [
		"无" if is_nan(float(lp.up)) else "%0.2f" % float(lp.up),
		"无" if is_nan(float(lp.down)) else "%0.2f" % float(lp.down)],
		13, Global.C_SUB)
	vb.add_child(info)

	# 五档盘口(模拟)
	if not is_nan(c):
		_build_level5(vb, _mock_level5(code, c))
		_build_company_info(vb, code, c)

	# 持有信息
	var pos: Dictionary = gm.positions.get(code, {})
	if not pos.is_empty():
		var avg := float(pos.cost) / float(pos.shares) if pos.shares > 0 else 0.0
		vb.add_child(_lbl("已持有 %d 股 · 可用 %d · 成本 %0.3f" % [
			int(pos.shares), int(pos.shares) - int(pos.today_buy), avg],
			14, Global.C_SUB))

	# ── 下单表单 ──
	_build_detail_order_form(vb, code, c, pos)


## 详情页下单表单: 市价/限价 + 数量/价格 + 快捷 + 确认
func _build_detail_order_form(vb: VBoxContainer, code: String, c: float, pos: Dictionary) -> void:
	var form := PanelContainer.new()
	form.add_theme_stylebox_override("panel", _card_style())
	vb.add_child(form)
	var fv := VBoxContainer.new()
	fv.add_theme_constant_override("separation", 8)
	fv.offset_left = 12
	fv.offset_right = -12
	fv.offset_top = 10
	fv.offset_bottom = -10
	form.add_child(fv)

	# 价格模式行: 市价/限价 切换 + 价格输入
	var price_row := HBoxContainer.new()
	price_row.add_theme_constant_override("separation", 8)
	fv.add_child(price_row)
	_order_mk = _btn("市价", func(): _set_order_otype("MARKET"),
		Color.WHITE, Global.C_MAIN)
	_order_mk.custom_minimum_size = Vector2(64, 40)
	price_row.add_child(_order_mk)
	_order_lp = _btn("限价", func(): _set_order_otype("LIMIT"),
		Global.C_TEXT, Global.C_CARD)
	_order_lp.custom_minimum_size = Vector2(64, 40)
	price_row.add_child(_order_lp)
	var price_edit := LineEdit.new()
	price_edit.placeholder_text = "限价 (元)"
	price_edit.add_theme_font_size_override("font_size", 16)
	price_edit.custom_minimum_size = Vector2(0, 40)
	price_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	price_edit.editable = false
	price_edit.text = "%.2f" % c if not is_nan(c) else ""
	price_row.add_child(price_edit)
	_order_price = price_edit
	_detail_price_edit = price_edit
	_set_order_otype(_order_otype)

	# 数量行: 输入 + 快捷
	var qty_row := HBoxContainer.new()
	qty_row.add_theme_constant_override("separation", 8)
	fv.add_child(qty_row)
	var qty_edit: LineEdit = null
	qty_edit = LineEdit.new()
	qty_edit.text = "100"
	qty_edit.add_theme_font_size_override("font_size", 16)
	qty_edit.custom_minimum_size = Vector2(0, 40)
	qty_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	qty_row.add_child(qty_edit)
	_detail_qty_edit = qty_edit
	var half_btn := _btn("半仓", func(): _quick_fill_qty(0.5, code, c, pos))
	half_btn.custom_minimum_size = Vector2(58, 40)
	qty_row.add_child(half_btn)
	var all_btn := _btn("全仓", func(): _quick_fill_qty(1.0, code, c, pos))
	all_btn.custom_minimum_size = Vector2(58, 40)
	qty_row.add_child(all_btn)

	# 提交按钮: 买入/卖出
	var submit := HBoxContainer.new()
	submit.add_theme_constant_override("separation", 10)
	fv.add_child(submit)
	var buy_btn := _btn("确认买入", func(): _detail_order("BUY"), Color.WHITE, Global.C_RED)
	buy_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	buy_btn.custom_minimum_size = Vector2(0, 48)
	submit.add_child(buy_btn)
	var sell_btn := _btn("确认卖出", func(): _detail_order("SELL"), Color.WHITE, Global.C_GREEN)
	sell_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sell_btn.custom_minimum_size = Vector2(0, 48)
	submit.add_child(sell_btn)


func _set_order_otype(t: String) -> void:
	_order_otype = t
	if _order_mk != null:
		_order_mk.add_theme_color_override("font_color",
			Color.WHITE if t == "MARKET" else Global.C_TEXT)
		var mks := StyleBoxFlat.new()
		mks.bg_color = Global.C_MAIN if t == "MARKET" else Global.C_CARD
		mks.set_corner_radius_all(8)
		_order_mk.add_theme_stylebox_override("normal", mks)
		_order_mk.add_theme_stylebox_override("hover", mks)
		_order_mk.add_theme_stylebox_override("pressed", mks)
	if _order_lp != null:
		_order_lp.add_theme_color_override("font_color",
			Color.WHITE if t == "LIMIT" else Global.C_TEXT)
		var lps := StyleBoxFlat.new()
		lps.bg_color = Global.C_MAIN if t == "LIMIT" else Global.C_CARD
		lps.set_corner_radius_all(8)
		_order_lp.add_theme_stylebox_override("normal", lps)
		_order_lp.add_theme_stylebox_override("hover", lps)
		_order_lp.add_theme_stylebox_override("pressed", lps)
	if _order_price != null:
		_order_price.editable = (t == "LIMIT")


## 快捷填数量: 买入按可用资金, 卖出按可用持仓
func _quick_fill_qty(ratio: float, code: String, c: float, pos: Dictionary) -> void:
	if _detail_qty_edit == null:
		return
	var qty := 0
	if not pos.is_empty() and int(pos.shares) > 0:
		# 卖出: 按可用持仓
		var avail := int(pos.shares) - int(pos.today_buy)
		qty = int(avail * ratio / 100.0) * 100
	else:
		# 买入: 按可用资金(市价按现价, 限价按输入价)
		var px := c
		if _order_otype == "LIMIT" and _detail_price_edit != null:
			var v := _detail_price_edit.text.to_float()
			if v > 0:
				px = v
		if px <= 0:
			return
		qty = int(gm.cash / px * 0.97 * ratio / 100.0) * 100
	_detail_qty_edit.text = str(maxi(qty, 0))


func _detail_order(side: String) -> void:
	if cur_code == "":
		return
	var otype := _order_otype
	var price := 0.0
	if otype == "LIMIT":
		price = _detail_price_edit.text.to_float() if _detail_price_edit != null else 0.0
		if price <= 0:
			_toast("请输入有效价格", false)
			return
	var qty: int = 0
	if _detail_qty_edit != null:
		qty = _detail_qty_edit.text.to_int()
	if qty <= 0:
		_toast("请输入有效数量", false)
		return
	if side == "BUY" and qty % TradeEngine.LOT != 0:
		_toast("买入数量须为 100 股整数倍", false)
		return
	var r := gm.place_order(cur_code, side, otype, price, qty)
	if r.status == "REJECTED":
		_toast(str(r.msg), false)
	elif r.status == "PENDING":
		var od: Dictionary = r.order
		_toast("挂单成功: %s" % str(od.reason), true)
	else:
		var tr: Dictionary = r.trade
		_toast("成交 %s %d股 @%0.2f" % ["买入" if side == "BUY" else "卖出",
			int(tr.qty), float(tr.price)], true)
	_refresh_all()


func _close_detail() -> void:
	if detail_overlay != null:
		detail_overlay.queue_free()
		detail_overlay = null
	_order_mk = null
	_order_lp = null
	_order_price = null
	_wm_btn = null


# ================= 刷新/事件 =================
var _in_refresh := false   # 刷新重入防护(place_order 信号会同步触发刷新)

func _on_state_changed() -> void:
	_refresh_all()


func _refresh_all() -> void:
	if _in_refresh:
		return   # 防止下单信号触发刷新时重入导致的 UI 竞争
	_in_refresh = true
	# 时间推进后行情数据失效: 无条件清缓存(无论当前页, 用户常在交易页推进)
	_quote_cache.clear()
	_sector_cache = []
	if page == "trade":
		_refresh_asset_board()
		_refresh_trade_list()
	elif page == "market":
		_show_page("market")
	# 详情页打开时推进时间: 重建详情刷新价格(保持打开, 不关闭)
	if detail_overlay != null and cur_code != "":
		_open_detail(cur_code)
	_in_refresh = false


func _on_game_ended(victory: bool, message: String, stats: Dictionary) -> void:
	# 全屏黑色渐变遮罩
	var ov := ColorRect.new()
	ov.color = Color(0.03, 0.025, 0.015, 0.94)
	ov.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(ov)
	# 黑金大卡片
	var card := PanelContainer.new()
	var gs := StyleBoxFlat.new()
	gs.bg_color = Color(0.07, 0.05, 0.02, 0.98)
	gs.set_corner_radius_all(16)
	gs.border_color = Color(0.85, 0.68, 0.3, 0.95)
	gs.set_border_width_all(2)
	gs.shadow_color = Color(0, 0, 0, 0.5)
	gs.shadow_size = 14
	card.add_theme_stylebox_override("panel", gs)
	card.set_anchors_preset(Control.PRESET_CENTER)
	card.custom_minimum_size = Vector2(400, 0)
	card.position = Vector2(-200, -260)
	add_child(card)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 10)
	vb.offset_left = 24
	vb.offset_right = -24
	vb.offset_top = 26
	vb.offset_bottom = -26
	card.add_child(vb)

	# 顶部结果
	var title := _lbl("交易达成 · 成功逃脱" if victory else "交易失败 · 灵魂收割", 30,
		Color("#f0c75e") if victory else Color("#c0392b"), true)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_color_override("font_outline_color",
		Color(0.3, 0.2, 0.04, 1.0) if victory else Color(0.25, 0.05, 0.02, 1.0))
	title.add_theme_constant_override("outline_size", 6)
	vb.add_child(title)
	var sub := _lbl(message, 14, Color(0.88, 0.82, 0.68, 1.0))
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vb.add_child(sub)
	# 金线分隔
	var hline := HSeparator.new()
	hline.add_theme_stylebox_override("separator", _gold_line())
	vb.add_child(hline)

	# 数据网格(2列×4行)
	var rate := float(stats.get("rate", 0.0))
	var rate_col := Global.C_RED if rate >= 0 else Global.C_GREEN
	var items := [
		["最终资产", _fmt(float(stats.get("total", 0.0))), Color("#f0c75e")],
		["目标金额", _fmt(float(stats.get("target", 0.0))), Color(0.9, 0.85, 0.7, 1.0)],
		["最终收益率", ("+" if rate >= 0 else "") + "%0.2f%%" % rate, rate_col],
		["持仓数", "%d 只" % int(stats.get("pos_count", 0)), Color(0.9, 0.85, 0.7, 1.0)],
		["交易次数", "%d 笔" % int(stats.get("trade_count", 0)), Color(0.9, 0.85, 0.7, 1.0)],
		["存活天数", "%d / %d 天" % [int(stats.get("days", 0)), int(stats.get("death", 0))],
			Color(0.9, 0.85, 0.7, 1.0)],
		["累计手续费", _fmt(float(stats.get("fees", 0.0))), Color(0.9, 0.85, 0.7, 1.0)],
		["恶魔交易币", "+%d" % int(stats.get("coins", 0)), Color("#f0c75e")],
	]
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 16)
	grid.add_theme_constant_override("v_separation", 10)
	vb.add_child(grid)
	for it in items:
		var cell := VBoxContainer.new()
		cell.add_theme_constant_override("separation", 2)
		grid.add_child(cell)
		cell.add_child(_lbl(str(it[0]), 12, Color(0.65, 0.58, 0.42, 1.0)))
		cell.add_child(_lbl(str(it[1]), 18, it[2], true))
	vb.add_child(hline2())

	# 恶魔币奖励说明(成功时)
	if victory:
		var coins := int(stats.get("coins", 0))
		var coin_l := _lbl("恶魔交易币 +%d · 可在恶魔果实界面使用" % coins, 15,
			Color("#f0c75e"), true)
		coin_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		vb.add_child(coin_l)

	# 回到主菜单
	var back := _btn("回到主菜单", func(): Transition.to_scene("res://scenes/start_screen.tscn"),
		Color("#141007"), Color("#f0c75e"))
	back.custom_minimum_size = Vector2(0, 48)
	back.add_theme_font_size_override("font_size", 17)
	vb.add_child(back)


func _gold_line() -> StyleBoxLine:
	var s := StyleBoxLine.new()
	s.color = Color(0.7, 0.55, 0.25, 0.6)
	s.thickness = 1
	return s


func hline2() -> HSeparator:
	var s := HSeparator.new()
	s.add_theme_stylebox_override("separator", _gold_line())
	return s


var _toast_label: Label = null
var _flash_label: Label = null   # 翻天提示(剩余天数/目标差值)

func _toast(text: String, ok: bool) -> void:
	if _toast_label != null:
		_toast_label.queue_free()
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 15)
	l.add_theme_color_override("font_color", Global.C_RED if not ok else Global.C_GREEN)
	l.set_anchors_preset(Control.PRESET_CENTER_TOP)
	l.position = Vector2(-200, 60)
	l.custom_minimum_size = Vector2(400, 0)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(l)
	_toast_label = l
	var tw := create_tween()
	tw.tween_interval(2.0)
	tw.tween_callback(func():
		# 防御: 连点时旧 toast 可能已被下一次 _toast 释放
		if is_instance_valid(l) and _toast_label == l:
			l.queue_free()
			_toast_label = null)


# ================= 引导框(4页, 暗金恶魔风) =================
func _show_guide() -> void:
	if _guide != null:
		return
	_guide_idx = 0
	_guide = Control.new()
	_guide.set_anchors_preset(Control.PRESET_FULL_RECT)
	_guide.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_guide)
	# 自绘背景(暗金渐变+恶魔红眼+金粒)
	var fx := preload("res://scripts/fx_guide.gd").new()
	fx.set_anchors_preset(Control.PRESET_FULL_RECT)
	_guide.add_child(fx)
	_build_guide_card()
	_guide_refresh()
	# 淡入
	_guide.modulate.a = 0.0
	var tw := create_tween()
	tw.tween_property(_guide, "modulate:a", 1.0, 0.4)


func _build_guide_card() -> void:
	# 中央卡片
	var card := PanelContainer.new()
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.10, 0.07, 0.03, 0.97)
	s.set_corner_radius_all(16)
	s.border_color = Color(0.85, 0.68, 0.3, 0.9)
	s.set_border_width_all(2)
	s.shadow_color = Color(0, 0, 0, 0.6)
	s.shadow_size = 18
	card.add_theme_stylebox_override("panel", s)
	card.set_anchors_preset(Control.PRESET_CENTER)
	card.custom_minimum_size = Vector2(372, 0)
	card.position = Vector2(-186, -240)
	_guide.add_child(card)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 14)
	vb.offset_left = 22
	vb.offset_right = -22
	vb.offset_top = 24
	vb.offset_bottom = -22
	card.add_child(vb)

	# 页眉小字
	var kicker := _lbl("", 13, Color(0.72, 0.55, 0.22, 0.9))
	kicker.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(kicker)
	# 标题
	_guide_title = _lbl("", 28, Color("#f0c75e"), true)
	_guide_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(_guide_title)
	# 分隔金线
	var line := ColorRect.new()
	line.color = Color(0.85, 0.68, 0.3, 0.4)
	line.custom_minimum_size = Vector2(0, 1)
	vb.add_child(line)
	# 正文
	_guide_body = _lbl("", 16, Color(0.9, 0.84, 0.68, 1.0))
	_guide_body.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_guide_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_guide_body.custom_minimum_size = Vector2(0, 170)
	vb.add_child(_guide_body)

	# 页码点
	var dots := HBoxContainer.new()
	dots.alignment = BoxContainer.ALIGNMENT_CENTER
	dots.add_theme_constant_override("separation", 10)
	vb.add_child(dots)
	for i in 4:
		var d := _lbl("●", 17, Color(0.45, 0.38, 0.25, 1.0))
		dots.add_child(d)
		_guide_dots.append(d)

	# 按钮行
	var btns := HBoxContainer.new()
	btns.add_theme_constant_override("separation", 12)
	vb.add_child(btns)
	_guide_prev = _btn_guide("上一条", Color(0.8, 0.75, 0.62, 1.0),
		Color(0.14, 0.11, 0.06, 1.0), Color(0.5, 0.42, 0.3, 0.5), func(): _guide_prev_page())
	_guide_next = _btn_guide("下一条", Color("#f0c75e"),
		Color(0.22, 0.15, 0.04, 1.0), Color(0.85, 0.68, 0.3, 0.9), func(): _guide_next_page())
	for b in [_guide_prev, _guide_next]:
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.custom_minimum_size = Vector2(0, 46)
		btns.add_child(b)

	# 右上角跳过
	var skip := Button.new()
	skip.text = "跳过 ▸▸"
	skip.flat = true
	skip.add_theme_font_size_override("font_size", 15)
	skip.add_theme_color_override("font_color", Color(0.72, 0.55, 0.22, 0.95))
	skip.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	skip.position = Vector2(-106, 26)
	skip.custom_minimum_size = Vector2(96, 40)
	skip.pressed.connect(_close_guide)
	_guide.add_child(skip)


func _btn_guide(text: String, fg: Color, bg: Color, border: Color, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_color_override("font_color", fg)
	b.add_theme_font_size_override("font_size", 16)
	b.add_theme_font_override("font", _font(true))
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(9)
	sb.border_color = border
	sb.set_border_width_all(1)
	b.add_theme_stylebox_override("normal", sb)
	var sb_h := StyleBoxFlat.new()
	sb_h.bg_color = Color(0.32, 0.22, 0.07, 1.0)
	sb_h.set_corner_radius_all(9)
	sb_h.border_color = Color(1.0, 0.85, 0.4, 0.9)
	sb_h.set_border_width_all(1)
	b.add_theme_stylebox_override("hover", sb_h)
	b.add_theme_stylebox_override("pressed", sb_h)
	b.pressed.connect(cb)
	return b


func _guide_prev_page() -> void:
	if _guide_idx <= 0:
		return
	_guide_idx -= 1
	_guide_refresh()


func _guide_next_page() -> void:
	if _guide_idx >= 3:
		_close_guide()
		return
	_guide_idx += 1
	_guide_refresh()


func _close_guide() -> void:
	if _guide == null:
		return
	var tw := create_tween()
	tw.tween_property(_guide, "modulate:a", 0.0, 0.25)
	tw.tween_callback(func():
		_guide.queue_free()
		_guide = null
		# 引导框结束 → 启动新手教程(仅首次)
		if _tut_step == 0:
			_start_tutorial())


# ================= 新手教程(加自选 → 试试买入) =================
var _tut_step := 0              # 0=未开始 1=引导加自选 2=引导买入 3=完成
var _tut_card: Control = null
var _tut_title: Label
var _tut_body: Label


func _start_tutorial() -> void:
	if _tut_step != 0:
		return
	_tut_step = 1
	_build_tut_card()


func _build_tut_card() -> void:
	var card := PanelContainer.new()
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.07, 0.05, 0.02, 0.96)
	s.set_corner_radius_all(12)
	s.border_color = Color(0.85, 0.68, 0.3, 0.9)
	s.set_border_width_all(1.5)
	s.shadow_color = Color(0, 0, 0, 0.35)
	s.shadow_size = 8
	card.add_theme_stylebox_override("panel", s)
	card.set_anchors_preset(Control.PRESET_CENTER_TOP)
	# 放屏幕中下部(不挡顶部 5Tab/导航/资产看板), 且点击穿透(教程卡不拦截任何操作)
	card.position = Vector2(-195, 470)
	card.custom_minimum_size = Vector2(390, 0)
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(card)
	_tut_card = card
	var cv := VBoxContainer.new()
	cv.add_theme_constant_override("separation", 5)
	cv.offset_left = 14
	cv.offset_right = -14
	cv.offset_top = 10
	cv.offset_bottom = -10
	card.add_child(cv)
	var head := HBoxContainer.new()
	cv.add_child(head)
	_tut_title = _lbl("", 15, Color("#f0c75e"), true)
	head.add_child(_tut_title)
	head.add_spacer(false)
	var close := _btn("✕ 跳过", func(): _finish_tutorial(true))
	close.add_theme_font_size_override("font_size", 12)
	close.custom_minimum_size = Vector2(64, 30)
	head.add_child(close)
	_tut_body = _lbl("", 13, Color(0.92, 0.86, 0.72, 1.0))
	_tut_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	cv.add_child(_tut_body)
	_tut_refresh()
	card.modulate.a = 0.0
	var tw := create_tween()
	tw.tween_property(card, "modulate:a", 1.0, 0.3)


func _tut_refresh() -> void:
	if _tut_card == null:
		return
	if _tut_step == 1:
		_tut_title.text = "新手教程 1/2 · 添加自选"
		_tut_body.text = "去底部「行情」页，点击股票右侧的「+自选」，\n添加你的第一只自选股，之后才能买入。"
	elif _tut_step == 2:
		_tut_title.text = "新手教程 2/2 · 试试买入"
		_tut_body.text = "去「交易」-「买入」页，点股票的「买入」按钮，\n看看交易面板长什么样（不用真的下单）。"


## 加自选后推进教程
func _tut_on_watch_added() -> void:
	if _tut_step == 1:
		_tut_step = 2
		_tut_refresh()
		_toast("已添加自选！下一步：去「买入」页看看", true)


## 进入买入页后完成教程
func _tut_on_buy_tab() -> void:
	if _tut_step == 2:
		_finish_tutorial(false)


func _finish_tutorial(skipped: bool) -> void:
	_tut_step = 3
	if _tut_card != null and is_instance_valid(_tut_card):
		_tut_card.queue_free()
		_tut_card = null
	if not skipped:
		_toast("新手教程完成，祝你好运！", true)


func _guide_refresh() -> void:
	var g := _guide_pages()
	_guide_title.text = g.title
	_guide_body.text = g.body
	for i in 4:
		var d: Label = _guide_dots[i]
		d.add_theme_color_override("font_color",
			Color("#f0c75e") if i == _guide_idx else Color(0.45, 0.38, 0.25, 1.0))
	_guide_prev.disabled = (_guide_idx == 0)
	_guide_prev.visible = true
	_guide_next.text = "开始交易" if _guide_idx == 3 else "下一条"


func _guide_pages() -> Dictionary:
	var pages := [
		{
			"title": "与恶魔的交易",
			"body": "2026年7月，你输光了所有，从楼顶纵身而下。\n\n恶魔给了你第二次机会——回到2022年开户那天。\n\n条件：在死亡之前（剩余 %d 天），\n把100万本金做到 %s。\n\n做不到，灵魂归他。",
		},
		{
			"title": "陌生的世界",
			"body": "这里的一切似曾相识，却不可尽信。\n\n行情与企业，全部裁剪自A股真实历史，\n但顺序与名称，每一局都会重新打乱。\n\n不要相信你的记忆——去相信数据。",
		},
		{
			"title": "恶魔的馈赠",
			"body": "你已觉醒「重生股神系统」。\n\n完成系统发布的任务，可以获得\n技能与物品奖励。\n\n它们将是你绝境翻盘的资本。",
		},
		{
			"title": "出发吧",
			"body": "合理地运用你的能力，控制每一次出手。\n\n祝你好运——\n也别忘了，恶魔正看着你。",
		},
	]
	var p: Dictionary = pages[_guide_idx]
	var body := str(p.body)
	if _guide_idx == 0:
		body = body % [maxi(gm.days_left(), 0), _fmt(gm.target_asset)]
	return {"title": str(p.title), "body": body}


# ================= 事件日历(目标/任务/临时事件) =================
func _open_calendar() -> void:
	if cal_overlay != null:
		return
	var ov := Control.new()
	ov.set_anchors_preset(Control.PRESET_FULL_RECT)
	ov.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(ov)
	cal_overlay = ov
	# 半透明遮罩
	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.55)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	ov.add_child(bg)
	# 卡片
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", _card_style())
	card.set_anchors_preset(Control.PRESET_CENTER)
	card.custom_minimum_size = Vector2(400, 0)
	card.position = Vector2(-200, -280)
	ov.add_child(card)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 12)
	vb.offset_left = 20
	vb.offset_right = -20
	vb.offset_top = 20
	vb.offset_bottom = -20
	card.add_child(vb)

	# 标题
	var title := _lbl("事件日历", 28, Global.C_MAIN, true)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(title)
	var tsub := _lbl(gm.real_day() + " · 交易日第 %d 日" % (gm.day_idx + 1), 15, Global.C_SUB)
	tsub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(tsub)
	var hline := HSeparator.new()
	vb.add_child(hline)

	# ① 最终目标(与恶魔的交易)
	var sec1 := _lbl("① 最终目标 · 与恶魔的交易", 17, Global.C_TEXT, true)
	vb.add_child(sec1)
	var goal := _lbl(
		"在死亡之前，把 100 万本金做到 %s（%d 倍）\n距死期：剩余 %d 天\n当前总资产：%s" % [
			_fmt(gm.target_asset), int(gm.target_asset / 1000000.0),
			maxi(gm.days_left(), 0), _fmt(gm.total_asset())],
		16, Global.C_SUB)
	goal.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vb.add_child(goal)

	# ② 任务
	var sec2 := _lbl("② 任务", 17, Global.C_TEXT, true)
	vb.add_child(sec2)
	var task := _lbl("暂无任务 · 完成系统发布的任务可获得技能与物品奖励", 15, Global.C_HINT)
	task.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vb.add_child(task)

	# ③ 临时事件
	var sec3 := _lbl("③ 临时事件", 17, Global.C_TEXT, true)
	vb.add_child(sec3)
	var evt := _lbl("暂无临时事件", 15, Global.C_HINT)
	vb.add_child(evt)

	# 关闭按钮
	var close := _btn("关闭", func(): _close_calendar())
	close.custom_minimum_size = Vector2(0, 48)
	vb.add_child(close)
	# 淡入
	ov.modulate.a = 0.0
	var tw := create_tween()
	tw.tween_property(ov, "modulate:a", 1.0, 0.25)


func _close_calendar() -> void:
	if cal_overlay == null:
		return
	cal_overlay.queue_free()
	cal_overlay = null


# ================= 个股详情: 五档盘口 / 公司信息 (模拟) =================
const INDUSTRIES := ["白酒", "半导体", "人工智能", "新能源", "医药", "银行", "证券",
	"军工", "汽车", "通信", "食品饮料", "有色金属", "电力", "房地产", "机械"]


## 模拟五档盘口(seed 稳定, 同股每次一致)
func _mock_level5(code: String, price: float) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = absi(code.hash())
	var tick := 0.01
	var asks := []
	var bids := []
	for i in range(5):
		asks.append([TradeEngine.round2(price + tick * float(i + 1)),
			int(rng.randf_range(100, 8000))])
		bids.append([TradeEngine.round2(price - tick * float(i + 1)),
			int(rng.randf_range(100, 8000))])
	return {"asks": asks, "bids": bids}


func _build_level5(vb: VBoxContainer, lv: Dictionary) -> void:
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", _card_style())
	vb.add_child(card)
	var cv := VBoxContainer.new()
	cv.add_theme_constant_override("separation", 3)
	cv.offset_left = 12
	cv.offset_right = -12
	cv.offset_top = 10
	cv.offset_bottom = -10
	card.add_child(cv)
	cv.add_child(_lbl("五档盘口", 14, Global.C_TEXT, true))
	var asks: Array = lv["asks"]
	var bids: Array = lv["bids"]
	# 卖盘(卖五→卖一, 绿色)
	for i in range(5):
		var row := HBoxContainer.new()
		cv.add_child(row)
		row.add_child(_lbl("卖%d" % (5 - i), 13, Global.C_HINT))
		row.add_spacer(false)
		var ap: Array = asks[4 - i]
		row.add_child(_lbl("%0.2f" % float(ap[0]), 14, Global.C_GREEN, true))
		row.add_child(_lbl("%d手" % int(ap[1]), 13, Global.C_SUB))
	# 现价分隔
	var mid := _lbl("──── 现价 ────", 13, Global.C_TEXT, true)
	mid.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cv.add_child(mid)
	# 买盘(买一→买五, 红色)
	for i in range(5):
		var row := HBoxContainer.new()
		cv.add_child(row)
		row.add_child(_lbl("买%d" % (i + 1), 13, Global.C_HINT))
		row.add_spacer(false)
		var bp: Array = bids[i]
		row.add_child(_lbl("%0.2f" % float(bp[0]), 14, Global.C_RED, true))
		row.add_child(_lbl("%d手" % int(bp[1]), 13, Global.C_SUB))


## 模拟公司概况(seed 稳定)
func _mock_company(code: String, price: float) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = absi(code.hash()) + 7
	var h := absi(code.hash())
	var industry: String = INDUSTRIES[h % INDUSTRIES.size()]
	var total_shares := roundf(rng.randf_range(3.0, 180.0) * 10.0) / 10.0   # 亿股
	var float_shares := roundf(total_shares * rng.randf_range(0.55, 0.98) * 10.0) / 10.0
	var total_cap := total_shares * price * 1e8
	var float_cap := float_shares * price * 1e8
	var eps := price / rng.randf_range(18.0, 80.0)
	var bvps := price / rng.randf_range(1.2, 9.0)
	return {
		"industry": industry, "total_shares": total_shares, "float_shares": float_shares,
		"total_cap": total_cap, "float_cap": float_cap,
		"pe": price / eps, "pb": price / bvps, "eps": eps, "bvps": bvps,
		"high52": TradeEngine.round2(price * rng.randf_range(1.12, 1.75)),
		"low52": TradeEngine.round2(price * rng.randf_range(0.5, 0.82)),
	}


func _build_company_info(vb: VBoxContainer, code: String, price: float) -> void:
	var m := _mock_company(code, price)
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", _card_style())
	vb.add_child(card)
	var cv := VBoxContainer.new()
	cv.add_theme_constant_override("separation", 5)
	cv.offset_left = 12
	cv.offset_right = -12
	cv.offset_top = 10
	cv.offset_bottom = -10
	card.add_child(cv)
	cv.add_child(_lbl("公司概况", 14, Global.C_TEXT, true))
	var rows := [
		"行业        %s" % str(m.industry),
		"总市值      %s      流通市值  %s" % [_fmt(float(m.total_cap)), _fmt(float(m.float_cap))],
		"总股本      %0.1f亿股   流通股本  %0.1f亿股" % [float(m.total_shares), float(m.float_shares)],
		"市盈率      %0.1f       市净率    %0.2f" % [float(m.pe), float(m.pb)],
		"每股收益    %0.2f元     每股净资产 %0.2f元" % [float(m.eps), float(m.bvps)],
		"52周高      %0.2f       52周低    %0.2f" % [float(m.high52), float(m.low52)],
	]
	for r in rows:
		cv.add_child(_lbl(r, 13, Global.C_SUB))


# ================= 快速购买面板 (买入列表直接下单) =================
var _qb: Control = null
var _qb_code := ""


func _open_quick_buy(code: String) -> void:
	if _qb != null:
		return
	_qb_code = code
	_order_otype = "MARKET"
	var c := gm.latest_close(code)
	var ov := Control.new()
	ov.set_anchors_preset(Control.PRESET_FULL_RECT)
	ov.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(ov)
	_qb = ov
	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.55)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	ov.add_child(bg)
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", _card_style())
	card.set_anchors_preset(Control.PRESET_CENTER)
	card.custom_minimum_size = Vector2(400, 0)
	card.position = Vector2(-200, -140)
	ov.add_child(card)
	var cv := VBoxContainer.new()
	cv.add_theme_constant_override("separation", 10)
	cv.offset_left = 20
	cv.offset_right = -20
	cv.offset_top = 18
	cv.offset_bottom = -18
	card.add_child(cv)

	var title := _lbl("快速买入 · %s %s" % [loader.stock_name(code), _code_disp(code)],
		20, Global.C_MAIN, true)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cv.add_child(title)
	if not is_nan(c):
		var px_l := _lbl("现价 %0.2f" % c, 15, Global.C_TEXT, true)
		px_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		cv.add_child(px_l)

	# 价格模式(成员引用, 避免 lambda 引用局部变量)
	var pr := HBoxContainer.new()
	pr.add_theme_constant_override("separation", 8)
	cv.add_child(pr)
	_order_mk = _btn("市价", func(): _set_order_otype("MARKET"), Color.WHITE, Global.C_MAIN)
	_order_mk.custom_minimum_size = Vector2(72, 44)
	pr.add_child(_order_mk)
	_order_lp = _btn("限价", func(): _set_order_otype("LIMIT"), Global.C_TEXT, Global.C_CARD)
	_order_lp.custom_minimum_size = Vector2(72, 44)
	pr.add_child(_order_lp)
	var pe := LineEdit.new()
	pe.placeholder_text = "限价 (元)"
	pe.add_theme_font_size_override("font_size", 16)
	pe.custom_minimum_size = Vector2(0, 44)
	pe.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pe.editable = false
	pe.text = "%.2f" % c if not is_nan(c) else ""
	pr.add_child(pe)
	_order_price = pe
	_set_order_otype(_order_otype)

	# 数量(成员引用)
	var qr := HBoxContainer.new()
	qr.add_theme_constant_override("separation", 8)
	cv.add_child(qr)
	_qb_qty_edit = LineEdit.new()
	_qb_qty_edit.text = "100"
	_qb_qty_edit.add_theme_font_size_override("font_size", 16)
	_qb_qty_edit.custom_minimum_size = Vector2(0, 44)
	_qb_qty_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	qr.add_child(_qb_qty_edit)
	var hb := _btn("半仓", func():
		if not is_nan(c) and _qb_qty_edit != null:
			_qb_qty_edit.text = str(maxi(int(gm.cash / c * 0.97 * 0.5 / 100.0) * 100, 0)))
	hb.custom_minimum_size = Vector2(62, 44)
	qr.add_child(hb)
	var ab := _btn("全仓", func():
		if not is_nan(c) and _qb_qty_edit != null:
			_qb_qty_edit.text = str(maxi(int(gm.cash / c * 0.97 / 100.0) * 100, 0)))
	ab.custom_minimum_size = Vector2(62, 44)
	qr.add_child(ab)

	# 确认/取消
	var br := HBoxContainer.new()
	br.add_theme_constant_override("separation", 10)
	cv.add_child(br)
	var confirm := _btn("确认买入", func():
		var otype: String = _order_otype
		var price := 0.0
		if otype == "LIMIT":
			if _order_price == null:
				return
			price = _order_price.text.to_float()
			if price <= 0:
				_toast("请输入有效价格", false)
				return
		var qty: int = _qb_qty_edit.text.to_int() if _qb_qty_edit != null else 0
		if qty <= 0:
			_toast("请输入有效数量", false)
			return
		if qty % TradeEngine.LOT != 0:
			_toast("买入数量须为 100 股整数倍", false)
			return
		var r: Dictionary = gm.place_order(_qb_code, "BUY", otype, price, qty)
		if r.status == "REJECTED":
			_toast(str(r.msg), false)
		elif r.status == "PENDING":
			_toast("挂单成功: %s" % str(r.order.reason), true)
		else:
			_toast("成交买入 %d股 @%0.2f" % [int(r.trade.qty), float(r.trade.price)], true)
		_close_quick_buy()
		_refresh_all()
		, Color.WHITE, Global.C_RED)
	confirm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	confirm.custom_minimum_size = Vector2(0, 48)
	br.add_child(confirm)
	var cancel := _btn("取消", func(): _close_quick_buy())
	cancel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cancel.custom_minimum_size = Vector2(0, 48)
	br.add_child(cancel)
	ov.modulate.a = 0.0
	var tw := create_tween()
	tw.tween_property(ov, "modulate:a", 1.0, 0.2)


func _close_quick_buy() -> void:
	if _qb == null:
		return
	_qb.queue_free()
	_qb = null
	_qb_qty_edit = null
	_order_mk = null
	_order_lp = null
	_order_price = null


## 快速卖出面板(卖出页持仓行直接下单, 与快速买入同款大尺寸)
func _open_quick_sell(code: String) -> void:
	if _qb != null:
		return
	_qb_code = code
	_order_otype = "MARKET"
	var c := gm.latest_close(code)
	var pos: Dictionary = gm.positions.get(code, {})
	var avail := 0
	if not pos.is_empty():
		avail = int(pos.shares) - int(pos.today_buy)
	var ov := Control.new()
	ov.set_anchors_preset(Control.PRESET_FULL_RECT)
	ov.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(ov)
	_qb = ov
	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.55)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	ov.add_child(bg)
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", _card_style())
	card.set_anchors_preset(Control.PRESET_CENTER)
	card.custom_minimum_size = Vector2(400, 0)
	card.position = Vector2(-200, -140)
	ov.add_child(card)
	var cv := VBoxContainer.new()
	cv.add_theme_constant_override("separation", 10)
	cv.offset_left = 20
	cv.offset_right = -20
	cv.offset_top = 18
	cv.offset_bottom = -18
	card.add_child(cv)

	var title := _lbl("快速卖出 · %s %s" % [loader.stock_name(code), _code_disp(code)],
		20, Global.C_GREEN, true)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cv.add_child(title)
	if not is_nan(c):
		var px_l := _lbl("现价 %0.2f    可用 %d 股" % [c, avail], 15, Global.C_TEXT, true)
		px_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		cv.add_child(px_l)

	# 价格模式(成员引用)
	var pr := HBoxContainer.new()
	pr.add_theme_constant_override("separation", 8)
	cv.add_child(pr)
	_order_mk = _btn("市价", func(): _set_order_otype("MARKET"), Color.WHITE, Global.C_MAIN)
	_order_mk.custom_minimum_size = Vector2(72, 44)
	pr.add_child(_order_mk)
	_order_lp = _btn("限价", func(): _set_order_otype("LIMIT"), Global.C_TEXT, Global.C_CARD)
	_order_lp.custom_minimum_size = Vector2(72, 44)
	pr.add_child(_order_lp)
	var pe := LineEdit.new()
	pe.placeholder_text = "限价 (元)"
	pe.add_theme_font_size_override("font_size", 16)
	pe.custom_minimum_size = Vector2(0, 44)
	pe.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pe.editable = false
	pe.text = "%.2f" % c if not is_nan(c) else ""
	pr.add_child(pe)
	_order_price = pe
	_set_order_otype(_order_otype)

	# 数量(默认可用持仓; 半仓/全仓按持仓算)
	var qr := HBoxContainer.new()
	qr.add_theme_constant_override("separation", 8)
	cv.add_child(qr)
	_qb_qty_edit = LineEdit.new()
	_qb_qty_edit.text = str(avail)
	_qb_qty_edit.add_theme_font_size_override("font_size", 16)
	_qb_qty_edit.custom_minimum_size = Vector2(0, 44)
	_qb_qty_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	qr.add_child(_qb_qty_edit)
	var hb := _btn("半仓", func():
		if _qb_qty_edit != null:
			_qb_qty_edit.text = str(maxi(int(avail * 0.5), 0)))
	hb.custom_minimum_size = Vector2(62, 44)
	qr.add_child(hb)
	var ab := _btn("全仓", func():
		if _qb_qty_edit != null:
			_qb_qty_edit.text = str(avail))
	ab.custom_minimum_size = Vector2(62, 44)
	qr.add_child(ab)

	# 确认/取消
	var br := HBoxContainer.new()
	br.add_theme_constant_override("separation", 10)
	cv.add_child(br)
	var confirm := _btn("确认卖出", func():
		var otype: String = _order_otype
		var price := 0.0
		if otype == "LIMIT":
			if _order_price == null:
				return
			price = _order_price.text.to_float()
			if price <= 0:
				_toast("请输入有效价格", false)
				return
		var qty: int = _qb_qty_edit.text.to_int() if _qb_qty_edit != null else 0
		if qty <= 0:
			_toast("请输入有效数量", false)
			return
		if qty > avail:
			_toast("可卖数量不足, 可用 %d 股" % avail, false)
			return
		var r: Dictionary = gm.place_order(_qb_code, "SELL", otype, price, qty)
		if r.status == "REJECTED":
			_toast(str(r.msg), false)
		elif r.status == "PENDING":
			_toast("挂单成功: %s" % str(r.order.reason), true)
		else:
			_toast("成交卖出 %d股 @%0.2f" % [int(r.trade.qty), float(r.trade.price)], true)
		_close_quick_buy()
		_refresh_all()
		, Color.WHITE, Global.C_GREEN)
	confirm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	confirm.custom_minimum_size = Vector2(0, 48)
	br.add_child(confirm)
	var cancel := _btn("取消", func(): _close_quick_buy())
	cancel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cancel.custom_minimum_size = Vector2(0, 48)
	br.add_child(cancel)
	ov.modulate.a = 0.0
	var tw := create_tween()
	tw.tween_property(ov, "modulate:a", 1.0, 0.2)

class_name GF
## 全局字体: 打包开源 Noto Sans CJK(安卓无 macOS 系统字体, 必须自带字体)
## 用法: GF.regular() / GF.bold() 或 ThemeDB.fallback_font 全局兜底

static var _regular: FontFile = null
static var _bold: Font = null

static func regular() -> FontFile:
	if _regular == null:
		_regular = load("res://assets/fonts/NotoSansCJKsc-Regular.otf") as FontFile
	return _regular

static func bold() -> Font:
	if _bold == null:
		var fv := FontVariation.new()
		fv.base_font = regular()
		fv.variation_embolden = 0.5   # 伪粗体(仅打包了 Regular 字重)
		_bold = fv
	return _bold

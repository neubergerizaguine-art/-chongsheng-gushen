extends Node
## 全局单例: 跨场景参数 + 统一配色
## 配色遵循 A 股惯例: 红涨绿跌

var difficulty := 1          # 0简单 1普通 2地狱

## 恶魔交易币: 成功结算时累积, 可在恶魔果实界面使用(功能待装, 仅持久化显示)
var demon_coins := 0


func _ready() -> void:
	_load_demon_coins()


func _load_demon_coins() -> void:
	var cf := ConfigFile.new()
	if cf.load("user://save.cfg") == OK:
		demon_coins = int(cf.get_value("meta", "demon_coins", 0))


func add_demon_coins(n: int) -> void:
	demon_coins += n
	var cf := ConfigFile.new()
	cf.set_value("meta", "demon_coins", demon_coins)
	cf.save("user://save.cfg")

# 浅色精致主题(券商 APP 风)
const C_BG := Color("#f5f6fa")       # 页面背景
const C_CARD := Color("#ffffff")     # 卡片
const C_MAIN := Color("#d0021b")     # 品牌主色(红)
const C_RED := Color("#e03131")      # 涨/正收益
const C_GREEN := Color("#0a9b4a")    # 跌/负收益
const C_TEXT := Color("#1a1a1a")     # 主文字
const C_SUB := Color("#8a8a8a")      # 次级文字
const C_HINT := Color("#b0b3b8")     # 辅助/单位
const C_LINE := Color("#e7e7e7")     # 分隔线
const C_AMBER := Color("#e8590c")    # 强调橙

const C_RED_BG := Color("#fdecec")   # 涨浅底
const C_GREEN_BG := Color("#e9f7ef")  # 跌浅底

# 主菜单金色主题
const GOLD := Color("#f0c75e")          # 亮金
const GOLD_DARK := Color("#b8860b")     # 深金(边框)
const GOLD_BG := Color("#141007")       # 深棕金背景
const GOLD_BG2 := Color("#221a0c")      # 背景渐变底
const GOLD_OUTLINE := Color("#3a2a05")  # 标题描边深棕

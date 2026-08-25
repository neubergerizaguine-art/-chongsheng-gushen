extends RefCounted
class_name DataLoader
## 游戏数据加载层: 读取洗牌后的数据包(meta.json + day_bins/*.bin)
## bin 格式: u32 magic'ASTK' | u32 version | u32 n | u32 m | u16 day_idx
##          | float32 prev_close × n | float32[o,h,l,c,v] × n × m

const DATA_DIR := "res://game_data/game"
const MAGIC := 0x4153544B

var meta: Dictionary = {}
var pool: Array = []          # [{code, name}] 按数据包顺序
var code_to_idx: Dictionary = {}
var days: Array = []          # [{idx, real_day, block}]
var minute_count := 0
var times: PackedStringArray = []   # 分钟时间标签

var _day_cache: Dictionary = {}     # day_idx -> {prev_close, data}
var _calendar: PackedStringArray = []   # 游戏连续交易日日历(与历史解耦)
var _game_prev: PackedFloat32Array = []   # 游戏内昨收链 (n_days × n_stocks)

func _init() -> void:
	_load_meta()
	_build_times()


func _load_meta() -> bool:
	var path := DATA_DIR + "/meta.json"
	if not FileAccess.file_exists(path):
		push_error("找不到数据包 meta.json: " + path)
		return false
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("无法打开 meta.json")
		return false
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("meta.json 解析失败")
		return false
	meta = parsed
	minute_count = meta.get("minute_count", 241)
	for p in meta.get("pool", []):
		pool.append({"code": p.code, "name": str(p.get("name", p.code))})
		code_to_idx[p.code] = pool.size() - 1
	for d in meta.get("days", []):
		days.append({"idx": d.idx, "real_day": d.real_day, "block": d.block})
	return pool.size() > 0


func _build_times() -> void:
	# 与数据源一致的时间轴: 09:30-11:30 + 13:01-15:00 (共241点)
	times.clear()
	for i in 121:
		var mins := 30 + i
		times.append("%02d:%02d:00" % [9 + mins / 60, mins % 60])
	for i in 120:
		var mins := 1 + i
		times.append("%02d:%02d:00" % [13 + mins / 60, mins % 60])


## 开局随机化: ①股票数据列↔公司随机匹配 ②历史数据↔游戏日随机匹配
## 每次新局调用(随机种子), 防背答案; 显示日期用连续日历, 不随真实历史跳变
func reshuffle() -> void:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	# ① 股票池洗牌: 数据列 ↔ 公司名称/代码 随机匹配
	var perm := _rand_perm(pool.size(), rng)
	var new_pool: Array = []
	for i in perm:
		new_pool.append(pool[i])
	code_to_idx.clear()
	for i in range(new_pool.size()):
		code_to_idx[str(new_pool[i].code)] = i
	pool = new_pool
	# ② 历史日洗牌: 游戏日 ↔ 真实历史数据随机匹配
	var dperm := _rand_perm(days.size(), rng)
	var new_days: Array = []
	for i in dperm:
		new_days.append(days[i])
	days = new_days
	_day_cache.clear()


static func _rand_perm(n: int, rng: RandomNumberGenerator) -> Array:
	var a: Array = []
	for i in range(n):
		a.append(i)
	for i in range(n - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var t = a[i]
		a[i] = a[j]
		a[j] = t
	return a


## 预生成游戏连续交易日日历(2022-09-01 起, 跳过周末, 与真实历史日期解耦)
func build_calendar(n: int) -> void:
	_calendar.clear()
	var y := 2022
	var m := 9
	var d := 1
	while _calendar.size() < n:
		var wd := _weekday(y, m, d)
		if wd != 0 and wd != 1:   # 0=周六 1=周日 跳过
			_calendar.append("%04d%02d%02d" % [y, m, d])
		var nd := _next_day(y, m, d)
		y = nd[0]
		m = nd[1]
		d = nd[2]


## 游戏日 → 连续日历日期("20220901"), 超出返回 "----"
func game_day_str(day_idx: int) -> String:
	if day_idx < _calendar.size():
		return _calendar[day_idx]
	return "----"


static func _days_in_month(y: int, m: int) -> int:
	var dm := [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
	if m == 2 and (y % 4 == 0 and (y % 100 != 0 or y % 400 == 0)):
		return 29
	return dm[m - 1]


static func _next_day(y: int, m: int, d: int) -> Array:
	d += 1
	if d > _days_in_month(y, m):
		d = 1
		m += 1
		if m > 12:
			m = 1
			y += 1
	return [y, m, d]


## 蔡勒公式星期: 0=周六 1=周日 2=周一 ... 5=周四 6=周五
static func _weekday(y: int, m: int, d: int) -> int:
	if m < 3:
		m += 12
		y -= 1
	return (d + (13 * (m + 1)) / 5 + y + y / 4 - y / 100 + y / 400) % 7


func stock_name(code: String) -> String:
	var i: int = code_to_idx.get(code, -1)
	if i < 0:
		return code
	return str(pool[i].get("name", code))


## 预计算游戏内昨收链: 洗牌后历史日期乱序, 若直接继承历史价格会跨日跳变几十倍。
## 方案: 只继承历史涨跌幅, 价格从前一游戏日收盘连续(第0日以历史昨收为起点)。
## 成交量按价格缩放重算(保持成交额形态)。开局时调用, 允许花费数秒。
func preprocess() -> void:
	var n := days.size()
	var m := pool.size()
	if n <= 0 or m <= 0:
		return
	_game_prev.resize(n * m)
	var prev_g := PackedFloat32Array()
	prev_g.resize(m)
	for k in range(n):
		var raw := _load_raw(k)
		if raw.is_empty():
			continue
		var hist_prev: PackedFloat32Array = raw["prev_close"]
		var data: PackedFloat32Array = raw["data"]
		for i in range(m):
			var hp := hist_prev[i]
			var base: float = hp if k == 0 else prev_g[i]
			# 收盘价: 最后一分钟有效价 × 涨跌幅(钳制在游戏内涨跌停)
			var lim := _limit_pct(str(pool[i].code), str(pool[i].name))
			var c := price_at(data, i, 240)
			var close := base
			if not is_nan(c) and not is_nan(hp) and hp > 0:
				close = base * clampf(c / hp, 1.0 - lim, 1.0 + lim)
			_game_prev[k * m + i] = close
			prev_g[i] = close
	_day_cache.clear()


## 加载某一天(洗牌后顺序)的全市场数据, 价格已归一化(游戏内连续)
## 返回 { prev_close: PackedFloat32Array(n), data: PackedFloat32Array(n*m*5),
##        o/h/l/c/v 按 [stock][minute] 扁平, 块内交错 }
func load_day(day_idx: int, use_cache: bool = true) -> Dictionary:
	if use_cache and _day_cache.has(day_idx):
		return _day_cache[day_idx]
	var raw := _load_raw(day_idx)
	if raw.is_empty():
		return {}
	var res := _normalize_day(raw, day_idx)
	if use_cache:
		_day_cache[day_idx] = res
		# 缓存只保留最近 6 天: 快进大量天数时防止内存膨胀(每天约2.4MB)
		if _day_cache.size() > 8:
			var stale: Array = []
			for k in _day_cache:
				if int(k) < day_idx - 6:
					stale.append(k)
			for k in stale:
				_day_cache.erase(k)
	return res


## K线聚合(基于归一化后数据): period "D"(日)/"W"(周=5交易日)/"M"(月)
## 返回 {klines: [{o,h,l,c,v,label}], }
func kline_data(code: String, period: String, count: int, cur_day: int) -> Dictionary:
	var si: int = code_to_idx.get(code, -1)
	if si < 0:
		return {}
	var need := count
	if period == "W":
		need = count * 5
	elif period == "M":
		need = count * 22
	var start := maxi(0, cur_day - need - 2)
	var m := pool.size()
	var lim := _limit_pct(code, str(pool[si].get("name", code)))
	var daily: Array = []
	var labels: Array = []
	for k in range(start, cur_day + 1):
		# 只归一化目标股票(避免整包 500 股归一化, 周/月K 提速约 500 倍)
		var raw := _load_raw(k)
		if raw.is_empty():
			continue
		var hp: float = raw.prev_close[si]
		var base: float = hp if k == 0 else _game_prev[(k - 1) * m + si]
		var data: PackedFloat32Array = raw.data
		var scale := base / hp if (not is_nan(hp) and hp > 0) else 0.0
		var mcnt := int(raw.get("minute_count", 241))
		var o := -1.0
		var h := -1e18
		var l := 1e18
		var c := 0.0
		var vsum := 0.0
		for mi in range(mcnt):
			var b := field_base(si, mi)
			var p := data[b + F_C]
			if is_nan(p):
				continue
			if scale > 0.0:
				p = base * clampf(p / hp, 1.0 - lim, 1.0 + lim)
				vsum += data[b + F_V] * scale
			else:
				p = base
			if o < 0.0:
				o = p
			h = maxf(h, p)
			l = minf(l, p)
			c = p
		if o < 0.0:
			continue   # 全天停牌
		daily.append([o, h, l, c, vsum])
		labels.append(game_day_str(k))
	if daily.is_empty():
		return {}
	var klines: Array = []
	var dlen := daily.size()
	if period == "D":
		for i in range(maxi(0, dlen - count), dlen):
			klines.append(_mk_kline(daily[i], labels[i]))
	elif period == "W":
		# 每 5 个交易日一组
		var grp: Array = []
		var glabel := ""
		for i in range(dlen - 1, -1, -1):
			grp.append(daily[i])
			glabel = labels[i]
			if grp.size() >= 5 or i == 0:
				var g := _agg_group(grp)
				klines.append(_mk_kline(g, glabel))
				grp = []
		klines.reverse()
		if klines.size() > count:
			klines = klines.slice(klines.size() - count)
	elif period == "M":
		# 按日历月分组
		var grp2: Array = []
		var glabel2 := ""
		var gmonth := ""
		for i in range(dlen - 1, -1, -1):
			var lb: String = labels[i]
			var mth := lb.substr(0, 6)
			if gmonth != "" and mth != gmonth:
				klines.append(_mk_kline(_agg_group(grp2), glabel2))
				grp2 = []
			grp2.append(daily[i])
			glabel2 = lb
			gmonth = mth
		if not grp2.is_empty():
			klines.append(_mk_kline(_agg_group(grp2), glabel2))
		klines.reverse()
		if klines.size() > count:
			klines = klines.slice(klines.size() - count)
	return {"klines": klines}


static func _mk_kline(d: Array, label: String) -> Dictionary:
	return {"o": d[0], "h": d[1], "l": d[2], "c": d[3], "v": d[4], "label": label}


static func _agg_group(grp: Array) -> Array:
	var o: float = float(grp[grp.size() - 1][0])
	var h := -1e18
	var l := 1e18
	var c: float = float(grp[0][3])
	var v := 0.0
	for d in grp:
		h = maxf(h, float(d[1]))
		l = minf(l, float(d[2]))
		v += float(d[4])
	return [o, h, l, c, v]


## 读原始 bin(不归一化, 不缓存)
func _load_raw(day_idx: int) -> Dictionary:
	var res: Dictionary = {}
	if day_idx >= days.size():
		return res
	# 洗牌后 days[day_idx].idx 才是真实 bin 文件编号
	var path := "%s/day_bins/%04d.bin" % [DATA_DIR, int(days[day_idx].idx)]
	if not FileAccess.file_exists(path):
		push_warning("缺少数据文件: " + path)
		return res
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return res
	var magic := f.get_32()
	if magic != MAGIC:
		f.close()
		push_warning("数据文件格式错误: " + path)
		return res
	f.get_32()  # version
	var n := f.get_32()
	var m := f.get_32()
	f.get_16()  # day_index
	var prev := PackedFloat32Array()
	prev.resize(n)
	for i in n:
		prev[i] = f.get_float()
	var raw := f.get_buffer(n * m * 5 * 4)
	f.close()
	res["prev_close"] = prev
	res["data"] = raw.to_float32_array()
	res["stock_count"] = n
	res["minute_count"] = m
	return res


## 归一化: 只继承历史涨跌幅, 价格=游戏内昨收×(1+pct); 停牌价=昨收量=0;
## 成交量按价格缩放(×游戏内昨收/历史昨收), 保持成交额形态
func _normalize_day(raw: Dictionary, day_idx: int) -> Dictionary:
	var hist_prev: PackedFloat32Array = raw["prev_close"]
	var data: PackedFloat32Array = raw["data"].duplicate()
	var m := pool.size()
	var mcnt := int(raw.get("minute_count", 241))
	var res: Dictionary = {}
	var prev_g := PackedFloat32Array()
	prev_g.resize(m)
	for i in range(m):
		# 游戏内昨收 = 前一游戏日收盘(第0日用历史昨收为起点)
		var base: float = hist_prev[i] if day_idx == 0 else \
			_game_prev[(day_idx - 1) * m + i]
		prev_g[i] = base
		var hp := hist_prev[i]
		var scale := base / hp if (not is_nan(hp) and hp > 0) else 0.0
		var lim := _limit_pct(str(pool[i].code), str(pool[i].name))
		var lo := 1.0 - lim
		var hi := 1.0 + lim
		for mi in range(mcnt):
			var b := field_base(i, mi)
			var c := data[b + F_C]
			if not is_nan(c) and scale > 0.0:
				# 涨跌幅钳制在游戏内涨跌停(随机匹配后防止超板块限制)
				data[b + F_O] = base * clampf(data[b + F_O] / hp, lo, hi)
				data[b + F_H] = base * clampf(data[b + F_H] / hp, lo, hi)
				data[b + F_L] = base * clampf(data[b + F_L] / hp, lo, hi)
				data[b + F_C] = base * clampf(c / hp, lo, hi)
				data[b + F_V] = data[b + F_V] * scale   # 成交量重算
			else:
				# 停牌: 价=昨收, 量=0
				data[b + F_O] = base
				data[b + F_H] = base
				data[b + F_L] = base
				data[b + F_C] = base
				data[b + F_V] = 0.0
	res["prev_close"] = prev_g
	res["data"] = data
	res["stock_count"] = int(raw.get("stock_count", m))
	res["minute_count"] = mcnt
	return res


## 游戏内涨跌停比例(按显示公司板块): 主板10% 创业板/科创板20% 北交所30% ST 5%
static func _limit_pct(code: String, name: String) -> float:
	if name.contains("ST"):
		return 0.05
	if code.begins_with("688") or code.begins_with("689") \
			or code.begins_with("300") or code.begins_with("301"):
		return 0.20
	if code.begins_with("8") or code.begins_with("4") or code.begins_with("92"):
		return 0.30
	return 0.10


## 取某股票某分钟: base 索引
static func field_base(stock_idx: int, minute_idx: int) -> int:
	return stock_idx * 241 * 5 + minute_idx * 5

const F_O := 0
const F_H := 1
const F_L := 2
const F_C := 3
const F_V := 4


## 便捷取值
static func price_at(data: PackedFloat32Array, stock_idx: int, minute_idx: int) -> float:
	var b := field_base(stock_idx, minute_idx)
	return data[b + F_C]


static func high_at(data: PackedFloat32Array, stock_idx: int, minute_idx: int) -> float:
	return data[field_base(stock_idx, minute_idx) + F_H]


static func low_at(data: PackedFloat32Array, stock_idx: int, minute_idx: int) -> float:
	return data[field_base(stock_idx, minute_idx) + F_L]


static func vol_at(data: PackedFloat32Array, stock_idx: int, minute_idx: int) -> float:
	return data[field_base(stock_idx, minute_idx) + F_V]


## 最新有效分钟(考虑停牌: NaN 价格)
static func last_minute(data: PackedFloat32Array, stock_idx: int, until_idx: int) -> int:
	for mi in range(until_idx, -1, -1):
		var p := price_at(data, stock_idx, mi)
		if not is_nan(p):
			return mi
	return -1


static func is_nan(v: float) -> bool:
	return v != v

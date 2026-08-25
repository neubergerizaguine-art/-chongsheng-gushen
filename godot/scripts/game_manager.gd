extends RefCounted
class_name GameManager
## 游戏状态机: 资金/持仓/委托/成交 + 时间推进 + 撮合
## 规则: T+1 / 动态涨跌停 / 委托价区间 / 限价单触及撮合 / 手续费

signal state_changed
signal game_ended(victory: bool, message: String, stats: Dictionary)

const INIT_CASH := 1_000_000.0

var data: DataLoader
var difficulty := 1
var death_day_idx := 200
var target_asset := 3_000_000.0

var cash := INIT_CASH
var positions := {}       # code -> {shares, cost, today_buy}
var orders: Array = []    # 委托(含历史)
var trades: Array = []    # 成交
var day_idx := 0
var t := 0
var base_asset := INIT_CASH
var run_over := false
var _order_seq := 1
var _trade_seq := 1
var _day: Dictionary = {}     # 当前日数据(DataLoader.load_day 结果)

const DIFFICULTIES := [
	{"name": "难度一", "death": 220, "target": 2.0},
	{"name": "难度二", "death": 210, "target": 2.5},
	{"name": "难度三", "death": 200, "target": 3.0},
	{"name": "难度四", "death": 190, "target": 3.5},
	{"name": "难度五", "death": 180, "target": 4.0},
	{"name": "难度六", "death": 170, "target": 4.5},
	{"name": "难度七", "death": 160, "target": 5.0},
]


func _init(loader: DataLoader) -> void:
	data = loader


func setup_run(diff: int) -> void:
	difficulty = clampi(diff, 0, DIFFICULTIES.size() - 1)
	var cfg: Dictionary = DIFFICULTIES[difficulty]
	death_day_idx = int(cfg.death)
	target_asset = INIT_CASH * float(cfg.target)
	# 开局随机化: 股票↔公司、历史↔游戏日 重新匹配(每次新局不同, 随机种子)
	data.reshuffle()
	data.build_calendar(data.days.size())
	# 预计算价格归一化链(只继承涨跌幅, 价格连续; 需读全部数据, 耗时数秒)
	data.preprocess()
	reset_run()


func reset_run() -> void:
	cash = INIT_CASH
	positions.clear()
	orders.clear()
	trades.clear()
	day_idx = 0
	t = 0
	run_over = false
	_order_seq = 1
	_trade_seq = 1
	load_current_day()
	recalc_base()


func load_current_day() -> void:
	_day = data.load_day(day_idx)


func recalc_base() -> void:
	# 当日开盘总资产: 现金 + 持仓按 09:30 开盘价估值
	var mv := 0.0
	for code in positions:
		var si: int = data.code_to_idx.get(code, -1)
		if si < 0:
			continue
		var p := DataLoader.price_at(_day.data, si, 0)
		if is_nan(p):
			p = 0.0
		mv += float(positions[code].shares) * p
	base_asset = cash + mv


# ---------- 时间 ----------
func time_str() -> String:
	if t >= data.times.size():
		return "--:--:--"
	var ts := data.times[t]
	# 数据时间轴无13:00(下午开盘第一分钟标为13:01)。
	# 下午时段整体显示减1分钟, 使 11:30→13:00、13:00+15分→13:15 连续;
	# 收盘 15:00(t=240) 保持不变。
	if t >= 121 and t < 240:
		var hh := ts.substr(0, 2).to_int()
		var mm := ts.substr(3, 2).to_int()
		mm -= 1
		if mm < 0:
			mm = 59
			hh -= 1
		return "%02d:%02d%s" % [hh, mm, ts.substr(5)]
	return ts


func is_closed() -> bool:
	return t >= data.times.size() - 1


func days_left() -> int:
	return death_day_idx - day_idx


func total_days() -> int:
	return data.days.size()


func real_day() -> String:
	# 游戏连续日历日期(与真实历史解耦): 洗牌后历史乱序, 但显示日期必须连续不乱跳
	return data.game_day_str(day_idx)


func month_block() -> String:
	# 历史月份块不再用于显示(日历连续), 保留空实现
	return ""


## 推进分钟并跳过午休(11:31-13:00): 跨过 11:30(t=120) 直接到 13:01(t=121)
func _advance_minutes(nt: int, m: int) -> int:
	if t <= 120 and nt > 120:
		nt = 121
	return mini(nt, m - 1)


func can_advance(step: String) -> bool:
	## 该步进是否会越过收盘/最后交易日(跨天则禁用)
	if run_over:
		return false
	var m := data.times.size()
	# 跨过收盘(最后分钟)即禁用; 午休跳转由 advance 内部处理(不影响可用性判断)
	if step == "15m":
		# 尾盘允许推进到收盘: 14:45 +15 → 15:00(clamp 由 _advance_minutes 处理)
		return t < m - 1
	elif step == "1h":
		return t + 60 < m
	elif step == "1d":
		# +1日永不禁用: 推进到死期/数据末尾由 advance 内部结算或自然停止
		return true
	return false


func advance(step: String) -> void:
	if run_over:
		return
	var m := data.times.size()
	if step == "15m":
		t = _advance_minutes(t + 15, m)
	elif step == "1h":
		t = _advance_minutes(t + 60, m)
	elif step == "1d":
		if day_idx < data.days.size() - 1:
			day_idx += 1
			t = 0
			load_current_day()
			# 跨日: 当日买入解冻, 挂单作废
			for code in positions:
				positions[code].today_buy = 0
			for o in orders:
				if o.status == "PENDING":
					o.status = "CANCELLED"
					o.reason = "当日收盘未成交, 自动作废"
			recalc_base()
	# 撮合
	match_orders()
	# 死期结算
	if day_idx >= death_day_idx and not run_over:
		finish_run()


## 批量快进 N 天: 中间天只推进状态(解冻/挂单作废/死期判断), 跳过数据加载;
## 仅最后一天 load_current_day(读盘+归一化 1 次), 快进 30 天提速约 30 倍
func advance_bulk(n: int) -> void:
	if run_over:
		return
	var limit := mini(n, data.days.size() - 1 - day_idx)
	for i in range(limit):
		day_idx += 1
		t = 0
		# 跨日: 当日买入解冻, 挂单作废
		for code in positions:
			positions[code].today_buy = 0
		for o in orders:
			if o.status == "PENDING":
				o.status = "CANCELLED"
				o.reason = "当日收盘未成交, 自动作废"
		# 死期结算(快进途中到达死期立即结算)
		if day_idx >= death_day_idx:
			load_current_day()
			recalc_base()
			finish_run()
			return
	load_current_day()
	recalc_base()


func finish_run() -> void:
	run_over = true
	var victory := total_asset() >= target_asset
	var msg := ""
	if victory:
		msg = "你在死期前赚够了目标金额，挣脱了恶魔的契约！"
	else:
		msg = "死期已至，你没能完成与恶魔的交易……"
	# 恶魔交易币奖励: 胜利 = 难度系数×50(难度一50 → 难度七350)
	var coins := 0
	if victory:
		coins = (difficulty + 1) * 50
		Global.add_demon_coins(coins)
	# 结算统计
	var fees := 0.0
	for tr in trades:
		fees += float(tr.fee)
	var stats := {
		"total": total_asset(), "target": target_asset,
		"rate": (total_asset() / INIT_CASH - 1.0) * 100.0,
		"pos_count": positions.size(), "trade_count": trades.size(),
		"days": day_idx + 1, "death": death_day_idx,
		"fees": fees, "coins": coins, "victory": victory,
	}
	game_ended.emit(victory, msg, stats)


# ---------- 行情 ----------
func stock_idx(code: String) -> int:
	return data.code_to_idx.get(code, -1)


func latest_minute(code: String) -> int:
	var si := stock_idx(code)
	if si < 0:
		return -1
	return DataLoader.last_minute(_day.data, si, t)


func latest_close(code: String) -> float:
	var mi := latest_minute(code)
	if mi < 0:
		return NAN
	return DataLoader.price_at(_day.data, stock_idx(code), mi)


func limit_prices(code: String) -> Dictionary:
	var si := stock_idx(code)
	if si < 0:
		return {"up": NAN, "down": NAN, "prev": NAN}
	var prev := float(_day.prev_close[si])
	var pct := TradeEngine.limit_pct(code, data.stock_name(code))
	if is_nan(prev):
		return {"up": NAN, "down": NAN, "prev": NAN}
	return {
		"up": TradeEngine.round2(prev * (1.0 + pct)),
		"down": TradeEngine.round2(prev * (1.0 - pct)),
		"prev": prev,
	}


# ---------- 资产 ----------
func market_value() -> float:
	var mv := 0.0
	for code in positions:
		var c := latest_close(code)
		if not is_nan(c):
			mv += float(positions[code].shares) * c
	return mv


func total_asset() -> float:
	return cash + market_value()


func day_pnl() -> float:
	return total_asset() - base_asset


func position_rows() -> Array:
	var rows := []
	for code in positions:
		var pos: Dictionary = positions[code]
		var c: float = latest_close(code)
		var shares_f: float = float(pos.shares)
		var mv: float = shares_f * c if not is_nan(c) else 0.0
		var avg: float = float(pos.cost) / shares_f if shares_f > 0 else 0.0
		var pnl: float = (c - avg) * shares_f if not is_nan(c) else 0.0
		var pnl_pct: float = (c / avg - 1.0) * 100.0 if (not is_nan(c) and avg > 0) else 0.0
		# 当日涨跌(相对游戏内昨收): 持仓条目显示当日, 资产看板显示累计
		var si := stock_idx(code)
		var pc := float(_day.prev_close[si]) if si >= 0 else NAN
		var day_pnl: float = (c - pc) * shares_f if (not is_nan(c) and not is_nan(pc)) else 0.0
		var day_pct: float = (c / pc - 1.0) * 100.0 \
			if (not is_nan(c) and not is_nan(pc) and pc > 0) else 0.0
		rows.append({
			"code": code, "name": data.stock_name(code),
			"shares": pos.shares, "avail": pos.shares - pos.today_buy,
			"today_buy": pos.today_buy, "cost": pos.cost, "avg_cost": avg,
			"price": c, "market_value": mv, "pnl": pnl, "pnl_pct": pnl_pct,
			"day_pnl": day_pnl, "day_pct": day_pct,
		})
	rows.sort_custom(func(a, b): return a.market_value > b.market_value)
	return rows


# ---------- 交易 ----------
func place_order(code: String, side: String, otype: String, price: float, qty: int) -> Dictionary:
	side = side.to_upper()
	otype = otype.to_upper()
	if run_over:
		return {"status": "REJECTED", "msg": "游戏已结束"}
	if is_closed() and otype != "LIMIT" or is_closed():
		return {"status": "REJECTED", "msg": "已收盘, 无法下单"}
	var si := stock_idx(code)
	if si < 0:
		return {"status": "REJECTED", "msg": "股票不在数据池"}
	var lc := latest_close(code)
	if is_nan(lc):
		return {"status": "REJECTED", "msg": "该股当日无交易(停牌)"}
	var lp := limit_prices(code)
	if otype == "MARKET":
		price = lc
	if price <= 0:
		return {"status": "REJECTED", "msg": "价格必须大于0"}
	price = TradeEngine.round2(price)
	if qty <= 0:
		return {"status": "REJECTED", "msg": "数量必须为正"}
	# 涨跌停拦截
	if side == "BUY" and TradeEngine.is_limit_up(lc, lp.up):
		return {"status": "REJECTED", "msg": "已涨停(%0.2f元), 买不进" % lp.up}
	if side == "SELL" and TradeEngine.is_limit_down(lc, lp.down):
		return {"status": "REJECTED", "msg": "已跌停(%0.2f元), 卖不出" % lp.down}
	# 委托价区间
	if not is_nan(lp.up) and price > lp.up + TradeEngine.PRICE_TICK:
		return {"status": "REJECTED", "msg": "委托价超涨停价 %0.2f" % lp.up}
	if not is_nan(lp.down) and price < lp.down - TradeEngine.PRICE_TICK:
		return {"status": "REJECTED", "msg": "委托价低于跌停价 %0.2f" % lp.down}
	if side == "BUY":
		if positions.size() >= 30 and not positions.has(code):
			return {"status": "REJECTED", "msg": "最多同时持有 30 只股票"}
		if qty % TradeEngine.LOT != 0:
			return {"status": "REJECTED", "msg": "买入数量须为100股整数倍"}
		var need := qty * price
		var fee := TradeEngine.fee("BUY", need)
		if need + fee > cash + 1e-6:
			return {"status": "REJECTED", "msg": "可用资金不足"}
		if otype == "LIMIT" and price < lc - 1e-9:
			return _create_order(code, side, price, qty,
				"挂单中: 买入价低于市价, 等待回调")
		return _fill(code, side, price, qty, lc, true)
	else:
		var pos: Dictionary = positions.get(code, {})
		if pos.is_empty() or pos.get("shares", 0) <= 0:
			return {"status": "REJECTED", "msg": "无此持仓"}
		var avail := int(pos.shares) - int(pos.today_buy)
		if avail <= 0:
			return {"status": "REJECTED", "msg": "可用股数为0 (T+1: 当日买入不可当日卖出)"}
		if qty > avail:
			return {"status": "REJECTED", "msg": "可卖数量不足, 可用 %d 股" % avail}
		if otype == "LIMIT" and price > lc + 1e-9:
			return _create_order(code, side, price, qty,
				"挂单中: 卖出价高于市价, 等待拉升")
		return _fill(code, side, price, qty, lc, true)


func _create_order(code: String, side: String, price: float, qty: int, reason: String) -> Dictionary:
	var order := {
		"id": _order_seq, "day": day_idx, "time": time_str(), "code": code,
		"name": data.stock_name(code), "side": side, "type": "LIMIT",
		"price": price, "qty": qty, "status": "PENDING", "reason": reason,
		"filled_price": 0.0, "filled_time": "", "time_idx": t,
	}
	_order_seq += 1
	orders.append(order)
	return {"status": "PENDING", "order": order}


func _fill(code: String, side: String, price: float, qty: int, fill_price: float,
		immediate: bool, order: Dictionary = {}) -> Dictionary:
	fill_price = TradeEngine.round2(fill_price)
	var amount := qty * fill_price
	var fee := TradeEngine.fee(side, amount)
	if side == "BUY":
		cash -= amount + fee
		var pos: Dictionary = positions.get(code, {"shares": 0, "cost": 0.0, "today_buy": 0})
		pos.shares = int(pos.shares) + qty
		pos.cost = float(pos.cost) + amount + fee
		pos.today_buy = int(pos.today_buy) + qty
		positions[code] = pos
	else:
		cash += amount - fee
		var pos: Dictionary = positions[code]
		var old_shares := int(pos.shares)
		if old_shares > 0:
			pos.cost = float(pos.cost) - float(pos.cost) * (float(qty) / float(old_shares))
		pos.shares = old_shares - qty
		if pos.shares <= 0:
			positions.erase(code)
	var trade := {
		"id": _trade_seq, "day": day_idx, "time": time_str(), "code": code,
		"name": data.stock_name(code), "side": side, "price": fill_price,
		"qty": qty, "amount": snappedf(amount, 0.01), "fee": fee,
		"type": "MARKET" if immediate else "LIMIT",
		"matched": "immediate" if immediate else "triggered",
	}
	_trade_seq += 1
	trades.append(trade)
	if not order.is_empty():
		order.status = "FILLED"
		order.filled_price = fill_price
		order.filled_time = time_str()
		order.reason = "已成交"
	state_changed.emit()
	return {"status": "FILLED", "trade": trade}


func match_orders() -> void:
	if _day.is_empty():
		return
	for o in orders:
		if o.status != "PENDING":
			continue
		var si := stock_idx(o.code)
		if si < 0:
			continue
		var hit := false
		var mi_from := int(o.time_idx) + 1
		for mi in range(mi_from, t + 1):
			var c := DataLoader.price_at(_day.data, si, mi)
			if is_nan(c):
				continue
			var lp := limit_prices(o.code)
			if o.side == "BUY":
				var lo := DataLoader.low_at(_day.data, si, mi)
				if lo <= float(o.price) + 1e-9:
					if TradeEngine.is_limit_up(c, lp.up):
						continue
					hit = true
					break
			else:
				var hi := DataLoader.high_at(_day.data, si, mi)
				if hi >= float(o.price) - 1e-9:
					if TradeEngine.is_limit_down(c, lp.down):
						continue
					hit = true
					break
		if hit:
			_fill(o.code, o.side, float(o.price), int(o.qty), float(o.price),
				false, o)


func cancel_order(id: int) -> Dictionary:
	for o in orders:
		if o.id == id and o.status == "PENDING":
			o.status = "CANCELLED"
			o.reason = "用户撤单"
			state_changed.emit()
			return {"status": "CANCELLED"}
	return {"status": "REJECTED", "msg": "未找到可撤销的挂单"}


# ---------- 列表 ----------
func market_rows(limit: int = -1) -> Array:
	## 全池行情行(当前时刻): code/name/price/pct/amount(估算 vol*price)
	var rows := []
	for si in range(0, data.pool.size()):
		var code := str(data.pool[si].code)
		var mi := DataLoader.last_minute(_day.data, si, t)
		if mi < 0:
			continue
		var c := DataLoader.price_at(_day.data, si, mi)
		var prev := float(_day.prev_close[si])
		var pct := (c / prev - 1.0) * 100.0 if (not is_nan(prev) and prev > 0) else 0.0
		var lp := limit_prices(code)
		var amt := 0.0
		for k in range(0, mi + 1):
			amt += DataLoader.vol_at(_day.data, si, k) * DataLoader.price_at(_day.data, si, k)
		rows.append({
			"code": code, "name": data.stock_name(code),
			"price": c, "pct": pct, "amount": amt,
			"limit_up": lp.up, "limit_down": lp.down,
		})
	rows.sort_custom(func(a, b): return b.amount > a.amount)
	if limit > 0 and rows.size() > limit:
		rows = rows.slice(0, limit)
	return rows


func stock_chart(code: String) -> Dictionary:
	## 分时数据: prices/avg/vols/prev_close
	var si := stock_idx(code)
	if si < 0:
		return {}
	var n := t + 1
	var prices := PackedFloat32Array()
	var avg := PackedFloat32Array()
	var vols := PackedFloat32Array()
	var cum_amt := 0.0
	var cum_vol := 0.0
	for mi in range(0, n):
		var c := DataLoader.price_at(_day.data, si, mi)
		var v := DataLoader.vol_at(_day.data, si, mi)
		prices.append(c)
		vols.append(v)
		cum_amt += c * v
		cum_vol += v
		avg.append(cum_amt / cum_vol if cum_vol > 0 else NAN)
	var lp := limit_prices(code)
	return {"prices": prices, "avg": avg, "vols": vols,
		"prev_close": lp.prev, "times": data.times.slice(0, n)}


# ---------- 工具 ----------
static func fmt_money(v: float) -> String:
	var abs_v := absf(v)
	var s := ""
	if abs_v >= 1e8:
		s = "%0.2f亿" % (v / 1e8)
	elif abs_v >= 1e4:
		s = "%0.1f万" % (v / 1e4)
	else:
		s = "%0.0f" % v
	return s

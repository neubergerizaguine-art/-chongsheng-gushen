extends RefCounted
class_name TradeEngine
## 交易规则引擎(严格按 A 股规则):
## T+1 / 动态涨跌停 / 委托价限涨跌停区间 / 限价单触及撮合 / 手续费

const COMMISSION_RATE := 0.00025   # 佣金 万2.5
const COMMISSION_MIN := 5.0        # 最低 5 元
const STAMP_TAX_RATE := 0.001      # 印花税(卖出) 千1
const TRANSFER_FEE_RATE := 0.00001 # 过户费 万0.1
const LOT := 100
const PRICE_TICK := 0.01
const EPS := 0.005


## 按板块与名称计算涨跌幅限制
static func limit_pct(code: String, name: String) -> float:
	if code.begins_with("688") or code.begins_with("689"):
		return 0.20
	if code.begins_with("300") or code.begins_with("301"):
		return 0.20
	if code.begins_with("8") or code.begins_with("4") or code.begins_with("92"):
		return 0.30
	if name.contains("ST"):
		return 0.05
	return 0.10


static func fee(side: String, amount: float) -> float:
	var comm := maxf(amount * COMMISSION_RATE, COMMISSION_MIN)
	var stamp := amount * STAMP_TAX_RATE if side == "SELL" else 0.0
	var transfer := amount * TRANSFER_FEE_RATE
	return snappedf(comm + stamp + transfer, 0.01)


static func round2(v: float) -> float:
	return snappedf(v, 0.01)


## 是否触及涨停/跌停 (按最新收盘价判断)
static func is_limit_up(close: float, limit_up: float) -> bool:
	return limit_up == limit_up and close >= limit_up - EPS   # NaN 保护


static func is_limit_down(close: float, limit_dn: float) -> bool:
	return limit_dn == limit_dn and close <= limit_dn + EPS

#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""引擎冒烟测试: 验证初始化/时间推进/买卖/T+1/涨跌停/挂单撮合"""
import sys, traceback, math
sys.path.insert(0, "/Users/malihao/WorkBuddy/股市仿真游戏")
import server

data = server.data_svc
game = server.game

passed, failed = 0, 0
def check(name, cond, extra=""):
    global passed, failed
    if cond:
        passed += 1
        print(f"  [PASS] {name}")
    else:
        failed += 1
        print(f"  [FAIL] {name} {extra}")

print("== 1. 初始化 ==")
game.reset(data.days[0])
s = game.state()
check("现金=100万", abs(s["cash"] - 1_000_000) < 0.01, str(s["cash"]))
check("时间=09:30", s["time"] == "09:30:00", s["time"])
check("总资产=100万", abs(s["total_asset"] - 1_000_000) < 0.01)
check("起始日", s["day"] == data.days[0], s["day"])
check("时间点241", s["time_list_len"] == 241, str(s["time_list_len"]))

print("== 2. 市场概览 ==")
ov = game.overview()
check("有指数", ov["index"]["cur"] is not None, str(ov["index"]))
check("股票数>1000", ov["market"]["stock_count"] > 1000, str(ov["market"]["stock_count"]))
check("涨跌统计和为总", ov["breadth"]["up"] + ov["breadth"]["down"] + ov["breadth"]["flat"] == ov["market"]["stock_count"])
check("成交额>0", ov["market"]["amount"] > 0)
print("   指数:", ov["index"]["cur"], "涨跌:", ov["breadth"])

print("== 3. 时间推进 ==")
game.advance("15m")
check("+15m到09:45", game.time_str == "09:45:00", game.time_str)
game.advance("1h")
check("+1h到10:45", game.time_str == "10:45:00", game.time_str)
game.t = 120  # 11:30
game.advance("15m")
check("11:30+15m按交易时间累计到13:15(跳过午休)", game.time_str == "13:15:00", game.time_str)
game.t = len(game.time_list) - 1  # 15:00收盘
check("15:00收盘", game.is_closed)
game.advance("1d")
check("+1交易日换日09:30", s["day"] != game.day and game.time_str == "09:30:00",
      f"{game.day} {game.time_str}")

print("== 4. 买入(市价) ==")
game.reset(data.days[0])
# 找一只非涨停股
ov = game.overview()
stk = [r for r in ov["gainers"] if r["pct"] < 9][0]
code6, name = stk["code"], stk["name"]
print(f"   选择: {code6} {name} 现价 {stk['price']} 涨幅 {stk['pct']}%")
qty = 1000
r = game.place_order(code6, "BUY", "MARKET", None, qty)
check("市价买入成交", r["status"] == "FILLED", str(r))
s = game.state()
pos = s["positions"][0]
check("持仓股数", pos["shares"] == qty)
check("现金减少", abs(s["cash"] - (1_000_000 - pos["cost"])) < 0.01)
cost = pos["cost"]
check("成本含费用", cost > qty * pos["avg_cost"], str(cost))

print("== 5. T+1 卖出拦截 ==")
try:
    game.place_order(code6, "SELL", "MARKET", None, qty)
    check("当日卖出被拦截", False)
except Exception as e:
    check("当日卖出被拦截", "T+1" in str(e), str(e))

print("== 6. 跨日后可卖 ==")
game.t = len(game.time_list) - 1
game.advance("1d")
r = game.place_order(code6, "SELL", "MARKET", None, qty)
check("次日卖出成交", r["status"] == "FILLED", str(r))
check("持仓清零", len(game.state()["positions"]) == 0)
s = game.state()
print("   现金:", s["cash"], "(买入1000股后的盈亏包含在内)")

print("== 7. 涨停买不进 ==")
game.reset(data.days[0])
df = game._day_df()
# 找当日盘中封涨停的股票(close 触及涨停价)
lu_mask = df["close"] >= df["limit_up"] - 0.005
lu_stocks = df[lu_mask & df["limit_up"].notna()]
if len(lu_stocks):
    row = lu_stocks.iloc[-1]
    code6 = row["code"].split(".")[0]
    game.t = int(row["time_idx"])
    if game.t >= len(game.time_list) - 1:
        game.t -= 1  # 避免收盘时刻
    try:
        game.place_order(code6, "BUY", "MARKET", None, 100)
        check("涨停买不进", False)
    except Exception as e:
        check("涨停买不进", "涨停" in str(e), str(e))
else:
    print("   (当日无封板涨停股, 跳过涨停测试)")

print("== 8. 跌停卖不出 ==")
game.reset(data.days[0])
df = game._day_df()
dn_mask = df["close"] <= df["limit_dn"] + 0.005
dn_stocks = df[dn_mask & df["limit_dn"].notna()]
if len(dn_stocks):
    row = dn_stocks.iloc[-1]
    code6 = row["code"].split(".")[0]
    fcode = row["code"]
    # 先回到开盘(非跌停)买入建仓
    game.t = 0
    b0 = game.latest_bar(fcode)
    if b0 is not None and float(b0["close"]) <= float(b0["limit_dn"]) + 0.005:
        print("   (开盘即跌停, 无法建仓, 跳过跌停测试)")
    else:
        try:
            game.place_order(code6, "BUY", "MARKET", None, 100)
            # 跳到跌停时刻尝试卖出
            game.t = int(row["time_idx"])
            if game.t >= len(game.time_list) - 1:
                game.t -= 1
            try:
                game.place_order(code6, "SELL", "MARKET", None, 100)
                check("跌停卖不出", False)
            except Exception as e:
                check("跌停卖不出", "跌停" in str(e), str(e))
        except Exception as e:
            print("   (建仓失败, 跳过跌停测试)", str(e))
else:
    print("   (当日无跌停股, 跳过跌停测试)")

print("== 9. 限价挂单与撮合 ==")
game.reset(data.days[0])
stk = game.overview()["gainers"][0]
code6, price = stk["code"], stk["price"]
low_price = round(price * 0.99, 2)  # 低于市价1%
r = game.place_order(code6, "BUY", "LIMIT", low_price, 100)
check("低挂买单被挂起", r["status"] == "PENDING", str(r))
# 推进时间看是否触发(可能需要多推几次, 也可能不触发)
triggered = False
for _ in range(16):
    game.advance("15m")
    st = game.state()
    if any(o["status"] == "FILLED" for o in game.orders):
        triggered = True
        break
print(f"   低挂 {low_price} vs 现价 {price}: 15分钟内触发成交: {triggered}")
check("挂单存在", len(game.orders) >= 1)

print("== 10. 挂单收盘作废 ==")
game.reset(data.days[0])
stk = game.overview()["gainers"][0]
# 挂一个低于市价但高于跌停价(有效区间内)的买单
dn = game.stock_detail(stk["code"])["limit_dn_price"]
low_price = round((stk["price"] + dn) / 2, 2)
game.place_order(stk["code"], "BUY", "LIMIT", low_price, 100)
game.t = len(game.time_list) - 1
game.advance("1d")
pend = [o for o in game.orders if o["status"] == "PENDING"]
check("跨日后挂单自动作废", len(pend) == 0)
cancelled = [o for o in game.orders if o["status"] == "CANCELLED"]
check("状态为CANCELLED", len(cancelled) == 1)

print("== 11. 日K ==")
game.reset(data.days[30])  # 跳到第31个交易日, 前面有足够历史
kl = game.kline("600000", 20)
check("日K返回20根", len(kl) == 20, str(len(kl)))
check("日K有OHLC", kl[-1]["close"] > 0 and kl[-1]["high"] >= kl[-1]["low"])

print("== 12. 个股详情 ==")
d = game.stock_detail("600000")
check("详情有分时", len(d["chart"]["times"]) == 1 and d["chart"]["prices"][0] > 0)
check("详情有盘口", len(d["order_book"]["bids"]) == 5)
check("名称存在", len(d["name"]) > 0, d["name"])
print("   600000:", d["name"], d["price"], d["pct"], "%")

print("== 13. 指数序列 ==")
game.t = 30
idx = game.index_series()
check("指数序列返回全天241个(展示时截取)", len(idx) == 241, str(len(idx)))
check("指数>0", idx[-1] > 0)

print("== 14. 2022年数据与动态涨跌停 ==")
game.reset("20220104")
s = game.state()
check("2022起始日", s["day"] == "20220104", s["day"])
check("2022现金100万", abs(s["cash"] - 1_000_000) < 0.01)
# 动态涨跌停
d = data
check("科创688=20%", abs(d.limit_pct("688981.SH", "20220104") - 0.20) < 1e-9)
check("创业300=20%", abs(d.limit_pct("300750.SZ", "20220104") - 0.20) < 1e-9)
check("主板600=10%", abs(d.limit_pct("600000.SH", "20220104") - 0.10) < 1e-9)
check("2010创业=10%", abs(d.limit_pct("300001.SZ", "20100104") - 0.10) < 1e-9)
# 年份首日昨收=开盘价(不误取2010)
sf = game._sf("300750.SZ")
first_bar = sf[sf["time_idx"] == 0].iloc[0]
check("2022首日有昨收基准(开盘价)", not math.isnan(float(first_bar["prev_close"])),
      str(first_bar["prev_close"]))
# 市场概览可用
ov = game.overview()
check("2022市场概览指数", ov["index"]["cur"] is not None)
check("2022股票数>4000", ov["market"]["stock_count"] > 4000,
      str(ov["market"]["stock_count"]))
# 创业板20%规则: 全天数据中存在涨幅>10%的股票(2022-01-04 有20%涨停的创业板股)
df_all = game._day_df()
max_pct_all = float(df_all["pct"].max())
check("2022创业板涨幅>10%(20%规则生效)", max_pct_all > 10, f"全天最大涨幅 {max_pct_all}%")

print()
print(f"结果: {passed} 通过, {failed} 失败")
sys.exit(1 if failed else 0)

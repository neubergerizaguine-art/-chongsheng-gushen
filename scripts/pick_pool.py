#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Step 1/3: 筛选游戏数据池 — 流动性前 500 只股票
口径: 2022 全年 + 2026 年(1-4月) parquet 的日均成交额(amount)排名, 取前 500
输出: game_data/pool.json
"""
import json
import os

import pandas as pd

BASE = "/Users/malihao/Downloads/A股分钟数据/日频数据+分钟数据--按年归档"
POOL_SIZE = 500
OUT = "/Users/malihao/WorkBuddy/股市仿真游戏/game_data/pool.json"


def main():
    years = ["2022", "2026"]
    daily_amount: dict = {}   # code -> 累计成交额
    day_count: dict = {}      # code -> 有交易的天数
    for y in years:
        d = os.path.join(BASE, y)
        files = sorted(f for f in os.listdir(d) if f.endswith(".parquet"))
        for i, f in enumerate(files):
            df = pd.read_parquet(os.path.join(d, f), columns=["code", "amount", "vol"])
            g = df.groupby("code").agg(amount=("amount", "sum"), vol=("vol", "sum"))
            for code, row in g.iterrows():
                daily_amount[code] = daily_amount.get(code, 0.0) + float(row["amount"])
                daily_amount["_vol_" + code] = daily_amount.get("_vol_" + code, 0.0) + float(row["vol"])
                day_count[code] = day_count.get(code, 0) + 1
            if (i + 1) % 50 == 0:
                print(f"  {y} 进度 {i+1}/{len(files)}")
    # 日均成交额
    ranked = []
    for code in daily_amount:
        if code.startswith("_"):
            continue
        days = day_count.get(code, 1)
        amt = daily_amount[code] / days
        vol = daily_amount.get("_vol_" + code, 0.0) / days
        ranked.append({"code": code, "avg_amount": amt, "avg_vol": vol, "days": days})
    ranked.sort(key=lambda r: r["avg_amount"], reverse=True)
    pool = ranked[:POOL_SIZE]
    print(f"候选总数: {len(ranked)}, 取前 {POOL_SIZE}")
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    json.dump({"pool": pool, "count": len(pool),
               "note": "日均成交额排名(2022+2026)", "generated": "2026-08-23"},
              open(OUT, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print("已输出", OUT)
    print("前 20 名:", [p["code"] for p in pool[:20]])


if __name__ == "__main__":
    main()

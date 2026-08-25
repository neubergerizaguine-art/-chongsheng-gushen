#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Step 2/3: 转换 2023-2025 年数据 — 从 1分钟_沪深_按年汇总 zip 提取数据池股票
- 输入: game_data/pool.json (500只) + {2023,2024,2025}_1min.zip
- 输出: /.../日频数据+分钟数据--按年归档/{year}/{day}.parquet (与 2022/2026 同结构)
- 说明: txt 无成交额, amount = vol × close 估算; pre_close/change/pct_chg 为占位列
"""
import io
import json
import os
import time
import zipfile

import pandas as pd

ZIP_DIR = "/Users/malihao/Downloads/A股分钟数据/分钟数据+复盘大师/1分钟_沪深_按年汇总"
OUT_BASE = "/Users/malihao/Downloads/A股分钟数据/日频数据+分钟数据--按年归档"
POOL = "/Users/malihao/WorkBuddy/股市仿真游戏/game_data/pool.json"
YEARS = ["2023", "2024", "2025"]


def code_prefix(c6: str) -> str:
    return "sh" if c6.startswith(("6", "9", "5")) else "sz"


def parse_txt(raw: bytes, code: str, year: str) -> pd.DataFrame:
    """解析 <TICKER>,<DTYYYYMMDD>,<TIME>,<OPEN>,<HIGH>,<LOW>,<CLOSE>,<VOL>"""
    text = raw.decode("utf-8", "ignore")
    rows = []
    for line in text.splitlines()[1:]:          # 跳过表头
        line = line.strip()
        if not line:
            continue
        p = line.split(",")
        if len(p) < 8:
            continue
        try:
            d, t = p[1], p[2]
            o, h, l, c = float(p[3]), float(p[4]), float(p[5]), float(p[6])
            v = float(p[7])
        except ValueError:
            continue
        rows.append((d, t, o, h, l, c, v))
    if not rows:
        return pd.DataFrame()
    df = pd.DataFrame(rows, columns=["date", "time", "open", "high", "low", "close", "vol"])
    df["trade_time"] = pd.to_datetime(
        df["date"] + " " + df["time"].str[:2] + ":" + df["time"].str[2:4] + ":00",
        format="%Y%m%d %H:%M:%S")
    df["code"] = code + ".SH" if code.startswith(("6", "9", "5")) else code + ".SZ"
    df["amount"] = df["vol"] * df["close"]       # 估算成交额
    df["pre_close"] = df["close"].shift(1)
    df["change"] = df["close"] - df["pre_close"]
    df["pct_chg"] = df["change"] / df["pre_close"] * 100
    cols = ["code", "trade_time", "close", "open", "high", "low",
            "vol", "amount", "date", "pre_close", "change", "pct_chg"]
    return df[cols]


def main():
    pool = json.load(open(POOL, encoding="utf-8"))["pool"]
    codes = [p["code"].split(".")[0] for p in pool]   # 去掉 .SH/.SZ 后缀
    print(f"数据池 {len(codes)} 只")
    for year in YEARS:
        zpath = os.path.join(ZIP_DIR, f"{year}_1min.zip")
        if not os.path.exists(zpath):
            print(f"  跳过 {year}: 无 zip"); continue
        t0 = time.time()
        per_day: dict = {}
        with zipfile.ZipFile(zpath) as z:
            names = set(z.namelist())
            for i, c6 in enumerate(codes):
                entry = f"{code_prefix(c6)}{c6}_{year}.txt"
                if entry not in names:
                    continue                      # 该年无此股(未上市/退市)
                raw = z.read(entry)
                df = parse_txt(raw, c6, year)
                if df.empty:
                    continue
                for day, sub in df.groupby("date"):
                    per_day.setdefault(day, []).append(sub)
                if (i + 1) % 100 == 0:
                    print(f"  {year} 提取 {i+1}/{len(codes)} ({time.time()-t0:.0f}s)")
        # 输出按日 parquet
        out_dir = os.path.join(OUT_BASE, year)
        os.makedirs(out_dir, exist_ok=True)
        for day, parts in per_day.items():
            df = pd.concat(parts, ignore_index=True)
            df = df.sort_values(["code", "trade_time"]).reset_index(drop=True)
            df.to_parquet(os.path.join(out_dir, day + ".parquet"), index=False)
        print(f"  {year} 完成: {len(per_day)} 个交易日, 耗时 {time.time()-t0:.0f}s")


if __name__ == "__main__":
    main()

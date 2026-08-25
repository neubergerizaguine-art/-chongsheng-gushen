#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Step 3/3: 生成游戏数据包 — 按月块洗牌 + Godot 二进制分片
- 输入: 日频数据+分钟数据--按年归档/{2022,2023,2024,2025,2026}/*.parquet + pool.json
- 输出: game_data/game/
    meta.json       股票元数据 + 洗牌后的交易日序列(含月份块信息)
    day_bins/{i:04d}.bin  按洗牌后顺序, 每天一个二进制文件(Godot FileAccess 直读)
- bin 格式(little-endian):
    u32 magic 'ASTK' | u32 version | u32 stock_count | u32 minute_count | u16 day_index
    float32 prev_close × stock_count
    float32[open,high,low,close,vol] × stock_count × minute_count
"""
import json
import os
import random
import struct

import numpy as np
import pandas as pd

BASE = "/Users/malihao/Downloads/A股分钟数据/日频数据+分钟数据--按年归档"
POOL = "/Users/malihao/WorkBuddy/股市仿真游戏/game_data/pool.json"
OUT = "/Users/malihao/WorkBuddy/股市仿真游戏/game_data/game"
YEARS = ["2022", "2023", "2024", "2025", "2026"]
SEED = 20260823          # 洗牌随机种子(可复现; 换种子=全新局)
MAGIC = 0x4153544B       # 'ASTK'


def collect_days():
    """按 年月 分块收集交易日"""
    blocks = {}
    for y in YEARS:
        d = os.path.join(BASE, y)
        if not os.path.isdir(d):
            print(f"  跳过 {y}: 无目录"); continue
        files = sorted(f[:8] for f in os.listdir(d) if f.endswith(".parquet"))
        if not files:
            print(f"  跳过 {y}: 无文件"); continue
        for day in files:
            ym = day[:6]
            blocks.setdefault(ym, []).append(day)
    # 块内按日排序
    for k in blocks:
        blocks[k].sort()
    print(f"月份块数: {len(blocks)}")
    return blocks


def shuffled_days(blocks, seed):
    """按月块随机重排(块内顺序不变), 返回 [(game_idx, real_day, block)]"""
    rng = random.Random(seed)
    keys = sorted(blocks.keys())
    rng.shuffle(keys)
    seq = []
    for b in keys:
        for day in blocks[b]:
            seq.append((len(seq), day, b))
    return seq


def load_day(day, pool_codes):
    """读取某日数据, 只取数据池股票, 按 pool 顺序返回矩阵"""
    y = day[:4]
    df = pd.read_parquet(os.path.join(BASE, y, day + ".parquet"))
    df = df[df["code"].isin(pool_codes)]
    if df.empty:
        return None
    df = df.sort_values(["code", "trade_time"])
    # 每只股票按时间排序后的分钟数
    minutes = sorted(df["trade_time"].unique())
    mcount = len(minutes)
    n = len(pool_codes)
    o = np.full((n, mcount), np.nan, np.float32)
    h = np.full((n, mcount), np.nan, np.float32)
    l = np.full((n, mcount), np.nan, np.float32)
    c = np.full((n, mcount), np.nan, np.float32)
    v = np.full((n, mcount), 0.0, np.float32)
    prev = np.full(n, np.nan, np.float32)
    tmap = {t: i for i, t in enumerate(minutes)}
    for code, g in df.groupby("code", sort=False):
        gi = pool_codes.index(code)
        idx = g["trade_time"].map(tmap).values
        o[gi, idx] = g["open"].values.astype(np.float32)
        h[gi, idx] = g["high"].values.astype(np.float32)
        l[gi, idx] = g["low"].values.astype(np.float32)
        c[gi, idx] = g["close"].values.astype(np.float32)
        v[gi, idx] = g["vol"].values.astype(np.float32)
        # 昨收: 当日首根bar的 open 近似(实际昨收由引擎从前一日15:00取)
        prev[gi] = g["open"].values[0] if len(g) else np.nan
    return minutes, o, h, l, c, v, prev


def write_bin(path, day_index, mcount, prev, o, h, l, c, v):
    n = len(prev)
    with open(path, "wb") as f:
        f.write(struct.pack("<IIIIH", MAGIC, 1, n, mcount, day_index))
        f.write(prev.astype(np.float32).tobytes())
        for i in range(n):
            block = np.stack([o[i], h[i], l[i], c[i], v[i]], axis=1)
            f.write(block.astype(np.float32).tobytes())


def main():
    pool = json.load(open(POOL, encoding="utf-8"))["pool"]
    pool_codes = [p["code"] for p in pool]
    print(f"数据池 {len(pool_codes)} 只, 洗牌种子 {SEED}")
    blocks = collect_days()
    seq = shuffled_days(blocks, SEED)
    print(f"洗牌后共 {len(seq)} 个交易日")
    os.makedirs(os.path.join(OUT, "day_bins"), exist_ok=True)

    # 记录每只股票在每个洗牌日的昨收连续性: 简单处理——跨月块边界也用上一日收盘
    day_meta = []
    prev_close_map = {}
    mcount = None
    for game_idx, day, block in seq:
        res = load_day(day, pool_codes)
        if res is None:
            continue
        minutes, o, h, l, c, v, prev = res
        if mcount is None:
            mcount = len(minutes)
        # 用上一交易日的收盘价作为昨收(连续性跨块保持)
        for i, code in enumerate(pool_codes):
            if code in prev_close_map and not np.isnan(prev_close_map[code]):
                prev[i] = prev_close_map[code]
            last_close = c[i, ~np.isnan(c[i])]
            if len(last_close):
                prev_close_map[code] = float(last_close[-1])
        write_bin(os.path.join(OUT, "day_bins", f"{game_idx:04d}.bin"),
                  game_idx, len(minutes), prev, o, h, l, c, v)
        day_meta.append({"idx": game_idx, "real_day": day, "block": block})
        if game_idx % 100 == 0:
            print(f"  {game_idx}/{len(seq)}")

    meta = {
        "game": "炒股之王",
        "seed": SEED,
        "minute_count": mcount,
        "pool": [_name_entry(p) for p in pool],
        "names": {},
        "days": day_meta,
    }
    json.dump(meta, open(os.path.join(OUT, "meta.json"), "w", encoding="utf-8"),
              ensure_ascii=False, indent=1)
    print("完成:", OUT, "| 交易日:", len(day_meta))


def _name_entry(p: dict) -> dict:
    """生成 {code, name}: 优先查名称映射缓存(names.json), 兜底用代码"""
    code = p["code"]
    base = code.split(".")[0]
    name = base
    try:
        cache_path = os.path.join(os.path.dirname(__file__), "..", ".cache", "names.json")
        if os.path.exists(cache_path):
            with open(cache_path, encoding="utf-8") as f:
                names = json.load(f)
            nm = names.get(base, "")
            if nm:
                name = nm
                for prefix in ("XD", "XR", "DR"):
                    if name.startswith(prefix) and len(name) > 2:
                        name = name[len(prefix):]
                        break
    except Exception as e:
        print("名称映射失败(将用代码兜底):", e)
    return {"code": code, "name": name}


if __name__ == "__main__":
    main()

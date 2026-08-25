#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
A股历史盘复刻 · 模拟交易游戏 —— 后端服务

数据源: /Users/malihao/Downloads/A股分钟数据/日频数据+分钟数据--按年归档
  - 每个交易日一个 parquet, 含全市场股票的 1 分钟 OHLCV + 成交额
  - 时间轴以数据为准(2010年: 09:30-11:30 + 13:01-15:00, 共241个点)

引擎规则(严格按A股市场规则):
  - T+1: 当日买入不可当日卖出
  - 涨跌停: 涨停买不进, 跌停卖不出 (普通股±10%; 新股首日无涨跌停, 按昨收缺失自动识别)
  - 挂单撮合: 限价买单价<市价挂起等回调, 卖单价>市价挂起等拉升; 触及即按挂单价成交
  - 手续费: 佣金万2.5(最低5元,双向) + 印花税千1(卖出) + 过户费万0.1
  - 挂单仅当日有效, 收盘自动作废
"""
import json
import math
import os
import urllib.request
from typing import Dict, List, Optional

import numpy as np
import pandas as pd
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

# ============================== 配置 ==============================
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
DATA_DIR = "/Users/malihao/Downloads/A股分钟数据/日频数据+分钟数据--按年归档"
CACHE_DIR = os.path.join(BASE_DIR, ".cache")
NAMES_FILE = os.path.join(CACHE_DIR, "names.json")
STATIC_DIR = os.path.join(BASE_DIR, "static")

# 游戏启用的数据年份(只加载这些年份目录, 减少扫描与加载压力)
DATA_YEARS = ["2022"]

INIT_CASH = 1_000_000.0      # 初始资金 100 万
COMMISSION_RATE = 0.00025    # 佣金 万2.5
COMMISSION_MIN = 5.0         # 佣金最低 5 元
STAMP_TAX_RATE = 0.001       # 印花税(仅卖出) 千1
TRANSFER_FEE_RATE = 0.00001  # 过户费 万0.1
LOT = 100                    # 一手 100 股
LIMIT_PCT = 0.10             # 普通股涨跌停 10%
ST_LIMIT_PCT = 0.05          # ST 5% (预留)
PRICE_TICK = 0.01            # 最小价格变动

app = FastAPI(title="A股历史盘复刻 · 模拟交易")
app.add_middleware(
    CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"]
)


# ============================== 数据服务 ==============================
class DataService:
    """按交易日加载 parquet, 提供昨收/涨跌停价/名称等基础数据"""

    def __init__(self, data_dir: str):
        self.data_dir = data_dir
        # parquet 按年份子目录归档: <data_dir>/2022/20220104.parquet
        # 只扫描 DATA_YEARS 配置的年份, 跳过其余(2010等)以加快启动
        self._paths: Dict[str, str] = {}
        self.first_days: set = set()   # 每个年份子目录的第一个交易日(无昨收, 需用开盘价补基准)
        for entry in sorted(os.listdir(data_dir)):
            p = os.path.join(data_dir, entry)
            if os.path.isdir(p) and entry in DATA_YEARS:
                files = sorted(f for f in os.listdir(p) if f.endswith(".parquet"))
                if files:
                    self.first_days.add(files[0][:8])
                for f in files:
                    self._paths[f[:8]] = os.path.join(p, f)
            elif entry.endswith(".parquet") and entry[:4] in DATA_YEARS:
                self._paths[entry[:8]] = p
        self.days: List[str] = sorted(self._paths.keys())
        self._day_cache: Dict[str, pd.DataFrame] = {}
        self._prev_close_cache: Dict[str, Dict[str, float]] = {}
        self.names: Dict[str, str] = {}

    def same_year(self, day1: str, day2: str) -> bool:
        """两个交易日是否来自同一数据年份目录(避免跨年误取昨收)"""
        return os.path.dirname(self._paths.get(day1, "")) == \
            os.path.dirname(self._paths.get(day2, ""))

    # ---------- 名称映射 ----------
    def load_names(self) -> bool:
        """优先用本地缓存, 否则拉取全市场代码->名称映射(东方财富, 新浪兜底)"""
        if os.path.exists(NAMES_FILE):
            try:
                cached = json.load(open(NAMES_FILE, encoding="utf-8"))
                if isinstance(cached, dict) and len(cached) > 1000:
                    self.names = cached
                    self._backfill_names()
                    return True
            except Exception:
                pass
        names: Dict[str, str] = {}
        try:
            names.update(self._fetch_eastmoney())
        except Exception:
            pass
        if len(names) < 1000:
            try:
                names.update(self._fetch_sina())
            except Exception:
                pass
        if len(names) > 1000:
            os.makedirs(CACHE_DIR, exist_ok=True)
            tmp = NAMES_FILE + ".tmp"
            json.dump(names, open(tmp, "w", encoding="utf-8"), ensure_ascii=False)
            os.replace(tmp, NAMES_FILE)
            self.names = names
            self._backfill_names()
            return True
        return False

    def _backfill_names(self):
        """用腾讯行情接口补齐启用年份(DATA_YEARS)中已退市、当前列表缺失的名称"""
        codes: set = set()
        for sub in DATA_YEARS:
            d = os.path.join(self.data_dir, sub)
            if os.path.isdir(d):
                files = sorted(f for f in os.listdir(d) if f.endswith(".parquet"))
                if files:
                    try:
                        df = pd.read_parquet(os.path.join(d, files[0]), columns=["code"])
                        codes.update(df["code"].str.split(".").str[0])
                    except Exception:
                        pass
        missing = sorted(c for c in codes if c not in self.names)
        if not missing:
            return
        extra = self._fetch_tencent(missing)
        if extra:
            self.names.update(extra)
            try:
                tmp = NAMES_FILE + ".tmp"
                json.dump(self.names, open(tmp, "w", encoding="utf-8"),
                          ensure_ascii=False)
                os.replace(tmp, NAMES_FILE)
            except Exception:
                pass

    def _fetch_tencent(self, codes: List[str]) -> Dict[str, str]:
        """腾讯批量行情接口(含退市股名称), 一次最多60只, GBK编码"""
        out: Dict[str, str] = {}
        for i in range(0, len(codes), 60):
            batch = codes[i:i + 60]
            qs = ",".join(("sh" if c.startswith(("6", "9", "5")) else "sz") + c
                          for c in batch)
            raw = (self._curl("https://qt.gtimg.cn/q=" + qs, 15) or b"")
            text = raw.decode("gbk", "ignore")
            for line in text.split(";"):
                line = line.strip()
                if not line.startswith("v_"):
                    continue
                try:
                    payload = line.split("=", 1)[1].strip('"')
                    fields = payload.split("~")
                    if len(fields) > 3:
                        out[fields[2]] = fields[1]
                except Exception:
                    continue
        return out

    @staticmethod
    def _curl(url: str, timeout: int = 25) -> bytes:
        import subprocess
        out = subprocess.run(["curl", "-s", "--max-time", str(timeout), url],
                             capture_output=True, timeout=timeout + 5)
        return out.stdout or b""

    def _fetch_eastmoney(self) -> Dict[str, str]:
        url = ("https://push2.eastmoney.com/api/qt/clist/get?pn=1&pz=6000&po=1&np=1"
               "&fltt=2&invt=2&fid=f12&fs=m:0+t:6,m:0+t:80,m:1+t:2,m:1+t:23&fields=f12,f14")
        data = json.loads(self._curl(url) or b"{}")
        diff = data.get("data", {}).get("diff") or []
        return {str(d["f12"]): str(d["f14"]) for d in diff if d.get("f12")}

    def _fetch_sina(self) -> Dict[str, str]:
        """新浪全市场列表分页拉取(每页100, 兜底方案); 单页失败自动重试"""
        names: Dict[str, str] = {}
        for page in range(1, 81):
            arr = []
            for attempt in range(3):
                url = ("http://vip.stock.finance.sina.com.cn/quotes_service/api/json_v2.php/"
                       "Market_Center.getHQNodeData?page=%d&num=100&sort=symbol&asc=1"
                       "&node=hs_a&symbol=&_s_r_a=page" % page)
                try:
                    raw = (self._curl(url, 12) or b"").decode("utf-8", "ignore").strip()
                    if raw:
                        arr = json.loads(raw)
                        if isinstance(arr, list):
                            break
                except Exception:
                    arr = []
                time.sleep(0.4)
            if not arr:
                break
            for d in arr:
                names[str(d.get("code"))] = str(d.get("name"))
            if len(arr) < 100:
                break
        return names

    def name_of(self, code: str) -> str:
        return self.names.get(code.split(".")[0], "")

    def disp_name(self, code: str) -> str:
        """显示名: 有名称用名称, 否则用6位代码"""
        return self.names.get(code.split(".")[0], "") or code.split(".")[0]

    def is_st(self, code: str) -> bool:
        return "ST" in self.name_of(code).upper()

    def limit_pct(self, code: str, day: str) -> float:
        """按板块与日期动态计算涨跌幅限制(A股规则):
        科创板 20% | 创业板 2020-08-24 起 20% | 北交所 2021-11-15 起 30% | ST 5% | 主板 10%
        注: ST 状态用当前名称近似判断(历史 ST 状态无数据)"""
        c6 = code.split(".")[0]
        if c6.startswith(("688", "689")):
            return 0.20
        if c6.startswith(("300", "301")):
            return 0.20 if day >= "20200824" else 0.10
        if c6.startswith(("8", "4", "92")):
            return 0.30 if day >= "20211115" else 0.10
        if self.is_st(code):
            return 0.05
        return 0.10

    # ---------- 数据加载 ----------
    def _load_raw(self, day: str) -> pd.DataFrame:
        if day not in self._day_cache:
            path = self._paths.get(day)
            if not path or not os.path.exists(path):
                raise HTTPException(404, f"交易日数据不存在: {day}")
            self._day_cache[day] = pd.read_parquet(path)
        return self._day_cache[day]

    def prev_close_map(self, day: str) -> Dict[str, float]:
        """前一交易日 15:00 收盘价作为昨收; 新股(前一日不存在)不在字典中"""
        if day in self._prev_close_cache:
            return self._prev_close_cache[day]
        prev: Dict[str, float] = {}
        idx = self.days.index(day) if day in self.days else -1
        if idx > 0:
            prev_day = self.days[idx - 1]
            # 仅取同一数据年份目录内的前一交易日(避免 2022-01-04 误取 2010-12-31 收盘)
            if self.same_year(day, prev_day):
                raw = self._load_raw(prev_day)
                last_time = sorted(raw["trade_time"].unique())[-1]
                sub = raw[raw["trade_time"] == last_time][["code", "close"]]
                prev = dict(zip(sub["code"].tolist(), sub["close"].tolist()))
        self._prev_close_cache[day] = prev
        return prev

    def load_day(self, day: str, fill_open: bool = False) -> pd.DataFrame:
        """返回修复后的当日全市场分钟数据, 附加 prev_close/limit_up/limit_dn/pct 列

        fill_open=True 时(游戏起始日): 用当日 09:30 开盘价作昨收基准,
        否则 prev_close 缺失(新股首日)保持 NaN -> 无涨跌停限制
        """
        raw = self._load_raw(day)
        prev = self.prev_close_map(day)
        df = raw.copy()
        df["prev_close"] = df["code"].map(prev)
        if fill_open:
            first = df[df["trade_time"] == sorted(df["trade_time"].unique())[0]]
            open_map = dict(zip(first["code"].tolist(), first["open"].tolist()))
            df["prev_close"] = df["prev_close"].fillna(df["code"].map(open_map))
        # 涨跌停价(按板块动态比例, 四舍五入到分); 新股首日 prev_close 为 NaN -> 无涨跌停
        # 用去重代码一次性计算, 避免 110 万行逐行 Python 调用
        uniq_codes = df["code"].unique()
        pct_map = {c: self.limit_pct(c, day) for c in uniq_codes}
        pcts = df["code"].map(pct_map)
        df["limit_up"] = (df["prev_close"] * (1 + pcts)).round(2)
        df["limit_dn"] = (df["prev_close"] * (1 - pcts)).round(2)
        df["pct"] = (df["close"] - df["prev_close"]) / df["prev_close"] * 100
        # 分钟序号(当日第几根bar), 对齐时间轴
        times = sorted(raw["trade_time"].unique())
        tmap = {t: i for i, t in enumerate(times)}
        df["time_idx"] = df["trade_time"].map(tmap)
        # 按 code+time_idx 排序, 便于按股截取
        df = df.sort_values(["code", "time_idx"]).reset_index(drop=True)
        return df

    def stock_frame(self, day: str, code: str, fill_open: bool = False) -> pd.DataFrame:
        """当日某股票的全天分钟数据(已修复, 含涨跌停价)"""
        df = self.load_day(day, fill_open=fill_open)
        return df[df["code"] == code].reset_index(drop=True)


# ============================== 游戏引擎 ==============================
class Game:
    def __init__(self, data: DataService):
        self.data = data
        self.day: str = data.days[0]
        self.day_idx: int = 0
        self.t: int = 0                    # 当前分钟索引(0..N-1)
        self.time_list: List[str] = []     # 当日时间点
        self.cash: float = INIT_CASH
        self.positions: Dict[str, dict] = {}  # code -> {shares, avail, cost, avg, today_buy}
        self.orders: List[dict] = []           # 委托(含挂单/历史)
        self.trades: List[dict] = []           # 成交记录
        self.base_asset: float = INIT_CASH     # 当日开盘总资产(算当日盈亏)
        self.index_base: Optional[float] = None  # 合成指数基准(起始日09:30全市场均价)
        self._index_series_cache: Dict[str, list] = {}
        self._overview_cache = None
        self._overview_at = None
        self._stock_detail_cache: Dict[str, tuple] = {}
        self._order_seq = 1
        self._trade_seq = 1
        self._codes_day: Optional[str] = None
        self._codes: List[str] = []

    # ---------- 初始化 ----------
    @staticmethod
    def default_day(data) -> str:
        """默认起始日: DATA_YEARS 中的第一个交易日(当前=2022年首日)"""
        for y in DATA_YEARS:
            for d in data.days:
                if d.startswith(y):
                    return d
        return data.days[0]

    def reset(self, day: Optional[str] = None):
        if day and day in self.data.days:
            self.day = day
        else:
            self.day = Game.default_day(self.data)
        self.day_idx = self.data.days.index(self.day)
        self.t = 0
        self.cash = INIT_CASH
        self.positions = {}
        self.orders = []
        self.trades = []
        self._order_seq = 1
        self._trade_seq = 1
        df = self._day_df()
        self.time_list = sorted(df["trade_time"].unique())
        self.time_list = [t.split(" ")[1] for t in self.time_list]
        # 合成指数基准: 起始日 09:30 全市场等权均价 -> 1000 点
        first = df[df["time_idx"] == 0]
        self.index_base = float(first["close"].mean())
        self._first_rows = first  # 复用: 当日 09:30 全部股票
        self._index_series_cache = {}
        self._overview_cache = None
        self._stock_detail_cache = {}
        self._codes_day = None
        self._calc_base_asset(df, first)
        return self.state()

    def _calc_base_asset(self, df: Optional[pd.DataFrame] = None,
                         first: Optional[pd.DataFrame] = None):
        """当日开盘总资产: 现金 + 持仓按 09:30 开盘价估值"""
        if first is None:
            if df is None:
                df = self._day_df()
            first = df[df["time_idx"] == 0]
        mv = 0.0
        open_prices = dict(zip(first["code"].tolist(), first["open"].tolist()))
        for code, pos in self.positions.items():
            p = open_prices.get(code, pos.get("avg", 0) or 0)
            mv += pos["shares"] * p
        self.base_asset = self.cash + mv

    # ---------- 时间推进 ----------
    @property
    def time_str(self) -> str:
        return self.time_list[self.t] if self.time_list else "--:--:--"

    @property
    def is_closed(self) -> bool:
        """收盘(最后时间点)后禁止交易"""
        return self.t >= len(self.time_list) - 1

    @property
    def game_over(self) -> bool:
        return self.day_idx >= len(self.data.days) - 1 and self.is_closed

    def advance(self, step: str) -> dict:
        """step: 15m | 1h | 1d"""
        if step == "15m":
            self.t = min(self.t + 15, len(self.time_list) - 1)
        elif step == "1h":
            self.t = min(self.t + 60, len(self.time_list) - 1)
        elif step == "1d":
            if self.game_over:
                return self.state()
            if self.day_idx < len(self.data.days) - 1:
                self.day_idx += 1
                self.day = self.data.days[self.day_idx]
                self.t = 0
                self._roll_day()
        else:
            raise HTTPException(400, "step 必须是 15m/1h/1d")
        self._match_all_orders()
        self._overview_cache = None
        self._stock_detail_cache.clear()
        return self.state()

    def _roll_day(self):
        """进入新交易日: 加载新日数据, 重置当日买入, 作废未成交挂单, 重算基准"""
        df = self._day_df()
        self.time_list = sorted(df["trade_time"].unique())
        self.time_list = [t.split(" ")[1] for t in self.time_list]
        for code, pos in self.positions.items():
            pos["today_buy"] = 0
            # 持仓成本随除权? 简化: 不做除权调整
        # 收盘作废未成交限价单
        for o in self.orders:
            if o["status"] == "PENDING":
                o["status"] = "CANCELLED"
                o["reason"] = "当日收盘未成交, 自动作废"
        self._index_series_cache = {}
        self._codes_day = None
        first = df[df["time_idx"] == 0]
        self._first_rows = first
        self._calc_base_asset(df, first)

    # ---------- 行情取值 ----------
    def _day_df(self) -> pd.DataFrame:
        """游戏当前日数据; 年份首日(无昨收)自动用开盘价填充基准"""
        return self.data.load_day(self.day, fill_open=(self.day in self.data.first_days))

    def _sf(self, code: str) -> pd.DataFrame:
        """游戏当前日某股数据"""
        return self.data.stock_frame(self.day, code,
                                     fill_open=(self.day in self.data.first_days))

    def latest_bar(self, code: str) -> Optional[pd.Series]:
        """该股截至当前时刻的最新bar"""
        sf = self._sf(code)
        sub = sf[sf["time_idx"] <= self.t]
        return sub.iloc[-1] if len(sub) else None

    def latest_close(self, code: str) -> Optional[float]:
        b = self.latest_bar(code)
        return float(b["close"]) if b is not None else None

    def price_state(self, code: str) -> dict:
        """涨跌停状态"""
        b = self.latest_bar(code)
        if b is None:
            return {"limit_up": False, "limit_dn": False, "limit_up_price": None,
                    "limit_dn_price": None}
        lu, ld = float(b["limit_up"]), float(b["limit_dn"])
        close = float(b["close"])
        eps = 0.005
        return {
            "limit_up": bool(not math.isnan(lu) and close >= lu - eps),
            "limit_dn": bool(not math.isnan(ld) and close <= ld + eps),
            "limit_up_price": None if math.isnan(lu) else lu,
            "limit_dn_price": None if math.isnan(ld) else ld,
        }

    # ---------- 合成指数 ----------
    def index_series(self) -> list:
        """当日合成指数(全市场等权平均, 基准=起始日09:30均价=1000点)"""
        if self.day in self._index_series_cache:
            return self._index_series_cache[self.day]
        df = self._day_df()
        base = self.index_base or 1.0
        g = df.groupby("time_idx")["close"].mean().sort_index()
        series = [(float(g.get(i, float("nan")) if i in g.index else float("nan")) / base * 1000)
                  for i in range(len(self.time_list))]
        series = [v for v in series if not math.isnan(v)]
        self._index_series_cache[self.day] = series
        return series

    def index_prev_close(self) -> float:
        """昨收指数(前一交易日15:00); 数据年份首日/跨年无前日则=基准1000"""
        if self.day_idx == 0:
            return 1000.0
        prev_day = self.data.days[self.day_idx - 1]
        if not self.data.same_year(self.day, prev_day):
            return 1000.0
        prev_df = self.data.load_day(prev_day)
        last_idx = prev_df["time_idx"].max()
        last = prev_df[prev_df["time_idx"] == last_idx]["close"].mean()
        return float(last) / (self.index_base or 1.0) * 1000

    # ---------- 市场概览 ----------
    def overview(self, force: bool = False) -> dict:
        if self._overview_cache is not None and not force:
            return self._overview_cache
        df = self._day_df()
        sub = df[df["time_idx"] <= self.t]
        last = sub.groupby("code").last().reset_index()
        cur_idx = self.index_series()[self.t] if self.t < len(self.index_series()) else None
        prev_idx = self.index_prev_close()
        up_cnt = int((last["pct"] > 0.01).sum())
        dn_cnt = int((last["pct"] < -0.01).sum())
        flat_cnt = int(((last["pct"] >= -0.01) & (last["pct"] <= 0.01)).sum())
        eps = 0.005
        lu = last["limit_up"].notna() & (last["close"] >= last["limit_up"] - eps)
        ld = last["limit_dn"].notna() & (last["close"] <= last["limit_dn"] + eps)
        lu_cnt, ld_cnt = int(lu.sum()), int(ld.sum())
        amount_total = float(sub["amount"].sum())
        vol_total = float(sub["vol"].sum())
        # 涨幅榜 / 成交额榜(取最后一行时点)
        gainers = last.nlargest(10, "pct")[["code", "close", "pct", "prev_close"]]
        by_amount = sub.groupby("code")["amount"].sum().reset_index()
        actives = by_amount.merge(last[["code", "close", "pct"]], on="code")
        actives = actives.nlargest(10, "amount")

        def _row(r, with_amount=True):
            c = r["code"]
            out = {"code": c.split(".")[0], "name": self.data.disp_name(c),
                   "price": round(float(r["close"]), 2),
                   "pct": round(float(r["pct"]), 2)}
            if with_amount:
                out["amount"] = round(float(r["amount"]), 0)
            return out
        res = {
            "index": {
                "cur": round(cur_idx, 2) if cur_idx else None,
                "prev_close": round(prev_idx, 2),
                "pct": round((cur_idx / prev_idx - 1) * 100, 2) if cur_idx else None,
                "series": [round(v, 2) for v in self.index_series()[:self.t + 1]],
                "times": self.time_list[:self.t + 1],
            },
            "breadth": {"up": up_cnt, "down": dn_cnt, "flat": flat_cnt,
                        "limit_up": lu_cnt, "limit_down": ld_cnt},
            "market": {"amount": round(amount_total, 0), "vol": round(vol_total, 0),
                       "stock_count": int(last["code"].nunique())},
            "gainers": [_row(r, with_amount=False) for _, r in gainers.iterrows()],
            "actives": [_row(r) for _, r in actives.iterrows()],
        }
        self._overview_cache = res
        return res

    # ---------- 个股详情 ----------
    def stock_detail(self, code: str, force: bool = False) -> dict:
        key = code
        if not force and key in self._stock_detail_cache:
            return self._stock_detail_cache[key]
        fcode = self._normalize_code(code)
        sf = self._sf(fcode)
        if len(sf) == 0:
            raise HTTPException(404, f"股票 {code} 当日无交易数据(可能停牌)")
        sub = sf[sf["time_idx"] <= self.t]
        b = sub.iloc[-1]
        prev_close = float(b["prev_close"])
        close = float(b["close"])
        pct = (close / prev_close - 1) * 100 if prev_close and not math.isnan(prev_close) else 0
        high = float(sub["high"].max()) if len(sub) else close
        low = float(sub["low"].min()) if len(sub) else close
        amp = (high - low) / prev_close * 100 if prev_close else 0
        # 分时: 价 + 均价线 + 成交量 + 成交额
        times = [self.time_list[i] for i in sub["time_idx"] if i < len(self.time_list)]
        prices = [round(float(x), 2) for x in sub["close"]]
        vols = [float(x) for x in sub["vol"]]
        cum_amount = [float(x) for x in sub["amount"].cumsum()]
        cum_vol = sub["vol"].cumsum().replace(0, np.nan)
        avg_price = [round(float(a / v), 2) if v and not math.isnan(v) else None
                     for a, v in zip(cum_amount, cum_vol)]
        amount_total = float(sub["amount"].sum())
        # 量比: 今日累计均量 / 前5日同累计均量(需要历史, 用 filter 快速读)
        vol_ratio = self._calc_vol_ratio(fcode)
        # 五档盘口(模拟): 基于最新价与成交量拆分
        order_book = self._mock_order_book(b, sub)
        ps = self.price_state(fcode)
        detail = {
            "code": fcode.split(".")[0],
            "full_code": fcode,
            "name": self.data.disp_name(fcode),
            "price": round(close, 2),
            "prev_close": round(prev_close, 2) if not math.isnan(prev_close) else None,
            "pct": round(pct, 2),
            "high": round(high, 2), "low": round(low, 2),
            "open": round(float(sub.iloc[0]["open"]), 2),
            "amount": round(amount_total, 0),
            "vol": round(float(sub["vol"].sum()), 0),
            "amp": round(amp, 2),
            "vol_ratio": round(vol_ratio, 2) if vol_ratio else None,
            "time": self.time_list[self.t],
            "limit_up_price": ps["limit_up_price"],
            "limit_dn_price": ps["limit_dn_price"],
            "is_limit_up": ps["limit_up"],
            "is_limit_down": ps["limit_dn"],
            "chart": {
                "times": times, "prices": prices, "avg": avg_price, "vols": vols,
                "prev_close": round(prev_close, 2) if not math.isnan(prev_close) else None,
            },
            "order_book": order_book,
            "is_new": math.isnan(prev_close),
        }
        self._stock_detail_cache[key] = detail
        return detail

    def _normalize_code(self, code: str) -> str:
        code = code.strip().upper()
        if "." in code:
            return code
        if code.startswith(("6", "9", "5")):
            return code + ".SH"
        return code + ".SZ"

    def _calc_vol_ratio(self, fcode: str) -> Optional[float]:
        """量比 = 今日累计均量 / 前5日同时点累计均量"""
        try:
            cur = self._sf(fcode)
            cur_sub = cur[cur["time_idx"] <= self.t]
            if len(cur_sub) < 2:
                return None
            cur_avg = cur_sub["vol"].mean()
            hist = []
            for d in self.data.days[max(0, self.day_idx - 5):self.day_idx]:
                hf = pd.read_parquet(self.data._paths[d],
                                     filters=[("code", "==", fcode)])
                hf = hf.sort_values("trade_time")
                n = min(self.t + 1, len(hf))
                if n > 0:
                    hist.append(float(hf.iloc[:n]["vol"].mean()))
            if not hist:
                return None
            return float(cur_avg / (sum(hist) / len(hist)))
        except Exception:
            return None

    def _mock_order_book(self, bar: pd.Series, sub: pd.DataFrame) -> dict:
        """模拟五档盘口(无真实盘口数据, 基于最新价与分钟成交量拆分, 仅展示)"""
        price = float(bar["close"])
        vol = max(float(bar["vol"]), 1.0)
        up = bool(bar["limit_up"] == bar["limit_up"] and
                  price >= float(bar["limit_up"]) - 0.005)
        dn = bool(bar["limit_dn"] == bar["limit_dn"] and
                  price <= float(bar["limit_dn"]) + 0.005)
        def _tick(p: float) -> float:
            return round(p * 100) / 100.0
        bids, asks = [], []
        for i in range(1, 6):
            bp = _tick(price - i * PRICE_TICK)
            ap = _tick(price + i * PRICE_TICK)
            bq = 0 if dn else int(vol * (0.35 - i * 0.05) * (0.8 + (i % 3) * 0.15))
            aq = 0 if up else int(vol * (0.30 - i * 0.04) * (0.9 + (i % 2) * 0.2))
            bids.append({"price": bp, "vol": max(bq, 0), "level": i})
            asks.append({"price": ap, "vol": max(aq, 0), "level": i})
        return {"bids": bids, "asks": asks, "simulated": True}

    def kline(self, code: str, days: int = 60) -> list:
        """日K: 遍历最近 N 个交易日, 用 pyarrow 谓词下推只读该股, 取当日 OHLC"""
        fcode = self._normalize_code(code)
        start = max(0, self.day_idx - days + 1)
        rows = []
        for d in self.data.days[start:self.day_idx + 1]:
            try:
                hf = pd.read_parquet(self.data._paths[d],
                                     filters=[("code", "==", fcode)])
                if len(hf) == 0:
                    continue
                hf = hf.sort_values("trade_time")
                prev = self.data.prev_close_map(d)
                pc = prev.get(fcode)
                o = float(hf.iloc[0]["open"])
                c = float(hf.iloc[-1]["close"])
                h = float(hf["high"].max())
                l = float(hf["low"].min())
                v = float(hf["vol"].sum())
                a = float(hf["amount"].sum())
                rows.append({
                    "date": d, "open": o, "close": c, "high": h, "low": l,
                    "vol": v, "amount": a,
                    "pct": round((c / pc - 1) * 100, 2) if pc else None,
                })
            except Exception:
                continue
        return rows

    # ---------- 交易 ----------
    def place_order(self, code: str, side: str, otype: str, price: Optional[float],
                    qty: int) -> dict:
        fcode = self._normalize_code(code)
        side, otype = side.upper(), otype.upper()
        if side not in ("BUY", "SELL"):
            raise HTTPException(400, "side 必须是 BUY/SELL")
        if otype not in ("LIMIT", "MARKET"):
            raise HTTPException(400, "otype 必须是 LIMIT/MARKET")
        if self.is_closed:
            raise HTTPException(400, f"已收盘({self.time_str}), 无法下单")
        sf = self._sf(fcode)
        if len(sf) == 0:
            raise HTTPException(404, f"股票 {code} 当日无交易数据(可能停牌)")
        b = self.latest_bar(fcode)
        if b is None:
            raise HTTPException(400, "暂无行情")
        latest = float(b["close"])
        prev_close = float(b["prev_close"])
        ps = self.price_state(fcode)
        if otype == "MARKET":
            price = latest
        if price is None or price <= 0:
            raise HTTPException(400, "价格必须大于0")
        price = round(price, 2)
        if qty <= 0 or qty != int(qty):
            raise HTTPException(400, "数量必须为正整数")
        # 涨跌停拦截
        if side == "BUY" and ps["limit_up"]:
            raise HTTPException(400, f"{fcode} 已涨停({ps['limit_up_price']}元), 买不进")
        if side == "SELL" and ps["limit_dn"]:
            raise HTTPException(400, f"{fcode} 已跌停({ps['limit_dn_price']}元), 卖不出")
        # 委托价格必须在当日涨跌停价格区间内(A股规则: 超出区间的委托无效)
        if ps["limit_up_price"] is not None and ps["limit_dn_price"] is not None:
            if price > ps["limit_up_price"] + PRICE_TICK:
                raise HTTPException(
                    400, f"委托价 {price} 超过涨停价 {ps['limit_up_price']}, 超出有效委托区间")
            if price < ps["limit_dn_price"] - PRICE_TICK:
                raise HTTPException(
                    400, f"委托价 {price} 低于跌停价 {ps['limit_dn_price']}, 超出有效委托区间")
        if side == "BUY":
            if qty % LOT != 0:
                raise HTTPException(400, f"买入数量必须为 {LOT} 股整数倍")
            # 限价买单: 价格 < 最新价 -> 挂起; 否则立即按市价成交
            need = qty * price
            fee = self._fee(side, need)
            if need + fee > self.cash + 1e-6:
                raise HTTPException(400, "可用资金不足")
            if otype == "LIMIT" and price < latest - 1e-9:
                return self._pending(fcode, side, price, qty,
                                     "挂单中: 买入价低于市价, 等待回调")
            return self._fill(fcode, side, price, qty, latest, immediate=True)
        else:  # SELL
            pos = self.positions.get(fcode)
            if not pos:
                raise HTTPException(400, "无此持仓")
            avail = pos["shares"] - pos["today_buy"]
            if avail <= 0:
                raise HTTPException(400, "可用股数为0(T+1: 当日买入不可当日卖出)")
            if qty > avail:
                raise HTTPException(400, f"可卖数量不足, 可用 {avail} 股")
            if otype == "LIMIT" and price > latest + 1e-9:
                return self._pending(fcode, side, price, qty,
                                     "挂单中: 卖出价高于市价, 等待拉升")
            return self._fill(fcode, side, price, qty, latest, immediate=True)

    def _fee(self, side: str, amount: float) -> float:
        comm = max(amount * COMMISSION_RATE, COMMISSION_MIN)
        stamp = amount * STAMP_TAX_RATE if side == "SELL" else 0.0
        transfer = amount * TRANSFER_FEE_RATE
        return round(comm + stamp + transfer, 2)

    def _pending(self, fcode: str, side: str, price: float, qty: int, reason: str) -> dict:
        oid = self._order_seq
        self._order_seq += 1
        order = {
            "id": oid, "day": self.day, "time": self.time_str, "code": fcode,
            "name": self.data.disp_name(fcode), "side": side, "type": "LIMIT",
            "price": price, "qty": qty, "status": "PENDING", "reason": reason,
            "filled_price": None, "filled_time": None,
            "time_idx": self.t,
        }
        self.orders.append(order)
        return {"status": "PENDING", "order": self._pub(order)}

    def _fill(self, fcode: str, side: str, price: float, qty: int, fill_price: float,
              immediate: bool = False, order: Optional[dict] = None) -> dict:
        """成交(price: 委托价, fill_price: 实际成交价)"""
        fill_price = round(fill_price, 2)
        amount = qty * fill_price
        fee = self._fee(side, amount)
        tid = self._trade_seq
        self._trade_seq += 1
        if side == "BUY":
            self.cash -= amount + fee
            pos = self.positions.setdefault(fcode, {
                "shares": 0, "cost": 0.0, "today_buy": 0})
            pos["shares"] += qty
            pos["cost"] += amount + fee
            pos["today_buy"] += qty
        else:
            self.cash += amount - fee
            pos = self.positions[fcode]
            old_shares = pos["shares"]
            if old_shares > 0:
                pos["cost"] -= pos["cost"] * (qty / old_shares)
            pos["shares"] -= qty
            if pos["shares"] <= 0:
                del self.positions[fcode]
        trade = {
            "id": tid, "day": self.day, "time": self.time_str, "code": fcode,
            "name": self.data.disp_name(fcode), "side": side,
            "price": fill_price, "qty": qty, "amount": round(amount, 2),
            "fee": fee, "type": "MARKET" if immediate else "LIMIT",
            "matched": "immediate" if immediate else "triggered",
        }
        self.trades.append(trade)
        if order is not None:
            order["status"] = "FILLED"
            order["filled_price"] = fill_price
            order["filled_time"] = self.time_str
            order["reason"] = "已成交"
        return {"status": "FILLED", "trade": trade}

    def _match_all_orders(self):
        """时间推进后撮合所有挂单"""
        df = self._day_df()
        for o in self.orders:
            if o["status"] != "PENDING":
                continue
            fcode = o["code"]
            sf = df[df["code"] == fcode]
            if len(sf) == 0:
                continue
            bars = sf[(sf["time_idx"] > o["time_idx"]) & (sf["time_idx"] <= self.t)]
            if len(bars) == 0:
                continue
            hit = False
            for _, b in bars.iterrows():
                lu, ld = float(b["limit_up"]), float(b["limit_dn"])
                if o["side"] == "BUY":
                    if float(b["low"]) <= o["price"] + 1e-9:
                        if not math.isnan(lu) and float(b["close"]) >= lu - 0.005:
                            continue  # 该分钟封板, 买单排不到
                        hit = True
                        break
                else:
                    if float(b["high"]) >= o["price"] - 1e-9:
                        if not math.isnan(ld) and float(b["close"]) <= ld + 0.005:
                            continue  # 该分钟封死跌停, 卖不出
                        hit = True
                        break
            if hit:
                self._fill(fcode, o["side"], o["price"], o["qty"], o["price"], order=o)

    def cancel_order(self, oid: int) -> dict:
        for o in self.orders:
            if o["id"] == oid and o["status"] == "PENDING":
                o["status"] = "CANCELLED"
                o["reason"] = "用户撤单"
                return {"status": "CANCELLED"}
        raise HTTPException(404, "未找到可撤销的挂单")

    # ---------- 资产 ----------
    def _pub_pos(self, code: str, pos: dict) -> dict:
        close = self.latest_close(code)
        mv = pos["shares"] * (close or 0)
        avg = pos["cost"] / pos["shares"] if pos["shares"] else 0
        pnl = (close - avg) * pos["shares"] if close else 0
        return {
            "code": code.split(".")[0], "full_code": code,
            "name": self.data.disp_name(code), "shares": pos["shares"],
            "avail": pos["shares"] - pos["today_buy"],
            "today_buy": pos["today_buy"], "cost": round(pos["cost"], 2),
            "avg_cost": round(avg, 3), "price": round(close, 2) if close else None,
            "market_value": round(mv, 2), "pnl": round(pnl, 2),
            "pnl_pct": round((close / avg - 1) * 100, 2) if close and avg else None,
        }

    def state(self) -> dict:
        mv = 0.0
        pos_list = []
        for code, pos in self.positions.items():
            p = self._pub_pos(code, pos)
            pos_list.append(p)
            mv += p["market_value"]
        total = self.cash + mv
        day_pnl = total - self.base_asset
        return {
            "day": self.day,
            "day_idx": self.day_idx,
            "total_days": len(self.data.days),
            "time": self.time_str,
            "time_idx": self.t,
            "time_list_len": len(self.time_list),
            "is_closed": self.is_closed,
            "game_over": self.game_over,
            "cash": round(self.cash, 2),
            "market_value": round(mv, 2),
            "total_asset": round(total, 2),
            "day_pnl": round(day_pnl, 2),
            "day_pnl_pct": round(day_pnl / self.base_asset * 100, 3) if self.base_asset else 0,
            "position_count": len(self.positions),
            "positions": sorted(pos_list, key=lambda x: x["market_value"], reverse=True),
        }

    def _pub(self, o: dict) -> dict:
        return {k: v for k, v in o.items() if k != "time_idx"}

    def search(self, q: str, limit: int = 10) -> list:
        q = q.strip().lower()
        if not q:
            return []
        # 当日代码列表按天缓存(避免每次全表 unique)
        if self._codes_day != self.day:
            self._codes_day = self.day
            self._codes = sorted(self._day_df()["code"].unique())
        out = []
        for c in self._codes:
            c6 = c.split(".")[0]
            name = self.data.disp_name(c)
            if q in c6 or q in name.lower():
                out.append({"code": c6, "full_code": c, "name": name})
            if len(out) >= limit:
                break
        return out


# ============================== 实例化 ==============================
data_svc = DataService(DATA_DIR)
data_svc.load_names()
game = Game(data_svc)
game.reset()  # 默认 2022 年第一个交易日


# ============================== API ==============================
class InitReq(BaseModel):
    day: Optional[str] = None


class OrderReq(BaseModel):
    code: str
    side: str          # BUY / SELL
    type: str          # LIMIT / MARKET
    price: Optional[float] = None
    qty: int


class AdvanceReq(BaseModel):
    step: str          # 15m / 1h / 1d


class CancelReq(BaseModel):
    id: int


@app.get("/api/meta")
def meta():
    return {
        "initial_cash": INIT_CASH,
        "days": data_svc.days,
        "default_day": Game.default_day(data_svc),
        "years": sorted({d[:4] for d in data_svc.days}),
        "days_sample": data_svc.days[:3] + ["..."] + data_svc.days[-3:],
        "stock_count": len(set(
            data_svc._load_raw(game.day)["code"].tolist())) if game.day else 0,
        "names_loaded": len(data_svc.names) > 0,
        "rules": {
            "T+1": "当日买入的股票当日不可卖出",
            "limit": "涨跌停按板块: 主板/创业板10%, 科创板/创业板(2020-08-24后)20%, 北交所30%, ST 5%; 涨停买不进/跌停卖不出; 新股首日无涨跌停",
            "commission": "佣金万2.5(最低5元) + 印花税千1(卖出) + 过户费万0.1",
            "order": "委托价须在当日涨跌停区间内; 限价买单低于市价挂起, 触及价成交; 挂单当日有效收盘作废",
        },
    }


@app.post("/api/game/init")
def init(req: InitReq):
    game.reset(req.day)
    return game.state()


@app.get("/api/game/state")
def get_state():
    return game.state()


@app.get("/api/market/overview")
def get_overview():
    return game.overview()


@app.get("/api/stock/{code}")
def get_stock(code: str):
    return game.stock_detail(code)


@app.get("/api/stock/{code}/kline")
def get_kline(code: str, days: int = 60):
    return game.kline(code, days)


@app.post("/api/order")
def place_order(req: OrderReq):
    try:
        return game.place_order(req.code, req.side, req.type, req.price, req.qty)
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(400, str(e))


@app.post("/api/order/cancel")
def cancel(req: CancelReq):
    return game.cancel_order(req.id)


@app.post("/api/time/advance")
def advance(req: AdvanceReq):
    return game.advance(req.step)


@app.get("/api/orders")
def get_orders():
    return [game._pub(o) for o in reversed(game.orders)]


@app.get("/api/trades")
def get_trades():
    return list(reversed(game.trades))


@app.get("/api/search")
def search(q: str, limit: int = 10):
    return game.search(q, limit)


if os.path.isdir(STATIC_DIR):
    app.mount("/", StaticFiles(directory=STATIC_DIR, html=True), name="static")


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="127.0.0.1", port=8337)

#!/bin/bash
# A股历史盘复刻 · 模拟交易游戏 — 一键启动(后台常驻)
cd "$(dirname "$0")"
PY=/Users/malihao/.workbuddy/binaries/python/envs/default/bin/python
if [ ! -x "$PY" ]; then PY=python3; fi
mkdir -p .cache
# 重启: 先停旧进程
pkill -f "uvicorn server:app" 2>/dev/null
sleep 1
nohup "$PY" -m uvicorn server:app --host 127.0.0.1 --port 8337 > .cache/server.log 2>&1 &
sleep 2
echo "已启动 A股历史盘复刻终端: http://127.0.0.1:8337"
echo "日志: .cache/server.log | 停止: pkill -f 'uvicorn server:app'"

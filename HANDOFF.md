# 《重生股神》项目交接文档（HANDOFF.md）

> 给接手开发者（人或 AI）的完整交接。**先读完全文再动代码**，尤其「§7 Godot 4.7 GDScript 铁律」和「§8 已知坑」——违反任何一条都会崩。
> 项目当前状态：**A 测 v0.1**（2026-08-24 出安卓包），版本号 -0.1。

---

## 1. 项目一句话

**《重生股神》**：roguelike 模拟经营+冒险游戏（Godot 4.7.2，移动端竖屏 460×900）。
2026年7月主角炒股亏光跳楼，与恶魔交易重生回 2022 开户日，觉醒「重生股神系统」，
在死亡日期前把 100 万本金做到目标金额（难度一~七：死亡第 220→160 日、目标 2→5 倍本金）。
**数据全部来自 A 股真实历史（裁剪自全量数据），但每局随机洗牌防背答案。**

---

## 2. 目录结构

```
股市仿真游戏/                     ← 项目根（Mac 上在此开发）
├── game_data/game/                ← 【全量原始数据 2.3GB，勿删勿传】
│   └── day_bins/0000..1031.bin    ← 1032 天 × 500 股 1 分钟 OHLCV
├── scripts/                       ← 数据生成脚本（Python，跨平台）
│   ├── pick_pool.py               ← 流动性 top500 选股
│   ├── convert_2023_2025.py       ← parquet → bin 转换
│   └── shuffle_build.py           ← 月份块洗牌打包 + meta.json
├── godot/                         ← ★ Godot 项目（开发主体）
│   ├── project.godot              ← 项目配置（竖屏/stretch/ETC2）
│   ├── export_presets.cfg         ← 安卓导出预设（signed=false 手动签）
│   ├── cutscene_content.tscn      ← ★ 必须放项目根（剧情容器约定）
│   ├── scenes/                    ← start_screen / cutscene / main
│   ├── scripts/                   ← 全部 GDScript（16 个，见 §5）
│   ├── game_data/game/            ← ★ 游戏用数据：260 天精简包（res:// 读）
│   └── assets/                    ← 视频 ogv / 字体 Noto / 贴图
└── HANDOFF.md / 迁移清单.md       ← 本文档
```

---

## 3. 技术栈与运行环境

| 项 | 值 |
|----|----|
| 引擎 | Godot 4.7.2 stable（渲染器 gl_compatibility，移动端友好） |
| 语言 | GDScript 4（严格模式：类型推断警告=错误） |
| 数据 | res://game_data/game（260 天精简包，meta.json + day_bins/*.bin） |
| 字体 | 打包开源 Noto Sans CJK（scripts/fonts.gd，安卓必须自带字体） |
| 安卓工具链 | JDK17 + Android SDK(platform 34/build-tools 34) + Godot 导出模板 4.7.2.stable |

**headless 验证命令**（Mac 上）：
```bash
# 编译+运行验证（零错误才算过）
~/Downloads/Godot.app/Contents/MacOS/Godot --headless --path . res://scenes/main.tscn --quit-after 150 --max-fps 60
# 首次导入资源（新增 otf/类名后必须跑）
~/Downloads/Godot.app/Contents/MacOS/Godot --headless --path . --import
```
Windows 对应：`Godot.exe --headless --path . ...`。

---

## 4. 数据管线（权威约定）

### 4.1 bin 文件格式（read-only，勿改）
```
文件头 20 字节：magic(4B,=0x4153544B "ASTK") + version(4B) + stock_count(4B=500) + minute_count(4B=241) + day_index(2B)
prev_close：500 × float32（该日历史昨收；但游戏内会被归一化覆盖，见 4.4）
数据区：500 × 241 × 5 × float32，交错布局 [stock][minute][o,h,l,c,v]
索引：field_base(i, mi) = i*241*5 + mi*5 + F_C（F_C=3）
时间轴 241 分钟：09:30-11:30（t=0..120）+ 13:01-15:00（t=121..240），【无 13:00】
vol 单位=股，amount 单位=元
```
### 4.2 meta.json
```json
{ "pool": [{"code":"600519.SH","name":"贵州茅台"}, ...500只],
  "days": [{"idx":0,"block":"202308","real_day":"20230801"}, ...260条] }
```
- `days[k].idx` = bin 文件编号（洗牌后 idx≠k，读文件必须用 idx）
- `real_day`/`block` **已废弃不用**（游戏日历独立连续，见 4.3）
- **池内 code 带后缀**（"600519.SH"），显示层用 `_code_disp()` 去后缀；测试脚本必须用完整 code，否则 stock_idx=-1 崩

### 4.3 开局随机化 + 连续日历（data_loader.gd）
每次新局 `setup_run()` 调用：
1. `reshuffle()`：随机种子，Fisher-Yates 洗 **pool**（数据列↔公司名随机匹配）+ 洗 **days**（历史↔游戏日随机匹配）
2. `build_calendar(n)`：生成连续交易日日历（2022-09-01 开户日起，跳周末，蔡勒公式），`game_day_str(day_idx)`
3. `preprocess()`：遍历全部游戏日建**游戏内价格链** `_game_prev[k*m+i]`（第 0 天起点=历史昨收，之后=前一日收盘×历史涨跌幅，**涨跌停钳制**）——每局约 1.6s

### 4.4 价格归一化（load_day → _normalize_day）
- **只继承历史涨跌幅形态，价格从前一游戏日收盘连续**（否则跨日价格跳变几十倍）
- `_limit_pct(code,name)`：ST 5% / 688·689·300·301 20% / 8·4·92 30% / 主板 10%；O/H/L/C 全部 `clampf(ratio, 1-lim, 1+lim)`
- 停牌：价=昨收、量=0（无 NaN）
- 成交量 × 缩放系数（游戏内昨收/历史昨收）保持成交额形态
- **索引语义**：`_game_prev[k]` 存第 k 天**收盘**；第 k 天昨收 = `_game_prev[k-1]`（k>0）或历史昨收（k=0）
- `load_day(day_idx, use_cache=true)`：缓存只保留最近 6~8 天（防内存膨胀）

### 4.5 K 线聚合（kline_data(code, period, count, cur_day)）
- D=逐日 / W=每 5 交易日分组 / M=按日历月分组
- 聚合时 `load_day(k, false)` **不缓存** + **只归一化目标单股**（`_load_raw` + `_game_prev` 表，勿改回整包归一化——会慢 500 倍）

---

## 5. 引擎规则与架构

### 5.1 场景流
`start_screen(主菜单)` →[Transition 渐隐]→ `cutscene(剧情容器)` →[跳过/播完]→ `main(交易界面)` →[结算]→ `start_screen`
- **剧情容器约定**：剧情内容必须在 `res://cutscene_content.tscn`（**项目根目录，不带 scenes/ 前缀**！放错会一直显示占位）
- autoload：`Global`（配色/难度/恶魔币持久化）、`Transition`（场景渐隐）

### 5.2 脚本职责
| 脚本 | 职责 |
|------|------|
| data_loader.gd | 数据层：meta/bin 读取、洗牌、日历、归一化、K线聚合（load() 返回 RefCounted 实例） |
| game_manager.gd | 引擎：资金/持仓/委托/撮合/T+1/涨跌停/死期结算/finish_run（**extends RefCounted 不是 Node**） |
| trade_engine.gd | 费用计算（佣金万2.5≥5元+印花税千1卖+过户费万0.1） |
| main.gd | 交易界面（~2000 行，四页 TabBar：行情/能力/交易/系统 + 个股详情 + 引导框 + 新手教程） |
| start_screen.gd | 主菜单（暗金风格 + 恶魔果实面板 + 难度切换） |
| cutscene*.gd / fx_cutscene_draw.gd | 剧情（视频 ogv 10s + 程序化动画 17s） |
| chart.gd / fx_kline.gd | 分时图 / 蜡烛图（自绘类，class_name MinuteChart/KlineChart） |
| fx_guide.gd / fx_background.gd / fx_glow.gd | 自绘层（引导框背景/主菜单背景/光效） |
| fonts.gd | 全局字体（GF.regular()/bold()，打包 Noto） |

### 5.3 交易规则（已实现，勿破坏）
T+1（当日买入不可卖，跨日解冻 `today_buy` 清零） / 动态涨跌停（见 4.4）/ 委托价区间校验 / 限价触及撮合（低于现价的买单 PENDING 等回调，**收盘自动作废**）/ 市价=现价即时成交 / 100 股整数倍（买入；卖出支持零股）/ 资金校验 / **最多同时持有 30 只** / 挂单数无上限
- 时间推进：`advance(step)`（15m/1h/1d，**午休跳转**：t≤120 且跨过→跳到 t=121）+ `advance_bulk(n)`（批量快进，中间天只推状态不读数据，仅末帧 load_day——**快进卡死修过 3 轮，勿回退**）
- `can_advance(step)`：跨过收盘(末分钟)禁用；`1d` **永不禁用**（靠 +1日 推进到死期结算）
- 游戏日历独立：`real_day()` = 连续日历，下午显示整体减 1 分钟（数据 13:01 显示 13:00），收盘 15:00 不偏移
- 死期：`day_idx >= death_day_idx` → `finish_run()` 结算（胜利奖励恶魔币=(难度+1)×50，存 user://save.cfg）

---

## 6. UI/布局约定

- 竖屏 460×900 设计分辨率，`canvas_items` stretch（任意手机比例自适应）
- 配色 Global：`C_MAIN=#d0021b`(红=主色/涨) `C_GREEN=#0a9b4a`(跌) `GOLD=#f0c75e`（暗金系：GOLD_BG/GOLD_DARK/GOLD_OUTLINE）
- **红涨绿跌**（中国习惯，勿改反）
- 所有字号已按"移动端尽量大"调过（总资产 36 号等），**不要整体改小**
- 时间推进悬浮块固定在右下角（`time_float`），**交易页所有子界面+个股详情都显示**
- 底部 TabBar：行情/能力/交易/系统（交易默认）；能力/系统是占位页
- 行情页五大可展开条：搜索(默认收起)/排行(涨跌幅成交额三tab)/板块精选(懒加载)/特殊股票(占位)/自选列表(局部更新)
- 4 页引导框 + 新手教程（引导框关闭后 2 步引导：加自选→进买入页）

---

## 7. ⚠️ Godot 4.7 GDScript 铁律（血泪教训，违反必崩/必错）

1. **类型推断警告=错误**：Dictionary 取值是 Variant，`var x := dict[key]` 必报错 → 显式 `var x: float = float(...)`；max/min→`maxf/minf`、abs→`absf`、clamp→`clampi/clampf`
2. **⚠️ lambda 捕获是"创建时快照"（值捕获）**：`var b: Button = null; b = _btn(..., func(): b.text=...)` —— lambda 创建时 b 还是 null，点击时对 Nil 赋值**崩溃**（"Invalid assignment ... on Nil"）！铁律：**lambda 只能引用①函数参数(默认参数捕获 `func(cd = code)`)②创建时已赋值的局部变量③成员变量**；"先声明后赋值"的局部变量绝不能进 lambda。崩溃日志：`~/Library/Application Support/Godot/app_userdata/重生股神/logs/godot*.log`
3. **自绘必须独立类**：`node.draw.connect(func)` 画在错误节点 → 每个绘制层 extends Control 重写 `_draw()`；**Control 子节点父必须是 Control**（否则锚点失效 size=0 全黑）
4. **`-s` 脚本模式不加载 autoload**（误报 Identifier not found）；端到端测试放临时 autoload
5. **`--quit-after N` 单位是帧数非秒**；headless 验证长流程须 `--max-fps 60`（否则真实时间不够）；**GUI 模式复现卡顿/崩溃**（headless 测不出渲染+输入交错时序）
6. **视频**：Godot 4 核心只支持 Ogg Theora(.ogv)；MP4/WebM 不支持；ffmpeg 转码 `-c:v libtheora -q:v 7 -c:a libvorbis`；ogv 无需 --import；VideoStreamPlayer 无 stretch 只有 expand；**draw_string 不支持 \n** 须逐行画
7. **class_name 需 --import 扫描才注册**：新类用 `preload("res://...")` 显式引用（如 `const GF := preload("res://scripts/fonts.gd")`）
8. **load().new() 返回 Variant** → preload().new() + 显式类型；**GameManager extends RefCounted**（测试里 `var gm: Node = m.get("gm")` 会类型报错）
9. **tween 回调 lambda 捕获的节点若可能被提前释放**：必须 `is_instance_valid(l) and 成员==l` 防御（连续翻天提示/连点 toast 曾崩）
10. **性能**：`SystemFont.new()` 每次创建极贵（曾致行情页 5.7s 卡死）→ 已用 `_font_cache`/GF 缓存，勿回退；板块成员**懒加载**（点开才构建）；行情数据缓存 `_quote_cache` 必须**无条件清**（推进时间后，不依赖当前页——曾致涨跌幅永远显示 0）
11. **红涨绿跌**：`_pct_color(pnl)` 正红负绿，勿改

---

## 8. 已知坑（已解决，改代码时勿踩回）

| 坑 | 现状 |
|----|------|
| 数据绝对路径 | 已改 `res://game_data/game`（260 天精简包在项目内） |
| 安卓无 PingFang 字体 | 已用 GF（Noto）替换全部 SystemFont |
| Godot 4.4+ sparse pck 漏掉 .bin 数据 | **打包流程必须手动 zip 塞数据**（见 §10） |
| Godot 内建签名 alias 传错 | `package/signed=false` + 手动 apksigner（JAVA_HOME 必须） |
| movie maker 离屏 Button/Label 文字不可靠 | 逻辑验证以 headless 打印 Label.text 为准 |
| GDScript 数组嵌套取值 `grp[0][3]` 是 Variant | 显式 float() |
| 快进30日连点卡死（3 轮） | `_advance_30d` 连点合并（_pending_days）+ advance_bulk + 按钮禁用 |
| 翻天提示 tween 竞争 | is_instance_valid + 成员置 null |

---

## 9. 待办与建议优化方向

### 当前待办（P1 优先）
- P1 交易打磨：五档盘口真实化、行情榜完善、自选排序
- P2 roguelike：**能力系统**（底部 Tab「能力」占位页→觉醒抽卡、技能定义接入引擎、任务系统）、「系统」页（任务/技能/物品）
- P3 闭环：**存档系统**（当前只有恶魔币持久化，游戏进度无存档）、结算画面完善、设置、音效
- P4 真实：ST/除权除息、数据扩展、性能（安卓首启预处理 10-30s 黑屏→加加载画面）
- P5 打包发布（正式签名 keystore）

### 深度优化候选（给 DeepSeek 的起点）
1. **安卓首启加载画面**：preprocess 260 天在安卓上黑屏 10-30s → 加载界面 + 分帧/后台线程
2. **main.gd 拆分**（2000+ 行）：按页/功能抽模块（行情页、详情页、下单面板、引导）
3. **数据层提速**：_load_raw 每次读 2.4MB 全包——考虑只读目标股、或预构建索引
4. **能力/任务系统的数据与 UI 框架**（为 P2 铺路）
5. 渲染性能：大量 Label 的列表页在低端安卓的帧率

---

## 10. 安卓打包命令链（A 测流程，勿乱改）

```bash
# 1. Godot 导出未签名 APK（export_presets.cfg 已配好；signed=false）
Godot --headless --path . --export-debug "Android" build/stockking.apk
#    ⚠️ 导出器会漏掉 game_data/day_bins/*.bin（Godot sparse pck 机制 bug）

# 2. 手动把数据塞进 APK（python zipfile：复制全部条目 + 添加 assets/game_data/game/day_bins/*.bin，deflate 6）

# 3. 对齐+签名（JAVA_HOME 必须指向 JDK17）
zipalign -f 4 full.apk aligned.apk
apksigner sign --ks ~/.android/debug.keystore --ks-pass pass:android --ks-key-alias androiddebugkey --out final.apk aligned.apk
apksigner verify final.apk

# 4. 应用名/包名在 export_presets.cfg：package/name="重生股神"、package/unique_name="com.heaven.stockking"
# 工具链：JDK17 + Android SDK（platforms;android-34 + build-tools;34.0.0）+ 模板 ~/Library/Application Support/Godot/export_templates/4.7.2.stable/
# 模板下载 URL（带 query！）：https://downloads.godotengine.org/?version=4.7.2&flavor=stable&slug=export_templates.tpz&platform=templates
```

---

## 11. 一句话开发守则

> **小步改、每步 headless 验证零错误；改引擎/数据层先看 §4；写 UI 先看 §6；用 lambda 先背 §7.2；改性能相关先读 §7.10。**

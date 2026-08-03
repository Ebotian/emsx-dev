# EMSx 审计研究可视化计划

> 规划文档，不执行。目标：为第七版审计报告（`typst_conclusion/emsx_verified_rollout.typ`）
> 设计一套有说服力、可复现、诚实的可视化。每张图对应一个**已闭环的审查结论**。
>
> **v2 修订**：05_results 页对比对象改为**论文标准控制器**
> （MPC 0.487 / OLFC 0.506–0.513 / SDP 0.691 / SDP-AR(1) 0.794，官方口径，
> 来自论文 Table tab:score）——当前基线 S_AR 已是改进后的，应展示它相对
> 论文较差方案的提升。双口径（官方 EMSx 口径 vs 本研究物理 LP 口径）
> 严格分开展示。
>
> **v3 修订**：对比不限于终点得分，还包含**过程差异**与**逐站点差异**——
> 所有曲线数据**按控制器平行准备**（每个控制器都有终点/逐站点/过程三套
> 数据），对比视图任意选控制器平行显示。新增 06_per_site 与 07_process
> 两页；02_dispatch 支持控制器切换。
>
> **v4 修订（前端架构与设计规范）**：
> - 前端栈：**Astro + Svelte 5 + TypeScript + Vite + pnpm + ECharts**
>   （环境已确认：Node 26.4.0 / pnpm 11.3.0）。
> - 设计规范：**Helvetica 风格、简约大方**——Helvetica 字体栈、
>   近黑/中性灰/白为主、单一强调色、8px 栅格、无装饰渐变阴影、
>   数字用 tabular-nums；数据系列按控制器家族着色（论文 lookahead
>   冷灰蓝、我们的物理控制器深蓝、exploit 红），非彩虹色板。
> - 组件：Svelte 成熟组件抽象（Chart 封装 / ControllerSelect /
>   口径标注 / 设计 token），非一次性 HTML 堆叠。

---

## 0. 设计原则（说服力来源）

1. **一图一结论**：每张图只回答一个问题，直接支撑报告中某一段落；
   不做装饰性图。
2. **主指标优先**：raw cost 节省（M₀ 相对 S_AR）是主图；normalized
   score 与风险坐标是副图。避免让 exploit 时代的 0.9973 抢视觉焦点。
3. **负结果不藏**：exploit 指标、11/70、corr=-0.095、~1% 边界效应
   都要可视化，甚至放在显眼位置——诚实本身就是说服力。
4. **数量级处理**：exploit 指标跨 1e-5 到 1e0，用对数刻度；成本差
   用线性刻度并标注数值。
5. **可复现**：所有图从 `score.jld2` / `physical_lp_oracle.csv` /
   `scores_full.csv` / train-test CSV 直接生成，脚本存
   `visualization_plan/scripts/`，图存 `visualization_plan/figures/`。
6. **标注关键数**：每张图角标注支撑结论的数字（如 "11/70 sites
   above baseline"、"~1% terminal"、"corr = -0.095"）。

---

## 1. 图清单（按报告叙事顺序）

### A. Exploit 审计（对应 §4.1–4.2，报告的核心翻转）

**图 A1 — 空电池放电的"免费能量"（单站点单日轨迹）**
- 内容：site 1 一个典型日的时间序列，双轴：SOC（左，0–1）与
  u（右，–1..1）；叠加累计账单成本。
- 数据源：R_P 无过滤版（或直接构造 u=-1, SOC=0 的 apply_control 演示）。
- 说服点：一眼看出"u=-1 从 SOC=0 发出、账单下降、SOC 停在 0"——
  环境能量不守恒的直观实证。
- 标注：箭头指向"bill drops while SOC clamps at 0"。

**图 A2 — exploit 指标三控制器对比（对数条形）**
- 内容：r_infeasible / E_phantom / r_{0,-1} 三个指标 ×
  candidate / oracle(DP) / baseline 三组，对数刻度条形。
- 数据源：§4.1 表格数字（0.996 / 1.0 / 7.1e-5 等）。
- 说服点：候选与 oracle 同量级、baseline 低 4–5 个数量级——
  "0.9973 是 exploit parity"的直接证据。

**图 A3 — SOC 轨迹分布（候选 vs baseline 直方图）**
- 内容：candidate（无过滤）与 baseline 的每步 SOC 直方图叠放。
- 说服点：candidate 的 SOC 几乎全压 0（每步放电空），baseline 正常
  分布——exploit 行为在状态层面的体现。

### B. 决策时刻与信息结构（对应 §3.1 / §4.11）

**图 B1 — 决策时刻时间线（step 1 全信息标记）**
- 内容：一条水平时间轴（2014-07-20 00:00 → 2014-07-21 00:30），
  标记：决策时刻（行 t+96 = 07-21 00:00）、信息窗口（行 t+1..t+96）、
  load[1]=当前实际、forecast origin（行 t+1）、settlement（行 t+97 =
  决策+15min）。
- 说服点：决策时刻证明的可视化——当前实际在决策时刻可见、结算在
  下一区间。取代易被误解的"行号表"。

**图 B2 — 论文信息结构 ↔ 数据窗口对齐示意**
- 内容：左侧论文 h_t = (w_t, ..., w_{t-95}) 的框图，右侧映射到
  行 t+1..t+96 的 actual 数组；标注 w_t = 行 t+96。
- 说服点：把 §4.11 的"四方证据之①"画出来。

### C. 物理双轨 leaderboard（对应 §4.9）

**图 C1 — 主指标：相对 S_AR 的加权总成本改善 M₀（柱状）**
- 内容：M₀(R_P) ≈ –7.7、M₀(R_FE96) ≈ –65（相对 S_AR 的
  Σωᵢ[Cᵢ(S_AR)–Cᵢ(π)]，ω=1/70）；S_AR 为 0 基准线，负值条向下。
- 说服点：**直接回答"新控制器是否改进当前最佳基线"**——否，全部为负。
- 标注：S_AR 0 线；"no proposed controller beats the baseline"。

**图 C2 — per-site 成本散点：R_P vs S_AR**
- 内容：70 点散点（x=S_AR cost，y=R_P cost），y=x 对角线，
  上方=baseline 赢，下方=R_P 赢，两区域着色 + 计数（11/70）。
- 说服点：显示"平均输、11 站点赢"的分布结构，比单均值信息量大。

**图 C3 — score 分布小提琴图**
- 内容：S_AR / R_P / R_FE96 的 70 站点 score 分布（小提琴 + 中位数）。
- 说服点：分布形状（R_FE96 尾部拖到负）比均值更能说明差异。

**图 C4 — 成本分解柱状（dummy / LP / S_AR / R_P / R_FE96）**
- 内容：mean cost 柱 + 节省标注（261 / 253 / 196）。
- 说服点：主指标"相对 dummy 的节省"直观；LP 是下界参考。

### D. 风险坐标（对应 §4.9 风险段落）

**图 D1 — 风险二维散点（E[J] × CVaR₀.₉[J]）**
- 内容：三控制器两点图，S_AR 应居左下（最优），R_FE96 右上。
- 说服点：均值-尾部双优的可视化；CVaR 正则无尾部收益。

### E. 统计与敏感性（对应 §4.9 分母 + §4.7 persistence）

**图 E1 — score 分母 D 分布（密度 + 分位数标注）**
- 内容：D = C^d − C^a 的 70 站点密度；标注 min 2.4 / P10 87 /
  median 295；阴影 8 个 D<100 站点。
- 说服点：哪些站点的 score 对微小成本变化敏感——报告忠实性的
  可视化（呼应审查者"分母分布应报告"）。

**图 E2 — persistence 相关散点（δR² vs δS）**
- 内容：70 点散点（x=AR−persistence 的 R² 差，y=R_P−S_AR 的 score
  差），标注 corr = –0.095。
- 说服点：**负证据可视化**——"persistence 越接近 AR 越可能赢"的
  假说无支持，诚实展示。

### F. 边界效应（对应 §4.11 边界 caveat）

**图 F1 — 最后一步成本占比**
- 内容：每控制器最后一步成本占比（1.021 / 1.034 / 1.057%）——
  简单柱或注释性小图。
- 说服点：~1% 的量级直观化，支撑"terminal clamped convention"限定。

### G. 过程叙事（可选，若报告想展示研究旅程）

**图 G1 — 分数演进阶梯**
- 内容：0.9973（exploit）→ 0.579（R_FE96 物理）→ 0.744（R_P）→
  0.768（S_AR），带每个台阶的"性质"标签（exploit parity / physical /
  causal persistence / baseline）。
- 说服点：把"漂亮数字被推翻、物理口径重建"的诚实过程画出来——
  研究叙事本身有价值。

---

## 2. 布局与组织（如何进报告）

- **主图（必进正文）**：A2（exploit 对比）、B1（决策时刻时间线）、
  C1（M₀ 主指标）、C2（per-site 散点）、D1（风险二维）。
- **副图（附录/折叠）**：A1、A3、B2、C3、C4、E1、E2、F1。
- 顺序：A（翻转）→ B（时间语义）→ C（leaderboard）→ D（风险）→
  E/F（敏感性）→ G（可选旅程）。
- 每张图在 typst 中用 `#figure` + 图注引用支撑段落号（如
  "Figure A2 supports §4.2's exploit-parity claim"）。

---

## 3. 工具与可复现性

- 语言：Python（numpy/pandas/matplotlib）或 Julia（Plots/StatsPlots）；
  推荐 **Python + matplotlib**（已有 /tmp/pyenv，与 LP 脚本同栈）。
- 数据源（全部已存在）：
  - `results_sdp/.../score.jld2`（各控制器每步 cost/control/soc）
  - `/tmp/physical_lp_oracle.csv`（70 站点 LP 上界）
  - `results_sdp/dp_upper_bound_v1/scores_full.csv`（dummy）
  - `dataset/train|test/*.csv.gz`（原始数据，B 图用）
- 输出：`visualization_plan/figures/fig_A2.png`（300 dpi，论文规格）。
- 脚本：`visualization_plan/scripts/make_figA2.py` 等，一个脚本一张图，
  顶部注释数据源与对应段落。
- 复现命令：`for f in visualization_plan/scripts/*.py; do python $f; done`。

---

## 4. 优先级（若时间有限）

1. **C1（M₀ 主指标柱）** —— 报告的核心结论图，必须。
2. **A2（exploit 对比对数条）** —— 报告的最大翻转，必须。
3. **B1（决策时刻时间线）** —— 第七版后最重要的新结论，必须。
4. **C2（per-site 散点）** —— 11/70 的分布结构，高价值。
5. **D1（风险二维）** —— 副指标收口。
6. E1/E2/F1 —— 敏感性诚实性图，有余力再做。
7. A1/A3/B2/C3/C4/G1 —— 叙事增强，按需。

---

## 5. 明确不做的图（避免误导）

- **不做** exploit 时代 0.9973 的大字海报图——会被误读为"最优结果"。
- **不做** 单站点的"最优轨迹 vs 实际轨迹"对比（oracle 有 terminal bias，
  逐点对比易被误读为 controller 缺陷）。
- **不做** 无误差棒的均值柱（全部 70 站点，均值是精确值；要画分布就
  用小提琴/散点，不用误差棒假装不确定性）。

---

## 6. v4 前端架构与设计规范（落定）

### 技术栈
- **Astro 5**（纯静态输出，islands）+ **Svelte 5**（图表/交互组件）
  + **TypeScript** + **Vite**（Astro 内置）+ **pnpm** + **ECharts**。
- 环境已确认：Node 26.4.0 / pnpm 11.3.0。
- 数据：Python 预计算 → `public/data/*.json`（大 JSON fetch；小数据
  Astro import 内联，避免 file:// 的 CORS 限制）。

### 目录结构
```
visualization/
  scripts/precompute/*.py      # 8 控制器 × 3 层次数据 → public/data/*.json
  src/
    pages/index.astro, 01..08.astro
    components/
      charts/EChart.svelte     # ECharts 通用封装（option 构建 + resize/dispose）
      charts/BarChart.svelte, LineChart.svelte, ScatterChart.svelte, Heatmap.svelte
      ui/ControllerSelect.svelte, MetricBadge.svelte, TwoTrackNote.svelte
      layout/SiteHeader.astro, SiteFooter.astro
    lib/
      types.ts                 # Controller / Endpoint / PerSite / Process 类型
      palette.ts               # 设计 token（字体/色板/间距/数字格式）
      data.ts                  # JSON 加载（fetch 或 import 内联）
      format.ts                # 数字/货币/百分比格式化（tabular-nums）
    styles/global.css          # 设计 token 的 CSS 变量 + 基础排版
  public/data/*.json
  astro.config.ts, tsconfig.json, package.json, pnpm-lock.yaml
  dist/                        # 构建产物（交付部署）
```

### 设计规范（Helvetica 风格，简约大方）
- **字体**：`Helvetica Neue, Helvetica, Arial, sans-serif`；UI 基准 14px；
  数字 `font-variant-numeric: tabular-nums`（表格对齐）。
- **色板**：近黑 `#1a1a1a`（正文）/ 中性灰 `#f5f5f5`（背景）/
  白（卡片）；**单一强调色** `#1f4e79`（数据主系列）；红 `#b91c1c`
  仅用于负结果/物理违反标记。
- **控制器家族着色**：论文 lookahead（MPC/OLFC/SDP）冷灰蓝系、
  我们的物理控制器（S_AR/R_P/R_FE96）深蓝系、exploit 红系——
  一眼区分"论文方案 / 我们的方案 / 漏洞"，不用彩虹。
- **栅格与形态**：8px 间距基准；圆角 ≤4px；无装饰性阴影/渐变；
  坐标轴细线、刻度克制；图例右上方、标注用最小字号。
- **组件原则**（非 ai-slopware）：组件职责单一、props 全类型化、
  无魔法数字（token 化）、ECharts option 在组件内收敛、数据加载与
  渲染分离。

### 页面（9 页，同 v3）
index / 01_data_forecast / 02_dispatch / 03_exploit / 04_timing /
05_results / 06_per_site / 07_process / 08_sensitivity；
控制器选择器贯穿 02/05/06/07，双口径标注贯穿 05。

---

## 7. 实现完成说明（2026-08-03）

- **数据**：8 控制器（Dummy/MPC/OLFC-10/SDP/SDP-AR(1)/S_AR/R_P/R_FE96）×
  三层次（endpoints/per_site/process）JSON，统一连续 SOC 口径 + 物理 LP
  oracle；accuracy.json（96 horizon 指标 + 覆盖率）。
- **重跑**：MPC（H=96 HiGHS）0.2911、SDP（soc-only VF）0.5764、
  OLFC（H=24/N=10 简化）−1.8010；论文分数（重置 SOC）仅作参考列。
- **前端**：Astro 5 + Svelte 5 + TS + ECharts，9 页，控制器选择贯穿
  02/05/06/07；en/zh JSON 字典 i18n 运行时切换；Helvetica 简约 token。
- **验证**：`pnpm build` 9 页全绿；本地静态服务冒烟 200。
- **git 提交树**（不 push）：a3b3f50 → 832dda5 → 898f0ca → fe5720c →
  ba7ad27 → 32c4e6c → eeed11c。

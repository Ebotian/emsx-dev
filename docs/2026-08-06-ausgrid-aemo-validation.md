# 无人值守一晚计划：Ausgrid + AEMO 双数据集验证与可视化

日期：2026-08-06。目的：无人值守一晚完成两个数据集的获取、算法验证（Mac 算力）、可视化接入。

## 总目标

1. **获取完整两个数据集**：Ausgrid（300 户，✅ 已下载转换）、AEMO（5min，下载中，需完整历史）；
2. **利用 Mac 算力**（`kevin@192.168.10.147`，`~/emsx-experiment`）跑算法验证：S_AR（SDP-AR(1)）与 R_P（persistence rollout）相对 Dummy 的 gain/score；
3. **可视化接入**：每个数据集新开一个子界面，含"逐站点最终结果对比"与"调度-预测曲线"，形式与现有页面平行（可对比）。

## 阶段 0：环境前置检查

- [ ] ssh 连通性：`ssh kevin@192.168.10.147`（免密已配）
- [ ] Mac Julia 环境包：StoOpt / ControlVariables / EMSx（`~/emsx-experiment` 跑过 SDP 脚本，应齐全）——`/opt/homebrew/bin/julia --project=~/emsx-experiment -e 'using StoOpt, ControlVariables'`
- [ ] Mac 磁盘/内存：24GB 内存，10 核——多站点并行用 `--threads` 或 Distributed

## 阶段 1：数据获取与准备

### 1.1 Ausgrid（✅ 已下载，本地 `external_data/ausgrid/`）
- 净需求序列已就绪：`processed/net_demand/<customer>.csv`（300 户，30min，2010-07~2013-07，`timestamp,net_demand_kw`）
- 补：
  - [ ] **train/test 划分**：2010-07-01~2012-06-30 训练、2012-07-01~2013-06-30 测试（2 年/1 年）
  - [ ] **TOU 电价构造**（买/卖价差，参考 2010-2013 新州居民 TOU：峰/谷时段，买价=TOU，卖价=买价×0.6 或固定）
  - [ ] **电池参数**：按户容量（Generator Capacity 列）或统一假设（如 power=5kW, capacity=13.5kWh, eff=0.95）
  - [ ] **导出验证格式**：每户 `train.csv` / `test.csv`（timestamp, z, price_buy, price_sell）+ 电池参数
- [ ] scp 到 Mac：`external_data/ausgrid/` → `~/emsx-experiment/external/ausgrid/`

### 1.2 AEMO（下载中，慢速 13KB/s）
- [ ] **ARCHIVE 每日包**（后台已启动）：`PUBLIC_DISPATCHIS_YYYYMMDD.zip`——验证 5min RRP + TOTALDEMAND 结构
- [ ] **MMSDM 月度逐表包**（历史主力，命名已核实）：
  - `Data_Archive/Wholesale_Electricity/MMSDM/<年>/MMSDM_<年>_<月>/MMSDM_Historical_Data_SQLLoader/DATA/PUBLIC_ARCHIVE%23DISPATCHPRICE%23FILE01%23<年><月>010000.zip`
  - 同路径 `PUBLIC_ARCHIVE%23DEMANDOPERATIONALACTUAL%23FILE01%23...zip`
  - 拉取 **18 个月**（如 2023-01 ~ 2024-06，训练 12 个月 + 测试 6 个月）；可选 `ROOFTOP_PV_ACTUAL`/`FORECAST`
  - 慢速后台逐个下载（限速下 18 个月 × 2 表 ≈ 36 文件，每晚可完成 1-2 年）
- [ ] **转换**：5min 净需求（`OPERATIONAL_DEMAND` 的 TOTALDEMAND 或按区域）+ 5min RRP 电价 → 每区域一个"站点"（NSW/VIC/QLD/SA/TAS），`timestamp, net_demand, price_buy, price_sell`（TOU 价差构造）
- [ ] 若 ARCHIVE 每日包更可行（延迟约 1 周，逐日 4MB），可用每日包拼 6-12 个月；MMSDM 优先
- [ ] scp 到 Mac：`external_data/aemo/` → `~/emsx-experiment/external/aemo/`

## 阶段 2：算法验证（Mac 上跑）

### 2.1 验证驱动脚本（新写，参数化 horizon）
位置：`~/emsx-experiment/external/run_validation.jl`（Mac），源码本地 `scripts/` 或 `experiments/external/`

核心逻辑（复用 wdwe2 的 SDP-AR(1) 模式，但参数化）：
- [ ] `fit_ar1(dataset, n_slots_per_day)`：weekday/weekend × n_slots 分组 OLS + 确定性 1D DP 量化（K=20）
  - Ausgrid：n_slots=48（30min）；AEMO：n_slots=288（5min）
- [ ] `build_sdp(horizon, dx, du, nz, noises, cost, dyn)`：StoOpt 周期平均成本 VI（`compute_periodic_value_functions` 模式，已实测 horizon=2016 可行）
- [ ] **回放（自定义，绕过 EMSx 15min 模拟器）**：通用步长回放——`soc_{t+1} = soc_t + (η_c max(0,u) − max(0,−u)/η_d) × power × dt / capacity`；成本 = `buy·max(0, z+u·P·dt) − sell·max(0, −(z+u·P·dt))`
- [ ] 控制器：**S_AR**（SDP 价值函数 + 一步 AR(1) 状态）、**R_P**（persistence rollout：用当前实际 z 作一步预测的贪心/价值回放）、**Dummy**（u=0）
- [ ] 输出：每站点/区域 `cost, gain(=dummy−model), score(=(dummy−model)/(dummy−anticipative))`——anticipative 用完美预见下界（小规模 LP 或简化：SOC 无约束的理想套利上界；若实现复杂可省略 score 只给 gain）
- [ ] 并行：Ausgrid 300 户 `--threads=10` 或 Distributed；AEMO 5 区域直接跑
- [ ] 同时产出**调度-预测曲线数据**：每站点窗口（如测试期第 1-2 天）的 `actual z / AR(1) 一步预测 / persistence`（对标 `forecast_curves.json` 格式）

### 2.2 执行
- [ ] Ausgrid：先 10 户冒烟（结构/数值 sanity）→ 300 户全量
- [ ] AEMO：5 区域全量
- [ ] 结果回传本地：`external_data/{ausgrid,aemo}/results/`（per-site json + curves json）

## 阶段 3：可视化接入（本地）

### 3.1 预计算 JSON（对标现有格式）
- [ ] `visualization/public/data/ausgrid/per_site_gain.json`：`[{site, rmse?, dummy_cost, gains: {S_AR, R_P, Dummy}}]`（对标 `site_gain.json`）
- [ ] `visualization/public/data/ausgrid/curves.json`：`{sites: [{site, actual[], ar1[], se?[]}]}`（对标 `forecast_curves.json`；AEMO 若有 forecast 可加 se）
- [ ] 同结构 `aemo/` 两份
- [ ] 注意：AEMO 是区域级（5 个"站点"）——曲线浏览器站点数少，直接适配

### 3.2 前端新页面
- [ ] 导航加两项（如 "Ausgrid"、"AEMO"）
- [ ] `visualization/src/pages/09_ausgrid.astro`、`10_aemo.astro`（或复用模板）
- [ ] **组件复用/参数化**（最小改动）：
  - 逐站点最终结果对比：参数化 `PerSiteGainChart`（数据路径 + 标题 + LP 上界可选）或复制适配（无物理 oracle 时 LP 线隐藏）
  - 调度-预测曲线：参数化 `ForecastCurveBrowser`（数据路径 + 站点列表 + 默认展示）
- [ ] i18n 双语（en/zh）：新页面标题、说明
- [ ] 视觉/交互与现有一致（palette、下拉切换、排序、tooltip）

### 3.3 验证
- [ ] `cd visualization && pnpm build` 退出 0
- [ ] 网桥目检两个新页面：渲染非空、站点切换/排序交互、i18n
- [ ] 数值 sanity：S_AR gain > 0（相对 dummy 有改进）、R_P 接近 S_AR

## 阶段 4：git 提交

- [ ] 数据获取脚本与转换（`external_data/` 不入库？——净需求 CSV 大——**只提交脚本与结果 JSON**，原始数据 gitignore 或留本地）
- [ ] 验证脚本（`scripts/` 或 `experiments/external/`）
- [ ] 可视化改动（页面/组件/i18n/JSON）
- [ ] 多个逻辑提交

## 风险与停止规则

- **AEMO 下载慢**（13KB/s 限速）：MMSDM 18 个月是理想目标；**下限 = 6 个月**（训练 4 + 测试 2）；不足则记录、用已有数据验证；ARCHIVE 每日包作补充
- **5min 回放实现复杂**：优先 Ausgrid（48 时段）完整跑通；AEMO 若回放受阻，退化为"48 时段重采样"或记录阻塞
- **Mac 环境缺包**：记录缺失，改用本地 Julia 跑（慢但可行）
- **anticipative 上界复杂**：可省略 score，只用 gain 对比（gain 已足够体现"相对 dummy 的预测优化效果"）
- **任何阶段失败**：记录原因，继续其他阶段，最终汇总报告（哪些完成/哪些阻塞/下一步）
- 无人值守不执行：git push、删除数据、修改主项目实验脚本（新脚本独立文件）

## 输出物清单

1. `external_data/ausgrid/`（净需求 + train/test + 电价 + 电池）+ `external_data/aemo/`（5min 数据 + 转换）
2. `external_data/{ausgrid,aemo}/results/`（per-site gain/score + curves）
3. 验证脚本（可复现）
4. 可视化 2 个新页面（平行于现有 06/01 页）
5. git 提交树 + 最终报告（完成/阻塞/下一步）

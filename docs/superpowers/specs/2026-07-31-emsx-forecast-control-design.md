# EMSx 可复现预测控制实验设计

## 1. 目标

在不改变 EMSx 官方数据划分、成本函数和 score 定义的前提下，建立仅依赖工作区源码和锁定依赖的实验环境，完成 A3V2 时间对齐诊断、实时 forecast rollout、forecast-error 建模、forecast MPC + SDP terminal bias，并在训练期内部验证上筛选后续高级方法。

最终确认性候选必须在相同 EMSx 版本的 70 站点官方评价上同时满足：

1. mean official score 严格大于 `0.8`；
2. mean score 的单侧 95% 站点级 bootstrap 下置信界严格大于 `0.794`；
3. 相对本地复现 `wdwe2_k20` 的逐站点 paired score 改善，其单侧 95% bootstrap 下置信界严格大于 0。

统计使用至少 10,000 次固定种子重采样。不能达到统计终点时，保留最佳可复现结果并如实报告，不能通过改变评价口径宣称完成。

## 2. 已确认的现状

当前实验是混合环境：

- 根目录没有 `Project.toml` 或 `Manifest.toml`；
- `using EMSx` 实际加载 `/home/ebt/.julia/packages/EMSx/rkBSw`；
- StoOpt、ControlVariables、JLD2 等来自全局 Julia 1.12 环境；
- SDP helper 又通过 `include` 加载工作区 `EMSx.jl/examples/sdp/*.jl`；
- 全局 EMSx package cache 相对 upstream tree 有三项未记录修改：CSV 0.10 compat、`Result.control` schema/旧 JLD2 compatibility、simulation control recording；
- 工作区 `EMSx.jl/examples/sdp/function.jl` 另有 noise layout 和概率归一化的未提交修改；
- 全局和工作区 clean HEAD 对应同一个 upstream tree，不存在上游版本差异；
- 现有 `wdwe2_k20` 的 70 站点 mean score 精确为 `0.7676755785921663`；
- 当前 A3V2 的 forecast 来自 96 步历史窗口最旧行的第一个 horizon，目标比当前计费点约早 95 步。

因此第一阶段必须重建并锁定实际运行环境，不能直接在当前全局环境上继续叠加算法。

## 3. 架构选择

### 3.1 候选方案

1. **根目录 application Project + committed Manifest**：覆盖所有根实验依赖，命令统一，适合记录实验环境。
2. **专用 `experiments/` Project**：隔离更强，但当前只有一套实验应用，增加路径和维护复杂度。
3. **直接激活 `EMSx.jl` Project**：会把 StoOpt、Clustering、MPC solver 等应用依赖混入库包依赖，而且当前会回退到全局环境。

采用方案 1。根目录是实验应用层，嵌套 `EMSx.jl` 保持独立 package 仓库。

### 3.2 环境结构

根目录新增并提交：

- `Project.toml`：声明实验直接依赖；
- `Manifest.toml`：锁定 Julia 1.12.6 下的完整依赖图；
- 本地 EMSx path dependency，由 `Pkg.develop(path="EMSx.jl")` 写入 Manifest；
- 环境身份检查脚本，验证主进程和 workers 的 `pathof(EMSx)` 均位于工作区；
- 数据、源码、依赖和运行参数 provenance 工具。

根 `.gitignore` 必须允许根 `Manifest.toml` 被跟踪。工作区 EMSx 的 package Project 不承担实验依赖，也不要求自己的 Manifest。

根 Project 首批直接依赖为 EMSx、StoOpt、ControlVariables、JLD2、CSV、DataFrames、Clustering、ProgressMeter 和 Interpolations；Julia 标准库按 Project 规范声明。MPC 阶段再加入 JuMP 和 HiGHS。HiGHS 优先于旧示例中的 Clp，因为它具有当前 Julia/JuMP 支持并适合线性、分段线性电池调度模型。

所有正式命令使用：

```bash
julia --startup-file=no --history-file=no --project=. <script>
```

不能通过 `LOAD_PATH` 或后续 `Pkg.activate` 隐式修正已经加载的包。

## 4. 双仓库与修改迁移

嵌套 `EMSx.jl` 是独立 Git 仓库，不是外层 submodule。为保持最小改动，本轮不先转换为 submodule，而使用双仓库 SHA 约束：

1. 将全局 package cache 中确属当前实验所需的 CSV compat、`Result.control`、旧 JLD2 compatibility 和 simulation control recording 重建到本地 EMSx；
2. 为 schema、旧结果加载和 control recording 添加测试；
3. 将现有 `examples/sdp/function.jl` 修改保持为独立变更，不与 schema 迁移混合；
4. 每次 EMSx 行为变化先准备嵌套仓库提交，再准备外层环境/实验提交；
5. 外层 provenance 记录嵌套 EMSx commit SHA，并在运行前验证 HEAD 与 dirty 状态。

不得编辑全局 package cache。不得覆盖、回退或擅自提交审计前已经存在的工作区修改。每个 Git commit 执行前单独请求用户确认，不 push。

## 5. 可复现性与产物隔离

### 5.1 基线身份

锁定并记录：

- Julia 版本、Manifest hash、外层和 EMSx commit SHA；
- `Base.active_project()`、主进程和 worker 的 `pathof(EMSx)`；
- CPU、BLAS vendor、线程数、worker 数；
- 140 个 train/test split 文件、metadata、dummy 和 anticipative baseline 的 SHA-256；
- `DX`、`DU`、`K_NOISE`、`MARGIN`、`NZ`、随机种子和 controller 标识；
- value-function 文件清单、shape 和 hash。

基线断言为：

```julia
isapprox(mean_score, 0.7676755785921663; atol=1e-6, rtol=0)
```

同时逐站比较 70 个 score，避免均值误差抵消。

### 5.2 分离三阶段

现有脚本无条件执行 calibration、simulation、evaluation，设计上拆成可独立选择的 phase：

- `calibrate`：只写新的 value-function 目录；
- `simulate`：只读指定 value-function source，写唯一 run 目录；
- `evaluate`：只读 simulation 结果并生成统计产物。

核心路径分离为：

```text
VALUE_FUNCTION_SOURCE_DIR  # 只读
RUN_OUTPUT_DIR             # 唯一、可写、运行前必须不存在
```

每个正式候选使用独立 TAG 和 run id。运行前检查目标目录不存在，不能原地覆盖旧 `score.jld2` 或 value functions。中断产物标为 incomplete，evaluation 不读取 incomplete run。

每个 run 保存机器可读 provenance，包括参数、源码和数据 hash、开始/结束时间、phase 完整性、输入 VF manifest 和输出文件清单。

## 6. Forecast 语义

### 6.1 明确定义

对签发时刻 `t`：

```text
forecast_load[k] 预测 t+k 的 load，k=1..96
forecast_pv[k]   预测 t+k 的 pv，k=1..96
```

当前控制 `u_t` 的 stage cost 使用 `t+1` 的实际净需求，因此实时一步 baseline 必须是：

```text
b_t = forecast_load[1] - forecast_pv[1]
```

但 forecast vector 必须来自最新可见的签发行 `t`，不能来自 96 步历史窗口最旧行。

### 6.2 两个严格分开的实验

1. **align96 反事实**：保持 legacy Information 和所有其他 A3V2 逻辑不变，仅将旧签发行 forecast index 从 `[1]` 改为 `[96]`。该实验只验证目标时间错位的因果影响，不宣称使用实时 forecast。
2. **实时 forecast**：修正本地 EMSx `Information`，使 forecast vector 来自最新可见行；此时 `[1]` 才对应当前控制后的计费点。

align96 可以复用 `wdwe2_k20` value functions。实时接口修正后，所有使用 forecast 的新候选必须通过时间语义测试。

### 6.3 回归测试

在 `EMSx.jl/test/information.jl` 使用完全 synthetic DataFrame；每个 forecast cell 编码 origin row 和 horizon index，从而直接断言：

- history 从最新到最旧排列；
- 实时 forecast origin 是最新可见行；
- forecast `[1]` 的 target 与 `apply_control` 的实际计费 row 一致；
- legacy align96 的 index 与目标一致；
- period 末端不越界。

测试不能依赖 Schneider API、6.2 GiB 数据集或网络。现有下载型 test suite 与该离线单元测试分开运行。

## 7. Forecast error 与一步 rollout

### 7.1 误差定义

训练数据上的 horizon-specific error 定义为：

```text
e[t,k] = actual_net[t+k] - forecast_net_issued_at_t[k]
```

一步 rollout 使用 `e[t,1]`。初始模型按 quarter-of-day 和 weekday/weekend 分组，采用与基线一致的有限离散 quantization，并在样本不足时向全局分布 shrink。是否加入当前 residual、天气代理或 forecast level 条件，只能由训练期阻塞验证决定。

必须报告 RMSE、bias、分位覆盖和尾部误差；不能把 AR(1) innovation 直接重命名为 forecast error。

### 7.2 正确的一步目标

`wdwe2` bias function 的状态是 `[soc,z]`。因此 forecast rollout 对每个候选控制计算：

```text
z_next = b_t + e
objective = stage_cost(u, z_next)
          + h[t+1](soc_next, z_next)
```

stage cost 和 continuation value 必须使用同一个预测实际量 `z_next`。不能在 stage cost 中使用 `b_t + noise`，同时在 continuation dynamics 中使用 `alpha*z + beta + noise`。

align96 反事实为了保持单变量实验，暂不修正这一语义；正确实时 rollout 单独修正并评价。

## 8. Forecast MPC + SDP terminal bias

### 8.1 基础模型

每个控制时刻读取最新 forecast path `t+1:t+H`，优化电池 SOC、charge/discharge 和 grid exchange。使用 EMSx 官方约束和 stage cost，第一控制实施后滚动重算。

先实现确定性 forecast MPC，再加入 forecast-error scenarios。随机版本采用第一步控制非预见约束；后续控制可选择 open-loop 序列或小型 scenario tree，二者必须作为不同候选报告。

### 8.2 Terminal value

终端项使用已验证的 `wdwe2` periodic bias/value function：

```text
h[(t+H) mod 672](soc_H, z_H)
```

时间 slice、SOC/z grid 和插值规则必须显式验证。对 scenario MPC，terminal value 对 scenario endpoint 求期望。value function 的加法常数及序列化来源写入 provenance。

### 8.3 求解与规模控制

JuMP + HiGHS 模型在每个 worker 内复用，更新 forecast、价格和初始 SOC 参数，避免每个 15 分钟点重新构建完整模型。允许 warm start，并记录 solve status、迭代次数和耗时。

开发顺序：

1. synthetic 和单 period 正确性；
2. 一个站点的训练期 validation；
3. 分层站点 validation；
4. 锁定候选后运行官方 70 站点。

固定评估 `H ∈ {4,8,16,32}`，每个 horizon 都必须完成官方 70 站点评价。正式运行前先在 validation 上测量吞吐量并优化模型复用；若资源形成持续阻塞，则按停止规则保存证据并报告，不能静默缩小官方评价样本。

## 9. 高级方法探索顺序

基础 rollout/MPC 未满足统计终点时，按证据和复杂度逐层推进：

1. phase/level-conditioned forecast-error calibration；
2. scenario MPC、风险敏感和分布鲁棒 MPC；
3. 低维 forecast curve features 与 fitted terminal correction；
4. fitted value iteration 或参数化 policy improvement；
5. 有严格离线验证和安全约束的 offline RL。

每个算法族先形成单一可证伪假设，只在训练期内部 validation 调参。连续三个最小实验否定同一假设时停止堆补丁；一个算法族无效后记录并转向下一有理论依据的算法族。

互联网和文献检索产出来源、适用假设、实现复杂度和与 EMSx 约束的对应关系。不能因方法新颖而跳过较简单的对照。

## 10. 防止测试泄漏

训练期构建时间阻塞 validation，并按站点规模分层。模型选择、horizon、scenario 数、风险参数和超参数只根据训练/validation 结果决定。

正式候选在官方测试前写入不可变 candidate specification，包括：

- 代码和环境 SHA；
- 全部参数与随机种子；
- 训练/validation 选择依据；
- 预期输出和失败判据。

官方测试用于里程碑确认。测试失败后的新候选必须有来自训练期诊断的新假设，不能只因测试 score 低而搜索参数。

## 11. 正交评价与统计

### 11.1 主指标子空间

唯一决定硬终点的主指标是 70 站点官方 EMSx score。最终候选需同时满足：

```text
mean(score_candidate) > 0.8
one_sided_95_LCB(mean(score_candidate)) > 0.794
one_sided_95_LCB(mean(score_candidate - score_wdwe2)) > 0
```

bootstrap 以站点为 cluster，至少 10,000 次，使用固定种子并保存 70 个站点输入。paired comparison 每次对候选和基线使用相同站点索引重采样。

### 11.2 独立辅助子空间

独立报告：

- raw cost 和 gain；
- score mean、median、最低十分位、逐站点差值和改善站点数；
- 按负荷规模和站点类型分层的稳健性；
- forecast RMSE、bias、分位覆盖和 calibration；
- action saturation、SOC boundary occupancy、clamp rate；
- calibration/simulation/solve 时间、内存和失败率。

辅助指标不能与 score 任意加权以规避主终点。

## 12. 错误处理和运行恢复

- 环境、源码、数据或 VF provenance 不匹配时 fail closed；
- solver 非 optimal、数值异常、NaN 或越界时记录 site/period/time，不返回未经标记的控制；
- 单站点失败不能生成 complete score；
- background run 保留完整日志和 machine-readable status；
- 重启只处理未完成站点，已完成站点必须通过 hash 后复用；
- evaluation 必须验证 70 个唯一站点和候选/baseline 站点集合完全相同。

## 13. 测试层次

1. **环境测试**：主进程/worker package path、Manifest、EMSx SHA、数据 hash。
2. **单元测试**：Information 对齐、forecast error、SOC transition、stage cost、terminal slice、bootstrap。
3. **小型集成测试**：synthetic period 和一个真实训练期 validation period。
4. **回归测试**：70 站点 `wdwe2_k20` mean 和逐站 score。
5. **候选完整性测试**：70 sites、独立 TAG、provenance、无旧结果覆盖。
6. **确认性统计**：固定脚本复算三项硬终点。

## 14. 实施阶段与提交边界

建议按以下边界准备提交；每次实际 commit 前单独请求确认：

1. 本地 EMSx schema/CSV/control 行为重建及测试；
2. 现有 noise layout 修改的独立测试和提交；
3. 根 Project/Manifest、身份检查和 provenance；
4. phase 分离与安全结果目录；
5. 本地基线复现；
6. align96 单变量实验；
7. 实时 Information 语义和测试；
8. forecast-error 与正确一步 rollout；
9. MPC + terminal bias；
10. 统计与正交评价；
11. 后续每个高级算法族独立提交。

不执行 push。正式实验结果使用独立 TAG 和不可覆盖目录，Git 只跟踪代码、配置、hash inventory 和紧凑统计，不跟踪大体积原始数据及 value-function 二进制。

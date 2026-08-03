# EMSx online-rollout: Lean 形式化验证报告（因果+物理审计版）

日期：2026-08-02（第三轮审计完成）
环境：Lean 4.32.2 / mathlib v4.33.0-rc1，`/home/ebt/Downloads/emsx/leanproof`
结果：`lake build` 全绿，定理全部闭合（**无 sorry / axiom / admit**）

---

## 〇、结论先行

**此前报告的 mean score = 0.997348 是环境（EMSx 模拟器）物理漏洞的利用
指标，不是控制质量指标。** 第五版审查后确认：**决策时刻 = 行 t+96**
（代码+论文+数据证明），所有控制器（S_AR / R_P / R_FE96）均为因果。
物理一致口径下 S_AR（baseline）= 0.768 最强，R_P = 0.744 是最强非基线
rollout，baseline 仍胜出。

## 一、索引审计（已完成，时间戳实证）

**A. forecast origin 恢复（interface violation，非时间泄漏）**
原版 EMSx `Information` 构造的 forecast 取自决策窗口 `t+1:t+96` 中时间
最早的行（`data[end]` = 行 `t+1`）；此前一次本地修改改为行 `t+96`。
第六版审查后明确三概念区分：

- **时间因果性**：按决策时刻 = 行 t+96（四·补7 证明），行 t+96 forecast
  的发布时间 = 决策时刻，**满足 t_issue ≤ t_decision，非时间泄漏**。
- **Information API 许可**：官方构造器仅暴露行 t+1 的 forecast
  （`data[end,...]`），行 t+96 forecast 不在 Information 对象内——读取它
  需绕过接口，属 **benchmark interface violation**。
- **官方协议**：接口即协议信息集。

已恢复接口暴露的行 t+1 forecast（显式 timestamp 排序），时间戳测试
13/13 锁定；"96 步泄漏"表述废弃，改为"恢复官方接口暴露的 forecast
origin"。行 t+96（决策时刻）最新一步 forecast 是否存在于原始数据、
其价值如何，属未测试的开放问题（audit 记录，未评估）。
13/13 锁定。

**B. 结算行对齐（index 96 = 结算对齐索引）**
`apply_control` 在行 `t+96+1`（=`t+97`）结算第 t 步；行 `t+1` 的
`load_k` 预测行 `t+k+1`，故 index 96（`load_95`）预测结算行 `t+97`，
index 1（`load_00`）预测行 `t+2`（差 95 步）。时间戳 trace（站点 1，
t=1）：决策=行 1 (2014-07-20 00:00)；窗口=行 2..97；origin=行 2
(00:15)；`load[1]`=行 97 的 actual（次日 00:00）；`forecast[1]` 目标
00:30；`forecast[96]` 目标 = 2014-07-21 00:15 = **结算行 row 98**。

**C. 决策时刻悖论消解**
- forecast 提前一期可用（行 t+1 的 forecast 在决策 t 时可见）是原版
  benchmark 的固有约定（原版 MPC/SDP 同样依赖该信息结构）。
- **candidate 只读 forecast 数组与 SOC，从不读 future actual**；
  **baseline (wdwe2_k20) 的 z_t = load[1]-pv[1] = 行 t+96 的 future
  actual（24h 后）**。信息使用上 candidate 比 baseline 更保守。

## 二、环境物理漏洞（能量不守恒）量化

`compute_stage_cost` 对空电池放电计全额电费信用（SOC 仅被 clamp 为 0）；
实证：SOC=0、u=-1 时账单每步降 2.44，SOC 不变。三个控制器在 70 站点：

| 指标 | candidate（无约束） | oracle（DP） | baseline |
|---|---|---|---|
| mean r_infeasible（越界放电率） | 0.996337 | **1.0** | 7.1e-5 |
| mean E_phantom（虚构能量 kWh/期） | 26023 | 168–25200 | 1.2 |
| mean r_{0,-1}（空电池满功率放电率） | 0.99624 | **1.0** | 8.0e-6 |

candidate 与 oracle 几乎每一步都在从空电池满功率放电；baseline 物理干净。
物理版 candidate（U(SOC) 过滤）r_infeasible 降至 5.2e-5，虚构能量降
1200 倍。

## 三、双轨评估结果（70 站点，同一数据与误差律）

**轨道 1：环境一致**（oracle = 后向 DP，共享环境松驰物理；candidate 无约束）
- mean score = 0.997348；LCB = 0.995720；paired LCB = 0.917831；
  min = 0.954600；55/70 站点 score≈1；70/70 胜 baseline。
- 解读：衡量 candidate 复现完美预测 **exploit**（有电价空间就空电池放电）
  的程度，非物理控制质量。

**轨道 2：物理一致**（oracle = 独立 LP，SOC∈[0,1]；candidate 限 U(SOC)）
- candidate mean score = **0.579397**（cost 2300.8）
- baseline wdwe2_k20 mean score = **0.7677**（cost 2235.7，dummy 2496.7）
- paired = **−0.1883**（baseline 胜）；candidate LCB = 0.5327。
- 物理口径下 candidate 不如 baseline：其价值函数在松驰动态下训练，受限后
  决策变差（4 站点甚至低于 dummy）。

**轨道 2 的 index 对比（3 站点，物理口径）**
| 站点 | index-1 物理 | index-96 物理 |
|---|---|---|
| 1 | 0.1148 | −0.2925 |
| 2 | 0.0648 | −0.2769 |
| 3 | 0.2391 | 0.2384 |

环境一致轨道中 index-96 的巨大优势（0.80→1.00）在物理约束下消失
（2/3 站点更差）：该优势是 phantom 放电的计时能力。

## 四、Lean 定理与边界

文件：`Leanproof/Reliability.lean`（`import Mathlib`，构建全绿）

1. `score_mem_Icc`：若 m≥a、0≤d−m、0<d−a，则 score∈[0,1]。**条件命题**，
   不声称因果控制器必然满足 m≥a。
2. `resample_mean_ge_min'`：重采样均值 ≥ 站点最小值（关于已观测 70 站点
   的代数事实，非总体/未来推断）。
3. `paired_resample_mean_ge_min'`：70/70 胜 + min_pair>0 ⟹ paired LCB>0
   （仅环境一致轨道成立；物理轨道 baseline 平均胜出）。
4. `dpValue_lower_bound'`：可达成本集合的 infimum 是任意控制序列总成本的
   下界（前提：集合有下界）。不连接任何 oracle 的数值实现与其数学定义。

## 四·补、价值函数重训为何无效（机制发现）

**关键机制**：exploit 只发生在 online，不在价值函数。
- offline 价值迭代已有 `state_in_bounds` 检查：校准动态**不 clamp SOC**，
  空电池放电使 next SOC < 0 出界 → 该动作 cost=Inf → 被排除。**VF 本就
  能量守恒**。
- online `select_rollout_control` 用 `compute_stage_dynamics`（**clamp 到
  [0,1]**）算 next SOC 后再做 bounds 检查 → 空电池放电蒙混过关 → 账单获
  全额信用。这就是 r_infeasible=0.996 的来源。
- 实证：physical_vf 校准（3 站点）产生与旧 VF **逐位相同**的 VF
  （max|Δ|=0）——注入冗余，合理解释成立。
- 正确的修复是 online 的 u_lo/u_hi 物理过滤（已加入
  `select_rollout_control`），把 r_infeasible 降到 5.2e-5。

## 四·补2、物理口径 index 对比（70 站点）

| 配置 | 物理 score |
|---|---|
| SDP-AR(1) baseline | 0.7677 |
| rollout index-96 + h96 律（物理过滤） | **0.5794** |
| rollout index-1 + h1 律（物理过滤） | 0.4849 |

物理约束下结算对齐仍有价值（z_next 与 VF 的 z 坐标一致）。两种 rollout
均不及 baseline：SDP 用完整 AR(1) 结构化 VF，一步场景 rollout 是同一
（已物理）VF 下更弱的选择器。

## 四·补3、提高路径：baseline 对齐状态 + 物理过滤（Plan A）

把 rollout 的 z 状态从 forecast 换成 **baseline 同款的行 t+96 actual**
（`load[1]-pv[1]`），保留物理过滤。这是物理诚实、且与 baseline 使用
相同信息的控制器：

| 配置 | 3 站点 | 70 站点 |
|---|---|---|
| SDP-AR(1) baseline | 0.5526 | 0.7677 |
| **Plan A：actual 状态 + 物理过滤** | **0.646** | **0.7442**（11/70 反超，无负分） |
| AR 推进版（noise=0） | 0.533 | — |
| forecast 状态版 | −0.11 | 0.5794 |

- 高分辨率 VF（dx=du=0.05）无提升 → 网格不是瓶颈。
- AR 一步推进反而更差（注入模型误差）→ 行 t+96 actual 直接查询最优。
- 剩余差距（0.744 vs 0.768）来自单场景选择器 vs baseline 对 AR 噪声
  分布的期望。

## 四·补4、SDP 选择器 + 物理过滤（最终对照）

把 Plan A 的贪心换成 baseline 同款 `StoOpt.compute_control`（AR 噪声
分布期望）+ 物理过滤：

- 3 站点：与 baseline **逐位相同**（0.6294/0.5797/0.4485）
- 70 站点：**0.7677 == baseline**（per-site max|Δ|=0）

物理过滤对 baseline 从不触发（其 r_infeasible=7e-5）——baseline 本就
物理干净。"baseline + 物理过滤" = baseline。Plan A 贪心在 3 站点更强
（0.646 vs 0.553）——状态已实现时单场景优于噪声期望；baseline 的全量
优势来自其他站点。

**物理口径最终排名**：baseline/SDP+phys = 0.7677 > Plan A = 0.7442
（11/70 反超）> forecast 版 = 0.5794。baseline 是该问题的最优 SDP 实现，
物理过滤对它无增益；Plan A 是最强的诚实变体。

## 四·补5、行为克隆 LP oracle（机器学习路径，负结果）

用物理 LP 的最优轨迹作监督，per-site MLP（特征：SOC、行 t+96 actual、
日内/周内时间、价格）→ u，评估时物理投影：

| 配置 | 70 站点物理 score |
|---|---|
| 3 站点合训回归（30 periods） | 0.664（仅站点 1-3） |
| per-site 回归（24 periods） | 0.5731 |
| 单网络共享（70 站点） | 0.4815 |
| per-site 分类（5 档） | 0.3069 |

负结果原因：LP 最优 u 是 bang-bang 型（43% 在 ±1 边界、47% 在 0），
且最优解有平坦区，单步回归/分类学不到该结构。行为克隆不如模型类
控制器。

## 四·补6、物理口径排行榜（70 站点，主指标 = raw cost 节省）

主指标 = 相对 dummy（均值 2496.7）的原始成本节省；归一化 score 为副指标。
physical score 分母 D_i = dummy − LP：min 2.4、P10 87、median 295、max 863
（8 站点 D<100，4 站点 D<50，这些站点 score 对成本极敏感）。

| 控制器 | score | mean cost | 节省 |
|---|---|---|---|
| SDP-AR(1) baseline（L2） | 0.7677 | 2235.7 | 261.0 |
| Plan A（L2 贪心 + 物理过滤） | 0.7442 | 2243.4 | 253.3 |
| SDP 选择器 + 物理过滤（L2） | 0.7677 | 2235.7 | 261.0 |
| causal baseline（L1 forecast + sdp + 物理过滤） | 0.5689 | 2309.9 | 186.8 |
| causal Plan A = forecast rollout（L1） | 0.5794 | 2300.8 | 195.9 |
| 行为克隆（per-site MLP，修复 SOC 特征后） | 0.5731 | — | — |

L2（lookahead）下 baseline 领先；L1（causal）下贪心 forecast rollout
略胜 SDP 选择器。causal 控制器远低于 L2——量化了 benchmark future-actual
状态的价值。

## 四·补7、决策时刻证明（第五版审查核心）

**t_decision = 行 t+96 的时间戳**（对 step 1：2014-07-21 00:00）。四方证据：

1. **论文信息结构**：论文定义决策在区间 [t,t+1[ 开始，信息 = 部分观测
   (w_t, ..., w_{t-95})（当前 + 过去 95 步）。Information(t) 暴露 96 个
   actual（行 t+1..t+96），映射 w_{t-95}..w_t 仅当 w_t = 行 t+96 actual；
   若 t_decision = 行 t 则窗口是 96 个未来值，与论文矛盾。
2. **apply_control**：结算行 t+97 = 决策后 15 分钟（下一区间，正常闭环
   语义）；若决策 = 行 t 则结算在 24h15min 后，无物理意义。
3. **原版 SDP**：z_t = load[1]-pv[1] 作为当前净需求，load[1] = 行 t+96
   actual——仅 t_decision=行 t+96 时是当前观测。
4. **horizon = nrow-96**：最后决策落在最后一行，一致。

运行时断言（step 1）：行 t+96 actual ≤ 决策时刻 ✓；行 t+1 forecast（95
步前发布）≤ 决策时刻 ✓；结算行 t+97 = 决策 + 15min ✓。

**结论：load[1]（行 t+96）是当前观测 w_t（因果）；行 t+1 forecast 是已
发布的 day-ahead（因果）。baseline / R_P / R_FE96 全部是因果控制器。
之前 L1/L2/lookahead 分类错误，无 lookahead 象限；四象限收敛为单一
"因果 + physical"部署象限。** 此前"causal baseline 0.569"实为状态语义
错位实验（把结算行 forecast 喂给 z 语义为当前实际的 VF），非信息层次
差异。

## 四·补7b、命名统一（第五版审查项）

- **S_AR**：原随机 SDP 选择器（baseline），状态 = 当前实际 z_t = load[1]-pv[1]
- **R_P**：actual-state persistence rollout（原 Plan A），单场景 z = 当前实际 + 物理过滤
- **R_FE96**：多场景 forecast-error rollout，baseline b_t = 结算行 day-ahead forecast + 物理过滤

排行榜（全因果 + physical，严格投影零违规，raw cost 主指标）：

| 控制器 | score | mean cost | 节省 |
|---|---|---|---|
| S_AR | 0.7677 | 2235.7 | 261.0 |
| R_P（严格投影，r_infeasible=0） | 0.7442 | 2243.4 | 253.3 |
| R_FE96 | 0.5794 | 2300.8 | 195.9 |
| S_AR w/ forecast 状态 | 0.5689 | 2309.9 | 186.8 |
| 行为克隆（per-site MLP） | 0.5731 | — | — |

风险二维（按 period 池化，n=2474）：S_AR E[J]=1208.9 / CVaR_0.9=15920.3；
R_P 1216.9 / 15928.2；R_FE96 1273.4 / 15968.8——S_AR 均值-尾部双优。
persistence 归因检验：corr(δR², δS) = -0.095（70 站点）——无经验支持，
选择器结构解释降级为猜想。

## 四·补8、本轮新增审计（第四版审查）

1. **LP 动作回放**：LP 的 u 轨迹送入同一物理模拟器，
   |J_LP − J_replay| ≤ 4.2e-11，max|SOC_LP − SOC_replay| ≤ 3.1e-16——
   价格/效率/单位/索引完全一致。
2. **offset 消融**：Plan A 查询 slice τ−1/τ/τ+1 → 3 站点 0.6457/0.6452/0.6458
   （差异 <0.001）——一行偏移未造成主要损失（全站点消融未跑）。
3. **persistence 解释**：Plan A 单场景 = persistence 模型
   （ẑ_{t+1|t}=z_t）；train 数据 R²：persistence 0.937 vs AR(1) 0.948——
   AR 期望优势有限，故单场景有竞争力。修正"状态已实现"的过度解释。
4. **r_infeasible 容差**：物理过滤用 1e-9 松弛，残余 5.2e-5 是数值容差
   （最大越界 ~1e-12）；统一投影可归零。
5. **无下界 LP 措辞**：与 clamp 环境"数值一致"而非"语义等价"（clamp 使
   SOC 停 0，无下界 LP 允许负 SOC；exploit 策略使成本对 SOC 不敏感）。
6. **ML 数据划分**：oracle 标签来自 train 时段 LP（24 periods/站点），
   训练于 train、评估于同站点 test（时段隔离无泄漏）；特征含行 t+96
   actual → L2 lookahead 策略。负结论限定为"当前特征/损失/划分下单步
   BC 未超过模型控制器"。
7. **OpenEvolve**：明确为 exploratory evaluation（3 站点 fitness 集是
   70 站点报告集的子集）。
8. **确定性**：error law 用固定 k/pseudocount 的加权分位数（无随机初始
   化），相同输入产生相同 law；缓存记录 per-site SHA-256。
9. **VF physics 统一**：删除"VF 在松驰动态训练需重训"表述（§4.5 证明
   VF 已物理）；差距归因于选择器结构与状态语义。

## 四·补9、第五版审查项闭环

1. **决策时刻证明**（见四·补7）：t_decision = 行 t+96，全部控制器因果。
2. **L1 不再称 causal**：删除 L1/L2 分类，无 lookahead 象限；"causal
   baseline"实验重解读为状态语义错位。
3. **命名统一**：S_AR / R_P / R_FE96（四·补7b）。
4. **physical LP 定性**：per-period J_PF^period（每期 V_T=0、SOC carry），
   是 receding finite-period LPs，非 full-sequence；披露 period boundary
   bias。动作回放（|Δ|≤4e-11）是实现一致性，非连续运行正确性。
5. **score>1 归因**：改为 oracle-approximation（21 点网格 + 最近邻 +
   per-period V_T=0 terminal mismatch）+ 数值效应，非纯 float noise。
6. **严格投影零违规**：U(x) = [max(-1, -η_dCx/(PΔt)), min(1,
   C(1-x)/(η_cPΔt))]，闭区间过滤（无容差松弛），SOC 跨 period carry
   度量下 r_infeasible = 0（R_P 重跑 score 0.7442 不变）。
7. **persistence 相关**：corr(δR², δS) = -0.095（70 站点）——"persistence
   越接近 AR 越可能赢"无经验支持，归因降级为猜想。
8. **风险二维**：S_AR 均值-尾部双优（E=1208.9, CVaR_0.9=15920.3）；
   R_P 略逊；R_FE96 最差。
9. **Lean 措辞收缩**："selected algebraic properties of the
   finite-benchmark evaluation are machine-checked in Lean"。
10. **标题**：改 "An Audit of Settlement Alignment, Information Timing,
    and Energy Conservation in EMSx Battery Control: Online Rollout under
    a Physical Evaluation"。

## 四·补10、第六版审查改善项（忽略继续优化项）

1. **forecast audit 重写**：三概念区分（时间因果性 / Information API
   许可 / 官方协议）——行 t+96 forecast 非时间泄漏（发布时间=决策时刻），
   但非官方接口提供，读取属 interface violation。"96 步泄漏"表述废弃。
2. **off-by-one 澄清**：settlement = min(t+97, horizon+96)，最后两步
   clamp 到 nrow（站点 1：horizon=17568，最后决策行 17664=nrow，
   settlement clamp 到 17664）——无越界，是文档表述问题。
3. **§4.3 修正**：R_FE96 是多场景 rollout（20 scenarios + CVaR），
   非 single-scenario（single-scenario 是 R_P）。
4. **§4.8 修正**：R_P 改"strongest proposed non-baseline controller"
   （baseline 0.7677 > R_P 0.7442）。
5. **两套 r_infeasible 分开标注**：pre-projection（1e-9 松弛）5.2e-5 vs
   strict-projection 0；正式榜单只用后者。
6. **environment oracle 措辞**：改 "environment-consistent approximate
   DP oracle"（21 点网格 + 最近邻 + per-period V_T=0，无 exact 下界保证）。
7. **forecast 归因限定**：两组控制器同时改变状态语义/转移模型/误差量化/
   CVaR 权重/选择器/continuation——"未隔离 forecast quality 与
   selector/state-model 差异"。
8. **风险聚合定义**：2474 period pooled 是 exposure-weighted portfolio
   estimand；mean cost 2235.7（per-site 全程）与 E[J]=1208.9
   （per-period pooled）不同单位。
9. **Abstract**：real-time → "online stochastic control"。

**忽略（继续优化项）**：full-sequence oracle（J_PF^full）、决策时刻最新
一步 forecast 路线（S_t=(SOC, z_t, ẑ_{t,t+1})）、正交奖励场、统计目标
（LCB>0 证明）——待出现超过 baseline 的候选后再进行。

## 四·补11、第七版审查打磨项

1. **末端边界效应**：settlement = min(t+97, horizon+96)，最后两步 clamp
   到 nrow；最后一步 settlement=decision row（每 period 重复）。成本占比
   ~1%（R_P 1.021% / S_AR 1.034% / R_FE96 1.057%，2474 periods）。
   文档限定为"interior steps timestamp-verified; terminal uses clamped
   convention"，修正（H=nrow-97 或删最后一步）已记录，未重跑。
2. **current-time forecast**：行 t+96 forecast 存在于原始数据（行 i 持有
   行 i 发布的 forecast），但官方 Information 接口不暴露；部署导向信息
   协议未评估。双信息轨道：I_EMSx ⊂ I_deployment，两轨道结果不混合。
3. **主指标**：M_0(π) = Σω_i[C_i(S_AR)−C_i(π)]，等站点权重 1/70
   （相对 dummy 排序相同）；与风险 pooled estimand 权重差异已写明。
4. **OpenEvolve 弱化**："在当前三参数族与有限搜索预算内，超参未弥补
   结构差距"；选择器/状态语义为推断而非已证明的唯一原因。
5. **行为克隆弱化**：负结果 consistent with bang-bang/flat optima；
   分类/集值目标/decision-focused loss 未测试，结构性解释为假说。
6. **Lean 句统一**："selected algebraic properties of the
   finite-benchmark score and resampling summaries are machine-checked
   with Lean"（§5 与 §7 一致）。
7. **Typst 排版修复**：§3.1 row t+97 等式断行（曾产生意外一级标题）已
   改为单行（i.e. decision time + 15 min）。
8. **参考文献**：补 EMSx 论文标题、Julia 1.12.6 / Python 3.14.6 /
   scipy 1.18.0 / Lean 4.32.2 / mathlib v4.33.0-rc1、仓库 commit hash
   （1ab0115 / 3467500 / 92fa399）。

**忽略（继续优化项）**：full-sequence/cyclic physical oracle
（J_PF^full）、部署信息协议路线、全量重跑修正末端边界。

## 五、OpenEvolve 自动参数优化（物理口径）
用 OpenEvolve（DeepSeek LLM 进化框架）优化 rollout 超参，fitness = 3 站点
物理 score（物理 LP oracle）。5 迭代 × 6 种群 ≈ 30 次 simulate 评估。

| 配置 (λ, α, margin) | 3 站点 fitness | 70 站点物理 score |
|---|---|---|
| 初始 (0.25, 0.9, 0.5) | −0.1104 | 0.5794 |
| 进化最优 (0.03, 0.55, 0.25) | **0.0352** | 0.5838 |
| SDP-AR(1) baseline | 0.5526 | 0.7677 |

结论：优化器有效（fitness +0.146），但 70 站点仅 +0.0044，无站点超过
baseline。瓶颈不在超参——价值函数在松驰（能量不守恒）动态下训练，调参
无法弥补；**物理动态重训 VF 才是下一步**（审计范围外）。

## 六、后续建议（审计范围外）

- 用物理动态（U(SOC) 约束）重训 A₂ 价值函数，再评估物理版 rollout；
- 若重训后物理 score 仍 < baseline，则 settlement-aligned rollout 在
  物理语义下没有控制贡献；
- 物理 LP oracle 已覆盖全部 70 站点（`/tmp/physical_lp_oracle.csv`），
  可直接作为后续评估的基准。

## 复现命令

```bash
cd /home/ebt/Downloads/emsx/leanproof
export PATH="/home/ebt/.elan/bin:$PATH"
lake build          # 全绿
grep -rn "sorry\|axiom" Leanproof/   # 空 = 全部闭合
```

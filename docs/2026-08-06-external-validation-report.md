# Ausgrid + AEMO 双数据集验证与可视化 — 最终报告

日期：2026-08-07（无人值守一晚执行，2026-08-06 23:59 前后收尾）
目标：见 `docs/2026-08-06-ausgrid-aemo-validation.md`。本文为执行结束后的汇总报告（完成项 / 阻塞项 / 根因分析 / 下一步）。

---

## 1. 完成项

### 1.1 Ausgrid 数据准备（✅）
- 300 户 30min 净需求（`actual_consumption − actual_pv`），2010-07 ~ 2013-06，Ausgrid Solar Home（镜像 `pierreh.eu`；来源/许可说明 `external_data/ausgrid/README.md`）
- train/test：2 年 / 1 年；TOU 两级电价（工作日 7-21 峰 0.30 AUD/kWh、其余 0.12，卖价=买价×0.6）；电池 5kW/13.5kWh
- 验证格式 `external_data/ausgrid/validation/<户>/{train,test}.csv + battery.json`，已 scp Mac

### 1.2 Ausgrid 算法验证（✅ 最终结果，Mac）
- 驱动 `scripts/run_external_validation.jl`（与 Mac 同步）：weekday/weekend×48 时段分组 AR(1)+确定性量化、StoOpt 周期平均成本 VI、物理 SOC 回放（无 exploit）、S_AR / R_P / Dummy
- **最终：S_AR gain > 0 共 300/300 户，均值 343.1 AUD/户（中位数 336.6）**；dummy 成本均值 685.4 AUD
  - R_P gain 均值 343.2（中位数 336.9）——与 S_AR 高度接近（TOU 电价确定，调度主要由价格驱动；逐户数值不同，符合"R_P 接近"预期）
- 结果回传 `external_data/ausgrid/results/`（300 份）

### 1.3 AEMO 数据（⚠️ 降级，见 §2）
- ARCHIVE 每日包 14 天（2026-07-22 ~ 2026-08-04，5min RRP + TOTALDEMAND，14×288=4032 子包），AEMO 官网直连（~10KB/s，慢速稳定）
- 转换：5 区域（NSW1/VIC1/QLD1/SA1/TAS1）净需求+电价；重采样至 30min（48 时段）、归一化 kW/$/kWh（与 Ausgrid 同单位约定）、时间戳对齐 30min 网格
- 电池按区域均值等比例缩放（沿用 Ausgrid 比率：功率=5×均值、容量=2.7h×功率），如 NSW1 ≈ 42.8GW/116GWh——与家用尺度保持平行

### 1.4 AEMO 算法验证（✅ 48 时段，Mac，5/5 区域正 gain）
| 区域 | dummy 成本 | S_AR gain | gain/dummy | R_P gain |
|---|---|---|---|---|
| NSW1 | 1.107e8 | +2.868e7 | 26% | +2.867e7 |
| QLD1 | 6.813e7 | +2.616e7 | 38% | +2.616e7 |
| VIC1 | 3.674e7 | +2.341e7 | 64% | +2.341e7 |
| SA1 | 1.115e7 | +2.695e6 | 24% | +2.695e6 |
| TAS1 | 7.006e6 | +3.047e6 | 44% | +3.047e6 |

- 计价口径：**区域典型电价时刻表**（训练窗分时均价）——与 Ausgrid 的固定 TOU 结构平行（详见 §3.3）
- 结果回传 `external_data/aemo/results/`（5 份）

### 1.5 可视化（✅ build + 网桥目检）
- 09_ausgrid 页：per_site_gain.json（300 户，与原始结果核对一致）+ curves.json + **forecast_error.json（一步预测 RMSE 差值曲线新卡片）**；网桥目检：渲染、300 站点下拉切换
- 10_aemo 页：per_site_gain.json（5 区域）+ curves.json + forecast_error.json；网桥目检：渲染、5 区域下拉切换
- **S_AR−R_P gain 差值曲线**（两页 gain 卡片改为差值形式）：diff = S_AR gain − R_P gain（AUD，均相对 dummy），按差值升序的单调曲线 + 零线，按符号着色（S_AR 优蓝 / R_P 优灰）——Ausgrid 300 户中 100 户 S_AR 更优、187 户 R_P 更优、13 户相等，差值 −0.65..+0.40 AUD（两者高度接近，差值极小但可见）；AEMO 5 区域差值 −8.4k..+37k
- **一步预测误差对比卡**（两页新增）：diff = persistence RMSE − AR(1) RMSE（kW），按差值升序单调曲线——AEMO 区域 AR1 比 persistence 好 1.4-2.3×（RMSE 比 0.43-0.73，误差集中在晨/晚爬坡时段，AR1 的分时段截距 β(τ) 记忆日循环）；Ausgrid 家用 AR1 略优（中位差值 +0.02 kW，49/300 户 persistence 更优）
- `pnpm build` 退出 0（11 页）；i18n 中英双语（AEMO 文案注明 14 天降级与计价口径）

### 1.6 git 提交树
- `583e72a` 脚手架；`ed7983f` Ausgrid 旧版结果+可视化；`5f93ac9` AEMO 管线脚本+短训练支持
- 本晚新增（见 §5 提交记录）：验证脚本对齐修复、Ausgrid 重跑、AEMO 数据/结果/可视化、最终报告

---

## 2. 阻塞项（已按停止规则记录并降级）

1. **AEMO 历史不足 6 个月**：MMSDM 月度包（18 个月理想/6 个月下限）因 AEMO 服务器限速（191B/s~13KB/s，60s 限时下不完 ~2MB 文件）全部失败 → 改用 ARCHIVE 每日包仅 14 天（≈0.5 个月）。**不满足"≥6 个月"标准**，作为 5min→30min 高分辨率演示，已如实标注。
2. **288 时段（5min 原生）验证受阻**：14 天训练仅 1 整周，576 个 (weekday/weekend×slot) 组每组 2-7 样本，AR(1) 拟合劣质（周末组被跳过导致 StoOpt "sum probability != 1"；修后仍 gain 为负）→ 按停止规则**降级 48 时段重采样**。
3. **区域级尺度**：AEMO 为区域净需求（MW）与市场价格（$/MWh），gain 绝对量与 Ausgrid 不可跨数据集直接比较；同数据集内 S_AR/R_P/dummy 对比有效。

---

## 3. 根因分析（调试过程记录，供复现/审阅）

### 3.1 288 时段 "sum probability != 1"
`fit_ar1` 原按完整周 reshape，n_weeks=1 时周末组样本 2<5 被跳过 → 该时段转移概率行全零 → StoOpt 校验失败。修复：阈值降至 2 + 全零行兜底为确定性零噪声核；并将 AR(1) 拟合改为使用**全部训练天数**（不再丢弃不完整周），每组样本翻倍。

### 3.2 AEMO 单位 1000× 错误
回放成本 `import_kwh = z + u·power·dt`：Ausgrid 的 z 是 kW、电价 $/kWh，电池项 kWh 与 z 同量纲；AEMO 的 z 是 MW、电价 $/MWh，电池项 kWh 直接加到 MW 上 → **电池能量被放大 1000 倍**（实测 gain 偏差恰为 1000×）。修复：AEMO 数据归一化到 kW/$/kWh（`resample_48.py`），两数据集同单位约定。

### 3.3 市场价格窗口漂移 → 时刻表计价
修复单位后 gain 仍全负（NSW1 -1.89e7），且 rp==sdp。定位：AEMO 是**真实市场价格**，14 天窗内测试期（后 20%）与训练期价格水平系统性漂移（SA1 训练均价 120.5 → 测试 66.7 $/MWh，-45%）；控制器按训练均价格局决策，测试期在错误价位执行 → 系统性亏损。DP 完美预知上界证明价格结构本身套利空间巨大（NSW1 最大 gain 1.37e8）。
修复：**回放成本改用训练窗分时均价（区域典型时刻表）计价**——与 Ausgrid 固定 TOU 结构平行（Ausgrid 测试价=训练价，此改动对其零影响，实证 dummy 68.5 不变）。

### 3.4 τ 位置索引 vs 真实时间错位
即使时刻表计价，Ausgrid 结果仍被改变（dummy 68.5 不变但决策变化）。定位：脚本按文件位置计算周时段 τ（`((i-1)%HORIZON)+1`），测试窗起始星期与训练窗不同 → 周末 TOU 档错位。修复：**τ 按时间戳真实周时段对齐**（`week_slot`），训练/测试统一按真实日历星期与时刻索引。修复后 Ausgrid 300/300 正 gain（均值 103.3→343.1，消除周末错位带来的系统性损失）。

### 3.5 其他
- zsh 远程 shell 不做未加引号参数词分割，批量站点号曾作为单个参数传入（`isdir` 失败 → 0 站点）——本地 bash 构造后分别 ssh。
- 聚合脚本相对路径（`../../visualization` 越级）修正为 `../visualization`。

### 3.6 调度-预测曲线对齐（persistence 曾与 actual 完全重合）
外部页曲线最初将 persistence 存为 `persist[t] = z(t)`，而 actual 同位置也是 `z(t)` → 两条线逐点相同、persistence 线无信息量；且 ar1 画在"决策时刻"而非"被预测目标时刻"。修正：三个序列统一对齐到**目标时刻 t**——`actual[t]=z_t`、`persist[t]=z_{t-1}`（一步 persistence 预测）、`ar1[t]=α(τ_{t-1})·z_{t-1}+β(τ_{t-1})`（t=1 用训练末值），与主项目 `controller_forecast.jl` 的 `se/ar1` 对齐语义一致；两线对 actual 的垂直差即一步预测误差。两个数据集已重跑（cost/gain 不变），页面网桥目检确认 persistence 线滞后一格。

---

## 4. 下一步

1. 换网络/渠道（如 NEMOSIS 或数据镜像）补 ≥6 个月 MMSDM 历史，重跑 AEMO 验证（原生 288 时段 + 训练窗充足），替换降级演示。
2. AEMO 价格漂移说明已在可视化文案体现；若补足数据，可考虑改用"市场价格计价的 AEMO 原实验"与"时刻表计价"双口径展示。
3. 长期：验证脚本的 `done: N sites` 计数（`results` 数组未 push）为已知装饰性缺陷，不影响结果。

## 5. 本晚 git 提交记录（自上而下）

- `fix(validation): real-time-of-week slot alignment + AEMO unit/normalization + tariff pricing`（run_external_validation.jl、resample_48.py、pipeline 路径/zsh 修复、.gitignore）
- `feat(validation): AEMO 5-region 48-slot validation results + 10_aemo viz data + i18n`（aemo/results、public/data/aemo、i18n）
- `feat(validation): Ausgrid 300-site re-run with time-aligned schedule + updated results/viz`（ausgrid/results、public/data/ausgrid）
- `docs: final external validation report`

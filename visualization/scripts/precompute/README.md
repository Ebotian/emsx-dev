# 预计算脚本（数据准备）

## 口径说明（2026-08-03 核实）
- worktree 的 `EMSx.jl/metadata/baseline/` 是**连续 SOC 版**（anticipative
  site1 = 4313.6 = 物理 LP_upper）——`evaluate_model` 的"官方口径"与
  本研究物理口径（LP oracle）**同一 baseline，数值一致**。
- 论文分数（MPC 0.487 / OLFC 0.513 / SDP 0.691 / SDP-AR(1) 0.794）是
  **原版重置 SOC 口径**（论文 Table tab:score），与本研究口径不同尺度。
- 可视化 05 页的"双口径"指：**论文原版（重置 SOC）** vs
  **本研究连续 SOC（LP oracle）**，严格分开展示。

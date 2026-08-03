# 预计算脚本（数据准备）

## 口径（2026-08-03 统一，用户指示）
- **统一连续 SOC 口径**：所有控制器（Dummy/MPC/OLFC-50/SDP/SDP-AR(1)/
  S_AR/R_P/R_FE96）都在连续 SOC 模拟器（SOC 跨 period carry、clamp
  动态、物理 U(x) 约束）下评估，用物理 LP oracle（`physical_lp_oracle.csv`）
  作为上界评分。
- **控制方法沿用论文**：MPC（H=96 确定性 lookahead LP）、OLFC（多场景
  开环 LP）、SDP（离线 VF + 在线 StoOpt，无 AR）、SDP-AR(1)（AR 噪声
  SDP）按论文设计实现，但全部在连续 SOC 口径下跑。
- **论文原版分数（MPC 0.487 / OLFC-50 0.513 / SDP 0.691 / SDP-AR(1)
  0.794，重置 SOC 口径）仅作外部参考**，不混入统一 leaderboard（口径
  不同不可比）。
- worktree 的 `EMSx.jl/metadata/baseline/` 已是连续 SOC 版
  （anticipative site1=4313.6=LP_upper），`evaluate_model` 结果与物理
  口径一致——不再做"官方 vs 物理"双口径。

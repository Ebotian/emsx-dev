#!/usr/bin/env python3
"""Analyze the value-function ratio experiment: /tmp/probe_vf_ratio.json.
Outputs:
  1. Efficiency matrix (training ratio x deployment ratio) as a table.
  2. The matched diagonal (rv == rd): clean price-ratio -> benefit relationship.
  3. The mismatch penalty (off-diagonal vs diagonal).
  4. 2D contour plot (x=training ratio, y=deployment ratio, z=efficiency),
     diagonal annotated, saved as PNG.
Usage: python3 analyze_vf_ratio.py <json_path> <out_png>
"""
import json, sys, numpy as np

path, out_png = sys.argv[1], sys.argv[2]
d = json.load(open(path))
ratios = [1.0, 2.0, 3.0, 5.0, 10.0, 20.0, 40.0]
n = len(ratios)

gain = np.zeros((n, n)); wmae = np.zeros((n, n)); eff = np.zeros((n, n))
for i, rv in enumerate(ratios):
    for j, rd in enumerate(ratios):
        k = f"{rv}_{rd}"
        gain[i, j] = d[k]["gain"]
        wmae[i, j] = d[k]["wmae"]
        eff[i, j] = d[k]["efficiency"]

print("=== 效率矩阵 eff(rv, rd) = gain/gain(rd,rd)（行=训练比值 rv，列=部署比值 rd） ===")
print("rv\\rd  " + "  ".join(f"{r:.0f}x".rjust(7) for r in ratios))
for i, rv in enumerate(ratios):
    print(f"{rv:>4.0f}x  " + "  ".join(f"{eff[i,j]*100:.0f}%".rjust(7) for j in range(n)))

print("\n=== 对角线（匹配：训练=部署）——干净的价格比值-收益关系 ===")
diag_gain = [gain[i, i] for i in range(n)]
print("rd    gain(匹配)    wmae(匹配)")
for j, rd in enumerate(ratios):
    print(f"{rd:>4.0f}x  {diag_gain[j]:>12,.0f}  {wmae[j,j]:>10.1f}")
print(f"\n对角线 gain 随比值的变化比（每倍）：")
for j in range(1, n):
    print(f"  {ratios[j-1]:.0f}x→{ratios[j]:.0f}x: {diag_gain[j]/diag_gain[j-1]:.2f}x")

print("\n=== 失配惩罚（非对角线 vs 对角线，相对损失） ===")
print("rv\\rd  " + "  ".join(f"{r:.0f}x".rjust(7) for r in ratios))
for i, rv in enumerate(ratios):
    row = []
    for j, rd in enumerate(ratios):
        loss = (1 - eff[i, j]) * 100
        row.append(f"{loss:.0f}%".rjust(7) if i != j else "  ==  ")
    print(f"{rv:>4.0f}x  " + "  ".join(row))

# ---- contour plot ----
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.ticker as mticker

X, Y = np.meshgrid(np.log10(ratios), np.log10(ratios))  # log axes
fig, ax = plt.subplots(figsize=(8, 6.5))
cf = ax.contourf(X, Y, eff.T, levels=np.linspace(0.5, 1.0, 21), cmap="RdYlGn", extend="min")
ax.contour(X, Y, eff.T, levels=[0.8, 0.9, 0.95, 0.99], colors="k", linewidths=0.6, linestyles="--")
ax.plot(np.log10(ratios), np.log10(ratios), "w-", linewidth=2, label="matched diagonal (rv=rd)")
tick_fmt = lambda v, p: f"{10**v:.0f}x"
ax.xaxis.set_major_formatter(mticker.FuncFormatter(tick_fmt))
ax.yaxis.set_major_formatter(mticker.FuncFormatter(tick_fmt))
ax.set_xlabel("training price ratio rv (value function fitted at rv)")
ax.set_ylabel("deployment price ratio rd (dispatch at rd prices)")
ax.set_title("Efficiency = gain(rv,rd) / gain(rd,rd)  [fixed AR(1) forecast]")
cb = fig.colorbar(cf, ax=ax, label="efficiency")
ax.legend(loc="lower right")
# annotate the diagonal cells
for i in range(n):
    ax.annotate(f"{eff[i,i]*100:.0f}%", (np.log10(ratios[i]), np.log10(ratios[i])),
                textcoords="offset points", xytext=(6, -14), fontsize=8, color="white")
plt.tight_layout()
plt.savefig(out_png, dpi=150)
print(f"\nsaved contour plot -> {out_png}")

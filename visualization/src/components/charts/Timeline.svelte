<script lang="ts">
  /** 04: decision-time timeline for step 1 (site 1) — static annotated timeline. */
  const marks = [
    { label: 'forecast origin (row t+1)\n2014-07-20 00:15', time: 0, kind: 'f' },
    { label: 'decision time (row t+96)\n2014-07-21 00:00', time: 1, kind: 'd' },
    { label: 'settlement (row t+97)\n2014-07-21 00:15', time: 2, kind: 's' },
  ];
  // window: rows t+1..t+96 = 00:15 .. 07-21 00:00 ; load[1] = current actual at decision
</script>

<div style="padding:16px 8px;">
  <div style="position:relative;height:120px;border-top:2px solid #1a1a1a;margin:24px 8px 0;">
    <div style="position:absolute;left:8px;top:-8px;font-size:12px;color:#6b7280;">2014-07-20 00:00 (row 1)</div>
    <div style="position:absolute;right:8px;top:-8px;font-size:12px;color:#6b7280;">2014-07-21 00:30</div>
    {#each marks as m}
      {@const left = m.time === 0 ? '2%' : m.time === 1 ? '62%' : '72%'}
      <div style="position:absolute;left:{left};top:-8px;transform:translateX(-50%);">
        <div style="width:2px;height:16px;background:{m.kind === 'd' ? '#1f4e79' : m.kind === 's' ? '#b91c1c' : '#6b7280'};margin:0 auto;"></div>
        <div style="position:absolute;top:22px;left:50%;transform:translateX(-50%);width:150px;font-size:11px;color:{m.kind === 'd' ? '#1f4e79' : m.kind === 's' ? '#b91c1c' : '#6b7280'};text-align:center;white-space:pre-line;background:#fff;padding:2px 4px;">{m.label}</div>
      </div>
    {/each}
  </div>
  <div style="margin-top:120px;font-size:12px;color:#6b7280;line-height:1.7;">
    <p>· 信息窗口：行 t+1..t+96（00:15 → 07-21 00:00），共 96 个 actual 观测。</p>
    <p>· <b style="color:#1f4e79">load[1]（行 t+96）</b> 是决策时刻的当前实际 w<sub>t</sub> —— 因果可见。</p>
    <p>· <b style="color:#6b7280">forecast origin（行 t+1）</b> 是已发布的 day-ahead forecast —— 因果可见。</p>
    <p>· <b style="color:#b91c1c">settlement（行 t+97）</b> = 决策后 15 分钟，为被控结果 —— 决策时未知。</p>
  </div>
</div>

import { useState } from 'react'

export type Point = { x: number; label: string; y: number; sub?: string }

/**
 * Single-series line over time.
 *
 * Deliberately ONE series on ONE axis. The raw score and the cohort-adjusted
 * residual live on different scales, and putting them on one chart would be a
 * dual-axis chart -- the single most misleading thing you can do to a reader.
 * The adjusted figures are in the gap table instead.
 */
export function Sparkline({
  points, height = 190, yLabel = 'Score', format = (v: number) => `${Math.round(v * 100)}%`,
}: { points: Point[]; height?: number; yLabel?: string; format?: (v: number) => string }) {
  const [hover, setHover] = useState<number | null>(null)
  const [tip, setTip] = useState<{ x: number; y: number } | null>(null)
  if (points.length === 0) return <div className="empty">No marks recorded yet.</div>

  const W = 720, H = height
  const pad = { t: 12, r: 14, b: 26, l: 40 }
  const iw = W - pad.l - pad.r, ih = H - pad.t - pad.b
  const xs = points.map((p) => p.x)
  const x0 = Math.min(...xs), x1 = Math.max(...xs)
  const sx = (x: number) => pad.l + (x1 === x0 ? iw / 2 : ((x - x0) / (x1 - x0)) * iw)
  const sy = (y: number) => pad.t + ih - Math.max(0, Math.min(1, y)) * ih
  const d = points.map((p, i) => `${i ? 'L' : 'M'}${sx(p.x).toFixed(1)},${sy(p.y).toFixed(1)}`).join(' ')
  const ticks = [0, 0.25, 0.5, 0.75, 1]

  return (
    <div style={{ position: 'relative' }}>
      <svg className="chart" viewBox={`0 0 ${W} ${H}`} role="img"
           aria-label={`${yLabel} over time, ${points.length} points`}
           onMouseLeave={() => { setHover(null); setTip(null) }}>
        {ticks.map((t) => (
          <g key={t}>
            <line className="grid-line" x1={pad.l} x2={W - pad.r} y1={sy(t)} y2={sy(t)} />
            <text className="axis-text" x={pad.l - 7} y={sy(t) + 4} textAnchor="end">{format(t)}</text>
          </g>
        ))}
        <line className="axis-line" x1={pad.l} x2={pad.l} y1={pad.t} y2={pad.t + ih} />
        <path className="series-line" d={d} />
        {hover !== null && points[hover] && (
          <line className="crosshair" x1={sx(points[hover]!.x)} x2={sx(points[hover]!.x)}
                y1={pad.t} y2={pad.t + ih} />
        )}
        {points.map((p, i) => (
          <circle key={i} className="dot" cx={sx(p.x)} cy={sy(p.y)} r={hover === i ? 6 : 4} />
        ))}
        {/* Hit bands are wider than the marks so hovering is easy. */}
        {points.map((p, i) => (
          <rect key={`h${i}`} className="hover-band"
                x={sx(p.x) - iw / Math.max(points.length, 1) / 2} y={pad.t}
                width={Math.max(iw / Math.max(points.length, 1), 14)} height={ih}
                onMouseMove={(e) => { setHover(i); setTip({ x: e.clientX, y: e.clientY }) }} />
        ))}
        <text className="axis-text" x={pad.l} y={H - 6}>{points[0]!.label}</text>
        {points.length > 1 && (
          <text className="axis-text" x={W - pad.r} y={H - 6} textAnchor="end">
            {points[points.length - 1]!.label}
          </text>
        )}
      </svg>
      {hover !== null && tip && points[hover] && (
        <div className="tooltip" style={{ left: Math.min(tip.x + 12, window.innerWidth - 270), top: tip.y + 12 }}>
          <div className="t-title">{points[hover]!.label}</div>
          <div>{yLabel}: <strong className="tabular">{format(points[hover]!.y)}</strong></div>
          {points[hover]!.sub && <div className="muted">{points[hover]!.sub}</div>}
        </div>
      )}
    </div>
  )
}

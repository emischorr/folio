// Renders the dashboard's main portfolio chart with TradingView
// lightweight-charts (vendored, Apache-2.0). The LiveView pushes
// "chart:data" events with {points: [{time, value}], mode, currency};
// colors follow the active daisyUI theme by resolving its CSS tokens at
// runtime. The operator's time-format setting ("24h"/"12h") arrives once via
// the root element's data-time-format attribute, since it never changes
// while the server is running.
import {
  createChart,
  AreaSeries,
  LineStyle,
  CrosshairMode,
  TrackingModeExitMode,
} from "../vendor/lightweight-charts.mjs"

// oklch(...) from the theme tokens isn't universally understood by canvas
// APIs, so resolve any CSS color to rgb components via a 1px canvas paint.
function toRgb(cssColor) {
  const canvas = document.createElement("canvas")
  canvas.width = canvas.height = 1
  const ctx = canvas.getContext("2d", {willReadFrequently: true})
  ctx.fillStyle = cssColor
  ctx.fillRect(0, 0, 1, 1)
  const [r, g, b] = ctx.getImageData(0, 0, 1, 1).data
  return {r, g, b}
}

function rgba({r, g, b}, alpha) {
  return `rgba(${r}, ${g}, ${b}, ${alpha})`
}

function themeColors(el) {
  const styles = getComputedStyle(el)
  const primary = toRgb(styles.getPropertyValue("--color-primary"))
  const content = toRgb(styles.getPropertyValue("--color-base-content"))
  return {
    line: rgba(primary, 1),
    areaTop: rgba(primary, 0.35),
    axisText: rgba(content, 0.35),
    crosshair: rgba(content, 0.25),
    zero: rgba(content, 0.3),
  }
}

// Mirrors FolioWeb.Format.money/2's symbol table and "sign + symbol + space
// + grouped" shape, so axis ticks and the tooltip read exactly like the
// rest of the UI.
const CURRENCY_SYMBOLS = {EUR: "€", USD: "$"}

function formatMoney(value, currency) {
  const symbol = CURRENCY_SYMBOLS[currency] ?? currency
  const sign = value < 0 ? "−" : ""
  const grouped = Math.abs(value).toLocaleString("en-US", {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  })
  return `${sign}${symbol} ${grouped}`
}

// Grid points are either stepped every 15min/1h (1d/1w windows) or one per
// calendar day (every other window) — inferred from spacing rather than a
// separate field from the server.
function isIntraday(points) {
  if (points.length < 2) return false
  return points[1].time - points[0].time < 20 * 60 * 60
}

function formatTooltipDate(unixSeconds, intraday, hour12) {
  const date = new Date(unixSeconds * 1000)
  return intraday
    ? date.toLocaleString("en-US", {
        month: "short",
        day: "numeric",
        hour: "numeric",
        minute: "2-digit",
        hour12,
      })
    : date.toLocaleDateString("en-US", {month: "short", day: "numeric", year: "numeric"})
}

// Compact form for the time-axis tick marks themselves (the tooltip above
// carries the full date, so ticks just need to be scannable).
function formatAxisDate(unixSeconds, intraday, hour12) {
  const date = new Date(unixSeconds * 1000)
  return intraday
    ? date.toLocaleTimeString("en-US", {hour: "numeric", minute: "2-digit", hour12})
    : date.toLocaleDateString("en-US", {month: "short", day: "numeric"})
}

const PortfolioChart = {
  mounted() {
    const colors = themeColors(this.el)
    this.currency = "EUR"
    this.mode = "value"
    this.intraday = false
    this.hour12 = this.el.dataset.timeFormat === "12h"

    this.chart = createChart(this.el, {
      autoSize: true,
      layout: {
        background: {color: "transparent"},
        textColor: colors.axisText,
        attributionLogo: false,
        fontSize: 11,
      },
      grid: {vertLines: {visible: false}, horzLines: {visible: false}},
      rightPriceScale: {visible: false},
      leftPriceScale: {
        visible: true,
        borderVisible: false,
        scaleMargins: {top: 0.15, bottom: 0.15},
        // Default density packs a tick every ~2.5 label-heights; bump it up
        // so a ~160-220px-tall chart lands around 4-6 ticks instead of 8+.
        tickMarkDensity: 3,
      },
      timeScale: {
        visible: true,
        borderVisible: false,
        tickMarkFormatter: (time) => formatAxisDate(time, this.intraday, this.hour12),
      },
      handleScroll: false,
      handleScale: false,
      trackingMode: {exitMode: TrackingModeExitMode.OnTouchEnd},
      crosshair: {
        mode: CrosshairMode.Magnet,
        horzLine: {visible: false, labelVisible: false},
        vertLine: {
          visible: true,
          style: LineStyle.Solid,
          width: 1,
          color: colors.crosshair,
          labelVisible: false,
        },
      },
    })
    this.series = this.chart.addSeries(AreaSeries, {
      lineColor: colors.line,
      lineWidth: 2,
      topColor: colors.areaTop,
      bottomColor: "transparent",
      priceLineVisible: false,
      lastValueVisible: false,
      crosshairMarkerVisible: true,
      crosshairMarkerRadius: 4,
      crosshairMarkerBorderColor: colors.line,
      crosshairMarkerBackgroundColor: colors.line,
      priceFormat: {
        type: "custom",
        formatter: (price) => formatMoney(price, this.currency),
        minMove: 0.01,
      },
    })

    this.el.style.position = "relative"
    this.tooltip = document.createElement("div")
    this.tooltip.className =
      "pointer-events-none absolute z-10 hidden -translate-x-1/2 -translate-y-full whitespace-nowrap rounded-lg border border-base-300 bg-base-100/95 px-2.5 py-1.5 text-[12px] shadow-md backdrop-blur-sm"
    this.el.appendChild(this.tooltip)

    this.chart.subscribeCrosshairMove((param) => this.updateTooltip(param))

    this.handleEvent("chart:data", ({points, mode, currency}) => {
      this.currency = currency
      this.mode = mode
      this.intraday = isIntraday(points)
      this.series.setData(points)
      this.setZeroLine(mode === "profit")
      this.chart.timeScale().fitContent()
      this.hideTooltip()
    })

    this.themeObserver = new MutationObserver(() => this.applyTheme())
    this.themeObserver.observe(document.documentElement, {
      attributes: true,
      attributeFilter: ["data-theme"],
    })
  },

  destroyed() {
    this.themeObserver?.disconnect()
    this.chart?.remove()
  },

  applyTheme() {
    const colors = themeColors(this.el)
    this.chart.applyOptions({
      layout: {textColor: colors.axisText},
      crosshair: {vertLine: {color: colors.crosshair}},
    })
    this.series.applyOptions({
      lineColor: colors.line,
      topColor: colors.areaTop,
      crosshairMarkerBorderColor: colors.line,
      crosshairMarkerBackgroundColor: colors.line,
    })
    if (this.zeroLine) {
      this.zeroLine.applyOptions({color: colors.zero})
    }
  },

  setZeroLine(visible) {
    if (visible && !this.zeroLine) {
      this.zeroLine = this.series.createPriceLine({
        price: 0,
        color: themeColors(this.el).zero,
        lineWidth: 1,
        lineStyle: LineStyle.Dashed,
        axisLabelVisible: false,
      })
    } else if (!visible && this.zeroLine) {
      this.series.removePriceLine(this.zeroLine)
      this.zeroLine = null
    }
  },

  updateTooltip(param) {
    const data = param.point && param.seriesData?.get(this.series)
    if (!param.point || !data || param.time === undefined) {
      this.hideTooltip()
      return
    }

    const price = data.value ?? data.close
    const changeClass =
      this.mode === "profit" ? (price < 0 ? "text-error" : "text-success") : ""

    this.tooltip.innerHTML = `
      <div class="text-base-content/50">${formatTooltipDate(param.time, this.intraday, this.hour12)}</div>
      <div class="font-semibold tabular-nums ${changeClass}">${formatMoney(price, this.currency)}</div>
    `
    this.tooltip.classList.remove("hidden")

    const width = this.el.clientWidth
    const tooltipWidth = this.tooltip.offsetWidth
    const margin = 8
    const left = Math.min(
      Math.max(param.point.x, tooltipWidth / 2 + margin),
      width - tooltipWidth / 2 - margin
    )
    this.tooltip.style.left = `${left}px`
    this.tooltip.style.top = `${Math.max(param.point.y - 12, 0)}px`
  },

  hideTooltip() {
    this.tooltip.classList.add("hidden")
  },
}

export default PortfolioChart

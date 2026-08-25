// Renders the dashboard's main portfolio chart with TradingView
// lightweight-charts (vendored, Apache-2.0). The LiveView pushes
// "chart:data" events with {points: [{time, value}], mode}; colors follow
// the active daisyUI theme by resolving its CSS tokens at runtime.
import {createChart, AreaSeries, LineStyle} from "../vendor/lightweight-charts.mjs"

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
    text: rgba(content, 0.5),
    zero: rgba(content, 0.3),
  }
}

const PortfolioChart = {
  mounted() {
    const colors = themeColors(this.el)
    this.chart = createChart(this.el, {
      autoSize: true,
      layout: {
        background: {color: "transparent"},
        textColor: colors.text,
        attributionLogo: false,
      },
      grid: {vertLines: {visible: false}, horzLines: {visible: false}},
      rightPriceScale: {visible: false},
      leftPriceScale: {visible: false},
      timeScale: {visible: false, borderVisible: false},
      handleScroll: false,
      handleScale: false,
      crosshair: {
        horzLine: {visible: false, labelVisible: false},
        vertLine: {visible: false, labelVisible: false},
      },
    })
    this.series = this.chart.addSeries(AreaSeries, {
      lineColor: colors.line,
      lineWidth: 2,
      topColor: colors.areaTop,
      bottomColor: "transparent",
      priceLineVisible: false,
      lastValueVisible: false,
      crosshairMarkerVisible: false,
    })

    this.handleEvent("chart:data", ({points, mode}) => {
      this.series.setData(points)
      this.setZeroLine(mode === "profit")
      this.chart.timeScale().fitContent()
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
    this.chart.applyOptions({layout: {textColor: colors.text}})
    this.series.applyOptions({lineColor: colors.line, topColor: colors.areaTop})
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
}

export default PortfolioChart

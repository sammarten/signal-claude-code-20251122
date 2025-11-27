import { createChart, CandlestickSeries } from 'lightweight-charts';

/**
 * SparkChart - Minimal candlestick chart for signal cards
 *
 * Shows recent price action with entry, stop, and target levels overlaid.
 * Designed to be compact and fit within signal cards.
 */

/**
 * Convert UTC timestamp to browser's local timezone
 */
function timeToLocal(originalTime) {
  const d = new Date(originalTime * 1000);
  return Date.UTC(d.getFullYear(), d.getMonth(), d.getDate(), d.getHours(), d.getMinutes(), d.getSeconds(), d.getMilliseconds()) / 1000;
}

export const SparkChart = {
  mounted() {
    const symbol = this.el.dataset.symbol;
    const width = parseInt(this.el.dataset.width || '200', 10);
    const height = parseInt(this.el.dataset.height || '100', 10);

    // Parse signal levels
    const entryPrice = parseFloat(this.el.dataset.entry);
    const stopLoss = parseFloat(this.el.dataset.stop);
    const takeProfit = parseFloat(this.el.dataset.target);
    const direction = this.el.dataset.direction;

    // Create minimal chart
    this.chart = createChart(this.el, {
      width: width,
      height: height,
      layout: {
        background: { color: 'transparent' },
        textColor: '#71717a',
        attributionLogo: false,
      },
      grid: {
        vertLines: { visible: false },
        horzLines: { color: '#27272a', style: 1 },
      },
      crosshair: {
        mode: 0,
        vertLine: { visible: false },
        horzLine: { visible: false },
      },
      rightPriceScale: {
        visible: false,
      },
      leftPriceScale: {
        visible: false,
      },
      timeScale: {
        visible: false,
        borderVisible: false,
      },
      handleScale: false,
      handleScroll: false,
    });

    // Create candlestick series
    this.candleSeries = this.chart.addSeries(CandlestickSeries, {
      upColor: '#10b981',
      downColor: '#ef4444',
      borderUpColor: '#10b981',
      borderDownColor: '#ef4444',
      wickUpColor: '#10b981',
      wickDownColor: '#ef4444',
    });

    // Load initial data
    const initialData = JSON.parse(this.el.dataset.bars || '[]');

    if (initialData.length > 0) {
      const candleData = initialData.map(bar => ({
        time: timeToLocal(bar.time),
        open: parseFloat(bar.open),
        high: parseFloat(bar.high),
        low: parseFloat(bar.low),
        close: parseFloat(bar.close),
      }));

      this.candleSeries.setData(candleData);

      // Add signal level lines
      if (entryPrice && !isNaN(entryPrice)) {
        this.entryLine = this.candleSeries.createPriceLine({
          price: entryPrice,
          color: '#f59e0b',
          lineWidth: 2,
          lineStyle: 2, // Dashed
          axisLabelVisible: false,
          title: '',
        });
      }

      if (stopLoss && !isNaN(stopLoss)) {
        this.stopLine = this.candleSeries.createPriceLine({
          price: stopLoss,
          color: '#ef4444',
          lineWidth: 1,
          lineStyle: 0, // Solid
          axisLabelVisible: false,
          title: '',
        });
      }

      if (takeProfit && !isNaN(takeProfit)) {
        this.targetLine = this.candleSeries.createPriceLine({
          price: takeProfit,
          color: '#10b981',
          lineWidth: 1,
          lineStyle: 0, // Solid
          axisLabelVisible: false,
          title: '',
        });
      }

      // Fit content to show all data
      this.chart.timeScale().fitContent();
    }
  },

  updated() {
    // Handle updates if bars data changes
    const initialData = JSON.parse(this.el.dataset.bars || '[]');

    if (initialData.length > 0 && this.candleSeries) {
      const candleData = initialData.map(bar => ({
        time: timeToLocal(bar.time),
        open: parseFloat(bar.open),
        high: parseFloat(bar.high),
        low: parseFloat(bar.low),
        close: parseFloat(bar.close),
      }));

      this.candleSeries.setData(candleData);
      this.chart.timeScale().fitContent();
    }
  },

  destroyed() {
    if (this.chart) {
      this.chart.remove();
    }
  }
};

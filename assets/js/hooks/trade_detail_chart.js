import { createChart, CandlestickSeries } from 'lightweight-charts';
import { TradeZonePrimitive } from './trade_zone_primitive';

/**
 * TradeDetailChart - Chart for trade details modal
 *
 * Shows the trade's price action with:
 * - Candlestick bars (5 min before entry to 5 min after exit)
 * - Shaded risk/reward zones
 * - Price lines for key level, entry, target, exit
 */

/**
 * Convert UTC timestamp to browser's local timezone
 */
function timeToLocal(originalTime) {
  const d = new Date(originalTime * 1000);
  return Date.UTC(d.getFullYear(), d.getMonth(), d.getDate(), d.getHours(), d.getMinutes(), d.getSeconds(), d.getMilliseconds()) / 1000;
}

/**
 * Format time for display on the time scale
 */
function formatTimeExact(time) {
  const date = new Date(time * 1000);
  const hours = date.getUTCHours();
  const minutes = date.getUTCMinutes();
  const ampm = hours >= 12 ? 'PM' : 'AM';
  const hour12 = hours % 12 || 12;
  const minuteStr = minutes.toString().padStart(2, '0');
  return `${hour12}:${minuteStr} ${ampm}`;
}

export const TradeDetailChart = {
  mounted() {
    // Create chart with dark theme
    this.chart = createChart(this.el, {
      width: 500,
      height: 250,
      layout: {
        background: { color: '#18181b' }, // zinc-900
        textColor: '#a1a1aa', // zinc-400
        attributionLogo: false,
      },
      grid: {
        vertLines: { color: '#27272a' }, // zinc-800
        horzLines: { color: '#27272a' },
      },
      crosshair: {
        mode: 0,
        vertLine: { color: '#71717a', width: 1, style: 3, labelBackgroundColor: '#3f3f46' },
        horzLine: { color: '#71717a', width: 1, style: 3, labelBackgroundColor: '#3f3f46' },
      },
      rightPriceScale: {
        borderColor: '#3f3f46', // zinc-700
      },
      timeScale: {
        borderColor: '#3f3f46',
        timeVisible: true,
        secondsVisible: false,
        tickMarkFormatter: (time) => formatTimeExact(time),
      },
      localization: {
        timeFormatter: (time) => formatTimeExact(time),
      },
    });

    // Create candlestick series
    this.candleSeries = this.chart.addSeries(CandlestickSeries, {
      upColor: '#10b981', // green-500
      downColor: '#ef4444', // red-500
      borderUpColor: '#10b981',
      borderDownColor: '#ef4444',
      wickUpColor: '#10b981',
      wickDownColor: '#ef4444',
    });

    // Create trade zone primitive for shaded areas
    this.tradeZonePrimitive = new TradeZonePrimitive();
    this.candleSeries.attachPrimitive(this.tradeZonePrimitive);

    // Store price lines for cleanup
    this.priceLines = [];

    // Listen for chart data from LiveView
    this.handleEvent('trade-chart-data', (data) => {
      this.setChartData(data);
    });
  },

  setChartData({ bars, trade, level }) {
    // Clear existing price lines
    this.clearPriceLines();

    if (!bars || bars.length === 0) {
      this.candleSeries.setData([]);
      return;
    }

    // Transform bar data
    const candleData = bars.map(bar => ({
      time: timeToLocal(bar.time),
      open: parseFloat(bar.open),
      high: parseFloat(bar.high),
      low: parseFloat(bar.low),
      close: parseFloat(bar.close),
    }));

    this.candleSeries.setData(candleData);

    // Set up trade zone (shaded risk/reward areas)
    if (trade) {
      const tradeWithLocalTime = {
        ...trade,
        entry_time: trade.entry_time ? timeToLocal(trade.entry_time) : null,
        exit_time: trade.exit_time ? timeToLocal(trade.exit_time) : null,
      };
      this.tradeZonePrimitive.setTrades([tradeWithLocalTime]);
    }

    // Draw price lines
    this.drawPriceLines(trade, level);

    // Fit content to show all data
    this.chart.timeScale().fitContent();

    // Ensure all trade levels are visible in the price scale
    this.fitPriceScale(candleData, trade, level);
  },

  fitPriceScale(candleData, trade, level) {
    // Collect all prices that need to be visible
    const prices = [];

    // Add bar highs and lows
    for (const bar of candleData) {
      prices.push(bar.high);
      prices.push(bar.low);
    }

    // Add trade levels
    if (trade) {
      if (trade.entry_price) prices.push(parseFloat(trade.entry_price));
      if (trade.stop_loss) prices.push(parseFloat(trade.stop_loss));
      if (trade.take_profit) prices.push(parseFloat(trade.take_profit));
      if (trade.exit_price) prices.push(parseFloat(trade.exit_price));
    }

    // Add key level
    if (level && level.price) {
      prices.push(parseFloat(level.price));
    }

    if (prices.length === 0) return;

    // Calculate min and max with some padding
    const minPrice = Math.min(...prices);
    const maxPrice = Math.max(...prices);
    const range = maxPrice - minPrice;
    const padding = range * 0.08; // 8% padding on each side

    // Store the price range for the autoscale provider
    this._priceRange = {
      minValue: minPrice - padding,
      maxValue: maxPrice + padding,
    };

    // Update the series with custom autoscale provider
    this.candleSeries.applyOptions({
      autoscaleInfoProvider: () => ({
        priceRange: this._priceRange,
      }),
    });

    // Force the chart to re-autoscale with the new provider
    this.candleSeries.priceScale().applyOptions({
      autoScale: true,
    });
  },

  clearPriceLines() {
    for (const line of this.priceLines) {
      this.candleSeries.removePriceLine(line);
    }
    this.priceLines = [];
  },

  drawPriceLines(trade, level) {
    if (!trade) return;

    const isLong = trade.direction === 'long';

    // Key level line (the level that was broken/retested) - dashed amber
    if (level && level.price) {
      const levelLine = this.candleSeries.createPriceLine({
        price: parseFloat(level.price),
        color: '#f59e0b', // amber-500
        lineWidth: 2,
        lineStyle: 2, // dashed
        axisLabelVisible: true,
        title: level.type ? level.type.toUpperCase() : 'Level',
      });
      this.priceLines.push(levelLine);
    }

    // Entry line - solid, color based on direction
    if (trade.entry_price) {
      const entryColor = isLong ? '#10b981' : '#ef4444';
      const entryLine = this.candleSeries.createPriceLine({
        price: parseFloat(trade.entry_price),
        color: entryColor,
        lineWidth: 2,
        lineStyle: 0, // solid
        axisLabelVisible: true,
        title: 'Entry',
      });
      this.priceLines.push(entryLine);
    }

    // Target line - dashed green
    if (trade.take_profit) {
      const targetLine = this.candleSeries.createPriceLine({
        price: parseFloat(trade.take_profit),
        color: '#10b981', // green-500
        lineWidth: 1,
        lineStyle: 2, // dashed
        axisLabelVisible: true,
        title: 'Target',
      });
      this.priceLines.push(targetLine);
    }

    // Exit line - dotted, color based on status
    if (trade.exit_price) {
      let exitColor = '#f59e0b'; // amber for time exit
      if (trade.status === 'target_hit') {
        exitColor = '#10b981'; // green
      } else if (trade.status === 'stopped_out') {
        exitColor = '#ef4444'; // red
      }

      const exitLine = this.candleSeries.createPriceLine({
        price: parseFloat(trade.exit_price),
        color: exitColor,
        lineWidth: 2,
        lineStyle: 1, // dotted
        axisLabelVisible: true,
        title: 'Exit',
      });
      this.priceLines.push(exitLine);
    }
  },

  destroyed() {
    if (this.chart) {
      this.chart.remove();
    }
  }
};

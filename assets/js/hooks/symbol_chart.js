import { createChart, CandlestickSeries, HistogramSeries } from 'lightweight-charts';
import { SessionHighlighter } from './session_highlighter';
import { TradeZonePrimitive } from './trade_zone_primitive';

/**
 * Convert UTC timestamp to browser's local timezone
 */
function timeToLocal(originalTime) {
  const d = new Date(originalTime * 1000);
  return Date.UTC(d.getFullYear(), d.getMonth(), d.getDate(), d.getHours(), d.getMinutes(), d.getSeconds(), d.getMilliseconds()) / 1000;
}

/**
 * Format time in 12-hour format for tick marks
 */
function formatTime12Hour(time) {
  const date = new Date(time * 1000);
  let hours = date.getUTCHours();
  const minutes = date.getUTCMinutes();
  const roundedMinutes = Math.round(minutes / 15) * 15;

  let adjustedHours = hours;
  let adjustedMinutes = roundedMinutes;

  if (roundedMinutes === 60) {
    adjustedMinutes = 0;
    adjustedHours = (hours + 1) % 24;
  }

  const ampm = adjustedHours >= 12 ? 'PM' : 'AM';
  const hour12 = adjustedHours % 12 || 12;
  const minuteStr = adjustedMinutes.toString().padStart(2, '0');
  return `${hour12}:${minuteStr} ${ampm}`;
}

/**
 * Format time in 12-hour format for crosshair (exact time)
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

/**
 * SymbolChart Hook - Chart with trade markers for historical analysis
 *
 * This hook creates a candlestick chart with trade entry/exit markers.
 * Used for reviewing trades on a specific date.
 */
export const SymbolChart = {
  mounted() {
    const symbol = this.el.dataset.symbol;
    console.log('SymbolChart mounted for', symbol);

    const width = Math.max(this.el.clientWidth, 400);
    const height = 600;

    // Create chart with dark theme
    this.chart = createChart(this.el, {
      width: width,
      height: height,
      layout: {
        background: { color: '#18181b' },
        textColor: '#a1a1aa',
        attributionLogo: false,
      },
      grid: {
        vertLines: { color: '#3f3f46' },
        horzLines: { color: '#3f3f46' },
      },
      crosshair: {
        mode: 0,
        vertLine: {
          color: '#71717a',
          width: 1,
          style: 3,
          labelBackgroundColor: '#3f3f46',
        },
        horzLine: {
          color: '#71717a',
          width: 1,
          style: 3,
          labelBackgroundColor: '#3f3f46',
        },
      },
      rightPriceScale: {
        borderColor: '#3f3f46',
      },
      timeScale: {
        borderColor: '#3f3f46',
        timeVisible: true,
        secondsVisible: false,
        tickMarkFormatter: (time) => formatTime12Hour(time),
      },
      localization: {
        timeFormatter: (time) => formatTimeExact(time),
      },
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

    // Add volume series
    this.volumeSeries = this.chart.addSeries(HistogramSeries, {
      color: '#3f3f46',
      priceFormat: {
        type: 'volume',
      },
      priceScaleId: '',
    });

    this.volumeSeries.priceScale().applyOptions({
      scaleMargins: {
        top: 0.8,
        bottom: 0,
      },
    });

    // Create session highlighter
    this.sessionHighlighter = new SessionHighlighter();
    this.candleSeries.attachPrimitive(this.sessionHighlighter);

    // Create trade zone primitive for shaded areas
    this.tradeZonePrimitive = new TradeZonePrimitive();
    this.candleSeries.attachPrimitive(this.tradeZonePrimitive);

    // Store price lines for key levels (must be initialized before loadChartData)
    this.priceLines = [];

    // Store price lines for trades
    this.tradeLines = [];

    // Load initial data
    this.loadChartData();

    // Listen for data updates from LiveView
    this.handleEvent('chart-data-updated', ({ bars, trades, levels }) => {
      this.updateChartData(bars, trades, levels);
    });

    // Handle resize
    this.resizeObserver = new ResizeObserver(entries => {
      if (entries.length === 0 || !entries[0].target) return;
      const { width, height } = entries[0].contentRect;
      this.chart.applyOptions({ width, height: height || 600 });
    });

    this.resizeObserver.observe(this.el);
  },

  loadChartData() {
    const rawBars = this.el.dataset.initialBars;
    const rawTrades = this.el.dataset.trades;
    const rawLevels = this.el.dataset.levels;

    const initialBars = JSON.parse(rawBars || '[]');
    const trades = JSON.parse(rawTrades || '[]');
    const levels = JSON.parse(rawLevels || '[]');

    this.setChartData(initialBars, trades, levels);
  },

  updateChartData(bars, trades, levels) {
    this.setChartData(bars || [], trades || [], levels || []);
  },

  setChartData(bars, trades, levels) {
    // Clear existing price lines
    this.clearPriceLines();
    this.clearTradeLines();

    if (bars.length === 0) {
      this.candleSeries.setData([]);
      this.volumeSeries.setData([]);
      // Clear markers if they exist
      if (this.seriesMarkers) {
        this.seriesMarkers.setMarkers([]);
      }
      return;
    }

    // Transform and set candle data
    const candleData = bars.map(bar => ({
      time: timeToLocal(bar.time),
      open: parseFloat(bar.open),
      high: parseFloat(bar.high),
      low: parseFloat(bar.low),
      close: parseFloat(bar.close),
    }));

    const volumeData = bars.map(bar => ({
      time: timeToLocal(bar.time),
      value: bar.volume,
      color: bar.close >= bar.open ? '#10b98133' : '#ef444433',
    }));

    // Update session highlighter
    const sessionData = bars.map(bar => ({
      localTime: timeToLocal(bar.time),
      utcTime: bar.time,
    }));
    this.sessionHighlighter.setData(sessionData);

    this.candleSeries.setData(candleData);
    this.volumeSeries.setData(volumeData);

    // Draw trade lines (entry, stop, target) instead of markers
    this.drawTradeLines(trades || []);

    // Draw key level price lines
    this.drawLevelLines(levels || []);

    // Fit content to view
    this.chart.timeScale().fitContent();
  },

  clearPriceLines() {
    // Remove all existing price lines
    for (const line of this.priceLines) {
      this.candleSeries.removePriceLine(line);
    }
    this.priceLines = [];
  },

  clearTradeLines() {
    // Remove all existing trade lines
    for (const line of this.tradeLines) {
      this.candleSeries.removePriceLine(line);
    }
    this.tradeLines = [];

    // Clear the trade zone primitive
    if (this.tradeZonePrimitive) {
      this.tradeZonePrimitive.setTrades([]);
    }
  },

  drawTradeLines(trades) {
    // Update the trade zone primitive with trades (for shaded areas)
    if (this.tradeZonePrimitive) {
      // Convert times to local for the primitive
      const tradesWithLocalTime = (trades || []).map(trade => ({
        ...trade,
        entry_time: trade.entry_time ? timeToLocal(trade.entry_time) : null,
        exit_time: trade.exit_time ? timeToLocal(trade.exit_time) : null,
      }));
      this.tradeZonePrimitive.setTrades(tradesWithLocalTime);
    }

    if (!trades || trades.length === 0) {
      return;
    }

    for (const trade of trades) {
      const isLong = trade.direction === 'long';
      const entryColor = isLong ? '#10b981' : '#ef4444'; // green for long, red for short

      // Entry line - solid
      if (trade.entry_price && trade.entry_price !== '-') {
        const entryLine = this.candleSeries.createPriceLine({
          price: parseFloat(trade.entry_price),
          color: entryColor,
          lineWidth: 2,
          lineStyle: 0, // Solid
          axisLabelVisible: true,
          title: `${trade.direction.toUpperCase()} Entry`,
        });
        this.tradeLines.push(entryLine);
      }

      // Stop loss line - dashed red
      if (trade.stop_loss && trade.stop_loss !== '-') {
        const stopLine = this.candleSeries.createPriceLine({
          price: parseFloat(trade.stop_loss),
          color: '#ef4444',
          lineWidth: 1,
          lineStyle: 2, // Dashed
          axisLabelVisible: true,
          title: 'Stop',
        });
        this.tradeLines.push(stopLine);
      }

      // Take profit line - dashed green
      if (trade.take_profit && trade.take_profit !== '-') {
        const targetR = trade.target_r || '2.0';
        const targetLine = this.candleSeries.createPriceLine({
          price: parseFloat(trade.take_profit),
          color: '#10b981',
          lineWidth: 1,
          lineStyle: 2, // Dashed
          axisLabelVisible: true,
          title: `Target (${targetR}R)`,
        });
        this.tradeLines.push(targetLine);
      }

      // Exit line - dotted, color based on result
      if (trade.exit_price && trade.exit_price !== '-') {
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
          lineStyle: 1, // Dotted
          axisLabelVisible: true,
          title: `Exit (${trade.r_multiple || '0'}R)`,
        });
        this.tradeLines.push(exitLine);
      }
    }
  },

  drawLevelLines(levels) {
    if (!levels || levels.length === 0) {
      return;
    }

    for (const level of levels) {
      const price = parseFloat(level.price);
      if (isNaN(price)) continue;

      const line = this.candleSeries.createPriceLine({
        price: price,
        color: level.color,
        lineWidth: 1,
        lineStyle: 2, // Dashed line
        axisLabelVisible: true,
        title: level.label,
      });

      this.priceLines.push(line);
    }
  },

  destroyed() {
    if (this.resizeObserver) {
      this.resizeObserver.disconnect();
    }
    if (this.chart) {
      this.chart.remove();
    }
  }
};

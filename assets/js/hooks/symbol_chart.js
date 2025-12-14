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
 * Easing function for smooth animation (ease-out cubic)
 */
function easeOutCubic(t) {
  return 1 - Math.pow(1 - t, 3);
}

/**
 * Animate the chart's visible time range
 * @param {Object} chart - Lightweight Charts instance
 * @param {Object} targetRange - Target range { from, to }
 * @param {number} duration - Animation duration in ms
 * @param {Function} onComplete - Callback when animation completes
 */
function animateTimeRange(chart, targetRange, duration = 250, onComplete = null) {
  const timeScale = chart.timeScale();
  const startRange = timeScale.getVisibleRange();

  if (!startRange) {
    timeScale.setVisibleRange(targetRange);
    if (onComplete) onComplete();
    return;
  }

  const startTime = performance.now();
  const startFrom = startRange.from;
  const startTo = startRange.to;
  const deltaFrom = targetRange.from - startFrom;
  const deltaTo = targetRange.to - startTo;

  function animate(currentTime) {
    const elapsed = currentTime - startTime;
    const progress = Math.min(elapsed / duration, 1);
    const easedProgress = easeOutCubic(progress);

    const currentFrom = startFrom + deltaFrom * easedProgress;
    const currentTo = startTo + deltaTo * easedProgress;

    timeScale.setVisibleRange({ from: currentFrom, to: currentTo });

    if (progress < 1) {
      requestAnimationFrame(animate);
    } else if (onComplete) {
      onComplete();
    }
  }

  requestAnimationFrame(animate);
}

/**
 * Animate both time range and price range together for smooth zoom effect
 * @param {Object} chart - Lightweight Charts instance
 * @param {Object} series - The candle series
 * @param {Object} targetTimeRange - Target time range { from, to }
 * @param {Object} startPriceRange - Starting price range { minValue, maxValue }
 * @param {Object} targetPriceRange - Target price range { minValue, maxValue }
 * @param {number} duration - Animation duration in ms
 * @param {Function} onComplete - Callback when animation completes
 */
function animateChartZoom(chart, series, targetTimeRange, startPriceRange, targetPriceRange, duration = 250, onComplete = null) {
  const timeScale = chart.timeScale();
  const startTimeRange = timeScale.getVisibleRange();

  if (!startTimeRange) {
    timeScale.setVisibleRange(targetTimeRange);
    series.applyOptions({
      autoscaleInfoProvider: () => ({ priceRange: targetPriceRange }),
    });
    if (onComplete) onComplete();
    return;
  }

  const startTime = performance.now();

  // Time range deltas
  const startTimeFrom = startTimeRange.from;
  const startTimeTo = startTimeRange.to;
  const deltaTimeFrom = targetTimeRange.from - startTimeFrom;
  const deltaTimeTo = targetTimeRange.to - startTimeTo;

  // Price range deltas
  const startPriceMin = startPriceRange.minValue;
  const startPriceMax = startPriceRange.maxValue;
  const deltaPriceMin = targetPriceRange.minValue - startPriceMin;
  const deltaPriceMax = targetPriceRange.maxValue - startPriceMax;

  function animate(currentTime) {
    const elapsed = currentTime - startTime;
    const progress = Math.min(elapsed / duration, 1);
    const easedProgress = easeOutCubic(progress);

    // Interpolate time range
    const currentTimeFrom = startTimeFrom + deltaTimeFrom * easedProgress;
    const currentTimeTo = startTimeTo + deltaTimeTo * easedProgress;
    timeScale.setVisibleRange({ from: currentTimeFrom, to: currentTimeTo });

    // Interpolate price range
    const currentPriceMin = startPriceMin + deltaPriceMin * easedProgress;
    const currentPriceMax = startPriceMax + deltaPriceMax * easedProgress;
    series.applyOptions({
      autoscaleInfoProvider: () => ({
        priceRange: { minValue: currentPriceMin, maxValue: currentPriceMax },
      }),
    });

    if (progress < 1) {
      requestAnimationFrame(animate);
    } else if (onComplete) {
      onComplete();
    }
  }

  requestAnimationFrame(animate);
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

    // Store full range for restoring after zoom
    this._fullRange = null;

    // Listen for trade highlight events via custom DOM events (client-side only, no server round-trip)
    this._highlightHandler = (e) => {
      const tradeId = e.detail?.id;
      if (this.tradeZonePrimitive && this._candleData) {
        this.tradeZonePrimitive.setHighlightedTrade(tradeId);
        // Force primitive redraw by re-setting the candle data
        this.candleSeries.setData(this._candleData);
      }
    };

    this._unhighlightHandler = () => {
      if (this.tradeZonePrimitive && this._candleData) {
        this.tradeZonePrimitive.setHighlightedTrade(null);
        // Force primitive redraw by re-setting the candle data
        this.candleSeries.setData(this._candleData);
      }
    };

    window.addEventListener('trade-highlight', this._highlightHandler);
    window.addEventListener('trade-unhighlight', this._unhighlightHandler);

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
      this._candleData = [];
      this._trades = [];
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

    // Store for later use (price scale fitting)
    this._candleData = candleData;
    this._trades = trades || [];

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

    // Ensure all trade levels are visible in the price scale
    this.fitPriceScale(candleData, trades || []);
  },

  fitPriceScale(candleData, trades) {
    // Collect all prices that need to be visible
    const prices = [];

    // Add bar highs and lows
    for (const bar of candleData) {
      prices.push(bar.high);
      prices.push(bar.low);
    }

    // Add trade levels (stop loss and take profit)
    for (const trade of trades) {
      if (trade.entry_price && trade.entry_price !== '-') {
        prices.push(parseFloat(trade.entry_price));
      }
      if (trade.stop_loss && trade.stop_loss !== '-') {
        prices.push(parseFloat(trade.stop_loss));
      }
      if (trade.take_profit && trade.take_profit !== '-') {
        prices.push(parseFloat(trade.take_profit));
      }
      if (trade.exit_price && trade.exit_price !== '-') {
        prices.push(parseFloat(trade.exit_price));
      }
    }

    if (prices.length === 0) return;

    // Calculate min and max with some padding
    const minPrice = Math.min(...prices);
    const maxPrice = Math.max(...prices);
    const range = maxPrice - minPrice;
    const padding = range * 0.05; // 5% padding on each side

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

  calculateTradePriceRange(trade, fromTime, toTime) {
    // Collect prices relevant to this specific trade
    const prices = [];

    // Add trade levels (entry, stop, target)
    if (trade.entry_price && trade.entry_price !== '-') {
      prices.push(parseFloat(trade.entry_price));
    }
    if (trade.stop_loss && trade.stop_loss !== '-') {
      prices.push(parseFloat(trade.stop_loss));
    }
    if (trade.take_profit && trade.take_profit !== '-') {
      prices.push(parseFloat(trade.take_profit));
    }
    if (trade.exit_price && trade.exit_price !== '-') {
      prices.push(parseFloat(trade.exit_price));
    }
    // Add the key level that triggered the trade
    if (trade.level_price && trade.level_price !== '-') {
      prices.push(parseFloat(trade.level_price));
    }

    // Add bar highs and lows within the visible time range
    for (const bar of this._candleData) {
      if (bar.time >= fromTime && bar.time <= toTime) {
        prices.push(bar.high);
        prices.push(bar.low);
      }
    }

    if (prices.length === 0) {
      return this.calculateFullPriceRange();
    }

    // Calculate min and max with padding for centering
    const minPrice = Math.min(...prices);
    const maxPrice = Math.max(...prices);
    const range = maxPrice - minPrice;
    const padding = range * 0.25; // 25% padding for better centering

    return {
      minValue: minPrice - padding,
      maxValue: maxPrice + padding,
    };
  },

  calculateFullPriceRange() {
    // Calculate price range from all bars and trades
    const prices = [];

    // Add bar highs and lows
    for (const bar of this._candleData) {
      prices.push(bar.high);
      prices.push(bar.low);
    }

    // Add trade levels
    for (const trade of this._trades) {
      if (trade.entry_price && trade.entry_price !== '-') {
        prices.push(parseFloat(trade.entry_price));
      }
      if (trade.stop_loss && trade.stop_loss !== '-') {
        prices.push(parseFloat(trade.stop_loss));
      }
      if (trade.take_profit && trade.take_profit !== '-') {
        prices.push(parseFloat(trade.take_profit));
      }
      if (trade.exit_price && trade.exit_price !== '-') {
        prices.push(parseFloat(trade.exit_price));
      }
    }

    if (prices.length === 0) {
      return { minValue: 0, maxValue: 100 };
    }

    const minPrice = Math.min(...prices);
    const maxPrice = Math.max(...prices);
    const range = maxPrice - minPrice;
    const padding = range * 0.05;

    return {
      minValue: minPrice - padding,
      maxValue: maxPrice + padding,
    };
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
    // Update the trade zone primitive with trades (for shaded areas only)
    // Price lines for entry/stop/target/exit are not drawn on the main chart
    // - they clutter the view when there are multiple trades
    // - detailed trade info is shown in the trade detail modal chart
    if (this.tradeZonePrimitive) {
      // Convert times to local for the primitive
      const tradesWithLocalTime = (trades || []).map(trade => ({
        ...trade,
        entry_time: trade.entry_time ? timeToLocal(trade.entry_time) : null,
        exit_time: trade.exit_time ? timeToLocal(trade.exit_time) : null,
      }));
      this.tradeZonePrimitive.setTrades(tradesWithLocalTime);
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
    if (this._highlightHandler) {
      window.removeEventListener('trade-highlight', this._highlightHandler);
    }
    if (this._unhighlightHandler) {
      window.removeEventListener('trade-unhighlight', this._unhighlightHandler);
    }
    if (this.chart) {
      this.chart.remove();
    }
  }
};

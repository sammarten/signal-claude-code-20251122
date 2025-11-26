import { createChart, CandlestickSeries, HistogramSeries } from 'lightweight-charts';
import { SessionHighlighter } from './session_highlighter';
import { KeyLevelsManager } from './key_levels';
import { MarketStructureManager } from './market_structure';

/**
 * Convert UTC timestamp to browser's local timezone
 * This shifts the displayed time to match the user's local time
 */
function timeToLocal(originalTime) {
  const d = new Date(originalTime * 1000);
  return Date.UTC(d.getFullYear(), d.getMonth(), d.getDate(), d.getHours(), d.getMinutes(), d.getSeconds(), d.getMilliseconds()) / 1000;
}

/**
 * Round minutes to nearest 15-minute interval (0, 15, 30, 45)
 */
function roundToNearest15(minutes) {
  return Math.round(minutes / 15) * 15;
}

/**
 * Format time in 12-hour format for tick marks
 * Rounds to nearest 15-minute interval for cleaner display
 */
function formatTime12Hour(time) {
  const date = new Date(time * 1000);
  let hours = date.getUTCHours();
  const minutes = date.getUTCMinutes();

  // Round to nearest 15-minute interval
  let roundedMinutes = roundToNearest15(minutes);

  // Handle rollover (e.g., 8:53 rounds to 9:00)
  if (roundedMinutes === 60) {
    roundedMinutes = 0;
    hours = (hours + 1) % 24;
  }

  const ampm = hours >= 12 ? 'PM' : 'AM';
  const hour12 = hours % 12 || 12;
  const minuteStr = roundedMinutes.toString().padStart(2, '0');
  return `${hour12}:${minuteStr} ${ampm}`;
}

/**
 * Format time in 12-hour format for hover/crosshair
 * Shows exact timestamp without rounding
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
 * TradingChart Hook - Lightweight Charts integration for real-time market data
 *
 * This hook creates and manages a candlestick chart with real-time updates.
 * It subscribes to Phoenix LiveView events for bar updates.
 */
export const TradingChart = {
  mounted() {
    const symbol = this.el.dataset.symbol;
    console.log('TradingChart mounted for', symbol);
    console.log('Container width:', this.el.clientWidth);
    console.log('Container height:', this.el.clientHeight);

    // Ensure container has minimum dimensions
    const width = Math.max(this.el.clientWidth, 400);
    const height = 500;

    // Create chart with dark theme matching zinc-950
    this.chart = createChart(this.el, {
      width: width,
      height: height,
      layout: {
        background: { color: '#18181b' }, // zinc-900 (lighter for visibility)
        textColor: '#a1a1aa', // zinc-400
        attributionLogo: false, // Disable TradingView logo to prevent duplicate ID warnings
      },
      grid: {
        vertLines: { color: '#3f3f46' }, // zinc-700 (more visible)
        horzLines: { color: '#3f3f46' }, // zinc-700 (more visible)
      },
      crosshair: {
        mode: 0, // Normal crosshair
        vertLine: {
          color: '#71717a',
          width: 1,
          style: 3, // Dashed
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
        borderColor: '#3f3f46', // zinc-700
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

    // Create candlestick series with custom colors (v5 API)
    this.candleSeries = this.chart.addSeries(CandlestickSeries, {
      upColor: '#10b981', // green-500
      downColor: '#ef4444', // red-500
      borderUpColor: '#10b981',
      borderDownColor: '#ef4444',
      wickUpColor: '#10b981',
      wickDownColor: '#ef4444',
    });

    // Add volume series (v5 API)
    this.volumeSeries = this.chart.addSeries(HistogramSeries, {
      color: '#3f3f46',
      priceFormat: {
        type: 'volume',
      },
      priceScaleId: '', // render as overlay
    });

    // Apply scale margins to volume series price scale (v5 requires this separate call)
    this.volumeSeries.priceScale().applyOptions({
      scaleMargins: {
        top: 0.8,
        bottom: 0,
      },
    });

    // Create and attach session highlighter for market hours visualization
    this.sessionHighlighter = new SessionHighlighter();
    this.candleSeries.attachPrimitive(this.sessionHighlighter);

    // Create key levels manager for price lines
    this.keyLevelsManager = new KeyLevelsManager(this.candleSeries);

    // Load initial key levels
    const initialLevels = JSON.parse(this.el.dataset.keyLevels || '{}');
    if (Object.keys(initialLevels).length > 0) {
      console.log('Initial key levels:', initialLevels);
      this.keyLevelsManager.setLevels(initialLevels);
    }

    // Create market structure manager for swing/BOS/ChoCh lines
    this.marketStructureManager = new MarketStructureManager(this.candleSeries);

    // Load initial market structure
    const initialStructure = JSON.parse(this.el.dataset.marketStructure || '{}');
    console.log('Initial market structure for', symbol, ':', initialStructure);
    console.log('Raw data-market-structure:', this.el.dataset.marketStructure);
    const hasStructureData = initialStructure.swing_highs?.length > 0 ||
                              initialStructure.swing_lows?.length > 0 ||
                              initialStructure.bos?.length > 0 ||
                              initialStructure.choch?.length > 0;
    if (hasStructureData) {
      console.log('Setting initial market structure');
      this.marketStructureManager.setStructure(initialStructure);
    } else {
      console.log('No structure data to display');
    }

    // Load initial data
    const initialData = JSON.parse(this.el.dataset.initialBars || '[]');
    console.log('Initial data:', initialData.length, 'bars');

    if (initialData.length > 0) {
      console.log('First bar:', initialData[0]);
      console.log('Last bar:', initialData[initialData.length - 1]);

      const candleData = initialData.map(bar => ({
        time: timeToLocal(bar.time),
        open: parseFloat(bar.open),
        high: parseFloat(bar.high),
        low: parseFloat(bar.low),
        close: parseFloat(bar.close),
      }));

      const volumeData = initialData.map(bar => ({
        time: timeToLocal(bar.time),
        value: bar.volume,
        color: bar.close >= bar.open ? '#10b98133' : '#ef444433',
      }));

      console.log('Setting candle data:', candleData.length, 'points');
      this.candleSeries.setData(candleData);
      this.volumeSeries.setData(volumeData);

      // Update session highlighter with both local time (for coordinates) and UTC time (for session detection)
      const sessionData = initialData.map(bar => ({
        localTime: timeToLocal(bar.time),
        utcTime: bar.time,
      }));
      this.sessionHighlighter.setData(sessionData);
      this._sessionData = sessionData;

      console.log('Chart data loaded successfully');
    } else {
      console.warn('No initial data available for chart');
      this._sessionData = [];
    }

    // Track current candle for real-time updates
    // Initialize from the last bar if available
    if (initialData.length > 0) {
      const lastBar = initialData[initialData.length - 1];
      this.currentCandle = {
        time: timeToLocal(lastBar.time),
        open: parseFloat(lastBar.open),
        high: parseFloat(lastBar.high),
        low: parseFloat(lastBar.low),
        close: parseFloat(lastBar.close),
      };
    } else {
      this.currentCandle = null;
    }

    // Listen for new bar updates from LiveView (symbol-specific events)
    this.handleEvent(`bar-update-${symbol}`, ({ bar }) => {
      this.updateBar(bar);
    });

    // Listen for real-time price updates from quotes
    this.handleEvent(`price-update-${symbol}`, ({ data }) => {
      this.updatePrice(data);
    });

    // Listen for key level updates
    this.handleEvent(`levels-update-${symbol}`, ({ levels }) => {
      console.log('Key levels updated:', levels);
      this.keyLevelsManager.setLevels(levels);
    });

    // Listen for market structure updates
    this.handleEvent(`structure-update-${symbol}`, ({ structure }) => {
      console.log('Market structure updated:', structure);
      this.marketStructureManager.setStructure(structure);
    });

    // Handle window resize
    this.resizeObserver = new ResizeObserver(entries => {
      if (entries.length === 0 || !entries[0].target) return;
      const { width, height } = entries[0].contentRect;
      this.chart.applyOptions({ width, height: height || 500 });
    });

    this.resizeObserver.observe(this.el);
  },

  updateBar(bar) {
    // Ensure time is a number (LiveView JSON can sometimes serialize differently)
    const barTime = typeof bar.time === 'number' ? bar.time : parseInt(bar.time, 10);
    const localTime = timeToLocal(barTime);

    // Only update if the new bar time is >= the current candle time (prevent stale updates)
    if (this.currentCandle && localTime < this.currentCandle.time) {
      console.log('Skipping stale bar update:', localTime, '<', this.currentCandle.time);
      return;
    }

    const candlePoint = {
      time: localTime,
      open: parseFloat(bar.open),
      high: parseFloat(bar.high),
      low: parseFloat(bar.low),
      close: parseFloat(bar.close),
    };

    const volumePoint = {
      time: localTime,
      value: bar.volume,
      color: parseFloat(bar.close) >= parseFloat(bar.open) ? '#10b98133' : '#ef444433',
    };

    this.candleSeries.update(candlePoint);
    this.volumeSeries.update(volumePoint);

    // Update session highlighter data for new bar
    const existingIndex = this._sessionData.findIndex(d => d.localTime === localTime);
    if (existingIndex === -1) {
      this._sessionData.push({ localTime, utcTime: barTime });
      this.sessionHighlighter.setData(this._sessionData);
    }

    // Update current candle tracker
    this.currentCandle = candlePoint;
  },

  updatePrice(data) {
    // Ensure time is a number
    const dataTime = typeof data.time === 'number' ? data.time : parseInt(data.time, 10);
    const localTime = timeToLocal(dataTime);
    const price = parseFloat(data.price);

    // Check if this is a new candle (new minute) or update to current
    if (!this.currentCandle || localTime > this.currentCandle.time) {
      // New candle - start fresh with this price
      this.currentCandle = {
        time: localTime,
        open: price,
        high: price,
        low: price,
        close: price,
      };

      // Update session highlighter for new candle
      const existingIndex = this._sessionData.findIndex(d => d.localTime === localTime);
      if (existingIndex === -1) {
        this._sessionData.push({ localTime, utcTime: dataTime });
        this.sessionHighlighter.setData(this._sessionData);
      }
    } else if (localTime === this.currentCandle.time) {
      // Same candle - update close and potentially high/low
      this.currentCandle.close = price;
      if (price > this.currentCandle.high) {
        this.currentCandle.high = price;
      }
      if (price < this.currentCandle.low) {
        this.currentCandle.low = price;
      }
    }
    // Ignore if localTime < currentCandle.time (stale data)

    // Update the chart
    if (this.currentCandle) {
      this.candleSeries.update(this.currentCandle);
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

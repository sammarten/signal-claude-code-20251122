import { createChart, CandlestickSeries, HistogramSeries } from 'lightweight-charts';

/**
 * Convert UTC timestamp to browser's local timezone
 * This shifts the displayed time to match the user's local time
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
        timeFormatter: (time) => formatTime12Hour(time),
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
      console.log('Chart data loaded successfully');
    } else {
      console.warn('No initial data available for chart');
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

    // Handle window resize
    this.resizeObserver = new ResizeObserver(entries => {
      if (entries.length === 0 || !entries[0].target) return;
      const { width, height } = entries[0].contentRect;
      this.chart.applyOptions({ width, height: height || 500 });
    });

    this.resizeObserver.observe(this.el);
  },

  updateBar(bar) {
    const localTime = timeToLocal(bar.time);
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
      color: bar.close >= bar.open ? '#10b98133' : '#ef444433',
    };

    this.candleSeries.update(candlePoint);
    this.volumeSeries.update(volumePoint);

    // Update current candle tracker
    this.currentCandle = candlePoint;
  },

  updatePrice(data) {
    const localTime = timeToLocal(data.time);
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

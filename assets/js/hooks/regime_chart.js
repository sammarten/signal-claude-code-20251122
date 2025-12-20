import { createChart, CandlestickSeries, createSeriesMarkers } from 'lightweight-charts';

/**
 * RegimeChart - Annotated candlestick chart for regime explanation
 *
 * Shows 20-day price action with:
 * - Swing high/low markers (triangles)
 * - Range bounds (horizontal lines if ranging)
 * - Dark theme matching the preview page
 */

export const RegimeChart = {
  mounted() {
    // Defer chart creation to ensure container has dimensions
    // This is critical for dynamically shown elements (expandable sections)
    requestAnimationFrame(() => this.initChart());
  },

  initChart() {
    let bars = [];
    let swingPoints = [];

    try {
      bars = JSON.parse(this.el.dataset.bars || '[]');
    } catch (e) {
      console.warn('RegimeChart: Failed to parse bars data', e);
      bars = [];
    }

    try {
      swingPoints = JSON.parse(this.el.dataset.swingPoints || '[]');
    } catch (e) {
      console.warn('RegimeChart: Failed to parse swing points data', e);
      swingPoints = [];
    }

    const rangeHigh = parseFloat(this.el.dataset.rangeHigh);
    const rangeLow = parseFloat(this.el.dataset.rangeLow);
    const regime = this.el.dataset.regime;

    // Early return if no valid bar data
    if (!bars || bars.length === 0) {
      console.warn('RegimeChart: No bar data available');
      return;
    }

    // Get container dimensions - ensure we have valid dimensions before creating chart
    const rect = this.el.getBoundingClientRect();
    const width = rect.width || this.el.clientWidth || 600;
    const height = rect.height || this.el.clientHeight || 300;

    // If container still has no dimensions, retry after another frame
    if (width === 0 || height === 0) {
      console.warn('RegimeChart: Container has zero dimensions, retrying...');
      requestAnimationFrame(() => this.initChart());
      return;
    }

    // Create chart with dark theme and explicit dimensions
    this.chart = createChart(this.el, {
      width: width,
      height: height,
      layout: {
        background: { color: 'transparent' },
        textColor: '#a1a1aa',
        attributionLogo: false,
      },
      grid: {
        vertLines: { color: '#27272a', style: 1 },
        horzLines: { color: '#27272a', style: 1 },
      },
      crosshair: {
        mode: 1,
        vertLine: { color: '#71717a', labelBackgroundColor: '#27272a' },
        horzLine: { color: '#71717a', labelBackgroundColor: '#27272a' },
      },
      rightPriceScale: {
        borderColor: '#3f3f46',
        scaleMargins: { top: 0.1, bottom: 0.1 },
      },
      timeScale: {
        borderColor: '#3f3f46',
        timeVisible: true,
        secondsVisible: false,
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

    if (bars.length > 0) {
      // Filter out any bars with null/undefined values to prevent Lightweight Charts errors
      const validBars = bars.filter(bar =>
        bar.time != null &&
        bar.open != null &&
        bar.high != null &&
        bar.low != null &&
        bar.close != null
      );

      if (validBars.length === 0) {
        console.warn('RegimeChart: No valid bars after filtering');
        return;
      }

      // Convert to proper number types and sort by time (Lightweight Charts requires ascending order)
      const candleData = validBars
        .map(bar => ({
          time: Number(bar.time),
          open: Number(bar.open),
          high: Number(bar.high),
          low: Number(bar.low),
          close: Number(bar.close),
        }))
        .sort((a, b) => a.time - b.time);

      this.candleSeries.setData(candleData);

      // Add range bounds for ranging/breakout_pending regimes
      if ((regime === 'ranging' || regime === 'breakout_pending') && !isNaN(rangeHigh) && !isNaN(rangeLow)) {
        this.rangeHighLine = this.candleSeries.createPriceLine({
          price: rangeHigh,
          color: '#f59e0b',
          lineWidth: 2,
          lineStyle: 2, // Dashed
          axisLabelVisible: true,
          title: 'Range High',
        });

        this.rangeLowLine = this.candleSeries.createPriceLine({
          price: rangeLow,
          color: '#f59e0b',
          lineWidth: 2,
          lineStyle: 2, // Dashed
          axisLabelVisible: true,
          title: 'Range Low',
        });
      }

      // Add swing point markers using v5 API
      if (swingPoints.length > 0) {
        const markers = swingPoints.map(point => ({
          time: Number(point.time),
          position: point.type === 'high' ? 'aboveBar' : 'belowBar',
          color: point.type === 'high' ? '#ef4444' : '#10b981',
          shape: point.type === 'high' ? 'arrowDown' : 'arrowUp',
          text: point.type === 'high' ? 'SH' : 'SL',
        }));

        // v5 API: use createSeriesMarkers instead of series.setMarkers
        createSeriesMarkers(this.candleSeries, markers);
      }

      // Fit content
      this.chart.timeScale().fitContent();
    }

    // Handle resize
    this.resizeObserver = new ResizeObserver(entries => {
      if (entries.length === 0 || entries[0].target !== this.el) return;
      const { width } = entries[0].contentRect;
      this.chart.applyOptions({ width });
    });
    this.resizeObserver.observe(this.el);
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

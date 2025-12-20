import { createChart, LineSeries } from 'lightweight-charts';

/**
 * DivergenceChart - Multi-line chart showing cumulative returns
 *
 * Displays SPY, QQQ, and DIA cumulative returns over 25 days
 * to visualize index divergence patterns.
 */

export const DivergenceChart = {
  mounted() {
    // Defer chart creation to ensure container has dimensions
    // This is critical for dynamically shown elements (expandable sections)
    requestAnimationFrame(() => this.initChart());
  },

  initChart() {
    let spyData = [];
    let qqqData = [];
    let diaData = [];

    try {
      spyData = JSON.parse(this.el.dataset.spy || '[]');
    } catch (e) {
      console.warn('DivergenceChart: Failed to parse SPY data', e);
      spyData = [];
    }

    try {
      qqqData = JSON.parse(this.el.dataset.qqq || '[]');
    } catch (e) {
      console.warn('DivergenceChart: Failed to parse QQQ data', e);
      qqqData = [];
    }

    try {
      diaData = JSON.parse(this.el.dataset.dia || '[]');
    } catch (e) {
      console.warn('DivergenceChart: Failed to parse DIA data', e);
      diaData = [];
    }

    // Early return if no data at all
    if (spyData.length === 0 && qqqData.length === 0 && diaData.length === 0) {
      console.warn('DivergenceChart: No data available');
      return;
    }

    // Get container dimensions - ensure we have valid dimensions before creating chart
    const rect = this.el.getBoundingClientRect();
    const width = rect.width || this.el.clientWidth || 600;
    const height = rect.height || this.el.clientHeight || 250;

    // If container still has no dimensions, retry after another frame
    if (width === 0 || height === 0) {
      console.warn('DivergenceChart: Container has zero dimensions, retrying...');
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

    // SPY line (blue)
    this.spySeries = this.chart.addSeries(LineSeries, {
      color: '#3b82f6',
      lineWidth: 2,
      priceLineVisible: false,
      lastValueVisible: true,
      title: 'SPY',
    });

    // QQQ line (purple)
    this.qqqSeries = this.chart.addSeries(LineSeries, {
      color: '#a855f7',
      lineWidth: 2,
      priceLineVisible: false,
      lastValueVisible: true,
      title: 'QQQ',
    });

    // DIA line (amber)
    this.diaSeries = this.chart.addSeries(LineSeries, {
      color: '#f59e0b',
      lineWidth: 2,
      priceLineVisible: false,
      lastValueVisible: true,
      title: 'DIA',
    });

    // Helper to filter, format, and sort data points
    const formatSeries = (data) => {
      // Filter out points with null/undefined values
      const validPoints = data.filter(d => d.time != null && d.value != null);
      // Convert to numbers and sort by time (Lightweight Charts requires ascending order)
      return validPoints
        .map(d => ({
          time: Number(d.time),
          value: Number(d.value),
        }))
        .sort((a, b) => a.time - b.time);
    };

    // Set data for each series
    if (spyData.length > 0) {
      const formatted = formatSeries(spyData);
      if (formatted.length > 0) {
        this.spySeries.setData(formatted);
      }
    }

    if (qqqData.length > 0) {
      const formatted = formatSeries(qqqData);
      if (formatted.length > 0) {
        this.qqqSeries.setData(formatted);
      }
    }

    if (diaData.length > 0) {
      const formatted = formatSeries(diaData);
      if (formatted.length > 0) {
        this.diaSeries.setData(formatted);
      }
    }

    // Add zero line for reference
    if (spyData.length > 0) {
      this.spySeries.createPriceLine({
        price: 0,
        color: '#52525b',
        lineWidth: 1,
        lineStyle: 2, // Dashed
        axisLabelVisible: false,
      });
    }

    // Fit content
    this.chart.timeScale().fitContent();

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

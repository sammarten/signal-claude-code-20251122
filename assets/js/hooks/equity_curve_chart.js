import { createChart, BaselineSeries } from 'lightweight-charts';

/**
 * EquityCurveChart - Visualizes backtest equity over time
 *
 * Features:
 * - Baseline series showing equity (green above initial, red below)
 * - Horizontal line at initial capital
 * - Date axis showing trading days
 * - Tooltips with equity and drawdown values
 */

/**
 * Convert date string or timestamp to chart time format
 */
function parseTime(timeValue) {
  if (typeof timeValue === 'number') {
    // Unix timestamp in seconds
    return timeValue;
  }
  if (typeof timeValue === 'string') {
    // ISO date string - convert to unix timestamp
    const date = new Date(timeValue);
    return Math.floor(date.getTime() / 1000);
  }
  return timeValue;
}

/**
 * Format currency for display
 */
function formatCurrency(value) {
  return new Intl.NumberFormat('en-US', {
    style: 'currency',
    currency: 'USD',
    minimumFractionDigits: 0,
    maximumFractionDigits: 0,
  }).format(value);
}

export const EquityCurveChart = {
  mounted() {
    const container = this.el;
    const width = container.clientWidth || 800;
    const height = parseInt(container.dataset.height || '300', 10);

    // Parse data from element
    const equityData = JSON.parse(container.dataset.equity || '[]');
    const initialCapital = parseFloat(container.dataset.initialCapital || '100000');

    // Create chart with dark theme
    this.chart = createChart(container, {
      width: width,
      height: height,
      layout: {
        background: { color: '#18181b' },
        textColor: '#a1a1aa',
        attributionLogo: false,
      },
      grid: {
        vertLines: { color: '#27272a' },
        horzLines: { color: '#27272a' },
      },
      crosshair: {
        mode: 1, // Magnet mode
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
        scaleMargins: {
          top: 0.1,
          bottom: 0.1,
        },
      },
      timeScale: {
        borderColor: '#3f3f46',
        timeVisible: true,
        secondsVisible: false,
      },
      localization: {
        priceFormatter: (price) => formatCurrency(price),
      },
    });

    // Use baseline series for equity (green above baseline, red below)
    this.equitySeries = this.chart.addSeries(BaselineSeries, {
      baseValue: { type: 'price', price: initialCapital },
      topLineColor: '#10b981',
      topFillColor1: 'rgba(16, 185, 129, 0.28)',
      topFillColor2: 'rgba(16, 185, 129, 0.05)',
      bottomLineColor: '#ef4444',
      bottomFillColor1: 'rgba(239, 68, 68, 0.05)',
      bottomFillColor2: 'rgba(239, 68, 68, 0.28)',
      lineWidth: 2,
      priceScaleId: 'right',
      lastValueVisible: true,
      priceLineVisible: true,
    });

    // Set data if available
    if (equityData.length > 0) {
      const chartData = equityData.map(point => ({
        time: parseTime(point.time || point[0]),
        value: parseFloat(point.equity || point.value || point[1]),
      }));

      // Sort by time to ensure correct order
      chartData.sort((a, b) => a.time - b.time);

      this.equitySeries.setData(chartData);

      // Add initial capital line
      this.initialLine = this.equitySeries.createPriceLine({
        price: initialCapital,
        color: '#71717a',
        lineWidth: 1,
        lineStyle: 2, // Dashed
        axisLabelVisible: true,
        title: 'Initial',
      });

      // Fit content
      this.chart.timeScale().fitContent();

      // Calculate and display summary stats
      if (chartData.length > 0) {
        const finalEquity = chartData[chartData.length - 1].value;
        const totalReturn = ((finalEquity - initialCapital) / initialCapital) * 100;

        // Calculate max drawdown
        let peak = initialCapital;
        let maxDrawdown = 0;
        chartData.forEach(point => {
          if (point.value > peak) peak = point.value;
          const drawdown = ((peak - point.value) / peak) * 100;
          if (drawdown > maxDrawdown) maxDrawdown = drawdown;
        });

        // Dispatch stats to LiveView if needed
        this.pushEvent && this.pushEvent('equity_stats', {
          final_equity: finalEquity,
          total_return: totalReturn,
          max_drawdown: maxDrawdown,
        });
      }
    }

    // Handle window resize
    this.resizeObserver = new ResizeObserver(entries => {
      if (entries.length === 0 || !entries[0].target) return;
      const { width } = entries[0].contentRect;
      if (width > 0) {
        this.chart.applyOptions({ width });
      }
    });

    this.resizeObserver.observe(container);

    // Subscribe to crosshair move for tooltip
    this.chart.subscribeCrosshairMove((param) => {
      if (!param.time || !param.seriesData) return;

      const data = param.seriesData.get(this.equitySeries);
      if (data) {
        const equity = data.value;
        const returnPct = ((equity - initialCapital) / initialCapital) * 100;

        // Could emit tooltip data to LiveView here if needed
      }
    });
  },

  updated() {
    // Re-render if data changes
    const equityData = JSON.parse(this.el.dataset.equity || '[]');
    const initialCapital = parseFloat(this.el.dataset.initialCapital || '100000');

    if (equityData.length > 0 && this.equitySeries) {
      const chartData = equityData.map(point => ({
        time: parseTime(point.time || point[0]),
        value: parseFloat(point.equity || point.value || point[1]),
      }));

      chartData.sort((a, b) => a.time - b.time);
      this.equitySeries.setData(chartData);

      // Update baseline
      this.equitySeries.applyOptions({
        baseValue: { type: 'price', price: initialCapital },
      });

      // Update initial line
      if (this.initialLine) {
        this.equitySeries.removePriceLine(this.initialLine);
      }
      this.initialLine = this.equitySeries.createPriceLine({
        price: initialCapital,
        color: '#71717a',
        lineWidth: 1,
        lineStyle: 2,
        axisLabelVisible: true,
        title: 'Initial',
      });

      this.chart.timeScale().fitContent();
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

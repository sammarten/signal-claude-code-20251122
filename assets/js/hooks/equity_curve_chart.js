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
    // Unix timestamp in seconds - ensure it's an integer
    return Math.floor(timeValue);
  }
  if (typeof timeValue === 'string') {
    // ISO date string - convert to unix timestamp
    const date = new Date(timeValue);
    if (isNaN(date.getTime())) {
      return null;
    }
    return Math.floor(date.getTime() / 1000);
  }
  return null;
}

/**
 * Parse value ensuring it's a valid number
 */
function parseValue(val) {
  if (val === null || val === undefined) {
    return null;
  }
  const num = typeof val === 'number' ? val : parseFloat(val);
  if (isNaN(num) || !isFinite(num)) {
    return null;
  }
  return num;
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

/**
 * Process raw equity data into valid chart format
 * Handles validation, deduplication, and sorting
 */
function processEquityData(rawData) {
  if (!Array.isArray(rawData) || rawData.length === 0) {
    return [];
  }

  // Map and validate each point
  const validPoints = [];
  for (const point of rawData) {
    if (!point) continue;

    const time = parseTime(point.time ?? point[0]);
    const value = parseValue(point.equity ?? point.value ?? point[1]);

    if (time !== null && value !== null) {
      validPoints.push({ time, value });
    }
  }

  if (validPoints.length === 0) {
    return [];
  }

  // Sort by time
  validPoints.sort((a, b) => a.time - b.time);

  // Remove duplicates (keep last value for each timestamp)
  const deduped = [];
  let lastTime = null;
  for (const point of validPoints) {
    if (point.time !== lastTime) {
      deduped.push(point);
      lastTime = point.time;
    } else {
      // Same timestamp - replace with newer value
      deduped[deduped.length - 1] = point;
    }
  }

  return deduped;
}

export const EquityCurveChart = {
  mounted() {
    const container = this.el;
    const width = container.clientWidth || 800;
    const height = parseInt(container.dataset.height || '300', 10);

    // Parse raw data safely
    let rawEquityData = [];
    try {
      const rawJson = container.dataset.equity || '[]';
      rawEquityData = JSON.parse(rawJson);
    } catch (e) {
      console.error('EquityCurveChart: Failed to parse equity data:', e);
      container.innerHTML = '<div class="text-zinc-500 text-center py-8">Invalid equity data</div>';
      return;
    }

    // Parse initial capital
    let initialCapital = parseValue(container.dataset.initialCapital);
    if (initialCapital === null || initialCapital <= 0) {
      initialCapital = 100000;
    }

    // Process and validate equity data (handles sorting and deduplication)
    const equityData = processEquityData(rawEquityData);

    // Don't create chart if no valid data
    if (equityData.length === 0) {
      console.warn('EquityCurveChart: No valid equity data after processing');
      container.innerHTML = '<div class="text-zinc-500 text-center py-8">No equity data available</div>';
      return;
    }

    // Create chart with dark theme
    try {
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

      // Set data (already validated, deduplicated, and sorted)
      this.equitySeries.setData(equityData);
    } catch (e) {
      console.error('EquityCurveChart: Failed to create chart:', e);
      container.innerHTML = '<div class="text-zinc-500 text-center py-8">Failed to create chart</div>';
      return;
    }

    // Add initial capital line (safe - chart was created successfully)
    try {
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
    } catch (e) {
      console.warn('EquityCurveChart: Failed to add price line or fit content:', e);
    }

    // Calculate and display summary stats
    const finalEquity = equityData[equityData.length - 1].value;
    const totalReturn = ((finalEquity - initialCapital) / initialCapital) * 100;

    // Calculate max drawdown
    let peak = initialCapital;
    let maxDrawdown = 0;
    equityData.forEach(point => {
      if (point.value > peak) peak = point.value;
      const drawdown = ((peak - point.value) / peak) * 100;
      if (drawdown > maxDrawdown) maxDrawdown = drawdown;
    });

    // Dispatch stats to LiveView if needed
    if (this.pushEvent) {
      this.pushEvent('equity_stats', {
        final_equity: finalEquity,
        total_return: totalReturn,
        max_drawdown: maxDrawdown,
      });
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
    // Skip if chart wasn't created (no valid data on mount)
    if (!this.chart || !this.equitySeries) {
      return;
    }

    // Parse raw data safely
    let rawEquityData = [];
    try {
      rawEquityData = JSON.parse(this.el.dataset.equity || '[]');
    } catch (e) {
      console.warn('EquityCurveChart: Failed to parse equity data in update:', e);
      return;
    }

    // Parse initial capital
    let initialCapital = parseValue(this.el.dataset.initialCapital);
    if (initialCapital === null || initialCapital <= 0) {
      initialCapital = 100000;
    }

    // Process and validate equity data (handles sorting and deduplication)
    const chartData = processEquityData(rawEquityData);

    if (chartData.length === 0) {
      console.warn('EquityCurveChart: No valid data points after processing in update');
      return;
    }

    // Update chart data with try-catch for safety
    try {
      this.equitySeries.setData(chartData);
    } catch (e) {
      console.error('EquityCurveChart: Failed to set chart data:', e);
      return;
    }

    // Update baseline and price line with error handling
    try {
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
    } catch (e) {
      console.warn('EquityCurveChart: Failed to update baseline/price line:', e);
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

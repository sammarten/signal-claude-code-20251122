/**
 * TradeZonePrimitive - Draws shaded rectangles for trade risk/reward zones
 *
 * Creates visual boxes showing:
 * - Risk zone (entry to stop) in red with transparency
 * - Reward zone (entry to target) in green with transparency
 * - Entry marker at the signal trigger point
 */
export class TradeZonePrimitive {
  constructor() {
    this._trades = [];
    this._chart = null;
    this._series = null;
    this._paneView = new TradeZonePaneView(this);
  }

  attached({ chart, series }) {
    this._chart = chart;
    this._series = series;
  }

  detached() {
    this._chart = null;
    this._series = null;
  }

  setTrades(trades) {
    this._trades = trades || [];
  }

  updateAllViews() {
    // Called when chart needs to update
  }

  paneViews() {
    return [this._paneView];
  }

  getTrades() {
    return this._trades;
  }

  getChart() {
    return this._chart;
  }

  getSeries() {
    return this._series;
  }
}

class TradeZonePaneView {
  constructor(source) {
    this._source = source;
  }

  renderer() {
    return {
      draw: (target) => {
        const trades = this._source.getTrades();
        const chart = this._source.getChart();
        const series = this._source.getSeries();

        if (!trades || trades.length === 0 || !chart || !series) {
          return;
        }

        target.useMediaCoordinateSpace((scope) => {
          const ctx = scope.context;
          const timeScale = chart.timeScale();

          for (const trade of trades) {
            this._drawTradeZone(ctx, trade, timeScale, series, scope.mediaSize);
          }
        });
      },
    };
  }

  _drawTradeZone(ctx, trade, timeScale, series, mediaSize) {
    const entryPrice = parseFloat(trade.entry_price);
    const stopPrice = parseFloat(trade.stop_loss);
    const targetPrice = trade.take_profit && trade.take_profit !== '-' ? parseFloat(trade.take_profit) : null;
    const entryTime = trade.entry_time;
    const exitTime = trade.exit_time;

    if (isNaN(entryPrice) || isNaN(stopPrice)) {
      return;
    }

    // Convert times to x coordinates
    const startX = timeScale.timeToCoordinate(entryTime);
    if (startX === null) return;

    // End at exit time or extend to the right edge
    let endX;
    if (exitTime) {
      endX = timeScale.timeToCoordinate(exitTime);
      if (endX === null) {
        endX = mediaSize.width;
      }
    } else {
      endX = mediaSize.width;
    }

    // Ensure we have a minimum width
    if (endX - startX < 5) {
      endX = startX + 50;
    }

    // Convert prices to y coordinates
    const entryY = series.priceToCoordinate(entryPrice);
    const stopY = series.priceToCoordinate(stopPrice);
    const targetY = targetPrice ? series.priceToCoordinate(targetPrice) : null;

    if (entryY === null || stopY === null) {
      return;
    }

    ctx.save();

    // Draw risk zone (entry to stop) - red with transparency
    ctx.fillStyle = 'rgba(239, 68, 68, 0.15)'; // red-500 with low opacity
    ctx.fillRect(
      startX,
      Math.min(entryY, stopY),
      endX - startX,
      Math.abs(stopY - entryY)
    );

    // Draw reward zone (entry to target) - green with transparency
    if (targetY !== null) {
      ctx.fillStyle = 'rgba(16, 185, 129, 0.15)'; // green-500 with low opacity
      ctx.fillRect(
        startX,
        Math.min(entryY, targetY),
        endX - startX,
        Math.abs(targetY - entryY)
      );
    }

    // Draw entry marker (triangle at entry point)
    const isLong = trade.direction === 'long';
    const markerColor = isLong ? '#10b981' : '#ef4444';
    const markerSize = 8;

    ctx.fillStyle = markerColor;
    ctx.beginPath();
    if (isLong) {
      // Triangle pointing up for long
      ctx.moveTo(startX, entryY + markerSize);
      ctx.lineTo(startX - markerSize, entryY + markerSize * 2);
      ctx.lineTo(startX + markerSize, entryY + markerSize * 2);
    } else {
      // Triangle pointing down for short
      ctx.moveTo(startX, entryY - markerSize);
      ctx.lineTo(startX - markerSize, entryY - markerSize * 2);
      ctx.lineTo(startX + markerSize, entryY - markerSize * 2);
    }
    ctx.closePath();
    ctx.fill();

    // Draw a vertical line at entry from stop to target
    ctx.strokeStyle = markerColor;
    ctx.lineWidth = 1;
    ctx.setLineDash([2, 2]);
    ctx.beginPath();
    ctx.moveTo(startX, stopY);
    ctx.lineTo(startX, targetY !== null ? targetY : entryY);
    ctx.stroke();

    ctx.restore();
  }
}

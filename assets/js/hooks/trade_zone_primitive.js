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
    this._highlightedTradeId = null;
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

  setHighlightedTrade(tradeId) {
    this._highlightedTradeId = tradeId;
  }

  getHighlightedTradeId() {
    return this._highlightedTradeId;
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
        const highlightedId = this._source.getHighlightedTradeId();

        if (!trades || trades.length === 0 || !chart || !series) {
          return;
        }

        target.useMediaCoordinateSpace((scope) => {
          const ctx = scope.context;
          const timeScale = chart.timeScale();

          for (const trade of trades) {
            const isHighlighted = highlightedId && trade.id === highlightedId;
            this._drawTradeZone(ctx, trade, timeScale, series, scope.mediaSize, isHighlighted);
          }
        });
      },
    };
  }

  _drawTradeZone(ctx, trade, timeScale, series, mediaSize, isHighlighted = false) {
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

    // Calculate zone bounds
    let zoneStartX = startX;
    let zoneEndX = endX;
    let zoneWidth = endX - startX;

    // When highlighted, expand the zone by 25% and add shadow
    if (isHighlighted) {
      const expandAmount = zoneWidth * 0.125; // 12.5% on each side = 25% total
      zoneStartX = startX - expandAmount;
      zoneEndX = endX + expandAmount;
      zoneWidth = zoneEndX - zoneStartX;

      // Add shadow effect
      ctx.shadowColor = 'rgba(0, 0, 0, 0.5)';
      ctx.shadowBlur = 20;
      ctx.shadowOffsetX = 0;
      ctx.shadowOffsetY = 4;
    }

    // Use higher opacity when highlighted (on hover)
    const riskOpacity = isHighlighted ? 0.5 : 0.15;
    const rewardOpacity = isHighlighted ? 0.5 : 0.15;

    // Calculate vertical expansion for highlighted state
    const riskTop = Math.min(entryY, stopY);
    const riskHeight = Math.abs(stopY - entryY);
    let drawRiskTop = riskTop;
    let drawRiskHeight = riskHeight;

    if (isHighlighted) {
      const verticalExpand = riskHeight * 0.125;
      drawRiskTop = riskTop - verticalExpand;
      drawRiskHeight = riskHeight + verticalExpand * 2;
    }

    // Draw risk zone (entry to stop) - red with transparency
    ctx.fillStyle = `rgba(239, 68, 68, ${riskOpacity})`; // red-500
    ctx.fillRect(zoneStartX, drawRiskTop, zoneWidth, drawRiskHeight);

    // Draw reward zone (entry to target) - green with transparency
    if (targetY !== null) {
      const rewardTop = Math.min(entryY, targetY);
      const rewardHeight = Math.abs(targetY - entryY);
      let drawRewardTop = rewardTop;
      let drawRewardHeight = rewardHeight;

      if (isHighlighted) {
        const verticalExpand = rewardHeight * 0.125;
        drawRewardTop = rewardTop - verticalExpand;
        drawRewardHeight = rewardHeight + verticalExpand * 2;
      }

      ctx.fillStyle = `rgba(16, 185, 129, ${rewardOpacity})`; // green-500
      ctx.fillRect(zoneStartX, drawRewardTop, zoneWidth, drawRewardHeight);
    }

    ctx.restore();
  }
}

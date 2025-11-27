/**
 * Signal Markers - Manages signal annotations on trading charts
 *
 * Displays entry, stop loss, and take profit levels for trade signals.
 * Supports multiple signals per chart with different visual styles.
 */

// Signal line colors
const SIGNAL_COLORS = {
  entry: '#f59e0b',      // amber-500
  stopLoss: '#ef4444',   // red-500
  takeProfit: '#10b981', // green-500
  long: '#10b981',       // green-500
  short: '#ef4444',      // red-500
};

// Line styles
const LINE_STYLES = {
  solid: 0,
  dashed: 2,
  dotted: 1,
};

/**
 * SignalMarkersManager
 * Manages multiple signal annotations on a candlestick series
 */
export class SignalMarkersManager {
  constructor(series) {
    this._series = series;
    this._signals = new Map(); // signalId -> { entryLine, stopLine, targetLine }
  }

  /**
   * Add a signal to the chart
   * @param {Object} signal - Signal data with entry, stop, target prices
   */
  addSignal(signal) {
    if (this._signals.has(signal.id)) {
      // Update existing signal
      this.removeSignal(signal.id);
    }

    const direction = signal.direction;
    const isLong = direction === 'long';

    // Entry line
    const entryLine = this._series.createPriceLine({
      price: parseFloat(signal.entry_price),
      color: SIGNAL_COLORS.entry,
      lineWidth: 2,
      lineStyle: LINE_STYLES.dashed,
      axisLabelVisible: true,
      title: `Entry ${signal.symbol}`,
    });

    // Stop loss line
    const stopLine = this._series.createPriceLine({
      price: parseFloat(signal.stop_loss),
      color: SIGNAL_COLORS.stopLoss,
      lineWidth: 1,
      lineStyle: LINE_STYLES.solid,
      axisLabelVisible: true,
      title: 'SL',
    });

    // Take profit line
    const targetLine = this._series.createPriceLine({
      price: parseFloat(signal.take_profit),
      color: SIGNAL_COLORS.takeProfit,
      lineWidth: 1,
      lineStyle: LINE_STYLES.solid,
      axisLabelVisible: true,
      title: 'TP',
    });

    this._signals.set(signal.id, {
      signal,
      entryLine,
      stopLine,
      targetLine,
    });
  }

  /**
   * Remove a signal from the chart
   * @param {string} signalId - The signal ID to remove
   */
  removeSignal(signalId) {
    const signalData = this._signals.get(signalId);
    if (!signalData) return;

    this._series.removePriceLine(signalData.entryLine);
    this._series.removePriceLine(signalData.stopLine);
    this._series.removePriceLine(signalData.targetLine);

    this._signals.delete(signalId);
  }

  /**
   * Update a signal's status (changes colors for filled/expired)
   * @param {string} signalId - The signal ID
   * @param {string} status - New status (active, filled, expired, invalidated)
   */
  updateSignalStatus(signalId, status) {
    const signalData = this._signals.get(signalId);
    if (!signalData) return;

    // Dim the lines for non-active signals
    const opacity = status === 'active' ? 1 : 0.4;
    const lineStyle = status === 'active' ? LINE_STYLES.dashed : LINE_STYLES.dotted;

    // We can't directly update price line options in lightweight-charts,
    // so we remove and recreate with updated styles
    const signal = signalData.signal;
    signal.status = status;

    this.removeSignal(signalId);

    if (status === 'active') {
      this.addSignal(signal);
    }
    // Don't re-add non-active signals (they stay removed)
  }

  /**
   * Clear all signal markers
   */
  clearAll() {
    for (const [signalId] of this._signals) {
      this.removeSignal(signalId);
    }
  }

  /**
   * Get all currently displayed signals
   * @returns {Array} Array of signal objects
   */
  getSignals() {
    return Array.from(this._signals.values()).map(data => data.signal);
  }

  /**
   * Check if a signal is currently displayed
   * @param {string} signalId - The signal ID
   * @returns {boolean}
   */
  hasSignal(signalId) {
    return this._signals.has(signalId);
  }

  /**
   * Set multiple signals at once (replaces all existing)
   * @param {Array} signals - Array of signal objects
   */
  setSignals(signals) {
    this.clearAll();
    for (const signal of signals) {
      if (signal.status === 'active') {
        this.addSignal(signal);
      }
    }
  }
}

/**
 * Signal Entry Marker Primitive
 * Draws a marker/arrow at the signal entry point
 */
class SignalMarkerPaneView {
  constructor(source) {
    this._source = source;
  }

  renderer() {
    return {
      draw: (target) => {
        const markers = this._source.getMarkers();
        if (!markers || markers.length === 0) return;

        target.useMediaCoordinateSpace((scope) => {
          const ctx = scope.context;
          ctx.save();

          for (const marker of markers) {
            this._drawMarker(ctx, marker);
          }

          ctx.restore();
        });
      },
    };
  }

  _drawMarker(ctx, marker) {
    const { x, y, direction, color } = marker;
    if (x === null || y === null) return;

    const size = 8;
    const isLong = direction === 'long';

    ctx.fillStyle = color;
    ctx.beginPath();

    if (isLong) {
      // Up arrow for long
      ctx.moveTo(x, y - size);
      ctx.lineTo(x - size, y + size);
      ctx.lineTo(x + size, y + size);
    } else {
      // Down arrow for short
      ctx.moveTo(x, y + size);
      ctx.lineTo(x - size, y - size);
      ctx.lineTo(x + size, y - size);
    }

    ctx.closePath();
    ctx.fill();
  }
}

/**
 * Signal Marker Primitive
 * Attaches to a series to draw signal entry markers
 */
export class SignalMarkerPrimitive {
  constructor() {
    this._chart = null;
    this._series = null;
    this._markers = [];
    this._paneView = new SignalMarkerPaneView(this);
  }

  attached({ chart, series }) {
    this._chart = chart;
    this._series = series;
  }

  detached() {
    this._chart = null;
    this._series = null;
  }

  paneViews() {
    return [this._paneView];
  }

  updateAllViews() {}

  /**
   * Add a marker at a specific time/price
   * @param {Object} marker - { time, price, direction, color }
   */
  addMarker(marker) {
    this._markers.push(marker);
  }

  /**
   * Clear all markers
   */
  clearMarkers() {
    this._markers = [];
  }

  /**
   * Get markers with screen coordinates
   */
  getMarkers() {
    if (!this._chart || !this._series) return [];

    const timeScale = this._chart.timeScale();

    return this._markers.map(marker => {
      const x = timeScale.timeToCoordinate(marker.time);
      const y = this._series.priceToCoordinate(marker.price);

      return {
        ...marker,
        x,
        y,
      };
    }).filter(m => m.x !== null && m.y !== null);
  }
}

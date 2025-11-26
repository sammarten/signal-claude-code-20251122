/**
 * Market Structure - Draws price lines for swing highs/lows, BOS, and ChoCh
 *
 * Levels displayed:
 * - Swing Highs: Recent swing high levels (solid blue lines with label)
 * - Swing Lows: Recent swing low levels (solid blue lines with label)
 * - BOS: Break of Structure levels (solid blue lines with label)
 * - ChoCh: Change of Character levels (solid blue lines with label)
 *
 * Design: Solid blue lines with low opacity, labels on the right side of chart
 */

// Structure element configuration - solid blue lines with varying opacity
const STRUCTURE_CONFIG = {
  // Swing Highs - solid blue
  swing_high: {
    color: 'rgba(96, 165, 250, 0.35)',  // blue-400 with low opacity
    lineWidth: 1,
    lineStyle: 0,      // Solid
    title: 'SH',
  },

  // Swing Lows - solid blue (slightly different shade)
  swing_low: {
    color: 'rgba(59, 130, 246, 0.35)',  // blue-500 with low opacity
    lineWidth: 1,
    lineStyle: 0,      // Solid
    title: 'SL',
  },

  // BOS Bullish - solid blue, slightly more visible
  bos_bullish: {
    color: 'rgba(96, 165, 250, 0.5)',   // blue-400 with medium opacity
    lineWidth: 1,
    lineStyle: 0,      // Solid
    title: 'BOS↑',
  },

  // BOS Bearish - solid blue, slightly more visible
  bos_bearish: {
    color: 'rgba(96, 165, 250, 0.5)',   // blue-400 with medium opacity
    lineWidth: 1,
    lineStyle: 0,      // Solid
    title: 'BOS↓',
  },

  // ChoCh Bullish - solid blue, most visible (important signal)
  choch_bullish: {
    color: 'rgba(147, 197, 253, 0.6)',  // blue-300 with higher opacity
    lineWidth: 1,
    lineStyle: 0,      // Solid
    title: 'ChoCh↑',
  },

  // ChoCh Bearish - solid blue, most visible (important signal)
  choch_bearish: {
    color: 'rgba(147, 197, 253, 0.6)',  // blue-300 with higher opacity
    lineWidth: 1,
    lineStyle: 0,      // Solid
    title: 'ChoCh↓',
  },
};

// Maximum number of each type to display (keeps chart clean)
const MAX_SWING_LINES = 3;
const MAX_BOS_LINES = 2;
const MAX_CHOCH_LINES = 2;

/**
 * MarketStructure Manager
 * Manages price lines for market structure elements (swings, BOS, ChoCh)
 */
export class MarketStructureManager {
  constructor(series) {
    this._series = series;
    this._priceLines = new Map();  // key -> priceLine
    this._enabled = true;
  }

  /**
   * Enable/disable structure display
   * @param {boolean} enabled
   */
  setEnabled(enabled) {
    this._enabled = enabled;
    if (!enabled) {
      this.clearAll();
    }
  }

  /**
   * Update all market structure elements at once
   * @param {Object} structure - Object containing swing_highs, swing_lows, bos, choch arrays
   */
  setStructure(structure) {
    console.log('MarketStructureManager.setStructure called with:', structure);
    if (!this._enabled) {
      console.log('MarketStructureManager is disabled');
      return;
    }

    // Clear existing lines
    this.clearAll();

    // Add swing highs (most recent first, limited)
    if (structure.swing_highs) {
      const swingHighs = structure.swing_highs.slice(0, MAX_SWING_LINES);
      swingHighs.forEach((swing, index) => {
        this._addLine(`swing_high_${index}`, swing.price, 'swing_high');
      });
    }

    // Add swing lows (most recent first, limited)
    if (structure.swing_lows) {
      const swingLows = structure.swing_lows.slice(0, MAX_SWING_LINES);
      swingLows.forEach((swing, index) => {
        this._addLine(`swing_low_${index}`, swing.price, 'swing_low');
      });
    }

    // Add BOS levels (most recent, limited)
    if (structure.bos) {
      const bosLevels = structure.bos.slice(0, MAX_BOS_LINES);
      bosLevels.forEach((bos, index) => {
        const configKey = bos.type === 'bullish' ? 'bos_bullish' : 'bos_bearish';
        this._addLine(`bos_${index}`, bos.price, configKey);
      });
    }

    // Add ChoCh levels (most recent, limited)
    if (structure.choch) {
      const chochLevels = structure.choch.slice(0, MAX_CHOCH_LINES);
      chochLevels.forEach((choch, index) => {
        const configKey = choch.type === 'bullish' ? 'choch_bullish' : 'choch_bearish';
        this._addLine(`choch_${index}`, choch.price, configKey);
      });
    }
  }

  /**
   * Clear all structure lines
   */
  clearAll() {
    for (const [key, line] of this._priceLines) {
      this._series.removePriceLine(line);
    }
    this._priceLines.clear();
  }

  /**
   * Add a price line for a structure element
   * @private
   */
  _addLine(key, price, configKey) {
    const config = STRUCTURE_CONFIG[configKey];
    if (!config || price == null) {
      console.log('MarketStructureManager._addLine skipped:', { key, price, configKey, hasConfig: !!config });
      return;
    }

    console.log('MarketStructureManager._addLine adding:', { key, price, configKey });
    const line = this._series.createPriceLine({
      price: price,
      color: config.color,
      lineWidth: config.lineWidth,
      lineStyle: config.lineStyle,
      axisLabelVisible: true,
      axisLabelColor: config.color,
      axisLabelTextColor: '#e4e4e7',  // zinc-200 for readability
      title: config.title,
    });

    this._priceLines.set(key, line);
  }

  /**
   * Get count of currently displayed lines
   * @returns {number}
   */
  getLineCount() {
    return this._priceLines.size;
  }
}

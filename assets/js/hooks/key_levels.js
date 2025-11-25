/**
 * Key Levels - Draws horizontal price lines for trading reference levels
 *
 * Levels displayed:
 * - PDH/PDL: Previous Day High/Low (solid lines)
 * - PMH/PML: Pre-market High/Low (dashed lines)
 * - OR5H/OR5L: 5-minute Opening Range High/Low (dotted lines)
 * - OR15H/OR15L: 15-minute Opening Range High/Low (dotted lines)
 */

// Level configuration - colors and styles for each level type
const LEVEL_CONFIG = {
  // Previous Day High/Low - most important, solid yellow/orange
  pdh: {
    color: '#fbbf24',  // amber-400
    lineWidth: 1,
    lineStyle: 0,      // Solid
    title: 'PDH',
  },
  pdl: {
    color: '#f97316',  // orange-500
    lineWidth: 1,
    lineStyle: 0,      // Solid
    title: 'PDL',
  },

  // Pre-market High/Low - dashed cyan/teal
  pmh: {
    color: '#22d3d1',  // cyan-400
    lineWidth: 1,
    lineStyle: 2,      // Dashed
    title: 'PMH',
  },
  pml: {
    color: '#14b8a6',  // teal-500
    lineWidth: 1,
    lineStyle: 2,      // Dashed
    title: 'PML',
  },

  // 5-minute Opening Range - dotted purple
  or5h: {
    color: '#a78bfa',  // violet-400
    lineWidth: 1,
    lineStyle: 1,      // Dotted
    title: 'OR5H',
  },
  or5l: {
    color: '#8b5cf6',  // violet-500
    lineWidth: 1,
    lineStyle: 1,      // Dotted
    title: 'OR5L',
  },

  // 15-minute Opening Range - dotted pink
  or15h: {
    color: '#f472b6',  // pink-400
    lineWidth: 1,
    lineStyle: 1,      // Dotted
    title: 'OR15H',
  },
  or15l: {
    color: '#ec4899',  // pink-500
    lineWidth: 1,
    lineStyle: 1,      // Dotted
    title: 'OR15L',
  },
};

/**
 * KeyLevels Manager
 * Manages price lines on a candlestick series for key trading levels
 */
export class KeyLevelsManager {
  constructor(series) {
    this._series = series;
    this._priceLines = new Map();
  }

  /**
   * Set all key levels at once
   * @param {Object} levels - Object with level keys (pdh, pdl, etc.) and price values
   */
  setLevels(levels) {
    // Remove all existing lines first
    this.clearAll();

    // Add new lines for each level
    for (const [key, price] of Object.entries(levels)) {
      if (price != null && LEVEL_CONFIG[key]) {
        this._addLine(key, price);
      }
    }
  }

  /**
   * Update a single level
   * @param {string} key - Level key (pdh, pdl, etc.)
   * @param {number} price - Price value
   */
  updateLevel(key, price) {
    // Remove existing line if present
    if (this._priceLines.has(key)) {
      this._series.removePriceLine(this._priceLines.get(key));
      this._priceLines.delete(key);
    }

    // Add new line if price is valid
    if (price != null && LEVEL_CONFIG[key]) {
      this._addLine(key, price);
    }
  }

  /**
   * Clear all price lines
   */
  clearAll() {
    for (const [key, line] of this._priceLines) {
      this._series.removePriceLine(line);
    }
    this._priceLines.clear();
  }

  /**
   * Add a price line for a level
   * @private
   */
  _addLine(key, price) {
    const config = LEVEL_CONFIG[key];
    if (!config) return;

    const line = this._series.createPriceLine({
      price: price,
      color: config.color,
      lineWidth: config.lineWidth,
      lineStyle: config.lineStyle,
      axisLabelVisible: true,
      title: config.title,
    });

    this._priceLines.set(key, line);
  }

  /**
   * Get current levels
   * @returns {Object} Current levels with their prices
   */
  getLevels() {
    const levels = {};
    for (const [key, line] of this._priceLines) {
      levels[key] = line.options().price;
    }
    return levels;
  }
}

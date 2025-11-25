/**
 * Session Highlighter - Draws subtle background colors for market sessions
 *
 * Market Hours (Eastern Time):
 * - Pre-market:    4:00 AM - 9:30 AM ET
 * - Regular hours: 9:30 AM - 4:00 PM ET
 * - Post-market:   4:00 PM - 8:00 PM ET
 */

// Session colors - very subtle to not distract from candlesticks
const SESSION_COLORS = {
  premarket: 'rgba(59, 130, 246, 0.06)',   // blue tint
  regular: 'rgba(0, 0, 0, 0)',              // transparent (no highlight for regular hours)
  postmarket: 'rgba(168, 85, 247, 0.06)',  // purple tint
};

// Session boundaries in minutes from midnight ET
const SESSION_BOUNDARIES = {
  premarketStart: 4 * 60,        // 4:00 AM = 240 minutes
  regularStart: 9 * 60 + 30,     // 9:30 AM = 570 minutes
  regularEnd: 16 * 60,           // 4:00 PM = 960 minutes
  postmarketEnd: 20 * 60,        // 8:00 PM = 1200 minutes
};

/**
 * Convert a UTC timestamp to Eastern Time and get minutes from midnight
 */
function getETMinutesFromMidnight(utcTimestamp) {
  // Create date from UTC timestamp
  const date = new Date(utcTimestamp * 1000);

  // Convert to ET using Intl API
  const etString = date.toLocaleString('en-US', {
    timeZone: 'America/New_York',
    hour: 'numeric',
    minute: 'numeric',
    hour12: false,
  });

  // Parse hours and minutes
  const [hours, minutes] = etString.split(':').map(Number);
  return hours * 60 + minutes;
}

/**
 * Determine which session a given UTC timestamp falls into
 */
function getSession(utcTimestamp) {
  const minutesFromMidnight = getETMinutesFromMidnight(utcTimestamp);

  if (minutesFromMidnight >= SESSION_BOUNDARIES.premarketStart &&
      minutesFromMidnight < SESSION_BOUNDARIES.regularStart) {
    return 'premarket';
  } else if (minutesFromMidnight >= SESSION_BOUNDARIES.regularStart &&
             minutesFromMidnight < SESSION_BOUNDARIES.regularEnd) {
    return 'regular';
  } else if (minutesFromMidnight >= SESSION_BOUNDARIES.regularEnd &&
             minutesFromMidnight < SESSION_BOUNDARIES.postmarketEnd) {
    return 'postmarket';
  }

  // Outside trading hours (overnight)
  return null;
}

/**
 * Session Highlighter View - renders the background rectangles
 */
class SessionHighlighterPaneView {
  constructor(source) {
    this._source = source;
  }

  renderer() {
    return {
      draw: (target) => {
        const sessions = this._source.getSessions();
        if (!sessions || sessions.length === 0) return;

        target.useMediaCoordinateSpace((scope) => {
          const ctx = scope.context;
          const height = scope.mediaSize.height;

          ctx.save();

          // Group consecutive bars by session and draw rectangles
          let currentSession = null;
          let sessionStart = null;

          for (let i = 0; i < sessions.length; i++) {
            const { x, session, barWidth } = sessions[i];

            if (session !== currentSession) {
              // Draw previous session rectangle if exists
              if (currentSession && sessionStart !== null && SESSION_COLORS[currentSession]) {
                const prevX = sessions[i - 1].x;
                const prevBarWidth = sessions[i - 1].barWidth;
                this._drawSessionRect(ctx, sessionStart, prevX + prevBarWidth, height, currentSession);
              }
              currentSession = session;
              sessionStart = x;
            }
          }

          // Draw the last session
          if (currentSession && sessionStart !== null && SESSION_COLORS[currentSession]) {
            const lastSession = sessions[sessions.length - 1];
            this._drawSessionRect(ctx, sessionStart, lastSession.x + lastSession.barWidth, height, currentSession);
          }

          ctx.restore();
        });
      },
    };
  }

  _drawSessionRect(ctx, startX, endX, height, session) {
    const color = SESSION_COLORS[session];
    if (!color || color === 'rgba(0, 0, 0, 0)') return;

    ctx.fillStyle = color;
    ctx.fillRect(startX, 0, endX - startX, height);
  }
}

/**
 * Session Highlighter Primitive
 * Attaches to a series and draws session backgrounds
 */
export class SessionHighlighter {
  constructor() {
    this._chart = null;
    this._series = null;
    this._data = [];
    this._paneView = new SessionHighlighterPaneView(this);
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

  updateAllViews() {
    // Called when chart needs to update
  }

  /**
   * Set the bar data - should be called whenever chart data changes
   * @param {Array} data - Array of { time } objects (time in seconds, already local)
   */
  setData(data) {
    this._data = data;
  }

  /**
   * Get session information for all visible bars
   * Returns array of { x, session, barWidth } for drawing
   */
  getSessions() {
    if (!this._chart || !this._series || this._data.length === 0) {
      return [];
    }

    const timeScale = this._chart.timeScale();
    const sessions = [];

    // Get bar spacing for width calculation
    const barSpacing = timeScale.options().barSpacing || 6;
    const barWidth = Math.max(1, barSpacing * 0.8);

    for (const bar of this._data) {
      // Use localTime for chart coordinate conversion
      const x = timeScale.timeToCoordinate(bar.localTime);
      if (x === null) continue;

      // Use utcTime for session detection
      const session = getSession(bar.utcTime);

      sessions.push({
        x: x - barWidth / 2,
        session,
        barWidth,
      });
    }

    return sessions;
  }
}

/**
 * TradesTable Hook - Handles trade row hover events and local time formatting
 *
 * Dispatches custom events to highlight trade zones on the chart
 * without requiring a server round-trip.
 */
export const TradesTable = {
  mounted() {
    this.formatLocalTimes();
    this.setupHoverListeners();
  },

  updated() {
    // Re-setup when the table updates (new trades added)
    this.formatLocalTimes();
    this.setupHoverListeners();
  },

  formatLocalTimes() {
    // Find all time elements and format them in local timezone
    const timeElements = this.el.querySelectorAll('time[data-utc]');

    timeElements.forEach(el => {
      const utcMs = parseInt(el.dataset.utc, 10);
      if (isNaN(utcMs)) return;

      const date = new Date(utcMs);
      const hours = date.getHours();
      const minutes = date.getMinutes();
      const ampm = hours >= 12 ? 'PM' : 'AM';
      const hour12 = hours % 12 || 12;
      const minuteStr = minutes.toString().padStart(2, '0');

      el.textContent = `${hour12}:${minuteStr} ${ampm}`;
    });
  },

  setupHoverListeners() {
    // Find all trade rows within this table
    const rows = this.el.querySelectorAll('tr[data-trade-id]');

    rows.forEach(row => {
      // Skip if already has listeners
      if (row._hasHoverListeners) return;
      row._hasHoverListeners = true;

      const tradeId = row.dataset.tradeId;

      row.addEventListener('mouseenter', () => {
        window.dispatchEvent(new CustomEvent('trade-highlight', {
          detail: { id: tradeId }
        }));
      });

      row.addEventListener('mouseleave', () => {
        window.dispatchEvent(new CustomEvent('trade-unhighlight'));
      });
    });
  },

  destroyed() {
    // Cleanup happens automatically when elements are removed
  }
};

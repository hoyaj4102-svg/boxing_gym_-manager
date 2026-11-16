/**
 * Numeric month value helpers for the Monthly Expiry Calendar.
 * Display text is digits only. The stored value stays YYYY-MM so the
 * existing calendar render path can keep reading calendarMonth.value.
 */
(function (global) {
  const MIN_YEAR = 1;
  const MAX_YEAR = 9999;
  const MONTH_COLUMNS = 4;

  function pad2(month) {
    return String(month).padStart(2, '0');
  }

  function parseMonthValue(value) {
    const match = /^(\d{4})-(\d{2})$/.exec(String(value || ''));
    if (!match) return null;
    const year = Number(match[1]);
    const month = Number(match[2]);
    if (year < MIN_YEAR || year > MAX_YEAR || month < 1 || month > 12) return null;
    return { year, month };
  }

  function formatMonthValue(year, month) {
    return `${year}-${pad2(month)}`;
  }

  // Closed control. November 2026 is "2026.11", January 2026 is "2026.1".
  function formatMonthDisplay(year, month) {
    return `${Number(year)}.${Number(month)}`;
  }

  function monthOptionLabel(month) {
    return pad2(month);
  }

  function monthOptionLabels() {
    const labels = [];
    for (let month = 1; month <= 12; month += 1) labels.push(monthOptionLabel(month));
    return labels;
  }

  function shiftYear(parts, delta) {
    const year = parts.year + delta;
    if (year < MIN_YEAR || year > MAX_YEAR) return { year: parts.year, month: parts.month };
    return { year, month: parts.month };
  }

  function adjacentYearLabels(year) {
    return {
      prev: year > MIN_YEAR ? String(year - 1) : '',
      current: String(year),
      next: year < MAX_YEAR ? String(year + 1) : ''
    };
  }

  // Returns the month that should receive focus, or null when key is not a grid key.
  // Arrow keys clamp at the edges so focus stays on a month number.
  function moveMonthFocus(month, key) {
    const current = Number(month);
    if (!Number.isInteger(current) || current < 1 || current > 12) return null;
    if (key === 'Home') return 1;
    if (key === 'End') return 12;
    if (key === 'ArrowRight') return Math.min(12, current + 1);
    if (key === 'ArrowLeft') return Math.max(1, current - 1);
    if (key === 'ArrowDown') {
      const next = current + MONTH_COLUMNS;
      return next <= 12 ? next : current;
    }
    if (key === 'ArrowUp') {
      const next = current - MONTH_COLUMNS;
      return next >= 1 ? next : current;
    }
    return null;
  }

  global.RememberMonthPicker = {
    MIN_YEAR,
    MAX_YEAR,
    MONTH_COLUMNS,
    parseMonthValue,
    formatMonthValue,
    formatMonthDisplay,
    monthOptionLabel,
    monthOptionLabels,
    shiftYear,
    adjacentYearLabels,
    moveMonthFocus
  };
})(typeof window !== 'undefined' ? window : globalThis);

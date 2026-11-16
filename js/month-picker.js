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

  // Closed month. January 2026 is "2026.01" and November 2026 is "2026.11".
  function formatMonthDisplay(year, month) {
    return `${Number(year)}.${pad2(Number(month))}`;
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

  function daysInMonth(year, month) {
    return new Date(year, month, 0).getDate();
  }

  function parseDateValue(value) {
    const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(value || ''));
    if (!match) return null;
    const year = Number(match[1]);
    const month = Number(match[2]);
    const day = Number(match[3]);
    if (year < MIN_YEAR || year > MAX_YEAR || month < 1 || month > 12) return null;
    if (day < 1 || day > daysInMonth(year, month)) return null;
    return { year, month, day };
  }

  function formatDateValue(year, month, day) {
    return `${year}-${pad2(month)}-${pad2(day)}`;
  }

  // Closed date. 5 January 2026 is "2026.01.05".
  function formatDateDisplay(year, month, day) {
    return `${Number(year)}.${pad2(Number(month))}.${pad2(Number(day))}`;
  }

  function shiftMonth(parts, delta) {
    const index = parts.year * 12 + (parts.month - 1) + delta;
    const year = Math.floor(index / 12);
    const month = (index % 12) + 1;
    if (year < MIN_YEAR || year > MAX_YEAR) {
      return { year: parts.year, month: parts.month, day: parts.day || 1 };
    }
    const day = Math.min(parts.day || 1, daysInMonth(year, month));
    return { year, month, day };
  }

  // Sunday-first grid, matching the expiry calendar. Leading and trailing
  // cells are real dates from the adjacent months.
  function calendarCells(year, month) {
    const firstWeekday = new Date(year, month - 1, 1).getDay();
    const count = daysInMonth(year, month);
    const cells = [];
    const previous = shiftMonth({ year, month, day: 1 }, -1);
    const previousCount = daysInMonth(previous.year, previous.month);
    for (let i = 0; i < firstWeekday; i += 1) {
      const day = previousCount - firstWeekday + 1 + i;
      cells.push({ year: previous.year, month: previous.month, day, inMonth: false });
    }
    for (let day = 1; day <= count; day += 1) {
      cells.push({ year, month, day, inMonth: true });
    }
    const next = shiftMonth({ year, month, day: 1 }, 1);
    let day = 1;
    while (cells.length % 7 !== 0) {
      cells.push({ year: next.year, month: next.month, day, inMonth: false });
      day += 1;
    }
    return cells;
  }

  function cellValue(cell) {
    return formatDateValue(cell.year, cell.month, cell.day);
  }

  // Moves within the rendered grid. Returns the next YYYY-MM-DD, or null
  // when the key is not a grid key.
  function moveDateFocus(cells, focusValue, key) {
    const index = cells.findIndex((cell) => cellValue(cell) === focusValue);
    if (index < 0) return null;
    let next = index;
    if (key === 'ArrowRight') next = Math.min(cells.length - 1, index + 1);
    else if (key === 'ArrowLeft') next = Math.max(0, index - 1);
    else if (key === 'ArrowDown') next = Math.min(cells.length - 1, index + 7);
    else if (key === 'ArrowUp') next = Math.max(0, index - 7);
    else if (key === 'Home') next = cells.findIndex((cell) => cell.inMonth && cell.day === 1);
    else if (key === 'End') {
      for (let i = cells.length - 1; i >= 0; i -= 1) {
        if (cells[i].inMonth) {
          next = i;
          break;
        }
      }
    } else {
      return null;
    }
    if (next < 0) return focusValue;
    return cellValue(cells[next]);
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

  global.RememberDatePicker = {
    MIN_YEAR,
    MAX_YEAR,
    daysInMonth,
    parseDateValue,
    formatDateValue,
    formatDateDisplay,
    formatMonthDisplay,
    shiftMonth,
    calendarCells,
    moveDateFocus
  };
})(typeof window !== 'undefined' ? window : globalThis);

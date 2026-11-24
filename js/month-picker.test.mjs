import assert from 'node:assert/strict';
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';
import test from 'node:test';
import vm from 'node:vm';

function loadPickers() {
  const window = {};
  vm.runInNewContext(readFileSync('js/month-picker.js', 'utf8'), { window }, {
    filename: 'js/month-picker.js'
  });
  return window;
}

function translations() {
  const page = readFileSync('index.html', 'utf8');
  const start = page.indexOf('    const TRANSLATIONS = ');
  const end = page.indexOf('    let currentLanguage');
  assert.ok(start > 0 && end > start);
  const context = {};
  vm.runInNewContext(`${page.slice(start, end)}\nthis.TRANSLATIONS = TRANSLATIONS;`, vm.createContext(context));
  return context.TRANSLATIONS;
}

function walk(dir, acc = []) {
  for (const entry of readdirSync(dir)) {
    if (entry === 'node_modules' || entry === '.git') continue;
    const path = join(dir, entry);
    if (statSync(path).isDirectory()) walk(path, acc);
    else if (/\.(html|js|mjs|css)$/.test(entry)) acc.push(path);
  }
  return acc;
}

function plain(value) {
  return JSON.parse(JSON.stringify(value));
}

const loaded = loadPickers();
const picker = loaded.RememberMonthPicker;
const dates = loaded.RememberDatePicker;
const page = readFileSync('index.html', 'utf8');
const pickerStart = page.indexOf('id="calendarMonthPicker"');
const pickerEnd = page.indexOf('id="calendarGrid"');
const pickerMarkup = page.slice(pickerStart, pickerEnd);

test('closed display is year.month with a two-digit month and no month name', () => {
  assert.equal(picker.formatMonthDisplay(2026, 11), '2026.11');
  assert.equal(picker.formatMonthDisplay(2026, 1), '2026.01');
  assert.equal(picker.formatMonthDisplay('2026', '03'), '2026.03');
  assert.doesNotMatch(picker.formatMonthDisplay(2026, 1), /[^\d.]/);
});

test('the value stored for the calendar stays YYYY-MM', () => {
  assert.equal(picker.formatMonthValue(2026, 11), '2026-11');
  assert.equal(picker.formatMonthValue(2026, 1), '2026-01');
  assert.deepEqual(plain(picker.parseMonthValue('2026-11')), { year: 2026, month: 11 });
  assert.deepEqual(plain(picker.parseMonthValue('2026-01')), { year: 2026, month: 1 });
  assert.equal(picker.parseMonthValue('2026-11-01'), null);
  assert.equal(picker.parseMonthValue('2026.11'), null);
  assert.equal(picker.parseMonthValue('2026-13'), null);
  assert.equal(picker.parseMonthValue(''), null);
});

test('the expanded month list is 01 through 12', () => {
  assert.deepEqual(plain(picker.monthOptionLabels()), [
    '01', '02', '03', '04', '05', '06', '07', '08', '09', '10', '11', '12'
  ]);
});

test('year navigation labels are adjacent year numbers', () => {
  assert.deepEqual(plain(picker.adjacentYearLabels(2026)), {
    prev: '2025',
    current: '2026',
    next: '2027'
  });
  assert.equal(picker.adjacentYearLabels(picker.MIN_YEAR).prev, '');
  assert.equal(picker.adjacentYearLabels(picker.MAX_YEAR).next, '');
  assert.deepEqual(plain(picker.shiftYear({ year: 2026, month: 11 }, 1)), { year: 2027, month: 11 });
  assert.deepEqual(plain(picker.shiftYear({ year: 2026, month: 11 }, -1)), { year: 2025, month: 11 });
  assert.deepEqual(plain(picker.shiftYear({ year: 1, month: 4 }, -1)), { year: 1, month: 4 });
  assert.deepEqual(plain(picker.shiftYear({ year: 9999, month: 4 }, 1)), { year: 9999, month: 4 });
});

test('arrow keys move through the 4-column month grid', () => {
  assert.equal(picker.moveMonthFocus(1, 'ArrowRight'), 2);
  assert.equal(picker.moveMonthFocus(1, 'ArrowLeft'), 1);
  assert.equal(picker.moveMonthFocus(1, 'ArrowDown'), 5);
  assert.equal(picker.moveMonthFocus(5, 'ArrowUp'), 1);
  assert.equal(picker.moveMonthFocus(12, 'ArrowRight'), 12);
  assert.equal(picker.moveMonthFocus(8, 'ArrowDown'), 12);
  assert.equal(picker.moveMonthFocus(10, 'ArrowDown'), 10);
  assert.equal(picker.moveMonthFocus(4, 'ArrowUp'), 4);
  assert.equal(picker.moveMonthFocus(6, 'Home'), 1);
  assert.equal(picker.moveMonthFocus(6, 'End'), 12);
  assert.equal(picker.moveMonthFocus(6, 'Enter'), null);
  assert.equal(picker.MONTH_COLUMNS, 4);
});

test('the expiry calendar draws its own month picker', () => {
  assert.equal(page.includes('type="month"'), false);
  assert.match(page, /<script src="\.\/js\/month-picker\.js"><\/script>/);
  assert.match(pickerMarkup, /id="calendarMonthTrigger"/);
  assert.match(pickerMarkup, /id="calendarMonthPanel"/);
  assert.match(pickerMarkup, /type="hidden" id="calendarMonth"/);
  assert.match(pickerMarkup, /data-i18n="calendarMonthAria"/);
  assert.match(page, /RememberMonthPicker/);
  assert.match(page, /calendarMonthTrigger/);
  assert.match(page, /keydown/);
  assert.match(page, /Escape/);
  assert.match(page, /ArrowDown/);
  assert.match(page, /PageUp/);
  assert.match(page, /pointerdown/);
  assert.match(page, /getElementById\('calendarMonth'\)\.addEventListener\('change'/);

  const buttons = [...pickerMarkup.matchAll(/<button\b[^>]*>([\s\S]*?)<\/button>/g)].map((match) =>
    match[1].replace(/<[^>]+>/g, '').trim()
  );
  const monthButtons = buttons.filter((label) => /^\d{2}$/.test(label));
  assert.deepEqual(monthButtons, plain(picker.monthOptionLabels()));
  for (const label of buttons) {
    assert.equal(/[가-힣]/.test(label), false, label);
    assert.doesNotMatch(label, /월|년|삭제|이번/);
  }
  assert.doesNotMatch(pickerMarkup, /type="month"|이번 달|삭제/);
});

test('previous and next year names exist in every language and are not Korean outside Korean', () => {
  const dictionaries = translations();
  assert.deepEqual(Object.keys(dictionaries).sort(), ['en', 'es', 'fr', 'hi', 'ko', 'mn', 'ru', 'zh']);
  for (const language of Object.keys(dictionaries)) {
    for (const key of ['calendarMonthPrevYear', 'calendarMonthNextYear']) {
      const value = dictionaries[language][key];
      assert.equal(typeof value, 'string', `${language}.${key}`);
      assert.match(value, /\{year\}/, `${language}.${key}`);
      if (language !== 'ko') assert.equal(/[가-힣]/.test(value), false, `${language}.${key}`);
    }
    const label = dictionaries[language].calendarMonthAria;
    assert.equal(typeof label, 'string', `${language}.calendarMonthAria`);
    assert.equal(label.includes('{year}'), false, `${language}.calendarMonthAria`);
    if (language !== 'ko') assert.equal(/[가-힣]/.test(label), false, `${language}.calendarMonthAria`);
  }
  assert.equal(dictionaries.ko.calendarMonthAria.includes('{year}'), false);
  assert.match(dictionaries.ko.calendarMonthPrevYear, /[가-힣]/);
  assert.match(dictionaries.en.calendarMonthPrevYear, /Previous year \{year\}/);
  assert.match(dictionaries.en.calendarMonthNextYear, /Next year \{year\}/);
  assert.equal(dictionaries.en.calendarMonthAria, 'Select expiry month');
  for (const language of Object.keys(dictionaries)) {
    for (const key of ['datePickerPrevMonth', 'datePickerNextMonth']) {
      const value = dictionaries[language][key];
      assert.equal(typeof value, 'string', `${language}.${key}`);
      assert.match(value, /\{month\}/, `${language}.${key}`);
      if (language !== 'ko') assert.equal(/[가-힣]/.test(value), false, `${language}.${key}`);
    }
    assert.equal(dictionaries[language].weekdayNames.length, 7, language);
    if (language !== 'ko') {
      for (const name of dictionaries[language].weekdayNames) {
        assert.equal(/[가-힣]/.test(name), false, `${language} weekday ${name}`);
      }
    }
  }
  assert.deepEqual(plain(dictionaries.en.weekdayNames), ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat']);
  assert.match(dictionaries.en.datePickerPrevMonth, /Previous month \{month\}/);
  assert.match(dictionaries.ko.datePickerPrevMonth, /[가-힣]/);
});

test('closed dates are zero-padded digits and the grid stays numeric', () => {
  assert.equal(dates.formatDateDisplay(2026, 1, 5), '2026.01.05');
  assert.equal(dates.formatDateDisplay(2026, 12, 31), '2026.12.31');
  assert.equal(dates.formatDateValue(2026, 1, 5), '2026-01-05');
  assert.deepEqual(plain(dates.parseDateValue('2026-01-05')), { year: 2026, month: 1, day: 5 });
  assert.equal(dates.parseDateValue('2026-02-31'), null);
  assert.equal(dates.parseDateValue('2026.01.05'), null);
  assert.equal(dates.daysInMonth(2026, 2), 28);
  assert.equal(dates.daysInMonth(2024, 2), 29);
  assert.deepEqual(plain(dates.shiftMonth({ year: 2026, month: 1, day: 5 }, -1)), {
    year: 2025, month: 12, day: 5
  });
  assert.deepEqual(plain(dates.shiftMonth({ year: 2026, month: 3, day: 31 }, -1)), {
    year: 2026, month: 2, day: 28
  });
  assert.deepEqual(plain(dates.shiftMonth({ year: 1, month: 1, day: 1 }, -1)), {
    year: 1, month: 1, day: 1
  });

  const cells = plain(dates.calendarCells(2026, 1));
  assert.equal(cells.length % 7, 0);
  const first = new Date(2026, 0, 1).getDay();
  assert.equal(cells[first].day, 1);
  assert.equal(cells[first].inMonth, true);
  assert.equal(cells.filter((cell) => cell.inMonth).length, 31);
  const focus = dates.formatDateValue(cells[first].year, cells[first].month, cells[first].day);
  const left = dates.moveDateFocus(cells, focus, 'ArrowLeft');
  assert.equal(left, dates.formatDateValue(cells[first - 1].year, cells[first - 1].month, cells[first - 1].day));
  assert.equal(dates.moveDateFocus(cells, focus, 'Home'), focus);
  assert.equal(dates.moveDateFocus(cells, focus, 'Enter'), null);
});

test('member dates use the app date picker and keep YYYY-MM-DD ids', () => {
  assert.equal(page.includes('type="date"'), false);
  assert.equal(page.includes('type="month"'), false);
  for (const id of ['startDate', 'expireDate', 'editStartDate', 'editExpireDate']) {
    assert.match(page, new RegExp(`data-date-for="${id}"`));
    assert.match(page, new RegExp(`type="hidden" id="${id}"`));
    assert.match(page, new RegExp(`id="${id}Trigger"`));
    assert.match(page, new RegExp(`id="${id}Panel"`));
  }
  assert.match(page, /RememberDatePicker/);
  assert.match(page, /t\('weekdayNames'\)/);
  assert.match(page, /t\('datePickerPrevMonth'/);
  assert.match(page, /getElementById\('startDate'\)\.addEventListener\('change'/);
  assert.match(page, /getElementById\('expireDate'\)\.value = addDays\(e\.target\.value \|\| getTodayDateOnly\(\), 30\)/);
  assert.match(page, /getElementById\('editStartDate'\)\.value = member\.startDate/);
  assert.match(page, /getElementById\('editExpireDate'\)\.value = member\.expireDate/);
  // navigator.languages is used only to resolve the app language, not dates.
  assert.doesNotMatch(page, /toLocaleDateString|toLocaleString|navigator\.language(?!s)/);

  const found = [];
  for (const file of walk('.')) {
    const source = readFileSync(file, 'utf8');
    for (const tag of source.matchAll(/<input\b[^>]*>/g)) {
      const type = /\btype="(date|month|week|time|datetime-local|datetime)"/.exec(tag[0]);
      if (!type) continue;
      const id = /\bid="([^"]+)"/.exec(tag[0]);
      found.push({ file, id: id ? id[1] : '', type: type[1] });
    }
  }
  assert.deepEqual(found, []);
});

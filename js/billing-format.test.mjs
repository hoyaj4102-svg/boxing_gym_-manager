import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

function loadBilling(language) {
  const window = {
    document: { documentElement: { lang: language || '' } }
  };
  vm.runInNewContext(readFileSync('js/billing.js', 'utf8'), { window, Intl, Number, Date, URL, URLSearchParams }, {
    filename: 'js/billing.js'
  });
  return window.SweatManagerBilling.formatKrw;
}

test('Korean amounts keep the won suffix', () => {
  const formatKrw = loadBilling('ko');
  const amount = new Intl.NumberFormat('ko-KR').format(10000);
  assert.equal(formatKrw(10000, 'ko'), `${amount}원`);
  assert.equal(formatKrw(10000), `${amount}원`);
});

test('other languages keep the KRW amount and drop the won suffix', () => {
  const formatKrw = loadBilling('en');
  const amount = new Intl.NumberFormat('en-US').format(10000);
  assert.equal(formatKrw(10000, 'en'), `${amount} KRW`);
  assert.equal(formatKrw(10000, 'es'), `${amount} KRW`);
  assert.equal(formatKrw(10000), `${amount} KRW`);
  assert.equal(formatKrw('10000', 'fr').endsWith('원'), false);
});

import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const source = readFileSync(new URL('./business-identity.js', import.meta.url), 'utf8');
const sandbox = { window: {}, document: null };
vm.createContext(sandbox);
vm.runInContext(source, sandbox);
const business = sandbox.window.SweatManagerBusiness;

test('business identity is placeholder text only', () => {
  const values = Object.values(business.PLACEHOLDERS);
  assert.ok(values.includes('[상호 미기재]'));
  assert.ok(values.includes('[사업자등록번호 미기재]'));
  assert.ok(values.includes('[대표자 미기재]'));
  assert.ok(values.includes('[주소 미기재]'));
  assert.ok(values.includes('[전화 미기재]'));
  assert.ok(values.includes('[통신판매업 신고번호 미기재]'));
  assert.ok(values.includes('[이메일 미기재]'));
  for (const value of values) {
    assert.equal(typeof value, 'string');
    assert.doesNotMatch(value, /\d{3}-\d{2}-\d{5}/);
    assert.doesNotMatch(value, /@/);
    assert.doesNotMatch(value, /\d{2,4}-\d{3,4}-\d{4}/);
  }
});

test('footer renderer escapes placeholder markup and links to the drafts', () => {
  const root = {
    dataset: { legalBase: 'legal/' },
    innerHTML: ''
  };
  business.renderInto(root);
  assert.match(root.innerHTML, /\[상호 미기재\]/);
  assert.match(root.innerHTML, /법률 검토 전 초안/);
  assert.match(root.innerHTML, /href="legal\/terms\.html"/);
  assert.match(root.innerHTML, /href="legal\/privacy\.html"/);
  assert.match(root.innerHTML, /href="legal\/refund\.html"/);
  assert.doesNotMatch(root.innerHTML, /<script/i);
});

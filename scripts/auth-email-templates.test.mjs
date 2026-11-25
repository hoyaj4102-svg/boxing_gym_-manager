import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const confirmation = readFileSync('supabase/templates/confirmation.html', 'utf8');
const recovery = readFileSync('supabase/templates/recovery.html', 'utf8');
const config = readFileSync('supabase/config.toml', 'utf8');
const doc = readFileSync('docs/auth-email-templates.md', 'utf8');

test('signup and recovery templates branch on locale and default to Korean', () => {
  for (const source of [confirmation, recovery]) {
    assert.match(source, /\{\{ if eq \.Data\.locale "en" \}\}/);
    assert.match(source, /\{\{ else \}\}/);
    assert.match(source, /\{\{ end \}\}/);
    assert.match(source, /\{\{ \.ConfirmationURL \}\}/);
  }
  assert.match(confirmation, /Confirm your email address/);
  assert.match(confirmation, /이메일 주소를 확인해 주세요/);
  assert.match(recovery, /Reset your password/);
  assert.match(recovery, /비밀번호를 다시 설정해 주세요/);
});

test('local config points at the templates and does not claim to change production', () => {
  assert.match(config, /\[auth\.email\.template\.confirmation\]/);
  assert.match(config, /\[auth\.email\.template\.recovery\]/);
  assert.match(config, /content_path = "\.\/supabase\/templates\/confirmation\.html"/);
  assert.match(config, /content_path = "\.\/supabase\/templates\/recovery\.html"/);
  assert.match(config, /Do not run `supabase config push`/);
});

test('the dashboard note records the SMTP prerequisite and the existing allow-list', () => {
  assert.match(doc, /Custom SMTP|custom SMTP/);
  assert.match(doc, /Resend/);
  assert.match(doc, /SendGrid/);
  assert.match(doc, /Amazon SES/);
  assert.match(doc, /Confirm your email address/);
  assert.match(doc, /Reset your password/);
  assert.match(doc, /https:\/\/boxing-gym-manager\.vercel\.app\/\*\*/);
  assert.match(doc, /https:\/\/remember-gym\.vercel\.app\/\*\*/);
  assert.match(doc, /No allow-list change/);
  assert.match(doc, /supabase\/templates\/confirmation\.html/);
  assert.match(doc, /supabase\/templates\/recovery\.html/);
});

test('the Go template renderer covers both branches when Go is installed', () => {
  const result = spawnSync('go', ['test', '-count=1', '.'], {
    cwd: 'supabase/templates',
    encoding: 'utf8',
  });
  if (result.error && result.error.code === 'ENOENT') return;
  assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
});

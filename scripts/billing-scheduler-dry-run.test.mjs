import assert from "node:assert/strict";
import test from "node:test";
import { evaluateSchedulerMode } from "./billing-scheduler-dry-run.mjs";

test("dry run makes no provider calls", () => {
  assert.deepEqual(evaluateSchedulerMode("dry-run"), {
    ok: true,
    dryRun: true,
    providerCalls: 0,
    reason: "dry_run",
  });
  assert.equal(evaluateSchedulerMode(undefined).providerCalls, 0);
});

test("live mode is rejected without a provider call", () => {
  const result = evaluateSchedulerMode("live");
  assert.equal(result.ok, false);
  assert.equal(result.providerCalls, 0);
  assert.equal(result.reason, "live_not_enabled");
});

test("unknown modes are rejected without a provider call", () => {
  const result = evaluateSchedulerMode("charge");
  assert.equal(result.ok, false);
  assert.equal(result.providerCalls, 0);
});

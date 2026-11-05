import { alreadyCompletedIsCurrent } from "./claim_gate.ts";

function assertEquals(actual: unknown, expected: unknown, message: string) {
  if (actual !== expected) {
    throw new Error(`${message}: expected ${expected}, got ${actual}`);
  }
}

const now = Date.parse("2026-11-04T00:00:00.000Z");

Deno.test("a future period is treated as current", () => {
  assertEquals(
    alreadyCompletedIsCurrent(
      { current_period_end: "2026-12-01T00:00:00.000Z" },
      now,
    ),
    true,
    "future period",
  );
});

Deno.test("a missing or ended period is not treated as current", () => {
  assertEquals(
    alreadyCompletedIsCurrent({}, now),
    false,
    "missing period fails closed",
  );
  assertEquals(
    alreadyCompletedIsCurrent({ current_period_end: "" }, now),
    false,
    "blank period fails closed",
  );
  assertEquals(
    alreadyCompletedIsCurrent(
      { current_period_end: "2026-10-01T00:00:00.000Z" },
      now,
    ),
    false,
    "ended period fails closed",
  );
});

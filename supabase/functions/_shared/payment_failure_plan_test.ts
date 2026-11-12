import { planPaymentFailure } from "./payment_failure_plan.ts";

function assert(condition: unknown, message: string) {
  if (!condition) throw new Error(message);
}

const first = "2026-11-01T00:00:00.000Z";

Deno.test("the first card failure schedules a retry inside a seven-day grace", () => {
  const plan = planPaymentFailure({
    firstFailedAt: first,
    failedAt: first,
    failureCount: 1,
  });
  assert(plan.state === "past_due", "the first failure is past due");
  assert(plan.nextRetryAt === "2026-11-02T00:00:00.000Z", "the first retry is 24 hours later");
  assert(plan.graceUntil === "2026-11-08T00:00:00.000Z", "grace lasts seven days");
  assert(plan.accessExtended === false, "grace does not extend Pro access");
  assert(plan.email === "disabled" && plan.sms === "disabled", "outbound channels stay disabled");
  assert(plan.cardReregistrationRequired === true, "the card needs to be registered again");
});

Deno.test("retries stop after the third retry slot and do not pass the grace end", () => {
  const third = planPaymentFailure({
    firstFailedAt: first,
    failedAt: "2026-11-04T00:00:00.000Z",
    failureCount: 3,
  });
  assert(third.nextRetryAt === "2026-11-06T00:00:00.000Z", "the third slot is 120 hours from the first failure");
  const fourth = planPaymentFailure({
    firstFailedAt: first,
    failedAt: "2026-11-06T00:00:00.000Z",
    failureCount: 4,
  });
  assert(fourth.nextRetryAt === null, "there is no fourth retry");
  assert(fourth.state === "grace_expired", "no remaining retry ends the grace case");
});

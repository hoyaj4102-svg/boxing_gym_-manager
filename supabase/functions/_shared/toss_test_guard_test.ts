import {
  assessTossTestCall,
  retryDispatchDecision,
} from "./toss_test_guard.ts";

function assert(condition: unknown, message: string) {
  if (!condition) throw new Error(message);
}

Deno.test("provider calls stay closed unless mode is test and the key is a test secret", () => {
  assert(
    assessTossTestCall({ mode: undefined, secretKey: "test_sk_synthetic" }).allow === false,
    "missing mode must not call Toss",
  );
  assert(
    assessTossTestCall({ mode: "live", secretKey: "test_sk_synthetic" }).code ===
      "PROVIDER_MODE_NOT_TEST",
    "live mode must not call the cancel or retry path",
  );
  assert(
    assessTossTestCall({ mode: "test", secretKey: "dummy-toss-secret-key" }).allow === false,
    "a non-test secret must not call Toss",
  );
  assert(
    assessTossTestCall({ mode: "test", secretKey: "live_sk_synthetic" }).allow === false,
    "a live-prefixed secret must not call Toss",
  );
  assert(
    assessTossTestCall({ mode: "test", secretKey: "test_sk_synthetic" }).allow === true,
    "an explicit test mode and synthetic test prefix may build a provider request",
  );
});

Deno.test("failure retry defaults to dry-run and does not treat live as proceed", () => {
  assert(retryDispatchDecision({ mode: null, secretKey: "test_sk_synthetic" }) === "dry_run", "default is dry-run");
  assert(retryDispatchDecision({ mode: "live", secretKey: "test_sk_synthetic" }) === "dry_run", "live is not a retry mode");
  assert(
    retryDispatchDecision({ mode: "test", secretKey: "dummy-toss-secret-key" }) === "blocked_secret",
    "test mode still needs a test secret",
  );
  assert(
    retryDispatchDecision({ mode: "test", secretKey: "test_sk_synthetic" }) === "proceed",
    "both gates are required before a retry can proceed",
  );
});

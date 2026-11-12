export type TossTestGuard = {
  allow: boolean;
  code: "TEST_MODE" | "PROVIDER_MODE_NOT_TEST" | "TOSS_SECRET_NOT_TEST";
};

// Toss test secret keys use the test_sk_ / test_gsk_ prefix.
// A missing mode, any other mode, or a non-test key never allows a provider call.
export function assessTossTestCall(input: {
  mode: string | null | undefined;
  secretKey: string | null | undefined;
}): TossTestGuard {
  if (input.mode !== "test") {
    return { allow: false, code: "PROVIDER_MODE_NOT_TEST" };
  }

  const secret = input.secretKey || "";
  const testSecret = secret.startsWith("test_sk_") || secret.startsWith("test_gsk_");
  if (!testSecret || secret.toLowerCase().includes("live_")) {
    return { allow: false, code: "TOSS_SECRET_NOT_TEST" };
  }

  return { allow: true, code: "TEST_MODE" };
}

export function retryDispatchDecision(input: {
  mode: string | null | undefined;
  secretKey: string | null | undefined;
}): "dry_run" | "blocked_secret" | "proceed" {
  if (input.mode !== "test") return "dry_run";
  return assessTossTestCall({ mode: "test", secretKey: input.secretKey }).allow
    ? "proceed"
    : "blocked_secret";
}

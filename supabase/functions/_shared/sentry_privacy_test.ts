import {
  beforeSend,
  environmentFromOrigin,
  FILTERED,
} from "../../../js/sentry-privacy.mjs";

const fakePassword = "fake-password-not-real";
const fakeJwt = "eyJhbGciOiJub25lIiwidHlwIjoiSldUIn0.eyJzdWIiOiJmYWtlLXVzZXIifQ.fakeSignatureValueNotASecret";
const fakeBillingKey = "billingKey_FAKE_NOT_A_KEY";
const fakeCard = "4242424242424242";
const fakeEmail = "fake.member@example.com";
const fakePhone = "010-0000-0000";

Deno.test("deno beforeSend removes the same fake secrets", () => {
  const message = `password=${fakePassword} ${fakeJwt} ${fakeBillingKey} ${fakeCard} ${fakeEmail} ${fakePhone}`;
  const result = beforeSend({
    message,
    request: {
      url: "https://example.test/pay?token=fake-token-value&plan=monthly",
      headers: { Authorization: `Bearer ${fakeJwt}`, "Content-Type": "application/json" },
      data: { password: fakePassword, billingKey: fakeBillingKey },
      cookies: { session: "fake-token-value" },
    },
    exception: { values: [{ value: message }] },
    breadcrumbs: [{ category: "fetch", message, data: { email: fakeEmail } }],
    extra: { phone: fakePhone, note: message },
  });
  if (!result) throw new Error("event was dropped");
  const serialized = JSON.stringify(result);
  for (const secret of [fakePassword, fakeJwt, fakeBillingKey, fakeCard, fakeEmail, fakePhone, "fake-token-value"]) {
    if (serialized.includes(secret)) throw new Error(`still present: ${secret}`);
  }
  if (result.request.data !== undefined) throw new Error("request body remains");
  if (result.request.cookies !== undefined) throw new Error("cookies remain");
  if (result.request.headers.Authorization !== FILTERED) throw new Error("authorization header remains");
  if (!result.request.url.includes("plan=monthly")) throw new Error("safe query param was removed");
  if (!result.exception.values[0].value.includes(FILTERED)) throw new Error("exception message was not masked");
});

Deno.test("deno environment tagging matches the exact production origins first", () => {
  if (environmentFromOrigin("https://boxing-gym-manager.vercel.app", "") !== "production") {
    throw new Error("boxing-gym-manager.vercel.app was not tagged production");
  }
  if (environmentFromOrigin("https://remember-gym.vercel.app/share", "") !== "production") {
    throw new Error("remember-gym.vercel.app was not tagged production");
  }
  if (environmentFromOrigin("https://app.re-member.kr", "") !== "production") {
    throw new Error("app.re-member.kr was not tagged production");
  }
  if (environmentFromOrigin("https://branch-name.vercel.app", "https://remember-gym.vercel.app") !== "preview") {
    throw new Error("other vercel.app host was not tagged preview");
  }
  if (environmentFromOrigin("", "") !== "unknown") throw new Error("missing origin was not unknown");
});

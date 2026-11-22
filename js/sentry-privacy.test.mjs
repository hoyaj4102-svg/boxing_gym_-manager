import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import {
  beforeBreadcrumb,
  beforeSend,
  beforeSendTransaction,
  createSentryOptions,
  environmentFromOrigin,
  FILTERED,
  TRACES_SAMPLE_RATE,
} from "./sentry-privacy.mjs";
import { installSentry, SENTRY_BROWSER_SDK_URL } from "./sentry.js";
import { renderSentryPublicEnv } from "../scripts/inject-sentry-public-env.mjs";

const fakePassword = "fake-password-not-real";
const fakeJwt = "eyJhbGciOiJub25lIiwidHlwIjoiSldUIn0.eyJzdWIiOiJmYWtlLXVzZXIifQ.fakeSignatureValueNotASecret";
const fakeBillingKey = "billingKey_FAKE_NOT_A_KEY";
const fakeAuthKey = "authKey_FAKE_NOT_A_KEY";
const fakeCustomerKey = "customerKey_FAKE_NOT_A_KEY";
const fakeCard = "4242424242424242";
const fakeEmail = "fake.member@example.com";
const fakePhone = "010-0000-0000";
const fakeToken = "fake-token-value";
const fakeCode = "fake-code-value";
const fakeKey = "fake-key-value";
const fakeApiKey = "fake-api-key-value";
const fakeIp = "203.0.113.5";

const secrets = [
  fakePassword,
  fakeJwt,
  fakeBillingKey,
  fakeAuthKey,
  fakeCustomerKey,
  fakeCard,
  fakeEmail,
  fakePhone,
  fakeToken,
  fakeCode,
  fakeKey,
  fakeApiKey,
  fakeIp,
];

function sensitiveEvent() {
  const message = [
    "checkout failed",
    `password=${fakePassword}`,
    fakePassword,
    fakeJwt,
    fakeBillingKey,
    fakeAuthKey,
    fakeCustomerKey,
    fakeCard,
    fakeEmail,
    fakePhone,
    `https://example.test/pay?token=${fakeToken}&code=${fakeCode}&key=${fakeKey}&plan=monthly`,
  ].join(" ");
  return {
    message,
    user: {
      id: "internal-random-id",
      email: fakeEmail,
      username: fakeEmail,
      ip_address: fakeIp,
    },
    request: {
      url: `https://example.test/pay?token=${fakeToken}&code=${fakeCode}&key=${fakeKey}&plan=monthly`,
      query_string: `token=${fakeToken}&code=${fakeCode}&key=${fakeKey}&plan=monthly`,
      cookies: { session: fakeToken },
      headers: {
        Authorization: `Bearer ${fakeJwt}`,
        apikey: fakeApiKey,
        "X-Api-Key": fakeToken,
        "X-Cron-Secret": fakeKey,
        Cookie: `session=${fakeToken}`,
        "X-Forwarded-For": fakeIp,
        "Content-Type": "application/json",
      },
      data: {
        password: fakePassword,
        billingKey: fakeBillingKey,
        authKey: fakeAuthKey,
        customerKey: fakeCustomerKey,
        cardNumber: fakeCard,
        email: fakeEmail,
        phone: fakePhone,
        note: message,
      },
    },
    exception: {
      values: [{ type: "Error", value: message }],
    },
    breadcrumbs: [
      {
        category: "console",
        level: "info",
        message: `console ${fakePassword} ${fakeEmail}`,
      },
      {
        category: "console",
        level: "error",
        message: `console-error ${message}`,
        data: { password: fakePassword, billingKey: fakeBillingKey },
      },
      {
        category: "fetch",
        level: "info",
        message,
        data: {
          password: fakePassword,
          billingKey: fakeBillingKey,
          authKey: fakeAuthKey,
          customerKey: fakeCustomerKey,
          email: fakeEmail,
          phone: fakePhone,
          cardNumber: fakeCard,
          token: fakeToken,
        },
      },
    ],
    extra: {
      password: fakePassword,
      billingKey: fakeBillingKey,
      authKey: fakeAuthKey,
      customerKey: fakeCustomerKey,
      email: fakeEmail,
      phone: fakePhone,
      cardNumber: fakeCard,
      note: message,
    },
  };
}

function assertSecretsGone(value) {
  const serialized = JSON.stringify(value);
  for (const secret of secrets) {
    assert.equal(serialized.includes(secret), false, `still present: ${secret}`);
  }
}

test("beforeSend removes fake secrets from the body, headers, breadcrumbs, exception, and extra", () => {
  const result = beforeSend(sensitiveEvent());
  assert.ok(result);
  assertSecretsGone(result);
  assert.equal(result.user.id, "internal-random-id");
  assert.equal(result.user.email, undefined);
  assert.equal(result.user.ip_address, undefined);
  assert.equal(result.request.data, undefined);
  assert.equal(result.request.cookies, undefined);
  assert.equal(result.request.headers.Authorization, FILTERED);
  assert.equal(result.request.headers.apikey, FILTERED);
  assert.equal(result.request.headers["X-Api-Key"], FILTERED);
  assert.equal(result.request.headers["X-Forwarded-For"], FILTERED);
  assert.equal(result.request.headers["Content-Type"], "application/json");
  assert.equal(result.request.url.includes("plan=monthly"), true);
  assert.equal(result.extra.password, FILTERED);
  assert.equal(result.extra.billingKey, FILTERED);
  assert.equal(result.extra.note.includes("checkout failed"), true);
  assert.equal(result.exception.values[0].type, "Error");
  assert.equal(result.exception.values[0].value.includes("checkout failed"), true);
  assert.equal(result.exception.values[0].value.includes("plan=monthly"), true);
  assert.equal(result.breadcrumbs.some((breadcrumb) => breadcrumb.category === "console" && breadcrumb.level === "info"), false);
  const consoleError = result.breadcrumbs.find((breadcrumb) => breadcrumb.category === "console");
  assert.equal(consoleError.level, "error");
  assert.equal(consoleError.data.password, FILTERED);
  assert.equal(consoleError.data.billingKey, FILTERED);
});

test("beforeSendTransaction uses the same removal", () => {
  const result = beforeSendTransaction(sensitiveEvent());
  assert.ok(result);
  assertSecretsGone(result);
  assert.equal(result.request.data, undefined);
});

test("beforeBreadcrumb drops non-error console crumbs and masks error crumbs", () => {
  assert.equal(beforeBreadcrumb({ category: "console", level: "log", message: fakePassword }), null);
  assert.equal(beforeBreadcrumb({ category: "console", level: "warning", message: fakeEmail }), null);
  const kept = beforeBreadcrumb({
    category: "console",
    level: "error",
    message: `boom ${fakeJwt} ${fakeEmail} ${fakePhone} ${fakeCard} password=${fakePassword}`,
    data: { billingKey: fakeBillingKey },
  });
  assertSecretsGone(kept);
  assert.equal(kept.data.billingKey, FILTERED);
  assert.equal(kept.message.includes("boom"), true);
});

test("beforeSend drops the event if it cannot be cloned", () => {
  const event = {};
  event.self = event;
  assert.equal(beforeSend(event), null);
});

test("edge environment matches exact production origins before the vercel.app preview rule", () => {
  assert.equal(environmentFromOrigin("https://boxing-gym-manager.vercel.app", ""), "production");
  assert.equal(environmentFromOrigin("https://boxing-gym-manager.vercel.app/signup", ""), "production");
  assert.equal(environmentFromOrigin("https://remember-gym.vercel.app", ""), "production");
  assert.equal(environmentFromOrigin("https://remember-gym.vercel.app/share", ""), "production");
  assert.equal(environmentFromOrigin("", "https://remember-gym.vercel.app/share"), "production");
  assert.equal(environmentFromOrigin("https://app.re-member.kr", ""), "production");
  assert.equal(environmentFromOrigin("", "https://app.re-member.kr/members"), "production");
  assert.equal(environmentFromOrigin("https://branch-name.vercel.app", "https://boxing-gym-manager.vercel.app"), "preview");
  assert.equal(environmentFromOrigin("https://boxing-gym-manager-git-feature-team.vercel.app", ""), "preview");
  assert.equal(environmentFromOrigin("https://not-boxing-gym-manager.vercel.app", ""), "preview");
  assert.equal(environmentFromOrigin("", ""), "unknown");
  assert.equal(environmentFromOrigin("https://tosspayments.com", "https://app.re-member.kr"), "unknown");
});

test("browser install stays off without a DSN and does not enable replay", () => {
  let inits = 0;
  const fake = {
    init() {
      inits += 1;
    },
    setUser() {},
  };
  assert.deepEqual(installSentry(fake, { dsn: "" }), { enabled: false });
  assert.equal(inits, 0);

  const calls = [];
  const enabled = installSentry({
    init(options) {
      calls.push(options);
    },
    setUser(user) {
      calls.push(user);
    },
  }, {
    dsn: "https://example-public-key@example.test/1",
    environment: "preview",
    release: "abc123",
  }, {
    storage: null,
    randomUUID: () => "11111111-1111-4111-8111-111111111111",
  });
  assert.equal(enabled.enabled, true);
  assert.equal(calls[0].sendDefaultPii, false);
  assert.equal(calls[0].tracesSampleRate, TRACES_SAMPLE_RATE);
  assert.equal(calls[0].tracesSampleRate, 0.1);
  assert.equal(calls[0].replaysSessionSampleRate, undefined);
  assert.equal(calls[0].replaysOnErrorSampleRate, undefined);
  assert.equal(calls[1].id, "11111111-1111-4111-8111-111111111111");
  assert.equal(calls[1].email, undefined);
  assert.equal(SENTRY_BROWSER_SDK_URL.includes("bundle.tracing.min.js"), true);
  assert.equal(SENTRY_BROWSER_SDK_URL.includes("replay"), false);
  const scrubbed = calls[0].beforeSend(sensitiveEvent());
  assertSecretsGone(scrubbed);
  const transaction = calls[0].beforeSendTransaction(sensitiveEvent());
  assertSecretsGone(transaction);
});

test("public env file is empty unless the build injects values", () => {
  const committed = readFileSync(new URL("./sentry-public-env.js", import.meta.url), "utf8");
  assert.equal(committed, renderSentryPublicEnv({}));
  assert.equal(committed.includes("sentry.io"), false);
  const rendered = renderSentryPublicEnv({
    SENTRY_DSN: "https://example-public-key@example.test/1",
    VERCEL_ENV: "preview",
    VERCEL_GIT_COMMIT_SHA: "abc123",
  });
  assert.equal(rendered.includes("https://example-public-key@example.test/1"), true);
  assert.equal(rendered.includes('"preview"'), true);
  assert.equal(rendered.includes('"abc123"'), true);
  assert.equal(renderSentryPublicEnv({}).includes('dsn: ""'), true);
});

test("sentry options keep the suggested trace sample rate and disable PII", () => {
  const options = createSentryOptions({ dsn: "", environment: "", release: "" });
  assert.equal(options.sendDefaultPii, false);
  assert.equal(options.tracesSampleRate, 0.1);
  assert.equal(options.environment, undefined);
  assert.equal(options.release, undefined);
});

import { readFileSync } from "node:fs";
import vm from "node:vm";

const source = readFileSync("js/billing.js", "utf8");
const window = {};

vm.runInNewContext(source, {
  window,
  console,
  Intl,
  URL,
  setTimeout,
  clearTimeout,
  fetch() {
    throw new Error("fetch must not be called by billing UI action tests");
  },
  document: {
    querySelector() {
      throw new Error("document must not be used by billing UI action tests");
    },
    createElement() {
      throw new Error("document must not be used by billing UI action tests");
    },
    head: {
      appendChild() {
        throw new Error("document must not be used by billing UI action tests");
      },
    },
  },
}, { filename: "js/billing.js" });

const billing = window.SweatManagerBilling;
if (!billing?.normalizeSummary || !billing?.actionState) {
  throw new Error("billing helpers were not exported");
}

function assertEqual(actual, expected, message) {
  const actualJson = JSON.stringify(actual);
  const expectedJson = JSON.stringify(expected);
  if (actualJson !== expectedJson) {
    throw new Error(`${message}: expected ${expectedJson}, got ${actualJson}`);
  }
}

function summary(overrides) {
  return billing.normalizeSummary({
    gym_id: "gym_1",
    plan_code: "free",
    subscription_status: "expired",
    member_limit: 20,
    member_count: 0,
    has_pro: false,
    can_add_member: true,
    can_cancel: false,
    can_resume: false,
    auto_renew: false,
    ...overrides,
  });
}

function assertActions(name, rawSummary, expected) {
  const normalized = summary(rawSummary);
  const actions = billing.actionState(normalized);
  assertEqual(
    {
      planCode: normalized.hasPro ? "pro" : "free",
      status: normalized.subscriptionStatus,
      canAddMember: normalized.canAddMember,
      canCancel: actions.canCancel,
      canResume: actions.canResume,
      canSubscribe: actions.canSubscribe,
      isSubscribedAuto: actions.isSubscribedAuto,
    },
    expected,
    name,
  );
}

assertActions("expired active Pro shows Free, subscribe available, cancel unavailable", {
  plan_code: "pro",
  subscription_status: "active",
  current_period_end: "2026-10-28T09:42:00.000Z",
  member_limit: 20,
  member_count: 20,
  has_pro: false,
  can_add_member: false,
  can_cancel: true,
  auto_renew: true,
}, {
  planCode: "free",
  status: "active",
  canAddMember: false,
  canCancel: false,
  canResume: false,
  canSubscribe: true,
  isSubscribedAuto: false,
});

assertActions("active unexpired Pro keeps cancel available", {
  plan_code: "pro",
  subscription_status: "active",
  current_period_end: "2099-01-01T00:00:00.000Z",
  member_limit: -1,
  member_count: 42,
  has_pro: true,
  can_add_member: true,
  can_cancel: true,
  auto_renew: true,
}, {
  planCode: "pro",
  status: "active",
  canAddMember: true,
  canCancel: true,
  canResume: false,
  canSubscribe: false,
  isSubscribedAuto: true,
});

assertActions("canceled paid-through Pro preserves resume behavior", {
  plan_code: "pro",
  subscription_status: "canceled",
  current_period_end: "2099-01-01T00:00:00.000Z",
  member_limit: -1,
  member_count: 42,
  has_pro: true,
  can_add_member: true,
  can_cancel: false,
  can_resume: true,
  auto_renew: false,
}, {
  planCode: "pro",
  status: "canceled",
  canAddMember: true,
  canCancel: false,
  canResume: true,
  canSubscribe: false,
  isSubscribedAuto: false,
});

assertActions("expired canceled Pro shows Free and allows new subscribe", {
  plan_code: "pro",
  subscription_status: "canceled",
  current_period_end: "2026-10-28T09:42:00.000Z",
  member_limit: 20,
  member_count: 20,
  has_pro: false,
  can_add_member: false,
  can_cancel: false,
  can_resume: false,
  auto_renew: false,
}, {
  planCode: "free",
  status: "canceled",
  canAddMember: false,
  canCancel: false,
  canResume: false,
  canSubscribe: true,
  isSubscribedAuto: false,
});

assertActions("free gym keeps subscribe available and cancel unavailable", {
  plan_code: "free",
  subscription_status: "expired",
  member_limit: 20,
  member_count: 10,
  has_pro: false,
  can_add_member: true,
}, {
  planCode: "free",
  status: "expired",
  canAddMember: true,
  canCancel: false,
  canResume: false,
  canSubscribe: true,
  isSubscribedAuto: false,
});

assertActions("trialing Pro has no cancel action regression", {
  plan_code: "pro",
  subscription_status: "trialing",
  trial_ends_at: "2099-01-01T00:00:00.000Z",
  member_limit: -1,
  member_count: 2,
  has_pro: true,
  can_add_member: true,
  can_cancel: false,
}, {
  planCode: "pro",
  status: "trialing",
  canAddMember: true,
  canCancel: false,
  canResume: false,
  canSubscribe: true,
  isSubscribedAuto: false,
});

console.log("Billing UI action checks passed.");

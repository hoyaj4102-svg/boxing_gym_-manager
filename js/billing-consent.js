// Draft billing disclosure and consent rules.
// The server function public.record_billing_consent is authoritative.
// This module only decides what the screen must show and whether the
// checkbox state is complete enough to ask the server to record consent.
(function (global) {
  const POLICY_VERSION = 'draft-2026-11-12';
  const MONTHLY_AMOUNT_KRW = 10000;
  const CONSENT_WINDOW_MS = 30 * 24 * 60 * 60 * 1000;
  const CANCELLATION_METHOD = '요금제 화면의 해지 버튼으로 해지합니다. 해지 후 다음 결제일부터 자동결제가 중단되고, 이미 결제한 이용 종료일까지 Pro를 사용할 수 있습니다.';

  function parseTime(value) {
    const time = new Date(value).getTime();
    return Number.isFinite(time) ? time : null;
  }

  function consentInWindow(consentedAt, conversionAt) {
    const consented = parseTime(consentedAt);
    const conversion = parseTime(conversionAt);
    if (consented == null || conversion == null) return false;
    return consented >= conversion - CONSENT_WINDOW_MS && consented < conversion;
  }

  function windowState(now, conversionAt) {
    const nowMs = parseTime(now);
    const conversionMs = parseTime(conversionAt);
    if (nowMs == null || conversionMs == null) {
      return { open: false, code: 'INVALID_TIME' };
    }
    if (nowMs >= conversionMs) return { open: false, code: 'WINDOW_CLOSED' };
    if (nowMs < conversionMs - CONSENT_WINDOW_MS) {
      return { open: false, code: 'WINDOW_NOT_OPEN' };
    }
    return { open: true, code: 'WINDOW_OPEN' };
  }

  function estimatedNextChargeAt(firstChargeAt) {
    const date = new Date(firstChargeAt);
    if (Number.isNaN(date.getTime())) return null;
    const day = date.getUTCDate();
    date.setUTCDate(1);
    date.setUTCMonth(date.getUTCMonth() + 1);
    const lastDay = new Date(Date.UTC(date.getUTCFullYear(), date.getUTCMonth() + 1, 0)).getUTCDate();
    date.setUTCDate(Math.min(day, lastDay));
    return date.toISOString();
  }

  function buildPrePaymentDisclosure(now) {
    const firstChargeAt = new Date(now).toISOString();
    return {
      draft: true,
      policyVersion: POLICY_VERSION,
      amountKrw: MONTHLY_AMOUNT_KRW,
      currency: 'KRW',
      billingCycle: 'monthly',
      autoRenew: true,
      firstChargeAt,
      nextChargeAt: estimatedNextChargeAt(firstChargeAt),
      nextChargeEstimate: true,
      paymentMethod: 'toss_card_auto_pay',
      paymentMethodLabel: '등록하는 카드로 매월 자동결제',
      cancellationMethod: CANCELLATION_METHOD
    };
  }

  function prePaymentContinueState(input) {
    const missing = [];
    if (!input || input.paymentChecked !== true) missing.push('pre_payment');
    if (input && input.trialRequired === true && input.trialChecked !== true) {
      missing.push('trial_to_paid');
    }
    if (input && input.priceRequired === true && input.priceChecked !== true) {
      missing.push('price_increase');
    }
    return { ok: missing.length === 0, missing };
  }

  function trialConsentRequired(readiness) {
    return Boolean(
      readiness &&
      readiness.trial &&
      readiness.trial.consent_required_for_conversion === true &&
      readiness.trial.window_open === true &&
      readiness.trial.consent_status !== 'granted'
    );
  }

  function priceConsentRequired(readiness) {
    const schedules = Array.isArray(readiness && readiness.price_schedules)
      ? readiness.price_schedules
      : [];
    return schedules.some((schedule) => (
      schedule &&
      schedule.window_open === true &&
      schedule.consent_status !== 'granted'
    ));
  }

  global.SweatManagerBillingConsent = {
    POLICY_VERSION,
    MONTHLY_AMOUNT_KRW,
    CONSENT_WINDOW_MS,
    CANCELLATION_METHOD,
    consentInWindow,
    windowState,
    estimatedNextChargeAt,
    buildPrePaymentDisclosure,
    prePaymentContinueState,
    trialConsentRequired,
    priceConsentRequired
  };
})(typeof window !== 'undefined' ? window : globalThis);

// Client helpers for test-mode refund display and receipt links.
// Provider calls stay in the edge function, which refuses non-test mode.
(function (global) {
  function safeReceiptUrl(value) {
    if (typeof value !== 'string' || !value) return null;
    try {
      const parsed = new URL(value);
      const host = parsed.hostname.toLowerCase();
      const tossHost = host === 'tosspayments.com' || host.endsWith('.tosspayments.com');
      if (parsed.protocol !== 'https:' || !tossHost) return null;
      return parsed.toString();
    } catch {
      return null;
    }
  }

  function refundSubmission(input) {
    const reason = input && input.reason;
    const amount = Number(input && input.amountKrw);
    if (!['customer_request', 'duplicate_charge', 'system_error'].includes(reason)) {
      return { ok: false, code: 'UNKNOWN_REASON' };
    }
    if (!Number.isInteger(amount) || amount <= 0) {
      return { ok: false, code: 'INVALID_AMOUNT' };
    }
    if (reason === 'customer_request' && input.normallyUsed == null) {
      return { ok: false, code: 'NORMAL_USE_UNCONFIRMED' };
    }
    return {
      ok: true,
      reason,
      requestedAmountKrw: amount,
      normallyUsed: reason === 'customer_request' ? input.normallyUsed === true : null
    };
  }

  function failureNotice(failure) {
    if (!failure) return null;
    return {
      state: failure.state || 'past_due',
      cardReregistrationRequired: failure.card_reregistration_required !== false,
      email: 'disabled',
      sms: 'disabled'
    };
  }

  global.SweatManagerBillingOps = {
    safeReceiptUrl,
    refundSubmission,
    failureNotice
  };
})(typeof window !== 'undefined' ? window : globalThis);

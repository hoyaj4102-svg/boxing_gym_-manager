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

  const REFUND_DECISION_REASONS = {
    FULL_REFUND_WITHIN_7_DAYS: '결제 후 7일 이내이고 정상 이용하지 않아 전액 환불 대상입니다.',
    FULL_REFUND_DUPLICATE_OR_SYSTEM_ERROR: '중복 결제 또는 시스템 오류로 전액 환불 대상입니다.',
    PARTIAL_REFUND_NOT_IN_DRAFT_POLICY: '부분 환불은 이 초안 정책에서 허용하지 않습니다.',
    REFUND_WINDOW_EXPIRED: '결제 후 7일이 지나 고객 요청 환불 기간이 지났습니다.',
    NORMAL_USE_LIMIT: '서비스를 정상 이용한 경우에는 환불하지 않습니다.',
    NORMAL_USE_UNCONFIRMED: '정상 이용 여부를 확인하지 않아 환불을 진행하지 않습니다.',
    INVALID_AMOUNT: '환불 금액이 올바르지 않습니다.',
    INVALID_REQUESTED_AMOUNT: '요청 금액이 올바르지 않습니다.',
    UNKNOWN_REASON: '알 수 없는 환불 사유입니다.',
    INVALID_TIME: '결제 시각을 확인할 수 없습니다.'
  };

  function refundDecisionCopy(input) {
    const code = (input && (input.decisionCode || input.decision_code || input.code)) || '';
    const allowed = Boolean(input && (input.allowed === true || input.allowed === 'true'));
    const reason = REFUND_DECISION_REASONS[code] || '환불 조건을 확인할 수 없습니다.';
    if (allowed) {
      return {
        outcome: 'accepted',
        code,
        text: `환불 요청을 접수했습니다. ${reason} 테스트 모드가 아니면 결제 취소 API는 호출하지 않습니다.`
      };
    }
    return {
      outcome: 'rejected',
      code,
      text: `환불 요청을 거절했습니다. ${reason}`
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
    refundDecisionCopy,
    failureNotice
  };
})(typeof window !== 'undefined' ? window : globalThis);

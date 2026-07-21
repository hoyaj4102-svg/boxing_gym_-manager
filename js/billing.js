/**
 * Sweat Manager - Billing helpers (plan limits + checkout stubs)
 *
 * Actual payment confirmation MUST happen in a server/Edge Function webhook.
 * The browser only reads billing summary and starts checkout.
 */
(function (global) {
  const PLANS = {
    free: {
      code: 'free',
      nameKey: 'planFreeName',
      memberLimit: 20,
      priceKrw: 0
    },
    pro: {
      code: 'pro',
      nameKey: 'planProName',
      memberLimit: -1,
      priceKrwMonthly: 29000,
      priceKrwYearly: 290000
    }
  };

  function getBillingConfig() {
    return global.SWEAT_MANAGER_BILLING || {
      provider: 'toss', // 'toss' | 'stripe' | 'manual'
      tossClientKey: '',
      stripePublishableKey: '',
      checkoutEndpoint: '', // e.g. https://xxxx.functions.supabase.co/create-checkout
      successUrl: '',
      failUrl: ''
    };
  }

  function formatKrw(amount) {
    return new Intl.NumberFormat('ko-KR').format(amount) + '원';
  }

  function normalizeSummary(summary) {
    const raw = summary || {};
    const memberLimit = Number(raw.member_limit);
    const memberCount = Number(raw.member_count) || 0;
    const hasPro = Boolean(raw.has_pro);
    const canAdd = raw.can_add_member != null
      ? Boolean(raw.can_add_member)
      : (memberLimit === -1 || memberCount < memberLimit);

    return {
      gymId: raw.gym_id || null,
      planCode: hasPro ? 'pro' : (raw.plan_code || 'free'),
      subscriptionStatus: raw.subscription_status || 'expired',
      trialEndsAt: raw.trial_ends_at || null,
      currentPeriodEnd: raw.current_period_end || null,
      memberLimit: Number.isFinite(memberLimit) ? memberLimit : 20,
      memberCount,
      hasPro,
      canAddMember: canAdd,
      billingProvider: raw.billing_provider || null
    };
  }

  function limitLabel(summary, t) {
    if (!summary) return '';
    if (summary.memberLimit === -1 || summary.hasPro) {
      return t('planUnlimitedMembers');
    }
    return t('planMemberUsage', {
      count: summary.memberCount,
      limit: summary.memberLimit
    });
  }

  function statusLabel(summary, t) {
    if (!summary) return t('planStatusUnknown');
    if (summary.subscriptionStatus === 'trialing' && summary.hasPro) {
      return t('planStatusTrialing');
    }
    if (summary.hasPro && summary.subscriptionStatus === 'active') {
      return t('planStatusActive');
    }
    if (summary.subscriptionStatus === 'past_due') {
      return t('planStatusPastDue');
    }
    return t('planStatusFree');
  }

  async function fetchBillingSummary(db) {
    if (!db || !db.isReady()) throw new Error('Not authenticated');
    const client = db.client();
    const { data, error } = await client.rpc('get_billing_summary');
    if (error) throw error;
    return normalizeSummary(data);
  }

  /**
   * Start checkout.
   * - If checkoutEndpoint is set: POST { plan, interval, successUrl, failUrl }
   * - Else: return a manual/instructions payload for UI
   */
  async function startCheckout({ plan = 'pro', interval = 'monthly' } = {}) {
    const config = getBillingConfig();
    const successUrl = config.successUrl || `${global.location.origin}${global.location.pathname}?billing=success`;
    const failUrl = config.failUrl || `${global.location.origin}${global.location.pathname}?billing=fail`;

    if (!config.checkoutEndpoint) {
      return {
        mode: 'manual',
        provider: config.provider,
        messageKey: 'billingCheckoutNotConfigured',
        plan,
        interval,
        amountKrw: interval === 'yearly' ? PLANS.pro.priceKrwYearly : PLANS.pro.priceKrwMonthly,
        successUrl,
        failUrl
      };
    }

    const session = await global.SweatManagerDB?.client()?.auth.getSession();
    const accessToken = session?.data?.session?.access_token;
    if (!accessToken) throw new Error('Login required');

    const response = await fetch(config.checkoutEndpoint, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${accessToken}`
      },
      body: JSON.stringify({
        plan,
        interval,
        successUrl,
        failUrl,
        provider: config.provider
      })
    });

    if (!response.ok) {
      const text = await response.text();
      throw new Error(text || 'Checkout failed');
    }

    const payload = await response.json();
    if (payload.checkoutUrl) {
      global.location.href = payload.checkoutUrl;
    }
    return { mode: 'redirect', ...payload };
  }

  global.SweatManagerBilling = {
    PLANS,
    getBillingConfig,
    formatKrw,
    normalizeSummary,
    limitLabel,
    statusLabel,
    fetchBillingSummary,
    startCheckout
  };
})(window);

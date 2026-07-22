/**
 * Sweat Manager - Billing helpers
 * Supports Toss (KRW prepaid period) + Stripe (subscription checkout)
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
      provider: 'toss',
      tossClientKey: '',
      stripePublishableKey: '',
      checkoutEndpoint: '',
      confirmTossEndpoint: '',
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

  async function getAccessToken() {
    const session = await global.SweatManagerDB?.client()?.auth.getSession();
    const accessToken = session?.data?.session?.access_token;
    if (!accessToken) throw new Error('Login required');
    return accessToken;
  }

  async function fetchBillingSummary(db) {
    if (!db || !db.isReady()) throw new Error('Not authenticated');
    const client = db.client();
    const { data, error } = await client.rpc('get_billing_summary');
    if (error) throw error;
    return normalizeSummary(data);
  }

  async function loadTossSdk() {
    if (global.TossPayments) return global.TossPayments;
    await new Promise((resolve, reject) => {
      const existing = document.querySelector('script[data-toss-sdk]');
      if (existing) {
        existing.addEventListener('load', () => resolve());
        existing.addEventListener('error', () => reject(new Error('Toss SDK load failed')));
        return;
      }
      const script = document.createElement('script');
      script.src = 'https://js.tosspayments.com/v2/standard';
      script.async = true;
      script.dataset.tossSdk = '1';
      script.onload = () => resolve();
      script.onerror = () => reject(new Error('Toss SDK load failed'));
      document.head.appendChild(script);
    });
    if (!global.TossPayments) throw new Error('TossPayments unavailable');
    return global.TossPayments;
  }

  async function openTossWidget(payload) {
    const TossPayments = await loadTossSdk();
    const clientKey = payload.clientKey || getBillingConfig().tossClientKey;
    if (!clientKey) throw new Error('TOSS client key missing');

    const tossPayments = TossPayments(clientKey);
    const payment = tossPayments.payment({ customerKey: payload.customerKey });

    await payment.requestPayment({
      method: 'CARD',
      amount: {
        currency: payload.currency || 'KRW',
        value: payload.amount
      },
      orderId: payload.orderId,
      orderName: payload.orderName,
      successUrl: payload.successUrl,
      failUrl: payload.failUrl,
      customerEmail: payload.customerEmail || undefined
    });

    return { mode: 'toss_widget', ...payload };
  }

  async function startCheckout({
    plan = 'pro',
    interval = 'monthly',
    provider
  } = {}) {
    const config = getBillingConfig();
    const selectedProvider = provider || config.provider || 'toss';
    const successUrl = config.successUrl || `${global.location.origin}${global.location.pathname}?billing=success`;
    const failUrl = config.failUrl || `${global.location.origin}${global.location.pathname}?billing=fail`;

    if (!config.checkoutEndpoint) {
      return {
        mode: 'manual',
        provider: selectedProvider,
        messageKey: 'billingCheckoutNotConfigured',
        plan,
        interval,
        amountKrw: interval === 'yearly' ? PLANS.pro.priceKrwYearly : PLANS.pro.priceKrwMonthly,
        successUrl,
        failUrl
      };
    }

    const accessToken = await getAccessToken();
    const response = await fetch(config.checkoutEndpoint, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${accessToken}`,
        apikey: (global.SWEAT_MANAGER_SUPABASE || {}).anonKey || ''
      },
      body: JSON.stringify({
        plan,
        interval,
        successUrl,
        failUrl,
        provider: selectedProvider
      })
    });

    const rawText = await response.text();
    let payload;
    try {
      payload = rawText ? JSON.parse(rawText) : {};
    } catch {
      payload = { message: rawText };
    }

    if (!response.ok) {
      throw new Error(payload.message || rawText || 'Checkout failed');
    }

    if (payload.mode === 'toss_widget' || selectedProvider === 'toss') {
      return openTossWidget(payload);
    }

    if (payload.checkoutUrl) {
      global.location.href = payload.checkoutUrl;
      return { mode: 'redirect', ...payload };
    }

    return payload;
  }

  async function confirmTossFromUrl(searchParams = new URLSearchParams(global.location.search)) {
    const provider = searchParams.get('provider');
    const billing = searchParams.get('billing');
    const paymentKey = searchParams.get('paymentKey');
    const orderId = searchParams.get('orderId');
    const amount = Number(searchParams.get('amount'));

    if (provider !== 'toss' || billing !== 'success' || !paymentKey || !orderId) {
      return null;
    }

    const config = getBillingConfig();
    if (!config.confirmTossEndpoint) {
      throw new Error('confirmTossEndpoint missing');
    }

    const accessToken = await getAccessToken();
    const response = await fetch(config.confirmTossEndpoint, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${accessToken}`,
        apikey: (global.SWEAT_MANAGER_SUPABASE || {}).anonKey || ''
      },
      body: JSON.stringify({ paymentKey, orderId, amount })
    });

    const rawText = await response.text();
    let payload;
    try {
      payload = rawText ? JSON.parse(rawText) : {};
    } catch {
      payload = { message: rawText };
    }

    if (!response.ok) {
      throw new Error(payload.message || rawText || 'Toss confirm failed');
    }

    // Clean query params after success
    const url = new URL(global.location.href);
    ['paymentKey', 'orderId', 'amount', 'paymentType'].forEach((key) => url.searchParams.delete(key));
    global.history.replaceState({}, '', url.toString());

    return payload;
  }

  global.SweatManagerBilling = {
    PLANS,
    getBillingConfig,
    formatKrw,
    normalizeSummary,
    limitLabel,
    statusLabel,
    fetchBillingSummary,
    startCheckout,
    confirmTossFromUrl
  };
})(window);

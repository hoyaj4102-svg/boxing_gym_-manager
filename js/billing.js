/**
 * Sweat Manager - Billing helpers
 * Toss monthly auto-pay (billing key) + cancel-at-period-end
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
      startBillingAuthEndpoint: '',
      confirmBillingAuthEndpoint: '',
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
      canCancel: Boolean(raw.can_cancel),
      autoRenew: Boolean(raw.auto_renew),
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
    if (summary.subscriptionStatus === 'canceled' && summary.hasPro) {
      return t('planStatusCanceledActive');
    }
    if (summary.subscriptionStatus === 'canceled') {
      return t('planStatusCanceled');
    }
    if (summary.hasPro && summary.subscriptionStatus === 'active') {
      return t('planStatusActive');
    }
    if (summary.subscriptionStatus === 'past_due') {
      return t('planStatusPastDue');
    }
    return t('planStatusFree');
  }

  async function cancelSubscription(db) {
    if (!db || !db.isReady()) throw new Error('Not authenticated');
    const client = db.client();
    const { data, error } = await client.rpc('cancel_gym_subscription');
    if (error) throw error;
    return data;
  }

  async function getAccessToken() {
    const session = await global.SweatManagerDB?.client()?.auth.getSession();
    const accessToken = session?.data?.session?.access_token;
    if (!accessToken) throw new Error('Login required');
    return accessToken;
  }

  async function waitForAccessToken(retries = 8) {
    for (let i = 0; i < retries; i += 1) {
      try {
        const token = await getAccessToken();
        if (token) return token;
      } catch {
        // retry
      }
      await new Promise((resolve) => setTimeout(resolve, 250));
    }
    throw new Error('Login required');
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

  async function invokeOrFetch(functionName, endpoint, body) {
    const client = global.SweatManagerDB?.client?.();
    if (client?.functions?.invoke) {
      await waitForAccessToken();
      const { data, error } = await client.functions.invoke(functionName, { body });
      if (error) {
        let message = error.message || `${functionName} failed`;
        try {
          if (typeof error.context?.json === 'function') {
            const errBody = await error.context.json();
            message = errBody?.message || errBody?.error || message;
          } else if (error.context?.body) {
            message = String(error.context.body);
          }
        } catch {
          // keep message
        }
        throw new Error(message);
      }
      return data;
    }

    if (!endpoint) throw new Error(`${functionName} endpoint missing`);
    const accessToken = await waitForAccessToken();
    const response = await fetch(endpoint, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${accessToken}`,
        apikey: (global.SWEAT_MANAGER_SUPABASE || {}).anonKey || ''
      },
      body: JSON.stringify(body || {})
    });

    const rawText = await response.text();
    let payload;
    try {
      payload = rawText ? JSON.parse(rawText) : {};
    } catch {
      payload = { message: rawText };
    }
    if (!response.ok) {
      throw new Error(payload.message || payload.error || rawText || `${functionName} failed`);
    }
    return payload;
  }

  async function openTossBillingAuth(payload) {
    const TossPayments = await loadTossSdk();
    const clientKey = payload.clientKey || getBillingConfig().tossClientKey;
    if (!clientKey) throw new Error('TOSS client key missing');

    const tossPayments = TossPayments(clientKey);
    const payment = tossPayments.payment({ customerKey: payload.customerKey });

    await payment.requestBillingAuth({
      method: 'CARD',
      successUrl: payload.successUrl,
      failUrl: payload.failUrl,
      customerEmail: payload.customerEmail || undefined,
      customerName: payload.customerName || undefined
    });

    return { mode: 'toss_billing_auth', ...payload };
  }

  /** Netflix-style monthly: register card → billing key → first charge */
  async function startSubscribe() {
    const config = getBillingConfig();
    const successUrl = config.successUrl || `${global.location.origin}${global.location.pathname}?billing=success`;
    const failUrl = config.failUrl || `${global.location.origin}${global.location.pathname}?billing=fail`;

    if (!config.startBillingAuthEndpoint && !global.SweatManagerDB?.client?.()?.functions?.invoke) {
      return {
        mode: 'manual',
        provider: 'toss',
        messageKey: 'billingCheckoutNotConfigured',
        amountKrw: PLANS.pro.priceKrwMonthly,
        successUrl,
        failUrl
      };
    }

    const payload = await invokeOrFetch(
      'start-billing-auth',
      config.startBillingAuthEndpoint,
      { successUrl, failUrl }
    );

    return openTossBillingAuth(payload);
  }

  /** Legacy one-time checkout (kept for compatibility) */
  async function startCheckout({
    plan = 'pro',
    interval = 'monthly',
    provider
  } = {}) {
    if ((provider || getBillingConfig().provider || 'toss') === 'toss' && interval === 'monthly') {
      return startSubscribe();
    }

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
      const TossPayments = await loadTossSdk();
      const clientKey = payload.clientKey || config.tossClientKey;
      if (!clientKey) throw new Error('TOSS client key missing');
      const tossPayments = TossPayments(clientKey);
      const payment = tossPayments.payment({ customerKey: payload.customerKey });
      await payment.requestPayment({
        method: 'CARD',
        amount: { currency: payload.currency || 'KRW', value: payload.amount },
        orderId: payload.orderId,
        orderName: payload.orderName,
        successUrl: payload.successUrl,
        failUrl: payload.failUrl,
        customerEmail: payload.customerEmail || undefined
      });
      return { mode: 'toss_widget', ...payload };
    }

    if (payload.checkoutUrl) {
      global.location.href = payload.checkoutUrl;
      return { mode: 'redirect', ...payload };
    }

    return payload;
  }

  function clearBillingParams(extraKeys = []) {
    const url = new URL(global.location.href);
    ['paymentKey', 'orderId', 'amount', 'paymentType', 'billing', 'provider', 'mode', 'authKey', 'customerKey']
      .concat(extraKeys)
      .forEach((key) => url.searchParams.delete(key));
    global.history.replaceState({}, '', `${url.pathname}${url.search}${url.hash}`);
  }

  async function confirmBillingAuthFromUrl(searchParams = new URLSearchParams(global.location.search)) {
    const provider = searchParams.get('provider');
    const billing = searchParams.get('billing');
    const mode = searchParams.get('mode');
    const authKey = searchParams.get('authKey');
    const customerKey = searchParams.get('customerKey');

    if (provider !== 'toss' || billing !== 'success' || mode !== 'billing') {
      return null;
    }

    if (!authKey || !customerKey) {
      const err = new Error('TOSS_BILLING_RETURN_INCOMPLETE');
      err.code = 'TOSS_BILLING_RETURN_INCOMPLETE';
      throw err;
    }

    const config = getBillingConfig();
    const data = await invokeOrFetch(
      'confirm-billing-auth',
      config.confirmBillingAuthEndpoint,
      { authKey, customerKey }
    );
    clearBillingParams();
    return data;
  }

  async function confirmTossFromUrl(searchParams = new URLSearchParams(global.location.search)) {
    const billingAuth = await confirmBillingAuthFromUrl(searchParams);
    if (billingAuth) return billingAuth;

    const provider = searchParams.get('provider');
    const billing = searchParams.get('billing');
    const paymentKey = searchParams.get('paymentKey');
    const orderIds = searchParams.getAll('orderId').filter(Boolean);
    const orderId = orderIds[orderIds.length - 1] || searchParams.get('orderId');
    const amount = Number(searchParams.get('amount'));

    if (provider !== 'toss' || billing !== 'success') {
      return null;
    }

    // Billing-auth return without mode=billing still has authKey
    if (searchParams.get('authKey') && searchParams.get('customerKey')) {
      return confirmBillingAuthFromUrl(
        new URLSearchParams({
          provider: 'toss',
          billing: 'success',
          mode: 'billing',
          authKey: searchParams.get('authKey'),
          customerKey: searchParams.get('customerKey')
        })
      );
    }

    if (!paymentKey || !orderId || !Number.isFinite(amount)) {
      const err = new Error('TOSS_RETURN_INCOMPLETE');
      err.code = 'TOSS_RETURN_INCOMPLETE';
      throw err;
    }

    const config = getBillingConfig();
    const data = await invokeOrFetch('confirm-toss-payment', config.confirmTossEndpoint, {
      paymentKey,
      orderId,
      amount
    });
    clearBillingParams();
    return data;
  }

  global.SweatManagerBilling = {
    PLANS,
    getBillingConfig,
    formatKrw,
    normalizeSummary,
    limitLabel,
    statusLabel,
    fetchBillingSummary,
    startSubscribe,
    startCheckout,
    confirmTossFromUrl,
    confirmBillingAuthFromUrl,
    cancelSubscription
  };
})(window);

import { corsHeaders, jsonResponse, textResponse } from '../_shared/cors.ts';
import { getAdminClient, getGymIdForUser, requireUser } from '../_shared/supabase.ts';

const AMOUNT_KRW = 10000;

function tossAuthHeader() {
  const secret = Deno.env.get('TOSS_SECRET_KEY') || '';
  if (!secret) throw new Error('TOSS_SECRET_KEY is missing');
  return `Basic ${btoa(`${secret}:`)}`;
}

function customerKeyForGym(gymId: string) {
  return `gym_${gymId.replace(/-/g, '')}`;
}

const SENSITIVE_KEYS = new Set([
  'authkey',
  'authorization',
  'billingkey',
  'card',
  'cardnumber',
  'customerkey',
  'secret',
  'secretkey'
]);

function sanitizeTossPayload(value: unknown): unknown {
  if (Array.isArray(value)) {
    return value.map(sanitizeTossPayload);
  }

  if (value && typeof value === 'object') {
    return Object.fromEntries(
      Object.entries(value as Record<string, unknown>).map(([key, entry]) => {
        const normalizedKey = key.replace(/[_\-\s]/g, '').toLowerCase();
        if (SENSITIVE_KEYS.has(normalizedKey)) {
          return [key, '[REDACTED]'];
        }
        return [key, sanitizeTossPayload(entry)];
      })
    );
  }

  return value;
}

function logTossBillingKeyFailure(
  stage: string,
  status: number,
  payload: unknown
) {
  const body = payload && typeof payload === 'object'
    ? payload as Record<string, unknown>
    : {};

  console.error('TOSS_BILLING_KEY_DEBUG', {
    stage,
    status,
    code: body.code || body.errorCode || null,
    message: body.message || body.errorMessage || null,
    raw: sanitizeTossPayload(payload)
  });
}

function errorMessage(error: unknown) {
  return error instanceof Error ? error.message : String(error);
}

async function updatePaymentAttempt(
  admin: ReturnType<typeof getAdminClient>,
  attemptId: string | null,
  values: Record<string, unknown>
) {
  if (!attemptId) return;
  const { error } = await admin
    .from('payment_attempts')
    .update(values)
    .eq('id', attemptId);
  if (error) {
    console.error('PAYMENT_ATTEMPT_UPDATE_FAILED', {
      attemptId,
      error: error.message
    });
  }
}

async function monthlyBillingPeriod(
  admin: ReturnType<typeof getAdminClient>,
): Promise<{ periodStart: string; periodEnd: string }> {
  const { data, error } = await admin.rpc('billing_period_bounds', {
    p_interval: 'monthly'
  });

  if (error) throw new Error(error.message);

  const period = data && typeof data === 'object'
    ? data as Record<string, unknown>
    : {};
  const periodStart = typeof period.period_start === 'string' ? period.period_start : '';
  const periodEnd = typeof period.period_end === 'string' ? period.period_end : '';

  if (!periodStart || !periodEnd) {
    throw new Error('BILLING_PERIOD_BOUNDS_INVALID');
  }

  return { periodStart, periodEnd };
}

async function activatePaymentAttempt(
  admin: ReturnType<typeof getAdminClient>,
  attemptId: string | null
) {
  if (!attemptId) throw new Error('PAYMENT_ATTEMPT_ID_REQUIRED');

  const { data, error } = await admin.rpc('activate_payment_attempt', {
    p_attempt_id: attemptId
  });

  if (error) return error;

  const result = data && typeof data === 'object'
    ? data as Record<string, unknown>
    : {};
  if (result.ok === false) {
    return new Error(String(result.error_message || result.error_code || 'Activation failed'));
  }

  return null;
}

async function tossPost(path: string, body: Record<string, unknown>) {
  const res = await fetch(`https://api.tosspayments.com${path}`, {
    method: 'POST',
    headers: {
      Authorization: tossAuthHeader(),
      'Content-Type': 'application/json'
    },
    body: JSON.stringify(body)
  });
  const json = await res.json();
  if (!res.ok) {
    if (path === '/v1/billing/authorizations/issue') {
      logTossBillingKeyFailure('issue_request_non_2xx', res.status, json);
    }
    throw new Error(json?.message || json?.code || 'Toss API failed');
  }
  return json;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  if (req.method !== 'POST') {
    return textResponse('Method not allowed', 405);
  }

  try {
    const { user } = await requireUser(req);
    const admin = getAdminClient();
    const gymId = await getGymIdForUser(admin, user.id);

    const body = await req.json();
    const authKey = String(body.authKey || '').trim();
    const customerKey = String(body.customerKey || '').trim();

    if (!authKey || !customerKey) {
      return textResponse('authKey and customerKey are required', 400);
    }

    const expected = customerKeyForGym(gymId);
    if (customerKey !== expected) {
      return textResponse('Invalid customerKey', 400);
    }

    // Idempotency: if already active with this customer key and auto_renew, skip re-issue
    const { data: gym } = await admin
      .from('gyms')
      .select('id, name, subscription_status, billing_customer_id, billing_subscription_id, auto_renew')
      .eq('id', gymId)
      .maybeSingle();

    if (
      gym?.subscription_status === 'active' &&
      gym?.auto_renew === true &&
      gym?.billing_customer_id === customerKey &&
      gym?.billing_subscription_id
    ) {
      return jsonResponse({
        ok: true,
        alreadyActive: true,
        gymId,
        interval: 'monthly'
      });
    }

    const orderId = `toss_bill_${Date.now()}_${crypto.randomUUID().replace(/-/g, '').slice(0, 12)}`;
    let paymentAttemptId: string | null = null;

    const { periodStart, periodEnd } = await monthlyBillingPeriod(admin);

    const { data: paymentAttempt, error: attemptError } = await admin
      .from('payment_attempts')
      .insert({
        gym_id: gymId,
        user_id: user.id,
        provider: 'toss',
        payment_type: 'initial_billing',
        billing_interval: 'monthly',
        amount_krw: AMOUNT_KRW,
        currency: 'KRW',
        order_id: orderId,
        customer_key: customerKey,
        target_period_start: periodStart,
        target_period_end: periodEnd,
        status: 'initiated',
        activation_status: 'not_started',
        recovery_status: 'none',
        provider_response: { mode: 'billing_auth_start' }
      })
      .select('id')
      .single();

    if (attemptError) {
      return textResponse(attemptError.message, 500);
    }
    paymentAttemptId = paymentAttempt.id;

    const issued = await tossPost('/v1/billing/authorizations/issue', {
      authKey,
      customerKey
    });

    const billingKey = String(issued.billingKey || '');
    if (!billingKey) {
      logTossBillingKeyFailure('issue_response_missing_billing_key', 200, issued);
      await updatePaymentAttempt(admin, paymentAttemptId, {
        status: 'charge_failed',
        activation_status: 'not_started',
        error_message: 'Failed to issue billing key',
        provider_response: sanitizeTossPayload(issued)
      });
      return textResponse('Failed to issue billing key', 502);
    }

    await updatePaymentAttempt(admin, paymentAttemptId, {
      status: 'auth_issued',
      billing_key_ref: billingKey,
      provider_response: {
        mode: 'billing_key_issued',
        response: sanitizeTossPayload(issued)
      }
    });

    const { data: sessionRow, error: insertError } = await admin
      .from('checkout_sessions')
      .insert({
        gym_id: gymId,
        user_id: user.id,
        provider: 'toss',
        interval: 'monthly',
        amount_krw: AMOUNT_KRW,
        amount_usd_cents: 0,
        currency: 'KRW',
        status: 'pending',
        order_id: orderId,
        raw: {
          mode: 'billing_key',
          cardCompany: issued.card?.company || null,
          cardNumber: issued.card?.number || null
        }
      })
      .select('id')
      .single();

    if (insertError) {
      return textResponse(insertError.message, 500);
    }

    let charged;
    try {
      charged = await tossPost(`/v1/billing/${billingKey}`, {
        customerKey,
        amount: AMOUNT_KRW,
        orderId,
        orderName: 're;member Pro 월간 구독',
        customerEmail: user.email || undefined,
        customerName: gym?.name || undefined
      });
    } catch (chargeError) {
      await admin
        .from('checkout_sessions')
        .update({
          status: 'failed',
          raw: { error: String(chargeError) }
        })
        .eq('id', sessionRow.id);
      await updatePaymentAttempt(admin, paymentAttemptId, {
        status: 'charge_failed',
        activation_status: 'not_started',
        recovery_status: 'none',
        error_message: errorMessage(chargeError)
      });
      throw chargeError;
    }

    const paymentKey = String(charged.paymentKey || orderId);

    await updatePaymentAttempt(admin, paymentAttemptId, {
      status: 'activation_pending',
      activation_status: 'pending',
      recovery_status: 'none',
      payment_key: paymentKey,
      provider_response: sanitizeTossPayload(charged)
    });

    const activateError = await activatePaymentAttempt(admin, paymentAttemptId);

    if (activateError) {
      await updatePaymentAttempt(admin, paymentAttemptId, {
        status: 'activation_failed',
        activation_status: 'failed',
        recovery_status: 'pending',
        error_message: activateError.message
      });
      return textResponse(activateError.message, 500);
    }

    await updatePaymentAttempt(admin, paymentAttemptId, {
      status: 'completed',
      activation_status: 'succeeded',
      recovery_status: 'none',
      activated_at: new Date().toISOString(),
      error_code: null,
      error_message: null
    });

    await admin
      .from('checkout_sessions')
      .update({
        status: 'completed',
        provider_session_id: paymentKey,
        completed_at: new Date().toISOString(),
        raw: { ...charged, billingKeyIssued: true }
      })
      .eq('id', sessionRow.id);

    return jsonResponse({
      ok: true,
      provider: 'toss',
      gymId,
      orderId,
      paymentKey,
      interval: 'monthly',
      billingKeyIssued: true
    });
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    const status = message === 'UNAUTHORIZED' ? 401 : 400;
    return textResponse(message, status);
  }
});

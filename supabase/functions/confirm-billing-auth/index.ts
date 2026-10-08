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

function claimValue(claim: Record<string, unknown>, key: string) {
  const value = claim[key];
  return typeof value === 'string' ? value : '';
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

async function updatePaymentAttemptRequired(
  admin: ReturnType<typeof getAdminClient>,
  attemptId: string | null,
  values: Record<string, unknown>,
  errorCode: string
) {
  if (!attemptId) throw new Error('PAYMENT_ATTEMPT_ID_REQUIRED');
  const { error } = await admin
    .from('payment_attempts')
    .update(values)
    .eq('id', attemptId);
  if (error) {
    throw new Error(`${errorCode}: ${error.message}`);
  }
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

async function recoverPaymentAttemptActivation(
  admin: ReturnType<typeof getAdminClient>,
  attemptId: string | null
) {
  if (!attemptId) throw new Error('PAYMENT_ATTEMPT_ID_REQUIRED');

  const { data, error } = await admin.rpc('recover_payment_attempt_activation', {
    p_attempt_id: attemptId
  });

  if (error) return error;

  const result = data && typeof data === 'object'
    ? data as Record<string, unknown>
    : {};
  if (result.ok === false) {
    return new Error(String(result.error_message || result.error_code || 'Recovery failed'));
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

    const { data: claimData, error: claimError } = await admin.rpc(
      'claim_initial_billing_attempt',
      {
        p_gym_id: gymId,
        p_user_id: user.id,
        p_customer_key: customerKey,
        p_amount_krw: AMOUNT_KRW
      }
    );

    if (claimError) {
      return textResponse(claimError.message, 500);
    }

    const claim = claimData && typeof claimData === 'object'
      ? claimData as Record<string, unknown>
      : {};
    const action = claimValue(claim, 'action') || 'processing';
    const canCharge = claim.can_charge === true;
    const paymentAttemptId = claimValue(claim, 'payment_attempt_id') || null;
    const orderId = claimValue(claim, 'order_id');
    const gymName = claimValue(claim, 'gym_name');

    if (action === 'already_completed') {
      return jsonResponse({
        ok: true,
        alreadyActive: true,
        gymId,
        interval: 'monthly',
        paymentAttemptId,
        orderId: orderId || undefined
      });
    }

    if (action === 'needs_recovery') {
      const recoveryError = await recoverPaymentAttemptActivation(admin, paymentAttemptId);
      if (!recoveryError) {
        return jsonResponse({
          ok: true,
          provider: 'toss',
          gymId,
          orderId,
          interval: 'monthly',
          paymentAttemptId,
          recovered: true
        });
      }

      return jsonResponse({
        ok: false,
        action,
        canCharge: false,
        paymentAttemptId,
        orderId,
        message: recoveryError.message || 'INITIAL_BILLING_RECOVERY_PENDING'
      }, 409);
    }

    if (!canCharge) {
      return jsonResponse({
        ok: false,
        action,
        canCharge: false,
        paymentAttemptId,
        orderId,
        message: action === 'do_not_charge'
          ? 'INITIAL_BILLING_DO_NOT_CHARGE'
          : 'INITIAL_BILLING_PROCESSING'
      }, 409);
    }

    if (!paymentAttemptId || !orderId) {
      return textResponse('INITIAL_BILLING_CLAIM_INVALID', 500);
    }

    let issued;
    try {
      issued = await tossPost('/v1/billing/authorizations/issue', {
        authKey,
        customerKey
      });
    } catch (issueError) {
      await updatePaymentAttempt(admin, paymentAttemptId, {
        status: 'charge_failed',
        activation_status: 'not_started',
        recovery_status: 'none',
        error_message: errorMessage(issueError)
      });
      throw issueError;
    }

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
        customerName: gymName || user.email || undefined
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

    await updatePaymentAttemptRequired(admin, paymentAttemptId, {
      status: 'charge_succeeded',
      activation_status: 'pending',
      recovery_status: 'none',
      payment_key: paymentKey,
      provider_response: sanitizeTossPayload(charged)
    }, 'PAYMENT_ATTEMPT_DURABLE_CHARGE_UPDATE_FAILED');

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

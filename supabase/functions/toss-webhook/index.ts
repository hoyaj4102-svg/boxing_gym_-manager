import { corsHeaders, jsonResponse, textResponse } from '../_shared/cors.ts';
import { getAdminClient } from '../_shared/supabase.ts';

const SUPPORTED_EVENT_TYPE = 'PAYMENT_STATUS_CHANGED';
const TOSS_LOOKUP_TIMEOUT_MS = 10000;

type WebhookEventRow = {
  id: string;
  processing_status: string;
};

type PaymentAttempt = {
  id: string;
  gym_id: string;
  payment_type: string;
  amount_krw: number;
  order_id: string;
  payment_key: string | null;
  status: string;
  activation_status: string;
  recovery_status: string;
};

type TossLookupResult =
  | { kind: 'found'; payment: Record<string, unknown> }
  | { kind: 'not_found'; status: number; payload: unknown }
  | { kind: 'retryable_error'; status?: number; message: string; payload?: unknown };

const SENSITIVE_KEYS = new Set([
  'authorization',
  'billingkey',
  'card',
  'cardnumber',
  'customerkey',
  'secret',
  'secretkey'
]);

class DbWriteError extends Error {
  code: string | null;

  constructor(message: string, code: string | null = null) {
    super(message);
    this.name = 'DbWriteError';
    this.code = code;
  }
}

function tossAuthHeader() {
  const secret = Deno.env.get('TOSS_SECRET_KEY') || '';
  if (!secret) throw new Error('TOSS_SECRET_KEY is missing');
  return `Basic ${btoa(`${secret}:`)}`;
}

function errorMessage(error: unknown) {
  return error instanceof Error ? error.message : String(error);
}

function sanitizePayload(value: unknown): unknown {
  if (Array.isArray(value)) {
    return value.map(sanitizePayload);
  }

  if (value && typeof value === 'object') {
    return Object.fromEntries(
      Object.entries(value as Record<string, unknown>).map(([key, entry]) => {
        const normalizedKey = key.replace(/[_\-\s]/g, '').toLowerCase();
        if (SENSITIVE_KEYS.has(normalizedKey)) {
          return [key, '[REDACTED]'];
        }
        return [key, sanitizePayload(entry)];
      })
    );
  }

  return value;
}

function asRecord(value: unknown): Record<string, unknown> {
  return value && typeof value === 'object' && !Array.isArray(value)
    ? value as Record<string, unknown>
    : {};
}

function firstString(...values: unknown[]) {
  for (const value of values) {
    if (typeof value === 'string' && value.trim()) {
      return value.trim();
    }
  }
  return '';
}

function extractEventFields(payload: Record<string, unknown>) {
  const data = asRecord(payload.data);
  const payment = asRecord(data.payment);

  return {
    eventType: firstString(payload.eventType, payload.event_type, payload.type),
    orderId: firstString(data.orderId, payment.orderId, payload.orderId),
    paymentKey: firstString(data.paymentKey, payment.paymentKey, payload.paymentKey)
  };
}

async function readJson(req: Request) {
  const text = await req.text();
  if (!text) return {};
  return JSON.parse(text);
}

async function readJsonResponse(response: Response) {
  const text = await response.text();
  if (!text) return null;
  try {
    return JSON.parse(text);
  } catch {
    return { raw: text };
  }
}

async function lookupTossPaymentByOrderId(orderId: string): Promise<TossLookupResult> {
  const controller = new AbortController();
  const timeoutId = setTimeout(() => controller.abort(), TOSS_LOOKUP_TIMEOUT_MS);

  try {
    const response = await fetch(
      `https://api.tosspayments.com/v1/payments/orders/${encodeURIComponent(orderId)}`,
      {
        method: 'GET',
        headers: {
          Authorization: tossAuthHeader()
        },
        signal: controller.signal
      }
    );
    const payload = await readJsonResponse(response);

    if (response.ok && payload && typeof payload === 'object' && !Array.isArray(payload)) {
      return { kind: 'found', payment: payload as Record<string, unknown> };
    }

    if (response.status === 404) {
      return { kind: 'not_found', status: response.status, payload };
    }

    return {
      kind: 'retryable_error',
      status: response.status,
      message: `Unexpected Toss lookup response: ${response.status}`,
      payload
    };
  } catch (error) {
    return {
      kind: 'retryable_error',
      message: errorMessage(error)
    };
  } finally {
    clearTimeout(timeoutId);
  }
}

function validatePayment(
  attempt: PaymentAttempt,
  webhookOrderId: string,
  payment: Record<string, unknown>
) {
  const paymentKey = typeof payment.paymentKey === 'string' ? payment.paymentKey : '';
  const orderId = typeof payment.orderId === 'string' ? payment.orderId : '';
  const status = typeof payment.status === 'string' ? payment.status : '';
  const totalAmount = Number(payment.totalAmount);
  const expectedMid = Deno.env.get('TOSS_MID') || Deno.env.get('TOSS_MERCHANT_ID') || '';
  const paymentMid = typeof payment.mId === 'string' ? payment.mId : '';

  const failures: string[] = [];
  if (orderId !== webhookOrderId) failures.push('queried orderId mismatch');
  if (attempt.order_id !== orderId) failures.push('payment_attempt orderId mismatch');
  if (!Number.isFinite(totalAmount) || totalAmount !== Number(attempt.amount_krw)) {
    failures.push('amount mismatch');
  }
  if (!paymentKey) failures.push('paymentKey missing');
  if (expectedMid && paymentMid !== expectedMid) failures.push('mId mismatch');

  return {
    ok: failures.length === 0,
    paymentKey,
    status,
    failures,
    midCheck: expectedMid ? 'checked' : 'skipped_no_expected_mid'
  };
}

async function updateWebhookEvent(
  admin: ReturnType<typeof getAdminClient>,
  eventId: string,
  values: Record<string, unknown>
) {
  const { error } = await admin
    .from('toss_webhook_events')
    .update(values)
    .eq('id', eventId);
  if (error) {
    throw new Error(`WEBHOOK_EVENT_UPDATE_FAILED: ${error.message}`);
  }
}

async function insertOrLoadWebhookEvent(
  admin: ReturnType<typeof getAdminClient>,
  params: {
    transmissionId: string;
    eventType: string;
    orderId: string | null;
    paymentKey: string | null;
    payload: unknown;
  }
) {
  const insertPayload = {
    provider: 'toss',
    transmission_id: params.transmissionId,
    event_type: params.eventType,
    order_id: params.orderId,
    payment_key: params.paymentKey,
    received_payload: sanitizePayload(params.payload),
    verification_status: 'unverified_payload',
    processing_status: 'received'
  };

  const { data, error } = await admin
    .from('toss_webhook_events')
    .insert(insertPayload)
    .select('id, processing_status')
    .single();

  if (!error) {
    return { event: data as WebhookEventRow, duplicate: false };
  }

  if (error.code !== '23505') {
    throw new Error(error.message);
  }

  const { data: existing, error: selectError } = await admin
    .from('toss_webhook_events')
    .select('id, processing_status')
    .eq('provider', 'toss')
    .eq('transmission_id', params.transmissionId)
    .maybeSingle();

  if (selectError || !existing) {
    throw new Error(selectError?.message || 'WEBHOOK_EVENT_DUPLICATE_LOOKUP_FAILED');
  }

  return { event: existing as WebhookEventRow, duplicate: true };
}

async function updatePaymentAttempt(
  admin: ReturnType<typeof getAdminClient>,
  attemptId: string,
  values: Record<string, unknown>
) {
  const { error } = await admin
    .from('payment_attempts')
    .update(values)
    .eq('id', attemptId);
  if (error) {
    throw new DbWriteError(`PAYMENT_ATTEMPT_UPDATE_FAILED: ${error.message}`, error.code || null);
  }
}

async function findAutoRenewalAttempt(
  admin: ReturnType<typeof getAdminClient>,
  orderId: string
) {
  const { data, error } = await admin
    .from('payment_attempts')
    .select('id, gym_id, payment_type, amount_krw, order_id, payment_key, status, activation_status, recovery_status')
    .eq('provider', 'toss')
    .eq('payment_type', 'auto_renewal')
    .eq('order_id', orderId)
    .maybeSingle();

  if (error) {
    throw new Error(error.message);
  }

  return data as PaymentAttempt | null;
}

function isRecoverableAttempt(attempt: PaymentAttempt) {
  return [
    'charge_succeeded',
    'activation_pending',
    'activation_failed',
    'recovery_pending'
  ].includes(attempt.status);
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  if (req.method !== 'POST') {
    return textResponse('Method not allowed', 405);
  }

  const admin = getAdminClient();

  try {
    const parsedPayload = asRecord(await readJson(req));
    const { eventType, orderId, paymentKey } = extractEventFields(parsedPayload);
    const rawTransmissionId = firstString(
      req.headers.get('tosspayments-webhook-transmission-id')
    );
    const transmissionId = rawTransmissionId || `missing_${crypto.randomUUID()}`;

    const { event, duplicate } = await insertOrLoadWebhookEvent(admin, {
      transmissionId,
      eventType,
      orderId: orderId || null,
      paymentKey: paymentKey || null,
      payload: parsedPayload
    });

    if (duplicate && !['received', 'processing', 'retryable_error'].includes(event.processing_status)) {
      return jsonResponse({
        ok: true,
        duplicate: true,
        processingStatus: event.processing_status
      });
    }

    if (!rawTransmissionId) {
      await updateWebhookEvent(admin, event.id, {
        verification_status: 'invalid',
        processing_status: 'invalid',
        error_code: 'TRANSMISSION_ID_MISSING',
        error_message: 'tosspayments-webhook-transmission-id header missing'
      });
      return jsonResponse({ ok: true, ignored: true, reason: 'transmission_id_missing' });
    }

    await updateWebhookEvent(admin, event.id, {
      processing_status: 'processing'
    });

    if (eventType !== SUPPORTED_EVENT_TYPE) {
      await updateWebhookEvent(admin, event.id, {
        verification_status: 'not_applicable',
        processing_status: 'ignored',
        error_code: 'UNSUPPORTED_EVENT_TYPE',
        error_message: eventType || 'eventType missing'
      });
      return jsonResponse({ ok: true, ignored: true, reason: 'unsupported_event_type' });
    }

    if (!orderId) {
      await updateWebhookEvent(admin, event.id, {
        verification_status: 'invalid',
        processing_status: 'invalid',
        error_code: 'ORDER_ID_MISSING',
        error_message: 'PAYMENT_STATUS_CHANGED payload did not include orderId'
      });
      return jsonResponse({ ok: true, ignored: true, reason: 'order_id_missing' });
    }

    const lookup = await lookupTossPaymentByOrderId(orderId);
    if (lookup.kind === 'retryable_error') {
      await updateWebhookEvent(admin, event.id, {
        processing_status: 'retryable_error',
        error_code: lookup.status ? `TOSS_LOOKUP_${lookup.status}` : 'TOSS_LOOKUP_RETRYABLE',
        error_message: lookup.message
      });
      return jsonResponse({ ok: false, retryable: true, error: lookup.message }, 500);
    }

    if (lookup.kind === 'not_found') {
      await updateWebhookEvent(admin, event.id, {
        verification_status: 'not_verified',
        processing_status: 'not_found',
        error_code: 'TOSS_PAYMENT_NOT_FOUND',
        error_message: 'Toss payment was not found for orderId'
      });
      return jsonResponse({ ok: true, ignored: true, reason: 'payment_not_found' });
    }

    const attempt = await findAutoRenewalAttempt(admin, orderId);
    if (!attempt) {
      await updateWebhookEvent(admin, event.id, {
        verification_status: 'verified_by_toss_lookup',
        processing_status: 'attempt_not_found',
        payment_key: typeof lookup.payment.paymentKey === 'string' ? lookup.payment.paymentKey : null,
        error_code: 'PAYMENT_ATTEMPT_NOT_FOUND',
        error_message: 'No auto_renewal payment_attempt found for orderId'
      });
      return jsonResponse({ ok: true, ignored: true, reason: 'payment_attempt_not_found' });
    }

    const validation = validatePayment(attempt, orderId, lookup.payment);
    if (!validation.ok) {
      await updateWebhookEvent(admin, event.id, {
        verification_status: 'not_verified',
        processing_status: 'validation_failed',
        payment_key: validation.paymentKey || null,
        error_code: 'TOSS_PAYMENT_VALIDATION_FAILED',
        error_message: `${validation.failures.join('; ')}; mid_check=${validation.midCheck}`
      });
      return jsonResponse({ ok: true, ignored: true, reason: 'validation_failed' });
    }

    if (validation.status !== 'DONE') {
      await updateWebhookEvent(admin, event.id, {
        verification_status: 'verified_by_toss_lookup',
        processing_status: 'non_done',
        payment_key: validation.paymentKey,
        error_code: `TOSS_PAYMENT_${validation.status || 'STATUS_MISSING'}`,
        error_message: 'Payment status is not DONE; no subscription state changed'
      });
      return jsonResponse({ ok: true, ignored: true, reason: 'payment_not_done' });
    }

    if (attempt.status === 'completed' && attempt.activation_status === 'succeeded') {
      await updateWebhookEvent(admin, event.id, {
        verification_status: 'verified_by_toss_lookup',
        processing_status: 'already_completed',
        payment_key: validation.paymentKey,
        error_code: null,
        error_message: `already completed; mid_check=${validation.midCheck}`
      });
      return jsonResponse({ ok: true, alreadyCompleted: true });
    }

    try {
      if (attempt.status === 'initiated') {
        await updatePaymentAttempt(admin, attempt.id, {
          status: 'activation_pending',
          activation_status: 'pending',
          recovery_status: 'none',
          payment_key: validation.paymentKey,
          error_code: null,
          error_message: null,
          provider_response: sanitizePayload({
            webhook: {
              transmission_id: transmissionId,
              event_type: eventType,
              mid_check: validation.midCheck
            },
            payment: lookup.payment
          })
        });
      } else if (isRecoverableAttempt(attempt)) {
        await updatePaymentAttempt(admin, attempt.id, {
          payment_key: validation.paymentKey,
          error_code: null,
          error_message: null,
          provider_response: sanitizePayload({
            webhook: {
              transmission_id: transmissionId,
              event_type: eventType,
              mid_check: validation.midCheck
            },
            payment: lookup.payment
          })
        });
      } else {
        await updateWebhookEvent(admin, event.id, {
          verification_status: 'verified_by_toss_lookup',
          processing_status: 'not_recoverable',
          payment_key: validation.paymentKey,
          error_code: 'PAYMENT_ATTEMPT_NOT_RECOVERABLE',
          error_message: `payment_attempt status is ${attempt.status}`
        });
        return jsonResponse({ ok: true, ignored: true, reason: 'payment_attempt_not_recoverable' });
      }
    } catch (error) {
      const dbError = error as Partial<DbWriteError>;
      const isUniqueViolation = dbError.code === '23505';
      await updateWebhookEvent(admin, event.id, {
        verification_status: 'verified_by_toss_lookup',
        processing_status: isUniqueViolation ? 'data_conflict' : 'retryable_error',
        payment_key: validation.paymentKey,
        error_code: isUniqueViolation
          ? 'PAYMENT_KEY_CONFLICT'
          : (dbError.code || 'PAYMENT_ATTEMPT_UPDATE_FAILED'),
        error_message: errorMessage(error)
      });
      return jsonResponse({
        ok: false,
        retryable: !isUniqueViolation,
        error: errorMessage(error)
      }, isUniqueViolation ? 200 : 500);
    }

    const { data: recoveryResult, error: recoveryError } = await admin.rpc(
      'recover_payment_attempt_activation',
      { p_attempt_id: attempt.id }
    );

    if (recoveryError) {
      await updatePaymentAttempt(admin, attempt.id, {
        status: 'activation_failed',
        activation_status: 'failed',
        recovery_status: 'pending',
        error_code: recoveryError.code || 'WEBHOOK_RECOVERY_FAILED',
        error_message: recoveryError.message
      });
      await updateWebhookEvent(admin, event.id, {
        verification_status: 'verified_by_toss_lookup',
        processing_status: 'recovery_failed',
        payment_key: validation.paymentKey,
        error_code: recoveryError.code || 'WEBHOOK_RECOVERY_FAILED',
        error_message: recoveryError.message
      });
      return jsonResponse({ ok: false, recoveredPayment: true, error: recoveryError.message }, 500);
    }

    await updateWebhookEvent(admin, event.id, {
      verification_status: 'verified_by_toss_lookup',
      processing_status: 'processed',
      payment_key: validation.paymentKey,
      error_code: null,
      error_message: `mid_check=${validation.midCheck}`
    });

    return jsonResponse({
      ok: true,
      processed: true,
      paymentAttemptId: attempt.id,
      recovery: recoveryResult
    });
  } catch (error) {
    const message = errorMessage(error);
    return jsonResponse({ ok: false, error: message || 'Unknown error' }, 500);
  }
});

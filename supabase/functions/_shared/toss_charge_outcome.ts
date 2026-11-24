import { chargeIdempotencyKey } from "./toss_idempotency.ts";

export type TossBillingChargeRequest = {
  billingKey: string;
  authorization: string;
  body: Record<string, unknown>;
  /**
   * Optional explicit key. When omitted, the key is derived from `body.orderId`.
   * A provided key must equal that derived key; approval is not sent otherwise.
   * The same payment attempt keeps one orderId, so a retry reuses this key.
   */
  idempotencyKey?: string;
  fetchImpl?: typeof fetch;
};

export type TossBillingChargeOutcome =
  | {
    kind: "success";
    paymentKey: string;
    payload: Record<string, unknown>;
  }
  | {
    kind: "rejected";
    status: number | null;
    code: string;
    message: string;
    payload: unknown;
  }
  | {
    kind: "uncertain";
    status: number | null;
    code: string;
    message: string;
    payload: unknown;
  };

function errorMessage(error: unknown) {
  return error instanceof Error ? error.message : String(error);
}

function payloadMessage(payload: unknown, fallback: string) {
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
    return fallback;
  }

  const body = payload as Record<string, unknown>;
  return String(
    body.message || body.errorMessage || body.code || body.errorCode ||
      fallback,
  );
}

function payloadCode(payload: unknown, fallback: string) {
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
    return fallback;
  }

  const body = payload as Record<string, unknown>;
  return String(body.code || body.errorCode || fallback);
}

function isUncertainHttpStatus(status: number) {
  return status === 408 || status === 409 || status === 425 || status === 429 ||
    status >= 500;
}

function unresolvedKey(code: string): TossBillingChargeOutcome {
  return {
    kind: "uncertain",
    status: null,
    code,
    message: code,
    payload: null,
  };
}

function resolveChargeIdempotencyKey(
  request: TossBillingChargeRequest,
): { key: string } | { error: string } {
  const orderId = request.body.orderId;
  if (typeof orderId !== "string" || orderId.trim() === "") {
    return { error: "IDEMPOTENCY_KEY_INVALID" };
  }

  let derived: string;
  try {
    derived = chargeIdempotencyKey(orderId);
  } catch (error) {
    return {
      error: error instanceof Error ? error.message : "IDEMPOTENCY_KEY_INVALID",
    };
  }

  if (
    request.idempotencyKey !== undefined &&
    request.idempotencyKey !== derived
  ) {
    return { error: "IDEMPOTENCY_KEY_MISMATCH" };
  }

  return { key: derived };
}

async function readJsonPayload(response: Response) {
  const text = await response.text();
  if (!text) return { payload: null, malformed: false };

  try {
    return { payload: JSON.parse(text), malformed: false };
  } catch {
    return { payload: { raw: text }, malformed: true };
  }
}

export async function chargeTossBilling(
  request: TossBillingChargeRequest,
): Promise<TossBillingChargeOutcome> {
  const fetchImpl = request.fetchImpl ?? fetch;
  const resolvedKey = resolveChargeIdempotencyKey(request);
  if ("error" in resolvedKey) {
    return unresolvedKey(resolvedKey.error);
  }

  let response: Response;
  try {
    response = await fetchImpl(
      `https://api.tosspayments.com/v1/billing/${
        encodeURIComponent(request.billingKey)
      }`,
      {
        method: "POST",
        headers: {
          Authorization: request.authorization,
          "Content-Type": "application/json",
          "Idempotency-Key": resolvedKey.key,
        },
        body: JSON.stringify(request.body),
      },
    );
  } catch (error) {
    return {
      kind: "uncertain",
      status: null,
      code: "TOSS_CHARGE_NETWORK_UNCERTAIN",
      message: errorMessage(error),
      payload: null,
    };
  }

  let parsed: { payload: unknown; malformed: boolean };
  try {
    parsed = await readJsonPayload(response);
  } catch (error) {
    return {
      kind: "uncertain",
      status: response.status,
      code: "TOSS_CHARGE_RESPONSE_READ_UNCERTAIN",
      message: errorMessage(error),
      payload: null,
    };
  }

  if (!response.ok) {
    const uncertain = isUncertainHttpStatus(response.status) ||
      parsed.malformed;
    return {
      kind: uncertain ? "uncertain" : "rejected",
      status: response.status,
      code: uncertain
        ? "TOSS_CHARGE_HTTP_UNCERTAIN"
        : payloadCode(parsed.payload, `TOSS_CHARGE_HTTP_${response.status}`),
      message: payloadMessage(
        parsed.payload,
        `Toss billing charge failed with HTTP ${response.status}`,
      ),
      payload: parsed.payload,
    };
  }

  if (
    parsed.malformed || !parsed.payload || typeof parsed.payload !== "object" ||
    Array.isArray(parsed.payload)
  ) {
    return {
      kind: "uncertain",
      status: response.status,
      code: "TOSS_CHARGE_RESPONSE_UNCERTAIN",
      message: "Toss billing charge returned an unreadable success response",
      payload: parsed.payload,
    };
  }

  const payload = parsed.payload as Record<string, unknown>;
  const paymentKey = typeof payload.paymentKey === "string"
    ? payload.paymentKey
    : "";
  if (!paymentKey) {
    return {
      kind: "uncertain",
      status: response.status,
      code: "TOSS_CHARGE_PAYMENT_KEY_MISSING_UNCERTAIN",
      message: "Toss billing charge response did not include paymentKey",
      payload,
    };
  }

  return {
    kind: "success",
    paymentKey,
    payload,
  };
}

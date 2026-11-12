export type TossCancelOutcome =
  | { kind: "success"; payload: Record<string, unknown> }
  | { kind: "rejected"; status: number | null; code: string; message: string }
  | { kind: "uncertain"; status: number | null; code: string; message: string };

function errorMessage(error: unknown) {
  return error instanceof Error ? error.message : String(error);
}

export async function cancelTossPayment(input: {
  paymentKey: string;
  cancelReason: string;
  cancelAmountKrw: number | null;
  idempotencyKey: string;
  authorization: string;
  fetchImpl?: typeof fetch;
}): Promise<TossCancelOutcome> {
  const fetchImpl = input.fetchImpl ?? fetch;
  const body: Record<string, unknown> = { cancelReason: input.cancelReason };
  if (input.cancelAmountKrw != null) body.cancelAmount = input.cancelAmountKrw;

  let response: Response;
  try {
    response = await fetchImpl(
      `https://api.tosspayments.com/v1/payments/${encodeURIComponent(input.paymentKey)}/cancel`,
      {
        method: "POST",
        headers: {
          Authorization: input.authorization,
          "Content-Type": "application/json",
          "Idempotency-Key": input.idempotencyKey,
        },
        body: JSON.stringify(body),
      },
    );
  } catch (error) {
    return {
      kind: "uncertain",
      status: null,
      code: "TOSS_CANCEL_NETWORK_UNCERTAIN",
      message: errorMessage(error),
    };
  }

  const text = await response.text();
  if (!response.ok) {
    return {
      kind: response.status >= 500 ? "uncertain" : "rejected",
      status: response.status,
      code: response.status >= 500 ? "TOSS_CANCEL_HTTP_UNCERTAIN" : `TOSS_CANCEL_HTTP_${response.status}`,
      message: text.slice(0, 180) || `Toss cancel failed with HTTP ${response.status}`,
    };
  }

  return { kind: "success", payload: { status: response.status } };
}

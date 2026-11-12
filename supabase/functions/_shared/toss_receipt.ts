import { extractTossReceiptUrl } from "./toss_receipt_url.ts";

export { extractTossReceiptUrl } from "./toss_receipt_url.ts";

export type TossReceiptLookup = {
  providerCalls: number;
  code: string;
  receiptUrl: string | null;
};

// Reads the receipt from a live Toss payment lookup. Callers must pass the
// payment key from payment_attempts.payment_key or the matching checkout /
// subscription column, never from stored provider_response.
export async function lookupTossReceiptByPaymentKey(input: {
  paymentKey: string;
  authorization: string;
  fetchImpl?: typeof fetch;
}): Promise<TossReceiptLookup> {
  if (!input.paymentKey) {
    return { providerCalls: 0, code: "PAYMENT_KEY_MISSING", receiptUrl: null };
  }

  const fetchImpl = input.fetchImpl ?? fetch;
  let response: Response;
  try {
    response = await fetchImpl(
      `https://api.tosspayments.com/v1/payments/${encodeURIComponent(input.paymentKey)}`,
      {
        method: "GET",
        headers: { Authorization: input.authorization },
      },
    );
  } catch {
    return { providerCalls: 1, code: "TOSS_RECEIPT_NETWORK", receiptUrl: null };
  }

  const text = await response.text();
  if (!response.ok) {
    return { providerCalls: 1, code: `TOSS_RECEIPT_HTTP_${response.status}`, receiptUrl: null };
  }

  let payload: unknown = null;
  try {
    payload = text ? JSON.parse(text) : null;
  } catch {
    return { providerCalls: 1, code: "TOSS_RECEIPT_UNREADABLE", receiptUrl: null };
  }

  const receiptUrl = extractTossReceiptUrl(payload);
  if (!receiptUrl) {
    return { providerCalls: 1, code: "RECEIPT_URL_UNAVAILABLE", receiptUrl: null };
  }
  return { providerCalls: 1, code: "RECEIPT_FOUND", receiptUrl };
}

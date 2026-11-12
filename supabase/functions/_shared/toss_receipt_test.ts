import { extractTossReceiptUrl } from "./toss_receipt_url.ts";
import { lookupTossReceiptByPaymentKey } from "./toss_receipt.ts";

function assert(condition: unknown, message: string) {
  if (!condition) throw new Error(message);
}

Deno.test("only an https Toss receipt URL is kept from a live payload", () => {
  assert(
    extractTossReceiptUrl({
      receipt: { url: "https://dashboard.tosspayments.com/receipt/redirection?transactionId=synthetic" },
    }) === "https://dashboard.tosspayments.com/receipt/redirection?transactionId=synthetic",
    "a Toss https receipt is kept",
  );
  assert(extractTossReceiptUrl({ receipt: { url: "http://dashboard.tosspayments.com/receipt" } }) === null, "http is rejected");
  assert(extractTossReceiptUrl({ receipt: { url: "https://example.test/receipt" } }) === null, "another host is rejected");
});

Deno.test("receipt lookup queries Toss by payment key and does not echo the body", async () => {
  const seen: string[] = [];
  const result = await lookupTossReceiptByPaymentKey({
    paymentKey: "pay_column",
    authorization: "Basic test",
    fetchImpl: async (input) => {
      seen.push(String(input));
      return new Response(JSON.stringify({
        paymentKey: "pay_column",
        receipt: { url: "https://dashboard.tosspayments.com/receipt/redirection?transactionId=synthetic" },
        card: { number: "0000000000000000" },
      }), { status: 200 });
    },
  });

  assert(seen.length === 1, "lookup makes one GET");
  assert(seen[0].endsWith("/v1/payments/pay_column"), "lookup uses the payment key path");
  assert(
    result.receiptUrl === "https://dashboard.tosspayments.com/receipt/redirection?transactionId=synthetic",
    "the receipt URL comes from the live response",
  );
  assert(result.providerCalls === 1, "the lookup counts one provider call");
  assert(!JSON.stringify(result).includes("0000000000000000"), "the card number is not returned");
});

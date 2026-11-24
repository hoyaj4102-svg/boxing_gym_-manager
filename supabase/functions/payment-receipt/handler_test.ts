import { executeReceiptLookup } from "./handler.ts";
import { assessTossTestCall } from "../_shared/toss_test_guard.ts";

function assert(condition: unknown, message: string) {
  if (!condition) throw new Error(message);
}

Deno.test("receipt lookup does not call Toss unless test mode allows it", async () => {
  let calls = 0;
  const result = await executeReceiptLookup({
    guard: assessTossTestCall({ mode: undefined, secretKey: "test_sk_synthetic" }),
    paymentKey: "pay_column",
    authorization: "Basic test",
    fetchImpl: async () => {
      calls += 1;
      return new Response("{}", { status: 200 });
    },
  });
  assert(calls === 0, "default mode must not query Toss");
  assert(result.providerCalls === 0, "no provider call is counted");
  assert(result.receiptUrl === null, "no stored URL is invented");
});

Deno.test("test mode queries Toss with the supplied payment key", async () => {
  let path = "";
  const result = await executeReceiptLookup({
    guard: assessTossTestCall({ mode: "test", secretKey: "test_sk_synthetic" }),
    paymentKey: "pay_column",
    authorization: "Basic test",
    fetchImpl: async (input) => {
      path = String(input);
      return new Response(JSON.stringify({
        receipt: { url: "https://dashboard.tosspayments.com/receipt/live" },
      }), { status: 200 });
    },
  });
  assert(path.endsWith("/v1/payments/pay_column"), "the payment key is the lookup id");
  assert(result.receiptUrl === "https://dashboard.tosspayments.com/receipt/live", "the live URL is returned");
  assert(result.providerCalls === 1, "one provider call is counted");
});

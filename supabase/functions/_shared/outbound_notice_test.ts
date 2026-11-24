import { disabledOutboundNotice } from "./outbound_notice.ts";

function assert(condition: unknown, message: string) {
  if (!condition) throw new Error(message);
}

Deno.test("email and sms notices are disabled and make no provider call", () => {
  const notice = disabledOutboundNotice();
  assert(notice.inApp === true, "in-app notice stays available");
  assert(notice.email === "disabled", "email is disabled");
  assert(notice.sms === "disabled", "sms is disabled");
  assert(notice.providerCall === false, "the helper must not send");
});

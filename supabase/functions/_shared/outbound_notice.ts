export function disabledOutboundNotice() {
  return {
    inApp: true,
    email: "disabled" as const,
    sms: "disabled" as const,
    providerCall: false,
  };
}

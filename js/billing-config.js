// Billing / payments config (client-safe values only)
// Secret keys belong in Supabase Edge Function secrets — never here.
window.SWEAT_MANAGER_BILLING = {
  // Korea-first: Toss monthly auto-pay (Netflix-style billing key)
  provider: 'toss',
  tossClientKey: '',
  stripePublishableKey: '',
  checkoutEndpoint: 'https://vziegzjeysteemjxgbnc.supabase.co/functions/v1/create-checkout',
  startBillingAuthEndpoint: 'https://vziegzjeysteemjxgbnc.supabase.co/functions/v1/start-billing-auth',
  confirmBillingAuthEndpoint: 'https://vziegzjeysteemjxgbnc.supabase.co/functions/v1/confirm-billing-auth',
  confirmTossEndpoint: 'https://vziegzjeysteemjxgbnc.supabase.co/functions/v1/confirm-toss-payment',
  successUrl: 'https://boxing-gym-manager.vercel.app/?billing=success',
  failUrl: 'https://boxing-gym-manager.vercel.app/?billing=fail'
};

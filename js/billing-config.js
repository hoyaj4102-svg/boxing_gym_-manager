// Billing / payments config (client-safe values only)
// Secret keys belong in Supabase Edge Function secrets — never here.
window.SWEAT_MANAGER_BILLING = {
  // Korea-first: Toss only for now. Stripe stays in code for later.
  provider: 'toss',
  tossClientKey: '',
  stripePublishableKey: '',
  checkoutEndpoint: 'https://vziegzjeysteemjxgbnc.supabase.co/functions/v1/create-checkout',
  confirmTossEndpoint: 'https://vziegzjeysteemjxgbnc.supabase.co/functions/v1/confirm-toss-payment',
  successUrl: 'https://boxing-gym-manager.vercel.app/?billing=success',
  failUrl: 'https://boxing-gym-manager.vercel.app/?billing=fail'
};

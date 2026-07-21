// Billing / payments config (safe to expose client keys only)
// Real charge confirmation must happen in a webhook (service role).
window.SWEAT_MANAGER_BILLING = {
  provider: 'toss', // 'toss' | 'stripe' | 'manual'
  tossClientKey: '',
  stripePublishableKey: '',
  // Supabase Edge Function or Vercel API route that creates a checkout session
  checkoutEndpoint: '',
  successUrl: '',
  failUrl: ''
};

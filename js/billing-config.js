// Billing / payments config (client-safe values only)
// Secret keys belong in Supabase Edge Function secrets — never here.
window.SWEAT_MANAGER_BILLING = {
  // default provider when user doesn't choose: 'toss' | 'stripe'
  provider: 'toss',
  // Public keys (optional on client; Edge Function can also return toss clientKey)
  tossClientKey: '',
  stripePublishableKey: '',
  // Supabase Edge Functions
  checkoutEndpoint: 'https://vziegzjeysteemjxgbnc.supabase.co/functions/v1/create-checkout',
  confirmTossEndpoint: 'https://vziegzjeysteemjxgbnc.supabase.co/functions/v1/confirm-toss-payment',
  successUrl: 'https://boxing-gym-manager.vercel.app/?billing=success',
  failUrl: 'https://boxing-gym-manager.vercel.app/?billing=fail'
};

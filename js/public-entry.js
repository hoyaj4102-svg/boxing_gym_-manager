/**
 * Logged-out entry routing for the public landing vs the existing auth card.
 * The landing CTA is a plain /signup link. This file does not start billing.
 */
(function (root, factory) {
  const api = factory();
  if (typeof module !== 'undefined' && module.exports) {
    module.exports = api;
  }
  root.RememberPublicEntry = api;
})(typeof globalThis !== 'undefined' ? globalThis : this, function () {
  function searchParams(search) {
    const raw = String(search || '');
    return new URLSearchParams(raw.startsWith('?') ? raw.slice(1) : raw);
  }

  function initialAuthMode(loc) {
    const path = String(loc?.pathname || '/').toLowerCase();
    const params = searchParams(loc?.search);
    const authParam = (params.get('auth') || params.get('mode') || '').toLowerCase();

    if (path.endsWith('/signup') || authParam === 'signup' || params.has('signup')) {
      return 'signup';
    }

    if (path.endsWith('/reset-password')) {
      return 'recovery';
    }

    if (authParam === 'reset' || params.has('reset')) {
      return 'reset';
    }

    return 'login';
  }

  function isAuthScreenRoute(loc) {
    const path = String(loc?.pathname || '/')
      .toLowerCase()
      .replace(/\/+$/, '') || '/';

    if (
      path.endsWith('/login') ||
      path.endsWith('/signup') ||
      path.endsWith('/reset-password')
    ) {
      return true;
    }

    const params = searchParams(loc?.search);
    const authParam = (params.get('auth') || params.get('mode') || '').toLowerCase();
    if (
      authParam === 'signup' ||
      authParam === 'login' ||
      authParam === 'reset' ||
      authParam === 'recovery'
    ) {
      return true;
    }

    if (params.has('signup') || params.has('reset') || params.has('code')) {
      return true;
    }

    const hash = String(loc?.hash || '');
    if (/access_token|refresh_token|type=recovery/i.test(hash)) {
      return true;
    }

    return false;
  }

  function applyPublicEntryVisibility(doc, loc) {
    const authScreen = isAuthScreenRoute(loc);
    const landing = doc.getElementById('publicLanding');
    const gate = doc.getElementById('authGate');
    if (landing) landing.hidden = authScreen;
    if (gate) gate.hidden = !authScreen;
    return authScreen;
  }

  return {
    initialAuthMode,
    isAuthScreenRoute,
    applyPublicEntryVisibility
  };
});

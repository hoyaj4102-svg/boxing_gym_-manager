/**
 * re;member language choice.
 * Display preference only. Never use the result for authorization.
 *
 * Order:
 * 1. ?lang= in the supported list, applied immediately and saved.
 * 2. A saved localStorage choice.
 * 3. The signed-in user's user_metadata.locale, only when nothing is saved locally.
 * 4. utm_source=x when nothing is saved: English, then save.
 * 5. The browser language when nothing is saved: English if the preferred
 *    language is English. This is not saved, so an explicit choice still wins later.
 * 6. Otherwise Korean. Threads and every other source stay Korean unless the
 *    browser's preferred language is English.
 */
(function (global) {
  const SUPPORTED_LANGUAGES = ['ko', 'en', 'es', 'ru', 'mn', 'zh', 'hi', 'fr'];
  const LANGUAGE_KEY = 'boxing_gym_language';

  function isSupportedLanguage(language) {
    return SUPPORTED_LANGUAGES.includes(language);
  }

  function searchParams(search) {
    const query = String(search || '').replace(/^\?/, '');
    return new URLSearchParams(query);
  }

  function languageFromSearch(search) {
    const lang = searchParams(search).get('lang');
    if (!lang) return null;
    const normalized = lang.toLowerCase();
    return isSupportedLanguage(normalized) ? normalized : null;
  }

  function utmSourceIsX(search) {
    return (searchParams(search).get('utm_source') || '').toLowerCase() === 'x';
  }

  function accountLocale(user) {
    const locale = user && user.user_metadata ? user.user_metadata.locale : null;
    if (!locale) return null;
    const normalized = String(locale).toLowerCase();
    return isSupportedLanguage(normalized) ? normalized : null;
  }

  function browserLanguageTags(input) {
    if (input == null || input === '') return [];
    const parts = Array.isArray(input) ? input : String(input).split(',');
    const tags = [];
    for (const part of parts) {
      const tag = String(part || '').trim().split(';')[0].trim().toLowerCase();
      if (tag) tags.push(tag);
    }
    return tags;
  }

  // Only English is auto-selected from the browser. Other supported languages
  // still need ?lang=, a saved choice, or the language selector.
  function languageFromBrowser(input) {
    const tags = browserLanguageTags(input);
    if (!tags.length) return null;
    const primary = tags[0].split('-')[0];
    return primary === 'en' ? 'en' : null;
  }

  function resolveLanguage(options) {
    const settings = options || {};
    const search = settings.search || '';
    const stored = isSupportedLanguage(settings.stored) ? settings.stored : null;
    const account = isSupportedLanguage(settings.accountLocale) ? settings.accountLocale : null;
    const sessionKnown = settings.sessionKnown === true;
    const browser = languageFromBrowser(settings.browserLanguages);

    const queryLang = languageFromSearch(search);
    if (queryLang) {
      return { language: queryLang, persist: true, source: 'query' };
    }
    if (stored) {
      return { language: stored, persist: false, source: 'storage' };
    }
    if (sessionKnown && account) {
      return { language: account, persist: false, source: 'account' };
    }
    if (!sessionKnown) {
      return {
        language: utmSourceIsX(search) || browser === 'en' ? 'en' : 'ko',
        persist: false,
        source: 'pending'
      };
    }
    if (utmSourceIsX(search)) {
      return { language: 'en', persist: true, source: 'utm' };
    }
    if (browser === 'en') {
      return { language: 'en', persist: false, source: 'browser' };
    }
    return { language: 'ko', persist: false, source: 'default' };
  }

  function redirectUrl(origin, path, language) {
    const url = new URL(path, origin);
    if (isSupportedLanguage(language)) url.searchParams.set('lang', language);
    return url.toString();
  }

  function shouldAnnounceSignedOut(options) {
    const settings = options || {};
    if (settings.bootstrapping) return false;
    if (settings.pendingMessage) return true;
    return settings.event === 'SIGNED_OUT' && settings.hadSession === true;
  }

  function cleanAuthPath(path, search, storedLanguage) {
    const pathname = String(path || '/').split('?')[0].split('#')[0] || '/';
    const lang = languageFromSearch(search) || (isSupportedLanguage(storedLanguage) ? storedLanguage : null);
    return lang ? `${pathname}?lang=${encodeURIComponent(lang)}` : pathname;
  }

  global.RememberLanguage = {
    LANGUAGE_KEY,
    SUPPORTED_LANGUAGES,
    isSupportedLanguage,
    languageFromSearch,
    languageFromBrowser,
    utmSourceIsX,
    accountLocale,
    resolveLanguage,
    redirectUrl,
    cleanAuthPath,
    shouldAnnounceSignedOut
  };
})(typeof window !== 'undefined' ? window : globalThis);

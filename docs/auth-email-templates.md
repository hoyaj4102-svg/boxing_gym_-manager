# Auth email templates (local only)

These templates are for local GoTrue. They are not live in production.

Production custom SMTP is off, so the dashboard template editor cannot be changed. Every account, including Korean accounts, currently receives the default English mail:

- Confirm signup subject: `Confirm your email address`
- Reset password subject: `Reset your password`

Turning on custom SMTP needs a separate Founder approval. It is an external provider plus the Supabase Auth SMTP settings, not a change this repository can make. Reasonable providers are Resend, SendGrid, or Amazon SES, entered in the dashboard as custom SMTP. After that is approved and working, a person can paste the templates below. Do not run `supabase config push`. The `supabase/config.toml` entries only tell local `supabase start` which files to load.

## Redirect allow-list

No allow-list change is required for `?lang=` links.

- Site URL: `https://boxing-gym-manager.vercel.app`
- Already allowed: `https://boxing-gym-manager.vercel.app/**`
- Already allowed: `https://remember-gym.vercel.app/**`

Signup and password-reset redirects must use the page's current origin, which is one of those two hosts. A path plus `?lang=` is already covered by `/**`. Do not add a new redirect URL for language.

## When a template is chosen

`user_metadata.locale` comes from signup `options.data.locale`. The template branch is:

```
{{ if eq .Data.locale "en" }}
English
{{ else }}
Korean
{{ end }}
```

`en` renders English. A missing locale, an empty metadata map, and every other value, including `ko`, render Korean.

## Dashboard paste, after custom SMTP is enabled

Authentication, Confirm signup.

Subject:

```
{{ if eq .Data.locale "en" }}Confirm your email address{{ else }}이메일 주소를 확인해 주세요{{ end }}
```

Body: the full contents of `supabase/templates/confirmation.html`.

Authentication, Reset password.

Subject:

```
{{ if eq .Data.locale "en" }}Reset your password{{ else }}비밀번호를 다시 설정해 주세요{{ end }}
```

Body: the full contents of `supabase/templates/recovery.html`.

Leave the other auth templates on the defaults unless a later approval covers them. The link variable stays `{{ .ConfirmationURL }}`. That URL already carries the redirect the app sent, including `lang` when the app set one.

# Sweat Manager 수익화 / 토스 + Stripe 결제 연동

한국(토스) + 해외(Stripe) 이중 결제 세션 설계입니다.

## 플랜

| 플랜 | 가격 | 한도 |
|---|---|---|
| Free | 0 | 회원 20명 |
| Pro trial | 가입 후 14일 | 무제한 |
| Pro 월간 | ₩29,000 / $29 | 무제한 |
| Pro 연간 | ₩290,000 / $290 | 무제한 |

## 결제 흐름

### 토스 (한국)
1. 앱에서 **토스 월간/연간** 클릭
2. `create-checkout`가 `orderId` 생성 + `checkout_sessions` 저장
3. 브라우저 Toss 결제창 (`requestPayment`)
4. 성공 리다이렉트 → `confirm-toss-payment`가 시크릿 키로 승인
5. `activate_gym_pro()`로 Pro 활성화

### Stripe (해외)
1. 앱에서 **Stripe Monthly/Yearly** 클릭
2. `create-checkout`가 Stripe Checkout Session 생성
3. Stripe 호스팅 결제 페이지로 이동
4. `billing-webhook`이 `checkout.session.completed` 수신
5. `activate_gym_pro()`로 Pro 활성화

시크릿 키는 절대 프론트에 넣지 마세요.

---

## 1) SQL 실행 (Supabase SQL Editor)

순서대로 실행:

1. `supabase/schema.sql` (이미 했으면 생략)
2. `supabase/billing.sql` (이미 했으면 생략)
3. **`supabase/checkout_sessions.sql`** ← 이번 추가

Raw:
https://raw.githubusercontent.com/hoyaj4102-svg/boxing_gym_-manager/main/supabase/checkout_sessions.sql

---

## 2) Edge Function 시크릿 설정

Supabase Dashboard → **Edge Functions → Secrets** (또는 CLI):

```bash
# 공통
supabase secrets set APP_URL=https://boxing-gym-manager.vercel.app

# Toss
supabase secrets set TOSS_CLIENT_KEY=test_ck_...
supabase secrets set TOSS_SECRET_KEY=test_sk_...

# Stripe
supabase secrets set STRIPE_SECRET_KEY=sk_test_...
supabase secrets set STRIPE_WEBHOOK_SECRET=whsec_...
# 권장: Stripe Dashboard에서 만든 Price ID
supabase secrets set STRIPE_PRICE_MONTHLY=price_...
supabase secrets set STRIPE_PRICE_YEARLY=price_...
```

`SUPABASE_SERVICE_ROLE_KEY` / `SUPABASE_ANON_KEY` / `SUPABASE_URL` 은 보통 함수 런타임에 기본 주입됩니다.

---

## 3) Edge Function 배포

```bash
supabase functions deploy create-checkout
supabase functions deploy confirm-toss-payment
supabase functions deploy billing-webhook
```

배포 후 URL 예:

- `https://vziegzjeysteemjxgbnc.supabase.co/functions/v1/create-checkout`
- `https://vziegzjeysteemjxgbnc.supabase.co/functions/v1/confirm-toss-payment`
- `https://vziegzjeysteemjxgbnc.supabase.co/functions/v1/billing-webhook`

`js/billing-config.js`에 위 URL이 이미 들어가 있습니다.

---

## 4) Stripe Webhook 등록

Stripe Dashboard → Developers → Webhooks → Add endpoint

- URL: `https://vziegzjeysteemjxgbnc.supabase.co/functions/v1/billing-webhook?provider=stripe`
- Events:
  - `checkout.session.completed`
  - `invoice.paid`
  - `invoice.payment_failed`
  - `customer.subscription.deleted`
- Signing secret → `STRIPE_WEBHOOK_SECRET`

---

## 5) 토스 키 발급

1. [토스페이먼츠 개발자센터](https://developers.tosspayments.com/) 로그인
2. 클라이언트 키 / 시크릿 키 발급 (테스트 키로 시작)
3. 성공 URL에 `https://boxing-gym-manager.vercel.app` 허용

프론트의 `tossClientKey`는 비워도 됩니다. `create-checkout` 응답의 `clientKey`를 사용합니다.

---

## 6) Stripe Price 만들기 (권장)

1. Stripe → Products → `Sweat Manager Pro`
2. Monthly $29, Yearly $290 Price 생성
3. Price ID를 `STRIPE_PRICE_MONTHLY` / `STRIPE_PRICE_YEARLY`에 저장

Price ID가 없으면 함수가 `price_data`로 임시 구독을 만듭니다.

---

## 파일 구조

```text
supabase/
  billing.sql
  checkout_sessions.sql
  functions/
    create-checkout/index.ts
    confirm-toss-payment/index.ts
    billing-webhook/index.ts
    _shared/
js/
  billing-config.js
  billing.js
BILLING.md
```

---

## 보안 체크

- [x] 브라우저가 `plan_code` 직접 변경 불가
- [x] Toss는 서버 confirm 후에만 활성화
- [x] Stripe는 webhook 서명 검증 후 활성화
- [x] 회원 한도는 DB 트리거로 강제

---

## 테스트 체크리스트

1. SQL 3종 실행
2. Secrets 입력 + Functions 배포
3. 앱에서 **토스 월간** → 테스트 카드 결제 → Pro 활성화
4. 앱에서 **Stripe Monthly** → 테스트 카드 결제 → Webhook 후 Pro 활성화
5. Free 한도(20명) 차단 확인 (체험/구독 종료 상태)

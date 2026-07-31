# Sweat Manager 수익화 / 토스 월간 구독

토스 페이먼츠 **월간 자동결제**(넷플릭스 방식) + 앱 내 **구독 / 해지** UI입니다.

## 플랜

| 플랜 | 가격 | 한도 |
|---|---|---|
| Free | 0 | 회원 20명 |
| Pro trial | 가입 후 14일 | 무제한 |
| Pro 월간 | ₩29,000 / 월 자동결제 | 무제한 |

## UX

요금제 패널에는 버튼이 **두 개만** 있습니다.

1. **구독** → 토스 빌링키 발급(카드 등록) → 첫 달 결제 → 이후 매월 자동결제
2. **해지** → 구독 상태 / 이용 종료일 표시 → **해지하기**로 자동결제 중단

해지 후에도 `current_period_end`까지 Pro 이용이 유지되고, 다음 달부터 청구되지 않습니다.

## 결제 흐름 (토스 Billing)

1. 앱에서 **구독** 클릭
2. `start-billing-auth`가 `clientKey` + `customerKey` 반환
3. 브라우저 `requestBillingAuth` (카드 등록)
4. 성공 리다이렉트(`authKey`) → `confirm-billing-auth`
5. 서버가 빌링키 발급 + ₩29,000 첫 결제 + `activate_gym_pro(..., auto_renew=true)`
6. 매일/매시간 `charge-subscriptions`(CRON)이 기간 종료분 재청구

시크릿 키는 절대 프론트에 넣지 마세요.

---

## 1) SQL 실행 (Supabase SQL Editor)

순서대로:

1. `supabase/schema.sql` (이미 했으면 생략)
2. `supabase/billing.sql`
3. `supabase/checkout_sessions.sql`
4. `supabase/cancel_subscription.sql`
5. **`supabase/monthly_billing.sql`** ← 월간 자동결제 / 해지 필드

---

## 2) Edge Function 시크릿

```bash
supabase secrets set APP_URL=https://boxing-gym-manager.vercel.app
supabase secrets set TOSS_CLIENT_KEY=test_ck_...
supabase secrets set TOSS_SECRET_KEY=test_sk_...
supabase secrets set CRON_SECRET=긴랜덤문자열
```

---

## 3) Edge Function 배포

```bash
supabase functions deploy start-billing-auth
supabase functions deploy confirm-billing-auth
supabase functions deploy charge-subscriptions
supabase functions deploy create-checkout
supabase functions deploy confirm-toss-payment
supabase functions deploy billing-webhook
```

`js/billing-config.js`에 URL이 이미 들어가 있습니다.

### 월간 자동결제 스케줄

GitHub Actions 워크플로: `.github/workflows/charge-subscriptions.yml`

- 매일 00:10 KST 자동 실행
- Actions 탭에서 **Run workflow**로 수동 실행 가능
- GitHub Secret `CRON_SECRET` 값이 Supabase Edge Secret `CRON_SECRET`과 **같아야** 함

설정 위치: GitHub 저장소 → **Settings → Secrets and variables → Actions → New repository secret**
- Name: `CRON_SECRET`
- Value: Supabase에 넣은 것과 동일한 값


---

## 4) 토스 키 발급

1. [토스페이먼츠 개발자센터](https://developers.tosspayments.com/) 로그인
2. **자동결제(빌링)** 사용 가능한 클라이언트/시크릿 키
3. 성공 URL에 `https://boxing-gym-manager.vercel.app` 허용

---

## 구독 / 환불 정책

- 월간 자동결제
- 언제든 해지 가능
- 해지 후 현재 결제 기간 종료일까지 이용
- 다음 결제일부터 자동결제 중단
- 결제 후 7일 이내 환불 요청 가능 (정상 이용 시 제한될 수 있음)
- 기간 중 해지 시 남은 기간 부분 환불 없음
- 중복 결제/시스템 오류는 전액 환불

---

## 파일 구조

```text
supabase/
  billing.sql
  checkout_sessions.sql
  cancel_subscription.sql
  monthly_billing.sql
  functions/
    start-billing-auth/
    confirm-billing-auth/
    charge-subscriptions/
    create-checkout/
    confirm-toss-payment/
    billing-webhook/
js/
  billing-config.js
  billing.js
BILLING.md
```

---

## 테스트 체크리스트

1. SQL 5종 실행 (특히 `monthly_billing.sql`)
2. Secrets + Functions 배포
3. 앱에서 **구독** → 테스트 카드 등록 → Pro 활성화 + `auto_renew=true`
4. **해지** → 상태/날짜 확인 → 해지하기 → 기간 종료까지 Pro 유지, 자동결제 중단
5. Free 한도(20명) 차단 확인 (체험/구독 종료 상태)

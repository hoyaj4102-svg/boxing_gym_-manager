# re;member 수익화 / 토스 월간 구독

토스 페이먼츠 **월간 자동결제**(넷플릭스 방식) + 앱 내 **구독 / 해지** UI입니다.

## 플랜

| 플랜      | 가격                  | 한도      |
| --------- | --------------------- | --------- |
| Free      | 0                     | 회원 20명 |
| Pro trial | 가입 후 14일          | 무제한    |
| Pro 월간  | ₩10,000 / 월 자동결제 | 무제한    |

## UX

요금제 패널에는 버튼이 **두 개만** 있습니다.

1. **구독** → 토스 빌링키 발급(카드 등록) → 첫 달 결제 → 이후 매월 자동결제
2. **해지** → 구독 상태 / 이용 종료일 표시 → **해지하기**로 자동결제 중단

해지 후에도 `current_period_end`까지 Pro 이용이 유지되고, 다음 달부터 청구되지
않습니다.

## 결제 흐름 (토스 Billing)

1. 앱에서 **구독** 클릭
2. `start-billing-auth`가 `clientKey` + `customerKey` 반환
3. 브라우저 `requestBillingAuth` (카드 등록)
4. 성공 리다이렉트(`authKey`) → `confirm-billing-auth`
5. 서버가 빌링키 발급 + ₩10,000 첫 결제 +
   `activate_gym_pro(..., auto_renew=true)`
6. 승인된 운영 재개 이후에만 `charge-subscriptions`가 기간 종료분을 재청구합니다. 현재 스케줄은 꺼져 있습니다.

시크릿 키는 절대 프론트에 넣지 마세요.

---

## 1) SQL 실행 (Supabase SQL Editor)

순서대로:

1. `supabase/schema.sql` (이미 했으면 생략)
2. `supabase/billing.sql`
3. `supabase/checkout_sessions.sql`
4. `supabase/cancel_subscription.sql`
5. **`supabase/monthly_billing.sql`** ← 월간 자동결제 / 해지 필드
6. **`supabase/payment_attempts.sql`** ← 결제 성공 후 Pro 활성화 실패 복구 기록

---

## 2) Edge Function 시크릿

```bash
supabase secrets set APP_URL=https://boxing-gym-manager.vercel.app
supabase secrets set TOSS_CLIENT_KEY=test_ck_...
supabase secrets set TOSS_SECRET_KEY=test_sk_...
supabase secrets set TOSS_MID=tosspayments_가맹점MID
supabase secrets set CRON_SECRET=긴랜덤문자열
```

`TOSS_MID`는 Toss 결제 조회 응답의 `mId`와 정확히 일치해야 합니다. 이미 같은
값을 `TOSS_MERCHANT_ID`로 관리 중이면 그 이름을 대신 사용할 수 있습니다. 운영
확인 시에는 시크릿 값을 출력하지 말고 Supabase/Toss 대시보드에서 존재 여부와
환경(테스트/라이브) 일치 여부만 확인하세요.

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

- 운영 스케줄은 꺼 둔 상태입니다. 이 파일을 배포해도 매일 자동 실행되지 않습니다.
- Actions 탭의 **Run workflow**는 dry-run만 실행합니다. 결제 제공자를 호출하지 않습니다.
- 운영 스케줄을 다시 켜거나 실제 청구를 재개하려면 별도의 승인이 필요합니다.
- dry-run은 저장소 시크릿 없이 동작합니다. 실제 청구 설정은 운영 재개 승인 이후에만 확인합니다.

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
  payment_attempts.sql
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

---

## 결제 준비 초안 (운영 적용 전)

`supabase/p1_17_billing_consent.sql`은 생산 데이터베이스에 적용하지 않습니다.
별도 승인이 있기 전에는 SQL Editor에서 실행하지 마세요.

이 파일은 결제 전 동의, 무료 체험의 유료 전환 동의, 요금 인상 동의를 기록합니다.
사업자 정보와 약관 페이지는 자리표시자와 법률 검토 전 초안입니다.
`js/business-identity.js`의 대괄호 값을 실제 상호, 사업자등록번호, 대표자, 주소,
전화, 통신판매업 신고번호, 이메일로 바꾸지 마세요. 그 값은 대표가 확인한 뒤에
따로 넣습니다.

카드 등록 버튼은 가격, 월 결제 주기, 자동갱신, 첫 결제 시점, 다음 결제 예정일,
해지 방법을 보여 주고 확인란에 동의하기 전에는 토스 카드 등록을 열지 않습니다.
동의 저장이 실패하면 카드 등록으로 진행하지 않습니다.

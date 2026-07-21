# Sweat Manager 수익화 / 구독 설계

이 문서는 **구독 테이블 + 회원 수 제한 + 결제 연동** 구조를 설명합니다.

## 한 줄 요약

| 구분 | 내용 |
|---|---|
| Free | 회원 **20명** |
| Pro trial | 가입 후 **14일** 무제한 |
| Pro | 월 **29,000원** / 연 **290,000원**, 회원 무제한 |
| 제한 위치 | 앱 UI + DB 트리거(우회 불가) |
| 결제 확정 | **웹훅(서버)** 만 gym plan 변경 |

브라우저가 직접 `plan_code`를 `pro`로 바꾸면 안 됩니다.  
결제 성공 웹훅(service role)만 `gyms` / `subscriptions` 를 갱신합니다.

---

## 파일 구조

```text
supabase/
  schema.sql          # 기본 SaaS 스키마
  billing.sql         # 구독/제한 (이번 추가) ← SQL Editor에서 실행
js/
  billing-config.js   # Toss/Stripe 키, checkout endpoint
  billing.js          # 플랜 헬퍼 + checkout 시작
  supabase-service.js # 회원 등록 시 한도 체크
index.html            # 요금제 패널 UI
BILLING.md            # 이 문서
```

---

## DB 설계

### `gyms`에 추가되는 컬럼

- `plan_code`: `free` | `pro`
- `member_limit`: Free 기본 `20`, Pro는 로직상 `-1`(무제한)
- `subscription_status`: `trialing` | `active` | `past_due` | `canceled` | `expired`
- `trial_ends_at`: 체험 종료 시각
- `current_period_end`: 유료 기간 종료
- `billing_provider`: `toss` | `stripe`
- `billing_customer_id`, `billing_subscription_id`

### `subscriptions` 테이블

결제/체험 이력(감사 로그). 앱은 **조회만**, 쓰기는 웹훅.

### RPC

- `get_billing_summary()` → 현재 플랜, 회원 수, 추가 가능 여부
- `gym_effective_member_limit(gym_id)`
- `members` INSERT 전 트리거로 `MEMBER_LIMIT_REACHED` 차단

### 체험 규칙

신규 회원가입 시:

1. `plan_code = pro`
2. `subscription_status = trialing`
3. `trial_ends_at = now() + 14 days`
4. 체험 중에는 회원 수 무제한
5. 체험 종료 후 결제 없으면 Free(20명)로 동작  
   (기존 회원은 유지, **추가 등록만 차단**)

---

## 앱 동작

1. 로그인 후 `get_billing_summary()` 호출
2. 헤더/데이터 관리에 요금제 상태 표시
3. Free 한도 도달 시 회원 등록 버튼 막고 Upgrade CTA
4. Upgrade 클릭 → `billing.js` `startCheckout()`
   - `checkoutEndpoint` 있으면 서버로 세션 생성 후 결제창 이동
   - 없으면 “결제 연동 전” 안내 (수동 모드)

---

## 결제 연동 순서 (추천: 토스페이먼츠)

### 1) SQL 적용

Supabase SQL Editor에서 `supabase/billing.sql` 실행.

### 2) Edge Function (또는 Vercel API)

예: `create-checkout`

1. Authorization Bearer(사용자 JWT) 검증
2. `gym_id` 확인
3. Toss/Stripe에서 결제 세션 생성
4. `{ checkoutUrl }` 반환

예: `billing-webhook`

1. 결제 성공 이벤트 수신
2. service role로:

```sql
update gyms
set plan_code = 'pro',
    subscription_status = 'active',
    member_limit = -1,
    current_period_end = ...,
    billing_provider = 'toss',
    billing_subscription_id = ...
where id = ...;

insert into subscriptions (...);
```

### 3) 프론트 설정

`js/billing-config.js`:

```js
window.SWEAT_MANAGER_BILLING = {
  provider: 'toss',
  tossClientKey: 'test_ck_...',
  checkoutEndpoint: 'https://<project>.functions.supabase.co/create-checkout',
  successUrl: 'https://boxing-gym-manager.vercel.app/?billing=success',
  failUrl: 'https://boxing-gym-manager.vercel.app/?billing=fail'
};
```

### Stripe를 쓸 때

- `provider: 'stripe'`
- Checkout Session + Customer Portal
- Webhook: `checkout.session.completed`, `customer.subscription.updated/deleted`

---

## 가격(초기 제안)

| 플랜 | 가격 | 한도 |
|---|---|---|
| Free | 0 | 회원 20명 |
| Pro 월간 | 29,000원 | 무제한 |
| Pro 연간 | 290,000원 (2개월 할인) | 무제한 |

가격은 `js/billing.js`의 `PLANS`에서 수정합니다.

---

## 보안 체크리스트

- [ ] 브라우저에서 `gyms.plan_code` 직접 update 금지 (RLS 유지)
- [ ] 웹훅 서명 검증 (Toss/Stripe)
- [ ] service_role 키는 Edge Function 시크릿에만
- [ ] 회원 한도는 DB 트리거로 강제

---

## 지금 바로 할 일

1. `supabase/billing.sql` 실행
2. 앱 새로고침 → 요금제 패널 확인
3. Free 한도 테스트(체험 종료 후 또는 status를 free로 수동 테스트)
4. 결제 준비되면 Edge Function + `billing-config.js` 채우기

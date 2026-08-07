# re;member

**체육관을 위한 가장 간단하고 저렴한 CRM**

웹 기반 체육관 회원·재등록·출석 관리 SaaS입니다.

- Frontend: 정적 HTML/CSS/JS (PWA)
- Backend: Supabase Auth + Postgres + RLS
- Payments: Toss 월간 자동결제

## 브랜드

- 이름: `re;member`
- 슬로건: 체육관을 위한 가장 간단하고 저렴한 CRM
- 포인트 컬러: `#2B5CFF` (세미콜론 블루) / 네이비 `#0A1628`

## 빠른 시작

1. Supabase 프로젝트 생성
2. `supabase/schema.sql` 실행
3. `supabase/billing.sql` 실행 (요금제/회원 한도)
4. `supabase/checkout_sessions.sql` / `cancel_subscription.sql` / `monthly_billing.sql` 실행
5. Edge Functions 배포 + Toss 시크릿 설정 ([BILLING.md](./BILLING.md))
6. `js/config.js`에 Project URL / anon key 입력
7. 앱 접속 → 회원가입 → 회원 관리

수익화/결제 연동은 [BILLING.md](./BILLING.md) 를 보세요.  
자세한 단계는 [SUPABASE_SETUP.md](./SUPABASE_SETUP.md) 를 보세요.

## 주요 기능

- 이메일 회원가입 / 로그인 / 로그아웃 / 비밀번호 재설정
- 체육관(gym)별 회원 데이터 완전 분리 (RLS)
- 회원 등록·수정·삭제
- 출석 기록 및 PT 차감
- 만기 예정 / 만기 지난 / 장기 미방문 / 메모
- CSV 내보내기, JSON 복원, 기존 localStorage 1회 마이그레이션
- Pro 월간 구독 / 해지 (토스 자동결제)

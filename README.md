# 복싱장 재등록 운영 관리 (Sweat Manager)

체육관 단위로 회원·출석·재등록을 관리하는 SaaS 앱입니다.

- Frontend: 정적 HTML/CSS/JS (기존 UI 유지)
- Backend: Supabase Auth + Postgres + RLS

## 빠른 시작

1. Supabase 프로젝트 생성
2. `supabase/schema.sql` 실행
3. `js/config.js`에 Project URL / anon key 입력
4. 앱 접속 → 회원가입 → 회원 관리

자세한 단계는 [SUPABASE_SETUP.md](./SUPABASE_SETUP.md) 를 보세요.

## 주요 기능

- 이메일 회원가입 / 로그인 / 로그아웃 / 비밀번호 재설정
- 체육관(gym)별 회원 데이터 완전 분리 (RLS)
- 회원 등록·수정·삭제
- 출석 기록 및 PT 차감
- 만기 예정 / 만기 지난 / 장기 미방문 / 메모
- JSON 백업·복원, 기존 localStorage 1회 마이그레이션

# Sweat Manager — Supabase SaaS 전환 가이드

복싱장 회원관리 앱을 **체육관(계정) 단위 멀티테넌트 SaaS**로 운영하기 위한 설정 문서입니다.

- 인증: Supabase Auth (이메일 회원가입 / 로그인 / 로그아웃 / 비밀번호 재설정)
- 저장소: Supabase Database (`gyms`, `profiles`, `members`, `attendance`)
- 보안: Row Level Security(RLS)로 **자기 gym_id 데이터만** 조회·등록·수정·삭제

---

## 추천 파일 구조

```text
/
├── index.html                 # UI (기존 디자인 유지) + 화면 로직
├── js/
│   ├── config.js              # Supabase URL / anon key (여기만 수정)
│   └── supabase-service.js    # Auth + DB API (gym 격리)
├── supabase/
│   └── schema.sql             # CREATE TABLE / Index / Trigger / RLS / RPC
├── SUPABASE_SETUP.md          # 이 문서
├── README.md
├── sw.js                      # PWA service worker
├── manifest.json
└── vercel.json
```

초보자 기준: **먼저 `schema.sql` 실행 → `js/config.js`에 키 입력 → 앱 접속** 순서만 지키면 됩니다.

---

## 실행 순서 (처음부터)

### 1) Supabase 프로젝트 만들기

1. [https://supabase.com](https://supabase.com) 접속 후 새 프로젝트 생성
2. 프로젝트 생성이 끝날 때까지 대기 (DB 준비)

### 2) Email Auth 설정

1. Supabase Dashboard → **Authentication → Providers → Email** 활성화
2. 개발 중 바로 로그인하려면 **Confirm email** 을 끄세요  
   - 켜 두면 회원가입 후 메일 확인 전까지 로그인이 안 됩니다.
3. 비밀번호 재설정을 쓰려면 **Authentication → URL Configuration** 에서  
   Site URL / Redirect URLs 에 앱 주소(예: `https://your-app.vercel.app`)를 추가하세요.

### 3) DB 스키마 + RLS 실행

1. Dashboard → **SQL Editor → New query**
2. 저장소의 `supabase/schema.sql` 전체 내용을 붙여넣고 **Run**
3. 성공하면 아래가 생성됩니다.
   - 테이블: `gyms`, `profiles`, `members`, `attendance`
   - 헬퍼: `current_gym_id()`
   - 회원가입 트리거: `handle_new_user` (auth.users 생성 시 gym + profile 자동 생성)
   - 출석 RPC: `record_attendance(member_id, attendance_date)`
   - 각 테이블 RLS 정책 (gym_id 격리)

### 4) 앱에 URL / anon key 넣기

1. Dashboard → **Project Settings → API**
2. 아래 값을 복사
   - Project URL
   - `anon` `public` key
3. `js/config.js` 수정:

```js
window.SWEAT_MANAGER_SUPABASE = {
  url: 'https://YOUR_PROJECT_ID.supabase.co',
  anonKey: 'YOUR_SUPABASE_ANON_KEY'
};
```

> `service_role` 키는 절대 프론트엔드에 넣지 마세요. 데이터 보호는 RLS가 담당합니다.

### 5) 로컬에서 확인 (선택)

정적 파일이므로 아무 HTTP 서버로 열면 됩니다.

```bash
npx serve .
# 또는
python3 -m http.server 5173
```

브라우저에서 앱을 열고:

1. **회원가입** (체육관 이름 / 대표자 / 연락처 / 이메일 / 비밀번호)
2. **로그인**
3. 회원 등록 → 출석 → 수정/삭제 확인

### 6) 배포 (Vercel 등)

1. `js/config.js`가 포함된 상태로 배포
2. Supabase Auth Redirect URL에 배포 도메인 추가
3. 배포 URL에서 회원가입/로그인 재확인

---

## 데이터 분리 방식 (중요)

1. 회원가입 시 `auth.users` 트리거가 `gyms` 1개 + `profiles` 1개를 만듭니다.
2. `profiles.gym_id` 가 그 체육관의 소유 범위입니다.
3. RLS 정책은 모든 쿼리에서 `gym_id = current_gym_id()` 를 강제합니다.
4. 따라서 A 체육관 계정은 B 체육관 `members` / `attendance` 를 절대 읽을 수 없습니다.

---

## 기존 localStorage 데이터 옮기기

1. 예전 브라우저에서 쓰던 데이터는 아직 그 브라우저 `localStorage`에 남아 있을 수 있습니다.
2. Supabase 로그인 후 앱의 **데이터 관리 → 로컬 데이터 업로드** 버튼을 누르세요.
3. 업로드 후부터는 Supabase 데이터가 기준입니다.

JSON 백업/복원도 유지됩니다. 복원 시 현재 체육관의 Supabase 회원/출석 데이터가 교체됩니다.

---

## 기능 체크리스트

- [x] 이메일 회원가입
- [x] 이메일 로그인
- [x] 로그아웃
- [x] 비밀번호 재설정 메일
- [x] 회원 등록/수정/삭제 → Supabase
- [x] 출석 + PT 차감 → `attendance` + RPC
- [x] 만기/만기예정/만기지난/장기미방문/메모 UI 유지
- [x] gym 단위 RLS 격리

---

## 문제 해결

| 증상 | 확인 |
|---|---|
| "Supabase 설정이 필요합니다" | `js/config.js`의 url/anonKey |
| 회원가입 후 로그인 안 됨 | Auth Confirm email 옵션, 트리거 실행 여부 |
| 프로필이 없습니다 | `schema.sql`의 `handle_new_user` 트리거 재실행 |
| 다른 체육관 데이터가 보임 | RLS 정책이 적용됐는지 SQL Editor에서 재확인 (정상 설계에선 불가) |
| 출석/저장 실패 | 브라우저 콘솔 에러 + Supabase Logs |

추가 문의 전에 SQL Editor에서 `supabase/schema.sql`을 한 번 더 실행해 스키마가 최신인지 확인하세요.

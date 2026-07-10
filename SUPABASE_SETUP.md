# Supabase 설정 및 localStorage 마이그레이션 가이드

이 앱은 Supabase Auth 이메일 로그인과 Postgres 저장소를 지원합니다. 로그인한 사용자는 Row Level Security(RLS)에 의해 자신의 회원 데이터만 조회, 추가, 수정, 삭제할 수 있습니다.

## 1. Supabase 프로젝트 만들기

1. Supabase에서 새 프로젝트를 생성합니다.
2. `Authentication > Providers > Email`을 활성화합니다.
3. 이메일 확인을 사용하지 않고 바로 로그인하게 하려면 `Authentication > Providers > Email > Confirm email` 옵션을 끕니다.
   - 이메일 확인을 켜두면 회원가입 후 메일 확인을 완료해야 로그인됩니다.

## 2. DB 스키마와 RLS 적용

1. Supabase Dashboard에서 `SQL Editor`를 엽니다.
2. 이 저장소의 `supabase.sql` 전체 내용을 실행합니다.
3. 실행 후 `public.members` 테이블에 RLS가 켜져 있고, 다음 정책이 생성되었는지 확인합니다.
   - Users can view their own members
   - Users can insert their own members
   - Users can update their own members
   - Users can delete their own members

## 3. 앱에 Supabase URL/anon key 입력

`Project Settings > API`에서 아래 값을 확인합니다.

- Project URL
- Project API keys > anon public

그 값을 `supabase-config.js`에 입력합니다.

```js
window.SWEAT_MANAGER_SUPABASE = {
  url: 'https://YOUR_PROJECT_ID.supabase.co',
  anonKey: 'YOUR_SUPABASE_ANON_KEY'
};
```

`anonKey`는 클라이언트에 공개되는 키입니다. 데이터 보호는 `supabase.sql`의 RLS 정책이 담당하므로 service_role key는 절대 프론트엔드에 넣지 마세요.

## 4. 배포

`supabase-config.js` 변경사항까지 배포되어야 로그인/DB 저장이 동작합니다.

Vercel 배포라면 변경사항을 `main`에 반영하면 자동 배포됩니다.

## 5. 기존 localStorage 데이터 마이그레이션

기존 브라우저에 저장된 회원 데이터가 있는 경우:

1. 앱에 접속합니다.
2. Supabase 설정이 완료된 상태에서 이메일로 로그인합니다.
3. 로그인 패널의 `현재 브라우저 로컬 데이터 업로드` 버튼을 누릅니다.
4. 현재 브라우저의 localStorage 데이터가 로그인한 사용자 계정의 Supabase `members` 테이블로 upsert됩니다.

주의:

- 여러 기기의 localStorage 데이터는 자동 합쳐지지 않습니다. 각 기기에서 로그인 후 업로드해야 합니다.
- 같은 회원 `id`가 있으면 Supabase에서 업데이트됩니다.
- 마이그레이션 후에는 로그인한 계정의 Supabase 데이터가 기준입니다.

## 6. JSON 백업/복원

JSON 백업/복원 기능은 유지됩니다.

- 로그인 상태에서 JSON 복원 시 Supabase 데이터도 함께 교체됩니다.
- 로그아웃 또는 Supabase 미설정 상태에서는 기존처럼 현재 브라우저 localStorage 기준으로 동작합니다.

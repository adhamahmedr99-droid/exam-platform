-- Exam platform - Supabase schema (run in the Supabase SQL editor once)
-- Teacher = Supabase Auth user. Students/parents use one-time codes via secure RPCs only.

create table if not exists exams (
  id uuid primary key default gen_random_uuid(),
  teacher_id uuid not null references auth.users(id) on delete cascade,
  title text not null,
  subject text default '',
  grade text default '',
  description text default '',
  duration_min int not null default 15,
  pass_pct int not null default 50,
  shuffle_q boolean not null default true,
  shuffle_c boolean not null default true,
  show_result boolean not null default true,
  start_at timestamptz,
  end_at timestamptz,
  published boolean not null default false,
  created_at timestamptz not null default now()
);

create table if not exists questions (
  id uuid primary key default gen_random_uuid(),
  exam_id uuid not null references exams(id) on delete cascade,
  ord int not null default 0,
  text text not null,
  type text not null check (type in ('mcq','tf','sa','essay')),
  choices jsonb,            -- ["a","b",...] for mcq/tf
  correct int,              -- index into choices for mcq/tf
  accepted jsonb,           -- ["ans1","ans2"] for sa
  points numeric not null default 1
);
create index if not exists questions_exam_idx on questions(exam_id);

create table if not exists students (
  id uuid primary key default gen_random_uuid(),
  teacher_id uuid not null references auth.users(id) on delete cascade,
  name text not null,
  parent_phone text default '',
  created_at timestamptz not null default now()
);

create table if not exists codes (
  id uuid primary key default gen_random_uuid(),
  exam_id uuid not null references exams(id) on delete cascade,
  student_id uuid references students(id) on delete set null,
  student_name text not null,
  token text not null unique,
  status text not null default 'unused' check (status in ('unused','in_progress','completed')),
  created_at timestamptz not null default now()
);
create index if not exists codes_exam_idx on codes(exam_id);

create table if not exists exam_sessions (
  id uuid primary key default gen_random_uuid(),
  code_id uuid not null unique references codes(id) on delete cascade,
  started_at timestamptz not null default now(),
  last_seen timestamptz not null default now(),
  status text not null default 'open' check (status in ('open','submitted'))
);

create table if not exists answers (
  session_id uuid not null references exam_sessions(id) on delete cascade,
  question_id uuid not null references questions(id) on delete cascade,
  answer jsonb,
  saved_at timestamptz not null default now(),
  primary key (session_id, question_id)
);

create table if not exists submissions (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null unique references exam_sessions(id) on delete cascade,
  auto_score numeric not null,
  auto_total numeric not null,
  correct_count int not null,
  n_auto int not null,
  bitmap text not null default '',
  time_sec int not null default 0,
  auto boolean not null default false,
  submitted_at timestamptz not null default now()
);

create table if not exists essay_grades (
  submission_id uuid not null references submissions(id) on delete cascade,
  question_id uuid not null references questions(id) on delete cascade,
  awarded numeric not null,
  primary key (submission_id, question_id)
);

-- RLS: teacher owns their rows; anonymous students never touch tables directly.
alter table exams enable row level security;
alter table questions enable row level security;
alter table students enable row level security;
alter table codes enable row level security;
alter table exam_sessions enable row level security;
alter table answers enable row level security;
alter table submissions enable row level security;
alter table essay_grades enable row level security;

create policy exams_teacher on exams for all using (auth.uid() = teacher_id) with check (auth.uid() = teacher_id);
create policy questions_teacher on questions for all
  using (exists (select 1 from exams e where e.id = questions.exam_id and e.teacher_id = auth.uid()))
  with check (exists (select 1 from exams e where e.id = questions.exam_id and e.teacher_id = auth.uid()));
create policy students_teacher on students for all using (auth.uid() = teacher_id) with check (auth.uid() = teacher_id);
create policy codes_teacher on codes for all
  using (exists (select 1 from exams e where e.id = codes.exam_id and e.teacher_id = auth.uid()))
  with check (exists (select 1 from exams e where e.id = codes.exam_id and e.teacher_id = auth.uid()));
create policy sessions_teacher on exam_sessions for select
  using (exists (select 1 from codes c join exams e on e.id = c.exam_id where c.id = exam_sessions.code_id and e.teacher_id = auth.uid()));
create policy answers_teacher on answers for select
  using (exists (select 1 from exam_sessions s join codes c on c.id = s.code_id join exams e on e.id = c.exam_id
                 where s.id = answers.session_id and e.teacher_id = auth.uid()));
create policy submissions_teacher on submissions for select
  using (exists (select 1 from exam_sessions s join codes c on c.id = s.code_id join exams e on e.id = c.exam_id
                 where s.id = submissions.session_id and e.teacher_id = auth.uid()));
create policy grades_teacher on essay_grades for all
  using (exists (select 1 from submissions sub join exam_sessions s on s.id = sub.session_id
                 join codes c on c.id = s.code_id join exams e on e.id = c.exam_id
                 where sub.id = essay_grades.submission_id and e.teacher_id = auth.uid()))
  with check (exists (select 1 from submissions sub join exam_sessions s on s.id = sub.session_id
                 join codes c on c.id = s.code_id join exams e on e.id = c.exam_id
                 where sub.id = essay_grades.submission_id and e.teacher_id = auth.uid()));

-- Arabic normalization for short-answer matching
create or replace function norm_ar(t text) returns text language sql immutable as $$
  select lower(trim(regexp_replace(
    translate(coalesce(t,''), 'أإآىة', 'ااايه'),
    '[ً-ْٰـ]', '', 'g')))
$$;

-- Student entry point: validate a one-time code, return the exam payload, open a session.
create or replace function redeem_code(p_token text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  c codes; e exams; s exam_sessions; qs jsonb;
begin
  select * into c from codes where token = p_token;
  if not found then return jsonb_build_object('ok', false, 'error', 'invalid_code'); end if;
  select * into e from exams where id = c.exam_id;
  if not e.published then return jsonb_build_object('ok', false, 'error', 'not_published'); end if;
  if e.start_at is not null and now() < e.start_at then
    return jsonb_build_object('ok', false, 'error', 'not_yet', 'start_at', e.start_at); end if;
  if e.end_at is not null and now() > e.end_at then
    return jsonb_build_object('ok', false, 'error', 'expired'); end if;
  if c.status = 'completed' then
    return jsonb_build_object('ok', false, 'error', 'already_completed'); end if;

  if c.status = 'in_progress' then
    -- resume an existing open session (answer autosave restores)
    select * into s from exam_sessions where code_id = c.id and status = 'open';
  end if;
  if s.id is null then
    insert into exam_sessions (code_id) values (c.id) returning * into s;
    update codes set status = 'in_progress' where id = c.id;
  end if;

  -- questions WITHOUT answers leak: strip correct/accepted from the payload
  select jsonb_agg(jsonb_build_object(
    'id', q.id, 'ord', q.ord, 'text', q.text, 'type', q.type,
    'choices', q.choices, 'points', q.points) order by q.ord)
  into qs from questions q where q.exam_id = e.id;

  return jsonb_build_object(
    'ok', true, 'session_id', s.id, 'student', c.student_name,
    'exam', jsonb_build_object(
      'id', e.id, 'title', e.title, 'subject', e.subject, 'grade', e.grade,
      'duration_min', e.duration_min, 'pass_pct', e.pass_pct,
      'shuffle_q', e.shuffle_q, 'shuffle_c', e.shuffle_c, 'show_result', e.show_result,
      'started_at', s.started_at),
    'questions', coalesce(qs, '[]'::jsonb),
    'saved', (select coalesce(jsonb_object_agg(question_id, answer), '{}'::jsonb) from answers where session_id = s.id)
  );
end $$;

-- Autosave one answer (session must be open)
create or replace function save_answer(p_session uuid, p_question uuid, p_answer jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from exam_sessions where id = p_session and status = 'open') then
    return jsonb_build_object('ok', false, 'error', 'closed');
  end if;
  insert into answers (session_id, question_id, answer) values (p_session, p_question, p_answer)
  on conflict (session_id, question_id) do update set answer = excluded.answer, saved_at = now();
  update exam_sessions set last_seen = now() where id = p_session;
  return jsonb_build_object('ok', true);
end $$;

-- Submit: server-side grading of objective questions, one-time enforcement.
create or replace function submit_exam(p_session uuid, p_time_sec int, p_auto boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  s exam_sessions; c codes; e exams;
  rec record; v_score numeric := 0; v_total numeric := 0; v_cc int := 0; v_n int := 0;
  v_bitmap text := ''; sub submissions;
begin
  select * into s from exam_sessions where id = p_session;
  if not found then return jsonb_build_object('ok', false, 'error', 'no_session'); end if;
  if s.status = 'submitted' then return jsonb_build_object('ok', false, 'error', 'already_submitted'); end if;

  update exam_sessions set status = 'submitted' where id = s.id and status = 'open';
  if not found then return jsonb_build_object('ok', false, 'error', 'already_submitted'); end if;

  select * into c from codes where id = s.code_id;
  select * into e from exams where id = c.exam_id;

  for rec in
    select q.*, a.answer from questions q
    left join answers a on a.question_id = q.id and a.session_id = s.id
    where q.exam_id = e.id order by q.ord
  loop
    if rec.type = 'essay' then continue; end if;
    v_n := v_n + 1; v_total := v_total + rec.points;
    if rec.answer is null then v_bitmap := v_bitmap || '0'; continue; end if;
    if (rec.type in ('mcq','tf') and (rec.answer)::text = to_jsonb(rec.correct)::text)
       or (rec.type = 'sa' and exists (
             select 1 from jsonb_array_elements_text(coalesce(rec.accepted,'[]'::jsonb)) x
             where norm_ar(x) = norm_ar(rec.answer #>> '{}'))) then
      v_score := v_score + rec.points; v_cc := v_cc + 1; v_bitmap := v_bitmap || '1';
    else
      v_bitmap := v_bitmap || '0';
    end if;
  end loop;

  insert into submissions (session_id, auto_score, auto_total, correct_count, n_auto, bitmap, time_sec, auto)
  values (s.id, v_score, v_total, v_cc, v_n, v_bitmap, greatest(0, coalesce(p_time_sec,0)), coalesce(p_auto,false))
  returning * into sub;
  update codes set status = 'completed' where id = c.id;

  return jsonb_build_object(
    'ok', true,
    'show', e.show_result,
    'score', v_score, 'total', v_total +
      coalesce((select sum(points) from questions where exam_id = e.id and type = 'essay'), 0),
    'correct', v_cc, 'n_auto', v_n,
    'essay_pending', exists (select 1 from questions where exam_id = e.id and type = 'essay')
  );
end $$;

-- Teacher dashboard helper: one row per code with live status
create or replace function exam_code_status(p_exam uuid)
returns table(token text, student_name text, status text, started_at timestamptz, submitted_at timestamptz)
language sql security definer set search_path = public as $$
  select c.token, c.student_name, c.status, s.started_at, sub.submitted_at
  from codes c
  left join exam_sessions s on s.code_id = c.id
  left join submissions sub on sub.session_id = s.id
  where c.exam_id = p_exam
    and exists (select 1 from exams e where e.id = p_exam and e.teacher_id = auth.uid())
  order by c.created_at;
$$;

-- Teacher profile (display name + WhatsApp number shown to students/parents)
create table if not exists profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text default '',
  phone text default '',
  default_pass_pct int default 50,
  default_duration int default 15
);
alter table profiles enable row level security;
create policy profiles_owner on profiles for all using (auth.uid() = id) with check (auth.uid() = id);

-- API access for the signed-in teacher role (RLS policies still apply per row)
grant usage on schema public to anon, authenticated;
grant select, insert, update, delete on exams, questions, students, codes, exam_sessions, answers, submissions, essay_grades, profiles to authenticated;
-- Migration: open-link exam sharing (share without a one-time code)
-- Safe to run more than once. Existing exams keep open_enabled = false.

alter table exams add column if not exists open_enabled boolean not null default false;
alter table exams add column if not exists open_token text;
create unique index if not exists exams_open_token_key on exams(open_token) where open_token is not null;
alter table codes add column if not exists via text not null default 'code';
alter table codes add column if not exists parent_phone text not null default '';

-- Teacher code/attempt list now also returns how each attempt entered
drop function if exists exam_code_status(uuid);
create function exam_code_status(p_exam uuid)
returns table(token text, student_name text, status text, started_at timestamptz, submitted_at timestamptz, via text)
language sql security definer set search_path = public as $$
  select c.token, c.student_name, c.status, s.started_at, sub.submitted_at, c.via
  from codes c
  left join exam_sessions s on s.code_id = c.id
  left join submissions sub on sub.session_id = s.id
  where c.exam_id = p_exam
    and exists (select 1 from exams e where e.id = p_exam and e.teacher_id = auth.uid())
  order by c.created_at;
$$;

-- Open link: public exam info for the landing page (no answers)
create or replace function open_info(p_token text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare e exams;
begin
  select * into e from exams where open_token = p_token;
  if not found then return jsonb_build_object('ok', false, 'error', 'invalid_link'); end if;
  if not e.open_enabled then return jsonb_build_object('ok', false, 'error', 'link_off'); end if;
  if not e.published then return jsonb_build_object('ok', false, 'error', 'not_published'); end if;
  if e.start_at is not null and now() < e.start_at then
    return jsonb_build_object('ok', false, 'error', 'not_yet', 'start_at', e.start_at); end if;
  if e.end_at is not null and now() > e.end_at then
    return jsonb_build_object('ok', false, 'error', 'expired'); end if;
  return jsonb_build_object('ok', true, 'title', e.title, 'subject', e.subject,
    'grade', e.grade, 'duration_min', e.duration_min);
end $$;

-- Open link: register a name and start an attempt. Each start is its own
-- attempt (its own codes row with via='open'), then grading/autosave/tracking
-- work exactly like one-time codes.
create or replace function open_session(p_token text, p_name text, p_phone text default '')
returns jsonb language plpgsql security definer set search_path = public as $$
declare e exams; c codes; s exam_sessions; qs jsonb;
begin
  select * into e from exams where open_token = p_token;
  if not found then return jsonb_build_object('ok', false, 'error', 'invalid_link'); end if;
  if not e.open_enabled then return jsonb_build_object('ok', false, 'error', 'link_off'); end if;
  if not e.published then return jsonb_build_object('ok', false, 'error', 'not_published'); end if;
  if e.start_at is not null and now() < e.start_at then
    return jsonb_build_object('ok', false, 'error', 'not_yet', 'start_at', e.start_at); end if;
  if e.end_at is not null and now() > e.end_at then
    return jsonb_build_object('ok', false, 'error', 'expired'); end if;
  if length(trim(coalesce(p_name, ''))) = 0 then
    return jsonb_build_object('ok', false, 'error', 'name_required'); end if;

  insert into codes (exam_id, student_name, token, via, parent_phone)
  values (e.id, left(trim(p_name), 120),
          'O' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 11)),
          'open', left(trim(coalesce(p_phone, '')), 40))
  returning * into c;
  insert into exam_sessions (code_id) values (c.id) returning * into s;
  update codes set status = 'in_progress' where id = c.id;

  -- questions WITHOUT answers leak: strip correct/accepted from the payload
  select jsonb_agg(jsonb_build_object(
    'id', q.id, 'ord', q.ord, 'text', q.text, 'type', q.type,
    'choices', q.choices, 'points', q.points) order by q.ord)
  into qs from questions q where q.exam_id = e.id;

  return jsonb_build_object(
    'ok', true, 'session_id', s.id, 'student', c.student_name,
    'exam', jsonb_build_object(
      'id', e.id, 'title', e.title, 'subject', e.subject, 'grade', e.grade,
      'duration_min', e.duration_min, 'pass_pct', e.pass_pct,
      'shuffle_q', e.shuffle_q, 'shuffle_c', e.shuffle_c, 'show_result', e.show_result,
      'started_at', s.started_at),
    'questions', coalesce(qs, '[]'::jsonb),
    'saved', '{}'::jsonb
  );
end $$;


-- Migration: video lessons with manual subscriptions (teacher-activated, paid off-platform)
-- Safe to run more than once.
create extension if not exists pgcrypto;

create table if not exists videos (
  id uuid primary key default gen_random_uuid(),
  teacher_id uuid not null references auth.users(id) on delete cascade,
  title text not null,
  url text not null,
  ord int not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default now()
);
alter table videos enable row level security;
create policy videos_teacher on videos for all using (auth.uid() = teacher_id) with check (auth.uid() = teacher_id);

create table if not exists video_students (
  id uuid primary key default gen_random_uuid(),
  teacher_id uuid not null references auth.users(id) on delete cascade,
  name text not null default '',
  username text not null unique,
  pass_hash text not null,
  active boolean not null default true,
  created_at timestamptz not null default now()
);
alter table video_students enable row level security;
create policy video_students_teacher on video_students for all using (auth.uid() = teacher_id) with check (auth.uid() = teacher_id);

-- Teacher creates a subscriber (password hashed server-side; username globally unique)
create or replace function create_video_student(p_name text, p_username text, p_password text)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return jsonb_build_object('ok', false, 'error', 'auth'); end if;
  p_username := lower(trim(coalesce(p_username, '')));
  if length(p_username) < 3 or p_username !~ '^[a-z0-9_.]+$' then
    return jsonb_build_object('ok', false, 'error', 'bad_username'); end if;
  if length(coalesce(p_password, '')) < 4 then
    return jsonb_build_object('ok', false, 'error', 'bad_password'); end if;
  if exists (select 1 from video_students where username = p_username) then
    return jsonb_build_object('ok', false, 'error', 'taken'); end if;
  insert into video_students (teacher_id, name, username, pass_hash)
  values (auth.uid(), left(trim(coalesce(p_name, '')), 120), p_username, extensions.crypt(p_password, extensions.gen_salt('bf')));
  return jsonb_build_object('ok', true);
end $$;

-- Teacher resets a subscriber's password
create or replace function reset_video_student_password(p_student uuid, p_password text)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if length(coalesce(p_password, '')) < 4 then
    return jsonb_build_object('ok', false, 'error', 'bad_password'); end if;
  update video_students set pass_hash = extensions.crypt(p_password, extensions.gen_salt('bf'))
  where id = p_student and teacher_id = auth.uid();
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  return jsonb_build_object('ok', true);
end $$;

-- Student side: verify credentials, return this student's teacher videos (no table access)
create or replace function video_login(p_username text, p_password text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare st video_students; vs jsonb;
begin
  select * into st from video_students where username = lower(trim(coalesce(p_username, '')));
  if not found or st.pass_hash <> extensions.crypt(coalesce(p_password, ''), st.pass_hash) then
    return jsonb_build_object('ok', false, 'error', 'invalid'); end if;
  if not st.active then return jsonb_build_object('ok', false, 'error', 'inactive'); end if;
  select jsonb_agg(jsonb_build_object('id', v.id, 'title', v.title, 'url', v.url) order by v.ord, v.created_at)
  into vs from videos v where v.teacher_id = st.teacher_id and v.active;
  return jsonb_build_object('ok', true, 'name', st.name, 'videos', coalesce(vs, '[]'::jsonb));
end $$;

grant select, insert, update, delete on videos, video_students to authenticated;

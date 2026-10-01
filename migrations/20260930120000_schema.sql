-- O JayV no Supabase. Cada usuário vê só as próprias linhas (RLS por
-- `user_id`); traduções e instruções do Jev são de todos e só `admins` escreve.
--
-- As tabelas do usuário espelham o SQLite de cada máquina (`local/outbox.rs`,
-- `TABLES`): TEXT vira `text` e INTEGER vira `bigint`, sem conversão. As três
-- colunas de sincronia são as únicas `timestamptz`:
--   row_updated_at  o instante da escrita na máquina; decide quem ganha
--   row_deleted_at  exclusão — ninguém apaga linha aqui
--   synced_at       o relógio do servidor; é o cursor do download

create table public.projects (
  id text primary key,
  name text not null,
  created_at text not null
);

create table public.chats (
  id text primary key,
  code text not null default '',
  project_id text not null references public.projects(id) on delete cascade,
  title text not null,
  named bigint not null default 0,
  created_at text not null,
  updated_at text not null
);

create table public.turns (
  id text primary key,
  chat_id text not null references public.chats(id) on delete cascade,
  ordinal bigint not null,
  status text not null,
  created_at text not null,
  unique (chat_id, ordinal)
);

create table public.messages (
  uid text primary key,
  chat_id text not null references public.chats(id) on delete cascade,
  turn_id text,
  role text not null,
  content text not null,
  created_at text not null
);

create table public.entry_checks (
  turn_id text primary key references public.turns(id) on delete cascade,
  at text not null,
  prompt text not null,
  score bigint not null,
  demand bigint not null,
  verdict text not null,
  scope text not null,
  criteria text not null,
  source text not null,
  note text not null
);

create table public.exit_checks (
  id text primary key,
  turn_id text not null references public.turns(id) on delete cascade,
  at text not null,
  kind text not null,
  target text not null,
  rule text,
  verdict text not null
);

create table public.turn_events (
  id text primary key,
  turn_id text not null references public.turns(id) on delete cascade,
  at text not null,
  seq bigint not null,
  kind text not null,
  detail text not null
);

create table public.questions (
  turn_id text primary key references public.turns(id) on delete cascade,
  at text not null,
  kind text not null,
  prompt text not null,
  options text not null,
  source text not null,
  status text not null,
  answered_by text references public.turns(id) on delete set null,
  settled_at text
);

create table public.llm_agents (
  user_id uuid not null default auth.uid() references auth.users on delete cascade,
  id text not null,
  enabled bigint not null default 1,
  command text not null,
  timeout bigint not null,
  options text not null default '{}',
  updated_at text not null,
  primary key (user_id, id)
);

create table public.llm_models (
  user_id uuid not null default auth.uid() references auth.users on delete cascade,
  agent text not null,
  model text not null,
  enabled bigint not null default 1,
  capabilities text not null default '[]',
  cost_class text not null,
  speed text not null,
  context_window bigint not null,
  position bigint not null default 0,
  primary key (user_id, agent, model),
  foreign key (user_id, agent) references public.llm_agents(user_id, id) on delete cascade
);

-- Uma escrita que chega atrasada — feita antes da que já está gravada — é
-- descartada: devolver `old` deixa a linha como estava, `synced_at` inclusive,
-- e as outras máquinas não baixam nada de novo.
create function public.sync_row() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'UPDATE' and new.row_updated_at < old.row_updated_at then
    return old;
  end if;
  new.synced_at := clock_timestamp();
  return new;
end
$$;

do $$
declare
  name text;
begin
  foreach name in array array['projects','chats','turns','messages','entry_checks','exit_checks','turn_events','questions','llm_agents','llm_models'] loop
    if name not in ('llm_agents','llm_models') then
      execute format('alter table public.%I add column user_id uuid not null default auth.uid() references auth.users on delete cascade', name);
    end if;
    execute format('alter table public.%I
      add column row_updated_at timestamptz not null default now(),
      add column row_deleted_at timestamptz,
      add column synced_at timestamptz not null default clock_timestamp()', name);
    execute format('create index %I on public.%I (user_id, synced_at)', name || '_user_synced', name);
    execute format('create trigger sync_row before insert or update on public.%I for each row execute function public.sync_row()', name);
    execute format('alter table public.%I enable row level security', name);
    execute format('create policy "dono lê" on public.%I for select to authenticated using (user_id = (select auth.uid()))', name);
    execute format('create policy "dono escreve" on public.%I for insert to authenticated with check (user_id = (select auth.uid()))', name);
    execute format('create policy "dono muda" on public.%I for update to authenticated using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()))', name);
    execute format('revoke delete, truncate on public.%I from anon, authenticated', name);
    execute format('revoke all on public.%I from anon', name);
  end loop;
end
$$;

-- O código curto do chat é único entre os chats vivos do usuário: um chat
-- apagado não segura o código para sempre.
create unique index chats_user_code on public.chats (user_id, code) where row_deleted_at is null and code <> '';

-- Conteúdo global.

create table public.admins (
  user_id uuid primary key references auth.users on delete cascade
);
alter table public.admins enable row level security;
revoke all on public.admins from anon, authenticated;

create function public.is_admin() returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.admins where user_id = (select auth.uid()))
$$;
revoke execute on function public.is_admin() from public;
grant execute on function public.is_admin() to anon, authenticated;

create table public.locales (
  id text primary key,
  name text not null,
  rtl boolean not null default false,
  position int not null default 0
);

create table public.translations (
  locale text not null references public.locales(id) on delete cascade,
  key text not null,
  -- Texto, ou as formas de plural como objeto.
  value jsonb not null,
  primary key (locale, key)
);

create table public.jev_questions (
  question_set text not null check (question_set in ('entry', 'routing', 'verification', 'asking')),
  id text not null,
  -- A pergunta no formato que a TypeSafe recebe.
  body jsonb not null,
  position int not null default 0,
  primary key (question_set, id)
);

create table public.jev_parameters (
  key text primary key,
  value jsonb not null
);

do $$
declare
  name text;
begin
  foreach name in array array['locales','translations','jev_questions','jev_parameters'] loop
    execute format('alter table public.%I enable row level security', name);
    execute format('create policy "admin escreve" on public.%I for insert to authenticated with check ((select public.is_admin()))', name);
    execute format('create policy "admin muda" on public.%I for update to authenticated using ((select public.is_admin())) with check ((select public.is_admin()))', name);
    execute format('create policy "admin apaga" on public.%I for delete to authenticated using ((select public.is_admin()))', name);
  end loop;
end
$$;

-- A tela de login já fala a língua do usuário: idiomas e traduções são
-- públicos. As instruções do Jev, não.
create policy "todos leem" on public.locales for select to anon, authenticated using (true);
create policy "todos leem" on public.translations for select to anon, authenticated using (true);
create policy "sessão lê" on public.jev_questions for select to authenticated using (true);
create policy "sessão lê" on public.jev_parameters for select to authenticated using (true);
revoke all on public.jev_questions, public.jev_parameters from anon;
revoke insert, update, delete, truncate on public.locales, public.translations from anon;

-- O limite diário da função `jev`. Só a função conta, por
-- `jev_take_call`; ninguém lê nem escreve a tabela diretamente.
create table public.jev_usage (
  user_id uuid not null references auth.users on delete cascade,
  day date not null,
  calls int not null default 0,
  primary key (user_id, day)
);
alter table public.jev_usage enable row level security;
revoke all on public.jev_usage from anon, authenticated;

-- Conta a chamada e diz se ela ainda cabe no dia. Roda com o JWT do usuário,
-- então a função `jev` não precisa da service role.
create function public.jev_take_call(daily_limit int) returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  used int;
begin
  if (select auth.uid()) is null then
    raise exception 'sem sessão' using errcode = '28000';
  end if;
  insert into public.jev_usage (user_id, day, calls)
  values ((select auth.uid()), (now() at time zone 'utc')::date, 1)
  on conflict (user_id, day) do update set calls = public.jev_usage.calls + 1
  returning calls into used;
  return used <= daily_limit;
end
$$;
revoke execute on function public.jev_take_call(int) from public, anon;
grant execute on function public.jev_take_call(int) to authenticated;

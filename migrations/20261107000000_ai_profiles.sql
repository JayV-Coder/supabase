-- Ticket #45: perfis de IA por Organização (ADR-0018). `ai_profile` é a escolha; `llm_provider`
-- (ADR-0007) passa a ser derivado dele e continua sendo o que os workers usam para montar o
-- provedor. O `dedicated` usa Provisioned Throughput no Vertex, no projeto da plataforma ou do
-- cliente (`ai_project`), e só a operação da plataforma o liga.

alter table doctor.tenants drop constraint tenants_llm_provider_check;
alter table doctor.tenants add constraint tenants_llm_provider_check
  check (llm_provider in ('anthropic', 'vertex', 'vertex_dedicated'));
alter table doctor.tenants add column ai_profile text not null default 'standard'
  check (ai_profile in ('standard', 'br_region', 'dedicated'));
-- Projeto do GCP com a capacidade dedicada; nulo é o projeto da plataforma.
alter table doctor.tenants add column ai_project text
  check (ai_project ~ '^[a-z][a-z0-9-]{4,28}[a-z0-9]$');
update doctor.tenants set ai_profile = 'br_region' where llm_provider = 'vertex';
alter table doctor.tenants add constraint tenants_ai_profile_provider_check check (
  (ai_profile = 'standard' and llm_provider = 'anthropic')
  or (ai_profile = 'br_region' and llm_provider = 'vertex')
  or (ai_profile = 'dedicated' and llm_provider = 'vertex_dedicated')
);
alter table doctor.tenants add constraint tenants_ai_project_dedicated_check
  check (ai_profile = 'dedicated' or ai_project is null);

-- Quem cria a Organização ainda escolhe o provedor (`create_organization`): o perfil sai dele.
-- Mudar o perfil muda o provedor junto, e mudar só o provedor (como no ADR-0007) muda o perfil;
-- provedor desconhecido continua barrado pela restrição. O mapa perfil → provedor é este e o
-- `PROFILES` do registro dos provedores.
create function doctor.sync_ai_profile()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' and new.ai_profile = 'standard' and new.llm_provider = 'vertex' then
    new.ai_profile := 'br_region';
  elsif tg_op = 'UPDATE' and new.ai_profile is not distinct from old.ai_profile
      and new.llm_provider is distinct from old.llm_provider then
    new.ai_profile := case new.llm_provider
      when 'anthropic' then 'standard' when 'vertex' then 'br_region'
      when 'vertex_dedicated' then 'dedicated' else new.ai_profile end;
  elsif tg_op = 'INSERT' or new.ai_profile is distinct from old.ai_profile then
    new.llm_provider := case new.ai_profile
      when 'standard' then case when tg_op = 'UPDATE' or new.llm_provider like 'vertex%'
        then 'anthropic' else new.llm_provider end
      when 'br_region' then 'vertex' else 'vertex_dedicated' end;
  end if;
  if new.ai_profile <> 'dedicated' then
    new.ai_project := null;
  end if;
  return new;
end;
$$;
create trigger tenants_sync_ai_profile
before insert or update of ai_profile, llm_provider, ai_project on doctor.tenants
for each row execute function doctor.sync_ai_profile();

-- A troca de perfil tem o registro próprio (`org.ai_profile_changed`): a auditoria genérica da
-- Organização não a repete.
drop trigger tenants_audit on doctor.tenants;
create trigger tenants_audit after update on doctor.tenants
for each row execute function doctor.audit_change('org', 'auto_diagnose_critical',
  'deletion_requested_at', 'deletion_requested_by', 'deletion_scheduled_for',
  'ai_profile', 'llm_provider', 'ai_project');

-- O Owner com MFA troca entre o padrão e o Brasil (o DPA e os subprocessadores mudam junto).
create function doctor.set_ai_profile(profile text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  tenant uuid := doctor.current_tenant_id();
  role text := doctor.require_manager();
  previous text;
begin
  if role <> 'owner' then
    raise insufficient_privilege using message = 'exige o Owner com MFA';
  end if;
  if profile not in ('standard', 'br_region') then
    raise exception 'o perfil dedicado é contratado com a plataforma' using errcode = 'DR090';
  end if;
  select t.ai_profile into previous from doctor.tenants t where t.id = tenant for update;
  if previous = profile then
    return;
  end if;
  update doctor.tenants t set ai_profile = profile where t.id = tenant;
  perform doctor.write_audit(tenant, 'org.ai_profile_changed', 'org', tenant::text,
    jsonb_build_object('ai_profile', previous), jsonb_build_object('ai_profile', profile));
end;
$$;

-- Capacidade dedicada contratada: só a operação da plataforma liga (com o projeto, se for o do
-- cliente).
create function doctor.set_dedicated_ai(tenant uuid, project text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  previous text;
begin
  select t.ai_profile into previous from doctor.tenants t where t.id = tenant for update;
  if previous is null then
    raise no_data_found using message = 'Organização não encontrada';
  end if;
  update doctor.tenants t set ai_profile = 'dedicated', ai_project = project where t.id = tenant;
  perform doctor.write_audit(tenant, 'org.ai_profile_changed', 'org', tenant::text,
    jsonb_build_object('ai_profile', previous),
    jsonb_build_object('ai_profile', 'dedicated', 'ai_project', project));
end;
$$;

-- Verificação diária de cada perfil em uso: os hosts e a região que a chamada de teste
-- realmente usou. Tabela da plataforma (o projeto dedicado é do perfil, não de uma Organização).
create table doctor.ai_profile_checks (
  id bigint generated always as identity primary key,
  profile text not null check (profile in ('standard', 'br_region', 'dedicated')),
  -- Projeto do GCP do dedicado, ou 'platform'.
  target text not null default 'platform' check (char_length(target) <= 64),
  checked_at timestamptz not null default now(),
  ok boolean not null,
  -- Todos os hosts no lugar do perfil. Falha da chamada (cota, 429 do dedicado) com hosts no
  -- Brasil é `ok = false` e `in_region = true`: indisponibilidade, não violação de região.
  in_region boolean not null default true,
  hosts text[] not null default '{}',
  region text check (char_length(region) <= 64),
  detail text check (char_length(detail) <= 500)
);
comment on table doctor.ai_profile_checks is 'Verificação diária do endpoint e da região efetivos de cada perfil de IA (ADR-0018).';
create index ai_profile_checks_latest_idx on doctor.ai_profile_checks (profile, target, checked_at desc);
alter table doctor.ai_profile_checks enable row level security;
revoke all on doctor.ai_profile_checks from anon, authenticated;

-- A última verificação do perfil desta Organização, para a tela de privacidade.
create function doctor.ai_profile_status()
returns table (profile text, checked_at timestamptz, ok boolean, in_region boolean, hosts text[], region text, detail text)
language sql
stable
security definer
set search_path = ''
as $$
  select t.ai_profile, c.checked_at, c.ok, c.in_region, c.hosts, c.region, c.detail
  from doctor.tenants t
  left join lateral (
    select * from doctor.ai_profile_checks c
    where c.profile = t.ai_profile and c.target = coalesce(t.ai_project, 'platform')
    order by c.checked_at desc limit 1
  ) c on true
  where t.id = doctor.current_tenant_id()
$$;

revoke all on function doctor.sync_ai_profile() from public, anon, authenticated;
revoke all on function doctor.set_ai_profile(text) from public, anon, service_role;
revoke all on function doctor.set_dedicated_ai(uuid, text) from public, anon, authenticated;
revoke all on function doctor.ai_profile_status() from public, anon, service_role;
grant execute on function doctor.set_ai_profile(text) to authenticated;
grant execute on function doctor.set_dedicated_ai(uuid, text) to service_role;
grant execute on function doctor.ai_profile_status() to authenticated;
grant select, insert on doctor.ai_profile_checks to service_role;

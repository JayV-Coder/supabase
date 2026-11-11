-- Ticket #32: Relatório técnico (PDF e Markdown) de um Incidente e do seu Diagnóstico atual, e o
-- link compartilhável de 7 dias, revogável e auditado (ADR-0014).

create table doctor.reports (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references doctor.tenants (id) on delete cascade,
  incident_id uuid not null,
  -- O Diagnóstico atual que já terminou, fixado no pedido; sem Diagnóstico, o relatório diz isso.
  diagnosis_id uuid,
  format text not null check (format in ('pdf', 'md')),
  include_timeline boolean not null default false,
  include_event_excerpts boolean not null default false,
  status text not null default 'queued' check (status in ('queued', 'running', 'ready', 'failed')),
  storage_path text check (char_length(storage_path) <= 300),
  size_bytes bigint check (size_bytes >= 0),
  -- Hash do conteúdo, o mesmo que sai no rodapé.
  content_sha256 text check (content_sha256 ~ '^[0-9a-f]{64}$'),
  error text check (char_length(error) <= 500),
  attempts integer not null default 0 check (attempts >= 0),
  processing_key text not null check (char_length(processing_key) between 1 and 200),
  requested_by uuid references auth.users (id) on delete set null,
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, processing_key),
  foreign key (tenant_id, incident_id) references doctor.incidents (tenant_id, id) on delete cascade,
  foreign key (tenant_id, diagnosis_id) references doctor.diagnoses (tenant_id, id)
    on delete set null (diagnosis_id),
  check (status <> 'ready' or (storage_path is not null and content_sha256 is not null))
);
comment on table doctor.reports is 'Relatório técnico gerado (arquivo no bucket doctor-reports).';
create index reports_incident_idx on doctor.reports (tenant_id, incident_id, created_at desc);
create index reports_diagnosis_idx on doctor.reports (tenant_id, diagnosis_id) where diagnosis_id is not null;

create trigger reports_set_updated_at
before update on doctor.reports
for each row execute function doctor.set_updated_at();

create table doctor.report_shares (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references doctor.tenants (id) on delete cascade,
  report_id uuid not null,
  -- sha256 do token, que só existe no link; o token em si não fica no banco.
  token_hash text not null unique check (token_hash ~ '^[0-9a-f]{64}$'),
  -- URL assinada do Storage (7 dias), que só a função de abertura lê: a API faz o proxy do
  -- arquivo e a URL nunca chega a quem tem o link, então revogar corta o acesso na hora.
  download_url text not null check (char_length(download_url) <= 2000),
  expires_at timestamptz not null,
  revoked_at timestamptz,
  revoked_by uuid references auth.users (id) on delete set null,
  access_count integer not null default 0 check (access_count >= 0),
  last_accessed_at timestamptz,
  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, id),
  foreign key (tenant_id, report_id) references doctor.reports (tenant_id, id) on delete cascade,
  check (expires_at <= created_at + interval '7 days')
);
comment on table doctor.report_shares is 'Link compartilhável de um Relatório técnico (7 dias, revogável).';
create index report_shares_report_idx on doctor.report_shares (tenant_id, report_id);

create trigger report_shares_set_updated_at
before update on doctor.report_shares
for each row execute function doctor.set_updated_at();

alter table doctor.reports enable row level security;
alter table doctor.report_shares enable row level security;
revoke all on doctor.reports, doctor.report_shares from anon, authenticated;
grant select on doctor.reports to authenticated;
-- Sem o hash do token nem a URL assinada.
grant select (id, tenant_id, report_id, expires_at, revoked_at, revoked_by, access_count,
  last_accessed_at, created_by, created_at) on doctor.report_shares to authenticated;

-- Todo Papel lê os relatórios da Organização ativa; os links, quem compartilha.
create policy reports_select on doctor.reports
for select to authenticated
using (tenant_id = (select doctor.current_tenant_id()));

create policy report_shares_select on doctor.report_shares
for select to authenticated
using (
  tenant_id = (select doctor.current_tenant_id())
  and (select doctor.has_member_role('owner', 'admin', 'analyst'))
);

-- Pedido: Analyst ou acima, idempotente pela chave; o worker de diagnóstico gera o arquivo.
create function doctor.request_report(
  incident uuid, format text, include_timeline boolean, include_event_excerpts boolean,
  processing_key text
)
returns table (id uuid, status text, created boolean)
language plpgsql
security definer
set search_path = ''
as $$
declare
  tenant uuid := doctor.current_tenant_id();
  current doctor.reports;
  diagnosis uuid;
begin
  if not doctor.has_member_role('owner', 'admin', 'analyst') then
    raise insufficient_privilege using message = 'exige Analyst ou acima';
  end if;
  if format not in ('pdf', 'md') then
    raise exception 'formato inválido' using errcode = '22023';
  end if;
  perform 1 from doctor.incidents i where i.tenant_id = tenant and i.id = incident;
  if not found then
    raise no_data_found using message = 'Incidente não encontrado';
  end if;
  select * into current from doctor.reports r
  where r.tenant_id = tenant and r.processing_key = request_report.processing_key;
  if current.id is not null then
    if current.incident_id <> incident then
      raise exception 'chave de idempotência já usada' using errcode = '23505';
    end if;
    return query select current.id, current.status, false;
    return;
  end if;
  select d.id into diagnosis from doctor.diagnoses d
  where d.tenant_id = tenant and d.incident_id = incident
    and d.status in ('published', 'inconclusive', 'failed_llm')
  order by d.version desc limit 1;
  insert into doctor.reports (tenant_id, incident_id, diagnosis_id, format, include_timeline,
    include_event_excerpts, processing_key, requested_by)
  values (tenant, incident, diagnosis, request_report.format, request_report.include_timeline,
    request_report.include_event_excerpts, request_report.processing_key, auth.uid())
  returning * into current;
  insert into doctor.outbox_messages (tenant_id, topic, payload)
  values (tenant, 'report.requested', jsonb_build_object('report_id', current.id));
  perform doctor.record_audit(tenant, 'report.requested', current.id::text);
  return query select current.id, current.status, true;
end;
$$;

-- Compartilhar: a API gera o token (só o hash chega aqui) e a URL assinada com o JWT de quem
-- compartilha, válida pelos mesmos 7 dias.
create function doctor.create_report_share(report uuid, token_hash text, download_url text)
returns table (id uuid, expires_at timestamptz)
language plpgsql
security definer
set search_path = ''
as $$
declare
  tenant uuid := doctor.current_tenant_id();
  ready boolean;
  share doctor.report_shares;
begin
  if not doctor.has_member_role('owner', 'admin', 'analyst') then
    raise insufficient_privilege using message = 'exige Analyst ou acima';
  end if;
  select r.status = 'ready' into ready from doctor.reports r where r.tenant_id = tenant and r.id = report;
  if ready is null then
    raise no_data_found using message = 'Relatório não encontrado';
  end if;
  if not ready then
    raise exception 'Relatório ainda não está pronto' using errcode = 'DR060';
  end if;
  insert into doctor.report_shares (tenant_id, report_id, token_hash, download_url, expires_at, created_by)
  values (tenant, report, create_report_share.token_hash, create_report_share.download_url,
    now() + interval '7 days', auth.uid())
  returning * into share;
  perform doctor.write_audit(tenant, 'report.shared', 'report', report::text, null,
    jsonb_build_object('share_id', share.id, 'expires_at', share.expires_at));
  return query select share.id, share.expires_at;
end;
$$;

create function doctor.revoke_report_share(share uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  tenant uuid := doctor.current_tenant_id();
  report uuid;
begin
  if not doctor.has_member_role('owner', 'admin', 'analyst') then
    raise insufficient_privilege using message = 'exige Analyst ou acima';
  end if;
  update doctor.report_shares s set revoked_at = coalesce(s.revoked_at, now()),
    revoked_by = coalesce(s.revoked_by, auth.uid())
  where s.tenant_id = tenant and s.id = share
  returning s.report_id into report;
  if report is null then
    raise no_data_found using message = 'Link não encontrado';
  end if;
  perform doctor.write_audit(tenant, 'report.share_revoked', 'report', report::text, null,
    jsonb_build_object('share_id', share));
end;
$$;

-- O link vale enquanto estiver ativo, o relatório pronto, a Organização ativa (nem suspensa
-- nem com exclusão marcada) e quem compartilhou ainda for Analyst ou acima nela.
create function doctor.active_report_share(token_hash text)
returns doctor.report_shares
language sql
stable
security definer
set search_path = ''
as $$
  select s.* from doctor.report_shares s
  join doctor.reports r on r.tenant_id = s.tenant_id and r.id = s.report_id and r.status = 'ready'
  join doctor.tenants t on t.id = s.tenant_id
    and t.status = 'active' and t.deletion_scheduled_for is null
  join doctor.memberships m on m.tenant_id = s.tenant_id and m.user_id = s.created_by
    and m.role in ('owner', 'admin', 'analyst')
  where s.token_hash = active_report_share.token_hash
    and s.revoked_at is null and s.expires_at > now()
$$;

-- Abertura pelo link, sem sessão: devolve a URL guardada, sem efeito. A API busca o arquivo e só
-- então registra o acesso (`record_report_share_access`).
create function doctor.open_report_share(token_hash text)
returns table (download_url text, format text, filename text)
language sql
stable
security definer
set search_path = ''
as $$
  select s.download_url, r.format,
    'inc-' || lpad(coalesce(i.number, 0)::text, 4, '0') || '.' || r.format
  from doctor.active_report_share(open_report_share.token_hash) s
  join doctor.reports r on r.tenant_id = s.tenant_id and r.id = s.report_id
  join doctor.incidents i on i.tenant_id = r.tenant_id and i.id = r.incident_id
  where s.id is not null
$$;

-- Arquivo entregue: conta o acesso e grava `report.share_accessed` na trilha da Organização dona.
create function doctor.record_report_share_access(token_hash text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  share doctor.report_shares := doctor.active_report_share(token_hash);
begin
  if share.id is null then
    return;
  end if;
  update doctor.report_shares s set access_count = s.access_count + 1, last_accessed_at = now()
  where s.id = share.id;
  perform doctor.write_audit(share.tenant_id, 'report.share_accessed', 'report',
    share.report_id::text, null, jsonb_build_object('share_id', share.id));
end;
$$;

revoke all on function doctor.request_report(uuid, text, boolean, boolean, text) from public, anon, service_role;
revoke all on function doctor.create_report_share(uuid, text, text) from public, anon, service_role;
revoke all on function doctor.revoke_report_share(uuid) from public, anon, service_role;
revoke all on function doctor.active_report_share(text) from public, anon, authenticated, service_role;
revoke all on function doctor.open_report_share(text) from public, service_role;
revoke all on function doctor.record_report_share_access(text) from public, service_role;
grant execute on function doctor.request_report(uuid, text, boolean, boolean, text) to authenticated;
grant execute on function doctor.create_report_share(uuid, text, text) to authenticated;
grant execute on function doctor.revoke_report_share(uuid) to authenticated;
grant execute on function doctor.open_report_share(text) to anon, authenticated;
grant execute on function doctor.record_report_share_access(text) to anon, authenticated;

-- O worker conclui: arquivo no Storage, a linha `ready` e a geração na trilha (com o hash).
create function doctor.finish_report(report uuid, path text, size bigint, digest text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  tenant uuid;
begin
  update doctor.reports r set status = 'ready', storage_path = path, size_bytes = size,
    content_sha256 = digest, error = null, completed_at = now()
  where r.id = report and r.status = 'running'
  returning r.tenant_id into tenant;
  if tenant is not null then
    perform doctor.write_audit(tenant, 'report.generated', 'report', report::text, null,
      jsonb_build_object('sha256', digest, 'size_bytes', size));
  end if;
end;
$$;
revoke all on function doctor.finish_report(uuid, text, bigint, text) from public, anon, authenticated;
grant execute on function doctor.finish_report(uuid, text, bigint, text) to service_role;

-- Revisão humana para o Relatório: o worker não lê `auth.users`. Sai o nome de quem revisou e
-- nunca o e-mail, porque o relatório vai para fora da Organização.
create function doctor.report_reviews(tenant uuid, diagnosis uuid)
returns table (verdict text, reviewer text, comment text, created_at timestamptz)
language sql
stable
security definer
set search_path = ''
as $$
  select f.verdict,
    coalesce(nullif(btrim(u.raw_user_meta_data ->> 'full_name'), ''), 'Revisor da Organização'),
    f.comment, f.created_at
  from doctor.diagnosis_feedback f
  left join auth.users u on u.id = f.reviewer_id
  where f.tenant_id = tenant and f.diagnosis_id = diagnosis
  order by f.created_at
$$;
revoke all on function doctor.report_reviews(uuid, uuid) from public, anon, authenticated;
grant execute on function doctor.report_reviews(uuid, uuid) to service_role;

-- Bucket privado do Doctor (ADR-0009): o worker sobe com a chave de serviço; lê, com URL
-- assinada de 5 min, todo Papel da Organização dona da pasta.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('doctor-reports', 'doctor-reports', false, 10485760, array['application/pdf', 'text/markdown'])
on conflict (id) do nothing;

create policy doctor_reports_select on storage.objects
for select to authenticated
using (
  bucket_id = 'doctor-reports'
  and (storage.foldername(name))[1] = (select doctor.current_tenant_id())::text
  and (select doctor.has_member_role('owner', 'admin', 'analyst', 'viewer'))
);

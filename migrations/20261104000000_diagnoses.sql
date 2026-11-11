-- Diagnóstico em 6 etapas (ticket #24, PRD §6, ADR-0003). Cada pedido é uma versão nova do
-- Incidente; publicada, a versão é imutável (trigger), e as Evidências apontam por FK composta
-- para registros reais do mesmo tenant. O progresso (`stage`) chega à tela pelo Realtime (ADR-0005).

alter table doctor.tenants
  add column auto_diagnose_critical boolean not null default false;
comment on column doctor.tenants.auto_diagnose_critical is
  'Diagnóstico híbrido automático ao abrir Incidente crítico (desligado por padrão).';

create table doctor.diagnoses (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references doctor.tenants (id) on delete cascade,
  incident_id uuid not null,
  version integer not null check (version > 0),
  status text not null default 'queued'
    check (status in ('queued', 'running', 'published', 'inconclusive', 'failed_llm', 'failed')),
  stage text not null default 'queued'
    check (stage in ('queued', 'validation', 'correlation', 'rules', 'knowledge', 'llm', 'verification', 'done')),
  -- Pedido e efetivo: sem Cota de IA o híbrido roda como rules_only, e a nota explica.
  requested_mode text not null check (requested_mode in ('hybrid', 'rules_only')),
  mode text not null check (mode in ('hybrid', 'rules_only')),
  include_knowledge_base boolean not null default true,
  -- Idempotência: a mesma requisição (hash de Usuário, Incidente, corpo e Idempotency-Key) ou o
  -- mesmo Incidente aberto, no automático, é 1 Diagnóstico.
  processing_key text not null check (char_length(processing_key) between 1 and 200),
  classification text check (char_length(classification) <= 80),
  probable_cause text check (char_length(probable_cause) <= 2000),
  -- Heurística, não calibrada: a tela mostra sempre com esse rótulo.
  confidence numeric(3, 2) check (confidence between 0 and 1),
  responsible_system text check (responsible_system in ('sap', 'salesforce', 'gcp', 'other')),
  requires_human_review boolean not null default true,
  verification_notes jsonb not null default '[]' check (jsonb_typeof(verification_notes) = 'array'),
  provider text,
  model text,
  ruleset_version text,
  input_tokens integer not null default 0 check (input_tokens >= 0),
  output_tokens integer not null default 0 check (output_tokens >= 0),
  duration_ms integer check (duration_ms >= 0),
  error text check (char_length(error) <= 500),
  -- Tentativas do worker: falha que se repete vira `failed` em vez de voltar à fila para sempre.
  attempts integer not null default 0 check (attempts >= 0),
  requested_by uuid references auth.users (id) on delete set null,
  started_at timestamptz,
  published_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, processing_key),
  unique (tenant_id, incident_id, version),
  foreign key (tenant_id, incident_id) references doctor.incidents (tenant_id, id) on delete cascade
);
comment on table doctor.diagnoses is 'Diagnóstico versionado de um Incidente; imutável depois de publicado.';
create index diagnoses_incident_idx on doctor.diagnoses (tenant_id, incident_id, version desc);

create trigger diagnoses_set_updated_at
before update on doctor.diagnoses
for each row execute function doctor.set_updated_at();

create table doctor.diagnosis_hypotheses (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references doctor.tenants (id) on delete cascade,
  diagnosis_id uuid not null,
  rank integer not null check (rank > 0),
  statement text not null check (char_length(statement) between 1 and 1000),
  confidence numeric(3, 2) check (confidence between 0 and 1),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, diagnosis_id, rank),
  foreign key (tenant_id, diagnosis_id) references doctor.diagnoses (tenant_id, id) on delete cascade
);
comment on table doctor.diagnosis_hypotheses is 'Hipóteses ordenadas de um Diagnóstico.';

create table doctor.diagnosis_evidence (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references doctor.tenants (id) on delete cascade,
  diagnosis_id uuid not null,
  rank integer not null check (rank > 0),
  kind text not null check (kind in ('event', 'raw_log', 'chunk', 'global_chunk', 'rule_match')),
  -- Exatamente uma referência ao gravar. A retenção (#29) pode apagar o registro apontado depois:
  -- a FK zera a referência e o `label` guarda o que ele era.
  event_id uuid,
  event_timestamp timestamptz,
  raw_log_object_id uuid,
  chunk_id uuid,
  global_chunk_id uuid references doctor.global_knowledge_chunks (id) on delete set null,
  rule_match_id uuid,
  label text not null check (char_length(label) between 1 and 300),
  finding text not null check (char_length(finding) between 1 and 1000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, diagnosis_id, rank),
  foreign key (tenant_id, diagnosis_id) references doctor.diagnoses (tenant_id, id) on delete cascade,
  foreign key (tenant_id, event_id, event_timestamp) references doctor.events (tenant_id, id, timestamp)
    on delete set null (event_id, event_timestamp),
  foreign key (tenant_id, raw_log_object_id) references doctor.raw_log_objects (tenant_id, id)
    on delete set null (raw_log_object_id),
  foreign key (tenant_id, chunk_id) references doctor.knowledge_chunks (tenant_id, id)
    on delete set null (chunk_id),
  foreign key (tenant_id, rule_match_id) references doctor.rule_matches (tenant_id, id)
    on delete set null (rule_match_id),
  check ((event_id is null) = (event_timestamp is null)),
  check (num_nonnulls(event_id, raw_log_object_id, chunk_id, global_chunk_id, rule_match_id) <= 1)
);
comment on table doctor.diagnosis_evidence is 'Evidência de um Diagnóstico: aponta para um Evento, Log bruto, Fragmento ou match de Regra do mesmo tenant.';
create index diagnosis_evidence_event_idx on doctor.diagnosis_evidence (tenant_id, event_id) where event_id is not null;
create index diagnosis_evidence_chunk_idx on doctor.diagnosis_evidence (tenant_id, chunk_id) where chunk_id is not null;
create index diagnosis_evidence_global_chunk_idx on doctor.diagnosis_evidence (global_chunk_id) where global_chunk_id is not null;
create index diagnosis_evidence_rule_match_idx on doctor.diagnosis_evidence (tenant_id, rule_match_id) where rule_match_id is not null;
create index diagnosis_evidence_raw_log_idx on doctor.diagnosis_evidence (tenant_id, raw_log_object_id) where raw_log_object_id is not null;

create table doctor.diagnosis_recommendations (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references doctor.tenants (id) on delete cascade,
  diagnosis_id uuid not null,
  rank integer not null check (rank > 0),
  text text not null check (char_length(text) between 1 and 1000),
  kind text not null check (kind in ('investigate', 'fix', 'verify')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, diagnosis_id, rank),
  foreign key (tenant_id, diagnosis_id) references doctor.diagnoses (tenant_id, id) on delete cascade
);
comment on table doctor.diagnosis_recommendations is 'Recomendações de um Diagnóstico: sempre ações humanas.';

create trigger diagnosis_hypotheses_set_updated_at
before update on doctor.diagnosis_hypotheses
for each row execute function doctor.set_updated_at();
create trigger diagnosis_evidence_set_updated_at
before update on doctor.diagnosis_evidence
for each row execute function doctor.set_updated_at();
create trigger diagnosis_recommendations_set_updated_at
before update on doctor.diagnosis_recommendations
for each row execute function doctor.set_updated_at();

-- Imutabilidade: versão final (publicada, inconclusiva ou com falha) não muda. Nova análise é a
-- versão N+1. Apagar continua possível (retenção, exclusão da Organização).
create function doctor.diagnosis_is_final(status text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select status in ('published', 'inconclusive', 'failed_llm', 'failed')
$$;

create function doctor.guard_diagnosis()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if doctor.diagnosis_is_final(old.status) then
    -- Única mudança aceita: a FK zerando quem pediu, quando o Usuário é excluído (LGPD).
    if new.requested_by is null
        and (to_jsonb(new) - array['requested_by', 'updated_at'])
          = (to_jsonb(old) - array['requested_by', 'updated_at']) then
      return new;
    end if;
    raise exception 'Diagnóstico % já publicado: crie uma nova versão', old.id
      using errcode = 'DR020';
  end if;
  return new;
end;
$$;

create trigger diagnoses_immutable
before update on doctor.diagnoses
for each row execute function doctor.guard_diagnosis();

-- Filhas: só entram enquanto o Diagnóstico roda; depois, só a FK da retenção mexe nelas (zerando a
-- referência a um registro apagado).
create function doctor.guard_diagnosis_child()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  parent_status text;
  refs text[] := array['event_id', 'event_timestamp', 'raw_log_object_id', 'chunk_id',
    'global_chunk_id', 'rule_match_id', 'updated_at'];
begin
  select d.status into parent_status from doctor.diagnoses d
  where d.tenant_id = new.tenant_id and d.id = new.diagnosis_id;
  if tg_op = 'INSERT' then
    if parent_status is distinct from 'running' then
      raise exception 'Diagnóstico % não está em andamento', new.diagnosis_id using errcode = 'DR020';
    end if;
    -- Campo a campo só na Evidência: as outras filhas não têm as colunas de referência.
    if tg_table_name = 'diagnosis_evidence' then
      if num_nonnulls(new.event_id, new.raw_log_object_id, new.chunk_id, new.global_chunk_id,
          new.rule_match_id) <> 1 then
        raise exception 'Evidência sem referência' using errcode = '23514';
      end if;
    end if;
    return new;
  end if;
  if doctor.diagnosis_is_final(parent_status) then
    if tg_table_name = 'diagnosis_evidence' then
      if (to_jsonb(new) - refs) = (to_jsonb(old) - refs)
          and (new.event_id is null or new.event_id = old.event_id)
          and (new.raw_log_object_id is null or new.raw_log_object_id = old.raw_log_object_id)
          and (new.chunk_id is null or new.chunk_id = old.chunk_id)
          and (new.global_chunk_id is null or new.global_chunk_id = old.global_chunk_id)
          and (new.rule_match_id is null or new.rule_match_id = old.rule_match_id) then
        return new;
      end if;
    end if;
    raise exception 'Diagnóstico % já publicado: crie uma nova versão', new.diagnosis_id
      using errcode = 'DR020';
  end if;
  return new;
end;
$$;

create trigger diagnosis_hypotheses_guard
before insert or update on doctor.diagnosis_hypotheses
for each row execute function doctor.guard_diagnosis_child();
create trigger diagnosis_evidence_guard
before insert or update on doctor.diagnosis_evidence
for each row execute function doctor.guard_diagnosis_child();
create trigger diagnosis_recommendations_guard
before insert or update on doctor.diagnosis_recommendations
for each row execute function doctor.guard_diagnosis_child();

revoke all on function doctor.diagnosis_is_final(text) from public;
-- Os triggers rodam com o papel de quem escreve (o worker, como service_role).
grant execute on function doctor.diagnosis_is_final(text) to authenticated, service_role;
revoke all on function doctor.guard_diagnosis() from public;
revoke all on function doctor.guard_diagnosis_child() from public;

alter table doctor.diagnoses enable row level security;
alter table doctor.diagnosis_hypotheses enable row level security;
alter table doctor.diagnosis_evidence enable row level security;
alter table doctor.diagnosis_recommendations enable row level security;
revoke all on doctor.diagnoses, doctor.diagnosis_hypotheses, doctor.diagnosis_evidence,
  doctor.diagnosis_recommendations from anon, authenticated;
grant select on doctor.diagnoses, doctor.diagnosis_hypotheses, doctor.diagnosis_evidence,
  doctor.diagnosis_recommendations to authenticated;

create policy diagnoses_select on doctor.diagnoses
for select to authenticated using (tenant_id = (select doctor.current_tenant_id()));
create policy diagnosis_hypotheses_select on doctor.diagnosis_hypotheses
for select to authenticated using (tenant_id = (select doctor.current_tenant_id()));
create policy diagnosis_evidence_select on doctor.diagnosis_evidence
for select to authenticated using (tenant_id = (select doctor.current_tenant_id()));
create policy diagnosis_recommendations_select on doctor.diagnosis_recommendations
for select to authenticated using (tenant_id = (select doctor.current_tenant_id()));

-- Pedido de Diagnóstico: Analyst ou acima. A mesma chave devolve o mesmo Diagnóstico; a versão sai
-- com o Incidente travado, para dois pedidos simultâneos não ganharem o mesmo número.
create function doctor.request_diagnosis(
  incident uuid, requested_mode text, include_knowledge_base boolean, processing_key text
)
returns table (id uuid, status text, version integer, created boolean)
language plpgsql
security definer
set search_path = ''
as $$
declare
  tenant uuid := doctor.current_tenant_id();
  current doctor.diagnoses;
  next_version integer;
begin
  if not doctor.has_member_role('owner', 'admin', 'analyst') then
    raise insufficient_privilege using message = 'exige Analyst ou acima';
  end if;
  if requested_mode not in ('hybrid', 'rules_only') then
    raise exception 'modo inválido' using errcode = '22023';
  end if;
  perform 1 from doctor.incidents i where i.tenant_id = tenant and i.id = incident for update;
  if not found then
    raise no_data_found using message = 'Incidente não encontrado';
  end if;
  select * into current from doctor.diagnoses d
  where d.tenant_id = tenant and d.processing_key = request_diagnosis.processing_key;
  if current.id is not null then
    if current.incident_id <> incident then
      raise exception 'chave de idempotência já usada' using errcode = '23505';
    end if;
    return query select current.id, current.status, current.version, false;
    return;
  end if;
  select coalesce(max(d.version), 0) + 1 into next_version from doctor.diagnoses d
  where d.tenant_id = tenant and d.incident_id = incident;
  insert into doctor.diagnoses (tenant_id, incident_id, version, requested_mode, mode,
    include_knowledge_base, processing_key, requested_by)
  values (tenant, incident, next_version, requested_mode, requested_mode,
    request_diagnosis.include_knowledge_base, request_diagnosis.processing_key, auth.uid())
  returning * into current;
  insert into doctor.outbox_messages (tenant_id, topic, payload)
  values (tenant, 'diagnosis.requested', jsonb_build_object('diagnosis_id', current.id));
  perform doctor.record_audit(tenant, 'diagnosis.requested', current.id::text);
  return query select current.id, current.status, current.version, true;
end;
$$;

-- Diagnóstico automático ao abrir Incidente crítico: Owner ou Admin com MFA liga e desliga.
create function doctor.set_auto_diagnosis(enabled boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  tenant uuid := doctor.current_tenant_id();
begin
  perform doctor.require_manager();
  update doctor.tenants t set auto_diagnose_critical = enabled where t.id = tenant;
  perform doctor.record_audit(tenant, 'diagnosis.auto_changed', enabled::text);
end;
$$;

revoke all on function doctor.request_diagnosis(uuid, text, boolean, text) from public, service_role;
revoke all on function doctor.set_auto_diagnosis(boolean) from public, service_role;
grant execute on function doctor.request_diagnosis(uuid, text, boolean, text) to authenticated;
grant execute on function doctor.set_auto_diagnosis(boolean) to authenticated;

-- Realtime (ADR-0005): a tela acompanha `stage` e `status` da versão em andamento.
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
    and not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime' and schemaname = 'doctor' and tablename = 'diagnoses'
    ) then
    alter publication supabase_realtime add table doctor.diagnoses;
  end if;
end;
$$;

-- Ticket #40: enriquecimento sob demanda na etapa 2 do Diagnóstico. O worker de diagnóstico pede
-- as consultas (uma por Referência do Mapa com `lookup`) e devolve o Diagnóstico à fila; o worker
-- de Conectores, o único que lê as credenciais (ADR-0006), consulta o destino só para leitura,
-- grava o resultado e pede o Diagnóstico de novo. O resultado é um registro real da Organização:
-- a Evidência do tipo `enrichment` aponta para ele.

create table doctor.enrichments (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references doctor.tenants (id) on delete cascade,
  diagnosis_id uuid not null,
  mapping_id uuid,
  connector_id uuid,
  -- Valor consultado (a chave normalizada do Mapa, com os zeros do destino).
  reference text not null check (char_length(reference) between 1 and 256),
  system text not null check (char_length(system) between 1 and 32),
  entity text not null check (entity ~ '^[A-Za-z][A-Za-z0-9_]{0,79}$'),
  field text not null check (field ~ '^[A-Za-z][A-Za-z0-9_]{0,79}$'),
  outcome text not null default 'pending' check (outcome in ('pending', 'found', 'not_found', 'failed')),
  record_id text check (char_length(record_id) <= 256),
  record_status text check (char_length(record_status) <= 128),
  -- Mensagem classificada do Conector (nunca a resposta do destino).
  error text check (char_length(error) <= 500),
  checked_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, diagnosis_id, mapping_id, reference),
  foreign key (tenant_id, diagnosis_id) references doctor.diagnoses (tenant_id, id) on delete cascade,
  foreign key (tenant_id, mapping_id) references doctor.correlation_mappings (tenant_id, id)
    on delete set null (mapping_id),
  foreign key (tenant_id, connector_id) references doctor.connectors (tenant_id, id)
    on delete set null (connector_id),
  check (outcome = 'pending' or checked_at is not null)
);
comment on table doctor.enrichments is 'Consulta de leitura no sistema de origem ou destino feita para um Diagnóstico.';
create index enrichments_diagnosis_idx on doctor.enrichments (tenant_id, diagnosis_id);
create index enrichments_pending_idx on doctor.enrichments (tenant_id, created_at) where outcome = 'pending';

create trigger enrichments_set_updated_at
before update on doctor.enrichments
for each row execute function doctor.set_updated_at();

alter table doctor.enrichments enable row level security;
revoke all on doctor.enrichments from anon, authenticated;
-- Leitura para a tela do Diagnóstico; só os workers (papel de plataforma) escrevem.
grant select on doctor.enrichments to authenticated;
create policy enrichments_select on doctor.enrichments
for select to authenticated
using (tenant_id = (select doctor.current_tenant_id()));

alter table doctor.diagnosis_evidence add column enrichment_id uuid;
alter table doctor.diagnosis_evidence
  add constraint diagnosis_evidence_enrichment_fk
  foreign key (tenant_id, enrichment_id) references doctor.enrichments (tenant_id, id)
  on delete set null (enrichment_id);
alter table doctor.diagnosis_evidence drop constraint diagnosis_evidence_kind_check;
alter table doctor.diagnosis_evidence
  add constraint diagnosis_evidence_kind_check
  check (kind in ('event', 'raw_log', 'chunk', 'global_chunk', 'rule_match', 'enrichment'));
alter table doctor.diagnosis_evidence drop constraint diagnosis_evidence_check1;
alter table doctor.diagnosis_evidence
  add constraint diagnosis_evidence_one_ref
  check (num_nonnulls(event_id, raw_log_object_id, chunk_id, global_chunk_id, rule_match_id, enrichment_id) <= 1);

-- A guarda das filhas do Diagnóstico passa a conhecer a referência nova: na inserção, uma
-- referência só; depois de publicado, só a retenção (ou a remoção da consulta) zera a referência.
create or replace function doctor.guard_diagnosis_child()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  parent_status text;
  refs text[] := array['event_id', 'event_timestamp', 'raw_log_object_id', 'chunk_id',
    'global_chunk_id', 'rule_match_id', 'enrichment_id', 'updated_at'];
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
          new.rule_match_id, new.enrichment_id) <> 1 then
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
          and (new.rule_match_id is null or new.rule_match_id = old.rule_match_id)
          and (new.enrichment_id is null or new.enrichment_id = old.enrichment_id) then
        return new;
      end if;
    end if;
    raise exception 'Diagnóstico % já publicado: crie uma nova versão', new.diagnosis_id
      using errcode = 'DR020';
  end if;
  return new;
end;
$$;

-- Conector OData genérico, só de consulta: entra na lista de provedores.
alter table doctor.connectors drop constraint connectors_provider_check;
alter table doctor.connectors
  add constraint connectors_provider_check check (provider in ('fake', 'gcp', 'salesforce', 'sap', 'odata'));

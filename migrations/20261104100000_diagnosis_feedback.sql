-- Revisão humana do Diagnóstico (ticket #26): um feedback por revisor por versão, auditado com o
-- veredito e a versão. Aceite ou correção tira o "Requer revisão" (a única mudança que a versão
-- publicada aceita). O Incidente resolvido com Diagnóstico aceito ou corrigido pode virar
-- documento da Base de conhecimento (`source = 'incident'`), que o Diagnóstico seguinte consulta.

create table doctor.diagnosis_feedback (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references doctor.tenants (id) on delete cascade,
  diagnosis_id uuid not null,
  reviewer_id uuid references auth.users (id) on delete set null,
  verdict text not null check (verdict in ('accepted', 'corrected', 'rejected')),
  correct_category text check (correct_category ~ '^[A-Z][A-Z0-9_]{2,59}$'),
  correct_cause text check (char_length(btrim(correct_cause)) between 1 and 2000),
  responsible_system text check (responsible_system in ('sap', 'salesforce', 'gcp', 'other')),
  comment text check (char_length(comment) <= 2000),
  -- Da publicação à revisão: entra no MTTR do relatório do piloto (#30).
  time_to_review_s integer check (time_to_review_s >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, diagnosis_id, reviewer_id),
  foreign key (tenant_id, diagnosis_id) references doctor.diagnoses (tenant_id, id) on delete cascade,
  -- Corrigir é dizer o que é certo.
  check (verdict <> 'corrected' or correct_category is not null or correct_cause is not null)
);
comment on table doctor.diagnosis_feedback is 'Revisão humana de uma versão do Diagnóstico.';
create index diagnosis_feedback_diagnosis_idx on doctor.diagnosis_feedback (tenant_id, diagnosis_id);

create trigger diagnosis_feedback_set_updated_at
before update on doctor.diagnosis_feedback
for each row execute function doctor.set_updated_at();

alter table doctor.diagnosis_feedback enable row level security;
revoke all on doctor.diagnosis_feedback from anon, authenticated;
grant select on doctor.diagnosis_feedback to authenticated;
create policy diagnosis_feedback_select on doctor.diagnosis_feedback
for select to authenticated using (tenant_id = (select doctor.current_tenant_id()));

-- A versão publicada aceita, além das FKs, só sair de "Requer revisão" (ADR-0013).
create or replace function doctor.guard_diagnosis()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  mutable text[] := array['requested_by', 'requires_human_review', 'updated_at'];
begin
  if doctor.diagnosis_is_final(old.status) then
    if (to_jsonb(new) - mutable) = (to_jsonb(old) - mutable)
        and (new.requested_by is null or new.requested_by = old.requested_by)
        and (new.requires_human_review = old.requires_human_review or not new.requires_human_review) then
      return new;
    end if;
    raise exception 'Diagnóstico % já publicado: crie uma nova versão', old.id
      using errcode = 'DR020';
  end if;
  return new;
end;
$$;

-- Documento vindo de Incidente: o texto fica no próprio registro (não há arquivo no Storage); o
-- worker sanitiza antes de fragmentar, como num upload. Um por Incidente.
alter table doctor.knowledge_documents
  add column body text check (char_length(body) <= 100000),
  add constraint knowledge_documents_incident_body check ((source = 'incident') = (body is not null));
-- O texto bruto (antes da Sanitização, que roda no worker) não é legível pelos membros: o worker
-- o troca pelo texto sanitizado ao indexar, e a busca só devolve Fragmentos.
revoke select on doctor.knowledge_documents from authenticated;
grant select (id, tenant_id, title, source, storage_path, incident_id, content_type, size_bytes,
  status, chunk_count, embedding_model, reindex_queued_at, error, created_by, created_at, updated_at)
  on doctor.knowledge_documents to authenticated;
create unique index knowledge_documents_incident_idx on doctor.knowledge_documents (tenant_id, incident_id)
  where source = 'incident';

create function doctor.submit_diagnosis_feedback(
  target uuid,
  verdict text,
  correct_category text,
  correct_cause text,
  responsible_system text,
  comment text
)
returns doctor.diagnosis_feedback
language plpgsql
security definer
set search_path = ''
as $$
declare
  tenant uuid := doctor.current_tenant_id();
  current doctor.diagnoses;
  created doctor.diagnosis_feedback;
  category text := nullif(btrim(submit_diagnosis_feedback.correct_category), '');
  cause text := nullif(btrim(submit_diagnosis_feedback.correct_cause), '');
begin
  if not doctor.has_member_role('owner', 'admin', 'analyst') then
    raise insufficient_privilege using message = 'exige Analyst ou acima';
  end if;
  select * into current from doctor.diagnoses d where d.tenant_id = tenant and d.id = target for update;
  if current.id is null then
    raise no_data_found using message = 'Diagnóstico não encontrado';
  end if;
  if current.status not in ('published', 'inconclusive', 'failed_llm') then
    raise exception 'Diagnóstico ainda não publicado' using errcode = 'DR021';
  end if;
  -- Só a versão mais nova publicada: revisar versão superada distorce as métricas do piloto.
  if exists (
    select 1 from doctor.diagnoses d
    where d.tenant_id = tenant and d.incident_id = current.incident_id
      and d.version > current.version and d.status in ('published', 'inconclusive', 'failed_llm')
  ) then
    raise exception 'Versão superada' using errcode = 'DR024';
  end if;
  if submit_diagnosis_feedback.verdict = 'corrected' and category is null and cause is null then
    raise exception 'Corrigir exige a categoria ou a causa certa' using errcode = 'DR025';
  end if;
  begin
    insert into doctor.diagnosis_feedback (tenant_id, diagnosis_id, reviewer_id, verdict,
      correct_category, correct_cause, responsible_system, comment, time_to_review_s)
    values (tenant, target, auth.uid(), submit_diagnosis_feedback.verdict, category, cause,
      submit_diagnosis_feedback.responsible_system,
      nullif(btrim(submit_diagnosis_feedback.comment), ''),
      greatest(0, extract(epoch from now() - coalesce(current.published_at, now()))::int))
    returning * into created;
  exception when unique_violation then
    raise exception 'Versão já revisada por este Usuário' using errcode = 'DR026';
  end;
  if submit_diagnosis_feedback.verdict in ('accepted', 'corrected') then
    update doctor.diagnoses d set requires_human_review = false where d.id = target;
  end if;
  -- Quem (actor_id), o veredito e a versão.
  insert into doctor.audit_logs (tenant_id, actor_type, actor_id, action, resource_type, resource_id, after)
  values (tenant, 'user', auth.uid(), 'diagnosis.reviewed', 'diagnosis', target::text,
    jsonb_build_object('verdict', submit_diagnosis_feedback.verdict, 'version', current.version,
      'incident_id', current.incident_id));
  return created;
end;
$$;

-- Promover: Incidente resolvido com a versão mais nova aceita ou corrigida vira documento da Base
-- (causa, Evidências e resolução). A correção vale sobre o que o Diagnóstico disse.
create function doctor.promote_incident_to_knowledge(incident uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  tenant uuid := doctor.current_tenant_id();
  found_incident doctor.incidents;
  latest doctor.diagnoses;
  review doctor.diagnosis_feedback;
  evidence text;
  content text;
  created uuid;
begin
  if not doctor.has_member_role('owner', 'admin', 'analyst') then
    raise insufficient_privilege using message = 'exige Analyst ou acima';
  end if;
  select * into found_incident from doctor.incidents i where i.tenant_id = tenant and i.id = incident;
  if found_incident.id is null then
    raise no_data_found using message = 'Incidente não encontrado';
  end if;
  if found_incident.status <> 'resolved' then
    raise exception 'Incidente ainda não resolvido' using errcode = 'DR022';
  end if;
  select * into latest from doctor.diagnoses d
  where d.tenant_id = tenant and d.incident_id = incident
    and d.status in ('published', 'inconclusive', 'failed_llm')
  order by d.version desc limit 1;
  select * into review from doctor.diagnosis_feedback f
  where f.tenant_id = tenant and f.diagnosis_id = latest.id and f.verdict in ('accepted', 'corrected')
  order by (f.verdict = 'corrected') desc, f.created_at desc limit 1;
  if review.id is null then
    raise exception 'Sem Diagnóstico aceito ou corrigido' using errcode = 'DR023';
  end if;
  select string_agg('- ' || e.label || ': ' || e.finding, E'\n' order by e.rank) into evidence
  from doctor.diagnosis_evidence e where e.tenant_id = tenant and e.diagnosis_id = latest.id;
  content := '# INC-' || lpad(found_incident.number::text, 4, '0') || ' · ' || found_incident.title || E'\n\n'
    || '## Classificação' || E'\n\n' || coalesce(review.correct_category, latest.classification, found_incident.category) || E'\n\n'
    || '## Causa' || E'\n\n' || coalesce(review.correct_cause, latest.probable_cause, 'Não registrada.') || E'\n\n'
    || '## Evidências' || E'\n\n' || coalesce(evidence, 'Nenhuma.') || E'\n\n'
    || '## Resolução' || E'\n\n' || coalesce(found_incident.resolution_note, 'Não registrada.');
  insert into doctor.knowledge_documents (tenant_id, title, source, incident_id, content_type,
    size_bytes, status, body)
  values (tenant, left('INC-' || lpad(found_incident.number::text, 4, '0') || ' · ' || found_incident.title, 200),
    'incident', incident, 'text/markdown', octet_length(content), 'indexing', content)
  on conflict (tenant_id, incident_id) where source = 'incident' do nothing
  returning id into created;
  if created is null then
    raise exception 'Incidente já promovido' using errcode = '23505';
  end if;
  insert into doctor.outbox_messages (tenant_id, topic, payload)
  values (tenant, 'knowledge.index', jsonb_build_object('document_id', created));
  perform doctor.record_audit(tenant, 'knowledge.promoted', created::text);
  return created;
end;
$$;

revoke all on function doctor.submit_diagnosis_feedback(uuid, text, text, text, text, text) from public, service_role;
revoke all on function doctor.promote_incident_to_knowledge(uuid) from public, service_role;
grant execute on function doctor.submit_diagnosis_feedback(uuid, text, text, text, text, text) to authenticated;
grant execute on function doctor.promote_incident_to_knowledge(uuid) to authenticated;

-- Excluir Integração (complementa o #10 do jayv-doctor): Owner ou Admin com MFA excluem de verdade
-- a que não tem histórico nem configuração ligada. A regra fica em `doctor.integration_in_use`,
-- que o gatilho usa para recusar (23503, o caminho é arquivar) e as listas usam para dizer
-- `deletable` (`integration_deletable`; a tela só oferece Excluir nessas). Conta como em uso: Execuções, Eventos,
-- Incidentes, estatísticas por hora (o painel, que sobrevive à retenção das Execuções), Conectores,
-- Agentes, tokens e lotes de ingestão, Importações e Regras de alerta que a citam (lista em jsonb,
-- sem chave estrangeira). Os Mapas de identificadores e os de colunas saem junto
-- (`on delete cascade`). O trigger `integrations_audit` registra a exclusão.

create function doctor.integration_in_use(tenant uuid, target uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from doctor.executions x where x.tenant_id = tenant and x.integration_id = target)
    or exists (select 1 from doctor.events e where e.tenant_id = tenant and e.integration_id = target)
    or exists (select 1 from doctor.incidents n where n.tenant_id = tenant and n.integration_id = target)
    or exists (select 1 from doctor.execution_stats_hourly s where s.tenant_id = tenant and s.integration_id = target)
    or exists (select 1 from doctor.connectors c where c.tenant_id = tenant and c.integration_id = target)
    or exists (select 1 from doctor.agents a where a.tenant_id = tenant and a.integration_id = target)
    or exists (select 1 from doctor.ingestion_tokens k where k.tenant_id = tenant and k.integration_id = target)
    or exists (select 1 from doctor.ingestion_batches b where b.tenant_id = tenant and b.integration_id = target)
    or exists (select 1 from doctor.imports m where m.tenant_id = tenant and m.integration_id = target)
    or exists (
      select 1 from doctor.alert_rules r
      where r.tenant_id = tenant and r.conditions -> 'integrations' ? target::text
    )
$$;
-- Recebe o tenant de fora: só para o gatilho e para `integration_deletable`.
revoke all on function doctor.integration_in_use(uuid, uuid) from public, anon, authenticated, service_role;

-- Para as listas: só na Organização ativa de quem pede.
create function doctor.integration_deletable(target uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select doctor.current_tenant_id() is not null
    and not doctor.integration_in_use(doctor.current_tenant_id(), target)
$$;
revoke all on function doctor.integration_deletable(uuid) from public, anon;
grant execute on function doctor.integration_deletable(uuid) to authenticated, service_role;

-- Recusa a exclusão pedida de uma Integração em uso. Só no `delete` direto (profundidade 1):
-- excluir a Organização inteira (privacidade) apaga em cascata, com histórico e tudo.
create function doctor.integrations_keep_history()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if pg_trigger_depth() = 1 and doctor.integration_in_use(old.tenant_id, old.id) then
    raise exception 'a Integração tem histórico ou configuração ligada; arquive-a'
      using errcode = '23503';
  end if;
  return old;
end;
$$;
revoke all on function doctor.integrations_keep_history() from public, anon, authenticated, service_role;

create trigger integrations_keep_history
  before delete on doctor.integrations
  for each row execute function doctor.integrations_keep_history();

grant delete on doctor.integrations to authenticated;

create policy integrations_delete on doctor.integrations
  for delete to authenticated
  using (tenant_id = (select doctor.current_tenant_id()) and (select doctor.is_manager()));

-- A lista do site diz quais dá para excluir.
create or replace function doctor_read.integrations(include_archived boolean default false)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
begin
  perform doctor.read_tenant();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', i.id, 'name', i.name, 'description', i.description,
      'source_system', i.source_system, 'target_system', i.target_system,
      'owner_team', i.owner_team, 'environment', i.environment,
      'archived_at', i.archived_at, 'created_at', i.created_at,
      'deletable', doctor.integration_deletable(i.id),
      'error_rate_24h', (
        select sum(s.failed)::float8 / nullif(sum(s.total), 0)
        from doctor.execution_stats_hourly s
        where s.tenant_id = i.tenant_id and s.integration_id = i.id
          and s.hour >= date_trunc('hour', now() - interval '24 hours')
      )
    ) order by i.name, i.environment)
    from doctor.integrations i
    where integrations.include_archived or i.archived_at is null
  ), '[]'::jsonb);
end;
$$;

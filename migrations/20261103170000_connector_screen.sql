-- Tela de Conectores (ticket #16): o Checkpoint e o motivo da pausa aparecem no card, e o status
-- chega em tempo real pelo Realtime.

-- Sem secret_id, como antes: nem o id do segredo vai para o cliente.
grant select (checkpoint, paused_reason) on doctor.connectors to authenticated;

-- O Realtime confere o RLS e os privilégios de coluna de quem assina (`realtime.apply_rls`), então
-- o evento traz só as colunas acima, e só para a Organização do JWT. A publicação é do projeto
-- inteiro (compartilhado com o jayv-coder, ADR-0009): só se acrescenta a tabela do Doctor.
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
    and not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime' and schemaname = 'doctor' and tablename = 'connectors'
    )
  then
    alter publication supabase_realtime add table doctor.connectors;
  end if;
end;
$$;

-- O assistente escolhe o intervalo ao criar: vai junto, numa escrita só (um registro de auditoria
-- de criação, sem um "update" que ninguém fez).
drop function doctor.create_connector(uuid, text, text, jsonb, text);

create function doctor.create_connector(
  integration_id uuid, provider text, name text, config jsonb, secret text,
  sync_interval_seconds integer default 300
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  tenant uuid := doctor.current_tenant_id();
  new_id uuid := gen_random_uuid();
begin
  if not doctor.is_manager() then
    raise insufficient_privilege using message = 'exige Owner ou Admin com MFA';
  end if;
  if not exists (
    select 1 from doctor.integrations i
    where i.id = create_connector.integration_id and i.tenant_id = tenant and i.archived_at is null
  ) then
    raise no_data_found using message = 'Integração não encontrada';
  end if;
  insert into doctor.connectors (
    id, tenant_id, integration_id, provider, name, config, sync_interval_seconds, secret_id
  )
  values (
    new_id, tenant, create_connector.integration_id, create_connector.provider,
    create_connector.name, create_connector.config, create_connector.sync_interval_seconds,
    vault.create_secret(create_connector.secret, 'doctor/connector/' || new_id, 'Credencial de Conector do Doctor')
  );
  perform doctor.record_audit(tenant, 'connector.create', new_id::text);
  return new_id;
end;
$$;

revoke all on function doctor.create_connector(uuid, text, text, jsonb, text, integer) from public, service_role;
grant execute on function doctor.create_connector(uuid, text, text, jsonb, text, integer) to authenticated;

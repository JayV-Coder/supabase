-- Ticket #11: Importação manual de logs. Logs brutos no Storage, Importações e outbox.

-- Para funções e políticas: o Papel do Usuário na Organização ativa, lido da tabela (a claim pode
-- estar atrasada). security definer: lê o Vínculo sem depender do RLS de memberships.
create function doctor.has_member_role(variadic roles text[])
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from doctor.memberships m
    where m.tenant_id = doctor.current_tenant_id()
      and m.user_id = auth.uid()
      and m.role = any (roles)
  )
$$;

revoke all on function doctor.has_member_role(text[]) from public, service_role;
grant execute on function doctor.has_member_role(text[]) to authenticated;

-- Log bruto: o arquivo como chegou, antes da Sanitização. Só a plataforma escreve.
create table doctor.raw_log_objects (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references doctor.tenants (id) on delete cascade,
  storage_path text not null unique check (split_part(storage_path, '/', 1) = tenant_id::text),
  sha256 text not null check (sha256 ~ '^[0-9a-f]{64}$'),
  size_bytes bigint not null check (size_bytes between 0 and 52428800),
  source text not null check (source in ('import', 'connector', 'api')),
  -- Retenção padrão de 30 dias; a política por Organização chega no ticket #29.
  expires_at timestamptz not null default now() + interval '30 days',
  created_at timestamptz not null default now(),
  unique (tenant_id, id)
);
comment on table doctor.raw_log_objects is 'Log bruto no Storage (bucket doctor-raw-logs), antes da Sanitização.';

create index raw_log_objects_expires_at_idx on doctor.raw_log_objects (tenant_id, expires_at);

create table doctor.imports (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references doctor.tenants (id) on delete cascade,
  integration_id uuid not null,
  raw_log_object_id uuid,
  filename text not null check (char_length(filename) between 1 and 255),
  size_bytes bigint not null check (size_bytes >= 0),
  sha256 text not null check (sha256 ~ '^[0-9a-f]{64}$'),
  format text check (format in ('json', 'ndjson', 'csv')),
  -- `pending`: criada, esperando o upload. As demais seguem o ticket #11.
  status text not null default 'pending'
    check (status in ('pending', 'uploaded', 'processing', 'done', 'failed', 'rejected')),
  duplicate_of uuid,
  total_lines integer not null default 0,
  accepted integer not null default 0,
  rejected integer not null default 0,
  duplicates integer not null default 0,
  secrets_removed integer not null default 0,
  error text check (char_length(error) <= 500),
  created_by uuid default auth.uid() references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, id),
  foreign key (tenant_id, integration_id) references doctor.integrations (tenant_id, id),
  foreign key (tenant_id, raw_log_object_id) references doctor.raw_log_objects (tenant_id, id),
  foreign key (tenant_id, duplicate_of) references doctor.imports (tenant_id, id)
);
comment on table doctor.imports is 'Importação manual: um arquivo de logs enviado para uma Integração.';

create index imports_tenant_created_idx on doctor.imports (tenant_id, created_at desc);
create index imports_tenant_sha256_idx on doctor.imports (tenant_id, integration_id, sha256);

create trigger imports_set_updated_at
before update on doctor.imports
for each row execute function doctor.set_updated_at();

-- Outbox (ADR-0001): a mensagem nasce na mesma transação do dado e um relay a publica no Pub/Sub.
create table doctor.outbox_messages (
  id bigint generated always as identity primary key,
  tenant_id uuid not null references doctor.tenants (id) on delete cascade,
  topic text not null check (topic ~ '^[a-z]+(\.[a-z]+)+$'),
  payload jsonb not null,
  created_at timestamptz not null default now(),
  published_at timestamptz,
  attempts integer not null default 0
);
comment on table doctor.outbox_messages is 'Mensagens a publicar no Pub/Sub; só a plataforma lê e escreve.';

-- Tabela da plataforma, não de tenant: o relay drena em ordem de `id`, de todas as Organizações,
-- por isso o índice de pendentes não começa por `tenant_id`. O `unique` segue a convenção.
alter table doctor.outbox_messages add constraint outbox_messages_tenant_id_id_key unique (tenant_id, id);
create index outbox_messages_pending_idx on doctor.outbox_messages (id) where published_at is null;

alter table doctor.raw_log_objects enable row level security;
alter table doctor.imports enable row level security;
alter table doctor.outbox_messages enable row level security;

-- Escrita só pelas funções abaixo (e pelos workers, com service_role).
revoke all on doctor.raw_log_objects, doctor.imports, doctor.outbox_messages from anon, authenticated;
grant select on doctor.imports to authenticated;
grant select on doctor.raw_log_objects to authenticated;

create policy imports_select on doctor.imports
for select to authenticated
using (tenant_id = (select doctor.current_tenant_id()));

create policy raw_log_objects_select on doctor.raw_log_objects
for select to authenticated
using (
  tenant_id = (select doctor.current_tenant_id())
  and (select doctor.has_member_role('owner', 'admin', 'analyst'))
);

-- Caminho do objeto no bucket: o nome original fica só no banco. Assim nenhum caractere do nome
-- (acento, espaço) chega à chave do Storage, e o caminho é montado num lugar só.
create function doctor.import_storage_path(tenant uuid, import_id uuid, format text)
returns text
language sql
immutable
set search_path = ''
as $$
  select tenant || '/imports/' || import_id || '/upload.' || format
$$;

grant execute on function doctor.import_storage_path(uuid, uuid, text) to authenticated;

-- security definer: cria a Importação conferindo Papel (da tabela), Integração ativa, formato,
-- tamanho e duplicidade. Formato e tamanho errados viram Importação `rejected`, com o motivo,
-- para o histórico mostrar a tentativa. A pendente já nasce com Log bruto que vence em 1 dia:
-- se o upload nunca for concluído, a retenção (ticket #29) apaga o que tiver chegado ao bucket.
create function doctor.create_import(integration_id uuid, filename text, size_bytes bigint, sha256 text)
returns table (id uuid, status text, format text, error text, duplicate_of uuid)
language plpgsql
security definer
set search_path = ''
as $$
declare
  tenant uuid := doctor.current_tenant_id();
  extension text := lower(substring(create_import.filename from '\.([A-Za-z0-9]+)$'));
  detected text;
  reason text;
  previous uuid;
  new_id uuid := gen_random_uuid();
  raw_id uuid;
begin
  if tenant is null or not doctor.has_member_role('owner', 'admin', 'analyst') then
    raise insufficient_privilege using message = 'Papel não importa logs';
  end if;
  if create_import.filename ~ '[/\\]' or create_import.filename ~ '^\.' or create_import.filename ~ '[[:cntrl:]]' then
    raise invalid_parameter_value using message = 'nome de arquivo inválido';
  end if;
  if not exists (
    select 1 from doctor.integrations i
    where i.id = create_import.integration_id and i.tenant_id = tenant and i.archived_at is null
  ) then
    raise no_data_found using message = 'Integração não encontrada';
  end if;

  if extension in ('json', 'ndjson', 'csv') then
    detected := extension;
  else
    reason := 'Formato não permitido';
  end if;
  if reason is null and create_import.size_bytes = 0 then
    reason := 'Arquivo vazio';
  end if;
  if reason is null and create_import.size_bytes > 52428800 then
    reason := 'Arquivo acima de 50 MB';
  end if;
  if reason is null then
    previous := doctor.imported_before(tenant, create_import.integration_id, create_import.sha256);
    if previous is not null then
      reason := 'Arquivo já importado nesta Integração';
    end if;
  end if;

  if reason is null then
    insert into doctor.raw_log_objects (tenant_id, storage_path, sha256, size_bytes, source, expires_at)
    values (
      tenant, doctor.import_storage_path(tenant, new_id, detected), create_import.sha256,
      create_import.size_bytes, 'import', now() + interval '1 day'
    )
    returning raw_log_objects.id into raw_id;
  end if;

  insert into doctor.imports (
    id, tenant_id, integration_id, raw_log_object_id, filename, size_bytes, sha256, format,
    status, error, duplicate_of
  )
  values (
    new_id, tenant, create_import.integration_id, raw_id, create_import.filename,
    create_import.size_bytes, create_import.sha256, detected,
    case when reason is null then 'pending' else 'rejected' end, reason, previous
  );

  return query
  select i.id, i.status, i.format, i.error, i.duplicate_of from doctor.imports i where i.id = new_id;
end;
$$;

-- A primeira Importação, já recebida, do mesmo arquivo na mesma Integração. A trava serializa
-- duas Importações do mesmo arquivo (duas abas, clique duplo) até o fim da transação.
create function doctor.imported_before(tenant uuid, integration uuid, sha text)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  previous uuid;
begin
  perform pg_advisory_xact_lock(hashtextextended(tenant::text || integration::text || sha, 0));
  select i.id into previous from doctor.imports i
  where i.tenant_id = tenant and i.integration_id = integration and i.sha256 = sha
    and i.status in ('uploaded', 'processing', 'done')
  order by i.created_at
  limit 1;
  return previous;
end;
$$;

revoke all on function doctor.imported_before(uuid, uuid, text) from public, authenticated, service_role;

-- Encerra uma pendente: `uploaded` (Log bruto passa a valer 30 dias e a mensagem vai para a
-- outbox) ou `rejected` (Log bruto vence já, para a retenção apagar). Mesma transação sempre.
create function doctor.finish_import(target uuid, stored_size bigint, reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  tenant uuid := doctor.current_tenant_id();
  pending_import doctor.imports;
  previous uuid;
begin
  if tenant is null or not doctor.has_member_role('owner', 'admin', 'analyst') then
    raise insufficient_privilege using message = 'Papel não importa logs';
  end if;
  select * into pending_import from doctor.imports i where i.id = target and i.tenant_id = tenant for update;
  if not found then
    raise no_data_found using message = 'Importação não encontrada';
  end if;
  if pending_import.status <> 'pending' then
    raise exception 'Importação não está pendente' using errcode = 'DR005';
  end if;
  if reason is null then
    -- De novo aqui: outra Importação do mesmo arquivo pode ter sido recebida enquanto esta subia.
    previous := doctor.imported_before(tenant, pending_import.integration_id, pending_import.sha256);
    if previous is not null then
      reason := 'Arquivo já importado nesta Integração';
    end if;
  end if;

  update doctor.raw_log_objects
  set size_bytes = least(stored_size, 52428800),
      expires_at = case when reason is null then now() + interval '30 days' else now() end
  where id = pending_import.raw_log_object_id;

  update doctor.imports
  set status = case when reason is null then 'uploaded' else 'rejected' end,
      error = left(reason, 500),
      duplicate_of = previous,
      size_bytes = stored_size
  where id = pending_import.id;

  if reason is null then
    insert into doctor.outbox_messages (tenant_id, topic, payload)
    values (
      tenant, 'ingestion.raw',
      jsonb_build_object(
        'import_id', pending_import.id,
        'raw_log_object_id', pending_import.raw_log_object_id,
        'storage_path', doctor.import_storage_path(tenant, pending_import.id, pending_import.format)
      )
    );
  end if;
end;
$$;

revoke all on function doctor.create_import(uuid, text, bigint, text) from public, service_role;
revoke all on function doctor.finish_import(uuid, bigint, text) from public, service_role;
grant execute on function doctor.create_import(uuid, text, bigint, text) to authenticated;
grant execute on function doctor.finish_import(uuid, bigint, text) to authenticated;

-- Bucket privado do Doctor no Storage, que é do projeto inteiro (ADR-0009): nome com prefixo e
-- políticas restritas a ele, sem efeito nos buckets do jayv-coder.
insert into storage.buckets (id, name, public, file_size_limit)
values ('doctor-raw-logs', 'doctor-raw-logs', false, 52428800)
on conflict (id) do nothing;

-- Sobe só quem importa, só na pasta da Organização ativa e só no caminho de uma Importação
-- pendente dela.
create policy doctor_raw_logs_insert on storage.objects
for insert to authenticated
with check (
  bucket_id = 'doctor-raw-logs'
  and (storage.foldername(name))[1] = (select doctor.current_tenant_id())::text
  and (select doctor.has_member_role('owner', 'admin', 'analyst'))
  and exists (
    select 1 from doctor.imports i
    where i.tenant_id = (select doctor.current_tenant_id())
      and i.status = 'pending'
      and name = doctor.import_storage_path(i.tenant_id, i.id, i.format)
  )
);

-- Lê (a API confere o conteúdo ao concluir) só quem importa, na pasta da Organização ativa.
create policy doctor_raw_logs_select on storage.objects
for select to authenticated
using (
  bucket_id = 'doctor-raw-logs'
  and (storage.foldername(name))[1] = (select doctor.current_tenant_id())::text
  and (select doctor.has_member_role('owner', 'admin', 'analyst'))
);

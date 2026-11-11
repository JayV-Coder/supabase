-- Base de conhecimento (ticket #23): documentos da Organização e Base global curada, em
-- Fragmentos com embedding (pgvector) e texto em português (tsvector) para a busca híbrida.
-- No projeto compartilhado, criar a extensão exige aprovação na janela combinada (ADR-0009).
create extension if not exists vector with schema extensions;

create table doctor.knowledge_documents (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references doctor.tenants (id) on delete cascade,
  title text not null check (char_length(btrim(title)) between 1 and 200),
  source text not null check (source in ('upload', 'incident')),
  -- Documento enviado: o arquivo no bucket doctor-knowledge; Incidente resolvido (#26): sem arquivo.
  storage_path text check (storage_path is null or split_part(storage_path, '/', 1) = tenant_id::text),
  incident_id uuid,
  content_type text check (content_type in (
    'application/pdf', 'text/markdown', 'text/plain',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document'
  )),
  size_bytes bigint check (size_bytes between 0 and 20971520),
  status text not null default 'pending' check (status in ('pending', 'indexing', 'ready', 'failed')),
  chunk_count integer not null default 0 check (chunk_count >= 0),
  embedding_model text,
  -- Reindexação pedida (troca de provedor ou indexação que não terminou): o documento segue
  -- `ready` e achável pelo texto até os Fragmentos novos chegarem.
  reindex_queued_at timestamptz,
  error text check (char_length(error) <= 500),
  created_by uuid default auth.uid() references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, id),
  foreign key (tenant_id, incident_id) references doctor.incidents (tenant_id, id) on delete set null (incident_id),
  check ((source = 'upload') = (storage_path is not null))
);
comment on table doctor.knowledge_documents is 'Documento da Base de conhecimento de uma Organização.';
create index knowledge_documents_tenant_idx on doctor.knowledge_documents (tenant_id, created_at desc);

create trigger knowledge_documents_set_updated_at
before update on doctor.knowledge_documents
for each row execute function doctor.set_updated_at();

create table doctor.knowledge_chunks (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references doctor.tenants (id) on delete cascade,
  document_id uuid not null,
  ordinal integer not null check (ordinal >= 0),
  content text not null,
  tokens integer not null check (tokens > 0),
  heading text,
  -- Sem dimensão fixa: cada modelo tem a sua (voyage-3 = 1024, text-embedding-005 = 768). A
  -- busca filtra pelo modelo, e o índice HNSW é parcial, por modelo: dimensões nunca se misturam.
  embedding extensions.vector,
  embedding_model text,
  metadata jsonb not null default '{}' check (jsonb_typeof(metadata) = 'object'),
  search_text tsvector generated always as (to_tsvector('portuguese', coalesce(heading, '') || ' ' || content)) stored,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, document_id, ordinal),
  foreign key (tenant_id, document_id) references doctor.knowledge_documents (tenant_id, id) on delete cascade,
  check ((embedding is null) = (embedding_model is null))
);
comment on table doctor.knowledge_chunks is 'Fragmento de um documento da Base de conhecimento, com embedding e texto indexado.';
create index knowledge_chunks_tenant_idx on doctor.knowledge_chunks (tenant_id, document_id);
create index knowledge_chunks_text_idx on doctor.knowledge_chunks using gin (search_text);
create index knowledge_chunks_voyage_idx on doctor.knowledge_chunks
  using hnsw ((embedding::extensions.vector(1024)) extensions.vector_cosine_ops)
  where embedding_model = 'voyage-3';
create index knowledge_chunks_vertex_idx on doctor.knowledge_chunks
  using hnsw ((embedding::extensions.vector(768)) extensions.vector_cosine_ops)
  where embedding_model = 'text-embedding-005';

create trigger knowledge_chunks_set_updated_at
before update on doctor.knowledge_chunks
for each row execute function doctor.set_updated_at();

-- Base global: a mesma forma, sem tenant. Todo autenticado lê; escrita só por migração ou seed.
create table doctor.global_knowledge_documents (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique check (slug ~ '^[a-z0-9-]{3,80}$'),
  title text not null check (char_length(btrim(title)) between 1 and 200),
  version text not null,
  chunk_count integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
comment on table doctor.global_knowledge_documents is 'Documento da Base global curada (comum a todas as Organizações).';

create table doctor.global_knowledge_chunks (
  id uuid primary key default gen_random_uuid(),
  document_id uuid not null references doctor.global_knowledge_documents (id) on delete cascade,
  ordinal integer not null check (ordinal >= 0),
  content text not null,
  tokens integer not null check (tokens > 0),
  heading text,
  embedding extensions.vector,
  embedding_model text,
  metadata jsonb not null default '{}' check (jsonb_typeof(metadata) = 'object'),
  search_text tsvector generated always as (to_tsvector('portuguese', coalesce(heading, '') || ' ' || content)) stored,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (document_id, ordinal),
  check ((embedding is null) = (embedding_model is null))
);
comment on table doctor.global_knowledge_chunks is 'Fragmento da Base global.';
create index global_knowledge_chunks_text_idx on doctor.global_knowledge_chunks using gin (search_text);
create index global_knowledge_chunks_voyage_idx on doctor.global_knowledge_chunks
  using hnsw ((embedding::extensions.vector(1024)) extensions.vector_cosine_ops)
  where embedding_model = 'voyage-3';
create index global_knowledge_chunks_vertex_idx on doctor.global_knowledge_chunks
  using hnsw ((embedding::extensions.vector(768)) extensions.vector_cosine_ops)
  where embedding_model = 'text-embedding-005';

create trigger global_knowledge_documents_set_updated_at
before update on doctor.global_knowledge_documents
for each row execute function doctor.set_updated_at();
create trigger global_knowledge_chunks_set_updated_at
before update on doctor.global_knowledge_chunks
for each row execute function doctor.set_updated_at();

alter table doctor.knowledge_documents enable row level security;
alter table doctor.knowledge_chunks enable row level security;
alter table doctor.global_knowledge_documents enable row level security;
alter table doctor.global_knowledge_chunks enable row level security;
revoke all on doctor.knowledge_documents, doctor.knowledge_chunks,
  doctor.global_knowledge_documents, doctor.global_knowledge_chunks from anon, authenticated;
grant select on doctor.knowledge_documents, doctor.knowledge_chunks,
  doctor.global_knowledge_documents, doctor.global_knowledge_chunks to authenticated;

create policy knowledge_documents_select on doctor.knowledge_documents
for select to authenticated using (tenant_id = (select doctor.current_tenant_id()));
create policy knowledge_chunks_select on doctor.knowledge_chunks
for select to authenticated using (tenant_id = (select doctor.current_tenant_id()));
create policy global_knowledge_documents_select on doctor.global_knowledge_documents
for select to authenticated using (true);
create policy global_knowledge_chunks_select on doctor.global_knowledge_chunks
for select to authenticated using (true);

-- Bucket privado do Doctor para os documentos, com política só nele (o jayv-coder tem os seus).
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('doctor-knowledge', 'doctor-knowledge', false, 20971520, array[
  'application/pdf', 'text/markdown', 'text/plain',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document'
])
on conflict (id) do nothing;

-- Sobe só Analyst ou acima, na pasta da Organização ativa e no caminho de um documento pendente.
create policy doctor_knowledge_insert on storage.objects
for insert to authenticated
with check (
  bucket_id = 'doctor-knowledge'
  and (storage.foldername(name))[1] = (select doctor.current_tenant_id())::text
  and (select doctor.has_member_role('owner', 'admin', 'analyst'))
  and exists (
    select 1 from doctor.knowledge_documents d
    where d.tenant_id = (select doctor.current_tenant_id())
      and d.status = 'pending' and d.storage_path = name
  )
);

-- Ler (para baixar o original) e apagar (junto com o documento): Analyst ou acima, só na pasta
-- da Organização ativa.
create policy doctor_knowledge_select on storage.objects
for select to authenticated
using (
  bucket_id = 'doctor-knowledge'
  and (storage.foldername(name))[1] = (select doctor.current_tenant_id())::text
  and (select doctor.has_member_role('owner', 'admin', 'analyst'))
);

create policy doctor_knowledge_delete on storage.objects
for delete to authenticated
using (
  bucket_id = 'doctor-knowledge'
  and (storage.foldername(name))[1] = (select doctor.current_tenant_id())::text
  and (select doctor.has_member_role('owner', 'admin', 'analyst'))
);

-- Documento novo: Analyst ou acima; o caminho no Storage sai do tenant da claim, do id e do
-- formato. O nome do arquivo fica fora da chave: o Storage recusa acento e símbolos nela, e o
-- título já guarda o nome para a tela.
create function doctor.create_knowledge_document(title text, filename text, content_type text, size_bytes bigint)
returns table (id uuid, storage_path text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  tenant uuid := doctor.current_tenant_id();
  new_id uuid := gen_random_uuid();
  path text;
begin
  if not doctor.has_member_role('owner', 'admin', 'analyst') then
    raise insufficient_privilege using message = 'exige Analyst ou acima';
  end if;
  if filename !~ '^[^/\\]{1,200}$' then
    raise exception 'nome de arquivo inválido' using errcode = '22023';
  end if;
  path := tenant::text || '/' || new_id::text || '/document.' || case create_knowledge_document.content_type
    when 'application/pdf' then 'pdf'
    when 'text/markdown' then 'md'
    when 'text/plain' then 'txt'
    else 'docx'
  end;
  insert into doctor.knowledge_documents (id, tenant_id, title, source, storage_path, content_type, size_bytes)
  values (new_id, tenant, btrim(create_knowledge_document.title), 'upload', path,
    create_knowledge_document.content_type, create_knowledge_document.size_bytes);
  return query select new_id, path;
end;
$$;

-- Upload concluído: o worker de diagnóstico indexa (extração, Sanitização, Fragmentos, embedding).
create function doctor.finish_knowledge_upload(target uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  tenant uuid := doctor.current_tenant_id();
begin
  if not doctor.has_member_role('owner', 'admin', 'analyst') then
    raise insufficient_privilege using message = 'exige Analyst ou acima';
  end if;
  update doctor.knowledge_documents d set status = 'indexing'
  where d.tenant_id = tenant and d.id = target and d.status = 'pending';
  if not found then
    raise no_data_found using message = 'Documento pendente não encontrado';
  end if;
  insert into doctor.outbox_messages (tenant_id, topic, payload)
  values (tenant, 'knowledge.index', jsonb_build_object('document_id', target));
end;
$$;

-- Remover leva os Fragmentos junto (cascade); o arquivo sai do Storage pela API.
create function doctor.delete_knowledge_document(target uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  tenant uuid := doctor.current_tenant_id();
  path text;
begin
  if not doctor.has_member_role('owner', 'admin', 'analyst') then
    raise insufficient_privilege using message = 'exige Analyst ou acima';
  end if;
  delete from doctor.knowledge_documents d where d.tenant_id = tenant and d.id = target
  returning d.storage_path into path;
  if not found then
    raise no_data_found using message = 'Documento não encontrado';
  end if;
  perform doctor.record_audit(tenant, 'knowledge.deleted', target::text);
  return path;
end;
$$;

revoke all on function doctor.create_knowledge_document(text, text, text, bigint) from public, service_role;
revoke all on function doctor.finish_knowledge_upload(uuid) from public, service_role;
revoke all on function doctor.delete_knowledge_document(uuid) from public, service_role;
grant execute on function doctor.create_knowledge_document(text, text, text, bigint) to authenticated;
grant execute on function doctor.finish_knowledge_upload(uuid) to authenticated;
grant execute on function doctor.delete_knowledge_document(uuid) to authenticated;

-- Ticket #7: respostas gravadas por `Idempotency-Key`, por Usuário. A limpeza é preguiçosa, na própria
-- API: um job no pg_cron do projeto compartilhado afetaria o agendador do jayv-coder.
create table doctor.idempotency_keys (
  id uuid not null default gen_random_uuid(),
  tenant_id uuid not null references doctor.tenants (id) on delete cascade,
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  key text not null check (char_length(key) between 1 and 255),
  request_hash text not null,
  response_status integer,
  response_body text,
  created_at timestamptz not null default now(),
  primary key (tenant_id, user_id, key),
  unique (tenant_id, id)
);
comment on table doctor.idempotency_keys is 'Resposta de escritas repetidas com a mesma chave, por 24 h.';

create index idempotency_keys_tenant_id_created_at_idx on doctor.idempotency_keys (tenant_id, created_at);

alter table doctor.idempotency_keys enable row level security;

revoke all on doctor.idempotency_keys from anon, authenticated;
grant select, insert, delete on doctor.idempotency_keys to authenticated;
grant update (response_status, response_body) on doctor.idempotency_keys to authenticated;

-- Cada pessoa só vê as próprias chaves: a resposta gravada pode ter dados que outro Papel não veria.
create policy idempotency_keys_select_own on doctor.idempotency_keys
for select to authenticated
using (tenant_id = (select doctor.current_tenant_id()) and user_id = (select auth.uid()));

create policy idempotency_keys_insert_own on doctor.idempotency_keys
for insert to authenticated
with check (tenant_id = (select doctor.current_tenant_id()) and user_id = (select auth.uid()));

create policy idempotency_keys_update_own on doctor.idempotency_keys
for update to authenticated
using (tenant_id = (select doctor.current_tenant_id()) and user_id = (select auth.uid()))
with check (tenant_id = (select doctor.current_tenant_id()) and user_id = (select auth.uid()));

create policy idempotency_keys_delete_own on doctor.idempotency_keys
for delete to authenticated
using (tenant_id = (select doctor.current_tenant_id()) and user_id = (select auth.uid()));

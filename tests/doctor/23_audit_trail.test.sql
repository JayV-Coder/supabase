begin;
\ir ../helpers/tenancy.psql
select plan(18);

select tests.create_user('00000000-0000-4000-8000-0000000a0001', 'owner@acme.test');
select tests.create_user('00000000-0000-4000-8000-0000000a0002', 'admin@acme.test');
select tests.create_user('00000000-0000-4000-8000-0000000a0003', 'analyst@acme.test');
select tests.create_tenant('00000000-0000-4000-8000-00000000ac01', 'acme');
select tests.create_tenant('00000000-0000-4000-8000-00000000be01', 'varejo');
select tests.add_member('00000000-0000-4000-8000-00000000ac01', '00000000-0000-4000-8000-0000000a0001', 'owner');
select tests.add_member('00000000-0000-4000-8000-00000000ac01', '00000000-0000-4000-8000-0000000a0002', 'admin');
select tests.add_member('00000000-0000-4000-8000-00000000ac01', '00000000-0000-4000-8000-0000000a0003', 'analyst');
select tests.add_member('00000000-0000-4000-8000-00000000be01', '00000000-0000-4000-8000-0000000a0001', 'owner');

-- Mudança de Papel, com a requisição que a API descreve em `doctor.request`.
select set_config('doctor.request', '{"ip": "177.10.0.1", "user_agent": "Mozilla/5.0", "request_id": "req-1"}', true);
select tests.authenticate_as('00000000-0000-4000-8000-0000000a0001', '00000000-0000-4000-8000-00000000ac01', 'owner', 'aal2');
select tests.clear_authentication();
update doctor.memberships set role = 'viewer'
where tenant_id = '00000000-0000-4000-8000-00000000ac01' and user_id = '00000000-0000-4000-8000-0000000a0003';
select results_eq(
  $$select before, after, host(ip), user_agent, request_id from doctor.audit_logs
    where tenant_id = '00000000-0000-4000-8000-00000000ac01' and action = 'membership.role_changed'$$,
  $$values ('{"role": "analyst"}'::jsonb, '{"role": "viewer"}'::jsonb, '177.10.0.1'::text,
            'Mozilla/5.0'::text, 'req-1'::text)$$,
  'mudança de Papel tem before e after, com IP, user agent e request id'
);

insert into doctor.invitations (tenant_id, email, role, token_hash, invited_by)
values ('00000000-0000-4000-8000-00000000ac01', 'pessoa@cliente.com.br', 'viewer', repeat('e', 64),
  '00000000-0000-4000-8000-0000000a0001');
select is(
  (select (after ? 'email') or (after ? 'token_hash') or after::text like '%pessoa@cliente%'
   from doctor.audit_logs where tenant_id = '00000000-0000-4000-8000-00000000ac01' and action = 'invitation.created'),
  false, 'convite auditado sem o e-mail do convidado nem o hash do token'
);

insert into doctor.integrations (id, tenant_id, name, source_system, target_system, environment)
values ('00000000-0000-4000-8000-0000000001a1', '00000000-0000-4000-8000-00000000ac01', 'Pedidos', 'salesforce', 'sap', 'prd');
update doctor.integrations set description = description where id = '00000000-0000-4000-8000-0000000001a1';
select is(
  (select count(*)::int from doctor.audit_logs where tenant_id = '00000000-0000-4000-8000-00000000ac01' and action like 'integration.%'),
  1, 'update sem mudança não gera registro'
);

select tests.authenticate_as('00000000-0000-4000-8000-0000000a0001', '00000000-0000-4000-8000-00000000ac01', 'owner', 'aal2');
select doctor.switch_organization('00000000-0000-4000-8000-00000000be01');
select tests.clear_authentication();
select results_eq(
  $$select tenant_id, actor_type, actor_id from doctor.audit_logs
    where tenant_id = '00000000-0000-4000-8000-00000000be01' and action = 'org.switched'$$,
  $$values ('00000000-0000-4000-8000-00000000be01'::uuid, 'user'::text,
            '00000000-0000-4000-8000-0000000a0001'::uuid)$$,
  'troca de Organização auditada na de destino'
);

-- Como as funções do worker: security definer chamada pelo service_role.
create function pg_temp.worker_action() returns void language sql security definer as $$
  select doctor.record_audit('00000000-0000-4000-8000-00000000ac01', 'connector.sync', 'c1')
$$;
grant execute on function pg_temp.worker_action() to service_role;
set local role service_role;
select pg_temp.worker_action();
reset role;
select is(
  (select actor_type from doctor.audit_logs where tenant_id = '00000000-0000-4000-8000-00000000ac01' and action = 'connector.sync'),
  'worker', 'o worker (service_role) aparece como worker'
);

-- Append-only para todos, até o postgres; delete só com a retenção ligada.
select throws_ok(
  $$update doctor.audit_logs set action = 'x.y' where tenant_id = '00000000-0000-4000-8000-00000000ac01' and action = 'connector.sync'$$,
  'DR030', null, 'ninguém altera a auditoria'
);
select throws_ok(
  $$delete from doctor.audit_logs where tenant_id = '00000000-0000-4000-8000-00000000ac01' and action = 'connector.sync'$$,
  'DR030', null, 'nem apaga fora da retenção'
);
set local role service_role;
select throws_ok(
  $$delete from doctor.audit_logs where tenant_id = '00000000-0000-4000-8000-00000000ac01' and action = 'connector.sync'$$,
  '42501', null, 'o worker não tem delete'
);
reset role;
select set_config('doctor.retention', 'on', true);
delete from doctor.audit_logs where tenant_id = '00000000-0000-4000-8000-00000000ac01' and action = 'connector.sync';
select set_config('doctor.retention', 'off', true);
select is((select count(*)::int from doctor.audit_logs where tenant_id = '00000000-0000-4000-8000-00000000ac01' and action = 'connector.sync'), 0,
  'a retenção apaga');

-- Leitura: Owner e Admin com MFA, só da Organização ativa.
select tests.authenticate_as('00000000-0000-4000-8000-0000000a0001', '00000000-0000-4000-8000-00000000ac01', 'owner', 'aal2');
select ok((select count(*) from doctor.audit_logs) > 0
  and not exists (select 1 from doctor.audit_logs where tenant_id <> '00000000-0000-4000-8000-00000000ac01'),
  'Owner com MFA lê só a Organização ativa');
select throws_ok(
  $$update doctor.audit_logs set action = 'x.y'$$, '42501', null, 'cliente não altera'
);
select tests.clear_authentication();
select tests.authenticate_as('00000000-0000-4000-8000-0000000a0002', '00000000-0000-4000-8000-00000000ac01', 'admin', 'aal1');
select is((select count(*)::int from doctor.audit_logs), 0, 'Admin sem MFA não lê');
select tests.clear_authentication();

-- Eventos do Supabase Auth, uma vez por Organização do Usuário.
insert into auth.audit_log_entries (instance_id, id, payload, created_at, ip_address)
values ('00000000-0000-0000-0000-000000000000', '00000000-0000-4000-8000-00000000e001',
  '{"action": "login", "actor_id": "00000000-0000-4000-8000-0000000a0001", "actor_username": "owner@acme.test"}',
  now(), '177.10.0.9');
select is(doctor.import_auth_events(now() - interval '1 hour'), 2, 'login entra nas 2 Organizações do Usuário');
select is(doctor.import_auth_events(now() - interval '1 hour'), 0, 'e não se repete');

delete from doctor.tenants where id = '00000000-0000-4000-8000-00000000be01';
select is((select count(*)::int from doctor.audit_logs where tenant_id = '00000000-0000-4000-8000-00000000be01'),
  0, 'excluir a Organização leva a auditoria dela junto');

-- Partições: nenhum papel chega nelas direto (o TRUNCATE furaria o append-only).
select is(
  (select array_agg(c.relname::text order by c.relname) from pg_class c
   where c.relnamespace = 'doctor'::regnamespace and c.relispartition
     and c.relname like 'audit_logs_%'
     and (has_table_privilege('service_role', c.oid, 'truncate')
          or has_table_privilege('service_role', c.oid, 'delete')
          or has_table_privilege('service_role', c.oid, 'update')
          or has_table_privilege('authenticated', c.oid, 'select'))),
  null, 'partições da auditoria sem privilégio direto para ninguém'
);
select isnt(doctor.ensure_audit_partition('2028-03-10'), null, 'o job cria a partição de um mês novo');
select is(
  (select has_table_privilege('service_role', 'doctor.audit_logs_2028_03', 'truncate')), false,
  'e ela também nasce trancada'
);

select * from finish();
rollback;

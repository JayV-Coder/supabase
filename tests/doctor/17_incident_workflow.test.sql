begin;
\ir ../helpers/tenancy.psql
select plan(16);

select tests.create_user('00000000-0000-4000-8000-0000000a0001', 'ana@acme.test');
select tests.create_user('00000000-0000-4000-8000-0000000a0002', 'vera@acme.test');
select tests.create_user('00000000-0000-4000-8000-0000000b0001', 'bruno@varejo.test');
select tests.create_tenant('00000000-0000-4000-8000-00000000ac01', 'acme');
select tests.create_tenant('00000000-0000-4000-8000-00000000be01', 'varejo');
select tests.add_member('00000000-0000-4000-8000-00000000ac01', '00000000-0000-4000-8000-0000000a0001', 'analyst');
select tests.add_member('00000000-0000-4000-8000-00000000ac01', '00000000-0000-4000-8000-0000000a0002', 'viewer');
select tests.add_member('00000000-0000-4000-8000-00000000be01', '00000000-0000-4000-8000-0000000b0001', 'owner');
insert into doctor.integrations (id, tenant_id, name, source_system, target_system, environment)
values
  ('00000000-0000-4000-8000-0000000001a1', '00000000-0000-4000-8000-00000000ac01', 'Pedidos', 'salesforce', 'sap', 'prd'),
  ('00000000-0000-4000-8000-0000000001b1', '00000000-0000-4000-8000-00000000be01', 'Notas', 'sap', 'gcp', 'prd');

create function tests.incident(id uuid, tenant uuid, integration uuid) returns void language sql as $$
  insert into doctor.incidents (id, tenant_id, integration_id, title, category, severity, rule_code,
    rule_version, first_seen_at, last_seen_at, execution_count)
  values (id, tenant, integration, 'Timeout', 'TIMEOUT', 'high', 'INT-003', '2026.10.1', now(), now(), 1)
$$;
select tests.incident('00000000-0000-4000-8000-0000000005a1', '00000000-0000-4000-8000-00000000ac01', '00000000-0000-4000-8000-0000000001a1');
select tests.incident('00000000-0000-4000-8000-0000000005a2', '00000000-0000-4000-8000-00000000ac01', '00000000-0000-4000-8000-0000000001a1');
select tests.incident('00000000-0000-4000-8000-0000000005b1', '00000000-0000-4000-8000-00000000be01', '00000000-0000-4000-8000-0000000001b1');

select results_eq(
  $$select number from doctor.incidents
    where tenant_id in ('00000000-0000-4000-8000-00000000ac01', '00000000-0000-4000-8000-00000000be01')
    order by tenant_id, number$$,
  $$values (1), (2), (1)$$,
  'número sequencial por Organização'
);

select throws_ok(
  $$update doctor.incidents set status = 'resolved' where id = '00000000-0000-4000-8000-0000000005a1'$$,
  '23514', null, 'resolver exige nota de resolução'
);
update doctor.incidents set status = 'resolved', resolution_note = 'Gateway ajustado.'
where id = '00000000-0000-4000-8000-0000000005a1';
select isnt(
  (select resolved_at from doctor.incidents where id = '00000000-0000-4000-8000-0000000005a1'), null,
  'resolver marca resolved_at'
);
select throws_ok(
  $$update doctor.incidents set status = 'investigating' where id = '00000000-0000-4000-8000-0000000005a1'$$,
  'DR010', null, 'resolvido só volta para aberto'
);
update doctor.incidents set status = 'open' where id = '00000000-0000-4000-8000-0000000005a1';
select is(
  (select resolved_at from doctor.incidents where id = '00000000-0000-4000-8000-0000000005a1'), null,
  'reabrir limpa resolved_at'
);

select tests.authenticate_as('00000000-0000-4000-8000-0000000a0002', '00000000-0000-4000-8000-00000000ac01', 'viewer');
select throws_ok(
  $$select doctor.update_incident('00000000-0000-4000-8000-0000000005a2', 'investigating', null, null, false, null)$$,
  '42501', null, 'Viewer não muda status'
);
select throws_ok(
  $$select doctor.add_incident_comment('00000000-0000-4000-8000-0000000005a2', 'oi', '{}')$$,
  '42501', null, 'Viewer não comenta'
);
select tests.clear_authentication();

select tests.authenticate_as('00000000-0000-4000-8000-0000000a0001', '00000000-0000-4000-8000-00000000ac01', 'analyst');
select lives_ok(
  $$select doctor.update_incident('00000000-0000-4000-8000-0000000005a2', 'investigating', 'critical',
    '00000000-0000-4000-8000-0000000a0001', true, null)$$,
  'Analyst muda status, severidade e responsável'
);
select results_eq(
  $$select action, from_value, to_value from doctor.incident_history
    where incident_id = '00000000-0000-4000-8000-0000000005a2' order by action$$,
  $$values ('assignee'::text, null::text, '00000000-0000-4000-8000-0000000a0001'::text),
    ('severity', 'high', 'critical'), ('status', 'open', 'investigating')$$,
  'cada mudança vai para o histórico'
);
select throws_ok(
  $$select doctor.update_incident('00000000-0000-4000-8000-0000000005a2', null, null,
    '00000000-0000-4000-8000-0000000b0001', true, null)$$,
  'DR011', null, 'responsável tem de ser da Organização'
);
create temporary table commented as
select doctor.add_incident_comment(
  '00000000-0000-4000-8000-0000000005a2', 'Olhando o gateway @vera @bruno',
  array['00000000-0000-4000-8000-0000000a0002', '00000000-0000-4000-8000-0000000b0001']::uuid[]
) as id;
select is(
  (select mentions from doctor.incident_comments where id = (select id from commented)),
  array['00000000-0000-4000-8000-0000000a0002']::uuid[],
  'menção a quem não é da Organização é descartada'
);
select throws_ok(
  $$select doctor.update_incident('00000000-0000-4000-8000-0000000005b1', 'investigating', null, null, false, null)$$,
  'P0002', null, 'Incidente de outra Organização não existe para ela'
);
select tests.clear_authentication();

insert into doctor.incident_comments (tenant_id, incident_id, body_md)
values ('00000000-0000-4000-8000-00000000be01', '00000000-0000-4000-8000-0000000005b1', 'da varejo');
insert into doctor.incident_history (tenant_id, incident_id, action)
values ('00000000-0000-4000-8000-00000000be01', '00000000-0000-4000-8000-0000000005b1', 'status');
select tests.authenticate_as('00000000-0000-4000-8000-0000000a0001', '00000000-0000-4000-8000-00000000ac01', 'analyst');
select is(
  (select count(*)::int from doctor.incident_comments where tenant_id <> '00000000-0000-4000-8000-00000000ac01'),
  0, 'outra Organização não lê os comentários'
);
select is(
  (select count(*)::int from doctor.incident_history where tenant_id <> '00000000-0000-4000-8000-00000000ac01'),
  0, 'nem o histórico'
);
select tests.clear_authentication();
select throws_ok(
  $$insert into doctor.incident_comments (tenant_id, incident_id, body_md)
    values ('00000000-0000-4000-8000-00000000ac01', '00000000-0000-4000-8000-0000000005b1', 'x')$$,
  '23503', null, 'comentário nunca referencia Incidente de outra Organização'
);

select ok(
  exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'doctor' and tablename = 'incidents'
  ),
  'a lista de Incidentes atualiza em tempo real'
);

select * from finish();
rollback;

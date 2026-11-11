begin;
\ir ../helpers/tenancy.psql
select plan(36);

select has_table('doctor', 'imports', 'tabela doctor.imports existe');
select has_table('doctor', 'raw_log_objects', 'tabela doctor.raw_log_objects existe');
select has_table('doctor', 'outbox_messages', 'tabela doctor.outbox_messages existe');
select is(
  (select bool_and(relrowsecurity) from pg_class
   where oid in ('doctor.imports'::regclass, 'doctor.raw_log_objects'::regclass, 'doctor.outbox_messages'::regclass)),
  true, 'RLS ligado nas três'
);
select is(
  (select public from storage.buckets where id = 'doctor-raw-logs'), false, 'bucket de Logs brutos é privado'
);

select tests.create_user('00000000-0000-4000-8000-0000000a0001', 'ana@acme.test');
select tests.create_user('00000000-0000-4000-8000-0000000a0002', 'vera@acme.test');
select tests.create_user('00000000-0000-4000-8000-0000000b0001', 'bruno@varejo.test');
select tests.create_tenant('00000000-0000-4000-8000-00000000ac01', 'acme');
select tests.create_tenant('00000000-0000-4000-8000-00000000be01', 'varejo');
select tests.add_member('00000000-0000-4000-8000-00000000ac01', '00000000-0000-4000-8000-0000000a0001', 'analyst');
select tests.add_member('00000000-0000-4000-8000-00000000ac01', '00000000-0000-4000-8000-0000000a0002', 'viewer');
select tests.add_member('00000000-0000-4000-8000-00000000be01', '00000000-0000-4000-8000-0000000b0001', 'analyst');

insert into doctor.integrations (id, tenant_id, name, source_system, target_system, environment)
values
  ('00000000-0000-4000-8000-0000000001a1', '00000000-0000-4000-8000-00000000ac01', 'Pedidos', 'salesforce', 'sap', 'prd'),
  ('00000000-0000-4000-8000-0000000001b1', '00000000-0000-4000-8000-00000000be01', 'Notas', 'sap', 'gcp', 'prd');
insert into doctor.integrations (id, tenant_id, name, source_system, target_system, environment, archived_at)
values ('00000000-0000-4000-8000-0000000001a2', '00000000-0000-4000-8000-00000000ac01', 'Velha', 'sap', 'gcp', 'prd', now());

create function tests.sha(seed text) returns text language sql as $$ select encode(sha256(seed::bytea), 'hex') $$;

-- Analyst (sem MFA) importa; o tenant e o caminho no Storage saem do JWT.
select tests.authenticate_as(
  '00000000-0000-4000-8000-0000000a0001', '00000000-0000-4000-8000-00000000ac01', 'analyst'
);
create temporary table created as
select * from doctor.create_import('00000000-0000-4000-8000-0000000001a1', 'sap-orders.ndjson', 1200, tests.sha('a'));
select results_eq(
  $$select c.status, c.format, r.storage_path = '00000000-0000-4000-8000-00000000ac01/imports/' || c.id || '/upload.ndjson',
      r.expires_at < now() + interval '2 days'
    from created c join doctor.imports i on i.id = c.id join doctor.raw_log_objects r on r.id = i.raw_log_object_id$$,
  $$values ('pending'::text, 'ndjson'::text, true, true)$$,
  'pendente nasce com Log bruto no caminho do tenant, vencendo em 1 dia se o upload não terminar'
);
select results_eq(
  $$select status, error from doctor.create_import('00000000-0000-4000-8000-0000000001a1', 'relatório de pedidos.csv', 10, tests.sha('acento'))$$,
  $$values ('pending'::text, null::text)$$,
  'nome com acento e espaço vale: ele não entra na chave do Storage'
);
select results_eq(
  $$select status, error from doctor.create_import('00000000-0000-4000-8000-0000000001a1', 'vazio.csv', 0, tests.sha(''))$$,
  $$values ('rejected'::text, 'Arquivo vazio'::text)$$,
  'arquivo vazio fica rejected'
);
select results_eq(
  $$select status, error from doctor.create_import('00000000-0000-4000-8000-0000000001a1', 'pedidos.xml', 10, tests.sha('x'))$$,
  $$values ('rejected'::text, 'Formato não permitido'::text)$$,
  '.xml fica rejected com "Formato não permitido"'
);
select results_eq(
  $$select status, error from doctor.create_import('00000000-0000-4000-8000-0000000001a1', 'grande.csv', 52428801, tests.sha('g'))$$,
  $$values ('rejected'::text, 'Arquivo acima de 50 MB'::text)$$,
  'acima de 50 MB fica rejected'
);
select throws_ok(
  $$select doctor.create_import('00000000-0000-4000-8000-0000000001b1', 'x.csv', 10, tests.sha('b'))$$,
  'P0002', null, 'Integração de outra Organização não é encontrada'
);
select throws_ok(
  $$select doctor.create_import('00000000-0000-4000-8000-0000000001a2', 'x.csv', 10, tests.sha('c'))$$,
  'P0002', null, 'Integração arquivada não recebe Importação'
);
select throws_ok(
  $$select doctor.create_import('00000000-0000-4000-8000-0000000001a1', '../../etc/passwd.csv', 10, tests.sha('d'))$$,
  '22023', null, 'nome de arquivo com caminho é recusado'
);
select throws_ok(
  $$insert into doctor.imports (integration_id, filename, size_bytes, sha256)
    values ('00000000-0000-4000-8000-0000000001a1', 'a.csv', 1, tests.sha('e'))$$,
  '42501', null, 'sem escrita direta em imports'
);

-- Storage: o objeto só entra na pasta do tenant e de uma Importação pendente dele.
select lives_ok(
  format(
    $$insert into storage.objects (bucket_id, name, owner_id) values ('doctor-raw-logs', %L, auth.uid()::text)$$,
    (select doctor.import_storage_path('00000000-0000-4000-8000-00000000ac01', id, format) from created)
  ),
  'sobe o arquivo no caminho da Importação pendente'
);
select throws_ok(
  $$insert into storage.objects (bucket_id, name) values
    ('doctor-raw-logs', '00000000-0000-4000-8000-00000000be01/imports/00000000-0000-4000-8000-000000000999/x.csv')$$,
  '42501', null, 'não sobe na pasta de outra Organização'
);
select throws_ok(
  $$insert into storage.objects (bucket_id, name) values
    ('doctor-raw-logs', '00000000-0000-4000-8000-00000000ac01/imports/00000000-0000-4000-8000-000000000999/x.csv')$$,
  '42501', null, 'não sobe sem Importação pendente'
);

-- Concluir: Log bruto registrado, mensagem na outbox, tudo numa transação.
select lives_ok(
  format($$select doctor.finish_import(%L, 1200, null)$$, (select id from created)),
  'conclui o upload'
);
select results_eq(
  $$select i.status, r.source, r.size_bytes::int, r.expires_at > now() + interval '29 days'
    from doctor.imports i join doctor.raw_log_objects r on r.id = i.raw_log_object_id
    where i.id = (select id from created)$$,
  $$values ('uploaded'::text, 'import'::text, 1200, true)$$,
  'Importação uploaded aponta para o Log bruto, que expira em 30 dias'
);
select throws_ok(
  format($$select doctor.finish_import(%L, 1200, null)$$, (select id from created)),
  'DR005', null, 'concluir de novo é recusado'
);
select throws_ok(
  format($$select doctor.finish_import(%L, 1200, 'Conteúdo não corresponde ao formato')$$, (select id from created)),
  'DR005', null, 'recusar depois de concluída também é recusado, com o mesmo erro'
);
select throws_ok($$select 1 from doctor.outbox_messages$$, '42501', null, 'a outbox não é lida pelo cliente');
select tests.clear_authentication();
select results_eq(
  $$select topic, tenant_id::text, payload ->> 'import_id' from doctor.outbox_messages
    where payload ->> 'import_id' = (select id::text from created)$$,
  format($$values ('ingestion.raw'::text, '00000000-0000-4000-8000-00000000ac01'::text, %L::text)$$, (select id from created)),
  'mensagem ingestion.raw na outbox, com o tenant da Importação'
);

-- Mesmo arquivo de novo na mesma Integração: marcada como duplicada, sem upload.
select tests.authenticate_as(
  '00000000-0000-4000-8000-0000000a0001', '00000000-0000-4000-8000-00000000ac01', 'analyst'
);
select results_eq(
  format(
    $$select status, duplicate_of::text, error from doctor.create_import('00000000-0000-4000-8000-0000000001a1', 'copia.ndjson', 1200, %L)$$,
    tests.sha('a')
  ),
  format($$values ('rejected'::text, %L::text, 'Arquivo já importado nesta Integração'::text)$$, (select id from created)),
  'mesmo sha256 na mesma Integração vira duplicada'
);
-- Mesmo arquivo em duas abas: as duas ficam pendentes; a segunda a concluir vira duplicada.
create temporary table twins as
select 1 as n, * from doctor.create_import('00000000-0000-4000-8000-0000000001a1', 'aba1.ndjson', 30, tests.sha('par'))
union all
select 2, * from doctor.create_import('00000000-0000-4000-8000-0000000001a1', 'aba2.ndjson', 30, tests.sha('par'));
select doctor.finish_import((select id from twins where n = 1), 30, null);
select doctor.finish_import((select id from twins where n = 2), 30, null);
select results_eq(
  $$select i.status, i.duplicate_of = (select id from twins where n = 1), r.expires_at <= now()
    from doctor.imports i join doctor.raw_log_objects r on r.id = i.raw_log_object_id
    where i.id = (select id from twins where n = 2)$$,
  $$values ('rejected'::text, true, true)$$,
  'a segunda do mesmo arquivo vira duplicada ao concluir, sem segunda mensagem na outbox'
);
select is(
  (select count(*)::int from doctor.imports), 8, 'o Analyst vê as Importações da Organização'
);

-- Conteúdo errado depois do upload: recusada, e o objeto vira Log bruto vencido para a retenção.
create temporary table wrong as
select * from doctor.create_import('00000000-0000-4000-8000-0000000001a1', 'imagem.csv', 16, tests.sha('png'));
select lives_ok(
  format($$select doctor.finish_import(%L, 16, 'Conteúdo não corresponde ao formato')$$, (select id from wrong)),
  'recusa pelo conteúdo'
);
select results_eq(
  $$select i.status, r.expires_at <= now() from doctor.imports i
    join doctor.raw_log_objects r on r.id = i.raw_log_object_id where i.filename = 'imagem.csv'$$,
  $$values ('rejected'::text, true)$$,
  'o arquivo recusado fica registrado e já vencido'
);

-- Viewer lê, mas não importa nem baixa o Log bruto.
select tests.authenticate_as(
  '00000000-0000-4000-8000-0000000a0002', '00000000-0000-4000-8000-00000000ac01', 'viewer'
);
select is((select count(*)::int from doctor.imports), 9, 'Viewer vê as Importações');
select throws_ok(
  $$select doctor.create_import('00000000-0000-4000-8000-0000000001a1', 'v.csv', 10, tests.sha('v'))$$,
  '42501', null, 'Viewer não importa'
);
select is_empty(
  $$select 1 from storage.objects where bucket_id = 'doctor-raw-logs'$$, 'Viewer não lê o Log bruto'
);

-- Claim de Papel atrasada não vale: o Papel é o da tabela.
select tests.authenticate_as(
  '00000000-0000-4000-8000-0000000a0002', '00000000-0000-4000-8000-00000000ac01', 'analyst'
);
select throws_ok(
  $$select doctor.create_import('00000000-0000-4000-8000-0000000001a1', 'v.csv', 10, tests.sha('v'))$$,
  '42501', null, 'claim de Analyst não basta para quem é Viewer'
);

-- Outra Organização não vê Importações nem o Log bruto, nem conclui a Importação alheia.
select tests.authenticate_as(
  '00000000-0000-4000-8000-0000000b0001', '00000000-0000-4000-8000-00000000be01', 'analyst'
);
select is_empty($$select 1 from doctor.imports$$, 'outra Organização não vê Importações');
select is_empty($$select 1 from doctor.raw_log_objects$$, 'outra Organização não vê Logs brutos');
select is_empty(
  $$select 1 from storage.objects where bucket_id = 'doctor-raw-logs'$$, 'outra Organização não lê o objeto'
);
select throws_ok(
  format($$select doctor.finish_import(%L, 1200, null)$$, (select id from created)),
  'P0002', null, 'outra Organização não conclui a Importação'
);
select tests.clear_authentication();

select * from finish();
rollback;

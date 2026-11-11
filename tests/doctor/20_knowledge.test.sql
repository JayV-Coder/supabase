begin;
\ir ../helpers/tenancy.psql
select plan(9);

select tests.create_user('00000000-0000-4000-8000-0000000a0001', 'ana@acme.test');
select tests.create_user('00000000-0000-4000-8000-0000000a0002', 'vera@acme.test');
select tests.create_tenant('00000000-0000-4000-8000-00000000ac01', 'acme');
select tests.create_tenant('00000000-0000-4000-8000-00000000be01', 'varejo');
select tests.add_member('00000000-0000-4000-8000-00000000ac01', '00000000-0000-4000-8000-0000000a0001', 'analyst');
select tests.add_member('00000000-0000-4000-8000-00000000ac01', '00000000-0000-4000-8000-0000000a0002', 'viewer');
insert into doctor.knowledge_documents (id, tenant_id, title, source, storage_path, content_type, size_bytes, status)
values ('00000000-0000-4000-8000-0000000007b1', '00000000-0000-4000-8000-00000000be01', 'Runbook B', 'upload',
  '00000000-0000-4000-8000-00000000be01/x/runbook.md', 'text/markdown', 10, 'ready');
insert into doctor.knowledge_chunks (tenant_id, document_id, ordinal, content, tokens)
values ('00000000-0000-4000-8000-00000000be01', '00000000-0000-4000-8000-0000000007b1', 0, 'VL10 bloqueado', 5);
insert into doctor.global_knowledge_documents (id, slug, title, version)
values ('00000000-0000-4000-8000-0000000007c1', 'teste-global', 'Global', 'v1');

select throws_ok(
  $$insert into doctor.knowledge_chunks (tenant_id, document_id, ordinal, content, tokens)
    values ('00000000-0000-4000-8000-00000000ac01', '00000000-0000-4000-8000-0000000007b1', 1, 'x', 1)$$,
  '23503', null, 'Fragmento nunca referencia documento de outra Organização'
);
select throws_ok(
  $$insert into doctor.knowledge_chunks (tenant_id, document_id, ordinal, content, tokens, embedding)
    values ('00000000-0000-4000-8000-00000000be01', '00000000-0000-4000-8000-0000000007b1', 2, 'x', 1, '[1,2]')$$,
  '23514', null, 'vetor sempre com o modelo que o gerou'
);

select tests.authenticate_as('00000000-0000-4000-8000-0000000a0001', '00000000-0000-4000-8000-00000000ac01', 'analyst');
select is((select count(*)::int from doctor.knowledge_chunks), 0, 'outra Organização não lê os Fragmentos');
select is((select count(*)::int from doctor.knowledge_documents), 0, 'nem os documentos');
select is(
  (select count(*)::int from doctor.global_knowledge_documents where slug = 'teste-global'), 1,
  'a Base global é de todos'
);
select throws_ok(
  $$insert into doctor.global_knowledge_documents (slug, title, version) values ('outro', 'x', 'v1')$$,
  '42501', null, 'cliente não escreve na Base global'
);
create temporary table created as
select * from doctor.create_knowledge_document('Configuração SAP [v2]', 'Configuração SAP [v2].md', 'text/markdown', 100);
select matches(
  (select storage_path from created),
  '^00000000-0000-4000-8000-00000000ac01/[0-9a-f-]{36}/document\.md$',
  'caminho no Storage sai da Organização do JWT, sem o nome do arquivo'
);
select tests.clear_authentication();

select tests.authenticate_as('00000000-0000-4000-8000-0000000a0002', '00000000-0000-4000-8000-00000000ac01', 'viewer');
select throws_ok(
  $$select doctor.create_knowledge_document('x', 'x.md', 'text/markdown', 1)$$,
  '42501', null, 'Viewer não envia documento'
);
select throws_ok(
  $$select doctor.delete_knowledge_document((select id from created))$$,
  '42501', null, 'nem remove'
);
select tests.clear_authentication();

select * from finish();
rollback;

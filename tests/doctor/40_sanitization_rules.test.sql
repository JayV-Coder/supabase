-- Regras de Sanitização por Organização (#13): padrões extras e IPs internos. Só Owner e Admin
-- com MFA mudam; todos da Organização leem; o worker de ingestão lê como plataforma.
begin;
\ir ../helpers/tenancy.psql
select plan(15);

select tests.create_user('00000000-0000-4000-8000-0000000f5001', 'owner@acme.test');
select tests.create_user('00000000-0000-4000-8000-0000000f5002', 'analyst@acme.test');
select tests.create_user('00000000-0000-4000-8000-0000000f5003', 'owner@varejo.test');
select tests.create_tenant('00000000-0000-4000-8000-00000000ac51', 'acme-regras');
select tests.create_tenant('00000000-0000-4000-8000-00000000be51', 'varejo-regras');
select tests.add_member('00000000-0000-4000-8000-00000000ac51', '00000000-0000-4000-8000-0000000f5001', 'owner');
select tests.add_member('00000000-0000-4000-8000-00000000ac51', '00000000-0000-4000-8000-0000000f5002', 'analyst');
select tests.add_member('00000000-0000-4000-8000-00000000be51', '00000000-0000-4000-8000-0000000f5003', 'owner');

-- Sem regra gravada, valem os padrões do Sanitizer.
select tests.authenticate_as('00000000-0000-4000-8000-0000000f5001', '00000000-0000-4000-8000-00000000ac51', 'owner', 'aal2');
select is((select count(*)::int from doctor.sanitization_rules), 0, 'sem regras, nada gravado');

select lives_ok($$select doctor.set_sanitization_rules('{"matricula": "MAT-[0-9]{6}"}', true, true)$$,
  'Owner com MFA grava as regras');
select is((select extra_patterns ->> 'matricula' from doctor.sanitization_rules), 'MAT-[0-9]{6}', 'o padrão fica gravado');
select is((select allow_private_ips from doctor.sanitization_rules), true, 'e a liberação dos IPs internos');
select lives_ok($$select doctor.set_sanitization_rules('{}', false, false)$$, 'gravar de novo substitui');
select is((select (detect_ips, jsonb_typeof(extra_patterns)) from doctor.sanitization_rules)::text, '(f,object)',
  'uma linha por Organização, com o valor novo');

select throws_ok($$select doctor.set_sanitization_rules('["MAT"]', true, false)$$, '22023', null,
  'padrões são um objeto tipo → padrão');
select throws_ok($$select doctor.set_sanitization_rules('{"Tipo Ruim": "x+"}', true, false)$$, '22023', null,
  'o tipo vira o marcador [REMOVIDO:<tipo>]: só minúsculas, números e _');
select throws_ok($$select doctor.set_sanitization_rules(jsonb_build_object('longo', repeat('a', 201)), true, false)$$, '22023', null,
  'padrão de até 200 caracteres');
select throws_ok($$select doctor.set_sanitization_rules((select jsonb_object_agg('t' || n, 'x' || n) from generate_series(1, 21) n), true, false)$$,
  '22023', null, 'até 20 padrões');
select tests.clear_authentication();

select tests.authenticate_as('00000000-0000-4000-8000-0000000f5001', '00000000-0000-4000-8000-00000000ac51', 'owner', 'aal1');
select throws_ok($$select doctor.set_sanitization_rules('{}', true, false)$$, '42501', null, 'sem MFA, não muda');
select tests.clear_authentication();

select tests.authenticate_as('00000000-0000-4000-8000-0000000f5002', '00000000-0000-4000-8000-00000000ac51', 'analyst', 'aal2');
select throws_ok($$select doctor.set_sanitization_rules('{}', true, false)$$, '42501', null, 'Analyst não muda');
select is((select count(*)::int from doctor.sanitization_rules), 1, 'mas lê as regras da Organização');
select tests.clear_authentication();

select is((select count(*)::int from doctor.audit_logs where tenant_id = '00000000-0000-4000-8000-00000000ac51'
  and action = 'org.sanitization_rules_changed'), 2, 'cada mudança fica na trilha de auditoria');

select tests.authenticate_as('00000000-0000-4000-8000-0000000f5003', '00000000-0000-4000-8000-00000000be51', 'owner', 'aal2');
select is((select count(*)::int from doctor.sanitization_rules), 0, 'outra Organização não lê');
select tests.clear_authentication();

select * from finish();
rollback;

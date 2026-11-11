-- Isolamento do Storage (ticket #27): os buckets do Doctor separam as Organizações pela pasta, e
-- a política repete o Papel. A Organização A não lê, não sobe e não apaga arquivo da B.
begin;
\ir ../helpers/tenancy.psql
select plan(32);

select tests.create_user('00000000-0000-4000-8000-0000000a0001', 'owner@acme.test');
select tests.create_user('00000000-0000-4000-8000-0000000a0003', 'analyst@acme.test');
select tests.create_user('00000000-0000-4000-8000-0000000a0004', 'viewer@acme.test');
select tests.create_tenant('00000000-0000-4000-8000-00000000ac01', 'acme');
select tests.create_tenant('00000000-0000-4000-8000-00000000be01', 'varejo');
select tests.add_member('00000000-0000-4000-8000-00000000ac01', '00000000-0000-4000-8000-0000000a0001', 'owner');
select tests.add_member('00000000-0000-4000-8000-00000000ac01', '00000000-0000-4000-8000-0000000a0003', 'analyst');
select tests.add_member('00000000-0000-4000-8000-00000000ac01', '00000000-0000-4000-8000-0000000a0004', 'viewer');

insert into storage.objects (bucket_id, name) values
  ('doctor-raw-logs', '00000000-0000-4000-8000-00000000be01/imports/x/upload.ndjson'),
  ('doctor-knowledge', '00000000-0000-4000-8000-00000000be01/y/document.md'),
  ('doctor-raw-logs', '00000000-0000-4000-8000-00000000ac01/imports/z/upload.ndjson'),
  ('doctor-knowledge', '00000000-0000-4000-8000-00000000ac01/w/document.md'),
  ('doctor-reports', '00000000-0000-4000-8000-00000000be01/r.pdf'),
  ('doctor-reports', '00000000-0000-4000-8000-00000000ac01/r.pdf');

create function pg_temp.blocked(command text) returns boolean language plpgsql as $$
declare
  affected bigint;
begin
  execute command;
  get diagnostics affected = row_count;
  return affected = 0;
exception
  when insufficient_privilege then return true;
end;
$$;

create temporary table storage_roles (user_id uuid, role text, aal text);
insert into storage_roles values
  ('00000000-0000-4000-8000-0000000a0001', 'owner', 'aal2'),
  ('00000000-0000-4000-8000-0000000a0003', 'analyst', 'aal1'),
  ('00000000-0000-4000-8000-0000000a0004', 'viewer', 'aal1');
grant select on storage_roles to authenticated;
create temporary table storage_results (role text, check_name text, passed boolean);
grant insert on storage_results to authenticated;

do $$
declare
  r record;
  bucket text;
begin
  for r in select * from storage_roles loop
    perform tests.authenticate_as(r.user_id, '00000000-0000-4000-8000-00000000ac01', r.role, r.aal);
    foreach bucket in array array['doctor-raw-logs', 'doctor-knowledge', 'doctor-reports'] loop
      insert into storage_results values
        (r.role, bucket || ': ler arquivo de B', (select count(*) = 0 from storage.objects
          where bucket_id = bucket and name like '00000000-0000-4000-8000-00000000be01/%')),
        (r.role, bucket || ': subir na pasta de B', pg_temp.blocked(format(
          'insert into storage.objects (bucket_id, name) values (%L, %L)', bucket,
          '00000000-0000-4000-8000-00000000be01/novo/arquivo.md')));
    end loop;
    -- Controle positivo: Owner e Analyst leem os arquivos da própria Organização (não é nega-tudo).
    -- O Viewer lê só o Relatório técnico (#32).
    insert into storage_results values
      (r.role, 'lê os arquivos da própria Organização', (select count(*) = case when r.role = 'viewer' then 1 else 3 end
        from storage.objects where name like '00000000-0000-4000-8000-00000000ac01/%'));
    insert into storage_results values
      (r.role, 'doctor-knowledge: apagar arquivo de B', pg_temp.blocked(
        'delete from storage.objects where bucket_id = ''doctor-knowledge'''
        || ' and name like ''00000000-0000-4000-8000-00000000be01/%''')),
      -- O bucket de Logs brutos não tem política de delete: só a retenção (plataforma) apaga.
      (r.role, 'doctor-raw-logs: ninguém apaga pelo cliente', pg_temp.blocked(
        'delete from storage.objects where bucket_id = ''doctor-raw-logs'''
        || ' and name like ''00000000-0000-4000-8000-00000000be01/%''')),
      -- Relatórios: só o worker sobe e só a retenção apaga.
      (r.role, 'doctor-reports: ninguém apaga pelo cliente', pg_temp.blocked(
        'delete from storage.objects where bucket_id = ''doctor-reports'''
        || ' and name like ''00000000-0000-4000-8000-00000000be01/%'''));
    perform tests.clear_authentication();
  end loop;
end;
$$;

-- Controle positivo do upload: com o documento pendente da própria Organização, o Analyst sobe.
insert into doctor.knowledge_documents (id, tenant_id, title, source, storage_path, content_type, size_bytes)
values ('00000000-0000-4000-8000-0000000008a1', '00000000-0000-4000-8000-00000000ac01', 'Runbook',
  'upload', '00000000-0000-4000-8000-00000000ac01/00000000-0000-4000-8000-0000000008a1/document.md',
  'text/markdown', 10);
select tests.authenticate_as('00000000-0000-4000-8000-0000000a0003', '00000000-0000-4000-8000-00000000ac01', 'analyst');
select lives_ok(
  $$insert into storage.objects (bucket_id, name) values ('doctor-knowledge',
    '00000000-0000-4000-8000-00000000ac01/00000000-0000-4000-8000-0000000008a1/document.md')$$,
  'analyst: sobe o documento pendente da própria Organização'
);
select tests.clear_authentication();

select ok(passed, format('%s: %s', role, check_name))
from storage_results
order by role, check_name;

select is(
  (select count(*)::int from storage.objects where name like '00000000-0000-4000-8000-00000000be01/%'),
  3, 'os arquivos de B continuam lá'
);
select * from finish();
rollback;

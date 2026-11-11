begin;
select plan(3);

select ok(
  has_column_privilege('authenticated', 'doctor.connectors', 'checkpoint', 'select')
  and has_column_privilege('authenticated', 'doctor.connectors', 'paused_reason', 'select'),
  'a tela lê o Checkpoint e o motivo da pausa'
);
select ok(
  not has_column_privilege('authenticated', 'doctor.connectors', 'secret_id', 'select'),
  'o id do segredo continua fora do cliente, também no evento do Realtime'
);
select ok(
  exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'doctor' and tablename = 'connectors'
  ),
  'o status dos Conectores chega pelo Realtime'
);
select * from finish();
rollback;

-- Apagar um projeto apaga os chats dele também no Supabase.
--
-- Aqui ninguém apaga linha: a exclusão é a marca `row_deleted_at`, que as
-- outras máquinas baixam. Até agora a marca só chegava aos filhos quando a
-- máquina que apagou o projeto mandava, uma por uma, a exclusão de cada chat
-- que ela conhecia. O chat que outra máquina abriu no projeto e que esta ainda
-- não tinha baixado ficava vivo no banco, apontando para um projeto apagado —
-- e uma escrita atrasada num chat de projeto apagado o trazia de volta.
--
-- Agora a exclusão desce pelo próprio banco, em dois gatilhos:
--   cascade_row_deletion  marcar o pai marca os filhos vivos (projeto → chats
--                         → turnos e mensagens → checagens, eventos e
--                         perguntas), com `synced_at` novo para a sync descer
--   inherit_row_deletion  a linha que chega com o pai já apagado nasce
--                         apagada: não ressuscita nada

create function public.cascade_row_deletion() returns trigger
language plpgsql
set search_path = ''
as $$
declare
  child record;
begin
  for child in
    select * from (values
      ('projects', 'chats', 'project_id'),
      ('chats', 'turns', 'chat_id'),
      ('chats', 'messages', 'chat_id'),
      ('turns', 'entry_checks', 'turn_id'),
      ('turns', 'exit_checks', 'turn_id'),
      ('turns', 'turn_events', 'turn_id'),
      ('turns', 'questions', 'turn_id')
    ) as edges(parent, name, fk)
    where parent = tg_table_name
  loop
    -- `row_updated_at` nunca recua: o `sync_row` descartaria a marca como
    -- escrita atrasada.
    execute format(
      'update public.%I set row_deleted_at = $1, row_updated_at = greatest(row_updated_at, $1)
        where %I = $2 and row_deleted_at is null',
      child.name, child.fk)
    using new.row_deleted_at, new.id;
  end loop;
  return null;
end
$$;

-- TG_ARGV: a tabela do pai e a coluna que aponta para ele.
create function public.inherit_row_deletion() returns trigger
language plpgsql
set search_path = ''
as $$
declare
  deleted timestamptz;
begin
  if new.row_deleted_at is null then
    execute format('select row_deleted_at from public.%I where id = $1', tg_argv[0])
      into deleted
      using to_jsonb(new) ->> tg_argv[1];
    new.row_deleted_at := deleted;
  end if;
  return new;
end
$$;

-- `inherit_row_deletion` vem antes de `sync_row` pela ordem do nome, como o
-- Postgres dispara os gatilhos `before` da mesma tabela.
do $$
declare
  parent text;
  edge record;
begin
  foreach parent in array array['projects', 'chats', 'turns'] loop
    execute format(
      'create trigger cascade_row_deletion after update of row_deleted_at on public.%I
        for each row when (old.row_deleted_at is null and new.row_deleted_at is not null)
        execute function public.cascade_row_deletion()',
      parent);
  end loop;
  for edge in
    select * from (values
      ('chats', 'projects', 'project_id'),
      ('turns', 'chats', 'chat_id'),
      ('messages', 'chats', 'chat_id'),
      ('entry_checks', 'turns', 'turn_id'),
      ('exit_checks', 'turns', 'turn_id'),
      ('turn_events', 'turns', 'turn_id'),
      ('questions', 'turns', 'turn_id')
    ) as edges(name, parent, fk)
  loop
    execute format(
      'create trigger inherit_row_deletion before insert or update on public.%I
        for each row execute function public.inherit_row_deletion(%L, %L)',
      edge.name, edge.parent, edge.fk);
  end loop;
end
$$;

-- Os filhos que ficaram vivos sob um pai já apagado, de cima para baixo: cada
-- nível marcado aqui leva junto os de baixo pelo gatilho, e as linhas de
-- baixo cujo pai já estava apagado antes desta migração entram pelo próprio
-- comando do nível delas.
update public.chats c set row_deleted_at = p.row_deleted_at, row_updated_at = greatest(c.row_updated_at, p.row_deleted_at)
  from public.projects p where p.id = c.project_id and p.row_deleted_at is not null and c.row_deleted_at is null;
update public.turns t set row_deleted_at = c.row_deleted_at, row_updated_at = greatest(t.row_updated_at, c.row_deleted_at)
  from public.chats c where c.id = t.chat_id and c.row_deleted_at is not null and t.row_deleted_at is null;
update public.messages m set row_deleted_at = c.row_deleted_at, row_updated_at = greatest(m.row_updated_at, c.row_deleted_at)
  from public.chats c where c.id = m.chat_id and c.row_deleted_at is not null and m.row_deleted_at is null;
update public.entry_checks x set row_deleted_at = t.row_deleted_at, row_updated_at = greatest(x.row_updated_at, t.row_deleted_at)
  from public.turns t where t.id = x.turn_id and t.row_deleted_at is not null and x.row_deleted_at is null;
update public.exit_checks x set row_deleted_at = t.row_deleted_at, row_updated_at = greatest(x.row_updated_at, t.row_deleted_at)
  from public.turns t where t.id = x.turn_id and t.row_deleted_at is not null and x.row_deleted_at is null;
update public.turn_events x set row_deleted_at = t.row_deleted_at, row_updated_at = greatest(x.row_updated_at, t.row_deleted_at)
  from public.turns t where t.id = x.turn_id and t.row_deleted_at is not null and x.row_deleted_at is null;
update public.questions x set row_deleted_at = t.row_deleted_at, row_updated_at = greatest(x.row_updated_at, t.row_deleted_at)
  from public.turns t where t.id = x.turn_id and t.row_deleted_at is not null and x.row_deleted_at is null;

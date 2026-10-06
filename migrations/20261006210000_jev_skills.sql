-- v0.71.0: o Jev escolhe a skill de cada pedido. O conjunto `skills` tem uma
-- pergunta fixa; as skills de quem usa vão no estado, numeradas, e a resposta
-- é o número de uma delas ou `none`.
--
-- A mesma linha está no seed regerado (20261001120100_seed_jev_en.sql); esta
-- migração a aplica nos bancos que já rodaram o seed.

do $$
declare
  found text;
begin
  for found in
    select conname from pg_constraint
    where conrelid = 'public.jev_questions'::regclass and contype = 'c'
      and pg_get_constraintdef(oid) like '%question_set%'
  loop
    execute format('alter table public.jev_questions drop constraint %I', found);
  end loop;
end $$;

alter table public.jev_questions
  add constraint jev_questions_question_set_check
  check (question_set in ('entry', 'routing', 'verification', 'asking', 'skills'));

insert into public.jev_questions (question_set, id, body, position) values
  ('skills', 'skill', $json${"criteria":{"1":"The skill whose `number` is 1 in `skills`: its description says when to use it, and this request is that case.","10":"The skill whose `number` is 10 in `skills`: its description says when to use it, and this request is that case.","11":"The skill whose `number` is 11 in `skills`: its description says when to use it, and this request is that case.","12":"The skill whose `number` is 12 in `skills`: its description says when to use it, and this request is that case.","2":"The skill whose `number` is 2 in `skills`: its description says when to use it, and this request is that case.","3":"The skill whose `number` is 3 in `skills`: its description says when to use it, and this request is that case.","4":"The skill whose `number` is 4 in `skills`: its description says when to use it, and this request is that case.","5":"The skill whose `number` is 5 in `skills`: its description says when to use it, and this request is that case.","6":"The skill whose `number` is 6 in `skills`: its description says when to use it, and this request is that case.","7":"The skill whose `number` is 7 in `skills`: its description says when to use it, and this request is that case.","8":"The skill whose `number` is 8 in `skills`: its description says when to use it, and this request is that case.","9":"The skill whose `number` is 9 in `skills`: its description says when to use it, and this request is that case.","none":"No skill clearly fits. Choose this whenever the request is a general question, is only loosely related to every description, or when two skills fit about equally."},"instructions":"Which skill listed in `skills` should the coding agent use to carry out `user_request`? Each skill has a `number`, a `name` and a `description` that says when it applies. Choose the number of the single skill whose description matches what the developer is asking for, or `none`.","type":"choice"}$json$::jsonb, 0)
on conflict (question_set, id) do update set body = excluded.body, position = excluded.position;

-- v0.56.0 (Fase 1 do plano de redução de voltas): a portaria de entrada
-- passa a receber as últimas falas do chat (`recent_turns`), e as perguntas
-- `goal_is_clear` e `says_where` julgam uma continuação curta ("pode
-- implementar", "ainda dá erro") contra o que a conversa já estabeleceu.
-- O parâmetro `continuation_minutes` é a janela em que um pedido curto ainda
-- continua a resposta anterior e herda o veredito dela.
--
-- As mesmas linhas estão no seed regerado (20261001120100_seed_jev_en.sql);
-- esta migração as aplica nos bancos que já rodaram o seed.

insert into public.jev_questions (question_set, id, body, position) values
  ('entry', 'goal_is_clear', $json${"criteria":{"false":{"examples":["\"fix this\", \"improve it here\", \"make it faster\" with nothing to anchor them","names a topic without saying what should change about it","several possible goals with no sign of which one is meant"],"when":"The outcome has to be guessed."},"true":{"examples":["asks for a named capability, file or fix","states the problem to be gone and what working looks like","asks a question whose answer would settle a decision"],"when":"The outcome is stated: the request names the behaviour, artefact or answer it expects to exist afterwards."}},"instructions":{"conversation":"`recent_turns`, when present, holds the last messages of this conversation. A short follow-up such as \"go ahead\", \"implement it\" or \"it still fails\" takes its outcome from them: judge the request together with what they already established.","guidance":"Look for the intended outcome, not for politeness or detail. A request can be short and still name its outcome exactly.","question":"Does `user_request` state what the developer wants to be true once the work is finished?"},"type":"noul"}$json$::jsonb, 1),
  ('entry', 'says_where', $json${"criteria":{"false":{"examples":["a change described only by its effect, in a project with many plausible homes for it","\"in the system\", \"in the code\", \"somewhere in the backend\""],"not_a_defect":["a general question that does not touch this project at all"],"when":"No place is given and the request is not self-locating."},"true":{"when":"The request points at a place: a path or filename, a named symbol, a module, a screen, a route, or a layer of the system."}},"instructions":{"conversation":"`recent_turns`, when present, holds the last messages of this conversation. A place named there, or the plan they already laid out, still locates a short follow-up that refers back to it.","guidance":"A location can be a path, a file, a module, a function, a screen, a layer or a named subsystem. Judge whether someone who knows this project could open the right place without guessing.","question":"Does `user_request` say where in the project the work belongs?"},"type":"noul"}$json$::jsonb, 3)
on conflict (question_set, id) do update set body = excluded.body, position = excluded.position;

insert into public.jev_parameters (key, value) values
  ('continuation_minutes', $json$30.0$json$::jsonb)
on conflict (key) do update set value = excluded.value;

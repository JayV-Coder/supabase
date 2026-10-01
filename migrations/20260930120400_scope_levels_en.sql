-- Os níveis de escopo do Jev passam a ser sempre em inglês. A tela os traduz
-- pela chave (`scope.0` a `scope.2`); o valor gravado é só identificador.
update public.jev_parameters
set value = $json$["small change","feature","whole system"]$json$::jsonb
where key = 'scope_levels';

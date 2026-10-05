-- v0.59.1: a chamada ao Jev conta uma vez no limite do dia, por mais que o
-- app a repita, e o prazo da portaria passa a ser parâmetro.
--
-- O app manda em cada chamada o cabeçalho `x-jev-request` (um UUID), o mesmo
-- em todas as repetições dela. A função `jev` repassa o id aqui: a primeira vez
-- que ele aparece no dia conta; as outras devolvem o total sem somar. Antes, o
-- app que desistia em 30 s e repetia pagava a chamada até quatro vezes,
-- enquanto a primeira ainda corria no servidor.
--
-- O app antigo não manda o cabeçalho e continua contando como antes, pela
-- `jev_count_call()` sem argumento.

-- 1. As chamadas do dia por id. Só as funções escrevem; ninguém lê.
create table public.jev_calls (
  user_id uuid not null references auth.users on delete cascade,
  request_id uuid not null,
  day date not null default (now() at time zone 'utc')::date,
  primary key (user_id, request_id)
);
alter table public.jev_calls enable row level security;
revoke all on public.jev_calls from anon, authenticated;

-- 2. Conta a chamada `request` uma vez só e devolve as do dia. Sem id, conta
-- como sempre. Os ids de antes de ontem saem na passagem: a tabela guarda só
-- o que uma repetição ainda pode alcançar.
create function public.jev_count_call(request uuid) returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  me uuid := (select auth.uid());
  today date := (now() at time zone 'utc')::date;
  used int;
begin
  if me is null then
    raise exception 'sem sessão' using errcode = '28000';
  end if;
  if request is null then
    return public.jev_count_call();
  end if;
  delete from public.jev_calls where user_id = me and day < today - 1;
  insert into public.jev_calls (user_id, request_id, day) values (me, request, today) on conflict do nothing;
  if found then
    return public.jev_count_call();
  end if;
  select calls into used from public.jev_usage where user_id = me and day = today;
  return coalesce(used, 0);
end
$$;
revoke execute on function public.jev_count_call(uuid) from public, anon;
grant execute on function public.jev_count_call(uuid) to authenticated;

-- 3. Devolve a chamada `request` ao limite do dia e esquece o id: a repetição
-- que vier depois de uma recusa da TypeSafe conta de novo, uma vez.
create function public.jev_refund_call(request uuid) returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (select auth.uid()) is null then
    raise exception 'sem sessão' using errcode = '28000';
  end if;
  if request is not null then
    delete from public.jev_calls where user_id = (select auth.uid()) and request_id = request;
    if not found then return; end if;
  end if;
  perform public.jev_refund_call();
end
$$;
revoke execute on function public.jev_refund_call(uuid) from public, anon;
grant execute on function public.jev_refund_call(uuid) to authenticated;

-- 4. O prazo que a portaria e o roteamento esperam o Jev antes das
-- heurísticas locais (segundos, repetição incluída). O mesmo valor está no
-- seed regerado (20261001120100_seed_jev_en.sql).
insert into public.jev_parameters (key, value) values
  ('deadline_seconds', $json$8.0$json$::jsonb)
on conflict (key) do update set value = excluded.value;

-- App 0.87.0 / site 2.7.0: a Administração mostra o que a conta tem em cada
-- ambiente (o pessoal e um por organização): projetos, chats e uso dos últimos
-- 30 dias. Só o admin chama.
create or replace function public.admin_user_environments(target uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  since text := to_char(now() - interval '30 days', 'YYYY-MM-DD');
begin
  perform public.admin_target(target);
  return coalesce((
    select jsonb_agg(e order by (e->>'id' <> 'personal'), e->>'name')
    from (
      select jsonb_build_object(
        'id', env.id,
        'name', env.name,
        'projects', (select count(*) from public.projects p where p.user_id = target and p.environment_id = env.id and p.row_deleted_at is null),
        'chats', (select count(*) from public.chats c where c.user_id = target and c.environment_id = env.id and c.row_deleted_at is null),
        'calls_30d', (select count(*) from public.usage_records r where r.user_id = target and r.environment_id = env.id and r.row_deleted_at is null and r.created_at >= since),
        'tokens_30d', (select coalesce(sum(r.input_tokens + r.output_tokens), 0) from public.usage_records r where r.user_id = target and r.environment_id = env.id and r.row_deleted_at is null and r.created_at >= since),
        'cost_30d', (select coalesce(sum(r.cost_usd), 0) from public.usage_records r where r.user_id = target and r.environment_id = env.id and r.row_deleted_at is null and r.created_at >= since)
      ) as e
      from (
        select 'personal'::text as id, null::text as name
        union all
        select o.id::text, o.name from public.organizations o
        join public.organization_members m on m.org_id = o.id and m.user_id = target
      ) env
    ) rows
  ), '[]'::jsonb);
end $$;
revoke execute on function public.admin_user_environments(uuid) from public, anon;
grant execute on function public.admin_user_environments(uuid) to authenticated;

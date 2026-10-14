-- As chaves do Stripe vêm do Vault do Supabase, não dos segredos das Edge
-- Functions. `stripe_secret(name)` devolve o segredo do Vault com esse nome
-- (STRIPE_SECRET_KEY ou STRIPE_WEBHOOK_SECRET, sem diferenciar maiúsculas) e
-- só a service role — as funções `billing` e `billing-webhook` — a executa:
-- nem o anon nem um usuário logado chegam ao valor. Outro nome devolve nulo.
create function public.stripe_secret(secret_name text) returns text language sql stable security definer set search_path = '' as $$
  select s.decrypted_secret
  from vault.decrypted_secrets s
  where lower(s.name) = lower(secret_name) and lower(s.name) in ('stripe_secret_key', 'stripe_webhook_secret')
  order by s.updated_at desc
  limit 1;
$$;
revoke all on function public.stripe_secret(text) from public, anon, authenticated;
grant execute on function public.stripe_secret(text) to service_role;

-- As chaves do Stripe no Vault: só a service role lê, e só as duas do Stripe.
begin;
create extension if not exists pgtap with schema extensions;
select plan(5);

select is(has_function_privilege('anon', 'public.stripe_secret(text)', 'execute'), false, 'o anon não lê segredo');
select is(has_function_privilege('authenticated', 'public.stripe_secret(text)', 'execute'), false, 'nem quem está logado');
select is(has_function_privilege('service_role', 'public.stripe_secret(text)', 'execute'), true, 'a service role lê');

select vault.create_secret('sk_test_exemplo', 'STRIPE_SECRET_KEY');
select vault.create_secret('outro-valor', 'OUTRA_COISA');
select is(public.stripe_secret('stripe_secret_key'), 'sk_test_exemplo', 'acha o segredo pelo nome, sem diferenciar maiúsculas');
select is(public.stripe_secret('OUTRA_COISA'), null, 'e só os dois nomes do Stripe');

select * from finish();
rollback;

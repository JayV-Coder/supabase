-- A Documentação, as Notas da versão e o menu da conta do site existem em
-- todos os idiomas de public.locales: toda chave que tem texto em inglês tem
-- texto em cada idioma. Um idioma novo sem essas traduções falha aqui.
begin;
create extension if not exists pgtap with schema extensions;
select plan(1);

select is_empty($$
  select l.id || ' ' || e.key
  from public.locales l
  cross join public.translations e
  where e.locale = 'en'
    and (e.key like 'docs.%' or e.key like 'site.docs.%' or e.key like 'site.releases.%'
      or e.key like 'site.account.photo.%' or e.key like 'whatsNew.item.%'
      or e.key in ('site.nav.docs', 'site.nav.openMenu', 'site.nav.closeMenu', 'site.nav.accountMenu', 'site.nav.connected'))
    and not exists (select 1 from public.translations t where t.locale = l.id and t.key = e.key)
  order by 1
$$, 'toda chave da documentação e das notas da versão existe em todos os idiomas');

select * from finish();
rollback;

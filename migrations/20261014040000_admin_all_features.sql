-- App 0.99.0: quem é admin do sistema tem todas as funcionalidades, em qualquer
-- plano e mesmo com o recurso desligado em Administração. Os interruptores dele
-- ficam livres (nada travado por plano); o valor de partida segue o plano e,
-- fora dele, é ligado.
create or replace function public.my_features() returns jsonb language sql stable security definer set search_path = '' as $$
  with mine as (select public.my_plan() as plan_key),
  me as (select coalesce(public.is_admin(), false) as admin),
  included as (
    select f.key, f.position, pf.mode, pf.default_on
    from public.features f
    left join public.plan_features pf on pf.feature_key = f.key and pf.plan_key = (select plan_key from mine)
    where case when (select admin from me) then true else f.enabled and pf.feature_key is not null end
  )
  select jsonb_build_object(
    'plan', (select plan_key from mine),
    'admin', (select admin from me),
    'managed', true,
    'features', coalesce((select jsonb_agg(key order by position, key) from included), '[]'::jsonb),
    'locked', coalesce((select jsonb_agg(key order by position, key) from included where mode = 'locked' and not (select admin from me)), '[]'::jsonb),
    'defaults', coalesce((select jsonb_object_agg(key, coalesce(default_on, true)) from included where mode is distinct from 'locked' or (select admin from me)), '{}'::jsonb),
    'limits', (select jsonb_build_object('jevDailyLimit', p.jev_daily_limit, 'maxConcurrentTurns', p.max_concurrent_turns)
               from public.plans p where p.key = (select plan_key from mine))
  );
$$;

insert into public.translations (locale, key, value) values
  ('pt-BR', 'whatsNew.item.adminAllFeatures.title', $json$"O admin do sistema tem todas as funcionalidades"$json$::jsonb),
  ('pt-BR', 'whatsNew.item.adminAllFeatures.detail', $json$"Quem é admin do sistema usa todos os recursos, em qualquer plano e mesmo os que foram desligados em Administração; os interruptores dele ficam livres."$json$::jsonb),
  ('en', 'whatsNew.item.adminAllFeatures.title', $json$"System admins get every feature"$json$::jsonb),
  ('en', 'whatsNew.item.adminAllFeatures.detail', $json$"Anyone who is a system admin uses every feature, on any plan and even those turned off in Administration; their toggles stay free."$json$::jsonb),
  ('es', 'whatsNew.item.adminAllFeatures.title', $json$"El admin del sistema tiene todas las funciones"$json$::jsonb),
  ('es', 'whatsNew.item.adminAllFeatures.detail', $json$"Quien es admin del sistema usa todos los recursos, en cualquier plan e incluso los desactivados en Administración; sus interruptores quedan libres."$json$::jsonb),
  ('zh-CN', 'whatsNew.item.adminAllFeatures.title', $json$"系统管理员拥有全部功能"$json$::jsonb),
  ('zh-CN', 'whatsNew.item.adminAllFeatures.detail', $json$"系统管理员可使用所有功能，不受套餐限制，即使在管理中被关闭的功能也可使用；其开关保持可自由切换。"$json$::jsonb),
  ('hi', 'whatsNew.item.adminAllFeatures.title', $json$"सिस्टम एडमिन के पास सभी सुविधाएँ होती हैं"$json$::jsonb),
  ('hi', 'whatsNew.item.adminAllFeatures.detail', $json$"सिस्टम एडमिन किसी भी प्लान में सभी सुविधाएँ इस्तेमाल करता है, यहाँ तक कि वे भी जो प्रशासन में बंद की गई हैं; उसके स्विच खुले रहते हैं।"$json$::jsonb),
  ('ar', 'whatsNew.item.adminAllFeatures.title', $json$"مشرف النظام لديه كل الميزات"$json$::jsonb),
  ('ar', 'whatsNew.item.adminAllFeatures.detail', $json$"مشرف النظام يستخدم كل الميزات في أي خطة، حتى تلك التي أُوقفت في الإدارة؛ وتبقى مفاتيحه حرة."$json$::jsonb),
  ('fr', 'whatsNew.item.adminAllFeatures.title', $json$"L’administrateur du système a toutes les fonctions"$json$::jsonb),
  ('fr', 'whatsNew.item.adminAllFeatures.detail', $json$"L’administrateur du système utilise toutes les fonctions, dans n’importe quel forfait et même celles désactivées dans Administration ; ses interrupteurs restent libres."$json$::jsonb),
  ('ru', 'whatsNew.item.adminAllFeatures.title', $json$"Админ системы получает все функции"$json$::jsonb),
  ('ru', 'whatsNew.item.adminAllFeatures.detail', $json$"Администратор системы использует все функции в любом тарифе, даже отключённые в разделе администрирования; его переключатели остаются свободными."$json$::jsonb),
  ('ja', 'whatsNew.item.adminAllFeatures.title', $json$"システム管理者はすべての機能を使えます"$json$::jsonb),
  ('ja', 'whatsNew.item.adminAllFeatures.detail', $json$"システム管理者は、どのプランでも、管理画面でオフにされた機能も含めてすべての機能を使えます。切り替えも自由です。"$json$::jsonb),
  ('de', 'whatsNew.item.adminAllFeatures.title', $json$"Systemadmins haben alle Funktionen"$json$::jsonb),
  ('de', 'whatsNew.item.adminAllFeatures.detail', $json$"Wer Systemadmin ist, nutzt alle Funktionen, in jedem Tarif und auch solche, die in der Verwaltung abgeschaltet wurden; die Schalter bleiben frei."$json$::jsonb)
on conflict (locale, key) do update set value = excluded.value;

-- Uma frase a mais no manual de Planos, em cada idioma (uma vez só).
update public.translations set value = to_jsonb((value #>> '{}') || $s$ Quem é admin do sistema tem todas as funcionalidades, em qualquer plano.$s$) where locale = 'pt-BR' and key = 'docs.plans.usage' and (value #>> '{}') not like '%' || $s$Quem é admin do sistema tem todas as funcionalidades, em qualquer plano.$s$ || '%';
update public.translations set value = to_jsonb((value #>> '{}') || $s$ System admins get every feature, on any plan.$s$) where locale = 'en' and key = 'docs.plans.usage' and (value #>> '{}') not like '%' || $s$System admins get every feature, on any plan.$s$ || '%';
update public.translations set value = to_jsonb((value #>> '{}') || $s$ El admin del sistema tiene todas las funciones, en cualquier plan.$s$) where locale = 'es' and key = 'docs.plans.usage' and (value #>> '{}') not like '%' || $s$El admin del sistema tiene todas las funciones, en cualquier plan.$s$ || '%';
update public.translations set value = to_jsonb((value #>> '{}') || $s$ 系统管理员在任何套餐下都拥有全部功能。$s$) where locale = 'zh-CN' and key = 'docs.plans.usage' and (value #>> '{}') not like '%' || $s$系统管理员在任何套餐下都拥有全部功能。$s$ || '%';
update public.translations set value = to_jsonb((value #>> '{}') || $s$ सिस्टम एडमिन के पास किसी भी प्लान में सभी सुविधाएँ होती हैं।$s$) where locale = 'hi' and key = 'docs.plans.usage' and (value #>> '{}') not like '%' || $s$सिस्टम एडमिन के पास किसी भी प्लान में सभी सुविधाएँ होती हैं।$s$ || '%';
update public.translations set value = to_jsonb((value #>> '{}') || $s$ مشرف النظام لديه كل الميزات في أي خطة.$s$) where locale = 'ar' and key = 'docs.plans.usage' and (value #>> '{}') not like '%' || $s$مشرف النظام لديه كل الميزات في أي خطة.$s$ || '%';
update public.translations set value = to_jsonb((value #>> '{}') || $s$ L’administrateur du système a toutes les fonctions, dans n’importe quel forfait.$s$) where locale = 'fr' and key = 'docs.plans.usage' and (value #>> '{}') not like '%' || $s$L’administrateur du système a toutes les fonctions, dans n’importe quel forfait.$s$ || '%';
update public.translations set value = to_jsonb((value #>> '{}') || $s$ Администратор системы получает все функции в любом тарифе.$s$) where locale = 'ru' and key = 'docs.plans.usage' and (value #>> '{}') not like '%' || $s$Администратор системы получает все функции в любом тарифе.$s$ || '%';
update public.translations set value = to_jsonb((value #>> '{}') || $s$ システム管理者はどのプランでもすべての機能を使えます。$s$) where locale = 'ja' and key = 'docs.plans.usage' and (value #>> '{}') not like '%' || $s$システム管理者はどのプランでもすべての機能を使えます。$s$ || '%';
update public.translations set value = to_jsonb((value #>> '{}') || $s$ Systemadmins haben in jedem Tarif alle Funktionen.$s$) where locale = 'de' and key = 'docs.plans.usage' and (value #>> '{}') not like '%' || $s$Systemadmins haben in jedem Tarif alle Funktionen.$s$ || '%';

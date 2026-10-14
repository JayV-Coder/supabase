-- App 0.98.1 e site 2.16.1: o admin liga e desliga qualquer recurso, também os do núcleo.
--
-- Até aqui os sete recursos de núcleo (portarias, proteção de segredos e de
-- arquivos sensíveis, sessões do agente, cache de contexto, roteamento
-- adaptativo) estavam em todo plano, travados, e o admin não os desligava nem
-- os tirava de um plano. Agora são recursos como os outros: continuam nos
-- planos que já existem (travados), mas o admin os desliga em Recursos, tira
-- de um plano ou os deixa opcionais.
-- `features.core` fica só como informação (o selo "Núcleo" na tela).
--
-- `my_features()` passa a devolver `managed: true`: a lista e os travados são
-- exatamente os do plano, sem somar o núcleo. Quem não conhece o campo (app
-- antigo) segue somando o núcleo por conta própria.
alter table public.features drop constraint features_core_enabled;
drop trigger plans_core_features on public.plans;
drop function public.plan_core_features();

create or replace function public.admin_set_feature(feature text, on_off boolean) returns void language plpgsql security definer set search_path = '' as $$
begin
  perform public.admin_require();
  update public.features set enabled = on_off, updated_by = auth.uid(), updated_at = now() where key = feature;
  if not found then raise exception 'admin.error.unknownFeature'; end if;
end;
$$;

-- `admin_save_plan`: igual ao de antes, sem forçar o núcleo no plano.
create or replace function public.admin_save_plan(plan jsonb) returns void language plpgsql security definer set search_path = '' as $$
declare
  chosen text := plan->>'key';
  item jsonb;
  wanted text[] := '{}';
  modes text[] := '{}';
  defaults boolean[] := '{}';
  mode text;
  extras jsonb := '[]'::jsonb;
  seen text[] := '{}';
  used text[] := '{}';
  cur text;
  countries jsonb;
  allowed text[] := array['usd','eur','gbp','brl','cad','aud','chf','mxn','inr'];
begin
  perform public.admin_require();
  if jsonb_typeof(plan) is distinct from 'object' or jsonb_typeof(plan->'features') is distinct from 'array' then
    raise exception 'admin.error.planInvalid';
  end if;
  for item in select value from jsonb_array_elements(plan->'features') loop
    if jsonb_typeof(item) = 'string' then
      if not ((item #>> '{}') = any (wanted)) then
        wanted := wanted || (item #>> '{}'); modes := modes || 'optional'::text; defaults := defaults || true;
      end if;
    elsif jsonb_typeof(item) = 'object' and jsonb_typeof(item->'key') = 'string' then
      mode := coalesce(item->>'mode', 'optional');
      if mode not in ('optional', 'locked') or (item ? 'default_on' and jsonb_typeof(item->'default_on') <> 'boolean') then
        raise exception 'admin.error.planInvalid';
      end if;
      if not ((item->>'key') = any (wanted)) then
        wanted := wanted || (item->>'key'); modes := modes || mode; defaults := defaults || coalesce((item->>'default_on')::boolean, true);
      end if;
    else
      raise exception 'admin.error.planInvalid';
    end if;
  end loop;
  if exists (select 1 from unnest(wanted) k where not exists (select 1 from public.features f where f.key = k)) then
    raise exception 'admin.error.unknownFeature';
  end if;
  -- Preços em outras moedas (e os países a que valem): só no plano pago.
  if plan ? 'extra_prices' and not coalesce((plan->>'is_default')::boolean, false) then
    if jsonb_typeof(plan->'extra_prices') is distinct from 'array' then
      raise exception 'admin.error.planInvalid';
    end if;
    for item in select value from jsonb_array_elements(plan->'extra_prices') loop
      cur := lower(btrim(coalesce(item->>'currency', '')));
      if jsonb_typeof(item) is distinct from 'object' or not (cur = any (allowed)) or cur = any (seen)
         or cur = lower(btrim(coalesce(plan->>'currency', '')))
         or coalesce(item->>'price_cents', '') !~ '^[1-9][0-9]{0,8}$' then
        raise exception 'admin.error.planInvalid';
      end if;
      if item ? 'countries' and jsonb_typeof(item->'countries') is distinct from 'array' then
        raise exception 'admin.error.planInvalid';
      end if;
      if exists (select 1 from jsonb_array_elements(coalesce(item->'countries', '[]'::jsonb)) c
                 where jsonb_typeof(c) is distinct from 'string' or (c #>> '{}') !~ '^[A-Za-z]{2}$') then
        raise exception 'admin.error.planInvalid';
      end if;
      select coalesce(jsonb_agg(distinct upper(c #>> '{}')), '[]'::jsonb) into countries
        from jsonb_array_elements(coalesce(item->'countries', '[]'::jsonb)) c;
      -- Um país só tem uma moeda.
      if exists (select 1 from jsonb_array_elements_text(countries) c where c = any (used)) then
        raise exception 'admin.error.planInvalid';
      end if;
      used := used || array(select jsonb_array_elements_text(countries));
      seen := seen || cur;
      extras := extras || jsonb_build_array(jsonb_build_object('currency', cur, 'price_cents', (item->>'price_cents')::integer, 'countries', countries));
    end loop;
  end if;
  begin
    -- Um padrão novo tira o posto do antigo antes de a linha nova entrar.
    if coalesce((plan->>'is_default')::boolean, false) then
      update public.plans set is_default = false where is_default and key <> chosen;
    end if;
    insert into public.plans (key, name, description, position, active, is_default, stripe_price_id, price_cents, currency, billing_interval, extra_prices, jev_daily_limit, max_concurrent_turns, updated_by, updated_at)
    values (
      chosen, btrim(plan->>'name'), coalesce(plan->>'description', ''), coalesce((plan->>'position')::integer, 0),
      coalesce((plan->>'active')::boolean, true), coalesce((plan->>'is_default')::boolean, false),
      nullif(btrim(plan->>'stripe_price_id'), ''), (plan->>'price_cents')::integer, nullif(lower(btrim(plan->>'currency')), ''),
      nullif(plan->>'billing_interval', ''), extras, nullif(plan->>'jev_daily_limit', '')::integer,
      coalesce(nullif(plan->>'max_concurrent_turns', '')::integer, 1), auth.uid(), now()
    )
    on conflict (key) do update set
      name = excluded.name, description = excluded.description, position = excluded.position, active = excluded.active,
      is_default = excluded.is_default, stripe_price_id = excluded.stripe_price_id, price_cents = excluded.price_cents,
      currency = excluded.currency, billing_interval = excluded.billing_interval, extra_prices = excluded.extra_prices, jev_daily_limit = excluded.jev_daily_limit,
      max_concurrent_turns = excluded.max_concurrent_turns, updated_by = excluded.updated_by, updated_at = excluded.updated_at;
  exception
    when check_violation or not_null_violation or invalid_text_representation then raise exception 'admin.error.planInvalid';
    when unique_violation then raise exception 'admin.error.priceTaken';
  end;
  if not exists (select 1 from public.plans where is_default) then raise exception 'admin.error.default'; end if;
  delete from public.plan_features pf
  where pf.plan_key = chosen and not (pf.feature_key = any (wanted));
  insert into public.plan_features (plan_key, feature_key, mode, default_on)
  select chosen, w.k, w.m, w.d from unnest(wanted, modes, defaults) as w(k, m, d)
  on conflict (plan_key, feature_key) do update set mode = excluded.mode, default_on = excluded.default_on;
end;
$$;

create or replace function public.my_features() returns jsonb language sql stable security definer set search_path = '' as $$
  with mine as (select public.my_plan() as plan_key),
  included as (
    select f.key, f.position, pf.mode, pf.default_on
    from public.features f
    join public.plan_features pf on pf.feature_key = f.key and pf.plan_key = (select plan_key from mine)
    where f.enabled
  )
  select jsonb_build_object(
    'plan', (select plan_key from mine),
    'admin', coalesce(public.is_admin(), false),
    'managed', true,
    'features', coalesce((select jsonb_agg(key order by position, key) from included), '[]'::jsonb),
    'locked', coalesce((select jsonb_agg(key order by position, key) from included where mode = 'locked'), '[]'::jsonb),
    'defaults', coalesce((select jsonb_object_agg(key, coalesce(default_on, true)) from included where mode is distinct from 'locked'), '{}'::jsonb),
    'limits', (select jsonb_build_object('jevDailyLimit', p.jev_daily_limit, 'maxConcurrentTurns', p.max_concurrent_turns)
               from public.plans p where p.key = (select plan_key from mine))
  );
$$;

insert into public.translations (locale, key, value) values
  ('pt-BR', 'site.admin.feature.core', $json$"Recurso de núcleo: começa em todo plano, mas você pode desligá-lo"$json$::jsonb),
  ('en', 'site.admin.feature.core', $json$"Core feature: starts in every plan, but you can turn it off"$json$::jsonb),
  ('es', 'site.admin.feature.core', $json$"Recurso de núcleo: empieza en todos los planes, pero puedes desactivarlo"$json$::jsonb),
  ('zh-CN', 'site.admin.feature.core', $json$"核心功能：默认包含在每个套餐中，但你可以关闭它"$json$::jsonb),
  ('hi', 'site.admin.feature.core', $json$"कोर सुविधा: हर प्लान में शुरू से होती है, पर आप इसे बंद कर सकते हैं"$json$::jsonb),
  ('ar', 'site.admin.feature.core', $json$"ميزة أساسية: تبدأ في كل خطة، ويمكنك إيقافها"$json$::jsonb),
  ('fr', 'site.admin.feature.core', $json$"Fonction de base : présente dès le départ dans chaque forfait, mais vous pouvez la désactiver"$json$::jsonb),
  ('ru', 'site.admin.feature.core', $json$"Базовая функция: изначально есть в каждом тарифе, но её можно отключить"$json$::jsonb),
  ('ja', 'site.admin.feature.core', $json$"コア機能：すべてのプランに最初から含まれますが、オフにできます"$json$::jsonb),
  ('de', 'site.admin.feature.core', $json$"Kernfunktion: in jedem Tarif von Anfang an enthalten, lässt sich aber ausschalten"$json$::jsonb),
  ('pt-BR', 'whatsNew.item.featuresEditable.title', $json$"O admin liga e desliga qualquer recurso, até os do núcleo"$json$::jsonb),
  ('en', 'whatsNew.item.featuresEditable.title', $json$"The admin can turn any feature on or off, core ones included"$json$::jsonb),
  ('es', 'whatsNew.item.featuresEditable.title', $json$"El admin activa y desactiva cualquier recurso, también los del núcleo"$json$::jsonb),
  ('zh-CN', 'whatsNew.item.featuresEditable.title', $json$"管理员可以开关任何功能，包括核心功能"$json$::jsonb),
  ('hi', 'whatsNew.item.featuresEditable.title', $json$"एडमिन किसी भी सुविधा को चालू या बंद कर सकता है, कोर सुविधाएँ भी"$json$::jsonb),
  ('ar', 'whatsNew.item.featuresEditable.title', $json$"يمكن للمشرف تشغيل أي ميزة أو إيقافها، بما فيها الأساسية"$json$::jsonb),
  ('fr', 'whatsNew.item.featuresEditable.title', $json$"L’admin active ou désactive n’importe quelle fonction, même celles de base"$json$::jsonb),
  ('ru', 'whatsNew.item.featuresEditable.title', $json$"Админ включает и отключает любые функции, в том числе базовые"$json$::jsonb),
  ('ja', 'whatsNew.item.featuresEditable.title', $json$"管理者はコア機能を含め、あらゆる機能をオン・オフできます"$json$::jsonb),
  ('de', 'whatsNew.item.featuresEditable.title', $json$"Der Admin schaltet jede Funktion ein oder aus, auch die Kernfunktionen"$json$::jsonb),
  ('pt-BR', 'whatsNew.item.featuresEditable.detail', $json$"Os recursos do núcleo (portarias, proteção de segredos e de arquivos sensíveis, sessões do agente, cache de contexto e roteamento adaptativo) deixam de ser travados: em Administração você os desliga para todos ou os tira de um plano, e o app segue a lista do plano."$json$::jsonb),
  ('en', 'whatsNew.item.featuresEditable.detail', $json$"The core features (gates, secret and sensitive-file protection, agent sessions, context cache and adaptive routing) are no longer locked: in Administration you turn them off for everyone or take them out of a plan, and the app follows the plan's list."$json$::jsonb),
  ('es', 'whatsNew.item.featuresEditable.detail', $json$"Los recursos del núcleo (porterías, protección de secretos y archivos sensibles, sesiones del agente, caché de contexto y enrutamiento adaptativo) dejan de estar bloqueados: en Administración los desactivas para todos o los quitas de un plan, y la app sigue la lista del plan."$json$::jsonb),
  ('zh-CN', 'whatsNew.item.featuresEditable.detail', $json$"核心功能（门禁、密钥与敏感文件保护、智能体会话、上下文缓存和自适应路由）不再被锁定：在“管理”中可以对所有人关闭，或从某个套餐中移除，应用会遵循套餐的功能列表。"$json$::jsonb),
  ('hi', 'whatsNew.item.featuresEditable.detail', $json$"कोर सुविधाएँ (गेट, गोपनीय जानकारी और संवेदनशील फ़ाइलों की सुरक्षा, एजेंट सत्र, संदर्भ कैश और अनुकूली रूटिंग) अब लॉक नहीं हैं: एडमिनिस्ट्रेशन में आप इन्हें सबके लिए बंद कर सकते हैं या किसी प्लान से हटा सकते हैं, और ऐप प्लान की सूची का पालन करता है।"$json$::jsonb),
  ('ar', 'whatsNew.item.featuresEditable.detail', $json$"لم تعد الميزات الأساسية (البوابات وحماية الأسرار والملفات الحساسة وجلسات الوكلاء وذاكرة السياق والتوجيه التكيفي) مقفلة: من الإدارة توقفها للجميع أو تزيلها من خطة، ويتبع التطبيق قائمة الخطة."$json$::jsonb),
  ('fr', 'whatsNew.item.featuresEditable.detail', $json$"Les fonctions de base (conciergeries, protection des secrets et des fichiers sensibles, sessions d’agents, cache de contexte et routage adaptatif) ne sont plus verrouillées : dans Administration, vous les désactivez pour tous ou les retirez d’un forfait, et l’app suit la liste du forfait."$json$::jsonb),
  ('ru', 'whatsNew.item.featuresEditable.detail', $json$"Базовые функции (проходные, защита секретов и чувствительных файлов, сессии агентов, кэш контекста и адаптивная маршрутизация) больше не заблокированы: в разделе «Администрирование» их можно отключить для всех или убрать из тарифа, а приложение следует списку тарифа."$json$::jsonb),
  ('ja', 'whatsNew.item.featuresEditable.detail', $json$"コア機能（ゲート、秘密情報と機密ファイルの保護、エージェントのセッション、コンテキストキャッシュ、適応型ルーティング）のロックを廃止しました。管理画面で全員に対してオフにしたり、プランから外したりでき、アプリはプランの一覧に従います。"$json$::jsonb),
  ('de', 'whatsNew.item.featuresEditable.detail', $json$"Die Kernfunktionen (Pforten, Schutz von Geheimnissen und sensiblen Dateien, Agentensitzungen, Kontext-Cache und adaptives Routing) sind nicht mehr gesperrt: In der Verwaltung schalten Sie sie für alle aus oder nehmen sie aus einem Tarif, und die App folgt der Liste des Tarifs."$json$::jsonb),
  ('pt-BR', 'docs.plans.usage', $json$"Abra Planos na barra lateral (ou Ctrl+K › Planos) para ver o que cada plano inclui. Assinar abre o pagamento do Stripe no navegador e, quando ele termina, o JayV atualiza o plano sozinho; Gerenciar assinatura abre o portal do Stripe para trocar o cartão ou o plano e cancelar. Quem administra o sistema monta os planos no site (Dashboard › Administração › Planos): ao salvar, cada plano vira um produto no Stripe e o plano pago ganha o preço recorrente; trocar o valor cria um preço novo e tira o antigo de venda. Um plano só fica à venda depois de enviado ao Stripe. Um plano pago também pode ter preços em outras moedas (dólar, euro, libra, real, dólar canadense e australiano, franco suíço, peso mexicano e rupia), cada uma com os países em que vale: quem paga vê a moeda do seu país e pode escolher outra na página de planos. O administrador pode ligar ou desligar qualquer recurso para todos e escolher em quais planos ele entra, até os do núcleo (portarias, proteção de segredos e de arquivos sensíveis, sessões do agente, cache de contexto e roteamento adaptativo); o que o plano não traz aparece como não incluído."$json$::jsonb),
  ('en', 'docs.plans.usage', $json$"Open Plans in the sidebar (or Ctrl+K › Plans) to see what each plan includes. Subscribe opens Stripe's payment in the browser and, when it finishes, JayV updates the plan by itself; Manage subscription opens Stripe's portal to change the card or the plan and to cancel. Whoever administers the system builds the plans on the site (Dashboard › Administration › Plans): when you save, each plan becomes a product in Stripe and a paid plan gets its recurring price; changing the amount creates a new price and takes the old one off sale. A plan only goes on sale once it has been sent to Stripe. A paid plan can also have prices in other currencies (US dollar, euro, pound, real, Canadian and Australian dollar, Swiss franc, Mexican peso and rupee), each with the countries it applies to: whoever pays sees the currency of their country and can pick another on the plans page. The administrator can turn any feature on or off for everyone and choose which plans include it, even the core ones (gates, secret and sensitive-file protection, agent sessions, context cache and adaptive routing); what a plan does not bring shows as not included."$json$::jsonb),
  ('es', 'docs.plans.usage', $json$"Abre Planes en la barra lateral (o Ctrl+K › Planes) para ver qué incluye cada plan. Suscribirse abre el pago de Stripe en el navegador y, al terminar, JayV actualiza el plan solo; Gestionar suscripción abre el portal de Stripe para cambiar la tarjeta o el plan y cancelar. Quien administra el sistema arma los planes en el sitio (Panel › Administración › Planes): al guardar, cada plan se convierte en un producto de Stripe y el plan de pago recibe su precio recurrente; cambiar el importe crea un precio nuevo y retira el anterior de la venta. Un plan solo se vende una vez enviado a Stripe. Un plan de pago también puede tener precios en otras monedas (dólar, euro, libra, real, dólar canadiense y australiano, franco suizo, peso mexicano y rupia), cada una con los países donde vale: quien paga ve la moneda de su país y puede elegir otra en la página de planes. El administrador puede activar o desactivar cualquier recurso para todos y elegir en qué planes entra, incluso los del núcleo (porterías, protección de secretos y archivos sensibles, sesiones del agente, caché de contexto y enrutamiento adaptativo); lo que el plan no trae aparece como no incluido."$json$::jsonb),
  ('zh-CN', 'docs.plans.usage', $json$"在侧边栏打开“套餐”（或 Ctrl+K › 套餐）查看每个套餐包含什么。“订阅”会在浏览器中打开 Stripe 支付，完成后 JayV 会自动更新套餐；“管理订阅”会打开 Stripe 门户，用于更换银行卡或套餐以及取消。系统管理员在网站（控制台 › 管理 › 套餐）中配置套餐：保存时，每个套餐都会成为 Stripe 中的一个产品，付费套餐还会创建循环价格；修改金额会创建新价格并下架旧价格。套餐发送到 Stripe 之后才会开始销售。 付费套餐还可以设置其他货币的价格（美元、欧元、英镑、雷亚尔、加元、澳元、瑞士法郎、墨西哥比索和卢比），并指定各自适用的国家：付款人看到所在国家的货币，也可以在套餐页面改选其他货币。 管理员可以为所有人开关任何功能，并选择哪些套餐包含它，核心功能（门禁、密钥与敏感文件保护、智能体会话、上下文缓存和自适应路由）也不例外；套餐未包含的功能显示为“未包含”。"$json$::jsonb),
  ('hi', 'docs.plans.usage', $json$"हर प्लान में क्या शामिल है यह देखने के लिए साइडबार में प्लान खोलें (या Ctrl+K › प्लान)। सदस्यता लें ब्राउज़र में Stripe का भुगतान खोलता है और पूरा होते ही JayV प्लान अपने आप बदल देता है; सदस्यता प्रबंधित करें Stripe का पोर्टल खोलता है, जहाँ कार्ड या प्लान बदला और सदस्यता रद्द की जा सकती है। सिस्टम का प्रशासक प्लान साइट पर बनाता है (डैशबोर्ड › प्रशासन › प्लान): सहेजते ही हर प्लान Stripe में प्रोडक्ट बन जाता है और सशुल्क प्लान को आवर्ती कीमत मिलती है; राशि बदलने पर नई कीमत बनती है और पुरानी बिक्री से हट जाती है। प्लान Stripe को भेजे जाने के बाद ही बिक्री पर आता है। सशुल्क प्लान की कीमतें अन्य मुद्राओं में भी हो सकती हैं (डॉलर, यूरो, पाउंड, रियल, कनाडाई और ऑस्ट्रेलियाई डॉलर, स्विस फ़्रैंक, मेक्सिकन पेसो और रुपया), हर एक के साथ वे देश जहाँ वह लागू है: भुगतान करने वाले को अपने देश की मुद्रा दिखती है और वह प्लान पेज पर दूसरी मुद्रा चुन सकता है। एडमिनिस्ट्रेटर किसी भी सुविधा को सबके लिए चालू या बंद कर सकता है और चुन सकता है कि वह किन प्लान में हो, कोर सुविधाएँ (गेट, गोपनीय जानकारी और संवेदनशील फ़ाइलों की सुरक्षा, एजेंट सत्र, संदर्भ कैश और अनुकूली रूटिंग) भी; जो प्लान में नहीं है वह \"शामिल नहीं\" दिखता है।"$json$::jsonb),
  ('ar', 'docs.plans.usage', $json$"افتح «الخطط» من الشريط الجانبي (أو Ctrl+K › الخطط) لترى ما تشمله كل خطة. «اشتراك» يفتح دفع Stripe في المتصفح، وعند انتهائه يحدّث JayV الخطة تلقائيًا؛ و«إدارة الاشتراك» يفتح بوابة Stripe لتغيير البطاقة أو الخطة والإلغاء. يبني مسؤول النظام الخطط في الموقع (لوحة التحكم › الإدارة › الخطط): عند الحفظ تصبح كل خطة منتجًا في Stripe وتحصل الخطة المدفوعة على سعرها المتكرر؛ وتغيير المبلغ ينشئ سعرًا جديدًا ويوقف بيع القديم. ولا تُعرض الخطة للبيع إلا بعد إرسالها إلى Stripe. يمكن أن تكون للخطة المدفوعة أسعار بعملات أخرى (الدولار واليورو والجنيه الإسترليني والريال البرازيلي والدولار الكندي والأسترالي والفرنك السويسري والبيزو المكسيكي والروبية)، لكل منها الدول التي تسري فيها: يرى من يدفع عملة بلده ويمكنه اختيار عملة أخرى في صفحة الخطط. يمكن للمشرف تشغيل أي ميزة أو إيقافها للجميع واختيار الخطط التي تتضمنها، حتى الأساسية منها (البوابات وحماية الأسرار والملفات الحساسة وجلسات الوكلاء وذاكرة السياق والتوجيه التكيفي)؛ وما لا تتضمنه الخطة يظهر على أنه غير مشمول."$json$::jsonb),
  ('fr', 'docs.plans.usage', $json$"Ouvrez Forfaits dans la barre latérale (ou Ctrl+K › Forfaits) pour voir ce que chaque forfait inclut. S’abonner ouvre le paiement Stripe dans le navigateur et, une fois terminé, JayV met le forfait à jour tout seul ; Gérer l’abonnement ouvre le portail Stripe pour changer de carte ou de forfait et résilier. L’administrateur du système monte les forfaits sur le site (Tableau de bord › Administration › Forfaits) : à l’enregistrement, chaque forfait devient un produit dans Stripe et un forfait payant reçoit son prix récurrent ; changer le montant crée un nouveau prix et retire l’ancien de la vente. Un forfait n’est en vente qu’une fois envoyé à Stripe. Un forfait payant peut aussi avoir des prix dans d’autres devises (dollar, euro, livre, réal, dollars canadien et australien, franc suisse, peso mexicain et roupie), chacune avec les pays où elle s’applique : la personne qui paie voit la devise de son pays et peut en choisir une autre sur la page des forfaits. L’administrateur peut activer ou désactiver n’importe quelle fonction pour tous et choisir les forfaits qui l’incluent, même celles de base (conciergeries, protection des secrets et des fichiers sensibles, sessions d’agents, cache de contexte et routage adaptatif) ; ce que le forfait n’apporte pas s’affiche comme non inclus."$json$::jsonb),
  ('ru', 'docs.plans.usage', $json$"Откройте «Тарифы» на боковой панели (или Ctrl+K › Тарифы), чтобы увидеть, что входит в каждый тариф. «Оформить подписку» открывает оплату Stripe в браузере, а когда она завершается, JayV сам обновляет тариф; «Управление подпиской» открывает портал Stripe, где можно сменить карту или тариф и отменить подписку. Администратор системы настраивает тарифы на сайте (Панель › Администрирование › Тарифы): при сохранении каждый тариф становится продуктом в Stripe, а платный получает регулярную цену; смена суммы создаёт новую цену и снимает старую с продажи. Тариф поступает в продажу только после отправки в Stripe. У платного тарифа могут быть цены и в других валютах (доллар, евро, фунт, реал, канадский и австралийский доллары, швейцарский франк, мексиканское песо и рупия), каждая со своими странами: плательщик видит валюту своей страны и может выбрать другую на странице тарифов. Администратор может включать и отключать любую функцию для всех и выбирать, в какие тарифы она входит, в том числе базовые (проходные, защита секретов и чувствительных файлов, сессии агентов, кэш контекста и адаптивная маршрутизация); чего нет в тарифе, показывается как не входящее."$json$::jsonb),
  ('ja', 'docs.plans.usage', $json$"サイドバーの「プラン」（または Ctrl+K › プラン）で、各プランの内容を確認できます。「申し込む」はブラウザーで Stripe の支払いを開き、完了すると JayV が自動でプランを更新します。「サブスクリプションを管理」は Stripe のポータルを開き、カードやプランの変更、解約ができます。システム管理者はサイト（ダッシュボード › 管理 › プラン）でプランを作ります。保存すると各プランが Stripe の商品になり、有料プランには定期課金の価格も作られます。金額を変えると新しい価格が作られ、古い価格は販売停止になります。プランは Stripe に送信されてから販売されます。 有料プランには、他の通貨（米ドル、ユーロ、ポンド、レアル、カナダドル、豪ドル、スイスフラン、メキシコペソ、ルピー）の価格も設定でき、通貨ごとに適用する国を指定できます。支払う人には自国の通貨が表示され、プランのページで別の通貨を選ぶこともできます。 管理者は、コア機能（ゲート、秘密情報と機密ファイルの保護、エージェントのセッション、コンテキストキャッシュ、適応型ルーティング）を含むあらゆる機能を全員に対してオン・オフし、どのプランに含めるかを選べます。プランに含まれない機能は「含まれません」と表示されます。"$json$::jsonb),
  ('de', 'docs.plans.usage', $json$"Öffnen Sie Tarife in der Seitenleiste (oder Strg+K › Tarife), um zu sehen, was jeder Tarif enthält. Abonnieren öffnet die Stripe-Zahlung im Browser; ist sie abgeschlossen, aktualisiert JayV den Tarif selbst. Abo verwalten öffnet das Stripe-Portal, um Karte oder Tarif zu ändern und zu kündigen. Wer das System verwaltet, richtet die Tarife auf der Website ein (Dashboard › Administration › Tarife): Beim Speichern wird jeder Tarif zu einem Produkt in Stripe, ein kostenpflichtiger Tarif erhält seinen wiederkehrenden Preis; ändert sich der Betrag, entsteht ein neuer Preis und der alte wird aus dem Verkauf genommen. Ein Tarif wird erst verkauft, wenn er an Stripe gesendet wurde. Ein kostenpflichtiger Tarif kann auch Preise in anderen Währungen haben (Dollar, Euro, Pfund, Real, kanadischer und australischer Dollar, Schweizer Franken, mexikanischer Peso und Rupie), jeweils mit den Ländern, in denen sie gilt: Wer zahlt, sieht die Währung seines Landes und kann auf der Tarifseite eine andere wählen. Der Administrator kann jede Funktion für alle ein- oder ausschalten und wählen, in welchen Tarifen sie enthalten ist, auch die Kernfunktionen (Pforten, Schutz von Geheimnissen und sensiblen Dateien, Agentensitzungen, Kontext-Cache und adaptives Routing); was ein Tarif nicht bringt, erscheint als nicht enthalten."$json$::jsonb)
on conflict (locale, key) do update set value = excluded.value;

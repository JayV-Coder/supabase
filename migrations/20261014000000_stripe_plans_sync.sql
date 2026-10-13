-- App 0.97.0 e site 2.15.0: os planos do site vão sozinhos para o Stripe.
--
-- Até aqui o admin criava o produto e o preço no painel do Stripe e colava o
-- `price_...` no plano. Agora o admin só preenche o plano no site (nome, preço,
-- moeda, intervalo) e a Edge Function `billing` (ações `sync_plan` e
-- `archive_plan`) cria ou atualiza o produto e o preço no Stripe e grava os
-- ids de volta. Os ids ficam sob a guarda do servidor:
--   - `stripe_product_id`: o produto do plano no Stripe;
--   - `stripe_synced_at`: quando o Stripe recebeu o plano pela última vez; fica
--     vazio quando o admin mexe em nome, descrição, "à venda" ou preço, e o
--     checkout só vende plano em dia com o Stripe (a página não mostra um preço
--     e o Stripe cobra outro).
-- Quem escreve `stripe_product_id`, `stripe_price_id` e `stripe_synced_at` é a
-- service role da função; `admin_save_plan` (que roda com o token do admin)
-- não os muda: o gatilho abaixo devolve o valor antigo.
--
-- Pro e Enterprise nascem ao lado do Free (fora de venda, sem preço, com os
-- mesmos recursos dele) para o admin só definir o preço e ligar. O Free vira
-- um produto sem preço no Stripe.
--
-- Também: textos do admin de planos (o ID do preço deixou de ser digitado), a
-- seção Mods da documentação e a página Planos do manual, nos dez idiomas.
alter table public.plans
  add column stripe_product_id text check (stripe_product_id ~ '^prod_[A-Za-z0-9]{6,80}$'),
  add column stripe_synced_at timestamptz;
create unique index plans_product on public.plans (stripe_product_id) where stripe_product_id is not null;

create function public.plans_guard_stripe() returns trigger language plpgsql set search_path = '' as $$
begin
  -- Só o token de um usuário (o admin pelas RPCs `admin_*`) fica sem tocar nos
  -- ids do Stripe; a service role da função e as migrações escrevem à vontade.
  if coalesce((nullif(current_setting('request.jwt.claims', true), '')::jsonb)->>'role', '') = 'authenticated' then
    if tg_op = 'INSERT' then
      new.stripe_product_id := null;
      new.stripe_price_id := null;
      new.stripe_synced_at := null;
    else
      new.stripe_product_id := old.stripe_product_id;
      new.stripe_price_id := old.stripe_price_id;
      new.stripe_synced_at := old.stripe_synced_at;
      if (new.name, new.description, new.active, new.price_cents, new.currency, new.billing_interval)
         is distinct from (old.name, old.description, old.active, old.price_cents, old.currency, old.billing_interval) then
        new.stripe_synced_at := null;
      end if;
    end if;
  end if;
  return new;
end;
$$;
revoke execute on function public.plans_guard_stripe() from public, anon, authenticated;
create trigger plans_guard_stripe before insert or update on public.plans
  for each row execute function public.plans_guard_stripe();

-- Pro e Enterprise, fora de venda até o admin definir o preço.
insert into public.plans (key, name, description, position, active, is_default) values
  ('pro', 'Pro', '', 10, false, false),
  ('enterprise', 'Enterprise', '', 20, false, false)
on conflict (key) do nothing;

insert into public.plan_features (plan_key, feature_key, mode, default_on)
select v.plan_key, pf.feature_key, pf.mode, pf.default_on
from public.plan_features pf, (values ('pro'), ('enterprise')) as v(plan_key)
where pf.plan_key = 'free'
on conflict do nothing;

insert into public.translations (locale, key, value) values
  ('pt-BR', 'admin.plans.description', $json$"Quem não assina fica no plano padrão. Cada plano vira um produto no Stripe quando você salva; o plano pago também ganha o preço recorrente."$json$::jsonb),
  ('en', 'admin.plans.description', $json$"Anyone without a subscription stays on the default plan. Each plan becomes a product in Stripe when you save it; a paid plan also gets its recurring price."$json$::jsonb),
  ('es', 'admin.plans.description', $json$"Quien no se suscribe se queda en el plan predeterminado. Cada plan se convierte en un producto de Stripe al guardarlo; el plan de pago también recibe su precio recurrente."$json$::jsonb),
  ('zh-CN', 'admin.plans.description', $json$"未订阅的用户使用默认套餐。每个套餐在保存时会成为 Stripe 中的一个产品；付费套餐还会创建循环价格。"$json$::jsonb),
  ('hi', 'admin.plans.description', $json$"जो सदस्यता नहीं लेता वह डिफ़ॉल्ट प्लान पर रहता है। सहेजते ही हर प्लान Stripe में एक प्रोडक्ट बन जाता है; सशुल्क प्लान को आवर्ती कीमत भी मिलती है।"$json$::jsonb),
  ('ar', 'admin.plans.description', $json$"من لا يشترك يبقى على الخطة الافتراضية. تصبح كل خطة منتجًا في Stripe عند حفظها، وتحصل الخطة المدفوعة أيضًا على سعرها المتكرر."$json$::jsonb),
  ('fr', 'admin.plans.description', $json$"Sans abonnement, on reste sur le forfait par défaut. Chaque forfait devient un produit dans Stripe à l’enregistrement ; un forfait payant reçoit aussi son prix récurrent."$json$::jsonb),
  ('ru', 'admin.plans.description', $json$"Кто не подписан, остаётся на тарифе по умолчанию. При сохранении каждый тариф становится продуктом в Stripe; платный тариф получает ещё и регулярную цену."$json$::jsonb),
  ('ja', 'admin.plans.description', $json$"未契約の人はデフォルトのプランになります。各プランは保存すると Stripe の商品になり、有料プランには定期課金の価格も作られます。"$json$::jsonb),
  ('de', 'admin.plans.description', $json$"Wer nichts abonniert hat, bleibt im Standardtarif. Jeder Tarif wird beim Speichern zu einem Produkt in Stripe; ein kostenpflichtiger Tarif erhält zusätzlich seinen wiederkehrenden Preis."$json$::jsonb),
  ('pt-BR', 'admin.plan.priceHint', $json$"É o preço cobrado: ao salvar, o JayV cria o preço no Stripe. Trocar o valor cria um preço novo e tira o antigo de venda."$json$::jsonb),
  ('en', 'admin.plan.priceHint', $json$"This is the price charged: when you save, JayV creates the price in Stripe. Changing the amount creates a new price and takes the old one off sale."$json$::jsonb),
  ('es', 'admin.plan.priceHint', $json$"Es el precio que se cobra: al guardar, JayV crea el precio en Stripe. Cambiar el importe crea un precio nuevo y retira el anterior de la venta."$json$::jsonb),
  ('zh-CN', 'admin.plan.priceHint', $json$"这是实际收取的价格：保存时 JayV 会在 Stripe 中创建该价格。修改金额会创建新价格并下架旧价格。"$json$::jsonb),
  ('hi', 'admin.plan.priceHint', $json$"यही कीमत वसूली जाती है: सहेजते समय JayV Stripe में कीमत बनाता है। राशि बदलने पर नई कीमत बनती है और पुरानी बिक्री से हट जाती है।"$json$::jsonb),
  ('ar', 'admin.plan.priceHint', $json$"هذا هو السعر المحصَّل: عند الحفظ ينشئ JayV السعر في Stripe. تغيير المبلغ ينشئ سعرًا جديدًا ويوقف بيع السعر القديم."$json$::jsonb),
  ('fr', 'admin.plan.priceHint', $json$"C’est le prix facturé : à l’enregistrement, JayV crée le prix dans Stripe. Changer le montant crée un nouveau prix et retire l’ancien de la vente."$json$::jsonb),
  ('ru', 'admin.plan.priceHint', $json$"Это списываемая цена: при сохранении JayV создаёт цену в Stripe. Если изменить сумму, создаётся новая цена, а старая снимается с продажи."$json$::jsonb),
  ('ja', 'admin.plan.priceHint', $json$"請求される価格です。保存すると JayV が Stripe に価格を作成します。金額を変えると新しい価格が作られ、古い価格は販売停止になります。"$json$::jsonb),
  ('de', 'admin.plan.priceHint', $json$"Das ist der berechnete Preis: Beim Speichern legt JayV den Preis in Stripe an. Ändert sich der Betrag, entsteht ein neuer Preis und der alte wird aus dem Verkauf genommen."$json$::jsonb),
  ('pt-BR', 'admin.error.planInvalid', $json$"Confira os campos do plano: identificador, nome, moeda (3 letras), preço e intervalo."$json$::jsonb),
  ('en', 'admin.error.planInvalid', $json$"Check the plan fields: identifier, name, currency (3 letters), price and interval."$json$::jsonb),
  ('es', 'admin.error.planInvalid', $json$"Revisa los campos del plan: identificador, nombre, moneda (3 letras), precio e intervalo."$json$::jsonb),
  ('zh-CN', 'admin.error.planInvalid', $json$"请检查套餐字段：标识、名称、货币（3 个字母）、价格和周期。"$json$::jsonb),
  ('hi', 'admin.error.planInvalid', $json$"प्लान के फ़ील्ड जाँचें: पहचानकर्ता, नाम, मुद्रा (3 अक्षर), कीमत और अवधि।"$json$::jsonb),
  ('ar', 'admin.error.planInvalid', $json$"تحقق من حقول الخطة: المعرّف والاسم والعملة (3 أحرف) والسعر والفترة."$json$::jsonb),
  ('fr', 'admin.error.planInvalid', $json$"Vérifiez les champs du forfait : identifiant, nom, devise (3 lettres), prix et période."$json$::jsonb),
  ('ru', 'admin.error.planInvalid', $json$"Проверьте поля тарифа: идентификатор, название, валюту (3 буквы), цену и период."$json$::jsonb),
  ('ja', 'admin.error.planInvalid', $json$"プランの項目を確認してください：識別子、名前、通貨（3 文字）、価格、期間。"$json$::jsonb),
  ('de', 'admin.error.planInvalid', $json$"Prüfen Sie die Tarifangaben: Kennung, Name, Währung (3 Buchstaben), Preis und Intervall."$json$::jsonb),
  ('pt-BR', 'site.admin.plan.stripe.hint', $json$"Ao salvar, o plano é enviado ao Stripe (produto e, se estiver à venda, o preço). O plano só fica à venda no app depois de enviado."$json$::jsonb),
  ('en', 'site.admin.plan.stripe.hint', $json$"When you save, the plan is sent to Stripe (the product and, if it is on sale, the price). It only goes on sale in the app once it has been sent."$json$::jsonb),
  ('es', 'site.admin.plan.stripe.hint', $json$"Al guardar, el plan se envía a Stripe (el producto y, si está a la venta, el precio). Solo se vende en la app una vez enviado."$json$::jsonb),
  ('zh-CN', 'site.admin.plan.stripe.hint', $json$"保存时套餐会发送到 Stripe（产品；若在售，还包括价格）。发送完成后，应用中才会开始销售。"$json$::jsonb),
  ('hi', 'site.admin.plan.stripe.hint', $json$"सहेजते ही प्लान Stripe को भेजा जाता है (प्रोडक्ट और, बिक्री पर हो तो, कीमत)। भेजे जाने के बाद ही वह ऐप में बिक्री पर आता है।"$json$::jsonb),
  ('ar', 'site.admin.plan.stripe.hint', $json$"عند الحفظ تُرسَل الخطة إلى Stripe (المنتج، والسعر إن كانت معروضة للبيع). لا تُباع في التطبيق إلا بعد إرسالها."$json$::jsonb),
  ('fr', 'site.admin.plan.stripe.hint', $json$"À l’enregistrement, le forfait est envoyé à Stripe (le produit et, s’il est en vente, le prix). Il n’est en vente dans l’app qu’une fois envoyé."$json$::jsonb),
  ('ru', 'site.admin.plan.stripe.hint', $json$"При сохранении тариф отправляется в Stripe (продукт и, если он в продаже, цена). В приложении он продаётся только после отправки."$json$::jsonb),
  ('ja', 'site.admin.plan.stripe.hint', $json$"保存するとプランが Stripe に送られます（商品と、販売中なら価格）。送信が済んでからアプリで販売されます。"$json$::jsonb),
  ('de', 'site.admin.plan.stripe.hint', $json$"Beim Speichern wird der Tarif an Stripe gesendet (das Produkt und, wenn er im Verkauf ist, der Preis). In der App wird er erst nach dem Senden verkauft."$json$::jsonb),
  ('pt-BR', 'site.admin.plan.stripe.inStripe', $json$"No Stripe"$json$::jsonb),
  ('en', 'site.admin.plan.stripe.inStripe', $json$"In Stripe"$json$::jsonb),
  ('es', 'site.admin.plan.stripe.inStripe', $json$"En Stripe"$json$::jsonb),
  ('zh-CN', 'site.admin.plan.stripe.inStripe', $json$"已在 Stripe"$json$::jsonb),
  ('hi', 'site.admin.plan.stripe.inStripe', $json$"Stripe में"$json$::jsonb),
  ('ar', 'site.admin.plan.stripe.inStripe', $json$"في Stripe"$json$::jsonb),
  ('fr', 'site.admin.plan.stripe.inStripe', $json$"Dans Stripe"$json$::jsonb),
  ('ru', 'site.admin.plan.stripe.inStripe', $json$"В Stripe"$json$::jsonb),
  ('ja', 'site.admin.plan.stripe.inStripe', $json$"Stripe 登録済み"$json$::jsonb),
  ('de', 'site.admin.plan.stripe.inStripe', $json$"In Stripe"$json$::jsonb),
  ('pt-BR', 'site.admin.plan.stripe.pending', $json$"Não enviado ao Stripe"$json$::jsonb),
  ('en', 'site.admin.plan.stripe.pending', $json$"Not sent to Stripe"$json$::jsonb),
  ('es', 'site.admin.plan.stripe.pending', $json$"No enviado a Stripe"$json$::jsonb),
  ('zh-CN', 'site.admin.plan.stripe.pending', $json$"未发送到 Stripe"$json$::jsonb),
  ('hi', 'site.admin.plan.stripe.pending', $json$"Stripe को नहीं भेजा गया"$json$::jsonb),
  ('ar', 'site.admin.plan.stripe.pending', $json$"لم يُرسَل إلى Stripe"$json$::jsonb),
  ('fr', 'site.admin.plan.stripe.pending', $json$"Pas envoyé à Stripe"$json$::jsonb),
  ('ru', 'site.admin.plan.stripe.pending', $json$"Не отправлен в Stripe"$json$::jsonb),
  ('ja', 'site.admin.plan.stripe.pending', $json$"Stripe に未送信"$json$::jsonb),
  ('de', 'site.admin.plan.stripe.pending', $json$"Nicht an Stripe gesendet"$json$::jsonb),
  ('pt-BR', 'site.admin.plan.stripe.sync', $json$"Enviar ao Stripe"$json$::jsonb),
  ('en', 'site.admin.plan.stripe.sync', $json$"Send to Stripe"$json$::jsonb),
  ('es', 'site.admin.plan.stripe.sync', $json$"Enviar a Stripe"$json$::jsonb),
  ('zh-CN', 'site.admin.plan.stripe.sync', $json$"发送到 Stripe"$json$::jsonb),
  ('hi', 'site.admin.plan.stripe.sync', $json$"Stripe को भेजें"$json$::jsonb),
  ('ar', 'site.admin.plan.stripe.sync', $json$"إرسال إلى Stripe"$json$::jsonb),
  ('fr', 'site.admin.plan.stripe.sync', $json$"Envoyer à Stripe"$json$::jsonb),
  ('ru', 'site.admin.plan.stripe.sync', $json$"Отправить в Stripe"$json$::jsonb),
  ('ja', 'site.admin.plan.stripe.sync', $json$"Stripe に送信"$json$::jsonb),
  ('de', 'site.admin.plan.stripe.sync', $json$"An Stripe senden"$json$::jsonb),
  ('pt-BR', 'site.admin.plan.stripe.sent', $json$"Plano {plan} salvo e enviado ao Stripe."$json$::jsonb),
  ('en', 'site.admin.plan.stripe.sent', $json$"Plan {plan} saved and sent to Stripe."$json$::jsonb),
  ('es', 'site.admin.plan.stripe.sent', $json$"Plan {plan} guardado y enviado a Stripe."$json$::jsonb),
  ('zh-CN', 'site.admin.plan.stripe.sent', $json$"套餐 {plan} 已保存并发送到 Stripe。"$json$::jsonb),
  ('hi', 'site.admin.plan.stripe.sent', $json$"प्लान {plan} सहेजा गया और Stripe को भेजा गया।"$json$::jsonb),
  ('ar', 'site.admin.plan.stripe.sent', $json$"حُفظت الخطة {plan} وأُرسلت إلى Stripe."$json$::jsonb),
  ('fr', 'site.admin.plan.stripe.sent', $json$"Forfait {plan} enregistré et envoyé à Stripe."$json$::jsonb),
  ('ru', 'site.admin.plan.stripe.sent', $json$"Тариф {plan} сохранён и отправлен в Stripe."$json$::jsonb),
  ('ja', 'site.admin.plan.stripe.sent', $json$"プラン {plan} を保存し、Stripe に送信しました。"$json$::jsonb),
  ('de', 'site.admin.plan.stripe.sent', $json$"Tarif {plan} gespeichert und an Stripe gesendet."$json$::jsonb),
  ('pt-BR', 'site.admin.plan.stripe.savedNotSent', $json$"Plano {plan} salvo, mas não foi enviado ao Stripe: {reason}"$json$::jsonb),
  ('en', 'site.admin.plan.stripe.savedNotSent', $json$"Plan {plan} saved, but it was not sent to Stripe: {reason}"$json$::jsonb),
  ('es', 'site.admin.plan.stripe.savedNotSent', $json$"Plan {plan} guardado, pero no se envió a Stripe: {reason}"$json$::jsonb),
  ('zh-CN', 'site.admin.plan.stripe.savedNotSent', $json$"套餐 {plan} 已保存，但未能发送到 Stripe：{reason}"$json$::jsonb),
  ('hi', 'site.admin.plan.stripe.savedNotSent', $json$"प्लान {plan} सहेजा गया, पर Stripe को नहीं भेजा जा सका: {reason}"$json$::jsonb),
  ('ar', 'site.admin.plan.stripe.savedNotSent', $json$"حُفظت الخطة {plan} لكن لم تُرسَل إلى Stripe: {reason}"$json$::jsonb),
  ('fr', 'site.admin.plan.stripe.savedNotSent', $json$"Forfait {plan} enregistré, mais pas envoyé à Stripe : {reason}"$json$::jsonb),
  ('ru', 'site.admin.plan.stripe.savedNotSent', $json$"Тариф {plan} сохранён, но не отправлен в Stripe: {reason}"$json$::jsonb),
  ('ja', 'site.admin.plan.stripe.savedNotSent', $json$"プラン {plan} は保存しましたが、Stripe に送信できませんでした: {reason}"$json$::jsonb),
  ('de', 'site.admin.plan.stripe.savedNotSent', $json$"Tarif {plan} gespeichert, aber nicht an Stripe gesendet: {reason}"$json$::jsonb),
  ('pt-BR', 'site.admin.plan.stripe.error.config', $json$"o servidor está sem a chave do Stripe (segredo STRIPE_SECRET_KEY das Edge Functions)."$json$::jsonb),
  ('en', 'site.admin.plan.stripe.error.config', $json$"the server has no Stripe key (the STRIPE_SECRET_KEY Edge Function secret)."$json$::jsonb),
  ('es', 'site.admin.plan.stripe.error.config', $json$"el servidor no tiene la clave de Stripe (el secreto STRIPE_SECRET_KEY de las Edge Functions)."$json$::jsonb),
  ('zh-CN', 'site.admin.plan.stripe.error.config', $json$"服务器缺少 Stripe 密钥（Edge Functions 的 STRIPE_SECRET_KEY 机密）。"$json$::jsonb),
  ('hi', 'site.admin.plan.stripe.error.config', $json$"सर्वर में Stripe की कुंजी नहीं है (Edge Functions का STRIPE_SECRET_KEY सीक्रेट)।"$json$::jsonb),
  ('ar', 'site.admin.plan.stripe.error.config', $json$"الخادم بلا مفتاح Stripe (سر STRIPE_SECRET_KEY في Edge Functions)."$json$::jsonb),
  ('fr', 'site.admin.plan.stripe.error.config', $json$"le serveur n’a pas la clé Stripe (le secret STRIPE_SECRET_KEY des Edge Functions)."$json$::jsonb),
  ('ru', 'site.admin.plan.stripe.error.config', $json$"на сервере нет ключа Stripe (секрет STRIPE_SECRET_KEY у Edge Functions)."$json$::jsonb),
  ('ja', 'site.admin.plan.stripe.error.config', $json$"サーバーに Stripe のキーがありません（Edge Functions のシークレット STRIPE_SECRET_KEY）。"$json$::jsonb),
  ('de', 'site.admin.plan.stripe.error.config', $json$"Auf dem Server fehlt der Stripe-Schlüssel (das Edge-Function-Secret STRIPE_SECRET_KEY)."$json$::jsonb),
  ('pt-BR', 'site.admin.plan.stripe.error.price', $json$"defina preço, moeda e intervalo para vender este plano."$json$::jsonb),
  ('en', 'site.admin.plan.stripe.error.price', $json$"set a price, currency and interval to sell this plan."$json$::jsonb),
  ('es', 'site.admin.plan.stripe.error.price', $json$"define precio, moneda e intervalo para vender este plan."$json$::jsonb),
  ('zh-CN', 'site.admin.plan.stripe.error.price', $json$"请先设置价格、货币和周期才能销售此套餐。"$json$::jsonb),
  ('hi', 'site.admin.plan.stripe.error.price', $json$"इस प्लान को बेचने के लिए कीमत, मुद्रा और अवधि तय करें।"$json$::jsonb),
  ('ar', 'site.admin.plan.stripe.error.price', $json$"حدّد السعر والعملة والفترة لبيع هذه الخطة."$json$::jsonb),
  ('fr', 'site.admin.plan.stripe.error.price', $json$"définissez le prix, la devise et la période pour vendre ce forfait."$json$::jsonb),
  ('ru', 'site.admin.plan.stripe.error.price', $json$"задайте цену, валюту и период, чтобы продавать этот тариф."$json$::jsonb),
  ('ja', 'site.admin.plan.stripe.error.price', $json$"このプランを販売するには、価格、通貨、期間を設定してください。"$json$::jsonb),
  ('de', 'site.admin.plan.stripe.error.price', $json$"Legen Sie Preis, Währung und Intervall fest, um diesen Tarif zu verkaufen."$json$::jsonb),
  ('pt-BR', 'site.admin.plan.stripe.error.stripe', $json$"o Stripe recusou ou não respondeu ({message})."$json$::jsonb),
  ('en', 'site.admin.plan.stripe.error.stripe', $json$"Stripe refused the request or did not answer ({message})."$json$::jsonb),
  ('es', 'site.admin.plan.stripe.error.stripe', $json$"Stripe rechazó la solicitud o no respondió ({message})."$json$::jsonb),
  ('zh-CN', 'site.admin.plan.stripe.error.stripe', $json$"Stripe 拒绝了请求或没有响应（{message}）。"$json$::jsonb),
  ('hi', 'site.admin.plan.stripe.error.stripe', $json$"Stripe ने अनुरोध ठुकराया या जवाब नहीं दिया ({message})।"$json$::jsonb),
  ('ar', 'site.admin.plan.stripe.error.stripe', $json$"رفض Stripe الطلب أو لم يرد ({message})."$json$::jsonb),
  ('fr', 'site.admin.plan.stripe.error.stripe', $json$"Stripe a refusé la demande ou n’a pas répondu ({message})."$json$::jsonb),
  ('ru', 'site.admin.plan.stripe.error.stripe', $json$"Stripe отклонил запрос или не ответил ({message})."$json$::jsonb),
  ('ja', 'site.admin.plan.stripe.error.stripe', $json$"Stripe がリクエストを拒否したか、応答しませんでした（{message}）。"$json$::jsonb),
  ('de', 'site.admin.plan.stripe.error.stripe', $json$"Stripe hat die Anfrage abgelehnt oder nicht geantwortet ({message})."$json$::jsonb),
  ('pt-BR', 'site.admin.plan.stripe.free', $json$"O plano padrão vira um produto sem preço no Stripe."$json$::jsonb),
  ('en', 'site.admin.plan.stripe.free', $json$"The default plan becomes a product without a price in Stripe."$json$::jsonb),
  ('es', 'site.admin.plan.stripe.free', $json$"El plan predeterminado se convierte en un producto sin precio en Stripe."$json$::jsonb),
  ('zh-CN', 'site.admin.plan.stripe.free', $json$"默认套餐在 Stripe 中是没有价格的产品。"$json$::jsonb),
  ('hi', 'site.admin.plan.stripe.free', $json$"डिफ़ॉल्ट प्लान Stripe में बिना कीमत वाला प्रोडक्ट बनता है।"$json$::jsonb),
  ('ar', 'site.admin.plan.stripe.free', $json$"تصبح الخطة الافتراضية منتجًا بلا سعر في Stripe."$json$::jsonb),
  ('fr', 'site.admin.plan.stripe.free', $json$"Le forfait par défaut devient un produit sans prix dans Stripe."$json$::jsonb),
  ('ru', 'site.admin.plan.stripe.free', $json$"Тариф по умолчанию становится в Stripe продуктом без цены."$json$::jsonb),
  ('ja', 'site.admin.plan.stripe.free', $json$"デフォルトのプランは、Stripe では価格のない商品になります。"$json$::jsonb),
  ('de', 'site.admin.plan.stripe.free', $json$"Der Standardtarif wird in Stripe zu einem Produkt ohne Preis."$json$::jsonb),
  ('pt-BR', 'site.docs.category.mods', $json$"Mods"$json$::jsonb),
  ('en', 'site.docs.category.mods', $json$"Mods"$json$::jsonb),
  ('es', 'site.docs.category.mods', $json$"Mods"$json$::jsonb),
  ('zh-CN', 'site.docs.category.mods', $json$"模组"$json$::jsonb),
  ('hi', 'site.docs.category.mods', $json$"मॉड"$json$::jsonb),
  ('ar', 'site.docs.category.mods', $json$"الإضافات"$json$::jsonb),
  ('fr', 'site.docs.category.mods', $json$"Mods"$json$::jsonb),
  ('ru', 'site.docs.category.mods', $json$"Моды"$json$::jsonb),
  ('ja', 'site.docs.category.mods', $json$"Mod"$json$::jsonb),
  ('de', 'site.docs.category.mods', $json$"Mods"$json$::jsonb),
  ('pt-BR', 'docs.plans.title', $json$"Planos e assinatura"$json$::jsonb),
  ('en', 'docs.plans.title', $json$"Plans and subscription"$json$::jsonb),
  ('es', 'docs.plans.title', $json$"Planes y suscripción"$json$::jsonb),
  ('zh-CN', 'docs.plans.title', $json$"套餐与订阅"$json$::jsonb),
  ('hi', 'docs.plans.title', $json$"प्लान और सदस्यता"$json$::jsonb),
  ('ar', 'docs.plans.title', $json$"الخطط والاشتراك"$json$::jsonb),
  ('fr', 'docs.plans.title', $json$"Forfaits et abonnement"$json$::jsonb),
  ('ru', 'docs.plans.title', $json$"Тарифы и подписка"$json$::jsonb),
  ('ja', 'docs.plans.title', $json$"プランとサブスクリプション"$json$::jsonb),
  ('de', 'docs.plans.title', $json$"Tarife und Abo"$json$::jsonb),
  ('pt-BR', 'docs.plans.summary', $json$"JayV tem três planos — Free, Pro e Enterprise — e o plano decide quais recursos você tem. Free é o padrão de quem não assina; Pro e Enterprise são assinaturas pagas pelo Stripe."$json$::jsonb),
  ('en', 'docs.plans.summary', $json$"JayV has three plans — Free, Pro and Enterprise — and the plan decides which features you have. Free is the default for anyone without a subscription; Pro and Enterprise are subscriptions paid through Stripe."$json$::jsonb),
  ('es', 'docs.plans.summary', $json$"JayV tiene tres planes — Free, Pro y Enterprise — y el plan decide qué funciones tienes. Free es el predeterminado de quien no se suscribe; Pro y Enterprise son suscripciones que se pagan por Stripe."$json$::jsonb),
  ('zh-CN', 'docs.plans.summary', $json$"JayV 有三个套餐：Free、Pro 和 Enterprise，套餐决定你能使用哪些功能。Free 是未订阅用户的默认套餐；Pro 和 Enterprise 是通过 Stripe 付费的订阅。"$json$::jsonb),
  ('hi', 'docs.plans.summary', $json$"JayV के तीन प्लान हैं — Free, Pro और Enterprise — और प्लान तय करता है कि आपके पास कौन-सी सुविधाएँ हैं। Free उन सबके लिए डिफ़ॉल्ट है जिनकी सदस्यता नहीं है; Pro और Enterprise Stripe से भुगतान वाली सदस्यताएँ हैं।"$json$::jsonb),
  ('ar', 'docs.plans.summary', $json$"لدى JayV ثلاث خطط — Free وPro وEnterprise — وتحدد الخطة المزايا المتاحة لك. Free هي الافتراضية لمن لا اشتراك له؛ أما Pro وEnterprise فاشتراكان مدفوعان عبر Stripe."$json$::jsonb),
  ('fr', 'docs.plans.summary', $json$"JayV propose trois forfaits — Free, Pro et Enterprise — et le forfait décide des fonctionnalités dont vous disposez. Free est le forfait par défaut sans abonnement ; Pro et Enterprise sont des abonnements payés via Stripe."$json$::jsonb),
  ('ru', 'docs.plans.summary', $json$"В JayV три тарифа — Free, Pro и Enterprise — и тариф определяет, какие функции вам доступны. Free — тариф по умолчанию без подписки; Pro и Enterprise — платные подписки через Stripe."$json$::jsonb),
  ('ja', 'docs.plans.summary', $json$"JayV には Free、Pro、Enterprise の 3 つのプランがあり、プランによって使える機能が決まります。Free は未契約の人のデフォルトで、Pro と Enterprise は Stripe で支払うサブスクリプションです。"$json$::jsonb),
  ('de', 'docs.plans.summary', $json$"JayV hat drei Tarife – Free, Pro und Enterprise – und der Tarif bestimmt, welche Funktionen Sie haben. Free gilt standardmäßig ohne Abo; Pro und Enterprise sind über Stripe bezahlte Abos."$json$::jsonb),
  ('pt-BR', 'docs.plans.usage', $json$"Abra Planos na barra lateral (ou Ctrl+K › Planos) para ver o que cada plano inclui. Assinar abre o pagamento do Stripe no navegador e, quando ele termina, o JayV atualiza o plano sozinho; Gerenciar assinatura abre o portal do Stripe para trocar o cartão ou o plano e cancelar. Quem administra o sistema monta os planos no site (Dashboard › Administração › Planos): ao salvar, cada plano vira um produto no Stripe e o plano pago ganha o preço recorrente; trocar o valor cria um preço novo e tira o antigo de venda. Um plano só fica à venda depois de enviado ao Stripe."$json$::jsonb),
  ('en', 'docs.plans.usage', $json$"Open Plans in the sidebar (or Ctrl+K › Plans) to see what each plan includes. Subscribe opens Stripe's payment in the browser and, when it finishes, JayV updates the plan by itself; Manage subscription opens Stripe's portal to change the card or the plan and to cancel. Whoever administers the system builds the plans on the site (Dashboard › Administration › Plans): when you save, each plan becomes a product in Stripe and a paid plan gets its recurring price; changing the amount creates a new price and takes the old one off sale. A plan only goes on sale once it has been sent to Stripe."$json$::jsonb),
  ('es', 'docs.plans.usage', $json$"Abre Planes en la barra lateral (o Ctrl+K › Planes) para ver qué incluye cada plan. Suscribirse abre el pago de Stripe en el navegador y, al terminar, JayV actualiza el plan solo; Gestionar suscripción abre el portal de Stripe para cambiar la tarjeta o el plan y cancelar. Quien administra el sistema arma los planes en el sitio (Panel › Administración › Planes): al guardar, cada plan se convierte en un producto de Stripe y el plan de pago recibe su precio recurrente; cambiar el importe crea un precio nuevo y retira el anterior de la venta. Un plan solo se vende una vez enviado a Stripe."$json$::jsonb),
  ('zh-CN', 'docs.plans.usage', $json$"在侧边栏打开“套餐”（或 Ctrl+K › 套餐）查看每个套餐包含什么。“订阅”会在浏览器中打开 Stripe 支付，完成后 JayV 会自动更新套餐；“管理订阅”会打开 Stripe 门户，用于更换银行卡或套餐以及取消。系统管理员在网站（控制台 › 管理 › 套餐）中配置套餐：保存时，每个套餐都会成为 Stripe 中的一个产品，付费套餐还会创建循环价格；修改金额会创建新价格并下架旧价格。套餐发送到 Stripe 之后才会开始销售。"$json$::jsonb),
  ('hi', 'docs.plans.usage', $json$"हर प्लान में क्या शामिल है यह देखने के लिए साइडबार में प्लान खोलें (या Ctrl+K › प्लान)। सदस्यता लें ब्राउज़र में Stripe का भुगतान खोलता है और पूरा होते ही JayV प्लान अपने आप बदल देता है; सदस्यता प्रबंधित करें Stripe का पोर्टल खोलता है, जहाँ कार्ड या प्लान बदला और सदस्यता रद्द की जा सकती है। सिस्टम का प्रशासक प्लान साइट पर बनाता है (डैशबोर्ड › प्रशासन › प्लान): सहेजते ही हर प्लान Stripe में प्रोडक्ट बन जाता है और सशुल्क प्लान को आवर्ती कीमत मिलती है; राशि बदलने पर नई कीमत बनती है और पुरानी बिक्री से हट जाती है। प्लान Stripe को भेजे जाने के बाद ही बिक्री पर आता है।"$json$::jsonb),
  ('ar', 'docs.plans.usage', $json$"افتح «الخطط» من الشريط الجانبي (أو Ctrl+K › الخطط) لترى ما تشمله كل خطة. «اشتراك» يفتح دفع Stripe في المتصفح، وعند انتهائه يحدّث JayV الخطة تلقائيًا؛ و«إدارة الاشتراك» يفتح بوابة Stripe لتغيير البطاقة أو الخطة والإلغاء. يبني مسؤول النظام الخطط في الموقع (لوحة التحكم › الإدارة › الخطط): عند الحفظ تصبح كل خطة منتجًا في Stripe وتحصل الخطة المدفوعة على سعرها المتكرر؛ وتغيير المبلغ ينشئ سعرًا جديدًا ويوقف بيع القديم. ولا تُعرض الخطة للبيع إلا بعد إرسالها إلى Stripe."$json$::jsonb),
  ('fr', 'docs.plans.usage', $json$"Ouvrez Forfaits dans la barre latérale (ou Ctrl+K › Forfaits) pour voir ce que chaque forfait inclut. S’abonner ouvre le paiement Stripe dans le navigateur et, une fois terminé, JayV met le forfait à jour tout seul ; Gérer l’abonnement ouvre le portail Stripe pour changer de carte ou de forfait et résilier. L’administrateur du système monte les forfaits sur le site (Tableau de bord › Administration › Forfaits) : à l’enregistrement, chaque forfait devient un produit dans Stripe et un forfait payant reçoit son prix récurrent ; changer le montant crée un nouveau prix et retire l’ancien de la vente. Un forfait n’est en vente qu’une fois envoyé à Stripe."$json$::jsonb),
  ('ru', 'docs.plans.usage', $json$"Откройте «Тарифы» на боковой панели (или Ctrl+K › Тарифы), чтобы увидеть, что входит в каждый тариф. «Оформить подписку» открывает оплату Stripe в браузере, а когда она завершается, JayV сам обновляет тариф; «Управление подпиской» открывает портал Stripe, где можно сменить карту или тариф и отменить подписку. Администратор системы настраивает тарифы на сайте (Панель › Администрирование › Тарифы): при сохранении каждый тариф становится продуктом в Stripe, а платный получает регулярную цену; смена суммы создаёт новую цену и снимает старую с продажи. Тариф поступает в продажу только после отправки в Stripe."$json$::jsonb),
  ('ja', 'docs.plans.usage', $json$"サイドバーの「プラン」（または Ctrl+K › プラン）で、各プランの内容を確認できます。「申し込む」はブラウザーで Stripe の支払いを開き、完了すると JayV が自動でプランを更新します。「サブスクリプションを管理」は Stripe のポータルを開き、カードやプランの変更、解約ができます。システム管理者はサイト（ダッシュボード › 管理 › プラン）でプランを作ります。保存すると各プランが Stripe の商品になり、有料プランには定期課金の価格も作られます。金額を変えると新しい価格が作られ、古い価格は販売停止になります。プランは Stripe に送信されてから販売されます。"$json$::jsonb),
  ('de', 'docs.plans.usage', $json$"Öffnen Sie Tarife in der Seitenleiste (oder Strg+K › Tarife), um zu sehen, was jeder Tarif enthält. Abonnieren öffnet die Stripe-Zahlung im Browser; ist sie abgeschlossen, aktualisiert JayV den Tarif selbst. Abo verwalten öffnet das Stripe-Portal, um Karte oder Tarif zu ändern und zu kündigen. Wer das System verwaltet, richtet die Tarife auf der Website ein (Dashboard › Administration › Tarife): Beim Speichern wird jeder Tarif zu einem Produkt in Stripe, ein kostenpflichtiger Tarif erhält seinen wiederkehrenden Preis; ändert sich der Betrag, entsteht ein neuer Preis und der alte wird aus dem Verkauf genommen. Ein Tarif wird erst verkauft, wenn er an Stripe gesendet wurde."$json$::jsonb),
  ('pt-BR', 'whatsNew.item.plansStripe.title', $json$"Planos Free, Pro e Enterprise no Stripe"$json$::jsonb),
  ('en', 'whatsNew.item.plansStripe.title', $json$"Free, Pro and Enterprise plans in Stripe"$json$::jsonb),
  ('es', 'whatsNew.item.plansStripe.title', $json$"Planes Free, Pro y Enterprise en Stripe"$json$::jsonb),
  ('zh-CN', 'whatsNew.item.plansStripe.title', $json$"Stripe 中的 Free、Pro 和 Enterprise 套餐"$json$::jsonb),
  ('hi', 'whatsNew.item.plansStripe.title', $json$"Stripe में Free, Pro और Enterprise प्लान"$json$::jsonb),
  ('ar', 'whatsNew.item.plansStripe.title', $json$"خطط Free وPro وEnterprise في Stripe"$json$::jsonb),
  ('fr', 'whatsNew.item.plansStripe.title', $json$"Forfaits Free, Pro et Enterprise dans Stripe"$json$::jsonb),
  ('ru', 'whatsNew.item.plansStripe.title', $json$"Тарифы Free, Pro и Enterprise в Stripe"$json$::jsonb),
  ('ja', 'whatsNew.item.plansStripe.title', $json$"Stripe の Free・Pro・Enterprise プラン"$json$::jsonb),
  ('de', 'whatsNew.item.plansStripe.title', $json$"Tarife Free, Pro und Enterprise in Stripe"$json$::jsonb),
  ('pt-BR', 'whatsNew.item.plansStripe.detail', $json$"Os planos são criados no site (Administração › Planos) e enviados sozinhos ao Stripe como produtos, com o preço recorrente dos pagos. Um plano só fica à venda depois de enviado. A página Planos ganhou a sua página na Documentação e o seu tutorial."$json$::jsonb),
  ('en', 'whatsNew.item.plansStripe.detail', $json$"Plans are created on the site (Administration › Plans) and sent to Stripe on their own as products, with the recurring price for the paid ones. A plan only goes on sale once it has been sent. The Plans page now has its page in the Documentation and its tutorial."$json$::jsonb),
  ('es', 'whatsNew.item.plansStripe.detail', $json$"Los planes se crean en el sitio (Administración › Planes) y se envían solos a Stripe como productos, con el precio recurrente en los de pago. Un plan solo se vende una vez enviado. La página Planes tiene ahora su página en la Documentación y su tutorial."$json$::jsonb),
  ('zh-CN', 'whatsNew.item.plansStripe.detail', $json$"套餐在网站（管理 › 套餐）中创建，并自动作为产品发送到 Stripe，付费套餐还带有循环价格。套餐发送之后才会开始销售。“套餐”页面现在有了文档页面和教程。"$json$::jsonb),
  ('hi', 'whatsNew.item.plansStripe.detail', $json$"प्लान साइट पर (प्रशासन › प्लान) बनाए जाते हैं और अपने आप Stripe को प्रोडक्ट के रूप में भेज दिए जाते हैं; सशुल्क प्लान के साथ आवर्ती कीमत भी जाती है। प्लान भेजे जाने के बाद ही बिक्री पर आता है। प्लान पेज को अब दस्तावेज़ीकरण में अपना पेज और ट्यूटोरियल मिल गया है।"$json$::jsonb),
  ('ar', 'whatsNew.item.plansStripe.detail', $json$"تُنشأ الخطط في الموقع (الإدارة › الخطط) وتُرسَل تلقائيًا إلى Stripe كمنتجات، ومعها السعر المتكرر للخطط المدفوعة. ولا تُعرض الخطة للبيع إلا بعد إرسالها. صار لصفحة الخطط الآن صفحتها في التوثيق ودليلها التعليمي."$json$::jsonb),
  ('fr', 'whatsNew.item.plansStripe.detail', $json$"Les forfaits se créent sur le site (Administration › Forfaits) et partent tout seuls vers Stripe comme produits, avec le prix récurrent pour les payants. Un forfait n’est en vente qu’une fois envoyé. La page Forfaits a maintenant sa page dans la Documentation et son tutoriel."$json$::jsonb),
  ('ru', 'whatsNew.item.plansStripe.detail', $json$"Тарифы создаются на сайте (Администрирование › Тарифы) и сами отправляются в Stripe как продукты, а у платных — с регулярной ценой. Тариф поступает в продажу только после отправки. У страницы «Тарифы» теперь есть своя страница в документации и свой обучающий тур."$json$::jsonb),
  ('ja', 'whatsNew.item.plansStripe.detail', $json$"プランはサイト（管理 › プラン）で作成され、自動的に商品として Stripe に送信されます。有料プランには定期課金の価格も付きます。プランは送信されてから販売されます。「プラン」画面にドキュメントのページとチュートリアルが加わりました。"$json$::jsonb),
  ('de', 'whatsNew.item.plansStripe.detail', $json$"Tarife werden auf der Website (Administration › Tarife) angelegt und automatisch als Produkte an Stripe gesendet, die kostenpflichtigen mit ihrem wiederkehrenden Preis. Ein Tarif wird erst nach dem Senden verkauft. Die Seite Tarife hat jetzt ihre Seite in der Dokumentation und ihr Tutorial."$json$::jsonb),
  ('pt-BR', 'whatsNew.item.modsDocs.title', $json$"Mods têm a sua própria seção na Documentação"$json$::jsonb),
  ('en', 'whatsNew.item.modsDocs.title', $json$"Mods have their own section in the Documentation"$json$::jsonb),
  ('es', 'whatsNew.item.modsDocs.title', $json$"Los mods tienen su propia sección en la Documentación"$json$::jsonb),
  ('zh-CN', 'whatsNew.item.modsDocs.title', $json$"文档中的模组独立成章"$json$::jsonb),
  ('hi', 'whatsNew.item.modsDocs.title', $json$"दस्तावेज़ीकरण में मॉड का अपना अलग खंड"$json$::jsonb),
  ('ar', 'whatsNew.item.modsDocs.title', $json$"للإضافات قسمها الخاص في التوثيق"$json$::jsonb),
  ('fr', 'whatsNew.item.modsDocs.title', $json$"Les mods ont leur propre section dans la Documentation"$json$::jsonb),
  ('ru', 'whatsNew.item.modsDocs.title', $json$"У модов теперь свой раздел в документации"$json$::jsonb),
  ('ja', 'whatsNew.item.modsDocs.title', $json$"ドキュメントに Mod 専用のセクションができました"$json$::jsonb),
  ('de', 'whatsNew.item.modsDocs.title', $json$"Mods haben einen eigenen Abschnitt in der Dokumentation"$json$::jsonb),
  ('pt-BR', 'whatsNew.item.modsDocs.detail', $json$"As páginas de mods saíram de “Agentes e modelos” e foram para a seção Mods: o sistema de mods é genérico e não se limita aos agentes."$json$::jsonb),
  ('en', 'whatsNew.item.modsDocs.detail', $json$"The mod pages left “Agents and models” and moved to the Mods section: the mod system is generic and not limited to agents."$json$::jsonb),
  ('es', 'whatsNew.item.modsDocs.detail', $json$"Las páginas de mods salieron de «Agentes y modelos» y pasaron a la sección Mods: el sistema de mods es genérico y no se limita a los agentes."$json$::jsonb),
  ('zh-CN', 'whatsNew.item.modsDocs.detail', $json$"模组页面已从“智能体与模型”移到“模组”章节：模组系统是通用的，不只限于智能体。"$json$::jsonb),
  ('hi', 'whatsNew.item.modsDocs.detail', $json$"मॉड के पेज “एजेंट और मॉडल” से हटकर मॉड खंड में आ गए हैं: मॉड प्रणाली सामान्य है, केवल एजेंटों तक सीमित नहीं।"$json$::jsonb),
  ('ar', 'whatsNew.item.modsDocs.detail', $json$"انتقلت صفحات الإضافات من «الوكلاء والنماذج» إلى قسم الإضافات: نظام الإضافات عام ولا يقتصر على الوكلاء."$json$::jsonb),
  ('fr', 'whatsNew.item.modsDocs.detail', $json$"Les pages des mods ont quitté « Agents et modèles » pour la section Mods : le système de mods est générique et ne se limite pas aux agents."$json$::jsonb),
  ('ru', 'whatsNew.item.modsDocs.detail', $json$"Страницы о модах переехали из «Агенты и модели» в раздел «Моды»: система модов универсальна и не ограничена агентами."$json$::jsonb),
  ('ja', 'whatsNew.item.modsDocs.detail', $json$"Mod のページを「エージェントとモデル」から Mod セクションに移しました。Mod の仕組みは汎用で、エージェントだけに限られないためです。"$json$::jsonb),
  ('de', 'whatsNew.item.modsDocs.detail', $json$"Die Mod-Seiten sind aus „Agenten und Modelle“ in den Abschnitt Mods umgezogen: Das Mod-System ist generisch und nicht auf Agenten beschränkt."$json$::jsonb),
  ('pt-BR', 'tutorial.tour.plans', $json$"Planos"$json$::jsonb),
  ('en', 'tutorial.tour.plans', $json$"Plans"$json$::jsonb),
  ('es', 'tutorial.tour.plans', $json$"Planes"$json$::jsonb),
  ('zh-CN', 'tutorial.tour.plans', $json$"套餐"$json$::jsonb),
  ('hi', 'tutorial.tour.plans', $json$"प्लान"$json$::jsonb),
  ('ar', 'tutorial.tour.plans', $json$"الخطط"$json$::jsonb),
  ('fr', 'tutorial.tour.plans', $json$"Forfaits"$json$::jsonb),
  ('ru', 'tutorial.tour.plans', $json$"Тарифы"$json$::jsonb),
  ('ja', 'tutorial.tour.plans', $json$"プラン"$json$::jsonb),
  ('de', 'tutorial.tour.plans', $json$"Tarife"$json$::jsonb)
on conflict (locale, key) do update set value = excluded.value;

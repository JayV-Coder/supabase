-- v0.50.1: correções da revisão de ponta a ponta.

-- 1. Textos e idiomas: a leitura segue aberta para a tela de login (anon e
-- `aal1`), mas escrever passa a exigir o segundo fator, como em qualquer
-- outra tabela. Antes, um admin com só a senha vazada reescrevia os textos
-- que todo mundo lê.
create policy "segundo fator escreve" on public.translations as restrictive for insert to authenticated
  with check ((select public.second_factor_ok()));
create policy "segundo fator muda" on public.translations as restrictive for update to authenticated
  using ((select public.second_factor_ok())) with check ((select public.second_factor_ok()));
create policy "segundo fator apaga" on public.translations as restrictive for delete to authenticated
  using ((select public.second_factor_ok()));
create policy "segundo fator escreve" on public.locales as restrictive for insert to authenticated
  with check ((select public.second_factor_ok()));
create policy "segundo fator muda" on public.locales as restrictive for update to authenticated
  using ((select public.second_factor_ok())) with check ((select public.second_factor_ok()));
create policy "segundo fator apaga" on public.locales as restrictive for delete to authenticated
  using ((select public.second_factor_ok()));

-- A checagem do PostgREST só deixa passar sem o segundo fator a *leitura* dos
-- textos e dos idiomas.
create or replace function public.require_second_factor() returns void language plpgsql stable security definer set search_path = '' as $$
begin
  if coalesce(current_setting('request.path', true), '') in ('/translations', '/locales')
     and coalesce(current_setting('request.method', true), 'GET') in ('GET', 'HEAD') then
    return;
  end if;
  if not public.second_factor_ok() then
    raise sqlstate 'PT403' using message = 'second factor required', hint = 'aal2';
  end if;
end
$$;

-- 2. A chamada ao Jev que a TypeSafe recusou (429/5xx) ou que nem chegou lá
-- volta para o limite do dia: as novas tentativas do app não gastam a cota em
-- dobro.
create function public.jev_refund_call() returns void language plpgsql security definer set search_path = '' as $$
begin
  if (select auth.uid()) is null then
    raise exception 'sem sessão' using errcode = '28000';
  end if;
  update public.jev_usage set calls = greatest(calls - 1, 0)
  where user_id = (select auth.uid()) and day = (now() at time zone 'utc')::date;
end;
$$;
revoke execute on function public.jev_refund_call() from public, anon;
grant execute on function public.jev_refund_call() to authenticated;

-- 3. Os textos desta versão, nos dez idiomas, e o botão do GitHub que só
-- tinha português e inglês.
insert into public.translations (locale, key, value) values
  ('pt-BR', 'turn.notRetryable', $json$"O pedido {turn} não falhou, então não pode ser repetido."$json$::jsonb),
  ('pt-BR', 'whatsNew.item.queueUnstuck.title', $json$"A fila de pedidos não trava mais"$json$::jsonb),
  ('pt-BR', 'whatsNew.item.queueUnstuck.detail', $json$"Limpar um chat com pedidos esperando travava a fila de todos os chats; uma tabela recusada pelo servidor parava os pedidos como se faltasse rede; e a busca da pergunta do agente segurava o próximo pedido. Pedidos na fila do mesmo chat também iam ao modelo fora de ordem e repetidos."$json$::jsonb),
  ('pt-BR', 'whatsNew.item.editsKept.title', $json$"Nada do que você digita se perde"$json$::jsonb),
  ('pt-BR', 'whatsNew.item.editsKept.detail', $json$"A resposta a uma pergunta volta para a caixa quando o envio falha, voltar às Configurações não descarta mais o que não foi salvo, /plan e /build não avisam sucesso quando o modo foi recusado, e um clique duplo não manda duas respostas."$json$::jsonb),
  ('pt-BR', 'whatsNew.item.safetyFixes.title', $json$"Correções de segurança"$json$::jsonb),
  ('pt-BR', 'whatsNew.item.safetyFixes.detail', $json$"Alterar os textos do app no servidor passa a exigir o segundo fator, o painel ao vivo não lê arquivos fora da pasta do projeto, o limite diário do Jev não some com uma configuração inválida e novas tentativas não gastam a cota."$json$::jsonb),
  ('en', 'turn.notRetryable', $json$"Request {turn} is not failed, so it can't be retried."$json$::jsonb),
  ('en', 'whatsNew.item.queueUnstuck.title', $json$"The request queue no longer gets stuck"$json$::jsonb),
  ('en', 'whatsNew.item.queueUnstuck.detail', $json$"Clearing a chat with waiting requests stalled the queue for every chat; a table refused by the server stopped requests as if the network were down; and looking for the agent's question held up the next request. Queued requests in the same chat also reached the model out of order and duplicated."$json$::jsonb),
  ('en', 'whatsNew.item.editsKept.title', $json$"Nothing you type gets lost"$json$::jsonb),
  ('en', 'whatsNew.item.editsKept.detail', $json$"An answer to a question goes back to the box when sending fails, returning to Settings no longer discards unsaved edits, /plan and /build no longer report success when the mode was refused, and a double click no longer sends two answers."$json$::jsonb),
  ('en', 'whatsNew.item.safetyFixes.title', $json$"Security fixes"$json$::jsonb),
  ('en', 'whatsNew.item.safetyFixes.detail', $json$"Changing the app's texts on the server now requires the second factor, the live panel no longer reads files outside the project folder, Jev's daily limit no longer disappears with an invalid setting, and retries no longer spend the quota."$json$::jsonb),
  ('es', 'turn.notRetryable', $json$"La petición {turn} no falló, así que no se puede repetir."$json$::jsonb),
  ('es', 'whatsNew.item.queueUnstuck.title', $json$"La cola de peticiones ya no se atasca"$json$::jsonb),
  ('es', 'whatsNew.item.queueUnstuck.detail', $json$"Vaciar un chat con peticiones en espera atascaba la cola de todos los chats; una tabla rechazada por el servidor detenía las peticiones como si no hubiera red; y buscar la pregunta del agente retenía la siguiente petición. Las peticiones en cola del mismo chat también llegaban al modelo desordenadas y repetidas."$json$::jsonb),
  ('es', 'whatsNew.item.editsKept.title', $json$"No se pierde nada de lo que escribes"$json$::jsonb),
  ('es', 'whatsNew.item.editsKept.detail', $json$"La respuesta a una pregunta vuelve al cuadro cuando el envío falla, volver a Configuración ya no descarta lo no guardado, /plan y /build ya no avisan éxito si el modo fue rechazado, y un doble clic ya no envía dos respuestas."$json$::jsonb),
  ('es', 'whatsNew.item.safetyFixes.title', $json$"Correcciones de seguridad"$json$::jsonb),
  ('es', 'whatsNew.item.safetyFixes.detail', $json$"Cambiar los textos de la app en el servidor ahora exige el segundo factor, el panel en vivo ya no lee archivos fuera de la carpeta del proyecto, el límite diario de Jev ya no desaparece con un ajuste inválido y los reintentos ya no gastan la cuota."$json$::jsonb),
  ('zh-CN', 'turn.notRetryable', $json$"请求 {turn} 没有失败，因此不能重试。"$json$::jsonb),
  ('zh-CN', 'whatsNew.item.queueUnstuck.title', $json$"请求队列不再卡住"$json$::jsonb),
  ('zh-CN', 'whatsNew.item.queueUnstuck.detail', $json$"清空有等待请求的聊天会卡住所有聊天的队列；服务器拒绝某个表时，请求会像断网一样停止；查找智能体的问题会拖住下一个请求。同一聊天中排队的请求还会乱序且重复地发给模型。"$json$::jsonb),
  ('zh-CN', 'whatsNew.item.editsKept.title', $json$"你输入的内容不再丢失"$json$::jsonb),
  ('zh-CN', 'whatsNew.item.editsKept.detail', $json$"发送失败时，问题的回答会回到输入框；返回设置不再丢弃未保存的修改；模式被拒绝时 /plan 和 /build 不再提示成功；双击也不再发送两次回答。"$json$::jsonb),
  ('zh-CN', 'whatsNew.item.safetyFixes.title', $json$"安全修复"$json$::jsonb),
  ('zh-CN', 'whatsNew.item.safetyFixes.detail', $json$"在服务器上修改应用文本现在需要第二因素；实时面板不再读取项目文件夹以外的文件；Jev 的每日限额不会因无效设置而失效；重试也不再消耗配额。"$json$::jsonb),
  ('hi', 'turn.notRetryable', $json$"अनुरोध {turn} विफल नहीं हुआ, इसलिए दोबारा नहीं चलाया जा सकता।"$json$::jsonb),
  ('hi', 'whatsNew.item.queueUnstuck.title', $json$"अनुरोधों की कतार अब अटकती नहीं"$json$::jsonb),
  ('hi', 'whatsNew.item.queueUnstuck.detail', $json$"प्रतीक्षा में अनुरोधों वाली चैट साफ़ करने से सभी चैट की कतार अटक जाती थी; सर्वर द्वारा अस्वीकार की गई तालिका अनुरोधों को ऐसे रोक देती थी जैसे नेटवर्क न हो; और एजेंट का प्रश्न खोजने से अगला अनुरोध रुक जाता था। एक ही चैट के कतार वाले अनुरोध भी मॉडल तक गलत क्रम में और दोहराकर पहुँचते थे।"$json$::jsonb),
  ('hi', 'whatsNew.item.editsKept.title', $json$"आप जो लिखते हैं वह अब खोता नहीं"$json$::jsonb),
  ('hi', 'whatsNew.item.editsKept.detail', $json$"भेजना विफल होने पर प्रश्न का उत्तर बॉक्स में लौट आता है, सेटिंग्स पर लौटने से बिना सहेजे बदलाव नहीं मिटते, मोड अस्वीकार होने पर /plan और /build सफलता नहीं बताते, और डबल क्लिक से दो उत्तर नहीं जाते।"$json$::jsonb),
  ('hi', 'whatsNew.item.safetyFixes.title', $json$"सुरक्षा सुधार"$json$::jsonb),
  ('hi', 'whatsNew.item.safetyFixes.detail', $json$"सर्वर पर ऐप के टेक्स्ट बदलने के लिए अब दूसरा फ़ैक्टर चाहिए, लाइव पैनल प्रोजेक्ट फ़ोल्डर के बाहर की फ़ाइलें नहीं पढ़ता, Jev की दैनिक सीमा अमान्य सेटिंग से गायब नहीं होती, और दोबारा कोशिशें कोटा नहीं खर्च करतीं।"$json$::jsonb),
  ('ar', 'turn.notRetryable', $json$"الطلب {turn} لم يفشل، لذا لا يمكن إعادة المحاولة."$json$::jsonb),
  ('ar', 'whatsNew.item.queueUnstuck.title', $json$"لم تعد قائمة الطلبات تتوقف"$json$::jsonb),
  ('ar', 'whatsNew.item.queueUnstuck.detail', $json$"كان مسح دردشة فيها طلبات منتظرة يوقف قائمة كل الدردشات؛ وكان جدول يرفضه الخادم يوقف الطلبات كأن الشبكة مقطوعة؛ وكان البحث عن سؤال الوكيل يؤخر الطلب التالي. كما كانت طلبات الدردشة نفسها تصل إلى النموذج بترتيب خاطئ ومكررة."$json$::jsonb),
  ('ar', 'whatsNew.item.editsKept.title', $json$"لم يعد يضيع شيء مما تكتبه"$json$::jsonb),
  ('ar', 'whatsNew.item.editsKept.detail', $json$"يعود جواب السؤال إلى المربع عند فشل الإرسال، ولم تعد العودة إلى الإعدادات تتجاهل التعديلات غير المحفوظة، ولم يعد /plan و/build يعلنان النجاح عند رفض الوضع، ولم يعد النقر المزدوج يرسل جوابين."$json$::jsonb),
  ('ar', 'whatsNew.item.safetyFixes.title', $json$"إصلاحات أمنية"$json$::jsonb),
  ('ar', 'whatsNew.item.safetyFixes.detail', $json$"صار تغيير نصوص التطبيق على الخادم يتطلب العامل الثاني، ولم تعد اللوحة المباشرة تقرأ ملفات خارج مجلد المشروع، ولم يعد الحد اليومي لـ Jev يختفي بإعداد غير صالح، ولم تعد إعادة المحاولة تستهلك الحصة."$json$::jsonb),
  ('fr', 'turn.notRetryable', $json$"La demande {turn} n'a pas échoué, elle ne peut donc pas être relancée."$json$::jsonb),
  ('fr', 'whatsNew.item.queueUnstuck.title', $json$"La file des demandes ne se bloque plus"$json$::jsonb),
  ('fr', 'whatsNew.item.queueUnstuck.detail', $json$"Vider un chat avec des demandes en attente bloquait la file de tous les chats ; une table refusée par le serveur arrêtait les demandes comme si le réseau était coupé ; et la recherche de la question de l'agent retenait la demande suivante. Les demandes en file d'un même chat arrivaient aussi au modèle dans le désordre et en double."$json$::jsonb),
  ('fr', 'whatsNew.item.editsKept.title', $json$"Plus rien de ce que vous tapez ne se perd"$json$::jsonb),
  ('fr', 'whatsNew.item.editsKept.detail', $json$"La réponse à une question revient dans la zone de saisie si l'envoi échoue, revenir aux Paramètres n'efface plus les modifications non enregistrées, /plan et /build n'annoncent plus de succès quand le mode a été refusé, et un double clic n'envoie plus deux réponses."$json$::jsonb),
  ('fr', 'whatsNew.item.safetyFixes.title', $json$"Correctifs de sécurité"$json$::jsonb),
  ('fr', 'whatsNew.item.safetyFixes.detail', $json$"Modifier les textes de l'app sur le serveur exige désormais le second facteur, le panneau en direct ne lit plus de fichiers hors du dossier du projet, la limite quotidienne de Jev ne disparaît plus avec un réglage invalide et les nouvelles tentatives ne consomment plus le quota."$json$::jsonb),
  ('ru', 'turn.notRetryable', $json$"Запрос {turn} не завершился ошибкой, поэтому его нельзя повторить."$json$::jsonb),
  ('ru', 'whatsNew.item.queueUnstuck.title', $json$"Очередь запросов больше не зависает"$json$::jsonb),
  ('ru', 'whatsNew.item.queueUnstuck.detail', $json$"Очистка чата с ожидающими запросами останавливала очередь всех чатов; таблица, отклонённая сервером, останавливала запросы, будто нет сети; поиск вопроса агента задерживал следующий запрос. Запросы из очереди одного чата также приходили к модели не по порядку и повторно."$json$::jsonb),
  ('ru', 'whatsNew.item.editsKept.title', $json$"Ничего из набранного больше не теряется"$json$::jsonb),
  ('ru', 'whatsNew.item.editsKept.detail', $json$"Ответ на вопрос возвращается в поле ввода, если отправка не удалась; возврат в Настройки больше не сбрасывает несохранённые правки; /plan и /build не сообщают об успехе, если режим отклонён; двойной щелчок больше не отправляет два ответа."$json$::jsonb),
  ('ru', 'whatsNew.item.safetyFixes.title', $json$"Исправления безопасности"$json$::jsonb),
  ('ru', 'whatsNew.item.safetyFixes.detail', $json$"Изменение текстов приложения на сервере теперь требует второго фактора, панель в реальном времени не читает файлы вне папки проекта, дневной лимит Jev не исчезает из-за неверной настройки, а повторные попытки не расходуют квоту."$json$::jsonb),
  ('ja', 'turn.notRetryable', $json$"リクエスト {turn} は失敗していないため、再試行できません。"$json$::jsonb),
  ('ja', 'whatsNew.item.queueUnstuck.title', $json$"リクエストのキューが止まらなくなりました"$json$::jsonb),
  ('ja', 'whatsNew.item.queueUnstuck.detail', $json$"待機中のリクエストがあるチャットを消去すると全チャットのキューが止まり、サーバーが拒否したテーブルがあるとネットワーク切断のようにリクエストが止まり、エージェントの質問の検出が次のリクエストを待たせていました。同じチャットのキュー内リクエストも順序が乱れ重複してモデルに届いていました。"$json$::jsonb),
  ('ja', 'whatsNew.item.editsKept.title', $json$"入力した内容が失われなくなりました"$json$::jsonb),
  ('ja', 'whatsNew.item.editsKept.detail', $json$"送信に失敗すると質問への回答が入力欄に戻り、設定に戻っても未保存の変更が消えず、モードが拒否されたときに /plan と /build が成功と表示せず、ダブルクリックで回答が 2 回送られなくなりました。"$json$::jsonb),
  ('ja', 'whatsNew.item.safetyFixes.title', $json$"セキュリティ修正"$json$::jsonb),
  ('ja', 'whatsNew.item.safetyFixes.detail', $json$"サーバー上でアプリのテキストを変更するには第 2 要素が必要になり、ライブパネルはプロジェクトフォルダー外のファイルを読まず、Jev の 1 日の上限は無効な設定で無効にならず、再試行でクォータを消費しなくなりました。"$json$::jsonb),
  ('de', 'turn.notRetryable', $json$"Anfrage {turn} ist nicht fehlgeschlagen und kann daher nicht wiederholt werden."$json$::jsonb),
  ('de', 'whatsNew.item.queueUnstuck.title', $json$"Die Anfragewarteschlange bleibt nicht mehr hängen"$json$::jsonb),
  ('de', 'whatsNew.item.queueUnstuck.detail', $json$"Das Leeren eines Chats mit wartenden Anfragen blockierte die Warteschlange aller Chats; eine vom Server abgelehnte Tabelle stoppte Anfragen, als gäbe es kein Netz; und die Suche nach der Frage des Agenten hielt die nächste Anfrage auf. Wartende Anfragen desselben Chats kamen außerdem ungeordnet und doppelt beim Modell an."$json$::jsonb),
  ('de', 'whatsNew.item.editsKept.title', $json$"Nichts, was Sie tippen, geht mehr verloren"$json$::jsonb),
  ('de', 'whatsNew.item.editsKept.detail', $json$"Eine Antwort auf eine Frage kommt bei einem Sendefehler ins Eingabefeld zurück, die Rückkehr zu den Einstellungen verwirft keine ungespeicherten Änderungen mehr, /plan und /build melden keinen Erfolg mehr, wenn der Modus abgelehnt wurde, und ein Doppelklick sendet keine zwei Antworten mehr."$json$::jsonb),
  ('de', 'whatsNew.item.safetyFixes.title', $json$"Sicherheitskorrekturen"$json$::jsonb),
  ('de', 'whatsNew.item.safetyFixes.detail', $json$"Das Ändern der App-Texte auf dem Server erfordert jetzt den zweiten Faktor, das Live-Panel liest keine Dateien außerhalb des Projektordners mehr, das Tageslimit von Jev verschwindet nicht mehr durch eine ungültige Einstellung, und Wiederholungen verbrauchen kein Kontingent mehr."$json$::jsonb),
  ('es', 'auth.github', $json$"Continuar con GitHub"$json$::jsonb),
  ('zh-CN', 'auth.github', $json$"使用 GitHub 继续"$json$::jsonb),
  ('hi', 'auth.github', $json$"GitHub के साथ जारी रखें"$json$::jsonb),
  ('ar', 'auth.github', $json$"المتابعة باستخدام GitHub"$json$::jsonb),
  ('fr', 'auth.github', $json$"Continuer avec GitHub"$json$::jsonb),
  ('ru', 'auth.github', $json$"Продолжить с GitHub"$json$::jsonb),
  ('ja', 'auth.github', $json$"GitHub で続行"$json$::jsonb),
  ('de', 'auth.github', $json$"Mit GitHub fortfahren"$json$::jsonb)
on conflict (locale, key) do update set value = excluded.value;

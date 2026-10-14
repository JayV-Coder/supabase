-- v0.101.3: com uma permissão do chat sempre ligada pela organização, os
-- comandos específicos que ela cobre aparecem marcados e travados no seletor
-- de permissões. Só traduções.

insert into public.translations (locale, key, value) values
  ('pt-BR', 'whatsNew.item.chatPermissionsCommandsOn.title', $json$"Comandos cobertos por uma permissão sempre ligada aparecem marcados"$json$::jsonb),
  ('en', 'whatsNew.item.chatPermissionsCommandsOn.title', $json$"Commands covered by an always-on permission show as ticked"$json$::jsonb),
  ('es', 'whatsNew.item.chatPermissionsCommandsOn.title', $json$"Los comandos cubiertos por un permiso siempre activo aparecen marcados"$json$::jsonb),
  ('zh-CN', 'whatsNew.item.chatPermissionsCommandsOn.title', $json$"被始终开启的权限覆盖的命令会显示为已勾选"$json$::jsonb),
  ('hi', 'whatsNew.item.chatPermissionsCommandsOn.title', $json$"हमेशा चालू अनुमति से कवर किए गए कमांड चुने हुए दिखते हैं"$json$::jsonb),
  ('ar', 'whatsNew.item.chatPermissionsCommandsOn.title', $json$"الأوامر التي يغطيها إذن مفعّل دائمًا تظهر محددة"$json$::jsonb),
  ('fr', 'whatsNew.item.chatPermissionsCommandsOn.title', $json$"Les commandes couvertes par une permission toujours activée apparaissent cochées"$json$::jsonb),
  ('ru', 'whatsNew.item.chatPermissionsCommandsOn.title', $json$"Команды, охваченные всегда включённым разрешением, отмечены"$json$::jsonb),
  ('ja', 'whatsNew.item.chatPermissionsCommandsOn.title', $json$"常にオンの権限がカバーするコマンドはチェック済みで表示されます"$json$::jsonb),
  ('de', 'whatsNew.item.chatPermissionsCommandsOn.title', $json$"Von einer immer aktiven Berechtigung abgedeckte Befehle erscheinen angehakt"$json$::jsonb),
  ('pt-BR', 'whatsNew.item.chatPermissionsCommandsOn.detail', $json$"Quando a organização deixa Rodar comandos, Git ou Rede sempre ligada, a lista de comandos específicos marca e trava os comandos que essa permissão cobre, com \"Sempre ligada por <organização>\"."$json$::jsonb),
  ('en', 'whatsNew.item.chatPermissionsCommandsOn.detail', $json$"When the organization keeps Run commands, Git or Network always on, the specific-commands list ticks and locks the commands that permission covers, labelled \"Always on by <organization>\"."$json$::jsonb),
  ('es', 'whatsNew.item.chatPermissionsCommandsOn.detail', $json$"Cuando la organización deja Ejecutar comandos, Git o Red siempre activos, la lista de comandos específicos marca y bloquea los comandos que ese permiso cubre, con \"Siempre activo por <organización>\"."$json$::jsonb),
  ('zh-CN', 'whatsNew.item.chatPermissionsCommandsOn.detail', $json$"当组织将“运行命令”、Git 或网络设为始终开启时，特定命令列表会勾选并锁定该权限覆盖的命令，并标注“由 <组织> 始终开启”。"$json$::jsonb),
  ('hi', 'whatsNew.item.chatPermissionsCommandsOn.detail', $json$"जब संगठन कमांड चलाना, Git या नेटवर्क को हमेशा चालू रखता है, तो विशिष्ट कमांड सूची उस अनुमति से कवर कमांड को चुनकर लॉक कर देती है, \"<संगठन> द्वारा हमेशा चालू\" के साथ।"$json$::jsonb),
  ('ar', 'whatsNew.item.chatPermissionsCommandsOn.detail', $json$"عندما تُبقي المؤسسة تشغيل الأوامر أو Git أو الشبكة مفعّلة دائمًا، تحدد قائمة الأوامر المحددة الأوامر التي يغطيها هذا الإذن وتقفلها مع عبارة \"مفعّل دائمًا من <المؤسسة>\"."$json$::jsonb),
  ('fr', 'whatsNew.item.chatPermissionsCommandsOn.detail', $json$"Quand l'organisation garde Exécuter des commandes, Git ou Réseau toujours activé, la liste des commandes spécifiques coche et verrouille les commandes couvertes, avec « Toujours activé par <organisation> »."$json$::jsonb),
  ('ru', 'whatsNew.item.chatPermissionsCommandsOn.detail', $json$"Когда организация оставляет «Выполнять команды», Git или сеть всегда включёнными, список отдельных команд отмечает и блокирует охваченные команды с подписью «Всегда включено организацией <организация>»."$json$::jsonb),
  ('ja', 'whatsNew.item.chatPermissionsCommandsOn.detail', $json$"組織が「コマンド実行」「Git」「ネットワーク」を常にオンにすると、個別コマンドの一覧でその権限がカバーするコマンドがチェックされロックされ、「<組織> により常にオン」と表示されます。"$json$::jsonb),
  ('de', 'whatsNew.item.chatPermissionsCommandsOn.detail', $json$"Hält die Organisation „Befehle ausführen“, Git oder Netzwerk immer aktiv, hakt die Liste der einzelnen Befehle die abgedeckten Befehle an und sperrt sie, mit „Immer aktiv durch <Organisation>“."$json$::jsonb)
on conflict (locale, key) do update set value = excluded.value;

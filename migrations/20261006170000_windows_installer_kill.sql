-- v0.68.1: o instalador do Windows não para mais em "Failed to kill JayV"
-- (novidades da versão).

insert into public.translations (locale, key, value) values
  ('en', 'whatsNew.item.windowsInstallerKill.title', $json$"Windows updates no longer stop at \"Failed to kill JayV\""$json$::jsonb),
  ('en', 'whatsNew.item.windowsInstallerKill.detail', $json$"The Windows installer now waits for JayV to finish closing after an update, then closes any JayV process still running, including agent helpers, instead of giving up."$json$::jsonb),
  ('pt-BR', 'whatsNew.item.windowsInstallerKill.title', $json$"Atualizações no Windows não param mais em \"Failed to kill JayV\""$json$::jsonb),
  ('pt-BR', 'whatsNew.item.windowsInstallerKill.detail', $json$"O instalador do Windows agora espera o JayV terminar de fechar depois de uma atualização e encerra qualquer processo do JayV que ainda esteja rodando, inclusive os auxiliares dos agentes, em vez de desistir."$json$::jsonb),
  ('es', 'whatsNew.item.windowsInstallerKill.title', $json$"Las actualizaciones en Windows ya no se detienen en \"Failed to kill JayV\""$json$::jsonb),
  ('es', 'whatsNew.item.windowsInstallerKill.detail', $json$"El instalador de Windows ahora espera a que JayV termine de cerrarse tras una actualización y cierra cualquier proceso de JayV que siga en ejecución, incluidos los auxiliares de los agentes, en lugar de rendirse."$json$::jsonb),
  ('fr', 'whatsNew.item.windowsInstallerKill.title', $json$"Les mises à jour sous Windows ne s'arrêtent plus sur « Failed to kill JayV »"$json$::jsonb),
  ('fr', 'whatsNew.item.windowsInstallerKill.detail', $json$"Le programme d'installation Windows attend désormais que JayV finisse de se fermer après une mise à jour, puis ferme tout processus JayV encore actif, y compris les auxiliaires des agents, au lieu d'abandonner."$json$::jsonb),
  ('de', 'whatsNew.item.windowsInstallerKill.title', $json$"Updates unter Windows bleiben nicht mehr bei „Failed to kill JayV“ hängen"$json$::jsonb),
  ('de', 'whatsNew.item.windowsInstallerKill.detail', $json$"Das Windows-Installationsprogramm wartet nach einem Update jetzt, bis JayV vollständig beendet ist, und schließt dann alle noch laufenden JayV-Prozesse, auch die Hilfsprozesse der Agenten, statt abzubrechen."$json$::jsonb),
  ('ru', 'whatsNew.item.windowsInstallerKill.title', $json$"Обновления в Windows больше не останавливаются на «Failed to kill JayV»"$json$::jsonb),
  ('ru', 'whatsNew.item.windowsInstallerKill.detail', $json$"Установщик Windows теперь ждёт, пока JayV закроется после обновления, а затем завершает все ещё работающие процессы JayV, включая вспомогательные процессы агентов, вместо того чтобы сдаваться."$json$::jsonb),
  ('zh-CN', 'whatsNew.item.windowsInstallerKill.title', $json$"Windows 更新不再停在“Failed to kill JayV”"$json$::jsonb),
  ('zh-CN', 'whatsNew.item.windowsInstallerKill.detail', $json$"Windows 安装程序现在会在更新后等待 JayV 完全关闭，然后结束仍在运行的所有 JayV 进程（包括代理的辅助进程），而不是直接放弃。"$json$::jsonb),
  ('ja', 'whatsNew.item.windowsInstallerKill.title', $json$"Windows の更新が「Failed to kill JayV」で止まらなくなりました"$json$::jsonb),
  ('ja', 'whatsNew.item.windowsInstallerKill.detail', $json$"Windows インストーラーは更新後に JayV が閉じ終わるのを待ち、まだ動いている JayV のプロセス（エージェントの補助プロセスを含む）を終了します。途中で諦めることはありません。"$json$::jsonb),
  ('ar', 'whatsNew.item.windowsInstallerKill.title', $json$"لم تعد التحديثات على Windows تتوقف عند \"Failed to kill JayV\""$json$::jsonb),
  ('ar', 'whatsNew.item.windowsInstallerKill.detail', $json$"ينتظر مثبّت Windows الآن حتى ينتهي JayV من الإغلاق بعد التحديث، ثم يغلق أي عملية JayV لا تزال تعمل، بما في ذلك العمليات المساعدة للوكلاء، بدلًا من التوقف."$json$::jsonb),
  ('hi', 'whatsNew.item.windowsInstallerKill.title', $json$"Windows पर अपडेट अब \"Failed to kill JayV\" पर नहीं रुकते"$json$::jsonb),
  ('hi', 'whatsNew.item.windowsInstallerKill.detail', $json$"Windows इंस्टॉलर अब अपडेट के बाद JayV के पूरी तरह बंद होने का इंतज़ार करता है, फिर JayV की जो भी प्रक्रिया अभी चल रही हो, एजेंटों की सहायक प्रक्रियाओं समेत, उसे बंद कर देता है, हार नहीं मानता।"$json$::jsonb)
on conflict (locale, key) do update set value = excluded.value;

-- v0.70.1: o JayV responde sempre no idioma escolhido no app (novidades da
-- versão).

insert into public.translations (locale, key, value) values
  ('pt-BR', 'whatsNew.item.replyLanguage.title', $json$"O JayV sempre responde no idioma do app"$json$::jsonb),
  ('en', 'whatsNew.item.replyLanguage.title', $json$"JayV always replies in the language of the app"$json$::jsonb),
  ('es', 'whatsNew.item.replyLanguage.title', $json$"JayV siempre responde en el idioma de la app"$json$::jsonb),
  ('zh-CN', 'whatsNew.item.replyLanguage.title', $json$"JayV 始终使用应用的语言回复"$json$::jsonb),
  ('hi', 'whatsNew.item.replyLanguage.title', $json$"JayV हमेशा ऐप की भाषा में जवाब देता है"$json$::jsonb),
  ('ar', 'whatsNew.item.replyLanguage.title', $json$"يرد JayV دائمًا بلغة التطبيق"$json$::jsonb),
  ('fr', 'whatsNew.item.replyLanguage.title', $json$"JayV répond toujours dans la langue de l’application"$json$::jsonb),
  ('ru', 'whatsNew.item.replyLanguage.title', $json$"JayV всегда отвечает на языке приложения"$json$::jsonb),
  ('ja', 'whatsNew.item.replyLanguage.title', $json$"JayV は常にアプリの言語で返信します"$json$::jsonb),
  ('de', 'whatsNew.item.replyLanguage.title', $json$"JayV antwortet immer in der Sprache der App"$json$::jsonb),
  ('pt-BR', 'whatsNew.item.replyLanguage.detail', $json$"Às vezes a resposta vinha em outro idioma: o idioma escolhido era trocado por inglês quando a lista de idiomas não carregava a tempo, e os agentes liam a instrução perdida no meio de um texto longo em inglês. Agora o JayV mantém o idioma salvo, avisa o núcleo logo na abertura e repete o idioma no fim de cada pedido enviado a um modelo."$json$::jsonb),
  ('en', 'whatsNew.item.replyLanguage.detail', $json$"Sometimes the reply came in another language: the language you chose was swapped for English when the language list did not load in time, and the agents read it buried in a long English instruction. JayV now keeps your saved language, tells the core about it right at startup, and repeats it at the end of every request sent to a model."$json$::jsonb),
  ('es', 'whatsNew.item.replyLanguage.detail', $json$"A veces la respuesta llegaba en otro idioma: el idioma elegido se cambiaba por inglés cuando la lista de idiomas no cargaba a tiempo, y los agentes leían la instrucción perdida dentro de un texto largo en inglés. Ahora JayV conserva el idioma guardado, se lo comunica al núcleo desde el arranque y lo repite al final de cada solicitud enviada a un modelo."$json$::jsonb),
  ('zh-CN', 'whatsNew.item.replyLanguage.detail', $json$"有时回复会用另一种语言：当语言列表没有及时加载时，你选择的语言会被换成英文，而且代理读到的这条指令埋在一长段英文说明里。现在 JayV 会保留你保存的语言，启动时就告知核心，并在发送给模型的每个请求末尾重复一遍。"$json$::jsonb),
  ('hi', 'whatsNew.item.replyLanguage.detail', $json$"कभी-कभी जवाब किसी और भाषा में आता था: भाषा सूची समय पर लोड न होने पर चुनी हुई भाषा की जगह अंग्रेज़ी ले लेती थी, और एजेंट उस निर्देश को लंबे अंग्रेज़ी पाठ के बीच दबा हुआ पढ़ते थे। अब JayV आपकी सहेजी हुई भाषा रखता है, शुरू होते ही कोर को बता देता है और मॉडल को भेजे हर अनुरोध के अंत में उसे दोहराता है।"$json$::jsonb),
  ('ar', 'whatsNew.item.replyLanguage.detail', $json$"كان الرد يأتي أحيانًا بلغة أخرى: كانت اللغة التي اخترتها تُستبدل بالإنجليزية حين لا تُحمَّل قائمة اللغات في الوقت المناسب، وكان الوكلاء يقرؤون التعليمة مدفونة داخل نص إنجليزي طويل. الآن يحتفظ JayV باللغة المحفوظة، ويُبلغ النواة بها عند البدء، ويكررها في نهاية كل طلب يُرسل إلى نموذج."$json$::jsonb),
  ('fr', 'whatsNew.item.replyLanguage.detail', $json$"Parfois la réponse arrivait dans une autre langue : la langue choisie était remplacée par l’anglais quand la liste des langues ne se chargeait pas à temps, et les agents lisaient la consigne noyée dans un long texte en anglais. JayV conserve désormais la langue enregistrée, la transmet au cœur dès le démarrage et la répète à la fin de chaque requête envoyée à un modèle."$json$::jsonb),
  ('ru', 'whatsNew.item.replyLanguage.detail', $json$"Иногда ответ приходил на другом языке: выбранный язык заменялся английским, если список языков не успевал загрузиться, а агенты читали указание, затерянное в длинном английском тексте. Теперь JayV сохраняет выбранный язык, сообщает его ядру сразу при запуске и повторяет в конце каждого запроса к модели."$json$::jsonb),
  ('ja', 'whatsNew.item.replyLanguage.detail', $json$"返信が別の言語で届くことがありました。言語一覧の読み込みが間に合わないと選んだ言語が英語に置き換わり、エージェントも長い英語の指示の中に埋もれたその指定を読んでいました。JayV は保存した言語を保持し、起動直後にコアへ伝え、モデルへ送るすべてのリクエストの末尾でも繰り返すようになりました。"$json$::jsonb),
  ('de', 'whatsNew.item.replyLanguage.detail', $json$"Manchmal kam die Antwort in einer anderen Sprache: Die gewählte Sprache wurde durch Englisch ersetzt, wenn die Sprachliste nicht rechtzeitig geladen wurde, und die Agenten lasen die Vorgabe vergraben in einem langen englischen Text. JayV behält jetzt die gespeicherte Sprache, teilt sie dem Kern gleich beim Start mit und wiederholt sie am Ende jeder Anfrage an ein Modell."$json$::jsonb)
on conflict (locale, key) do update set value = excluded.value;

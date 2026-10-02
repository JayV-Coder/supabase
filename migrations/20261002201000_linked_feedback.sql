-- O retorno do vínculo de contas: o aviso de que o provedor foi vinculado e o
-- de que ele já entra em outra conta do JayV, agora com o nome do provedor e
-- o caminho para trazê-lo.

insert into public.translations (locale, key, value) values
  ('pt-BR', 'linked.done', $json$"{provider} foi vinculado à sua conta."$json$::jsonb),
  ('pt-BR', 'linked.taken', $json$"Esta conta do {provider} já entra em outra conta do JayV. Para trazê-la para cá, entre com o {provider}, defina uma senha, desvincule o {provider} naquela conta e tente de novo."$json$::jsonb),
  ('en', 'linked.done', $json$"{provider} is now linked to your account."$json$::jsonb),
  ('en', 'linked.taken', $json$"This {provider} account already signs in to another JayV account. To bring it here, sign in with {provider}, set a password, unlink {provider} in that account and try again."$json$::jsonb),
  ('es', 'linked.done', $json$"{provider} se vinculó a tu cuenta."$json$::jsonb),
  ('es', 'linked.taken', $json$"Esta cuenta de {provider} ya inicia sesión en otra cuenta de JayV. Para traerla aquí, inicia sesión con {provider}, define una contraseña, desvincula {provider} en esa cuenta y vuelve a intentarlo."$json$::jsonb),
  ('zh-CN', 'linked.done', $json$"{provider} 已关联到你的账户。"$json$::jsonb),
  ('zh-CN', 'linked.taken', $json$"此 {provider} 账户已用于登录另一个 JayV 账户。要将其关联到这里，请使用 {provider} 登录，设置密码，在那个账户中取消关联 {provider}，然后重试。"$json$::jsonb),
  ('hi', 'linked.done', $json$"{provider} आपके खाते से लिंक हो गया है।"$json$::jsonb),
  ('hi', 'linked.taken', $json$"यह {provider} खाता पहले से किसी दूसरे JayV खाते में साइन इन करता है। इसे यहाँ लाने के लिए {provider} से साइन इन करें, पासवर्ड सेट करें, उस खाते में {provider} को अनलिंक करें और फिर से कोशिश करें।"$json$::jsonb),
  ('ar', 'linked.done', $json$"تم ربط {provider} بحسابك."$json$::jsonb),
  ('ar', 'linked.taken', $json$"حساب {provider} هذا يسجّل الدخول بالفعل إلى حساب JayV آخر. لنقله إلى هنا، سجّل الدخول باستخدام {provider}، وعيّن كلمة مرور، وألغِ ربط {provider} في ذلك الحساب، ثم حاول مرة أخرى."$json$::jsonb),
  ('fr', 'linked.done', $json$"{provider} est maintenant lié à votre compte."$json$::jsonb),
  ('fr', 'linked.taken', $json$"Ce compte {provider} se connecte déjà à un autre compte JayV. Pour le rattacher ici, connectez-vous avec {provider}, définissez un mot de passe, dissociez {provider} de ce compte et réessayez."$json$::jsonb),
  ('ru', 'linked.done', $json$"{provider} привязан к вашей учётной записи."$json$::jsonb),
  ('ru', 'linked.taken', $json$"Эта учётная запись {provider} уже используется для входа в другую учётную запись JayV. Чтобы перенести её сюда, войдите через {provider}, задайте пароль, отвяжите {provider} в той учётной записи и попробуйте снова."$json$::jsonb),
  ('ja', 'linked.done', $json$"{provider} をアカウントに連携しました。"$json$::jsonb),
  ('ja', 'linked.taken', $json$"この {provider} アカウントは、すでに別の JayV アカウントへのサインインに使われています。こちらに連携するには、{provider} でサインインしてパスワードを設定し、そのアカウントで {provider} の連携を解除してから、もう一度お試しください。"$json$::jsonb),
  ('de', 'linked.done', $json$"{provider} ist jetzt mit deinem Konto verknüpft."$json$::jsonb),
  ('de', 'linked.taken', $json$"Dieses {provider}-Konto meldet sich bereits bei einem anderen JayV-Konto an. Um es hierher zu holen, melde dich mit {provider} an, lege ein Passwort fest, trenne {provider} in jenem Konto und versuche es erneut."$json$::jsonb)
on conflict (locale, key) do update set value = excluded.value;

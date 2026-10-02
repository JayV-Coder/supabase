-- O código do e-mail que libera a primeira senha não tem sempre 6 dígitos: o
-- tamanho segue o "Email OTP Length" do projeto (de 6 a 10). A dica deixa de
-- citar o número para não mandar a pessoa cortar um código de 8.

insert into public.translations (locale, key, value) values
  ('pt-BR', 'security.codeSent', $json$"Enviamos um código para {email}."$json$::jsonb),
  ('en', 'security.codeSent', $json$"We sent a code to {email}."$json$::jsonb),
  ('es', 'security.codeSent', $json$"Enviamos un código a {email}."$json$::jsonb),
  ('zh-CN', 'security.codeSent', $json$"我们已向 {email} 发送了验证码。"$json$::jsonb),
  ('hi', 'security.codeSent', $json$"हमने {email} पर एक कोड भेजा है।"$json$::jsonb),
  ('ar', 'security.codeSent', $json$"أرسلنا رمزًا إلى {email}."$json$::jsonb),
  ('fr', 'security.codeSent', $json$"Nous avons envoyé un code à {email}."$json$::jsonb),
  ('ru', 'security.codeSent', $json$"Мы отправили код на {email}."$json$::jsonb),
  ('ja', 'security.codeSent', $json$"{email} にコードを送信しました。"$json$::jsonb),
  ('de', 'security.codeSent', $json$"Wir haben einen Code an {email} gesendet."$json$::jsonb)
on conflict (locale, key) do update set value = excluded.value;

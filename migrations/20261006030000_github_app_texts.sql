-- Site 1.4.5: o GitHub conecta pelo GitHub App, com a tela do GitHub de
-- escolher a conta ou a organização a cada clique. O aviso de quando a
-- instalação fica esperando a aprovação do dono da organização, nos dez idiomas.
insert into public.translations (locale, key, value) values
  ('pt-BR', 'site.org.git.requested', $json$"O {provider} enviou a instalação para o dono da organização aprovar. Depois da aprovação, clique no provedor de novo."$json$::jsonb),
  ('en', 'site.org.git.requested', $json$"{provider} sent the installation for the organization owner's approval. Once it is approved, click the provider again."$json$::jsonb),
  ('es', 'site.org.git.requested', $json$"{provider} envió la instalación para que la apruebe el dueño de la organización. Cuando la apruebe, vuelve a hacer clic en el proveedor."$json$::jsonb),
  ('zh-CN', 'site.org.git.requested', $json$"{provider} 已将安装请求发送给组织所有者审批。批准后，请再次点击该提供方。"$json$::jsonb),
  ('hi', 'site.org.git.requested', $json$"{provider} ने इंस्टॉलेशन को संगठन के मालिक की मंज़ूरी के लिए भेजा है। मंज़ूरी मिलने के बाद प्रदाता पर फिर से क्लिक करें।"$json$::jsonb),
  ('ar', 'site.org.git.requested', $json$"أرسل {provider} التثبيت إلى مالك المؤسسة للموافقة عليه. بعد الموافقة، انقر على المزوّد مرة أخرى."$json$::jsonb),
  ('fr', 'site.org.git.requested', $json$"{provider} a envoyé l'installation au propriétaire de l'organisation pour approbation. Une fois approuvée, cliquez à nouveau sur le fournisseur."$json$::jsonb),
  ('ru', 'site.org.git.requested', $json$"{provider} отправил установку на одобрение владельцу организации. После одобрения нажмите на провайдера ещё раз."$json$::jsonb),
  ('ja', 'site.org.git.requested', $json$"{provider} はインストールを組織のオーナーの承認待ちとして送信しました。承認されたら、もう一度プロバイダーをクリックしてください。"$json$::jsonb),
  ('de', 'site.org.git.requested', $json$"{provider} hat die Installation dem Eigentümer der Organisation zur Genehmigung geschickt. Sobald sie genehmigt ist, klicke erneut auf den Anbieter."$json$::jsonb)
on conflict (locale, key) do update set value = excluded.value;

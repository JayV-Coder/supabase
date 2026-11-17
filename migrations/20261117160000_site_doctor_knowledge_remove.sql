-- Site: o Integration AI Doctor no site (`/doctor`), bloco 8: Base de conhecimento (botão de remover, depois da revisão).
--
-- A Base de conhecimento (Tela 14): os documentos da Organização e a Base global, a busca e o
-- envio de documentos. Chaves `site.doctor.*`, nos dez idiomas.
--
-- Não é migração do schema `doctor`: só grava em `public.translations` e vai pelo `db push`.

insert into public.translations (locale, key, value) values
  ('pt-BR', 'site.doctor.knowledge.remove', $json$"Remover"$json$::jsonb),
  ('en', 'site.doctor.knowledge.remove', $json$"Remove"$json$::jsonb),
  ('es', 'site.doctor.knowledge.remove', $json$"Eliminar"$json$::jsonb),
  ('zh-CN', 'site.doctor.knowledge.remove', $json$"删除"$json$::jsonb),
  ('hi', 'site.doctor.knowledge.remove', $json$"हटाएँ"$json$::jsonb),
  ('ar', 'site.doctor.knowledge.remove', $json$"إزالة"$json$::jsonb),
  ('fr', 'site.doctor.knowledge.remove', $json$"Supprimer"$json$::jsonb),
  ('ru', 'site.doctor.knowledge.remove', $json$"Удалить"$json$::jsonb),
  ('ja', 'site.doctor.knowledge.remove', $json$"削除"$json$::jsonb),
  ('de', 'site.doctor.knowledge.remove', $json$"Entfernen"$json$::jsonb)
on conflict (locale, key) do update set value = excluded.value;

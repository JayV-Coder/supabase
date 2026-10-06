-- Site 2.0.2: "Selecionar todos" na lista de adicionar repositórios, com o
-- limite de quantos entram de uma vez, nos dez idiomas.
insert into public.translations (locale, key, value) values
  ('pt-BR', 'site.org.repos.pick.selectAll', $json$"Selecionar todos"$json$::jsonb),
  ('pt-BR', 'site.org.repos.pick.limit', $json$"Até {max} de cada vez"$json$::jsonb),
  ('en', 'site.org.repos.pick.selectAll', $json$"Select all"$json$::jsonb),
  ('en', 'site.org.repos.pick.limit', $json$"Up to {max} at a time"$json$::jsonb),
  ('es', 'site.org.repos.pick.selectAll', $json$"Seleccionar todos"$json$::jsonb),
  ('es', 'site.org.repos.pick.limit', $json$"Hasta {max} a la vez"$json$::jsonb),
  ('zh-CN', 'site.org.repos.pick.selectAll', $json$"全选"$json$::jsonb),
  ('zh-CN', 'site.org.repos.pick.limit', $json$"每次最多 {max} 个"$json$::jsonb),
  ('hi', 'site.org.repos.pick.selectAll', $json$"सभी चुनें"$json$::jsonb),
  ('hi', 'site.org.repos.pick.limit', $json$"एक बार में अधिकतम {max}"$json$::jsonb),
  ('ar', 'site.org.repos.pick.selectAll', $json$"تحديد الكل"$json$::jsonb),
  ('ar', 'site.org.repos.pick.limit', $json$"حتى {max} في المرة الواحدة"$json$::jsonb),
  ('fr', 'site.org.repos.pick.selectAll', $json$"Tout sélectionner"$json$::jsonb),
  ('fr', 'site.org.repos.pick.limit', $json$"Jusqu'à {max} à la fois"$json$::jsonb),
  ('ru', 'site.org.repos.pick.selectAll', $json$"Выбрать все"$json$::jsonb),
  ('ru', 'site.org.repos.pick.limit', $json$"Не больше {max} за раз"$json$::jsonb),
  ('ja', 'site.org.repos.pick.selectAll', $json$"すべて選択"$json$::jsonb),
  ('ja', 'site.org.repos.pick.limit', $json$"一度に {max} 件まで"$json$::jsonb),
  ('de', 'site.org.repos.pick.selectAll', $json$"Alle auswählen"$json$::jsonb),
  ('de', 'site.org.repos.pick.limit', $json$"Bis zu {max} auf einmal"$json$::jsonb)
on conflict (locale, key) do update set value = excluded.value;

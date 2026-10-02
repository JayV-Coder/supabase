-- Notificações da conta: o que acontece nas organizações e chega a quem não
-- fez a ação, em qualquer aparelho. Os gatilhos das tabelas das organizações
-- escrevem aqui; o app lê pela RLS (cada um só as suas), ouve as novas pelo
-- Realtime e marca como lidas pelas RPCs.
--
-- `kind` é um identificador estável em inglês e `data` traz os nomes do
-- momento (organização, @usuário, papel, repositório): a tela monta a frase no
-- idioma de quem lê, e a notificação continua legível depois que a
-- organização é renomeada ou excluída.
--
-- O que acontece no aparelho (resposta pronta, pergunta do agente, falha,
-- portaria, cota) não passa por aqui: o app avisa sozinho.

create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users on delete cascade,
  kind text not null check (kind in (
    'org.invited', 'org.inviteAccepted', 'org.inviteDeclined', 'org.roleChanged',
    'org.removed', 'org.deleted', 'org.policyChanged'
  )),
  data jsonb not null default '{}' check (jsonb_typeof(data) = 'object'),
  created_at timestamptz not null default now(),
  read_at timestamptz
);
create index notifications_user on public.notifications (user_id, created_at desc);
create index notifications_unread on public.notifications (user_id) where read_at is null;

alter table public.notifications enable row level security;
create policy "dono lê" on public.notifications for select to authenticated
  using (user_id = (select auth.uid()));

-- Ninguém escreve direto: os gatilhos escrevem e as RPCs marcam ou limpam.
revoke insert, update, delete, truncate on public.notifications from anon, authenticated;
revoke all on public.notifications from anon;

-- O Realtime entrega as novas ao app (a RLS acima vale para ele também). Sem a
-- publicação (banco de teste), a tabela funciona igual, só sem o aviso ao vivo.
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.notifications;
  end if;
end;
$$;

-- O @usuário de quem fez a ação, ou nulo (painel, service role).
create function public.notification_actor() returns text language sql stable security definer set search_path = '' as $$
  select username from public.profiles where user_id = auth.uid();
$$;

-- Avisa uma pessoa, menos quem fez a ação e menos conta que já não existe.
create function public.notify(target uuid, kind text, data jsonb) returns void language plpgsql security definer set search_path = '' as $$
begin
  if target is null or target is not distinct from auth.uid() then return; end if;
  if not exists (select 1 from auth.users where id = target) then return; end if;
  insert into public.notifications (user_id, kind, data) values (target, kind, jsonb_strip_nulls(data));
end;
$$;

-- Convite novo: para a conta convidada, ou para a conta cujo e-mail
-- confirmado é o do convite (quem ainda não tem conta vê o convite ao entrar).
create function public.notifications_invite_created() returns trigger language plpgsql security definer set search_path = '' as $$
declare
  target uuid := new.invited_user_id;
begin
  if target is null then
    select id into target from auth.users where lower(email) = new.email and email_confirmed_at is not null;
  end if;
  perform public.notify(target, 'org.invited', jsonb_build_object(
    'orgId', new.org_id,
    'org', (select name from public.organizations where id = new.org_id),
    'inviteId', new.id,
    'role', new.role,
    'user', (select username from public.profiles where user_id = new.invited_by)
  ));
  return new;
end;
$$;
create trigger notify_invite_created after insert on public.organization_invites
  for each row execute function public.notifications_invite_created();

-- Convite respondido: quem convidou fica sabendo. Aceito, recusado ou
-- revogado, o aviso do convite para o convidado já não pede nada e vira lido.
create function public.notifications_invite_answered() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if old.status <> 'pending' or new.status = 'pending' then return new; end if;
  update public.notifications set read_at = now()
    where kind = 'org.invited' and read_at is null and data->>'inviteId' = new.id::text;
  if new.status in ('accepted', 'declined') then
    perform public.notify(new.invited_by, case new.status when 'accepted' then 'org.inviteAccepted' else 'org.inviteDeclined' end, jsonb_build_object(
      'orgId', new.org_id,
      'org', (select name from public.organizations where id = new.org_id),
      'user', public.notification_actor()
    ));
  end if;
  return new;
end;
$$;
create trigger notify_invite_answered after update of status on public.organization_invites
  for each row execute function public.notifications_invite_answered();

create function public.notifications_role_changed() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.role is distinct from old.role then
    perform public.notify(new.user_id, 'org.roleChanged', jsonb_build_object(
      'orgId', new.org_id,
      'org', (select name from public.organizations where id = new.org_id),
      'role', new.role,
      'user', public.notification_actor()
    ));
  end if;
  return new;
end;
$$;
create trigger notify_role_changed after update of role on public.organization_members
  for each row execute function public.notifications_role_changed();

-- Removido por outra pessoa. Sair por conta própria não avisa (o `notify`
-- pula quem fez a ação), e a exclusão da organização avisa pelo gatilho dela.
create function public.notifications_member_removed() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if exists (select 1 from public.organizations where id = old.org_id) then
    perform public.notify(old.user_id, 'org.removed', jsonb_build_object(
      'orgId', old.org_id,
      'org', (select name from public.organizations where id = old.org_id),
      'user', public.notification_actor()
    ));
  end if;
  return old;
end;
$$;
create trigger notify_member_removed after delete on public.organization_members
  for each row execute function public.notifications_member_removed();

create function public.notifications_org_deleted() returns trigger language plpgsql security definer set search_path = '' as $$
declare
  member uuid;
begin
  for member in select user_id from public.organization_members where org_id = old.id loop
    perform public.notify(member, 'org.deleted', jsonb_build_object('org', old.name, 'user', public.notification_actor()));
  end loop;
  return old;
end;
$$;
create trigger notify_org_deleted before delete on public.organizations
  for each row execute function public.notifications_org_deleted();

-- A política que vale para os projetos de todos os membros mudou. Apagada em
-- cascata (com a organização ou com o repositório), não há o que avisar. O
-- `set_llm_policy` apaga e grava de novo na mesma transação: o par vira um
-- aviso só.
create function public.notifications_policy_changed() returns trigger language plpgsql security definer set search_path = '' as $$
declare
  changed public.organization_llm_policies := coalesce(new, old);
  repository text;
  member uuid;
begin
  if not exists (select 1 from public.organizations where id = changed.org_id) then return null; end if;
  if changed.repository_id is not null then
    select r.repo_key into repository from public.organization_repositories r where r.id = changed.repository_id;
    if repository is null then return null; end if;
  end if;
  for member in
    select m.user_id from public.organization_members m
    where m.org_id = changed.org_id
      and not exists (
        select 1 from public.notifications n
        where n.user_id = m.user_id and n.kind = 'org.policyChanged' and n.created_at = now()
          and n.data->>'orgId' = changed.org_id::text and n.data->>'repository' is not distinct from repository
      )
  loop
    perform public.notify(member, 'org.policyChanged', jsonb_build_object(
      'orgId', changed.org_id,
      'org', (select name from public.organizations where id = changed.org_id),
      'repository', repository,
      'user', public.notification_actor()
    ));
  end loop;
  return null;
end;
$$;
create trigger notify_policy_changed after insert or update or delete on public.organization_llm_policies
  for each row execute function public.notifications_policy_changed();

-- `ids` nulo marca todas as de quem chama.
create function public.mark_notifications_read(ids uuid[] default null) returns void language sql security definer set search_path = '' as $$
  update public.notifications set read_at = now()
  where user_id = auth.uid() and read_at is null and (ids is null or id = any (ids));
$$;

-- Limpa as já lidas de quem chama.
create function public.clear_notifications() returns void language sql security definer set search_path = '' as $$
  delete from public.notifications where user_id = auth.uid() and read_at is not null;
$$;

do $$
declare
  fn text;
begin
  foreach fn in array array[
    'notification_actor()', 'notify(uuid, text, jsonb)', 'notifications_invite_created()',
    'notifications_invite_answered()', 'notifications_role_changed()', 'notifications_member_removed()',
    'notifications_org_deleted()', 'notifications_policy_changed()'
  ] loop
    execute format('revoke execute on function public.%s from public, anon, authenticated', fn);
  end loop;
  foreach fn in array array['mark_notifications_read(uuid[])', 'clear_notifications()'] loop
    execute format('revoke execute on function public.%s from public, anon', fn);
    execute format('grant execute on function public.%s to authenticated', fn);
  end loop;
end;
$$;

-- O sino e a central de notificações, nos dez idiomas.
insert into public.translations (locale, key, value) values
  ('pt-BR', 'notifications.title', $json$"Notificações"$json$::jsonb),
  ('pt-BR', 'notifications.unread', $json${"one": "{count} não lida", "other": "{count} não lidas"}$json$::jsonb),
  ('pt-BR', 'notifications.allRead', $json$"Tudo em dia"$json$::jsonb),
  ('pt-BR', 'notifications.unreadMark', $json$"Não lida"$json$::jsonb),
  ('pt-BR', 'notifications.markAllRead', $json$"Marcar todas como lidas"$json$::jsonb),
  ('pt-BR', 'notifications.clearRead', $json$"Limpar as lidas"$json$::jsonb),
  ('pt-BR', 'notifications.open', $json$"Abrir"$json$::jsonb),
  ('pt-BR', 'notifications.empty.title', $json$"Nenhuma notificação ainda"$json$::jsonb),
  ('pt-BR', 'notifications.empty.description', $json$"Convites, respostas prontas, perguntas do agente e limites dos planos aparecem aqui."$json$::jsonb),
  ('pt-BR', 'notifications.someone', $json$"Alguém"$json$::jsonb),
  ('pt-BR', 'notifications.by', $json$"por {user}"$json$::jsonb),
  ('pt-BR', 'notifications.org.invited', $json$"Convite para entrar em {org} como {role}"$json$::jsonb),
  ('pt-BR', 'notifications.org.inviteAccepted', $json$"{user} aceitou o convite para {org}"$json$::jsonb),
  ('pt-BR', 'notifications.org.inviteDeclined', $json$"{user} recusou o convite para {org}"$json$::jsonb),
  ('pt-BR', 'notifications.org.roleChanged', $json$"Seu papel em {org} agora é {role}"$json$::jsonb),
  ('pt-BR', 'notifications.org.removed', $json$"Você foi removido de {org}"$json$::jsonb),
  ('pt-BR', 'notifications.org.deleted', $json$"A organização {org} foi excluída"$json$::jsonb),
  ('pt-BR', 'notifications.org.policyChanged', $json$"A política de LLM de {org} mudou"$json$::jsonb),
  ('pt-BR', 'notifications.org.repositoryPolicyChanged', $json$"A política de LLM de {repository} em {org} mudou"$json$::jsonb),
  ('pt-BR', 'notifications.turn.answered', $json$"Resposta pronta em {chat}"$json$::jsonb),
  ('pt-BR', 'notifications.turn.asking', $json$"O agente está esperando sua resposta em {chat}"$json$::jsonb),
  ('pt-BR', 'notifications.turn.failed', $json$"Um pedido falhou em {chat}"$json$::jsonb),
  ('pt-BR', 'notifications.turn.blocked', $json$"A portaria barrou um pedido em {chat}"$json$::jsonb),
  ('pt-BR', 'notifications.quota.crossed', $json$"{agent} passou de {percent}% do limite"$json$::jsonb),
  ('en', 'notifications.title', $json$"Notifications"$json$::jsonb),
  ('en', 'notifications.unread', $json${"one": "{count} unread", "other": "{count} unread"}$json$::jsonb),
  ('en', 'notifications.allRead', $json$"All caught up"$json$::jsonb),
  ('en', 'notifications.unreadMark', $json$"Unread"$json$::jsonb),
  ('en', 'notifications.markAllRead', $json$"Mark all as read"$json$::jsonb),
  ('en', 'notifications.clearRead', $json$"Clear read"$json$::jsonb),
  ('en', 'notifications.open', $json$"Open"$json$::jsonb),
  ('en', 'notifications.empty.title', $json$"No notifications yet"$json$::jsonb),
  ('en', 'notifications.empty.description', $json$"Invitations, finished answers, questions from the agent and plan limits show up here."$json$::jsonb),
  ('en', 'notifications.someone', $json$"Someone"$json$::jsonb),
  ('en', 'notifications.by', $json$"by {user}"$json$::jsonb),
  ('en', 'notifications.org.invited', $json$"Invitation to join {org} as {role}"$json$::jsonb),
  ('en', 'notifications.org.inviteAccepted', $json$"{user} accepted the invitation to {org}"$json$::jsonb),
  ('en', 'notifications.org.inviteDeclined', $json$"{user} declined the invitation to {org}"$json$::jsonb),
  ('en', 'notifications.org.roleChanged', $json$"Your role in {org} is now {role}"$json$::jsonb),
  ('en', 'notifications.org.removed', $json$"You were removed from {org}"$json$::jsonb),
  ('en', 'notifications.org.deleted', $json$"The organization {org} was deleted"$json$::jsonb),
  ('en', 'notifications.org.policyChanged', $json$"The LLM policy of {org} changed"$json$::jsonb),
  ('en', 'notifications.org.repositoryPolicyChanged', $json$"The LLM policy of {repository} in {org} changed"$json$::jsonb),
  ('en', 'notifications.turn.answered', $json$"Answer ready in {chat}"$json$::jsonb),
  ('en', 'notifications.turn.asking', $json$"The agent is waiting for your answer in {chat}"$json$::jsonb),
  ('en', 'notifications.turn.failed', $json$"A request failed in {chat}"$json$::jsonb),
  ('en', 'notifications.turn.blocked', $json$"The Gatehouse blocked a request in {chat}"$json$::jsonb),
  ('en', 'notifications.quota.crossed', $json$"{agent} passed {percent}% of its limit"$json$::jsonb),
  ('es', 'notifications.title', $json$"Notificaciones"$json$::jsonb),
  ('es', 'notifications.unread', $json${"one": "{count} sin leer", "other": "{count} sin leer"}$json$::jsonb),
  ('es', 'notifications.allRead', $json$"Todo al día"$json$::jsonb),
  ('es', 'notifications.unreadMark', $json$"Sin leer"$json$::jsonb),
  ('es', 'notifications.markAllRead', $json$"Marcar todas como leídas"$json$::jsonb),
  ('es', 'notifications.clearRead', $json$"Borrar las leídas"$json$::jsonb),
  ('es', 'notifications.open', $json$"Abrir"$json$::jsonb),
  ('es', 'notifications.empty.title', $json$"Aún no hay notificaciones"$json$::jsonb),
  ('es', 'notifications.empty.description', $json$"Aquí aparecen invitaciones, respuestas listas, preguntas del agente y límites de los planes."$json$::jsonb),
  ('es', 'notifications.someone', $json$"Alguien"$json$::jsonb),
  ('es', 'notifications.by', $json$"por {user}"$json$::jsonb),
  ('es', 'notifications.org.invited', $json$"Invitación para unirte a {org} como {role}"$json$::jsonb),
  ('es', 'notifications.org.inviteAccepted', $json$"{user} aceptó la invitación a {org}"$json$::jsonb),
  ('es', 'notifications.org.inviteDeclined', $json$"{user} rechazó la invitación a {org}"$json$::jsonb),
  ('es', 'notifications.org.roleChanged', $json$"Tu rol en {org} ahora es {role}"$json$::jsonb),
  ('es', 'notifications.org.removed', $json$"Te quitaron de {org}"$json$::jsonb),
  ('es', 'notifications.org.deleted', $json$"La organización {org} fue eliminada"$json$::jsonb),
  ('es', 'notifications.org.policyChanged', $json$"La política de LLM de {org} cambió"$json$::jsonb),
  ('es', 'notifications.org.repositoryPolicyChanged', $json$"La política de LLM de {repository} en {org} cambió"$json$::jsonb),
  ('es', 'notifications.turn.answered', $json$"Respuesta lista en {chat}"$json$::jsonb),
  ('es', 'notifications.turn.asking', $json$"El agente espera tu respuesta en {chat}"$json$::jsonb),
  ('es', 'notifications.turn.failed', $json$"Una solicitud falló en {chat}"$json$::jsonb),
  ('es', 'notifications.turn.blocked', $json$"La portería bloqueó una solicitud en {chat}"$json$::jsonb),
  ('es', 'notifications.quota.crossed', $json$"{agent} superó el {percent}% del límite"$json$::jsonb),
  ('zh-CN', 'notifications.title', $json$"通知"$json$::jsonb),
  ('zh-CN', 'notifications.unread', $json${"other": "{count} 条未读"}$json$::jsonb),
  ('zh-CN', 'notifications.allRead', $json$"全部已读"$json$::jsonb),
  ('zh-CN', 'notifications.unreadMark', $json$"未读"$json$::jsonb),
  ('zh-CN', 'notifications.markAllRead', $json$"全部标为已读"$json$::jsonb),
  ('zh-CN', 'notifications.clearRead', $json$"清除已读"$json$::jsonb),
  ('zh-CN', 'notifications.open', $json$"打开"$json$::jsonb),
  ('zh-CN', 'notifications.empty.title', $json$"暂无通知"$json$::jsonb),
  ('zh-CN', 'notifications.empty.description', $json$"邀请、已完成的回答、代理的提问和套餐限额都会显示在这里。"$json$::jsonb),
  ('zh-CN', 'notifications.someone', $json$"有人"$json$::jsonb),
  ('zh-CN', 'notifications.by', $json$"由 {user}"$json$::jsonb),
  ('zh-CN', 'notifications.org.invited', $json$"邀请你以 {role} 身份加入 {org}"$json$::jsonb),
  ('zh-CN', 'notifications.org.inviteAccepted', $json$"{user} 接受了加入 {org} 的邀请"$json$::jsonb),
  ('zh-CN', 'notifications.org.inviteDeclined', $json$"{user} 拒绝了加入 {org} 的邀请"$json$::jsonb),
  ('zh-CN', 'notifications.org.roleChanged', $json$"你在 {org} 的角色现在是 {role}"$json$::jsonb),
  ('zh-CN', 'notifications.org.removed', $json$"你已被移出 {org}"$json$::jsonb),
  ('zh-CN', 'notifications.org.deleted', $json$"组织 {org} 已被删除"$json$::jsonb),
  ('zh-CN', 'notifications.org.policyChanged', $json$"{org} 的 LLM 策略已更改"$json$::jsonb),
  ('zh-CN', 'notifications.org.repositoryPolicyChanged', $json$"{org} 中 {repository} 的 LLM 策略已更改"$json$::jsonb),
  ('zh-CN', 'notifications.turn.answered', $json$"{chat} 中的回答已就绪"$json$::jsonb),
  ('zh-CN', 'notifications.turn.asking', $json$"代理正在 {chat} 中等待你的回答"$json$::jsonb),
  ('zh-CN', 'notifications.turn.failed', $json$"{chat} 中有请求失败"$json$::jsonb),
  ('zh-CN', 'notifications.turn.blocked', $json$"门岗拦下了 {chat} 中的一个请求"$json$::jsonb),
  ('zh-CN', 'notifications.quota.crossed', $json$"{agent} 已超过限额的 {percent}%"$json$::jsonb),
  ('hi', 'notifications.title', $json$"सूचनाएँ"$json$::jsonb),
  ('hi', 'notifications.unread', $json${"one": "{count} अपठित", "other": "{count} अपठित"}$json$::jsonb),
  ('hi', 'notifications.allRead', $json$"सब पढ़ लिया गया"$json$::jsonb),
  ('hi', 'notifications.unreadMark', $json$"अपठित"$json$::jsonb),
  ('hi', 'notifications.markAllRead', $json$"सभी को पढ़ा हुआ चिह्नित करें"$json$::jsonb),
  ('hi', 'notifications.clearRead', $json$"पढ़ी हुई हटाएँ"$json$::jsonb),
  ('hi', 'notifications.open', $json$"खोलें"$json$::jsonb),
  ('hi', 'notifications.empty.title', $json$"अभी कोई सूचना नहीं"$json$::jsonb),
  ('hi', 'notifications.empty.description', $json$"निमंत्रण, तैयार जवाब, एजेंट के सवाल और प्लान की सीमाएँ यहाँ दिखती हैं।"$json$::jsonb),
  ('hi', 'notifications.someone', $json$"कोई"$json$::jsonb),
  ('hi', 'notifications.by', $json$"{user} द्वारा"$json$::jsonb),
  ('hi', 'notifications.org.invited', $json$"{org} में {role} के रूप में जुड़ने का निमंत्रण"$json$::jsonb),
  ('hi', 'notifications.org.inviteAccepted', $json$"{user} ने {org} का निमंत्रण स्वीकार किया"$json$::jsonb),
  ('hi', 'notifications.org.inviteDeclined', $json$"{user} ने {org} का निमंत्रण अस्वीकार किया"$json$::jsonb),
  ('hi', 'notifications.org.roleChanged', $json$"{org} में अब आपकी भूमिका {role} है"$json$::jsonb),
  ('hi', 'notifications.org.removed', $json$"आपको {org} से हटा दिया गया"$json$::jsonb),
  ('hi', 'notifications.org.deleted', $json$"संगठन {org} हटा दिया गया"$json$::jsonb),
  ('hi', 'notifications.org.policyChanged', $json$"{org} की LLM नीति बदल गई"$json$::jsonb),
  ('hi', 'notifications.org.repositoryPolicyChanged', $json$"{org} में {repository} की LLM नीति बदल गई"$json$::jsonb),
  ('hi', 'notifications.turn.answered', $json$"{chat} में जवाब तैयार है"$json$::jsonb),
  ('hi', 'notifications.turn.asking', $json$"{chat} में एजेंट आपके जवाब का इंतज़ार कर रहा है"$json$::jsonb),
  ('hi', 'notifications.turn.failed', $json$"{chat} में एक अनुरोध विफल हुआ"$json$::jsonb),
  ('hi', 'notifications.turn.blocked', $json$"गेट ने {chat} में एक अनुरोध रोक दिया"$json$::jsonb),
  ('hi', 'notifications.quota.crossed', $json$"{agent} ने सीमा का {percent}% पार किया"$json$::jsonb),
  ('ar', 'notifications.title', $json$"الإشعارات"$json$::jsonb),
  ('ar', 'notifications.unread', $json${"zero": "لا إشعارات غير مقروءة", "one": "إشعار واحد غير مقروء", "two": "إشعاران غير مقروءين", "few": "{count} إشعارات غير مقروءة", "many": "{count} إشعارًا غير مقروء", "other": "{count} إشعار غير مقروء"}$json$::jsonb),
  ('ar', 'notifications.allRead', $json$"لا جديد"$json$::jsonb),
  ('ar', 'notifications.unreadMark', $json$"غير مقروء"$json$::jsonb),
  ('ar', 'notifications.markAllRead', $json$"تعليم الكل كمقروء"$json$::jsonb),
  ('ar', 'notifications.clearRead', $json$"مسح المقروءة"$json$::jsonb),
  ('ar', 'notifications.open', $json$"فتح"$json$::jsonb),
  ('ar', 'notifications.empty.title', $json$"لا إشعارات بعد"$json$::jsonb),
  ('ar', 'notifications.empty.description', $json$"تظهر هنا الدعوات والإجابات الجاهزة وأسئلة الوكيل وحدود الخطط."$json$::jsonb),
  ('ar', 'notifications.someone', $json$"شخص ما"$json$::jsonb),
  ('ar', 'notifications.by', $json$"بواسطة {user}"$json$::jsonb),
  ('ar', 'notifications.org.invited', $json$"دعوة للانضمام إلى {org} بدور {role}"$json$::jsonb),
  ('ar', 'notifications.org.inviteAccepted', $json$"قبل {user} الدعوة إلى {org}"$json$::jsonb),
  ('ar', 'notifications.org.inviteDeclined', $json$"رفض {user} الدعوة إلى {org}"$json$::jsonb),
  ('ar', 'notifications.org.roleChanged', $json$"أصبح دورك في {org} الآن {role}"$json$::jsonb),
  ('ar', 'notifications.org.removed', $json$"تمت إزالتك من {org}"$json$::jsonb),
  ('ar', 'notifications.org.deleted', $json$"تم حذف المؤسسة {org}"$json$::jsonb),
  ('ar', 'notifications.org.policyChanged', $json$"تغيّرت سياسة LLM في {org}"$json$::jsonb),
  ('ar', 'notifications.org.repositoryPolicyChanged', $json$"تغيّرت سياسة LLM لـ {repository} في {org}"$json$::jsonb),
  ('ar', 'notifications.turn.answered', $json$"الإجابة جاهزة في {chat}"$json$::jsonb),
  ('ar', 'notifications.turn.asking', $json$"الوكيل ينتظر إجابتك في {chat}"$json$::jsonb),
  ('ar', 'notifications.turn.failed', $json$"فشل طلب في {chat}"$json$::jsonb),
  ('ar', 'notifications.turn.blocked', $json$"منعت البوابة طلبًا في {chat}"$json$::jsonb),
  ('ar', 'notifications.quota.crossed', $json$"تجاوز {agent} نسبة {percent}% من الحد"$json$::jsonb),
  ('fr', 'notifications.title', $json$"Notifications"$json$::jsonb),
  ('fr', 'notifications.unread', $json${"one": "{count} non lue", "other": "{count} non lues"}$json$::jsonb),
  ('fr', 'notifications.allRead', $json$"Tout est lu"$json$::jsonb),
  ('fr', 'notifications.unreadMark', $json$"Non lue"$json$::jsonb),
  ('fr', 'notifications.markAllRead', $json$"Tout marquer comme lu"$json$::jsonb),
  ('fr', 'notifications.clearRead', $json$"Effacer les lues"$json$::jsonb),
  ('fr', 'notifications.open', $json$"Ouvrir"$json$::jsonb),
  ('fr', 'notifications.empty.title', $json$"Aucune notification pour l’instant"$json$::jsonb),
  ('fr', 'notifications.empty.description', $json$"Les invitations, les réponses prêtes, les questions de l’agent et les limites des forfaits apparaissent ici."$json$::jsonb),
  ('fr', 'notifications.someone', $json$"Quelqu’un"$json$::jsonb),
  ('fr', 'notifications.by', $json$"par {user}"$json$::jsonb),
  ('fr', 'notifications.org.invited', $json$"Invitation à rejoindre {org} en tant que {role}"$json$::jsonb),
  ('fr', 'notifications.org.inviteAccepted', $json$"{user} a accepté l’invitation à {org}"$json$::jsonb),
  ('fr', 'notifications.org.inviteDeclined', $json$"{user} a refusé l’invitation à {org}"$json$::jsonb),
  ('fr', 'notifications.org.roleChanged', $json$"Votre rôle dans {org} est maintenant {role}"$json$::jsonb),
  ('fr', 'notifications.org.removed', $json$"Vous avez été retiré de {org}"$json$::jsonb),
  ('fr', 'notifications.org.deleted', $json$"L’organisation {org} a été supprimée"$json$::jsonb),
  ('fr', 'notifications.org.policyChanged', $json$"La politique LLM de {org} a changé"$json$::jsonb),
  ('fr', 'notifications.org.repositoryPolicyChanged', $json$"La politique LLM de {repository} dans {org} a changé"$json$::jsonb),
  ('fr', 'notifications.turn.answered', $json$"Réponse prête dans {chat}"$json$::jsonb),
  ('fr', 'notifications.turn.asking', $json$"L’agent attend votre réponse dans {chat}"$json$::jsonb),
  ('fr', 'notifications.turn.failed', $json$"Une demande a échoué dans {chat}"$json$::jsonb),
  ('fr', 'notifications.turn.blocked', $json$"La loge a bloqué une demande dans {chat}"$json$::jsonb),
  ('fr', 'notifications.quota.crossed', $json$"{agent} a dépassé {percent} % de sa limite"$json$::jsonb),
  ('ru', 'notifications.title', $json$"Уведомления"$json$::jsonb),
  ('ru', 'notifications.unread', $json${"one": "{count} непрочитанное", "few": "{count} непрочитанных", "many": "{count} непрочитанных", "other": "{count} непрочитанного"}$json$::jsonb),
  ('ru', 'notifications.allRead', $json$"Всё прочитано"$json$::jsonb),
  ('ru', 'notifications.unreadMark', $json$"Не прочитано"$json$::jsonb),
  ('ru', 'notifications.markAllRead', $json$"Отметить все как прочитанные"$json$::jsonb),
  ('ru', 'notifications.clearRead', $json$"Удалить прочитанные"$json$::jsonb),
  ('ru', 'notifications.open', $json$"Открыть"$json$::jsonb),
  ('ru', 'notifications.empty.title', $json$"Пока нет уведомлений"$json$::jsonb),
  ('ru', 'notifications.empty.description', $json$"Здесь появляются приглашения, готовые ответы, вопросы агента и лимиты тарифов."$json$::jsonb),
  ('ru', 'notifications.someone', $json$"Кто-то"$json$::jsonb),
  ('ru', 'notifications.by', $json$"от {user}"$json$::jsonb),
  ('ru', 'notifications.org.invited', $json$"Приглашение в {org} с ролью {role}"$json$::jsonb),
  ('ru', 'notifications.org.inviteAccepted', $json$"{user} принял(а) приглашение в {org}"$json$::jsonb),
  ('ru', 'notifications.org.inviteDeclined', $json$"{user} отклонил(а) приглашение в {org}"$json$::jsonb),
  ('ru', 'notifications.org.roleChanged', $json$"Ваша роль в {org} теперь {role}"$json$::jsonb),
  ('ru', 'notifications.org.removed', $json$"Вас удалили из {org}"$json$::jsonb),
  ('ru', 'notifications.org.deleted', $json$"Организация {org} удалена"$json$::jsonb),
  ('ru', 'notifications.org.policyChanged', $json$"Политика LLM в {org} изменилась"$json$::jsonb),
  ('ru', 'notifications.org.repositoryPolicyChanged', $json$"Политика LLM для {repository} в {org} изменилась"$json$::jsonb),
  ('ru', 'notifications.turn.answered', $json$"Ответ готов в {chat}"$json$::jsonb),
  ('ru', 'notifications.turn.asking', $json$"Агент ждёт вашего ответа в {chat}"$json$::jsonb),
  ('ru', 'notifications.turn.failed', $json$"Запрос в {chat} завершился ошибкой"$json$::jsonb),
  ('ru', 'notifications.turn.blocked', $json$"Проходная остановила запрос в {chat}"$json$::jsonb),
  ('ru', 'notifications.quota.crossed', $json$"{agent} превысил {percent}% лимита"$json$::jsonb),
  ('ja', 'notifications.title', $json$"通知"$json$::jsonb),
  ('ja', 'notifications.unread', $json${"other": "未読 {count} 件"}$json$::jsonb),
  ('ja', 'notifications.allRead', $json$"すべて既読"$json$::jsonb),
  ('ja', 'notifications.unreadMark', $json$"未読"$json$::jsonb),
  ('ja', 'notifications.markAllRead', $json$"すべて既読にする"$json$::jsonb),
  ('ja', 'notifications.clearRead', $json$"既読を消去"$json$::jsonb),
  ('ja', 'notifications.open', $json$"開く"$json$::jsonb),
  ('ja', 'notifications.empty.title', $json$"まだ通知はありません"$json$::jsonb),
  ('ja', 'notifications.empty.description', $json$"招待、完了した回答、エージェントからの質問、プランの上限がここに表示されます。"$json$::jsonb),
  ('ja', 'notifications.someone', $json$"誰か"$json$::jsonb),
  ('ja', 'notifications.by', $json$"{user} による"$json$::jsonb),
  ('ja', 'notifications.org.invited', $json$"{org} への {role} としての招待"$json$::jsonb),
  ('ja', 'notifications.org.inviteAccepted', $json$"{user} が {org} への招待を承諾しました"$json$::jsonb),
  ('ja', 'notifications.org.inviteDeclined', $json$"{user} が {org} への招待を辞退しました"$json$::jsonb),
  ('ja', 'notifications.org.roleChanged', $json$"{org} でのあなたの役割は {role} になりました"$json$::jsonb),
  ('ja', 'notifications.org.removed', $json$"{org} から削除されました"$json$::jsonb),
  ('ja', 'notifications.org.deleted', $json$"組織 {org} は削除されました"$json$::jsonb),
  ('ja', 'notifications.org.policyChanged', $json$"{org} の LLM ポリシーが変更されました"$json$::jsonb),
  ('ja', 'notifications.org.repositoryPolicyChanged', $json$"{org} の {repository} の LLM ポリシーが変更されました"$json$::jsonb),
  ('ja', 'notifications.turn.answered', $json$"{chat} の回答ができました"$json$::jsonb),
  ('ja', 'notifications.turn.asking', $json$"{chat} でエージェントがあなたの回答を待っています"$json$::jsonb),
  ('ja', 'notifications.turn.failed', $json$"{chat} でリクエストが失敗しました"$json$::jsonb),
  ('ja', 'notifications.turn.blocked', $json$"ゲートが {chat} のリクエストを止めました"$json$::jsonb),
  ('ja', 'notifications.quota.crossed', $json$"{agent} が上限の {percent}% を超えました"$json$::jsonb),
  ('de', 'notifications.title', $json$"Benachrichtigungen"$json$::jsonb),
  ('de', 'notifications.unread', $json${"one": "{count} ungelesen", "other": "{count} ungelesen"}$json$::jsonb),
  ('de', 'notifications.allRead', $json$"Alles gelesen"$json$::jsonb),
  ('de', 'notifications.unreadMark', $json$"Ungelesen"$json$::jsonb),
  ('de', 'notifications.markAllRead', $json$"Alle als gelesen markieren"$json$::jsonb),
  ('de', 'notifications.clearRead', $json$"Gelesene entfernen"$json$::jsonb),
  ('de', 'notifications.open', $json$"Öffnen"$json$::jsonb),
  ('de', 'notifications.empty.title', $json$"Noch keine Benachrichtigungen"$json$::jsonb),
  ('de', 'notifications.empty.description', $json$"Einladungen, fertige Antworten, Fragen des Agenten und Tariflimits erscheinen hier."$json$::jsonb),
  ('de', 'notifications.someone', $json$"Jemand"$json$::jsonb),
  ('de', 'notifications.by', $json$"von {user}"$json$::jsonb),
  ('de', 'notifications.org.invited', $json$"Einladung zu {org} als {role}"$json$::jsonb),
  ('de', 'notifications.org.inviteAccepted', $json$"{user} hat die Einladung zu {org} angenommen"$json$::jsonb),
  ('de', 'notifications.org.inviteDeclined', $json$"{user} hat die Einladung zu {org} abgelehnt"$json$::jsonb),
  ('de', 'notifications.org.roleChanged', $json$"Deine Rolle in {org} ist jetzt {role}"$json$::jsonb),
  ('de', 'notifications.org.removed', $json$"Du wurdest aus {org} entfernt"$json$::jsonb),
  ('de', 'notifications.org.deleted', $json$"Die Organisation {org} wurde gelöscht"$json$::jsonb),
  ('de', 'notifications.org.policyChanged', $json$"Die LLM-Richtlinie von {org} wurde geändert"$json$::jsonb),
  ('de', 'notifications.org.repositoryPolicyChanged', $json$"Die LLM-Richtlinie von {repository} in {org} wurde geändert"$json$::jsonb),
  ('de', 'notifications.turn.answered', $json$"Antwort fertig in {chat}"$json$::jsonb),
  ('de', 'notifications.turn.asking', $json$"Der Agent wartet in {chat} auf deine Antwort"$json$::jsonb),
  ('de', 'notifications.turn.failed', $json$"Eine Anfrage in {chat} ist fehlgeschlagen"$json$::jsonb),
  ('de', 'notifications.turn.blocked', $json$"Die Pforte hat eine Anfrage in {chat} gestoppt"$json$::jsonb),
  ('de', 'notifications.quota.crossed', $json$"{agent} hat {percent} % des Limits überschritten"$json$::jsonb)
on conflict (locale, key) do update set value = excluded.value;

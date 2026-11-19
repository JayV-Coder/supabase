-- Excluir Integração (complementa o #10 do jayv-doctor): Owner ou Admin com MFA excluem de verdade
-- a que não tem histórico. Com Execuções, Eventos, Incidentes, Conectores, Agentes, tokens de
-- ingestão ou Importações, as chaves estrangeiras (sem `on delete`) recusam com 23503, e o caminho
-- é arquivar. Os Mapas de identificadores, os de colunas e as estatísticas por hora saem junto
-- (`on delete cascade`). O trigger `integrations_audit` registra a exclusão.

grant delete on doctor.integrations to authenticated;

create policy integrations_delete on doctor.integrations
  for delete to authenticated
  using (tenant_id = (select doctor.current_tenant_id()) and (select doctor.is_manager()));

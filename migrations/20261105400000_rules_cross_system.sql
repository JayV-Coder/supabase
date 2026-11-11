-- Ticket #40: Regras `2026.11.2`. INT-008 passa a ver também a chave do Mapa de identificadores
-- (com `reconcile`) que apareceu na origem e não no destino; as outras repetem a `2026.11.1`
-- na versão nova. As versões anteriores continuam: os matches antigos apontam para elas.
insert into doctor.rule_definitions (code, version, category, severity_hint, description) values
  ('INT-001', '2026.11.2', 'AUTH', 'high', 'O destino recusou a autenticação ou a autorização (HTTP 401/403).'),
  ('INT-002', '2026.11.2', 'RATE_LIMIT', 'medium', 'O destino limitou as chamadas (HTTP 429).'),
  ('INT-003', '2026.11.2', 'TIMEOUT', 'high', 'Tempo esgotado (HTTP 504 ou timeout): o resultado no destino é indeterminado.'),
  ('INT-004', '2026.11.2', 'VALIDATION', 'medium', 'O payload foi recusado na validação (HTTP 400/422).'),
  ('INT-005', '2026.11.2', 'BUSINESS_REJECTION', 'high', 'O SAP rejeitou por regra de negócio (BAPIRET2 tipo E/A, mensagens V1/VL).'),
  ('INT-006', '2026.11.2', 'DUPLICATE', 'low', 'O identificador já existe no destino (duplicidade).'),
  ('INT-007', '2026.11.2', 'PENDING_CONFIRMATION', 'medium', 'Enviado, sem confirmação do destino dentro do prazo.'),
  ('INT-008', '2026.11.2', 'DIVERGENCE', 'high', 'Origem e destino divergem em contagem ou status, ou o registro da origem não chegou ao destino.'),
  ('INT-009', '2026.11.2', 'SAP_LOCK', 'medium', 'O objeto estava bloqueado por outro usuário no SAP (ex.: MC 601); tende a passar numa nova tentativa.'),
  ('INT-010', '2026.11.2', 'IDOC_ERROR', 'high', 'IDoc com status 51: o documento de aplicação não foi lançado no SAP.'),
  ('INT-011', '2026.11.2', 'SAP_AUTHORIZATION', 'high', 'O usuário técnico não tem autorização no SAP para a operação.'),
  ('INT-012', '2026.11.2', 'MASTER_DATA', 'medium', 'Cadastro mestre faltante ou incompleto no SAP (ex.: material não mantido no centro, M3 305).');

-- Divergência pelo Mapa (INT-008): avaliada de novo quando a janela do Mapa já passou desde o
-- último Evento, para o destino ter tido tempo de chegar. A Execução reaberta zera a marca.
alter table doctor.executions add column reconciled_at timestamptz;
create index executions_reconcile_due_idx on doctor.executions (tenant_id, last_event_at)
  where reconciled_at is null and closed_at is not null and merged_into is null;

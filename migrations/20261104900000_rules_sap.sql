-- Ticket #38: Regras `2026.11.1`. As oito anteriores na versão nova (INT-005 também lê a
-- mensagem SAP tipo E/A reconhecida pela ingestão e deixa os casos específicos para as Regras
-- SAP) e quatro Regras SAP. A versão `2026.10.1` continua: os matches antigos apontam para ela.
insert into doctor.rule_definitions (code, version, category, severity_hint, description) values
  ('INT-001', '2026.11.1', 'AUTH', 'high', 'O destino recusou a autenticação ou a autorização (HTTP 401/403).'),
  ('INT-002', '2026.11.1', 'RATE_LIMIT', 'medium', 'O destino limitou as chamadas (HTTP 429).'),
  ('INT-003', '2026.11.1', 'TIMEOUT', 'high', 'Tempo esgotado (HTTP 504 ou timeout): o resultado no destino é indeterminado.'),
  ('INT-004', '2026.11.1', 'VALIDATION', 'medium', 'O payload foi recusado na validação (HTTP 400/422).'),
  ('INT-005', '2026.11.1', 'BUSINESS_REJECTION', 'high', 'O SAP rejeitou por regra de negócio (BAPIRET2 tipo E/A, mensagens V1/VL).'),
  ('INT-006', '2026.11.1', 'DUPLICATE', 'low', 'O identificador já existe no destino (duplicidade).'),
  ('INT-007', '2026.11.1', 'PENDING_CONFIRMATION', 'medium', 'Enviado, sem confirmação do destino dentro do prazo.'),
  ('INT-008', '2026.11.1', 'DIVERGENCE', 'high', 'Origem e destino divergem em contagem ou status.'),
  ('INT-009', '2026.11.1', 'SAP_LOCK', 'medium', 'O objeto estava bloqueado por outro usuário no SAP (ex.: MC 601); tende a passar numa nova tentativa.'),
  ('INT-010', '2026.11.1', 'IDOC_ERROR', 'high', 'IDoc com status 51: o documento de aplicação não foi lançado no SAP.'),
  ('INT-011', '2026.11.1', 'SAP_AUTHORIZATION', 'high', 'O usuário técnico não tem autorização no SAP para a operação.'),
  ('INT-012', '2026.11.1', 'MASTER_DATA', 'medium', 'Cadastro mestre faltante ou incompleto no SAP (ex.: material não mantido no centro, M3 305).');

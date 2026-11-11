-- Ticket #12 (relay): mensagem recusada 10 vezes sai do índice de pendentes. Sem isso, as
-- abandonadas ficariam no começo do índice e toda rodada do relay passaria por elas.
drop index doctor.outbox_messages_pending_idx;
create index outbox_messages_pending_idx on doctor.outbox_messages (id)
  where published_at is null and attempts < 10;

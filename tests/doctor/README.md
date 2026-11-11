# Testes do jayv-doctor (schema `doctor`)

Os testes pgTAP do Integration AI Doctor, que vivem no schema `doctor` deste projeto
(ADR-0009 do jayv-doctor). Rodam junto com os do jayv-coder em `supabase test db` e usam o
helper `../helpers/tenancy.psql` (usuários, Organizações e o JWT de teste).

# Supabase do JayV

O banco do projeto `exvsozyemolrjbjetqww`, dividido pelos apps:

| Schema   | De quem                         | Migrações                         | Testes          |
|----------|---------------------------------|-----------------------------------|-----------------|
| `public` | compartilhado (conta, organizações, i18n, cobrança) | `migrations/<versão>_<nome>.sql` | `tests/*.test.sql` |
| `coder`  | app jayv-coder                  | `migrations/<versão>_<nome>.sql`  | `tests/*.test.sql` |
| `doctor` | Integration AI Doctor (jayv-doctor) | `migrations/<versão>_doctor_<nome>.sql` | `tests/doctor/` |

- **Merge na `main` é deploy:** o workflow `Deploy` roda `supabase db push` no projeto e publica
  as Edge Functions. O PR mostra antes, no `Conferir migrations`, o que o merge vai aplicar.
- Migração do Doctor tem `_doctor_` logo depois da versão (`^[0-9]+_doctor_`). O deploy deixa
  essas de fora do `db push`: quem as aplica é o `scripts/apply-doctor-migrations.py` do
  jayv-doctor, que as registra em `doctor.schema_migrations`. Só elas mexem no schema `doctor`
  (o `Conferir migrations` recusa as outras), e elas não alteram `public` nem `coder`.
- Migração aplicada não se edita: ajuste vira migração nova.
- `supabase test db` roda os testes de todos os schemas sobre o banco inteiro.

## Tabelas do app em `coder`

As tabelas só do app (chats, projetos, `jev_*`, `llm_*`, turns, uso…) moram em `coder`. Em
`public` ficou, para cada uma, uma view de mesmo nome (`security_invoker`, atualizável), que o
app instalado, o site e as Edge Functions ainda usam. Enquanto as views existirem:

- DDL é na tabela: `alter table coder.<tabela> …`, `create index … on coder.<tabela>`,
  `create trigger … on coder.<tabela>`, `create policy … on coder.<tabela>`. Em
  `public.<tabela>` falha, porque é uma view.
- Coluna nova: refaça a view na mesma migração, senão ela não aparece para quem lê por `public`
  (o teste `coder_schema` cobra):
  `create or replace view public.<tabela> with (security_invoker = true) as select * from coder.<tabela>;`
- Remover ou renomear coluna: `drop view public.<tabela>` antes, e depois recrie a view com os
  mesmos `grant`.
- Função nova cita `coder.<tabela>`. `on conflict on constraint` não funciona através da view.
- Tabela nova do app nasce em `coder`; `public` é só o que os apps dividem.
- `organization_git_connections` e `organization_repositories` seguem em `public` até o app
  escutar o Realtime em `coder` (uma view não emite `postgres_changes`).

# Supabase do JayV

O banco do projeto `exvsozyemolrjbjetqww`, dividido pelos apps:

| Schema   | De quem                         | Migrações                         | Testes          |
|----------|---------------------------------|-----------------------------------|-----------------|
| `public` | compartilhado (conta, organizações, i18n, cobrança) | `migrations/<versão>_<nome>.sql` | `tests/*.test.sql` |
| `coder`  | app jayv-coder                  | `migrations/<versão>_<nome>.sql`  | `tests/*.test.sql` |
| `doctor` | Integration AI Doctor (jayv-doctor) | `migrations/<versão>_doctor_<nome>.sql` | `tests/doctor/` |

- Migração do Doctor tem `_doctor_` logo depois da versão. É por esse nome que o
  `scripts/apply-doctor-migrations.py` do jayv-doctor separa as dele, registradas em
  `doctor.schema_migrations`; o resto segue pelo `supabase db push`.
- Migração do Doctor não altera `public` nem `coder`, e as dos outros não alteram `doctor`.
- Migração aplicada não se edita: ajuste vira migração nova.
- `supabase test db` roda os testes de todos os schemas sobre o banco inteiro.

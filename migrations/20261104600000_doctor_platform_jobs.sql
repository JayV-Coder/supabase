-- Ticket #33: estado dos jobs de plataforma (o backup diário do Storage guarda até onde copiou).
-- Não é dado de tenant: só os workers (service_role) leem e escrevem.
create table doctor.platform_jobs (
  name text primary key check (name ~ '^[a-z][a-z0-9_]{2,59}$'),
  last_success_at timestamptz not null,
  details jsonb not null default '{}' check (jsonb_typeof(details) = 'object'),
  updated_at timestamptz not null default now()
);
comment on table doctor.platform_jobs is 'Última execução bem-sucedida de cada job de plataforma.';

create trigger platform_jobs_set_updated_at
before update on doctor.platform_jobs
for each row execute function doctor.set_updated_at();

alter table doctor.platform_jobs enable row level security;
revoke all on doctor.platform_jobs from anon, authenticated;
grant select, insert, update on doctor.platform_jobs to service_role;

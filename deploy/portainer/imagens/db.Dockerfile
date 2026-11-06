# syntax=docker/dockerfile:1
# Postgres do Supabase com os scripts de início embutidos, na ref self-hosted/v0.8.1
# que o kit fixa. Assim a VPS não precisa de nenhum arquivo fora da stack.
FROM supabase/postgres:17.6.1.136
ARG BASE=https://raw.githubusercontent.com/supabase/supabase/self-hosted/v0.8.1/docker/volumes/db
ADD --chmod=644 --checksum=sha256:7e9e442e7fc4dae05544c07b67bede37a00d84644304dfce4d937134cb4c8f88 ${BASE}/realtime.sql /docker-entrypoint-initdb.d/migrations/99-realtime.sql
ADD --chmod=644 --checksum=sha256:b584aaaa0c393f27218f81e01e76e1d07d42f947083249adcd6097ad471cde62 ${BASE}/webhooks.sql /docker-entrypoint-initdb.d/init-scripts/98-webhooks.sql
ADD --chmod=644 --checksum=sha256:3ad717b225daa38aa982da26750f35641eb404e1eb5e69a763c22236ab96c1b2 ${BASE}/roles.sql /docker-entrypoint-initdb.d/init-scripts/99-roles.sql
ADD --chmod=644 --checksum=sha256:1cc94a4f16f6e2932b383cd68e211a96bcae298437ca4120d8a5106396c58465 ${BASE}/jwt.sql /docker-entrypoint-initdb.d/init-scripts/99-jwt.sql
ADD --chmod=644 --checksum=sha256:9dce462adc04137d6afabcf28efa60a6c355270a4b32d7af58891ac4eb964c5f ${BASE}/_supabase.sql /docker-entrypoint-initdb.d/migrations/97-_supabase.sql
ADD --chmod=644 --checksum=sha256:f0463ce5030907acef49326d2bffd36002df0718035071be7c99bd7fc897c63d ${BASE}/logs.sql /docker-entrypoint-initdb.d/migrations/99-logs.sql
ADD --chmod=644 --checksum=sha256:df97ebe148d94cfb92a5e37ebf972dfd496be195f0915ecf14396b2cf50efecb ${BASE}/pooler.sql /docker-entrypoint-initdb.d/migrations/99-pooler.sql

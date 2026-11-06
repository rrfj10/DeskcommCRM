#!/usr/bin/env bash
# Roda a cada deploy da stack e a cada chamada do webhook deste serviço. Só reaplica
# o schema quando ele mudou; aí o CRM, o rest e o realtime ficam parados durante a
# aplicação. Se falhar, o CRM segue na versão que estava.
set -euo pipefail

: "${STACK:?}" "${IMAGE_OWNER:?}" "${DESKCOMM_VERSION:?}" "${POSTGRES_PASSWORD:?}"
: "${SERVICE_ROLE_KEY:?}" "${OWNER_EMAIL:?}" "${OWNER_PASSWORD:?}"
: "${NUVEMSHOP_OAUTH_ENCRYPTION_KEY:?}" "${CPF_ENCRYPTION_KEY:?}"
URL="postgresql://postgres:${POSTGRES_PASSWORD}@supabase-db:5432/postgres"
BASELINE=/schema/baseline.sql
MARCA=/estado/baseline.sha256
# Os mesmos filtros de hostgator-setup-kit/_common.sh (reaplicar_baseline).
ERROS_BENIGNOS='already exists|multiple primary keys|multiple default values|is already a member|already a partition'
ERROS_DE_DISPUTA='deadlock detected|could not serialize access|lock timeout|could not obtain lock|terminating connection|server closed the connection|connection to server was lost|SSL connection has been closed unexpectedly|SSL SYSCALL error|remaining connection slots|too many clients|max client(s| connections) reached|the database system is (starting up|shutting down|in recovery mode|not yet accepting connections)|Temporary failure in name resolution|Connection refused|Connection timed out|timeout expired|Network (is )?unreachable'
# Quem fala com o banco: com eles de pé, a troca das regras de isolamento trava.
QUEM_PAUSA="${STACK}_app ${STACK}_worker ${STACK}_scheduler ${STACK}_rest ${STACK}_realtime"
PAUSADOS=""

die() { printf 'ERRO: %s\n' "$*" >&2; exit 1; }
sql() { PGCONNECT_TIMEOUT=5 psql "$URL" -tAc "$1" | tr -d '[:space:]'; }

retomar() {
  local s
  for s in $PAUSADOS; do
    docker service scale --detach "$s=1" >/dev/null || echo "AVISO: suba $s pelo Portainer" >&2
  done
  PAUSADOS=""
}
pausar() {
  local s
  for s in $QUEM_PAUSA; do
    docker service inspect "$s" >/dev/null 2>&1 || continue
    PAUSADOS="$PAUSADOS $s"
    docker service scale "$s=0" >/dev/null
  done
}
trap retomar EXIT
trap 'exit 130' INT TERM

# Sem ON_ERROR_STOP: ele pararia no primeiro "já existe" e pularia o apêndice,
# onde estão as migrations novas. Sem ele, quem acusa falha é o filtro de erros.
reaplicar() {
  local passada rc saida erros=""
  for passada in 1 2 3; do
    rc=0
    saida="$(psql "$URL" -q -f "$BASELINE" 2>&1)" || rc=$?
    erros="$(printf '%s\n' "$saida" | grep -iE 'ERROR|FATAL' | grep -viE "$ERROS_BENIGNOS" || true)"
    [ "$rc" -eq 0 ] && [ -z "$erros" ] && return 0
    [ "$rc" -ne 0 ] || grep -qiE "$ERROS_DE_DISPUTA" <<<"$erros" || break
    [ "$passada" = 3 ] || { echo "Banco ocupado, aplicando de novo"; sleep $((passada * 10)); }
  done
  printf '%s\n' "$erros" | awk 'NF && ++i <= 20' >&2
  return 1
}

# As funções de cifra leem a chave do banco, não do ambiente. Sem a linha, nenhum
# segredo é gravado e contato é salvo sem CPF. Vale ensure_encryption_key, do kit.
semear_chaves() {
  psql "$URL" -v ON_ERROR_STOP=1 -q -v cifra="$NUVEMSHOP_OAUTH_ENCRYPTION_KEY" -v cpf="$CPF_ENCRYPTION_KEY" <<'SQL'
insert into private.app_secrets (name, value)
values ('nuvemshop_oauth_key', :'cifra'), ('cpf_key', :'cpf')
on conflict (name) do update set value = excluded.value, updated_at = now();
SQL
}

criar_dono() {
  echo "Criando o dono ($OWNER_EMAIL)"
  local i
  for i in $(seq 1 60); do
    curl -fsS -o /dev/null http://supabase-gw:8000/auth/v1/health -H "apikey: $SERVICE_ROLE_KEY" && break
    [ "$i" = 60 ] && die "o Auth não ficou pronto"
    sleep 5
  done
  printf '{"email":"%s","password":"%s","email_confirm":true}' "$OWNER_EMAIL" "$OWNER_PASSWORD" | \
    curl -sS -o /dev/null -X POST http://supabase-gw:8000/auth/v1/admin/users \
      -H "apikey: $SERVICE_ROLE_KEY" -H "Authorization: Bearer $SERVICE_ROLE_KEY" \
      -H "Content-Type: application/json" --data-binary @- || true
  psql "$URL" -v ON_ERROR_STOP=1 -q -v email="$OWNER_EMAIL" <<'SQL'
select set_config('deskcomm.owner', :'email', false);
do $$
declare v_org uuid; v_uid uuid; v_email text := current_setting('deskcomm.owner');
begin
  select id into v_uid from auth.users where email = v_email;
  if v_uid is null then
    raise exception 'usuário % não encontrado: a criação no Auth falhou', v_email;
  end if;
  select id into v_org from public.organizations where slug = 'minha-empresa';
  if v_org is null then
    insert into public.organizations (slug, display_name, legal_name, locale, created_by)
    values ('minha-empresa', 'Minha Empresa', 'Minha Empresa', 'pt-BR', v_uid)
    returning id into v_org;
  end if;
  insert into public.user_organizations (user_id, organization_id, role, accepted_at)
  values (v_uid, v_org, 'admin', now())
  on conflict (user_id, organization_id) do update set role = 'admin', revoked_at = null;
  if not exists (select 1 from public.platform_admins where user_id = v_uid and revoked_at is null) then
    insert into public.platform_admins (user_id, granted_by, scope, mfa_required, reason)
    values (v_uid, v_uid, 'full', false, 'Bootstrap inicial do self-host');
  end if;
end $$;
SQL
}

echo "Esperando o banco e o Storage"
for i in $(seq 1 120); do
  n="$(sql "select count(*) from information_schema.tables where table_schema='storage' and table_name in ('buckets','objects')" 2>/dev/null || true)"
  [ "$n" = "2" ] && break
  [ "$i" = 120 ] && die "o banco ou o Storage não ficaram prontos"
  sleep 5
done

atual="$(sha256sum "$BASELINE" | cut -d' ' -f1)"
existe="$(sql "select 1 from information_schema.tables where table_schema='public' and table_name='organizations'")"
psql "$URL" -v ON_ERROR_STOP=1 -q -c \
  "create extension if not exists vector with schema public; create extension if not exists citext with schema public; create extension if not exists pg_trgm with schema public;" >/dev/null

if [ "$existe" != "1" ]; then
  echo "Banco novo: aplicando o schema"
  psql "$URL" -v ON_ERROR_STOP=1 -q -f "$BASELINE" >/dev/null || die "o schema falhou"
elif [ "${FORCAR_SCHEMA:-}" = "1" ] || [ "$(cat "$MARCA" 2>/dev/null || true)" != "$atual" ]; then
  echo "Schema mudou: pausando o CRM durante a aplicação"
  pausar
  reaplicar || die "o schema não fechou; o CRM segue na versão anterior"
else
  echo "Schema sem mudança"
fi
printf '%s\n' "$atual" > "$MARCA"
semear_chaves
psql "$URL" -q -c "notify pgrst, 'reload schema'" >/dev/null

[ "$(sql "select count(*) from public.platform_admins where revoked_at is null")" != "0" ] || criar_dono
retomar

echo "Atualizando os serviços para $DESKCOMM_VERSION"
for par in app:deskcommcrm worker:deskcomm-worker scheduler:deskcomm-scheduler; do
  s="${STACK}_${par%%:*}"
  docker service inspect "$s" >/dev/null 2>&1 || continue
  docker service update --detach --image "ghcr.io/${IMAGE_OWNER}/${par##*:}:${DESKCOMM_VERSION}" "$s" >/dev/null
done
echo "Pronto."

#!/usr/bin/env bash
# Aplica o schema do CRM no banco da stack supabase. Use em toda atualização,
# antes de trocar a versão. Com banco já instalado, o CRM, o rest e o realtime
# ficam parados durante a aplicação e voltam sozinhos no fim. As stacks precisam
# se chamar "deskcomm" e "supabase".
#
# Uso:
#   bash aplicar-schema.sh                     aplica a versão de stacks.env
#   bash aplicar-schema.sh --version sha-abc1234   aplica outra versão
#   bash aplicar-schema.sh --owner voce@email  também cria o dono (primeira vez)
set -euo pipefail

DIR="${DESKCOMM_DIR:-/opt/deskcomm}"
ENVF="$DIR/stacks.env"
VERSAO=""; OWNER=""
PG=postgres:17-alpine
REDE=deskcomm_net
# Os mesmos filtros de hostgator-setup-kit/_common.sh (reaplicar_baseline).
ERROS_BENIGNOS='already exists|multiple primary keys|multiple default values|is already a member|already a partition'
ERROS_DE_DISPUTA='deadlock detected|could not serialize access|lock timeout|could not obtain lock|terminating connection|server closed the connection|connection to server was lost|SSL connection has been closed unexpectedly|SSL SYSCALL error|remaining connection slots|too many clients|max client(s| connections) reached|the database system is (starting up|shutting down|in recovery mode|not yet accepting connections)|Temporary failure in name resolution|Connection refused|Connection timed out|timeout expired|Network (is )?unreachable'
# Quem fala com o banco: com eles de pé, a troca das regras de isolamento trava.
QUEM_PAUSA="deskcomm_app deskcomm_worker deskcomm_scheduler supabase_rest supabase_realtime"
PAUSADOS=""

die() { printf 'ERRO: %s\n' "$*" >&2; exit 1; }
while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSAO="${2:-}"; shift 2 ;;
    --owner) OWNER="${2:-}"; shift 2 ;;
    *) die "opção desconhecida: $1" ;;
  esac
done
[ -f "$ENVF" ] || die "$ENVF não existe: rode preparar-vps.sh antes"
ler() { sed -n "s/^$1=//p" "$ENVF" | head -1; }
POSTGRES_PASSWORD="$(ler POSTGRES_PASSWORD)"
SERVICE_ROLE_KEY="$(ler SERVICE_ROLE_KEY)"
[ -n "$VERSAO" ] || VERSAO="$(ler DESKCOMM_VERSION)"
[[ "$VERSAO" =~ ^[A-Za-z0-9._-]+$ ]] || die "versão inválida: $VERSAO"
SCHEMA_REPO="$(ler SCHEMA_REPO)"; SCHEMA_REPO="${SCHEMA_REPO:-melgarafael/DeskcommCRM}"
# A tag da imagem vira a referência do Git: 1.2.3 > v1.2.3, sha-abc > abc, branch igual.
case "$VERSAO" in
  sha-*) REF="${VERSAO#sha-}" ;;
  *) if [[ "$VERSAO" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then REF="v$VERSAO"; else REF="$VERSAO"; fi ;;
esac
if [ -n "$OWNER" ]; then
  [[ "$OWNER" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || die "e-mail inválido: $OWNER"
fi
URL="postgresql://postgres:${POSTGRES_PASSWORD}@supabase-db:5432/postgres"
psql_c() { docker run --rm -i --network "$REDE" -e PGCONNECT_TIMEOUT=5 "$@"; }

echo "==> Esperando o banco e o Storage"
for i in $(seq 1 60); do
  n="$(psql_c "$PG" psql "$URL" -tAc \
    "select count(*) from information_schema.tables where table_schema='storage' and table_name in ('buckets','objects')" 2>/dev/null || true)"
  [ "$(printf '%s' "$n" | tr -d '[:space:]')" = "2" ] && break
  [ "$i" = 60 ] && die "o banco ou o Storage não ficaram prontos. A stack supabase está no ar?"
  sleep 5
done

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
# Sem ON_ERROR_STOP: ele pararia no primeiro "já existe" e pularia o apêndice,
# onde estão as migrations novas. Sem ele, quem acusa falha é o filtro de erros.
reaplicar() {
  local passada rc saida erros=""
  : > "$LOG"
  for passada in 1 2 3; do
    rc=0
    saida="$(psql_c -v "$TMP/baseline.sql:/baseline.sql:ro" "$PG" \
      psql "$URL" -q -f /baseline.sql 2>&1)" || rc=$?
    printf -- '-- passada %s (saída %s) --\n%s\n' "$passada" "$rc" "$saida" >> "$LOG"
    erros="$(printf '%s\n' "$saida" | grep -iE 'ERROR|FATAL' | grep -viE "$ERROS_BENIGNOS" || true)"
    [ "$rc" -eq 0 ] && [ -z "$erros" ] && return 0
    [ "$rc" -ne 0 ] || grep -qiE "$ERROS_DE_DISPUTA" <<<"$erros" || break
    [ "$passada" = 3 ] || { echo "    Banco ocupado, aplicando de novo"; sleep $((passada * 10)); }
  done
  printf '%s\n' "$erros" | awk 'NF && ++i <= 20' >&2
  return 1
}

TMP="$(mktemp -d)"; chmod 755 "$TMP"
trap 'retomar; rm -rf "$TMP"' EXIT
trap 'exit 130' INT TERM
echo "==> Baixando o schema da versão $VERSAO"
curl -fsSL --max-time 120 \
  "https://raw.githubusercontent.com/${SCHEMA_REPO}/${REF}/supabase/baseline.sql" \
  -o "$TMP/baseline.sql" || die "não consegui baixar o schema da versão $VERSAO"
chmod 644 "$TMP/baseline.sql"

echo "==> Aplicando o schema"
psql_c "$PG" psql "$URL" -v ON_ERROR_STOP=1 -q -c \
  "create extension if not exists vector with schema public; create extension if not exists citext with schema public; create extension if not exists pg_trgm with schema public;" >/dev/null
LOG="$DIR/schema-$VERSAO.log"
existe="$(psql_c "$PG" psql "$URL" -tAc \
  "select 1 from information_schema.tables where table_schema='public' and table_name='organizations'" 2>/dev/null || true)"
if [ "$(printf '%s' "$existe" | tr -d '[:space:]')" = "1" ]; then
  echo "    Banco já instalado: pausando o CRM durante a aplicação"
  pausar
  reaplicar || die "o schema não fechou. Não troque a versão. Log completo: $LOG"
  retomar
elif ! psql_c -v "$TMP/baseline.sql:/baseline.sql:ro" "$PG" \
    psql "$URL" -v ON_ERROR_STOP=1 -q -f /baseline.sql > "$LOG" 2>&1; then
  tail -5 "$LOG" >&2
  die "o schema falhou. Log completo: $LOG"
fi
tabelas="$(psql_c "$PG" psql "$URL" -tAc "select count(*) from information_schema.tables where table_schema='public'" | tr -d '[:space:]')"
echo "    $tabelas tabelas no schema public"
[ "${tabelas:-0}" -ge 30 ] || die "schema incompleto"

if [ -n "$OWNER" ]; then
  CRED="$DIR/owner-credentials"
  if [ -f "$CRED" ]; then
    SENHA="$(sed -n 's/^OWNER_PASSWORD=//p' "$CRED")"
  else
    SENHA="$(openssl rand -hex 16)"
    ( umask 077; printf 'OWNER_EMAIL=%s\nOWNER_PASSWORD=%s\n' "$OWNER" "$SENHA" > "$CRED" )
  fi
  echo "==> Criando o dono ($OWNER)"
  printf '{"email":"%s","password":"%s","email_confirm":true}' "$OWNER" "$SENHA" | \
    docker run --rm -i --network "$REDE" curlimages/curl:8.11.1 -sS -o /dev/null -X POST \
      http://supabase-gw:8000/auth/v1/admin/users \
      -H "apikey: $SERVICE_ROLE_KEY" -H "Authorization: Bearer $SERVICE_ROLE_KEY" \
      -H "Content-Type: application/json" --data-binary @- || true
  psql_c "$PG" psql "$URL" -v ON_ERROR_STOP=1 -q -v email="$OWNER" <<'SQL'
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
  echo "    Dono pronto. E-mail e senha estão em $CRED"
fi
echo "Pronto."

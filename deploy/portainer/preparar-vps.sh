#!/usr/bin/env bash
# Prepara a VPS para as stacks do Portainer. Rode uma vez, como root, na VPS.
# Baixa os arquivos oficiais do Supabase, cria a rede e gera todas as chaves em
# /opt/deskcomm/stacks.env. Rodar de novo não troca nenhuma chave.
#
# Uso:
#   bash preparar-vps.sh --domain crm.empresa.com.br \
#     --traefik-network dcnet --certresolver letsencryptresolver
set -euo pipefail

SUPABASE_REF="self-hosted/v0.8.1"
DESKCOMM_VERSION_PADRAO="3f-custom"
IMAGE_OWNER_PADRAO="rrfj10"
SCHEMA_REPO_PADRAO="rrfj10/DeskcommCRM"
DIR="${DESKCOMM_DIR:-/opt/deskcomm}"
DOMAIN=""; TRAEFIK_NETWORK=""; CERTRESOLVER=""; ENTRYPOINT="websecure"

die() { printf 'ERRO: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --domain) DOMAIN="${2:-}"; shift 2 ;;
    --traefik-network) TRAEFIK_NETWORK="${2:-}"; shift 2 ;;
    --certresolver) CERTRESOLVER="${2:-}"; shift 2 ;;
    --entrypoint) ENTRYPOINT="${2:-}"; shift 2 ;;
    *) die "opção desconhecida: $1" ;;
  esac
done
[ -n "$DOMAIN" ] && [ -n "$TRAEFIK_NETWORK" ] && [ -n "$CERTRESOLVER" ] \
  || die "informe --domain, --traefik-network e --certresolver"
[[ "$DOMAIN" =~ ^[a-z0-9.-]+\.[a-z]{2,}$ ]] || die "domínio inválido: $DOMAIN"

for c in docker curl openssl sha256sum; do
  command -v "$c" >/dev/null || die "falta o comando $c"
done
[ "$(docker info --format '{{.Swarm.LocalNodeState}}')" = "active" ] \
  || die "o Docker Swarm não está ativo nesta máquina"
docker network inspect "$TRAEFIK_NETWORK" >/dev/null 2>&1 \
  || die "a rede $TRAEFIK_NETWORK não existe (confira com: docker network ls)"

mkdir -p "$DIR/supabase/db/data" "$DIR/supabase/api" "$DIR/supabase/storage" "$DIR/backups"
chmod 700 "$DIR"

BASE="https://raw.githubusercontent.com/supabase/supabase/${SUPABASE_REF}/docker/volumes"
baixar() {  # baixar <sha256> <origem> <destino>
  local tmp; tmp="$(mktemp)"
  curl -fsSL --max-time 60 "$BASE/$2" -o "$tmp" || { rm -f "$tmp"; die "não consegui baixar $2"; }
  [ "$(sha256sum "$tmp" | cut -d' ' -f1)" = "$1" ] || { rm -f "$tmp"; die "$2 não passou na conferência SHA-256"; }
  install -m 644 "$tmp" "$DIR/supabase/$3"
  rm -f "$tmp"
}
echo "==> Baixando arquivos oficiais do Supabase ($SUPABASE_REF)"
baixar 7e9e442e7fc4dae05544c07b67bede37a00d84644304dfce4d937134cb4c8f88 db/realtime.sql db/realtime.sql
baixar b584aaaa0c393f27218f81e01e76e1d07d42f947083249adcd6097ad471cde62 db/webhooks.sql db/webhooks.sql
baixar 3ad717b225daa38aa982da26750f35641eb404e1eb5e69a763c22236ab96c1b2 db/roles.sql db/roles.sql
baixar 1cc94a4f16f6e2932b383cd68e211a96bcae298437ca4120d8a5106396c58465 db/jwt.sql db/jwt.sql
baixar 9dce462adc04137d6afabcf28efa60a6c355270a4b32d7af58891ac4eb964c5f db/_supabase.sql db/_supabase.sql
baixar f0463ce5030907acef49326d2bffd36002df0718035071be7c99bd7fc897c63d db/logs.sql db/logs.sql
baixar df97ebe148d94cfb92a5e37ebf972dfd496be195f0915ecf14396b2cf50efecb db/pooler.sql db/pooler.sql
baixar 3697f23b0be9ec5b829f937c600eb9b878f1f778ab510b42ad5e4f14742447e9 api/envoy/envoy.yaml api/envoy.yaml
baixar 1d7514b891370ed27c25911df008887402e16ab09273e6e433225bb7f09f7905 api/envoy/cds.yaml api/cds.yaml
baixar 9d9a6d6ea0a372be99e165d995f012d383d5cc8473b92a06b7aa0bbd73566c3d api/envoy/lds.template.yaml api/lds.template.yaml
baixar 8a0c9503764de32ba39e0d81e73629457b13ec42ef19897e30e4918c996d0508 api/envoy/docker-entrypoint.sh api/docker-entrypoint.sh

echo "==> Rede interna deskcomm_net"
docker network inspect deskcomm_net >/dev/null 2>&1 \
  || docker network create --driver overlay --attachable deskcomm_net >/dev/null

ENVF="$DIR/stacks.env"
if [ -f "$ENVF" ]; then
  echo "==> $ENVF já existe: chaves mantidas"
else
  echo "==> Gerando chaves em $ENVF"
  hex() { openssl rand -hex "$1"; }
  b64() { openssl rand -base64 32; }
  b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
  JWT_SECRET="$(hex 32)"
  jwt() {  # jwt <role>
    local h p agora fim
    agora="$(date +%s)"; fim=$((agora + 315360000))
    h="$(printf '{"alg":"HS256","typ":"JWT"}' | b64url)"
    p="$(printf '{"role":"%s","iss":"supabase","iat":%s,"exp":%s}' "$1" "$agora" "$fim" | b64url)"
    printf '%s.%s.%s' "$h" "$p" "$(printf '%s.%s' "$h" "$p" | openssl dgst -sha256 -hmac "$JWT_SECRET" -binary | b64url)"
  }
  WAHA_API_KEY="$(hex 32)"
  ( umask 077
    cat > "$ENVF" <<ENV
DESKCOMM_DIR=$DIR
DESKCOMM_VERSION=$DESKCOMM_VERSION_PADRAO
IMAGE_OWNER=$IMAGE_OWNER_PADRAO
SCHEMA_REPO=$SCHEMA_REPO_PADRAO
DOMAIN=$DOMAIN
TRAEFIK_NETWORK=$TRAEFIK_NETWORK
TRAEFIK_ENTRYPOINT=$ENTRYPOINT
TRAEFIK_CERTRESOLVER=$CERTRESOLVER
POSTGRES_PASSWORD=$(hex 32)
JWT_SECRET=$JWT_SECRET
ANON_KEY=$(jwt anon)
SERVICE_ROLE_KEY=$(jwt service_role)
DASHBOARD_PASSWORD=$(hex 24)
SECRET_KEY_BASE=$(hex 32)
REALTIME_DB_ENC_KEY=$(hex 8)
S3_PROTOCOL_ACCESS_KEY_ID=$(hex 16)
S3_PROTOCOL_ACCESS_KEY_SECRET=$(hex 32)
INTERNAL_SECRET=$(hex 32)
INTERNAL_CRON_SECRET=$(hex 32)
NUVEMSHOP_OAUTH_ENCRYPTION_KEY=$(hex 32)
CPF_ENCRYPTION_KEY=$(b64)
AI_CRED_AES_KEY=$(b64)
WAHA_BYO_ENCRYPTION_KEY=$(b64)
IMPERSONATE_COOKIE_SECRET=$(hex 32)
LGPD_SIGNING_KEY=$(hex 32)
WAHA_HMAC_SECRET=$(hex 32)
SRH_TOKEN=$(hex 32)
WAHA_API_KEY=$WAHA_API_KEY
WAHA_API_KEY_SHA512=$(printf '%s' "$WAHA_API_KEY" | openssl dgst -sha512 -hex | awk '{print $NF}')
ENV
  )
fi
chmod 600 "$ENVF"

cat <<MSG

Pronto. Próximo passo: no Portainer, crie a stack "supabase" (ver LEIAME.md).
As variáveis estão em $ENVF. Para ver, rode: cat $ENVF
Esse arquivo guarda as chaves do sistema: não compartilhe nem envie a ninguém.
MSG

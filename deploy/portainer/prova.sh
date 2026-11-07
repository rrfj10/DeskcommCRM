#!/usr/bin/env bash
# Prova a stack de ponta a ponta num Swarm descartável, com um Traefik igual ao da
# VPS (rede não attachable, provider swarm). Roda no CI. Uso: prova.sh <tag> <dono>
set -uo pipefail
VERSAO="$1"; DONO="$2"; D=crm.teste.dev; DIR="$(cd "$(dirname "$0")" && pwd)"; S="$(mktemp -d)"
falhas=0
passo() { printf '\n=== %s [%s]\n' "$*" "$(date +%H:%M:%S)"; }
exige() { if [ "$2" = "$3" ]; then echo "ok    $1 = $2"; else echo "FALHA $1 = $2 (esperado $3)"; falhas=$((falhas+1)); fi; }
setup_estado() { docker service ps deskcomm_setup --no-trunc --format '{{.DesiredState}} {{.CurrentState}}' | head -1 | awk '{print $2}'; }
esperar_setup() {
  local i e
  for i in $(seq 1 120); do
    e="$(setup_estado)"
    case "$e" in Complete|Failed|Rejected) break ;; esac
    sleep 10
  done
  docker service logs --raw --tail 30 deskcomm_setup 2>&1 | cut -c1-200
  exige "setup ($1)" "$e" Complete
}

passo swarm
docker swarm init >/dev/null
docker network create --driver overlay dcnet >/dev/null
docker service create -q --name traefik_traefik --network dcnet \
  --mount type=bind,src=/var/run/docker.sock,dst=/var/run/docker.sock \
  --publish mode=host,target=80,published=80 --publish mode=host,target=443,published=443 \
  traefik:v3.7.16 --log.level=DEBUG --providers.swarm=true --providers.swarm.exposedbydefault=false \
  --providers.swarm.network=dcnet --providers.docker.endpoint=unix:///var/run/docker.sock \
  --providers.docker.exposedbydefault=false --providers.docker.network=dcnet --entrypoints.web.address=:80 --entrypoints.websecure.address=:443 \
  --certificatesresolvers.letsencryptresolver.acme.httpchallenge=true \
  --certificatesresolvers.letsencryptresolver.acme.httpchallenge.entrypoint=web \
  --certificatesresolvers.letsencryptresolver.acme.caserver=https://acme-staging-v02.api.letsencrypt.org/directory \
  --certificatesresolvers.letsencryptresolver.acme.email=teste@example.com \
  --certificatesresolvers.letsencryptresolver.acme.storage=/tmp/acme.json >/dev/null

passo gerar
python3 "$DIR/gerar-stack.py" --domain "$D" --owner dono@example.com --traefik-network dcnet \
  --certresolver letsencryptresolver --version "$VERSAO" --image-owner "$DONO" --saida "$S" >/dev/null
docker stack deploy --with-registry-auth --detach=true -c "$S/stack.yml" deskcomm | tail -3

passo setup
esperar_setup "instalação"
for i in $(seq 1 60); do
  r="$(docker service ls --filter label=com.docker.stack.namespace=deskcomm --format '{{.Name}} {{.Replicas}}' | grep -v _setup | grep -c ' 1/1')"
  [ "$r" = 13 ] && break; sleep 10
done
docker service ls --format '{{.Name}} {{.Replicas}}'
exige "serviços 1/1" "$r" 13
sleep 20

passo checagens
. "$S/chaves.env" 2>/dev/null
C="curl -sk --max-time 20 --resolve $D:443:127.0.0.1"; U="https://$D"
cod() { $C -o /dev/null -w '%{http_code}' "$@"; }
exige "/" "$(cod "$U/")" 200
exige "/app" "$(cod "$U/app")" 307
exige "/login" "$(cod "$U/login")" 200
exige "auth" "$(cod -H "apikey: $ANON_KEY" "$U/auth/v1/health")" 200
exige "webhook waha" "$(cod -X POST "$U/api/v1/webhooks/waha")" 403
T="$($C -X POST "$U/auth/v1/token?grant_type=password" -H "apikey: $ANON_KEY" -H 'Content-Type: application/json' \
  -d "{\"email\":\"dono@example.com\",\"password\":\"$OWNER_PASSWORD\"}" | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')"
exige "login do dono" "$([ -n "$T" ] && echo sim || echo nao)" sim
exige "RLS com login" "$($C -H "apikey: $ANON_KEY" -H "Authorization: Bearer $T" "$U/rest/v1/organizations?select=slug")" '[{"slug":"minha-empresa"}]'
exige "sem login não vaza" "$($C -H "apikey: $ANON_KEY" "$U/rest/v1/organizations?select=slug" | grep -c minha-empresa)" 0
exige "realtime" "$($C --http1.1 -o /dev/null -w '%{http_code}' --max-time 4 -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
  -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' "$U/realtime/v1/websocket?apikey=$ANON_KEY&vsn=1.0.0")" 101
cifra() { $C -X POST "$U/rest/v1/rpc/$1" -H "apikey: $SERVICE_ROLE_KEY" -H "Authorization: Bearer $SERVICE_ROLE_KEY" \
  -H 'Content-Type: application/json' -d "$2" | grep -cE '^"\\+x[0-9a-f]+"$'; }
exige "cifra de segredos" "$(cifra fn_encrypt_oauth '{"plaintext":"x"}')" 1
exige "cifra do CPF" "$(cifra encrypt_cpf '{"p_plaintext":"12345678901"}')" 1
echo "buckets: $($C -H "apikey: $SERVICE_ROLE_KEY" -H "Authorization: Bearer $SERVICE_ROLE_KEY" "$U/storage/v1/bucket" | cut -c1-160)"

passo confirmação da versão em execução
runtime_confirmado() {
  $C -H "apikey: $SERVICE_ROLE_KEY" -H "Authorization: Bearer $SERVICE_ROLE_KEY" \
    "$U/rest/v1/system_version?select=runtime_confirmation,agent_last_seen_at&id=eq.1" | python3 -c '
import json,sys,datetime
try:
    row=json.load(sys.stdin)[0]
    snapshot=row["runtime_confirmation"]
    services=snapshot["services"]
    now=datetime.datetime.now(datetime.timezone.utc)
    age=(now-datetime.datetime.fromisoformat(snapshot["collected_at"].replace("Z","+00:00"))).total_seconds()
    good=(not snapshot["issues"] and len(services)==3 and {s["role"] for s in services}=={"app","worker","scheduler"}
          and all(s["running"] and s["healthy"] and s["source_verified"] for s in services)
          and len({(s["revision"],s["base_version"],s["base_revision"]) for s in services})==1
          and 0 <= age < 900)
    sys.exit(0 if good else 1)
except (ValueError,TypeError,KeyError,IndexError):
    sys.exit(1)
'
}
confirmado=nao
for i in $(seq 1 60); do
  if runtime_confirmado; then confirmado=sim; break; fi
  sleep 5
done
exige "versão e serviços observados" "$confirmado" sim

passo traefik
docker service inspect deskcomm_app --format '{{json .Spec.Labels}}' | cut -c1-600
docker service logs --raw --tail 400 traefik_traefik 2>&1 | grep -iE 'deskcomm|resolver|network|error' \
  | sed -E 's/eyJ[A-Za-z0-9._-]+/<jwt>/g' | tail -30 | cut -c1-260

passo atualização com schema
docker service update --detach --force --env-add FORCAR_SCHEMA=1 deskcomm_setup >/dev/null
sleep 15
esperar_setup "reaplicar schema"
sleep 60
exige "/app depois de atualizar" "$(cod "$U/app")" 307
exige "RLS depois de atualizar" "$($C -H "apikey: $ANON_KEY" -H "Authorization: Bearer $T" "$U/rest/v1/organizations?select=slug")" '[{"slug":"minha-empresa"}]'

passo logs
for s in app worker scheduler waha realtime api-gw; do
  echo "--- $s"; docker service logs --tail 6 --no-task-ids "deskcomm_$s" 2>&1 | sed -E 's/eyJ[A-Za-z0-9._-]+/<jwt>/g' | cut -c1-170
done
echo; echo "falhas=$falhas"
[ "$falhas" = 0 ]

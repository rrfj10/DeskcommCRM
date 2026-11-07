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
  [ "$r" = 12 ] && break; sleep 10
done
docker service ls --format '{{.Name}} {{.Replicas}}'
exige "serviços 1/1" "$r" 12
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

passo "login: o que as telas decidem chega ao GoTrue e sobrevive ao redeploy"
# Grava Admin → E-mail e Admin → Cadastro direto no banco (a senha com aspas e
# `$`, para provar o arquivo que o sh do auth carrega), chama o setup e lê o env
# do PROCESSO do GoTrue — não o do serviço, onde o SMTP não mora mais.
DB="$(docker ps -q -f name=deskcomm_db -f status=running | head -1)"
docker exec -i -e PGPASSWORD="$POSTGRES_PASSWORD" "$DB" psql -h 127.0.0.1 -U postgres -d postgres -v ON_ERROR_STOP=1 -q <<'SQL' >/dev/null
insert into public.platform_smtp_settings (id, smtp_host, smtp_port, smtp_username, smtp_password_encrypted, from_email, from_name)
values (1, 'smtp.prova.test', 465, 'prova', public.fn_encrypt_oauth('se''nha $x'), 'login@prova.test', 'Prova')
on conflict (id) do update set smtp_host = excluded.smtp_host, smtp_port = excluded.smtp_port,
  smtp_username = excluded.smtp_username, smtp_password_encrypted = excluded.smtp_password_encrypted,
  from_email = excluded.from_email, from_name = excluded.from_name;
insert into public.platform_settings (id, signup_mode) values (1, 'so_convite')
on conflict (id) do update set signup_mode = excluded.signup_mode;
SQL
docker service update --detach --force deskcomm_setup >/dev/null
sleep 15
esperar_setup "levar as telas ao login"
env_do_auth() {
  local c
  c="$(docker ps -q -f name=deskcomm_auth -f status=running | head -1)"
  [ -n "$c" ] && docker exec "$c" sh -c 'tr "\0" "\n" < /proc/1/environ' 2>/dev/null
}
# Espera o auth reiniciado responder com o modo novo (endpoint público).
fechado() { $C -H "apikey: $ANON_KEY" "$U/auth/v1/settings" | grep -c '"disable_signup":true'; }
for i in $(seq 1 24); do [ "$(fechado)" = 1 ] && break; sleep 5; done
exige "cadastro direto fechado (so_convite)" "$(fechado)" 1
exige "SMTP da tela no GoTrue" "$(env_do_auth | grep -cx 'GOTRUE_SMTP_HOST=smtp.prova.test')" 1
exige "senha com aspas e \$ intacta" "$(env_do_auth | grep -cxF "GOTRUE_SMTP_PASS=se'nha \$x")" 1
exige "SMTP fora do env do serviço" "$(docker service inspect deskcomm_auth \
  --format '{{range .Spec.TaskTemplate.ContainerSpec.Env}}{{println .}}{{end}}' | grep -c '^GOTRUE_SMTP_')" 0
# O defeito que o arquivo conserta: "Update the stack" que muda o auth o refaz a
# partir do arquivo da stack, e o setup NÃO roda de novo (o serviço dele não
# mudou). Uma variável inócua força a recriação do auth.
sed 's/^      GOTRUE_API_HOST: 0.0.0.0$/&\n      PROVA_REDEPLOY: "1"/' "$S/stack.yml" > "$S/stack-redeploy.yml"
docker stack deploy --with-registry-auth --detach=true -c "$S/stack-redeploy.yml" deskcomm >/dev/null
for i in $(seq 1 36); do
  env_do_auth | grep -qx 'PROVA_REDEPLOY=1' && [ "$(cod -H "apikey: $ANON_KEY" "$U/auth/v1/health")" = 200 ] && break
  sleep 5
done
exige "auth recriado pelo redeploy" "$(env_do_auth | grep -cx 'PROVA_REDEPLOY=1')" 1
exige "SMTP sobrevive ao redeploy" "$(env_do_auth | grep -cx 'GOTRUE_SMTP_HOST=smtp.prova.test')" 1
exige "cadastro segue fechado depois do redeploy" "$(fechado)" 1

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

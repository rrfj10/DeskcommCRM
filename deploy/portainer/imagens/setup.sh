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

# >>> gotrue — bloco que tests/shell/portainer-setup-smtp.test.sh extrai e roda sozinho
# ── O que as telas decidem chega ao serviço de login ────────────────────────
#
# O GoTrue self-hosted NÃO tem API de configuração: SMTP e DISABLE_SIGNUP moram
# no env do processo. Duas formas que NÃO servem, e por quê:
#
#   - o molde apontar para `supabase-mail`: o serviço não existe nesta stack, e
#     confirmação de cadastro e "esqueci a senha" ficavam mudos enquanto
#     Admin → E-mail dizia "Em uso" (medido em 2026-11-06);
#   - `docker service update --env-add`: todo "Update the stack" refaz o `auth`
#     a partir do arquivo da stack e o env some — e o setup só roda de novo se o
#     serviço DELE mudou. O e-mail morria em silêncio no redeploy seguinte.
#
# O que vale: o setup escreve GOTRUE_ENV num volume que o `auth` monta só para
# leitura, e o comando do `auth` (stack.yml) carrega o arquivo antes de subir.
# O volume sobrevive a redeploy; só muda quando o setup reescreve, e aí o setup
# reinicia o `auth` — só quando o conteúdo mudou.
#
# Fontes, na precedência do app e do kit (hostgator-setup-kit/_common.sh):
#   e-mail   → platform_smtp_settings (Admin → E-mail; host E remetente); senão
#              a Resend de platform_config, que também fala SMTP
#              (smtp.resend.com:465, usuário `resend`, senha = a chave); senão
#              nada muda — quem pôs SMTP direto no env do `auth` na stack manda.
#   cadastro → platform_settings.signup_mode: `so_convite` fecha o cadastro
#              direto (GOTRUE_DISABLE_SIGNUP=true); os outros e "sem linha", aberto.
# Consulta que FALHA não é "não tem": aquele grupo fica como estava, e o log diz.
#
# Stack antiga (colada antes deste arquivo, sem o volume no `auth`): cai no
# `--env-add` de antes, que vale até o próximo "Update the stack", e avisa.
GOTRUE_ENV="${GOTRUE_ENV:-/gotrue-env/gotrue.env}"
SEP=$'\x1f'

# Valor entre aspas simples, seguro para o `.` do sh do `auth`.
aspas_sh() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# Abre o envelope AES-256-GCM de platform_config (lib/crypto/aes_gcm.ts), com a
# AI_CRED_AES_KEY do app. Entrada: "cifra iv tag" em hex. Sai 1 se não abrir.
abrir_envelope() {
  [ -n "${AI_CRED_AES_KEY:-}" ] && command -v node >/dev/null 2>&1 || return 1
  node -e "const [c,i,t]=require('fs').readFileSync(0,'utf8').trim().split(' ').map(h=>Buffer.from(h,'hex'));const d=require('crypto').createDecipheriv('aes-256-gcm',Buffer.from(process.env.AI_CRED_AES_KEY,'base64'),i);d.setAuthTag(t);process.stdout.write(Buffer.concat([d.update(c),d.final()]).toString('utf8'))" 2>/dev/null
}

# A Resend da instalação, como valorDaInstalacao (lib/instalacao/config.ts):
# a linha manda, inclusive vazia; sem linha, o env. Envelope que não abre vale
# vazio. Imprime "chave<SEP>remetente"; sai 1 sem os dois, 2 se o banco falhou.
resend_da_instalacao() {
  local linhas chave eh valor ct iv tag api="${RESEND_API_KEY:-}" de="${RESEND_FROM_EMAIL:-}"
  linhas="$(psql "$URL" -tA -F "$SEP" -c "select chave, eh_segredo, coalesce(valor,''),
      coalesce(encode(ciphertext,'hex'),''), coalesce(encode(iv,'hex'),''), coalesce(encode(tag,'hex'),'')
    from public.platform_config where chave in ('RESEND_API_KEY','RESEND_FROM_EMAIL')" 2>/dev/null)" || return 2
  while IFS="$SEP" read -r chave eh valor ct iv tag; do
    [ -n "$chave" ] || continue
    if [ "$eh" = t ]; then
      valor="$(printf '%s %s %s' "$ct" "$iv" "$tag" | abrir_envelope)" || valor=""
    fi
    case "$chave" in
      RESEND_API_KEY) api="$valor" ;;
      RESEND_FROM_EMAIL) de="$valor" ;;
    esac
  done <<<"$linhas"
  api="$(printf '%s' "$api" | tr -d '[:space:]')"; de="$(printf '%s' "$de" | tr -d '[:space:]')"
  [ -n "$api" ] && [ -n "$de" ] || return 1
  printf '%s%s%s' "$api" "$SEP" "$de"
}

# Grupo e-mail, como pares "CHAVE<SEP>valor" por linha. Sai 1 sem fonte, 2 se
# não deu para ler (banco, ou valor com quebra de linha, que o env não carrega).
pares_do_email() {
  local linha="" host="" porta="" usuario="" senha="" remetente="" nome="" r="" rc=0
  linha="$(psql "$URL" -tA -F "$SEP" -c "select coalesce(smtp_host,''), smtp_port,
      coalesce(smtp_username,''),
      coalesce(case when smtp_password_encrypted is null then '' else public.fn_decrypt_oauth(smtp_password_encrypted) end,''),
      coalesce(from_email,''), coalesce(from_name,'')
    from public.platform_smtp_settings where id = 1" 2>/dev/null)" || return 2
  case "$linha" in *$'\n'*) return 2 ;; esac
  [ -z "$linha" ] || IFS="$SEP" read -r host porta usuario senha remetente nome <<<"$linha"
  if [ -z "$host" ] || [ -z "$remetente" ]; then
    r="$(resend_da_instalacao)" || { rc=$?; return "$rc"; }
    IFS="$SEP" read -r senha remetente <<<"$r"
    host=smtp.resend.com; porta=465; usuario=resend
  fi
  printf 'GOTRUE_SMTP_HOST%s%s\n' "$SEP" "$host"
  printf 'GOTRUE_SMTP_PORT%s%s\n' "$SEP" "${porta:-587}"
  printf 'GOTRUE_SMTP_USER%s%s\n' "$SEP" "$usuario"
  printf 'GOTRUE_SMTP_PASS%s%s\n' "$SEP" "$senha"
  printf 'GOTRUE_SMTP_ADMIN_EMAIL%s%s\n' "$SEP" "$remetente"
  # Nome em branco não vira env: a marca do produto não é deste arquivo.
  [ -z "$nome" ] || printf 'GOTRUE_SMTP_SENDER_NAME%s%s\n' "$SEP" "$nome"
}

# Grupo cadastro. Mesma régua do kit e de disableSignupEsperado
# (lib/auth/aviso-da-troca-de-modo.ts). Sai 2 se não deu para ler.
pares_do_cadastro() {
  local modo v
  modo="$(psql "$URL" -tA -c "select signup_mode from public.platform_settings where id = 1" 2>/dev/null)" || return 2
  modo="$(printf '%s' "$modo" | tr -d '[:space:]')"
  case "$modo" in
    so_convite) v=true ;;
    ""|aberto|com_aprovacao) v=false ;;
    *) return 2 ;;
  esac
  printf 'GOTRUE_DISABLE_SIGNUP%s%s\n' "$SEP" "$v"
}

# Pares → linhas `export CHAVE='valor'` do arquivo.
como_export() {
  local k v
  while IFS="$SEP" read -r k v; do
    [ -n "$k" ] && printf 'export %s=%s\n' "$k" "$(aspas_sh "$v")"
  done <<<"$1"
  return 0
}

gotrue_por_arquivo() {
  local img="$1" re="$2" email="$3" rc="$4" cad="$5" antigo="" novo="" tmp
  antigo="$(cat "$GOTRUE_ENV" 2>/dev/null || true)"
  novo="$(
    echo "# Escrito pelo setup da stack (deploy/portainer/imagens/setup.sh). Não edite:"
    echo "# o próximo setup reescreve a partir de Admin → E-mail e Admin → Cadastro."
    if [ "$re" = 0 ]; then como_export "$email"; else grep '^export GOTRUE_SMTP_' <<<"$antigo" || true; fi
    if [ "$rc" = 0 ]; then como_export "$cad"; else grep '^export GOTRUE_DISABLE_SIGNUP=' <<<"$antigo" || true; fi
  )"
  # Compara só o que o `auth` carrega: cabeçalho novo numa versão não reinicia.
  if [ "$(grep -v '^#' <<<"$novo" || true)" = "$(grep -v '^#' <<<"$antigo" || true)" ]; then
    echo "Serviço de login já estava em dia"
    return 0
  fi
  tmp="$GOTRUE_ENV.novo"
  printf '%s\n' "$novo" > "$tmp"
  # 0644: o `auth` roda sem root e precisa ler. O volume só existe para ele e
  # para o setup, como o env de qualquer serviço da stack.
  chmod 0644 "$tmp"
  mv -f "$tmp" "$GOTRUE_ENV"
  if docker service update --detach --force "$img" >/dev/null 2>&1; then
    echo "Serviço de login atualizado a partir de Admin → E-mail e Admin → Cadastro"
  else
    echo "AVISO: o arquivo do login foi escrito, mas $img não reiniciou; reinicie-o no Portainer."
  fi
  return 0
}

# Stack antiga: o `auth` não monta o volume. Vale até o próximo "Update the stack".
gotrue_por_env() {
  local img="$1" pares="$2" atual k v falta=0
  local args=()
  [ -n "$pares" ] || return 0
  atual="$(docker service inspect \
    --format '{{range .Spec.TaskTemplate.ContainerSpec.Env}}{{println .}}{{end}}' "$img" 2>/dev/null || true)"
  while IFS="$SEP" read -r k v; do
    [ -n "$k" ] || continue
    grep -Fqx -- "$k=$v" <<<"$atual" || falta=1
    args+=(--env-add "$k=$v")
  done <<<"$pares"
  if [ "$falta" = 0 ]; then
    echo "Serviço de login já estava em dia"
    return 0
  fi
  if docker service update --detach "${args[@]}" "$img" >/dev/null 2>&1; then
    echo "Serviço de login atualizado a partir de Admin → E-mail e Admin → Cadastro"
  else
    echo "AVISO: não deu para aplicar a configuração em $img; confira o serviço no Portainer."
  fi
  return 0
}

sincronizar_gotrue() {
  local img="${STACK}_auth" email="" cad="" re=0 rc=0 montagens="" env_atual="" pasta
  pasta="$(dirname "$GOTRUE_ENV")"
  email="$(pares_do_email)" || re=$?
  cad="$(pares_do_cadastro)" || rc=$?
  montagens="$(docker service inspect \
    --format '{{range .Spec.TaskTemplate.ContainerSpec.Mounts}}{{println .Target}}{{end}}' "$img" 2>/dev/null || true)"
  env_atual="$(docker service inspect \
    --format '{{range .Spec.TaskTemplate.ContainerSpec.Env}}{{println .}}{{end}}' "$img" 2>/dev/null || true)
$(cat "$GOTRUE_ENV" 2>/dev/null || true)"

  case "$re" in
    1) if grep -qE '^(export )?GOTRUE_SMTP_HOST=.+' <<<"$env_atual"; then
         echo "E-mail do login: Admin → E-mail e Resend vazios; fica o que o serviço já tem"
       else
         echo "AVISO: sem servidor de e-mail em Admin → E-mail nem Resend. O login continua sem mandar confirmação de cadastro nem 'esqueci a senha'."
       fi ;;
    2) echo "AVISO: não deu para ler o e-mail de Admin → E-mail no banco; o do login ficou como estava." ;;
  esac
  [ "$rc" = 0 ] || echo "AVISO: não deu para ler o modo de cadastro no banco; o cadastro direto ficou como estava."

  if grep -qxF -- "$pasta" <<<"$montagens" && [ -d "$pasta" ]; then
    gotrue_por_arquivo "$img" "$re" "$email" "$rc" "$cad"
  else
    echo "AVISO: a stack colada no Portainer é anterior ao arquivo do login. Gere a nova (gerar-stack.py) e cole em Stacks › deskcomm › Editor; até lá, o e-mail do login some a cada 'Update the stack'."
    [ "$re" = 0 ] || email=""
    [ "$rc" = 0 ] || cad=""
    gotrue_por_env "$img" "$(printf '%s\n%s' "$email" "$cad")"
  fi
  return 0
}
# <<< gotrue

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
# Depois de semear: a senha do SMTP é cifrada com a chave que acabou de ir para
# o banco, e fn_decrypt_oauth não abre o envelope antes disso.
sincronizar_gotrue
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

#!/usr/bin/env bash
# O SMTP de Admin → E-mail chega ao serviço de login na stack do Portainer.
#
#   bash tests/shell/portainer-setup-smtp.test.sh
#
# ── POR QUE ESTE ARQUIVO EXISTE ──────────────────────────────────────────────
# O GoTrue self-hosted não tem API de configuração: o servidor de e-mail dele
# mora no env do serviço `auth`. O molde do Portainer apontava para
# `supabase-mail:2500` com `fake_mail_user` — serviço que NÃO existe na stack —
# então a confirmação de cadastro e o "esqueci a senha" nunca saíam, enquanto a
# tela Admin → E-mail dizia "Em uso" (ela configura o SMTP do CRM, que é outro
# caminho). Quem convidava a equipe via "E-mail enviado: Sim" e quem era
# convidado via "o envio de e-mails desta instalação não está configurado".
#
# ── O QUE ESTÁ SOB PROVA ────────────────────────────────────────────────────
#   1. o molde da stack não traz mais SMTP de mentira (é o que gerar-stack.py
#      copia para a pasta privada) e marca SINGLE_SERVER=1, para o CRM avisar
#      quando o login estiver sem e-mail (lib/email/estado.ts);
#   2. o setup lê a linha de `platform_smtp_settings` — a MESMA fonte do app —
#      e decifra a senha com `fn_decrypt_oauth`, depois de `semear_chaves`
#      (sem a chave no banco, o envelope não abre);
#   3. com SMTP na tela, ele aplica os seis `GOTRUE_SMTP_*` no serviço
#      `<STACK>_auth` via `docker service update --env-add`;
#   4. quando o serviço já está em dia, NÃO reinicia o auth;
#   5. quando a tela não tem SMTP, NÃO apaga o que foi posto no serviço à mão —
#      e avisa quando não há nenhum dos dois;
#   6. a senha do SMTP nunca vai para a saída do setup (log de serviço no
#      Portainer é legível por quem tem acesso à stack).
#
# Não precisa de Docker nem de Postgres: `psql` e `docker` são dublês, e a
# função é extraída do setup real para rodar sozinha.
set -uo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
SETUP="$RAIZ/deploy/portainer/imagens/setup.sh"
MOLDE="$RAIZ/deploy/portainer/stack.yml"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
US=$'\x1f'

falhas=0
casos=0

ok()    { printf '  ok     %s\n' "$1"; }
falha() { printf '  FALHA  %s\n' "$1"; falhas=$((falhas + 1)); }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else falha "$d"; fi; }

# ── A função, sozinha ───────────────────────────────────────────────────────
# Extraída do arquivo real: o que roda aqui é o que roda no deploy. O resto do
# setup fala com o Docker e com o banco de verdade.
awk '/^sincronizar_smtp_do_gotrue\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' \
  "$SETUP" > "$TMP/funcao.sh"

cat > "$TMP/rodar.sh" <<'HARNESS'
#!/usr/bin/env bash
set -euo pipefail
STACK="${STACK:-deskcomm}"
URL="postgresql://postgres:senha-do-banco@supabase-db:5432/postgres"
psql() {
  [ -s "$DB" ] || return 1   # sem linha (ou sem a tabela): o setup não impõe nada
  cat "$DB"
}
docker() {
  case "$1 $2" in
    "service inspect") cat "$ENV_ATUAL"; return 0 ;;
    "service update")  printf '%s\n' "$*" >> "$CHAMADAS"; return 0 ;;
  esac
  return 1
}
. "$FUNCAO"
sincronizar_smtp_do_gotrue
HARNESS

SAIDA=""
RC=0
# uso: preparar <caso> <linha-do-banco> <env-do-servico>
preparar() {
  local caso="$1"
  mkdir -p "$TMP/$caso"
  printf '%s' "$2" > "$TMP/$caso/db"
  printf '%s' "$3" > "$TMP/$caso/env"
  : > "$TMP/$caso/chamadas"
}

# uso: rodar <caso>
rodar() {
  SAIDA="$(DB="$TMP/$1/db" ENV_ATUAL="$TMP/$1/env" CHAMADAS="$TMP/$1/chamadas" \
    FUNCAO="$TMP/funcao.sh" bash "$TMP/rodar.sh" 2>&1)"
  RC=$?
}

chamadas()    { cat "$TMP/$1/chamadas"; }
atualizou()   { [ -s "$TMP/$1/chamadas" ]; }
nao_atualizou() { [ ! -s "$TMP/$1/chamadas" ]; }

printf '\n1) o molde da stack não tem SMTP de mentira\n'
casos=$((casos + 1))
check "não aponta mais para o serviço inexistente supabase-mail (só em comentário)" \
  bash -c '! grep -E "supabase-mail" "$1" | grep -qv "^[[:space:]]*#"' _ "$MOLDE"
check "não tem usuário/senha de mentira" \
  bash -c '! grep -qE "fake_mail_(user|password)" "$1"' _ "$MOLDE"
check "o env do serviço auth não declara mais GOTRUE_SMTP_*" \
  bash -c '! grep -q "GOTRUE_SMTP_" "$1"' _ "$MOLDE"
check "mantém a confirmação de e-mail ligada (autoconfirm false)" \
  grep -q 'GOTRUE_MAILER_AUTOCONFIRM: "false"' "$MOLDE"
check "marca SINGLE_SERVER=1 no env comum do CRM" grep -q 'SINGLE_SERVER: "1"' "$MOLDE"
# A marca tem que estar no bloco herdado pelo app, não num serviço qualquer.
check "SINGLE_SERVER está no x-crm-env (antes de services:)" bash -c \
  'awk "/^x-crm-env:/{f=1} /^services:/{f=0} f" "$1" | grep -q "SINGLE_SERVER: \"1\""' _ "$MOLDE"

printf '\n2) o setup sabe de onde ler, e na ordem certa\n'
casos=$((casos + 1))
check "sintaxe do setup válida" bash -n "$SETUP"
check "a função existe uma vez só" test "$(grep -c '^sincronizar_smtp_do_gotrue() {' "$SETUP")" = 1
check "lê a linha da tela (platform_smtp_settings)" \
  grep -q 'from public.platform_smtp_settings' "$SETUP"
check "decifra a senha com fn_decrypt_oauth (chave vem do banco)" \
  grep -q 'fn_decrypt_oauth(smtp_password_encrypted)' "$SETUP"
check "roda depois de semear_chaves (senão o envelope não abre)" bash -c '
  s=$(grep -n "^semear_chaves$" "$1" | cut -d: -f1)
  f=$(grep -n "^sincronizar_smtp_do_gotrue$" "$1" | cut -d: -f1)
  [ -n "$s" ] && [ -n "$f" ] && [ "$f" -gt "$s" ]' _ "$SETUP"

printf '\n3) com SMTP na tela, ele chega ao serviço auth\n'
casos=$((casos + 1))
LINHA="smtp.hostinger.com${US}465${US}naoresponda@exemplo.test${US}senha-do-smtp${US}naoresponda@exemplo.test${US}Direct Line"
preparar aplica "$LINHA" 'GOTRUE_MAILER_AUTOCONFIRM=false
GOTRUE_SMTP_HOST=supabase-mail
GOTRUE_SMTP_PORT=2500'
rodar aplica
check "saiu 0" test "$RC" = 0
check "chamou o serviço deskcomm_auth" grep -q 'deskcomm_auth' "$TMP/aplica/chamadas"
check "com --detach (o setup não espera o auth subir)" grep -q -- '--detach' "$TMP/aplica/chamadas"
check "host da tela" grep -q -- '--env-add GOTRUE_SMTP_HOST=smtp.hostinger.com' "$TMP/aplica/chamadas"
check "porta da tela" grep -q -- '--env-add GOTRUE_SMTP_PORT=465' "$TMP/aplica/chamadas"
check "usuário da tela" grep -q -- '--env-add GOTRUE_SMTP_USER=naoresponda@exemplo.test' "$TMP/aplica/chamadas"
check "senha decifrada" grep -q -- '--env-add GOTRUE_SMTP_PASS=senha-do-smtp' "$TMP/aplica/chamadas"
check "remetente da tela" grep -q -- '--env-add GOTRUE_SMTP_ADMIN_EMAIL=naoresponda@exemplo.test' "$TMP/aplica/chamadas"
check "nome do remetente da tela" grep -q -- '--env-add GOTRUE_SMTP_SENDER_NAME=Direct Line' "$TMP/aplica/chamadas"
check "são seis variáveis, nem uma a mais" test "$(grep -o -- '--env-add' "$TMP/aplica/chamadas" | wc -l | tr -d ' ')" = 6
case "$SAIDA" in
  *"atualizado"*) ok "diz o que fez" ;;
  *)              falha "não diz o que fez — saída: $SAIDA" ;;
esac
case "$SAIDA" in
  *senha-do-smtp*) falha "a senha do SMTP vazou para o log do setup" ;;
  *)               ok "não imprime a senha do SMTP" ;;
esac

printf '\n4) serviço já em dia não é reiniciado\n'
casos=$((casos + 1))
preparar idem "$LINHA" 'GOTRUE_MAILER_AUTOCONFIRM=false
GOTRUE_SMTP_HOST=smtp.hostinger.com
GOTRUE_SMTP_PORT=465
GOTRUE_SMTP_USER=naoresponda@exemplo.test
GOTRUE_SMTP_PASS=senha-do-smtp
GOTRUE_SMTP_ADMIN_EMAIL=naoresponda@exemplo.test
GOTRUE_SMTP_SENDER_NAME=Direct Line'
rodar idem
check "saiu 0" test "$RC" = 0
check "não chamou docker service update" nao_atualizou idem
case "$SAIDA" in
  *"já estava em dia"*) ok "diz que já estava em dia" ;;
  *)                    falha "não reconheceu o estado — saída: $SAIDA" ;;
esac

printf '\n5) porta em branco cai no padrão; sem nome, o env não inventa um\n'
casos=$((casos + 1))
preparar sem-nome "smtp.exemplo.test${US}${US}login${US}segredo${US}de@exemplo.test${US}" ''
rodar sem-nome
check "saiu 0" test "$RC" = 0
check "aplicou o host" grep -q -- '--env-add GOTRUE_SMTP_HOST=smtp.exemplo.test' "$TMP/sem-nome/chamadas"
check "não mandou GOTRUE_SMTP_SENDER_NAME" \
  bash -c '! grep -q "GOTRUE_SMTP_SENDER_NAME" "$1"' _ "$TMP/sem-nome/chamadas"
check "porta em branco vira 587 (o padrão do kit)" \
  grep -q -- '--env-add GOTRUE_SMTP_PORT=587' "$TMP/sem-nome/chamadas"

printf '\n6) sem SMTP na tela, o que está no serviço manda\n'
casos=$((casos + 1))
preparar so-no-servico "" 'GOTRUE_SMTP_HOST=smtp.contratado.pelo.tecnico
GOTRUE_SMTP_PORT=465'
rodar so-no-servico
check "saiu 0" test "$RC" = 0
check "não sobrescreveu o env do serviço" nao_atualizou so-no-servico
case "$SAIDA" in
  *"configurado no próprio serviço"*) ok "reconhece que o serviço já tem e-mail" ;;
  *)                                  falha "não reconheceu — saída: $SAIDA" ;;
esac

printf '\n7) sem nenhum dos dois, avisa (é o caso que quebra "esqueci a senha")\n'
casos=$((casos + 1))
preparar vazio "" 'GOTRUE_MAILER_AUTOCONFIRM=false'
rodar vazio
check "saiu 0 (aviso não derruba o deploy)" test "$RC" = 0
check "não chamou o serviço" nao_atualizou vazio
case "$SAIDA" in
  *AVISO*Admin*) ok "avisa e diz onde configurar" ;;
  *)             falha "não avisou — saída: $SAIDA" ;;
esac

printf '\n%s caso(s), %s falha(s)\n' "$casos" "$falhas"
if [ "$falhas" -ne 0 ]; then
  echo "==> O SMTP da tela não chega ao login: cadastro por convite e 'esqueci a senha' ficam mudos."
  exit 1
fi
echo "==> O SMTP de Admin → E-mail chega ao serviço auth pelo setup."

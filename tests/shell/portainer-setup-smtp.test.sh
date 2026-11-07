#!/usr/bin/env bash
# O que Admin → E-mail e Admin → Cadastro decidem chega ao serviço de login na
# stack do Portainer — e continua lá depois de um "Update the stack".
#
#   bash tests/shell/portainer-setup-smtp.test.sh
#
# ── POR QUE ESTE ARQUIVO EXISTE ──────────────────────────────────────────────
# O GoTrue self-hosted não tem API de configuração: SMTP e DISABLE_SIGNUP moram
# no env do processo. Duas tentativas falharam antes desta:
#
#   - o molde apontava para `supabase-mail:2500` com `fake_mail_user`, serviço
#     que NÃO existe na stack: confirmação de cadastro e "esqueci a senha" nunca
#     saíam, enquanto Admin → E-mail dizia "Em uso";
#   - o setup punha o SMTP no env do serviço com `docker service update
#     --env-add`, e todo "Update the stack" refazia o serviço a partir do
#     arquivo — o env sumia e o setup não rodava de novo.
#
# O desenho que vale: o setup escreve um arquivo num volume, e o comando do
# `auth` o carrega ao subir. Este teste prova a metade que roda sem Docker; a
# metade do Swarm (o arquivo sobrevive ao redeploy, o GoTrue o carrega) está em
# deploy/portainer/prova.sh, que roda no CI.
#
# ── O QUE ESTÁ SOB PROVA ────────────────────────────────────────────────────
#   1. o molde: sem SMTP de mentira, `auth` carrega o arquivo de um volume
#      só-leitura que o setup escreve, e as marcas que o app lê;
#   2. a ordem no setup (depois de `semear_chaves`, senão o envelope não abre);
#   3. SMTP da tela vira o arquivo, e o `sh` do `auth` lê de volta o valor EXATO
#      (aspas, espaço, `$`) — e a senha nunca vai para o log;
#   4. arquivo em dia não reinicia o `auth`;
#   5. porta em branco vira 587; sem nome, não inventa um;
#   6. sem SMTP na tela, a Resend da tela (cifrada com AI_CRED_AES_KEY) vira SMTP;
#   7. sem fonte nenhuma, o que já está no arquivo fica; sem nada, avisa;
#   8. consulta que FALHA não é "não tem": o grupo fica como estava;
#   9. `so_convite` fecha o cadastro direto no GoTrue;
#  10. stack antiga (auth sem o volume) cai no --env-add e manda colar a nova.
#
# Não precisa de Docker nem de Postgres: `psql` e `docker` são dublês, e o
# bloco é extraído do setup real. Precisa de `node` (o caso 6 cifra de verdade).
set -uo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
SETUP="$RAIZ/deploy/portainer/imagens/setup.sh"
MOLDE="$RAIZ/deploy/portainer/stack.yml"
DOCKERFILE="$RAIZ/deploy/portainer/imagens/setup.Dockerfile"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
US=$'\x1f'

falhas=0
casos=0

ok()    { printf '  ok     %s\n' "$1"; }
falha() { printf '  FALHA  %s\n' "$1"; falhas=$((falhas + 1)); }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else falha "$d"; fi; }
contem()     { case "$2" in *"$1"*) ok "$3" ;; *) falha "$3 — saída: $2" ;; esac; }
nao_contem() { case "$2" in *"$1"*) falha "$3 — saída: $2" ;; *) ok "$3" ;; esac; }

# ── O bloco, sozinho ────────────────────────────────────────────────────────
awk '/^# >>> gotrue/{f=1} f{print} /^# <<< gotrue/{exit}' "$SETUP" > "$TMP/bloco.sh"

cat > "$TMP/rodar.sh" <<'HARNESS'
#!/usr/bin/env bash
set -euo pipefail
STACK="${STACK:-deskcomm}"
URL="postgresql://postgres:senha-do-banco@supabase-db:5432/postgres"
# Como o psql real: sem linha, sai 0 e não imprime nada; consulta que falha sai
# != 0. Cada tabela tem o seu arquivo; "FALHA" no arquivo simula a falha.
psql() {
  local q="$*" f
  case "$q" in
    *platform_smtp_settings*) f="$CENA/smtp" ;;
    *platform_config*)        f="$CENA/resend" ;;
    *platform_settings*)      f="$CENA/cadastro" ;;
    *) return 1 ;;
  esac
  [ -f "$f" ] || return 0
  [ "$(cat "$f")" != "FALHA" ] || return 1
  cat "$f"
}
docker() {
  case "$1 $2" in
    "service inspect")
      case "$*" in
        *Mounts*) cat "$CENA/montagens" 2>/dev/null || true ;;
        *Env*)    cat "$CENA/env" 2>/dev/null || true ;;
      esac
      return 0 ;;
    "service update") printf '%s\n' "$*" >> "$CENA/chamadas"; return 0 ;;
  esac
  return 1
}
. "$BLOCO"
sincronizar_gotrue
HARNESS

SAIDA=""
RC=0
# uso: cena <nome> [arquivo=conteúdo ...]; o volume do auth fica montado.
cena() {
  local c="$TMP/$1"; shift
  mkdir -p "$c/vol"
  : > "$c/chamadas"
  printf '%s\n' "$c/vol" > "$c/montagens"
  local par
  for par in "$@"; do printf '%s' "${par#*=}" > "$c/${par%%=*}"; done
}
rodar() {
  SAIDA="$(CENA="$TMP/$1" GOTRUE_ENV="$TMP/$1/vol/gotrue.env" BLOCO="$TMP/bloco.sh" \
    AI_CRED_AES_KEY="${CHAVE_AES:-}" bash "$TMP/rodar.sh" 2>&1)"
  RC=$?
}
arquivo()   { cat "$TMP/$1/vol/gotrue.env" 2>/dev/null; }
reiniciou() { grep -q -- '--force' "$TMP/$1/chamadas"; }
quieto()    { [ ! -s "$TMP/$1/chamadas" ]; }
# O que o `sh` do auth enxerga depois de carregar o arquivo.
lido() { sh -c '. "$1"; eval "printf %s \"\${$2-<ausente>}\""' _ "$TMP/$1/vol/gotrue.env" "$2"; }

printf '\n1) o molde da stack\n'
casos=$((casos + 1))
check "não aponta para o serviço inexistente supabase-mail (só em comentário)" \
  bash -c '! grep -E "supabase-mail" "$1" | grep -qv "^[[:space:]]*#"' _ "$MOLDE"
check "não tem usuário/senha de mentira" bash -c '! grep -qE "fake_mail_(user|password)" "$1"' _ "$MOLDE"
check "o env do auth não declara GOTRUE_SMTP_* (fora de comentário)" \
  bash -c '! grep -E "GOTRUE_SMTP_" "$1" | grep -qv "^[[:space:]]*#"' _ "$MOLDE"
check "mantém a confirmação de e-mail ligada" grep -q 'GOTRUE_MAILER_AUTOCONFIRM: "false"' "$MOLDE"
check "SINGLE_SERVER=1 e INSTALACAO_VIA=portainer no x-crm-env" bash -c '
  b=$(awk "/^x-crm-env:/{f=1} /^services:/{f=0} f" "$1")
  grep -q "SINGLE_SERVER: \"1\"" <<<"$b" && grep -q "INSTALACAO_VIA: portainer" <<<"$b"' _ "$MOLDE"
check "auth e setup montam o volume gotrue-env (auth só-leitura), e ele é declarado" python3 -c '
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
assert "gotrue-env:/gotrue-env:ro" in d["services"]["auth"]["volumes"]
assert "gotrue-env:/gotrue-env" in d["services"]["setup"]["volumes"]
assert "gotrue-env" in d["volumes"]
' "$MOLDE"
check "o comando do auth carrega o arquivo e só então sobe o binário" python3 -c '
import sys, yaml
a = yaml.safe_load(open(sys.argv[1]))["services"]["auth"]
assert a["entrypoint"] == ["/bin/sh", "-c"]
c = " ".join(a["command"])
assert c.index(". /gotrue-env/gotrue.env") < c.index("exec auth"), c
assert "$" not in c, "$ no molde seria interpolado pela stack"
' "$MOLDE"
check "o setup recebe AI_CRED_AES_KEY (abre a chave da Resend)" python3 -c '
import sys, yaml
assert "AI_CRED_AES_KEY" in yaml.safe_load(open(sys.argv[1]))["services"]["setup"]["environment"]
' "$MOLDE"
check "a imagem do setup traz node" grep -qE 'apk add .*nodejs' "$DOCKERFILE"

printf '\n2) o setup chama na ordem certa\n'
casos=$((casos + 1))
check "sintaxe do setup válida" bash -n "$SETUP"
check "o bloco tem começo e fim" bash -c 'grep -q "^# >>> gotrue" "$1" && grep -q "^# <<< gotrue" "$1"' _ "$SETUP"
check "roda depois de semear_chaves (senão o envelope não abre)" bash -c '
  s=$(grep -n "^semear_chaves$" "$1" | cut -d: -f1)
  f=$(grep -n "^sincronizar_gotrue$" "$1" | cut -d: -f1)
  [ -n "$s" ] && [ -n "$f" ] && [ "$f" -gt "$s" ]' _ "$SETUP"

printf '\n3) SMTP da tela vira o arquivo, com o valor exato\n'
casos=$((casos + 1))
SENHA="se'nha \$HOME \"x\""
cena aplica "smtp=smtp.hostinger.com${US}465${US}naoresponda@exemplo.test${US}${SENHA}${US}naoresponda@exemplo.test${US}Direct Line" \
  "cadastro=aberto"
rodar aplica
check "saiu 0" test "$RC" = 0
check "reiniciou o auth com --force" reiniciou aplica
check "no serviço deskcomm_auth" grep -q 'deskcomm_auth' "$TMP/aplica/chamadas"
check "não usa mais --env-add" bash -c '! grep -q -- "--env-add" "$1"' _ "$TMP/aplica/chamadas"
check "host lido pelo sh"  test "$(lido aplica GOTRUE_SMTP_HOST)" = smtp.hostinger.com
check "porta lida pelo sh" test "$(lido aplica GOTRUE_SMTP_PORT)" = 465
check "usuário lido pelo sh" test "$(lido aplica GOTRUE_SMTP_USER)" = naoresponda@exemplo.test
check "senha com aspas, espaço e \$ volta idêntica" test "$(lido aplica GOTRUE_SMTP_PASS)" = "$SENHA"
check "remetente lido pelo sh" test "$(lido aplica GOTRUE_SMTP_ADMIN_EMAIL)" = naoresponda@exemplo.test
check "nome com espaço lido pelo sh" test "$(lido aplica GOTRUE_SMTP_SENDER_NAME)" = "Direct Line"
check "cadastro aberto → DISABLE_SIGNUP=false" test "$(lido aplica GOTRUE_DISABLE_SIGNUP)" = false
check "arquivo legível pelo auth (0644)" bash -c '[ "$(stat -f %Lp "$1" 2>/dev/null || stat -c %a "$1")" = 644 ]' _ "$TMP/aplica/vol/gotrue.env"
nao_contem "se'nha" "$SAIDA" "não imprime a senha do SMTP"
contem "atualizado" "$SAIDA" "diz o que fez"

printf '\n4) arquivo em dia não reinicia o auth\n'
casos=$((casos + 1))
: > "$TMP/aplica/chamadas"
rodar aplica
check "saiu 0" test "$RC" = 0
check "não chamou docker service update" quieto aplica
contem "já estava em dia" "$SAIDA" "diz que já estava em dia"

printf '\n5) porta em branco cai no padrão; sem nome, não inventa um\n'
casos=$((casos + 1))
cena sem-nome "smtp=smtp.exemplo.test${US}${US}login${US}segredo${US}de@exemplo.test${US}"
rodar sem-nome
check "saiu 0" test "$RC" = 0
check "porta em branco vira 587" test "$(lido sem-nome GOTRUE_SMTP_PORT)" = 587
check "sem GOTRUE_SMTP_SENDER_NAME" test "$(lido sem-nome GOTRUE_SMTP_SENDER_NAME)" = "<ausente>"

printf '\n6) sem SMTP na tela, a Resend da tela vira SMTP\n'
casos=$((casos + 1))
if command -v node >/dev/null 2>&1; then
  CHAVE_AES="$(node -e 'process.stdout.write(require("crypto").randomBytes(32).toString("base64"))')"
  ENVELOPE="$(CHAVE_AES="$CHAVE_AES" node -e '
    const c=require("crypto"), iv=c.randomBytes(12);
    const k=c.createCipheriv("aes-256-gcm",Buffer.from(process.env.CHAVE_AES,"base64"),iv);
    const ct=Buffer.concat([k.update("re_chave_da_tela"),k.final()]);
    process.stdout.write([ct,iv,k.getAuthTag()].map(b=>b.toString("hex")).join("\x1f"))')"
  cena resend "smtp=${US}587${US}${US}${US}${US}" \
    "resend=RESEND_API_KEY${US}t${US}${US}${ENVELOPE}
RESEND_FROM_EMAIL${US}f${US}envio@exemplo.test${US}${US}${US}"
  rodar resend
  check "saiu 0" test "$RC" = 0
  check "host smtp.resend.com" test "$(lido resend GOTRUE_SMTP_HOST)" = smtp.resend.com
  check "porta 465" test "$(lido resend GOTRUE_SMTP_PORT)" = 465
  check "usuário resend" test "$(lido resend GOTRUE_SMTP_USER)" = resend
  check "senha = a chave decifrada" test "$(lido resend GOTRUE_SMTP_PASS)" = re_chave_da_tela
  check "remetente da tela" test "$(lido resend GOTRUE_SMTP_ADMIN_EMAIL)" = envio@exemplo.test
  nao_contem "re_chave_da_tela" "$SAIDA" "não imprime a chave da Resend"
  # Chave errada: o envelope não abre e vale vazio, como no app.
  CHAVE_AES_CERTA="$CHAVE_AES"
  CHAVE_AES="$(node -e 'process.stdout.write(require("crypto").randomBytes(32).toString("base64"))')"
  cena resend-chave-errada "smtp=" "resend=RESEND_API_KEY${US}t${US}${US}${ENVELOPE}
RESEND_FROM_EMAIL${US}f${US}envio@exemplo.test${US}${US}${US}"
  rodar resend-chave-errada
  check "chave errada: não escreve SMTP" test "$(lido resend-chave-errada GOTRUE_SMTP_HOST)" = "<ausente>"
  contem "AVISO" "$SAIDA" "chave errada: avisa que o login fica sem e-mail"
  CHAVE_AES="$CHAVE_AES_CERTA"
else
  falha "node ausente: o caso da Resend não foi medido"
fi
CHAVE_AES=""

printf '\n7) sem fonte nenhuma: o que já está fica; sem nada, avisa\n'
casos=$((casos + 1))
cena fica "cadastro=aberto"
printf "export GOTRUE_SMTP_HOST='smtp.antigo.test'\nexport GOTRUE_DISABLE_SIGNUP='false'\n" > "$TMP/fica/vol/gotrue.env"
rodar fica
check "saiu 0" test "$RC" = 0
check "manteve o SMTP que estava no arquivo" test "$(lido fica GOTRUE_SMTP_HOST)" = smtp.antigo.test
contem "fica o que o serviço já tem" "$SAIDA" "reconhece que o login já tem e-mail"
cena vazio "cadastro=aberto"
rodar vazio
check "saiu 0 (aviso não derruba o deploy)" test "$RC" = 0
contem "AVISO: sem servidor de e-mail" "$SAIDA" "avisa e diz onde configurar"

printf '\n8) consulta que falha não vira "não tem"\n'
casos=$((casos + 1))
cena falhou "smtp=FALHA" "cadastro=FALHA"
printf "export GOTRUE_SMTP_HOST='smtp.antigo.test'\nexport GOTRUE_DISABLE_SIGNUP='true'\n" > "$TMP/falhou/vol/gotrue.env"
rodar falhou
check "saiu 0" test "$RC" = 0
check "não reiniciou o auth" quieto falhou
check "SMTP ficou como estava" test "$(lido falhou GOTRUE_SMTP_HOST)" = smtp.antigo.test
check "cadastro ficou como estava (não reabriu)" test "$(lido falhou GOTRUE_DISABLE_SIGNUP)" = true
contem "não deu para ler o e-mail" "$SAIDA" "diz que não leu o e-mail"
contem "não deu para ler o modo de cadastro" "$SAIDA" "diz que não leu o cadastro"
nao_contem "sem servidor de e-mail" "$SAIDA" "não afirma ausência que não mediu"

printf '\n9) só convite fecha o cadastro direto no GoTrue\n'
casos=$((casos + 1))
cena convite "cadastro=so_convite"
rodar convite
check "saiu 0" test "$RC" = 0
check "DISABLE_SIGNUP=true" test "$(lido convite GOTRUE_DISABLE_SIGNUP)" = true
check "reiniciou o auth" reiniciou convite

printf '\n10) stack antiga (auth sem o volume) cai no --env-add e avisa\n'
casos=$((casos + 1))
cena antiga "smtp=smtp.exemplo.test${US}465${US}u${US}s${US}de@exemplo.test${US}" "cadastro=so_convite"
: > "$TMP/antiga/montagens"
rodar antiga
check "saiu 0" test "$RC" = 0
check "não escreveu arquivo" test ! -e "$TMP/antiga/vol/gotrue.env"
check "aplicou o host por --env-add" grep -q -- '--env-add GOTRUE_SMTP_HOST=smtp.exemplo.test' "$TMP/antiga/chamadas"
check "aplicou o cadastro por --env-add" grep -q -- '--env-add GOTRUE_DISABLE_SIGNUP=true' "$TMP/antiga/chamadas"
contem "cole em Stacks" "$SAIDA" "manda colar a stack nova"

printf '\n%s caso(s), %s falha(s)\n' "$casos" "$falhas"
if [ "$falhas" -ne 0 ]; then
  echo "==> As telas não chegam ao serviço de login: cadastro por convite e 'esqueci a senha' ficam mudos."
  exit 1
fi
echo "==> Admin → E-mail e Admin → Cadastro chegam ao serviço de login pelo setup."

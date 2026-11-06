#!/usr/bin/env bash
# Backup do banco e dos arquivos anexados em /opt/deskcomm/backups (guarda 14).
# A sessão do WhatsApp fica no volume do WAHA e não entra aqui.
# Copie os backups para fora da VPS: nela, eles somem junto com o servidor.
# O stacks-*.env guarda as chaves: sem ele, dados cifrados do banco não voltam.
set -euo pipefail
DIR="${DESKCOMM_DIR:-/opt/deskcomm}"
ENVF="$DIR/stacks.env"
[ -f "$ENVF" ] || { echo "ERRO: $ENVF não existe" >&2; exit 1; }
SENHA="$(sed -n 's/^POSTGRES_PASSWORD=//p' "$ENVF" | head -1)"
ts="$(date +%Y%m%d-%H%M%S)"
B="$DIR/backups"
parcial="$B/.db-$ts.sql.gz.parcial"
trap 'rm -f "$parcial"' EXIT
docker run --rm --network deskcomm_net postgres:17-alpine \
  pg_dump "postgresql://postgres:${SENHA}@supabase-db:5432/postgres" --no-owner --no-privileges \
  | gzip > "$parcial"
[ "${PIPESTATUS[0]}" = 0 ] || { echo "ERRO: pg_dump falhou" >&2; exit 1; }
mv "$parcial" "$B/db-$ts.sql.gz"
tar -czf "$B/storage-$ts.tgz" -C "$DIR/supabase" storage
install -m 600 "$ENVF" "$B/stacks-$ts.env"
ls -1t "$B"/db-*.sql.gz | tail -n +15 | xargs -r rm -f
ls -1t "$B"/storage-*.tgz | tail -n +15 | xargs -r rm -f
ls -1t "$B"/stacks-*.env | tail -n +15 | xargs -r rm -f
echo "Backup pronto: $B/db-$ts.sql.gz, $B/storage-$ts.tgz e $B/stacks-$ts.env"

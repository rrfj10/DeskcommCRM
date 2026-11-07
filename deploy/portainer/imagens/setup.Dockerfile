# Aplica o schema da própria versão, cria o dono e atualiza os serviços do CRM.
# nodejs: abre o envelope AES-GCM da chave da Resend (abrir_envelope, setup.sh).
FROM alpine:3.22
RUN apk add --no-cache bash curl coreutils docker-cli postgresql17-client nodejs
COPY supabase/baseline.sql /schema/baseline.sql
COPY deploy/portainer/imagens/setup.sh /setup.sh
ENTRYPOINT ["bash", "/setup.sh"]

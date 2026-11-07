# Aplica o schema da própria versão, cria o dono e atualiza os serviços do CRM.
FROM alpine:3.22
RUN apk add --no-cache bash curl coreutils docker-cli postgresql17-client python3 git
COPY supabase/baseline.sql /schema/baseline.sql
COPY deploy/portainer/imagens/setup.sh /setup.sh
COPY deploy/portainer/imagens/runtime.py /runtime.py
ENTRYPOINT ["bash", "/setup.sh"]

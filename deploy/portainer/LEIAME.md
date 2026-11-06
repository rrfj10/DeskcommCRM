# Instalar pelo Portainer (Docker Swarm)

Sobe o CRM e o Supabase como duas stacks gerenciadas pelo Portainer, atrás de um
Traefik que já existe na VPS. Voz e telefonia (wacalls, asterisk, voice-agent) não
entram.

**Os nomes das stacks têm de ser exatamente `supabase` e `deskcomm`.** O
`aplicar-schema.sh` pausa os serviços por esses nomes.

## Antes de começar

- Imagens publicadas no GHCR do fork e visíveis sem login (ver "Imagens do fork").
- Portainer com Swarm ativo e Traefik lendo serviços Swarm.
- O domínio já apontando para a VPS, sem proxy da Cloudflare (nuvem cinza).
- Saber três valores do Traefik: a rede, o certresolver e o entrypoint (o padrão
  aqui é `websecure`; se for outro, passe `--entrypoint`).

## 1. Copiar os arquivos para a VPS

No seu computador, na raiz do repositório:

```bash
scp -r deploy/portainer root@SEU_DOMINIO:/root/deskcomm-portainer
```

## 2. Preparar a VPS

Na VPS, como root:

```bash
cd /root/deskcomm-portainer
bash preparar-vps.sh --domain SEU_DOMINIO \
  --traefik-network REDE_DO_TRAEFIK --certresolver SEU_CERTRESOLVER
cat /opt/deskcomm/stacks.env
```

Copie a saída do `cat`. Ela tem as chaves do sistema: não envie a ninguém. Rodar
o script de novo não troca nenhuma chave.

## 3. Criar a stack `supabase`

No Portainer: **Stacks › Add stack**.

1. Nome: `supabase`.
2. **Web editor**: cole o conteúdo de `supabase-stack.yml`.
3. **Environment variables › Advanced mode**: cole o `stacks.env`.
4. **Deploy the stack**.

Espere os 6 serviços ficarem `1/1`. O banco leva cerca de um minuto na primeira vez.

## 4. Criar o banco do CRM e o dono

Na VPS:

```bash
bash aplicar-schema.sh --owner SEU_EMAIL
cat /opt/deskcomm/owner-credentials
```

A segunda linha mostra a senha do primeiro acesso.

## 5. Criar a stack `deskcomm`

Repita o passo 3 com o nome `deskcomm`, o arquivo `deskcomm-stack.yml` e o mesmo
`stacks.env`. Espere os 6 serviços ficarem `1/1`.

## 6. Conferir

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://SEU_DOMINIO/
curl -s -o /dev/null -w '%{http_code}\n' https://SEU_DOMINIO/app
```

O esperado é `200` e `307`. Depois entre pelo navegador com o e-mail e a senha do
passo 4 e siga o onboarding.

## Backup

```bash
bash backup.sh
```

Guarda banco, arquivos anexados e chaves em `/opt/deskcomm/backups`, mantendo os 14
últimos. Copie para fora da VPS. Para rodar todo dia às 3h, acrescente no
`crontab -e` da VPS:

```cron
0 3 * * * bash /root/deskcomm-portainer/backup.sh >> /opt/deskcomm/backups/backup.log 2>&1
```

A sessão do WhatsApp fica no volume do WAHA e não entra no backup.

## Imagens do fork

O workflow `.github/workflows/imagens-3f-custom.yml` publica `deskcommcrm`,
`deskcomm-worker` e `deskcomm-scheduler` a cada push na `3f-custom`, com duas tags:
`3f-custom` (a mais recente) e `sha-abc1234` (fixa, para voltar atrás).

Na primeira publicação, confira em **GitHub › Packages** se os três pacotes estão
públicos. Se estiverem privados, abra cada um e use **Package settings › Change
visibility › Public**. Essa mudança não tem volta.

## Atualização automática

Depois da stack `deskcomm` no ar, uma vez só:

1. No Portainer, abra **Services**, entre em `deskcomm_app` e ligue **Service
   webhook**. Copie a URL. Repita em `deskcomm_worker` e `deskcomm_scheduler`.
2. Em **GitHub › Settings › Secrets and variables › Actions**, crie
   `PORTAINER_WEBHOOK_APP`, `PORTAINER_WEBHOOK_WORKER` e
   `PORTAINER_WEBHOOK_SCHEDULER` com essas URLs. Quem tem a URL atualiza o serviço:
   não a publique.
3. Em **Actions › Imagens da 3f-custom › Run workflow**, rode na `3f-custom`. Essa
   primeira execução grava a marca da implantação.

A partir daí, cada merge na `3f-custom` publica e atualiza sozinho, em alguns
minutos de build.

**Quando o schema mudar**, o que inclui quase toda sincronização com o projeto
original, as imagens saem, mas a VPS não atualiza, e o workflow avisa. Faça:

1. `bash backup.sh`
2. `bash aplicar-schema.sh --version 3f-custom`. O CRM fica fora do ar durante a
   aplicação e volta sozinho.
3. **Run workflow**, como no item 3 acima.

## Voltar uma versão

Em **Stacks › deskcomm**, troque `DESKCOMM_VERSION` para `sha-abc1234` e faça
**Update the stack**. Para retomar as atualizações, volte para `3f-custom`.

O botão de atualizar dentro do CRM não vale para esta instalação.

## Desfazer

Remova as stacks `deskcomm` e `supabase` no Portainer. Os dados ficam em
`/opt/deskcomm`. Para recomeçar do zero, apague essa pasta e a rede `deskcomm_net`.
Isso destrói banco, anexos e chaves.

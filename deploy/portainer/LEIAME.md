# Instalar pelo Portainer (Docker Swarm)

Uma stack só, colada no Portainer. Nada roda por SSH e nenhum arquivo fica na VPS.
Voz e telefonia (wacalls, asterisk, voice-agent) não entram.

## Antes de começar

- Portainer com Swarm ativo e Traefik lendo serviços Swarm.
- O domínio apontando para a VPS, sem proxy da Cloudflare (nuvem cinza).
- Imagens publicadas e públicas: o workflow `imagens-3f-custom.yml` publica seis
  pacotes no GHCR do fork. Na primeira vez, confira a visibilidade em cada um em
  **Package settings › Change visibility**. Tornar público não tem volta.

## Instalar

No seu computador, na raiz do repositório:

```bash
python3 deploy/portainer/gerar-stack.py --domain SEU_DOMINIO --owner SEU_EMAIL \
  --traefik-network REDE_DO_TRAEFIK --certresolver SEU_CERTRESOLVER
pbcopy < deploy/portainer/privado/stack.yml
```

No Portainer: **Stacks › Add stack**, nome `deskcomm` (exatamente esse), cole no
**Web editor** e clique em **Deploy the stack**.

O serviço `deskcomm_setup` aplica o schema e cria o dono, e termina como `Complete`.
Leva alguns minutos. A senha do primeiro acesso é a linha `OWNER_PASSWORD` de
`deploy/portainer/privado/chaves.env`.

**Guarde `chaves.env` fora do computador.** Sem esse arquivo, os dados cifrados do
banco não voltam num restauro. A stack colada tem as mesmas chaves: não a compartilhe.

## E-mail e cadastro do login

O produto tem **dois caminhos de e-mail**, configurados em lugares diferentes:

| E-mail | Quem manda | Onde se configura |
| --- | --- | --- |
| Convite da equipe, export de LGPD, alarme de SLA | o CRM | **Admin › E-mail** (grava no banco) |
| Confirmação de cadastro e "esqueci a senha" | o serviço de login (`auth`) | o mesmo **Admin › E-mail**, levado pelo `setup` |

O serviço de login não tem API de configuração, então o `setup` escreve um arquivo
no volume `deskcomm_gotrue-env`, e o `auth` o carrega ao subir (função
`sincronizar_gotrue`, em `imagens/setup.sh`). O arquivo leva:

- **o SMTP de Admin › E-mail**, com a senha decifrada no banco; se a tela não tem
  servidor SMTP mas tem a **Resend**, ela vai como SMTP (`smtp.resend.com:465`);
- **o modo de cadastro de Admin › Cadastro**: em "só convite", o cadastro direto
  no serviço de login fica fechado.

Consequências práticas:

- **Depois de trocar Admin › E-mail ou o modo de cadastro**, o login só passa a
  usá-los na próxima execução do `setup`: dispare o webhook (veja *Atualização
  automática*) ou, em **Services › deskcomm_setup**, clique em **Update the service**
  com *Force update*. A tela de cadastro avisa quando o login ainda está no modo antigo.
- ***Update the stack* não apaga nada:** o arquivo mora num volume, e o `auth`
  recriado o carrega de novo. (A prova roda no CI: `prova.sh` recria o `auth` por
  redeploy e confere o SMTP no processo.)
- Quem pôs `GOTRUE_SMTP_*` **direto no env do `auth`**, na stack, continua valendo
  enquanto Admin › E-mail e a Resend estiverem vazios. Com SMTP na tela, a tela manda.
- Consulta ao banco que falha não apaga nada: o `setup` mantém o que estava e o log
  traz um `AVISO`. Sem e-mail em lugar nenhum, o `AVISO` diz que o login está mudo.
- O volume é local ao nó: a stack assume um Swarm de um nó só (uma VPS).

**Instalação feita antes deste arquivo existir:** gere a stack de novo
(`gerar-stack.py`, que reaproveita as chaves) e cole em **Stacks › deskcomm ›
Editor › Update the stack**. Até lá o `setup` segue pelo caminho antigo — que vale
até o próximo *Update the stack* — e o log pede a troca.

## Atualização automática

Uma vez só:

1. No Portainer, abra **Services › deskcomm_setup**, ligue **Service webhook** e
   copie a URL. Quem tem a URL dispara o serviço: não a publique.
2. Grave no GitHub: `gh secret set PORTAINER_WEBHOOK_SETUP --repo rrfj10/DeskcommCRM`.

A partir daí, cada merge na `3f-custom` publica as imagens, prova a stack num Swarm
descartável e chama o `setup`. Ele aplica o schema, se mudou, e atualiza o CRM. Com
schema novo, o CRM fica fora do ar durante a aplicação. Se o `setup` falhar, o CRM
segue na versão anterior, e o log dele fica em **Services › deskcomm_setup**.

## Voltar uma versão

Em **Stacks › deskcomm › Editor**, troque a tag `3f-custom` por `sha-abc1234` nas
imagens e em `DESKCOMM_VERSION`, e clique em **Update the stack**. Schema não volta
junto: se a versão nova mudou o banco, restaure o backup.

## Desfazer

Remova a stack `deskcomm` no Portainer. Os volumes `deskcomm_*` guardam os dados
até serem apagados em **Volumes**, o que destrói banco e anexos.

## Ainda não coberto

Backup automático. Até existir, nada copia o banco para fora da VPS.

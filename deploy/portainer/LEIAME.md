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

## Atualização automática

Uma vez só:

1. No Portainer, abra **Services › deskcomm_setup**, ligue **Service webhook** e
   copie a URL. Quem tem a URL dispara o serviço: não a publique.
2. Grave no GitHub: `gh secret set PORTAINER_WEBHOOK_SETUP --repo rrfj10/DeskcommCRM`.

A partir daí, cada merge na `3f-custom` publica imagens com tag por SHA, prova essa
versão num Swarm descartável, promove as imagens aprovadas para `3f-custom` e chama
o `setup`. Se a prova falhar, a tag móvel permanece na versão anterior. A promoção
das seis tags é sequencial: não é uma transação entre pacotes.

O setup aplica o schema quando necessário, preserva a quantidade anterior de
réplicas ao retomar e aguarda a convergência dos serviços. Conflitos transitórios
`update out of sequence` têm até cinco tentativas; rollback, pausa ou timeout
interrompem a execução sem imprimir “Pronto.”.

Com schema novo, o CRM fica fora do ar durante a aplicação. Uma falha não desfaz
SQL já aplicado nem garante retorno à imagem anterior: o Portainer também pode
ter atualizado serviços. Confira as tarefas e os logs em **Services › deskcomm_setup**.
O rollback configurado no serviço app é diferente de rollback de banco.

## Diagnosticar erro na atualização

O setup é uma tarefa finita: `0/1` após `Complete` com código 0 é esperado. Não
altere réplicas para mantê-lo em execução. O resultado da stack não se deduz apenas
do número de réplicas ou de logs de várias execuções misturados.

No Portainer, expanda as tarefas do serviço e confira a execução mais recente,
seu código de saída e o campo Error. Confira também app, worker e scheduler. Uma
tarefa antiga Failed pode continuar no histórico mesmo com uma substituta Running.
Os logs da aplicação são diferentes dos logs da tarefa de setup.

Há um [bug reportado no Portainer 2.45](https://github.com/portainer/portainer/issues/13281)
no qual uma tarefa histórica marca a atualização da stack como erro e o editor pode
voltar ao arquivo anterior embora o Swarm tenha aplicado a atualização. A versão
2.45.3 LTS observada no incidente requer essa checagem. O rótulo de uma release na
issue não prova que a correção já foi publicada: confira as notas oficiais antes
de planejar atualização do Portainer.

Se a mensagem for `update out of sequence`, não dispare outra atualização enquanto
setup ou serviços estiverem mudando. A repetição limitada do setup não serializa
uma operação externa do Portainer. Antes de repetir, compare a imagem/digest e as
configurações efetivas com o editor salvo. Não remova a stack nem os volumes para
limpar um alerta. Um “Pronto.” do setup não substitui testar o acesso ao CRM.

## Voltar uma versão

Em **Stacks › deskcomm › Editor**, troque a tag `3f-custom` por `sha-abc1234` nas
imagens e em `DESKCOMM_VERSION`, e clique em **Update the stack**. Schema não volta
junto: se a versão nova mudou o banco, restaure o backup.

## Desfazer

Remova a stack `deskcomm` no Portainer. Os volumes `deskcomm_*` guardam os dados
até serem apagados em **Volumes**, o que destrói banco e anexos.

## Ainda não coberto

Backup automático. Até existir, nada copia o banco para fora da VPS.

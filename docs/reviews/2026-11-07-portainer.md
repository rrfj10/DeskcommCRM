---
title: Revisão de deploy e setup do Portainer
date: 2026-11-07
status: in-progress
baseline: 04deebba36932a5dc100c2b4276c6465ce16d7e6
destino: infraestrutura
---

# Revisão de deploy e setup do Portainer

Escopo confirmado pelo usuário: deploy/setup no Portainer, motivado por `update out of sequence`, stack em erro, serviços em execução e setup 0/1. Não há story ou sprint vinculada; não foram inventados critérios de aceite nem tarefas previamente concluídas. A intenção foi confrontada com o contrato de operação de `deploy/portainer/LEIAME.md`, a doutrina de packaging e o código efetivamente distribuído na `3f-custom`.

As pastas de planejamento configuradas não continham arquitetura, UX ou épico para essa entrega. Contexto carregado do repositório: `CLAUDE.md`, `ARCHITECTURE.md`, doutrina de packaging e Sistema Vivo. A revisão excluiu `_dl/`, `_dl-output/`, configurações de IDE e arquivos privados. As alterações anteriores em `package.json` e `.claude/settings.json` na pasta original não pertencem a esta revisão e foram preservadas.

## Achados e correções

Referências abaixo usam as linhas da base acima, disponíveis por `git show <baseline>:<arquivo>`.

1. **Alta — tag de produção publicada antes da prova.** `.github/workflows/imagens-3f-custom.yml:68` publicava a tag móvel durante cada build da matriz; `provar` só rodava depois. Um build parcial ou prova vermelha já deixava imagens não aprovadas disponíveis ao re-pull da VPS. Corrigido com a cadeia publicar por SHA → provar esse SHA → promover → implantar. A promoção não reconstrói imagens. Ela continua sequencial entre pacotes, sem garantia de atomicidade das seis tags.
2. **Alta — conclusão antes da convergência.** `deploy/portainer/imagens/setup.sh:139` usava `--detach` e imprimia “Pronto.” na linha 141. A aceitação da atualização não prova que o serviço subiu; rollback posterior e pausa não alteravam o exit code do setup. Corrigido com espera limitada por réplicas e estado de atualização, rejeição de pausa/rollback e interrupção antes de atualizar o serviço seguinte. Serviço obrigatório ausente agora reprova em vez de ser ignorado.
3. **Média — disputa de versão derrubava o setup sem tentativa de recuperação.** O mesmo comando da linha 139 podia receber `update out of sequence` enquanto o Portainer também alterava o serviço. Corrigido com até cinco tentativas, exclusivamente para esse conflito, também nas operações de scale. Permissão negada e outros erros continuam falhando imediatamente. É uma mitigação de conflitos transitórios no setup; não é uma trava distribuída contra o Portainer.
4. **Alta — retomada podia falhar silenciosamente e mudar a escala.** `setup.sh:24` retomava sempre uma réplica, descartava falha com aviso e apagava a lista de pendências. A pausa não aguardava a parada antes de aplicar SQL. Corrigido para salvar/restaurar a escala original, aguardar zero réplicas antes do schema, preservar pendências e retornar erro quando não consegue restaurar. O trap de saída também sinaliza falha. A documentação não promete mais retorno à versão anterior de banco/imagem, porque não há transação ou rollback coordenado.

## Diagnóstico externo ainda não confirmado na VPS

O [Portainer #13281](https://github.com/portainer/portainer/issues/13281) descreve erro de implantação causado por tarefa histórica no Swarm e possível divergência entre editor e estado aplicado. A captura do usuário mostra Portainer CE 2.45.3 LTS; o sintoma é compatível. Isso é hipótese sustentada pelo upstream, não identificação da tarefa na VPS: ainda faltam estado, horário e erro da tarefa responsável. `0/1` do setup depois de Complete não prova defeito. Os logs fornecidos terminam em “Pronto.” e não permitem atribuir a falha da stack a essas execuções.

Fontes técnicas: [semântica de --detach](https://docs.docker.com/reference/cli/docker/service/update/), [inspeção de serviços](https://docs.docker.com/reference/cli/docker/service/inspect/), [promoção de manifestos](https://docs.docker.com/reference/cli/docker/buildx/imagetools/create/).

## Arquivos revisados

- `deploy/portainer/stack.yml`: serviços, volumes, políticas de reinício, réplicas e update.
- `deploy/portainer/imagens/setup.sh`: schema, credenciais, retomada e atualização.
- `deploy/portainer/imagens/setup.Dockerfile`, `db.Dockerfile`, `gw.Dockerfile`: conteúdo distribuído.
- `deploy/portainer/gerar-stack.py`: geração e preservação das chaves; sem abrir arquivos privados.
- `deploy/portainer/prova.sh`: cobertura do Swarm descartável e limites da prova por API.
- `deploy/portainer/LEIAME.md`: contrato de operação e recuperação.
- `.github/workflows/imagens-3f-custom.yml`: publicação, prova, promoção e webhook.
- `tests/unit/gatilho-dos-jobs-de-entrega.test.ts`, `tests/unit/workflows-tem-permissions.test.ts`: gates existentes de CI.

## File List das correções

- `.github/workflows/imagens-3f-custom.yml`
- `deploy/portainer/imagens/setup.sh`
- `deploy/portainer/LEIAME.md`
- `tests/unit/gatilho-dos-jobs-de-entrega.test.ts`
- `tests/unit/portainer-setup-operacao.test.ts`
- `tests/unit/portainer-promocao-de-imagens.test.ts`
- `.changes/portainer-convergencia-e-promocao.md`
- `docs/reviews/2026-11-07-portainer.md`

## Living System Checklist

1. Entrada: Portainer e job implantar do workflow.
2. Saída: serviços app, worker, scheduler; funções SQL e serviços restaurados.
3. Registro: stdout/stderr do setup com erro explícito e resultado do job do GitHub.
4. Superfície: tarefas/logs do serviço no Portainer e execução do GitHub Actions.
5. Porta: stack deskcomm e serviço deskcomm_setup existentes; nenhuma tela nova.
6. Anti-morte: até cinco tentativas de conflito, espera limitada, trap de retomada e erro visível.
7. Configuração: stack e parâmetros já existentes; nenhuma chave nova obrigatória.
8. Continuidade IA/humano: sem mudança no atendimento; a entrega mantém os serviços que processam ambos.
9. Retorno: conflito transitório repete; rollback/pausa/timeout interrompem e impedem “Pronto.”; prova vermelha impede promoção.
10. Mapa: nenhuma peça de runtime nova; a cadeia do workflow é descrita neste relatório e no LEIAME. Nenhum nó novo de produto exige atualização do mapa.

## Validação e pendências

Os testes determinísticos exercitam funções reais do setup com Docker dublado: disputa transitória/exaurida, erro permanente, convergência, rollback, timeout, pausa, preservação de escala e propagação da falha de retomada. Há teste do fluxo principal que impede aplicação do schema sem pausa. As guardas do workflow cobrem a ordem de promoção e a lista das imagens.

- Testes direcionados: 4 arquivos, 51 casos aprovados (setup, promoção, gatilhos de CI e permissões).
- ESLint dos três arquivos de teste alterados: aprovado.
- `bash -n deploy/portainer/imagens/setup.sh` e `git diff --check`: aprovados.
- `pnpm release:conferir`: fragmento válido, sem escrever release.
- `pnpm test:shell`: executado, exit 1. O log aponta falhas de escaping de apóstrofo e cenários inconclusivos de update/proxy no kit HostGator, fora dos arquivos alterados. Não foram classificados como regressão desta entrega nem corrigidos por suposição.
- Typecheck global, suíte unitária completa, publicação das imagens e teste na VPS não foram repetidos nesta revisão.

Controle negativo depois do commit: retirados temporariamente o guarda de rollback/pausa e a dependência `promover → provar`, exatamente cinco casos falharam (quatro estados de rollout e um de ordenação do workflow), conforme previsto. Os dois arquivos foram restaurados do commit e os 51 casos foram repetidos com sucesso. A prova real de Swarm/Portainer e a atualização de uma VPS existente ainda não foram executadas para estas correções. O Docker Desktop permanece desligado conforme pedido anterior do usuário. A entrega não deve ser considerada validada para produção apenas pelos testes dublados.

## Review Follow-ups (AI)

- [ ] [AI-Review][Low] Confirmar a tarefa e a configuração efetiva da VPS antes de atribuir o alerta ao bug upstream; registrar digest, estado e Error sem dados secretos. [deploy/portainer/LEIAME.md]
- [ ] [AI-Review][Low] Acompanhar correção upstream do Portainer #13281 e validar a versão de destino antes de uma atualização do painel. [deploy/portainer/LEIAME.md]

## Change Log

- 2026-11-07: revisão solicitada pelo usuário; quatro problemas corrigidos localmente e diagnóstico upstream documentado. Estado in-progress até prova real da entrega em Swarm/Portainer.

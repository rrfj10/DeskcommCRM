# Confirmação de versão no Portainer

Destino: infraestrutura, atendendo a instalação no Swarm de nó único do fork.
Não altera o schema ou a regra do rodapé. Contrato reutilizado:
`runtimeConfirmationSchema` → `POST /api/v1/system/agent` → `system_version` →
`GET /api/v1/system/version` → `VersionFooter`.

O build identifica uma tag oficial ancestral e grava APP_VERSION semântica e
labels OCI com source/revision/version. `identidade-build.sh` usa refs isoladas
obtidas do upstream; não supõe que a versão do package.json descreva a release.
O observador verifica novamente a ancestralidade entre a tag oficial e a revisão
real da imagem do fork. Só os metadados da imagem imutável entram na observação,
e uma segunda seleção de containers detecta substituições durante a coleta.

O setup é finito. O observador é um serviço separado, reiniciado pelo Swarm e
instalado automaticamente pelo setup novo em stacks antigas. Não recebe chaves
no arquivo de stack: lê a credencial canônica da configuração do app pelo daemon.
O app não recebe acesso ao Docker. Uma observação incompleta nunca apaga o aviso;
sem heartbeat o contrato existente expira a confirmação em quinze minutos.

## Aceite e cobertura

- [x] Rodapé recebe a versão base e distingue o fork personalizado por revisão.
- [x] Não confirma sem os três serviços, saúde, origem e revisões coerentes.
- [x] Detecta mudança durante a coleta e expira sem heartbeat.
- [x] Usa autenticação existente, não publica credencial no payload e não executa
  a resposta do endpoint como comando.
- [x] Instala/atualiza observador em stack legada sem novas chaves obrigatórias.
- [x] CI contém prova da observação real gravada, antes de promover a tag.
- [ ] Executar a candidata no Swarm descartável do CI e conferir o rodapé numa
  instalação real. Código da prova não equivale a prova executada.

Testes determinísticos: `tests/unit/portainer-runtime.test.ts`,
`tests/unit/portainer-identidade-build.test.ts` e
`tests/unit/portainer-setup-operacao.test.ts`. A primeira suíte passa as observações
do coletor Python real para o validador/derivador TypeScript real do produto.
As fixtures dublam Docker e Git; testes separados verificam ancestralidade e
transporte HTTP. Não se mede uma VPS de produção por essas fixtures.

## Living System Checklist

1. Entrada: daemon do Swarm, containers/imagens, tags oficiais e histórico do fork.
2. Saída: heartbeat autenticado para a rota existente do agente.
3. Registro: logs do observador e `system_version.agent_last_seen_at`.
4. Tela: rodapé `VersionFooter` e painel de atualização existentes.
5. Porta: sidebar e Configurações; serviço visível em Services no Portainer.
6. Anti-morte: restart do Swarm, healthcheck, ciclo de cinco minutos, expiração
   de quinze minutos sem observação; captura incompleta não autoriza sucesso.
7. Configuração: STACK/IMAGE_OWNER já existentes no setup e no molde; sem nova
   credencial ou edição manual dos arquivos privados.
8. Continuidade: nenhuma decisão de atendimento IA/humano alterada; a observação
   cobre o app e os serviços que processam as duas formas de atendimento.
9. Retorno: dados divergentes/parciais mantêm o aviso; nova observação reavalia
   todos os dados e a origem; nenhuma ação do host é decidida pelo app.
10. Mapa: nós e arestas adicionados ao mapa de atualização self-service.

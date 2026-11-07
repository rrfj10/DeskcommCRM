---
impacto: nada_mudou
secao: corrigido
titulo: Atualização no Portainer verifica a retomada dos serviços
---

O preparo da atualização passa a tolerar conflitos transitórios do Docker,
preservar a quantidade de réplicas e informar falha quando os serviços não
convergem. A mensagem de conclusão só aparece após essa conferência. No pipeline
do fork, a tag consumida pela instalação passa a apontar para imagens novas apenas
depois de a versão passar na prova da stack. Não é necessário trocar chaves.

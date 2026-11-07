---
impacto: capacidade_nova
secao: corrigido
titulo: Instalação pelo Portainer confirma a versão no rodapé
---

A stack do Portainer passa a observar periodicamente os serviços em execução e
confirmar a versão base e a revisão personalizada no rodapé. Serviços parados,
sem saúde confirmada ou com versões divergentes mantêm o aviso. O setup atualizado
instala o observador nas stacks existentes, sem exigir troca de chaves.

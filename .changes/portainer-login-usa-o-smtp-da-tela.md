---
impacto: exige_acao
secao: corrigido
titulo: Instalação pelo Portainer volta a mandar a confirmação de cadastro e o "esqueci a senha"
---

Na instalação feita pela stack do Portainer, o serviço de login nascia apontado
para um servidor de e-mail que não existe na stack (`supabase-mail`, com usuário
e senha de mentira). O resultado era o pior tipo de defeito: a tela
**Admin › E-mail** dizia "Em uso" — ela configura o servidor do CRM — e o
convite da equipe saía, mas quem era convidado via "o envio de e-mails desta
instalação não está configurado" ao criar a conta, e o "esqueci a senha" nunca
chegava.

Agora o `setup` leva ao serviço de login, a cada execução, o SMTP de
**Admin › E-mail** (ou a Resend da mesma tela, que também fala SMTP) e o modo de
**Admin › Cadastro** — em "só convite", o cadastro direto passa a ficar fechado
também no login. A configuração mora num arquivo num volume que o serviço de
login carrega ao subir, então *Update the stack* não a apaga.

Trocar o e-mail ou o modo de cadastro nas telas passa a valer para o login na
próxima execução do `setup` (webhook da atualização, ou *Force update* no serviço
`deskcomm_setup`), não na hora. A tela de cadastro, no Portainer, ensina esse
caminho em vez do `update.sh` do kit.

## Requer atenção

Quem instalou pela stack do Portainer: gere a stack de novo com `gerar-stack.py`
(as chaves são reaproveitadas) e cole em Stacks › deskcomm › Editor, com
**Update the stack**, uma vez. Sem isso o `setup` segue pelo caminho antigo, que se perde
no próximo *Update the stack*, e o log dele pede a troca.

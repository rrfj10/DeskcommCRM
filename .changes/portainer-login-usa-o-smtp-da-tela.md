---
impacto: nada_mudou
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

Agora o `setup` copia o SMTP de **Admin › E-mail** para o serviço de login a
cada execução, decifrando a senha no banco, e o molde da stack deixou de trazer
os valores falsos. Quem já tem o SMTP preenchido naquela tela não precisa fazer
nada além da atualização de sempre: o próximo `setup` leva a configuração e o
login volta a enviar. Quem só usa o serviço externo de envio precisa preencher
também o servidor SMTP na mesma tela — é ele que o login usa.

Duas coisas para saber: trocar o SMTP de **Admin › E-mail** passa a valer para o
login na próxima execução do `setup` (webhook da atualização ou *Update the
stack*), não na hora; e quem configurou o SMTP direto no env do serviço de login
continua mandando, porque sem SMTP na tela o `setup` não mexe em nada.

A instalação por Docker Compose com o kit já se comportava assim — o que faltava
era a peça equivalente no caminho do Portainer.

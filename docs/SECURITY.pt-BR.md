# Segurança e limites

[English](SECURITY.md) · [Instalação](INSTALL.pt-BR.md)

Este software está em desenvolvimento. Comece com uma sessão aninhada do River,
executada pelo seu usuário normal. O gerenciador não usa setuid, serviço root,
servidor de rede, telemetria, atualização automática ou configuração remota.

O protocolo do River permite ao gerenciador posicionar, focar e fechar janelas,
além de registrar atalhos. Proteja o executável e sua configuração como outros
programas iniciados no login. Uma configuração Haskell é código executável;
o formato textual recarregável também contém comandos confiáveis e não oferece
isolamento.

Comandos de aplicativos usam um executável e uma lista de argumentos, sem shell
implícito. Títulos e identificadores das janelas não são interpretados como
comandos. Os processos filhos são recolhidos ao terminar. O lançador passa ao
River uma expressão fixa, sem montar comandos a partir de metadados de clientes.

A conexão Wayland usa libwayland-client e as definições geradas dos protocolos.
A camada C verifica interfaces necessárias, fases de gerenciamento/renderização
e duração dos objetos. O compositor é um componente confiável da sessão; este
gerenciador não isola o usuário de um compositor malicioso.

O bloqueio de tela depende do River e de um programa de bloqueio separado.
O gerenciador suspende suas ações quando recebe o estado de sessão bloqueada,
mas não implementa o bloqueio nem valida a combinação compositor/bloqueador.
Parar o gerenciador não é bloquear a tela. O encerramento confirmado exige
uma resposta explícita bem-sucedida e protocolo versão 4.

Aplicativos X11 usam o XWayland e seus limites de segurança. Este pacote não
promete isolamento entre clientes X11. A versão 0.2.0-dev não tem certificação
de produção nem auditoria de segurança externa.

Instalar o pacote não altera a configuração existente do XMonad, `river/init`,
permissões de dispositivos, kernel, firewall ou seleção do gerenciador de login.

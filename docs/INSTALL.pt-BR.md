# Instalar e executar no GNU Guix

[English](INSTALL.md) · [Visão geral do projeto](../README.pt-BR.md)

A versão **0.3.0** é destinada a desenvolvimento e testes. Comece dentro de
um desktop Wayland existente. No notebook do mantenedor, uma sessão física
de login com o River está em uso desde setembro de 2026; os passos abaixo
documentam a forma portátil e aninhada de experimentar o gerenciador em
qualquer lugar.

## Compilar o perfil local

Você precisa de uma instalação funcional do Guix com acesso ao daemon de
compilação, deste código-fonte e de internet para obter dependências ainda não
armazenadas. Execute no diretório do projeto, com seu usuário normal:

```sh
./scripts/guix-build
./run.sh --doctor
```

O script autentica a revisão do Guix definida em `packaging/guix/channels.scm`,
compila o River 0.4.8 fixado e o gerenciador a partir do código local atual, e
executa os testes dos pacotes. Ele cria:

| Caminho | Conteúdo |
| --- | --- |
| `build/guix-river` | Saída do River, protegida da coleta de lixo |
| `build/guix-manager` | Saída do gerenciador, protegida da coleta de lixo |
| `build/guix-runtime` | Perfil separado com ambos, Foot, Fuzzel e fontes |

Seu perfil Guix padrão, canais e sessão de login permanecem inalterados.
`--doctor` verifica executáveis, versões e o diretório de execução da sessão;
não inicia o River nem comprova suporte gráfico. O script informa onde está o
registro da compilação em `evidence/`. Esses registros são gerados localmente;
a distribuição do código-fonte não depende de cópias deles.

Para limitar a compilação ou omitir o perfil conjunto de aplicativos:

```sh
GUIX_BUILD_CORES=2 ./scripts/guix-build
./scripts/guix-build --build-only
```

Com `--build-only`, você precisa fornecer seu terminal e lançador separadamente.
Após editar o código, execute novamente o comando completo para recompilar o
perfil. A revisão fixada é usada sem executar `guix pull` no seu perfil.

## Abrir uma sessão aninhada

Dentro do seu desktop Wayland atual:

```sh
./run.sh --nested
```

O River abre em uma janela separada, com um terminal Foot. O lançador escolhe
o backend Wayland e um diretório de execução privado. Clique na janela e use
**Super+Return** para outro terminal ou **Super+p** para o Fuzzel.

No Sway, um modo temporário encaminha os atalhos somente enquanto essa janela
River tem foco. **Ctrl+Alt+Escape** devolve o controle ao Sway. Para capturar de
novo, foque outra janela e volte ao River. Os atalhos e arquivos existentes do
Sway são preservados. Outros compositores podem continuar interceptando Super.

O pacote Guix inclui Python 3 para supervisionar os processos aninhados. Para
escolher outro terminal inicial, defina `XMONAD_WAYLAND_TERMINAL` com o caminho
de um executável. O valor é literal, sem argumentos ou sintaxe de shell. Essa
escolha é independente do atalho Haskell `terminalCommand`.

O lançador informa o diretório de diagnóstico em `$XDG_STATE_HOME/xmonad-wayland`
(padrão `~/.local/state/xmonad-wayland`). Cada sessão tem um diretório privado e
registros separados para River, gerenciador, terminal e auxiliar do Sway. O rastreio
do protocolo Wayland é desativado nessa sessão; os registros não gravam teclas.

Ao terminar, feche a janela do River pelo desktop externo. O atalho genérico
Super+Shift+q para apenas o gerenciador, mantendo o River e os aplicativos em
execução; ele não encerra nem bloqueia a sessão.

O lançador específico da máquina, chamado `xmonad-wayland-river`, é separado
deste fluxo genérico com `run.sh`/`xmonad-wayland-session`. Seus 74 atalhos
personalizados derivados do Sway, Kitty automático e regras de entrada pelo
Channel pertencem à instalação local. O pacote genérico oferece seu próprio
terminal inicial, registros privados e encaminhamento no Sway, com atalhos padrão.

## Sessão física e NVIDIA

Em outro console de texto, com permissões de acesso aos dispositivos e um
`XDG_RUNTIME_DIR` válido, `./run.sh` pode iniciar o River diretamente. Configure
o acesso à sessão e a pilha gráfica pela configuração do sistema Guix. O
lançador recusa root; executá-lo com sudo não faz parte da instalação.

O pacote genérico não configura um gerenciador de login nem escolhe uma sessão
padrão. Ele não fornece regras de dispositivos de entrada, bloqueio automático,
notificações, gerenciamento da área de transferência, portais ou um serviço de
desktop completo. Configure e teste esses componentes antes de substituir sua
sessão atual.

Sistemas Guix com driver NVIDIA proprietário precisam de um pacote River com a
mesma transformação de Mesa para NVIDIA usada no restante da pilha gráfica.
Selecionar apenas um arquivo JSON do fornecedor EGL não substitui as bibliotecas
Mesa vinculadas. Uma configuração de máquina separada passou em testes aninhados
com aceleração usando essa transformação; o perfil genérico de software livre
não a aplica. Saída DRM direta, entrada física, conexão de monitores e
suspensão/retomada ainda precisam ser validadas.

## Configurar e diagnosticar

Os padrões genéricos são Foot, Fuzzel e nove áreas de trabalho, listados no
[README](../README.pt-BR.md#atalhos-padrão). Um ponto de entrada Haskell
personalizado pode alterá-los e adicionar atalhos recarregáveis. Consulte a
[configuração](CONFIGURATION.pt-BR.md) para conhecer a API; um `xmonad.hs`
existente para X11 não pode ser usado sem adaptação.

| Sintoma | O que verificar |
| --- | --- |
| `guix` ausente ou daemon inacessível | Confirme que a instalação do Guix consegue compilar pacotes antes de executar o script do projeto. |
| River ausente ou incompatível | Execute o script completo. River 0.3 e river-classic não oferecem o protocolo necessário. |
| `XDG_RUNTIME_DIR` inválido | Use uma sessão de login normal, com seu próprio diretório de execução gravável. |
| Janela aninhada vazia | Confira terminal.log no diretório de diagnóstico informado, o terminal inicial configurado e o encaminhamento pelo Sway. |
| Renderização falha antes de abrir uma janela | Leia a saída no terminal e confira a pilha gráfica do Guix, especialmente a ligação com Mesa/NVIDIA. |
| Terminal ou lançador indisponível | Compile o perfil completo ou configure comandos instalados; `--build-only` omite esses aplicativos. |

Falhas de compilação ficam no registro informado pelo `guix-build`; mensagens do
renderizador e do gerenciador ficam no diretório privado informado pelo lançador.
Mais detalhes estão em [empacotamento Guix](../packaging/guix/README.md),
[limites de segurança](SECURITY.pt-BR.md) e [origem do código](PROVENANCE.md), em inglês.

# Configuração em Haskell e atalhos recarregáveis

[English](CONFIGURATION.md) · [Instalação no Guix](INSTALL.pt-BR.md)

O executável genérico usa os padrões do README. Para definir seus próprios
comandos, áreas de trabalho, atalhos, layout e cursor, copie `examples/Main.hs`
e compile com `make MAIN=/caminho/absoluto/Main.hs`. A API é própria deste
projeto; arquivos do XMonad para X11 e módulos do `xmonad-contrib` precisam de
adaptação.

`XMonad.Wayland.Keymap` oferece `key`, `modeKey`, `keySym`, constantes de
modificadores e teclas especiais. Exemplo de ações inspiradas no Sway:

```haskell
key (keySym 'l') super CycleSwayLayout
key (keySym 't') super FocusModeToggle
key (keySym 'r') (super + shift) (EnterMode ResizeMode)
modeKey ResizeMode keyLeft 0 (Resize Width (-10))
modeKey ResizeMode keyEscape 0 (EnterMode NormalMode)
```

Os modos normal e de redimensionamento têm atalhos separados. A validação
rejeita combinações duplicadas no mesmo modo, modificadores desconhecidos e
referências a áreas de trabalho inexistentes. Alterar a lista de áreas de
trabalho exige reiniciar o gerenciador; uma recarga que tente fazer isso mantém
a configuração anterior.

## Recarregar sem fechar janelas

`runWithReload initialConfig loader` recebe uma função que lê a configuração.
`readConfig path` lê a representação textual `Read`/`Show` de `Config`;
`show config` produz esse formato. Ele depende da versão: guarde uma cópia antes
de atualizar o programa.

A ação `Reload` substitui comandos, atalhos e cursor, preservando as janelas,
o foco, as posições flutuantes, as áreas de trabalho e o estado dos layouts.
Arquivos inválidos mantêm a configuração anterior e geram um erro no registro
do gerenciador. `run config` usa uma função constante; nesse caso, recarregar
simplesmente reaplica o mesmo valor compilado.

## Comandos e encerramento

Use `Command executavel [argumento, ...]`. Os argumentos são literais: pipes,
`$()` e expansão de `~` exigem um shell explícito, como
`Command "sh" ["-c", "..."]`. A configuração é código de confiança e pode
executar programas com os privilégios do usuário. Títulos e identificadores
de aplicativos nunca viram comandos.

`ConfirmExit (Command "fuzzel" ["--dmenu"])` apresenta `Cancel` e `Exit`.
Somente a resposta exata `Exit`, seguida por uma quebra de linha e uma saída
bem-sucedida do comando, pede ao River que encerre a sessão. Cancelamento,
resposta vazia e falhas não encerram nada. É necessário protocolo de
gerenciamento versão 4. A ação separada `Stop` para somente o gerenciador;
ela não encerra nem bloqueia a sessão.

## Layouts inspirados no Sway

`Columns` e `Rows` distribuem as janelas lado a lado ou verticalmente.
`Tabbed` e `Stacking` mostram a janela selecionada, mas ainda não desenham
cabeçalhos de abas. `CycleSwayLayout` alterna entre divisão, abas e pilha;
`ToggleSplit` muda a orientação da divisão.

Foco direcional considera a geometria das janelas. Movimento direcional troca
janelas lado a lado ou transfere uma janela e seus diálogos para outro monitor.
Movimento e redimensionamento flutuantes usam pixels. Essas ações se aplicam à
área de trabalho inteira; não reproduzem a árvore de contêineres do Sway.

Em uma janela flutuante, segure Super e arraste com o botão esquerdo para mover,
ou com o direito para redimensionar pelo canto mais próximo. Pedidos de movimento
e redimensionamento feitos pelo próprio aplicativo também são atendidos. Solte
o botão do mouse para terminar, mesmo que já tenha soltado Super.

O arrasto fica na área útil do monitor inicial e exige uma janela já flutuante,
inteiramente dentro dessa área. Ele não transforma janelas lado a lado em
flutuantes nem as transfere entre monitores. Tela cheia, fechamento da janela,
remoção do monitor, conflitos de foco e bloqueio da sessão cancelam a operação.

## Serviços da sessão

Quando o River anuncia `river_layer_shell_v1`, o gerenciador habilita superfícies
como o Fuzzel, respeita áreas reservadas por painéis e trata o foco de teclado
dessas superfícies. Janelas em tela cheia usam a área física do monitor.

Notificações, papel de parede, configuração de entrada, bloqueio e portais
dependem de outros programas e da configuração da sessão. O pacote não inicia
um desktop completo. Consulte os [limites de segurança](SECURITY.pt-BR.md)
antes de substituir sua sessão atual.

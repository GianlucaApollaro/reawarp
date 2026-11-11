# reawarp: Warp, Mapa de tempo, Groove Match e Quantize para o REAPER

*[Read in English](README.md) · [Leer en español](README.es.md)*

> Contribuições, relatos de problemas e sugestões são muito bem-vindos; veja
> [Como contribuir](#como-contribuir).
>
> Contato: gabrielschuck.tecladista@gmail.com

Warp de áudio para o REAPER, no estilo do Warp do Ableton Live: o reawarp detecta as
batidas de uma música (inclusive com tempo variável) e

- **Warp**: encaixa o item no tempo do projeto (stretch markers em cada batida),
- **Mapa de tempo**: faz o projeto seguir a música (marcadores de tempo em cada batida), ou
- **Groove Match** (*Combinar groove*): faz outros itens (um loop, outra gravação) seguirem
  as batidas de um item de referência, sem mexer no tempo do projeto, ou
- **Quantizar**: leva os ataques do áudio para as notas de um item MIDI, que dá o ritmo
  (reto, swing, um shuffle como a tarantela).

As batidas erradas podem ser corrigidas pelo teclado: vá ao marcador de batida seguinte ou
anterior (o OSARA fala compasso, tempo e BPM; sem o OSARA, eles aparecem numa nota perto
do mouse) e mova, adicione ou remova um marcador; o warp, o mapa de tempo ou o groove match
é aplicado de novo sozinho.

Vários itens podem ser processados juntos, por exemplo uma música e um loop num remix, ou
as faixas de uma gravação multipista; veja [Vários itens de uma vez](#vários-itens-de-uma-vez).

Escrito em Lua; as batidas são detectadas pelo detector com rede neural
[Beat This!](https://github.com/CPJKU/beat_this), instalado com um clique (não é preciso
ter Python instalado). Toda a interface usa menus e diálogos nativos do REAPER (compatível com leitores de
tela / OSARA). Sem o OSARA, tudo também é visual: os resultados aparecem numa janela, uma
ação em andamento mostra o progresso numa dica (tooltip) perto do mouse, e a navegação
entre marcadores de batida mostra o marcador numa nota perto do mouse que some sozinha. As
mensagens aparecem em português, inglês ou espanhol conforme a configuração *Idioma*.

## Instalação

**Pelo ReaPack** (recomendado: as atualizações chegam sozinhas):

1. No REAPER: *Extensions > ReaPack > Import repositories...* e cole
   `https://github.com/gabrielschuck/reawarp/raw/main/index.xml`
2. *Extensions > ReaPack > Browse packages*, procure **reawarp** e instale.
   Todas as ações aparecem no Action List.

**Manualmente** (sem o ReaPack):

1. Baixe o ZIP da versão mais recente em
   [Releases](https://github.com/gabrielschuck/reawarp/releases) e extraia a pasta
   `reawarp` dentro da pasta `Scripts` do REAPER (*Options > Show REAPER resource path*).
2. No REAPER: *Actions > Show action list > New action > Load ReaScript...* e carregue
   `reawarp.lua`.
3. Rode a ação `reawarp.lua` uma vez. Ela abre o menu e registra as ações individuais no
   Action List (depois disso, pode cancelar o menu).

Depois, instale o detector Beat This! pelo menu do reawarp (veja abaixo). Opcional: atribua
atalhos às ações.

Todo o código está em `reawarp.lua`. Como o REAPER associa cada ação a um arquivo, as
ações individuais são arquivos de duas linhas na subpasta `actions/`, que só chamam a
função correspondente de `reawarp.lua`. Não é preciso editá-los, e eles são recriados se
forem apagados. Os nomes das ações são em inglês.

Para passar de uma instalação manual para o ReaPack: o ReaPack instala em
`Scripts/reawarp/Tempo/`. Para manter o Beat This! já instalado, mova as pastas `env`,
`models`, `python` e `uv` da pasta `backend` antiga para a nova; depois apague o
`Scripts/reawarp/reawarp.lua` e a pasta `actions` antigos (e remova as entradas deles do
Action List). Mover as pastas quebra os vínculos do ambiente Python; por isso, depois rode
uma vez *Instalar o detector Beat This!...* no menu do reawarp: ele repara o ambiente em
poucos segundos e reaproveita o que já foi baixado.

O REAPER continua respondendo enquanto uma ação trabalha: o Beat This! roda em segundo
plano e a análise devolve a janela ao REAPER muitas vezes por segundo, então dá para
continuar navegando pelo projeto (não edite o item que está sendo analisado). O resultado
é anunciado pelo OSARA; sem o OSARA, ele aparece numa janela (a navegação entre marcadores
de batida mostra o marcador numa nota perto do mouse, já que uma janela a cada tecla
atrapalharia). Diálogos só aparecem quando
o reawarp precisa de uma resposta (fórmula de compasso, remover um mapa de tempo, um novo
BPM) e nas configurações. Rodar a mesma ação de novo enquanto ela trabalha a cancela
(Desfazer reverte o que ela já tinha mudado); iniciar outra
ação do reawarp nesse meio-tempo só avisa que ele ainda está trabalhando. Quando uma ação
começa, o OSARA avisa que o reawarp está processando; o relatório da análise continua
numa janela, porque explica o que conferir em seguida.

| Ação no Action List | O que faz |
|---|---|
| `reawarp.lua` | Menu com todas as funções |
| `reawarp - Analyze beats.lua` | Analisa e cria marcadores de batida (mostra o relatório) |
| `reawarp - Warp item to project tempo.lua` | Item segue o tempo do projeto |
| `reawarp - Tempo map from item.lua` | Projeto segue o tempo do item |
| `reawarp - Fixed project tempo from item.lua` | O projeto assume o BPM do item, como um tempo fixo (sem mapa de tempo) |
| `reawarp - Match groove to first item.lua` | Ajusta os itens selecionados às batidas do primeiro item selecionado |
| `reawarp - Change song tempo.lua` | Muda o tempo de uma música que tem mapa de tempo |
| `reawarp - Double BPM.lua` | Dobra o BPM: do projeto depois de um mapa de tempo, da música depois de um warp |
| `reawarp - Halve BPM.lua` | Reduz o BPM à metade: do projeto depois de um mapa de tempo, da música depois de um warp |
| `reawarp - Next beat marker.lua` | Move o cursor de edição para o próximo marcador de batida e o anuncia pelo OSARA (sem o OSARA, numa nota perto do mouse) |
| `reawarp - Previous beat marker.lua` | Move o cursor de edição para o marcador de batida anterior e o anuncia pelo OSARA (sem o OSARA, numa nota perto do mouse) |
| `reawarp - Move nearest beat marker to edit cursor.lua` | Move o marcador de batida mais próximo para o cursor e atualiza o mapa de tempo/warp |
| `reawarp - Add beat marker at edit cursor.lua` | Adiciona um marcador de batida no cursor de edição e atualiza o mapa de tempo/warp |
| `reawarp - Delete nearest beat marker.lua` | Remove o marcador de batida mais próximo e atualiza o mapa de tempo/warp |
| `reawarp - Shift beats by half a beat.lua` | Desloca meia batida as batidas antes do cursor de edição (ou na seleção de tempo), onde o detector marcou os contratempos, e atualiza o mapa de tempo/warp |
| `reawarp - Set downbeat at edit cursor.lua` | Define o tempo 1 na batida mais próxima do cursor |
| `reawarp - Restore original items.lua` | Volta o item ao estado anterior ao reawarp |
| `reawarp - Quantize to MIDI item.lua` | Leva os ataques dos itens de áudio selecionados para as notas do item MIDI selecionado (a referência, na faixa de cima) |
| `reawarp - Quantize settings.lua` | Força, busca do ataque e sensibilidade do quantize |
| `reawarp - Settings.lua` | Configurações |

### Detector Beat This! (necessário)

O [Beat This!](https://github.com/CPJKU/beat_this) (CPJKU, ISMIR 2024) é um detector de
batidas e tempos fortes com rede neural. O reawarp precisa dele: a primeira análise sem ele
pergunta se deve instalá-lo.

O reawarp também tem um detector interno (Lua puro), mas ele não é confiável o bastante para
ser o padrão. Comparado com o Beat This! em 47 músicas de vários gêneros, concordou em cerca
de 75% delas; ele erra quando os ataques mais fortes ficam fora da batida (reggae, samba,
hip-hop, rock com guitarra no contratempo) e quando não há bumbo e caixa claros (baladas).
Cerca de 25 variantes de sensibilidade aos ataques, peso das bandas e rastreamento não
mudaram isso. Ele continua disponível para quem não pode instalar o Beat This!: escolha `builtin`
em *Detector de batidas* nas configurações. Se o Beat This! estiver instalado mas falhar,
o reawarp para com uma mensagem de erro em vez de usar o detector interno sem avisar; rodar
o instalador de novo o repara.

- Requisito: conexão com a internet durante a instalação. Não é preciso ter Python: o
  instalador baixa o [uv](https://github.com/astral-sh/uv), que traz um Python próprio e
  nunca mexe num Python que já exista no computador.
- Instalação: no menu do reawarp, escolha *Instalar o detector Beat This!*, ou
  rode `backend/install_beat_this.bat` (Windows) ou `backend/install_beat_this.sh` (macOS /
  Linux). Ele baixa cerca de 350 MB e ocupa cerca de 800 MB, tudo dentro de `backend/`
  (`uv`, `python`, `env` e `models`). Para desinstalar, escolha *Desinstalar o detector Beat This!* no
  menu do reawarp (quando o Beat This! está instalado, ela aparece no lugar de *Instalar o detector Beat This!*): ele apaga essas quatro pastas
  e libera cerca de 0,8 GB (3 GB na versão para GPU); o reawarp continua instalado.
  A janela do instalador fecha sozinha no fim, e o reawarp mostra o resultado num diálogo;
  se falhar, o diálogo mostra o final do relatório e oferece copiar o relatório completo
  (`backend/install.log`) para a área de transferência.
  No macOS / Linux o instalador não deixa nada com escrita para todos (pastas 775,
  arquivos 664), então a pasta do REAPER pode ser sincronizada na nuvem (o MEGA e outros
  recusam 777); se uma instalação antiga deixou pastas 777, rode o instalador de novo. Os
  arquivos temporários da análise vão para `/tmp`, não para a pasta do REAPER.
- A análise leva de 5 a 8 segundos por música, em vez de cerca de 1.
- Com uma placa de vídeo NVIDIA (Windows, Linux), o instalador pergunta se deve instalar
  a versão para GPU: o Beat This! fica cerca de duas vezes mais rápido (uma música de 4
  minutos: cerca de 3 s em vez de 6 s), mas ela baixa cerca de 2,5 GB e ocupa cerca de
  3 GB. Ele escolhe a versão do CUDA que o driver da placa suporta; se a GPU falhar, o
  reawarp usa a CPU. Num Mac com Apple silicon a versão normal já usa a GPU. Para trocar
  de versão, rode o instalador de novo e responda a pergunta de outro jeito.
- A pasta `backend` precisa ficar ao lado de `reawarp.lua`.

O warp não escolhe algoritmo: usa o modo de time stretch / pitch shift e o modo dos stretch
markers definidos no item (propriedades do item) ou, se o item usar o padrão, no projeto
(*Project settings*).

## Fluxo de trabalho

1. Selecione o item e rode **Analyze beats**. São criados marcadores de take
   `RW compasso.tempo` (vermelhos no tempo 1). O relatório informa o BPM, a faixa de
   variação, a fórmula de compasso detectada (3/4 ou 4/4) e o primeiro tempo forte. O warp
   alinha esse tempo forte à barra de compasso mais próxima de onde o item está; para
   escolher outra barra, mova o item para perto dela antes de aplicar.
2. Confira. Se precisar:
   - **BPM pela metade ou dobro** → rode **Double BPM** ou **Halve BPM** (no menu: *Dobrar o
     BPM* / *BPM pela metade*). Elas mudam o BPM do que acompanha: depois de um *Mapa de
     tempo*, o tempo do projeto (a música não muda); depois de um *Warp*, a velocidade da
     música (o tempo do projeto não muda; por exemplo, uma música detectada pela metade toca
     rápida demais, e *BPM pela metade* a traz de volta). O tempo 1 fica no lugar, e o mapa
     de tempo ou o warp é aplicado de novo. Ao dobrar, são usadas as batidas que o
     detector realmente encontrou entre as existentes, quando houver (Beat This!, ou
     batidas removidas por *BPM pela metade*); senão, os pontos médios. Também dá para
     ajustar *BPM aproximado* nas configurações e analisar de novo.
   - **Fórmula de compasso errada** → defina-a nas configurações (`3/4`, `4/4`, `6/8`,
     `12/8`...) e analise de novo. Fórmulas compostas (6/8, 9/8, 12/8) contam a semínima
     pontuada como tempo; use-as quando a análise der um BPM 1,5× menor que o esperado.
   - **Tempo 1 errado** → coloque o cursor de edição sobre o tempo 1 correto e rode
     *Set downbeat at edit cursor*.
   - **Uma batida errada** → vá até ela com *Próximo marcador de batida* / *Marcador de
     batida anterior* (o OSARA fala o marcador, por exemplo "RW 3.2 (batida 10 de 120,
     98,5 BPM)"), coloque o cursor de edição onde a batida realmente está e rode *Mover
     marcador de batida mais próximo para o cursor de edição*; *Adicionar marcador de
     batida no cursor de edição* preenche uma batida que o detector perdeu, e *Remover
     marcador de batida mais próximo* tira uma sobrando. Se o item já tiver warp, mapa de
     tempo ou groove match, ele é aplicado de novo sozinho. Também dá para mover ou apagar
     os marcadores `RW` à mão. Os marcadores são a grade usada pelo warp; o reawarp não os
     recria se já existirem.
   - **Parte da música no contratempo** → numa introdução só com voz, ou numa parada, o
     detector pode marcar os contratempos; onde a banda entra, ele volta para as batidas,
     e ali o intervalo entre dois marcadores de batida é de 1,5 batida (ou 0,5). Coloque o
     cursor de edição ali (até 3 batidas de distância serve) e rode *Deslocar batidas em meia batida*: as batidas antes do
     cursor andam meia batida, e o warp, o mapa de tempo ou o groove match é aplicado de
     novo. Para um trecho no meio da música, selecione-o antes com uma seleção de tempo. A
     direção é a que transforma o pulo numa batida inteira; se não houver esse pulo nas
     bordas, nada muda.
3. Rode **Warp** ou **Mapa de tempo**.
   - *Warp*: o tempo forte da música vai para a barra de compasso mais próxima de onde ele
     já está, e cada batida (ou a cada N tempos) recebe um stretch marker no grid. A música
     passa a tocar no BPM do projeto. Para manter o tempo original, use *Mapa de tempo*.
     Se o item ainda não foi analisado, a análise é feita antes, sem mostrar relatório.
     Se o projeto tiver um mapa de tempo variável no trecho do item (por exemplo, sobra de
     um *Mapa de tempo*), o reawarp pergunta se deve removê-lo e usar um tempo fixo; senão,
     a música seguiria esse tempo variável.
     Quando dá tudo certo o warp não abre janela (com o OSARA, ele anuncia "Warp
     aplicado"); só aparece um diálogo para perguntar sobre a fórmula de compasso ou o
     mapa de tempo.
     2/4, 4/4 e 2/2 são tratados como equivalentes (não dá para distingui-los com segurança
     pelo áudio e as barras coincidem): uma música binária usa a fórmula do projeto.
     Se a fórmula da música for diferente da do projeto (ex.: 3/4 num projeto 4/4), o
     reawarp pergunta se deve inserir a fórmula da música no início do item (e restaurar a
     anterior depois dele) para os compassos coincidirem. O item mantém o seu modo de time
     stretch e de stretch markers e, por padrão, passa a usar a base de tempo "beats
     (position, length, rate)" para continuar sincronizado se o tempo do projeto mudar.
     Com vários itens selecionados, cada um recebe o warp pelas suas próprias batidas (veja
     [Vários itens de uma vez](#vários-itens-de-uma-vez)).
     Quando o item começa bem na primeira batida (um loop), os primeiros milissegundos
     tocam na velocidade original, porque o stretch do REAPER borra um ataque logo no
     início do item; o esticamento começa logo depois desse ataque.
   - *Mapa de tempo*: o tempo do projeto segue a música desde antes de ela começar, então a
     introdução, a anacruse e a contagem já ficam no tempo da música: desde o início do
     projeto, se não houver marcador de tempo antes do item, ou desde a barra em que o item
     começa (marcadores anteriores, como os de outra música, são mantidos). O item é
     deslocado (menos de meio compasso) para o tempo forte cair numa barra, e cada batida,
     inclusive as da anacruse, recebe um marcador de tempo. Depois, o item acompanha
     mudanças de tempo como um item com warp (base de tempo "beats (position, length,
     rate)"), ou mantém a sua base de tempo se *Item segue mudanças de tempo* for 0.
     Marcadores de tempo existentes na região do item são substituídos. Com vários itens
     selecionados, o primeiro (na ordem das faixas) cria o mapa de tempo e os outros
     recebem o warp para ele, como no *Warp* (veja
     [Vários itens de uma vez](#vários-itens-de-uma-vez)).
   - *Groove Match* (*Combinar groove*): selecione o item de referência (por exemplo uma
     música ou a bateria) e os itens que devem segui-lo (por exemplo um loop). A
     referência é o primeiro item selecionado na ordem das faixas, então coloque-a na
     faixa de cima. Cada um dos outros itens recebe stretch markers para que as suas
     batidas sigam as da referência, inclusive nas acelerações e desacelerações, e fica
     onde você o colocou; a referência e o tempo do projeto não mudam. As batidas são
     encaixadas nas batidas mais próximas da referência, não compasso com compasso, então
     coloque o item perto da batida onde ele deve começar. *Dobrar o BPM* e *BPM pela
     metade* também funcionam nos itens ajustados.

### Vários itens de uma vez

Selecione os itens e rode a ação. Eles são considerados na ordem das faixas: o item da faixa
de cima (a primeira faixa do projeto, quando estão em faixas diferentes) é a
**referência**, como no *Groove Match* e em *Sincronizar outros itens* (abaixo). Itens MIDI
são ignorados.

- **Warp**: não há item de referência, a referência é o tempo do projeto. Cada item é
  analisado e recebe o warp pelas suas próprias batidas, no grid do projeto; assim, uma
  música e um loop gravados em andamentos diferentes ficam os dois no BPM do projeto,
  juntos.
- **Mapa de tempo**: o item de referência cria o mapa de tempo, e todos os outros itens
  selecionados recebem o warp para esse mapa; assim eles assumem o andamento da referência,
  com as acelerações e desacelerações dela. Exemplo: num remix, coloque a música na faixa de
  cima e um loop (bateria, uma linha de baixo) numa faixa abaixo, deixe o loop perto do
  compasso onde ele deve começar, selecione os dois e rode o *Mapa de tempo*: o tempo do
  projeto segue a música, e o loop a acompanha compasso a compasso.
- **Groove Match**: o item de referência e o tempo do projeto não mudam; os outros itens
  seguem as batidas da referência.
- **Fixed project tempo from item** usa só o primeiro item selecionado.

**Música e loop: Mapa de tempo ou Groove Match?** Nos dois casos, o loop passa a seguir o
andamento da música, batida a batida. A diferença está no grid do projeto:

- Com o *Mapa de tempo*, o tempo do projeto (metrônomo, grid, MIDI, novas gravações) também
  segue a música, então tudo o que for acrescentado depois fica no tempo da música e do
  loop. É a escolha comum para um remix ou para acrescentar instrumentos a uma gravação.
- Com o *Groove Match*, só o loop segue a música; o tempo do projeto fica como estava. Use
  quando o projeto já tem um andamento que não pode mudar (por exemplo outras músicas no
  mesmo projeto), e o loop só precisa se encaixar na música.
- Com o *Warp* (selecionando os dois), é o contrário: a música é esticada para o tempo fixo
  do projeto, e o loop também.

Com *Stretch marker a cada N tempos* em 0 (automático), cada item só recebe marcadores
onde o andamento dele se afasta da referência (o grid do projeto, ou o mapa de tempo criado
pelo item de referência), dentro da tolerância de *Marcadores automáticos*.

Gravações multipista: com *Sincronizar outros itens* em 1 nas configurações, o warp ou o
mapa de tempo aplicado a um item (por exemplo a bateria) é aplicado do mesmo jeito aos itens
agrupados com ele (selecione-os e aperte Ctrl+G, *Group items*), e a banda toda continua
junta; 2 inclui todos os itens de áudio desbloqueados no mesmo trecho, sem os itens MIDI (para que uma
parte MIDI ou a referência de um quantize fique no grid do projeto); 3 inclui todos os itens
desbloqueados, MIDI também. No padrão (0), só os itens
selecionados mudam.

Para um loop, ou uma música de tempo estável, **Fixed project tempo from item** (no menu: *Tempo
do projeto: projeto assume o BPM do item*) ajusta o projeto para o BPM do item, como um tempo
fixo, sem mapa de tempo: o item mantém a sua velocidade e é deslocado (menos de meio
compasso) para o tempo forte cair numa barra de compasso. O BPM vem de todas as batidas
juntas (num loop, da sua duração, que é um número inteiro de batidas) e é arredondado
quando fica a menos de 0,02 de um número inteiro. Se o projeto tiver marcadores de tempo no
trecho do item, o reawarp pergunta antes de removê-los; se o tempo do item variar, o
resultado avisa (uma música de tempo variável é acompanhada melhor pelo *Mapa de tempo* ou
pelo *Warp*).

Para deixar mais rápida ou mais lenta uma música com mapa de tempo, use **Change song
tempo** (no menu: *Alterar o tempo da música*). O BPM do projeto no REAPER só muda o tempo
até o próximo marcador de tempo (aqui há um por batida), então essa ação pede um novo BPM
médio e multiplica todos os marcadores da música pela mesma proporção, mantendo cada um no
seu compasso e tempo. Com um item selecionado, muda o trecho desse item; sem nenhum, o
projeto inteiro. O item acompanha, com o tom preservado. Outros itens nesse trecho que
receberam warp do reawarp (um loop, por exemplo) recebem o warp de novo para o novo tempo,
e o começo de um loop mantém o seu ataque.

### Quantizar por um item MIDI

**Quantizar** (*Quantize to MIDI item*) leva os ataques de itens de áudio para as notas de um
item MIDI, que dá o ritmo: desenhe ou grave a figura que quiser (colcheias retas, um swing,
um shuffle como a tarantela, ou o groove de outra execução), numa faixa acima.

1. Primeiro faça o áudio seguir o tempo do projeto, com *Warp* ou *Mapa de tempo* (o quantize
   parte das batidas estarem no tempo do grid).
2. Selecione o item MIDI (a referência, na faixa de cima) e um ou mais itens de áudio.
3. Rode **Quantizar**.

Cada nota corresponde a uma posição do grid reto, com o número de notas por tempo mais comum
no item MIDI: com duas notas por tempo são colcheias, então uma nota a 2/3 do tempo (swing de
tercina) recebe o áudio da metade do tempo, e uma nota na cabeça recebe o áudio da cabeça. O
áudio dali é preso na nota com um stretch marker, no seu ataque quando há um perto; o áudio
no meio (semicolcheias, por exemplo) é esticado junto. Só conta onde as notas começam, não a
duração delas. Notas mudas são ignoradas; um item MIDI em loop conta só a primeira volta.
Fora das notas, o item fica como estava (com o seu warp, por exemplo). Vários itens de áudio
podem ser quantizados de uma vez, e o mesmo item MIDI pode ser usado em outras músicas: com
*Sincronizar outros itens* em 2, o warp não mexe nos itens MIDI.

**Configurações do quantize** (no menu, ou a ação *Quantize settings*):

| Campo | Padrão | Observações |
|---|---|---|
| Força em % | 75 | 100 põe cada ataque exatamente na nota; 50 leva até a metade do caminho, mantendo parte da execução original e esticando menos |
| Procurar o ataque até N ms da grade | 25 | Até onde, em volta da posição do grid reto, procurar o ataque do áudio. 0 usa a própria posição do grid |
| Sensibilidade em % | 50 | 100 aceita até os ataques mais fracos (numa mixagem densa), 0 só os bem claros. Onde nenhum ataque é aceito, usa a própria posição do grid |

Os padrões são do lado seguro: o groove se ouve bem, com menos artefatos de esticamento.
Para um quantize exato e agressivo (o áudio segue o MIDI nota por nota), use força 100,
40 ms e sensibilidade 100.

Cada ação é um único passo de desfazer (Ctrl+Z).

## Configurações

| Campo | Padrão | Notas |
|---|---|---|
| BPM mínimo / máximo | 60 / 180 | Faixa de busca do tempo |
| BPM aproximado | 0 | Se > 0, força a busca perto desse valor (resolve metade/dobro) |
| Fórmula de compasso | auto | `auto` detecta 3/4 ou 4/4; ou digite `3/4`, `6/8`, `5/4`... |
| Flexibilidade | 50 | 0 = tempo rígido (eletrônica); 100 = muito livre (ao vivo, rubato) |
| Stretch marker a cada N tempos | 1 | Use 4 (um por compasso) para menos artefatos. 0 = automático: marcadores só onde o tempo muda (entre dois marcadores o áudio é esticado por igual; uma batida só ganha marcador quando, sem ele, alguma batida ficaria mais longe do grid do que a tolerância). Uma música de tempo estável fica com poucos marcadores, uma com rubato com muitos. Vale também para os marcadores do *Mapa de tempo* |
| Marcadores automáticos: tolerância em ms | 10 | Com N = 0: o quanto (em ms) uma batida pode ficar fora do grid antes de ganhar um marcador |
| Suavizar grade | 0 | -1 = ajusta um tempo constante; N = suaviza com ±N batidas |
| Alinhar ao transiente | 1 | Ajusta cada batida ao início do ataque mais próximo (±30 ms) |
| Ajuste fino | 0 | Com o Beat This!, 1 coloca cada batida no seu primeiro ataque (até 12 ms) em vez de só corrigir o deslocamento médio; experimente quando algumas batidas soarem um pouco atrasadas em trechos cheios |
| Item segue mudanças de tempo | 1 | Base de tempo do item após o warp |
| Ajustar compasso do projeto | 1 | No warp, se a fórmula difere: 0 = nunca, 1 = perguntar, 2 = sempre |
| Sincronizar outros itens | 0 | No warp/mapa de tempo: 0 = não, 1 = itens agrupados com o selecionado, 2 = todos os itens de áudio desbloqueados sobrepostos, 3 = todos os itens desbloqueados sobrepostos, MIDI incluído |
| Detector de batidas | auto | `auto` (ou `beat_this`) usa o Beat This!; `builtin` usa o detector interno, menos confiável |
| Progresso visual | auto | Uma dica (tooltip) perto do mouse mostra a etapa e o tempo decorrido enquanto uma ação roda. `auto` mostra só sem o OSARA (leitores de tela podem ler cada atualização); `on` ou `off` |
| Idioma | auto | `auto`, `en`, `pt-BR` ou `es`. `auto` usa o langpack do REAPER ou, sem ele, o idioma do sistema |

## Traduções

Todas as mensagens estão na tabela `STRINGS`, no início da seção 2 de `reawarp.lua`. O
inglês (`STRINGS.en`) é a referência. Para adicionar um idioma, copie essa tabela com um
novo código (por exemplo `STRINGS["fr"]`), traduza os valores (mantendo cada `%s`, `%d`,
`%.2f`... na mesma ordem) e, para a detecção automática, inclua o idioma em `detect_lang`.
O usuário também pode escolhê-lo digitando o código na configuração *Idioma*. Chaves que
faltarem numa tradução usam o inglês. Os nomes dos campos das configurações não podem ter
vírgulas (o diálogo do REAPER as usa como separador).

## Como funciona

A primeira seção de `reawarp.lua` (independente do REAPER):

1. O áudio é mixado em mono (todos os canais, então itens multicanal também funcionam),
   lido a 11025 Hz e dividido em 4 bandas (graves, médio-graves, médios, agudos).
   O fluxo de energia logarítmica entre quadros de 11,6 ms gera a curva de "ataques".
2. Tempo global por autocorrelação com preferência por ~120 BPM (ou pela sua dica).
3. Curva de tempo local (janelas de 8 s), que acompanha acelerandos e oscilações.
4. Rastreamento de batidas por programação dinâmica (Ellis, 2007) usando o período local.
5. Cada batida é ajustada ao início do transiente mais próximo, com precisão de ~1 ms.
6. Fórmula de compasso: os padrões rítmicos por banda em cada batida se repetem a cada
   compasso; compara-se a correlação em defasagens de 3/9 e 4/8 batidas.
7. O tempo forte é estimado pela acentuação dos graves (bumbo), em escala logarítmica e
   linear (para diferenciar o bumbo forte do tempo 1 do mais fraco do tempo 3).

Com o Beat This! instalado, `backend/reawarp_beat_this.py` substitui os passos 2 a 7: ele
devolve batidas e tempos fortes, com posição refinada abaixo dos quadros de 20 ms do modelo
(interpolando o pico da saída). O reawarp então escolhe o nível métrico mais próximo da sua
própria estimativa de tempo, corrige trechos em que o detector passa a marcar colcheias ou
pula batidas (usando como referência a curva de tempo local do passo 3) e tira a fórmula de
compasso e a fase do compasso dos tempos fortes.

## Testes

```
pip install lupa numpy
python tests/test_dsp.py            # sinais sintéticos: tempo fixo, rampa, drift, 3/4
python tests/test_dsp.py musica.mp3 # analisa um arquivo (precisa do ffmpeg no PATH)
python tests/test_core.py           # ações completas contra um REAPER simulado
```

`tests/reaper_run.lua` roda as ações no REAPER de verdade, numa aba de projeto separada, e
reanalisa o áudio já processado para medir a distância das batidas até o grid. Ele é
chamado por um script curto que define `RW_MAIN`, `RW_OUT`, `RW_RPP` e `RW_CASES` (veja o
cabeçalho do arquivo) e é enviado à instância aberta com `reaper.exe -nonewinst script.lua`.

## Limitações conhecidas

- A detecção de tempo forte é heurística (bumbo); use *Set downbeat at edit cursor*
  quando errar.
- Introduções sem pulso claro (rubato, só um instrumento, anacruse longa) podem ter as
  primeiras batidas mal posicionadas, principalmente com o detector interno. Confira os
  primeiros marcadores `RW` e mova ou apague os errados antes do warp.
- Mudanças de fórmula de compasso dentro da música não são detectadas.
- A detecção automática distingue binário (2/4, 4/4) de ternário (3/4); fórmulas compostas
  ou irregulares (6/8, 5/4, 7/8) precisam ser definidas nas configurações.

## Como contribuir

O reawarp para REAPER pretende ser um warp tão bom quanto parece. Se ele está ajudando de
alguma forma no seu projeto, considere contribuir:

- **Problemas e sugestões**: abra uma
  [issue](https://github.com/gabrielschuck/reawarp/issues) (em português ou inglês). Se uma
  música for detectada ou ajustada errado, diga qual ação usou, as configurações, o que
  esperava e o que aconteceu (compasso e tempo ajudam muito).
- **Código**: faça um fork do repositório e abra um pull request. Rode os testes offline
  (veja [Testes](#testes)) e mantenha a interface acessível: só menus e diálogos nativos do
  REAPER, mensagens pelo OSARA quando disponível.
- **Traduções**: acrescente uma tabela em `STRINGS` no `reawarp.lua` (veja
  [Traduções](#traduções)).
- **Doações**: se o reawarp for útil para você, pode apoiar o desenvolvimento por Pix ou
  PayPal para **gabrielschuck.tecladista@gmail.com**. Obrigado!

## Licença

Copyright (C) 2026 Gabriel Schuck.

O reawarp é software livre sob a [GNU General Public License v3.0](LICENSE) ou posterior.
Você pode usar, estudar, modificar e compartilhar; se distribuir uma versão modificada,
ela também precisa ser publicada sob a GPL, com o código-fonte, mantendo o aviso de
copyright original.

## Agradecimentos

- A [vrivrixd](https://github.com/vrivrixd), pela tradução para o espanhol.
- A [GianlucaApollaro](https://github.com/GianlucaApollaro), pelo Groove Match, pela
  navegação e edição dos marcadores de batida, pela sincronização multipista e pela
  análise multicanal.

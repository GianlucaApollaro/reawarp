# reawarp: Warp, Mapa de tempo, Groove Match y Cuantización para REAPER

*[Read in English](README.md) · [Leia em português](README.pt-BR.md)*

> Las contribuciones, los reportes de errores y las sugerencias son muy bienvenidos; vea
> [Cómo contribuir](#cómo-contribuir).
>
> Contacto: gabrielschuck.tecladista@gmail.com

Warp de audio para REAPER, al estilo del Warp de Ableton Live: reawarp detecta los pulsos
de una canción (incluso con tempo variable) y

- **Warp**: ajusta el ítem al tempo del proyecto (un stretch marker en cada pulso),
- **Mapa de tempo**: hace que el proyecto siga la canción (un marcador de tempo en cada pulso), o
- **Groove Match** (*Igualar groove*): hace que otros ítems (un loop, otra grabación) sigan
  los pulsos de un ítem de referencia, sin cambiar el tempo del proyecto, o
- **Cuantizar**: lleva los ataques del audio a las notas de un ítem MIDI, que marca el ritmo
  (recto, swing, un shuffle como la tarantela).

Los pulsos incorrectos se pueden corregir con el teclado: vaya al marcador de pulso
siguiente o anterior (OSARA anuncia compás, pulso y BPM; sin OSARA se muestran en una nota
junto al ratón) y mueva, añada o elimine un marcador; el warp, el mapa de tempo o el groove
match se vuelve a aplicar solo.

Se pueden procesar varios ítems a la vez, por ejemplo una canción y un loop en un remix, o
las pistas de una grabación multipista; vea [Varios ítems a la vez](#varios-ítems-a-la-vez).

Está escrito en Lua; los pulsos los detecta el detector con red neuronal
[Beat This!](https://github.com/CPJKU/beat_this), que se instala con un clic (no hace falta
tener Python instalado). Toda la interfaz usa los menús y diálogos nativos de REAPER, así que
funciona con lectores de pantalla (OSARA). Sin OSARA todo es también visual: los resultados
aparecen en una ventana, una acción en curso muestra su progreso en una ayuda emergente
(tooltip) junto al ratón, y al moverse entre marcadores de pulso el marcador se muestra en
una nota junto al ratón que desaparece sola. Los mensajes aparecen en español, portugués o
inglés según el ajuste *Idioma*.

## Instalación

**Con ReaPack** (recomendado: las actualizaciones llegan solas):

1. En REAPER: *Extensions > ReaPack > Import repositories...* y pegue
   `https://github.com/gabrielschuck/reawarp/raw/main/index.xml`
2. *Extensions > ReaPack > Browse packages*, busque **reawarp** e instálelo.
   Todas las acciones aparecen en la lista de acciones.

**Manualmente** (sin ReaPack):

1. Descargue el ZIP de la última versión en
   [Releases](https://github.com/gabrielschuck/reawarp/releases) y extraiga la carpeta
   `reawarp` dentro de la carpeta `Scripts` de REAPER (*Options > Show REAPER resource path*).
2. En REAPER: *Actions > Show action list > New action > Load ReaScript...* y cargue
   `reawarp.lua`.
3. Ejecute una vez la acción `reawarp.lua`. Abre el menú y registra las acciones
   individuales en la lista de acciones (después puede cancelar el menú).

Luego instale el detector Beat This! desde el menú de reawarp (vea más abajo). Opcional:
asigne atajos de teclado a las acciones.

Todo el código está en `reawarp.lua`. REAPER asocia cada acción a un archivo, así que las
acciones individuales son archivos de dos líneas en la subcarpeta `actions/`; solo llaman a
la función correspondiente de `reawarp.lua`. Nunca hace falta editarlos, y se vuelven a
crear si se borran.

Pasar de una instalación manual a ReaPack: ReaPack instala en `Scripts/reawarp/Tempo/`.
Para conservar el Beat This! ya instalado, mueva las carpetas `env`, `models`, `python` y
`uv` de la carpeta `backend` antigua a la nueva, y luego borre los antiguos
`Scripts/reawarp/reawarp.lua` y `actions` (y quite sus entradas de la lista de acciones).
Al mover las carpetas se rompen los enlaces del entorno de Python, así que después ejecute
una vez *Instalar el detector Beat This!...* desde el menú de reawarp: repara el entorno en
unos segundos y aprovecha lo que ya se descargó.

REAPER sigue respondiendo mientras una acción trabaja: Beat This! se ejecuta en segundo
plano y el análisis le devuelve la ventana a REAPER muchas veces por segundo, así que puede
seguir moviéndose por el proyecto (no edite el ítem que se está analizando). El resultado
se anuncia por OSARA; sin OSARA se muestra en una ventana (al moverse entre marcadores de
pulso, el marcador se muestra en una nota junto al ratón, ya que una ventana en cada
pulsación de tecla estorbaría). Los diálogos solo aparecen
cuando reawarp necesita una respuesta (compás, eliminar un mapa de tempo, un nuevo BPM) y
en los ajustes. Ejecutar de nuevo la misma acción mientras trabaja la cancela (Deshacer
revierte lo que ya había cambiado); iniciar otra acción de reawarp mientras tanto solo
avisa que todavía está trabajando. Al iniciar una acción, OSARA anuncia que reawarp está
procesando; el informe del análisis se sigue mostrando en un diálogo, porque explica qué
revisar a continuación.

Las acciones tienen nombre en inglés en la lista de acciones:

| Entrada en la lista de acciones | Qué hace |
|---|---|
| `reawarp.lua` | Menú con todas las funciones |
| `reawarp - Analyze beats.lua` | Analiza y crea marcadores de pulso (muestra un informe) |
| `reawarp - Warp item to project tempo.lua` | El ítem sigue el tempo del proyecto |
| `reawarp - Tempo map from item.lua` | El proyecto sigue el tempo del ítem |
| `reawarp - Fixed project tempo from item.lua` | El proyecto toma el BPM del ítem, como un tempo fijo (sin mapa de tempo) |
| `reawarp - Match groove to first item.lua` | Ajusta los ítems seleccionados a los pulsos del primer ítem seleccionado |
| `reawarp - Change song tempo.lua` | Cambia el tempo de una canción que tiene mapa de tempo |
| `reawarp - Double BPM.lua` | Duplica el BPM: del proyecto después de un mapa de tempo, de la canción después de un warp |
| `reawarp - Halve BPM.lua` | Reduce el BPM a la mitad: del proyecto después de un mapa de tempo, de la canción después de un warp |
| `reawarp - Next beat marker.lua` | Mueve el cursor de edición al siguiente marcador de pulso y lo anuncia por OSARA (sin OSARA, en una nota junto al ratón) |
| `reawarp - Previous beat marker.lua` | Mueve el cursor de edición al marcador de pulso anterior y lo anuncia por OSARA (sin OSARA, en una nota junto al ratón) |
| `reawarp - Move nearest beat marker to edit cursor.lua` | Mueve el marcador de pulso más cercano al cursor y actualiza el mapa de tempo/warp |
| `reawarp - Add beat marker at edit cursor.lua` | Añade un marcador de pulso en el cursor de edición y actualiza el mapa de tempo/warp |
| `reawarp - Delete nearest beat marker.lua` | Elimina el marcador de pulso más cercano y actualiza el mapa de tempo/warp |
| `reawarp - Shift beats by half a beat.lua` | Desplaza medio pulso los pulsos antes del cursor de edición (o en la selección de tiempo), donde el detector marcó los contratiempos, y actualiza el mapa de tempo/warp |
| `reawarp - Set downbeat at edit cursor.lua` | Convierte en pulso 1 el pulso más cercano al cursor de edición |
| `reawarp - Restore original items.lua` | Devuelve los ítems al estado que tenían antes de reawarp |
| `reawarp - Quantize to MIDI item.lua` | Lleva los ataques de los ítems de audio seleccionados a las notas del ítem MIDI seleccionado (la referencia, en la pista de arriba) |
| `reawarp - Quantize settings.lua` | Fuerza, búsqueda del ataque y sensibilidad de la cuantización |
| `reawarp - Settings.lua` | Ajustes |

### Detector Beat This! (necesario)

[Beat This!](https://github.com/CPJKU/beat_this) (CPJKU, ISMIR 2024) es un detector de
pulsos y tiempos fuertes basado en redes neuronales. reawarp lo necesita: el primer
análisis sin él pregunta si desea instalarlo.

reawarp también tiene un detector integrado (Lua puro), pero no es lo bastante fiable para
ser el predeterminado. Comparado con Beat This! en 47 canciones de muchos géneros, coincidió
en cerca del 75% de ellas; falla cuando los ataques más fuertes están fuera del pulso
(reggae, samba, hip-hop, rock con guitarra a contratiempo) y cuando no hay un bombo o una
caja claros (baladas). Unas 25 variantes de su sensibilidad a los ataques, del peso de las
bandas y del seguimiento no cambiaron eso. Sigue disponible para quien no pueda instalar
Beat This!: elija `builtin` como *Detector de pulsos* en los ajustes. Si Beat This! está
instalado pero falla, reawarp se detiene con un error en lugar de usar en silencio el
detector integrado; volver a ejecutar el instalador lo repara.

- Requisitos: conexión a internet durante la instalación. No hace falta tener Python
  instalado: el instalador descarga [uv](https://github.com/astral-sh/uv), que trae su
  propio Python privado y nunca toca un Python que ya esté en el equipo.
- Instalar: en el menú de reawarp elija *Instalar el detector Beat This!*, o ejecute
  `backend/install_beat_this.bat` (Windows) o `backend/install_beat_this.sh` (macOS /
  Linux). Descarga unos 350 MB y ocupa unos 800 MB en disco, todo dentro de `backend/`
  (`uv`, `python`, `env` y `models`). Para desinstalarlo, elija *Desinstalar el detector
  Beat This!* en el menú de reawarp (cuando Beat This! está instalado, aparece en lugar de *Instalar el detector Beat This!*): borra esas
  cuatro carpetas y libera unos 0,8 GB (3 GB en la versión para GPU); reawarp sigue
  instalado.
  La ventana del instalador se cierra sola al terminar, y reawarp muestra el resultado en
  un diálogo; si falla, el diálogo muestra el final del registro y ofrece copiar el
  registro completo (`backend/install.log`) al portapapeles.
  En macOS / Linux el instalador no deja nada con permiso de escritura para todos
  (carpetas 775, archivos 664), así que la carpeta de REAPER se puede sincronizar en la
  nube (MEGA y otros rechazan 777); si una instalación anterior dejó carpetas en 777,
  vuelva a ejecutar el instalador. Los archivos temporales del análisis van a `/tmp`, no a
  la carpeta de REAPER.
- El análisis tarda unos 5 a 8 segundos por canción en lugar de cerca de 1.
- Con una tarjeta gráfica NVIDIA (Windows, Linux), el instalador pregunta si desea
  instalar la versión para GPU: Beat This! funciona unas dos veces más rápido (una canción
  de 4 minutos: unos 3 s en lugar de 6 s), pero descarga unos 2,5 GB y ocupa unos 3 GB en
  disco. Elige la versión de CUDA que admite el controlador de la tarjeta; si la GPU falla,
  reawarp usa la CPU. En un Mac con Apple silicon la versión normal ya usa la GPU. Para
  cambiar de versión, vuelva a ejecutar el instalador y responda de otra forma a la
  pregunta.
- Para que funcione, la carpeta `backend` debe estar junto a `reawarp.lua`.

El warp no elige un algoritmo de estiramiento: usa el modo de time stretch / pitch shift y
el modo de stretch markers configurados en el ítem (propiedades del ítem) o, cuando el ítem
usa el predeterminado, en el proyecto (*Project settings*).

## Cómo se usa

1. Seleccione el ítem y ejecute **Analizar los pulsos**. Se crean marcadores de toma
   `RW compás.pulso` (rojos en el pulso 1). El informe muestra el BPM, su rango, el compás
   detectado (3/4 o 4/4) y el primer tiempo fuerte. El warp alinea ese tiempo fuerte con la
   línea de compás más cercana a donde está el ítem; para elegir otro compás, acerque el
   ítem a él antes del warp.
2. Revise el resultado. Si hace falta:
   - **BPM a la mitad o al doble** → ejecute **Duplicar el BPM** o **Reducir el BPM a la
     mitad**. Cambian el BPM de lo que sigue: después de un *Mapa de tempo*, el tempo del
     proyecto (la canción no cambia); después de un *Warp*, la velocidad de la canción (el
     tempo del proyecto no cambia; por ejemplo, una canción detectada a la mitad del tempo
     suena el doble de rápida, y *Reducir el BPM a la mitad* la corrige). El pulso 1 se
     queda en su lugar y el mapa de tempo o el warp se vuelve a aplicar.
     Para duplicar se usan los pulsos que el detector realmente encontró entre los
     existentes cuando los hay (Beat This!, o pulsos quitados por *Reducir el BPM a la
     mitad*); si no, los puntos medios. También puede indicar un *BPM aproximado* en los
     ajustes y volver a analizar.
   - **Compás incorrecto** → indíquelo en los ajustes (`3/4`, `4/4`, `6/8`, `12/8`...) y
     vuelva a analizar. Los compases compuestos (6/8, 9/8, 12/8) cuentan la negra con
     puntillo como pulso; úselos cuando el análisis informe un BPM 1,5 veces menor que el
     esperado.
   - **Pulso 1 incorrecto** → coloque el cursor de edición sobre el pulso 1 correcto y
     ejecute *Fijar el tiempo fuerte en el cursor de edición*.
   - **Un pulso incorrecto** → vaya hasta él con *Siguiente marcador de pulso* /
     *Marcador de pulso anterior* (OSARA anuncia el marcador, por ejemplo "RW 3.2 (pulso
     10 de 120, 98,5 BPM)"), coloque el cursor de edición donde realmente está el pulso y
     ejecute *Mover el marcador de pulso más cercano al cursor de edición*; *Añadir
     marcador de pulso en el cursor de edición* agrega un pulso que el detector no
     encontró, y *Eliminar el marcador de pulso más cercano* quita uno que sobra. Si el
     ítem ya tiene warp, mapa de tempo o groove match, se vuelve a aplicar solo. También
     puede mover o borrar a mano los marcadores `RW`. Los marcadores son la cuadrícula
     que usa el warp; reawarp no los vuelve a crear si ya existen.
   - **Parte de la canción en el contratiempo** → en una introducción solo con voz, o en un
     corte, el detector puede marcar los contratiempos; donde entra la banda, vuelve a los
     pulsos, y ahí el intervalo entre dos marcadores de pulso es de 1,5 pulsos (o 0,5).
     Coloque el cursor de edición ahí (hasta 3 pulsos de distancia sirve) y ejecute *Desplazar pulsos medio pulso*: los pulsos
     antes del cursor se mueven medio pulso, y el warp, el mapa de tempo o el groove match
     se vuelve a aplicar. Para un tramo en medio de la canción, selecciónelo antes con una
     selección de tiempo. La dirección es la que convierte el salto en un pulso entero; si
     no hay ese salto en los bordes, no se cambia nada.
3. Ejecute **Warp** o **Mapa de tempo**.
   - *Warp*: el tiempo fuerte de la canción va a la línea de compás más cercana a donde ya
     está, y cada pulso (o cada N pulsos) recibe un stretch marker sobre la cuadrícula.
     La canción pasa a sonar al BPM del proyecto; para conservar su tempo original, use
     *Mapa de tempo*.
     Si el ítem nunca se analizó, primero se analiza sin mostrar el informe.
     Si el proyecto tiene un mapa de tempo variable en la zona del ítem (por ejemplo, el
     que dejó un *Mapa de tempo*), reawarp pregunta si desea eliminarlo y usar un tempo
     fijo; si no, la canción con warp seguiría ese tempo variable.
     Cuando todo sale bien, el warp no abre ninguna ventana (con OSARA anuncia "Warp
     aplicado"); un diálogo solo aparece para preguntar por el compás o el mapa de tempo.
     2/4, 4/4 y 2/2 se tratan como equivalentes (no se pueden distinguir con fiabilidad
     por el audio, y sus líneas de compás coinciden): una canción en compás binario usa el
     compás del proyecto. Si el compás de la canción es distinto del del proyecto (por
     ejemplo 3/4 en un proyecto en 4/4), reawarp pregunta si desea insertar el compás de
     la canción al inicio del ítem (y restaurar el anterior después) para que los compases
     coincidan. El ítem conserva sus modos de time stretch y de stretch markers y, por
     defecto, pasa a la base de tiempo "beats (position, length, rate)" para seguir
     sincronizado si el tempo del proyecto cambia más adelante.
     Con varios ítems seleccionados, cada uno recibe el warp según sus propios pulsos (vea
     [Varios ítems a la vez](#varios-ítems-a-la-vez)).
     Cuando el ítem empieza justo en su primer pulso (un loop), sus primeros milisegundos
     suenan a su velocidad original, porque el stretch de REAPER emborrona un ataque justo
     al inicio de un ítem; el estiramiento empieza justo después de ese ataque.
   - *Mapa de tempo*: el tempo del proyecto sigue la canción desde antes de que empiece la
     música, así que la introducción, las anacrusas y la cuenta previa ya están al tempo de
     la canción: desde el inicio del proyecto cuando no hay ningún marcador de tempo antes
     del ítem; si no, desde la línea de compás donde empieza el ítem (los marcadores
     anteriores, por ejemplo de otra canción, se conservan). El ítem se mueve (menos de
     medio compás) para que su tiempo fuerte caiga sobre una línea de compás, y cada pulso,
     anacrusas incluidas, recibe un marcador de tempo. Después el ítem sigue los cambios de
     tempo posteriores como un ítem con warp (base de tiempo "beats (position, length,
     rate)"), o conserva su propia base de tiempo si *El ítem sigue los cambios de tempo*
     es 0. Los marcadores de tempo que ya había en la zona del ítem se reemplazan. Con
     varios ítems seleccionados, el primero (en el orden de las pistas) crea el mapa de
     tempo y los demás reciben el warp hacia él, como con *Warp* (vea
     [Varios ítems a la vez](#varios-ítems-a-la-vez)).
   - *Groove Match* (*Igualar groove*): seleccione el ítem de referencia (por ejemplo una
     canción o la batería) y los ítems que deben seguirlo (por ejemplo un loop). La
     referencia es el primer ítem seleccionado en el orden de las pistas, así que póngala
     en la pista de arriba. Cada uno de los demás ítems recibe stretch markers para que sus
     pulsos sigan los de la referencia, incluso en sus aceleraciones y desaceleraciones, y
     se queda donde usted lo puso; la referencia y el tempo del proyecto no cambian. Los
     pulsos se encajan en los pulsos más cercanos de la referencia, no compás con compás,
     así que coloque el ítem cerca del pulso donde debe empezar. *Duplicar el BPM* y
     *Reducir el BPM a la mitad* también funcionan en los ítems igualados.

### Varios ítems a la vez

Seleccione los ítems y ejecute la acción. Se toman en el orden de las pistas: el ítem de la
pista de arriba (la primera pista del proyecto, cuando están en pistas distintas) es la
**referencia**, como en *Groove Match* y en *Sincronizar otros ítems* (abajo). Los ítems
MIDI se ignoran.

- **Warp**: no hay ítem de referencia, la referencia es el tempo del proyecto. Cada ítem se
  analiza y recibe el warp según sus propios pulsos, sobre la cuadrícula del proyecto; así,
  una canción y un loop grabados a tempos distintos quedan los dos al BPM del proyecto,
  juntos.
- **Mapa de tempo**: el ítem de referencia crea el mapa de tempo, y todos los demás ítems
  seleccionados reciben el warp hacia ese mapa; así toman el tempo de la referencia, con
  sus aceleraciones y desaceleraciones. Ejemplo: en un remix, ponga la canción en la pista
  de arriba y un loop (batería, una línea de bajo) en una pista de abajo, deje el loop
  cerca del compás donde debe empezar, seleccione los dos y ejecute *Mapa de tempo*: el
  tempo del proyecto sigue la canción, y el loop la sigue compás a compás.
- **Groove Match**: el ítem de referencia y el tempo del proyecto no cambian; los demás
  ítems siguen los pulsos de la referencia.
- **Fixed project tempo from item** usa solo el primer ítem seleccionado.

**Canción y loop: ¿Mapa de tempo o Groove Match?** En los dos casos el loop pasa a seguir
el tempo de la canción, pulso a pulso. La diferencia está en la cuadrícula del proyecto:

- Con *Mapa de tempo*, el tempo del proyecto (metrónomo, cuadrícula, MIDI, nuevas
  grabaciones) también sigue la canción, así que todo lo que se añada después queda a
  tempo con la canción y el loop. Es la opción habitual para un remix o para añadir
  instrumentos a una grabación.
- Con *Groove Match*, solo el loop sigue la canción; el tempo del proyecto queda como
  estaba. Úselo cuando el proyecto ya tiene un tempo que no debe cambiar (por ejemplo otras
  canciones en el mismo proyecto), y el loop solo tiene que encajar en la canción.
- Con *Warp* (seleccionando los dos), es al revés: la canción se estira al tempo fijo del
  proyecto, y el loop también.

Con *Un stretch marker cada N pulsos* en 0 (automático), cada ítem solo recibe marcadores
donde su tempo se aleja de la referencia (la cuadrícula del proyecto, o el mapa de tempo
creado por el ítem de referencia), dentro de la tolerancia de *Marcadores automáticos*.

Grabaciones multipista: con *Sincronizar otros ítems* en 1 en los ajustes, el warp o el mapa
de tempo aplicado a un ítem (por ejemplo la batería) se aplica de la misma manera a los
ítems agrupados con él (selecciónelos y pulse Ctrl+G, *Group items*), y toda la banda sigue
junta; 2 incluye todos los ítems de audio desbloqueados en la misma zona, sin los ítems MIDI (para que
una parte MIDI o la referencia de una cuantización quede en la cuadrícula del proyecto); 3
incluye todos los ítems desbloqueados, también los MIDI. Por defecto (0), solo
cambian los ítems seleccionados.

Para un loop, o una canción con tempo estable, **Fixed project tempo from item** (en el menú:
*Tempo del proyecto: el proyecto toma el BPM del ítem*) ajusta el proyecto al BPM del ítem,
como un tempo fijo, sin mapa de tempo: el ítem conserva su velocidad y se mueve (menos de
medio compás) para que su tiempo fuerte caiga sobre una línea de compás. El BPM se calcula
con todos los pulsos juntos (en un loop, con su duración, que es un número entero de
pulsos) y se redondea cuando queda a menos de 0,02 de un número entero. Si el proyecto
tiene marcadores de tempo en la zona del ítem, reawarp pregunta antes de eliminarlos; si el
tempo del ítem varía, el resultado lo avisa (una canción con tempo variable se sigue mejor
con *Mapa de tempo* o *Warp*).

Para que una canción con mapa de tempo suene más rápida o más lenta, use **Cambiar el
tempo de la canción**: el BPM del proyecto en REAPER solo cambia el tempo hasta el
siguiente marcador de tempo (aquí hay uno por pulso), así que esta acción pide un nuevo BPM
medio y escala todos los marcadores de la canción por el mismo factor, manteniendo cada uno
en su compás y su pulso. Con un ítem seleccionado cambia la zona de ese ítem; sin ninguno,
todo el proyecto. El ítem acompaña el cambio y conserva la afinación. Los demás ítems de esa
zona que recibieron el warp de reawarp (un loop, por ejemplo) reciben el warp de nuevo hacia
el nuevo tempo, y el inicio de un loop conserva su ataque.

### Cuantizar según un ítem MIDI

**Cuantizar** (*Quantize to MIDI item*) lleva los ataques de ítems de audio a las notas de un
ítem MIDI, que marca el ritmo: dibuje o grabe la figura que quiera (corcheas rectas, un
swing, un shuffle como la tarantela, o el groove de otra interpretación), en una pista de
arriba.

1. Primero haga que el audio siga el tempo del proyecto, con *Warp* o *Mapa de tempo* (la
   cuantización parte de que los pulsos están a tempo con la cuadrícula).
2. Seleccione el ítem MIDI (la referencia, en la pista de arriba) y uno o más ítems de audio.
3. Ejecute **Cuantizar**.

Cada nota corresponde a una posición de la cuadrícula recta, con el número de notas por
pulso más habitual en el ítem MIDI: con dos notas por pulso son corcheas, así que una nota a
2/3 del pulso (swing de tresillo) recibe el audio de la mitad del pulso, y una nota en el
pulso recibe el audio del pulso. El audio de ahí se fija en la nota con un stretch marker,
en su ataque cuando hay uno cerca; el audio de en medio (semicorcheas, por ejemplo) se
estira con él. Solo cuenta dónde empiezan las notas, no su duración. Las notas silenciadas
se ignoran; un ítem MIDI en bucle solo cuenta la primera vuelta. Fuera de las notas, el ítem
queda como estaba (con su warp, por ejemplo). Se pueden cuantizar varios ítems de audio a la
vez, y el mismo ítem MIDI sirve para otras canciones: con *Sincronizar otros ítems* en 2, el
warp no toca los ítems MIDI.

**Ajustes de la cuantización** (en el menú, o la acción *Quantize settings*):

| Campo | Por defecto | Notas |
|---|---|---|
| Fuerza en % | 75 | 100 pone cada ataque exactamente en su nota; 50 lo lleva a mitad de camino, conservando parte de la interpretación original y estirando menos |
| Buscar el ataque hasta N ms de la cuadrícula | 25 | Hasta dónde, alrededor de la posición de la cuadrícula recta, se busca el ataque del audio. 0 usa la propia posición de la cuadrícula |
| Sensibilidad en % | 50 | 100 acepta incluso los ataques más suaves (en una mezcla densa), 0 solo los muy claros. Donde no se acepta ningún ataque, se usa la propia posición de la cuadrícula |

Los valores por defecto son prudentes: el groove se nota bien, con menos artefactos de
estiramiento. Para una cuantización exacta y agresiva (el audio sigue al MIDI nota por
nota), use fuerza 100, 40 ms y sensibilidad 100.

Cada acción es un único paso de deshacer (Ctrl+Z).

## Ajustes

| Campo | Predeterminado | Notas |
|---|---|---|
| BPM mínimo / máximo | 60 / 180 | Rango de búsqueda del tempo |
| BPM aproximado | 0 | Si es > 0, busca cerca de este valor (corrige el tempo a la mitad o al doble) |
| Compás | auto | `auto` detecta 3/4 o 4/4; o escriba `3/4`, `6/8`, `5/4`... |
| Flexibilidad de tempo | 50 | 0 = tempo rígido (electrónica); 100 = muy libre (en vivo, rubato) |
| Un stretch marker cada N pulsos | 1 | Use 4 (uno por compás) para tener menos artefactos. 0 = automático: marcadores solo donde el tempo cambia (entre dos marcadores el audio se estira por igual; un pulso solo recibe un marcador cuando, sin él, algún pulso quedaría más lejos de la cuadrícula que la tolerancia). Una canción de tempo estable recibe pocos marcadores, una con rubato muchos. También vale para los marcadores del *Mapa de tempo* |
| Marcadores automáticos: tolerancia en ms | 10 | Con N = 0: cuánto (en ms) puede quedar un pulso fuera de la cuadrícula antes de recibir un marcador |
| Suavizar cuadrícula | 0 | -1 = ajusta un tempo constante; N = suaviza en ±N pulsos |
| Ajustar a transitorios | 1 | Mueve cada pulso al inicio del ataque más cercano (±30 ms) |
| Ajuste fino | 0 | Con Beat This!, 1 pone cada pulso en su primer ataque (hasta 12 ms) en lugar de solo corregir el desplazamiento medio; pruébelo cuando algunos pulsos suenen un poco tarde en pasajes densos |
| El ítem sigue los cambios de tempo | 1 | Base de tiempo del ítem después del warp |
| Cambiar compás del proyecto | 1 | En el warp, si los compases difieren: 0 = nunca, 1 = preguntar, 2 = siempre |
| Sincronizar otros ítems | 0 | En el warp/mapa de tempo: 0 = no, 1 = ítems agrupados con el seleccionado, 2 = todos los ítems de audio desbloqueados superpuestos, 3 = todos los ítems desbloqueados superpuestos, MIDI incluido |
| Detector de pulsos | auto | `auto` (o `beat_this`) usa Beat This!; `builtin` usa el detector integrado, menos fiable |
| Progreso visual | auto | Una ayuda emergente (tooltip) junto al ratón muestra la etapa y el tiempo transcurrido mientras se ejecuta una acción. `auto` la muestra solo sin OSARA (los lectores de pantalla pueden leer cada actualización); `on` u `off` |
| Idioma | auto | `auto`, `en`, `pt-BR` o `es`. `auto` usa el paquete de idioma de REAPER o, si no hay, el idioma del sistema |

## Traducciones

Todos los mensajes están en la tabla `STRINGS`, al inicio de la sección 2 de `reawarp.lua`.
El inglés (`STRINGS.en`) es la referencia. Para agregar un idioma, copie esa tabla con un
código nuevo (por ejemplo `STRINGS["fr"]`), traduzca los valores (manteniendo cada `%s`,
`%d`, `%.2f`... en el mismo orden) y, para la detección automática, agregue el idioma en
`detect_lang`. El usuario también puede elegirlo escribiendo su código en el ajuste
*Idioma*. Las claves que falten en una traducción usan el inglés. Los nombres de los campos
de los ajustes no pueden tener comas (el diálogo de REAPER las usa como separador).

## Cómo funciona

La primera sección de `reawarp.lua` (independiente de REAPER):

1. El audio se mezcla en mono (todos sus canales, así que los ítems multicanal también
   funcionan), se lee a 11025 Hz y se divide en 4 bandas (graves, medios graves, medios,
   agudos). El flujo de la energía logarítmica entre cuadros de 11,6 ms da la curva de
   intensidad de los ataques.
2. Tempo global por autocorrelación, con preferencia alrededor de 120 BPM (o de su
   indicación).
3. Curva de tempo local (ventanas de 8 s) que sigue los accelerandos y las derivas.
4. Seguimiento de pulsos por programación dinámica (Ellis, 2007) con el período local.
5. Cada pulso se ajusta al inicio del transitorio más cercano, con una precisión de ~1 ms.
6. Compás: los patrones rítmicos de cada banda en cada pulso se repiten en cada compás; se
   compara la correlación con desfases de 3/9 y 4/8 pulsos.
7. El tiempo fuerte se estima por los acentos del bajo (bombo), en escala logarítmica y
   lineal (para distinguir el bombo fuerte del pulso 1 del más suave del pulso 3).

Con Beat This! instalado, `backend/reawarp_beat_this.py` reemplaza los pasos 2 a 7:
devuelve pulsos y tiempos fuertes, refinados por debajo de los cuadros de 20 ms del modelo
interpolando el pico de su salida. reawarp elige entonces el nivel métrico más cercano a su
propia estimación de tempo, reduce o completa los tramos en que el detector pasa por un
momento a corcheas o se salta pulsos (usando como referencia la curva de tempo local del
paso 3), y toma el compás y la fase del compás de los tiempos fuertes.

## Pruebas

```
pip install lupa numpy
python tests/test_dsp.py            # señales sintéticas: estable, rampa, deriva, 3/4
python tests/test_dsp.py song.mp3   # analiza un archivo (necesita ffmpeg en el PATH)
python tests/test_core.py           # acciones completas contra un REAPER simulado
```

`tests/reaper_run.lua` ejecuta las acciones en REAPER de verdad, en una pestaña de proyecto
aparte, y vuelve a analizar el audio procesado para medir a qué distancia de la cuadrícula
quedan los pulsos. Lo llama un script corto que define `RW_MAIN`, `RW_OUT`, `RW_RPP` y
`RW_CASES` (vea el encabezado del archivo) y que se envía a la instancia abierta con
`reaper.exe -nonewinst script.lua`.

## Limitaciones conocidas

- La detección del tiempo fuerte es heurística (bombo); use *Fijar el tiempo fuerte en el
  cursor de edición* cuando sea incorrecta.
- Las introducciones sin un pulso claro (rubato, un solo instrumento, una anacrusa larga)
  pueden tener los primeros pulsos mal ubicados, sobre todo con el detector integrado.
  Revise los primeros marcadores `RW` y mueva o borre los incorrectos antes del warp.
- No se detectan los cambios de compás dentro de una canción.
- La detección automática distingue compás binario (2/4, 4/4) de ternario (3/4); los
  compases compuestos o irregulares (6/8, 5/4, 7/8) se deben indicar en los ajustes.

## Cómo contribuir

reawarp para REAPER pretende ser un warp tan bueno como parece. Si le está ayudando de
alguna forma en su proyecto, considere contribuir:

- **Reportes de errores y sugerencias**: abra un
  [issue](https://github.com/gabrielschuck/reawarp/issues). Para una canción que se detecta
  o se ajusta mal, indique qué acción ejecutó, los ajustes, qué esperaba y qué pasó (el
  compás y el pulso ayudan mucho). Puede escribir en español.
- **Código**: haga un fork del repositorio y abra un pull request. Ejecute las pruebas
  offline (vea [Pruebas](#pruebas)) y mantenga la interfaz accesible: solo los menús y
  diálogos nativos de REAPER, y mensajes por OSARA cuando esté disponible.
- **Traducciones**: agregue una tabla en `STRINGS` en `reawarp.lua` (vea
  [Traducciones](#traducciones)).
- **Donaciones**: si reawarp le resulta útil, puede apoyar su desarrollo por PayPal o Pix
  (Brasil) a **gabrielschuck.tecladista@gmail.com**. ¡Gracias!

## Licencia

Copyright (C) 2026 Gabriel Schuck.

reawarp es software libre bajo la [GNU General Public License v3.0](LICENSE) o posterior.
Puede usarlo, estudiarlo, modificarlo y compartirlo; si distribuye una versión modificada,
también debe publicarla bajo la GPL con su código fuente, y debe conservar el aviso de
copyright original.

## Agradecimientos

- A [vrivrixd](https://github.com/vrivrixd), por la traducción al español.
- A [GianlucaApollaro](https://github.com/GianlucaApollaro), por el Groove Match, la
  navegación y edición de los marcadores de pulso, la sincronización multipista y el
  análisis multicanal.

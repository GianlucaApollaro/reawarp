# reawarp

*[Leia em português](README.pt-BR.md)*

> reawarp is still an experimental version: it has been tested on a
> number of real songs, but expect rough edges. Contributions, bug reports and suggestions
> are very welcome; see [Contributing](#contributing).
>
> Contact: gabrielschuck.tecladista@gmail.com

Audio warping for REAPER, in the spirit of Ableton Live's Warp: reawarp detects the beats
of a song (including songs whose tempo drifts or changes) and either

- **Warp**: fits the item to the project tempo (a stretch marker on each beat), or
- **Tempo map**: makes the project follow the song (a tempo marker on each beat).

Written in Lua; beats are detected by the neural detector
[Beat This!](https://github.com/CPJKU/beat_this), installed with one click (no Python
installation needed). The whole interface uses REAPER's native menus and dialogs, so it works with
screen readers (OSARA).

## Installation

**With ReaPack** (recommended: updates arrive by themselves):

1. In REAPER: *Extensions > ReaPack > Import repositories...* and paste
   `https://github.com/gabrielschuck/reawarp/raw/main/index.xml`
2. *Extensions > ReaPack > Browse packages*, search for **reawarp** and install it.
   All the actions appear in the Action List.

**Manually** (without ReaPack):

1. Download the ZIP of the latest version from
   [Releases](https://github.com/gabrielschuck/reawarp/releases) and extract the `reawarp`
   folder into REAPER's `Scripts` folder (*Options > Show REAPER resource path*).
2. In REAPER: *Actions > Show action list > New action > Load ReaScript...* and load
   `reawarp.lua`.
3. Run the `reawarp.lua` action once. It opens the menu and registers the individual
   actions in the Action List (you can cancel the menu afterwards).

Then install the Beat This! detector from the reawarp menu (see below). Optional: assign
shortcuts to the actions.

All the code is in `reawarp.lua`. REAPER maps each action to one file, so the individual
actions are two-line files in the `actions/` subfolder; they only call the matching
function in `reawarp.lua`. You never need to edit them, and they are recreated if deleted.

Moving from a manual installation to ReaPack: ReaPack installs into
`Scripts/reawarp/Tempo/`. To keep the Beat This! already installed, move the folders
`env`, `models`, `python` and `uv` from the old `backend` folder into the new one, then
delete the old `Scripts/reawarp/reawarp.lua` and `actions` (and remove their entries from
the Action List). Moving the folders breaks the Python environment's links, so then run
*Install the Beat This! detector...* from the reawarp menu once: it repairs the
environment in a few seconds and reuses what is already downloaded.

REAPER keeps responding while an action works: Beat This! runs in the background and the
analysis gives REAPER its window back many times a second, so you can keep moving around
the project (do not edit the item being analyzed). The result is announced through OSARA;
without OSARA it is shown in a window. Dialogs only appear when reawarp needs an answer
(time signature, removing a tempo map, a new BPM) and for the settings. Running the same
action again while it works cancels it (Undo reverts what it had already changed); starting
another reawarp action meanwhile only announces that it is still working. When an action starts,
OSARA announces that reawarp is processing; the analysis report is still shown in a
dialog, since it explains what to check next.

| Action List entry | What it does |
|---|---|
| `reawarp.lua` | Menu with every function |
| `reawarp - Analyze beats.lua` | Analyzes and creates beat markers (shows a report) |
| `reawarp - Warp item to project tempo.lua` | Item follows the project tempo |
| `reawarp - Tempo map from item.lua` | Project follows the item's tempo |
| `reawarp - Change song tempo.lua` | Changes the tempo of a song that has a tempo map |
| `reawarp - Double BPM.lua` | Doubles the BPM: of the project after a tempo map, of the song after a warp |
| `reawarp - Halve BPM.lua` | Halves the BPM: of the project after a tempo map, of the song after a warp |
| `reawarp - Set downbeat at edit cursor.lua` | Makes the beat nearest the edit cursor beat 1 |
| `reawarp - Restore original items.lua` | Returns items to their state before reawarp |
| `reawarp - Settings.lua` | Settings |

### Beat This! detector (required)

[Beat This!](https://github.com/CPJKU/beat_this) (CPJKU, ISMIR 2024) is a neural beat and
downbeat tracker. reawarp needs it: the first analysis without it asks to install it.

reawarp also has a built-in detector (pure Lua), but it is not reliable enough to be the
default. Benchmarked against Beat This! on 47 songs of many genres, it agreed on about 75%
of them; it fails where the strongest attacks are off the beat (reggae, samba, hip-hop, rock
with offbeat guitar) and where there is no clear kick/snare (ballads). About 25 variants of
its onset sensitivity, band weighting and tracking did not change that. It is still
available for those who cannot install Beat This!: choose `builtin` as the *Beat detector* in
the settings. If Beat This! is installed but fails, reawarp stops with
an error instead of silently using the built-in detector; running the installer again
repairs it.

- Requirements: an internet connection during the installation. No Python installation
  is needed: the installer downloads [uv](https://github.com/astral-sh/uv), which brings
  its own private Python, never touching a Python already on the computer.
- Install: in the reawarp menu choose *Install the Beat This! detector*, or run
  `backend/install_beat_this.bat` (Windows) or `backend/install_beat_this.sh` (macOS /
  Linux). It downloads about 350 MB and uses about 800 MB of disk, all inside `backend/`
  (`uv`, `python`, `env` and `models`). To uninstall, delete those four folders.
  On macOS / Linux the installer leaves nothing writable by everyone (folders 775,
  files 664), so REAPER's folder can be synced to the cloud (MEGA and others refuse
  777); if an older install left 777 folders, run the installer again. Temporary files
  of the analysis go to `/tmp`, not to REAPER's folder.
- Analysis takes about 5 to 8 seconds per song instead of about 1.
- With an NVIDIA graphics card (Windows, Linux), the installer asks whether to install
  the GPU version: Beat This! runs about twice as fast (a 4-minute song: about 3 s
  instead of 6 s), but it downloads about 2.5 GB and uses about 3 GB of disk. It picks
  the CUDA version that the card's driver supports; if the GPU fails, reawarp uses the
  CPU. On a Mac with Apple silicon the standard version already uses the GPU. To switch
  between the versions, run the installer again and answer the question differently.
- Copy the `backend` folder next to `reawarp.lua` for this to work.

The warp does not pick a stretch algorithm: it uses the time stretch / pitch shift mode and
the stretch marker mode set on the item (item properties) or, when the item uses the
default, on the project (*Project settings*).

## Workflow

1. Select the item and run **Analyze beats**. Take markers `RW bar.beat` are created (red
   on beat 1). The report shows the BPM, its range, the detected time signature (3/4 or
   4/4) and the first downbeat. The warp aligns that downbeat with the bar line nearest to
   where the item is; to pick another bar, move the item close to it before warping.
2. Check the result. If needed:
   - **Half or double BPM** → run **Double BPM** or **Halve BPM**. They change the BPM of
     what follows: after a *Tempo map*, the project tempo (the song is untouched); after a
     *Warp*, the song's speed (the project tempo is untouched; e.g. a song detected at half
     tempo plays twice too fast, and *Halve BPM* brings it back). Beat 1 stays in place,
     and the tempo map or warp is applied again.
     Doubling uses the beats the detector actually found between the existing ones when
     it has them (Beat This!, or beats removed by *Halve BPM*), else the midpoints. You
     can also set *Approximate BPM* in the settings and analyze again.
   - **Wrong time signature** → set it in the settings (`3/4`, `4/4`, `6/8`, `12/8`...)
     and analyze again. Compound meters (6/8, 9/8, 12/8) count the dotted quarter as the
     beat; use them when the analysis reports a BPM 1.5× lower than expected.
   - **Wrong beat 1** → place the edit cursor on the correct beat 1 and run *Set downbeat
     at edit cursor*.
   - **A wrong beat** → move or delete that `RW` marker by hand. The markers are the grid
     the warp uses; reawarp does not recreate them if they exist.
3. Run **Warp** or **Tempo map**.
   - *Warp*: the song's downbeat goes to the bar line nearest to where it already is, and
     every beat (or every N beats) gets a stretch marker on the grid. The song then plays
     at the project BPM; to keep its original tempo, use *Tempo map*.
     If the item was never analyzed, it is analyzed first without showing a report.
     If the project has a varying tempo map where the item is (e.g. left over from a
     *Tempo map*), reawarp asks whether to remove it and use a fixed tempo; otherwise the
     warped song would follow that varying tempo.
     When everything works the warp opens no window (with OSARA it announces "Warp
     applied"); a dialog only appears to ask about the time signature or the tempo map.
     2/4, 4/4 and 2/2 are treated as equivalent (they cannot be told apart reliably from
     audio, and their bar lines coincide): a duple-meter song uses the project's signature.
     If the song's signature differs from the project's (e.g. 3/4 in a 4/4 project),
     reawarp asks whether to insert the song's signature at the start of the item (and
     restore the previous one after it) so that the bars match. The item keeps its time
     stretch and stretch marker modes and, by default, switches to the "beats (position,
     length, rate)" timebase so it stays in sync if the project tempo changes later.
   - *Tempo map*: the project tempo follows the song from before the music starts, so the
     intro, pickup beats and count-in are already at the song's tempo: from the project
     start when no tempo marker comes before the item, otherwise from the bar line where
     the item starts (earlier markers, e.g. of another song, are kept). The item is moved
     (by less than half a bar) so its downbeat falls on a bar line, and every beat,
     pickups included, gets a tempo marker. Afterwards the item follows later tempo
     changes like a warped item ("beats (position, length, rate)" timebase), or keeps its
     own timebase if *Item follows tempo changes* is 0. Existing tempo markers in the
     item's range are replaced.

To make a song with a tempo map faster or slower, use **Change song tempo**: REAPER's
project BPM only changes the tempo up to the next tempo marker (one per beat here), so this
action asks for a new average BPM and scales every marker of the song by the same factor,
keeping each on its bar and beat. With an item selected it changes that item's range;
with none, the whole project. The item follows with its pitch preserved.

Each action is a single undo step (Ctrl+Z).

## Settings

| Field | Default | Notes |
|---|---|---|
| Minimum / maximum BPM | 60 / 180 | Tempo search range |
| Approximate BPM | 0 | If > 0, searches near this value (fixes half/double tempo) |
| Time signature | auto | `auto` detects 3/4 or 4/4; or type `3/4`, `6/8`, `5/4`... |
| Tempo flexibility | 50 | 0 = rigid tempo (electronic); 100 = very loose (live, rubato) |
| Stretch marker every N beats | 1 | Use 4 (one per bar) for fewer artifacts |
| Smooth grid | 0 | -1 = fit one constant tempo; N = smooth over ±N beats |
| Snap to transients | 1 | Moves each beat to the start of the nearest attack (±30 ms) |
| Item follows tempo changes | 1 | Item timebase after the warp |
| Change project time sig | 1 | On warp, if the signatures differ: 0 = never, 1 = ask, 2 = always |
| Beat detector | auto | `auto` (or `beat_this`) uses Beat This!; `builtin` uses the less reliable built-in detector |
| Language | auto | `auto`, `en` or `pt-BR`. `auto` uses REAPER's language pack, or else the system language |

## Translations

All messages are in the `STRINGS` table near the top of section 2 of `reawarp.lua`.
English (`STRINGS.en`) is the reference. To add a language, copy that table under a new
code (for example `STRINGS["es"]`), translate the values (keep every `%s`, `%d`, `%.2f`...
in the same order) and, for automatic detection, add the language to `detect_lang`. Users
can also pick it by typing its code in the *Language* setting. Keys missing from a
translation fall back to English. Setting
captions must not contain commas (REAPER's input dialog uses them as separators).

## How it works

The first section of `reawarp.lua` (independent of REAPER):

1. Audio is read at 11025 Hz and split into 4 bands (low, low-mid, mid, high). The flux
   of log energy between 11.6 ms frames gives the onset strength curve.
2. Global tempo by autocorrelation, with a preference around 120 BPM (or your hint).
3. Local tempo curve (8 s windows) that follows accelerandos and drifts.
4. Beat tracking by dynamic programming (Ellis, 2007) using the local period.
5. Each beat is snapped to the start of the nearest transient, with ~1 ms precision.
6. Time signature: per-band rhythm patterns at each beat repeat every bar; correlation at
   lags of 3/9 and 4/8 beats is compared.
7. The downbeat is estimated from bass accents (kick), in log and linear scale (to tell
   the strong kick on beat 1 from the softer one on beat 3).

With Beat This! installed, `backend/reawarp_beat_this.py` replaces steps 2 to 7: it returns
beats and downbeats, refined below the model's 20 ms frames by interpolating the peak of
its output. reawarp then picks the metrical level closest to its own tempo estimate,
thins or fills stretches where the detector briefly switches to eighth notes or skips
beats (using the local tempo curve of step 3 as reference), and takes the time signature
and bar phase from the downbeats.

## Tests

```
pip install lupa numpy
python tests/test_dsp.py            # synthetic signals: steady, ramp, drift, 3/4
python tests/test_dsp.py song.mp3   # analyzes a file (needs ffmpeg on the PATH)
python tests/test_core.py           # full actions against a simulated REAPER
```

`tests/reaper_run.lua` runs the actions in real REAPER, in a separate project tab, and
re-analyzes the processed audio to measure how far the beats land from the grid. It is
called by a short script that sets `RW_MAIN`, `RW_OUT`, `RW_RPP` and `RW_CASES` (see the
file header) and is sent to the running instance with `reaper.exe -nonewinst script.lua`.

## Known limitations

- Downbeat detection is a heuristic (kick drum); use *Set downbeat at edit cursor* when it
  is wrong.
- Intros without a clear pulse (rubato, a single instrument, a long pickup) may get their
  first beats misplaced, mostly with the built-in detector. Check the first `RW` markers
  and move or delete the wrong ones before warping.
- Time signature changes within a song are not detected.
- Automatic detection tells duple (2/4, 4/4) from triple (3/4) meter; compound or
  irregular meters (6/8, 5/4, 7/8) must be set in the settings.

## Contributing

reawarp is a work in progress and contributions are welcome:

- **Bug reports and suggestions**: open an
  [issue](https://github.com/gabrielschuck/reawarp/issues). For a song that is detected
  or warped wrongly, say which action you ran, the settings, what you expected and what
  happened (bar and beat help a lot).
- **Code**: fork the repository and open a pull request. Please run the offline tests
  (see [Tests](#tests)) and keep the interface accessible: REAPER's native menus and
  dialogs only, messages through OSARA when available.
- **Translations**: add a table to `STRINGS` in `reawarp.lua` (see
  [Translations](#translations)).
- **Donations**: if reawarp is useful to you, you can support its development through
  PayPal or Pix (Brazil) to **gabrielschuck.tecladista@gmail.com**. Thank you!

## License

Copyright (C) 2026 Gabriel Schuck.

reawarp is free software under the [GNU General Public License v3.0](LICENSE) or later.
You may use, study, modify and share it; if you distribute a modified version, it must
also be released under the GPL with its source code, and the original copyright notice
must be kept.

# SecondsUp

Natywna aplikacja macOS do tworzenia filmow w stylu **One Second Everyday**:
od wyboru najlepszej sekundy z kazdego nagrania po gotowy, zmontowany film
z muzyka, tytulem i data w rogu.

## Zakladka Wycinanie

1. Wybierz folder z filmami (`.mov`, `.mp4`, `.m4v`) i folder eksportu.
2. Aplikacja analizuje filmy w tle i dla kazdego proponuje **top 3-5 kandydatow**
   na najlepsza sekunde (miniaturki pod playerem).
3. Algorytm ocenia okna 1 s na gestej siatce: ostrosc, ekspozycje, kontrast,
   nasycenie (normalizowane percentylowo w obrebie filmu), **twarze i saliency
   (Vision)**, stabilnosc ruchu z kara za ciecia sceny oraz energie dzwieku.
4. Os czasu z **waveformem audio** — klikasz/przeciagasz po wykresie glosnosci,
   widzac od razu smiech czy mowe; znaczniki pokazuja keyframe'y i kandydatow.
5. Eksport **smart cut**: start na keyframe → bezstratny `-c copy`;
   start poza keyframe → precyzyjny re-encode co do klatki (libx264 CRF 16).
   Etykieta przy eksporcie pokazuje, ktory tryb zostanie uzyty.
6. `Eksportuj wszystkie` robi cala robote wsadowo wg rekomendacji.

Wyniki analizy sa cache'owane (`~/Library/Caches/SecondsUp`) — powrot do
filmu jest natychmiastowy.

Skroty: `←`/`→` klatka, `⇧←`/`⇧→` ±0.5 s, `spacja` podglad 1 s,
`⌘R` rekomendacja, `⌘E` eksport.

## Zakladka Montaz

1. Wybierz folder z wycietymi sekundami (podpowiadany jest folder eksportu).
2. Klipy sortuja sie chronologicznie po dacie z nazwy pliku; checkbox
   wlacza/wylacza klip, kolejnosc zmieniasz przeciaganiem.
3. Opcje: plansza tytulowa, **napis z data z nazwy pliku** (np. `2026-06-05.mov`
   → `2026-06-05`, domyslnie prawy dolny rog), muzyka z regulacja glosnosci
   i fade-out, zachowanie dzwieku klipow, rozdzielczosc (4K/1080p/720p/kwadrat/pion) i fps.
4. `Renderuj film`: normalizacja klipow → napisy → concat → muzyka → walidacja,
   z paskiem postepu i mozliwoscia przerwania.

Ustawienia projektu (kolejnosc, wykluczenia, muzyka, ...) zapisuja sie w
`.secondsup-project.json` w folderze klipow.

## Wymagania

- macOS 13 albo nowszy.
- Lokalny `ffmpeg` i `ffprobe`, np. z Homebrew (analiza dziala natywnie,
  ffmpeg jest potrzebny do eksportu i montazu).

## Budowanie

```bash
./build_app.sh          # dist/SecondsUp.app
swift run               # uruchomienie bez pakowania
```

## Testy headless

```bash
# analiza (kandydaci, waveform, czasy)
SecondsUp --self-test-export --analyze --source film.mov

# eksport 1 s (smart cut)
SecondsUp --self-test-export --source film.mov --output ./out --start 2.0

# montaz calego folderu
SecondsUp --self-test-export --montage --folder ./out --output final.mp4 --music muzyka.m4a
```

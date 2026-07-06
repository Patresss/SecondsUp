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
5. Eksport ma jawny **tryb ciecia**:
   - `Tylko bezstratnie` (domyslnie): rekomendacje sa liczone tylko od keyframe'ow,
     wiec wybrana sekunda jest realnie eksportowalna przez `-c copy` bez przesuwania startu;
   - `Auto precyzyjnie`: keyframe → bezstratnie, poza keyframe → krotki re-encode
     co do klatki (libx264 CRF 16).
   Etykieta przy eksporcie pokazuje, ktory tryb zostanie uzyty.
6. `Eksportuj wszystkie` robi cala robote wsadowo wg rekomendacji.

Wyniki analizy sa cache'owane (`~/Library/Caches/SecondsUp`) — powrot do
filmu jest natychmiastowy.

Skroty: `←`/`→` klatka, `⇧←`/`⇧→` ±0.5 s, `spacja` podglad 1 s,
`⌘R` rekomendacja, `⌘E` eksport.

## Zakladka Naprawa

Klipy zebrane przez caly rok bywaja niejednorodne (inny kodek, rozdzielczosc,
fps, kolor, audio) — a to psuje bezstratne sklejanie: przyciecia i zwolnione
tempo na granicach klipow. Zakladka Naprawa:

1. Analizuje wszystkie klipy w folderze i wyznacza **wzorzec** (najczestszy format).
2. Pokazuje, ktore klipy odstaja i czym.
3. `Napraw` dopasowuje odstajace klipy wysoka jakoscia (libx265/libx264 CRF 14,
   konwersja fps przez duplikacje klatek, kolory przez zscale, audio i timescale
   sciezki do spec wzorca). Oryginaly laduja w podfolderze `_oryginaly/`.

Po naprawie folder skleja sie czysto w kazdym trybie.

## Zakladka Montaz

1. Wybierz folder z wycietymi sekundami (podpowiadany jest folder eksportu).
2. Klipy sortuja sie chronologicznie po dacie z nazwy pliku; checkbox
   wlacza/wylacza klip, kolejnosc zmieniasz przeciaganiem.
3. Podglad moze odtwarzac pojedynczy klip albo caly film — ten drugi jako
   przewijalna kompozycja bez renderowania (suwak dziala jak w gotowym pliku,
   napis daty podaza za czasem).
4. Opcje: dokladna dlugosc klipu (domyslnie 1.00 s), opcjonalna normalizacja
   glosnosci klipow (EBU R128, -16 LUFS — koncert obok szeptu przestaje
   strzelac glosnoscia), plansza tytulowa i koncowa, **napis z data z nazwy pliku** w wielu formatach, wybor fontu,
   muzyka z regulacja glosnosci i fade-out, zachowanie dzwieku klipow,
   rozdzielczosc (4K/1080p/720p/kwadrat/pion) i fps.
5. Tryby renderu:
   - `Premium HDR` (zalecany do ogladania): HEVC 10-bit z zachowanym HDR
     (HLG/BT.2020) i wysokim bitrate — jakosc wizualnie jak oryginal
     z iPhone'a, z napisami, planszami i muzyka; jeden format w sciezce,
     wiec gra wszedzie (QuickTime, TV, AirPlay);
   - `H.264`: uniwersalny MP4 (SDR 8-bit), obraz jest renderowany ponownie;
   - `ProRes HQ`: bardzo wysoka jakosc do archiwum lub dalszego montazu,
     z napisami, planszami i muzyka;
   - `Bezstratnie smart`: klipy zgodne z najczestsza sygnatura (kodek,
     rozdzielczosc, pix_fmt, kolor, audio) sa kopiowane bit-w-bit; tylko
     odstajace sa dopasowywane re-encode'em (libx265/libx264 CRF 14,
     konwersja kolorow zscale, audio do spec wzorca). Wynik przechodzi
     walidacje czystego dekodowania, zeby nie zapisac filmu z uszkodzonym
     strumieniem HEVC.
   - `Bezstratnie copy`: prawdziwe sklejanie bez rekompresji, ale bez napisow,
     plansz, muzyki, zmiany rozdzielczosci i zmiany fps. Wymaga identycznych
     parametrow wszystkich klipow (kodek, rozdzielczosc, kolor) — aplikacja
     sprawdza to przed renderem i po renderze weryfikuje dekodowanie. Przy
     problemach uzyj `ProRes HQ` albo `H.264`.

   UWAGA (tryby bezstratne): gdy w folderze sa klipy z roznych enkoderow
   (np. naprawione klipy x265 wsrod nagran z iPhone'a), wynik ma wiecej niz
   jeden opis formatu w sciezce (multi-stsd). To poprawna struktura QuickTime
   — ffmpeg, VLC i silnik IINA graja ja idealnie — ale sama aplikacja
   QuickTime Player potrafi pokazac blednie czas i zwolnic odtwarzanie.
   Bezstratny plik traktuj jako archiwum i ogladaj w IINA/VLC; do ogladania
   w swiecie Apple i udostepniania renderuj `Premium HDR`.
6. `Renderuj film`: kazdy klip jest przycinany do ustawionej dlugosci,
   normalizacja klipow → napisy → concat → muzyka → walidacja, z paskiem
   postepu i mozliwoscia przerwania.

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
SecondsUp --self-test-export --montage --folder ./out --output final.mp4 --music muzyka.m4a --clip-duration 1.0

# naprawa (konformacja) klipow w folderze
SecondsUp --self-test-export --repair --folder ./out
```

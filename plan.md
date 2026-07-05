# SecondsUp — plan rozwoju

Aplikacja docelowo sklada sie z dwoch krokow:

1. **Wycinanie** — wybor i eksport najlepszej 1 sekundy z kazdego filmu (istnieje, do poprawy).
2. **Montaz** — sklejenie wycietych sekund w jeden film z muzyka, tytulem i data w rogu (do zbudowania).

---

## 1. Struktura aplikacji: zakladki

Glowne okno przechodzi na `TabView` (lub toolbar picker) z dwiema zakladkami:

```
┌──────────────────────────────────────────────┐
│  [ ✂ Wycinanie ]  [ 🎬 Montaz ]              │
├──────────────────────────────────────────────┤
│                                              │
│   zawartosc aktywnej zakladki                │
│                                              │
└──────────────────────────────────────────────┘
```

Refaktor struktury katalogow (bez zmiany logiki):

```
Sources/SecondsUp/
  App/        SecondsUpApp.swift, MainView.swift (TabView)
  Extract/    ExtractModel.swift (dzis AppModel), ExtractView.swift (dzis ContentView),
              PlayerView.swift, VideoModels.swift
  Montage/    MontageModel.swift, MontageView.swift, MontageService.swift
  Shared/     FFmpegRunner.swift (run/probe wydzielone z MediaService),
              DateParser.swift, AnalysisCache.swift
```

Folder eksportu z kroku 1 staje sie naturalnym folderem wejsciowym kroku 2 —
aplikacja proponuje go automatycznie po przejsciu na zakladke Montaz.
Ostatnio uzyte foldery zapamietywane w `UserDefaults`.

---

## 2. Krok 1 — Wycinanie: analiza obecnego algorytmu i poprawki

### 2.1. Zdiagnozowane slabosci (MediaService.swift)

| # | Problem | Gdzie | Skutek |
|---|---------|-------|--------|
| P1 | **Kandydaci tylko z keyframe'ow**, max 8, rozrzedzone rownomiernie | `recommendStart` + `limitedCandidates` | Najlepszy moment miedzy keyframe'ami jest niewidzialny; w telefonach GOP bywa 1–2 s, wiec siatka kandydatow jest bardzo rzadka |
| P2 | **Ranking de facto na 1 klatce.** Quick pass ocenia 1 klatke (start+0.5 s), a pelna ocena 3 klatek dotyczy tylko zwyciezcy (`quick.prefix(1)`) — nie moze juz zmienic rankingu | `recommendStart` | Wybor jest szumny; jedna rozmyta/przeswietlona klatka dyskwalifikuje dobra sekunde i odwrotnie |
| P3 | **Cala dekompresja pliku na potrzeby probek.** `frameSamples` uzywa `select='eq(n,...)'` bez `-ss`, wiec ffmpeg dekoduje film od zera do konca | `frameSamples` | Dla dlugich nagran analiza trwa dziesiatki sekund |
| P4 | **Sztywne progi absolutne** (ekspozycja=118, kontrast/64, itd.) | `FrameAnalyzer.sample` | Sceny nocne, snieg, zachody slonca sa systematycznie karane, mimo ze to najlepsze momenty dnia |
| P5 | **Brak sygnalu semantycznego** — zero informacji o twarzach/ludziach/saliency | caly scoring | Dla dziennika 1SE twarze i ludzie to najwazniejsza tresc; algorytm woli ostra sciane od lekko poruszonego usmiechu |
| P6 | **Motion score marginalny i zgrubny** (waga 0.12, roznica lumy klatek co 0.3 s); brak wykrywania ciecia sceny wewnatrz sekundy | `scoreSamples` | Sekunda moze zawierac cut/gwaltowny ruch kamery i wciaz wygrac |
| P7 | **Jedna rekomendacja bez alternatyw** | `Recommendation` | Uzytkownik nie widzi „drugiego wyboru"; poprawianie suwakiem od zera |
| P8 | **UI klamie o precyzji.** Suwak i przyciski ±1 klatka sugeruja dokladnosc co do klatki, ale eksport `-c copy` tnie na granicach pakietow — start poza keyframe'em daje zepsute/zamrozone pierwsze klatki | `exportLosslessSecond` vs `AppModel.stepForward` | Uzytkownik ustawia idealna klatke, a dostaje klip zaczynajacy sie gdzie indziej albo z artefaktami |
| P9 | **Brak cache** — powrot do pliku liczy wszystko od nowa | `loadMetadataAndRecommendation` | Zbedne czekanie przy przegladaniu folderu |

### 2.2. Algorytm v2 — projekt

Zasada: **oceniaj cale okna 1 s na gestej siatce, normalizuj wzgledem tego filmu,
dodaj sygnal semantyczny, zwracaj top-N**.

**Faza 0 — metadane i keyframe'y** (jak dzis, ffprobe; keyframe'y potrzebne do
trybu bezstratnego i znacznikow na osi czasu).

**Faza 1 — szybki skan calego filmu.**
Probkuj klatki co ~0.4 s na calej dlugosci (~250 klatek dla 100 s filmu przy 320 px szerokosci).
Zamiast rury PNG z ffmpeg — **`AVAssetImageGenerator`** (natywny, sprzetowy, random access,
`generateCGImagesAsynchronously` dla calej listy czasow). To usuwa P3 i zalezy tylko od AVFoundation.
Dla kazdej klatki policz:

- metryki techniczne jak dzis: ostrosc (Laplace), ekspozycja, kontrast, nasycenie, clipping,
- **Vision.framework** (natywne, darmowe, offline):
  - `VNDetectFaceRectanglesRequest` → liczba i wielkosc twarzy (+ `VNDetectFaceCaptureQualityRequest` jako jakosc twarzy),
  - `VNGenerateAttentionBasedSaliencyImageRequest` → czy kadr ma wyrazny obiekt uwagi (srednia energia saliency).

**Faza 2 — scoring okien 1 s.**
Kandydatem jest kazdy start `t` na siatce co 0.2 s (`0 ≤ t ≤ duration − 1`).
Ocena okna `[t, t+1]` agreguje klatki z fazy 1 wpadajace do okna (2–3 klatki):

```
window_score = 0.40 · image_q      // srednia metryk technicznych (po normalizacji, patrz nizej)
             + 0.25 · face_q       // bonus za twarze: max(face_area·quality) w oknie
             + 0.15 · saliency_q   // wyrazny podmiot kadru
             + 0.20 · motion_q     // stabilnosc: kara za |diff| ~ 0 (stopklatka) i za diff duzy (szarpanie/cut)
- twarda kara, jesli w oknie wykryto ciecie sceny (luma diff sasiednich probek > prog)
```

**Normalizacja wzgledna (usuwa P4):** kazda metryke przeksztalcamy na percentyl
w obrebie tego filmu (rank / liczba probek). Szukamy najlepszej sekundy *tego* nagrania,
a nie sekundy „ladnej absolutnie" — film nocny tez ma swoja najlepsza sekunde.
Wagi trzymamy w jednym structu `ScoringWeights` z wartosciami domyslnymi — latwo stroic.

**Faza 3 — doprecyzowanie top-N.**
Wez 5 najlepszych okien z tlumieniem sasiadow (non-max suppression: kolejne okno musi byc
oddalone ≥ 1.5 s od juz wybranych). Dla kazdego dosampluj 5 klatek (co 0.2 s wewnatrz okna),
przelicz pelny score i wygeneruj miniaturke. Wynik:

```swift
struct Recommendation {          // rozszerzenie istniejacego modelu
    let candidates: [Candidate]  // posortowane, top 3–5
}
struct Candidate {
    let start: Double
    let score: Double
    let reason: String           // jak dzis: sharp/exposure/faces/motion
    let thumbnail: CGImage?
    let nearestKeyframe: Double  // do trybu bezstratnego
}
```

**UI:** pod playerem pasek 3–5 miniaturek-kandydatow; klikniecie ustawia start.
Na `RangeTimeline` dodatkowo znaczniki keyframe'ow (male kreski), zeby bylo widac,
gdzie mozliwe jest ciecie bezstratne.

### 2.3. Os czasu z waveformem audio

`RangeTimeline` zostaje rozbudowana o **wykres glosnosci pod suwakiem** — smiech,
mowa czy brawa widac na waveformie od razu, co bardzo ulatwia wybor sekundy:

```
┌──────────────────────────────────────────────────┐
│      ▂▃▂▁▁▂▅▇▆▃▂▁▁▁▂▃▆█▇▅▃▂▁▁▂▂▃▂▁▁▁▂▄▅▃▂▁       │  ← waveform (RMS)
│  |     |      |   ▓▓▓ |        |       |         │  ← keyframe'y + zaznaczona 1 s
└──────────────────────────────────────────────────┘
```

- **Dane:** dekodowanie sciezki audio przez `AVAssetReader` (natywnie, bez ffmpeg) do PCM,
  redukcja do ~600–1000 slupkow RMS (jeden slupek = `duration / liczba_pikseli`);
  liczone raz przy wyborze filmu, w tle, i trzymane w cache razem z analiza obrazu.
- **Rysowanie:** `Canvas` w SwiftUI (szybkie, bez widokow per slupek); slupki wysrodkowane
  pionowo, zaznaczone okno 1 s podswietlone, kandydaci top-N jako subtelne znaczniki.
- **Interakcja:** klikniecie/przeciagniecie po waveformie ustawia start (to samo co suwak);
  suwak moze wtedy zniknac — waveform staje sie glownym sposobem nawigacji.
- **Film bez audio:** waveform zastepuje pasek jednolity + informacja „brak dzwieku".
- **Bonus dla scoringu:** te same dane RMS to gotowy sygnal audio do rekomendacji
  (okna z wyrazna, ale nie przesterowana energia dzwieku dostaja bonus) — pkt 2.5.

### 2.4. Eksport: „smart cut" (usuwa P8)

Dwa tryby + automat (domyslny):

| Tryb | Kiedy | Jak |
|------|-------|-----|
| **Bezstratny** | start ≈ keyframe (± pol klatki) | `-c copy` jak dzis |
| **Precyzyjny** | start poza keyframe'em | re-encode 1 s klipu: `-ss` przed `-i` (szybki seek) + dokladny trim, `h264_videotoolbox`/`libx264 -crf 16`, audio copy jesli mozliwe |
| **Auto** (domyslny) | zawsze | wybiera jeden z powyzszych wg pozycji startu |

Re-encode 1-sekundowego klipu trwa ulamek sekundy, a i tak caly montaz w kroku 2
przechodzi przez re-encode — strata jakosci jest pomijalna, za to start jest
dokladnie tam, gdzie uzytkownik ustawil. Walidacja wyniku zostaje jak dzis.
W UI mala etykieta przy przycisku eksportu: „bezstratnie" / „precyzyjnie (re-encode)".

### 2.5. Pozostale usprawnienia kroku 1

- **Cache analizy (P9):** wynik fazy 1–3 zapisywany do JSON w `~/Library/Caches/SecondsUp/`
  kluczowany sciezka+rozmiarem+data modyfikacji pliku. Powrot do filmu = natychmiastowa rekomendacja.
- **Analiza w tle calego folderu:** po zeskanowaniu folderu licz rekomendacje kolejno dla
  wszystkich plikow (niski priorytet, `TaskGroup` z limitem 2), ikona ✨ na liscie gdy gotowe.
- **Tryb wsadowy:** przycisk „Eksportuj wszystkie wg rekomendacji" — dla calego folderu naraz;
  raport na koncu (ile OK / ile bledow).
- **Skroty klawiszowe:** ← / → klatka, ⇧← / ⇧→ ±0.5 s, spacja podglad 1 s, ⏎ eksport.
- (Opcjonalnie, pozniej) **Sygnal audio:** RMS/energia dzwieku jako dodatkowa waga —
  smiech i mowa to dobre sekundy; latwe do policzenia raz na caly plik (`astats`).

---

## 3. Krok 2 — Montaz

### 3.1. UI zakladki Montaz

```
┌───────────────┬──────────────────────────────────────┐
│ Klipy (lista) │  Podglad / ustawienia                │
│ ☑ 2026-06-01  │  ┌─────────────────────────────┐     │
│ ☑ 2026-06-02  │  │  player z podgladem klipu   │     │
│ ☐ 2026-06-03  │  │       (napis w rogu)        │     │
│ ☑ 2026-06-05  │  └─────────────────────────────┘     │
│  (miniaturki, │  Tytul:  [Czerwiec 2026    ] [2 s]   │
│   drag&drop   │  Napis daty: ☑  format [yyyy-MM-dd]  │
│   kolejnosc)  │  pozycja [prawy dolny ▾] rozmiar [..]│
│               │  Muzyka: [wybierz plik] vol [──●──]  │
│               │    ☑ fade out  ☐ zachowaj audio klipu│
│               │  Wyjscie: [1080p ▾] [30 fps ▾]       │
│               │            [ 🎬 Renderuj film ]      │
│               │            ▓▓▓▓▓░░░░░ 52%  klip 12/23│
└───────────────┴──────────────────────────────────────┘
```

- Zrodlo: wybor folderu (domyslnie folder eksportu z kroku 1).
- Klipy sortowane chronologicznie po dacie z nazwy pliku (`DateParser` — juz istnieje);
  sufiks spacji z `nextOutputURL` oznacza kolejne sekundy tego samego dnia i sortuje sie naturalnie.
- Checkbox = wlacz/wylacz klip; drag & drop zmienia kolejnosc (domyslnie chronologia).
- **Napis daty:** tekst = nazwa pliku bez rozszerzenia i bez sufiksu spacji
  (`2026-06-05.mov` → `2026-06-05`), domyslnie prawy dolny rog, konfigurowalny format/rozmiar/przezroczystosc.

### 3.2. Pipeline renderowania (MontageService, ffmpeg)

Etapy (kazdy raportuje postep — parsowanie `-progress pipe:1`):

1. **Normalizacja kazdego klipu** do plikow tymczasowych (scratch):
   `scale` + `pad` do docelowej rozdzielczosci (z zachowaniem proporcji, czarne pasy),
   ujednolicenie fps, `format=yuv420p`, `setsar=1`; audio do wspolnego formatu
   (albo wyciete, jesli muzyka zastepuje dzwiek).
2. **Napis daty:** w tym samym przebiegu `drawtext=text='2026-06-05':x=w-tw-24:y=h-th-24:
   fontsize=…:fontcolor=white:alpha=0.9:shadowx=1:shadowy=1` (fontfile z zasobow aplikacji,
   zeby nie zalezec od sciezek systemowych).
3. **Plansza tytulowa:** `lavfi color=black` + `drawtext` (tekst i czas trwania z ustawien) —
   generowana jako pierwszy klip.
4. **Konkatenacja:** demuxer `concat` po znormalizowanych plikach posrednich
   (odporniejsze niz jeden gigantyczny `filter_complex` przy dziesiatkach klipow).
5. **Muzyka:** `-i muzyka` + `afade=t=out` na koncu, `-shortest`;
   tryb „zachowaj audio klipow" → `amix` z regulacja glosnosci muzyki.
6. **Walidacja** wyniku (czas trwania ≈ suma klipow) — analogicznie do `validateClip`.

Dlaczego ffmpeg, a nie AVFoundation composition: ffmpeg juz jest wymaganiem aplikacji,
concat + drawtext + amix to jego naturalny teren, a pipeline jest deterministyczny
i latwy do zdiagnozowania (te same komendy da sie odpalic z terminala).

### 3.3. Ustawienia projektu

Struktura `MontageSettings` (Codable) zapisywana w folderze klipow jako
`.secondsup-project.json`: kolejnosc, wykluczenia, tytul, muzyka, format napisu, wyjscie.
Powrot do folderu przywraca caly stan montazu.

---

## 4. Kolejnosc prac (milestones)

| M | Zakres | Efekt |
|---|--------|-------|
| **M1** | Algorytm v2: AVAssetImageGenerator + Vision, scoring okien, normalizacja percentylowa, top-N kandydatow z miniaturkami, cache | Rekomendacje szybsze i trafniejsze, uzytkownik wybiera z 3–5 propozycji |
| **M2** | Os czasu z waveformem audio (AVAssetReader + Canvas), smart cut (auto: copy vs re-encode), znaczniki keyframe na osi, skroty klawiszowe | Wybor sekundy po dzwieku; eksport dokladnie tam, gdzie ustawiono start |
| **M3** | Refaktor na zakladki (App/Extract/Montage/Shared), zakladka Montaz: skan, sortowanie, miniaturki, checkbox, drag&drop | Szkielet kroku 2 |
| **M4** | Pipeline renderu: normalizacja → drawtext daty → concat → walidacja + pasek postepu | Pierwszy pelny film z datami |
| **M5** | Muzyka (fade, amix), plansza tytulowa, zapis ustawien projektu | Kompletny montaz 1SE |
| **M6** | Polish: analiza folderu w tle, tryb wsadowy eksportu, sygnal audio w scoringu | Jakosc zycia |

Kazdy milestone konczy sie dzialajaca aplikacja (`swift build` + test reczny na realnym folderze),
commit po kazdym milestone.

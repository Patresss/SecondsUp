# SecondsUp

Natywna aplikacja macOS do wyboru i bezstratnego eksportu jednej sekundy z plikow `.mov`, `.mp4` i `.m4v` — pod montaz w stylu One Second Everyday.

## Workflow

1. Wybierz folder z filmami.
2. Wybierz folder eksportu.
3. Kliknij film na liscie.
4. Aplikacja zasugeruje poczatek sekundy podobnym algorytmem jak skrypt: ostrosc, ekspozycja, kontrast, nasycenie i stabilnosc ruchu.
5. Popraw poczatek suwakiem albo przyciskami o jedna klatke.
6. Kliknij `Eksportuj 1s`.

Eksport jest wykonywany przez `ffmpeg -c copy`, bez rekompresji. Aplikacja waliduje wynik i usuwa nieudany plik, jesli wynik nie ma okolo jednej sekundy albo nie zgadza sie liczba klatek.

## Wymagania

- macOS 13 albo nowszy.
- Lokalny `ffmpeg` i `ffprobe`, np. z Homebrew.

## Budowanie

```bash
./build_app.sh
```

Gotowa aplikacja powstanie tutaj:

```text
dist/SecondsUp.app
```

Mozna tez uruchomic bez pakowania:

```bash
swift run
```

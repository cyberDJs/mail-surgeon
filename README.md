# Mail Surgeon

macOS aplikace pro bezpečnou analýzu, čištění, zálohu a migraci e-mailů.

## Stav

Toto je **Phase 0 scaffold**: běžící SwiftUI kostra, datový model, konektorové rozhraní, analyzátor a Keychain wrapper. Konektory jsou zatím placeholdery a nic nemažou ani neupravují.

## Plán MVP

1. MBOX + EML/EMLX import
2. Lokální index a hashování
3. Detekce přesných duplicit
4. Apple Mail export reader
5. IMAP reader/upload
6. Review queue a karanténa
7. Lokální AI klasifikace

## Spuštění

1. Nainstaluj Xcode 16 nebo novější.
2. Otevři `Package.swift` v Xcode.
3. Vyber schéma `MailSurgeon` a `My Mac`.
4. Spusť přes `Cmd+R`.

Cílová platforma: macOS 14+, Intel i Apple Silicon.

## Running the macOS application

Build the local macOS application bundle:

```bash
make app
```

Launch the foreground GUI application:

```bash
make run
```

`swift run MailSurgeon` is still useful for executable debugging, but `make run`
is the supported GUI launch method. It launches the generated bundle at
`.build/app/MailSurgeon.app`, which is a local build artifact and is not
committed to Git.

## Bezpečnostní zásady

- Výchozí režim je dry run.
- Hesla patří do Keychainu.
- Přímé čtení Apple Mail úložiště bude pouze read-only.
- Definitivní mazání nebude dostupné bez review a explicitního potvrzení.

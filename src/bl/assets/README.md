# Launcher font asset

`mono.ttf` is the launcher console's typeface: a subset of **JetBrains
Mono NL** (no-ligatures), Regular, cut down to printable ASCII
(U+0020-U+007E), 8828 bytes.

## What this is

The status console needs a fixed-pitch face. LÖVE ships no monospace
font, and none of Balatro's own fonts are fixed pitch. This subset
provides one in 8828 bytes that loads from savedata.

## How it was created

```
pyftsubset JetBrainsMonoNL-Regular.ttf \
    --unicodes=U+0020-007E --layout-features='' --no-hinting \
    --desubroutinize --output-file=src/bl/assets/mono.ttf
```

The file is covered by the runtime fingerprint (see `TRACKED` in
`src/bl/stamp.lua`), so a replaced font changes the reported build
identity.

## License

SIL Open Font License, Version 1.1. Copyright 2020 The JetBrains Mono
Project Authors (https://github.com/JetBrains/JetBrainsMono). The full
license text is in `OFL.txt` next to this file, and ships inside every
built save archive.

The subset is a Modified Version under the OFL: it is shipped as
`mono.ttf`, not under the Reserved Font Name, per condition 3. The OFL
permits redistribution, modification (including subsetting) and
bundling, provided the copyright notice and license are retained and the
font is not sold by itself.

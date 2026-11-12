# Bloom — logo og bruksguide

**Idé:** Seks lamellblader fra en kameraåpning snurrer seg til en blomst. Kamera og «bloom» i én form.

## Filer
| Mappe | Innhold |
|---|---|
| `svg/` | Masterfiler: `bloom-symbol-color.svg` (hovedmerke), `bloom-symbol.svg` (én farge), `bloom-symbol-small.svg` (versjon for ≤ 32 px, med bredere mellomrom), `bloom-wordmark.svg`, liggende og stående lockup (lys og mørk bakgrunn) |
| `ios/` | App-ikon i 1024 px: `light`, `dark`, `tinted` og `foreground` (transparent lag til Icon Composer) |
| `variants/` | Svart, hvit og indigo i én farge, kvadratisk, favicon, web-ikonsett (`favicon.ico`, `apple-touch-icon.png`, manifest) |
| `presentation/` | Presentasjon (HTML og PNG-slides) med mockups |
| `source/` | Python-generatoren. Geometrien er parametrisk (R=108, hull r=22, kuttsirkler ρ=58, mellomrom g=9, myke hjørner 4) |

## Farger
| | HEX | Rolle |
|---|---|---|
| Oransje | `#FF8A00` | blad |
| Gul | `#FFC400` | blad |
| Grønn | `#2FC96B` | blad |
| Cyan | `#1EB3F0` | blad |
| Indigo | `#5A5CF2` | blad og **merkevarefarge** (versjon i én farge, aksentfarge) |
| Rosa | `#FF3D7F` | blad |
| Blekk | `#1C1C1E` | ordmerket på lys bakgrunn (hvitt på mørk) |

Rekkefølgen på bladene er fast. Ikke bytt om fargene og ikke legg til gradienter. Glasseffekten kommer fra iOS 26 (Liquid Glass) og skal ikke tegnes inn.

## Regler
- **Frisone:** minst diameteren til hullet i midten × 2 rundt symbolet.
- **Minste størrelse:** 16 px for symbolet (bruk `bloom-symbol-small.svg` til og med 32 px). Lockupen skal være minst 96 px bred.
- **Bakgrunn:** hvit, lys grå, svart. På bilder og sterke farger brukes versjonen i én farge (hvit eller svart).
- **Ikke** roter, speilvend, strekk eller fjern blader, legg til skygger eller sett ordmerket med en annen skrift.

## App-ikon i Xcode (iOS 26)
Enklest: Assets → AppIcon → velg «Any, Dark, Tinted» og dra inn `ios/AppIcon-light-1024.png`, `-dark-` og `-tinted-`.
Med Icon Composer: lag en ny `.icon`, sett bakgrunnen til hvit og importer `svg/bloom-symbol-color.svg` (eller ett lag per blad, gruppene heter `blade-1…6`) som forgrunn, så får bladene Liquid Glass.

## Åpne punkter
- Varemerkesøk før lansering, særlig mot Googles gamle Picasa-logo (også en regnbue-blenderåpning, men med en annen form).
- Bladene bruker en avrundende kontur (stroke) i SVG-en. For plotter og brodering: «Outline Stroke + Unite» i et vektorprogram.
- Ordmerket er bygd av geometri (ingen fontlisens trengs).

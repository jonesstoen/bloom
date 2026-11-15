# Privacy Policy for Bloom

*Last updated: 15 November 2026* · [Norsk versjon nedenfor](#personvernerklæring-for-bloom)

Bloom is an iPhone app for viewing your photos on your own [Immich](https://immich.app) server.
It is an independent hobby project and is not affiliated with Immich.

## In short

Bloom collects no data. It talks only to the Immich server you sign in to. The developer receives
nothing from the app: no analytics, no crash reports, no advertising, no tracking and no
third-party SDKs.

## What Bloom sends, and where

- **To your Immich server only:** your API key and the requests needed to show your library
  (photos, videos, albums, people, places, memories, search). With **Allow Changes** on, also the
  changes you make: favorites, moving items to Recently Deleted and restoring them, creating
  albums and adding photos to them.
- **To Apple, for the map:** the Map screen uses Apple Maps. To draw the map, Apple receives the
  area you are looking at, as with any app that shows Apple Maps. Your photos and their locations
  are not sent to Apple; the pins are drawn on the device.
- **To apps you choose:** when you share a photo, the original file is passed to the app you pick
  in the iOS share sheet.

- **Backup (only if you turn it on):** photos and videos from the albums you choose are uploaded to
  your Immich server. iOS sends them in the background, also when Bloom is closed. While an upload
  runs, iOS keeps the request headers, which include your API key, in its own system storage until
  the upload has finished. They are not readable by other apps and never leave your iPhone except to
  your server.

Bloom never sends your API key anywhere except to your server. It refuses unencrypted http to
servers on the internet, asks before using unencrypted http on a local network, and never follows a
redirect to another server.

## What Bloom stores on your iPhone

- **Server address and API key**, in the iOS Keychain, on this device only (not in iCloud).
- **Cached thumbnails, previews and a list of your library**, so it opens quickly. They are
  protected while the iPhone is locked and deleted when you sign out.
- **Settings** such as the grid size and sort order.
- **Temporary copies of originals while you share them**, deleted afterwards.

Signing out removes the API key and the cached photos. Deleting the app removes everything.
Bloom reads the iPhone's own photo library only when you turn on Backup, and never changes or deletes
anything in it.

## Children

Bloom is not directed at children and collects no data from anyone.

## Changes and contact

Changes to this policy are published in this file in the
[Bloom repository](https://github.com/jonesstoen/bloom/blob/main/PRIVACY.md). Questions:
[open an issue](https://github.com/jonesstoen/bloom/issues).

---

# Personvernerklæring for Bloom

*Sist oppdatert: 15. november 2026*

Bloom er en iPhone-app for å se bildene dine på din egen [Immich](https://immich.app)-server.
Det er et uavhengig hobbyprosjekt og har ingen tilknytning til Immich.

## Kort fortalt

Bloom samler ikke inn noen data. Appen snakker bare med Immich-serveren du logger inn på. Utvikleren
får ingenting fra appen: ingen analyse, ingen krasjrapporter, ingen reklame, ingen sporing og ingen
tredjeparts-SDK-er.

## Hva Bloom sender, og hvor

- **Bare til Immich-serveren din:** API-nøkkelen og forespørslene som trengs for å vise biblioteket
  (bilder, videoer, album, personer, steder, minner, søk). Med **Tillat endringer** på, også
  endringene du gjør: favoritter, flytte til Nylig slettet og gjenopprette, lage album og legge
  bilder i dem.
- **Til Apple, for kartet:** kartskjermen bruker Apple Kart. For å tegne kartet får Apple vite
  hvilket område du ser på, som i alle apper som viser Apple Kart. Bildene dine og stedene deres
  sendes ikke til Apple; nålene tegnes på enheten.
- **Til apper du velger:** når du deler et bilde, sendes originalfilen til appen du velger i
  delingsarket i iOS.

- **Sikkerhetskopi (bare hvis du slår den på):** bilder og videoer fra albumene du velger, lastes opp
  til Immich-serveren din. iOS sender dem i bakgrunnen, også når Bloom er lukket. Mens en opplasting
  pågår, lagrer iOS forespørselens overskrifter, som inneholder API-nøkkelen din, i sin egen
  systemlagring til opplastingen er ferdig. Andre apper kan ikke lese dem, og de forlater aldri
  iPhonen unntatt til serveren din.

Bloom sender aldri API-nøkkelen andre steder enn til serveren din. Appen nekter ukryptert http til
servere på internett, spør før den bruker ukryptert http på et lokalt nettverk, og følger aldri en
videresending til en annen server.

## Hva Bloom lagrer på iPhonen

- **Serveradresse og API-nøkkel**, i nøkkelringen i iOS, bare på denne enheten (ikke i iCloud).
- **Miniatyrer, forhåndsvisninger og en oversikt over biblioteket**, slik at appen åpner raskt. De
  er beskyttet når iPhonen er låst, og slettes når du logger ut.
- **Innstillinger** som rutenettstørrelse og sortering.
- **Midlertidige kopier av originaler mens du deler dem**, som slettes etterpå.

Når du logger ut, fjernes API-nøkkelen og de lagrede bildene. Sletter du appen, forsvinner alt.
Bloom leser iPhonens eget bildebibliotek bare når du slår på Sikkerhetskopi, og endrer eller sletter
aldri noe i det.

## Barn

Bloom er ikke rettet mot barn og samler ikke inn data fra noen.

## Endringer og kontakt

Endringer i erklæringen publiseres i denne filen i
[Bloom-repoet](https://github.com/jonesstoen/bloom/blob/main/PRIVACY.md). Spørsmål:
[opprett en sak](https://github.com/jonesstoen/bloom/issues).

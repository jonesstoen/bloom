# Hidden photos (design)

Approved by the owner 2026-11-18.

## Why
Photos on iOS lets you hide a photo from the library and keeps it in a Hidden album behind Face ID.
The owner wants the same in Bloom. They have nothing in Immich's Archive today.

## Approach
Considered: (A) Immich's Archive (`visibility: archive`) presented as "Hidden" with a Face ID lock in
Bloom; (B) Immich's Locked folder (`visibility: locked`), which needs a PIN-unlocked *session*
(`POST /auth/session/unlock`). Bloom authenticates with an API key, which probably can't get elevated
access, so B may not work at all. Picked A. The lock is Bloom-only: on the web the photos are in Archive.
The owner agreed that "Archive" as a name is misleading, so Bloom calls it Hidden / Skjult.

## Goals
- "Hide" (`eye.slash`) in the viewer's More menu and in the Library selection menu. No confirmation
  (undoable). Requires Allow Changes like every write (`EditGuardedService`).
- The hidden photo disappears from the grid it was hidden from (Library, album, person, search...) at once.
- Collections → Other: the "Archive" row becomes "Hidden" (`eye.slash`), with a lock glyph while locked.
- Opening Hidden asks for Face ID / Touch ID / device passcode (`LAContext`,
  `.deviceOwnerAuthentication`). It locks again when the view is left or the app goes to the background.
- Inside Hidden: "Unhide" (`eye`) in the viewer's More menu and the selection menu; the photo leaves the
  Hidden grid at once.
- Footer/empty text in Hidden: "In Immich on the web, these photos are in Archive."
- Setting "Use Face ID for Hidden" (default on) next to Allow Changes in the account menu.
- All text through `tr()` with Norwegian.

## Non-goals
- Locked folder / PIN. Hiding from People and albums (to check: whether Immich lists archived photos
  there; report, don't build). Hiding in Memories beyond what the server already does.

## Anti-goals
- Never show Hidden content without passing authentication when the setting is on (also after
  backgrounding while inside it). A failed/cancelled authentication leaves the user on Collections.
- Hiding must never trash or delete.

## Decided
- Write: `PUT /assets/{id}` with `{"visibility": "archive"}` / `{"visibility": "timeline"}` via the
  existing raw-JSON PUT path (as `setFavorite`), followed by GET to confirm. Per-asset loop with partial
  failure handling like `setFavorites`.
- The app target needs `NSFaceIDUsageDescription` in its Info.plist (owner adds it in Xcode).
- When no authentication is available on the device (no passcode), Hidden opens without a lock.

## Left to the builder
How the grid removes hidden/unhidden assets (follow the trash path's local-edits + snapshot handling),
exact placement in menus, preview wiring with the mock service.

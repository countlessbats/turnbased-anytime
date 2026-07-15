# Toggle Turn-Based In Combat

A Pillars of Eternity 1 mod that lets you switch between **real-time-with-pause** and
**turn-based ("Tactical") combat** at runtime, from a keybind — **including mid-combat, both
directions.**

The base game ships both combat modes, but locks the choice in the options menu: the checkbox
greys out once you're in a session or in a fight. That lock is UI-only — the underlying mode is a
single live setting, so this mod just flips it whenever you want.

## What works

| Switch | When | Works |
|---|---|---|
| turn-based → real-time | any time, including mid-combat | ✅ |
| real-time → turn-based | out of combat | ✅ |
| real-time → turn-based | **mid-combat** | ✅ (the current fighters enroll into the turn order the next frame) |

Turning turn-based on mid-fight rides the game's own combat loop: every combatant self-enrolls
into the turn system exactly as if the fight had started that way. Turning it back off clears the
turn queue and real-time resumes. Your chosen mode saves with your game.

## The keybind is the game's own (default: `T`)

This mod doesn't add its own hotkey UI. Pillars already ships a first-class control for this —
Obsidian wired it up but left it dormant, with nothing polling it. This mod simply consumes it, so:

- **Default key is `T`** (the game's own default). Rebind it in **Options → Controls** (the
  camera/turn group, near *Pass Turn* / *Wait Turn*) like any other control — with real conflict
  detection and persistence.
- It works everywhere, **including in combat**.
- The little center-bottom HUD toggle button (which normally fades out during a fight) is kept
  visible and clickable too, found by function rather than fragile name-matching.

## Install

1. Close Pillars of Eternity.
2. Download the release zip and extract it anywhere.
3. Double-click **install.bat**. It auto-detects your install; if it can't find one, it asks you to
   paste the game folder — quotes are optional, and paths with spaces or parentheses are fine
   (e.g. `C:\Program Files (x86)\Steam\steamapps\common\Pillars of Eternity`).
4. Launch the game and press `T` in combat.

Needs only Windows PowerShell (built into Windows) — no .NET SDK or compiler.

## Uninstall

Double-click **uninstall.bat** (or run `install.ps1 -Uninstall`). It surgically removes **only**
this mod's hook and DLL — any other mods that patch the same method are left intact.

## Notes

- Sidecar DLL; **no game data files are edited**. No Harmony or other runtime dependencies — the
  only bundled file is Mono.Cecil (used once, by the installer, to inject the hook).
- Internal assembly name is `LoomToggleTurnBasedInCombat.dll` (the identifier the installer injects
  into `GameState.Update()`). Coexists with other mods that hook the same method.
- A one-time backup of `Assembly-CSharp.dll` is made next to it.
- Steam "Verify integrity of game files" will revert the hook (it restores `Assembly-CSharp.dll`);
  just re-run the installer if that happens.

## Build from source

`./build.ps1 -GameDir "<Pillars of Eternity folder>"` compiles `src/ToggleTurnBasedInCombat.cs` into
`LoomToggleTurnBasedInCombat.dll` against the game's assemblies. `patch-hook.ps1` is the developer
hook injector (the release installer does the same thing for end users).

## License

MIT — see [LICENSE](LICENSE). Contains only original mod code; no Obsidian game assets.

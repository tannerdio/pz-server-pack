# Project Zomboid 42.22.2 mod compatibility patches

You are being asked to apply a set of file edits to this machine's Project Zomboid Workshop mods so they are byte-identical to another player's install. The two players want to play together with the same mod files. Everything you need is in this folder.

## What this is and why

Project Zomboid updated to build 42.22.2. Several Project Viewpoint add-on mods have not been updated by their authors yet, so they were patched by hand on the other machine:

- **6 `mod.info` files (4 mods)** had `versionMax` capped at 42.21, so the game refused to load them. The only change is `versionMax=42.22.999`.
- **7 mod jars** call `zombie.util.list.PZArrayList`, a class 42.22 removed (`IsoGridSquare.getObjects()` now returns `java.util.List`). The jars were rewritten to use `java.util.List` through a small added helper class, `pzcompat/ListShim`.
- **Mvdox Grass** (`Mvdox-Grass-v1`, Workshop 3815166404) is switched off, because it crashes Viewpoint 0.1.6.2 at the main menu.

Added 2026-11-13, a new weapon pack:

- **Escape From Zomboid Firearms 1.1.6** (Workshop 3824755284, about 1.9 GB) and its required framework **Gunworks-gang** (Workshop 3722064198). Both are unmodified Workshop items: the user subscribes to them in Steam, nothing in them is patched.
- **EFZ x Viewpoint ADS compat** (`EFZAdsCompat`), a small local mod that makes Project Viewpoint ADS ignore the new pack's guns, because both mods were posing the arms at once. It ships in this folder.
- **Co-op Fast Forward** (`CoopFastForward`), a small local mod that lets any player fast forward time for everyone with the normal speed keys or a small on-screen bar. It ships in this folder.
- **Viewpoint cursor keep** (`VPCursorKeep`), a small local mod that stops Project Viewpoint QOL from re-locking the mouse (and resetting the cursor to screen centre) when a right-click menu closes while the inventory is still open. It ships in this folder.
- **Gun Swap** (`GunSwap`), a small local mod that runs on the server and turns the old guns, magazines, attachments and ammo already lying around the world into the new weapon pack's items. It ships in this folder; the files must be present on this machine too because the server checks them.
- **Attachments UI** (`AttachmentsUI`, Workshop 3816324722) is removed from the mod list. It took over the attachment menu of the new pack's guns and froze the host's game. The user can stay subscribed; it just must not be enabled.
- **True Ballistics** (`ViewpointTrueBallistics`) is switched off in the mod list. It disables itself on 42.22.2, and while it is enabled the new weapon pack turns its own ballistics off. Its patched jar stays in the manifest and should still be applied, so the files match.

## Contents of this folder

| Item | Purpose |
|---|---|
| `workshop\` | The 13 patched files, laid out exactly as they sit under `steamapps\workshop\content\108600\` |
| `manifest.json` | For each file: relative path, sha256 of the unpatched original, sha256 of the patched file |
| `local-mods\BaseKeeper\` | Base Keeper 0.19.0, the other player's own mod. It is not on the Workshop, so it ships here |
| `local-mods\EFZAdsCompat\` | EFZ x Viewpoint ADS compat 1.0.0, also the other player's own mod |
| `local-mods\CoopFastForward\` | Co-op Fast Forward 1.1.0, also the other player's own mod |
| `local-mods\VPCursorKeep\` | Viewpoint cursor keep 1.0.0, also the other player's own mod |
| `local-mods\GunSwap\` | Gun Swap 1.0.0, also the other player's own mod |
| `local-mods-manifest.json` | sha256 of every file under `local-mods\` |
| `default.txt` | The other player's enabled mod list (201 mods), from `%UserProfile%\Zomboid\mods\default.txt` |
| `pzfix.py`, `linkcheck.py` | The scripts that produced the jar patches. Reference and fallback only |

## Before you start

1. Project Zomboid must be closed.
2. Find the Workshop folder. The default is `C:\Program Files (x86)\Steam\steamapps\workshop\content\108600`. If Steam's library is elsewhere, read `libraryfolders.vdf` in the Steam `steamapps` folder to locate it.
3. Confirm the game is on 42.22.2 and Viewpoint (Workshop 3809306528) is 0.1.6.2: its `mods\Viewpoint\common\mod.info` should say `modversion=0.1.6.2`.

## Steps

For each entry in `manifest.json`:

1. Compute the sha256 of the file at that path on this machine.
2. If it equals `patched_sha256`, it is already done. Skip it.
3. If it equals `original_sha256`, back up the file beside itself (`<name>.jar.pre-pzfix` for jars, `mod.info.pre-unpin` for mod.info), then copy the bundled file from `workshop\<path>` over it. Re-hash and confirm it now equals `patched_sha256`.
4. If it equals neither, **stop and do not overwrite it**. This machine has a different version of that mod than the one the patch was made from. Report which file and both hashes to the user. The likely cause is that the mod author shipped an update (in which case the patch may no longer be needed, and the other player needs the same update), or that Steam has not finished downloading.
5. If the file or its mod folder is missing, the user is not subscribed to that Workshop item. Report the Workshop ID (the first path segment).

Then Base Keeper:

6. Copy `local-mods\BaseKeeper` to `%UserProfile%\Zomboid\mods\BaseKeeper`, so that `%UserProfile%\Zomboid\mods\BaseKeeper\42\mod.info` exists. If a `BaseKeeper` folder is already there, move it aside as a backup first rather than merging into it. Verify every copied file against `local-mods-manifest.json`.

Then the ADS compat mod:

6a. Copy `local-mods\EFZAdsCompat` to `%UserProfile%\Zomboid\mods\EFZAdsCompat`, so that `%UserProfile%\Zomboid\mods\EFZAdsCompat\42\mod.info` exists. Verify its files against `local-mods-manifest.json`.

6a2. Copy `local-mods\CoopFastForward` to `%UserProfile%\Zomboid\mods\CoopFastForward`, so that `%UserProfile%\Zomboid\mods\CoopFastForward\42\mod.info` exists. Verify its files against `local-mods-manifest.json`.

6a3. Copy `local-mods\VPCursorKeep` to `%UserProfile%\Zomboid\mods\VPCursorKeep`, so that `%UserProfile%\Zomboid\mods\VPCursorKeep\42\mod.info` exists. Verify its files against `local-mods-manifest.json`.

6a4. Copy `local-mods\GunSwap` to `%UserProfile%\Zomboid\mods\GunSwap`, so that `%UserProfile%\Zomboid\mods\GunSwap\42\mod.info` exists. Verify its files against `local-mods-manifest.json`.

Then the weapon pack:

6b. Check that `<workshop>\3722064198\mods\Gunworks_gang_framework` and `<workshop>\3824755284\mods\EscapeFromZomboidFirearms` exist. If either is missing, the user is not subscribed: give them these two links, have them click Subscribe, and wait for Steam to finish the download (about 1.9 GB) before going on.
    - https://steamcommunity.com/sharedfiles/filedetails/?id=3722064198
    - https://steamcommunity.com/sharedfiles/filedetails/?id=3824755284
6c. Confirm `<workshop>\3824755284\mods\EscapeFromZomboidFirearms\42\mod.info` says `modversion=1.1.6`. If it says something newer, tell the user: the other player needs the same version, which Steam gives them on their next update.

Then the mod list:

7. Back up `%UserProfile%\Zomboid\mods\default.txt` and compare it with the bundled `default.txt`. Show the user the differences and ask before replacing it, because replacing it changes which mods they have enabled. The bundled list has Mvdox Grass removed on purpose; whatever else you do, make sure no `Mvdox-Grass-v1` line is left enabled. It also has `ViewpointTrueBallistics` removed and `SWMG`, `EscapeFromZomboidFirearms`, `EFZAdsCompat`, `CoopFastForward`, `VPCursorKeep` and `GunSwap` added, and `AttachmentsUI` removed; make sure no `AttachmentsUI` line is left enabled.

## Do not touch

- Do not edit `ProjectZomboid64.json`, the `.bat`, or anything in the game folder. Launcher settings are per-machine and not part of this.
- Do not write to `%UserProfile%\.zombie_buddy\mod_approvals.json`. ZombieBuddy approves mod jars by sha256, so the 7 patched jars and the new weapon pack's jars will prompt for approval at the next launch. The user approves them in game. If the weapon pack's jar is denied, its sights, lasers and ballistics do not work.
- Do not run Steam "Verify integrity of game files" afterwards. It reverts every patched file.

## Report back

List each of the 13 files as patched, already patched, mismatched, or missing, whether Base Keeper, EFZAdsCompat, CoopFastForward, VPCursorKeep and GunSwap were installed and verified, whether both weapon pack Workshop items are present and at which version, plus the result of the mod list comparison.

## Reference: the 13 files

Version cap (`versionMax=42.22.999`):

- `3811472160\mods\ViewpointBloodFX\42\mod.info` and `...\common\mod.info` (Blood FX for Viewpoint)
- `3813801053\mods\ViewpointBloodFXAddon\42\mod.info` and `...\common\mod.info` (Blood FX for Viewpoint - Fixes)
- `3815630947\mods\ViewpointRollingHills\42\mod.info` (Viewpoint Rolling Hills)
- `3817555882\mods\RollingHillsPhysics\42\mod.info` (Rolling Hills Physics)

Jar patch:

- `3812612054` ProjectViewpointADS.jar
- `3812702301` ViewpointAdvancedMovement.jar
- `3812864848` ViewpointTrueBallistics.jar
- `3813194971` ViewpointAdvancedThrowables.jar
- `3813908957` ViewpointTrueWeathers.jar
- `3816442251` ViewpointLivingProps.jar
- `3816856700` PoolPitVP.jar

"6301 3D models for Viewpoint" (3810302175) was also patched originally, but its author updated it on 2026-11-12 for 42.22.2. It needs no edit; just make sure Steam has the current version.

"Viewpoint - Proper Roofs" (3818941548) was patched too, until its author updated it on 2026-11-16 (0.3.41). It needs no edit now; make sure Steam has the current version. If an old `ProperRoofs.jar.pre-pzfix` is still beside the jar, ignore it and do not copy it back.

"Surface Fix" (3814398576, `ViewpointSurface`) and "Isometric No More" (3819166046, `isometricnomore`) were removed from the server and the mod list on 2026-11-16: Surface Fix stops Viewpoint 0.1.7 drawing walls and floors (its author marked it broken), and Isometric No More is built into Viewpoint 0.1.7. Neither is patched or loaded any more; the new `default.txt` leaves both out.

## What changed on the server on 2026-11-14 (tell the user)

Nothing to install for these; they are server settings and apply when the user joins.

- **More zombies.** Population is up from 0.65 to 0.8 and sprinters from 2% to 3% of zombies. Respawn is off, so the extra zombies only show up in places nobody has visited yet.
- **Players on the map.** Other players now show on the full-screen map. The paper map on M does not show them.
- **Guns.** Old guns, magazines, attachments and ammo lying around the world turn into the new weapon pack's items as each area loads. Nothing a player carries is changed; put an old gun in a crate to have it converted.
- **Attachments.** The separate Attachments UI window is gone; use the weapon pack's own modding screen.
- **Fast forward.** Reading, crafting and other timed actions now speed up with fast forward.

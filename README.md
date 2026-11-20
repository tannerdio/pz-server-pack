# Project Zomboid server pack

Everything a friend needs to match the co-op server's mods: patched Workshop files, the host's own small mods
and the mod list. Game build 42.22.2 with Project Viewpoint.

## Install or update

1. Close Project Zomboid.
2. Open the Start menu, type `PowerShell`, open **Windows PowerShell**, paste this line and press Enter:

   ```
   irm https://raw.githubusercontent.com/tannerdio/pz-server-pack/main/get.ps1 | iex
   ```

3. Read the summary. Green means done. Yellow or red lines say what is left to do.

Run the same line again whenever the host says there is an update. It always fetches the newest version.

There is nothing to download by hand, so the browser has nothing to block. If you would rather double-click a
file, [Install-or-Update.bat](Install-or-Update.bat) does the same thing, but Edge may refuse the download
("signature is corrupt or invalid") and Windows may warn about an unknown file. That is only because the file
is not signed by a company; the paste-in line avoids both.

## What it does

- Patches 11 files in Workshop mods that have not been updated for 42.22.2 yet. The original of each file is
  kept beside it (`.pre-pzfix` or `.pre-unpin`). A file from a different mod version is left alone and reported.
- Copies the host's own mods into `%UserProfile%\Zomboid\mods`.
- Replaces `%UserProfile%\Zomboid\mods\default.txt` with the server's mod list. Your old list is kept beside it.
- Lists server Workshop mods you have not downloaded yet.

It changes nothing else, and nothing in the game's own folder.

## Good to know

- The game may ask you to approve changed mod jars at the next start. Approve them.
- Steam's "Verify integrity of game files" undoes the patches. Run the installer again afterwards.
- "Lua/script checksums do not match" when joining means your files differ from the server's: run the installer.

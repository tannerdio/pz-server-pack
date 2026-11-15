# Project Zomboid server pack

Everything a friend needs to match the co-op server's mods: patched Workshop files, the host's own small mods
and the mod list. Game build 42.22.2 with Project Viewpoint.

## Install or update

1. Close Project Zomboid.
2. Download [Install-or-Update.bat](Install-or-Update.bat) (open it, then the download button at the top right)
   and double-click it.
3. Read the summary. Green means done. Yellow or red lines say what is left to do.

Run the same file again whenever the host says there is an update. It always fetches the newest version, so
you only ever need to download it once.

### If the browser or Windows blocks the file

The file is a plain script, not signed by a company, so Windows is cautious about it. Both warnings are expected:

- **Edge says "signature is corrupt or invalid" or "isn't commonly downloaded"**: in the Downloads list, hover
  the file, click **...** > **Keep**, then **Show more** > **Keep anyway**.
- **"Windows protected your PC" when you double-click it**: click **More info** > **Run anyway**.

## What it does

- Patches 15 files in Workshop mods that have not been updated for 42.22.2 yet. The original of each file is
  kept beside it (`.pre-pzfix` or `.pre-unpin`). A file from a different mod version is left alone and reported.
- Copies the host's own mods into `%UserProfile%\Zomboid\mods`.
- Replaces `%UserProfile%\Zomboid\mods\default.txt` with the server's mod list. Your old list is kept beside it.
- Lists server Workshop mods you have not downloaded yet.

It changes nothing else, and nothing in the game's own folder.

## Good to know

- The game may ask you to approve changed mod jars at the next start. Approve them.
- Steam's "Verify integrity of game files" undoes the patches. Run the installer again afterwards.
- "Lua/script checksums do not match" when joining means your files differ from the server's: run the installer.

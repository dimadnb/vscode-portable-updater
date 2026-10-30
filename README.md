# VS Code Portable Updater

Update the official Windows portable version of Visual Studio Code with a double-click. Keep your `data` folder and personal folders, move old build folders out of the installation root, and restore the previous application files if an update fails.

## Requirements

- An existing **VS Code Stable ZIP installation** for **x64 or ARM64**, with `Code.exe` and a `data` folder next to each other.
- **Windows PowerShell 5.1**, included with Windows 10 and 11. The `.cmd` launchers use it automatically; PowerShell 7 can also run the script directly.
- Internet access, permission to write to the VS Code folder, and enough free space for the download and extracted files.

No Python, Git, Node.js, extra PowerShell modules or administrator account is needed. This updater does not install VS Code from scratch. If you do not have a portable installation yet, follow Microsoft's [Portable mode guide](https://code.visualstudio.com/docs/setup/portable).

## Quick start

1. **Download and extract this project's ZIP.** In File Explorer, right-click it and choose **Extract All**. Do not run the updater from inside the ZIP.
2. **Find your portable VS Code folder.** It must contain both `Code.exe` and `data`.
3. **Copy these three files directly into that folder:**
   - `Update-VSCodePortable.ps1`
   - `Update.cmd`
   - `Rollback.cmd`
4. **Save your work and close VS Code**, including terminals and tunnels running from that installation.
5. **Double-click `Update.cmd` in File Explorer.** Wait for `Done`, then open `Code.exe` as usual. If your version is already current and no old builds need cleaning up, the updater reports that instead.

Place the files beside `Code.exe`, not inside `data`, `bin` or a build folder:

```text
VSCode/
  Code.exe
  data/
  bin/
  <build folder>/
  Update-VSCodePortable.ps1
  Update.cmd
  Rollback.cmd
```

You can keep this README anywhere convenient. The updater detects the installation path, version and architecture automatically. Use `Update.cmd` again whenever you want to check for updates.

## What is preserved

**The updater leaves `data` in place.** Settings, extensions and session data stored there are not copied, replaced or deleted. Separate personal folders beside `data`, such as `projects` or `scripts`, also stay in place. Unknown folders are not removed just because their names look like hashes.

Application folders such as `bin`, recognized `tools`/`appx`/`policies`, and recognized build folders are replaced as a whole. If you put personal files inside them, those files remain in the backup and are not automatically copied into the new version. Keep personal projects in separate folders. If a new application entry conflicts with an unknown personal item, the updater stops.

## Backups and recovery

Before replacing files, the updater downloads and extracts the new release, checks its SHA-256, Microsoft signature, version and architecture, and checks command-line startup. Downloads and redirects are restricted to the official HTTPS update and download hosts. Running instances are never forcibly closed.

Old application files, including recognized old hash folders, are moved into:

```text
.vscode-portable-updater/tx-<date>-<time>-<id>/old/
```

**This cleans the installation root but does not immediately free disk space.** Backups remain available until you remove them yourself.

- To undo the last successful update, close VS Code and double-click **`Rollback.cmd`**. This restores application files, not an earlier copy of your settings.
- If an update fails during replacement, the updater attempts to restore the previous files automatically.
- If the updater was interrupted, run **`Update.cmd`** again. It first recovers the previous installation and exits. Run it once more to start a new update.
- If recovery cannot finish because a file is locked, close the process using that file and retry. Keep the entire `.vscode-portable-updater` folder until recovery finishes.

After checking that VS Code works, you may delete unwanted `tx-...` folders while the updater is closed. Open each folder's `journal.json` in Notepad first: delete only completed operations marked `Committed` or `RolledBack`. Keep the latest `Committed` folder if you want rollback available. Never delete an operation marked `Applying` or `RollingBack`.

The updater does not back up `data` or undo profile changes made by VS Code after you launch it. Back up important personal data separately.

## Optional PowerShell commands

Run these from the folder containing the script:

```powershell
# Check versions without downloading the ZIP or changing the installation
.\Update-VSCodePortable.ps1 -CheckOnly

# Update an installation in another folder
.\Update-VSCodePortable.ps1 -Path 'D:\Tools\VSCode'

# Reinstall the current official release and clean recognized old builds
.\Update-VSCodePortable.ps1 -Reinstall

# Restore the files from the last successful update
.\Update-VSCodePortable.ps1 -Rollback

# Refuse to move these names even if they are recognized as application entries
.\Update-VSCodePortable.ps1 -Keep 'tools','my-files'
```

Ordinary unknown personal folders are already preserved; `-Keep` adds an explicit protection rule. It accepts names in the installation root, not full paths. To use it on every double-click, add the option to the PowerShell command in `Update.cmd`.

## Troubleshooting

| Message or situation | What to do |
| --- | --- |
| No `data` folder | Check that this is an existing portable ZIP installation. Do not create an empty `data` folder in an installer-based version as a shortcut. See the [Portable mode guide](https://code.visualstudio.com/docs/setup/portable). |
| VS Code is still running | Save your work, close that installation and its tunnels, then retry. An inaccessible VS Code process path also causes the updater to stop. |
| Network, checksum or signature error | Check your connection and Windows date/time, then retry. These checks happen before replacement; do not disable them. |
| Windows blocks the downloaded files | If you trust the download, open the ZIP's **Properties**, select **Unblock** if available, and extract it again. Organization policies may still prevent execution. |
| Not enough space or access denied | Free space or use a folder you can write to, then retry. Do not delete an unfinished recovery operation. |

The launchers use `ExecutionPolicy Bypass` for their PowerShell process only; they do not change the system execution policy. The updater is intended for the official Stable ZIP distribution. Insiders, VSCodium, PortableApps wrappers, x86, UNC paths and drive roots are not supported. Links or junctions in the installation path or managed application files cause it to stop. If Microsoft changes the package layout or download hosts, it may stop until the script is updated.

Official documentation: [Portable mode](https://code.visualstudio.com/docs/setup/portable) · [VS Code on Windows](https://code.visualstudio.com/docs/setup/windows).

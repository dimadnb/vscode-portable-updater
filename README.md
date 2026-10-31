# VS Code Portable Updater

One Windows script for updating the official **VS Code Stable ZIP distribution**. Includes a menu, progress bars, resumable downloads and rollback. The interface is in English.

## Quick start

1. Download **`vscode-portable-updater.cmd`**, or extract it from this project's ZIP.
2. Put it beside **`Code.exe` and `data`** in your portable VS Code folder.
3. Save your work and close that VS Code installation, including its terminals and tunnels.
4. Double-click **`vscode-portable-updater.cmd`**, then press **Enter** to update.
5. Wait for `Finished successfully. [0]`, then open `Code.exe` normally.

```text
VSCode/
  Code.exe
  data/
  bin/
  <build folder>/
  vscode-portable-updater.cmd    <- the only updater file you need
```

The README is optional. If you keep the script elsewhere, use **Choose folder** in its menu. When upgrading from the earlier updater, you can remove its `Update.cmd`, `Rollback.cmd` and `Update-VSCodePortable.ps1`. Keep `.vscode-portable-updater`: the new script understands existing recovery journals.

Requires Windows with **Windows PowerShell 5.1 and .NET Framework**, internet access and write access to the installation folder. No Python, Git, curl installation, extra modules or administrator account is needed. x64 and ARM64 packages are supported; the installed architecture is preserved. This is a console application, not a graphical installer.

If you do not already have a portable installation, follow Microsoft's [Portable mode guide](https://code.visualstudio.com/docs/setup/portable). The updater does not convert an installer-based version or create an empty profile for you.

## Menu

| Action | What it does |
| --- | --- |
| Update | Install the latest Stable release, or clean recognized old builds using the current release. |
| Check version | Compare installed and available versions without downloading the ZIP or changing installation files. |
| Rollback | Restore application files from the last successful update. |
| Choose folder | Select another portable installation. |
| Reinstall | Replace the current program files even if the version is already current. |
| Use one connection | Disable parallel downloading for this run, for connections or proxies that work better that way. |

## Downloads and progress

- Up to **four concurrent HTTP ranges** for archives of at least 16 MB, when supported by the server. Actual speed depends on the connection and server; four connections do not guarantee four times the speed.
- Download progress shows bytes, percentage, current speed and estimated time remaining. Extraction has its own progress bar.
- Partial ranges remain cached after a disconnect, cancellation or failed run. Running the updater again resumes them for the same release.
- If ranges are unavailable, the updater uses one streaming connection. Partial streaming downloads restart instead of resuming.
- **15 seconds** to receive response headers; **20 seconds** without incoming data; at most **three attempts per request/range**, with 2- and 4-second retry delays. Metadata has a **60-second total limit**; downloading and assembly have a **15-minute total limit**. There is no unlimited retry loop.
- **Esc** cancels a network operation and keeps downloaded parts. Keep the window open during file replacement. After a forced interruption, choose Update to recover the previous installation first.

The source and each redirect must use an allowed Microsoft HTTPS host. The completed archive must match Microsoft's SHA-256. Microsoft signatures, version, commit, architecture and command-line startup are checked before replacement, and the installed application is checked again afterwards. A checksum mismatch discards the download cache; it never bypasses verification.

## Data, backups and disk space

**`data` and separate personal folders in the installation root stay in place.** Unknown folders are not deleted just because their names look like hashes. Recognized application folders are replaced as a whole. Personal files placed inside `bin`, build folders or other managed application folders remain in the backup and are not copied into the new program.

Runtime files are created only as needed under `.vscode-portable-updater`:

```text
.vscode-portable-updater/
  last-run.log                  status and diagnostic messages
  downloads/<sha256>/           resumable parts and the verified archive
  tx-<date>-<time>-<id>/
    journal.json                recovery state
    old/                        previous program files and old builds
```

Old hash folders leave the installation root but remain in the backup, so cleanup does **not immediately free their disk space**. The updater checks free space before downloading and extracting. Download parts temporarily coexist with the assembled archive; successful updates clear that release's download cache.

After checking that VS Code works, you may remove unwanted `tx-...` folders while the updater is closed. Open `journal.json` in Notepad first: only remove operations marked `Committed` or `RolledBack`. Keep the latest successful backup if you want rollback. Never delete an operation marked `Applying` or `RollingBack`.

Rollback restores **program files**, not a previous copy of settings or profile changes made by VS Code. Back up important personal data separately. If a backup is incomplete or recovery cannot finish, the updater reports an error and keeps the recovery files.

## Error codes

The console shows a numeric code and a readable reason. The same number is returned to the calling process. Update and rollback runs also write `.vscode-portable-updater/last-run.log`.

| Code | Meaning / next step |
| --- | --- |
| 0 | Completed successfully. |
| 2 | Cancelled or exited the menu. Run again to resume a download. |
| 10 | Invalid installation, folder conflict or incompatible options. Check the folder and message. |
| 11 | A relevant process is running. Save your work, close it and retry. |
| 12 | Another updater may hold the installation lock. Close it before retrying. |
| 20 | Network failure; retry budget exhausted. Check your connection and run again. |
| 21 | Connection, idle or total timeout. Check the connection; saved parts can resume. |
| 22 | HTTP error or inconsistent server response. The message includes the reason. |
| 23 | Disallowed source/redirect or TLS trust failure. Check Windows time and trust; do not disable certificate checks. |
| 30 | Checksum or cache integrity failure. Retry a fresh download; if instructed, remove only `downloads` while the updater is closed. |
| 31 | Invalid or unsupported ZIP layout. The existing application has not been replaced. |
| 32 | Missing or invalid Microsoft signature. Do not bypass the check. |
| 40 | Insufficient disk space. Free space without deleting unfinished recovery files. |
| 41 | File access or filesystem error. Check permissions, locks and paths. |
| 50 | Update failed; previous application files were restored. |
| 51 | Recovery needs attention, or no suitable rollback exists. Keep backups and follow the message. |
| 99 | Unexpected/startup error. Save the message and log for diagnosis. |

For scripted use, set `VSCPU_ACTION` to `Update`, `Check` or `Rollback` and optionally set `VSCPU_PATH` before launching the CMD file. This skips the menu and closing prompt. Clear these environment variables afterwards to return to interactive use.

## Notes

The CMD contains its PowerShell and embedded .NET download helper; it does not unpack a separate PS1 launcher. Execution policy is changed only for that process. Organization policies may still block script execution or runtime compilation. If Windows blocks a trusted downloaded ZIP, use **Properties > Unblock** before extracting it.

Insiders, VSCodium, PortableApps wrappers, x86, UNC paths and drive roots are outside this updater's scope. Links/junctions in managed paths are refused. ARM64 selection is implemented, but this release was exercised with real x64 binaries. Versioned build folders were tested; legacy layouts and every USB filesystem have not been tested end to end.

Implementation references: [Microsoft Portable mode](https://code.visualstudio.com/docs/setup/portable), [HTTP response/body timeout semantics](https://learn.microsoft.com/en-us/dotnet/api/system.net.http.httpcompletionoption), [PowerShell progress bars](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/write-progress), [HTTP range semantics](https://www.rfc-editor.org/rfc/rfc9110.html#section-14.2). No external downloader or project code is required at runtime.

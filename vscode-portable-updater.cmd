@echo off
setlocal DisableDelayedExpansion
set "VSCPU_FILE=%~f0"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "try{$s=[IO.File]::ReadAllText($env:VSCPU_FILE);$m='#==POWER'+'SHELL==';$i=$s.IndexOf($m);if($i -lt 0){throw 'Embedded script not found.'};& ([scriptblock]::Create($s.Substring($i+$m.Length)))}catch{Write-Host ('ERROR [99 / STARTUP]: '+$_.Exception.Message);exit 99}"
set "VSCPU_RESULT=%errorlevel%"
if defined VSCPU_ACTION goto finished
echo.
echo Press any key to close this window...
pause >nul
:finished
exit /b %VSCPU_RESULT%
#==POWERSHELL==
#requires -Version 5.1
<#
Windows VS Code Stable ZIP, x64/ARM64. Single-file console updater. See README.md.
No elevation, external modules, self-modification, or forced process termination.
#>
[CmdletBinding()]
param(
    [string]$Path = '',
    [switch]$CheckOnly,
    [switch]$Reinstall,
    [switch]$Rollback,
    [string[]]$Keep = @(),
    [ValidateSet('Menu','Update','Check','Rollback')][string]$Action = 'Menu',
    [ValidateRange(1,4)][int]$Connections = 4
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:LauncherFile = if ($env:VSCPU_FILE) { $env:VSCPU_FILE } else { $PSCommandPath }
if (-not $Path) { $Path = if ($env:VSCPU_PATH) { $env:VSCPU_PATH } else { [IO.Path]::GetDirectoryName($script:LauncherFile) } }
if ($env:VSCPU_ACTION -and $Action -eq 'Menu') { $Action = $env:VSCPU_ACTION }
$script:FailureCode = 99
$script:LogFile = $null
$script:ProgressAt = 0
$script:ProtectedNames = @('data','.vscode-portable-updater','VSCodePortableUpdater.cmd','Update-VSCodePortable.ps1','Update.cmd','Rollback.cmd',([IO.Path]::GetFileName($script:LauncherFile)))
$script:ErrorNames = @{2='CANCELLED';10='INSTALLATION';11='RUNNING';12='BUSY';20='NETWORK';21='TIMEOUT';22='HTTP';23='SOURCE';30='CHECKSUM';31='PACKAGE';32='SIGNATURE';40='DISK_SPACE';41='FILE_ACCESS';50='UPDATE_ROLLED_BACK';51='RECOVERY_REQUIRED';99='UNEXPECTED'}

$script:StateName = '.vscode-portable-updater'
$script:KnownFiles = @('Code.exe','Code.VisualElementsManifest.xml','LICENSE.txt','LICENSES.chromium.html',
    'ThirdPartyNotices.txt','chrome_100_percent.pak','chrome_200_percent.pak','d3dcompiler_47.dll',
    'ffmpeg.dll','icudtl.dat','libEGL.dll','libGLESv2.dll','resources.pak','snapshot_blob.bin',
    'v8_context_snapshot.bin','vk_swiftshader.dll','vk_swiftshader_icd.json','vulkan-1.dll',
    'chrome_crashpad_handler.exe')


if (-not ('PortableUpdater.Transfer' -as [type])) {
    Add-Type -AssemblyName System.Net.Http
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    [Net.ServicePointManager]::DefaultConnectionLimit = [math]::Max(8,[Net.ServicePointManager]::DefaultConnectionLimit)
    $networkSource = @'
using System;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;

namespace PortableUpdater {
    public sealed class Failure : Exception {
        public readonly int ExitCode;
        public readonly bool Transient;
        public Failure(int code, string message, bool transient = false, Exception inner = null) : base(message, inner) {
            ExitCode = code; Transient = transient;
        }
    }
    public sealed class TransferOptions {
        public int HeaderMs = 15000, IdleMs = 20000, TotalMs = 900000, Attempts = 3, Connections = 4, RetryDelayMs = 2000;
        public long MaxArchiveBytes = 1073741824;
    }
    public sealed class Transfer : IDisposable {
        readonly TransferOptions opt;
        readonly HttpClient client;
        readonly CancellationTokenSource user = new CancellationTokenSource();
        readonly CancellationTokenSource deadline = new CancellationTokenSource();
        readonly CancellationTokenSource lifetime;
        readonly Stopwatch budgetClock = Stopwatch.StartNew();
        long completedMilliseconds = -1;
        long total, received, transferred;
        string phase = "Connecting";
        public Task Completion { get; private set; }
        public string Text { get; private set; }
        public string FilePath { get; private set; }
        public long Total { get { return Interlocked.Read(ref total); } }
        public long Received { get { return Interlocked.Read(ref received); } }
        public long Transferred { get { return Interlocked.Read(ref transferred); } }
        public string Phase { get { return phase; } }
        public double ElapsedSeconds { get { long end = Interlocked.Read(ref completedMilliseconds); return (end < 0 ? budgetClock.ElapsedMilliseconds : end) / 1000.0; } }
        public readonly ConcurrentQueue<string> Events = new ConcurrentQueue<string>();

        public Transfer() : this(new TransferOptions(), null) { }
        // Handler injection is for offline testing. URL checks are always enforced.
        public Transfer(TransferOptions options, HttpMessageHandler handler) {
            opt = options;
            if (opt.Connections < 1 || opt.Connections > 4 || opt.Attempts < 1 || opt.Attempts > 3 ||
                opt.HeaderMs < 1 || opt.IdleMs < 1 || opt.TotalMs < 1) throw new ArgumentException("Invalid transfer settings.");
            if (handler == null) {
                var native = new HttpClientHandler { AllowAutoRedirect = false, AutomaticDecompression = DecompressionMethods.None };
                var limit = native.GetType().GetProperty("MaxConnectionsPerServer");
                if (limit != null) limit.SetValue(native, 8, null);
                handler = native;
            }
            client = new HttpClient(handler);
            client.Timeout = Timeout.InfiniteTimeSpan;
            deadline.CancelAfter(opt.TotalMs);
            lifetime = CancellationTokenSource.CreateLinkedTokenSource(user.Token, deadline.Token);
        }
        public void Cancel() { user.Cancel(); }
        public void Dispose() { user.Cancel(); client.Dispose(); lifetime.Dispose(); deadline.Dispose(); user.Dispose(); }
        public static void CheckUri(Uri uri) {
            if (!uri.IsAbsoluteUri || uri.Scheme != "https" || uri.Port != 443 || uri.UserInfo.Length != 0 ||
                (uri.Host != "update.code.visualstudio.com" && uri.Host != "vscode.download.prss.microsoft.com"))
                throw new Failure(23, "The update source or redirect is not an allowed Microsoft HTTPS address.");
        }
        Exception Cancellation() {
            if (user.IsCancellationRequested) return new Failure(2, "Cancelled. Downloaded parts are kept for the next run.");
            if (deadline.IsCancellationRequested || budgetClock.ElapsedMilliseconds >= opt.TotalMs) return new Failure(21, "The transfer time limit (" + (opt.TotalMs / 1000) + " seconds) was reached. Downloaded parts are kept.");
            return new OperationCanceledException();
        }
        static void Observe(Task task) { task.ContinueWith(t => { var ignored = t.Exception; }, TaskContinuationOptions.OnlyOnFaulted); }
        void CheckBudget() { if (user.IsCancellationRequested || deadline.IsCancellationRequested || budgetClock.ElapsedMilliseconds >= opt.TotalMs) throw Cancellation(); }
        async Task<T> Bounded<T>(Task<T> task, int ms, CancellationToken token, Action abort, string message) {
            try { CheckBudget(); } catch { abort(); Observe(task); throw; }
            ms = (int)Math.Max(1, Math.Min(ms, opt.TotalMs - budgetClock.ElapsedMilliseconds));
            using (var delayCancel = CancellationTokenSource.CreateLinkedTokenSource(token)) {
                var delay = Task.Delay(ms, delayCancel.Token);
                if (await Task.WhenAny(task, delay).ConfigureAwait(false) != task) {
                    abort();
                    // Observe any later exception without waiting indefinitely for a broken transport.
                    Observe(task);
                    if (token.IsCancellationRequested || budgetClock.ElapsedMilliseconds >= opt.TotalMs) throw Cancellation();
                    throw new Failure(21, message, true);
                }
                delayCancel.Cancel();
                CheckBudget();
                try { return await task.ConfigureAwait(false); }
                catch (OperationCanceledException) { throw Cancellation(); }
            }
        }
        async Task<HttpResponseMessage> Open(string url, long? from, long? to, CancellationToken token) {
            var uri = new Uri(url);
            for (int redirect = 0; redirect <= 5; redirect++) {
                CheckUri(uri);
                using (var request = new HttpRequestMessage(HttpMethod.Get, uri))
                using (var requestCancel = CancellationTokenSource.CreateLinkedTokenSource(token)) {
                    request.Headers.UserAgent.ParseAdd("VSCodePortableUpdater/2.0");
                    request.Headers.AcceptEncoding.ParseAdd("identity");
                    if (from.HasValue) request.Headers.Range = new RangeHeaderValue(from.Value, to);
                    HttpResponseMessage response;
                    try {
                        response = await Bounded(client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, requestCancel.Token),
                            opt.HeaderMs, token, () => requestCancel.Cancel(), "No response headers within the connection timeout.").ConfigureAwait(false);
                    } catch (HttpRequestException ex) {
                        var inner = ex.InnerException;
                        while (inner != null) {
                            if (inner is System.Security.Authentication.AuthenticationException)
                                throw new Failure(23, "TLS certificate validation failed. Check Windows time and certificate trust.", false, ex);
                            var web = inner as WebException;
                            if (web != null && (web.Status == WebExceptionStatus.TrustFailure || web.Status == WebExceptionStatus.SecureChannelFailure))
                                throw new Failure(23, "A trusted TLS connection could not be established.", false, ex);
                            inner = inner.InnerException;
                        }
                        throw new Failure(20, "Network connection failed: " + ex.Message, true, ex);
                    }
                    int status = (int)response.StatusCode;
                    if (status == 301 || status == 302 || status == 303 || status == 307 || status == 308) {
                        var location = response.Headers.Location;
                        response.Dispose();
                        if (location == null) throw new Failure(23, "The server returned an empty redirect.");
                        uri = new Uri(uri, location);
                        continue;
                    }
                    if (status != 200 && status != 206) {
                        response.Dispose();
                        bool retry = status == 408 || status == 429 || status == 500 || status == 502 || status == 503 || status == 504;
                        throw new Failure(22, "The server returned HTTP " + status + ".", retry);
                    }
                    if (response.Content.Headers.ContentEncoding.Any(e => e != "identity")) {
                        response.Dispose(); throw new Failure(22, "Unexpected HTTP content encoding.");
                    }
                    return response;
                }
            }
            throw new Failure(23, "Too many redirects.");
        }
        async Task<T> Retry<T>(Func<Task<T>> action, string label, CancellationToken token) {
            for (int attempt = 1; ; attempt++) {
                CheckBudget();
                token.ThrowIfCancellationRequested();
                try { return await action().ConfigureAwait(false); }
                catch (Failure error) {
                    if (!error.Transient || attempt >= opt.Attempts) throw;
                    Events.Enqueue(label + ": " + error.Message + " Retry " + (attempt + 1) + "/" + opt.Attempts + " in " + (opt.RetryDelayMs * attempt / 1000.0).ToString("0.#") + " s.");
                }
                await Task.Delay(opt.RetryDelayMs * attempt, token).ConfigureAwait(false);
            }
        }
        async Task<int> Read(Stream input, byte[] buffer, HttpResponseMessage response, CancellationToken token) {
            try {
                return await Bounded(input.ReadAsync(buffer, 0, buffer.Length, token), opt.IdleMs, token,
                    () => response.Dispose(), "No download data received within the idle timeout.").ConfigureAwait(false);
            } catch (IOException ex) { throw new Failure(20, "The download connection was interrupted.", true, ex); }
              catch (HttpRequestException ex) { throw new Failure(20, "The download connection was interrupted.", true, ex); }
        }
        async Task Guard(Func<Task> operation) {
            try { CheckBudget(); await operation().ConfigureAwait(false); CheckBudget(); }
            catch (OperationCanceledException) { throw Cancellation(); }
            finally { Interlocked.Exchange(ref completedMilliseconds, budgetClock.ElapsedMilliseconds); }
        }
        public void StartMetadata(string url) {
            if (Completion != null) throw new InvalidOperationException("A transfer can only be started once.");
            Completion = Task.Run(() => Guard(async () => {
                Text = await Retry(async () => {
                    using (var response = await Open(url, null, null, lifetime.Token).ConfigureAwait(false)) {
                        if (response.StatusCode != HttpStatusCode.OK) throw new Failure(22, "Unexpected partial metadata response.");
                        long? length = response.Content.Headers.ContentLength;
                        if (length.HasValue && length.Value > 1048576) throw new Failure(22, "Release metadata exceeds the 1 MB limit.");
                        using (var input = await response.Content.ReadAsStreamAsync().ConfigureAwait(false))
                        using (var output = new MemoryStream()) {
                            var buffer = new byte[16384]; int count;
                            while ((count = await Read(input, buffer, response, lifetime.Token).ConfigureAwait(false)) != 0) {
                                if (output.Length + count > 1048576) throw new Failure(22, "Release metadata exceeds the 1 MB limit.");
                                output.Write(buffer, 0, count);
                            }
                            if (length.HasValue && length.Value != output.Length) throw new Failure(20, "The release metadata download was interrupted.", true);
                            return System.Text.Encoding.UTF8.GetString(output.ToArray());
                        }
                    }
                }, "Release check", lifetime.Token).ConfigureAwait(false);
            }));
        }
        void SafeFile(string file, string directory) {
            string root = Path.GetFullPath(directory).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
            if (!Path.GetFullPath(file).StartsWith(root, StringComparison.OrdinalIgnoreCase)) throw new Failure(41, "A cache path is outside its folder.");
            string item = Path.GetFullPath(file);
            while (!String.IsNullOrEmpty(item)) {
                if ((File.Exists(item) || Directory.Exists(item)) && (File.GetAttributes(item) & FileAttributes.ReparsePoint) != 0)
                    throw new Failure(41, "A cache path contains a symbolic link or junction.");
                item = Path.GetDirectoryName(item);
            }
        }
        void CheckSpace(string directory, long required) {
            var drive = new DriveInfo(Path.GetPathRoot(Path.GetFullPath(directory)));
            if (drive.AvailableFreeSpace < required + 268435456L) throw new Failure(40, "Not enough disk space for download parts and assembly.");
        }
        sealed class Probe { public long Size; public bool Ranges; }
        sealed class Part { public string File; public long Start, End; public int Number; }
        async Task<Probe> ProbeServer(string url) {
            return await Retry(async () => {
                using (var response = await Open(url, 0, 0, lifetime.Token).ConfigureAwait(false)) {
                    var range = response.Content.Headers.ContentRange;
                    if (response.StatusCode == HttpStatusCode.PartialContent) {
                        if (range == null || range.Unit != "bytes" || range.From != 0 || range.To != 0 || !range.Length.HasValue)
                            throw new Failure(22, "Invalid Content-Range in the download probe.");
                        return new Probe { Size = range.Length.Value, Ranges = true };
                    }
                    return new Probe { Size = response.Content.Headers.ContentLength ?? -1, Ranges = false };
                }
            }, "Download probe", lifetime.Token).ConfigureAwait(false);
        }
        async Task<bool> DownloadPart(string url, string file, long start, long end, long size, CancellationToken token) {
            long expected = end - start + 1;
            long existing = File.Exists(file) ? new FileInfo(file).Length : 0;
            if (existing > expected) throw new Failure(30, "A saved download part is larger than expected. Clear the download cache and retry.");
            if (existing == expected) return true;
            using (var response = await Open(url, start + existing, end, token).ConfigureAwait(false)) {
                if (response.StatusCode == HttpStatusCode.OK) throw new Failure(24, "The server ignored a range request.");
                var range = response.Content.Headers.ContentRange;
                if (range == null || range.Unit != "bytes" || range.From != start + existing || range.To != end || range.Length != size ||
                    (response.Content.Headers.ContentLength.HasValue && response.Content.Headers.ContentLength != expected - existing))
                    throw new Failure(22, "The server returned a mismatched download range.");
                using (var input = await response.Content.ReadAsStreamAsync().ConfigureAwait(false))
                using (var output = new FileStream(file, FileMode.Append, FileAccess.Write, FileShare.Read, 262144, true)) {
                    var buffer = new byte[262144]; int count;
                    while ((count = await Read(input, buffer, response, token).ConfigureAwait(false)) != 0) {
                        if (output.Length + count > expected) throw new Failure(22, "The server sent more bytes than the requested range.");
                        await output.WriteAsync(buffer, 0, count, token).ConfigureAwait(false);
                        Interlocked.Add(ref received, count);
                        Interlocked.Add(ref transferred, count);
                    }
                    output.Flush(true);
                    if (output.Length != expected) throw new Failure(20, "The server closed the download before the range was complete.", true);
                }
            }
            return true;
        }
        async Task StreamDownload(string url, string file, long expected) {
            await Retry(async () => {
                Interlocked.Exchange(ref received, 0);
                using (var response = await Open(url, null, null, lifetime.Token).ConfigureAwait(false)) {
                    if (response.StatusCode != HttpStatusCode.OK) throw new Failure(22, "Unexpected partial response in streaming mode.");
                    long length = response.Content.Headers.ContentLength ?? -1;
                    if (expected >= 0 && length >= 0 && expected != length) throw new Failure(22, "The archive size changed during download.");
                    if (length > opt.MaxArchiveBytes) throw new Failure(22, "The archive exceeds the download size limit.");
                    Interlocked.Exchange(ref total, length);
                    using (var input = await response.Content.ReadAsStreamAsync().ConfigureAwait(false))
                    using (var output = new FileStream(file, FileMode.Create, FileAccess.Write, FileShare.Read, 262144, true)) {
                        var buffer = new byte[262144]; int count;
                        while ((count = await Read(input, buffer, response, lifetime.Token).ConfigureAwait(false)) != 0) {
                            if (output.Length + count > opt.MaxArchiveBytes || (length >= 0 && output.Length + count > length)) throw new Failure(22, "The response exceeds the expected archive size.");
                            await output.WriteAsync(buffer, 0, count, lifetime.Token).ConfigureAwait(false);
                            Interlocked.Add(ref received, count);
                            Interlocked.Add(ref transferred, count);
                        }
                        output.Flush(true);
                        if (length >= 0 && output.Length != length) throw new Failure(20, "The archive download was interrupted.", true);
                    }
                }
                return true;
            }, "Streaming download", lifetime.Token).ConfigureAwait(false);
        }
        public void StartDownload(string url, string directory) {
            if (Completion != null) throw new InvalidOperationException("A transfer can only be started once.");
            Completion = Task.Run(() => Guard(async () => {
                var probe = await ProbeServer(url).ConfigureAwait(false);
                if (probe.Size == 0 || probe.Size > opt.MaxArchiveBytes) throw new Failure(22, "The archive size is outside the supported range.");
                Interlocked.Exchange(ref total, probe.Size);
                var archive = Path.Combine(directory, "archive.zip");
                var assembling = Path.Combine(directory, "assembly.tmp");
                SafeFile(archive, directory); SafeFile(assembling, directory);
                if (File.Exists(archive)) throw new Failure(41, "A completed cache archive already exists.");
                CheckSpace(directory, probe.Size > 0 ? probe.Size * 2 : opt.MaxArchiveBytes * 2);
                bool ranged = probe.Ranges;
                var parts = new List<string>();
                if (ranged) {
                    int connections = probe.Size >= 16777216 ? opt.Connections : 1;
                    phase = "Downloading with " + connections + " connection(s)";
                    Events.Enqueue(phase + ". Saved parts will be resumed when available.");
                    var jobs = new List<Task>();
                    var plan = new List<Part>();
                    // Validate every cached part before starting any writer.
                    for (int i = 0; i < connections; i++) {
                        long start = probe.Size * i / connections, end = probe.Size * (i + 1) / connections - 1;
                        string file = Path.Combine(directory, "range-" + start + "-" + end + ".part");
                        SafeFile(file, directory); parts.Add(file);
                        long existing = File.Exists(file) ? new FileInfo(file).Length : 0;
                        if (existing > end - start + 1) throw new Failure(30, "A saved download part has an invalid size. Clear the download cache.");
                        Interlocked.Add(ref received, existing);
                        plan.Add(new Part { File=file, Start=start, End=end, Number=i+1 });
                    }
                    using (var group = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token)) {
                        foreach (var item in plan) {
                            var part = item;
                            jobs.Add(Task.Run(async () => {
                                try { await Retry(() => DownloadPart(url, part.File, part.Start, part.End, probe.Size, group.Token), "Part " + part.Number, group.Token).ConfigureAwait(false); }
                                catch { group.Cancel(); throw; }
                            }));
                        }
                        try { await Task.WhenAll(jobs).ConfigureAwait(false); }
                        catch {
                            var errors = jobs.Where(j => j.IsFaulted).SelectMany(j => j.Exception.Flatten().InnerExceptions).ToArray();
                            var error = errors.FirstOrDefault(e => !(e is OperationCanceledException) && !(e is Failure && ((Failure)e).ExitCode == 2));
                            if (error is Failure && ((Failure)error).ExitCode == 24) {
                                ranged = false; Events.Enqueue("Range requests are unavailable. Switching to one streaming connection.");
                            } else if (error != null) throw error;
                            else throw Cancellation();
                        }
                    }
                }
                if (!ranged) {
                    phase = "Downloading with one streaming connection";
                    Events.Enqueue(phase + ". This server does not support resuming partial files.");
                    await StreamDownload(url, assembling, probe.Size).ConfigureAwait(false);
                } else {
                    phase = "Assembling downloaded parts";
                    using (var output = new FileStream(assembling, FileMode.Create, FileAccess.Write, FileShare.None, 262144, true)) {
                        foreach (string file in parts) {
                            using (var input = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.Read, 262144, true))
                                await input.CopyToAsync(output, 262144, lifetime.Token).ConfigureAwait(false);
                        }
                        output.Flush(true);
                        if (output.Length != probe.Size) throw new Failure(30, "The assembled archive has an invalid size.");
                    }
                }
                File.Move(assembling, archive);
                FilePath = archive; phase = "Download complete";
            }));
        }
    }
}

'@
    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        Add-Type -TypeDefinition $networkSource -ReferencedAssemblies @('System.Net.Http.dll','System.Core.dll','System.dll') -WarningAction SilentlyContinue
    } else { Add-Type -TypeDefinition $networkSource -WarningAction SilentlyContinue }
}

function Say([string]$Message) {
    Write-Host $Message
    if ($script:LogFile) {
        try { Assert-PlainPath $script:LogFile; Add-Content -LiteralPath $script:LogFile -Value ((Get-Date -Format 's') + ' ' + $Message) -Encoding UTF8 }
        catch { Write-Warning 'Could not append to the diagnostic log.' }
    }
}
function Fail([int]$Code, [string]$Message) {
    $e = New-Object Exception($Message); $e.Data['ExitCode'] = $Code; throw $e
}
function Get-Failure($ErrorRecord) {
    $e = $ErrorRecord.Exception; $message = $e.Message; $code = $script:FailureCode
    while ($e) {
        if ($e.Data.Contains('ExitCode')) { $code=[int]$e.Data['ExitCode']; $message=$e.Message; break }
        if ($e -is [PortableUpdater.Failure]) { $code=$e.ExitCode; $message=$e.Message; break }
        if (($e.HResult -band 0xffff) -eq 112) { $code=40 }
        elseif ($e -is [UnauthorizedAccessException]) { $code=41 }
        elseif ($e -is [IO.IOException] -and $code -notin @(50,51)) { $code=41 }
        $e=$e.InnerException
    }
    [pscustomobject]@{Code=$code;Message=$message}
}
function Stage([int]$Percent, [string]$Message) {
    $script:ProgressAt=$Percent
    Say $Message
    Write-Progress -Id 1 -Activity 'VS Code Portable Updater' -Status $Message -PercentComplete $Percent
}
function Wait-Transfer($Transfer) {
    $clock=[Diagnostics.Stopwatch]::StartNew(); $last=$Transfer.Transferred; $lastTime=0.0; $speed=0.0
    try {
        while (-not $Transfer.Completion.IsCompleted) {
            $event=''
            while ($Transfer.Events.TryDequeue([ref]$event)) { Say $event }
            try { if (-not [Console]::IsInputRedirected -and [Console]::KeyAvailable -and [Console]::ReadKey($true).Key -eq 'Escape') { $Transfer.Cancel() } } catch { }
            $done=$Transfer.Received; $total=$Transfer.Total; $fresh=$Transfer.Transferred; $now=$clock.Elapsed.TotalSeconds
            if ($now-$lastTime -ge 0.5) {
                $instant=[math]::Max(0,($fresh-$last)/($now-$lastTime)); $speed=if ($speed -eq 0) {$instant} else {0.7*$speed+0.3*$instant}
                $last=$fresh;$lastTime=$now
            }
            $percent=if ($total -gt 0) {[int][math]::Min(100,100.0*$done/$total)} else {-1}
            $eta=if ($speed -gt 0 -and $total -gt $done) {[int][math]::Min([int]::MaxValue,($total-$done)/$speed)} else {-1}
            $size=if ($total -gt 0) {'{0:N1} / {1:N1} MB' -f ($done/1MB),($total/1MB)} else {'{0:N1} MB' -f ($done/1MB)}
            Write-Progress -Id 2 -ParentId 1 -Activity $Transfer.Phase -Status ("$size | {0:N1} MB/s | Esc to cancel" -f ($speed/1MB)) -PercentComplete $percent -SecondsRemaining $eta
            Start-Sleep -Milliseconds 150
        }
        $event='';while ($Transfer.Events.TryDequeue([ref]$event)) { Say $event }
        [void]$Transfer.Completion.GetAwaiter().GetResult()
        if ($Transfer.Total -gt 0) { Say ('Download transfer completed in {0:N1} s; {1:N1} MB including any resumed parts.' -f $Transfer.ElapsedSeconds,($Transfer.Total/1MB)) }
    } finally { Write-Progress -Id 2 -Activity 'Transfer' -Completed; $Transfer.Dispose() }
}
function Read-Json([string]$File) { Get-Content -LiteralPath $File -Raw -Encoding UTF8 | ConvertFrom-Json }
function New-Dir([string]$Dir) { [IO.Directory]::CreateDirectory($Dir) | Out-Null }
function Has([string]$File) { Test-Path -LiteralPath $File }
function Is-Link([string]$File) { ((Get-Item -LiteralPath $File -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 }
function Assert-PlainPath([string]$File) {
    $part = [IO.Path]::GetFullPath($File)
    while ($part) {
        if ((Has $part) -and (Is-Link $part)) { throw "A symbolic link or junction was found in a managed path: $part" }
        $part = [IO.Path]::GetDirectoryName($part)
    }
}
function Assert-PlainTree([string]$Dir) {
    Assert-PlainPath $Dir
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return }
    foreach ($item in Get-ChildItem -LiteralPath $Dir -Force) {
        if (Is-Link $item.FullName) { throw "A symbolic link was found inside the application files: $($item.FullName)" }
        if ($item.PSIsContainer) { Assert-PlainTree $item.FullName }
    }
}
function Assert-Child([string]$Child, [string]$Parent) {
    $c = [IO.Path]::GetFullPath($Child)
    $p = [IO.Path]::GetFullPath($Parent).TrimEnd('\') + '\'
    if (-not $c.StartsWith($p, [StringComparison]::OrdinalIgnoreCase)) { throw "The path is outside the allowed working folder: $c" }
    Assert-PlainPath $c
}
function Remove-PrivateTree([string]$Dir, [string]$Parent) {
    Assert-Child $Dir $Parent
    if (Has $Dir) { Assert-PlainTree $Dir; Remove-Item -LiteralPath $Dir -Recurse -Force }
}
function Move-AppItem([string]$From, [string]$To) {
    Assert-PlainPath $From; Assert-PlainPath $To
    if (Has $To) { throw "The destination already exists: $To" }
    # Same-volume rename; no wildcard expansion and no overwrite.
    if (Test-Path -LiteralPath $From -PathType Container) { [IO.Directory]::Move($From, $To) }
    else { [IO.File]::Move($From, $To) }
}
function Write-Journal($Journal, [string]$Tx) {
    $file = Join-Path $Tx 'journal.json'
    $tmp = Join-Path $Tx 'journal.tmp'
    Assert-PlainPath $file; Assert-PlainPath $tmp; Assert-PlainPath (Join-Path $Tx 'journal.previous.json')
    $bytes = [Text.Encoding]::UTF8.GetBytes(($Journal | ConvertTo-Json -Depth 8))
    $stream = [IO.File]::Open($tmp, 'Create', 'Write', 'None')
    try { $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
    if (Has $file) { [IO.File]::Replace($tmp,$file,(Join-Path $Tx 'journal.previous.json')) } else { [IO.File]::Move($tmp,$file) }
}
function Assert-Stopped([string]$Root) {
    $prefix = $Root.TrimEnd('\') + '\'
    foreach ($p in Get-Process) {
        $exe = ''
        try { $exe = [string]$p.Path } catch { }
        if (($exe -and $exe.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) -or
            (-not $exe -and $p.ProcessName -in @('Code','code-tunnel'))) {
            Fail 11 "Close VS Code and processes running from this folder, then try again (PID $($p.Id))."
        }
    }
}
function Get-Architecture([string]$Exe) {
    $stream = [IO.File]::OpenRead($Exe); $r = New-Object IO.BinaryReader($stream)
    try {
        if ($r.ReadUInt16() -ne 0x5A4D) { throw 'The executable is missing its MZ header.' }
        $stream.Position = 0x3C; $offset = $r.ReadInt32()
        if ($offset -lt 64 -or $offset -gt ($stream.Length - 6)) { throw 'The executable has an invalid PE header.' }
        $stream.Position = $offset
        if ($r.ReadUInt32() -ne 0x4550) { throw 'The executable is missing its PE header.' }
        switch ($r.ReadUInt16()) { 0x8664 { return 'x64' }; 0xAA64 { return 'arm64' }; default { throw 'Only x64 and ARM64 are supported.' } }
    } finally { $r.Dispose() }
}
function Assert-Microsoft([string]$Exe) {
    $s = Get-AuthenticodeSignature -LiteralPath $Exe
    if ($s.Status -ne 'Valid' -or -not $s.SignerCertificate -or
        $s.SignerCertificate.Subject -notmatch '(^|,\s*)O=Microsoft Corporation(,|$)') {
        Fail 32 "A valid Microsoft signature is required: $Exe ($($s.Status))."
    }
}
function Get-Bundle([string]$Base, [string]$Tag = '') {
    $app = Join-Path $Base 'resources\app'
    if (-not (Has (Join-Path $app 'product.json')) -or -not (Has (Join-Path $app 'package.json'))) { return $null }
    Assert-PlainPath $app
    Assert-PlainPath (Join-Path $app 'product.json'); Assert-PlainPath (Join-Path $app 'package.json')
    try { $p = Read-Json (Join-Path $app 'product.json'); $v = Read-Json (Join-Path $app 'package.json') } catch { return $null }
    foreach ($field in @('applicationName','nameShort','quality','commit')) { if (-not $p.PSObject.Properties[$field]) { return $null } }
    if (-not $v.PSObject.Properties['version']) { return $null }
    if ($p.applicationName -ne 'code' -or $p.nameShort -ne 'Code' -or $p.quality -ne 'stable' -or
        $p.commit -notmatch '^[a-f0-9]{40}$' -or $v.version -notmatch '^\d+\.\d+\.\d+$') { return $null }
    if ($p.PSObject.Properties['target'] -and $p.target -in @('user','system')) { throw 'An installer-based version was detected. Use the official portable ZIP distribution.' }
    if ($Tag -and $Tag -ne $p.commit.Substring(0,10)) { return $null }
    [pscustomobject]@{ Version=[string]$v.version; Commit=[string]$p.commit; Tag=$Tag; App=$app }
}
function Get-Installation([string]$Root) {
    $exe = Join-Path $Root 'Code.exe'; Assert-PlainPath $exe; Assert-Microsoft $exe
    $version = (Get-Item -LiteralPath $exe).VersionInfo.ProductVersion
    if ($version -notmatch '^(\d+\.\d+\.\d+)(?:\s|$)') { throw 'Could not read the version of Code.exe.' }
    $version = $Matches[1]
    $bundles = @()
    $legacy = Get-Bundle $Root
    if ($legacy) { $bundles += $legacy }
    foreach ($d in Get-ChildItem -LiteralPath $Root -Directory -Force) {
        if ($d.Name -match '^[a-f0-9]{10}$' -and -not (Is-Link $d.FullName)) {
            $b = Get-Bundle $d.FullName $d.Name
            if ($b) { $bundles += $b }
        }
    }
    $candidates = @($bundles | Where-Object { $_.Version -eq $version })
    # The installed CLI identifies the active commit; never pick the first stale directory.
    $cmd = Join-Path $Root 'bin\code.cmd'
    if (Has $cmd) {
        Assert-PlainPath $cmd
        $text = Get-Content -LiteralPath $cmd -Raw
        $tags = @([regex]::Matches($text,'(?i)[\\/]([a-f0-9]{10})[\\/]') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
        if ($tags.Count -eq 1) { $candidates = @($candidates | Where-Object { $_.Tag -eq $tags[0] }) }
    }
    if ($candidates.Count -ne 1) { throw 'The active build is ambiguous or damaged. Automatic replacement was cancelled.' }
    $b = $candidates[0]
    [pscustomobject]@{ Version=$b.Version; Commit=$b.Commit; Tag=$b.Tag; App=$b.App; Architecture=(Get-Architecture $exe); Bundles=$bundles }
}
function Assert-Url([uri]$Uri) {
    $allowed = @('update.code.visualstudio.com','vscode.download.prss.microsoft.com')
    if ($Uri.Scheme -ne 'https' -or $Uri.Port -ne 443 -or $Uri.UserInfo -or $Uri.Host -notin $allowed) {
        Fail 23 "The update source is not allowed: $Uri"
    }
}
function Get-Official([string]$Url) {
    Assert-Url ([uri]$Url)
    $settings=New-Object PortableUpdater.TransferOptions; $settings.TotalMs=60000
    $transfer=New-Object PortableUpdater.Transfer($settings,$null)
    $transfer.StartMetadata($Url)
    Wait-Transfer $transfer
    return $transfer.Text
}
function Get-Archive([string]$Url, [string]$Cache) {
    Assert-Url ([uri]$Url); Assert-PlainTree $Cache
    $settings=New-Object PortableUpdater.TransferOptions; $settings.Connections=$Connections
    $transfer=New-Object PortableUpdater.Transfer($settings,$null)
    $transfer.StartDownload($Url,$Cache)
    Wait-Transfer $transfer
    return $transfer.FilePath
}
function Get-Release([string]$Architecture) {
    $m = (Get-Official "https://update.code.visualstudio.com/api/update/win32-$Architecture-archive/stable/latest") | ConvertFrom-Json
    if ($m.version -notmatch '^[a-f0-9]{40}$' -or $m.productVersion -notmatch '^\d+\.\d+\.\d+$' -or
        $m.sha256hash -notmatch '^[a-f0-9]{64}$') { throw 'The release metadata is incomplete or has an unexpected format.' }
    Assert-Url ([uri]$m.url)
    $expected = '/stable/' + $m.version + '/VSCode-win32-' + $Architecture + '-' + $m.productVersion + '.zip'
    if (-not ([uri]$m.url).AbsolutePath.EndsWith($expected,[StringComparison]::Ordinal)) { throw 'The download URL does not match the release version or architecture.' }
    return $m
}
function Assert-ArchiveHash([string]$Zip, [string]$Expected) {
    if ($Expected -notmatch '^[a-f0-9]{64}$' -or (Get-FileHash -LiteralPath $Zip -Algorithm SHA256).Hash -ne $Expected) { Fail 30 'The archive SHA-256 does not match. The installation has not been changed.' }
}
function Expand-CheckedZip([string]$Zip, [string]$Dest) {
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    Assert-PlainPath $Dest
    if (Has $Dest) { throw 'The extraction folder already exists.' }
    $z = [IO.Compression.ZipFile]::OpenRead($Zip)
    try {
        if ($z.Entries.Count -lt 10 -or $z.Entries.Count -gt 100000) { throw 'The ZIP archive contains an unexpected number of entries.' }
        $seen = @{}; [long]$total = 0
        foreach ($e in $z.Entries) {
            $name = $e.FullName.Replace('/','\').TrimEnd('\')
            if (-not $name -or $name.StartsWith('\') -or $name.Contains(':')) { throw 'The ZIP archive contains an unsafe path.' }
            foreach ($segment in $name.Split('\')) {
                if ($segment -in @('','.','..') -or $segment -match '[<>"|?*\x00-\x1f]' -or $segment -match '[. ]$' -or
                    $segment -match '^(?i:CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(?:\.|$)') { throw "The ZIP archive contains an unsafe entry: $name" }
            }
            if ($seen.ContainsKey($name)) { throw "The ZIP archive contains a duplicate path: $name" }; $seen[$name] = $true
            if ((($e.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000 -or ($e.ExternalAttributes -band 0x400) -ne 0) { throw 'Symbolic links are not allowed in the ZIP archive.' }
            $resolved = [IO.Path]::GetFullPath((Join-Path $Dest $name))
            if (-not $resolved.StartsWith(($Dest.TrimEnd('\') + '\'),[StringComparison]::OrdinalIgnoreCase)) { throw 'A ZIP entry points outside the extraction folder.' }
            $total += $e.Length
        }
        if ($total -gt 4GB) { throw 'The extracted archive exceeds the 4 GB limit.' }
        $drive = New-Object IO.DriveInfo([IO.Path]::GetPathRoot($Dest))
        if ($drive.AvailableFreeSpace -lt ($total + 256MB)) { Fail 40 'Not enough disk space for extraction and recovery.' }
        New-Dir $Dest
        $entryIndex=0
        foreach ($e in $z.Entries) {
            if (($entryIndex++ % 100) -eq 0) { Write-Progress -Id 2 -ParentId 1 -Activity 'Extracting verified archive' -Status "$entryIndex / $($z.Entries.Count) entries" -PercentComplete ([int](100.0*$entryIndex/$z.Entries.Count)) }
            $file = Join-Path $Dest ($e.FullName.Replace('/','\'))
            if ($e.FullName.EndsWith('/') -or $e.FullName.EndsWith('\')) { New-Dir $file }
            else { New-Dir ([IO.Path]::GetDirectoryName($file)); [IO.Compression.ZipFileExtensions]::ExtractToFile($e,$file,$false) }
        }
    } finally { $z.Dispose(); Write-Progress -Id 2 -Activity 'Extracting' -Completed }
}
function Assert-NewBuild([string]$Root, $Release, [string]$Architecture) {
    $v = Get-Installation $Root
    if ($v.Version -ne $Release.productVersion -or $v.Commit -ne $Release.version -or $v.Architecture -ne $Architecture) { throw 'The extracted version, commit or architecture does not match the release metadata.' }
    if ($v.Bundles.Count -ne 1 -or -not (Has (Join-Path $v.App 'out\cli.js')) -or -not (Has (Join-Path $Root 'bin\code.cmd'))) { throw 'The ZIP archive is missing required application files.' }
    if ((Has (Join-Path $Root 'data')) -or (Has (Join-Path $Root $script:StateName))) { throw 'The ZIP archive contains a protected user-data or updater folder.' }
    return $v
}
function Invoke-Probe([string]$Root, $Build, [string]$Scratch) {
    # Node CLI only, isolated data path: no editor windows, extensions or user settings.
    $exe = Join-Path $Root 'Code.exe'
    if ($Build.Tag -and (Has (Join-Path $Root ($Build.Tag + '\Code.exe')))) { $exe = Join-Path $Root ($Build.Tag + '\Code.exe') }
    Assert-Microsoft $exe
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $exe
    $info.Arguments = '"' + (Join-Path $Build.App 'out\cli.js') + '" --version'
    $info.WorkingDirectory = $Root; $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    foreach ($name in @('NODE_OPTIONS','VSCODE_DEV','VSCODE_IPC_HOOK_CLI')) { $info.EnvironmentVariables.Remove($name) }
    $info.EnvironmentVariables['ELECTRON_RUN_AS_NODE'] = '1'
    $info.EnvironmentVariables['VSCODE_PORTABLE'] = $Scratch
    $p = New-Object Diagnostics.Process; $p.StartInfo = $info
    try {
        [void]$p.Start(); $stdout = $p.StandardOutput.ReadToEndAsync(); $stderr = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit(30000)) { $p.Kill(); $p.WaitForExit(); throw 'The command-line check timed out after 30 seconds.' }
        $lines = @($stdout.GetAwaiter().GetResult().Trim() -split '\r?\n')
        $err = $stderr.GetAwaiter().GetResult()
        if ($p.ExitCode -ne 0 -or $lines.Count -ne 3 -or $lines[0] -ne $Build.Version -or $lines[1] -ne $Build.Commit -or $lines[2] -ne $Build.Architecture) { throw "The command-line check failed: $err" }
    } finally { $p.Dispose() }
}
function Get-ManagedNames([string]$Root, $Installed) {
    $names = @()
    foreach ($name in $script:KnownFiles) { if (Has (Join-Path $Root $name)) { $names += $name } }
    if (Has (Join-Path $Root 'bin\code.cmd')) { $names += 'bin' }
    # Recognize shared vendor directories by their actual contents, not their name alone.
    if (Has (Join-Path $Root 'tools\inno_updater.exe')) { Assert-Microsoft (Join-Path $Root 'tools\inno_updater.exe'); $names += 'tools' }
    $shellDll = Join-Path $Root ('appx\code_explorer_command_' + $Installed.Architecture + '.dll')
    if (Has $shellDll) { Assert-Microsoft $shellDll; $names += 'appx' }
    if (Has (Join-Path $Root 'policies\VSCode.admx')) {
        $policy = Get-Content -LiteralPath (Join-Path $Root 'policies\VSCode.admx') -Raw
        if ($policy -match 'Microsoft.Policies.VSCode') { $names += 'policies' }
    }
    foreach ($b in $Installed.Bundles) {
        if ($b.Tag) { $names += $b.Tag }
        else {
            $names += 'resources'
            if (Has (Join-Path $Root 'locales')) { $names += 'locales' }
        }
    }
    return @($names | Select-Object -Unique)
}
function Assert-Plan([string]$Root, [string]$New, [string[]]$OldNames, [string[]]$KeepNames) {
    $newNames = @(Get-ChildItem -LiteralPath $New -Force | ForEach-Object Name)
    foreach ($name in @($OldNames) + $newNames) {
        if ($name -in ($script:ProtectedNames + $KeepNames)) { throw "A protected name conflicts with an application entry: $name" }
    }
    foreach ($name in $newNames) {
        if ((Has (Join-Path $Root $name)) -and $name -notin $OldNames) { throw "The new release conflicts with an existing user item '$name'. Move that item manually before updating." }
    }
    foreach ($name in $OldNames) { Assert-PlainTree (Join-Path $Root $name) }
    Assert-PlainTree $New
    return $newNames
}
function Assert-Journal($J, [string]$Root, [string]$Tx) {
    Assert-Child $Tx (Join-Path $Root $script:StateName)
    if ([IO.Path]::GetDirectoryName($Tx) -ne (Join-Path $Root $script:StateName)) { Fail 51 'The recovery folder must be a direct child of the updater state folder.' }
    Assert-PlainPath (Join-Path $Tx 'journal.json')
    if ($J.Schema -notin @(1,2) -or -not $J.Root -or $J.Status -notin @('Applying','Committed','RollingBack','RolledBack')) { Fail 51 "The recovery journal is invalid: $Tx" }
    foreach ($group in @('OldNames','NewNames')) {
        if (-not $J.PSObject.Properties[$group] -or @($J.$group).Count -eq 0) { Fail 51 'The recovery journal has an empty file list.' }
        $seen=@{}
        foreach ($n in @($J.$group)) {
            if ($n -notmatch '^[a-zA-Z0-9_.-]+$' -or $n -in (@('.','..') + $script:ProtectedNames) -or $seen.ContainsKey($n)) { Fail 51 'The recovery journal contains an unsafe or duplicate entry.' }
            $seen[$n]=$true
        }
    }
    if ($J.Schema -eq 2 -and (-not $J.PSObject.Properties['Original'] -or $J.Original.Commit -notmatch '^[a-f0-9]{40}$')) { Fail 51 'The recovery journal has no valid original build identity.' }
}
function Undo-Transaction([string]$Root, [string]$Tx) {
    $script:FailureCode=51
    Assert-PlainPath (Join-Path $Tx 'journal.json')
    $j = Read-Json (Join-Path $Tx 'journal.json'); Assert-Journal $j $Root $Tx
    Assert-Stopped $Root
    Assert-PlainTree (Join-Path $Tx 'old'); Assert-PlainTree (Join-Path $Tx 'new')
    # Check recoverability before moving anything. A deleted backup must not look like success.
    foreach ($name in @($j.OldNames)) {
        $backup=Join-Path $Tx ('old\'+$name);$live=Join-Path $Root $name;$staged=Join-Path $Tx ('new\'+$name)
        if (-not (Has $backup) -and (-not (Has $live) -or ($name -in @($j.NewNames) -and -not (Has $staged)))) { Fail 51 "An original entry is missing from the backup: $name. Keep all operation files for manual recovery." }
    }
    $j.Status = 'RollingBack'
    try { Write-Journal $j $Tx } catch { Say 'Could not save the rollback status. Recovering from the existing journal.' }
    foreach ($name in @($j.NewNames)) {
        $staged = Join-Path $Tx ('new\' + $name); $live = Join-Path $Root $name
        if (-not (Has $staged) -and (Has $live)) { Move-AppItem $live $staged }
    }
    foreach ($name in @($j.OldNames)) {
        $backup = Join-Path $Tx ('old\' + $name)
        if (Has $backup) { Move-AppItem $backup (Join-Path $Root $name) }
        if (-not (Has (Join-Path $Root $name))) { Fail 51 "Recovery is incomplete: $name is missing." }
    }
    $restored=Get-Installation $Root
    if ($j.Schema -eq 2 -and ($restored.Commit -ne $j.Original.Commit -or $restored.Version -ne $j.Original.Version -or $restored.Architecture -ne $j.Original.Architecture)) { Fail 51 'The restored application does not match the original build.' }
    $j.Status = 'RolledBack'; Write-Journal $j $Tx
    Say "The previous application files have been restored. Operation files: $Tx"
}
function Apply-Transaction([string]$Root, [string]$Tx, [string[]]$OldNames, [string[]]$NewNames, $Release, [string]$Architecture) {
    $original=Get-Installation $Root
    $j = [pscustomobject]@{ Schema=2; Root=$Root; Status='Applying'; OldNames=@($OldNames); NewNames=@($NewNames); Version=$Release.productVersion; Commit=$Release.version; Original=[pscustomobject]@{Version=$original.Version;Commit=$original.Commit;Architecture=$original.Architecture} }
    New-Dir (Join-Path $Tx 'old')
    Assert-Journal $j $Root $Tx
    Write-Journal $j $Tx
    # Exercise atomic journal replacement before changing the installation.
    Write-Journal $j $Tx
    try {
        Assert-Stopped $Root
        foreach ($name in $OldNames) { Move-AppItem (Join-Path $Root $name) (Join-Path $Tx ('old\' + $name)) }
        foreach ($name in $NewNames) { Move-AppItem (Join-Path $Tx ('new\' + $name)) (Join-Path $Root $name) }
        $build = Get-Installation $Root
        if ($build.Commit -ne $Release.version -or $build.Version -ne $Release.productVersion -or $build.Architecture -ne $Architecture) { throw 'The installed version check failed.' }
        Invoke-Probe $Root $build (Join-Path $Tx 'probe')
        $j.Status = 'Committed'; Write-Journal $j $Tx
    } catch {
        $reason = $_.Exception.Message
        try { Undo-Transaction $Root $Tx } catch { Fail 51 "Update failed: $reason`nRecovery could not finish: $($_.Exception.Message)`nClose VS Code and run the updater again. Keep $Tx" }
        Fail 50 "The update failed and the previous files were restored. Reason: $reason"
    }
}
function Invoke-Updater {
    $script:FailureCode=10
    if ($CheckOnly -and $Rollback) { Fail 10 'CheckOnly and Rollback cannot be used together.' }
    $root = (Resolve-Path -LiteralPath $Path).ProviderPath.TrimEnd('\')
    if ($root -notmatch '^[a-zA-Z]:\\' -or $root.Length -le 3) { Fail 10 'Choose a folder on a local drive. Drive roots and UNC paths are not supported.' }
    Assert-PlainPath $root
    if (-not (Test-Path -LiteralPath (Join-Path $root 'data') -PathType Container)) { Fail 10 'No data folder was found next to Code.exe. Select an existing portable installation.' }
    foreach ($n in $Keep) { if ($n -notmatch '^[^\\/:]+$' -or $n -in @('.','..')) { Fail 10 'Keep accepts only names in the installation root.' } }
    $state = Join-Path $root $script:StateName; Assert-PlainPath $state
    $lock = $null; $tx = $null; $cache=$null
    try {
        if (-not $CheckOnly) {
            $script:FailureCode=41
            New-Dir $state
            $lockPath=Join-Path $state 'update.lock'; Assert-PlainPath $lockPath
            try { $lock = [IO.File]::Open($lockPath,'OpenOrCreate','ReadWrite','None') }
            catch [IO.IOException] { Fail 12 'Another updater may be using this installation. Close it and retry.' }
            $script:LogFile=Join-Path $state 'last-run.log'; Assert-PlainPath $script:LogFile
            [IO.File]::WriteAllText($script:LogFile,('VS Code Portable Updater 2.0 - '+(Get-Date -Format 's')+"`r`n"))
        }
        $script:FailureCode=51
        $history = @()
        if (Has $state) {
            foreach ($dir in Get-ChildItem -LiteralPath $state -Directory -Force | Sort-Object Name) {
                if ($dir.Name -match '^tx-[0-9]{8}-[0-9]{6}-[a-f0-9]{8}$' -and (Has (Join-Path $dir.FullName 'journal.json'))) {
                    Assert-PlainPath (Join-Path $dir.FullName 'journal.json')
                    $j = Read-Json (Join-Path $dir.FullName 'journal.json'); Assert-Journal $j $root $dir.FullName
                    $history += [pscustomobject]@{ Dir=$dir.FullName; Journal=$j }
                }
            }
        }
        $pending = @($history | Where-Object { $_.Journal.Status -in @('Applying','RollingBack') })
        if ($pending.Count -gt 1) { Fail 51 'Multiple unfinished operations were found. Inspect the backups before continuing.' }
        if ($pending.Count -eq 1) {
            if ($CheckOnly) { Fail 51 'An unfinished operation was found. Choose Update to recover it first.' }
            Stage 90 'Recovering the previous installation...'
            Undo-Transaction $root $pending[0].Dir
            Say 'Recovery is complete. Run the updater again to start a new update.'; return
        }
        if ($Rollback) {
            if (-not $history.Count -or $history[-1].Journal.Status -ne 'Committed') { Fail 51 'There is no latest successful update available to roll back.' }
            $current = Get-Installation $root
            if ($current.Commit -ne $history[-1].Journal.Commit) { Fail 51 'The installed build has changed since the update. Automatic rollback was cancelled.' }
            Stage 90 'Restoring the previous application files...'
            Undo-Transaction $root $history[-1].Dir; return
        }
        $script:FailureCode=10
        Stage 5 'Checking the installed application...'
        $installed = Get-Installation $root
        Say "Installed: $($installed.Version), $($installed.Architecture)"
        $script:FailureCode=22
        Stage 10 'Checking the latest official Stable release...'
        $release = Get-Release $installed.Architecture
        Say "Latest official Stable: $($release.productVersion)"
        if ([version]$release.productVersion -lt [version]$installed.Version) { Fail 10 'The server returned an older version. Automatic downgrades are not allowed.' }
        if ($CheckOnly) { return }
        $script:FailureCode=10
        $oldNames = @(Get-ManagedNames $root $installed)
        $stale = @($installed.Bundles | Where-Object { $_.Commit -ne $installed.Commit })
        if ($installed.Commit -eq $release.version -and -not $Reinstall -and -not $stale.Count) { Say 'The installed version is already up to date.'; return }
        Assert-Stopped $root
        $script:FailureCode=41
        $cacheParent=Join-Path $state 'downloads'
        $cache=Join-Path $cacheParent $release.sha256hash
        Assert-Child $cache $state;New-Dir $cache;Assert-PlainTree $cache
        $zip=Join-Path $cache 'archive.zip';Assert-PlainPath $zip
        if (-not (Has $zip)) {
            $script:FailureCode=20
            Stage 20 'Downloading the official archive (Esc cancels; saved parts can resume)...'
            $zip=Get-Archive $release.url $cache
        } else { Say 'Using the previously downloaded archive; verifying it again.' }
        $script:FailureCode=30
        Stage 55 'Verifying the archive SHA-256...'
        try { Assert-ArchiveHash $zip $release.sha256hash }
        catch { Remove-PrivateTree $cache $cacheParent; Fail 30 'The downloaded archive failed SHA-256 verification. The cache was discarded; run the updater again for a fresh download.' }
        $tx = Join-Path $state ('tx-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8))
        New-Dir $tx
        $new=Join-Path $tx 'new'
        $script:FailureCode=31
        Stage 65 'Extracting and validating the new application...'
        Expand-CheckedZip $zip $new
        $build = Assert-NewBuild $new $release $installed.Architecture
        Invoke-Probe $new $build (Join-Path $tx 'probe')
        $script:FailureCode=10
        $newNames = @(Assert-Plan $root $new $oldNames $Keep)
        $script:FailureCode=41
        Stage 90 'Replacing application files. Keep this window open until recovery is safe.'
        Apply-Transaction $root $tx $oldNames $newNames $release $installed.Architecture
        try { Remove-PrivateTree $cache $cacheParent;Remove-PrivateTree (Join-Path $tx 'probe') $tx }
        catch { Say 'The update succeeded; some cache files remain in the updater folder.' }
        Stage 100 "Done: VS Code $($release.productVersion)."
        Say "Backup: $tx\old"
        Say 'Choose Rollback in the updater menu to restore the previous application files.'
    } catch {
        if ($tx -and -not (Has (Join-Path $tx 'journal.json'))) {
            try { Remove-PrivateTree $tx $state } catch { Say "The temporary folder was kept for inspection: $tx" }
        }
        throw
    } finally { if ($lock) { $lock.Dispose() };Write-Progress -Id 2 -Activity 'Operation' -Completed;Write-Progress -Id 1 -Activity 'VS Code Portable Updater' -Completed }
}

function Start-App {
    try {
        Write-Host "`n  VS Code Portable Updater 2.0" -ForegroundColor Cyan
        Write-Host "  Official Stable | download, update and recovery`n"
        if ($Action -eq 'Menu') {
            while ($true) {
                Write-Host "  Folder: $Path"
                Write-Host '  [1] Update   [2] Check version   [3] Rollback'
                Write-Host '  [4] Choose folder   [5] Reinstall   [6] Use one connection   [0] Exit'
                $choice=Read-Host '  Choose an action (Enter = Update)'
                switch ($choice) {
                    {$_ -in @('','1')} { $Action='Update' }
                    '2' {$Action='Check'}
                    '3' {$Action='Rollback'}
                    '4' { $candidate=Read-Host '  Paste the VS Code folder path';if ($candidate) {$Path=$candidate.Trim().Trim('"')};continue }
                    '5' { $Action='Update';$Reinstall=$true }
                    '6' { $Connections=1;Write-Host '  One connection selected for this run.';continue }
                    '0' {return 2}
                    default { Write-Host '  Enter a number from 0 to 6.';continue }
                }
                if ($Action -ne 'Menu') {break}
            }
        }
        if ($Action -notin @('Update','Check','Rollback')) { Fail 10 'Unknown action. Use Update, Check or Rollback.' }
        if ($Action -eq 'Check') {$CheckOnly=$true}
        if ($Action -eq 'Rollback') {$Rollback=$true}
        Invoke-Updater
        Say 'Finished successfully. [0]'
        return 0
    } catch {
        $failure=Get-Failure $_
        $name=$script:ErrorNames[$failure.Code]
        if (-not $name) {$name='UNEXPECTED'}
        Say "ERROR [$($failure.Code) / $name]: $($failure.Message)"
        if ($failure.Code -in @(20,21,22)) { Say 'Check the connection and retry. Completed download parts are kept; retries are limited to three attempts.' }
        if ($failure.Code -eq 51) { Say 'Keep the updater state folder and backups. Close VS Code before attempting recovery again.' }
        if ($script:LogFile) { Write-Host "Details: $script:LogFile" }
        return $failure.Code
    }
}
if ($MyInvocation.InvocationName -ne '.') { $result=Start-App; exit $result }

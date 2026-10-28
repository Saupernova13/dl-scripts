# Launch a PowerShell script as a detached background worker and return its pid.
#
# Generic form of dlrom's Start-DlromJob (dlrom/Jobs.ps1), for tools that hand a long job to a
# worker and return to the caller immediately. dlrom still carries its own copy; migrating it
# onto this helper is a separate change.
#
# Needs lib/Platform.ps1 (Test-DlWindows) loaded first - DriveResolver.ps1 does that.

# Launch the script as a detached process and return immediately.
#
# Two load-bearing details on Windows:
#   * CreateNoWindow + UseShellExecute=$false, via raw ProcessStartInfo. Start-Process
#     cannot express CreateNoWindow, so it flashes a console window.
#   * The worker must NOT inherit this console's handles, or the caller's .cmd stays attached
#     to it and the caller's terminal hangs. cmd's own `> log 2>&1` gives the worker a file
#     for stdout/stderr, and redirecting stdin (then closing it) makes a stray prompt hit EOF
#     rather than block forever.
#
# Linux needs both for a different reason: the common caller is `ssh deck 'dltv ...'`, and
# sshd waits on any pipe the worker still holds.
#
# Escaping the dying session needs more than setsid. SteamOS sets KillUserProcesses=True, and
# logind kills the session's whole CGROUP on teardown - a new session id does not leave that
# cgroup, so a setsid'd worker dies the instant the ssh command returns, leaving the job at
# "pending" with an empty log. systemd-run --user puts it under user@1000.service instead,
# which teardown does not touch; setsid stays as the fallback where that is unavailable.
#
# To outlive the *last* session too, the user manager must persist: `loginctl enable-linger`.
#
# The pid returned on Windows is cmd.exe's, not the worker's. A worker that needs an accurate
# pid in its job file must record its own $PID, as dlrom's and dltv's do.
function Start-DlDetachedScript {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [string[]]$ScriptArgs = @(),
        [Parameter(Mandatory)][string]$LogFile,
        [Parameter(Mandatory)][string]$UnitName     # systemd unit stem on Linux, e.g. "dltv-<jobId>"
    )

    $psExe = (Get-Process -Id $PID).Path        # re-run the same PowerShell we are on
    if (-not $psExe) { $psExe = if (Test-DlWindows) { 'powershell.exe' } else { 'pwsh' } }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.CreateNoWindow  = $true
    $psi.UseShellExecute = $false

    if (Test-DlWindows) {
        # cmd /c ""ps.exe" -File "script" "arg" ... > "log" 2>&1"
        $argText = ''
        foreach ($a in $ScriptArgs) { $argText += ' "{0}"' -f $a }
        $inner = '"{0}" -NoProfile -ExecutionPolicy Bypass -File "{1}"{2} > "{3}" 2>&1' -f `
                    $psExe, $ScriptPath, $argText, $LogFile
        $psi.FileName              = 'cmd.exe'
        $psi.Arguments             = "/c `"$inner`""
        $psi.RedirectStandardInput = $true
    } else {
        # Prefer a transient user-manager unit; fall back to setsid where systemd-run or a
        # user bus is missing. A runtime probe, not an OS guess - either can be absent
        # anywhere. --collect reaps the unit on exit so no failed unit is left behind, and
        # the pid comes from `systemctl show` because the worker is a grandchild of systemd,
        # not of this shell, so $! would be the systemd-run client that exits immediately.
        $q = { param($s) "'" + ($s -replace "'", "'\''") + "'" }
        $qLog   = & $q $LogFile
        $worker = '{0} -NoProfile -File {1}' -f (& $q $psExe), (& $q $ScriptPath)
        foreach ($a in $ScriptArgs) { $worker += ' ' + (& $q $a) }

        $sdRun = "systemd-run --user --collect --quiet --unit=$UnitName " +
                 "--property=StandardOutput=append:$qLog " +
                 "--property=StandardError=append:$qLog " +
                 "--property=StandardInput=null $worker"

        $inner = @(
            'has_user_bus() { command -v systemd-run >/dev/null 2>&1 && [ -S "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/bus" ]; }'
            "if has_user_bus && $sdRun >/dev/null 2>&1; then"
            "    systemctl --user show -p MainPID --value $UnitName.service 2>/dev/null"
            '    exit 0'
            'fi'
            "setsid $worker > $qLog 2>&1 < /dev/null & echo `$!"
        ) -join "`n"
        $psi.FileName               = '/bin/sh'
        $psi.ArgumentList.Add('-c')
        $psi.ArgumentList.Add($inner)
        $psi.RedirectStandardOutput = $true
    }

    $proc = [System.Diagnostics.Process]::Start($psi)
    if (-not $proc) { throw "Failed to start detached worker process" }

    if (Test-DlWindows) {
        $proc.StandardInput.Close()
    } else {
        $workerPid = ($proc.StandardOutput.ReadLine() -as [int])
        $proc.WaitForExit()
        if ($workerPid) { return $workerPid }
    }

    return $proc.Id
}

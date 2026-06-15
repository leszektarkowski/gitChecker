using System.Diagnostics;

namespace WinGitChecker;

/// Opens a terminal with the working directory set to a repo path.
/// Mirrors the macOS client's "open Terminal at the repo folder" behaviour.
public static class TerminalLauncher
{
    public static void Open(string path)
    {
        // Prefer Windows Terminal (wt.exe) opened at the directory; fall back to
        // PowerShell rooted in the folder if Windows Terminal isn't installed.
        if (TryStart(new ProcessStartInfo
        {
            FileName = "wt.exe",
            Arguments = $"-d \"{path}\"",
            UseShellExecute = true,
        }))
            return;

        if (TryStart(new ProcessStartInfo
        {
            FileName = "powershell.exe",
            WorkingDirectory = path,
            UseShellExecute = true,
        }))
            return;

        // Last resort: open the folder in Explorer so the click still does something.
        TryStart(new ProcessStartInfo
        {
            FileName = path,
            UseShellExecute = true,
        });
    }

    private static bool TryStart(ProcessStartInfo info)
    {
        try
        {
            Process.Start(info);
            return true;
        }
        catch
        {
            return false;
        }
    }
}

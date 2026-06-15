using System.Text.Json.Serialization;

namespace WinGitChecker;

/// Sync relationship with upstream. Mirrors the server's tagged enum:
/// {"kind":"none"} or {"kind":"tracking","name":...,"ahead":N,"behind":N}.
public sealed class Upstream
{
    public string Kind { get; init; } = "none";
    public string? Name { get; init; }
    public int? Ahead { get; init; }
    public int? Behind { get; init; }

    [JsonIgnore]
    public bool IsTracking => Kind == "tracking";
}

/// One repository's status, decoded from GET /repos.
/// JSON is snake_case; the deserializer uses SnakeCaseLower naming.
public sealed class RepoStatus
{
    public string Id { get; init; } = "";
    public string Path { get; init; } = "";
    public string? Branch { get; init; }
    public bool DetachedHead { get; init; }
    public bool HasStaged { get; init; }
    public bool HasUnstaged { get; init; }
    public bool HasUntracked { get; init; }
    public int StashCount { get; init; }
    public string Operation { get; init; } = "clean";
    public Upstream Upstream { get; init; } = new();
    public string? Error { get; init; }
    public long? LastChecked { get; init; }
    public long? LastFetched { get; init; }
    public string? LastFetchError { get; init; }

    /// Last path component, for display.
    [JsonIgnore]
    public string Name
    {
        get
        {
            var trimmed = Path.TrimEnd('\\', '/');
            var name = System.IO.Path.GetFileName(trimmed);
            return string.IsNullOrEmpty(name) ? trimmed : name;
        }
    }

    [JsonIgnore] public int Ahead => Upstream.Ahead ?? 0;
    [JsonIgnore] public int Behind => Upstream.Behind ?? 0;

    [JsonIgnore] public bool HasWorkingTreeChanges => HasStaged || HasUnstaged || HasUntracked;
    [JsonIgnore] public bool OperationInProgress => Operation != "clean";

    /// Mirrors the server's is_dirty: any local work at risk.
    [JsonIgnore]
    public bool NeedsAttention =>
        HasWorkingTreeChanges || StashCount > 0 || OperationInProgress || Ahead > 0;

    /// True when this repo should appear in the panel list at all.
    [JsonIgnore]
    public bool ShouldList =>
        NeedsAttention || Behind > 0 || LastFetchError != null || Error != null;

    /// Whether the badge string should be tinted as a warning.
    [JsonIgnore]
    public bool HasProblem => LastFetchError != null || Error != null;

    /// Compact status badges for a row, e.g. ["↑2", "●", "↓1", "⚠"].
    [JsonIgnore]
    public IReadOnlyList<string> Badges
    {
        get
        {
            var outp = new List<string>();
            if (Ahead > 0) outp.Add($"↑{Ahead}");
            if (Behind > 0) outp.Add($"↓{Behind}");
            if (HasWorkingTreeChanges) outp.Add("●");
            if (StashCount > 0) outp.Add($"⚑{StashCount}");
            if (OperationInProgress) outp.Add(Operation);
            if (DetachedHead) outp.Add("detached");
            if (LastFetchError != null) outp.Add("⚠");
            if (Error != null) outp.Add("error");
            return outp;
        }
    }
}

/// Aggregate counts, decoded from GET /summary.
public sealed class Summary
{
    public int Total { get; init; }
    public int Attention { get; init; }
    public int Uncommitted { get; init; }
    public int Ahead { get; init; }
    public int Behind { get; init; }
    public int Stashed { get; init; }
    public int InProgress { get; init; }
    public int FetchErrors { get; init; }
    public int ReadErrors { get; init; }

    public static readonly Summary Empty = new();
}

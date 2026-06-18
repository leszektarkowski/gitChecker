using System.Net;
using System.Net.Http;
using System.Net.Http.Json;
using System.Net.Sockets;
using System.Text.Json;

namespace WinGitChecker;

/// Application state: polls the gitchecker service and raises <see cref="Changed"/>
/// whenever the summary / repo list / connection state updates.
///
/// Polling is driven by a WinForms timer so every tick and every async
/// continuation lands back on the UI thread — handlers can touch controls freely.
public sealed class AppModel : IDisposable
{
    public Summary Summary { get; private set; } = Summary.Empty;
    public IReadOnlyList<RepoStatus> Repos { get; private set; } = Array.Empty<RepoStatus>();
    public DateTime? LastRefresh { get; private set; }
    /// Non-null when the service can't be reached (e.g. daemon not running).
    public string? ConnectionError { get; private set; }
    /// True while a (potentially slower) rescan is in flight, for UI feedback.
    public bool IsScanning { get; private set; }

    /// Whether the panel is currently visible. Drives how hard we poll.
    public bool IsPanelOpen { get; private set; }

    /// Raised on the UI thread after any state change.
    public event Action? Changed;

    // Poll cadences. The background poll NEVER triggers a server-side re-check
    // (that's git work); it only reads cached state. Re-checks happen on the
    // server's own timer, on panel-open, and on the Refresh/Rescan buttons — so
    // an idle, closed tray costs nothing but a cheap /summary read every minute.
    private const int OpenIntervalMs = 30_000;
    private const int ClosedIntervalMs = 60_000;
    private readonly HttpClient _http;
    private readonly System.Windows.Forms.Timer _timer = new();
    private readonly JsonSerializerOptions _json = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
        PropertyNameCaseInsensitive = true,
    };
    private bool _busy;

    public AppModel()
    {
        _http = new HttpClient
        {
            BaseAddress = new Uri("http://127.0.0.1:7878/"),
            Timeout = TimeSpan.FromSeconds(5),
        };
        _timer.Tick += OnTick;
    }

    /// Headline badge count for the tray icon.
    public int BadgeCount => Summary.Attention;

    /// Repos worth showing, attention-first then alphabetical.
    public IReadOnlyList<RepoStatus> AttentionRepos =>
        Repos.Where(r => r.ShouldList)
             .OrderBy(r => r.Name, StringComparer.OrdinalIgnoreCase)
             .ToList();

    /// Begin polling. The first poll fires almost immediately, then settles into
    /// the cadence appropriate to the panel state (60s closed, 30s open).
    public void Start()
    {
        _timer.Interval = 200;
        _timer.Start();
    }

    private async void OnTick(object? sender, EventArgs e)
    {
        // Settle into the cadence for the current panel state.
        _timer.Interval = IsPanelOpen ? OpenIntervalMs : ClosedIntervalMs;
        // Cheap: read cached state only — never a server-side re-check. Fetch the
        // repo list only when the panel is open (the only time it's visible).
        await ReloadAsync(trigger: null, includeList: IsPanelOpen);
    }

    /// The panel became visible: switch to the fast cadence and pull fresh,
    /// fully re-checked data right now.
    public void PanelOpened()
    {
        IsPanelOpen = true;
        _timer.Interval = OpenIntervalMs;
        _ = RefreshAsync();
    }

    /// The panel was hidden: drop back to the cheap badge-only idle poll.
    public void PanelClosed()
    {
        IsPanelOpen = false;
        _timer.Interval = ClosedIntervalMs;
    }

    /// Re-inspect known repos server-side (POST /check is synchronous), then reload.
    /// This is what makes Refresh pick up a repo you just cleaned or changed.
    public Task RefreshAsync() => ReloadAsync(trigger: "check");

    /// Re-discover repos under the configured roots (POST /scan finds new ones /
    /// prunes gone ones and re-checks), then reload.
    public async Task RescanAsync()
    {
        IsScanning = true;
        Changed?.Invoke();
        await ReloadAsync(trigger: "scan");
        IsScanning = false;
        Changed?.Invoke();
    }

    /// POST <paramref name="trigger"/> (if any), then GET /summary (always) and
    /// /repos (only when <paramref name="includeList"/>).
    private async Task ReloadAsync(string? trigger, bool includeList = true)
    {
        if (_busy) return;
        _busy = true;
        try
        {
            if (trigger != null)
                await PostAsync(trigger);

            var summary = await GetAsync<Summary>("summary");
            Summary = summary ?? Summary.Empty;
            if (includeList)
            {
                var repos = await GetAsync<List<RepoStatus>>("repos");
                Repos = repos ?? new List<RepoStatus>();
            }
            ConnectionError = null;
            LastRefresh = DateTime.Now;
        }
        catch (Exception ex)
        {
            ConnectionError = FriendlyError(ex);
        }
        finally
        {
            _busy = false;
            Changed?.Invoke();
        }
    }

    private async Task<T?> GetAsync<T>(string path)
    {
        using var resp = await _http.GetAsync(path);
        resp.EnsureSuccessStatusCode();
        return await resp.Content.ReadFromJsonAsync<T>(_json);
    }

    private async Task PostAsync(string path)
    {
        using var resp = await _http.PostAsync(path, content: null);
        resp.EnsureSuccessStatusCode();
    }

    private static string FriendlyError(Exception error)
    {
        // A connection refused / DNS failure surfaces as HttpRequestException
        // wrapping a SocketException; a timeout as TaskCanceledException.
        if (error is TaskCanceledException or TimeoutException)
            return "service timed out";

        for (Exception? e = error; e != null; e = e.InnerException)
        {
            if (e is SocketException
                or HttpRequestException { StatusCode: null })
                return "service not running";
        }
        return error.Message;
    }

    public void Dispose()
    {
        _timer.Stop();
        _timer.Dispose();
        _http.Dispose();
    }
}

using System.Drawing;

namespace WinGitChecker;

/// Owns the tray icon, the popup panel and the model. The process has no main
/// window — it lives entirely in the notification area, like the macOS menu bar
/// agent (NSApp .accessory policy).
public sealed class TrayApp : ApplicationContext
{
    private readonly AppModel _model = new();
    private readonly NotifyIcon _tray = new();
    private readonly PanelForm _panel;

    private IntPtr _iconHandle = IntPtr.Zero;
    /// Suppresses the click that immediately follows a click-to-dismiss, so the
    /// panel toggles instead of flickering closed-then-open.
    private DateTime _lastHidden = DateTime.MinValue;

    public TrayApp()
    {
        _panel = new PanelForm(_model);
        _panel.VisibleChanged += (_, _) =>
        {
            // Fetch fresh on open, drop to the cheap idle poll on close.
            if (_panel.Visible)
            {
                _model.PanelOpened();
            }
            else
            {
                _lastHidden = DateTime.Now;
                _model.PanelClosed();
            }
        };

        var menu = new ContextMenuStrip();
        menu.Items.Add("Refresh", null, async (_, _) => await _model.RefreshAsync());
        menu.Items.Add("Rescan", null, async (_, _) => await _model.RescanAsync());
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Quit", null, (_, _) => ExitThread());

        _tray.Text = "gitchecker";
        _tray.ContextMenuStrip = menu;
        _tray.Visible = true;
        _tray.MouseClick += OnTrayClick;
        UpdateIcon();

        _model.Changed += OnModelChanged;
        _model.Start();
    }

    private void OnTrayClick(object? sender, MouseEventArgs e)
    {
        if (e.Button != MouseButtons.Left) return;

        if (_panel.Visible)
        {
            _panel.Hide();
        }
        else if ((DateTime.Now - _lastHidden).TotalMilliseconds > 250)
        {
            _panel.ShowNearTray();
        }
    }

    private void OnModelChanged()
    {
        UpdateIcon();
    }

    private void UpdateIcon()
    {
        int count = _model.BadgeCount;
        bool attention = count > 0;

        var old = _iconHandle;
        var icon = IconRenderer.Build(count, attention, out _iconHandle);
        var previous = _tray.Icon;
        _tray.Icon = icon;
        previous?.Dispose();
        IconRenderer.Release(old);

        _tray.Text = _model.ConnectionError is { } err
            ? $"gitchecker — {err}"
            : attention
                ? $"gitchecker — {count} need attention"
                : "gitchecker — all clean";
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _tray.Visible = false;
            _tray.Icon?.Dispose();
            IconRenderer.Release(_iconHandle);
            _tray.Dispose();
            _panel.Dispose();
            _model.Dispose();
        }
        base.Dispose(disposing);
    }
}

using System.Drawing;
using System.Runtime.InteropServices;

namespace WinGitChecker;

/// The borderless popup shown when the tray icon is clicked. Mirrors the macOS
/// client's window-style menu: header, repo list with compact badges, footer.
public sealed class PanelForm : Form
{
    // GetDpiForWindow is reliable as soon as the handle exists; Control.DeviceDpi
    // can still read 96 at construction time (before the window settles on its
    // monitor), which would make the DPI scaling a no-op and clip all the text.
    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(IntPtr hwnd);

    private readonly AppModel _model;

    private readonly Panel _header = new();
    private readonly Label _title = new();
    private readonly Label _trackedLabel = new();
    private readonly Panel _list = new();
    private readonly Panel _footer = new();
    private readonly Label _statusLabel = new();
    private readonly Button _rescan = new();
    private readonly Button _refresh = new();
    private readonly Button _quit = new();

    private static readonly Color Bg = Color.FromArgb(0x25, 0x25, 0x25);
    private static readonly Color Fg = Color.FromArgb(0xF0, 0xF0, 0xF0);
    private static readonly Color Secondary = Color.FromArgb(0x9A, 0x9A, 0x9A);
    private static readonly Color Hover = Color.FromArgb(0x3A, 0x3A, 0x3A);
    private static readonly Color WarnFg = Color.FromArgb(0xF0, 0xA0, 0x30);
    private static readonly Color OkGreen = Color.FromArgb(0x4C, 0xC0, 0x6A);

    // Logical sizes, in 96-DPI pixels. Everything is multiplied by Sc() so the
    // layout tracks the monitor DPI (the app is PerMonitorV2-aware, so point-size
    // fonts render larger on a scaled display and fixed-pixel boxes would clip).
    private const int PanelWidth = 460;
    private const int MaxListHeight = 540;
    private const int HeaderHeight = 46;
    private const int FooterHeight = 50;
    private const int RowHeight = 62;
    private const int BadgeWidth = 200;

    public PanelForm(AppModel model)
    {
        _model = model;

        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        // We scale every dimension manually via Sc(); let WinForms not also do it.
        AutoScaleMode = AutoScaleMode.None;
        BackColor = Bg;
        ForeColor = Fg;
        Font = new Font("Segoe UI", 10.5f);

        BuildChrome();
        _model.Changed += OnModelChanged;
    }

    /// Current monitor DPI. Uses GetDpiForWindow once the handle exists (reliable),
    /// falling back to DeviceDpi only before then.
    private int Dpi
    {
        get
        {
            if (IsHandleCreated)
            {
                int d = (int)GetDpiForWindow(Handle);
                if (d > 0) return d;
            }
            return DeviceDpi;
        }
    }

    /// Scale a logical (96-DPI) pixel value to the current monitor DPI.
    private int Sc(int px) => (int)Math.Round(px * Dpi / 96.0);

    // ---- layout scaffolding -------------------------------------------------

    private void BuildChrome()
    {
        // Structure + fonts only; all pixel sizes are set in ApplyMetrics() once
        // the real monitor DPI is known (see Dpi/Sc).
        _header.Dock = DockStyle.Top;
        _title.Text = "⎇ gitchecker";
        _title.Dock = DockStyle.Left;
        _title.AutoSize = false;
        _title.TextAlign = ContentAlignment.MiddleLeft;
        _title.Font = new Font("Segoe UI", 13f, FontStyle.Bold);
        _title.ForeColor = Fg;
        _trackedLabel.Dock = DockStyle.Right;
        _trackedLabel.TextAlign = ContentAlignment.MiddleRight;
        _trackedLabel.ForeColor = Secondary;
        _trackedLabel.Font = new Font("Segoe UI", 10f);
        _header.Controls.Add(_title);
        _header.Controls.Add(_trackedLabel);

        _list.Dock = DockStyle.Fill;
        _list.AutoScroll = true;

        _footer.Dock = DockStyle.Bottom;
        _statusLabel.Dock = DockStyle.Fill;
        _statusLabel.AutoSize = false;
        _statusLabel.TextAlign = ContentAlignment.MiddleLeft;
        _statusLabel.ForeColor = Secondary;
        _statusLabel.Font = new Font("Segoe UI", 9.5f);

        StyleFooterButton(_quit, "Quit");
        StyleFooterButton(_refresh, "Refresh");
        StyleFooterButton(_rescan, "Rescan");
        _quit.Dock = DockStyle.Right;
        _refresh.Dock = DockStyle.Right;
        _rescan.Dock = DockStyle.Right;

        _rescan.Click += async (_, _) => await _model.RescanAsync();
        _refresh.Click += async (_, _) => await _model.RefreshAsync();
        _quit.Click += (_, _) => Application.Exit();

        // Fill first (lowest z-order) so it takes the space left by the buttons.
        _footer.Controls.Add(_statusLabel);
        _footer.Controls.Add(_quit);
        _footer.Controls.Add(_refresh);
        _footer.Controls.Add(_rescan);

        var sep1 = new Panel { Dock = DockStyle.Top, Height = 1, BackColor = Hover };
        var sep2 = new Panel { Dock = DockStyle.Bottom, Height = 1, BackColor = Hover };

        // Add fill first so it doesn't cover the docked bars.
        Controls.Add(_list);
        Controls.Add(sep1);
        Controls.Add(_header);
        Controls.Add(sep2);
        Controls.Add(_footer);
    }

    /// Apply all DPI-scaled pixel sizes. Called at show time (and on DPI change),
    /// when the window is on its monitor and the DPI is reliable.
    private void ApplyMetrics()
    {
        Width = Sc(PanelWidth);
        _header.Height = Sc(HeaderHeight);
        _header.Padding = new Padding(Sc(14), 0, Sc(14), 0);
        _title.Width = Sc(240);
        _trackedLabel.Width = Sc(170);
        _list.Padding = new Padding(Sc(10), Sc(6), Sc(10), Sc(6));
        _footer.Height = Sc(FooterHeight);
        _footer.Padding = new Padding(Sc(12), Sc(6), Sc(10), Sc(6));
        _quit.Width = _refresh.Width = _rescan.Width = Sc(82);
    }

    private void StyleFooterButton(Button b, string text)
    {
        b.Text = text;
        b.AutoSize = false;
        b.FlatStyle = FlatStyle.Flat;
        b.FlatAppearance.BorderSize = 0;
        b.FlatAppearance.MouseOverBackColor = Hover;
        b.BackColor = Bg;
        b.ForeColor = Fg;
        b.Font = new Font("Segoe UI", 10f);
        b.Cursor = Cursors.Hand;
    }

    // ---- show / hide near the tray -----------------------------------------

    /// Position at the bottom-right of the screen under the cursor and show.
    public void ShowNearTray()
    {
        _ = Handle;        // ensure the handle exists so Dpi reads GetDpiForWindow
        ApplyMetrics();    // size the chrome for the current DPI before measuring
        Rebuild();
        var wa = Screen.FromPoint(Cursor.Position).WorkingArea;
        int margin = Sc(6);
        Location = new Point(wa.Right - Width - margin, wa.Bottom - Height - margin);
        Show();
        Activate();
    }

    /// Re-scale everything if the window moves to a monitor with a different DPI.
    protected override void OnDpiChanged(DpiChangedEventArgs e)
    {
        base.OnDpiChanged(e);
        ApplyMetrics();
        if (Visible) Rebuild();
    }

    protected override void OnDeactivate(EventArgs e)
    {
        base.OnDeactivate(e);
        Hide();
    }

    protected override bool ShowWithoutActivation => false;

    private void OnModelChanged()
    {
        if (Visible) Rebuild();
    }

    // ---- content ------------------------------------------------------------

    private void Rebuild()
    {
        _trackedLabel.Text = $"{_model.Summary.Total} tracked";
        _statusLabel.Text = StatusText();

        bool scanning = _model.IsScanning;
        _rescan.Enabled = !scanning;
        _refresh.Enabled = !scanning;

        _list.SuspendLayout();
        _list.Controls.Clear();

        if (_model.ConnectionError is { } err)
        {
            AddMessage("⚠  " + err, WarnFg);
        }
        else if (_model.AttentionRepos.Count == 0)
        {
            AddMessage("✓  All clean — nothing needs attention", OkGreen);
        }
        else
        {
            // Add bottom-up: docked-top rows stack in reverse insertion order.
            foreach (var repo in _model.AttentionRepos.Reverse())
                _list.Controls.Add(MakeRow(repo));
        }

        _list.ResumeLayout();
        ResizeToContent();
    }

    private void AddMessage(string text, Color color)
    {
        _list.Controls.Add(new Label
        {
            Text = text,
            Dock = DockStyle.Top,
            Height = Sc(40),
            ForeColor = color,
            TextAlign = ContentAlignment.MiddleLeft,
            Font = new Font("Segoe UI", 10.5f),
            Padding = new Padding(Sc(6), 0, 0, 0),
        });
    }

    private Control MakeRow(RepoStatus repo)
    {
        var row = new Panel
        {
            Dock = DockStyle.Top,
            Height = Sc(RowHeight),
            Margin = new Padding(0),
            Cursor = Cursors.Hand,
        };

        // Width left for the name/branch text before the (right-docked) badges.
        int textWidth = Sc(PanelWidth - BadgeWidth - 28);
        var name = new Label
        {
            Text = repo.Name,
            Location = new Point(Sc(12), Sc(8)),
            AutoSize = false,
            Size = new Size(textWidth, Sc(26)),
            AutoEllipsis = true,
            TextAlign = ContentAlignment.MiddleLeft,
            ForeColor = Fg,
            Font = new Font("Segoe UI", 11.5f),
        };
        var sub = new Label
        {
            Text = repo.Branch ?? (repo.DetachedHead ? "detached HEAD" : ""),
            Location = new Point(Sc(12), Sc(34)),
            AutoSize = false,
            Size = new Size(textWidth, Sc(20)),
            AutoEllipsis = true,
            TextAlign = ContentAlignment.MiddleLeft,
            ForeColor = Secondary,
            Font = new Font("Segoe UI", 9.5f),
        };
        var badges = new Label
        {
            Text = string.Join("  ", repo.Badges),
            Dock = DockStyle.Right,
            Width = Sc(BadgeWidth),
            TextAlign = ContentAlignment.MiddleRight,
            ForeColor = repo.HasProblem ? WarnFg : Fg,
            Font = new Font("Consolas", 11.5f),
            Padding = new Padding(0, 0, Sc(10), 0),
        };

        row.Controls.Add(name);
        row.Controls.Add(sub);
        row.Controls.Add(badges);

        // Hover highlight + click-through to open a terminal, on the row and
        // all its child labels (children otherwise swallow the events).
        void Enter(object? s, EventArgs e) => row.BackColor = Hover;
        void Leave(object? s, EventArgs e) => row.BackColor = Bg;
        void Click(object? s, EventArgs e) => TerminalLauncher.Open(repo.Path);

        foreach (Control c in new Control[] { row, name, sub, badges })
        {
            c.MouseEnter += Enter;
            c.MouseLeave += Leave;
            c.Click += Click;
        }

        var tip = new ToolTip();
        tip.SetToolTip(row, repo.Path);
        tip.SetToolTip(name, repo.Path);

        return row;
    }

    private void ResizeToContent()
    {
        bool empty = _model.ConnectionError != null || _model.AttentionRepos.Count == 0;
        int contentHeight = empty
            ? Sc(44)
            : Math.Min(_model.AttentionRepos.Count * Sc(RowHeight) + Sc(12), Sc(MaxListHeight));
        // header + sep(1) + list + sep(1) + footer
        Height = Sc(HeaderHeight) + 1 + Math.Max(contentHeight, Sc(44)) + 1 + Sc(FooterHeight);
    }

    private string StatusText()
    {
        if (_model.IsScanning) return "scanning…";
        if (_model.LastRefresh is not { } last) return "never refreshed";
        int secs = (int)(DateTime.Now - last).TotalSeconds;
        return secs < 2 ? "refreshed just now" : $"refreshed {secs}s ago";
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
            _model.Changed -= OnModelChanged;
        base.Dispose(disposing);
    }
}

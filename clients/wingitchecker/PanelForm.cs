using System.Drawing;

namespace WinGitChecker;

/// The borderless popup shown when the tray icon is clicked. Mirrors the macOS
/// client's window-style menu: header, repo list with compact badges, footer.
public sealed class PanelForm : Form
{
    private readonly AppModel _model;

    private readonly Label _trackedLabel = new();
    private readonly Panel _list = new();
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

    private const int PanelWidth = 360;
    private const int MaxListHeight = 420;

    public PanelForm(AppModel model)
    {
        _model = model;

        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        BackColor = Bg;
        ForeColor = Fg;
        Width = PanelWidth;
        Font = new Font("Segoe UI", 9f);

        BuildChrome();
        _model.Changed += OnModelChanged;
    }

    // ---- layout scaffolding -------------------------------------------------

    private void BuildChrome()
    {
        var header = new Panel { Dock = DockStyle.Top, Height = 38, Padding = new Padding(12, 0, 12, 0) };
        var title = new Label
        {
            Text = "⎇ gitchecker",
            Dock = DockStyle.Left,
            AutoSize = false,
            Width = 180,
            TextAlign = ContentAlignment.MiddleLeft,
            Font = new Font("Segoe UI", 11f, FontStyle.Bold),
            ForeColor = Fg,
        };
        _trackedLabel.Dock = DockStyle.Right;
        _trackedLabel.Width = 140;
        _trackedLabel.TextAlign = ContentAlignment.MiddleRight;
        _trackedLabel.ForeColor = Secondary;
        _trackedLabel.Font = new Font("Segoe UI", 8.5f);
        header.Controls.Add(title);
        header.Controls.Add(_trackedLabel);

        _list.Dock = DockStyle.Fill;
        _list.AutoScroll = true;
        _list.Padding = new Padding(8, 4, 8, 4);

        var footer = new Panel { Dock = DockStyle.Bottom, Height = 40, Padding = new Padding(10, 4, 8, 4) };
        _statusLabel.Dock = DockStyle.Left;
        _statusLabel.AutoSize = false;
        _statusLabel.Width = 150;
        _statusLabel.TextAlign = ContentAlignment.MiddleLeft;
        _statusLabel.ForeColor = Secondary;
        _statusLabel.Font = new Font("Segoe UI", 8f);

        StyleFooterButton(_quit, "Quit");
        StyleFooterButton(_refresh, "Refresh");
        StyleFooterButton(_rescan, "Rescan");
        _quit.Dock = DockStyle.Right;
        _refresh.Dock = DockStyle.Right;
        _rescan.Dock = DockStyle.Right;

        _rescan.Click += async (_, _) => await _model.RescanAsync();
        _refresh.Click += async (_, _) => await _model.RefreshAsync();
        _quit.Click += (_, _) => Application.Exit();

        // Right-docked controls stack right-to-left in declaration order.
        footer.Controls.Add(_statusLabel);
        footer.Controls.Add(_quit);
        footer.Controls.Add(_refresh);
        footer.Controls.Add(_rescan);

        var sep1 = new Panel { Dock = DockStyle.Top, Height = 1, BackColor = Hover };
        var sep2 = new Panel { Dock = DockStyle.Bottom, Height = 1, BackColor = Hover };

        // Add fill first so it doesn't cover the docked bars.
        Controls.Add(_list);
        Controls.Add(sep1);
        Controls.Add(header);
        Controls.Add(sep2);
        Controls.Add(footer);
    }

    private static void StyleFooterButton(Button b, string text)
    {
        b.Text = text;
        b.AutoSize = false;
        b.Width = 64;
        b.FlatStyle = FlatStyle.Flat;
        b.FlatAppearance.BorderSize = 0;
        b.FlatAppearance.MouseOverBackColor = Hover;
        b.BackColor = Bg;
        b.ForeColor = Fg;
        b.Font = new Font("Segoe UI", 8.5f);
        b.Cursor = Cursors.Hand;
    }

    // ---- show / hide near the tray -----------------------------------------

    /// Position at the bottom-right of the screen under the cursor and show.
    public void ShowNearTray()
    {
        Rebuild();
        var wa = Screen.FromPoint(Cursor.Position).WorkingArea;
        Location = new Point(wa.Right - Width - 6, wa.Bottom - Height - 6);
        Show();
        Activate();
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
            Height = 30,
            ForeColor = color,
            TextAlign = ContentAlignment.MiddleLeft,
            Padding = new Padding(4, 0, 0, 0),
        });
    }

    private Control MakeRow(RepoStatus repo)
    {
        var row = new Panel
        {
            Dock = DockStyle.Top,
            Height = 46,
            Margin = new Padding(0),
            Cursor = Cursors.Hand,
        };

        var name = new Label
        {
            Text = repo.Name,
            Location = new Point(8, 5),
            AutoSize = true,
            ForeColor = Fg,
            Font = new Font("Segoe UI", 9.5f),
        };
        var sub = new Label
        {
            Text = repo.Branch ?? (repo.DetachedHead ? "detached HEAD" : ""),
            Location = new Point(8, 24),
            AutoSize = true,
            ForeColor = Secondary,
            Font = new Font("Segoe UI", 8f),
        };
        var badges = new Label
        {
            Text = string.Join("  ", repo.Badges),
            Dock = DockStyle.Right,
            Width = 130,
            TextAlign = ContentAlignment.MiddleRight,
            ForeColor = repo.HasProblem ? WarnFg : Fg,
            Font = new Font("Consolas", 9.5f),
            Padding = new Padding(0, 0, 8, 0),
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
        int rows = _model.ConnectionError != null || _model.AttentionRepos.Count == 0
            ? 1
            : _model.AttentionRepos.Count;
        int contentHeight = _model.ConnectionError != null || _model.AttentionRepos.Count == 0
            ? 34
            : Math.Min(rows * 46 + 8, MaxListHeight);
        // header(38) + sep(1) + list + sep(1) + footer(40)
        Height = 38 + 1 + Math.Max(contentHeight, 34) + 1 + 40;
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

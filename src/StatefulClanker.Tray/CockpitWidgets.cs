namespace StatefulClanker.Tray;

sealed class RecentActivityPanel : Panel
{
    readonly TableLayoutPanel _rows = new()
    {
        Dock = DockStyle.Top,
        ColumnCount = 1,
        AutoSize = true,
        AutoSizeMode = AutoSizeMode.GrowAndShrink,
        BackColor = Theme.Surface
    };
    readonly Label _empty = new()
    {
        Text = "No recent activity.",
        Dock = DockStyle.Top,
        Height = 28,
        ForeColor = Theme.Muted,
        Font = new Font("Cascadia Mono", 8.25f),
        Padding = new Padding(8, 6, 4, 0)
    };

    public event Action? OpenActivityRequested;

    public RecentActivityPanel()
    {
        Dock = DockStyle.Fill;
        BackColor = Theme.Surface;
        Padding = new Padding(1);
        AutoScroll = true;
        Controls.Add(_empty);
        Controls.Add(_rows);
        Click += (_, _) => OpenActivityRequested?.Invoke();
    }

    public void SetActivity(string activity, int maxRows = 9)
    {
        var lines = (activity ?? "")
            .Split(new[] { "\r\n", "\n" }, StringSplitOptions.RemoveEmptyEntries)
            .Select(x => x.TrimEnd())
            .Where(x => !string.IsNullOrWhiteSpace(x))
            .TakeLast(maxRows)
            .Reverse()
            .ToList();

        _rows.SuspendLayout();
        try
        {
            _rows.Controls.Clear();
            _rows.RowStyles.Clear();
            _rows.RowCount = 0;
            foreach (var line in lines)
            {
                var label = new Label
                {
                    Text = line,
                    Dock = DockStyle.Top,
                    Height = 26,
                    AutoEllipsis = true,
                    ForeColor = ActivityColor(line),
                    BackColor = Theme.Surface,
                    Font = new Font("Cascadia Mono", 8f),
                    Padding = new Padding(7, 5, 5, 0),
                    Cursor = Cursors.Hand,
                    Margin = new Padding(0, 0, 0, 1)
                };
                label.Click += (_, _) => OpenActivityRequested?.Invoke();
                _rows.RowStyles.Add(new RowStyle(SizeType.Absolute, 27));
                _rows.Controls.Add(label, 0, _rows.RowCount++);
            }
            _empty.Visible = lines.Count == 0;
        }
        finally { _rows.ResumeLayout(); }
    }

    static Color ActivityColor(string line)
    {
        var l = line.ToLowerInvariant();
        if (l.Contains("fail") || l.Contains("reject") || l.Contains("blocked") || l.Contains("error")) return Theme.Error;
        if (l.Contains("pass") || l.Contains("complete") || l.Contains("commit")) return Theme.Good;
        if (l.Contains("critic") || l.Contains("validator") || l.Contains("stale")) return Theme.Warn;
        if (l.Contains("started") || l.Contains("running") || l.Contains("dispatch")) return Theme.Accent;
        return Theme.Text;
    }
}

sealed class OrchestratorStatusPanel : Control
{
    ProjectMetrics _project = new();
    AutofillSnapshot _autofill = new();
    bool _mcpRunning;
    bool _hasProject;

    public OrchestratorStatusPanel()
    {
        DoubleBuffered = true;
        Dock = DockStyle.Fill;
        MinimumSize = new Size(220, 105);
    }

    public void SetState(ProjectMetrics project, AutofillSnapshot autofill, bool mcpRunning, bool hasProject)
    {
        _project = project;
        _autofill = autofill;
        _mcpRunning = mcpRunning;
        _hasProject = hasProject;
        Invalidate();
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        var g = e.Graphics;
        g.Clear(Color.FromArgb(9, 13, 18));
        g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;

        var border = new Rectangle(0, 0, Width - 1, Height - 1);
        using var panel = new SolidBrush(Color.FromArgb(15, 21, 28));
        using var borderPen = new Pen(Theme.Border);
        g.FillRectangle(panel, border);
        g.DrawRectangle(borderPen, border);

        using var titleFont = new Font("Cascadia Mono", 9.25f, FontStyle.Bold);
        using var labelFont = new Font("Cascadia Mono", 8f, FontStyle.Bold);
        using var valueFont = new Font("Cascadia Mono", 8f);
        using var titleBrush = new SolidBrush(Theme.Accent);
        using var mutedBrush = new SolidBrush(Theme.Muted);
        using var textBrush = new SolidBrush(Theme.Text);

        g.DrawString("CLANKER STATUS", titleFont, titleBrush, 11, 8);

        var rows = new List<(string label, string value, Color color)>
        {
            ("PROJECT", _hasProject ? "ACTIVE" : "NONE", _hasProject ? Theme.Good : Theme.Muted),
            ("MCP", _mcpRunning ? "ONLINE" : "OFFLINE", _mcpRunning ? Theme.Good : Theme.Error),
            ("AUTOFILL", _autofill.Paused ? "PAUSED" : (_autofill.Running ? "RUNNING" : "STOPPED"), _autofill.Paused ? Theme.Warn : (_autofill.Running ? Theme.Good : Theme.Muted)),
            ("WORKERS", $"{_project.ActiveAgents}/{Math.Max(1, _autofill.MaxConcurrent)}", _project.ActiveAgents > 0 ? Theme.Accent : Theme.Muted),
            ("QUEUE", $"{_autofill.ReadyCount} READY" + (_autofill.RetryCount > 0 ? $" / {_autofill.RetryCount} RETRY" : ""), _autofill.RetryCount > 0 ? Theme.Warn : Theme.Text),
            ("INTENT", string.IsNullOrWhiteSpace(_project.IntentRevision) ? "—" : $"R{_project.IntentRevision}", Theme.Text)
        };

        var top = 29;
        var colWidth = Math.Max(120, Width / 2);
        for (var i = 0; i < rows.Count; i++)
        {
            var col = i % 2;
            var row = i / 2;
            var x = 12 + col * colWidth;
            var y = top + row * 25;
            var item = rows[i];

            using var lamp = new SolidBrush(item.color);
            g.FillEllipse(lamp, x, y + 4, 8, 8);
            g.DrawString(item.label, labelFont, mutedBrush, x + 15, y);
            g.DrawString(item.value, valueFont, textBrush, x + 77, y);
        }

        if (!string.IsNullOrWhiteSpace(_autofill.BlockReason))
        {
            using var warn = new SolidBrush(Theme.Warn);
            var message = _autofill.BlockReason.Length > 80 ? _autofill.BlockReason[..77] + "..." : _autofill.BlockReason;
            g.DrawString("HOLD  " + message, valueFont, warn, 12, Height - 22);
        }
    }
}

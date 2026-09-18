using System.Diagnostics;
using System.Windows.Forms.Integration;
using EasyWindowsTerminalControl;
using Microsoft.Terminal.Wpf;

namespace StatefulClanker.Tray;

/// <summary>
/// Embedded project terminal backed by Windows ConPTY and the Windows Terminal renderer.
/// Sessions are always started with the active project as their working directory, so
/// launching agy/opencode here is equivalent to opening a terminal in that project and
/// running the command manually.
/// </summary>
sealed class EmbeddedTerminalPanel : UserControl
{
    readonly TableLayoutPanel _layout = new();
    readonly FlowLayoutPanel _toolbar = new();
    readonly ComboBox _preset = new();
    readonly TextBox _custom = new();
    readonly Button _start = new();
    readonly Button _restart = new();
    readonly Button _stop = new();
    readonly Label _status = new();
    readonly Panel _hostPanel = new();
    readonly Panel _toastPanel = new();
    readonly Label _toastLabel = new();
    readonly Button _toastClose = new();
    readonly System.Windows.Forms.Timer _toastTimer = new() { Interval = 8000 };
    // Polls for a quiet gap in typing so a queued notice can be auto-sent without
    // waiting on an Enter keypress that may never come (e.g. the human just reads a
    // response and doesn't submit anything for a while).
    readonly System.Windows.Forms.Timer _idleFlushTimer = new() { Interval = 400 };
    static readonly TimeSpan IdleThreshold = TimeSpan.FromMilliseconds(900);
    // Hard ceiling independent of typing detection. Observed in practice: idle
    // detection here depends on this native ConPTY-hosted control reliably
    // reporting focus/keystrokes to a plain WinForms message filter, which it does
    // not always do -- notices were only ever delivered on an explicit Enter
    // keypress, never automatically. Rather than debug that native-focus quirk
    // further, cap how long a notice can sit queued: past this, it flushes no
    // matter what the (possibly wrong) typing state says.
    static readonly TimeSpan MaxQueueWait = TimeSpan.FromMilliseconds(2500);
    readonly Queue<string> _pendingNotices = new();
    DateTime _lastKeyUtc = DateTime.MinValue;
    DateTime? _oldestPendingUtc;
    NoticeMessageFilter? _noticeFilter;

    sealed class NoticeMessageFilter : IMessageFilter
    {
        const int WM_KEYDOWN = 0x0100;
        readonly EmbeddedTerminalPanel _owner;

        public NoticeMessageFilter(EmbeddedTerminalPanel owner) => _owner = owner;

        public bool PreFilterMessage(ref Message m)
        {
            if (m.Msg == WM_KEYDOWN && _owner._elementHost?.ContainsFocus == true)
            {
                _owner._lastKeyUtc = DateTime.UtcNow;
                if ((Keys)m.WParam == Keys.Enter)
                {
                    // A submitted line is itself a safe, immediate boundary -- don't
                    // wait for the idle timer to catch up to it.
                    _ = _owner.FlushAfterEnterAsync();
                }
            }
            return false;
        }
    }

    // ElementHost does not forward arrow/Tab WM_KEYDOWN messages into its hosted WPF
    // tree by default -- IsInputKey on the plain WinForms ElementHost returns false for
    // them, so they get eaten by WinForms dialog/focus navigation before the WPF
    // EasyTerminalControl (and its Win32InputMode/InputCapture settings) ever sees them.
    // This subclass claims those keys as "input" only while the terminal has focus, so
    // normal Tab-navigation between other tray controls is unaffected.
    sealed class TerminalElementHost : ElementHost
    {
        protected override bool IsInputKey(Keys keyData)
        {
            var key = keyData & Keys.KeyCode;
            if (ContainsFocus && (key is Keys.Left or Keys.Right or Keys.Up or Keys.Down or Keys.Tab))
                return true;
            return base.IsInputKey(keyData);
        }
    }

    ElementHost? _elementHost;
    EasyTerminalControl? _terminal;
    string? _projectPath;
    string _currentCommand = "";

    static readonly (string name, string command)[] Presets =
    {
        ("PowerShell", "pwsh.exe -NoLogo"),
        ("Antigravity (agy)", "agy"),
        ("OpenCode", "opencode"),
        ("OpenCode mini", "opencode mini"),
        ("Custom", "")
    };

    public EmbeddedTerminalPanel()
    {
        Dock = DockStyle.Fill;
        BackColor = Theme.Back;

        _layout.Dock = DockStyle.Fill;
        _layout.ColumnCount = 1;
        _layout.RowCount = 4;
        _layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 42));
        _layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 0));
        _layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 24));
        _layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));

        _toolbar.Dock = DockStyle.Fill;
        _toolbar.WrapContents = false;
        _toolbar.Padding = new Padding(0, 2, 0, 0);

        _preset.DropDownStyle = ComboBoxStyle.DropDownList;
        _preset.Width = 150;
        _preset.Margin = new Padding(0, 4, 6, 0);
        foreach (var p in Presets) _preset.Items.Add(p.name);
        _preset.SelectedIndex = 0;
        _preset.SelectedIndexChanged += (_, _) => UpdateCustomVisibility();

        _custom.Width = 260;
        _custom.Margin = new Padding(0, 4, 6, 0);
        _custom.Font = new Font("Cascadia Mono", 9f);
        _custom.PlaceholderText = "command + arguments";
        _custom.Visible = false;

        _start.Text = "Start";
        _start.Width = 72;
        _start.Height = 30;
        _start.Margin = new Padding(0, 3, 6, 0);
        _start.Click += async (_, _) => await StartSelectedAsync(false);

        _restart.Text = "Restart";
        _restart.Width = 78;
        _restart.Height = 30;
        _restart.Margin = new Padding(0, 3, 6, 0);
        _restart.Click += async (_, _) => await StartSelectedAsync(true);

        _stop.Text = "Stop";
        _stop.Width = 68;
        _stop.Height = 30;
        _stop.Margin = new Padding(0, 3, 6, 0);
        _stop.Click += (_, _) => StopSession();

        _toolbar.Controls.AddRange(new Control[]
        {
            new Label { Text = "SESSION", AutoSize = true, ForeColor = Theme.Muted, Font = new Font("Segoe UI Semibold", 8f, FontStyle.Bold), Margin = new Padding(0, 10, 8, 0) },
            _preset, _custom, _start, _restart, _stop
        });

        _status.Dock = DockStyle.Fill;
        _status.TextAlign = ContentAlignment.MiddleLeft;
        _status.ForeColor = Theme.Muted;
        _status.Font = new Font("Cascadia Mono", 8.25f);
        _status.Text = "Select a project to open an embedded shell.";

        _hostPanel.Dock = DockStyle.Fill;
        _hostPanel.BackColor = Color.FromArgb(8, 11, 15);
        _hostPanel.Padding = new Padding(1);

        _toastPanel.Dock = DockStyle.Fill;
        _toastPanel.BackColor = Theme.Surface2;
        _toastPanel.Visible = false;
        _toastPanel.Padding = new Padding(8, 0, 4, 0);

        _toastLabel.Dock = DockStyle.Fill;
        _toastLabel.TextAlign = ContentAlignment.MiddleLeft;
        _toastLabel.ForeColor = Theme.Accent;
        _toastLabel.Font = new Font("Cascadia Mono", 8.25f);
        _toastLabel.AutoEllipsis = true;

        _toastClose.Text = "x";
        _toastClose.Width = 24;
        _toastClose.Dock = DockStyle.Right;
        _toastClose.FlatStyle = FlatStyle.Flat;
        _toastClose.Click += (_, _) => HideToast();

        _toastPanel.Controls.Add(_toastLabel);
        _toastPanel.Controls.Add(_toastClose);

        _toastTimer.Tick += (_, _) => { _toastTimer.Stop(); HideToast(); };
        _idleFlushTimer.Tick += (_, _) => TryFlushIfIdle();
        _idleFlushTimer.Start();

        _layout.Controls.Add(_toolbar, 0, 0);
        _layout.Controls.Add(_toastPanel, 0, 1);
        _layout.Controls.Add(_status, 0, 2);
        _layout.Controls.Add(_hostPanel, 0, 3);
        Controls.Add(_layout);

        Theme.Apply(this);
    }

    public void SetProject(string? path)
    {
        var normalized = string.IsNullOrWhiteSpace(path) ? null : Path.GetFullPath(path);
        if (string.Equals(_projectPath, normalized, StringComparison.OrdinalIgnoreCase)) return;

        StopSession();
        _projectPath = normalized;

        if (_projectPath is null || !Directory.Exists(_projectPath))
        {
            _status.Text = "Select a project to open an embedded shell.";
            _status.ForeColor = Theme.Muted;
            _start.Enabled = _restart.Enabled = _stop.Enabled = false;
            return;
        }

        _status.Text = $"Project shell ready: {_projectPath}";
        _status.ForeColor = Theme.Accent;
        _start.Enabled = _restart.Enabled = true;
        _stop.Enabled = false;

        // A shell should be immediately useful without another click.  It has the
        // same cwd semantics as opening PowerShell inside the project directory.
        _ = StartCommandAsync(ShellCommand(), false);
    }

    string ShellCommand()
    {
        var pwsh = Runtime.FindPowerShell();
        return QuoteIfNeeded(pwsh) + " -NoLogo";
    }

    static string QuoteIfNeeded(string s) => s.Contains(' ') && !s.StartsWith('"') ? $"\"{s}\"" : s;

    string SelectedCommand()
    {
        if (_preset.SelectedIndex < 0 || _preset.SelectedIndex >= Presets.Length) return ShellCommand();
        var selected = Presets[_preset.SelectedIndex];
        if (selected.name == "PowerShell") return ShellCommand();
        if (selected.name == "Custom") return ToolViaShell(_custom.Text.Trim());
        return ToolViaShell(selected.command);
    }

    string ToolViaShell(string command)
    {
        if (string.IsNullOrWhiteSpace(command)) return "";
        var pwsh = QuoteIfNeeded(Runtime.FindPowerShell());
        var escaped = command.Replace("\"", "\\\"");
        // Keep PowerShell alive after the TUI exits. This deliberately matches
        // "open PowerShell in the project, then type agy/opencode" semantics and
        // also lets PowerShell resolve .cmd/.ps1 shims or aliases.
        return $"{pwsh} -NoLogo -NoExit -Command \"{escaped}\"";
    }

    void UpdateCustomVisibility()
    {
        _custom.Visible = _preset.SelectedItem?.ToString() == "Custom";
    }

    async Task StartSelectedAsync(bool forceRestart)
    {
        var command = SelectedCommand();
        if (string.IsNullOrWhiteSpace(command)) return;
        await StartCommandAsync(command, forceRestart);
    }

    async Task StartCommandAsync(string command, bool forceRestart)
    {
        if (string.IsNullOrWhiteSpace(_projectPath) || !Directory.Exists(_projectPath)) return;

        if (!forceRestart && _terminal is not null && string.Equals(_currentCommand, command, StringComparison.OrdinalIgnoreCase))
            return;

        try
        {
            DisposeTerminal();

            _terminal = new EasyTerminalControl
            {
                StartupCommandLine = command,
                WorkingDirectory = _projectPath,
                LogConPTYOutput = true,
                FontFamilyWhenSettingTheme = new System.Windows.Media.FontFamily("Cascadia Mono"),
                FontSizeWhenSettingTheme = 11,
                Win32InputMode = true,
                InputCapture = EasyTerminalControl.INPUT_CAPTURE.TabKey | EasyTerminalControl.INPUT_CAPTURE.DirectionKeys,
                Theme = BuildTerminalTheme()
            };

            _elementHost = new TerminalElementHost
            {
                Dock = DockStyle.Fill,
                Child = _terminal,
                BackColor = Color.FromArgb(8, 11, 15)
            };
            _hostPanel.Controls.Add(_elementHost);
            _elementHost.BringToFront();

            _currentCommand = command;
            _status.Text = $"RUNNING  {command}   @   {_projectPath}";
            _status.ForeColor = Theme.Good;
            _stop.Enabled = true;

            if (_noticeFilter is null)
            {
                _noticeFilter = new NoticeMessageFilter(this);
                Application.AddMessageFilter(_noticeFilter);
            }

            // Let WPF create the terminal HWND and ConPTY before focusing it.
            await Task.Delay(150);
            try { _terminal.Focus(); } catch { }
        }
        catch (Exception ex)
        {
            _status.Text = "Terminal start failed: " + ex.Message;
            _status.ForeColor = Theme.Error;
            DisposeTerminal();
        }
    }

    static TerminalTheme BuildTerminalTheme()
    {
        uint C(System.Drawing.Color c) => BitConverter.ToUInt32(new byte[] { c.R, c.G, c.B, 0 }, 0);
        return new TerminalTheme
        {
            DefaultBackground = C(Color.FromArgb(8, 11, 15)),
            DefaultForeground = C(Color.FromArgb(224, 232, 239)),
            DefaultSelectionBackground = C(Color.FromArgb(45, 63, 79)),
            CursorStyle = CursorStyle.BlinkingBar,
            ColorTable = new uint[]
            {
                C(Color.FromArgb(12, 15, 20)), C(Color.FromArgb(210, 70, 75)),
                C(Color.FromArgb(70, 200, 125)), C(Color.FromArgb(220, 180, 70)),
                C(Color.FromArgb(75, 145, 220)), C(Color.FromArgb(175, 100, 210)),
                C(Color.FromArgb(70, 190, 205)), C(Color.FromArgb(205, 215, 225)),
                C(Color.FromArgb(85, 100, 115)), C(Color.FromArgb(245, 95, 100)),
                C(Color.FromArgb(90, 225, 145)), C(Color.FromArgb(245, 205, 90)),
                C(Color.FromArgb(100, 175, 255)), C(Color.FromArgb(210, 135, 245)),
                C(Color.FromArgb(90, 220, 235)), C(Color.FromArgb(245, 248, 250))
            }
        };
    }

    public void StartAgy()
    {
        _preset.SelectedItem = "Antigravity (agy)";
        _ = StartCommandAsync(ToolViaShell("agy"), true);
    }

    public void StartOpenCode()
    {
        _preset.SelectedItem = "OpenCode";
        _ = StartCommandAsync(ToolViaShell("opencode"), true);
    }

    /// <summary>
    /// True while a terminal session is live and can accept injected notices.
    /// </summary>
    public bool HasActiveSession => _terminal is not null;

    /// <summary>
    /// Writes a short notice into the live PTY's input stream so it appears as text in
    /// front of the running session (agy/opencode/pwsh). No-op if no session is running.
    /// Deliberate accepted tradeoff (ledger D7): this writes into the same input stream
    /// the human or an AI composer may be mid-typing into, so it can interleave with
    /// in-progress input -- moving to a fresh line for display requires sending what the
    /// shell interprets as a newline/Enter, but no further automated action is taken.
    /// </summary>
    public void QueueNotice(string text)
    {
        if (string.IsNullOrWhiteSpace(text)) return;
        _pendingNotices.Enqueue(text);
        _oldestPendingUtc ??= DateTime.UtcNow;
        ShowToast(text);
        TryFlushIfIdle();
    }

    // Auto-sends whenever the human isn't actively typing (D9): if no keystroke has
    // ever been observed, or the last one is older than IdleThreshold, flush right
    // away instead of waiting for an Enter that may not come. _idleFlushTimer covers
    // the case where a notice arrives mid-typing -- it keeps checking every tick and
    // flushes the moment typing pauses. MaxQueueWait is a backstop: it flushes
    // regardless of the idle check once a notice has waited long enough, so a
    // missed/unreliable keystroke observation never turns into "only sends when the
    // human happens to press Enter."
    void TryFlushIfIdle()
    {
        if (_pendingNotices.Count == 0) return;
        var idle = _lastKeyUtc == DateTime.MinValue || DateTime.UtcNow - _lastKeyUtc >= IdleThreshold;
        var overdue = _oldestPendingUtc.HasValue && DateTime.UtcNow - _oldestPendingUtc.Value >= MaxQueueWait;
        if (idle || overdue)
            FlushPendingNotices();
    }

    void ShowToast(string latestText)
    {
        var extra = _pendingNotices.Count - 1;
        _toastLabel.Text = extra > 0 ? $"{latestText}  (+{extra} more)" : latestText;
        _toastPanel.Visible = true;
        _layout.RowStyles[1] = new RowStyle(SizeType.Absolute, 24);
        _toastTimer.Stop();
        _toastTimer.Start();
    }

    void HideToast()
    {
        _toastPanel.Visible = false;
        _layout.RowStyles[1] = new RowStyle(SizeType.Absolute, 0);
    }

    async Task FlushAfterEnterAsync()
    {
        await Task.Delay(200);
        try
        {
            if (IsHandleCreated && !IsDisposed)
                BeginInvoke(new Action(FlushPendingNotices));
        }
        catch { }
    }

    void FlushPendingNotices()
    {
        if (_pendingNotices.Count == 0) return;
        if (!HasActiveSession)
        {
            _pendingNotices.Clear();
            _oldestPendingUtc = null;
            return;
        }
        try
        {
            var joined = string.Join("\r\n", _pendingNotices);
            _terminal!.ConPTYTerm?.WriteToTerm(("\r\n" + joined + "\r\n").AsSpan());
        }
        catch { }
        finally
        {
            _pendingNotices.Clear();
            _oldestPendingUtc = null;
        }
    }

    public void StopSession()
    {
        DisposeTerminal();
        _currentCommand = "";
        _stop.Enabled = false;
        if (!string.IsNullOrWhiteSpace(_projectPath) && Directory.Exists(_projectPath))
        {
            _status.Text = $"Stopped. Project shell ready: {_projectPath}";
            _status.ForeColor = Theme.Muted;
        }
    }

    void DisposeTerminal()
    {
        if (_noticeFilter is not null)
        {
            try { Application.RemoveMessageFilter(_noticeFilter); } catch { }
            _noticeFilter = null;
        }

        try
        {
            if (_terminal is not null)
            {
                try { _terminal.ConPTYTerm?.CloseStdinToApp(); } catch { }
                try { _terminal.ConPTYTerm?.StopExternalTermOnly(); } catch { }
            }
        }
        catch { }

        if (_elementHost is not null)
        {
            try { _hostPanel.Controls.Remove(_elementHost); } catch { }
            try { _elementHost.Dispose(); } catch { }
        }

        _elementHost = null;
        _terminal = null;
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            DisposeTerminal();
            _idleFlushTimer.Dispose();
            _toastTimer.Dispose();
        }
        base.Dispose(disposing);
    }
}

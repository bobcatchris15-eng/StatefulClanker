using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Windows.Forms;

namespace StatefulClanker.Tray;

static class Program
{
    [STAThread]
    static void Main()
    {
        ApplicationConfiguration.Initialize();
        using var mutex = new Mutex(true, "Local\\StatefulClanker.WindowsHost", out var first);
        if (!first) return;
        Application.Run(new MainForm());
    }
}

sealed class ProjectEntry
{
    public string Name { get; set; } = "";
    public string Path { get; set; } = "";
}

sealed class AppSettings
{
    public List<ProjectEntry> Projects { get; set; } = new();
    public string? ActiveProjectPath { get; set; }
    public int HttpPort { get; set; } = 7337;
    public string? McpToken { get; set; }
}

static class AppStore
{
    public static readonly string Root = System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "StatefulClanker");
    public static readonly string SettingsPath = System.IO.Path.Combine(Root, "app.json");
    public static readonly string ActiveProjectPointer = System.IO.Path.Combine(Root, "active-project.txt");
    public static readonly string McpDetailsPath = System.IO.Path.Combine(Root, "mcp-http.json");
    static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true, PropertyNameCaseInsensitive = true };

    public static AppSettings Load()
    {
        Directory.CreateDirectory(Root);
        AppSettings settings = new();
        try { if (File.Exists(SettingsPath)) settings = JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(SettingsPath), JsonOptions) ?? new(); }
        catch { }
        if (string.IsNullOrWhiteSpace(settings.McpToken))
        {
            try
            {
                if (File.Exists(McpDetailsPath))
                {
                    var d = JsonSerializer.Deserialize<McpDetails>(File.ReadAllText(McpDetailsPath), JsonOptions);
                    if (!string.IsNullOrWhiteSpace(d?.token)) settings.McpToken = d.token;
                }
            }
            catch { }
            if (string.IsNullOrWhiteSpace(settings.McpToken))
            {
                settings.McpToken = Guid.NewGuid().ToString("N");
            }
            Save(settings);
        }
        return settings;
    }

    public static void Save(AppSettings settings)
    {
        Directory.CreateDirectory(Root);
        File.WriteAllText(SettingsPath, JsonSerializer.Serialize(settings, JsonOptions), new UTF8Encoding(false));
    }

    public static void SetActiveProject(string? path)
    {
        Directory.CreateDirectory(Root);
        if (string.IsNullOrWhiteSpace(path)) { try { File.Delete(ActiveProjectPointer); } catch { } return; }
        File.WriteAllText(ActiveProjectPointer, path, new UTF8Encoding(false));
    }
}

static class Runtime
{
    public static string FindRoot()
    {
        DirectoryInfo? current = new(AppContext.BaseDirectory);
        for (var i = 0; i < 8 && current is not null; i++, current = current.Parent)
        {
            if (File.Exists(System.IO.Path.Combine(current.FullName, "StatefulClanker.ps1")) &&
                File.Exists(System.IO.Path.Combine(current.FullName, "mcp", "StatefulClanker.McpHttp.ps1"))) return current.FullName;
        }
        return AppContext.BaseDirectory;
    }

    public static string FindPowerShell()
    {
        var fixedPath = System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "PowerShell", "7", "pwsh.exe");
        if (File.Exists(fixedPath)) return fixedPath;
        if (CommandExists("pwsh.exe")) return "pwsh.exe";
        return "powershell.exe";
    }

    public static bool CommandExists(string command)
    {
        if (string.IsNullOrWhiteSpace(command)) return false;
        if (command.Contains('\\') || command.Contains('/')) return File.Exists(command);
        try
        {
            using var p = Process.Start(new ProcessStartInfo("where.exe")
            {
                UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true,
                ArgumentList = { command }
            });
            p?.WaitForExit(1500);
            return p?.ExitCode == 0;
        }
        catch { return false; }
    }

    public static (int code, string stdout, string stderr) Run(string file, string workingDir, params string[] args)
    {
        try
        {
            var psi = new ProcessStartInfo(file) { WorkingDirectory = workingDir, UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
            foreach (var arg in args) psi.ArgumentList.Add(arg);
            using var p = Process.Start(psi);
            if (p is null) return (-1, "", "Could not start process.");
            var stdout = p.StandardOutput.ReadToEnd();
            var stderr = p.StandardError.ReadToEnd();
            p.WaitForExit();
            return (p.ExitCode, stdout, stderr);
        }
        catch (Exception ex) { return (-1, "", ex.Message); }
    }

    public static (int code, string stdout, string stderr) RunPowerShell(string root, params string[] args)
    {
        var all = new List<string> { "-NoProfile", "-NonInteractive" }; all.AddRange(args);
        return Run(FindPowerShell(), root, all.ToArray());
    }
}

sealed class McpDetails
{
    public string? url { get; set; }
    public string? token { get; set; }
    public int pid { get; set; }
}

sealed class McpHost : IDisposable
{
    readonly string _root;
    Process? _owned;
    public int Port { get; }
    public string? Token { get; }
    public McpHost(string root, int port, string? token = null) { _root = root; Port = port; Token = token; }

    public McpDetails? Details()
    {
        try
        {
            if (!File.Exists(AppStore.McpDetailsPath)) return null;
            var d = JsonSerializer.Deserialize<McpDetails>(File.ReadAllText(AppStore.McpDetailsPath));
            if (d is null || d.pid <= 0 || string.IsNullOrWhiteSpace(d.url)) return null;
            using var _ = Process.GetProcessById(d.pid);
            return d;
        }
        catch { return null; }
    }

    public void EnsureStarted()
    {
        if (_owned is { HasExited: false } || Details() is not null) return;
        var script = System.IO.Path.Combine(_root, "mcp", "StatefulClanker.McpHttp.ps1");
        if (!File.Exists(script)) return;
        var psi = new ProcessStartInfo(Runtime.FindPowerShell()) { WorkingDirectory = _root, UseShellExecute = false, CreateNoWindow = true };
        var args = new List<string> { "-NoProfile", "-NonInteractive", "-File", script, "-Port", Port.ToString() };
        if (!string.IsNullOrWhiteSpace(Token)) { args.AddRange(new[] { "-Token", Token }); }
        foreach (var arg in args) psi.ArgumentList.Add(arg);
        try { _owned = Process.Start(psi); } catch { _owned = null; }
    }

    public void Dispose()
    {
        try { if (_owned is { HasExited: false }) _owned.Kill(entireProcessTree: true); } catch { }
        _owned?.Dispose();
    }
}

sealed class AutofillHost : IDisposable
{
    readonly string _root;
    Process? _owned;
    string? _project;
    public AutofillHost(string root) { _root = root; }

    static string StateDir(string project) => System.IO.Path.Combine(project, ".statefulclanker", "autofill");
    static string StatusPath(string project) => System.IO.Path.Combine(StateDir(project), "supervisor.json");
    static string StopPath(string project) => System.IO.Path.Combine(StateDir(project), "stop.request");

    static bool Enabled(string project)
    {
        try
        {
            var path = System.IO.Path.Combine(project, ".statefulclanker", "config.json");
            if (!File.Exists(path)) return false;
            using var d = JsonDocument.Parse(File.ReadAllText(path));
            return !d.RootElement.TryGetProperty("autofillEnabled", out var enabled) || enabled.ValueKind != JsonValueKind.False;
        }
        catch { return false; }
    }

    static bool ExistingAlive(string project)
    {
        try
        {
            var path = StatusPath(project); if (!File.Exists(path)) return false;
            using var d = JsonDocument.Parse(File.ReadAllText(path)); if (!d.RootElement.TryGetProperty("pid", out var p)) return false;
            using var proc = Process.GetProcessById(p.GetInt32()); return !proc.HasExited;
        }
        catch { return false; }
    }

    static void RequestStop(string? project)
    {
        if (string.IsNullOrWhiteSpace(project)) return;
        try { Directory.CreateDirectory(StateDir(project)); File.WriteAllText(StopPath(project), DateTimeOffset.UtcNow.ToString("O"), new UTF8Encoding(false)); } catch { }
    }

    public void EnsureStarted(string? project)
    {
        if (string.IsNullOrWhiteSpace(project) || !Directory.Exists(project)) { if (_project is not null) RequestStop(_project); _project = null; return; }
        if (!string.Equals(_project, project, StringComparison.OrdinalIgnoreCase) && _project is not null) RequestStop(_project);
        _project = project;
        if (!Enabled(project)) { RequestStop(project); return; }
        if (_owned is { HasExited: false } || ExistingAlive(project)) return;
        var harness = System.IO.Path.Combine(_root, "StatefulClanker.ps1"); if (!File.Exists(harness)) return;
        try
        {
            var psi = new ProcessStartInfo(Runtime.FindPowerShell()) { WorkingDirectory = project, UseShellExecute = false, CreateNoWindow = true };
            foreach (var arg in new[] { "-NoProfile", "-NonInteractive", "-File", harness, "autofill", "run" }) psi.ArgumentList.Add(arg);
            _owned = Process.Start(psi);
        }
        catch { _owned = null; }
    }

    public void Dispose()
    {
        RequestStop(_project);
        _owned?.Dispose();
    }
}

sealed class ProjectMetrics
{
    public int ActiveAgents, Sessions, Commits, Critics, CompleteTasks, TotalTasks;
    public long UsageReports, PromptTokens, CompletionTokens, TotalTokens;
    public Dictionary<string,long> ModelTokens = new(StringComparer.OrdinalIgnoreCase);
    public string IntentRevision = "—", Goal = "", Activity = "";
}

sealed class IntegrationStatus
{
    public string id { get; set; } = "";
    public string name { get; set; } = "";
    public bool installed { get; set; }
    public bool registered { get; set; }
    public bool verified { get; set; }
    public string note { get; set; } = "";
}

sealed class ProviderStatus
{
    public string Name = "", Backend = "", Target = "", Roles = "";
    public bool Disabled;
    public int Priority = 100;
}

sealed class UiSnapshot
{
    public McpDetails? Mcp;
    public ProjectMetrics Project = new();
    public List<IntegrationStatus> Integrations = new();
    public List<ProviderStatus> Providers = new();
    public bool HasProject;
}

static class Inspector
{
    static IEnumerable<string> JsonFiles(string dir) => Directory.Exists(dir) ? Directory.EnumerateFiles(dir, "*.json") : Array.Empty<string>();

    public static ProjectMetrics Project(string project)
    {
        var m = new ProjectMetrics(); var state = System.IO.Path.Combine(project, ".statefulclanker"); if (!Directory.Exists(state)) return m;
        var active = JsonFiles(System.IO.Path.Combine(state, "telemetry", "active")).ToArray(); m.ActiveAgents = active.Length;
        foreach (var file in active) { try { using var d = JsonDocument.Parse(File.ReadAllText(file)); AddModels(m, d.RootElement); } catch { } }
        var runs = JsonFiles(System.IO.Path.Combine(state, "telemetry", "runs")).ToArray(); m.Sessions = runs.Length;
        foreach (var file in runs)
        {
            try { using var d = JsonDocument.Parse(File.ReadAllText(file)); var r=d.RootElement; if (r.TryGetProperty("stage", out var s) && s.GetString() == "critic") m.Critics++; AddUsage(m,r); } catch { }
        }
        foreach (var file in JsonFiles(System.IO.Path.Combine(state, "tasks")))
        {
            m.TotalTasks++; try { using var d = JsonDocument.Parse(File.ReadAllText(file)); if (d.RootElement.TryGetProperty("status", out var s) && s.GetString() == "complete") m.CompleteTasks++; } catch { }
        }
        try { m.Goal = JsonNode.Parse(File.ReadAllText(System.IO.Path.Combine(state, "state.json")))?["goal"]?.GetValue<string>() ?? ""; } catch { }
        try { m.IntentRevision = JsonNode.Parse(File.ReadAllText(System.IO.Path.Combine(state, "intent", "contract.json")))?["revision"]?.ToString() ?? "—"; } catch { }
        m.Commits = CommitCount(project); m.Activity = Activity(System.IO.Path.Combine(state, "events.jsonl")); return m;
    }

    static long Number(JsonElement r,string name) => r.TryGetProperty(name,out var n) && n.ValueKind==JsonValueKind.Number && n.TryGetInt64(out var v) ? v : 0;
    static void PutModel(ProjectMetrics m,string? model,long tokens=0) { if(string.IsNullOrWhiteSpace(model)) return; m.ModelTokens[model]=m.ModelTokens.TryGetValue(model,out var old)?old+tokens:tokens; }
    static void AddModels(ProjectMetrics m,JsonElement r)
    {
        if(r.TryGetProperty("actualModels",out var actual) && actual.ValueKind==JsonValueKind.Array){foreach(var x in actual.EnumerateArray()) if(x.ValueKind==JsonValueKind.String) PutModel(m,x.GetString());return;}
        if(r.TryGetProperty("model",out var model) && model.ValueKind==JsonValueKind.String) PutModel(m,model.GetString());
    }
    static void AddUsage(ProjectMetrics m,JsonElement r)
    {
        m.UsageReports+=Number(r,"usageReports");m.PromptTokens+=Number(r,"promptTokens");m.CompletionTokens+=Number(r,"completionTokens");m.TotalTokens+=Number(r,"totalTokens");
        if(r.TryGetProperty("modelUsage",out var usage) && usage.ValueKind==JsonValueKind.Array){foreach(var row in usage.EnumerateArray()){var model=row.TryGetProperty("model",out var x)&&x.ValueKind==JsonValueKind.String?x.GetString():null;PutModel(m,model,Number(row,"totalTokens"));}return;}
        AddModels(m,r);
    }

    static int CommitCount(string project)
    {
        var r = Runtime.Run("git", project, "log", "--all", "--author=statefulclanker@localhost", "--format=%H");
        if (r.code != 0) return 0;
        return r.stdout.Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries).Length;
    }

    static string Activity(string path)
    {
        if (!File.Exists(path)) return "No activity recorded.";
        var sb = new StringBuilder();
        try
        {
            foreach (var line in File.ReadLines(path).Where(x => !string.IsNullOrWhiteSpace(x)).TakeLast(100).Reverse())
            {
                try
                {
                    using var d = JsonDocument.Parse(line); var r = d.RootElement;
                    var ts = r.TryGetProperty("ts", out var t) ? t.GetString() : ""; var type = r.TryGetProperty("type", out var ty) ? ty.GetString() : "event"; var msg = r.TryGetProperty("message", out var mm) ? mm.GetString() : "";
                    var clock = DateTimeOffset.TryParse(ts, out var dto) ? dto.ToLocalTime().ToString("MM-dd HH:mm:ss") : ts;
                    sb.Append(clock).Append("  ").Append(type); if (!string.IsNullOrWhiteSpace(msg)) sb.Append("  ").Append(msg); sb.AppendLine();
                }
                catch { }
            }
        }
        catch { }
        return sb.Length == 0 ? "No activity recorded." : sb.ToString();
    }
}

static class Theme
{
    public static readonly Color Back = Color.FromArgb(16, 22, 29), Surface = Color.FromArgb(24, 33, 43), Surface2 = Color.FromArgb(31, 42, 54), Border = Color.FromArgb(52, 69, 86), Text = Color.FromArgb(232, 239, 245), Muted = Color.FromArgb(135, 153, 171), Accent = Color.FromArgb(85, 198, 232), Good = Color.FromArgb(73, 217, 145), Warn = Color.FromArgb(255, 174, 74);
    public static void Apply(Control root)
    {
        root.BackColor = Back; root.ForeColor = Text;
        foreach (Control c in root.Controls)
        {
            if (c is Button b) { b.FlatStyle = FlatStyle.Flat; b.FlatAppearance.BorderColor = Border; b.BackColor = Surface2; b.ForeColor = Text; }
            else if (c is TextBox tb) { tb.BackColor = Surface; tb.ForeColor = Text; }
            else if (c is TreeView tv) { tv.BackColor = Surface; tv.ForeColor = Text; tv.BorderStyle = BorderStyle.FixedSingle; }
            else if (c is DataGridView dg) { dg.BackgroundColor = Surface; dg.GridColor = Border; dg.BorderStyle = BorderStyle.None; dg.DefaultCellStyle.BackColor = Surface; dg.DefaultCellStyle.ForeColor = Text; dg.DefaultCellStyle.SelectionBackColor = Surface2; dg.DefaultCellStyle.SelectionForeColor = Text; dg.ColumnHeadersDefaultCellStyle.BackColor = Surface2; dg.ColumnHeadersDefaultCellStyle.ForeColor = Text; dg.EnableHeadersVisualStyles = false; }
            Apply(c);
        }
    }
}

sealed class BlinkenLightsPanel : Control
{
    readonly System.Windows.Forms.Timer _pulse = new() { Interval = 110 };
    readonly Random _rng = new();
    const int TotalLamps = 160;
    readonly bool[] _lamps = new bool[TotalLamps];
    readonly byte[] _colorPalette = new byte[TotalLamps];
    int _sweepStep;
    bool _active;

    public bool Active
    {
        get => _active;
        set
        {
            if (_active == value) return;
            _active = value;
            _pulse.Interval = value ? 110 : 250;
            Invalidate();
        }
    }

    public BlinkenLightsPanel()
    {
        DoubleBuffered = true;
        MinimumSize = new Size(220, 72);
        for (var i = 0; i < TotalLamps; i++)
        {
            var roll = _rng.Next(100);
            _colorPalette[i] = roll < 35 ? (byte)3 : roll < 60 ? (byte)1 : roll < 80 ? (byte)2 : roll < 95 ? (byte)0 : (byte)4;
        }
        _pulse.Tick += (_, _) => Step();
        _pulse.Start();
    }

    void Step()
    {
        _sweepStep = (_sweepStep + 1) % 32;
        if (Active)
        {
            for (var i = 0; i < TotalLamps; i++)
            {
                var bank = i / 40;
                var col = i % 10;
                var sweepHit = ((col + bank * 2) % 10) == (_sweepStep % 10);
                if (_rng.NextDouble() < 0.65)
                {
                    _lamps[i] = sweepHit ? (_rng.NextDouble() < 0.85) : (_rng.NextDouble() < 0.42);
                }
            }
        }
        else
        {
            for (var i = 0; i < TotalLamps; i++)
            {
                if (_rng.NextDouble() < 0.08)
                    _lamps[i] = _rng.NextDouble() < 0.06;
            }
        }
        Invalidate();
    }

    static Color GetColor(byte code, bool on)
    {
        Color lit = code switch
        {
            0 => Color.FromArgb(255, 60, 60),
            1 => Color.FromArgb(255, 140, 30),
            2 => Color.FromArgb(255, 210, 40),
            3 => Color.FromArgb(50, 235, 110),
            _ => Color.FromArgb(60, 210, 255)
        };
        return on ? lit : Color.FromArgb(28, Math.Max(20, (int)(lit.R * 0.22f)), Math.Max(25, (int)(lit.G * 0.22f)), Math.Max(25, (int)(lit.B * 0.22f)));
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        var g = e.Graphics;
        g.Clear(Color.FromArgb(10, 14, 18));

        const int numBanks = 4;
        const int rowsPerBank = 4;
        const int colsPerBank = 10;
        var gap = 6;
        var availWidth = Width - gap * (numBanks + 1);
        var bankWidth = Math.Max(40, availWidth / numBanks);
        var bankHeight = Height - gap * 2;

        for (var b = 0; b < numBanks; b++)
        {
            var r = new Rectangle(gap + b * (bankWidth + gap), gap, bankWidth, bankHeight);
            DrawBank(g, r, b * (rowsPerBank * colsPerBank), rowsPerBank, colsPerBank);
        }
    }

    void DrawBank(Graphics g, Rectangle r, int offset, int rows, int cols)
    {
        using var panelBrush = new SolidBrush(Color.FromArgb(18, 24, 30));
        using var edgePen = new Pen(Color.FromArgb(48, 62, 76));
        using var innerPen = new Pen(Color.FromArgb(30, 38, 48));

        g.FillRectangle(panelBrush, r);
        g.DrawRectangle(edgePen, r);

        using var screwBrush = new SolidBrush(Color.FromArgb(80, 92, 104));
        g.FillEllipse(screwBrush, r.Left + 3, r.Top + 3, 3, 3);
        g.FillEllipse(screwBrush, r.Right - 6, r.Top + 3, 3, 3);
        g.FillEllipse(screwBrush, r.Left + 3, r.Bottom - 6, 3, 3);
        g.FillEllipse(screwBrush, r.Right - 6, r.Bottom - 6, 3, 3);

        var padX = 10;
        var padY = 8;
        var drawW = r.Width - padX * 2;
        var drawH = r.Height - padY * 2;
        if (drawW <= 0 || drawH <= 0) return;

        var ledW = Math.Max(4, (drawW - (cols - 1) * 3) / cols);
        var ledH = Math.Max(4, (drawH - (rows - 1) * 3) / rows);
        var spacingX = (drawW - ledW * cols) / Math.Max(1, cols - 1) + ledW;
        var spacingY = (drawH - ledH * rows) / Math.Max(1, rows - 1) + ledH;

        for (var row = 0; row < rows; row++)
        {
            for (var col = 0; col < cols; col++)
            {
                var idx = (offset + row * cols + col) % TotalLamps;
                var x = r.X + padX + col * spacingX;
                var y = r.Y + padY + row * spacingY;
                var on = _lamps[idx];
                var c = GetColor(_colorPalette[idx], on);

                using var b = new SolidBrush(c);
                g.FillRectangle(b, x, y, ledW, ledH);

                if (on)
                {
                    using var center = new SolidBrush(Color.FromArgb(200, 255, 255, 255));
                    g.FillRectangle(center, x + 1, y + 1, Math.Max(1, ledW - 2), Math.Max(1, ledH - 2));
                }
                else
                {
                    g.DrawRectangle(innerPen, x, y, ledW, ledH);
                }
            }
        }
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing) _pulse.Dispose();
        base.Dispose(disposing);
    }
}

sealed class MainForm : Form
{
    readonly string _root = Runtime.FindRoot();
    readonly AppSettings _settings = AppStore.Load();
    readonly TreeView _projects = new();
    readonly TabControl _tabs = new();
    readonly Label _header = new(), _mcpState = new(), _intent = new(), _goal = new();
    readonly Label[] _metrics = Enumerable.Range(0, 5).Select(_ => new Label()).ToArray();
    readonly TextBox _usage = new(), _overviewActivity = new(), _allActivity = new(), _endpoint = new(), _stdio = new(), _integrationNote = new();
    readonly BlinkenLightsPanel _blinken = new();
    readonly DataGridView _integrations = new(), _providers = new();
    readonly System.Windows.Forms.Timer _timer = new() { Interval = 3000 };
    int _refreshing;
    readonly McpHost _mcp;
    readonly AutofillHost _autofill;
    readonly NotifyIcon _notify;
    bool _reallyExit;

    public MainForm()
    {
        Text = "StatefulClanker"; Width = 1160; Height = 740; MinimumSize = new Size(920, 590); StartPosition = FormStartPosition.CenterScreen;
        try { using var s = typeof(MainForm).Assembly.GetManifestResourceStream("StatefulClanker.ico"); if (s is not null) Icon = new Icon(s); } catch { }
        _mcp = new McpHost(_root, _settings.HttpPort, _settings.McpToken); _mcp.EnsureStarted(); _autofill = new AutofillHost(_root);
        var menu = new ContextMenuStrip(); menu.Items.Add("Open StatefulClanker", null, (_, _) => ShowFromTray()); menu.Items.Add("Exit", null, (_, _) => { _reallyExit = true; Close(); });
        _notify = new NotifyIcon { Text = "StatefulClanker", Icon = Icon ?? SystemIcons.Application, Visible = true, ContextMenuStrip = menu }; _notify.DoubleClick += (_, _) => ShowFromTray();
        BuildUi(); RestoreProjects(); Theme.Apply(this); _ = RefreshAllAsync();
        _timer.Tick += async (_, _) => await RefreshAllAsync(); _timer.Start(); Resize += (_, _) => { if (WindowState == FormWindowState.Minimized) Hide(); }; FormClosing += HandleFormClosing;
    }

    static Button Btn(string text, int width = 145) => new() { Text = text, Width = width, Height = 32, Margin = new Padding(0, 4, 8, 0) };
    static Label Section(string text) => new() { Text = text, Dock = DockStyle.Fill, TextAlign = ContentAlignment.BottomLeft, Font = new Font("Segoe UI Semibold", 8, FontStyle.Bold), ForeColor = Theme.Muted };
    TabPage Page(string name) => new(name) { Padding = new Padding(12), BackColor = Theme.Back, ForeColor = Theme.Text };

    void BuildUi()
    {
        var shell = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, RowCount = 1, BackColor = Theme.Back };
        shell.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 270)); shell.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); Controls.Add(shell);
        var left = new TableLayoutPanel { Dock = DockStyle.Fill, RowCount = 5, ColumnCount = 1, Padding = new Padding(12), Margin = new Padding(0) };
        left.RowStyles.Add(new RowStyle(SizeType.Absolute, 38)); left.RowStyles.Add(new RowStyle(SizeType.Percent, 100)); for (var i = 0; i < 3; i++) left.RowStyles.Add(new RowStyle(SizeType.Absolute, 42));
        left.Controls.Add(new Label { Text = "STATEFULCLANKER", Dock = DockStyle.Fill, Font = new Font("Segoe UI Semibold", 12, FontStyle.Bold), ForeColor = Theme.Accent, TextAlign = ContentAlignment.MiddleLeft }, 0, 0);
        _projects.Dock = DockStyle.Fill; _projects.HideSelection = false; _projects.AfterSelect += (_, _) => SelectProject(); left.Controls.Add(_projects, 0, 1);
        var add = Btn("+ Add / open project", 210); add.Dock = DockStyle.Fill; add.Click += (_, _) => AddProject(); left.Controls.Add(add, 0, 2);
        var remove = Btn("Remove from list", 210); remove.Dock = DockStyle.Fill; remove.Click += (_, _) => RemoveProject(); left.Controls.Add(remove, 0, 3);
        var explorer = Btn("Open in Explorer", 210); explorer.Dock = DockStyle.Fill; explorer.Click += (_, _) => OpenExplorer(); left.Controls.Add(explorer, 0, 4); shell.Controls.Add(left, 0, 0);

        var right = new TableLayoutPanel { Dock = DockStyle.Fill, RowCount = 2, ColumnCount = 1, Padding = new Padding(14) }; right.RowStyles.Add(new RowStyle(SizeType.Absolute, 52)); right.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        var top = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, RowCount = 1 }; top.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); top.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 210));
        _header.Dock = DockStyle.Fill; _header.Font = new Font("Segoe UI Semibold", 15, FontStyle.Bold); _header.TextAlign = ContentAlignment.MiddleLeft; _mcpState.Dock = DockStyle.Fill; _mcpState.TextAlign = ContentAlignment.MiddleCenter; _mcpState.Font = new Font("Segoe UI Semibold", 9, FontStyle.Bold); top.Controls.Add(_header, 0, 0); top.Controls.Add(_mcpState, 1, 0); right.Controls.Add(top, 0, 0);
        _tabs.Dock = DockStyle.Fill; _tabs.TabPages.Add(BuildOverview()); _tabs.TabPages.Add(BuildActivity()); _tabs.TabPages.Add(BuildIntegrations()); _tabs.TabPages.Add(BuildProviders()); right.Controls.Add(_tabs, 0, 1); right.Margin = new Padding(0); shell.Controls.Add(right, 1, 0);
    }

    TabPage BuildOverview()
    {
        var p = Page("Overview"); var rows = new TableLayoutPanel { Dock = DockStyle.Fill, RowCount = 8, ColumnCount = 1 };
        rows.RowStyles.Add(new RowStyle(SizeType.Absolute, 96)); rows.RowStyles.Add(new RowStyle(SizeType.Absolute, 76)); rows.RowStyles.Add(new RowStyle(SizeType.Absolute, 26)); rows.RowStyles.Add(new RowStyle(SizeType.Absolute, 86)); rows.RowStyles.Add(new RowStyle(SizeType.Absolute, 26)); rows.RowStyles.Add(new RowStyle(SizeType.Absolute, 84)); rows.RowStyles.Add(new RowStyle(SizeType.Absolute, 26)); rows.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        var metricNames = new[] { "ACTIVE AGENTS", "WORKER SESSIONS", "COMMITS", "CRITIC RUNS", "TASKS COMPLETE" }; var metrics = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 5, RowCount = 1 };
        for (var i = 0; i < 5; i++) { metrics.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 20)); _metrics[i].Dock = DockStyle.Fill; _metrics[i].Margin = new Padding(5); _metrics[i].TextAlign = ContentAlignment.MiddleCenter; _metrics[i].Font = new Font("Cascadia Mono", 12, FontStyle.Bold); _metrics[i].Text = metricNames[i] + "\r\n—"; metrics.Controls.Add(_metrics[i], i, 0); }
        _blinken.Dock = DockStyle.Fill; _blinken.Margin = new Padding(5,2,5,2);
        _usage.Dock = DockStyle.Fill; _usage.Multiline = true; _usage.ReadOnly = true; _usage.ScrollBars = ScrollBars.Vertical; _usage.WordWrap = false; _usage.Font = new Font("Cascadia Mono", 8.5f);
        var authority = new Panel { Dock = DockStyle.Fill, Padding = new Padding(12), BackColor = Theme.Surface }; _intent.Dock = DockStyle.Top; _intent.Height = 26; _intent.ForeColor = Theme.Accent; _intent.Font = new Font("Cascadia Mono", 9, FontStyle.Bold); _goal.Dock = DockStyle.Fill; authority.Controls.Add(_goal); authority.Controls.Add(_intent);
        _overviewActivity.Dock = DockStyle.Fill; _overviewActivity.Multiline = true; _overviewActivity.ReadOnly = true; _overviewActivity.ScrollBars = ScrollBars.Vertical; _overviewActivity.Font = new Font("Cascadia Mono", 8.5f);
        rows.Controls.Add(metrics, 0, 0); rows.Controls.Add(_blinken, 0, 1); rows.Controls.Add(Section("MODEL / TOKEN USAGE"), 0, 2); rows.Controls.Add(_usage, 0, 3); rows.Controls.Add(Section("PROJECT AUTHORITY"), 0, 4); rows.Controls.Add(authority, 0, 5); rows.Controls.Add(Section("RECENT ACTIVITY"), 0, 6); rows.Controls.Add(_overviewActivity, 0, 7); p.Controls.Add(rows); return p;
    }

    TabPage BuildActivity()
    {
        var p = Page("Activity"); _allActivity.Dock = DockStyle.Fill; _allActivity.Multiline = true; _allActivity.ReadOnly = true; _allActivity.ScrollBars = ScrollBars.Both; _allActivity.WordWrap = false; _allActivity.Font = new Font("Cascadia Mono", 9); p.Controls.Add(_allActivity); return p;
    }

    TabPage BuildIntegrations()
    {
        var p = Page("Integrations"); var rows = new TableLayoutPanel { Dock = DockStyle.Fill, RowCount = 7, ColumnCount = 1 }; rows.RowStyles.Add(new RowStyle(SizeType.Absolute, 28)); rows.RowStyles.Add(new RowStyle(SizeType.Absolute, 50)); rows.RowStyles.Add(new RowStyle(SizeType.Absolute, 28)); rows.RowStyles.Add(new RowStyle(SizeType.Absolute, 50)); rows.RowStyles.Add(new RowStyle(SizeType.Absolute, 44)); rows.RowStyles.Add(new RowStyle(SizeType.Absolute, 28)); rows.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        rows.Controls.Add(Section("RESIDENT STREAMABLE MCP"), 0, 0); _endpoint.Dock = DockStyle.Fill; _endpoint.ReadOnly = true; _endpoint.Font = new Font("Cascadia Mono", 9); rows.Controls.Add(_endpoint, 0, 1);
        rows.Controls.Add(Section("STDIO BRIDGE"), 0, 2); _stdio.Dock = DockStyle.Fill; _stdio.ReadOnly = true; _stdio.Font = new Font("Cascadia Mono", 9); rows.Controls.Add(_stdio, 0, 3);
        var bar = new FlowLayoutPanel { Dock = DockStyle.Fill }; var copyEndpoint = Btn("Copy endpoint"); copyEndpoint.Click += (_, _) => Copy(_endpoint.Text); var copyToken = Btn("Copy token"); copyToken.Click += (_, _) => Copy(_mcp.Details()?.token ?? ""); var register = Btn("Register selected"); register.Click += (_, _) => RegisterSelected(); var remove = Btn("Remove selected"); remove.Click += (_, _) => UnregisterSelected(); bar.Controls.AddRange(new Control[] { copyEndpoint, copyToken, register, remove }); rows.Controls.Add(bar, 0, 4);
        rows.Controls.Add(Section("CLIENT INTEGRATIONS"), 0, 5); _integrations.Dock = DockStyle.Fill; _integrations.ReadOnly = true; _integrations.AllowUserToAddRows = false; _integrations.RowHeadersVisible = false; _integrations.SelectionMode = DataGridViewSelectionMode.FullRowSelect; _integrations.AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.Fill; _integrations.Columns.Add("client", "Client"); _integrations.Columns.Add("installed", "Installed"); _integrations.Columns.Add("registered", "Registered"); _integrations.Columns.Add("verified", "Path verified"); _integrations.Columns.Add("note", "Note"); rows.Controls.Add(_integrations, 0, 6);
        p.Controls.Add(rows); return p;
    }

    TabPage BuildProviders()
    {
        var p = Page("Providers"); var rows = new TableLayoutPanel { Dock = DockStyle.Fill, RowCount = 4, ColumnCount = 1 };
        rows.RowStyles.Add(new RowStyle(SizeType.Absolute, 42));
        rows.RowStyles.Add(new RowStyle(SizeType.Absolute, 42));
        rows.RowStyles.Add(new RowStyle(SizeType.Absolute, 32));
        rows.RowStyles.Add(new RowStyle(SizeType.Percent, 100));

        var bar = new FlowLayoutPanel { Dock = DockStyle.Fill, WrapContents = false };
        var toggle = Btn("Disable / Enable", 125); toggle.Click += (_, _) => ToggleSelectedProviderDisabled();
        var moveUp = Btn("Move Up", 85); moveUp.Click += (_, _) => AdjustProviderPriority(-1);
        var moveDown = Btn("Move Down", 90); moveDown.Click += (_, _) => AdjustProviderPriority(1);
        var test = Btn("Test Provider", 105); test.Click += (_, _) => TestSelectedProvider();
        var open = Btn("Open config", 100); open.Click += (_, _) => OpenConfig();
        var refresh = Btn("Refresh", 85); refresh.Click += async (_, _) => await RefreshAllAsync();
        bar.Controls.AddRange(new Control[] { toggle, moveUp, moveDown, test, open, refresh });

        var roleBar = new FlowLayoutPanel { Dock = DockStyle.Fill, WrapContents = false };
        var roleLbl = new Label { Text = "Routing role:", AutoSize = true, Margin = new Padding(4, 10, 4, 0), ForeColor = Theme.Muted };
        var setDefault = Btn("Set Default", 95); setDefault.Click += (_, _) => SetProviderRole("defaultProvider");
        var setCritic = Btn("Set Critic", 90); setCritic.Click += (_, _) => SetProviderRole("criticProvider");
        var setValidator = Btn("Set Validator", 105); setValidator.Click += (_, _) => SetProviderRole("validatorProvider");
        var sizeLbl = new Label { Text = "Task size:", AutoSize = true, Margin = new Padding(12, 10, 4, 0), ForeColor = Theme.Muted };
        var setTiny = Btn("Set Tiny", 80); setTiny.Click += (_, _) => SetProviderRole("tiny");
        var setSmall = Btn("Set Small", 85); setSmall.Click += (_, _) => SetProviderRole("small");
        var setMed = Btn("Set Medium", 95); setMed.Click += (_, _) => SetProviderRole("medium");
        var setLrg = Btn("Set Large", 85); setLrg.Click += (_, _) => SetProviderRole("large");
        var clearRoles = Btn("Clear Roles", 95); clearRoles.Click += (_, _) => ClearProviderRoles();
        roleBar.Controls.AddRange(new Control[] { roleLbl, setDefault, setCritic, setValidator, sizeLbl, setTiny, setSmall, setMed, setLrg, clearRoles });

        rows.Controls.Add(bar, 0, 0);
        rows.Controls.Add(roleBar, 0, 1);
        rows.Controls.Add(Section("WORKER BACKEND STATUS, PRIORITY, AND ROUTING"), 0, 2);

        _providers.Dock = DockStyle.Fill; _providers.ReadOnly = true; _providers.AllowUserToAddRows = false; _providers.RowHeadersVisible = false; _providers.SelectionMode = DataGridViewSelectionMode.FullRowSelect; _providers.AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.Fill;
        _providers.Columns.Add("name", "Provider");
        _providers.Columns.Add("status", "Status");
        _providers.Columns.Add("priority", "Priority");
        _providers.Columns.Add("backend", "Backend");
        _providers.Columns.Add("target", "Target");
        _providers.Columns.Add("roles", "Routing / roles");

        var menu = new ContextMenuStrip();
        menu.Items.Add("Disable / Enable", null, (_, _) => ToggleSelectedProviderDisabled());
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Move Up (Priority)", null, (_, _) => AdjustProviderPriority(-1));
        menu.Items.Add("Move Down (Priority)", null, (_, _) => AdjustProviderPriority(1));
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Set as Default Provider", null, (_, _) => SetProviderRole("defaultProvider"));
        menu.Items.Add("Set as Critic Provider", null, (_, _) => SetProviderRole("criticProvider"));
        menu.Items.Add("Set as Validator Provider", null, (_, _) => SetProviderRole("validatorProvider"));
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Set for Tiny Tasks", null, (_, _) => SetProviderRole("tiny"));
        menu.Items.Add("Set for Small Tasks", null, (_, _) => SetProviderRole("small"));
        menu.Items.Add("Set for Medium Tasks", null, (_, _) => SetProviderRole("medium"));
        menu.Items.Add("Set for Large Tasks", null, (_, _) => SetProviderRole("large"));
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Clear Roles & Sizes for Provider", null, (_, _) => ClearProviderRoles());
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Test Provider", null, (_, _) => TestSelectedProvider());

        _providers.ContextMenuStrip = menu;
        _providers.CellMouseDown += (s, e) =>
        {
            if (e.Button == MouseButtons.Right && e.RowIndex >= 0)
            {
                _providers.ClearSelection();
                _providers.Rows[e.RowIndex].Selected = true;
            }
        };

        rows.Controls.Add(_providers, 0, 3);
        p.Controls.Add(rows);
        return p;
    }

    ProviderStatus? SelectedProvider => _providers.SelectedRows.Count > 0 ? _providers.SelectedRows[0].Tag as ProviderStatus : null;

    void ToggleSelectedProviderDisabled()
    {
        var p = SelectedProvider;
        var path = _settings.ActiveProjectPath;
        if (p is null || string.IsNullOrWhiteSpace(path)) return;
        var cfgPath = System.IO.Path.Combine(path, ".statefulclanker", "config.json");
        if (!File.Exists(cfgPath)) return;
        try
        {
            var node = JsonNode.Parse(File.ReadAllText(cfgPath));
            var providers = node?["providers"] as JsonObject;
            if (providers is not null && providers.TryGetPropertyValue(p.Name, out var pNode) && pNode is JsonObject pObj)
            {
                var current = pObj.TryGetPropertyValue("disabled", out var dv) && dv is not null && dv.GetValue<bool>();
                pObj["disabled"] = !current;
                File.WriteAllText(cfgPath, node!.ToJsonString(new JsonSerializerOptions { WriteIndented = true }), new UTF8Encoding(false));
                _ = RefreshAllAsync();
            }
        }
        catch (Exception ex)
        {
            MessageBox.Show(this, "Failed to update provider status: " + ex.Message, "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }

    void AdjustProviderPriority(int direction)
    {
        var p = SelectedProvider;
        var path = _settings.ActiveProjectPath;
        if (p is null || string.IsNullOrWhiteSpace(path)) return;
        var cfgPath = System.IO.Path.Combine(path, ".statefulclanker", "config.json");
        if (!File.Exists(cfgPath)) return;
        try
        {
            var node = JsonNode.Parse(File.ReadAllText(cfgPath));
            var providers = node?["providers"] as JsonObject;
            if (providers is null) return;

            var list = new List<(string Name, int Priority, JsonObject Obj)>();
            int fallbackPri = 1;
            foreach (var kv in providers)
            {
                if (kv.Value is JsonObject obj)
                {
                    int pri = obj.TryGetPropertyValue("priority", out var pv) && pv is not null && int.TryParse(pv.ToString(), out var parsed)
                        ? parsed
                        : fallbackPri * 10;
                    list.Add((kv.Key, pri, obj));
                    fallbackPri++;
                }
            }
            if (list.Count < 2) return;
            list = list.OrderBy(x => x.Priority).ThenBy(x => x.Name, StringComparer.OrdinalIgnoreCase).ToList();
            var currentIndex = list.FindIndex(x => x.Name == p.Name);
            if (currentIndex < 0) return;
            var targetIndex = currentIndex + direction;
            if (targetIndex < 0 || targetIndex >= list.Count) return;

            var item = list[currentIndex];
            list.RemoveAt(currentIndex);
            list.Insert(targetIndex, item);

            for (int i = 0; i < list.Count; i++)
            {
                list[i].Obj["priority"] = i + 1;
            }

            File.WriteAllText(cfgPath, node!.ToJsonString(new JsonSerializerOptions { WriteIndented = true }), new UTF8Encoding(false));
            _ = RefreshAllAsync();
        }
        catch (Exception ex)
        {
            MessageBox.Show(this, "Failed to adjust provider priority: " + ex.Message, "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }

    void SetProviderRole(string roleOrSize)
    {
        var p = SelectedProvider;
        var path = _settings.ActiveProjectPath;
        if (p is null || string.IsNullOrWhiteSpace(path)) return;
        var cfgPath = System.IO.Path.Combine(path, ".statefulclanker", "config.json");
        if (!File.Exists(cfgPath)) return;
        try
        {
            var node = JsonNode.Parse(File.ReadAllText(cfgPath));
            if (node is null) return;

            if (roleOrSize is "tiny" or "small" or "medium" or "large")
            {
                if (node["providerBySize"] is not JsonObject bySize)
                {
                    bySize = new JsonObject();
                    node["providerBySize"] = bySize;
                }
                bySize[roleOrSize] = p.Name;
            }
            else
            {
                node[roleOrSize] = p.Name;
            }

            File.WriteAllText(cfgPath, node.ToJsonString(new JsonSerializerOptions { WriteIndented = true }), new UTF8Encoding(false));
            _ = RefreshAllAsync();
        }
        catch (Exception ex)
        {
            MessageBox.Show(this, "Failed to update config: " + ex.Message, "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }

    void ClearProviderRoles()
    {
        var p = SelectedProvider;
        var path = _settings.ActiveProjectPath;
        if (p is null || string.IsNullOrWhiteSpace(path)) return;
        var cfgPath = System.IO.Path.Combine(path, ".statefulclanker", "config.json");
        if (!File.Exists(cfgPath)) return;
        try
        {
            var node = JsonNode.Parse(File.ReadAllText(cfgPath));
            if (node is null) return;

            if (node["defaultProvider"]?.ToString() == p.Name) node.AsObject().Remove("defaultProvider");
            if (node["criticProvider"]?.ToString() == p.Name) node.AsObject().Remove("criticProvider");
            if (node["validatorProvider"]?.ToString() == p.Name) node.AsObject().Remove("validatorProvider");

            if (node["providerBySize"] is JsonObject bySize)
            {
                foreach (var size in new[] { "tiny", "small", "medium", "large" })
                {
                    if (bySize[size]?.ToString() == p.Name)
                    {
                        bySize.Remove(size);
                    }
                }
            }

            File.WriteAllText(cfgPath, node.ToJsonString(new JsonSerializerOptions { WriteIndented = true }), new UTF8Encoding(false));
            _ = RefreshAllAsync();
        }
        catch (Exception ex)
        {
            MessageBox.Show(this, "Failed to clear provider roles: " + ex.Message, "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }

    void TestSelectedProvider()
    {
        var p = SelectedProvider;
        var path = _settings.ActiveProjectPath;
        if (p is null || string.IsNullOrWhiteSpace(path)) return;
        var harness = System.IO.Path.Combine(_root, "mcp", "StatefulClanker.McpCore.ps1");
        var command = $". '{harness.Replace("'", "''")}'; Test-McpProvider '{path.Replace("'", "''")}' @{{ name='{p.Name.Replace("'", "''")}' }} | ConvertTo-Json -Depth 5 -Compress";
        var r = Runtime.RunPowerShell(_root, "-Command", command);
        if (!string.IsNullOrWhiteSpace(r.stdout))
        {
            try
            {
                using var doc = JsonDocument.Parse(r.stdout);
                var elem = doc.RootElement;
                var usable = elem.TryGetProperty("usable", out var uv) && uv.GetBoolean();
                var diag = elem.TryGetProperty("diagnosis", out var dv) ? dv.GetString() : "";
                var icon = usable ? MessageBoxIcon.Information : MessageBoxIcon.Warning;
                MessageBox.Show(this, $"Provider: {p.Name}\nUsable: {usable}\n\nDiagnosis:\n{diag}", "Provider Test Result", MessageBoxButtons.OK, icon);
                return;
            }
            catch { }
        }
        MessageBox.Show(this, (r.stdout + "\n" + r.stderr).Trim(), "Provider Test Output", MessageBoxButtons.OK, MessageBoxIcon.Information);
    }

    void RestoreProjects()
    {
        _projects.Nodes.Clear(); TreeNode? active = null;
        foreach (var entry in _settings.Projects.OrderBy(x => x.Name, StringComparer.OrdinalIgnoreCase))
        {
            var node = new TreeNode(Directory.Exists(entry.Path) ? entry.Name : entry.Name + "  [missing]") { Tag = entry, ToolTipText = entry.Path }; _projects.Nodes.Add(node); if (SamePath(entry.Path, _settings.ActiveProjectPath)) active = node;
        }
        if (active is not null && Directory.Exists(((ProjectEntry)active.Tag!).Path)) { _projects.SelectedNode = active; active.EnsureVisible(); }
        else SetActiveProject(null);
    }

    static bool SamePath(string a, string? b)
    {
        if (b is null) return false; try { return string.Equals(System.IO.Path.GetFullPath(a).TrimEnd('\\'), System.IO.Path.GetFullPath(b).TrimEnd('\\'), StringComparison.OrdinalIgnoreCase); } catch { return false; }
    }

    ProjectEntry? SelectedProject => _projects.SelectedNode?.Tag as ProjectEntry;
    void SelectProject() { var p = SelectedProject; SetActiveProject(p is not null && Directory.Exists(p.Path) ? p.Path : null); }

    void SetActiveProject(string? path)
    {
        _settings.ActiveProjectPath = path; AppStore.Save(_settings); AppStore.SetActiveProject(path); _header.Text = path is null ? "No active project" : (SelectedProject?.Name ?? new DirectoryInfo(path).Name); Text = path is null ? "StatefulClanker" : $"StatefulClanker — {_header.Text}"; _ = RefreshAllAsync();
    }

    void AddProject()
    {
        using var picker = new FolderBrowserDialog { Description = "Select the project StatefulClanker should manage", UseDescriptionForTitle = true }; if (picker.ShowDialog(this) != DialogResult.OK) return; var path = System.IO.Path.GetFullPath(picker.SelectedPath);
        if (!File.Exists(System.IO.Path.Combine(path, ".statefulclanker", "state.json")))
        {
            if (MessageBox.Show(this, "Initialize StatefulClanker state in this folder?", "Initialize project", MessageBoxButtons.YesNo, MessageBoxIcon.Question) != DialogResult.Yes) return;
            var script = System.IO.Path.Combine(_root, "StatefulClanker.ps1"); var r = Runtime.RunPowerShell(path, "-File", script, "init"); if (r.code != 0) { MessageBox.Show(this, (r.stdout + Environment.NewLine + r.stderr).Trim(), "Initialization failed", MessageBoxButtons.OK, MessageBoxIcon.Error); return; }
        }
        if (_settings.Projects.All(x => !SamePath(x.Path, path))) _settings.Projects.Add(new ProjectEntry { Name = new DirectoryInfo(path).Name, Path = path }); AppStore.Save(_settings); RestoreProjects();
        foreach (TreeNode node in _projects.Nodes) if (node.Tag is ProjectEntry e && SamePath(e.Path, path)) { _projects.SelectedNode = node; break; }
    }

    void RemoveProject()
    {
        var p = SelectedProject; if (p is null) return; if (MessageBox.Show(this, $"Remove '{p.Name}' from the local list? No project files are deleted.", "Remove project", MessageBoxButtons.YesNo) != DialogResult.Yes) return;
        var active = SamePath(p.Path, _settings.ActiveProjectPath); _settings.Projects.RemoveAll(x => SamePath(x.Path, p.Path)); if (active) _settings.ActiveProjectPath = null; AppStore.Save(_settings); RestoreProjects();
    }

    void OpenExplorer() { var path = _settings.ActiveProjectPath; if (string.IsNullOrWhiteSpace(path) || !Directory.Exists(path)) return; try { Process.Start(new ProcessStartInfo("explorer.exe") { UseShellExecute = true, ArgumentList = { path } }); } catch { } }

    async Task RefreshAllAsync()
    {
        if (Interlocked.Exchange(ref _refreshing, 1) != 0) return;
        var projectPath = _settings.ActiveProjectPath;
        try
        {
            var snapshot = await Task.Run(() => BuildSnapshot(projectPath));
            if (IsDisposed || Disposing) return;
            ApplySnapshot(snapshot);
        }
        catch { }
        finally { Interlocked.Exchange(ref _refreshing, 0); }
    }

    UiSnapshot BuildSnapshot(string? projectPath)
    {
        _mcp.EnsureStarted(); _autofill.EnsureStarted(projectPath);
        var snapshot = new UiSnapshot { Mcp = _mcp.Details(), HasProject = !string.IsNullOrWhiteSpace(projectPath) && Directory.Exists(projectPath) };
        if (snapshot.HasProject)
        {
            snapshot.Project = Inspector.Project(projectPath!);
            snapshot.Providers = ReadProviderStatus(projectPath!);
        }
        snapshot.Integrations = ReadIntegrationStatus();
        return snapshot;
    }

    void ApplySnapshot(UiSnapshot snapshot)
    {
        var d = snapshot.Mcp;
        _mcpState.Text = d is null ? "MCP  STOPPED" : "MCP  RUNNING";
        _mcpState.ForeColor = d is null ? Theme.Warn : Theme.Good; _mcpState.BackColor = Theme.Surface;
        _endpoint.Text = d?.url ?? $"http://127.0.0.1:{_settings.HttpPort}/mcp (starting...)";
        var stdioScript = System.IO.Path.Combine(_root, "mcp", "StatefulClanker.Mcp.ps1");
        _stdio.Text = $"{Runtime.FindPowerShell()} -NoProfile -File \"{stdioScript}\"";
        if (snapshot.HasProject)
        {
            SetMetrics(snapshot.Project);
            _overviewActivity.Text = _allActivity.Text = snapshot.Project.Activity;
        }
        else
        {
            SetMetrics(new());
            _overviewActivity.Text = _allActivity.Text = "Select a project at left. StatefulClanker does not silently substitute a default project.";
        }
        _integrations.SuspendLayout();
        try
        {
            _integrations.Rows.Clear();
            foreach (var item in snapshot.Integrations) { var i = _integrations.Rows.Add(item.name, item.installed ? "yes" : "no", item.registered ? "yes" : "no", item.verified ? "yes" : "no", item.note); _integrations.Rows[i].Tag = item; }
        }
        finally { _integrations.ResumeLayout(); }
        _providers.SuspendLayout();
        try
        {
            _providers.Rows.Clear();
            foreach (var item in snapshot.Providers) {
                var statusText = item.Disabled ? "DISABLED" : "Active";
                var priText = item.Priority < 1000 ? item.Priority.ToString() : "-";
                var i = _providers.Rows.Add(item.Name, statusText, priText, item.Backend, item.Target, item.Roles);
                _providers.Rows[i].Tag = item;
                if (item.Disabled)
                {
                    _providers.Rows[i].DefaultCellStyle.ForeColor = Theme.Warn;
                }
            }
        }
        finally { _providers.ResumeLayout(); }
    }

    static string TokenText(long value) => value >= 1_000_000 ? $"{value / 1_000_000d:0.00}M" : value >= 1_000 ? $"{value / 1_000d:0.0}K" : value.ToString("N0");
    static string UsageText(ProjectMetrics m)
    {
        var sb = new StringBuilder();
        sb.Append("TOTAL ").Append(TokenText(m.TotalTokens)).Append("   INPUT ").Append(TokenText(m.PromptTokens)).Append("   OUTPUT ").Append(TokenText(m.CompletionTokens));
        if (m.UsageReports == 0) sb.Append("   [provider token telemetry unavailable]");
        foreach (var row in m.ModelTokens.OrderByDescending(x => x.Value).ThenBy(x => x.Key, StringComparer.OrdinalIgnoreCase))
            sb.AppendLine().Append(row.Key).Append("   ").Append(row.Value > 0 ? TokenText(row.Value) + " tokens" : "usage not reported");
        return m.ModelTokens.Count == 0 ? sb.AppendLine().Append("No model telemetry recorded yet.").ToString() : sb.ToString();
    }

    void SetMetrics(ProjectMetrics m)
    {
        _metrics[0].Text = $"ACTIVE AGENTS\r\n{m.ActiveAgents}"; _metrics[1].Text = $"WORKER SESSIONS\r\n{m.Sessions}"; _metrics[2].Text = $"COMMITS\r\n{m.Commits}"; _metrics[3].Text = $"CRITIC RUNS\r\n{m.Critics}"; _metrics[4].Text = $"TASKS COMPLETE\r\n{m.CompleteTasks}/{m.TotalTasks}"; _intent.Text = $"INTENT REVISION  {m.IntentRevision}"; _goal.Text = string.IsNullOrWhiteSpace(m.Goal) ? "No project goal recorded." : m.Goal;
        _usage.Text = UsageText(m); _blinken.Active = m.ActiveAgents > 0;
    }

    List<IntegrationStatus> ReadIntegrationStatus()
    {
        var module = System.IO.Path.Combine(_root, "lib", "StatefulClanker.Integrations.ps1"); var escaped = module.Replace("'", "''");
        var command = $". '{escaped}'; @(Get-SCIntegrationTargets | ForEach-Object {{ [pscustomobject]@{{ id=$_.id; name=$_.name; installed=[bool](Test-SCIntegrationInstalled $_); registered=[bool](Test-SCIntegrationRegistered $_); verified=[bool]$_.verified; note=$_.note }} }}) | ConvertTo-Json -Depth 6 -Compress";
        var r = Runtime.RunPowerShell(_root, "-Command", command); if (r.code != 0 || string.IsNullOrWhiteSpace(r.stdout)) return new();
        try { return JsonSerializer.Deserialize<List<IntegrationStatus>>(r.stdout, new JsonSerializerOptions { PropertyNameCaseInsensitive = true }) ?? new(); } catch { return new(); }
    }

    IntegrationStatus? SelectedIntegration => _integrations.SelectedRows.Count > 0 ? _integrations.SelectedRows[0].Tag as IntegrationStatus : null;

    void RegisterSelected()
    {
        var s = SelectedIntegration; if (s is null) return; if (!s.verified) { MessageBox.Show(this, "This integration's config path is not verified. Use its MCP settings and the stdio command shown above instead of allowing StatefulClanker to write a guessed path.", "Manual registration", MessageBoxButtons.OK, MessageBoxIcon.Information); return; }
        InvokeIntegrationMutation(s.id, true);
    }

    void UnregisterSelected() { var s = SelectedIntegration; if (s is null || !s.verified) return; InvokeIntegrationMutation(s.id, false); }

    void InvokeIntegrationMutation(string id, bool register)
    {
        var module = System.IO.Path.Combine(_root, "lib", "StatefulClanker.Integrations.ps1").Replace("'", "''"); var safeId = id.Replace("'", "''");
        var action = register ? "Register-SCIntegration $t $null (Get-SCInstallRoot) | ConvertTo-Json -Depth 6 -Compress" : "Unregister-SCIntegration $t | ConvertTo-Json -Compress";
        var cmd = $". '{module}'; $t=@(Get-SCIntegrationTargets | Where-Object {{ $_.id -eq '{safeId}' }})[0]; if($null -eq $t){{throw 'Integration not found'}}; {action}";
        var r = Runtime.RunPowerShell(_root, "-Command", cmd); if (r.code != 0) MessageBox.Show(this, (r.stdout + Environment.NewLine + r.stderr).Trim(), "Integration update failed", MessageBoxButtons.OK, MessageBoxIcon.Error); _ = RefreshAllAsync();
    }

    List<ProviderStatus> ReadProviderStatus(string path)
    {
        var result = new List<ProviderStatus>(); var cfg = System.IO.Path.Combine(path, ".statefulclanker", "config.json"); if (!File.Exists(cfg)) return result;
        try
        {
            using var d = JsonDocument.Parse(File.ReadAllText(cfg)); var root = d.RootElement; var def = root.TryGetProperty("defaultProvider", out var dv) ? dv.GetString() : null; var critic = root.TryGetProperty("criticProvider", out var cv) ? cv.GetString() : null; var validator = root.TryGetProperty("validatorProvider", out var vv) ? vv.GetString() : null; var routes = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            if (root.TryGetProperty("providerBySize", out var map) && map.ValueKind == JsonValueKind.Object) foreach (var x in map.EnumerateObject()) if (x.Value.ValueKind == JsonValueKind.String) routes[x.Name] = x.Value.GetString() ?? "";
            if (!root.TryGetProperty("providers", out var providers) || providers.ValueKind != JsonValueKind.Object) return result;
            int defaultPri = 1;
            foreach (var p in providers.EnumerateObject())
            {
                var type = p.Value.TryGetProperty("type", out var tv) && tv.ValueKind == JsonValueKind.String ? tv.GetString() ?? "cli" : "cli";
                var cmd = p.Value.TryGetProperty("command", out var c) ? c.GetString() ?? "" : "";
                var connection = p.Value.TryGetProperty("connection", out var cn) ? cn.GetString() ?? "" : "";
                var target = type.Equals("api", StringComparison.OrdinalIgnoreCase) ? connection : cmd;
                var disabled = p.Value.TryGetProperty("disabled", out var disV) && disV.ValueKind == JsonValueKind.True;
                var pri = p.Value.TryGetProperty("priority", out var pv) && pv.TryGetInt32(out var parsedPri) ? parsedPri : (p.Name == def ? 0 : defaultPri * 10);
                defaultPri++;
                var status = disabled ? "disabled" : (type.Equals("api", StringComparison.OrdinalIgnoreCase) ? (string.IsNullOrWhiteSpace(connection) ? "missing" : "api") : (Runtime.CommandExists(cmd) ? "cli" : "missing"));
                var tags = new List<string>();
                if (p.Name == def) tags.Add("default");
                if (p.Name == critic) tags.Add("critic");
                if (p.Name == validator) tags.Add("validator");
                foreach (var route in routes.Where(x => x.Value == p.Name)) tags.Add(route.Key);
                result.Add(new ProviderStatus { Name = p.Name, Backend = status, Target = target, Roles = string.Join(", ", tags), Disabled = disabled, Priority = pri });
            }
            result = result.OrderBy(x => x.Priority).ThenBy(x => x.Name, StringComparer.OrdinalIgnoreCase).ToList();
        }
        catch { }
        return result;
    }

    void OpenConfig() { var path = _settings.ActiveProjectPath; if (string.IsNullOrWhiteSpace(path)) return; var cfg = System.IO.Path.Combine(path, ".statefulclanker", "config.json"); if (File.Exists(cfg)) try { Process.Start(new ProcessStartInfo("notepad.exe") { UseShellExecute = true, ArgumentList = { cfg } }); } catch { } }
    static void Copy(string text) { if (!string.IsNullOrWhiteSpace(text)) Clipboard.SetText(text); }
    void ShowFromTray() { Show(); WindowState = FormWindowState.Normal; Activate(); }
    void HandleFormClosing(object? sender, FormClosingEventArgs e) { if (!_reallyExit) { e.Cancel = true; Hide(); return; } _timer.Stop(); _autofill.Dispose(); _mcp.Dispose(); _notify.Visible = false; _notify.Dispose(); }
}

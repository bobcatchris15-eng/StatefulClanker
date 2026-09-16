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
    public string Display => Directory.Exists(Path) ? Name : $"{Name}  [missing]";
}

sealed class AppSettings
{
    public List<ProjectEntry> Projects { get; set; } = new();
    public string? ActiveProjectPath { get; set; }
    public int HttpPort { get; set; } = 7337;
}

static class AppStore
{
    public static readonly string Root = System.IO.Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "StatefulClanker");
    public static readonly string SettingsPath = System.IO.Path.Combine(Root, "app.json");
    public static readonly string ActiveProjectPath = System.IO.Path.Combine(Root, "active-project.txt");
    public static readonly string McpDetailsPath = System.IO.Path.Combine(Root, "mcp-http.json");

    static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true, PropertyNameCaseInsensitive = true };

    public static AppSettings Load()
    {
        Directory.CreateDirectory(Root);
        try
        {
            if (File.Exists(SettingsPath))
                return JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(SettingsPath), JsonOptions) ?? new AppSettings();
        }
        catch { }
        return new AppSettings();
    }

    public static void Save(AppSettings settings)
    {
        Directory.CreateDirectory(Root);
        File.WriteAllText(SettingsPath, JsonSerializer.Serialize(settings, JsonOptions), new UTF8Encoding(false));
    }

    public static void WriteActiveProject(string? path)
    {
        Directory.CreateDirectory(Root);
        if (string.IsNullOrWhiteSpace(path))
        {
            try { File.Delete(ActiveProjectPath); } catch { }
            return;
        }
        File.WriteAllText(ActiveProjectPath, path, new UTF8Encoding(false));
    }
}

static class RuntimeLocator
{
    public static string FindInstallRoot()
    {
        var current = new DirectoryInfo(AppContext.BaseDirectory);
        for (var i = 0; i < 8 && current is not null; i++, current = current.Parent)
        {
            if (File.Exists(System.IO.Path.Combine(current.FullName, "StatefulClanker.ps1")) &&
                File.Exists(System.IO.Path.Combine(current.FullName, "mcp", "StatefulClanker.McpHttp.ps1")))
                return current.FullName;
        }
        return AppContext.BaseDirectory;
    }

    public static string FindPowerShell()
    {
        foreach (var candidate in new[]
        {
            System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "PowerShell", "7", "pwsh.exe"),
            "pwsh.exe",
            "powershell.exe"
        })
        {
            if (candidate.Contains('\\') && File.Exists(candidate)) return candidate;
            if (!candidate.Contains('\\') && CommandExists(candidate)) return candidate;
        }
        return "powershell.exe";
    }

    public static bool CommandExists(string command)
    {
        if (string.IsNullOrWhiteSpace(command)) return false;
        if (command.Contains('\\') || command.Contains('/')) return File.Exists(command);
        try
        {
            using var p = Process.Start(new ProcessStartInfo("where.exe", command)
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true
            });
            p?.WaitForExit(1500);
            return p?.ExitCode == 0;
        }
        catch { return false; }
    }

    public static string Quote(string value) => "\"" + value.Replace("\"", "\\\"") + "\"";
}

sealed class McpDetails
{
    public string? url { get; set; }
    public string? token { get; set; }
    public int pid { get; set; }
    public string? project { get; set; }
    public string? startedAt { get; set; }
}

sealed class McpHost : IDisposable
{
    readonly string _root;
    Process? _owned;
    public int Port { get; set; }

    public McpHost(string root, int port) { _root = root; Port = port; }

    public McpDetails? ReadDetails()
    {
        try
        {
            if (!File.Exists(AppStore.McpDetailsPath)) return null;
            var details = JsonSerializer.Deserialize<McpDetails>(File.ReadAllText(AppStore.McpDetailsPath));
            if (details is null || details.pid <= 0 || string.IsNullOrWhiteSpace(details.url)) return null;
            try { Process.GetProcessById(details.pid); } catch { return null; }
            return details;
        }
        catch { return null; }
    }

    public bool IsRunning => ReadDetails() is not null;

    public void EnsureStarted()
    {
        if (IsRunning) return;
        var script = System.IO.Path.Combine(_root, "mcp", "StatefulClanker.McpHttp.ps1");
        if (!File.Exists(script)) return;
        var log = System.IO.Path.Combine(AppStore.Root, "mcp-host.log");
        var err = System.IO.Path.Combine(AppStore.Root, "mcp-host.err.log");
        var psi = new ProcessStartInfo(RuntimeLocator.FindPowerShell())
        {
            WorkingDirectory = _root,
            UseShellExecute = false,
            CreateNoWindow = true,
            WindowStyle = ProcessWindowStyle.Hidden,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            Arguments = $"-NoProfile -NonInteractive -File {RuntimeLocator.Quote(script)} -Port {Port}"
        };
        _owned = Process.Start(psi);
        if (_owned is null) return;
        _ = Task.Run(async () =>
        {
            try
            {
                await using var stdout = new StreamWriter(log, append: true, new UTF8Encoding(false));
                await using var stderr = new StreamWriter(err, append: true, new UTF8Encoding(false));
                while (!_owned.HasExited)
                {
                    var line = await _owned.StandardOutput.ReadLineAsync();
                    if (line is null) break;
                    await stdout.WriteLineAsync(line); await stdout.FlushAsync();
                }
                var rest = await _owned.StandardError.ReadToEndAsync();
                if (!string.IsNullOrEmpty(rest)) { await stderr.WriteAsync(rest); await stderr.FlushAsync(); }
            }
            catch { }
        });
    }

    public void Dispose()
    {
        try { if (_owned is { HasExited: false }) _owned.Kill(entireProcessTree: true); } catch { }
        _owned?.Dispose();
    }
}

sealed class ProjectMetrics
{
    public int ActiveAgents { get; set; }
    public int WorkerSessions { get; set; }
    public int Commits { get; set; }
    public int CriticRuns { get; set; }
    public int CompleteTasks { get; set; }
    public int TotalTasks { get; set; }
    public string IntentRevision { get; set; } = "—";
    public string Goal { get; set; } = "";
    public string RecentActivity { get; set; } = "";
}

static class ProjectInspector
{
    static IEnumerable<string> JsonFiles(string dir) => Directory.Exists(dir) ? Directory.EnumerateFiles(dir, "*.json") : Array.Empty<string>();

    public static ProjectMetrics Inspect(string project)
    {
        var result = new ProjectMetrics();
        var stateDir = System.IO.Path.Combine(project, ".statefulclanker");
        if (!Directory.Exists(stateDir)) return result;
        result.ActiveAgents = JsonFiles(System.IO.Path.Combine(stateDir, "telemetry", "active")).Count();
        var runFiles = JsonFiles(System.IO.Path.Combine(stateDir, "telemetry", "runs")).ToArray();
        result.WorkerSessions = runFiles.Length;
        foreach (var file in runFiles)
        {
            try
            {
                using var doc = JsonDocument.Parse(File.ReadAllText(file));
                if (doc.RootElement.TryGetProperty("stage", out var stage) && stage.GetString() == "critic") result.CriticRuns++;
            }
            catch { }
        }
        foreach (var file in JsonFiles(System.IO.Path.Combine(stateDir, "tasks")))
        {
            result.TotalTasks++;
            try
            {
                using var doc = JsonDocument.Parse(File.ReadAllText(file));
                if (doc.RootElement.TryGetProperty("status", out var s) && s.GetString() == "complete") result.CompleteTasks++;
            }
            catch { }
        }
        try
        {
            var state = JsonNode.Parse(File.ReadAllText(System.IO.Path.Combine(stateDir, "state.json")))?.AsObject();
            result.Goal = state?["goal"]?.GetValue<string>() ?? "";
        }
        catch { }
        try
        {
            var intent = JsonNode.Parse(File.ReadAllText(System.IO.Path.Combine(stateDir, "intent", "contract.json")))?.AsObject();
            result.IntentRevision = intent?["revision"]?.ToString() ?? "—";
        }
        catch { }
        result.Commits = CountStatefulClankerCommits(project);
        result.RecentActivity = ReadActivity(System.IO.Path.Combine(stateDir, "events.jsonl"));
        return result;
    }

    static int CountStatefulClankerCommits(string project)
    {
        try
        {
            var psi = new ProcessStartInfo("git", "log --all --author=statefulclanker@localhost --format=%H")
            {
                WorkingDirectory = project, UseShellExecute = false, CreateNoWindow = true,
                RedirectStandardOutput = true, RedirectStandardError = true
            };
            using var p = Process.Start(psi); if (p is null) return 0;
            var text = p.StandardOutput.ReadToEnd(); p.WaitForExit(2000);
            if (p.ExitCode != 0) return 0;
            return text.Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries).Length;
        }
        catch { return 0; }
    }

    static string ReadActivity(string path)
    {
        if (!File.Exists(path)) return "No activity recorded.";
        try
        {
            var lines = File.ReadLines(path).Where(x => !string.IsNullOrWhiteSpace(x)).TakeLast(80).Reverse();
            var sb = new StringBuilder();
            foreach (var line in lines)
            {
                try
                {
                    using var doc = JsonDocument.Parse(line);
                    var r = doc.RootElement;
                    var ts = r.TryGetProperty("ts", out var t) ? t.GetString() : "";
                    var type = r.TryGetProperty("type", out var ty) ? ty.GetString() : "event";
                    var msg = r.TryGetProperty("message", out var m) ? m.GetString() : "";
                    var clock = DateTimeOffset.TryParse(ts, out var dto) ? dto.ToLocalTime().ToString("MM-dd HH:mm:ss") : ts;
                    sb.Append(clock).Append("  ").Append(type);
                    if (!string.IsNullOrWhiteSpace(msg)) sb.Append("  ").Append(msg);
                    sb.AppendLine();
                }
                catch { }
            }
            return sb.Length == 0 ? "No activity recorded." : sb.ToString();
        }
        catch { return "Unable to read activity."; }
    }
}

static class Theme
{
    public static readonly Color Back = Color.FromArgb(16, 22, 29);
    public static readonly Color Surface = Color.FromArgb(24, 33, 43);
    public static readonly Color Surface2 = Color.FromArgb(31, 42, 54);
    public static readonly Color Border = Color.FromArgb(52, 69, 86);
    public static readonly Color Text = Color.FromArgb(232, 239, 245);
    public static readonly Color Muted = Color.FromArgb(135, 153, 171);
    public static readonly Color Accent = Color.FromArgb(85, 198, 232);
    public static readonly Color Good = Color.FromArgb(73, 217, 145);
    public static readonly Color Warn = Color.FromArgb(255, 174, 74);

    public static void Apply(Control root)
    {
        root.BackColor = Back; root.ForeColor = Text;
        foreach (Control c in root.Controls)
        {
            if (c is Button b) { b.FlatStyle = FlatStyle.Flat; b.FlatAppearance.BorderColor = Border; b.BackColor = Surface2; b.ForeColor = Text; }
            else if (c is TextBox tb) { tb.BackColor = Surface; tb.ForeColor = Text; tb.BorderStyle = BorderStyle.FixedSingle; }
            else if (c is ListBox lb) { lb.BackColor = Surface; lb.ForeColor = Text; lb.BorderStyle = BorderStyle.FixedSingle; }
            else if (c is DataGridView dg) {
                dg.BackgroundColor = Surface; dg.GridColor = Border; dg.BorderStyle = BorderStyle.None;
                dg.DefaultCellStyle.BackColor = Surface; dg.DefaultCellStyle.ForeColor = Text; dg.DefaultCellStyle.SelectionBackColor = Surface2; dg.DefaultCellStyle.SelectionForeColor = Text;
                dg.ColumnHeadersDefaultCellStyle.BackColor = Surface2; dg.ColumnHeadersDefaultCellStyle.ForeColor = Text; dg.EnableHeadersVisualStyles = false;
            }
            Apply(c);
        }
    }
}

sealed class MainForm : Form
{
    readonly string _root = RuntimeLocator.FindInstallRoot();
    readonly AppSettings _settings = AppStore.Load();
    readonly McpHost _mcp;
    readonly NotifyIcon _notify;
    readonly ListBox _projects = new();
    readonly Label _projectHeader = new();
    readonly Label _mcpPill = new();
    readonly Label _metricActive = Metric("ACTIVE AGENTS");
    readonly Label _metricSessions = Metric("WORKER SESSIONS");
    readonly Label _metricCommits = Metric("COMMITS");
    readonly Label _metricCritics = Metric("CRITIC RUNS");
    readonly Label _metricTasks = Metric("TASKS COMPLETE");
    readonly Label _intent = new();
    readonly Label _goal = new();
    readonly TextBox _activity = new();
    readonly TextBox _endpoint = new();
    readonly TextBox _stdio = new();
    readonly DataGridView _providers = new();
    readonly System.Windows.Forms.Timer _timer = new() { Interval = 2500 };
    readonly TabControl _tabs = new();
    bool _reallyExit;

    public MainForm()
    {
        Text = "StatefulClanker"; Width = 1120; Height = 720; MinimumSize = new Size(900, 580); StartPosition = FormStartPosition.CenterScreen;
        try
        {
            using var stream = typeof(MainForm).Assembly.GetManifestResourceStream("StatefulClanker.ico");
            if (stream is not null) Icon = new Icon(stream);
        }
        catch { }
        _mcp = new McpHost(_root, _settings.HttpPort);
        _mcp.EnsureStarted();

        var menu = new ContextMenuStrip();
        menu.Items.Add("Open StatefulClanker", null, (_, _) => ShowFromTray());
        menu.Items.Add("Exit", null, (_, _) => { _reallyExit = true; _notify.Visible = false; Close(); });
        _notify = new NotifyIcon { Text = "StatefulClanker", Icon = Icon ?? SystemIcons.Application, Visible = true, ContextMenuStrip = menu };
        _notify.DoubleClick += (_, _) => ShowFromTray();

        BuildUi();
        RestoreProjects();
        RefreshAll();
        _timer.Tick += (_, _) => RefreshAll(); _timer.Start();
        Resize += (_, _) => { if (WindowState == FormWindowState.Minimized) Hide(); };
        FormClosing += OnClosing;
        Theme.Apply(this);
    }

    static Label Metric(string caption) => new()
    {
        AutoSize = false, Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleCenter,
        Font = new Font("Cascadia Mono", 13, FontStyle.Bold), Text = caption + "\r\n—", Margin = new Padding(5)
    };

    void BuildUi()
    {
        var split = new SplitContainer { Dock = DockStyle.Fill, FixedPanel = FixedPanel.Panel1, SplitterDistance = 245, BackColor = Theme.Border };
        Controls.Add(split);

        var left = new TableLayoutPanel { Dock = DockStyle.Fill, RowCount = 5, ColumnCount = 1, Padding = new Padding(12) };
        left.RowStyles.Add(new RowStyle(SizeType.Absolute, 38)); left.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        left.RowStyles.Add(new RowStyle(SizeType.Absolute, 42)); left.RowStyles.Add(new RowStyle(SizeType.Absolute, 42)); left.RowStyles.Add(new RowStyle(SizeType.Absolute, 42));
        var brand = new Label { Text = "STATEFULCLANKER", Dock = DockStyle.Fill, Font = new Font("Segoe UI Semibold", 12, FontStyle.Bold), ForeColor = Theme.Accent, TextAlign = ContentAlignment.MiddleLeft };
        _projects.Dock = DockStyle.Fill; _projects.Font = new Font("Segoe UI", 10); _projects.SelectedIndexChanged += (_, _) => SelectProjectFromList();
        var add = Button("+ Add / open project"); add.Click += (_, _) => AddProject();
        var remove = Button("Remove from list"); remove.Click += (_, _) => RemoveProject();
        var explorer = Button("Open in Explorer"); explorer.Click += (_, _) => OpenActiveInExplorer();
        left.Controls.Add(brand, 0, 0); left.Controls.Add(_projects, 0, 1); left.Controls.Add(add, 0, 2); left.Controls.Add(remove, 0, 3); left.Controls.Add(explorer, 0, 4);
        split.Panel1.Controls.Add(left);

        var right = new TableLayoutPanel { Dock = DockStyle.Fill, RowCount = 2, ColumnCount = 1, Padding = new Padding(14) };
        right.RowStyles.Add(new RowStyle(SizeType.Absolute, 52)); right.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        var header = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, RowCount = 1 };
        header.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); header.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 215));
        _projectHeader.Dock = DockStyle.Fill; _projectHeader.Font = new Font("Segoe UI Semibold", 15, FontStyle.Bold); _projectHeader.TextAlign = ContentAlignment.MiddleLeft;
        _mcpPill.Dock = DockStyle.Fill; _mcpPill.TextAlign = ContentAlignment.MiddleCenter; _mcpPill.Font = new Font("Segoe UI Semibold", 9, FontStyle.Bold);
        header.Controls.Add(_projectHeader, 0, 0); header.Controls.Add(_mcpPill, 1, 0);
        right.Controls.Add(header, 0, 0);
        _tabs.Dock = DockStyle.Fill; _tabs.TabPages.Add(BuildOverview()); _tabs.TabPages.Add(BuildActivity()); _tabs.TabPages.Add(BuildIntegrations()); _tabs.TabPages.Add(BuildProviders());
        right.Controls.Add(_tabs, 0, 1); split.Panel2.Controls.Add(right);
    }

    static Button Button(string text) => new() { Text = text, Dock = DockStyle.Fill, Margin = new Padding(3) };

    TabPage Page(string name)
    {
        var p = new TabPage(name) { Padding = new Padding(12), BackColor = Theme.Back, ForeColor = Theme.Text };
        return p;
    }

    TabPage BuildOverview()
    {
        var page = Page("Overview");
        var rows = new TableLayoutPanel { Dock = DockStyle.Fill, RowCount = 5, ColumnCount = 1 };
        rows.RowStyles.Add(new RowStyle(SizeType.Absolute, 108)); rows.RowStyles.Add(new RowStyle(SizeType.Absolute, 38)); rows.RowStyles.Add(new RowStyle(SizeType.Absolute, 92)); rows.RowStyles.Add(new RowStyle(SizeType.Absolute, 38)); rows.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        var metrics = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 5, RowCount = 1 };
        for (var i = 0; i < 5; i++) metrics.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 20));
        foreach (var (control, index) in new[] { (_metricActive,0),(_metricSessions,1),(_metricCommits,2),(_metricCritics,3),(_metricTasks,4) }) metrics.Controls.Add(control,index,0);
        var intentTitle = Section("PROJECT AUTHORITY");
        var authority = new Panel { Dock = DockStyle.Fill, Padding = new Padding(12), BackColor = Theme.Surface };
        _intent.Dock = DockStyle.Top; _intent.Height = 28; _intent.ForeColor = Theme.Accent; _intent.Font = new Font("Cascadia Mono", 9, FontStyle.Bold);
        _goal.Dock = DockStyle.Fill; _goal.ForeColor = Theme.Text; _goal.Font = new Font("Segoe UI", 10); _goal.AutoEllipsis = true;
        authority.Controls.Add(_goal); authority.Controls.Add(_intent);
        rows.Controls.Add(metrics,0,0); rows.Controls.Add(intentTitle,0,1); rows.Controls.Add(authority,0,2); rows.Controls.Add(Section("RECENT ACTIVITY"),0,3);
        _activity.Multiline = true; _activity.ReadOnly = true; _activity.ScrollBars = ScrollBars.Vertical; _activity.Dock = DockStyle.Fill; _activity.Font = new Font("Cascadia Mono", 8.5f);
        rows.Controls.Add(_activity,0,4); page.Controls.Add(rows); return page;
    }

    TabPage BuildActivity()
    {
        var page = Page("Activity");
        var box = new TextBox { Dock = DockStyle.Fill, Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Both, WordWrap = false, Font = new Font("Cascadia Mono", 9) };
        page.Tag = box; page.Controls.Add(box); return page;
    }

    TabPage BuildIntegrations()
    {
        var page = Page("Integrations");
        var rows = new TableLayoutPanel { Dock = DockStyle.Fill, RowCount = 8, ColumnCount = 1 };
        rows.RowStyles.Add(new RowStyle(SizeType.Absolute, 32)); rows.RowStyles.Add(new RowStyle(SizeType.Absolute, 58)); rows.RowStyles.Add(new RowStyle(SizeType.Absolute, 42)); rows.RowStyles.Add(new RowStyle(SizeType.Absolute, 32)); rows.RowStyles.Add(new RowStyle(SizeType.Absolute, 58)); rows.RowStyles.Add(new RowStyle(SizeType.Absolute, 42)); rows.RowStyles.Add(new RowStyle(SizeType.Absolute, 32)); rows.RowStyles.Add(new RowStyle(SizeType.Percent,100));
        rows.Controls.Add(Section("STREAMABLE MCP"),0,0); _endpoint.Dock = DockStyle.Fill; _endpoint.ReadOnly = true; _endpoint.Font = new Font("Cascadia Mono", 9.5f); rows.Controls.Add(_endpoint,0,1);
        var httpButtons = new FlowLayoutPanel { Dock = DockStyle.Fill }; var copyEndpoint = ButtonFixed("Copy endpoint"); copyEndpoint.Click += (_,_) => Copy(_endpoint.Text); var copyToken = ButtonFixed("Copy token"); copyToken.Click += (_,_) => Copy(_mcp.ReadDetails()?.token ?? ""); httpButtons.Controls.Add(copyEndpoint); httpButtons.Controls.Add(copyToken); rows.Controls.Add(httpButtons,0,2);
        rows.Controls.Add(Section("STDIO BRIDGE"),0,3); _stdio.Dock = DockStyle.Fill; _stdio.ReadOnly = true; _stdio.Font = new Font("Cascadia Mono", 9.5f); rows.Controls.Add(_stdio,0,4);
        var stdButtons = new FlowLayoutPanel { Dock = DockStyle.Fill }; var copyStdio = ButtonFixed("Copy command"); copyStdio.Click += (_,_) => Copy(_stdio.Text); var register = ButtonFixed("Register client..."); register.Click += (_,_) => RegisterClient(); stdButtons.Controls.Add(copyStdio); stdButtons.Controls.Add(register); rows.Controls.Add(stdButtons,0,5);
        rows.Controls.Add(Section("CONTROL-PLANE INSTRUCTIONS"),0,6);
        var note = new TextBox { Dock = DockStyle.Fill, Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical, Font = new Font("Segoe UI", 9), Text = "The resident MCP follows the project selected at left. Connected conversational agents are instructed to use structured questionnaires aggressively for material ambiguity, capture human direction durably, build SCPLAN task graphs semantically, and dispatch implementation through configured provider CLIs. stdio clients bridge into the same resident HTTP authority while the app is running." };
        rows.Controls.Add(note,0,7); page.Controls.Add(rows); return page;
    }

    static Button ButtonFixed(string text) => new() { Text = text, Width = 150, Height = 32, Margin = new Padding(0,4,8,0) };
    static Label Section(string text) => new() { Text = text, Dock = DockStyle.Fill, TextAlign = ContentAlignment.BottomLeft, Font = new Font("Segoe UI Semibold", 8, FontStyle.Bold), ForeColor = Theme.Muted };

    TabPage BuildProviders()
    {
        var page = Page("Providers");
        var rows = new TableLayoutPanel { Dock = DockStyle.Fill, RowCount = 2, ColumnCount = 1 };
        rows.RowStyles.Add(new RowStyle(SizeType.Absolute, 42)); rows.RowStyles.Add(new RowStyle(SizeType.Percent,100));
        var bar = new FlowLayoutPanel { Dock = DockStyle.Fill }; var refresh = ButtonFixed("Refresh"); refresh.Click += (_,_) => RefreshProviders(); var open = ButtonFixed("Open config"); open.Click += (_,_) => OpenProviderConfig(); bar.Controls.Add(refresh); bar.Controls.Add(open);
        _providers.Dock = DockStyle.Fill; _providers.ReadOnly = true; _providers.AllowUserToAddRows = false; _providers.RowHeadersVisible = false; _providers.AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.Fill; _providers.SelectionMode = DataGridViewSelectionMode.FullRowSelect;
        _providers.Columns.Add("name","Provider"); _providers.Columns.Add("installed","CLI"); _providers.Columns.Add("command","Command"); _providers.Columns.Add("roles","Routing / roles");
        rows.Controls.Add(bar,0,0); rows.Controls.Add(_providers,0,1); page.Controls.Add(rows); return page;
    }

    void RestoreProjects()
    {
        _projects.Items.Clear();
        foreach (var p in _settings.Projects.OrderBy(p => p.Name, StringComparer.OrdinalIgnoreCase)) _projects.Items.Add(p);
        _projects.DisplayMember = nameof(ProjectEntry.Display);
        if (!string.IsNullOrWhiteSpace(_settings.ActiveProjectPath) && Directory.Exists(_settings.ActiveProjectPath))
        {
            for (var i=0;i<_projects.Items.Count;i++) if (_projects.Items[i] is ProjectEntry p && SamePath(p.Path,_settings.ActiveProjectPath)) { _projects.SelectedIndex=i; return; }
        }
        // Missing last-active project is intentionally not replaced by the first item.
        SetActiveProject(null);
    }

    static bool SamePath(string a, string? b)
    {
        if (b is null) return false;
        try { return string.Equals(System.IO.Path.GetFullPath(a).TrimEnd('\\'), System.IO.Path.GetFullPath(b).TrimEnd('\\'), StringComparison.OrdinalIgnoreCase); }
        catch { return false; }
    }

    ProjectEntry? ActiveEntry => _projects.SelectedItem as ProjectEntry;

    void SelectProjectFromList()
    {
        var entry=ActiveEntry;
        if (entry is null || !Directory.Exists(entry.Path)) { SetActiveProject(null); return; }
        SetActiveProject(entry.Path);
    }

    void SetActiveProject(string? path)
    {
        _settings.ActiveProjectPath = path; AppStore.Save(_settings); AppStore.WriteActiveProject(path);
        _projectHeader.Text = path is null ? "No active project" : (ActiveEntry?.Name ?? System.IO.Path.GetFileName(path));
        Text = path is null ? "StatefulClanker" : $"StatefulClanker — {_projectHeader.Text}";
        RefreshAll();
    }

    void AddProject()
    {
        using var picker = new FolderBrowserDialog { Description = "Select the project directory StatefulClanker should manage", UseDescriptionForTitle = true };
        if (picker.ShowDialog(this) != DialogResult.OK) return;
        var path = System.IO.Path.GetFullPath(picker.SelectedPath);
        var state = System.IO.Path.Combine(path, ".statefulclanker", "state.json");
        if (!File.Exists(state))
        {
            if (MessageBox.Show(this, "This folder is not initialized for StatefulClanker. Initialize it now?", "Initialize project", MessageBoxButtons.YesNo, MessageBoxIcon.Question) != DialogResult.Yes) return;
            var run = RunHarness(path, "init");
            if (run.exitCode != 0) { MessageBox.Show(this, run.output, "Initialization failed", MessageBoxButtons.OK, MessageBoxIcon.Error); return; }
        }
        var existing = _settings.Projects.FirstOrDefault(p => SamePath(p.Path,path));
        if (existing is null)
        {
            existing = new ProjectEntry { Name = new DirectoryInfo(path).Name, Path = path }; _settings.Projects.Add(existing); AppStore.Save(_settings);
            RestoreProjects();
        }
        for (var i=0;i<_projects.Items.Count;i++) if (_projects.Items[i] is ProjectEntry p && SamePath(p.Path,path)) { _projects.SelectedIndex=i; break; }
    }

    void RemoveProject()
    {
        var entry=ActiveEntry; if(entry is null) return;
        if(MessageBox.Show(this,$"Remove '{entry.Name}' from the local project list? Project files are not deleted.","Remove project",MessageBoxButtons.YesNo,MessageBoxIcon.Question)!=DialogResult.Yes) return;
        var wasActive=SamePath(entry.Path,_settings.ActiveProjectPath); _settings.Projects.RemoveAll(p=>SamePath(p.Path,entry.Path)); if(wasActive)_settings.ActiveProjectPath=null; AppStore.Save(_settings); RestoreProjects();
    }

    void OpenActiveInExplorer()
    {
        var path=_settings.ActiveProjectPath; if(string.IsNullOrWhiteSpace(path)||!Directory.Exists(path))return;
        try{Process.Start(new ProcessStartInfo("explorer.exe",RuntimeLocator.Quote(path)){UseShellExecute=true});}catch{}
    }

    (int exitCode,string output) RunHarness(string project,string args)
    {
        var script=System.IO.Path.Combine(_root,"StatefulClanker.ps1");
        try
        {
            var psi=new ProcessStartInfo(RuntimeLocator.FindPowerShell(), $"-NoProfile -NonInteractive -File {RuntimeLocator.Quote(script)} {args}") { WorkingDirectory=project,UseShellExecute=false,CreateNoWindow=true,RedirectStandardOutput=true,RedirectStandardError=true };
            using var p=Process.Start(psi); if(p is null)return(-1,"Could not start PowerShell."); var o=p.StandardOutput.ReadToEnd(); var e=p.StandardError.ReadToEnd(); p.WaitForExit(); return(p.ExitCode,(o+Environment.NewLine+e).Trim());
        }catch(Exception ex){return(-1,ex.Message);}
    }

    void RefreshAll()
    {
        _mcp.EnsureStarted(); var details=_mcp.ReadDetails();
        _mcpPill.Text=details is null?"MCP  STOPPED":"MCP  RUNNING"; _mcpPill.ForeColor=details is null?Theme.Warn:Theme.Good; _mcpPill.BackColor=Theme.Surface;
        _endpoint.Text=details?.url ?? $"http://127.0.0.1:{_settings.HttpPort}/mcp (starting...)";
        var stdioScript=System.IO.Path.Combine(_root,"mcp","StatefulClanker.Mcp.ps1"); _stdio.Text=$"{RuntimeLocator.FindPowerShell()} -NoProfile -File {RuntimeLocator.Quote(stdioScript)}";

        var path=_settings.ActiveProjectPath;
        if(string.IsNullOrWhiteSpace(path)||!Directory.Exists(path))
        {
            SetMetrics(new ProjectMetrics()); _activity.Text="Select a project at left. StatefulClanker does not silently substitute a default project.";
            var actPage=_tabs.TabPages.Cast<TabPage>().FirstOrDefault(p=>p.Text=="Activity"); if(actPage?.Tag is TextBox box)box.Text=_activity.Text;
            RefreshProviders(); return;
        }
        var m=ProjectInspector.Inspect(path); SetMetrics(m); _activity.Text=m.RecentActivity;
        var activityPage=_tabs.TabPages.Cast<TabPage>().FirstOrDefault(p=>p.Text=="Activity"); if(activityPage?.Tag is TextBox activityBox) activityBox.Text=m.RecentActivity;
        RefreshProviders();
    }

    void SetMetrics(ProjectMetrics m)
    {
        _metricActive.Text=$"ACTIVE AGENTS\r\n{m.ActiveAgents}"; _metricSessions.Text=$"WORKER SESSIONS\r\n{m.WorkerSessions}"; _metricCommits.Text=$"COMMITS\r\n{m.Commits}"; _metricCritics.Text=$"CRITIC RUNS\r\n{m.CriticRuns}"; _metricTasks.Text=$"TASKS COMPLETE\r\n{m.CompleteTasks}/{m.TotalTasks}";
        _intent.Text=$"INTENT REVISION  {m.IntentRevision}"; _goal.Text=string.IsNullOrWhiteSpace(m.Goal)?"No project goal recorded.":m.Goal;
    }

    void RefreshProviders()
    {
        _providers.Rows.Clear(); var path=_settings.ActiveProjectPath; if(string.IsNullOrWhiteSpace(path))return;
        var cfg=System.IO.Path.Combine(path,".statefulclanker","config.json"); if(!File.Exists(cfg))return;
        try
        {
            using var doc=JsonDocument.Parse(File.ReadAllText(cfg)); var root=doc.RootElement;
            var def=root.TryGetProperty("defaultProvider",out var d)?d.GetString():null; var critic=root.TryGetProperty("criticProvider",out var c)?c.GetString():null; var validator=root.TryGetProperty("validatorProvider",out var v)?v.GetString():null;
            var routes=new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase); if(root.TryGetProperty("providerBySize",out var map)&&map.ValueKind==JsonValueKind.Object)foreach(var p in map.EnumerateObject())if(p.Value.ValueKind==JsonValueKind.String)routes[p.Name]=p.Value.GetString()??"";
            if(!root.TryGetProperty("providers",out var providers)||providers.ValueKind!=JsonValueKind.Object)return;
            foreach(var p in providers.EnumerateObject())
            {
                var cmd=p.Value.TryGetProperty("command",out var ce)?ce.GetString()??"":""; var roles=new List<string>(); if(p.Name==def)roles.Add("default"); if(p.Name==critic)roles.Add("critic"); if(p.Name==validator)roles.Add("validator"); foreach(var route in routes.Where(x=>x.Value==p.Name))roles.Add(route.Key);
                _providers.Rows.Add(p.Name,RuntimeLocator.CommandExists(cmd)?"found":"missing",cmd,string.Join(", ",roles));
            }
        }catch{}
    }

    void OpenProviderConfig()
    {
        var path=_settings.ActiveProjectPath; if(string.IsNullOrWhiteSpace(path))return; var cfg=System.IO.Path.Combine(path,".statefulclanker","config.json"); if(!File.Exists(cfg))return; try{Process.Start(new ProcessStartInfo("notepad.exe",RuntimeLocator.Quote(cfg)){UseShellExecute=true});}catch{}
    }

    void RegisterClient()
    {
        using var dialog=new Form{Text="Register MCP client",Width=430,Height=210,StartPosition=FormStartPosition.CenterParent,BackColor=Theme.Back,ForeColor=Theme.Text};
        var combo=new ComboBox{DropDownStyle=ComboBoxStyle.DropDownList,Left=20,Top=25,Width=370}; combo.Items.AddRange(new object[]{"claude-desktop","claude-code","opencode","vscode","antigravity","cursor"}); combo.SelectedIndex=0;
        var note=new Label{Left=20,Top=65,Width=370,Height=45,Text="Registration uses the stdio bridge and follows the project selected in StatefulClanker. It does not pin a default project into the client config."};
        var ok=new Button{Text="Register",Left=210,Top=120,Width=85,DialogResult=DialogResult.OK}; var cancel=new Button{Text="Cancel",Left=305,Top=120,Width=85,DialogResult=DialogResult.Cancel}; dialog.Controls.AddRange(new Control[]{combo,note,ok,cancel}); dialog.AcceptButton=ok; dialog.CancelButton=cancel; Theme.Apply(dialog);
        if(dialog.ShowDialog(this)!=DialogResult.OK)return;
        var script=System.IO.Path.Combine(_root,"Install-McpServer.ps1"); try
        {
            var psi=new ProcessStartInfo(RuntimeLocator.FindPowerShell(),$"-NoProfile -ExecutionPolicy Bypass -File {RuntimeLocator.Quote(script)} -Client {combo.SelectedItem} -Write"){WorkingDirectory=_root,UseShellExecute=false,CreateNoWindow=true,RedirectStandardOutput=true,RedirectStandardError=true}; using var p=Process.Start(psi); if(p is null)return; var o=p.StandardOutput.ReadToEnd(); var e=p.StandardError.ReadToEnd(); p.WaitForExit(); MessageBox.Show(this,(o+Environment.NewLine+e).Trim(),p.ExitCode==0?"Registered":"Registration failed",MessageBoxButtons.OK,p.ExitCode==0?MessageBoxIcon.Information:MessageBoxIcon.Error);
        }catch(Exception ex){MessageBox.Show(this,ex.Message,"Registration failed",MessageBoxButtons.OK,MessageBoxIcon.Error);}
    }

    static void Copy(string text){if(!string.IsNullOrWhiteSpace(text))Clipboard.SetText(text);}
    void ShowFromTray(){Show();WindowState=FormWindowState.Normal;Activate();}

    void OnClosing(object? sender, FormClosingEventArgs e)
    {
        if(!_reallyExit){e.Cancel=true;Hide();return;}
        _timer.Stop(); _mcp.Dispose(); _notify.Visible=false; _notify.Dispose();
    }
}

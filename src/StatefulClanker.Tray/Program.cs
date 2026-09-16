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
        try { if (File.Exists(SettingsPath)) return JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(SettingsPath), JsonOptions) ?? new(); }
        catch { }
        return new();
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
    public McpHost(string root, int port) { _root = root; Port = port; }

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
        foreach (var arg in new[] { "-NoProfile", "-NonInteractive", "-File", script, "-Port", Port.ToString() }) psi.ArgumentList.Add(arg);
        try { _owned = Process.Start(psi); } catch { _owned = null; }
    }

    public void Dispose()
    {
        try { if (_owned is { HasExited: false }) _owned.Kill(entireProcessTree: true); } catch { }
        _owned?.Dispose();
    }
}

sealed class ProjectMetrics
{
    public int ActiveAgents, Sessions, Commits, Critics, CompleteTasks, TotalTasks;
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

static class Inspector
{
    static IEnumerable<string> JsonFiles(string dir) => Directory.Exists(dir) ? Directory.EnumerateFiles(dir, "*.json") : Array.Empty<string>();

    public static ProjectMetrics Project(string project)
    {
        var m = new ProjectMetrics(); var state = System.IO.Path.Combine(project, ".statefulclanker"); if (!Directory.Exists(state)) return m;
        m.ActiveAgents = JsonFiles(System.IO.Path.Combine(state, "telemetry", "active")).Count();
        var runs = JsonFiles(System.IO.Path.Combine(state, "telemetry", "runs")).ToArray(); m.Sessions = runs.Length;
        foreach (var file in runs)
        {
            try { using var d = JsonDocument.Parse(File.ReadAllText(file)); if (d.RootElement.TryGetProperty("stage", out var s) && s.GetString() == "critic") m.Critics++; } catch { }
        }
        foreach (var file in JsonFiles(System.IO.Path.Combine(state, "tasks")))
        {
            m.TotalTasks++; try { using var d = JsonDocument.Parse(File.ReadAllText(file)); if (d.RootElement.TryGetProperty("status", out var s) && s.GetString() == "complete") m.CompleteTasks++; } catch { }
        }
        try { m.Goal = JsonNode.Parse(File.ReadAllText(System.IO.Path.Combine(state, "state.json")))?["goal"]?.GetValue<string>() ?? ""; } catch { }
        try { m.IntentRevision = JsonNode.Parse(File.ReadAllText(System.IO.Path.Combine(state, "intent", "contract.json")))?["revision"]?.ToString() ?? "—"; } catch { }
        m.Commits = CommitCount(project); m.Activity = Activity(System.IO.Path.Combine(state, "events.jsonl")); return m;
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

sealed class MainForm : Form
{
    readonly string _root = Runtime.FindRoot();
    readonly AppSettings _settings = AppStore.Load();
    readonly TreeView _projects = new();
    readonly TabControl _tabs = new();
    readonly Label _header = new(), _mcpState = new(), _intent = new(), _goal = new();
    readonly Label[] _metrics = Enumerable.Range(0, 5).Select(_ => new Label()).ToArray();
    readonly TextBox _overviewActivity = new(), _allActivity = new(), _endpoint = new(), _stdio = new(), _integrationNote = new();
    readonly DataGridView _integrations = new(), _providers = new();
    readonly System.Windows.Forms.Timer _timer = new() { Interval = 3000 };
    readonly McpHost _mcp;
    readonly NotifyIcon _notify;
    bool _reallyExit;

    public MainForm()
    {
        Text = "StatefulClanker"; Width = 1160; Height = 740; MinimumSize = new Size(920, 590); StartPosition = FormStartPosition.CenterScreen;
        try { using var s = typeof(MainForm).Assembly.GetManifestResourceStream("StatefulClanker.ico"); if (s is not null) Icon = new Icon(s); } catch { }
        _mcp = new McpHost(_root, _settings.HttpPort); _mcp.EnsureStarted();
        var menu = new ContextMenuStrip(); menu.Items.Add("Open StatefulClanker", null, (_, _) => ShowFromTray()); menu.Items.Add("Exit", null, (_, _) => { _reallyExit = true; Close(); });
        _notify = new NotifyIcon { Text = "StatefulClanker", Icon = Icon ?? SystemIcons.Application, Visible = true, ContextMenuStrip = menu }; _notify.DoubleClick += (_, _) => ShowFromTray();
        BuildUi(); RestoreProjects(); RefreshAll(); Theme.Apply(this);
        _timer.Tick += (_, _) => RefreshAll(); _timer.Start(); Resize += (_, _) => { if (WindowState == FormWindowState.Minimized) Hide(); }; FormClosing += HandleFormClosing;
    }

    static Button Btn(string text, int width = 145) => new() { Text = text, Width = width, Height = 32, Margin = new Padding(0, 4, 8, 0) };
    static Label Section(string text) => new() { Text = text, Dock = DockStyle.Fill, TextAlign = ContentAlignment.BottomLeft, Font = new Font("Segoe UI Semibold", 8, FontStyle.Bold), ForeColor = Theme.Muted };
    TabPage Page(string name) => new(name) { Padding = new Padding(12), BackColor = Theme.Back, ForeColor = Theme.Text };

    void BuildUi()
    {
        var split = new SplitContainer { Dock = DockStyle.Fill, FixedPanel = FixedPanel.Panel1, SplitterDistance = 250, BackColor = Theme.Border }; Controls.Add(split);
        var left = new TableLayoutPanel { Dock = DockStyle.Fill, RowCount = 5, ColumnCount = 1, Padding = new Padding(12) };
        left.RowStyles.Add(new RowStyle(SizeType.Absolute, 38)); left.RowStyles.Add(new RowStyle(SizeType.Percent, 100)); for (var i = 0; i < 3; i++) left.RowStyles.Add(new RowStyle(SizeType.Absolute, 42));
        left.Controls.Add(new Label { Text = "STATEFULCLANKER", Dock = DockStyle.Fill, Font = new Font("Segoe UI Semibold", 12, FontStyle.Bold), ForeColor = Theme.Accent, TextAlign = ContentAlignment.MiddleLeft }, 0, 0);
        _projects.Dock = DockStyle.Fill; _projects.HideSelection = false; _projects.AfterSelect += (_, _) => SelectProject(); left.Controls.Add(_projects, 0, 1);
        var add = Btn("+ Add / open project", 210); add.Dock = DockStyle.Fill; add.Click += (_, _) => AddProject(); left.Controls.Add(add, 0, 2);
        var remove = Btn("Remove from list", 210); remove.Dock = DockStyle.Fill; remove.Click += (_, _) => RemoveProject(); left.Controls.Add(remove, 0, 3);
        var explorer = Btn("Open in Explorer", 210); explorer.Dock = DockStyle.Fill; explorer.Click += (_, _) => OpenExplorer(); left.Controls.Add(explorer, 0, 4); split.Panel1.Controls.Add(left);

        var right = new TableLayoutPanel { Dock = DockStyle.Fill, RowCount = 2, ColumnCount = 1, Padding = new Padding(14) }; right.RowStyles.Add(new RowStyle(SizeType.Absolute, 52)); right.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        var top = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, RowCount = 1 }; top.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); top.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 210));
        _header.Dock = DockStyle.Fill; _header.Font = new Font("Segoe UI Semibold", 15, FontStyle.Bold); _header.TextAlign = ContentAlignment.MiddleLeft; _mcpState.Dock = DockStyle.Fill; _mcpState.TextAlign = ContentAlignment.MiddleCenter; _mcpState.Font = new Font("Segoe UI Semibold", 9, FontStyle.Bold); top.Controls.Add(_header, 0, 0); top.Controls.Add(_mcpState, 1, 0); right.Controls.Add(top, 0, 0);
        _tabs.Dock = DockStyle.Fill; _tabs.TabPages.Add(BuildOverview()); _tabs.TabPages.Add(BuildActivity()); _tabs.TabPages.Add(BuildIntegrations()); _tabs.TabPages.Add(BuildProviders()); right.Controls.Add(_tabs, 0, 1); split.Panel2.Controls.Add(right);
    }

    TabPage BuildOverview()
    {
        var p = Page("Overview"); var rows = new TableLayoutPanel { Dock = DockStyle.Fill, RowCount = 5, ColumnCount = 1 }; rows.RowStyles.Add(new RowStyle(SizeType.Absolute, 108)); rows.RowStyles.Add(new RowStyle(SizeType.Absolute, 32)); rows.RowStyles.Add(new RowStyle(SizeType.Absolute, 90)); rows.RowStyles.Add(new RowStyle(SizeType.Absolute, 32)); rows.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        var metricNames = new[] { "ACTIVE AGENTS", "WORKER SESSIONS", "COMMITS", "CRITIC RUNS", "TASKS COMPLETE" }; var metrics = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 5, RowCount = 1 };
        for (var i = 0; i < 5; i++) { metrics.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 20)); _metrics[i].Dock = DockStyle.Fill; _metrics[i].Margin = new Padding(5); _metrics[i].TextAlign = ContentAlignment.MiddleCenter; _metrics[i].Font = new Font("Cascadia Mono", 12, FontStyle.Bold); _metrics[i].Text = metricNames[i] + "\r\n—"; metrics.Controls.Add(_metrics[i], i, 0); }
        var authority = new Panel { Dock = DockStyle.Fill, Padding = new Padding(12), BackColor = Theme.Surface }; _intent.Dock = DockStyle.Top; _intent.Height = 26; _intent.ForeColor = Theme.Accent; _intent.Font = new Font("Cascadia Mono", 9, FontStyle.Bold); _goal.Dock = DockStyle.Fill; authority.Controls.Add(_goal); authority.Controls.Add(_intent);
        _overviewActivity.Dock = DockStyle.Fill; _overviewActivity.Multiline = true; _overviewActivity.ReadOnly = true; _overviewActivity.ScrollBars = ScrollBars.Vertical; _overviewActivity.Font = new Font("Cascadia Mono", 8.5f);
        rows.Controls.Add(metrics, 0, 0); rows.Controls.Add(Section("PROJECT AUTHORITY"), 0, 1); rows.Controls.Add(authority, 0, 2); rows.Controls.Add(Section("RECENT ACTIVITY"), 0, 3); rows.Controls.Add(_overviewActivity, 0, 4); p.Controls.Add(rows); return p;
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
        var p = Page("Providers"); var rows = new TableLayoutPanel { Dock = DockStyle.Fill, RowCount = 3, ColumnCount = 1 }; rows.RowStyles.Add(new RowStyle(SizeType.Absolute, 44)); rows.RowStyles.Add(new RowStyle(SizeType.Absolute, 34)); rows.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        var bar = new FlowLayoutPanel { Dock = DockStyle.Fill }; var open = Btn("Open config"); open.Click += (_, _) => OpenConfig(); var refresh = Btn("Refresh"); refresh.Click += (_, _) => RefreshProviders(); bar.Controls.Add(open); bar.Controls.Add(refresh); rows.Controls.Add(bar, 0, 0); rows.Controls.Add(Section("WORKER BACKEND STATUS AND SEMANTIC SIZE ROUTING"), 0, 1);
        _providers.Dock = DockStyle.Fill; _providers.ReadOnly = true; _providers.AllowUserToAddRows = false; _providers.RowHeadersVisible = false; _providers.SelectionMode = DataGridViewSelectionMode.FullRowSelect; _providers.AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.Fill; _providers.Columns.Add("name", "Provider"); _providers.Columns.Add("backend", "Backend"); _providers.Columns.Add("target", "Target"); _providers.Columns.Add("roles", "Routing / roles"); rows.Controls.Add(_providers, 0, 2); p.Controls.Add(rows); return p;
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
        _settings.ActiveProjectPath = path; AppStore.Save(_settings); AppStore.SetActiveProject(path); _header.Text = path is null ? "No active project" : (SelectedProject?.Name ?? new DirectoryInfo(path).Name); Text = path is null ? "StatefulClanker" : $"StatefulClanker — {_header.Text}"; RefreshProject();
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

    void RefreshAll()
    {
        _mcp.EnsureStarted(); var d = _mcp.Details(); _mcpState.Text = d is null ? "MCP  STOPPED" : "MCP  RUNNING"; _mcpState.ForeColor = d is null ? Theme.Warn : Theme.Good; _mcpState.BackColor = Theme.Surface; _endpoint.Text = d?.url ?? $"http://127.0.0.1:{_settings.HttpPort}/mcp (starting...)";
        var stdioScript = System.IO.Path.Combine(_root, "mcp", "StatefulClanker.Mcp.ps1"); _stdio.Text = $"{Runtime.FindPowerShell()} -NoProfile -File \"{stdioScript}\""; RefreshProject(); RefreshIntegrations(); RefreshProviders();
    }

    void RefreshProject()
    {
        var path = _settings.ActiveProjectPath; if (string.IsNullOrWhiteSpace(path) || !Directory.Exists(path)) { SetMetrics(new()); _overviewActivity.Text = _allActivity.Text = "Select a project at left. StatefulClanker does not silently substitute a default project."; return; }
        var m = Inspector.Project(path); SetMetrics(m); _overviewActivity.Text = _allActivity.Text = m.Activity;
    }

    void SetMetrics(ProjectMetrics m)
    {
        _metrics[0].Text = $"ACTIVE AGENTS\r\n{m.ActiveAgents}"; _metrics[1].Text = $"WORKER SESSIONS\r\n{m.Sessions}"; _metrics[2].Text = $"COMMITS\r\n{m.Commits}"; _metrics[3].Text = $"CRITIC RUNS\r\n{m.Critics}"; _metrics[4].Text = $"TASKS COMPLETE\r\n{m.CompleteTasks}/{m.TotalTasks}"; _intent.Text = $"INTENT REVISION  {m.IntentRevision}"; _goal.Text = string.IsNullOrWhiteSpace(m.Goal) ? "No project goal recorded." : m.Goal;
    }

    List<IntegrationStatus> ReadIntegrationStatus()
    {
        var module = System.IO.Path.Combine(_root, "lib", "StatefulClanker.Integrations.ps1"); var escaped = module.Replace("'", "''");
        var command = $". '{escaped}'; @(Get-SCIntegrationTargets | ForEach-Object {{ [pscustomobject]@{{ id=$_.id; name=$_.name; installed=[bool](Test-SCIntegrationInstalled $_); registered=[bool](Test-SCIntegrationRegistered $_); verified=[bool]$_.verified; note=$_.note }} }}) | ConvertTo-Json -Depth 6 -Compress";
        var r = Runtime.RunPowerShell(_root, "-Command", command); if (r.code != 0 || string.IsNullOrWhiteSpace(r.stdout)) return new();
        try { return JsonSerializer.Deserialize<List<IntegrationStatus>>(r.stdout, new JsonSerializerOptions { PropertyNameCaseInsensitive = true }) ?? new(); } catch { return new(); }
    }

    void RefreshIntegrations()
    {
        _integrations.Rows.Clear(); foreach (var s in ReadIntegrationStatus()) { var i = _integrations.Rows.Add(s.name, s.installed ? "yes" : "no", s.registered ? "yes" : "no", s.verified ? "yes" : "no", s.note); _integrations.Rows[i].Tag = s; }
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
        var r = Runtime.RunPowerShell(_root, "-Command", cmd); if (r.code != 0) MessageBox.Show(this, (r.stdout + Environment.NewLine + r.stderr).Trim(), "Integration update failed", MessageBoxButtons.OK, MessageBoxIcon.Error); RefreshIntegrations();
    }

    void RefreshProviders()
    {
        _providers.Rows.Clear(); var path = _settings.ActiveProjectPath; if (string.IsNullOrWhiteSpace(path)) return; var cfg = System.IO.Path.Combine(path, ".statefulclanker", "config.json"); if (!File.Exists(cfg)) return;
        try
        {
            using var d = JsonDocument.Parse(File.ReadAllText(cfg)); var root = d.RootElement; var def = root.TryGetProperty("defaultProvider", out var dv) ? dv.GetString() : null; var critic = root.TryGetProperty("criticProvider", out var cv) ? cv.GetString() : null; var validator = root.TryGetProperty("validatorProvider", out var vv) ? vv.GetString() : null; var routes = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            if (root.TryGetProperty("providerBySize", out var map) && map.ValueKind == JsonValueKind.Object) foreach (var x in map.EnumerateObject()) if (x.Value.ValueKind == JsonValueKind.String) routes[x.Name] = x.Value.GetString() ?? "";
            if (!root.TryGetProperty("providers", out var providers) || providers.ValueKind != JsonValueKind.Object) return;
            foreach (var p in providers.EnumerateObject())
            {
                var type = p.Value.TryGetProperty("type", out var tv) && tv.ValueKind == JsonValueKind.String ? tv.GetString() ?? "cli" : "cli"; var cmd = p.Value.TryGetProperty("command", out var c) ? c.GetString() ?? "" : ""; var connection = p.Value.TryGetProperty("connection", out var cn) ? cn.GetString() ?? "" : ""; var target = type.Equals("api", StringComparison.OrdinalIgnoreCase) ? connection : cmd; var status = type.Equals("api", StringComparison.OrdinalIgnoreCase) ? (string.IsNullOrWhiteSpace(connection) ? "missing" : "api") : (Runtime.CommandExists(cmd) ? "cli" : "missing"); var tags = new List<string>(); if (p.Name == def) tags.Add("default"); if (p.Name == critic) tags.Add("critic"); if (p.Name == validator) tags.Add("validator"); foreach (var route in routes.Where(x => x.Value == p.Name)) tags.Add(route.Key); _providers.Rows.Add(p.Name, status, target, string.Join(", ", tags));
            }
        }
        catch { }
    }

    void OpenConfig() { var path = _settings.ActiveProjectPath; if (string.IsNullOrWhiteSpace(path)) return; var cfg = System.IO.Path.Combine(path, ".statefulclanker", "config.json"); if (File.Exists(cfg)) try { Process.Start(new ProcessStartInfo("notepad.exe") { UseShellExecute = true, ArgumentList = { cfg } }); } catch { } }
    static void Copy(string text) { if (!string.IsNullOrWhiteSpace(text)) Clipboard.SetText(text); }
    void ShowFromTray() { Show(); WindowState = FormWindowState.Normal; Activate(); }
    void HandleFormClosing(object? sender, FormClosingEventArgs e) { if (!_reallyExit) { e.Cancel = true; Hide(); return; } _timer.Stop(); _mcp.Dispose(); _notify.Visible = false; _notify.Dispose(); }
}

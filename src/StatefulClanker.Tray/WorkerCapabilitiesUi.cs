using System.Diagnostics;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Windows.Forms;

namespace StatefulClanker.Tray;

static class WorkerCapabilityStore
{
    public static string Path => System.IO.Path.Combine(AppStore.Root, "worker-capabilities.json");
    static JsonObject Defaults() => new()
    {
        ["schemaVersion"] = 2,
        ["allow"] = new JsonArray("builtin.*", "intent.human.read", "intent.normalized.read"),
        ["deny"] = new JsonArray(), ["profiles"] = new JsonObject(), ["sources"] = new JsonObject()
    };
    public static JsonObject Load()
    {
        try
        {
            if (!File.Exists(Path)) return Defaults();
            var root = JsonNode.Parse(File.ReadAllText(Path))?.AsObject() ?? Defaults();
            root["schemaVersion"] = 2; root["allow"] ??= new JsonArray(); root["deny"] ??= new JsonArray(); root["profiles"] ??= new JsonObject(); root["sources"] ??= new JsonObject(); return root;
        }
        catch { return Defaults(); }
    }
    public static void Save(JsonObject root)
    {
        Directory.CreateDirectory(AppStore.Root); root["schemaVersion"] = 2; var tmp = Path + ".tmp";
        File.WriteAllText(tmp, root.ToJsonString(new JsonSerializerOptions { WriteIndented = true }), new UTF8Encoding(false)); File.Move(tmp, Path, true);
    }
    public static string? ActiveProject()
    {
        try { return File.Exists(AppStore.ActiveProjectPointer) ? File.ReadAllText(AppStore.ActiveProjectPointer).Trim() : null; } catch { return null; }
    }
}

static class WorkerCapabilitiesUiBootstrap
{
    static bool _installed;
    [ModuleInitializer] public static void Initialize() => Application.Idle += Install;
    static void Install(object? sender, EventArgs e)
    {
        if (_installed) return;
        foreach (Form form in Application.OpenForms)
        {
            var tabs = Find<TabControl>(form).FirstOrDefault(); if (tabs is null) continue;
            tabs.TabPages.Add(new WorkerCapabilitiesPage()); _installed = true; break;
        }
    }
    static IEnumerable<T> Find<T>(Control root) where T : Control { foreach (Control c in root.Controls) { if (c is T t) yield return t; foreach (var x in Find<T>(c)) yield return x; } }
}

sealed class WorkerCapabilitiesPage : TabPage
{
    readonly DataGridView _profiles = new(), _sources = new(); readonly Label _summary = new(); JsonObject _root = WorkerCapabilityStore.Load();
    public WorkerCapabilitiesPage() : base("Worker Capabilities")
    {
        Padding = new Padding(12); BackColor = Theme.Back; ForeColor = Theme.Text;
        var rows = new TableLayoutPanel { Dock = DockStyle.Fill, RowCount = 6, ColumnCount = 1 };
        rows.RowStyles.Add(new RowStyle(SizeType.Absolute, 44)); rows.RowStyles.Add(new RowStyle(SizeType.Absolute, 48)); rows.RowStyles.Add(new RowStyle(SizeType.Absolute, 28)); rows.RowStyles.Add(new RowStyle(SizeType.Percent, 48)); rows.RowStyles.Add(new RowStyle(SizeType.Absolute, 28)); rows.RowStyles.Add(new RowStyle(SizeType.Percent, 52));
        var bar = new FlowLayoutPanel { Dock = DockStyle.Fill };
        foreach (var b in new[] { Btn("Machine grants", EditGrants), Btn("Add profile", AddProfile), Btn("Add MCP source", AddSource, 150), Btn("Project policy", OpenProjectPolicy), Btn("Refresh", (_, _) => Reload()) }) bar.Controls.Add(b);
        rows.Controls.Add(bar, 0, 0); _summary.Dock = DockStyle.Fill; _summary.Font = new Font("Cascadia Mono", 8.5f); _summary.ForeColor = Theme.Muted; rows.Controls.Add(_summary, 0, 1);
        rows.Controls.Add(Section("CAPABILITY PROFILES — reusable narrowing only"), 0, 2); SetupGrid(_profiles, new[] { "Profile", "Allow", "Deny" }); _profiles.CellDoubleClick += (_, _) => EditSelectedProfile(); rows.Controls.Add(_profiles, 0, 3);
        rows.Controls.Add(Section("EXTERNAL MCP TOOL SOURCES — existence does not imply authorization"), 0, 4); SetupGrid(_sources, new[] { "Source", "Transport", "URL", "Enabled", "Declared tools" }); _sources.CellDoubleClick += (_, _) => EditSelectedSource(); rows.Controls.Add(_sources, 0, 5);
        Controls.Add(rows); Theme.Apply(this); Reload();
    }
    static Button Btn(string text, EventHandler click, int width = 130) { var b = new Button { Text = text, Width = width, Height = 32, Margin = new Padding(0, 4, 8, 0), FlatStyle = FlatStyle.Flat, BackColor = Theme.Surface2, ForeColor = Theme.Text }; b.Click += click; return b; }
    static Label Section(string text) => new() { Text = text, Dock = DockStyle.Fill, TextAlign = ContentAlignment.BottomLeft, Font = new Font("Segoe UI Semibold", 8, FontStyle.Bold), ForeColor = Theme.Muted };
    static void SetupGrid(DataGridView g, IEnumerable<string> cols) { g.Dock = DockStyle.Fill; g.ReadOnly = true; g.AllowUserToAddRows = false; g.RowHeadersVisible = false; g.SelectionMode = DataGridViewSelectionMode.FullRowSelect; g.AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.Fill; foreach (var c in cols) g.Columns.Add(c.ToLowerInvariant().Replace(" ", "_"), c); }
    static string Join(JsonNode? n) => n is JsonArray a ? string.Join(", ", a.Select(x => x?.ToString()).Where(x => !string.IsNullOrWhiteSpace(x))) : "";
    void Reload()
    {
        _root = WorkerCapabilityStore.Load(); _profiles.Rows.Clear(); _sources.Rows.Clear();
        _summary.Text = $"Machine allow: {Join(_root["allow"])}\r\nMachine deny:  {Join(_root["deny"])}";
        if (_root["profiles"] is JsonObject profiles) foreach (var p in profiles.OrderBy(x => x.Key)) { var o = p.Value as JsonObject; _profiles.Rows.Add(p.Key, Join(o?["allow"]), Join(o?["deny"])); }
        if (_root["sources"] is JsonObject sources) foreach (var s in sources.OrderBy(x => x.Key)) { var o = s.Value as JsonObject; _sources.Rows.Add(s.Key, o?["transport"]?.ToString() ?? "http", o?["url"]?.ToString() ?? "", o?["enabled"]?.ToString() ?? "true", o?["tools"] is JsonArray a ? a.Count.ToString() : "dynamic"); }
    }
    void EditGrants(object? s, EventArgs e)
    {
        using var d = new AllowDenyDialog("Machine worker grants", Join(_root["allow"]), Join(_root["deny"])); if (d.ShowDialog(FindForm()) != DialogResult.OK) return;
        _root["allow"] = ToArray(d.Allow); _root["deny"] = ToArray(d.Deny); WorkerCapabilityStore.Save(_root); Reload();
    }
    void AddProfile(object? s, EventArgs e) => EditProfile(null);
    void EditSelectedProfile() { var name = _profiles.SelectedRows.Count > 0 ? _profiles.SelectedRows[0].Cells[0].Value?.ToString() : null; if (name is not null) EditProfile(name); }
    void EditProfile(string? name)
    {
        var profiles = (_root["profiles"] as JsonObject)!; var old = name is null ? null : profiles[name] as JsonObject;
        using var d = new ProfileDialog(name, Join(old?["allow"]), Join(old?["deny"])); if (d.ShowDialog(FindForm()) != DialogResult.OK) return;
        if (name is not null && !string.Equals(name, d.ProfileName, StringComparison.OrdinalIgnoreCase)) profiles.Remove(name);
        profiles[d.ProfileName] = new JsonObject { ["allow"] = string.IsNullOrWhiteSpace(d.Allow) ? null : ToArray(d.Allow), ["deny"] = ToArray(d.Deny) }; WorkerCapabilityStore.Save(_root); Reload();
    }
    void AddSource(object? s, EventArgs e) => EditSource(null);
    void EditSelectedSource() { var name = _sources.SelectedRows.Count > 0 ? _sources.SelectedRows[0].Cells[0].Value?.ToString() : null; if (name is not null) EditSource(name); }
    void EditSource(string? name)
    {
        var sources = (_root["sources"] as JsonObject)!; var old = name is null ? null : sources[name] as JsonObject;
        using var d = new SourceDialog(name, old); if (d.ShowDialog(FindForm()) != DialogResult.OK) return;
        if (name is not null && !string.Equals(name, d.SourceName, StringComparison.OrdinalIgnoreCase)) RemoveSource(name);
        sources = (_root["sources"] as JsonObject)!; sources[d.SourceName] = d.Source;
        foreach (var pattern in Split(d.AllowPatterns)) { if (!pattern.StartsWith($"mcp.{d.SourceName}.", StringComparison.OrdinalIgnoreCase)) { MessageBox.Show(FindForm(), $"Ignoring out-of-scope grant '{pattern}'. Source grants must begin mcp.{d.SourceName}."); continue; } AddUnique(_root["allow"]!.AsArray(), pattern); }
        WorkerCapabilityStore.Save(_root); Reload();
    }
    void RemoveSource(string name)
    {
        (_root["sources"] as JsonObject)?.Remove(name); var prefix = $"mcp.{name}."; FilterArray(_root["allow"]!.AsArray(), prefix); FilterArray(_root["deny"]!.AsArray(), prefix);
    }
    void OpenProjectPolicy(object? s, EventArgs e)
    {
        var project = WorkerCapabilityStore.ActiveProject(); if (string.IsNullOrWhiteSpace(project) || !Directory.Exists(project)) { MessageBox.Show(FindForm(), "Select an active project first."); return; }
        var path = System.IO.Path.Combine(project, ".statefulclanker", "worker-policy.json"); if (!File.Exists(path)) File.WriteAllText(path, "{\n  \"schemaVersion\": 1,\n  \"allow\": null,\n  \"deny\": [],\n  \"roles\": {},\n  \"stages\": {}\n}\n", new UTF8Encoding(false)); Process.Start(new ProcessStartInfo("notepad.exe", path) { UseShellExecute = true });
    }
    static JsonArray ToArray(string value) { var a = new JsonArray(); foreach (var x in Split(value)) a.Add(x); return a; }
    static IEnumerable<string> Split(string value) => value.Split(new[] { ',', ';', '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).Distinct(StringComparer.OrdinalIgnoreCase);
    static void AddUnique(JsonArray a, string value) { if (!a.Any(x => string.Equals(x?.ToString(), value, StringComparison.OrdinalIgnoreCase))) a.Add(value); }
    static void FilterArray(JsonArray a, string prefix) { for (var i = a.Count - 1; i >= 0; i--) if ((a[i]?.ToString() ?? "").StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) a.RemoveAt(i); }
}

class AllowDenyDialog : Form
{
    protected readonly TextBox AllowBox = new(), DenyBox = new(); public string Allow => AllowBox.Text; public string Deny => DenyBox.Text;
    public AllowDenyDialog(string title, string allow, string deny)
    {
        Text = title; Width = 650; Height = 360; StartPosition = FormStartPosition.CenterParent;
        var t = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 5, Padding = new Padding(12) }; t.RowStyles.Add(new RowStyle(SizeType.Absolute, 24)); t.RowStyles.Add(new RowStyle(SizeType.Percent, 50)); t.RowStyles.Add(new RowStyle(SizeType.Absolute, 24)); t.RowStyles.Add(new RowStyle(SizeType.Percent, 50)); t.RowStyles.Add(new RowStyle(SizeType.Absolute, 42));
        AllowBox.Multiline = DenyBox.Multiline = true; AllowBox.Text = allow; DenyBox.Text = deny; t.Controls.Add(new Label { Text = "ALLOW patterns (comma/line separated)", Dock = DockStyle.Fill }, 0, 0); t.Controls.Add(AllowBox, 0, 1); t.Controls.Add(new Label { Text = "DENY patterns (deny wins)", Dock = DockStyle.Fill }, 0, 2); t.Controls.Add(DenyBox, 0, 3);
        var bar = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.RightToLeft }; bar.Controls.Add(new Button { Text = "Save", DialogResult = DialogResult.OK, Width = 90 }); bar.Controls.Add(new Button { Text = "Cancel", DialogResult = DialogResult.Cancel, Width = 90 }); t.Controls.Add(bar, 0, 4); Controls.Add(t); Theme.Apply(this);
    }
}

sealed class ProfileDialog : Form
{
    readonly TextBox _name = new(), _allow = new(), _deny = new(); public string ProfileName => _name.Text.Trim(); public string Allow => _allow.Text; public string Deny => _deny.Text;
    public ProfileDialog(string? name, string allow, string deny)
    {
        Text = "Capability profile"; Width = 650; Height = 420; StartPosition = FormStartPosition.CenterParent;
        var t = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 7, Padding = new Padding(12) };
        t.RowStyles.Add(new RowStyle(SizeType.Absolute, 24)); t.RowStyles.Add(new RowStyle(SizeType.Absolute, 38)); t.RowStyles.Add(new RowStyle(SizeType.Absolute, 24)); t.RowStyles.Add(new RowStyle(SizeType.Percent, 50)); t.RowStyles.Add(new RowStyle(SizeType.Absolute, 24)); t.RowStyles.Add(new RowStyle(SizeType.Percent, 50)); t.RowStyles.Add(new RowStyle(SizeType.Absolute, 42));
        _name.Text = name ?? ""; _allow.Text = allow; _deny.Text = deny; _allow.Multiline = _deny.Multiline = true;
        t.Controls.Add(new Label { Text = "PROFILE NAME", Dock = DockStyle.Fill }, 0, 0); t.Controls.Add(_name, 0, 1); t.Controls.Add(new Label { Text = "ALLOW patterns (narrowing only)", Dock = DockStyle.Fill }, 0, 2); t.Controls.Add(_allow, 0, 3); t.Controls.Add(new Label { Text = "DENY patterns", Dock = DockStyle.Fill }, 0, 4); t.Controls.Add(_deny, 0, 5);
        var bar = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.RightToLeft }; var save = new Button { Text = "Save", DialogResult = DialogResult.OK, Width = 90 }; save.Click += Validate; bar.Controls.Add(save); bar.Controls.Add(new Button { Text = "Cancel", DialogResult = DialogResult.Cancel, Width = 90 }); t.Controls.Add(bar, 0, 6); Controls.Add(t); AcceptButton = save; Theme.Apply(this);
    }
    void Validate(object? sender, EventArgs e) { if (string.IsNullOrWhiteSpace(ProfileName) || !System.Text.RegularExpressions.Regex.IsMatch(ProfileName, "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")) { MessageBox.Show(this, "Profile name must use letters, numbers, dot, underscore, or hyphen."); DialogResult = DialogResult.None; } }
}

sealed class SourceDialog : Form
{
    readonly TextBox _name = new(), _url = new(), _headers = new(), _allow = new(); readonly CheckBox _enabled = new() { Text = "Enabled", Checked = true }; public string SourceName => _name.Text.Trim(); public string AllowPatterns => _allow.Text; public JsonObject Source { get; private set; } = new();
    public SourceDialog(string? name, JsonObject? old)
    {
        Text = "Worker MCP source"; Width = 680; Height = 360; StartPosition = FormStartPosition.CenterParent; var t = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, RowCount = 6, Padding = new Padding(12) }; t.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 160)); t.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); Add(t, 0, "Source name", _name); Add(t, 1, "Streamable HTTP URL", _url); Add(t, 2, "Headers", _headers); Add(t, 3, "Machine allow", _allow); t.Controls.Add(_enabled, 1, 4); var bar = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.RightToLeft }; var save = new Button { Text = "Save", DialogResult = DialogResult.OK, Width = 90 }; bar.Controls.Add(save); bar.Controls.Add(new Button { Text = "Cancel", DialogResult = DialogResult.Cancel, Width = 90 }); t.Controls.Add(bar, 0, 5); t.SetColumnSpan(bar, 2); Controls.Add(t); AcceptButton = save; save.Click += Save;
        _name.Text = name ?? ""; _url.Text = old?["url"]?.ToString() ?? ""; _enabled.Checked = old?["enabled"]?.GetValue<bool>() ?? true; if (old?["headers"] is JsonObject h) _headers.Text = string.Join("; ", h.Select(x => $"{x.Key}: {x.Value}")); _allow.Text = name is null ? "" : $"mcp.{name}.*"; Theme.Apply(this);
    }
    static void Add(TableLayoutPanel t, int row, string label, Control c) { t.RowStyles.Add(new RowStyle(SizeType.Absolute, 48)); t.Controls.Add(new Label { Text = label, Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleLeft }, 0, row); c.Dock = DockStyle.Fill; c.Margin = new Padding(0, 6, 0, 6); t.Controls.Add(c, 1, row); }
    void Save(object? sender, EventArgs e)
    {
        if (string.IsNullOrWhiteSpace(SourceName) || !System.Text.RegularExpressions.Regex.IsMatch(SourceName, "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$") || string.IsNullOrWhiteSpace(_url.Text)) { MessageBox.Show(this, "Source name (letters/numbers/dot/underscore/hyphen) and URL are required."); DialogResult = DialogResult.None; return; }
        var headers = new JsonObject(); foreach (var p in _headers.Text.Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)) { var i = p.IndexOf(':'); if (i > 0) headers[p[..i].Trim()] = p[(i + 1)..].Trim(); }
        Source = new JsonObject { ["transport"] = "streamable-http", ["url"] = _url.Text.Trim(), ["enabled"] = _enabled.Checked, ["headers"] = headers };
    }
}

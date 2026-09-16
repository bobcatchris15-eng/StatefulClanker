using System.Net.Http.Headers;
using System.Runtime.CompilerServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Windows.Forms;

namespace StatefulClanker.Tray;

sealed class ApiConnectionProfile
{
    public string name { get; set; } = "";
    public string baseUrl { get; set; } = "";
    public string model { get; set; } = "";
    public string toolMode { get; set; } = "native";
    public string? apiKeyProtected { get; set; }
    public string? apiKeyEnv { get; set; }
    public Dictionary<string,string> headers { get; set; } = new(StringComparer.OrdinalIgnoreCase);
    public int maxSteps { get; set; } = 24;
    public int? maxTokens { get; set; }
    public double? temperature { get; set; }
}

static class ApiConnectionStore
{
    static readonly JsonSerializerOptions Json = new() { WriteIndented = true, PropertyNameCaseInsensitive = true };
    public static string Path => System.IO.Path.Combine(AppStore.Root, "connections.json");
    public static Dictionary<string,ApiConnectionProfile> Load()
    {
        try
        {
            if (!File.Exists(Path)) return new(StringComparer.OrdinalIgnoreCase);
            using var d = JsonDocument.Parse(File.ReadAllText(Path));
            if (!d.RootElement.TryGetProperty("connections", out var c) || c.ValueKind != JsonValueKind.Object) return new(StringComparer.OrdinalIgnoreCase);
            var result = new Dictionary<string,ApiConnectionProfile>(StringComparer.OrdinalIgnoreCase);
            foreach (var p in c.EnumerateObject()) result[p.Name] = p.Value.Deserialize<ApiConnectionProfile>(Json) ?? new();
            return result;
        }
        catch { return new(StringComparer.OrdinalIgnoreCase); }
    }
    public static void Save(Dictionary<string,ApiConnectionProfile> connections)
    {
        Directory.CreateDirectory(AppStore.Root);
        var root = new JsonObject { ["schemaVersion"] = 1, ["connections"] = JsonSerializer.SerializeToNode(connections, Json) };
        File.WriteAllText(Path, root.ToJsonString(Json), new UTF8Encoding(false));
    }
    public static string Protect(string value)
    {
        var bytes = ProtectedData.Protect(Encoding.UTF8.GetBytes(value), null, DataProtectionScope.CurrentUser);
        return Convert.ToBase64String(bytes);
    }
    public static string? Unprotect(string? value)
    {
        if (string.IsNullOrWhiteSpace(value)) return null;
        try { return Encoding.UTF8.GetString(ProtectedData.Unprotect(Convert.FromBase64String(value), null, DataProtectionScope.CurrentUser)); }
        catch { return null; }
    }
}

static class ApiConnectionsUiBootstrap
{
    static bool _installed;
    [ModuleInitializer]
    public static void Initialize() => Application.Idle += Install;
    static void Install(object? sender, EventArgs e)
    {
        if (_installed) return;
        foreach (Form form in Application.OpenForms)
        {
            var tabs = Find<TabControl>(form).FirstOrDefault();
            if (tabs is null) continue;
            tabs.TabPages.Add(new ApiConnectionsPage());
            _installed = true;
            break;
        }
    }
    static IEnumerable<T> Find<T>(Control root) where T:Control
    {
        foreach (Control c in root.Controls) { if (c is T t) yield return t; foreach (var x in Find<T>(c)) yield return x; }
    }
}

sealed class ApiConnectionsPage : TabPage
{
    readonly DataGridView _grid = new();
    Dictionary<string,ApiConnectionProfile> _profiles = new(StringComparer.OrdinalIgnoreCase);
    public ApiConnectionsPage() : base("API Connections")
    {
        Padding = new Padding(12); BackColor = Theme.Back; ForeColor = Theme.Text;
        var rows = new TableLayoutPanel { Dock = DockStyle.Fill, RowCount = 3, ColumnCount = 1 };
        rows.RowStyles.Add(new RowStyle(SizeType.Absolute, 46)); rows.RowStyles.Add(new RowStyle(SizeType.Absolute, 30)); rows.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        var bar = new FlowLayoutPanel { Dock = DockStyle.Fill };
        foreach (var b in new[] { Make("Add", Add), Make("Edit", Edit), Make("Remove", Remove), Make("Test", Test), Make("Add backend to active project", AddBackend, 220) }) bar.Controls.Add(b);
        rows.Controls.Add(bar,0,0); rows.Controls.Add(new Label { Text="MACHINE-LOCAL DIRECT INFERENCE CONNECTIONS", Dock=DockStyle.Fill, TextAlign=ContentAlignment.BottomLeft, ForeColor=Theme.Muted, Font=new Font("Segoe UI Semibold",8,FontStyle.Bold)},0,1);
        _grid.Dock=DockStyle.Fill; _grid.ReadOnly=true; _grid.AllowUserToAddRows=false; _grid.RowHeadersVisible=false; _grid.SelectionMode=DataGridViewSelectionMode.FullRowSelect; _grid.AutoSizeColumnsMode=DataGridViewAutoSizeColumnsMode.Fill;
        _grid.Columns.Add("id","Connection"); _grid.Columns.Add("url","Base URL"); _grid.Columns.Add("model","Model"); _grid.Columns.Add("tools","Tools"); _grid.Columns.Add("auth","Auth"); rows.Controls.Add(_grid,0,2); Controls.Add(rows); Theme.Apply(this); Reload();
    }
    static Button Make(string text, EventHandler click, int width=130) { var b=new Button{Text=text,Width=width,Height=32,Margin=new Padding(0,4,8,0),FlatStyle=FlatStyle.Flat,BackColor=Theme.Surface2,ForeColor=Theme.Text}; b.Click+=click; return b; }
    string? SelectedId => _grid.SelectedRows.Count>0 ? _grid.SelectedRows[0].Cells[0].Value?.ToString() : null;
    void Reload()
    {
        _profiles=ApiConnectionStore.Load(); _grid.Rows.Clear();
        foreach(var p in _profiles.OrderBy(x=>x.Key,StringComparer.OrdinalIgnoreCase)) _grid.Rows.Add(p.Key,p.Value.baseUrl,p.Value.model,p.Value.toolMode,string.IsNullOrWhiteSpace(p.Value.apiKeyEnv)?(string.IsNullOrWhiteSpace(p.Value.apiKeyProtected)?"none":"DPAPI"):"env:"+p.Value.apiKeyEnv);
    }
    void Add(object? s, EventArgs e) { using var d=new ApiConnectionDialog(); if(d.ShowDialog(FindForm())!=DialogResult.OK)return; _profiles[d.ConnectionId]=d.Profile; ApiConnectionStore.Save(_profiles); Reload(); }
    void Edit(object? s, EventArgs e) { var id=SelectedId; if(id is null||!_profiles.TryGetValue(id,out var p))return; using var d=new ApiConnectionDialog(id,p); if(d.ShowDialog(FindForm())!=DialogResult.OK)return; _profiles.Remove(id); _profiles[d.ConnectionId]=d.Profile; ApiConnectionStore.Save(_profiles); Reload(); }
    void Remove(object? s, EventArgs e) { var id=SelectedId;if(id is null)return;if(MessageBox.Show(FindForm(),$"Remove API connection '{id}'?","Remove connection",MessageBoxButtons.YesNo)!=DialogResult.Yes)return;_profiles.Remove(id);ApiConnectionStore.Save(_profiles);Reload(); }
    async void Test(object? s, EventArgs e)
    {
        var id=SelectedId;if(id is null||!_profiles.TryGetValue(id,out var p))return;
        try
        {
            using var h=new HttpClient{Timeout=TimeSpan.FromSeconds(15)}; var key=string.IsNullOrWhiteSpace(p.apiKeyEnv)?ApiConnectionStore.Unprotect(p.apiKeyProtected):Environment.GetEnvironmentVariable(p.apiKeyEnv!); if(!string.IsNullOrWhiteSpace(key))h.DefaultRequestHeaders.Authorization=new AuthenticationHeaderValue("Bearer",key); foreach(var x in p.headers)h.DefaultRequestHeaders.TryAddWithoutValidation(x.Key,x.Value);
            var url=p.baseUrl.TrimEnd('/')+"/models"; using var r=await h.GetAsync(url); MessageBox.Show(FindForm(),$"HTTP {(int)r.StatusCode} {r.ReasonPhrase}\n{url}",r.IsSuccessStatusCode?"Connection available":"Connection responded",MessageBoxButtons.OK,r.IsSuccessStatusCode?MessageBoxIcon.Information:MessageBoxIcon.Warning);
        } catch(Exception ex) { MessageBox.Show(FindForm(),ex.Message,"Connection test failed",MessageBoxButtons.OK,MessageBoxIcon.Error); }
    }
    void AddBackend(object? s, EventArgs e)
    {
        var id=SelectedId;if(id is null)return;var pointer=AppStore.ActiveProjectPointer;if(!File.Exists(pointer)){MessageBox.Show(FindForm(),"Select an active project first.");return;}var project=File.ReadAllText(pointer).Trim();var path=System.IO.Path.Combine(project,".statefulclanker","config.json");if(!File.Exists(path)){MessageBox.Show(FindForm(),"Active project has no StatefulClanker config.");return;}
        var backend=Microsoft.VisualBasic.Interaction.InputBox("Project backend name:","Add direct API backend",id);if(string.IsNullOrWhiteSpace(backend))return;
        try { var root=JsonNode.Parse(File.ReadAllText(path))?.AsObject() ?? throw new Exception("Invalid project config.");var providers=root["providers"] as JsonObject ?? new JsonObject();root["providers"]=providers;providers[backend]=new JsonObject{{"type","api"},{"connection",id}};File.WriteAllText(path,root.ToJsonString(new JsonSerializerOptions{WriteIndented=true}),new UTF8Encoding(false));MessageBox.Show(FindForm(),$"Added backend '{backend}' using connection '{id}'. Route tasks to it from the Providers/project config."); } catch(Exception ex){MessageBox.Show(FindForm(),ex.Message,"Could not update project",MessageBoxButtons.OK,MessageBoxIcon.Error);}
    }
}

sealed class ApiConnectionDialog : Form
{
    readonly TextBox _id=new(), _url=new(), _model=new(), _key=new(), _env=new(), _headers=new(); readonly ComboBox _preset=new(), _tools=new(); readonly NumericUpDown _steps=new(){Minimum=1,Maximum=100,Value=24};
    public string ConnectionId => _id.Text.Trim(); public ApiConnectionProfile Profile { get; private set; } = new();
    public ApiConnectionDialog(string? id=null, ApiConnectionProfile? current=null)
    {
        Text=id is null?"Add API connection":"Edit API connection";Width=680;Height=590;StartPosition=FormStartPosition.CenterParent;BackColor=Theme.Back;ForeColor=Theme.Text;
        var t=new TableLayoutPanel{Dock=DockStyle.Fill,ColumnCount=2,RowCount=10,Padding=new Padding(14)};t.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute,150));t.ColumnStyles.Add(new ColumnStyle(SizeType.Percent,100));
        Add(t,0,"Preset",_preset);_preset.Items.AddRange(new object[]{"Custom OpenAI-compatible","Ollama (local)","LM Studio (local)","vLLM (local)","OpenRouter"});_preset.SelectedIndex=0;_preset.SelectedIndexChanged+=(_,_)=>ApplyPreset();
        Add(t,1,"Connection id",_id);Add(t,2,"Base URL",_url);Add(t,3,"Model",_model);Add(t,4,"Tool protocol",_tools);_tools.Items.AddRange(new object[]{"native","text"});_tools.SelectedIndex=0;Add(t,5,"API key",_key);_key.UseSystemPasswordChar=true;Add(t,6,"API key env",_env);Add(t,7,"Extra headers",_headers);_headers.PlaceholderText="Header: value; Header2: value";Add(t,8,"Max agent steps",_steps);
        var bar=new FlowLayoutPanel{Dock=DockStyle.Fill,FlowDirection=FlowDirection.RightToLeft};var ok=new Button{Text="Save",DialogResult=DialogResult.OK,Width=100};var cancel=new Button{Text="Cancel",DialogResult=DialogResult.Cancel,Width=100};bar.Controls.Add(ok);bar.Controls.Add(cancel);t.Controls.Add(bar,0,9);t.SetColumnSpan(bar,2);Controls.Add(t);AcceptButton=ok;CancelButton=cancel;ok.Click+=Save;
        if(current is not null){_id.Text=id;_url.Text=current.baseUrl;_model.Text=current.model;_tools.SelectedItem=current.toolMode;_env.Text=current.apiKeyEnv??"";_steps.Value=Math.Clamp(current.maxSteps,1,100);_headers.Text=string.Join("; ",current.headers.Select(x=>$"{x.Key}: {x.Value}"));}
        Theme.Apply(this);
    }
    static void Add(TableLayoutPanel t,int row,string label,Control c){t.RowStyles.Add(new RowStyle(SizeType.Absolute,row==7?66:46));t.Controls.Add(new Label{Text=label,Dock=DockStyle.Fill,TextAlign=ContentAlignment.MiddleLeft,ForeColor=Theme.Muted},0,row);c.Dock=DockStyle.Fill;c.Margin=new Padding(0,6,0,6);t.Controls.Add(c,1,row);}
    void ApplyPreset(){switch(_preset.SelectedItem?.ToString()){case "Ollama (local)":_url.Text="http://127.0.0.1:11434/v1";break;case "LM Studio (local)":_url.Text="http://127.0.0.1:1234/v1";break;case "vLLM (local)":_url.Text="http://127.0.0.1:8000/v1";break;case "OpenRouter":_url.Text="https://openrouter.ai/api/v1";break;}}
    void Save(object? s,EventArgs e)
    {
        if(string.IsNullOrWhiteSpace(_id.Text)||string.IsNullOrWhiteSpace(_url.Text)||string.IsNullOrWhiteSpace(_model.Text)){MessageBox.Show(this,"Connection id, base URL, and model are required.");DialogResult=DialogResult.None;return;}
        var h=new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase);foreach(var part in _headers.Text.Split(';',StringSplitOptions.RemoveEmptyEntries|StringSplitOptions.TrimEntries)){var i=part.IndexOf(':');if(i>0)h[part[..i].Trim()]=part[(i+1)..].Trim();}
        Profile=new ApiConnectionProfile{name=_id.Text.Trim(),baseUrl=_url.Text.Trim().TrimEnd('/'),model=_model.Text.Trim(),toolMode=_tools.SelectedItem?.ToString()??"native",apiKeyEnv=string.IsNullOrWhiteSpace(_env.Text)?null:_env.Text.Trim(),apiKeyProtected=string.IsNullOrWhiteSpace(_key.Text)?null:ApiConnectionStore.Protect(_key.Text),headers=h,maxSteps=(int)_steps.Value};
    }
}

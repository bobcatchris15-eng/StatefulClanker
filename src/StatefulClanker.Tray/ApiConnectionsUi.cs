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
    public string protocol { get; set; } = "openai-chat";
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
        var tmp = Path + ".tmp";
        File.WriteAllText(tmp, root.ToJsonString(Json), new UTF8Encoding(false));
        File.Move(tmp, Path, true);
    }
    public static string Protect(string value) => Convert.ToBase64String(ProtectedData.Protect(Encoding.UTF8.GetBytes(value), null, DataProtectionScope.CurrentUser));
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
    [ModuleInitializer] public static void Initialize() => Application.Idle += Install;
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
    readonly TextBox _openRouterKey = new();
    readonly Label _openRouterStatus = new();
    Dictionary<string,ApiConnectionProfile> _profiles = new(StringComparer.OrdinalIgnoreCase);

    public ApiConnectionsPage() : base("API Connections")
    {
        Padding = new Padding(12); BackColor = Theme.Back; ForeColor = Theme.Text;
        var rows = new TableLayoutPanel { Dock = DockStyle.Fill, RowCount = 5, ColumnCount = 1 };
        rows.RowStyles.Add(new RowStyle(SizeType.Absolute, 28));
        rows.RowStyles.Add(new RowStyle(SizeType.Absolute, 48));
        rows.RowStyles.Add(new RowStyle(SizeType.Absolute, 46));
        rows.RowStyles.Add(new RowStyle(SizeType.Absolute, 30));
        rows.RowStyles.Add(new RowStyle(SizeType.Percent, 100));

        rows.Controls.Add(new Label { Text="OPENROUTER", Dock=DockStyle.Fill, TextAlign=ContentAlignment.BottomLeft, ForeColor=Theme.Muted, Font=new Font("Segoe UI Semibold",8,FontStyle.Bold)},0,0);
        var openRouter = new TableLayoutPanel { Dock=DockStyle.Fill, ColumnCount=4, RowCount=1 };
        openRouter.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 150));
        openRouter.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        openRouter.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 135));
        openRouter.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 135));
        openRouter.Controls.Add(new Label { Text="OpenRouter API Key", Dock=DockStyle.Fill, TextAlign=ContentAlignment.MiddleLeft, ForeColor=Theme.Text },0,0);
        _openRouterKey.Dock=DockStyle.Fill; _openRouterKey.UseSystemPasswordChar=true; _openRouterKey.PlaceholderText="sk-or-v1-..."; _openRouterKey.Margin=new Padding(0,7,8,7); openRouter.Controls.Add(_openRouterKey,1,0);
        openRouter.Controls.Add(Make("Save key", SaveOpenRouterKey, 125),2,0);
        openRouter.Controls.Add(Make("Test key", TestOpenRouterKey, 125),3,0);
        rows.Controls.Add(openRouter,0,1);

        var bar = new FlowLayoutPanel { Dock = DockStyle.Fill };
        foreach (var b in new[] { Make("Add custom", Add), Make("Edit", Edit), Make("Remove", Remove), Make("Test", Test), Make("Add backend to active project", AddBackend, 220) }) bar.Controls.Add(b);
        _openRouterStatus.AutoSize=true; _openRouterStatus.Margin=new Padding(12,11,0,0); _openRouterStatus.ForeColor=Theme.Muted; bar.Controls.Add(_openRouterStatus);
        rows.Controls.Add(bar,0,2);
        rows.Controls.Add(new Label { Text="MACHINE-LOCAL DIRECT INFERENCE CONNECTIONS", Dock=DockStyle.Fill, TextAlign=ContentAlignment.BottomLeft, ForeColor=Theme.Muted, Font=new Font("Segoe UI Semibold",8,FontStyle.Bold)},0,3);

        _grid.Dock=DockStyle.Fill; _grid.ReadOnly=true; _grid.AllowUserToAddRows=false; _grid.RowHeadersVisible=false; _grid.SelectionMode=DataGridViewSelectionMode.FullRowSelect; _grid.AutoSizeColumnsMode=DataGridViewAutoSizeColumnsMode.Fill;
        _grid.Columns.Add("id","Connection"); _grid.Columns.Add("protocol","Protocol"); _grid.Columns.Add("url","Base URL"); _grid.Columns.Add("model","Model"); _grid.Columns.Add("tools","Tools"); _grid.Columns.Add("auth","Auth"); rows.Controls.Add(_grid,0,4);
        Controls.Add(rows); Theme.Apply(this); Reload();
    }

    static Button Make(string text, EventHandler click, int width=130) { var b=new Button{Text=text,Width=width,Height=32,Margin=new Padding(0,4,8,0),FlatStyle=FlatStyle.Flat,BackColor=Theme.Surface2,ForeColor=Theme.Text}; b.Click+=click; return b; }
    string? SelectedId => _grid.SelectedRows.Count>0 ? _grid.SelectedRows[0].Cells[0].Value?.ToString() : null;
    static bool IsManagedOpenRouter(string id) => OpenRouterFreeModels.All.Any(x=>string.Equals(x.ConnectionId,id,StringComparison.OrdinalIgnoreCase));

    void Reload()
    {
        _profiles=ApiConnectionStore.Load(); _grid.Rows.Clear();
        foreach(var p in _profiles.OrderBy(x=>x.Key,StringComparer.OrdinalIgnoreCase)) _grid.Rows.Add(p.Key,p.Value.protocol,p.Value.baseUrl,p.Value.model,p.Value.toolMode,string.IsNullOrWhiteSpace(p.Value.apiKeyEnv)?(string.IsNullOrWhiteSpace(p.Value.apiKeyProtected)?"none":"DPAPI"):"env:"+p.Value.apiKeyEnv);
        var ready=OpenRouterFreeModels.All.Count(x=>_profiles.TryGetValue(x.ConnectionId,out var p)&&!string.IsNullOrWhiteSpace(p.apiKeyProtected));
        _openRouterStatus.Text=ready==OpenRouterFreeModels.All.Length?$"OpenRouter: {ready} free models ready":ready>0?$"OpenRouter: {ready}/{OpenRouterFreeModels.All.Length} presets ready":"OpenRouter: not configured";
        _openRouterKey.PlaceholderText=ready>0?"saved securely  -  paste a new key to replace":"sk-or-v1-...";
    }

    void SaveOpenRouterKey(object? s, EventArgs e)
    {
        var key=_openRouterKey.Text.Trim();
        if(string.IsNullOrWhiteSpace(key)){MessageBox.Show(FindForm(),"Paste an OpenRouter API key first.","OpenRouter",MessageBoxButtons.OK,MessageBoxIcon.Information);return;}
        var protectedKey=ApiConnectionStore.Protect(key);
        foreach(var model in OpenRouterFreeModels.All)
        {
            var p=_profiles.TryGetValue(model.ConnectionId,out var current)?current:new ApiConnectionProfile();
            p.name=model.ConnectionId;p.protocol="openai-chat";p.baseUrl=OpenRouterFreeModels.BaseUrl;p.model=model.ModelId;p.toolMode=model.ToolMode;p.apiKeyEnv=null;p.apiKeyProtected=protectedKey;
            _profiles[model.ConnectionId]=p;
        }
        ApiConnectionStore.Save(_profiles);_openRouterKey.Clear();Reload();
        MessageBox.Show(FindForm(),$"OpenRouter key saved for the current Windows user. {OpenRouterFreeModels.All.Length} free-model connections are ready.","OpenRouter ready",MessageBoxButtons.OK,MessageBoxIcon.Information);
    }

    string? ResolveOpenRouterKey()
    {
        var typed=_openRouterKey.Text.Trim();if(!string.IsNullOrWhiteSpace(typed))return typed;
        foreach(var model in OpenRouterFreeModels.All) if(_profiles.TryGetValue(model.ConnectionId,out var p)){var key=ApiConnectionStore.Unprotect(p.apiKeyProtected);if(!string.IsNullOrWhiteSpace(key))return key;}
        return null;
    }

    async void TestOpenRouterKey(object? s, EventArgs e)
    {
        var key=ResolveOpenRouterKey();if(string.IsNullOrWhiteSpace(key)){MessageBox.Show(FindForm(),"No OpenRouter key is saved or entered.","OpenRouter",MessageBoxButtons.OK,MessageBoxIcon.Information);return;}
        try
        {
            using var h=new HttpClient{Timeout=TimeSpan.FromSeconds(15)};h.DefaultRequestHeaders.Authorization=new AuthenticationHeaderValue("Bearer",key);
            using var r=await h.GetAsync(OpenRouterFreeModels.BaseUrl+"/key");var body=await r.Content.ReadAsStringAsync();
            var detail="";try{using var d=JsonDocument.Parse(body);if(d.RootElement.TryGetProperty("data",out var data)){var label=data.TryGetProperty("label",out var l)?l.GetString():null;var remaining=data.TryGetProperty("limit_remaining",out var rem)?rem.ToString():null;detail=$"\nKey: {label??"valid"}"+(remaining is null?"":$"\nLimit remaining: {remaining}");}}catch{}
            MessageBox.Show(FindForm(),$"HTTP {(int)r.StatusCode} {r.ReasonPhrase}{detail}",r.IsSuccessStatusCode?"OpenRouter key valid":"OpenRouter key rejected",MessageBoxButtons.OK,r.IsSuccessStatusCode?MessageBoxIcon.Information:MessageBoxIcon.Warning);
        } catch(Exception ex){MessageBox.Show(FindForm(),ex.Message,"OpenRouter test failed",MessageBoxButtons.OK,MessageBoxIcon.Error);}
    }

    void Add(object? s, EventArgs e) { using var d=new ApiConnectionDialog(); if(d.ShowDialog(FindForm())!=DialogResult.OK)return; _profiles[d.ConnectionId]=d.Profile; ApiConnectionStore.Save(_profiles); Reload(); }
    void Edit(object? s, EventArgs e)
    {
        var id=SelectedId; if(id is null||!_profiles.TryGetValue(id,out var previous))return;
        if(IsManagedOpenRouter(id)){MessageBox.Show(FindForm(),"This is a managed OpenRouter free-model preset. Change the shared key in the OpenRouter field above; model/base URL/tool mode are maintained by the preset catalog.");return;}
        using var d=new ApiConnectionDialog(id,previous); if(d.ShowDialog(FindForm())!=DialogResult.OK)return;
        if(string.IsNullOrWhiteSpace(d.Profile.apiKeyProtected) && string.Equals(d.Profile.apiKeyEnv, previous.apiKeyEnv, StringComparison.OrdinalIgnoreCase)) d.Profile.apiKeyProtected=previous.apiKeyProtected;
        _profiles.Remove(id); _profiles[d.ConnectionId]=d.Profile; ApiConnectionStore.Save(_profiles); Reload();
    }
    void Remove(object? s, EventArgs e) { var id=SelectedId;if(id is null)return;if(MessageBox.Show(FindForm(),$"Remove API connection '{id}'?"+(IsManagedOpenRouter(id)?" Saving the OpenRouter key again will recreate it.":""),"Remove connection",MessageBoxButtons.YesNo)!=DialogResult.Yes)return;_profiles.Remove(id);ApiConnectionStore.Save(_profiles);Reload(); }
    async void Test(object? s, EventArgs e)
    {
        var id=SelectedId;if(id is null||!_profiles.TryGetValue(id,out var p))return;
        try
        {
            if(!string.Equals(p.protocol,"openai-chat",StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException($"No connection test adapter exists yet for protocol '{p.protocol}'.");
            using var h=new HttpClient{Timeout=TimeSpan.FromSeconds(15)}; var key=string.IsNullOrWhiteSpace(p.apiKeyEnv)?ApiConnectionStore.Unprotect(p.apiKeyProtected):Environment.GetEnvironmentVariable(p.apiKeyEnv!); if(!string.IsNullOrWhiteSpace(key))h.DefaultRequestHeaders.Authorization=new AuthenticationHeaderValue("Bearer",key); foreach(var x in p.headers)h.DefaultRequestHeaders.TryAddWithoutValidation(x.Key,x.Value);
            var url=p.baseUrl.TrimEnd('/')+"/models"; using var r=await h.GetAsync(url); MessageBox.Show(FindForm(),$"HTTP {(int)r.StatusCode} {r.ReasonPhrase}\n{url}",r.IsSuccessStatusCode?"Connection available":"Connection responded",MessageBoxButtons.OK,r.IsSuccessStatusCode?MessageBoxIcon.Information:MessageBoxIcon.Warning);
        } catch(Exception ex) { MessageBox.Show(FindForm(),ex.Message,"Connection test failed",MessageBoxButtons.OK,MessageBoxIcon.Error); }
    }
    void AddBackend(object? s, EventArgs e)
    {
        var id=SelectedId;if(id is null)return;var pointer=AppStore.ActiveProjectPointer;if(!File.Exists(pointer)){MessageBox.Show(FindForm(),"Select an active project first.");return;}var project=File.ReadAllText(pointer).Trim();var path=System.IO.Path.Combine(project,".statefulclanker","config.json");if(!File.Exists(path)){MessageBox.Show(FindForm(),"Active project has no StatefulClanker config.");return;}
        var backend=PromptText(FindForm(),"Add direct API backend","Project backend name:",id);if(string.IsNullOrWhiteSpace(backend))return;
        try
        {
            var root=JsonNode.Parse(File.ReadAllText(path))?.AsObject() ?? throw new Exception("Invalid project config.");var providers=root["providers"] as JsonObject ?? new JsonObject();root["providers"]=providers;providers[backend]=new JsonObject{{"type","api"},{"connection",id}};
            var tmp=path+".tmp";File.WriteAllText(tmp,root.ToJsonString(new JsonSerializerOptions{WriteIndented=true}),new UTF8Encoding(false));File.Move(tmp,path,true);
            MessageBox.Show(FindForm(),$"Added backend '{backend}' using connection '{id}'. Route tasks to it from the Providers/project config.");
        } catch(Exception ex){MessageBox.Show(FindForm(),ex.Message,"Could not update project",MessageBoxButtons.OK,MessageBoxIcon.Error);}
    }
    static string? PromptText(IWin32Window? owner,string title,string label,string initial)
    {
        using var f=new Form{Text=title,Width=460,Height=160,StartPosition=FormStartPosition.CenterParent,BackColor=Theme.Back,ForeColor=Theme.Text};var l=new Label{Text=label,Left=12,Top=14,Width=420};var t=new TextBox{Text=initial,Left=12,Top=40,Width=420};var ok=new Button{Text="OK",DialogResult=DialogResult.OK,Left=250,Top=75,Width=85};var cancel=new Button{Text="Cancel",DialogResult=DialogResult.Cancel,Left=347,Top=75,Width=85};f.Controls.AddRange(new Control[]{l,t,ok,cancel});f.AcceptButton=ok;f.CancelButton=cancel;Theme.Apply(f);return f.ShowDialog(owner)==DialogResult.OK?t.Text.Trim():null;
    }
}

sealed class ApiConnectionDialog : Form
{
    readonly TextBox _id=new(), _url=new(), _model=new(), _key=new(), _env=new(), _headers=new(); readonly ComboBox _preset=new(), _protocol=new(), _tools=new(); readonly NumericUpDown _steps=new(){Minimum=1,Maximum=100,Value=24};
    public string ConnectionId => _id.Text.Trim(); public ApiConnectionProfile Profile { get; private set; } = new();
    public ApiConnectionDialog(string? id=null, ApiConnectionProfile? current=null)
    {
        Text=id is null?"Add API connection":"Edit API connection";Width=680;Height=640;StartPosition=FormStartPosition.CenterParent;BackColor=Theme.Back;ForeColor=Theme.Text;
        var t=new TableLayoutPanel{Dock=DockStyle.Fill,ColumnCount=2,RowCount=11,Padding=new Padding(14)};t.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute,150));t.ColumnStyles.Add(new ColumnStyle(SizeType.Percent,100));
        Add(t,0,"Preset",_preset);_preset.Items.AddRange(new object[]{"Custom OpenAI-compatible","Ollama (local)","LM Studio (local)","vLLM (local)"});_preset.SelectedIndex=0;_preset.SelectedIndexChanged+=(_,_)=>ApplyPreset();
        Add(t,1,"Connection id",_id);Add(t,2,"Protocol",_protocol);_protocol.Items.Add("openai-chat");_protocol.SelectedIndex=0;Add(t,3,"Base URL",_url);Add(t,4,"Model",_model);Add(t,5,"Tool protocol",_tools);_tools.Items.AddRange(new object[]{"native","text"});_tools.SelectedIndex=0;Add(t,6,"API key",_key);_key.UseSystemPasswordChar=true;Add(t,7,"API key env",_env);Add(t,8,"Extra headers",_headers);_headers.PlaceholderText="Header: value; Header2: value";Add(t,9,"Max agent steps",_steps);
        var bar=new FlowLayoutPanel{Dock=DockStyle.Fill,FlowDirection=FlowDirection.RightToLeft};var ok=new Button{Text="Save",DialogResult=DialogResult.OK,Width=100};var cancel=new Button{Text="Cancel",DialogResult=DialogResult.Cancel,Width=100};bar.Controls.Add(ok);bar.Controls.Add(cancel);t.Controls.Add(bar,0,10);t.SetColumnSpan(bar,2);Controls.Add(t);AcceptButton=ok;CancelButton=cancel;ok.Click+=Save;
        if(current is not null){_id.Text=id;_protocol.SelectedItem=string.IsNullOrWhiteSpace(current.protocol)?"openai-chat":current.protocol;_url.Text=current.baseUrl;_model.Text=current.model;_tools.SelectedItem=current.toolMode;_env.Text=current.apiKeyEnv??"";_steps.Value=Math.Clamp(current.maxSteps,1,100);_headers.Text=string.Join("; ",current.headers.Select(x=>$"{x.Key}: {x.Value}"));}
        Theme.Apply(this);
    }
    static void Add(TableLayoutPanel t,int row,string label,Control c){t.RowStyles.Add(new RowStyle(SizeType.Absolute,row==8?66:46));t.Controls.Add(new Label{Text=label,Dock=DockStyle.Fill,TextAlign=ContentAlignment.MiddleLeft,ForeColor=Theme.Muted},0,row);c.Dock=DockStyle.Fill;c.Margin=new Padding(0,6,0,6);t.Controls.Add(c,1,row);}
    void ApplyPreset(){switch(_preset.SelectedItem?.ToString()){case "Ollama (local)":_url.Text="http://127.0.0.1:11434/v1";break;case "LM Studio (local)":_url.Text="http://127.0.0.1:1234/v1";break;case "vLLM (local)":_url.Text="http://127.0.0.1:8000/v1";break;}}
    void Save(object? s,EventArgs e)
    {
        if(string.IsNullOrWhiteSpace(_id.Text)||string.IsNullOrWhiteSpace(_url.Text)||string.IsNullOrWhiteSpace(_model.Text)){MessageBox.Show(this,"Connection id, base URL, and model are required.");DialogResult=DialogResult.None;return;}
        var h=new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase);foreach(var part in _headers.Text.Split(';',StringSplitOptions.RemoveEmptyEntries|StringSplitOptions.TrimEntries)){var i=part.IndexOf(':');if(i>0)h[part[..i].Trim()]=part[(i+1)..].Trim();}
        Profile=new ApiConnectionProfile{name=_id.Text.Trim(),protocol=_protocol.SelectedItem?.ToString()??"openai-chat",baseUrl=_url.Text.Trim().TrimEnd('/'),model=_model.Text.Trim(),toolMode=_tools.SelectedItem?.ToString()??"native",apiKeyEnv=string.IsNullOrWhiteSpace(_env.Text)?null:_env.Text.Trim(),apiKeyProtected=string.IsNullOrWhiteSpace(_key.Text)?null:ApiConnectionStore.Protect(_key.Text),headers=h,maxSteps=(int)_steps.Value};
    }
}

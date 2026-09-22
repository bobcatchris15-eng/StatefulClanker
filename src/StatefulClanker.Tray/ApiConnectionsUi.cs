using System.Diagnostics;
using System.Net.Http.Headers;
using System.Runtime.CompilerServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Windows.Forms;

namespace StatefulClanker.Tray;

sealed class ApiDiscoveredModel
{
    public string id { get; set; } = "";
    public string displayName { get; set; } = "";
    public string ownedBy { get; set; } = "";
    public long? contextLength { get; set; }
    public bool? supportsTools { get; set; }
    public bool? isFree { get; set; }
    public double? inputPrice { get; set; }
    public double? outputPrice { get; set; }
}

sealed class ApiConnectionProfile
{
    public string name { get; set; } = "";
    public string presetId { get; set; } = "custom";
    public string protocol { get; set; } = "openai-chat";
    public string baseUrl { get; set; } = "";
    public string modelsPath { get; set; } = "/models";
    public string discoveryKind { get; set; } = "openai";
    public string authKind { get; set; } = "bearer";
    public string? accountId { get; set; }
    public string toolModeDefault { get; set; } = "native";
    public string? apiKeyProtected { get; set; }
    public string? apiKeyEnv { get; set; }
    public Dictionary<string,string> headers { get; set; } = new(StringComparer.OrdinalIgnoreCase);
    public List<ApiDiscoveredModel> models { get; set; } = new();
    public string health { get; set; } = "unknown";
    public string? lastTestAt { get; set; }
    public string? lastError { get; set; }

    // v1 compatibility. Old profiles stored one model per "connection".
    public string? model { get; set; }
    public string? toolMode { get; set; }
    public int maxSteps { get; set; } = 512;
    public int? maxTokens { get; set; }
    public double? temperature { get; set; }
}

sealed class TargetPoolEntry
{
    public string id { get; set; } = "";
    public string connection { get; set; } = "";
    public string model { get; set; } = "";
    public string displayName { get; set; } = "";
    public bool enabled { get; set; } = true;
    public bool workhorse { get; set; } = true;
    public bool? free { get; set; }
    public bool? supportsTools { get; set; }
    public long? contextLength { get; set; }
    public string toolMode { get; set; } = "native";
    public string source { get; set; } = "user";
    public string? rationale { get; set; }
    public string? researchedAt { get; set; }
    public string updatedAt { get; set; } = DateTimeOffset.UtcNow.ToString("O");
}

sealed class TargetPoolDocument
{
    public int schemaVersion { get; set; } = 1;
    public string updatedAt { get; set; } = DateTimeOffset.UtcNow.ToString("O");
    public Dictionary<string,TargetPoolEntry> entries { get; set; } = new(StringComparer.OrdinalIgnoreCase);
}

static class TargetPoolStore
{
    static readonly JsonSerializerOptions Json = new() { WriteIndented = true, PropertyNameCaseInsensitive = true };

    // Endpoint selection is machine-operational state, not project truth. StatefulClanker
    // has one active project at a time; the same connection/model catalog simply services
    // whichever project is active now.
    public static string ActivePoolPath() => System.IO.Path.Combine(AppStore.Root,"endpoints.json");

    public static TargetPoolDocument LoadActive()
    {
        var path = ActivePoolPath();
        if (!File.Exists(path)) return new();
        try
        {
            var doc = JsonSerializer.Deserialize<TargetPoolDocument>(File.ReadAllText(path),Json) ?? new();
            doc.entries = new Dictionary<string,TargetPoolEntry>(doc.entries ?? new(),StringComparer.OrdinalIgnoreCase);
            return doc;
        }
        catch { return new(); }
    }

    public static void SaveActive(TargetPoolDocument doc)
    {
        var path = ActivePoolPath();
        Directory.CreateDirectory(System.IO.Path.GetDirectoryName(path)!);
        doc.schemaVersion = 2;
        doc.updatedAt = DateTimeOffset.UtcNow.ToString("O");
        var tmp = path + ".tmp";
        File.WriteAllText(tmp,JsonSerializer.Serialize(doc,Json),new UTF8Encoding(false));
        File.Move(tmp,path,true);
    }

    public static string Id(string connection,string model) => connection.Trim() + "::" + model.Trim();
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
            foreach (var p in c.EnumerateObject())
            {
                var profile = p.Value.Deserialize<ApiConnectionProfile>(Json) ?? new();
                profile.name = string.IsNullOrWhiteSpace(profile.name) ? p.Name : profile.name;
                profile.models ??= new();
                profile.headers ??= new(StringComparer.OrdinalIgnoreCase);
                if (string.Equals(profile.protocol,"anthropic-messages",StringComparison.OrdinalIgnoreCase) &&
                    string.Equals(profile.authKind,"bearer",StringComparison.OrdinalIgnoreCase))
                    profile.authKind="x-api-key";
                if (profile.models.Count == 0 && !string.IsNullOrWhiteSpace(profile.model))
                {
                    profile.models.Add(new ApiDiscoveredModel {
                        id = profile.model!,
                        displayName = profile.model!,
                        supportsTools = !string.Equals(profile.toolMode,"text",StringComparison.OrdinalIgnoreCase)
                    });
                }
                result[p.Name] = profile;
            }
            return result;
        }
        catch { return new(StringComparer.OrdinalIgnoreCase); }
    }

    public static void Save(Dictionary<string,ApiConnectionProfile> connections)
    {
        Directory.CreateDirectory(AppStore.Root);
        var root = new JsonObject { ["schemaVersion"] = 2, ["connections"] = JsonSerializer.SerializeToNode(connections, Json) };
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

    public static string? ResolveKey(ApiConnectionProfile p)
    {
        if (!string.IsNullOrWhiteSpace(p.apiKeyEnv)) return Environment.GetEnvironmentVariable(p.apiKeyEnv!);
        return Unprotect(p.apiKeyProtected);
    }
}

sealed record ApiConnectionTestResult(bool Success,string Message,List<ApiDiscoveredModel> Models);

static class ApiConnectionTester
{
    public static async Task<ApiConnectionTestResult> TestAndDiscoverAsync(ApiConnectionProfile p,string? rawKey=null)
    {
        try
        {
            using var h = new HttpClient { Timeout = TimeSpan.FromSeconds(20) };
            var key = !string.IsNullOrWhiteSpace(rawKey) ? rawKey : ApiConnectionStore.ResolveKey(p);
            if (!string.IsNullOrWhiteSpace(key))
            {
                switch ((p.authKind ?? "bearer").Trim().ToLowerInvariant())
                {
                    case "x-api-key":
                        h.DefaultRequestHeaders.TryAddWithoutValidation("x-api-key",key);
                        break;
                    case "none":
                        break;
                    default:
                        h.DefaultRequestHeaders.Authorization=new AuthenticationHeaderValue("Bearer",key);
                        break;
                }
            }
            foreach (var x in p.headers)
            {
                var value=x.Value;
                if (string.Equals(x.Key,"x-opencode-session",StringComparison.OrdinalIgnoreCase) &&
                    string.Equals(value,"project",StringComparison.OrdinalIgnoreCase))
                    value="statefulclanker-discovery";
                h.DefaultRequestHeaders.TryAddWithoutValidation(x.Key,value);
            }

            var baseUrl = InferencePresets.Expand(p.baseUrl,p.accountId).TrimEnd('/');
            var modelsPath = InferencePresets.Expand(p.modelsPath,p.accountId);
            var url = Uri.TryCreate(modelsPath,UriKind.Absolute,out var absolute)
                ? absolute.ToString()
                : baseUrl + "/" + modelsPath.TrimStart('/');

            using var r = await h.GetAsync(url);
            var body = await r.Content.ReadAsStringAsync();
            if (!r.IsSuccessStatusCode)
            {
                var detail = body.Length > 800 ? body[..800] + "…" : body;
                return new(false,$"HTTP {(int)r.StatusCode} {r.ReasonPhrase}\r\n{url}\r\n{detail}",new());
            }

            using var d = JsonDocument.Parse(body);
            var models = ParseModels(d.RootElement,p.discoveryKind);
            if (models.Count == 0)
                return new(false,$"The API authenticated successfully but returned no discoverable models from {url}.",new());

            return new(true,$"Authenticated. Discovered {models.Count:N0} model(s).",models);
        }
        catch(Exception ex) { return new(false,ex.Message,new()); }
    }

    static List<ApiDiscoveredModel> ParseModels(JsonElement root,string kind)
    {
        JsonElement list = default;
        var found = false;
        if (root.ValueKind == JsonValueKind.Array) { list=root; found=true; }
        else if (root.ValueKind == JsonValueKind.Object)
        {
            if (root.TryGetProperty("data",out var data) && data.ValueKind==JsonValueKind.Array) { list=data; found=true; }
            else if (root.TryGetProperty("models",out var models) && models.ValueKind==JsonValueKind.Array) { list=models; found=true; }
            else if (root.TryGetProperty("result",out var result))
            {
                if (result.ValueKind==JsonValueKind.Array) { list=result; found=true; }
                else if (result.ValueKind==JsonValueKind.Object && result.TryGetProperty("data",out var nested) && nested.ValueKind==JsonValueKind.Array) { list=nested; found=true; }
            }
        }
        if (!found) return new();

        var output = new List<ApiDiscoveredModel>();
        foreach (var x in list.EnumerateArray())
        {
            if (x.ValueKind != JsonValueKind.Object) continue;
            var id = Str(x,"id") ?? Str(x,"name") ?? Str(x,"model");
            if (string.IsNullOrWhiteSpace(id)) continue;
            var display = Str(x,"display_name") ?? Str(x,"displayName") ?? Str(x,"name") ?? id;
            long? context = Long(x,"context_length") ?? Long(x,"max_context_length");
            bool? tools = Bool(x,"supports_tools");
            if (tools is null && x.TryGetProperty("capabilities",out var caps) && caps.ValueKind==JsonValueKind.Object)
                tools = Bool(caps,"function_calling");
            if (tools is null && x.TryGetProperty("supported_parameters",out var supported) && supported.ValueKind==JsonValueKind.Array)
                tools = supported.EnumerateArray().Any(v => v.ValueKind==JsonValueKind.String && (string.Equals(v.GetString(),"tools",StringComparison.OrdinalIgnoreCase) || string.Equals(v.GetString(),"tool_choice",StringComparison.OrdinalIgnoreCase)));
            bool? free = Bool(x,"is_free");
            double? input = null, outputPrice = null;
            if (x.TryGetProperty("pricing",out var pricing) && pricing.ValueKind==JsonValueKind.Object)
            {
                input = Double(pricing,"input");
                outputPrice = Double(pricing,"output");
                if (free is null && input == 0d && outputPrice == 0d) free=true;
            }
            if (free is null && id.EndsWith(":free",StringComparison.OrdinalIgnoreCase)) free=true;
            output.Add(new ApiDiscoveredModel {
                id=id, displayName=display ?? id, ownedBy=Str(x,"owned_by") ?? "",
                contextLength=context, supportsTools=tools, isFree=free, inputPrice=input, outputPrice=outputPrice
            });
        }
        return output.OrderBy(x=>x.displayName,StringComparer.OrdinalIgnoreCase).ThenBy(x=>x.id,StringComparer.OrdinalIgnoreCase).ToList();
    }

    static string? Str(JsonElement x,string name) => x.TryGetProperty(name,out var v) && v.ValueKind==JsonValueKind.String ? v.GetString() : null;
    static long? Long(JsonElement x,string name) => x.TryGetProperty(name,out var v) && v.TryGetInt64(out var n) ? n : null;
    static bool? Bool(JsonElement x,string name) => x.TryGetProperty(name,out var v) ? v.ValueKind switch { JsonValueKind.True=>true, JsonValueKind.False=>false, _=>null } : null;
    static double? Double(JsonElement x,string name)
    {
        if (!x.TryGetProperty(name,out var v)) return null;
        if (v.ValueKind==JsonValueKind.Number && v.TryGetDouble(out var n)) return n;
        if (v.ValueKind==JsonValueKind.String && double.TryParse(v.GetString(),System.Globalization.NumberStyles.Float,System.Globalization.CultureInfo.InvariantCulture,out n)) return n;
        return null;
    }
}

static class ApiConnectionsUiBootstrap
{
    static bool _installed;
    static ApiConnectionsPage? _page;
    [ModuleInitializer] public static void Initialize() => Application.Idle += Install;
    public static void RefreshProjectMarkers() => _page?.RefreshProjectMarkers();
    static void Install(object? sender, EventArgs e)
    {
        if (_installed) return;
        foreach (Form form in Application.OpenForms)
        {
            var tabs = Find<TabControl>(form).FirstOrDefault();
            if (tabs is null) continue;
            _page = new ApiConnectionsPage();
            tabs.TabPages.Add(_page);
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
    readonly DataGridView _connections = new();
    readonly DataGridView _models = new();
    readonly Label _summary = new();
    Dictionary<string,ApiConnectionProfile> _profiles = new(StringComparer.OrdinalIgnoreCase);

    public ApiConnectionsPage() : base("Connections")
    {
        Padding=new Padding(12); BackColor=Theme.Back; ForeColor=Theme.Text;
        var rows=new TableLayoutPanel{Dock=DockStyle.Fill,RowCount=5,ColumnCount=1};
        rows.RowStyles.Add(new RowStyle(SizeType.Absolute,42));
        rows.RowStyles.Add(new RowStyle(SizeType.Percent,42));
        rows.RowStyles.Add(new RowStyle(SizeType.Absolute,32));
        rows.RowStyles.Add(new RowStyle(SizeType.Percent,58));
        rows.RowStyles.Add(new RowStyle(SizeType.Absolute,42));

        var bar=new FlowLayoutPanel{Dock=DockStyle.Fill,WrapContents=false};
        bar.Controls.Add(Make("Add connection",Add,125));
        bar.Controls.Add(Make("Edit",Edit,80));
        bar.Controls.Add(Make("Test & refresh",TestSelected,120));
        bar.Controls.Add(Make("Remove",Remove,85));
        bar.Controls.Add(Make("Setup help",SetupHelp,95));
        _summary.AutoSize=true;_summary.Margin=new Padding(12,11,0,0);_summary.ForeColor=Theme.Muted;bar.Controls.Add(_summary);
        rows.Controls.Add(bar,0,0);

        ConfigureConnectionGrid(); rows.Controls.Add(_connections,0,1);
        rows.Controls.Add(SectionLabel("DISCOVERED MODELS / ACTIVE PROJECT TARGET POOL"),0,2);
        ConfigureModelGrid(); rows.Controls.Add(_models,0,3);

        var bottom=new FlowLayoutPanel{Dock=DockStyle.Fill,WrapContents=false};
        bottom.Controls.Add(Make("Save target selection",SaveTargetSelection,170));
        bottom.Controls.Add(Make("Auto-target free workhorses",AutoTargetFreeWorkhorses,205));
        var note=new Label{Text="Connections are machine-local. The endpoint catalog is project-local and is the scheduler's pseudo-round-robin workhorse set.",AutoSize=true,Margin=new Padding(12,11,0,0),ForeColor=Theme.Muted};
        bottom.Controls.Add(note);rows.Controls.Add(bottom,0,4);

        Controls.Add(rows); Theme.Apply(this); Reload();
    }

    static Label SectionLabel(string text)=>new(){Text=text,Dock=DockStyle.Fill,TextAlign=ContentAlignment.BottomLeft,ForeColor=Theme.Muted,Font=new Font("Segoe UI Semibold",8,FontStyle.Bold)};
    static Button Make(string text,EventHandler click,int width=130){var b=new Button{Text=text,Width=width,Height=32,Margin=new Padding(0,4,8,0)};b.Click+=click;return b;}

    void ConfigureConnectionGrid()
    {
        _connections.Dock=DockStyle.Fill;_connections.ReadOnly=true;_connections.AllowUserToAddRows=false;_connections.RowHeadersVisible=false;_connections.SelectionMode=DataGridViewSelectionMode.FullRowSelect;_connections.MultiSelect=false;_connections.AutoSizeColumnsMode=DataGridViewAutoSizeColumnsMode.Fill;
        _connections.Columns.Add("id","Connection");_connections.Columns.Add("preset","Service");_connections.Columns.Add("url","Base URL");_connections.Columns.Add("models","Models");_connections.Columns.Add("health","Health");_connections.Columns.Add("tested","Last tested");
        _connections.SelectionChanged+=(_,_)=>LoadModels();
    }

    void ConfigureModelGrid()
    {
        _models.Dock=DockStyle.Fill;_models.AllowUserToAddRows=false;_models.RowHeadersVisible=false;_models.SelectionMode=DataGridViewSelectionMode.FullRowSelect;_models.AutoSizeColumnsMode=DataGridViewAutoSizeColumnsMode.Fill;
        _models.Columns.Add(new DataGridViewCheckBoxColumn{Name="use",HeaderText="Target",Width=58,AutoSizeMode=DataGridViewAutoSizeColumnMode.None});
        _models.Columns.Add("name","Model");_models.Columns.Add("id","Model ID");_models.Columns.Add("state","Current project target");_models.Columns.Add("tools","Tools");_models.Columns.Add("context","Context");_models.Columns.Add("free","Free");
        foreach(DataGridViewColumn c in _models.Columns) if(c.Name!="use") c.ReadOnly=true;
    }

    string? SelectedId=>_connections.SelectedRows.Count>0?_connections.SelectedRows[0].Cells["id"].Value?.ToString():null;

    void Reload(string? select=null)
    {
        _profiles=ApiConnectionStore.Load();_connections.Rows.Clear();
        foreach(var kv in _profiles.OrderBy(x=>x.Key,StringComparer.OrdinalIgnoreCase))
        {
            var p=kv.Value;var preset=InferencePresets.Get(p.presetId);
            var i=_connections.Rows.Add(kv.Key,preset.DisplayName,p.baseUrl,p.models.Count,p.health,p.lastTestAt is null?"—":FormatTime(p.lastTestAt));
            _connections.Rows[i].Tag=p;
            if(string.Equals(p.health,"healthy",StringComparison.OrdinalIgnoreCase))_connections.Rows[i].Cells["health"].Style.ForeColor=Theme.Good;
            else if(string.Equals(p.health,"failed",StringComparison.OrdinalIgnoreCase))_connections.Rows[i].Cells["health"].Style.ForeColor=Theme.Error;
        }
        var pool=TargetPoolStore.LoadActive();
        _summary.Text=$"{_profiles.Count} connection(s) • {pool.entries.Count} enabled endpoint(s)";
        if(_connections.Rows.Count>0)
        {
            var row=_connections.Rows.Cast<DataGridViewRow>().FirstOrDefault(x=>string.Equals(x.Cells["id"].Value?.ToString(),select,StringComparison.OrdinalIgnoreCase))??_connections.Rows[0];
            row.Selected=true;
        }
        LoadModels();
    }

    static string FormatTime(string text)=>DateTimeOffset.TryParse(text,out var dto)?dto.ToLocalTime().ToString("MM-dd HH:mm"):"—";

    void LoadModels()
    {
        _models.Rows.Clear();var id=SelectedId;if(id is null||!_profiles.TryGetValue(id,out var p))return;
        var pool=TargetPoolStore.LoadActive();
        foreach(var m in p.models)
        {
            var context=m.contextLength.HasValue?m.contextLength.Value.ToString("N0"):"—";
            var free=m.isFree==true?"yes":m.isFree==false?"no":"?";
            var targeted=pool.entries.TryGetValue(TargetPoolStore.Id(id,m.id),out var entry);
            var state=!targeted?"—":entry!.enabled?"enabled":"disabled";
            var row=_models.Rows.Add(targeted,m.displayName,m.id,state,m.supportsTools==false?"text":"native",context,free);
            if(targeted)_models.Rows[row].Cells["state"].Style.ForeColor=entry!.enabled?Theme.Good:Theme.Muted;
        }
    }

    public void RefreshProjectMarkers() => LoadModels();

    void Add(object? s,EventArgs e)
    {
        using var d=new ApiConnectionDialog();
        if(d.ShowDialog(FindForm())!=DialogResult.OK)return;
        _profiles[d.ConnectionId]=d.Profile;ApiConnectionStore.Save(_profiles);Reload(d.ConnectionId);
    }

    void Edit(object? s,EventArgs e)
    {
        var id=SelectedId;if(id is null||!_profiles.TryGetValue(id,out var p))return;
        using var d=new ApiConnectionDialog(id,p);
        if(d.ShowDialog(FindForm())!=DialogResult.OK)return;
        _profiles.Remove(id);_profiles[d.ConnectionId]=d.Profile;ApiConnectionStore.Save(_profiles);Reload(d.ConnectionId);
    }

    async void TestSelected(object? s,EventArgs e)
    {
        var id=SelectedId;if(id is null||!_profiles.TryGetValue(id,out var p))return;
        _summary.Text="Testing and discovering models…";
        var result=await ApiConnectionTester.TestAndDiscoverAsync(p);
        p.lastTestAt=DateTimeOffset.UtcNow.ToString("O");p.health=result.Success?"healthy":"failed";p.lastError=result.Success?null:result.Message;
        if(result.Success)p.models=result.Models;
        _profiles[id]=p;ApiConnectionStore.Save(_profiles);Reload(id);
        MessageBox.Show(FindForm(),result.Message,result.Success?"Connection healthy":"Connection test failed",MessageBoxButtons.OK,result.Success?MessageBoxIcon.Information:MessageBoxIcon.Warning);
    }

    void Remove(object? s,EventArgs e)
    {
        var id=SelectedId;if(id is null)return;
        if(MessageBox.Show(FindForm(),$"Remove machine connection '{id}'? Endpoint catalog rows that reference it will remain visible to Clanker but cannot route until the connection is restored or those rows are removed.","Remove connection",MessageBoxButtons.YesNo,MessageBoxIcon.Warning)!=DialogResult.Yes)return;
        _profiles.Remove(id);ApiConnectionStore.Save(_profiles);Reload();
    }

    void SetupHelp(object? s,EventArgs e)
    {
        var id=SelectedId;if(id is null||!_profiles.TryGetValue(id,out var p))return;var preset=InferencePresets.Get(p.presetId);
        var choice=MessageBox.Show(FindForm(),$"{preset.FreeLabel}\r\n\r\n{preset.Instructions}\r\n\r\nOpen the provider setup page?","Setup: "+preset.DisplayName,MessageBoxButtons.YesNo,MessageBoxIcon.Information);
        if(choice==DialogResult.Yes&&!string.IsNullOrWhiteSpace(preset.SetupUrl))try{Process.Start(new ProcessStartInfo(preset.SetupUrl){UseShellExecute=true});}catch{}
    }

    void SaveTargetSelection(object? s,EventArgs e)
    {
        var connection=SelectedId;if(connection is null)return;
        if(false){}
        try
        {
            var pool=TargetPoolStore.LoadActive();
            var p=_profiles[connection];
            foreach(DataGridViewRow row in _models.Rows)
            {
                var modelId=row.Cells["id"].Value?.ToString();if(string.IsNullOrWhiteSpace(modelId))continue;
                var key=TargetPoolStore.Id(connection,modelId);
                var selected=Convert.ToBoolean(row.Cells["use"].Value??false);
                if(!selected){pool.entries.Remove(key);continue;}
                var model=p.models.FirstOrDefault(x=>string.Equals(x.id,modelId,StringComparison.OrdinalIgnoreCase));
                if(model is null)continue;
                if(!pool.entries.TryGetValue(key,out var entry))entry=new TargetPoolEntry{id=key,connection=connection,model=model.id,source="user"};
                entry.displayName=model.displayName;entry.enabled=true;entry.workhorse=true;entry.free=model.isFree;entry.supportsTools=model.supportsTools;
                entry.contextLength=model.contextLength;entry.toolMode=model.supportsTools==false?"text":"native";entry.updatedAt=DateTimeOffset.UtcNow.ToString("O");
                if(string.IsNullOrWhiteSpace(entry.rationale))entry.rationale="Selected by the operator from the discovered connection catalog.";
                pool.entries[key]=entry;
            }
            TargetPoolStore.SaveActive(pool);Reload(connection);
        }
        catch(Exception ex){MessageBox.Show(FindForm(),ex.Message,"Could not save endpoint catalog",MessageBoxButtons.OK,MessageBoxIcon.Error);}
    }

    void AutoTargetFreeWorkhorses(object? s,EventArgs e)
    {
        if(false){}
        try
        {
            var pool=TargetPoolStore.LoadActive();var added=0;
            foreach(var kv in _profiles)
            {
                var connection=kv.Key;var p=kv.Value;var preset=InferencePresets.Get(p.presetId);
                var candidates=p.models
                    .Where(m => IsSafeFreeCandidate(preset,m) && IsLikelyWorkhorse(m))
                    .OrderByDescending(WorkhorseScore)
                    .ThenBy(m=>m.displayName,StringComparer.OrdinalIgnoreCase)
                    .Take(6)
                    .ToList();
                foreach(var model in candidates)
                {
                    var key=TargetPoolStore.Id(connection,model.id);
                    if(pool.entries.TryGetValue(key,out var existing))
                    {
                        existing.displayName=model.displayName;existing.free=model.isFree;existing.supportsTools=model.supportsTools;existing.contextLength=model.contextLength;
                        existing.toolMode=model.supportsTools==false?"text":"native";existing.updatedAt=DateTimeOffset.UtcNow.ToString("O");pool.entries[key]=existing;continue;
                    }
                    pool.entries[key]=new TargetPoolEntry{
                        id=key,connection=connection,model=model.id,displayName=model.displayName,enabled=true,workhorse=true,free=model.isFree,
                        supportsTools=model.supportsTools,contextLength=model.contextLength,toolMode=model.supportsTools==false?"text":"native",
                        source="auto-seed",rationale=$"Seeded from {preset.DisplayName} as a likely free/local bounded-work workhorse. Clanker should briefly research and prune/update this row when model availability or quota changes.",
                        updatedAt=DateTimeOffset.UtcNow.ToString("O")
                    };added++;
                }
            }
            TargetPoolStore.SaveActive(pool);Reload(SelectedId);
            MessageBox.Show(FindForm(),$"Seeded {added} new endpoint(s). Existing user/Clanker choices were preserved.");
        }
        catch(Exception ex){MessageBox.Show(FindForm(),ex.Message,"Could not auto-target models",MessageBoxButtons.OK,MessageBoxIcon.Error);}
    }

    static bool IsSafeFreeCandidate(InferencePreset preset,ApiDiscoveredModel model)
    {
        if(preset.Id is "ollama" or "lmstudio" or "vllm")return true;
        if(model.isFree==true)return true;
        if(model.isFree==false)return false;
        var id=(model.id+" "+model.displayName).ToLowerInvariant();
        if(id.Contains(":free")||id.Contains("/free")||id.Contains("auto:free")||id.Contains("free/"))return true;
        // FreeLLMAPI intentionally exposes a curated free catalog. Other providers
        // with mixed paid/free catalogs stay out until model metadata or research
        // positively identifies a zero-cost route.
        return preset.Id is "freellmapi";
    }

    static bool IsLikelyWorkhorse(ApiDiscoveredModel model)
    {
        if(model.supportsTools==false)return false;
        var id=(model.id+" "+model.displayName).ToLowerInvariant();
        string[] reject={"embedding","embed-","rerank","whisper","speech","audio","tts","image","flux","stable-diffusion","video","moderation"};
        if(reject.Any(id.Contains))return false;
        if(model.contextLength.HasValue && model.contextLength.Value<16000)return false;
        return true;
    }

    static int WorkhorseScore(ApiDiscoveredModel model)
    {
        var score=0;var id=(model.id+" "+model.displayName).ToLowerInvariant();
        if(model.isFree==true)score+=8;
        if(model.supportsTools==true)score+=8;else if(model.supportsTools is null)score+=2;
        if(model.contextLength>=131072)score+=4;else if(model.contextLength>=32768)score+=3;else if(model.contextLength>=16000)score+=1;
        string[] useful={"coder","code","devstral","codestral","qwen","gpt-oss","flash","instruct","llama","gemma","mistral","glm"};
        if(useful.Any(id.Contains))score+=3;
        if(id.Contains(":free")||id.Contains("/free")||id.Contains("auto:free"))score+=4;
        if(id.Contains("vision")||id.Contains("vl"))score-=1;
        return score;
    }

    static string SafeId(string text)
    {
        var sb=new StringBuilder();foreach(var ch in text.ToLowerInvariant()){if(char.IsLetterOrDigit(ch))sb.Append(ch);else if(sb.Length>0&&sb[^1]!='-')sb.Append('-');}
        var s=sb.ToString().Trim('-');if(s.Length>55)s=s[..55].TrimEnd('-');return string.IsNullOrWhiteSpace(s)?"endpoint":s;
    }
}

sealed class ApiConnectionDialog : Form
{
    readonly ComboBox _preset=new(){DropDownStyle=ComboBoxStyle.DropDownList};
    readonly TextBox _id=new(),_url=new(),_account=new(),_key=new(),_env=new(),_headers=new(),_instructions=new(),_status=new();
    readonly DataGridView _models=new();
    readonly Button _save=new(){Text="Save connection",Width=120,Enabled=false},_test=new(){Text="Test & discover",Width=120};
    readonly ApiConnectionProfile? _previous;
    ApiConnectionProfile? _tested;

    public string ConnectionId=>_id.Text.Trim();
    public ApiConnectionProfile Profile=>_tested??throw new InvalidOperationException("Connection was not validated.");

    public ApiConnectionDialog(string? id=null,ApiConnectionProfile? current=null)
    {
        _previous=current;Text=current is null?"Add inference connection":"Edit inference connection";Width=820;Height=720;MinimumSize=new Size(720,620);StartPosition=FormStartPosition.CenterParent;
        var root=new TableLayoutPanel{Dock=DockStyle.Fill,ColumnCount=1,RowCount=2,Padding=new Padding(14)};
        root.RowStyles.Add(new RowStyle(SizeType.Percent,100));root.RowStyles.Add(new RowStyle(SizeType.Absolute,46));

        var split=new QuietSplitContainer(Orientation.Horizontal){Panel1MinSize=150,Panel2MinSizePending=120,ResetDistance=350};
        var setupScroll=new Panel{Dock=DockStyle.Fill,AutoScroll=true,BackColor=Theme.Back};
        var form=new TableLayoutPanel{Dock=DockStyle.Top,AutoSize=true,AutoSizeMode=AutoSizeMode.GrowAndShrink,ColumnCount=2,RowCount=8};form.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute,155));form.ColumnStyles.Add(new ColumnStyle(SizeType.Percent,100));
        foreach(var p in InferencePresets.All)_preset.Items.Add(p);_preset.DisplayMember=nameof(InferencePreset.DisplayName);
        Add(form,0,"Service preset",_preset);Add(form,1,"Connection name",_id);Add(form,2,"Base URL",_url);Add(form,3,"Account ID",_account);Add(form,4,"API key",_key);_key.UseSystemPasswordChar=true;Add(form,5,"API key env",_env);Add(form,6,"Extra headers",_headers);_headers.PlaceholderText="Header: value; Header2: value";
        _instructions.Multiline=true;_instructions.ReadOnly=true;_instructions.ScrollBars=ScrollBars.Vertical;_instructions.Height=82;Add(form,7,"Setup instructions",_instructions,82);
        setupScroll.Controls.Add(form);split.Panel1.Controls.Add(setupScroll);

        _models.Dock=DockStyle.Fill;_models.ReadOnly=true;_models.AllowUserToAddRows=false;_models.RowHeadersVisible=false;_models.AutoSizeColumnsMode=DataGridViewAutoSizeColumnsMode.Fill;
        _models.Columns.Add("name","Discovered model");_models.Columns.Add("id","Model ID");_models.Columns.Add("tools","Tools");_models.Columns.Add("context","Context");split.Panel2.Controls.Add(_models);
        root.Controls.Add(split,0,0);
        Shown+=(_,_)=>BeginInvoke(new Action(()=>split.RestoreDistance(350)));

        var bar=new FlowLayoutPanel{Dock=DockStyle.Fill,FlowDirection=FlowDirection.RightToLeft,WrapContents=false};
        var cancel=new Button{Text="Cancel",DialogResult=DialogResult.Cancel,Width=90};_save.DialogResult=DialogResult.OK;bar.Controls.Add(cancel);bar.Controls.Add(_save);bar.Controls.Add(_test);
        _status.ReadOnly=true;_status.BorderStyle=BorderStyle.None;_status.Width=350;_status.Margin=new Padding(0,9,10,0);bar.Controls.Add(_status);root.Controls.Add(bar,0,1);
        Controls.Add(root);AcceptButton=_save;CancelButton=cancel;

        _preset.SelectedIndexChanged+=(_,_)=>ApplyPreset();
        _test.Click+=async(_,_)=>await TestAsync();
        _save.Click+=(_,e)=>{if(_tested is null){DialogResult=DialogResult.None;MessageBox.Show(this,"Test and discover models before saving.");}};
        foreach(Control c in new Control[]{_id,_url,_account,_key,_env,_headers}) c.TextChanged+=(_,_)=>InvalidateTest();

        if(current is null){_preset.SelectedItem=InferencePresets.All[0];ApplyPreset();}
        else
        {
            _preset.SelectedItem=InferencePresets.Get(current.presetId);_id.Text=id??current.name;_url.Text=current.baseUrl;_account.Text=current.accountId??"";_env.Text=current.apiKeyEnv??"";_headers.Text=string.Join("; ",current.headers.Select(x=>$"{x.Key}: {x.Value}"));ApplyPreset(false);
            _instructions.Text=InferencePresets.Get(current.presetId).Instructions;
        }
        Theme.Apply(this);
    }

    static void Add(TableLayoutPanel t,int row,string label,Control c,int height=40)
    {
        t.RowStyles.Add(new RowStyle(SizeType.Absolute,height));t.Controls.Add(new Label{Text=label,Dock=DockStyle.Fill,TextAlign=ContentAlignment.MiddleLeft,ForeColor=Theme.Muted},0,row);c.Dock=DockStyle.Fill;c.Margin=new Padding(0,5,0,5);t.Controls.Add(c,1,row);
    }

    void ApplyPreset(bool overwrite=true)
    {
        if(_preset.SelectedItem is not InferencePreset p)return;
        var custom=string.Equals(p.Id,"custom",StringComparison.OrdinalIgnoreCase);
        if(overwrite||string.IsNullOrWhiteSpace(_url.Text))_url.Text=p.BaseUrlTemplate;
        if(overwrite||string.IsNullOrWhiteSpace(_headers.Text))_headers.Text=p.DefaultHeaders;
        _url.ReadOnly=!custom;_url.Enabled=custom;_url.PlaceholderText=custom?"required":"managed by provider preset";
        _headers.ReadOnly=!custom;_headers.Enabled=custom;_headers.PlaceholderText=custom?"Header: value; Header2: value":"managed by provider preset";
        _env.Enabled=custom;_env.PlaceholderText=custom?"optional":"managed by provider preset";
        _account.Enabled=p.RequiresAccountId||custom;_account.PlaceholderText=p.RequiresAccountId?"required":custom?"optional":"not used";
        _key.Enabled=p.RequiresApiKey||custom;_key.PlaceholderText=p.RequiresApiKey?p.KeyPlaceholder:custom?"optional":"not required";
        _instructions.Text=$"{p.FreeLabel}\r\n\r\n{p.Instructions}";
        InvalidateTest();
    }

    void InvalidateTest(){_tested=null;_save.Enabled=false;_status.Text="Not validated";_status.ForeColor=Theme.Muted;}

    ApiConnectionProfile BuildProfile()
    {
        if(_preset.SelectedItem is not InferencePreset preset)throw new Exception("Select a service preset.");
        if(string.IsNullOrWhiteSpace(_id.Text))throw new Exception("Connection name is required.");
        if(string.IsNullOrWhiteSpace(_url.Text))throw new Exception("Base URL is required.");
        if(preset.RequiresAccountId&&string.IsNullOrWhiteSpace(_account.Text))throw new Exception("This service requires an Account ID.");
        var custom=string.Equals(preset.Id,"custom",StringComparison.OrdinalIgnoreCase);
        var headers=new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase);
        var headerText=custom?_headers.Text:preset.DefaultHeaders;
        foreach(var part in headerText.Split(';',StringSplitOptions.RemoveEmptyEntries|StringSplitOptions.TrimEntries)){var i=part.IndexOf(':');if(i>0)headers[part[..i].Trim()]=part[(i+1)..].Trim();}
        var baseTemplate=custom?_url.Text.Trim().TrimEnd('/'):preset.BaseUrlTemplate;
        var p=new ApiConnectionProfile{
            name=_id.Text.Trim(),presetId=preset.Id,protocol=preset.Protocol,authKind=preset.AuthKind,
            baseUrl=InferencePresets.Expand(baseTemplate, string.IsNullOrWhiteSpace(_account.Text)?null:_account.Text.Trim()),
            modelsPath=preset.ModelsPathTemplate,discoveryKind=preset.DiscoveryKind,accountId=string.IsNullOrWhiteSpace(_account.Text)?null:_account.Text.Trim(),
            apiKeyEnv=custom&& !string.IsNullOrWhiteSpace(_env.Text)?_env.Text.Trim():null,headers=headers,toolModeDefault="native"
        };
        if(preset.RequiresApiKey && string.IsNullOrWhiteSpace(_key.Text) && (_previous is null || string.IsNullOrWhiteSpace(_previous.apiKeyProtected)))throw new Exception("This service requires an API key.");
        if(!string.IsNullOrWhiteSpace(_key.Text))p.apiKeyProtected=ApiConnectionStore.Protect(_key.Text.Trim());
        else if(_previous is not null)p.apiKeyProtected=_previous.apiKeyProtected;
        return p;
    }

    async Task TestAsync()
    {
        ApiConnectionProfile p;try{p=BuildProfile();}catch(Exception ex){MessageBox.Show(this,ex.Message);return;}
        _test.Enabled=false;_status.Text="Authenticating and discovering models…";_status.ForeColor=Theme.Accent;
        var raw=string.IsNullOrWhiteSpace(_key.Text)?null:_key.Text.Trim();
        var result=await ApiConnectionTester.TestAndDiscoverAsync(p,raw);
        p.lastTestAt=DateTimeOffset.UtcNow.ToString("O");p.health=result.Success?"healthy":"failed";p.lastError=result.Success?null:result.Message;
        _models.Rows.Clear();
        if(result.Success)
        {
            p.models=result.Models;_tested=p;_save.Enabled=true;_status.Text=result.Message;_status.ForeColor=Theme.Good;
            foreach(var m in result.Models)_models.Rows.Add(m.displayName,m.id,m.supportsTools==false?"text":"native",m.contextLength?.ToString("N0")??"—");
        }
        else{_tested=null;_save.Enabled=false;_status.Text="Test failed";_status.ForeColor=Theme.Error;MessageBox.Show(this,result.Message,"Connection test failed",MessageBoxButtons.OK,MessageBoxIcon.Warning);}
        _test.Enabled=true;
    }
}

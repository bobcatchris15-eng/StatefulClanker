using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Windows.Forms;

namespace StatefulClanker.Tray;

sealed class ProjectEndpointStatus
{
    public string Name="";
    public string Type="";
    public string Connection="";
    public string Model="";
    public string Command="";
    public string Health="";
    public string Roles="";
    public bool Disabled;
    public int Priority=100;
}

static class EndpointsRoutingUiBootstrap
{
    static bool _installed;
    [ModuleInitializer] public static void Initialize()=>Application.Idle+=Install;
    static void Install(object? sender,EventArgs e)
    {
        if(_installed)return;
        foreach(Form form in Application.OpenForms)
        {
            var tabs=Find<TabControl>(form).FirstOrDefault();if(tabs is null)continue;
            var page=tabs.TabPages.Cast<TabPage>().FirstOrDefault(x=>string.Equals(x.Text,"Providers",StringComparison.OrdinalIgnoreCase));
            if(page is null)continue;
            page.Text="Endpoints & Routing";page.Controls.Clear();page.Padding=new Padding(12);page.Controls.Add(new EndpointsRoutingPanel(form));_installed=true;break;
        }
    }
    static IEnumerable<T> Find<T>(Control root) where T:Control{foreach(Control c in root.Controls){if(c is T t)yield return t;foreach(var x in Find<T>(c))yield return x;}}
}

sealed class EndpointsRoutingPanel : UserControl
{
    readonly Form _owner;
    readonly DataGridView _grid=new();
    readonly Label _summary=new();
    readonly System.Windows.Forms.Timer _timer=new(){Interval=2500};
    string? _project;
    bool _loading;

    public EndpointsRoutingPanel(Form owner)
    {
        _owner=owner;Dock=DockStyle.Fill;BackColor=Theme.Back;ForeColor=Theme.Text;
        var rows=new TableLayoutPanel{Dock=DockStyle.Fill,RowCount=5,ColumnCount=1};
        rows.RowStyles.Add(new RowStyle(SizeType.Absolute,42));rows.RowStyles.Add(new RowStyle(SizeType.Absolute,42));rows.RowStyles.Add(new RowStyle(SizeType.Absolute,30));rows.RowStyles.Add(new RowStyle(SizeType.Percent,100));rows.RowStyles.Add(new RowStyle(SizeType.Absolute,28));

        var bar=new FlowLayoutPanel{Dock=DockStyle.Fill,WrapContents=false};
        bar.Controls.Add(Btn("Add CLI endpoint",AddCli,125));bar.Controls.Add(Btn("Test endpoint",TestSelected,105));bar.Controls.Add(Btn("Remove endpoint",RemoveSelected,115));bar.Controls.Add(Btn("Open config",OpenConfig,95));bar.Controls.Add(Btn("Refresh",(_,_)=>Reload(),80));
        _summary.AutoSize=true;_summary.Margin=new Padding(12,11,0,0);_summary.ForeColor=Theme.Muted;bar.Controls.Add(_summary);rows.Controls.Add(bar,0,0);

        var role=new FlowLayoutPanel{Dock=DockStyle.Fill,WrapContents=false};
        role.Controls.Add(Label("Preferred:"));role.Controls.Add(Btn("Default",(_,_)=>SetRole("defaultProvider"),75));role.Controls.Add(Btn("Critic",(_,_)=>SetRole("criticProvider"),70));role.Controls.Add(Btn("Validator",(_,_)=>SetRole("validatorProvider"),80));
        role.Controls.Add(Label("Size:",12));role.Controls.Add(Btn("Tiny",(_,_)=>SetRole("tiny"),55));role.Controls.Add(Btn("Small",(_,_)=>SetRole("small"),60));role.Controls.Add(Btn("Medium",(_,_)=>SetRole("medium"),70));role.Controls.Add(Btn("Large",(_,_)=>SetRole("large"),60));role.Controls.Add(Btn("Clear roles",(_,_)=>ClearRoles(),85));rows.Controls.Add(role,0,1);

        rows.Controls.Add(new Label{Text="PROJECT ENDPOINTS — priority is the failover order after the preferred route",Dock=DockStyle.Fill,TextAlign=ContentAlignment.BottomLeft,ForeColor=Theme.Muted,Font=new Font("Segoe UI Semibold",8,FontStyle.Bold)},0,2);
        ConfigureGrid();rows.Controls.Add(_grid,0,3);
        rows.Controls.Add(new Label{Text="API endpoints are connection + model pairs. Machine credentials live on Connections; this page only controls what the active project may route to.",Dock=DockStyle.Fill,ForeColor=Theme.Muted,Font=new Font("Segoe UI",8.25f),TextAlign=ContentAlignment.MiddleLeft},0,4);
        Controls.Add(rows);Theme.Apply(this);Reload();_timer.Tick+=(_,_)=>Reload();_timer.Start();
    }

    static Button Btn(string text,EventHandler click,int width){var b=new Button{Text=text,Width=width,Height=32,Margin=new Padding(0,4,8,0)};b.Click+=click;return b;}
    static Label Label(string text,int left=4)=>new(){Text=text,AutoSize=true,Margin=new Padding(left,10,4,0),ForeColor=Theme.Muted};

    void ConfigureGrid()
    {
        _grid.Dock=DockStyle.Fill;_grid.AllowUserToAddRows=false;_grid.RowHeadersVisible=false;_grid.SelectionMode=DataGridViewSelectionMode.FullRowSelect;_grid.MultiSelect=false;_grid.AutoSizeColumnsMode=DataGridViewAutoSizeColumnsMode.Fill;
        _grid.Columns.Add(new DataGridViewCheckBoxColumn{Name="enabled",HeaderText="Enabled",Width=60,AutoSizeMode=DataGridViewAutoSizeColumnMode.None});
        _grid.Columns.Add("name","Endpoint");_grid.Columns.Add("type","Type");_grid.Columns.Add("connection","Connection");_grid.Columns.Add("target","Model / command");_grid.Columns.Add("health","Health");_grid.Columns.Add("roles","Routing / roles");
        foreach(DataGridViewColumn c in _grid.Columns)if(c.Name!="enabled")c.ReadOnly=true;
        _grid.CurrentCellDirtyStateChanged+=(_,_)=>{if(_grid.IsCurrentCellDirty&&_grid.CurrentCell?.ColumnIndex==0)_grid.CommitEdit(DataGridViewDataErrorContexts.Commit);};
        _grid.CellValueChanged+=(_,e)=>{if(!_loading&&e.RowIndex>=0&&e.ColumnIndex==0)Toggle(e.RowIndex,Convert.ToBoolean(_grid.Rows[e.RowIndex].Cells[0].Value));};

        _grid.AllowDrop=true;Rectangle dragBox=Rectangle.Empty;int dragIndex=-1;
        _grid.MouseDown+=(_,e)=>{var h=_grid.HitTest(e.X,e.Y);dragIndex=h.RowIndex;if(dragIndex>=0&&h.ColumnIndex!=0){var s=SystemInformation.DragSize;dragBox=new Rectangle(e.X-s.Width/2,e.Y-s.Height/2,s.Width,s.Height);}else dragBox=Rectangle.Empty;};
        _grid.MouseMove+=(_,e)=>{if((e.Button&MouseButtons.Left)!=0&&dragBox!=Rectangle.Empty&&!dragBox.Contains(e.X,e.Y))_grid.DoDragDrop(_grid.Rows[dragIndex],DragDropEffects.Move);};
        _grid.DragEnter+=(_,e)=>e.Effect=DragDropEffects.Move;
        _grid.DragDrop+=(_,e)=>{var p=_grid.PointToClient(new Point(e.X,e.Y));var h=_grid.HitTest(p.X,p.Y);if(h.RowIndex>=0&&dragIndex>=0&&h.RowIndex!=dragIndex)Reorder(dragIndex,h.RowIndex);};

        var menu=new ContextMenuStrip();
        menu.Items.Add("Set preferred default",null,(_,_)=>SetRole("defaultProvider"));menu.Items.Add("Set preferred critic",null,(_,_)=>SetRole("criticProvider"));menu.Items.Add("Set preferred validator",null,(_,_)=>SetRole("validatorProvider"));menu.Items.Add(new ToolStripSeparator());
        foreach(var s in new[]{"tiny","small","medium","large"}){var size=s;menu.Items.Add("Set for "+char.ToUpperInvariant(size[0])+size[1..]+" tasks",null,(_,_)=>SetRole(size));}
        menu.Items.Add(new ToolStripSeparator());menu.Items.Add("Test endpoint",null,TestSelected);menu.Items.Add("Remove endpoint",null,RemoveSelected);_grid.ContextMenuStrip=menu;
        _grid.CellMouseDown+=(_,e)=>{if(e.Button==MouseButtons.Right&&e.RowIndex>=0){_grid.ClearSelection();_grid.Rows[e.RowIndex].Selected=true;}};
    }

    string? CurrentProject()
    {
        try{if(!File.Exists(AppStore.ActiveProjectPointer))return null;var p=File.ReadAllText(AppStore.ActiveProjectPointer).Trim();return Directory.Exists(p)?p:null;}catch{return null;}
    }
    string? ConfigPath()=>_project is null?null:System.IO.Path.Combine(_project,".statefulclanker","config.json");
    ProjectEndpointStatus? Selected=>_grid.SelectedRows.Count>0?_grid.SelectedRows[0].Tag as ProjectEndpointStatus:null;

    void Reload()
    {
        var project=CurrentProject();if(!string.Equals(project,_project,StringComparison.OrdinalIgnoreCase))_project=project;
        var data=ReadEndpoints();_loading=true;_grid.SuspendLayout();
        try
        {
            var selected=Selected?.Name;_grid.Rows.Clear();
            foreach(var x in data)
            {
                var target=x.Type=="api"?x.Model:x.Command;var i=_grid.Rows.Add(!x.Disabled,x.Name,x.Type,x.Connection,target,x.Health,x.Roles);_grid.Rows[i].Tag=x;
                if(x.Disabled)_grid.Rows[i].DefaultCellStyle.ForeColor=Theme.Muted;
                if(x.Health.StartsWith("cooldown",StringComparison.OrdinalIgnoreCase)||x.Health.StartsWith("failed",StringComparison.OrdinalIgnoreCase))_grid.Rows[i].Cells["health"].Style.ForeColor=Theme.Warn;
                else if(x.Health=="healthy"||x.Health=="ready")_grid.Rows[i].Cells["health"].Style.ForeColor=Theme.Good;
                if(x.Name==selected)_grid.Rows[i].Selected=true;
            }
            _summary.Text=_project is null?"No active project":$"{data.Count} endpoint(s)";
        }
        finally{_grid.ResumeLayout();_loading=false;}
    }

    List<ProjectEndpointStatus> ReadEndpoints()
    {
        var result=new List<ProjectEndpointStatus>();var cfg=ConfigPath();if(cfg is null||!File.Exists(cfg))return result;
        var connections=ApiConnectionStore.Load();
        try
        {
            using var d=JsonDocument.Parse(File.ReadAllText(cfg));var root=d.RootElement;
            var def=root.TryGetProperty("defaultProvider",out var dv)?dv.GetString():null;var critic=root.TryGetProperty("criticProvider",out var cv)?cv.GetString():null;var validator=root.TryGetProperty("validatorProvider",out var vv)?vv.GetString():null;
            var sizes=new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase);if(root.TryGetProperty("providerBySize",out var by)&&by.ValueKind==JsonValueKind.Object)foreach(var x in by.EnumerateObject())if(x.Value.ValueKind==JsonValueKind.String)sizes[x.Name]=x.Value.GetString()??"";
            var routeHealth=ReadRouteHealth();
            if(!root.TryGetProperty("providers",out var providers)||providers.ValueKind!=JsonValueKind.Object)return result;
            var seq=1;
            foreach(var p in providers.EnumerateObject())
            {
                var v=p.Value;var type=v.TryGetProperty("type",out var tv)&&tv.ValueKind==JsonValueKind.String?tv.GetString()??"cli":"cli";
                var conn=v.TryGetProperty("connection",out var cn)&&cn.ValueKind==JsonValueKind.String?cn.GetString()??"":"";
                var model=v.TryGetProperty("model",out var md)&&md.ValueKind==JsonValueKind.String?md.GetString()??"":"";
                var cmd=v.TryGetProperty("command",out var cm)&&cm.ValueKind==JsonValueKind.String?cm.GetString()??"":"";
                var disabled=v.TryGetProperty("disabled",out var dis)&&dis.ValueKind==JsonValueKind.True;
                var pri=v.TryGetProperty("priority",out var pr)&&pr.TryGetInt32(out var n)?n:seq++*10;
                var roles=new List<string>();if(p.Name==def)roles.Add("default");if(p.Name==critic)roles.Add("critic");if(p.Name==validator)roles.Add("validator");foreach(var x in sizes.Where(x=>x.Value==p.Name))roles.Add(x.Key);
                var health=disabled?"disabled":"ready";
                if(type=="api")
                {
                    if(!connections.TryGetValue(conn,out var cp))health="missing connection";
                    else health=cp.health=="healthy"?"healthy":cp.health;
                }
                else if(!Runtime.CommandExists(cmd))health="missing command";
                if(routeHealth.TryGetValue(p.Name,out var rh))health=rh;
                if(type=="api" && !string.IsNullOrWhiteSpace(conn) && routeHealth.TryGetValue("connection:"+conn,out var connectionHealth) && connectionHealth!="ready")
                    health=connectionHealth+" [connection]";
                result.Add(new(){Name=p.Name,Type=type,Connection=conn,Model=model,Command=cmd,Disabled=disabled,Priority=pri,Roles=string.Join(", ",roles),Health=health});
            }
        }catch{}
        return result.OrderBy(x=>x.Priority).ThenBy(x=>x.Name,StringComparer.OrdinalIgnoreCase).ToList();
    }

    Dictionary<string,string> ReadRouteHealth()
    {
        var output=new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase);if(_project is null)return output;
        var path=System.IO.Path.Combine(_project,".statefulclanker","routing","health.json");if(!File.Exists(path))return output;
        try
        {
            using var d=JsonDocument.Parse(File.ReadAllText(path));if(!d.RootElement.TryGetProperty("endpoints",out var eps)||eps.ValueKind!=JsonValueKind.Object)return output;
            foreach(var p in eps.EnumerateObject())
            {
                var state=p.Value.TryGetProperty("state",out var s)?s.GetString():"";var reason=p.Value.TryGetProperty("reason",out var r)?r.GetString():"";var retry=p.Value.TryGetProperty("retryAfter",out var ra)?ra.GetString():null;
                if(state=="cooldown"&&DateTimeOffset.TryParse(retry,out var dto)&&dto>DateTimeOffset.UtcNow)output[p.Name]=$"cooldown: {reason} until {dto.ToLocalTime():HH:mm:ss}";
                else if(state=="cooldown")output[p.Name]="ready";
                else if(!string.IsNullOrWhiteSpace(state))output[p.Name]=string.IsNullOrWhiteSpace(reason)?state:$"{state}: {reason}";
            }
        }catch{}
        return output;
    }

    JsonObject? LoadConfig()
    {
        var path=ConfigPath();if(path is null||!File.Exists(path))return null;return JsonNode.Parse(File.ReadAllText(path))?.AsObject();
    }
    void SaveConfig(JsonObject root){var path=ConfigPath()??throw new Exception("No project config.");var tmp=path+".tmp";File.WriteAllText(tmp,root.ToJsonString(new JsonSerializerOptions{WriteIndented=true}),new UTF8Encoding(false));File.Move(tmp,path,true);Reload();}

    void Toggle(int row,bool enabled)
    {
        var status=_grid.Rows[row].Tag as ProjectEndpointStatus;var root=LoadConfig();if(status is null||root?["providers"] is not JsonObject eps||eps[status.Name] is not JsonObject ep)return;ep["disabled"]=!enabled;SaveConfig(root);
    }
    void Reorder(int from,int to)
    {
        var names=_grid.Rows.Cast<DataGridViewRow>().Select(x=>x.Cells["name"].Value?.ToString()).Where(x=>x is not null).Cast<string>().ToList();var item=names[from];names.RemoveAt(from);names.Insert(to,item);
        var root=LoadConfig();if(root?["providers"] is not JsonObject eps)return;for(var i=0;i<names.Count;i++)if(eps[names[i]] is JsonObject ep)ep["priority"]=(i+1)*10;SaveConfig(root);
    }
    void SetRole(string role)
    {
        var ep=Selected;var root=LoadConfig();if(ep is null||root is null)return;
        if(role is "tiny" or "small" or "medium" or "large"){var by=root["providerBySize"] as JsonObject??new JsonObject();root["providerBySize"]=by;by[role]=ep.Name;}
        else root[role]=ep.Name;SaveConfig(root);
    }
    void ClearRoles()
    {
        var ep=Selected;var root=LoadConfig();if(ep is null||root is null)return;
        foreach(var key in new[]{"defaultProvider","criticProvider","validatorProvider"})if(root[key]?.ToString()==ep.Name)root.Remove(key);
        if(root["providerBySize"] is JsonObject by)foreach(var s in new[]{"tiny","small","medium","large"})if(by[s]?.ToString()==ep.Name)by.Remove(s);SaveConfig(root);
    }

    void RemoveSelected(object? s,EventArgs e)
    {
        var ep=Selected;var root=LoadConfig();if(ep is null||root?["providers"] is not JsonObject eps)return;
        if(MessageBox.Show(_owner,$"Remove project endpoint '{ep.Name}'? Machine connection credentials are not removed.","Remove endpoint",MessageBoxButtons.YesNo,MessageBoxIcon.Warning)!=DialogResult.Yes)return;
        eps.Remove(ep.Name);foreach(var key in new[]{"defaultProvider","criticProvider","validatorProvider"})if(root[key]?.ToString()==ep.Name)root.Remove(key);
        if(root["providerBySize"] is JsonObject by)foreach(var size in new[]{"tiny","small","medium","large"})if(by[size]?.ToString()==ep.Name)by.Remove(size);SaveConfig(root);
    }

    void AddCli(object? s,EventArgs e)
    {
        using var d=new CliEndpointDialog();if(d.ShowDialog(_owner)!=DialogResult.OK)return;var root=LoadConfig();if(root is null)return;var eps=root["providers"] as JsonObject??new JsonObject();root["providers"]=eps;
        if(eps.ContainsKey(d.EndpointName)){MessageBox.Show(_owner,"An endpoint with that name already exists.");return;}
        var next=eps.Select(x=>x.Value is JsonObject o && o["priority"] is JsonValue v && v.TryGetValue<int>(out var n) ? n : 100).DefaultIfEmpty(0).Max()+10;
        var obj=new JsonObject{{"type","cli"},{"command",d.Command},{"mode",d.Mode},{"priority",next}};var args=new JsonArray();foreach(var a in d.Arguments)args.Add(a);obj["args"]=args;eps[d.EndpointName]=obj;SaveConfig(root);
    }

    void TestSelected(object? s,EventArgs e)
    {
        var ep=Selected;if(ep is null||_project is null)return;
        var harness=System.IO.Path.Combine(Runtime.FindRoot(),"mcp","StatefulClanker.McpCore.ps1");
        var command=$". '{harness.Replace("'","''")}'; Test-McpProvider '{_project.Replace("'","''")}' @{{ name='{ep.Name.Replace("'","''")}' }} | ConvertTo-Json -Depth 6 -Compress";
        var r=Runtime.RunPowerShell(Runtime.FindRoot(),"-Command",command);
        MessageBox.Show(_owner,(r.stdout+"\r\n"+r.stderr).Trim(),"Endpoint test",MessageBoxButtons.OK,r.code==0?MessageBoxIcon.Information:MessageBoxIcon.Warning);Reload();
    }
    void OpenConfig(object? s,EventArgs e){var p=ConfigPath();if(p is null||!File.Exists(p))return;try{System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("notepad.exe"){UseShellExecute=true,ArgumentList={p}});}catch{}}

    protected override void Dispose(bool disposing){if(disposing)_timer.Dispose();base.Dispose(disposing);}
}

sealed class CliEndpointDialog : Form
{
    readonly TextBox _name=new(),_command=new(),_args=new();readonly ComboBox _mode=new(){DropDownStyle=ComboBoxStyle.DropDownList};
    public string EndpointName=>_name.Text.Trim();public string Command=>_command.Text.Trim();public string Mode=>_mode.SelectedItem?.ToString()??"stdin";
    public string[] Arguments=>SplitArgs(_args.Text);

    public CliEndpointDialog()
    {
        Text="Add CLI endpoint";Width=620;Height=285;StartPosition=FormStartPosition.CenterParent;
        var t=new TableLayoutPanel{Dock=DockStyle.Fill,ColumnCount=2,RowCount=5,Padding=new Padding(14)};t.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute,135));t.ColumnStyles.Add(new ColumnStyle(SizeType.Percent,100));
        Add(t,0,"Endpoint name",_name);Add(t,1,"Command",_command);Add(t,2,"Arguments",_args);_args.PlaceholderText="Example: exec --prompt-file {promptFile}";Add(t,3,"Prompt mode",_mode);_mode.Items.AddRange(new object[]{"stdin","args"});_mode.SelectedIndex=0;
        var bar=new FlowLayoutPanel{Dock=DockStyle.Fill,FlowDirection=FlowDirection.RightToLeft};var ok=new Button{Text="Add",DialogResult=DialogResult.OK,Width=90};var cancel=new Button{Text="Cancel",DialogResult=DialogResult.Cancel,Width=90};bar.Controls.Add(cancel);bar.Controls.Add(ok);t.Controls.Add(bar,0,4);t.SetColumnSpan(bar,2);Controls.Add(t);AcceptButton=ok;CancelButton=cancel;
        ok.Click+=(_,_)=>{if(string.IsNullOrWhiteSpace(EndpointName)||string.IsNullOrWhiteSpace(Command)){MessageBox.Show(this,"Endpoint name and command are required.");DialogResult=DialogResult.None;}};
        Theme.Apply(this);
    }
    static void Add(TableLayoutPanel t,int row,string label,Control c){t.RowStyles.Add(new RowStyle(SizeType.Absolute,42));t.Controls.Add(new Label{Text=label,Dock=DockStyle.Fill,TextAlign=ContentAlignment.MiddleLeft,ForeColor=Theme.Muted},0,row);c.Dock=DockStyle.Fill;c.Margin=new Padding(0,5,0,5);t.Controls.Add(c,1,row);}
    static string[] SplitArgs(string text)
    {
        var result=new List<string>();var sb=new StringBuilder();var quote=false;
        foreach(var ch in text){if(ch=='"'){quote=!quote;continue;}if(char.IsWhiteSpace(ch)&&!quote){if(sb.Length>0){result.Add(sb.ToString());sb.Clear();}}else sb.Append(ch);}if(sb.Length>0)result.Add(sb.ToString());return result.ToArray();
    }
}

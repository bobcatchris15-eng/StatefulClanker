using System.Runtime.CompilerServices;
using System.Text.Json;
using System.Windows.Forms;

namespace StatefulClanker.Tray;

sealed class EndpointStatus
{
    public string Id="";
    public string Connection="";
    public string Model="";
    public string DisplayName="";
    public string Health="ready";
    public string Quota="-";
    public bool Enabled=true;
    public bool? Free;
    public bool? SupportsTools;
    public string? ManagedBy;
    public string? UserOverride;
    public string? RetiredReason;
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
            var page=tabs.TabPages.Cast<TabPage>().FirstOrDefault(x=>string.Equals(x.Text,"Providers",StringComparison.OrdinalIgnoreCase)||string.Equals(x.Text,"Endpoints & Routing",StringComparison.OrdinalIgnoreCase));
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
    bool _loading;

    public EndpointsRoutingPanel(Form owner)
    {
        _owner=owner;Dock=DockStyle.Fill;BackColor=Theme.Back;ForeColor=Theme.Text;
        var rows=new TableLayoutPanel{Dock=DockStyle.Fill,RowCount=4,ColumnCount=1};
        rows.RowStyles.Add(new RowStyle(SizeType.Absolute,42));rows.RowStyles.Add(new RowStyle(SizeType.Absolute,30));rows.RowStyles.Add(new RowStyle(SizeType.Percent,100));rows.RowStyles.Add(new RowStyle(SizeType.Absolute,42));

        var bar=new FlowLayoutPanel{Dock=DockStyle.Fill,WrapContents=false};
        bar.Controls.Add(Btn("Remove endpoint",RemoveSelected,115));bar.Controls.Add(Btn("Refresh",(_,_)=>Reload(),80));
        _summary.AutoSize=true;_summary.Margin=new Padding(12,11,0,0);_summary.ForeColor=Theme.Muted;bar.Controls.Add(_summary);rows.Controls.Add(bar,0,0);

        rows.Controls.Add(new Label{Text="MACHINE ENDPOINTS — fixed models use one lease; provider auto-routing pools may use up to five",Dock=DockStyle.Fill,TextAlign=ContentAlignment.BottomLeft,ForeColor=Theme.Muted,Font=new Font("Segoe UI Semibold",8,FontStyle.Bold)},0,1);
        ConfigureGrid();rows.Controls.Add(_grid,0,2);
        rows.Controls.Add(new Label{Text="The dispatcher submits tasks without choosing a model. The router walks healthy endpoint capacity round-robin; fixed models take one lease, while recognized provider auto-routing pools take up to five. The project worker cap remains the overall limit. Configure provider accounts and select models on Connections.",Dock=DockStyle.Fill,ForeColor=Theme.Muted,Font=new Font("Segoe UI",8.25f),TextAlign=ContentAlignment.MiddleLeft},0,3);
        Controls.Add(rows);Theme.Apply(this);Reload();_timer.Tick+=(_,_)=>Reload();_timer.Start();
    }

    static Button Btn(string text,EventHandler click,int width){var b=new Button{Text=text,Width=width,Height=32,Margin=new Padding(0,4,8,0)};b.Click+=click;return b;}

    void ConfigureGrid()
    {
        _grid.Dock=DockStyle.Fill;_grid.AllowUserToAddRows=false;_grid.RowHeadersVisible=false;_grid.SelectionMode=DataGridViewSelectionMode.FullRowSelect;_grid.MultiSelect=false;_grid.AutoSizeColumnsMode=DataGridViewAutoSizeColumnsMode.Fill;
        _grid.Columns.Add(new DataGridViewCheckBoxColumn{Name="enabled",HeaderText="Enabled",Width=60,AutoSizeMode=DataGridViewAutoSizeColumnMode.None});
        _grid.Columns.Add("name","Endpoint");_grid.Columns.Add("connection","Provider connection");_grid.Columns.Add("model","Model");_grid.Columns.Add("tools","Tools");_grid.Columns.Add("free","Free");_grid.Columns.Add("quota","Quota / reset");_grid.Columns.Add("health","Health");
        foreach(DataGridViewColumn c in _grid.Columns)if(c.Name!="enabled")c.ReadOnly=true;
        _grid.CurrentCellDirtyStateChanged+=(_,_)=>{if(_grid.IsCurrentCellDirty&&_grid.CurrentCell?.ColumnIndex==0)_grid.CommitEdit(DataGridViewDataErrorContexts.Commit);};
        _grid.CellValueChanged+=(_,e)=>{if(!_loading&&e.RowIndex>=0&&e.ColumnIndex==0)Toggle(e.RowIndex,Convert.ToBoolean(_grid.Rows[e.RowIndex].Cells[0].Value));};
        var menu=new ContextMenuStrip();menu.Items.Add("Remove endpoint",null,RemoveSelected);_grid.ContextMenuStrip=menu;
        _grid.CellMouseDown+=(_,e)=>{if(e.Button==MouseButtons.Right&&e.RowIndex>=0){_grid.ClearSelection();_grid.Rows[e.RowIndex].Selected=true;}};
    }

    EndpointStatus? Selected=>_grid.SelectedRows.Count>0?_grid.SelectedRows[0].Tag as EndpointStatus:null;

    void Reload()
    {
        var data=ReadEndpoints();_loading=true;_grid.SuspendLayout();
        try
        {
            var selected=Selected?.Id;_grid.Rows.Clear();
            foreach(var x in data)
            {
                var i=_grid.Rows.Add(x.Enabled,x.DisplayName,x.Connection,x.Model,x.SupportsTools==false?"text":"native",x.Free==true?"yes":x.Free==false?"no":"?",x.Quota,x.Health);_grid.Rows[i].Tag=x;
                if(!x.Enabled)_grid.Rows[i].DefaultCellStyle.ForeColor=Theme.Muted;
                if(x.Health.StartsWith("cooldown",StringComparison.OrdinalIgnoreCase)||x.Health.StartsWith("quarantined",StringComparison.OrdinalIgnoreCase))_grid.Rows[i].Cells["health"].Style.ForeColor=Theme.Warn;
                else if(x.Health=="healthy"||x.Health=="ready")_grid.Rows[i].Cells["health"].Style.ForeColor=Theme.Good;
                if(x.Id==selected)_grid.Rows[i].Selected=true;
            }
            _summary.Text=$"{data.Count(x=>x.Enabled)} enabled / {data.Count} endpoint(s)";
        }
        finally{_grid.ResumeLayout();_loading=false;}
    }

    sealed class RouteDisplay
    {
        public string Health="ready";
        public string Quota="-";
    }

    List<EndpointStatus> ReadEndpoints()
    {
        var pool=TargetPoolStore.LoadActive();var health=ReadRouteHealth();var result=new List<EndpointStatus>();
        foreach(var kv in pool.entries)
        {
            var e=kv.Value;var h="ready";var quota="-";
            health.TryGetValue("connection:"+e.connection,out var connectionHealth);
            if(health.TryGetValue("pool:"+kv.Key,out var endpointHealth))
            {
                h=endpointHealth.Health;
                quota=endpointHealth.Quota!="-"?endpointHealth.Quota:(connectionHealth?.Quota??"-");
            }
            else if(connectionHealth is not null)
            {
                h=connectionHealth.Health=="ready"?"ready":connectionHealth.Health+" [connection]";
                quota=connectionHealth.Quota;
            }
            if(!string.IsNullOrWhiteSpace(e.retiredReason) && !e.enabled)
                h="retired: "+e.retiredReason;
            result.Add(new EndpointStatus{Id=kv.Key,Connection=e.connection,Model=e.model,DisplayName=string.IsNullOrWhiteSpace(e.displayName)?e.model:e.displayName,Enabled=e.enabled,Free=e.free,SupportsTools=e.supportsTools,Health=h,Quota=quota,ManagedBy=e.managedBy,UserOverride=e.userOverride,RetiredReason=e.retiredReason});
        }
        return result.OrderBy(x=>x.Connection,StringComparer.OrdinalIgnoreCase).ThenBy(x=>x.Model,StringComparer.OrdinalIgnoreCase).ToList();
    }

    static Dictionary<string,RouteDisplay> ReadRouteHealth()
    {
        var output=new Dictionary<string,RouteDisplay>(StringComparer.OrdinalIgnoreCase);
        var path=System.IO.Path.Combine(AppStore.Root,"routing","health.json");if(!File.Exists(path))return output;
        try
        {
            using var d=JsonDocument.Parse(File.ReadAllText(path));if(!d.RootElement.TryGetProperty("endpoints",out var eps)||eps.ValueKind!=JsonValueKind.Object)return output;
            foreach(var p in eps.EnumerateObject())
            {
                var state=p.Value.TryGetProperty("state",out var s)?s.GetString():"";var reason=p.Value.TryGetProperty("reason",out var r)?r.GetString():"";var retry=p.Value.TryGetProperty("retryAfter",out var ra)?ra.GetString():null;
                var display=new RouteDisplay();
                if(state=="cooldown"&&DateTimeOffset.TryParse(retry,out var dto)&&dto>DateTimeOffset.UtcNow)display.Health=$"cooldown: {reason} until {dto.ToLocalTime():HH:mm:ss}";
                else if(state=="cooldown")display.Health="ready";
                else if(!string.IsNullOrWhiteSpace(state))display.Health=string.IsNullOrWhiteSpace(reason)?state:$"{state}: {reason}";

                if(p.Value.TryGetProperty("quota",out var q)&&q.ValueKind==JsonValueKind.Object)
                {
                    var status=q.TryGetProperty("status",out var qs)?qs.GetString():null;
                    var source=q.TryGetProperty("source",out var qso)?qso.GetString():null;
                    var probed=source?.StartsWith("probe:",StringComparison.OrdinalIgnoreCase)==true;
                    double? remaining=q.TryGetProperty("remaining",out var qr)&&qr.ValueKind==JsonValueKind.Number&&qr.TryGetDouble(out var rd)?rd:null;
                    double? limit=q.TryGetProperty("limit",out var ql)&&ql.ValueKind==JsonValueKind.Number&&ql.TryGetDouble(out var ld)?ld:null;
                    var at=q.TryGetProperty("nextAvailableAt",out var qn)?qn.GetString():null;
                    if(string.IsNullOrWhiteSpace(at)&&q.TryGetProperty("resetAt",out var qra))at=qra.GetString();

                    var parts=new List<string>();
                    if(remaining is not null&&limit is not null)parts.Add($"{remaining:0.##}/{limit:0.##}");
                    else if(remaining is not null)parts.Add($"{remaining:0.##} left");
                    else if(string.Equals(status,"exhausted",StringComparison.OrdinalIgnoreCase))parts.Add("exhausted");
                    if(DateTimeOffset.TryParse(at,out var reset)&&reset>DateTimeOffset.UtcNow)
                        parts.Add($"reset {reset.ToLocalTime():HH:mm:ss}");
                    if(parts.Count>0)display.Quota=(probed?"probe ":"")+string.Join(" · ",parts);
                }
                output[p.Name]=display;
            }
        }catch{}
        return output;
    }

    void Toggle(int row,bool enabled)
    {
        if(_grid.Rows[row].Tag is not EndpointStatus status)return;
        var changed=TargetPoolStore.UpdateActive(pool =>
        {
            if(!pool.entries.TryGetValue(status.Id,out var entry))return false;
            entry.enabled=enabled;
            if(string.Equals(entry.managedBy,"free-capacity",StringComparison.OrdinalIgnoreCase))
                entry.userOverride=enabled?"enabled":"disabled";
            entry.updatedAt=DateTimeOffset.UtcNow.ToString("O");
            pool.entries[status.Id]=entry;
            return true;
        });
        if(!changed){Reload();return;}

        status.Enabled=enabled;
        _grid.Rows[row].DefaultCellStyle.ForeColor=enabled?Theme.Text:Theme.Muted;
        var current=TargetPoolStore.LoadActive();
        _summary.Text=$"{current.entries.Count(x=>x.Value.enabled)} enabled / {current.entries.Count} endpoint(s)";
    }

    void RemoveSelected(object? s,EventArgs e)
    {
        var ep=Selected;if(ep is null)return;
        if(MessageBox.Show(_owner,$"Remove endpoint '{ep.Connection} / {ep.Model}' from the machine routing pool? The provider connection and discovered model remain available on Connections.","Remove endpoint",MessageBoxButtons.YesNo,MessageBoxIcon.Warning)!=DialogResult.Yes)return;
        TargetPoolStore.UpdateActive(pool =>
        {
            if(pool.entries.TryGetValue(ep.Id,out var entry) && string.Equals(entry.managedBy,"free-capacity",StringComparison.OrdinalIgnoreCase))
            {
                // Removing an auto-managed endpoint must persist as an operator
                // suppression; otherwise the next catalog sync would recreate it.
                entry.enabled=false;
                entry.userOverride="disabled";
                entry.retiredReason="suppressed-by-user";
                entry.updatedAt=DateTimeOffset.UtcNow.ToString("O");
                pool.entries[ep.Id]=entry;
            }
            else pool.entries.Remove(ep.Id);
            return 0;
        });
        Reload();
    }

    protected override void Dispose(bool disposing){if(disposing)_timer.Dispose();base.Dispose(disposing);}
}

namespace StatefulClanker.Tray;

sealed class RecentActivityPanel : Panel
{
    readonly TableLayoutPanel _rows = new()
    {
        Dock = DockStyle.Top,
        ColumnCount = 1,
        AutoSize = true,
        AutoSizeMode = AutoSizeMode.GrowAndShrink,
        BackColor = Theme.Surface
    };
    readonly Label _empty = new()
    {
        Text = "No recent activity.",
        Dock = DockStyle.Top,
        Height = 28,
        ForeColor = Theme.Muted,
        Font = new Font("Cascadia Mono", 8.25f),
        Padding = new Padding(8, 6, 4, 0)
    };

    public event Action? OpenActivityRequested;

    public RecentActivityPanel()
    {
        Dock = DockStyle.Fill;
        BackColor = Theme.Surface;
        Padding = new Padding(1);
        AutoScroll = true;
        Controls.Add(_empty);
        Controls.Add(_rows);
        Click += (_, _) => OpenActivityRequested?.Invoke();
    }

    public void SetActivity(string activity, int maxRows = 9)
    {
        var lines = (activity ?? "")
            .Split(new[] { "\r\n", "\n" }, StringSplitOptions.RemoveEmptyEntries)
            .Select(x => x.TrimEnd())
            .Where(x => !string.IsNullOrWhiteSpace(x))
            .TakeLast(maxRows)
            .Reverse()
            .ToList();

        _rows.SuspendLayout();
        try
        {
            _rows.Controls.Clear();
            _rows.RowStyles.Clear();
            _rows.RowCount = 0;
            foreach (var line in lines)
            {
                var label = new Label
                {
                    Text = line,
                    Dock = DockStyle.Top,
                    Height = 26,
                    AutoEllipsis = true,
                    ForeColor = ActivityColor(line),
                    BackColor = Theme.Surface,
                    Font = new Font("Cascadia Mono", 8f),
                    Padding = new Padding(7, 5, 5, 0),
                    Cursor = Cursors.Hand,
                    Margin = new Padding(0, 0, 0, 1)
                };
                label.Click += (_, _) => OpenActivityRequested?.Invoke();
                _rows.RowStyles.Add(new RowStyle(SizeType.Absolute, 27));
                _rows.Controls.Add(label, 0, _rows.RowCount++);
            }
            _empty.Visible = lines.Count == 0;
        }
        finally { _rows.ResumeLayout(); }
    }

    static Color ActivityColor(string line)
    {
        var l = line.ToLowerInvariant();
        if (l.Contains("fail") || l.Contains("reject") || l.Contains("blocked") || l.Contains("error")) return Theme.Error;
        if (l.Contains("pass") || l.Contains("complete") || l.Contains("commit")) return Theme.Good;
        if (l.Contains("critic") || l.Contains("validator") || l.Contains("stale")) return Theme.Warn;
        if (l.Contains("started") || l.Contains("running") || l.Contains("dispatch")) return Theme.Accent;
        return Theme.Text;
    }
}

sealed class OrchestratorStatusPanel : Control
{
    ProjectMetrics _project = new();
    AutofillSnapshot _autofill = new();
    bool _mcpRunning;
    bool _hasProject;

    public OrchestratorStatusPanel()
    {
        DoubleBuffered = true;
        Dock = DockStyle.Fill;
        MinimumSize = new Size(220, 105);
    }

    public void SetState(ProjectMetrics project, AutofillSnapshot autofill, bool mcpRunning, bool hasProject)
    {
        _project = project;
        _autofill = autofill;
        _mcpRunning = mcpRunning;
        _hasProject = hasProject;
        Invalidate();
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        var g = e.Graphics;
        g.Clear(Parent?.BackColor ?? Theme.Back);
        Theme.PaintCard(g, new Rectangle(0, 0, Width, Height), Color.FromArgb(20, 27, 35), 8);

        using var titleFont = new Font("Cascadia Mono", 9.25f, FontStyle.Bold);
        using var labelFont = new Font("Cascadia Mono", 8f, FontStyle.Bold);
        using var valueFont = new Font("Cascadia Mono", 8f);
        using var titleBrush = new SolidBrush(Theme.Accent);
        using var mutedBrush = new SolidBrush(Theme.Muted);
        using var textBrush = new SolidBrush(Theme.Text);

        g.DrawString("CLANKER STATUS", titleFont, titleBrush, 11, 8);

        var rows = new List<(string label, string value, Color color)>
        {
            ("PROJECT", _hasProject ? "ACTIVE" : "NONE", _hasProject ? Theme.Good : Theme.Muted),
            ("MCP", _mcpRunning ? "ONLINE" : "OFFLINE", _mcpRunning ? Theme.Good : Theme.Error),
            ("AUTOFILL", _autofill.Paused ? "PAUSED" : (_autofill.Running ? "RUNNING" : "STOPPED"), _autofill.Paused ? Theme.Warn : (_autofill.Running ? Theme.Good : Theme.Muted)),
            ("WORKERS", $"{_project.ActiveAgents}/{Math.Max(1, _autofill.MaxConcurrent)}", _project.ActiveAgents > 0 ? Theme.Accent : Theme.Muted),
            ("QUEUE", $"{_autofill.ReadyCount} READY" + (_autofill.RetryCount > 0 ? $" / {_autofill.RetryCount} RETRY" : ""), _autofill.RetryCount > 0 ? Theme.Warn : Theme.Text),
            ("INTENT", string.IsNullOrWhiteSpace(_project.IntentRevision) ? "—" : $"R{_project.IntentRevision}", Theme.Text)
        };

        var top = 29;
        var colWidth = Math.Max(120, Width / 2);
        for (var i = 0; i < rows.Count; i++)
        {
            var col = i % 2;
            var row = i / 2;
            var x = 12 + col * colWidth;
            var y = top + row * 25;
            var item = rows[i];

            using (var glow = new SolidBrush(Color.FromArgb(70, item.color)))
                g.FillEllipse(glow, x - 2, y + 2, 12, 12);
            using var lamp = new SolidBrush(item.color);
            g.FillEllipse(lamp, x, y + 4, 8, 8);
            using (var hot = new SolidBrush(Color.FromArgb(180, 255, 255, 255)))
                g.FillEllipse(hot, x + 1.5f, y + 5, 3, 3);
            g.DrawString(item.label, labelFont, mutedBrush, x + 15, y);
            g.DrawString(item.value, valueFont, textBrush, x + 77, y);
        }

        if (!string.IsNullOrWhiteSpace(_autofill.BlockReason))
        {
            using var warn = new SolidBrush(Theme.Warn);
            var message = _autofill.BlockReason.Length > 80 ? _autofill.BlockReason[..77] + "..." : _autofill.BlockReason;
            g.DrawString("HOLD  " + message, valueFont, warn, 12, Height - 22);
        }
    }
}


sealed class EndpointQueuePreview
{
    public string EndpointId = "";
    public string Connection = "";
    public string Model = "";
    public string State = "empty";
    public string Detail = "";
    public int EnabledCount;
    public int ReadyCount;
    public string Display => string.IsNullOrWhiteSpace(Connection)
        ? "NO READY ENDPOINT"
        : Connection + " / " + Model;
}

static class RoutingQueueInspector
{
    public static EndpointQueuePreview Snapshot()
    {
        var preview = new EndpointQueuePreview();
        try
        {
            var pool = TargetPoolStore.LoadActive();
            var enabled = pool.entries
                .Where(x => x.Value.enabled)
                .Select(x => new { Id=x.Key, Route="pool:"+x.Key, Entry=x.Value })
                .OrderBy(x => x.Route, StringComparer.OrdinalIgnoreCase)
                .ToList();
            preview.EnabledCount = enabled.Count;
            if (enabled.Count == 0) { preview.Detail="endpoint catalog empty"; return preview; }

            var health = ReadHealth();
            var connections = ApiConnectionStore.Load();
            var ready = new List<(string id,string route,TargetPoolEntry entry)>();
            foreach (var x in enabled)
            {
                if (!IsHealthy(health,x.Route)) continue;
                if (!IsHealthy(health,"connection:"+x.Entry.connection)) continue;
                if (connections.TryGetValue(x.Entry.connection,out var profile))
                {
                    var service = ServiceName(profile);
                    if (!string.IsNullOrWhiteSpace(service) && !IsHealthy(health,"service:"+service)) continue;
                }
                ready.Add((x.Id,x.Route,x.Entry));
            }
            preview.ReadyCount = ready.Count;
            if (ready.Count == 0)
            {
                preview.State="waiting";
                preview.Detail="all endpoints cooling or quarantined";
                return preview;
            }

            // Match Get-SCProviderCandidates exactly: health filtering happens first,
            // then the durable cursor rotates that eligible sorted set. Occupancy is
            // checked afterward by the dispatch loop, so skip leased routes in that order.
            var cursor = ReadCursor(ready.Count);
            for (var offset=0; offset<ready.Count; offset++)
            {
                var candidate=ready[(cursor+offset)%ready.Count];
                if (!LeaseLooksFree(candidate.route)) continue;
                preview.EndpointId=candidate.route;
                preview.Connection=candidate.entry.connection;
                preview.Model=candidate.entry.displayName == candidate.entry.model ? candidate.entry.model : candidate.entry.displayName;
                preview.State="ready";
                preview.Detail=$"{ready.Count}/{enabled.Count} healthy";
                return preview;
            }

            preview.State="busy";
            preview.Detail=$"{ready.Count}/{enabled.Count} healthy; all presently occupied";
            return preview;
        }
        catch (Exception ex)
        {
            preview.State="error";
            preview.Detail=ex.Message;
            return preview;
        }
    }

    static int ReadCursor(int count)
    {
        if (count<=0) return 0;
        var path=System.IO.Path.Combine(AppStore.Root,"routing","round-robin.json");
        try
        {
            if (!File.Exists(path)) return 0;
            using var doc=System.Text.Json.JsonDocument.Parse(File.ReadAllText(path));
            if (doc.RootElement.TryGetProperty("cursor",out var c) && c.TryGetInt32(out var n))
                return ((n%count)+count)%count;
        }
        catch { }
        return 0;
    }

    static Dictionary<string,string> ReadHealth()
    {
        var output=new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase);
        var path=System.IO.Path.Combine(AppStore.Root,"routing","health.json");
        try
        {
            if (!File.Exists(path)) return output;
            using var doc=System.Text.Json.JsonDocument.Parse(File.ReadAllText(path));
            if (!doc.RootElement.TryGetProperty("endpoints",out var endpoints) || endpoints.ValueKind!=System.Text.Json.JsonValueKind.Object) return output;
            foreach (var p in endpoints.EnumerateObject())
            {
                var state=p.Value.TryGetProperty("state",out var s) && s.ValueKind==System.Text.Json.JsonValueKind.String ? s.GetString() : null;
                if (!string.IsNullOrWhiteSpace(state)) output[p.Name]=state!;
            }
        }
        catch { }
        return output;
    }

    static bool IsHealthy(Dictionary<string,string> health,string name)
        => !health.TryGetValue(name,out var state) || string.Equals(state,"healthy",StringComparison.OrdinalIgnoreCase);

    static string? ServiceName(ApiConnectionProfile p)
    {
        if (!string.IsNullOrWhiteSpace(p.presetId) && !string.Equals(p.presetId,"custom",StringComparison.OrdinalIgnoreCase))
            return p.presetId.ToLowerInvariant();
        try { return new Uri(p.baseUrl).Host.ToLowerInvariant(); } catch { return null; }
    }

    static bool LeaseLooksFree(string route)
    {
        try
        {
            var material=AppStore.Root+"|"+route;
            var hash=Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(material))).ToLowerInvariant();
            using var mutex=new Mutex(false,"Local\\StatefulClankerEndpoint-"+hash[..24]);
            var acquired=false;
            try { acquired=mutex.WaitOne(0); }
            catch (AbandonedMutexException) { acquired=true; }
            if (acquired) { try { mutex.ReleaseMutex(); } catch { } }
            return acquired;
        }
        catch { return true; }
    }
}

sealed class OverviewReadoutPanel : Control
{
    ProjectMetrics _project=new();
    AutofillSnapshot _autofill=new();
    EndpointQueuePreview _next=new();
    bool _mcpRunning;
    bool _hasProject;

    public OverviewReadoutPanel()
    {
        Dock=DockStyle.Fill;
        DoubleBuffered=true;
        MinimumSize=new Size(420,82);
        BackColor=Color.FromArgb(9,13,16);
    }

    public void SetState(ProjectMetrics project,AutofillSnapshot autofill,bool mcpRunning,bool hasProject,EndpointQueuePreview next)
    {
        _project=project;_autofill=autofill;_mcpRunning=mcpRunning;_hasProject=hasProject;_next=next;
        Invalidate();
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        var g=e.Graphics;
        g.Clear(Color.FromArgb(9,13,16));
        using var edge=new Pen(Color.FromArgb(37,48,55));
        g.DrawRectangle(edge,0,0,Math.Max(0,Width-1),Math.Max(0,Height-1));

        var gap=5;
        var usable=Math.Max(1,Width-gap*5);
        var col=usable/4;
        var rowH=Math.Max(28,(Height-18)/2);
        DrawCell(g,new Rectangle(gap,5,col,rowH),"PROJECT",_hasProject?"ACTIVE":"NO PROJECT",_hasProject?Theme.Good:Theme.Muted,_hasProject);
        DrawCell(g,new Rectangle(gap*2+col,5,col,rowH),"MCP",_mcpRunning?"ONLINE":"OFFLINE",_mcpRunning?Theme.Good:Theme.Error,_mcpRunning);
        var af=_autofill.Paused?"PAUSED":_autofill.Running?"RUNNING":"STOPPED";
        DrawCell(g,new Rectangle(gap*3+col*2,5,col,rowH),"AUTOFILL",af,_autofill.Paused?Theme.Warn:_autofill.Running?Theme.Good:Theme.Muted,_autofill.Running&&!_autofill.Paused);
        DrawCell(g,new Rectangle(gap*4+col*3,5,col,rowH),"WORKERS",$"{_project.ActiveAgents}/{Math.Max(1,_autofill.MaxConcurrent)}",_project.ActiveAgents>0?Theme.Accent:Theme.Muted,_project.ActiveAgents>0);

        var y=8+rowH;
        DrawCell(g,new Rectangle(gap,y,col*2+gap,rowH),"NEXT ENDPOINT IN QUEUE",_next.Display,EndpointColor(_next.State),string.Equals(_next.State,"ready",StringComparison.OrdinalIgnoreCase),_next.Detail);
        DrawCell(g,new Rectangle(gap*3+col*2,y,col,rowH),"QUEUE",$"{_autofill.ReadyCount} READY / {_autofill.RetryCount} RETRY",_autofill.RetryCount>0?Theme.Warn:Theme.Text,_autofill.ReadyCount>0);
        var intent=string.IsNullOrWhiteSpace(_project.IntentRevision)?"—":"R"+_project.IntentRevision;
        DrawCell(g,new Rectangle(gap*4+col*3,y,col,rowH),"INTENT",intent,Theme.Text,!string.IsNullOrWhiteSpace(_project.IntentRevision));
    }

    static Color EndpointColor(string state) => state.ToLowerInvariant() switch
    {
        "ready"=>Theme.Good,
        "busy"=>Theme.Accent,
        "waiting"=>Theme.Warn,
        "error"=>Theme.Error,
        _=>Theme.Muted
    };

    static void DrawCell(Graphics g,Rectangle r,string label,string value,Color color,bool lit,string? sub=null)
    {
        using var fill=new SolidBrush(Color.FromArgb(15,21,24));
        using var border=new Pen(Color.FromArgb(31,43,48));
        g.FillRectangle(fill,r);g.DrawRectangle(border,r);
        using var labelFont=new Font("Cascadia Mono",6.9f,FontStyle.Bold);
        using var valueFont=new Font("Cascadia Mono",8.4f,FontStyle.Bold);
        using var tinyFont=new Font("Cascadia Mono",6.5f);
        using var muted=new SolidBrush(Color.FromArgb(104,121,126));
        using var valueBrush=new SolidBrush(color);
        var led=new Rectangle(r.X+7,r.Y+8,7,7);
        if(lit)
        {
            using var glow=new SolidBrush(Color.FromArgb(65,color));
            g.FillEllipse(glow,led.X-2,led.Y-2,11,11);
        }
        using(var lamp=new SolidBrush(lit?color:Color.FromArgb(42,54,57))) g.FillEllipse(lamp,led);
        g.DrawString(label,labelFont,muted,r.X+19,r.Y+4);
        var valueRect=new Rectangle(r.X+8,r.Y+17,Math.Max(0,r.Width-16),15);
        TextRenderer.DrawText(g,value,valueFont,valueRect,color,TextFormatFlags.EndEllipsis|TextFormatFlags.NoPadding|TextFormatFlags.SingleLine);
        if(!string.IsNullOrWhiteSpace(sub)&&r.Height>=42)
        {
            var subRect=new Rectangle(r.X+8,r.Y+32,Math.Max(0,r.Width-16),11);
            TextRenderer.DrawText(g,sub,tinyFont,subRect,Color.FromArgb(88,108,113),TextFormatFlags.EndEllipsis|TextFormatFlags.NoPadding|TextFormatFlags.SingleLine);
        }
    }
}

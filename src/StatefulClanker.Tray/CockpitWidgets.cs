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


sealed class QuotaRemainingPanel : Panel
{
    readonly TableLayoutPanel _rows = new()
    {
        Dock = DockStyle.Top,
        ColumnCount = 1,
        AutoSize = true,
        AutoSizeMode = AutoSizeMode.GrowAndShrink,
        BackColor = Theme.Recess
    };

    readonly Label _empty = new()
    {
        Text = "No quota telemetry yet.",
        Dock = DockStyle.Top,
        Height = 30,
        ForeColor = Theme.Muted,
        Font = new Font("Cascadia Mono", 8.25f),
        Padding = new Padding(6, 6, 4, 0),
        BackColor = Theme.Recess
    };

    public QuotaRemainingPanel()
    {
        Dock = DockStyle.Fill;
        BackColor = Theme.Recess;
        Padding = new Padding(0);
        AutoScroll = true;
        Controls.Add(_empty);
        Controls.Add(_rows);
    }

    public void RefreshQuota()
    {
        var items = ReadQuotaRows();

        _rows.SuspendLayout();
        try
        {
            _rows.Controls.Clear();
            _rows.RowStyles.Clear();
            _rows.RowCount = 0;

            foreach (var item in items)
            {
                var row = new QuotaBarRow(item)
                {
                    Dock = DockStyle.Top,
                    Height = 42,
                    Margin = new Padding(0)
                };
                _rows.RowStyles.Add(new RowStyle(SizeType.Absolute, 42));
                _rows.Controls.Add(row, 0, _rows.RowCount++);
            }

            _empty.Visible = items.Count == 0;
        }
        finally { _rows.ResumeLayout(); }
    }

    static List<QuotaDisplayItem> ReadQuotaRows()
    {
        var root = AppStore.Root;
        var connectionsPath = System.IO.Path.Combine(root, "connections.json");
        var endpointsPath = System.IO.Path.Combine(root, "endpoints.json");
        var healthPath = System.IO.Path.Combine(root, "routing", "health.json");
        var output = new List<QuotaDisplayItem>();

        try
        {
            var connectionNames = new List<string>();
            if (File.Exists(connectionsPath))
            {
                using var connections = System.Text.Json.JsonDocument.Parse(File.ReadAllText(connectionsPath));
                if (connections.RootElement.TryGetProperty("connections", out var c) &&
                    c.ValueKind == System.Text.Json.JsonValueKind.Object)
                    connectionNames.AddRange(c.EnumerateObject().Select(x => x.Name));
            }

            var endpointConnections = new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase);
            if (File.Exists(endpointsPath))
            {
                using var endpoints = System.Text.Json.JsonDocument.Parse(File.ReadAllText(endpointsPath));
                if (endpoints.RootElement.TryGetProperty("entries", out var entries) &&
                    entries.ValueKind == System.Text.Json.JsonValueKind.Object)
                {
                    foreach (var entry in entries.EnumerateObject())
                    {
                        if (entry.Value.TryGetProperty("connection", out var conn) &&
                            conn.ValueKind == System.Text.Json.JsonValueKind.String)
                            endpointConnections["pool:" + entry.Name] = conn.GetString() ?? "";
                    }
                }
            }

            var healthByKey = new Dictionary<string,System.Text.Json.JsonElement>(StringComparer.OrdinalIgnoreCase);
            if (File.Exists(healthPath))
            {
                using var health = System.Text.Json.JsonDocument.Parse(File.ReadAllText(healthPath));
                if (health.RootElement.TryGetProperty("endpoints", out var entries) &&
                    entries.ValueKind == System.Text.Json.JsonValueKind.Object)
                {
                    foreach (var item in entries.EnumerateObject())
                        healthByKey[item.Name] = item.Value.Clone();
                }
            }

            foreach (var connection in connectionNames.OrderBy(x => x, StringComparer.OrdinalIgnoreCase))
            {
                var candidates = new List<QuotaCandidate>();
                if (healthByKey.TryGetValue("connection:" + connection, out var connectionHealth))
                    candidates.AddRange(ParseHealth(connectionHealth));

                foreach (var route in endpointConnections.Where(x =>
                    string.Equals(x.Value, connection, StringComparison.OrdinalIgnoreCase)))
                    if (healthByKey.TryGetValue(route.Key, out var endpointHealth))
                        candidates.AddRange(ParseHealth(endpointHealth));

                output.Add(BuildItem(connection, candidates));
            }
        }
        catch
        {
            // Overview telemetry must never destabilize the tray.
        }

        return output;
    }

    static IEnumerable<QuotaCandidate> ParseHealth(System.Text.Json.JsonElement health)
    {
        var state = health.TryGetProperty("state", out var st) ? st.GetString() ?? "" : "";
        var reason = health.TryGetProperty("reason", out var rs) ? rs.GetString() ?? "" : "";
        var retry = health.TryGetProperty("retryAfter", out var ra) ? ra.GetString() : null;

        if (!health.TryGetProperty("quota", out var quota) ||
            quota.ValueKind != System.Text.Json.JsonValueKind.Object)
        {
            if (!string.IsNullOrWhiteSpace(state) && !string.Equals(state, "healthy", StringComparison.OrdinalIgnoreCase))
                yield return new QuotaCandidate(null, null, null, null, state, reason, retry, "health");
            yield break;
        }

        if (quota.TryGetProperty("windows", out var windows) &&
            windows.ValueKind == System.Text.Json.JsonValueKind.Array)
        {
            foreach (var w in windows.EnumerateArray())
            {
                yield return new QuotaCandidate(
                    Number(w, "remaining"),
                    Number(w, "limit"),
                    JsonText(w, "kind"),
                    JsonText(w, "unit"),
                    JsonText(quota, "status") ?? state,
                    reason,
                    JsonText(w, "resetAt") ?? JsonText(quota, "nextAvailableAt"),
                    JsonText(w, "source") ?? JsonText(quota, "source") ?? "quota");
            }
        }

        // Compatibility with older single-window observations.
        if (!quota.TryGetProperty("windows", out var ws) ||
            ws.ValueKind != System.Text.Json.JsonValueKind.Array ||
            ws.GetArrayLength() == 0)
        {
            yield return new QuotaCandidate(
                Number(quota, "remaining"),
                Number(quota, "limit"),
                JsonText(quota, "limiter"),
                null,
                JsonText(quota, "status") ?? state,
                reason,
                JsonText(quota, "nextAvailableAt") ?? JsonText(quota, "resetAt") ?? retry,
                JsonText(quota, "source") ?? "quota");
        }
    }

    static QuotaDisplayItem BuildItem(string connection, List<QuotaCandidate> candidates)
    {
        var measurable = candidates
            .Where(x => x.Remaining is not null && x.Limit is > 0)
            .Select(x => (candidate:x, fraction:Math.Clamp(x.Remaining!.Value / x.Limit!.Value, 0d, 1d)))
            .OrderBy(x => x.fraction)
            .FirstOrDefault();

        if (measurable.candidate is not null)
        {
            var c = measurable.candidate;
            var pct = measurable.fraction;
            var kind = PrettyKind(c.Kind, c.Unit);
            var detail = $"{Format(c.Remaining)} / {Format(c.Limit)}";
            if (!string.IsNullOrWhiteSpace(kind)) detail += " " + kind;
            detail += ResetSuffix(c.ResetAt);
            return new QuotaDisplayItem(connection, pct, detail, StateText(c), c.Status, true);
        }

        var timed = candidates
            .Where(x => DateTimeOffset.TryParse(x.ResetAt, out var t) && t > DateTimeOffset.UtcNow)
            .OrderBy(x => DateTimeOffset.Parse(x.ResetAt!))
            .FirstOrDefault();
        if (timed is not null)
        {
            var detail = PrettyKind(timed.Kind, timed.Unit);
            if (string.IsNullOrWhiteSpace(detail)) detail = StateText(timed);
            detail += ResetSuffix(timed.ResetAt);
            return new QuotaDisplayItem(connection, null, detail.Trim(), StateText(timed), timed.Status, false);
        }

        var informative = candidates.FirstOrDefault();
        if (informative is not null)
        {
            var detail = PrettyKind(informative.Kind, informative.Unit);
            if (informative.Limit is > 0)
                detail = (string.IsNullOrWhiteSpace(detail) ? "" : detail + " · ") + $"limit {Format(informative.Limit)}";
            if (string.IsNullOrWhiteSpace(detail)) detail = StateText(informative);
            return new QuotaDisplayItem(connection, null, detail, StateText(informative), informative.Status, false);
        }

        return new QuotaDisplayItem(connection, null, "quota unknown", "UNKNOWN", "unknown", false);
    }

    static string StateText(QuotaCandidate c)
    {
        if (string.Equals(c.Status, "exhausted", StringComparison.OrdinalIgnoreCase)) return "EXHAUSTED";
        if (string.Equals(c.Status, "cooldown", StringComparison.OrdinalIgnoreCase)) return "COOLING";
        if (string.Equals(c.Status, "quarantined", StringComparison.OrdinalIgnoreCase)) return "QUARANTINED";
        if (!string.IsNullOrWhiteSpace(c.Reason)) return c.Reason!.ToUpperInvariant();
        return "READY";
    }

    static string PrettyKind(string? kind, string? unit)
    {
        if (!string.IsNullOrWhiteSpace(unit)) return unit!;
        return (kind ?? "").Replace('_', ' ').Replace("per ", "/").Trim();
    }

    static string ResetSuffix(string? raw)
    {
        if (!DateTimeOffset.TryParse(raw, out var at) || at <= DateTimeOffset.UtcNow) return "";
        var local = at.ToLocalTime();
        var sameDay = local.Date == DateTimeOffset.Now.Date;
        return sameDay ? $" · reset {local:HH:mm:ss}" : $" · reset {local:ddd HH:mm}";
    }

    static string Format(double? value)
    {
        if (value is null) return "?";
        var v = value.Value;
        if (Math.Abs(v) >= 1_000_000) return (v / 1_000_000d).ToString("0.##") + "M";
        if (Math.Abs(v) >= 1_000) return (v / 1_000d).ToString("0.##") + "K";
        return v.ToString("0.##");
    }

    static string? JsonText(System.Text.Json.JsonElement e, string name) =>
        e.TryGetProperty(name, out var v) && v.ValueKind == System.Text.Json.JsonValueKind.String ? v.GetString() : null;

    static double? Number(System.Text.Json.JsonElement e, string name)
    {
        if (!e.TryGetProperty(name, out var v)) return null;
        if (v.ValueKind == System.Text.Json.JsonValueKind.Number && v.TryGetDouble(out var n)) return n;
        if (v.ValueKind == System.Text.Json.JsonValueKind.String &&
            double.TryParse(v.GetString(), System.Globalization.NumberStyles.Float,
                System.Globalization.CultureInfo.InvariantCulture, out n)) return n;
        return null;
    }

    sealed record QuotaCandidate(
        double? Remaining, double? Limit, string? Kind, string? Unit,
        string? Status, string? Reason, string? ResetAt, string Source);

    sealed record QuotaDisplayItem(
        string Connection, double? Fraction, string Detail, string State, string? RawState, bool Measured);

    sealed class QuotaBarRow : Control
    {
        readonly QuotaDisplayItem _item;

        public QuotaBarRow(QuotaDisplayItem item)
        {
            _item = item;
            DoubleBuffered = true;
            BackColor = Theme.Recess;
            Cursor = Cursors.Default;
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaint(e);
            var g = e.Graphics;
            g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.None;
            g.Clear(Theme.Recess);

            using var separator = new Pen(Theme.Border);
            g.DrawLine(separator, 0, Height - 1, Width, Height - 1);

            using var nameFont = new Font("Cascadia Mono", 7.7f, FontStyle.Bold);
            using var detailFont = new Font("Cascadia Mono", 6.7f);
            var stateColor = StateColor(_item.RawState, _item.Fraction);

            TextRenderer.DrawText(g, _item.Connection, nameFont,
                new Rectangle(6, 3, Math.Max(20, Width - 88), 12), Theme.Text,
                TextFormatFlags.EndEllipsis | TextFormatFlags.NoPadding | TextFormatFlags.SingleLine);
            TextRenderer.DrawText(g, _item.State, detailFont,
                new Rectangle(Math.Max(0, Width - 78), 4, 72, 10), stateColor,
                TextFormatFlags.Right | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPadding | TextFormatFlags.SingleLine);

            var bar = new Rectangle(6, 18, Math.Max(20, Width - 12), 7);
            using (var track = new SolidBrush(Color.FromArgb(19, 26, 31)))
                g.FillRectangle(track, bar);

            if (_item.Fraction is double fraction)
            {
                var fillWidth = (int)Math.Round(bar.Width * Math.Clamp(fraction, 0d, 1d));
                if (fillWidth > 0)
                {
                    using var fillBrush = new SolidBrush(stateColor);
                    g.FillRectangle(fillBrush, bar.X, bar.Y, fillWidth, bar.Height);
                    using var hi = new Pen(Color.FromArgb(100, 255, 255, 255));
                    g.DrawLine(hi, bar.X, bar.Y, bar.X + fillWidth - 1, bar.Y);
                }
            }
            else
            {
                using var pen = new Pen(Color.FromArgb(62, Theme.Muted));
                for (var x = bar.X - bar.Height; x < bar.Right; x += 7)
                    g.DrawLine(pen, x, bar.Bottom - 1, x + bar.Height, bar.Top);
            }

            using (var edge = new Pen(Theme.Border))
                g.DrawRectangle(edge, bar);

            TextRenderer.DrawText(g, _item.Detail, detailFont,
                new Rectangle(6, 29, Math.Max(20, Width - 12), 10), Theme.Muted,
                TextFormatFlags.EndEllipsis | TextFormatFlags.NoPadding | TextFormatFlags.SingleLine);
        }

        static Color StateColor(string? state, double? fraction)
        {
            var s = (state ?? "").ToLowerInvariant();
            if (s.Contains("quarant") || s.Contains("auth") || s.Contains("retired")) return Theme.Error;
            if (s.Contains("cool") || s.Contains("exhaust") || s.Contains("rate")) return Theme.Warn;
            if (fraction is double f)
            {
                if (f <= 0.1) return Theme.Error;
                if (f <= 0.3) return Theme.Warn;
                return Theme.Good;
            }
            return Theme.Accent;
        }
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
        var compiled = TryCompiledRouter();
        if (compiled is not null) return compiled;
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

    static EndpointQueuePreview? TryCompiledRouter()
    {
        try
        {
            var store = new StatefulClanker.Router.RouterStore();
            var pipe = StatefulClanker.Router.RouterNames.PipeName(store.Root);
            var response = StatefulClanker.Router.RouterPipeClient
                .SendAsync(pipe, new StatefulClanker.Router.RouterRequest { op = "snapshot" }, 120)
                .GetAwaiter().GetResult();
            if (!response.ok || response.data is not System.Text.Json.JsonElement root ||
                root.ValueKind != System.Text.Json.JsonValueKind.Object) return null;

            static string? Text(System.Text.Json.JsonElement e,string name) =>
                e.TryGetProperty(name,out var v) && v.ValueKind==System.Text.Json.JsonValueKind.String ? v.GetString() : null;
            static int Number(System.Text.Json.JsonElement e,string name) =>
                e.TryGetProperty(name,out var v) && v.TryGetInt32(out var n) ? n : 0;

            var next = Text(root,"nextEndpoint");
            var connection = Text(root,"nextConnection");
            var model = Text(root,"nextModel");
            var enabled = Number(root,"enabledRoutes");
            var healthy = Number(root,"healthyRoutes");
            var leases = Number(root,"activeLeases");

            return new EndpointQueuePreview
            {
                EndpointId = next ?? "",
                Connection = connection ?? "",
                Model = model ?? "",
                EnabledCount = enabled,
                ReadyCount = healthy,
                State = !string.IsNullOrWhiteSpace(next) ? "ready" : (healthy > 0 && leases >= healthy ? "busy" : "waiting"),
                Detail = $"{healthy}/{enabled} healthy · {leases} leased"
            };
        }
        catch { return null; }
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
        MinimumSize=new Size(420,80);
        BackColor=Theme.Recess;
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
        g.SmoothingMode=System.Drawing.Drawing2D.SmoothingMode.None;
        g.Clear(Theme.Recess);

        using(var shell=new Pen(Theme.Border))
            g.DrawRectangle(shell,0,0,Math.Max(0,Width-1),Math.Max(0,Height-1));
        using(var top=new Pen(Color.FromArgb(92,Theme.EdgeHi)))
            g.DrawLine(top,1,1,Math.Max(1,Width-2),1);

        const int outer=3;
        const int gap=2;
        var usable=Math.Max(1,Width-outer*2-gap*3);
        var col=Math.Max(1,usable/4);
        var rowH=Math.Max(27,(Height-outer*2-gap)/2);

        DrawCell(g,new Rectangle(outer,outer,col,rowH),"PROJECT",_hasProject?"ACTIVE":"NO PROJECT",_hasProject?Theme.Good:Theme.Muted,_hasProject);
        DrawCell(g,new Rectangle(outer+col+gap,outer,col,rowH),"MCP",_mcpRunning?"ONLINE":"OFFLINE",_mcpRunning?Theme.Good:Theme.Error,_mcpRunning);
        var af=_autofill.Paused?"PAUSED":_autofill.Running?"RUNNING":"STOPPED";
        DrawCell(g,new Rectangle(outer+(col+gap)*2,outer,col,rowH),"AUTOFILL",af,_autofill.Paused?Theme.Warn:_autofill.Running?Theme.Good:Theme.Muted,_autofill.Running&&!_autofill.Paused);
        DrawCell(g,new Rectangle(outer+(col+gap)*3,outer,Math.Max(1,Width-outer-(outer+(col+gap)*3)),rowH),"WORKERS",$"{_project.ActiveAgents}/{Math.Max(1,_autofill.MaxConcurrent)}",_project.ActiveAgents>0?Theme.Accent:Theme.Muted,_project.ActiveAgents>0);

        var y=outer+rowH+gap;
        DrawCell(g,new Rectangle(outer,y,col*2+gap,rowH),"NEXT ENDPOINT IN QUEUE",_next.Display,EndpointColor(_next.State),string.Equals(_next.State,"ready",StringComparison.OrdinalIgnoreCase),_next.Detail);
        DrawCell(g,new Rectangle(outer+(col+gap)*2,y,col,rowH),"QUEUE",$"{_autofill.ReadyCount} READY / {_autofill.RetryCount} RETRY",_autofill.RetryCount>0?Theme.Warn:Theme.Text,_autofill.ReadyCount>0);
        var intent=string.IsNullOrWhiteSpace(_project.IntentRevision)?"—":"R"+_project.IntentRevision;
        DrawCell(g,new Rectangle(outer+(col+gap)*3,y,Math.Max(1,Width-outer-(outer+(col+gap)*3)),rowH),"INTENT",intent,Theme.Text,!string.IsNullOrWhiteSpace(_project.IntentRevision));
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
        if(r.Width<=1||r.Height<=1) return;
        using var fill=new SolidBrush(Theme.Surface);
        using var border=new Pen(Theme.Border);
        using var topEdge=new Pen(Color.FromArgb(72,Theme.EdgeHi));
        g.FillRectangle(fill,r);
        g.DrawRectangle(border,r);
        g.DrawLine(topEdge,r.Left+1,r.Top+1,r.Right-1,r.Top+1);

        using var labelFont=new Font("Cascadia Mono",6.7f,FontStyle.Bold);
        using var valueFont=new Font("Cascadia Mono",8.1f,FontStyle.Bold);
        using var tinyFont=new Font("Cascadia Mono",6.2f);

        var lamp=new Rectangle(r.X+7,r.Y+7,6,6);
        using(var lampFill=new SolidBrush(lit?color:Color.FromArgb(38,48,53))) g.FillRectangle(lampFill,lamp);
        using(var lampEdge=new Pen(lit?Color.FromArgb(125,color):Theme.EdgeLo)) g.DrawRectangle(lampEdge,lamp);
        if(lit)
        {
            using var hi=new Pen(Color.FromArgb(115,255,255,255));
            g.DrawLine(hi,lamp.Left+1,lamp.Top+1,lamp.Right-1,lamp.Top+1);
        }

        TextRenderer.DrawText(g,label,labelFont,new Rectangle(r.X+18,r.Y+4,Math.Max(0,r.Width-23),11),Theme.Muted,
            TextFormatFlags.EndEllipsis|TextFormatFlags.NoPadding|TextFormatFlags.SingleLine);
        TextRenderer.DrawText(g,value,valueFont,new Rectangle(r.X+7,r.Y+16,Math.Max(0,r.Width-14),14),color,
            TextFormatFlags.EndEllipsis|TextFormatFlags.NoPadding|TextFormatFlags.SingleLine);

        if(!string.IsNullOrWhiteSpace(sub)&&r.Height>=39)
            TextRenderer.DrawText(g,sub,tinyFont,new Rectangle(r.X+7,r.Y+30,Math.Max(0,r.Width-14),10),Color.FromArgb(89,104,111),
                TextFormatFlags.EndEllipsis|TextFormatFlags.NoPadding|TextFormatFlags.SingleLine);
    }
}

using System.Reflection;
using System.Runtime.CompilerServices;
using StatefulClanker.Tray;

static class Program
{
    [STAThread]
    static void Main()
    {
        // Skip MainForm's service-starting constructor. Exercise its real watcher
        // callback against a real native UI pump, without touching worker state.
        var mainType = typeof(WatcherRefreshGate).Assembly.GetType("StatefulClanker.Tray.MainForm")!;
        var main = RuntimeHelpers.GetUninitializedObject(mainType);
        var gate = new WatcherRefreshGate();
        mainType.GetField("_watcherRefreshGate", BindingFlags.Instance | BindingFlags.NonPublic)!.SetValue(main, gate);
        var callback = mainType.GetMethod("QueueWatcherRefresh", BindingFlags.Instance | BindingFlags.NonPublic)!.CreateDelegate<Action>(main);
        using var form = new Form();
        using var heartbeat = new System.Windows.Forms.Timer { Interval = 20 };
        using var poll = new System.Windows.Forms.Timer { Interval = 400 };
        using var timeout = new System.Windows.Forms.Timer { Interval = 10000 };
        int beats = 0, refreshes = 0;
        Task burst = Task.CompletedTask;
        bool passed = false;
        heartbeat.Tick += (_, _) => beats++;
        poll.Tick += (_, _) =>
        {
            if (gate.TryBeginRefresh()) { refreshes++; gate.CompleteRefresh(); }
            if (burst.IsCompleted && beats >= 5 && refreshes > 0)
            {
                burst.GetAwaiter().GetResult();
                passed = true;
                form.Close();
            }
        };
        timeout.Tick += (_, _) => form.Close();
        form.Shown += (_, _) =>
        {
            heartbeat.Start(); poll.Start(); timeout.Start();
            burst = Task.Run(() => Parallel.For(0, 1000000, _ => callback()));
        };
        Application.Run(form);
        if (!passed) throw new Exception($"UI pump starved under watcher storm: heartbeats={beats}, refreshes={refreshes}");
        Console.WriteLine($"PASS: native UI pump remained responsive during 1,000,000 actual watcher callbacks ({beats} heartbeats, {refreshes} refreshes).");
    }
}

namespace StatefulClanker.Tray;

// Watcher threads only set a bit. The UI timer consumes it without posting work
// for each event, and changes arriving during a refresh remain pending.
public sealed class WatcherRefreshGate : IDisposable
{
    const int Dirty = 1, Running = 2, Disposed = 4;
    int _state;

    public void MarkDirty()
    {
        while (true)
        {
            var state = Volatile.Read(ref _state);
            if ((state & (Dirty | Disposed)) != 0) return;
            if (Interlocked.CompareExchange(ref _state, state | Dirty, state) == state) return;
        }
    }

    public bool TryBeginRefresh()
    {
        return Interlocked.CompareExchange(ref _state, Running, Dirty) == Dirty;
    }

    public void CompleteRefresh()
    {
        while (true)
        {
            var state = Volatile.Read(ref _state);
            if (Interlocked.CompareExchange(ref _state, state & ~Running, state) == state) return;
        }
    }

    public void Dispose() => Interlocked.Exchange(ref _state, Disposed);
}

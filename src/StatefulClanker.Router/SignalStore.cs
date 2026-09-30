using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace StatefulClanker.Router;

public sealed class SignalStore
{
    static readonly JsonSerializerOptions Json=new(){PropertyNameCaseInsensitive=true};
    readonly string _dir;
    readonly Mutex _mutex;

    public SignalStore(string routerRoot)
    {
        var root=RouterRoot.Normalize(routerRoot);
        _dir=Path.Combine(root,"routing","signals");
        Directory.CreateDirectory(_dir);
        var hash=Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(RouterRoot.Identity(root)))).ToLowerInvariant()[..16];
        _mutex=new Mutex(false,"Local\\StatefulClankerRouterSignals-"+hash);
    }

    public string Append(SignalEnvelope signal)
    {
        SignalEnvelopeValidator.Validate(signal);
        WithLock(() =>
        {
            Directory.CreateDirectory(_dir);
            var when=DateTimeOffset.Parse(signal.createdAt).UtcDateTime;
            var path=Path.Combine(_dir,when.ToString("yyyy-MM-dd")+".jsonl");
            File.AppendAllText(path,JsonSerializer.Serialize(signal,Json)+Environment.NewLine,new UTF8Encoding(false));
            return 0;
        });
        return signal.id;
    }

    public IReadOnlyList<SignalEnvelope> ReadRecent(int limit=200)
    {
        if(limit<=0 || !Directory.Exists(_dir)) return Array.Empty<SignalEnvelope>();
        return WithLock(() =>
        {
            var output=new List<SignalEnvelope>(Math.Min(limit,256));
            foreach(var file in Directory.GetFiles(_dir,"*.jsonl").OrderByDescending(x=>x,StringComparer.OrdinalIgnoreCase))
            {
                foreach(var line in File.ReadLines(file).Reverse())
                {
                    if(string.IsNullOrWhiteSpace(line)) continue;
                    try
                    {
                        var signal=JsonSerializer.Deserialize<SignalEnvelope>(line,Json);
                        if(signal is not null) output.Add(signal);
                    }
                    catch(JsonException){}
                    if(output.Count>=limit) return (IReadOnlyList<SignalEnvelope>)output;
                }
            }
            return (IReadOnlyList<SignalEnvelope>)output;
        });
    }

    T WithLock<T>(Func<T> action)
    {
        var held=false;
        try
        {
            try{held=_mutex.WaitOne(TimeSpan.FromSeconds(10));}
            catch(AbandonedMutexException){held=true;}
            if(!held) throw new TimeoutException("Timed out waiting for router signal lock.");
            return action();
        }
        finally{if(held) try{_mutex.ReleaseMutex();}catch{}}
    }
}

using System.Text.Json;

namespace StatefulClanker.Router;

public sealed class SignalAddress
{
    public string type { get; set; } = "";
    public string id { get; set; } = "";
    public string? qualifier { get; set; }
}

public sealed class SignalEnvelope
{
    public int schemaVersion { get; set; } = 1;
    public string id { get; set; } = "sig-" + Guid.NewGuid().ToString("N");
    public string domain { get; set; } = "routing";
    public string kind { get; set; } = "";
    public string createdAt { get; set; } = DateTimeOffset.UtcNow.ToString("O");
    public Dictionary<string,object?> source { get; set; } = new(StringComparer.OrdinalIgnoreCase);
    public Dictionary<string,object?> subject { get; set; } = new(StringComparer.OrdinalIgnoreCase);
    public List<SignalAddress> audience { get; set; } = new();
    public string authority { get; set; } = "observed";
    public string scope { get; set; } = "request";
    public Dictionary<string,object?> freshness { get; set; } = new(StringComparer.OrdinalIgnoreCase);
    public Dictionary<string,object?> payload { get; set; } = new(StringComparer.OrdinalIgnoreCase);

    public static SignalEnvelope Routing(
        string kind,
        string subjectType,
        string subjectId,
        string audienceType,
        string audienceId,
        string scope,
        Dictionary<string,object?>? payload=null,
        string authority="observed")
    {
        return new SignalEnvelope
        {
            domain="routing",
            kind=kind,
            source=new(StringComparer.OrdinalIgnoreCase){{"component","router"}},
            subject=new(StringComparer.OrdinalIgnoreCase){{"type",subjectType},{"id",subjectId}},
            audience=new(){new SignalAddress{type=audienceType,id=audienceId}},
            authority=authority,
            scope=scope,
            payload=payload ?? new(StringComparer.OrdinalIgnoreCase)
        };
    }
}

public static class SignalEnvelopeValidator
{
    static readonly HashSet<string> Domains=new(StringComparer.OrdinalIgnoreCase){"execution","routing","project"};
    static readonly HashSet<string> Authorities=new(StringComparer.OrdinalIgnoreCase){"observed","corrective","advisory","authoritative"};
    const int MaxPayloadChars=16384;

    public static void Validate(SignalEnvelope signal)
    {
        if(signal.schemaVersion!=1) throw new InvalidDataException("Signal schemaVersion must be 1.");
        Required(signal.id,"id");
        Required(signal.domain,"domain");
        Required(signal.kind,"kind");
        Required(signal.createdAt,"createdAt");
        Required(signal.authority,"authority");
        Required(signal.scope,"scope");
        if(!Domains.Contains(signal.domain)) throw new InvalidDataException("Unsupported signal domain: "+signal.domain);
        if(!Authorities.Contains(signal.authority)) throw new InvalidDataException("Unsupported signal authority: "+signal.authority);
        if(!DateTimeOffset.TryParse(signal.createdAt,out _)) throw new InvalidDataException("Signal createdAt is not a timestamp.");
        if(!signal.source.TryGetValue("component",out var component) || string.IsNullOrWhiteSpace(Convert.ToString(component))) throw new InvalidDataException("Signal source.component is required.");
        RequiredMapIdentity(signal.subject,"subject");
        if(signal.audience.Count==0) throw new InvalidDataException("Signal audience must contain at least one address.");
        foreach(var address in signal.audience){Required(address.type,"audience.type");Required(address.id,"audience.id");}
        var payload=JsonSerializer.Serialize(signal.payload);
        if(payload.Length>MaxPayloadChars) throw new InvalidDataException("Signal payload exceeds size limit.");
    }

    static void RequiredMapIdentity(Dictionary<string,object?> map,string name)
    {
        if(!map.TryGetValue("type",out var type) || string.IsNullOrWhiteSpace(Convert.ToString(type))) throw new InvalidDataException("Signal "+name+".type is required.");
        if(!map.TryGetValue("id",out var id) || string.IsNullOrWhiteSpace(Convert.ToString(id))) throw new InvalidDataException("Signal "+name+".id is required.");
    }

    static void Required(string? value,string name)
    {
        if(string.IsNullOrWhiteSpace(value)) throw new InvalidDataException("Signal "+name+" is required.");
    }
}

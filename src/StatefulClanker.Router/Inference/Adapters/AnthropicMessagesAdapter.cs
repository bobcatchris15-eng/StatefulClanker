using System.Text.Json;

namespace StatefulClanker.Router;

public sealed class AnthropicMessagesAdapter : IProviderAdapter
{
    public string Id => "anthropic-messages";
    public string SourcePath => "src/StatefulClanker.Router/Inference/Adapters/AnthropicMessagesAdapter.cs";

    public bool CanHandle(ConnectionProfile connection) =>
        string.Equals(connection.protocol,"anthropic-messages",StringComparison.OrdinalIgnoreCase);

    public AdapterRequest BuildRequest(ConnectionProfile connection,EndpointEntry endpoint,NormalizedInferenceRequest request,string? apiKey)
    {
        var baseUrl=(connection.baseUrl??"").TrimEnd('/');
        if(string.IsNullOrWhiteSpace(baseUrl)) throw new InvalidOperationException("Connection baseUrl is required.");
        var uri=baseUrl.EndsWith("/v1/messages",StringComparison.OrdinalIgnoreCase)
            ? baseUrl
            : baseUrl.EndsWith("/v1",StringComparison.OrdinalIgnoreCase)
                ? baseUrl+"/messages"
                : baseUrl+"/v1/messages";

        var body=new Dictionary<string,object?>
        {
            ["model"]=endpoint.model,
            ["max_tokens"]=Math.Clamp(request.maxOutputTokens,1,64),
            ["messages"]=new[]{new Dictionary<string,object?>{{"role","user"},{"content",request.prompt}}}
        };

        if(request.testTools)
        {
            body["tools"]=new[]
            {
                new Dictionary<string,object?>
                {
                    ["name"]="clanker_probe",
                    ["description"]="Harmless endpoint diagnostic tool.",
                    ["input_schema"]=new Dictionary<string,object?>
                    {
                        ["type"]="object",
                        ["properties"]=new Dictionary<string,object?>()
                    }
                }
            };
        }

        var message=AdapterHttp.JsonRequest(
            HttpMethod.Post,uri,connection,apiKey,body,
            "anthropic-messages",
            request.testTools?"native":"text");
        if(!message.Headers.Contains("anthropic-version"))
            message.Headers.TryAddWithoutValidation("anthropic-version","2023-06-01");

        // Refresh evidence after protocol-required headers are applied.
        var evidence=AdapterHttp.Evidence(message);
        if(!evidence.headersPresent.Contains("anthropic-version",StringComparer.OrdinalIgnoreCase))
        {
            evidence.headersPresent.Add("anthropic-version");
            evidence.headersPresent= evidence.headersPresent.OrderBy(x=>x,StringComparer.OrdinalIgnoreCase).ToList();
        }
        return new AdapterRequest(message,evidence);
    }

    public AdapterParseResult ParseSuccess(string body)
    {
        try
        {
            using var doc=JsonDocument.Parse(body);
            if(!doc.RootElement.TryGetProperty("content",out var content) ||
               content.ValueKind!=JsonValueKind.Array ||
               content.GetArrayLength()==0)
                return new(false,null,"Successful Anthropic response did not contain content.");

            var textParts=new List<string>();
            foreach(var part in content.EnumerateArray())
            {
                if(part.TryGetProperty("type",out var type) &&
                   string.Equals(type.GetString(),"text",StringComparison.OrdinalIgnoreCase) &&
                   part.TryGetProperty("text",out var text) &&
                   text.ValueKind==JsonValueKind.String)
                    textParts.Add(text.GetString()??"");
                else if(part.TryGetProperty("type",out type) &&
                        string.Equals(type.GetString(),"tool_use",StringComparison.OrdinalIgnoreCase))
                    textParts.Add("[tool_use]");
            }
            return textParts.Count>0
                ? new(true,string.Join("",textParts),null)
                : new(false,null,"Anthropic content contained no text or tool_use item.");
        }
        catch(Exception ex)
        {
            return new(false,null,"Could not parse Anthropic response: "+ex.Message);
        }
    }
}

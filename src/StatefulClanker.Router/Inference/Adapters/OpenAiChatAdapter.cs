using System.Text.Json;

namespace StatefulClanker.Router;

public sealed class OpenAiChatAdapter : IProviderAdapter
{
    public string Id => "openai-chat";
    public string SourcePath => "src/StatefulClanker.Router/Inference/Adapters/OpenAiChatAdapter.cs";

    public bool CanHandle(ConnectionProfile connection)
    {
        var p=(connection.protocol??"openai-chat").Trim().ToLowerInvariant();
        return p is "openai-chat" or "openai-completions" or "openai";
    }

    public AdapterRequest BuildRequest(ConnectionProfile connection,EndpointEntry endpoint,NormalizedInferenceRequest request,string? apiKey)
    {
        var baseUrl=(connection.baseUrl??"").TrimEnd('/');
        if(string.IsNullOrWhiteSpace(baseUrl)) throw new InvalidOperationException("Connection baseUrl is required.");
        var uri=baseUrl.EndsWith("/chat/completions",StringComparison.OrdinalIgnoreCase)
            ? baseUrl
            : baseUrl+"/chat/completions";

        var body=new Dictionary<string,object?>
        {
            ["model"]=endpoint.model,
            ["messages"]=new[]{new Dictionary<string,object?>{{"role","user"},{"content",request.prompt}}},
            ["max_tokens"]=Math.Clamp(request.maxOutputTokens,1,64),
            ["stream"]=false
        };

        if(request.testTools)
        {
            body["tools"]=new[]
            {
                new Dictionary<string,object?>
                {
                    ["type"]="function",
                    ["function"]=new Dictionary<string,object?>
                    {
                        ["name"]="clanker_probe",
                        ["description"]="Harmless endpoint diagnostic tool.",
                        ["parameters"]=new Dictionary<string,object?>
                        {
                            ["type"]="object",
                            ["properties"]=new Dictionary<string,object?>()
                        }
                    }
                }
            };
            body["tool_choice"]="auto";
        }

        var message=AdapterHttp.JsonRequest(
            HttpMethod.Post,uri,connection,apiKey,body,
            "openai-chat",
            request.testTools?"native":"text");
        return new AdapterRequest(message,AdapterHttp.Evidence(message));
    }

    public AdapterParseResult ParseSuccess(string body)
    {
        try
        {
            using var doc=JsonDocument.Parse(body);
            if(!doc.RootElement.TryGetProperty("choices",out var choices) ||
               choices.ValueKind!=JsonValueKind.Array ||
               choices.GetArrayLength()==0)
                return new(false,null,"Successful response did not contain choices.");

            var first=choices[0];
            if(!first.TryGetProperty("message",out var message))
                return new(false,null,"Successful response choice did not contain message.");

            if(message.TryGetProperty("content",out var content))
            {
                if(content.ValueKind==JsonValueKind.String) return new(true,content.GetString(),null);
                if(content.ValueKind==JsonValueKind.Array) return new(true,content.ToString(),null);
            }
            if(message.TryGetProperty("tool_calls",out var tools) && tools.ValueKind==JsonValueKind.Array)
                return new(true,"[tool_calls]",null);

            return new(false,null,"Successful response message contained neither content nor tool_calls.");
        }
        catch(Exception ex)
        {
            return new(false,null,"Could not parse OpenAI-compatible response: "+ex.Message);
        }
    }
}

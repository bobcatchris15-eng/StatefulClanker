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

        var system=new List<string>();
        var messages=new List<Dictionary<string,object?>>();
        List<object>? pendingResults=null;

        foreach(var m in request.messages)
        {
            var role=(m.role??"user").ToLowerInvariant();
            if(role=="system")
            {
                if(!string.IsNullOrWhiteSpace(m.content)) system.Add(m.content);
                continue;
            }
            if(role=="tool")
            {
                pendingResults ??= new();
                pendingResults.Add(new Dictionary<string,object?>
                {
                    ["type"]="tool_result",
                    ["tool_use_id"]=m.tool_call_id??"",
                    ["content"]=m.content??""
                });
                continue;
            }
            if(pendingResults is {Count:>0})
            {
                messages.Add(new Dictionary<string,object?>{{"role","user"},{"content",pendingResults.ToArray()}});
                pendingResults=null;
            }

            if(role=="assistant")
            {
                var blocks=new List<object>();
                if(!string.IsNullOrWhiteSpace(m.content))
                    blocks.Add(new Dictionary<string,object?>{{"type","text"},{"text",m.content}});
                foreach(var call in m.tool_calls??new())
                {
                    blocks.Add(new Dictionary<string,object?>
                    {
                        ["type"]="tool_use",
                        ["id"]=call.id,
                        ["name"]=call.function.name,
                        ["input"]=AdapterJson.ParseArguments(call.function.arguments)
                    });
                }
                messages.Add(new Dictionary<string,object?>{{"role","assistant"},{"content",blocks.ToArray()}});
            }
            else
            {
                messages.Add(new Dictionary<string,object?>{{"role","user"},{"content",m.content??""}});
            }
        }
        if(pendingResults is {Count:>0})
            messages.Add(new Dictionary<string,object?>{{"role","user"},{"content",pendingResults.ToArray()}});

        var body=new Dictionary<string,object?>
        {
            ["model"]=endpoint.model,
            ["max_tokens"]=Math.Clamp(request.maxOutputTokens,1,131072),
            ["messages"]=messages
        };
        if(system.Count>0) body["system"]=string.Join("\n\n",system);
        if(request.temperature is not null) body["temperature"]=request.temperature.Value;
        if(!string.Equals(request.toolMode,"text",StringComparison.OrdinalIgnoreCase) && request.tools.Count>0)
        {
            body["tools"]=request.tools.Select(t=>(object)new Dictionary<string,object?>
            {
                ["name"]=t.function.name,
                ["description"]=t.function.description,
                ["input_schema"]=t.function.parameters
            }).ToArray();
        }

        var message=AdapterHttp.JsonRequest(
            HttpMethod.Post,uri,connection,apiKey,body,
            "anthropic-messages",request.toolMode,request.sessionKey);
        if(!message.Headers.Contains("anthropic-version"))
            message.Headers.TryAddWithoutValidation("anthropic-version","2023-06-01");

        var evidence=AdapterHttp.Evidence(message);
        if(!evidence.headersPresent.Contains("anthropic-version",StringComparer.OrdinalIgnoreCase))
        {
            evidence.headersPresent.Add("anthropic-version");
            evidence.headersPresent=evidence.headersPresent.OrderBy(x=>x,StringComparer.OrdinalIgnoreCase).ToList();
        }
        return new AdapterRequest(message,evidence);
    }

    public AdapterParseResult ParseSuccess(string body,EndpointEntry endpoint)
    {
        try
        {
            using var doc=JsonDocument.Parse(body);
            var root=doc.RootElement;
            if(!root.TryGetProperty("content",out var content) || content.ValueKind!=JsonValueKind.Array)
                return new(false,null,new(){model=endpoint.model},"Successful Anthropic response did not contain content.");

            var assistant=new NormalizedInferenceMessage{role="assistant",tool_calls=new()};
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
                {
                    var input=part.TryGetProperty("input",out var inputEl)?inputEl.GetRawText():"{}";
                    assistant.tool_calls.Add(new NormalizedToolCall
                    {
                        id=part.TryGetProperty("id",out var id)?id.GetString()??Guid.NewGuid().ToString("N"):Guid.NewGuid().ToString("N"),
                        type="function",
                        function=new NormalizedFunctionCall
                        {
                            name=part.TryGetProperty("name",out var name)?name.GetString()??"":"",
                            arguments=input
                        }
                    });
                }
            }
            assistant.content=textParts.Count>0?string.Join("\n",textParts):"";

            var usage=new NormalizedUsage{model=endpoint.model};
            if(root.TryGetProperty("usage",out var usageEl) && usageEl.ValueKind==JsonValueKind.Object)
            {
                usage.promptTokens=AdapterJson.Long(usageEl,"input_tokens");
                usage.completionTokens=AdapterJson.Long(usageEl,"output_tokens");
                usage.totalTokens=usage.promptTokens+usage.completionTokens;
                usage.reported=true;
            }
            var hasContent=!string.IsNullOrWhiteSpace(assistant.content);
            var hasTools=assistant.tool_calls.Count>0;
            return hasContent||hasTools
                ? new(true,assistant,usage,null)
                : new(false,null,usage,"Anthropic content contained no text or tool_use item.");
        }
        catch(Exception ex)
        {
            return new(false,null,new(){model=endpoint.model},"Could not parse Anthropic response: "+ex.Message);
        }
    }
}

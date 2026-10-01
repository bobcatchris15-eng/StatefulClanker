using System.Text.Json;

namespace StatefulClanker.Router;

public sealed class GeminiNativeAdapter : IProviderAdapter
{
    public string Id => "gemini-native";
    public string SourcePath => "src/StatefulClanker.Router/Inference/Adapters/GeminiNativeAdapter.cs";

    public bool CanHandle(ConnectionProfile connection) =>
        string.Equals(connection.protocol,"gemini-native",StringComparison.OrdinalIgnoreCase);

    public AdapterRequest BuildRequest(ConnectionProfile connection,EndpointEntry endpoint,NormalizedInferenceRequest request,string? apiKey)
    {
        var baseUrl=(connection.baseUrl??"").TrimEnd('/');
        if(string.IsNullOrWhiteSpace(baseUrl)) throw new InvalidOperationException("Connection baseUrl is required.");
        var rawModel=endpoint.model??"";
        var model=rawModel.StartsWith("models/",StringComparison.OrdinalIgnoreCase)
            ? rawModel["models/".Length..]
            : rawModel;
        var uri=baseUrl.Contains(":generateContent",StringComparison.OrdinalIgnoreCase)
            ? baseUrl
            : baseUrl+"/models/"+Uri.EscapeDataString(model)+":generateContent";

        var system=new List<string>();
        var contents=new List<Dictionary<string,object?>>();
        var callNames=new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase);

        foreach(var m in request.messages)
        {
            var role=(m.role??"user").ToLowerInvariant();
            if(role=="system")
            {
                if(!string.IsNullOrWhiteSpace(m.content)) system.Add(m.content);
                continue;
            }
            if(role=="assistant")
            {
                var parts=new List<object>();
                if(!string.IsNullOrWhiteSpace(m.content))
                    parts.Add(new Dictionary<string,object?>{{"text",m.content}});
                foreach(var call in m.tool_calls??new())
                {
                    if(!string.IsNullOrWhiteSpace(call.id)) callNames[call.id]=call.function.name;
                    var part=new Dictionary<string,object?>
                    {
                        ["functionCall"]=new Dictionary<string,object?>
                        {
                            ["name"]=call.function.name,
                            ["args"]=AdapterJson.ParseArguments(call.function.arguments)
                        }
                    };
                    if(!string.IsNullOrWhiteSpace(call.thought_signature))
                        part["thoughtSignature"]=call.thought_signature;
                    parts.Add(part);
                }
                if(parts.Count>0)
                    contents.Add(new Dictionary<string,object?>{{"role","model"},{"parts",parts.ToArray()}});
                continue;
            }
            if(role=="tool")
            {
                var name=!string.IsNullOrWhiteSpace(m.tool_call_id) && callNames.TryGetValue(m.tool_call_id,out var mapped)
                    ? mapped
                    : "tool";
                contents.Add(new Dictionary<string,object?>
                {
                    ["role"]="user",
                    ["parts"]=new[]{new Dictionary<string,object?>
                    {
                        ["functionResponse"]=new Dictionary<string,object?>
                        {
                            ["name"]=name,
                            ["response"]=new Dictionary<string,object?>{{"result",m.content??""}}
                        }
                    }}
                });
                continue;
            }
            contents.Add(new Dictionary<string,object?>
            {
                ["role"]="user",
                ["parts"]=new[]{new Dictionary<string,object?>{{"text",m.content??""}}}
            });
        }

        var body=new Dictionary<string,object?>{{"contents",contents}};
        if(system.Count>0)
            body["systemInstruction"]=new Dictionary<string,object?>
            {
                ["parts"]=new[]{new Dictionary<string,object?>{{"text",string.Join("\n\n",system)}}}
            };
        if(!string.Equals(request.toolMode,"text",StringComparison.OrdinalIgnoreCase) && request.tools.Count>0)
        {
            body["tools"]=new[]
            {
                new Dictionary<string,object?>
                {
                    ["functionDeclarations"]=request.tools.Select(t=>(object)new Dictionary<string,object?>
                    {
                        ["name"]=t.function.name,
                        ["description"]=t.function.description,
                        ["parameters"]=t.function.parameters
                    }).ToArray()
                }
            };
            body["toolConfig"]=new Dictionary<string,object?>
            {
                ["functionCallingConfig"]=new Dictionary<string,object?>{{"mode","AUTO"}}
            };
        }
        var generation=new Dictionary<string,object?>{{"maxOutputTokens",Math.Clamp(request.maxOutputTokens,1,131072)}};
        if(request.temperature is not null) generation["temperature"]=request.temperature.Value;
        body["generationConfig"]=generation;

        var message=AdapterHttp.JsonRequest(
            HttpMethod.Post,uri,connection,apiKey,body,
            "gemini-native",request.toolMode,request.sessionKey);
        return new AdapterRequest(message,AdapterHttp.Evidence(message));
    }

    public AdapterParseResult ParseSuccess(string body,EndpointEntry endpoint)
    {
        try
        {
            using var doc=JsonDocument.Parse(body);
            var root=doc.RootElement;
            var usage=new NormalizedUsage{model=endpoint.model};
            if(root.TryGetProperty("usageMetadata",out var usageEl) && usageEl.ValueKind==JsonValueKind.Object)
            {
                usage.promptTokens=AdapterJson.Long(usageEl,"promptTokenCount");
                usage.completionTokens=AdapterJson.Long(usageEl,"candidatesTokenCount");
                usage.totalTokens=AdapterJson.Long(usageEl,"totalTokenCount");
                if(usage.totalTokens<=0) usage.totalTokens=usage.promptTokens+usage.completionTokens;
                usage.reported=true;
            }
            if(!root.TryGetProperty("candidates",out var candidates) ||
               candidates.ValueKind!=JsonValueKind.Array ||
               candidates.GetArrayLength()==0)
                return new(false,null,new(){model=endpoint.model},"Successful Gemini response did not contain candidates.");

            var candidate=candidates[0];
            if(!candidate.TryGetProperty("content",out var content) ||
               !content.TryGetProperty("parts",out var parts) ||
               parts.ValueKind!=JsonValueKind.Array)
                return new(false,null,new(){model=endpoint.model},"Successful Gemini candidate did not contain content.parts.");

            var assistant=new NormalizedInferenceMessage{role="assistant",tool_calls=new()};
            var textParts=new List<string>();
            var n=0;
            foreach(var part in parts.EnumerateArray())
            {
                if(part.TryGetProperty("text",out var text) && text.ValueKind==JsonValueKind.String)
                    textParts.Add(text.GetString()??"");
                if(part.TryGetProperty("functionCall",out var fc))
                {
                    if(fc.ValueKind!=JsonValueKind.Object)
                        return new(false,null,usage,"Provider returned invalid functionCall shape.",null,"invalid_tool_arguments");
                    n++;
                    var name=fc.TryGetProperty("name",out var nameEl) && nameEl.ValueKind==JsonValueKind.String?nameEl.GetString()??"":"";
                    var args=fc.TryGetProperty("args",out var argsEl)?argsEl.GetRawText():"{}";
                    var call=new NormalizedToolCall
                    {
                        id=$"gemini-{n}-{name}",
                        type="function",
                        function=new NormalizedFunctionCall{name=name,arguments=args}
                    };
                    if(part.TryGetProperty("thoughtSignature",out var sig) && sig.ValueKind==JsonValueKind.String)
                        call.thought_signature=sig.GetString();
                    else if(part.TryGetProperty("thought_signature",out sig) && sig.ValueKind==JsonValueKind.String)
                        call.thought_signature=sig.GetString();
                    assistant.tool_calls.Add(call);
                }
            }
            assistant.content=textParts.Count>0?string.Join("\n",textParts):"";

            if(InferenceRequestValidator.Validate(new(){messages=new(){assistant}}) is not null)
                return new(false,null,usage,"Provider returned invalid tool call name or JSON object arguments.",null,"invalid_tool_arguments");
            var hasContent=!string.IsNullOrWhiteSpace(assistant.content);
            var hasTools=assistant.tool_calls.Count>0;
            return hasContent||hasTools
                ? new(true,assistant,usage,null)
                : new(false,null,usage,"Gemini candidate contained no text or functionCall.");
        }
        catch(Exception ex)
        {
            return new(false,null,new(){model=endpoint.model},"Could not parse Gemini response: "+ex.Message);
        }
    }
}

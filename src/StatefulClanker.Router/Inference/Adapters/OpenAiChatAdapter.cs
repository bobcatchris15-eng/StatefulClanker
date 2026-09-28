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
            ["messages"]=request.messages,
            ["max_tokens"]=Math.Clamp(request.maxOutputTokens,1,131072),
            ["stream"]=false
        };
        if(request.temperature is not null) body["temperature"]=request.temperature.Value;
        if(!string.Equals(request.toolMode,"text",StringComparison.OrdinalIgnoreCase) && request.tools.Count>0)
        {
            body["tools"]=request.tools;
            body["tool_choice"]="auto";
        }
        if(uri.Contains("openrouter.ai",StringComparison.OrdinalIgnoreCase))
            body["usage"]=new Dictionary<string,object?>{{"include",true}};

        var message=AdapterHttp.JsonRequest(
            HttpMethod.Post,uri,connection,apiKey,body,
            "openai-chat",request.toolMode,request.sessionKey);
        return new AdapterRequest(message,AdapterHttp.Evidence(message));
    }

    public AdapterParseResult ParseSuccess(string body,EndpointEntry endpoint)
    {
        try
        {
            using var doc=JsonDocument.Parse(body);
            var root=doc.RootElement;
            if(!root.TryGetProperty("choices",out var choices) ||
               choices.ValueKind!=JsonValueKind.Array ||
               choices.GetArrayLength()==0)
                return new(false,null,new(){model=endpoint.model},"Successful response did not contain choices.");

            var first=choices[0];
            if(!first.TryGetProperty("message",out var message))
                return new(false,null,new(){model=endpoint.model},"Successful response choice did not contain message.");

            var assistant=new NormalizedInferenceMessage{role="assistant"};
            if(message.TryGetProperty("content",out var content))
            {
                if(content.ValueKind==JsonValueKind.String) assistant.content=content.GetString();
                else if(content.ValueKind!=JsonValueKind.Null) assistant.content=content.GetRawText();
            }
            if(message.TryGetProperty("tool_calls",out var toolCalls) && toolCalls.ValueKind==JsonValueKind.Array)
            {
                assistant.tool_calls=new();
                foreach(var call in toolCalls.EnumerateArray())
                {
                    if(!call.TryGetProperty("function",out var fn)) continue;
                    var normalized=new NormalizedToolCall
                    {
                        id=call.TryGetProperty("id",out var id)?id.GetString()??"":Guid.NewGuid().ToString("N"),
                        type="function",
                        function=new NormalizedFunctionCall
                        {
                            name=fn.TryGetProperty("name",out var name)?name.GetString()??"":"",
                            arguments=fn.TryGetProperty("arguments",out var args)
                                ? (args.ValueKind==JsonValueKind.String?args.GetString()??"{}":args.GetRawText())
                                : "{}"
                        }
                    };
                    if(call.TryGetProperty("thought_signature",out var sig) && sig.ValueKind==JsonValueKind.String)
                        normalized.thought_signature=sig.GetString();
                    assistant.tool_calls.Add(normalized);
                }
            }

            var model=root.TryGetProperty("model",out var modelEl) && modelEl.ValueKind==JsonValueKind.String
                ? modelEl.GetString()
                : endpoint.model;
            var usage=new NormalizedUsage{model=model};
            if(root.TryGetProperty("usage",out var usageEl) && usageEl.ValueKind==JsonValueKind.Object)
            {
                usage.promptTokens=AdapterJson.Long(usageEl,"prompt_tokens","input_tokens");
                usage.completionTokens=AdapterJson.Long(usageEl,"completion_tokens","output_tokens");
                usage.totalTokens=AdapterJson.Long(usageEl,"total_tokens");
                if(usage.totalTokens<=0) usage.totalTokens=usage.promptTokens+usage.completionTokens;
                usage.reported=true;
            }
            var hasContent=!string.IsNullOrWhiteSpace(assistant.content);
            var hasTools=assistant.tool_calls is {Count:>0};
            return hasContent||hasTools
                ? new(true,assistant,usage,null)
                : new(false,null,usage,"Successful response message contained neither content nor tool_calls.");
        }
        catch(Exception ex)
        {
            return new(false,null,new(){model=endpoint.model},"Could not parse OpenAI-compatible response: "+ex.Message);
        }
    }
}

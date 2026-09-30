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
            ["messages"]=request.messages.Select(ToWireMessage).ToArray(),
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

    static Dictionary<string,object?> ToWireMessage(NormalizedInferenceMessage message)
    {
        var wire=new Dictionary<string,object?>
        {
            ["role"]=message.role,
            ["content"]=message.content
        };
        if(message.tool_call_id is not null) wire["tool_call_id"]=message.tool_call_id;
        if(message.tool_calls is not null)
            wire["tool_calls"]=message.tool_calls.Select(call=>
            {
                var tool=new Dictionary<string,object?>
                {
                    ["id"]=call.id,
                    ["type"]=call.type,
                    ["function"]=call.function
                };
                if(call.thought_signature is not null) tool["thought_signature"]=call.thought_signature;
                return tool;
            }).ToArray();
        return wire;
    }

    public AdapterParseResult ParseSuccess(string body,EndpointEntry endpoint)
    {
        var usage=new NormalizedUsage{model=endpoint.model};
        try
        {
            using var doc=JsonDocument.Parse(body);
            var root=doc.RootElement;
            var model=root.TryGetProperty("model",out var modelEl) && modelEl.ValueKind==JsonValueKind.String
                ? modelEl.GetString()
                : endpoint.model;
            usage.model=model;
            if(root.TryGetProperty("usage",out var usageEl) && usageEl.ValueKind==JsonValueKind.Object)
            {
                usage.promptTokens=AdapterJson.Long(usageEl,"prompt_tokens","input_tokens");
                usage.completionTokens=AdapterJson.Long(usageEl,"completion_tokens","output_tokens");
                usage.totalTokens=AdapterJson.Long(usageEl,"total_tokens");
                if(usage.totalTokens<=0) usage.totalTokens=usage.promptTokens+usage.completionTokens;
                usage.reported=true;
            }
            if(root.TryGetProperty("error",out var error) && error.ValueKind==JsonValueKind.Object)
            {
                int? status=null;
                if(error.TryGetProperty("code",out var code))
                {
                    if(code.ValueKind==JsonValueKind.Number && code.TryGetInt32(out var number)) status=number;
                    else if(code.ValueKind==JsonValueKind.String && int.TryParse(code.GetString(),out number)) status=number;
                }
                var detail=error.GetRawText();
                return new(false,null,usage,detail,status,FailurePolicy.Classify(detail,status),true);
            }
            if(!root.TryGetProperty("choices",out var choices) ||
               choices.ValueKind!=JsonValueKind.Array ||
               choices.GetArrayLength()==0)
                return new(false,null,usage,"Successful response did not contain choices.");

            var first=choices[0];
            var exhausted=first.TryGetProperty("finish_reason",out var finish) && finish.ValueKind==JsonValueKind.String && finish.GetString()=="length";
            if(!first.TryGetProperty("message",out var message))
                return new(false,null,usage,"Successful response choice did not contain message.");

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

            var hasContent=!string.IsNullOrWhiteSpace(assistant.content);
            var hasTools=assistant.tool_calls is {Count:>0};
            if(hasTools)
                foreach(var call in assistant.tool_calls!)
                {
                    try
                    {
                        using var arguments=JsonDocument.Parse(call.function.arguments);
                        if(arguments.RootElement.ValueKind!=JsonValueKind.Object) throw new JsonException("Tool arguments must be a JSON object.");
                    }
                    catch(JsonException)
                    {
                        return new(false,null,usage,"Provider returned invalid JSON object tool arguments.",null,
                            exhausted?"output_budget_exhausted":"invalid_tool_arguments");
                    }
                }
            return hasContent||hasTools
                ? new(true,assistant,usage,null)
                : new(false,null,usage,"Successful response message contained neither content nor tool_calls.",null,
                    exhausted?"output_budget_exhausted":null);
        }
        catch(Exception ex)
        {
            return new(false,null,usage,"Could not parse OpenAI-compatible response: "+ex.Message);
        }
    }
}

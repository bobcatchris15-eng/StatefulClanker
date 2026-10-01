using System.Text.Json;
using System.Text.RegularExpressions;

namespace StatefulClanker.Router;

public static class InferenceRequestValidator
{
    public static bool IsValidFunctionName(string? name) => name is not null &&
        Regex.IsMatch(name, @"\A[A-Za-z_][A-Za-z0-9_.-]{0,63}\z", RegexOptions.CultureInvariant);

    public static NormalizedInferenceResult InvalidRequest(string summary) => Failure("invalid_inference_request", "INVALID_INFERENCE_REQUEST", summary);

    static NormalizedInferenceResult Failure(string failureClass, string reasonCode, string summary) => new()
    {
        ok=false,
        diagnosis=new(){failureClass=failureClass,scope="request",reasonCode=reasonCode,summary=summary}
    };

    public static NormalizedInferenceResult? Validate(NormalizedInferenceRequest request)
    {
        if(request is null || request.messages is null)
            return InvalidRequest("Inference request messages and tools must be arrays.");
        if(request.toolMode is not ("text" or "native"))
            return InvalidRequest("Inference request toolMode must be text or native.");
        // Older PowerShell text-mode clients serialize an empty tool list as null.
        if(request.tools is null && request.toolMode=="text") request.tools=new();
        if(request.tools is null) return InvalidRequest("Native inference request tools must be an array.");
        foreach(var tool in request.tools)
        {
            if(tool is null || tool.type!="function" || tool.function is null ||
                !IsValidFunctionName(tool.function.name) || tool.function.parameters.ValueKind!=JsonValueKind.Object)
                return InvalidRequest("Tools require type function and a function object with a valid name and object parameters schema.");
            if(tool.function.parameters.TryGetProperty("type",out var type) &&
                (type.ValueKind!=JsonValueKind.String || type.GetString()!="object"))
                return InvalidRequest("Tool parameters schema type must be object.");
        }
        foreach(var message in request.messages)
        {
            if(message is null || message.role is not ("user" or "assistant" or "system" or "developer" or "tool"))
                return InvalidRequest("Inference messages require a supported role.");
            if(message.tool_calls is null) continue;
            foreach(var call in message.tool_calls)
            {
                if(call is null || call.type!="function" || call.function is null ||
                    !IsValidFunctionName(call.function.name) || !IsObjectArguments(call.function.arguments))
                    return Failure("corrupt_input", "CORRUPT_INPUT_TOOL_CALL", "Saved message tool calls require a valid function name and JSON object arguments.");
            }
        }
        return null;
    }

    static bool IsObjectArguments(string? arguments)
    {
        if(string.IsNullOrWhiteSpace(arguments)) return false;
        try{using var document=JsonDocument.Parse(arguments);return document.RootElement.ValueKind==JsonValueKind.Object;}
        catch(JsonException){return false;}
    }
}

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
        var model=(endpoint.model??"").StartsWith("models/",StringComparison.OrdinalIgnoreCase)
            ? endpoint.model["models/".Length..]
            : endpoint.model;
        var uri=baseUrl.Contains(":generateContent",StringComparison.OrdinalIgnoreCase)
            ? baseUrl
            : baseUrl+"/models/"+Uri.EscapeDataString(model)+":generateContent";

        var body=new Dictionary<string,object?>
        {
            ["contents"]=new[]
            {
                new Dictionary<string,object?>
                {
                    ["role"]="user",
                    ["parts"]=new[]{new Dictionary<string,object?>{{"text",request.prompt}}}
                }
            },
            ["generationConfig"]=new Dictionary<string,object?>
            {
                ["maxOutputTokens"]=Math.Clamp(request.maxOutputTokens,1,64)
            }
        };

        if(request.testTools)
        {
            body["tools"]=new[]
            {
                new Dictionary<string,object?>
                {
                    ["functionDeclarations"]=new[]
                    {
                        new Dictionary<string,object?>
                        {
                            ["name"]="clanker_probe",
                            ["description"]="Harmless endpoint diagnostic tool.",
                            ["parameters"]=new Dictionary<string,object?>
                            {
                                ["type"]="OBJECT",
                                ["properties"]=new Dictionary<string,object?>()
                            }
                        }
                    }
                }
            };
        }

        var message=AdapterHttp.JsonRequest(
            HttpMethod.Post,uri,connection,apiKey,body,
            "gemini-native",
            request.testTools?"native":"text");
        return new AdapterRequest(message,AdapterHttp.Evidence(message));
    }

    public AdapterParseResult ParseSuccess(string body)
    {
        try
        {
            using var doc=JsonDocument.Parse(body);
            if(!doc.RootElement.TryGetProperty("candidates",out var candidates) ||
               candidates.ValueKind!=JsonValueKind.Array ||
               candidates.GetArrayLength()==0)
                return new(false,null,"Successful Gemini response did not contain candidates.");

            var candidate=candidates[0];
            if(!candidate.TryGetProperty("content",out var content) ||
               !content.TryGetProperty("parts",out var parts) ||
               parts.ValueKind!=JsonValueKind.Array)
                return new(false,null,"Successful Gemini candidate did not contain content.parts.");

            var textParts=new List<string>();
            foreach(var part in parts.EnumerateArray())
            {
                if(part.TryGetProperty("text",out var text) && text.ValueKind==JsonValueKind.String)
                    textParts.Add(text.GetString()??"");
                else if(part.TryGetProperty("functionCall",out _))
                    textParts.Add("[functionCall]");
            }
            return textParts.Count>0
                ? new(true,string.Join("",textParts),null)
                : new(false,null,"Gemini candidate contained no text or functionCall.");
        }
        catch(Exception ex)
        {
            return new(false,null,"Could not parse Gemini response: "+ex.Message);
        }
    }
}

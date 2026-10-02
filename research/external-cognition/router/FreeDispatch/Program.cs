using System.Globalization;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using StatefulClanker.Router;

namespace StatefulClanker.FreeDispatch;

public sealed class DispatchReceipt
{
    public int SchemaVersion { get; set; } = 1;
    public string Status { get; set; } = "failed";
    public bool Sent { get; set; }
    public string? Provider { get; set; }
    public string? ConnectionId { get; set; }
    public string? EndpointId { get; set; }
    public string? Model { get; set; }
    public string? FailureCode { get; set; }
    public int? HttpStatus { get; set; }
    public string? RequestSha256 { get; set; }
    public string? ResponseSha256 { get; set; }
    public string? ContentSha256 { get; set; }
    public string? ReturnedModel { get; set; }
    public string? FinishReason { get; set; }
    public bool ProviderError { get; set; }
    public bool AdapterSuccess { get; set; }
    public bool UsageReported { get; set; }
    public long? PromptTokens { get; set; }
    public long? CompletionTokens { get; set; }
    public long? TotalTokens { get; set; }
    public string? ProviderRequestId { get; set; }
    public string? StartedAt { get; set; }
    public string? FinishedAt { get; set; }
    public long? DurationMilliseconds { get; set; }
}

public sealed class FreeDispatcher
{
    public const string OpenRouterOrigin = "https://openrouter.ai/api/v1";
    public const string KiloFreeOrigin = "https://api.kilo.ai/api/gateway";
    static readonly JsonSerializerOptions WebJson = new(JsonSerializerDefaults.Web) { WriteIndented = true };
    static readonly JsonSerializerOptions RequestJson = new(JsonSerializerDefaults.Web) { PropertyNameCaseInsensitive = true };
    static readonly UTF8Encoding StrictUtf8 = new(false, true);

    readonly string _routerRoot;
    readonly Func<HttpMessageHandler>? _handlerFactory;
    readonly Func<ConnectionProfile, string?> _resolveKey;

    public FreeDispatcher(string? routerRoot = null, Func<HttpMessageHandler>? handlerFactory = null,
        Func<ConnectionProfile, string?>? resolveKey = null)
    {
        _routerRoot = Path.GetFullPath(routerRoot ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "StatefulClanker"));
        _handlerFactory = handlerFactory;
        _resolveKey = resolveKey ?? ConnectionCredentialResolver.ResolveKey;
    }

    public static HttpClientHandler CreateLiveHttpClientHandler() => new() { AllowAutoRedirect = false };

    public async Task<DispatchReceipt> DispatchAsync(string requestPath, string allowlistPath, string outputDirectory,
        int timeoutSeconds = 120, CancellationToken cancellationToken = default)
    {
        var receipt = new DispatchReceipt { StartedAt = DateTimeOffset.UtcNow.ToString("O") };
        var output = Path.GetFullPath(outputDirectory);
        try
        {
            if (IsWithin(output, _routerRoot))
                return Failed(receipt, "OUTPUT_INSIDE_ROUTER_ROOT");
            if (Directory.Exists(output) && Directory.EnumerateFileSystemEntries(output).Any())
                return Failed(receipt, "OUTPUT_DIRECTORY_NOT_EMPTY");
            if (timeoutSeconds is < 90 or > 300)
                return Fail(output, receipt, "TIMEOUT_OUT_OF_RANGE");

            var requestBytes = await File.ReadAllBytesAsync(requestPath, cancellationToken);
            var allowlistBytes = await File.ReadAllBytesAsync(allowlistPath, cancellationToken);
            Directory.CreateDirectory(output);
            WriteOnce(Path.Combine(output, "input.request.json"), requestBytes);
            WriteOnce(Path.Combine(output, "input.allowlist.json"), allowlistBytes);

            var selection = ParseSelection(allowlistBytes);
            receipt.Provider = selection.Provider;
            receipt.ConnectionId = selection.ConnectionId;
            receipt.EndpointId = selection.EndpointId;
            receipt.Model = selection.Model;
            var expectedOrigin = ExpectedOrigin(selection.Provider);
            if (selection.BaseUrl != expectedOrigin)
                return Fail(output, receipt, "ALLOWLIST_ORIGIN_MISMATCH");
            if (!selection.Model.EndsWith(":free", StringComparison.Ordinal))
                return Fail(output, receipt, "MODEL_NOT_FREE_SUFFIX");

            var catalogPath = Path.IsPathRooted(selection.CatalogPath)
                ? Path.GetFullPath(selection.CatalogPath)
                : Path.GetFullPath(selection.CatalogPath, Path.GetDirectoryName(Path.GetFullPath(allowlistPath))!);
            var catalogBytes = await File.ReadAllBytesAsync(catalogPath, cancellationToken);
            WriteOnce(Path.Combine(output, "input.catalog.json"), catalogBytes);
            var catalogHash = Sha256(catalogBytes);
            if (!string.Equals(catalogHash, selection.CatalogSha256, StringComparison.OrdinalIgnoreCase))
                return Fail(output, receipt, "CATALOG_HASH_MISMATCH");
            if (!CatalogAllows(selection, catalogBytes))
                return Fail(output, receipt, "MODEL_NOT_IN_FROZEN_FREE_CATALOG");

            NormalizedInferenceRequest? inference;
            try { inference = JsonSerializer.Deserialize<NormalizedInferenceRequest>(requestBytes, RequestJson); }
            catch (JsonException) { return Fail(output, receipt, "INVALID_REQUEST_JSON"); }
            if (inference is null || inference.messages is null || inference.messages.Count == 0)
                return Fail(output, receipt, "INVALID_NORMALIZED_REQUEST");
            var invalid = InferenceRequestValidator.Validate(inference);
            if (invalid is not null)
                return Fail(output, receipt, "INVALID_NORMALIZED_REQUEST");
            inference.timeoutSeconds = timeoutSeconds;

            // RouterStore's constructor creates its routing directory. Refuse an absent directory
            // so this read-only research path cannot initialize or mutate a production root.
            if (!Directory.Exists(Path.Combine(_routerRoot, "routing")))
                return Fail(output, receipt, "ROUTER_ROOT_NOT_INITIALIZED");
            var connections = new RouterStore(_routerRoot).LoadConnections();
            if (!connections.connections.TryGetValue(selection.ConnectionId, out var connection))
                return Fail(output, receipt, "CONNECTION_NOT_FOUND");
            if (!string.Equals(NormalizeBase(connection.baseUrl), expectedOrigin, StringComparison.Ordinal))
                return Fail(output, receipt, "CONNECTION_ORIGIN_MISMATCH");

            var registry = new ProviderAdapterRegistry();
            IProviderAdapter adapter;
            try { adapter = registry.Resolve(connection); }
            catch (InvalidOperationException) { return Fail(output, receipt, "NO_MATCHING_PROVIDER_ADAPTER"); }
            if (!string.Equals(adapter.Id, "openai-chat", StringComparison.Ordinal) &&
                !string.Equals(adapter.Id, "gemini-native", StringComparison.Ordinal))
                return Fail(output, receipt, "UNSUPPORTED_ADAPTER");

            var endpoint = new EndpointEntry
            {
                id = selection.EndpointId,
                connection = selection.ConnectionId,
                model = selection.Model,
                free = true,
                source = "research-free-catalog"
            };

            // The origin guard above intentionally precedes this secret resolver.
            var apiKey = _resolveKey(connection);
            using var adapterRequest = adapter.BuildRequest(connection, endpoint, inference, apiKey);
            if (!RequestUriAllowed(adapterRequest.message.RequestUri, expectedOrigin))
                return Fail(output, receipt, "BUILT_REQUEST_ORIGIN_MISMATCH");
            var outgoingBody = adapterRequest.message.Content is null
                ? Array.Empty<byte>()
                : await adapterRequest.message.Content.ReadAsByteArrayAsync(cancellationToken);
            receipt.RequestSha256 = Sha256(outgoingBody);
            var headerNames = adapterRequest.message.Headers.Select(h => h.Key)
                .Concat(adapterRequest.message.Content?.Headers.Select(h => h.Key) ?? Array.Empty<string>())
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .OrderBy(x => x, StringComparer.OrdinalIgnoreCase).ToArray();
            var requestMetadata = new
            {
                method = adapterRequest.message.Method.Method,
                uri = adapterRequest.message.RequestUri!.AbsoluteUri,
                header_names = headerNames,
                header_values_saved = false,
                body_sha256 = receipt.RequestSha256,
                timeout_seconds = timeoutSeconds,
                adapter = adapter.Id
            };
            WriteOnce(Path.Combine(output, "request.body.raw"), outgoingBody);
            WriteOnce(Path.Combine(output, "request.metadata.json"), JsonSerializer.SerializeToUtf8Bytes(requestMetadata, WebJson));

            using var handler = _handlerFactory?.Invoke() ?? CreateLiveHttpClientHandler();
            using var client = new HttpClient(handler, disposeHandler: false) { Timeout = TimeSpan.FromSeconds(timeoutSeconds) };
            using var requestDeadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            requestDeadline.CancelAfter(TimeSpan.FromSeconds(timeoutSeconds));
            receipt.Sent = true;
            var started = DateTimeOffset.UtcNow;
            var timer = System.Diagnostics.Stopwatch.StartNew();
            HttpResponseMessage response;
            try
            {
                response = await client.SendAsync(adapterRequest.message, HttpCompletionOption.ResponseHeadersRead, requestDeadline.Token);
            }
            catch (OperationCanceledException)
            {
                timer.Stop();
                receipt.DurationMilliseconds = timer.ElapsedMilliseconds;
                receipt.FinishedAt = DateTimeOffset.UtcNow.ToString("O");
                return Fail(output, receipt, "TRANSPORT_TIMEOUT");
            }
            catch (HttpRequestException)
            {
                timer.Stop();
                receipt.DurationMilliseconds = timer.ElapsedMilliseconds;
                receipt.FinishedAt = DateTimeOffset.UtcNow.ToString("O");
                return Fail(output, receipt, "TRANSPORT_FAILURE");
            }

            using (response)
            {
                receipt.HttpStatus = (int)response.StatusCode;
                var (responseBody, complete, readFailure) = await ReadBodyAsync(response.Content, requestDeadline.Token);
                receipt.ResponseSha256 = Sha256(responseBody);
                WriteOnce(Path.Combine(output, "response.body.raw"), responseBody);
                var safeHeaders = SafeResponseHeaders(response);
                receipt.ProviderRequestId = FindRequestId(safeHeaders);
                var responseMetadata = new
                {
                    status = (int)response.StatusCode,
                    reason = response.ReasonPhrase,
                    safe_headers = safeHeaders,
                    body_sha256 = receipt.ResponseSha256,
                    body_complete = complete,
                    transport_error = readFailure
                };
                WriteOnce(Path.Combine(output, "response.metadata.json"), JsonSerializer.SerializeToUtf8Bytes(responseMetadata, WebJson));
                timer.Stop();
                receipt.DurationMilliseconds = timer.ElapsedMilliseconds;
                receipt.FinishedAt = DateTimeOffset.UtcNow.ToString("O");
                if (!complete)
                    return Fail(output, receipt, readFailure == "timeout" ? "TRANSPORT_TIMEOUT" : "INCOMPLETE_RESPONSE_BODY");

                string responseText;
                try { responseText = StrictUtf8.GetString(responseBody); }
                catch (DecoderFallbackException) { return Fail(output, receipt, "RESPONSE_NOT_UTF8"); }
                var parsed = adapter.ParseSuccess(responseText, endpoint);
                receipt.ReturnedModel = parsed.Usage.model;
                receipt.ProviderError = parsed.ProviderError;
                receipt.AdapterSuccess = parsed.Success;
                receipt.UsageReported = parsed.Usage.reported;
                receipt.PromptTokens = parsed.Usage.reported ? parsed.Usage.promptTokens : null;
                receipt.CompletionTokens = parsed.Usage.reported ? parsed.Usage.completionTokens : null;
                receipt.TotalTokens = parsed.Usage.reported ? parsed.Usage.totalTokens : null;
                receipt.FinishReason = ReadFinishReason(responseText);
                if (!response.IsSuccessStatusCode)
                    return Fail(output, receipt, parsed.ProviderError ? "PROVIDER_ERROR" : "HTTP_STATUS_FAILURE");
                if (!parsed.Success || parsed.Assistant is null)
                    return Fail(output, receipt, parsed.ProviderError ? "PROVIDER_ERROR" : "ADAPTER_PARSE_FAILURE");
                if (parsed.Assistant.content is null)
                    return Fail(output, receipt, "NO_TEXT_ASSISTANT_CONTENT");
                var content = StrictUtf8.GetBytes(parsed.Assistant.content);
                WriteOnce(Path.Combine(output, "content.raw"), content);
                receipt.ContentSha256 = Sha256(content);
                receipt.Status = "completed";
                receipt.FailureCode = null;
                SaveReceipt(output, receipt);
                return receipt;
            }
        }
        catch (OutputConflictException)
        {
            return Failed(receipt, "OUTPUT_ARTIFACT_CONFLICT");
        }
        catch (DispatchInputException exception)
        {
            return Fail(output, receipt, exception.Code);
        }
        catch (OperationCanceledException)
        {
            receipt.FinishedAt = DateTimeOffset.UtcNow.ToString("O");
            return Fail(output, receipt, receipt.Sent ? "TRANSPORT_TIMEOUT" : "CANCELLED_BEFORE_SEND");
        }
        catch (UnauthorizedAccessException)
        {
            return Fail(output, receipt, "FILE_ACCESS_FAILURE");
        }
        catch (IOException)
        {
            return Fail(output, receipt, "FILE_IO_FAILURE");
        }
        catch (JsonException)
        {
            return Fail(output, receipt, "INVALID_INPUT_JSON");
        }
        catch
        {
            // Deliberately omit exception text: adapter/transport exceptions may contain sensitive data.
            return Fail(output, receipt, receipt.Sent ? "DISPATCH_FAILURE" : "INPUT_OR_SETUP_FAILURE");
        }
    }

    public static string ExpectedOrigin(string provider) => provider switch
    {
        "openrouter" => OpenRouterOrigin,
        "kilo-free" => KiloFreeOrigin,
        _ => throw new DispatchInputException("UNSUPPORTED_PROVIDER")
    };

    static AllowlistSelection ParseSelection(byte[] bytes)
    {
        using var doc = JsonDocument.Parse(bytes);
        var root = doc.RootElement;
        if (root.ValueKind != JsonValueKind.Object || GetInt(root, "schema_version") != 1)
            throw new DispatchInputException("INVALID_ALLOWLIST");
        var provider = GetString(root, "provider");
        var connection = GetString(root, "connection_id");
        var endpoint = GetString(root, "endpoint_id");
        var model = GetString(root, "model");
        var baseUrl = GetString(root, "base_url");
        var catalogPath = GetString(root, "catalog_path");
        var catalogHash = GetString(root, "catalog_sha256");
        if (provider is null || connection is null || endpoint is null || model is null || baseUrl is null || catalogPath is null || catalogHash is null)
            throw new DispatchInputException("INVALID_ALLOWLIST");
        return new AllowlistSelection(provider, connection, endpoint, model, baseUrl, catalogPath, catalogHash);
    }

    static bool CatalogAllows(AllowlistSelection selection, byte[] rawCatalog)
    {
        try
        {
            using var doc = JsonDocument.Parse(rawCatalog);
            var root = doc.RootElement;
            if (GetString(root, "url") != ExpectedOrigin(selection.Provider) + "/models") return false;
            if (!root.TryGetProperty("data", out var rows) || rows.ValueKind != JsonValueKind.Array) return false;
            foreach (var row in rows.EnumerateArray())
            {
                if (GetString(row, "id") != selection.Model) continue;
                if (!row.TryGetProperty("pricing", out var pricing) || pricing.ValueKind != JsonValueKind.Object) return false;
                if (!IsZero(pricing, "prompt") || !IsZero(pricing, "completion")) return false;
                if (selection.Provider == "kilo-free" && (!row.TryGetProperty("isFree", out var free) || free.ValueKind != JsonValueKind.True)) return false;
                if (row.TryGetProperty("isFree", out var optionalFree) && optionalFree.ValueKind == JsonValueKind.False) return false;
                return true;
            }
            return false;
        }
        catch (JsonException) { return false; }
        catch (DispatchInputException) { return false; }
    }

    static bool IsZero(JsonElement obj, string name)
    {
        if (!obj.TryGetProperty(name, out var value)) return false;
        if (value.ValueKind == JsonValueKind.Number) return value.TryGetDecimal(out var number) && number == 0m;
        return value.ValueKind == JsonValueKind.String &&
            decimal.TryParse(value.GetString(), NumberStyles.Number | NumberStyles.AllowExponent, CultureInfo.InvariantCulture, out var parsed) && parsed == 0m;
    }

    static bool RequestUriAllowed(Uri? uri, string origin)
    {
        if (uri is null || !uri.IsAbsoluteUri || uri.UserInfo.Length > 0 || uri.Query.Length > 0 || uri.Fragment.Length > 0) return false;
        var allowed = new Uri(origin + "/chat/completions", UriKind.Absolute);
        return string.Equals(uri.Scheme, allowed.Scheme, StringComparison.OrdinalIgnoreCase) &&
               string.Equals(uri.Host, allowed.Host, StringComparison.OrdinalIgnoreCase) && uri.Port == allowed.Port &&
               string.Equals(uri.AbsolutePath, allowed.AbsolutePath, StringComparison.Ordinal);
    }

    static string NormalizeBase(string baseUrl)
    {
        if (!Uri.TryCreate(baseUrl, UriKind.Absolute, out var uri) || uri.UserInfo.Length > 0 || uri.Query.Length > 0 || uri.Fragment.Length > 0)
            return "";
        return uri.GetLeftPart(UriPartial.Path).TrimEnd('/');
    }

    static string? GetString(JsonElement obj, string name) =>
        obj.ValueKind == JsonValueKind.Object && obj.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString() : null;

    static int GetInt(JsonElement obj, string name) =>
        obj.ValueKind == JsonValueKind.Object && obj.TryGetProperty(name, out var value) && value.TryGetInt32(out var number) ? number : 0;

    static async Task<(byte[] Body, bool Complete, string? Error)> ReadBodyAsync(HttpContent content, CancellationToken cancellationToken)
    {
        using var buffer = new MemoryStream();
        var chunk = new byte[8192];
        try
        {
            await using var stream = await content.ReadAsStreamAsync(cancellationToken);
            while (true)
            {
                var count = await stream.ReadAsync(chunk.AsMemory(0, chunk.Length), cancellationToken);
                if (count == 0) break;
                buffer.Write(chunk, 0, count);
            }
            return (buffer.ToArray(), true, null);
        }
        catch (OperationCanceledException) { return (buffer.ToArray(), false, "timeout"); }
        catch (HttpRequestException) { return (buffer.ToArray(), false, "transport"); }
        catch (IOException) { return (buffer.ToArray(), false, "transport"); }
    }

    static Dictionary<string, string[]> SafeResponseHeaders(HttpResponseMessage response)
    {
        var safeNames = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        { "Content-Type", "Date", "Retry-After", "Request-Id", "X-Request-Id", "X-OpenRouter-Request-Id", "X-Kilo-Request-Id" };
        var result = new Dictionary<string, string[]>(StringComparer.OrdinalIgnoreCase);
        foreach (var header in response.Headers.Concat(response.Content.Headers))
            if (safeNames.Contains(header.Key)) result[header.Key] = header.Value.ToArray();
        return result;
    }

    static string? FindRequestId(Dictionary<string, string[]> headers)
    {
        foreach (var name in new[] { "X-OpenRouter-Request-Id", "X-Kilo-Request-Id", "X-Request-Id", "Request-Id" })
            if (headers.TryGetValue(name, out var values) && values.Length > 0) return values[0];
        return null;
    }

    static string? ReadFinishReason(string body)
    {
        try
        {
            using var doc = JsonDocument.Parse(body);
            if (doc.RootElement.TryGetProperty("choices", out var choices) && choices.ValueKind == JsonValueKind.Array && choices.GetArrayLength() > 0 &&
                choices[0].TryGetProperty("finish_reason", out var finish) && finish.ValueKind == JsonValueKind.String)
                return finish.GetString();
        }
        catch (JsonException) { }
        return null;
    }

    DispatchReceipt Fail(string output, DispatchReceipt receipt, string code)
    {
        receipt.Status = "failed";
        receipt.FailureCode = code;
        if (receipt.FinishedAt is null) receipt.FinishedAt = DateTimeOffset.UtcNow.ToString("O");
        try { SaveReceipt(output, receipt); } catch { }
        return receipt;
    }

    static DispatchReceipt Failed(DispatchReceipt receipt, string code)
    {
        receipt.Status = "failed";
        receipt.FailureCode = code;
        receipt.FinishedAt ??= DateTimeOffset.UtcNow.ToString("O");
        return receipt;
    }

    static void SaveReceipt(string output, DispatchReceipt receipt) =>
        WriteOnce(Path.Combine(output, "receipt.json"), JsonSerializer.SerializeToUtf8Bytes(receipt, WebJson));

    static void WriteOnce(string path, byte[] bytes)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        try
        {
            using var stream = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None);
            stream.Write(bytes);
            stream.Flush(true);
        }
        catch (IOException) { throw new OutputConflictException(); }
    }

    static string Sha256(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();

    static bool IsWithin(string child, string parent)
    {
        var relative = Path.GetRelativePath(parent, child);
        return relative == "." || (!Path.IsPathRooted(relative) && relative != ".." && !relative.StartsWith(".." + Path.DirectorySeparatorChar, StringComparison.Ordinal));
    }

    sealed record AllowlistSelection(string Provider, string ConnectionId, string EndpointId, string Model,
        string BaseUrl, string CatalogPath, string CatalogSha256);

    sealed class DispatchInputException(string code) : Exception(code)
    {
        public string Code { get; } = code;
    }

    sealed class OutputConflictException : Exception;
}

public static class Program
{
    public static async Task<int> Main(string[] args)
    {
        if (args.Length == 1 && args[0] is "--help" or "-h")
        {
            Console.WriteLine("Usage: FreeDispatch dispatch --request PATH --allowlist PATH --out-dir DIR [--timeout-seconds 90..300]");
            return 0;
        }
        try
        {
            var options = ParseArgs(args);
            var result = await new FreeDispatcher().DispatchAsync(options.Request, options.Allowlist, options.Output, options.Timeout);
            Console.WriteLine(JsonSerializer.Serialize(result, new JsonSerializerOptions(JsonSerializerDefaults.Web)));
            return result.Status == "completed" ? 0 : 2;
        }
        catch
        {
            // Keep parse/setup failures small and never echo exception text that could contain secrets.
            Console.WriteLine("{\"schemaVersion\":1,\"status\":\"failed\",\"sent\":false,\"failureCode\":\"INVALID_COMMAND\"}");
            return 2;
        }
    }

    static (string Request, string Allowlist, string Output, int Timeout) ParseArgs(string[] args)
    {
        if (args.Length < 1 || args[0] != "dispatch") throw new ArgumentException();
        string? request = null, allowlist = null, output = null;
        var timeout = 120;
        for (var i = 1; i < args.Length; i++)
        {
            if (i + 1 >= args.Length) throw new ArgumentException();
            var value = args[++i];
            switch (args[i - 1])
            {
                case "--request": request = value; break;
                case "--allowlist": allowlist = value; break;
                case "--out-dir": output = value; break;
                case "--timeout-seconds": if (!int.TryParse(value, out timeout)) throw new ArgumentException(); break;
                default: throw new ArgumentException();
            }
        }
        if (request is null || allowlist is null || output is null) throw new ArgumentException();
        return (request, allowlist, output, timeout);
    }
}

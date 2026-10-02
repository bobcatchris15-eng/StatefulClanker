using System.Net;
using System.Text;
using System.Text.Json;
using StatefulClanker.FreeDispatch;
using StatefulClanker.Router;

var failures = new List<string>();
var passed = 0;
await Test("success persists exact request and response before parsing, with one send", SuccessPreservesArtifacts);
await Test("non-free catalog row is rejected before credential resolution or send", PaidModelIsRejected);
await Test("model without free suffix is rejected before credential resolution or send", MissingFreeSuffixIsRejected);
await Test("provider origin mismatch is rejected before credential resolution", WrongOriginIsRejected);
await Test("redirect and HTTP failure consume one send without retry", RedirectDoesNotRetry);
await Test("transport failure consumes one send and retains a receipt", TransportFailureDoesNotRetry);
await Test("Kilo requires the catalog free flag", KiloCatalogFreeFlagIsRequired);
await Test("request timeout is bounded to 90 through 300 seconds", TimeoutIsBounded);
await Test("body stream acquisition timeout becomes captured incomplete response", BodyStreamAcquisitionTimeoutIsCaptured);
await Test("router-root output rejection performs no write", RouterRootOutputIsNotMutated);
await Test("non-empty output rejection performs no write", NonEmptyOutputIsNotMutated);
if (failures.Count > 0)
{
    Console.Error.WriteLine(string.Join(Environment.NewLine, failures));
    return 1;
}
Console.WriteLine($"FreeDispatch self-tests passed ({passed}).");
return 0;

async Task Test(string name, Func<Task> action)
{
    try
    {
        await action();
        passed++;
        Console.WriteLine($"PASS {name}");
    }
    catch (Exception ex)
    {
        failures.Add($"FAIL {name}: {ex.GetType().Name}: {ex.Message}");
    }
}

async Task SuccessPreservesArtifacts()
{
    using var temp = new TempDir();
    var fixture = MakeFixture(temp.Path);
    var secret = "fixture-secret-never-persist";
    Environment.SetEnvironmentVariable("FREEDISPATCH_TEST_KEY", secret);
    try
    {
        var response = "{\"id\":\"resp-1\",\"model\":\"vendor/model:free\",\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"  exact content  \"},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":7,\"completion_tokens\":3,\"total_tokens\":10}}";
        var handler = new FixtureHandler(request =>
        {
            Assert(File.Exists(Path.Combine(fixture.Output, "request.body.raw")), "request body must be durable before send");
            Assert(request.Headers.Authorization?.Parameter == secret, "fixture env credential should be used in memory");
            Assert(!File.ReadAllText(Path.Combine(fixture.Output, "request.metadata.json")).Contains(secret), "request metadata leaked credential");
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new ByteArrayContent(Encoding.UTF8.GetBytes(response))
            });
        });
        var runner = new FreeDispatcher(fixture.RouterRoot, () => handler);
        var receipt = await runner.DispatchAsync(fixture.Request, fixture.Allowlist, fixture.Output, 120);
        Assert(receipt.Status == "completed", "success receipt expected: " + JsonSerializer.Serialize(receipt));
        Assert(handler.SendCount == 1, "exactly one provider send expected");
        Assert(File.ReadAllText(Path.Combine(fixture.Output, "request.body.raw")).Contains("vendor/model:free"), "adapter request body missing model");
        Assert(File.ReadAllText(Path.Combine(fixture.Output, "response.body.raw")) == response, "full provider body not preserved");
        Assert(File.ReadAllBytes(Path.Combine(fixture.Output, "content.raw")).SequenceEqual(Encoding.UTF8.GetBytes("  exact content  ")), "assistant content was changed");
        var metadata = File.ReadAllText(Path.Combine(fixture.Output, "request.metadata.json"));
        Assert(!metadata.Contains(secret), "credential appeared in saved metadata");
        Assert(metadata.Contains("Authorization"), "header name should be captured");
        var receiptText = File.ReadAllText(Path.Combine(fixture.Output, "receipt.json"));
        Assert(!receiptText.Contains(secret), "credential appeared in receipt");
        var retry = await runner.DispatchAsync(fixture.Request, fixture.Allowlist, fixture.Output, 120);
        Assert(retry.Status == "failed" && retry.FailureCode == "OUTPUT_DIRECTORY_NOT_EMPTY", "existing output should block another attempt");
        Assert(handler.SendCount == 1, "a second invocation sent a retry");
    }
    finally { Environment.SetEnvironmentVariable("FREEDISPATCH_TEST_KEY", null); }
}

Task PaidModelIsRejected()
{
    using var temp = new TempDir();
    var fixture = MakeFixture(temp.Path, completionPrice: "0.01");
    var resolved = 0;
    var handler = new FixtureHandler(_ => Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)));
    var runner = new FreeDispatcher(fixture.RouterRoot, () => handler, _ => { resolved++; return "fixture"; });
    var receipt = runner.DispatchAsync(fixture.Request, fixture.Allowlist, fixture.Output, 120).GetAwaiter().GetResult();
    Assert(receipt.Status == "failed", "paid model must fail closed");
    Assert(receipt.Sent is false && handler.SendCount == 0, "invalid catalog row reached network");
    Assert(resolved == 0, "credential was resolved before catalog validation");
    Assert(File.Exists(Path.Combine(fixture.Output, "input.request.json")) && File.Exists(Path.Combine(fixture.Output, "receipt.json")), "failure evidence missing");
    return Task.CompletedTask;
}

Task MissingFreeSuffixIsRejected()
{
    using var temp = new TempDir();
    var fixture = MakeFixture(temp.Path, modelId: "vendor/model");
    var resolved = 0;
    var handler = new FixtureHandler(_ => Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)));
    var runner = new FreeDispatcher(fixture.RouterRoot, () => handler, _ => { resolved++; return "fixture"; });
    var receipt = runner.DispatchAsync(fixture.Request, fixture.Allowlist, fixture.Output, 120).GetAwaiter().GetResult();
    Assert(receipt.FailureCode == "MODEL_NOT_FREE_SUFFIX" && receipt.Sent is false, "paid model suffix was not rejected");
    Assert(resolved == 0 && handler.SendCount == 0, "suffix guard must precede secret resolution and send");
    return Task.CompletedTask;
}

async Task WrongOriginIsRejected()
{
    using var temp = new TempDir();
    var fixture = MakeFixture(temp.Path, connectionBaseUrl: "https://evil.example/api/v1");
    var resolved = 0;
    var handler = new FixtureHandler(_ => Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)));
    var runner = new FreeDispatcher(fixture.RouterRoot, () => handler, _ => { resolved++; return "fixture"; });
    var receipt = await runner.DispatchAsync(fixture.Request, fixture.Allowlist, fixture.Output, 120);
    Assert(receipt.Status == "failed" && receipt.Sent is false, "origin mismatch must fail before send");
    Assert(resolved == 0 && handler.SendCount == 0, "origin guard ran after credential resolution or send");
}

async Task RedirectDoesNotRetry()
{
    using var temp = new TempDir();
    var fixture = MakeFixture(temp.Path);
    Environment.SetEnvironmentVariable("FREEDISPATCH_TEST_KEY", "fixture-secret");
    try
    {
        var redirectHandler = new FixtureHandler(_ => Task.FromResult(new HttpResponseMessage(HttpStatusCode.Redirect)
        {
            Headers = { Location = new Uri("https://elsewhere.invalid/collect") },
            Content = new StringContent("redirect")
        }));
        using var liveHandler = FreeDispatcher.CreateLiveHttpClientHandler();
        Assert(!liveHandler.AllowAutoRedirect, "live HttpClient must disable redirects");
        var runner = new FreeDispatcher(fixture.RouterRoot, () => redirectHandler);
        var receipt = await runner.DispatchAsync(fixture.Request, fixture.Allowlist, fixture.Output, 120);
        Assert(receipt.Status == "failed" && receipt.HttpStatus == 302, "redirect response should be retained as failure: " + JsonSerializer.Serialize(receipt));
        Assert(redirectHandler.SendCount == 1, "redirect produced an additional send");
        Assert(File.ReadAllText(Path.Combine(fixture.Output, "response.body.raw")) == "redirect", "redirect body was not preserved");
    }
    finally { Environment.SetEnvironmentVariable("FREEDISPATCH_TEST_KEY", null); }
}

Task TransportFailureDoesNotRetry()
{
    using var temp = new TempDir();
    var fixture = MakeFixture(temp.Path);
    Environment.SetEnvironmentVariable("FREEDISPATCH_TEST_KEY", "fixture-secret");
    try
    {
        var handler = new FixtureHandler(_ => throw new HttpRequestException("fixture transport failure"));
        var runner = new FreeDispatcher(fixture.RouterRoot, () => handler);
        var receipt = runner.DispatchAsync(fixture.Request, fixture.Allowlist, fixture.Output, 120).GetAwaiter().GetResult();
        Assert(receipt.Status == "failed" && receipt.Sent && receipt.FailureCode == "TRANSPORT_FAILURE", "transport failure evidence missing");
        Assert(handler.SendCount == 1, "transport failure was retried");
        Assert(File.Exists(Path.Combine(fixture.Output, "request.body.raw")), "failed request body missing");
        Assert(File.Exists(Path.Combine(fixture.Output, "receipt.json")), "transport failure receipt missing");
        Assert(!File.Exists(Path.Combine(fixture.Output, "response.body.raw")), "fabricated response body was written");
    }
    finally { Environment.SetEnvironmentVariable("FREEDISPATCH_TEST_KEY", null); }
    return Task.CompletedTask;
}

Task KiloCatalogFreeFlagIsRequired()
{
    using var temp = new TempDir();
    var fixture = MakeFixture(temp.Path, provider: "kilo-free", kiloFreeFlag: false);
    var resolved = 0;
    var handler = new FixtureHandler(_ => Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)));
    var runner = new FreeDispatcher(fixture.RouterRoot, () => handler, _ => { resolved++; return "fixture"; });
    var receipt = runner.DispatchAsync(fixture.Request, fixture.Allowlist, fixture.Output, 120).GetAwaiter().GetResult();
    Assert(receipt.Status == "failed" && receipt.Sent is false, "Kilo row without isFree must be rejected");
    Assert(resolved == 0 && handler.SendCount == 0, "Kilo free-flag rejection must precede credentials and send");
    return Task.CompletedTask;
}

async Task TimeoutIsBounded()
{
    using var temp = new TempDir();
    var fixture = MakeFixture(temp.Path);
    var handler = new FixtureHandler(_ => Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)));
    var runner = new FreeDispatcher(fixture.RouterRoot, () => handler);
    var below = await runner.DispatchAsync(fixture.Request, fixture.Allowlist, fixture.Output, 89);
    Assert(below.Status == "failed" && below.Sent is false && handler.SendCount == 0, "timeout below range should fail before send");
}

async Task BodyStreamAcquisitionTimeoutIsCaptured()
{
    using var content = new AcquisitionBlockingContent();
    using var cancellation = new CancellationTokenSource(TimeSpan.FromMilliseconds(25));
    var method = typeof(FreeDispatcher).GetMethod("ReadBodyAsync", System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Static)
        ?? throw new InvalidOperationException("body reader not found");
    var task = (Task)(method.Invoke(null, new object[] { content, cancellation.Token }) ?? throw new InvalidOperationException("body reader did not return task"));
    try { await task; }
    catch (OperationCanceledException) { throw new InvalidOperationException("body acquisition cancellation escaped instead of producing a failure result"); }
    var result = task.GetType().GetProperty("Result")!.GetValue(task)!;
    Assert(!(bool)result.GetType().GetField("Item2")!.GetValue(result)!, "cancelled body was marked complete");
    Assert((string?)result.GetType().GetField("Item3")!.GetValue(result) == "timeout", "timeout evidence code missing");
}

Task RouterRootOutputIsNotMutated()
{
    using var temp = new TempDir();
    var fixture = MakeFixture(temp.Path);
    var forbidden = Path.Combine(fixture.RouterRoot, "research-output");
    var before = Directory.GetFileSystemEntries(fixture.RouterRoot).OrderBy(x => x).ToArray();
    var receipt = new FreeDispatcher(fixture.RouterRoot).DispatchAsync(fixture.Request, fixture.Allowlist, forbidden, 120).GetAwaiter().GetResult();
    var after = Directory.GetFileSystemEntries(fixture.RouterRoot).OrderBy(x => x).ToArray();
    Assert(receipt.FailureCode == "OUTPUT_INSIDE_ROUTER_ROOT", "wrong path failure code");
    Assert(before.SequenceEqual(after), "router root changed after unsafe output rejection");
    return Task.CompletedTask;
}

Task NonEmptyOutputIsNotMutated()
{
    using var temp = new TempDir();
    var fixture = MakeFixture(temp.Path);
    Directory.CreateDirectory(fixture.Output);
    var sentinel = Path.Combine(fixture.Output, "sentinel.txt");
    File.WriteAllText(sentinel, "preserve");
    var before = Directory.GetFileSystemEntries(fixture.Output).OrderBy(x => x).ToArray();
    var receipt = new FreeDispatcher(fixture.RouterRoot).DispatchAsync(fixture.Request, fixture.Allowlist, fixture.Output, 120).GetAwaiter().GetResult();
    var after = Directory.GetFileSystemEntries(fixture.Output).OrderBy(x => x).ToArray();
    Assert(receipt.FailureCode == "OUTPUT_DIRECTORY_NOT_EMPTY", "wrong output collision code");
    Assert(before.SequenceEqual(after) && File.ReadAllText(sentinel) == "preserve", "non-empty output was modified");
    return Task.CompletedTask;
}

static Fixture MakeFixture(string root, string completionPrice = "0", string? connectionBaseUrl = null,
    string provider = "openrouter", bool kiloFreeFlag = true, string modelId = "vendor/model:free")
{
    var routerRoot = Path.Combine(root, "router-root");
    Directory.CreateDirectory(Path.Combine(routerRoot, "routing"));
    var origin = provider == "openrouter" ? FreeDispatcher.OpenRouterOrigin : FreeDispatcher.KiloFreeOrigin;
    connectionBaseUrl ??= origin;
    var connections = new ConnectionDocument();
    connections.connections["fixture-connection"] = new ConnectionProfile
    {
        name = "Fixture", protocol = "openai-chat", baseUrl = connectionBaseUrl!,
        authKind = "bearer", apiKeyEnv = "FREEDISPATCH_TEST_KEY"
    };
    File.WriteAllText(Path.Combine(routerRoot, "connections.json"), JsonSerializer.Serialize(connections));

    var dir = Path.Combine(root, Guid.NewGuid().ToString("N"));
    Directory.CreateDirectory(dir);
    var requestPath = Path.Combine(dir, "request.json");
    var allowlistPath = Path.Combine(dir, "allowlist.json");
    var catalogPath = Path.Combine(dir, "catalog.json");
    var output = Path.Combine(dir, "slot");
    File.WriteAllText(requestPath, """
        {"messages":[{"role":"user","content":"fixture prompt"}],"tools":[],"toolMode":"text","maxOutputTokens":24,"temperature":0,"timeoutSeconds":120}
        """);
    var catalog = JsonSerializer.Serialize(new
    {
        url = origin + "/models",
        data = new[] { new { id = modelId, isFree = kiloFreeFlag, pricing = new { prompt = "0", completion = completionPrice } } }
    });
    File.WriteAllText(catalogPath, catalog);
    var catalogHash = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(File.ReadAllBytes(catalogPath))).ToLowerInvariant();
    File.WriteAllText(allowlistPath, JsonSerializer.Serialize(new
    {
        schema_version = 1,
        provider,
        connection_id = "fixture-connection",
        endpoint_id = "fixture-endpoint",
        model = modelId,
        base_url = origin,
        catalog_path = "catalog.json",
        catalog_sha256 = catalogHash
    }));
    return new Fixture(routerRoot, requestPath, allowlistPath, output);
}

static void Assert(bool condition, string message)
{
    if (!condition) throw new InvalidOperationException(message);
}

sealed record Fixture(string RouterRoot, string Request, string Allowlist, string Output);

sealed class TempDir : IDisposable
{
    public string Path { get; } = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "freedispatch-test-" + Guid.NewGuid().ToString("N"));
    public TempDir() => Directory.CreateDirectory(Path);
    public void Dispose() { try { Directory.Delete(Path, true); } catch { } }
}

sealed class FixtureHandler(Func<HttpRequestMessage, Task<HttpResponseMessage>> respond) : HttpMessageHandler
{
    public int SendCount { get; private set; }
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        SendCount++;
        return respond(request);
    }
}

sealed class AcquisitionBlockingContent : HttpContent
{
    protected override async Task<Stream> CreateContentReadStreamAsync(CancellationToken cancellationToken)
    {
        await Task.Delay(Timeout.Infinite, cancellationToken);
        return new MemoryStream();
    }
    protected override Task SerializeToStreamAsync(Stream stream, TransportContext? context) => Task.CompletedTask;
    protected override bool TryComputeLength(out long length) { length = 0; return true; }
}

using System.Diagnostics;
using System.Net;
using System.Text.Json;

namespace StatefulClanker.Router;

public sealed class InferenceGateway : IDisposable
{
    readonly RouterEngine _engine;
    readonly RouterStore _store;
    readonly SignalStore _signals;
    readonly ProviderAdapterRegistry _adapters=new();
    readonly HttpClient _http;

    public InferenceGateway(RouterEngine engine)
    {
        _engine=engine;
        _store=engine.Store;
        _signals=new SignalStore(_store.Root);
        _http=new HttpClient{Timeout=TimeSpan.FromSeconds(45)};
        _http.DefaultRequestHeaders.UserAgent.ParseAdd("StatefulClanker-InferenceGateway/0.1");
    }

    public IReadOnlyList<object> DescribeAdapters() => _adapters.Describe();

    public async Task<RouterResponse> TestEndpointAsync(
        string? endpoint,
        string? prompt=null,
        string? mode=null,
        int maxOutputTokens=8,
        CancellationToken token=default)
    {
        if(string.IsNullOrWhiteSpace(endpoint))
            return RouterResponse.Fail("endpoint is required.");

        var route=_engine.FindRoute(endpoint);
        if(route is null)
            return RouterResponse.Fail($"Unknown endpoint '{endpoint}'.");

        if(route.Connection is null)
            return RouterResponse.Fail($"Endpoint '{route.RouteName}' references missing connection '{route.Endpoint.connection}'.");

        IProviderAdapter adapter;
        try
        {
            adapter=_adapters.Resolve(route.Connection);
        }
        catch(Exception ex)
        {
            var unsupported=BaseResult(route,"unresolved","",new SanitizedRequestEvidence(),
                new SanitizedResponseEvidence(),
                Diagnosis("adapter_unavailable","request",true,false,"ADAPTER_NOT_FOUND",ex.Message));
            unsupported.signalRef=EmitTestSignal(route,unsupported,false);
            return RouterResponse.Ok(unsupported);
        }

        var normalized=new NormalizedInferenceRequest
        {
            prompt=string.IsNullOrWhiteSpace(prompt) ? "Reply with exactly: CLANKER_OK" : prompt!,
            maxOutputTokens=Math.Clamp(maxOutputTokens,1,64),
            testTools=string.Equals(mode,"tools",StringComparison.OrdinalIgnoreCase)
        };

        AdapterRequest? built=null;
        var responseEvidence=new SanitizedResponseEvidence();
        var stopwatch=Stopwatch.StartNew();

        try
        {
            var key=ConnectionCredentialResolver.ResolveKey(route.Connection);
            built=adapter.BuildRequest(route.Connection,route.Endpoint,normalized,key);
            using var response=await _http.SendAsync(built.message,HttpCompletionOption.ResponseHeadersRead,token);
            stopwatch.Stop();

            var body=await ReadBodyBounded(response,token);
            responseEvidence=new SanitizedResponseEvidence
            {
                httpStatus=(int)response.StatusCode,
                headers=DiagnosticHeaders(response),
                bodyExcerpt=Bound(body,4096),
                providerRequestId=ProviderRequestId(response),
                durationSeconds=Math.Round(stopwatch.Elapsed.TotalSeconds,3)
            };

            if(response.IsSuccessStatusCode)
            {
                var parsed=adapter.ParseSuccess(body);
                if(parsed.Success)
                {
                    _engine.Success(null,route.RouteName);
                    var result=BaseResult(
                        route,adapter.Id,adapter.SourcePath,built.evidence,responseEvidence,
                        Diagnosis("none","endpoint",false,false,"TEST_INFERENCE_SUCCEEDED","Real inference succeeded through the production adapter path."));
                    result.ok=true;
                    result.signalRef=EmitTestSignal(route,result,true);
                    return RouterResponse.Ok(result);
                }

                var malformed=BaseResult(
                    route,adapter.Id,adapter.SourcePath,built.evidence,responseEvidence,
                    Diagnosis("malformed_response","request",true,false,"RESPONSE_SHAPE_UNRECOGNIZED",parsed.Error));
                malformed.signalRef=EmitTestSignal(route,malformed,false);
                return RouterResponse.Ok(malformed);
            }

            var diagnosticText=$"HTTP {(int)response.StatusCode} {response.ReasonPhrase} {body}".Trim();
            var klass=FailurePolicy.Classify(diagnosticText,(int)response.StatusCode);
            var scope=FailurePolicy.ScopeFor(klass);
            var adapterSuspect=(int)response.StatusCode is 400 or 404 or 422 ||
                               klass is "bad_request" or "protocol_error" or "malformed_response";
            if((int)response.StatusCode is 400 or 422) scope="request";
            var providerSuspect=scope is not ("request" or "harness");

            if(scope is not ("request" or "harness"))
                _engine.Failure(null,route.RouteName,klass,diagnosticText);

            var failed=BaseResult(
                route,adapter.Id,adapter.SourcePath,built.evidence,responseEvidence,
                Diagnosis(
                    klass,scope,adapterSuspect,providerSuspect,
                    ReasonCode(klass,(int)response.StatusCode,adapterSuspect),
                    Bound(diagnosticText,1000)));
            failed.signalRef=EmitTestSignal(route,failed,false);
            return RouterResponse.Ok(failed);
        }
        catch(TaskCanceledException ex) when(!token.IsCancellationRequested)
        {
            stopwatch.Stop();
            responseEvidence.durationSeconds=Math.Round(stopwatch.Elapsed.TotalSeconds,3);
            _engine.Failure(null,route.RouteName,"timeout",ex.Message);
            var result=BaseResult(
                route,adapter.Id,adapter.SourcePath,built?.evidence??new SanitizedRequestEvidence(),responseEvidence,
                Diagnosis("timeout","endpoint",false,true,"TRANSPORT_TIMEOUT",ex.Message));
            result.signalRef=EmitTestSignal(route,result,false);
            return RouterResponse.Ok(result);
        }
        catch(HttpRequestException ex)
        {
            stopwatch.Stop();
            responseEvidence.durationSeconds=Math.Round(stopwatch.Elapsed.TotalSeconds,3);
            var klass=FailurePolicy.Classify(ex.Message);
            if(klass=="request_error") klass="transport";
            var scope=klass=="transport"?"endpoint":FailurePolicy.ScopeFor(klass);
            if(scope!="request") _engine.Failure(null,route.RouteName,klass,ex.Message);
            var result=BaseResult(
                route,adapter.Id,adapter.SourcePath,built?.evidence??new SanitizedRequestEvidence(),responseEvidence,
                Diagnosis(klass,scope,false,true,"TRANSPORT_FAILURE",ex.Message));
            result.signalRef=EmitTestSignal(route,result,false);
            return RouterResponse.Ok(result);
        }
        catch(Exception ex)
        {
            stopwatch.Stop();
            responseEvidence.durationSeconds=Math.Round(stopwatch.Elapsed.TotalSeconds,3);
            var result=BaseResult(
                route,adapter.Id,adapter.SourcePath,built?.evidence??new SanitizedRequestEvidence(),responseEvidence,
                Diagnosis("harness_internal","harness",true,false,"ADAPTER_OR_HARNESS_EXCEPTION",ex.Message));
            result.signalRef=EmitTestSignal(route,result,false);
            return RouterResponse.Ok(result);
        }
        finally
        {
            built?.Dispose();
        }
    }

    EndpointTestResult BaseResult(
        EndpointRoute route,
        string adapterId,
        string adapterSource,
        SanitizedRequestEvidence request,
        SanitizedResponseEvidence response,
        InferenceDiagnosis diagnosis)
    {
        return new EndpointTestResult
        {
            ok=false,
            endpoint=route.RouteName,
            connection=route.Endpoint.connection,
            model=route.Endpoint.model,
            adapterId=adapterId,
            adapterSource=adapterSource,
            protocol=route.Connection?.protocol??"",
            connectionConfigFingerprint=route.Connection is null ? "" : _store.ConnectionFingerprint(route.Connection),
            request=request,
            response=response,
            diagnosis=diagnosis
        };
    }

    string? EmitTestSignal(EndpointRoute route,EndpointTestResult result,bool success)
    {
        try
        {
            var payload=new Dictionary<string,object?>
            {
                ["endpoint"]=result.endpoint,
                ["connection"]=result.connection,
                ["model"]=result.model,
                ["adapterId"]=result.adapterId,
                ["adapterSource"]=result.adapterSource,
                ["protocol"]=result.protocol,
                ["request"]=result.request,
                ["response"]=result.response,
                ["diagnosis"]=result.diagnosis,
                ["connectionConfigFingerprint"]=result.connectionConfigFingerprint
            };
            var signal=SignalEnvelope.Routing(
                success?"endpoint_test_succeeded":"endpoint_test_failed",
                "endpoint",route.RouteName,
                "orchestrator","control-plane",
                result.diagnosis.scope,
                payload);
            signal.source["component"]="inference-gateway";
            return _signals.Append(signal);
        }
        catch
        {
            return null;
        }
    }

    static InferenceDiagnosis Diagnosis(
        string klass,string scope,bool adapterSuspect,bool providerSuspect,string reasonCode,string? summary)
    {
        return new InferenceDiagnosis
        {
            failureClass=klass,
            scope=scope,
            adapterSuspect=adapterSuspect,
            providerHealthSuspect=providerSuspect,
            reasonCode=reasonCode,
            summary=Bound(summary,1000)
        };
    }

    static string ReasonCode(string klass,int status,bool adapterSuspect)
    {
        if(adapterSuspect && status is 400 or 422) return "REQUEST_SHAPE_REJECTED";
        if(adapterSuspect && status==404) return "REQUEST_URI_OR_MODEL_REJECTED";
        return klass switch
        {
            "auth" or "permission" => "AUTHENTICATION_REJECTED",
            "rate_limited" => "RATE_LIMITED",
            "billing_exhausted" => "BILLING_OR_QUOTA_EXHAUSTED",
            "model_unavailable" => "MODEL_UNAVAILABLE",
            "capacity" => "PROVIDER_CAPACITY",
            "timeout" => "TRANSPORT_TIMEOUT",
            "server_error" => "PROVIDER_SERVER_ERROR",
            "bad_request" => "REQUEST_SHAPE_REJECTED",
            "protocol_error" => "PROTOCOL_REJECTED",
            _ => "ENDPOINT_TEST_FAILED"
        };
    }

    static Dictionary<string,string> DiagnosticHeaders(HttpResponseMessage response)
    {
        var output=new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase);
        foreach(var pair in response.Headers.Concat(response.Content.Headers))
        {
            if(!SafeDiagnosticHeader(pair.Key)) continue;
            output[pair.Key]=Bound(string.Join(",",pair.Value),500);
        }
        return output;
    }

    static bool SafeDiagnosticHeader(string name)
    {
        var n=name.ToLowerInvariant();
        return n is "date" or "content-type" or "retry-after" or "request-id" or "x-request-id" or "cf-ray" ||
               n.StartsWith("x-ratelimit-",StringComparison.Ordinal) ||
               n.StartsWith("ratelimit-",StringComparison.Ordinal) ||
               n.StartsWith("anthropic-ratelimit-",StringComparison.Ordinal) ||
               n.StartsWith("openai-",StringComparison.Ordinal);
    }

    static string? ProviderRequestId(HttpResponseMessage response)
    {
        foreach(var key in new[]{"x-request-id","request-id","cf-ray"})
            if(response.Headers.TryGetValues(key,out var values))
                return values.FirstOrDefault();
        return null;
    }

    static async Task<string> ReadBodyBounded(HttpResponseMessage response,CancellationToken token)
    {
        var body=await response.Content.ReadAsStringAsync(token);
        return body.Length<=16384?body:body[..16384];
    }

    static string Bound(string? value,int max)
    {
        if(string.IsNullOrEmpty(value)) return "";
        var text=value.Replace("\r"," ").Replace("\n"," ").Trim();
        return text.Length<=max?text:text[..max];
    }

    public void Dispose() => _http.Dispose();
}

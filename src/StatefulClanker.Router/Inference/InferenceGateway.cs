using System.Diagnostics;
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
        _http=new HttpClient();
        _http.DefaultRequestHeaders.UserAgent.ParseAdd("StatefulClanker-InferenceGateway/0.2");
    }

    public IReadOnlyList<object> DescribeAdapters() => _adapters.Describe();

    public async Task<RouterResponse> InferAsync(RouterRequest request,CancellationToken token=default)
    {
        if(request.inference is null) return RouterResponse.Fail("inference request is required.");
        if(!string.IsNullOrWhiteSpace(request.endpoint))
            return await InferExactAsync(request.endpoint,request.inference,token);

        var inference=request.inference;
        inference.EnsureDiagnosticConversation();
        var maxAttempts=Math.Clamp(inference.maxRouteAttempts,1,32);
        var maxWait=Math.Clamp(inference.maxRouteWaitSeconds,0,300);
        var deadline=DateTimeOffset.UtcNow.AddSeconds(maxWait);
        var history=new List<RoutingAttemptRecord>();
        NormalizedInferenceResult? last=null;
        var preferred=request.preferred;

        for(var attempt=1;attempt<=maxAttempts;attempt++)
        {
            var acquire=_engine.Acquire(
                preferred,
                request.preferredConnection,
                request.strictPreferred,
                request.sessionId,
                request.requireTools,
                request.ownerPid,
                request.allowedEndpoints,
                inference.toolMode);

            if(!acquire.ok)
            {
                var reason=ReadString(acquire.data,"reason")??"route_unavailable";
                var nextRetryAt=ReadString(acquire.data,"nextRetryAt");
                var retrySeconds=ReadDouble(acquire.data,"retryAfterSeconds");
                var delay=RetryDelay(nextRetryAt,retrySeconds,deadline);

                if(delay>TimeSpan.Zero && attempt<maxAttempts)
                {
                    await Task.Delay(delay,token);
                    if(!request.strictPreferred) preferred=null;
                    continue;
                }

                var unavailable=last??new NormalizedInferenceResult();
                unavailable.ok=false;
                unavailable.routeDeferred=true;
                unavailable.routeExhausted=history.Count>0;
                unavailable.nextRetryAt=nextRetryAt;
                unavailable.routeAttempts=history.Count;
                unavailable.routeHistory=history;
                unavailable.diagnosis=Diagnosis(
                    "route_unavailable","request",false,false,
                    reason.ToUpperInvariant(),
                    acquire.error??"No eligible inference route is currently available.");
                unavailable.failoverAllowed=false;
                return RouterResponse.Ok(unavailable);
            }

            var lease=ReadString(acquire.data,"lease");
            var endpoint=ReadString(acquire.data,"endpoint");
            if(string.IsNullOrWhiteSpace(endpoint))
            {
                if(!string.IsNullOrWhiteSpace(lease)) _engine.Release(lease);
                return RouterResponse.Fail("Router acquire succeeded without an endpoint.");
            }

            var route=_engine.FindRoute(endpoint);
            if(route is null)
            {
                if(!string.IsNullOrWhiteSpace(lease)) _engine.Release(lease);
                preferred=null;
                continue;
            }

            var started=Stopwatch.StartNew();
            NormalizedInferenceResult result;
            try
            {
                result=await ExecuteAsync(route,inference,false,token,lease);
            }
            finally
            {
                if(!string.IsNullOrWhiteSpace(lease)) _engine.Release(lease);
            }
            started.Stop();

            history.Add(new RoutingAttemptRecord
            {
                attempt=attempt,
                endpoint=route.RouteName,
                connection=route.Endpoint.connection,
                model=route.Endpoint.model,
                outcome=result.ok?"success":"failed",
                failureClass=result.ok?null:result.diagnosis.failureClass,
                scope=result.ok?null:result.diagnosis.scope,
                reasonCode=result.ok?null:result.diagnosis.reasonCode,
                durationSeconds=Math.Round(started.Elapsed.TotalSeconds,3)
            });
            result.routeAttempts=history.Count;
            result.routeHistory=new(history);

            if(result.ok) return RouterResponse.Ok(result);

            last=result;
            if(request.strictPreferred || !result.failoverAllowed)
                return RouterResponse.Ok(result);

            preferred=null;
        }

        var exhausted=last??new NormalizedInferenceResult
        {
            diagnosis=Diagnosis("route_exhausted","request",false,false,
                "ROUTE_ATTEMPTS_EXHAUSTED","Inference route attempts were exhausted.")
        };
        exhausted.ok=false;
        exhausted.routeExhausted=true;
        exhausted.routeAttempts=history.Count;
        exhausted.routeHistory=history;
        exhausted.failoverAllowed=false;
        return RouterResponse.Ok(exhausted);
    }

    public async Task<RouterResponse> InferExactAsync(
        string? endpoint,
        NormalizedInferenceRequest? request,
        CancellationToken token=default)
    {
        if(string.IsNullOrWhiteSpace(endpoint)) return RouterResponse.Fail("endpoint is required.");
        if(request is null) return RouterResponse.Fail("inference request is required.");
        var route=_engine.FindRoute(endpoint);
        if(route is null) return RouterResponse.Fail($"Unknown endpoint '{endpoint}'.");
        if(route.Connection is null)
            return RouterResponse.Fail($"Endpoint '{route.RouteName}' references missing connection '{route.Endpoint.connection}'.");

        var result=await ExecuteAsync(route,request,false,token,null);
        return RouterResponse.Ok(result);
    }

    public async Task<RouterResponse> TestEndpointAsync(
        string? endpoint,
        string? prompt=null,
        string? mode=null,
        int maxOutputTokens=8,
        CancellationToken token=default)
    {
        if(string.IsNullOrWhiteSpace(endpoint)) return RouterResponse.Fail("endpoint is required.");
        var route=_engine.FindRoute(endpoint);
        if(route is null) return RouterResponse.Fail($"Unknown endpoint '{endpoint}'.");
        if(route.Connection is null)
            return RouterResponse.Fail($"Endpoint '{route.RouteName}' references missing connection '{route.Endpoint.connection}'.");

        var request=new NormalizedInferenceRequest
        {
            prompt=string.IsNullOrWhiteSpace(prompt)?"Reply with exactly: CLANKER_OK":prompt!,
            maxOutputTokens=Math.Clamp(maxOutputTokens,1,64),
            testTools=string.Equals(mode,"tools",StringComparison.OrdinalIgnoreCase),
            toolMode=string.Equals(mode,"tools",StringComparison.OrdinalIgnoreCase)?"native":"text",
            timeoutSeconds=45
        };
        request.EnsureDiagnosticConversation();
        var inference=await ExecuteAsync(route,request,true,token,null);
        var mapped=new EndpointTestResult
        {
            ok=inference.ok,
            endpoint=inference.endpoint,
            connection=inference.connection,
            model=inference.model,
            adapterId=inference.adapterId,
            adapterSource=inference.adapterSource,
            protocol=route.Connection.protocol,
            connectionConfigFingerprint=_store.ConnectionFingerprint(route.Connection),
            request=inference.request,
            response=inference.response,
            diagnosis=inference.diagnosis,
            signalRef=inference.signalRef
        };
        return RouterResponse.Ok(mapped);
    }

    async Task<NormalizedInferenceResult> ExecuteAsync(
        EndpointRoute route,
        NormalizedInferenceRequest request,
        bool diagnosticMode,
        CancellationToken token,
        string? leaseToken)
    {
        IProviderAdapter adapter;
        try{adapter=_adapters.Resolve(route.Connection!);}
        catch(Exception ex)
        {
            var unsupported=BaseResult(route,"unresolved","",
                Diagnosis("adapter_unavailable","request",true,false,"ADAPTER_NOT_FOUND",ex.Message));
            unsupported.failoverAllowed=false;
            unsupported.signalRef=EmitSignal(route,unsupported,diagnosticMode);
            return unsupported;
        }

        AdapterRequest? built=null;
        var responseEvidence=new SanitizedResponseEvidence();
        var stopwatch=Stopwatch.StartNew();
        using var timeoutCts=CancellationTokenSource.CreateLinkedTokenSource(token);
        timeoutCts.CancelAfter(TimeSpan.FromSeconds(Math.Clamp(request.timeoutSeconds,15,1800)));

        try
        {
            var key=ConnectionCredentialResolver.ResolveKey(route.Connection!);
            built=adapter.BuildRequest(route.Connection!,route.Endpoint,request,key);
            using var response=await _http.SendAsync(
                built.message,HttpCompletionOption.ResponseHeadersRead,timeoutCts.Token);
            stopwatch.Stop();

            var body=await ReadBodyBounded(response,timeoutCts.Token);
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
                var parsed=adapter.ParseSuccess(body,route.Endpoint);
                if(parsed.Success && parsed.Assistant is not null)
                {
                    _engine.Success(leaseToken,route.RouteName);
                    var result=BaseResult(route,adapter.Id,adapter.SourcePath,
                        Diagnosis("none","endpoint",false,false,
                            diagnosticMode?"TEST_INFERENCE_SUCCEEDED":"INFERENCE_SUCCEEDED",
                            "Inference succeeded through the router-owned adapter."));
                    result.ok=true;
                    result.assistant=parsed.Assistant;
                    result.usage=parsed.Usage;
                    result.request=built.evidence;
                    result.response=responseEvidence;
                    result.healthChanged=true;
                    result.signalRef=EmitSignal(route,result,diagnosticMode);
                    return result;
                }

                var malformed=BaseResult(route,adapter.Id,adapter.SourcePath,
                    Diagnosis("malformed_response","request",true,false,
                        "RESPONSE_SHAPE_UNRECOGNIZED",parsed.Error));
                malformed.usage=parsed.Usage;
                malformed.request=built.evidence;
                malformed.response=responseEvidence;
                malformed.failoverAllowed=false;
                malformed.signalRef=EmitSignal(route,malformed,diagnosticMode);
                return malformed;
            }

            var routingHeaders=string.Join(" ",responseEvidence.headers.Select(kv=>$"{kv.Key}: {kv.Value}"));
            var diagnosticText=$"HTTP {(int)response.StatusCode} {response.ReasonPhrase} {routingHeaders} {body}".Trim();
            var klass=FailurePolicy.Classify(diagnosticText,(int)response.StatusCode);
            var scope=FailurePolicy.ScopeFor(klass);
            var adapterSuspect=(int)response.StatusCode is 400 or 422 ||
                               klass is "bad_request" or "protocol_error" or "malformed_response";
            if((int)response.StatusCode is 400 or 422) scope="request";
            var providerSuspect=scope is not ("request" or "harness");
            var healthChanged=scope is not ("request" or "harness");

            if(healthChanged)
                _engine.Failure(leaseToken,route.RouteName,klass,diagnosticText);

            var failed=BaseResult(route,adapter.Id,adapter.SourcePath,
                Diagnosis(klass,scope,adapterSuspect,providerSuspect,
                    ReasonCode(klass,(int)response.StatusCode,adapterSuspect),
                    Bound(diagnosticText,1000)));
            failed.request=built.evidence;
            failed.response=responseEvidence;
            failed.healthChanged=healthChanged;
            failed.failoverAllowed=!adapterSuspect && FailurePolicy.CanFailover(klass);
            failed.signalRef=EmitSignal(route,failed,diagnosticMode);
            return failed;
        }
        catch(TaskCanceledException ex) when(!token.IsCancellationRequested)
        {
            stopwatch.Stop();
            responseEvidence.durationSeconds=Math.Round(stopwatch.Elapsed.TotalSeconds,3);
            _engine.Failure(leaseToken,route.RouteName,"timeout",ex.Message);
            var result=BaseResult(route,adapter.Id,adapter.SourcePath,
                Diagnosis("timeout","endpoint",false,true,"TRANSPORT_TIMEOUT",ex.Message));
            result.request=built?.evidence??new SanitizedRequestEvidence();
            result.response=responseEvidence;
            result.healthChanged=true;
            result.failoverAllowed=true;
            result.signalRef=EmitSignal(route,result,diagnosticMode);
            return result;
        }
        catch(HttpRequestException ex)
        {
            stopwatch.Stop();
            responseEvidence.durationSeconds=Math.Round(stopwatch.Elapsed.TotalSeconds,3);
            var klass=FailurePolicy.Classify(ex.Message);
            if(klass=="request_error") klass="transport";
            var scope=klass=="transport"?"endpoint":FailurePolicy.ScopeFor(klass);
            var healthChanged=scope is not ("request" or "harness");
            if(healthChanged) _engine.Failure(leaseToken,route.RouteName,klass,ex.Message);
            var result=BaseResult(route,adapter.Id,adapter.SourcePath,
                Diagnosis(klass,scope,false,true,"TRANSPORT_FAILURE",ex.Message));
            result.request=built?.evidence??new SanitizedRequestEvidence();
            result.response=responseEvidence;
            result.healthChanged=healthChanged;
            result.failoverAllowed=FailurePolicy.CanFailover(klass) || klass=="transport";
            result.signalRef=EmitSignal(route,result,diagnosticMode);
            return result;
        }
        catch(Exception ex)
        {
            stopwatch.Stop();
            responseEvidence.durationSeconds=Math.Round(stopwatch.Elapsed.TotalSeconds,3);
            var result=BaseResult(route,adapter.Id,adapter.SourcePath,
                Diagnosis("harness_internal","harness",true,false,
                    "ADAPTER_OR_HARNESS_EXCEPTION",ex.Message));
            result.request=built?.evidence??new SanitizedRequestEvidence();
            result.response=responseEvidence;
            result.healthChanged=false;
            result.failoverAllowed=false;
            result.signalRef=EmitSignal(route,result,diagnosticMode);
            return result;
        }
        finally{built?.Dispose();}
    }

    NormalizedInferenceResult BaseResult(
        EndpointRoute route,string adapterId,string adapterSource,InferenceDiagnosis diagnosis) =>
        new()
        {
            ok=false,
            endpoint=route.RouteName,
            connection=route.Endpoint.connection,
            model=route.Endpoint.model,
            adapterId=adapterId,
            adapterSource=adapterSource,
            diagnosis=diagnosis,
            usage=new NormalizedUsage{model=route.Endpoint.model}
        };

    string? EmitSignal(EndpointRoute route,NormalizedInferenceResult result,bool diagnosticMode)
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
                ["request"]=result.request,
                ["response"]=result.response,
                ["diagnosis"]=result.diagnosis,
                ["usage"]=result.usage,
                ["failoverAllowed"]=result.failoverAllowed,
                ["healthChanged"]=result.healthChanged
            };
            var kind=diagnosticMode
                ? (result.ok?"endpoint_test_succeeded":"endpoint_test_failed")
                : (result.ok?"inference_succeeded":"inference_failed");
            var signal=SignalEnvelope.Routing(
                kind,"endpoint",route.RouteName,
                diagnosticMode?"orchestrator":"router",
                diagnosticMode?"control-plane":"inference",
                result.diagnosis.scope,payload);
            signal.source["component"]="inference-gateway";
            return _signals.Append(signal);
        }
        catch{return null;}
    }

    static string? ReadString(object? source,string name)
    {
        if(source is null) return null;
        try
        {
            using var doc=JsonDocument.Parse(JsonSerializer.Serialize(source));
            if(doc.RootElement.TryGetProperty(name,out var value) && value.ValueKind!=JsonValueKind.Null)
                return value.ValueKind==JsonValueKind.String?value.GetString():value.ToString();
        }
        catch{}
        return null;
    }

    static double? ReadDouble(object? source,string name)
    {
        if(source is null) return null;
        try
        {
            using var doc=JsonDocument.Parse(JsonSerializer.Serialize(source));
            if(doc.RootElement.TryGetProperty(name,out var value))
            {
                if(value.ValueKind==JsonValueKind.Number && value.TryGetDouble(out var n)) return n;
                if(value.ValueKind==JsonValueKind.String && double.TryParse(value.GetString(),out n)) return n;
            }
        }
        catch{}
        return null;
    }

    static TimeSpan RetryDelay(string? nextRetryAt,double? retrySeconds,DateTimeOffset deadline)
    {
        var now=DateTimeOffset.UtcNow;
        if(now>=deadline) return TimeSpan.Zero;
        DateTimeOffset target=now;
        if(!string.IsNullOrWhiteSpace(nextRetryAt) && DateTimeOffset.TryParse(nextRetryAt,out var parsed))
            target=parsed;
        else if(retrySeconds is >0)
            target=now.AddSeconds(Math.Min(5,retrySeconds.Value));
        else
            return TimeSpan.Zero;

        if(target>deadline) return TimeSpan.Zero;
        var delay=target-now;
        if(delay<TimeSpan.FromMilliseconds(100)) delay=TimeSpan.FromMilliseconds(100);
        return delay;
    }

    static InferenceDiagnosis Diagnosis(
        string klass,string scope,bool adapterSuspect,bool providerSuspect,string reasonCode,string? summary) =>
        new()
        {
            failureClass=klass,
            scope=scope,
            adapterSuspect=adapterSuspect,
            providerHealthSuspect=providerSuspect,
            reasonCode=reasonCode,
            summary=Bound(summary,1000)
        };

    static string ReasonCode(string klass,int status,bool adapterSuspect)
    {
        if(adapterSuspect && status is 400 or 422) return "REQUEST_SHAPE_REJECTED";
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
            _ => "INFERENCE_FAILED"
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
            if(response.Headers.TryGetValues(key,out var values)) return values.FirstOrDefault();
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

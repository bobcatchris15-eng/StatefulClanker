<# A connected request must never be replayed after a timeout or disconnected response. #>
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$project=Join-Path $repo 'src\StatefulClanker.Router\StatefulClanker.Router.csproj'
$temp=Join-Path ([IO.Path]::GetTempPath()) ('sc-client-recovery-'+[guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory $temp|Out-Null
    @"
<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net8.0-windows</TargetFramework><ImplicitUsings>enable</ImplicitUsings><Nullable>enable</Nullable></PropertyGroup><ItemGroup><ProjectReference Include="$project" /></ItemGroup></Project>
"@|Set-Content (Join-Path $temp 'Recovery.csproj')
    @'
using System.IO.Pipes;
using System.Reflection;
using System.Text;
using StatefulClanker.Router;

// Program's startup uses Environment.ProcessPath; a child harness with "daemon" exits
// immediately, keeping this regression isolated from real daemon state.
if (args.Contains("daemon")) return;
var method=typeof(RouterPipeClient).Assembly.GetType("StatefulClanker.Router.Program")!
    .GetMethod("SendWithDaemonAsync",BindingFlags.Static|BindingFlags.NonPublic)!;
foreach(var mode in new[]{"startup-timeout","startup-disconnect","timeout","disconnect"})
{
    var name="sc-recovery-"+Guid.NewGuid().ToString("N");
    using var stop=new CancellationTokenSource();
    var requests=0;
    var server=Task.Run(async()=>
    {
        if(mode.StartsWith("startup-")) await Task.Delay(1100,stop.Token);
        while(!stop.IsCancellationRequested)
        {
            await using var pipe=new NamedPipeServerStream(name,PipeDirection.InOut,4,PipeTransmissionMode.Byte,PipeOptions.Asynchronous);
            try
            {
                await pipe.WaitForConnectionAsync(stop.Token);
                using var reader=new StreamReader(pipe,Encoding.UTF8,false,4096,true);
                await reader.ReadLineAsync(stop.Token);
                Interlocked.Increment(ref requests);
                if(requests==1 && mode.EndsWith("timeout")) await Task.Delay(900,stop.Token);
                if(requests>1)
                {
                    using var writer=new StreamWriter(pipe,new UTF8Encoding(false),4096,true){AutoFlush=true};
                    await writer.WriteLineAsync("{\"ok\":true}");
                }
            }
            catch(OperationCanceledException) when(stop.IsCancellationRequested) { break; }
            catch(IOException) { }
        }
    });
    Exception? failure=null;
    RouterResponse? result=null;
    try { result=await (Task<RouterResponse>)method.Invoke(null,new object[]{name,new RouterRequest{op=mode.EndsWith("disconnect")?"infer":"snapshot"}})!; }
    catch(Exception ex) { failure=ex; }
    finally { stop.Cancel();await server; }
    if(requests!=1 || (failure is null && result?.ok!=false)) throw new Exception($"{mode}: expected one submitted request and a surfaced failure, got {requests} requests, {failure}");
    if(failure?.Message.Contains("did not become ready")==true) throw new Exception($"{mode}: submitted request failure was misreported as startup failure");
    Console.WriteLine($"PASS: {mode} surfaces failure without replay ({requests} request)");
}
'@|Set-Content (Join-Path $temp 'Program.cs')
    & dotnet run --project (Join-Path $temp 'Recovery.csproj') --no-launch-profile
    if($LASTEXITCODE -ne 0){throw 'Router client recovery regression failed'}
} finally {
    if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Recurse -Force}
}

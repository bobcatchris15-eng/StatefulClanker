<# Root aliases must use one IPC identity and one state mutex; default IPC stays compatible. #>
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$temp=Join-Path ([IO.Path]::GetTempPath()) ('sc-root-identity-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp|Out-Null
try{
    $project=[Security.SecurityElement]::Escape((Join-Path $repo 'src\StatefulClanker.Router\StatefulClanker.Router.csproj'))
    "<Project Sdk=`"Microsoft.NET.Sdk`"><PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net8.0-windows</TargetFramework><ImplicitUsings>enable</ImplicitUsings></PropertyGroup><ItemGroup><ProjectReference Include=`"$project`" /></ItemGroup></Project>"|Set-Content (Join-Path $temp 'RootIdentity.csproj')
    @'
using StatefulClanker.Router;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
static void Check(bool value,string message){if(!value)throw new Exception(message);}
string root=Path.Combine(Path.GetTempPath(),"sc-root-fixture-"+Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(root);
try{
    var canonical=new RouterStore(root);
    var aliases=new[]{root.Replace('\\','/'),root+Path.DirectorySeparatorChar,root.ToUpperInvariant(),Path.Combine(root,"child",".."),Path.GetRelativePath(Environment.CurrentDirectory,root)};
    foreach(var alias in aliases){
        var store=new RouterStore(alias);
        Check(Path.IsPathFullyQualified(store.Root),"Store root must be absolute: "+alias);
        Check(RouterNames.PipeName(alias)==RouterNames.PipeName(root),"Pipe identity differs for alias: "+alias);
        var field=typeof(RouterStore).GetField("_mutex",BindingFlags.Instance|BindingFlags.NonPublic)!;
        var first=(Mutex)field.GetValue(canonical)!;var second=(Mutex)field.GetValue(store)!;
        first.WaitOne();
        try{Check(!Task.Run(()=>{var held=second.WaitOne(100);if(held)second.ReleaseMutex();return held;}).GetAwaiter().GetResult(),"State mutex differs for alias: "+alias);}
        finally{first.ReleaseMutex();second.Dispose();}
    }
    var signalCanonical=new SignalStore(root);
    foreach(var alias in aliases){
        var signalAlias=new SignalStore(alias);
        var field=typeof(SignalStore).GetField("_mutex",BindingFlags.Instance|BindingFlags.NonPublic)!;
        var first=(Mutex)field.GetValue(signalCanonical)!;var second=(Mutex)field.GetValue(signalAlias)!;
        first.WaitOne();
        try{Check(!Task.Run(()=>{var held=second.WaitOne(100);if(held)second.ReleaseMutex();return held;}).GetAwaiter().GetResult(),"Signal mutex differs for alias: "+alias);}
        finally{first.ReleaseMutex();second.Dispose();}
    }
    var defaultRoot=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"StatefulClanker");
    var legacy="StatefulClanker.Router.v1."+Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(defaultRoot))).ToLowerInvariant()[..12];
    foreach(var alias in new[]{defaultRoot,defaultRoot.Replace('\\','/'),defaultRoot.ToUpperInvariant()+"\\"})
        Check(RouterNames.PipeName(alias)==legacy,"Default pipe identity lost compatibility: "+alias);
    Check(RouterNames.PipeName(root)!=RouterNames.PipeName(root+"-other"),"Distinct roots share IPC identity");
    Check(RouterNames.PipeName(Path.GetPathRoot(root)!)==RouterNames.PipeName(Path.GetPathRoot(root)!.Replace('\\','/')),"Drive-root aliases differ");
    Console.WriteLine("PASS: root aliases share pipe/state identity and default IPC remains compatible");
}finally{Directory.Delete(root,true);}
'@ | Set-Content (Join-Path $temp 'Program.cs')
    dotnet run --project (Join-Path $temp 'RootIdentity.csproj') --verbosity quiet
    if($LASTEXITCODE -ne 0){throw 'Root identity regression failed'}
}finally{
    $resolved=[IO.Path]::GetFullPath($temp)
    if(-not $resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe fixture cleanup path'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}

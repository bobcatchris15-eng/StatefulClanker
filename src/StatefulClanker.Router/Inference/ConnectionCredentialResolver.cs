using System.Security.Cryptography;
using System.Text;

namespace StatefulClanker.Router;

public static class ConnectionCredentialResolver
{
    public static string? ResolveKey(ConnectionProfile profile)
    {
        if(!string.IsNullOrWhiteSpace(profile.apiKeyEnv))
        {
            var env=Environment.GetEnvironmentVariable(profile.apiKeyEnv);
            if(!string.IsNullOrWhiteSpace(env)) return env;
        }

        if(string.IsNullOrWhiteSpace(profile.apiKeyProtected)) return null;
        try
        {
            var bytes=Convert.FromBase64String(profile.apiKeyProtected);
            var clear=ProtectedData.Unprotect(bytes,null,DataProtectionScope.CurrentUser);
            return Encoding.UTF8.GetString(clear);
        }
        catch
        {
            return null;
        }
    }
}

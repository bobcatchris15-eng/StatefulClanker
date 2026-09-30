namespace StatefulClanker.Router;

internal static class RouterRoot
{
    internal static string Default => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "StatefulClanker");

    internal static string Normalize(string root) => Path.TrimEndingDirectorySeparator(Path.GetFullPath(root));

    internal static string Identity(string root)
    {
        var normalized = Normalize(root);
        if (!OperatingSystem.IsWindows()) return normalized;

        // Installed clients hash this exact mixed-case default path. Keep that
        // identity for every spelling of the default; fold other Windows roots.
        var defaultRoot = Normalize(Default);
        return string.Equals(normalized, defaultRoot, StringComparison.OrdinalIgnoreCase)
            ? defaultRoot : normalized.ToUpperInvariant();
    }
}

using System.Runtime.InteropServices;

namespace StatefulClanker.Tray;

static class NativeUiTheme
{
    [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)]
    static extern int SetWindowTheme(IntPtr hWnd, string? pszSubAppName, string? pszSubIdList);

    [DllImport("dwmapi.dll")]
    static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);

    const int DWMWA_USE_IMMERSIVE_DARK_MODE = 20;

    public static void Attach(Control control)
    {
        control.HandleCreated += (_, _) => ApplyHandle(control);
        if (control.IsHandleCreated) ApplyHandle(control);
    }

    static void ApplyHandle(Control control)
    {
        try
        {
            var enabled = 1;
            if (control is Form)
                DwmSetWindowAttribute(control.Handle, DWMWA_USE_IMMERSIVE_DARK_MODE, ref enabled, sizeof(int));

            // Explorer dark mode themes native scrollbars and selection chrome for
            // WinForms controls that otherwise ignore BackColor/ForeColor.
            if (control is TreeView or ListView or TextBox or RichTextBox or ComboBox)
                SetWindowTheme(control.Handle, "DarkMode_Explorer", null);
        }
        catch { }
    }
}

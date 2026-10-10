using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows.Forms;

[assembly: AssemblyTitle("OpenCode Go Limits")]
[assembly: AssemblyProduct("OpenCode Go Limits")]
[assembly: AssemblyDescription("Desktop widget showing OpenCode Go usage limits")]
[assembly: AssemblyVersion("1.1.0.0")]
[assembly: AssemblyFileVersion("1.1.0.0")]

static class Launcher
{
    private const string ResourceName = "limits-widget.ps1";

    [STAThread]
    static void Main()
    {
        try
        {
            string exePath = Application.ExecutablePath;
            string targetDir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "OpenCodeLimits", "app");
            Directory.CreateDirectory(targetDir);
            string scriptPath = Path.Combine(targetDir, ResourceName);

            Assembly asm = Assembly.GetExecutingAssembly();
            using (Stream resource = asm.GetManifestResourceStream(ResourceName))
            {
                if (resource == null)
                {
                    MessageBox.Show(
                        "Внутри программы не найден встроенный скрипт. Скачайте exe заново со страницы релизов.",
                        "OpenCode Go Limits", MessageBoxButtons.OK, MessageBoxIcon.Error);
                    return;
                }
                using (FileStream file = new FileStream(scriptPath, FileMode.Create, FileAccess.Write, FileShare.None))
                {
                    resource.CopyTo(file);
                }
            }

            string powershell = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.System),
                @"WindowsPowerShell\v1.0\powershell.exe");

            var psi = new ProcessStartInfo
            {
                FileName = powershell,
                Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + scriptPath + "\" -ExePath \"" + exePath + "\"",
                UseShellExecute = false,
                CreateNoWindow = true,
                WorkingDirectory = targetDir
            };
            Process.Start(psi);
        }
        catch (Exception ex)
        {
            MessageBox.Show(
                "Не удалось запустить виджет: " + ex.Message,
                "OpenCode Go Limits", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }
}

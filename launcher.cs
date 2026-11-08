using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Security.Cryptography;
using System.Windows.Forms;

[assembly: AssemblyTitle("OpenCode Go Limits")]
[assembly: AssemblyProduct("OpenCode Go Limits")]
[assembly: AssemblyDescription("Desktop widget showing OpenCode Go usage limits")]
[assembly: AssemblyVersion("1.4.1.0")]
[assembly: AssemblyFileVersion("1.4.1.0")]

static class Launcher
{
    private const string ResourceName = "limits-widget.ps1";

    [STAThread]
    static void Main()
    {
        try
        {
            string exePath = Application.ExecutablePath;
            string baseDir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "OpenCodeLimits");

            byte[] scriptBytes;
            using (Stream resource = Assembly.GetExecutingAssembly().GetManifestResourceStream(ResourceName))
            {
                if (resource == null)
                {
                    MessageBox.Show(
                        "Внутри программы не найден встроенный скрипт. Скачайте exe заново со страницы релизов.",
                        "OpenCode Go Limits", MessageBoxButtons.OK, MessageBoxIcon.Error);
                    return;
                }
                using (MemoryStream buffer = new MemoryStream())
                {
                    resource.CopyTo(buffer);
                    scriptBytes = buffer.ToArray();
                }
            }

            string expectedHash = ComputeSha256(scriptBytes);

            string runDir = Path.Combine(baseDir, "run-" + Guid.NewGuid().ToString("N").Substring(0, 8));
            Directory.CreateDirectory(runDir);
            string scriptPath = Path.Combine(runDir, ResourceName);
            File.WriteAllBytes(scriptPath, scriptBytes);

            string actualHash;
            using (FileStream file = File.OpenRead(scriptPath))
            {
                actualHash = ComputeSha256(file);
            }
            if (!string.Equals(expectedHash, actualHash, StringComparison.OrdinalIgnoreCase))
            {
                try { Directory.Delete(runDir, true); } catch { }
                MessageBox.Show(
                    "Файл виджета повреждён при распаковке. Скачайте exe заново со страницы релизов.",
                    "OpenCode Go Limits", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }

            CleanupOldRuns(baseDir, runDir);
            try { Directory.Delete(Path.Combine(baseDir, "app"), true); } catch { }

            string powershell = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.System),
                @"WindowsPowerShell\v1.0\powershell.exe");

            var psi = new ProcessStartInfo
            {
                FileName = powershell,
                Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + scriptPath + "\" -ExePath \"" + exePath + "\"",
                UseShellExecute = false,
                CreateNoWindow = true,
                WorkingDirectory = runDir
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

    private static string ComputeSha256(byte[] data)
    {
        using (SHA256 sha = SHA256.Create())
        {
            return BitConverter.ToString(sha.ComputeHash(data)).Replace("-", "");
        }
    }

    private static string ComputeSha256(Stream stream)
    {
        using (SHA256 sha = SHA256.Create())
        {
            return BitConverter.ToString(sha.ComputeHash(stream)).Replace("-", "");
        }
    }

    private static void CleanupOldRuns(string baseDir, string currentDir)
    {
        try
        {
            foreach (string dir in Directory.GetDirectories(baseDir, "run-*"))
            {
                if (string.Equals(dir, currentDir, StringComparison.OrdinalIgnoreCase)) { continue; }
                try { Directory.Delete(dir, true); } catch { }
            }
        }
        catch { }
    }
}

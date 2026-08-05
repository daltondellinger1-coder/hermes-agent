using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;

internal static class HermesHostSupervisorLauncher
{
    private static string Quote(string value)
    {
        return "\"" + value.Replace("\"", "\\\"") + "\"";
    }

    [STAThread]
    private static int Main(string[] additionalArguments)
    {
        string baseDirectory = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
        string supervisorPath = Path.Combine(baseDirectory, "HermesHostSupervisor.ps1");
        string dataDirectory = Path.Combine(baseDirectory, "data");
        string powershellPath = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.Windows),
            "System32",
            "WindowsPowerShell",
            "v1.0",
            "powershell.exe");

        if (!File.Exists(supervisorPath))
        {
            return 2;
        }

        string arguments =
            "-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden " +
            "-ExecutionPolicy Bypass -File " + Quote(supervisorPath) + " " +
            "-HealthUrl \"http://127.0.0.1:8646/health/detailed\" " +
            "-DataDirectory " + Quote(dataDirectory) + " -AlwaysLog";

        if (additionalArguments.Length > 0)
        {
            arguments += " " + string.Join(" ", additionalArguments);
        }

        using (Process process = new Process())
        {
            process.StartInfo = new ProcessStartInfo
            {
                FileName = powershellPath,
                Arguments = arguments,
                UseShellExecute = false,
                CreateNoWindow = true,
                WindowStyle = ProcessWindowStyle.Hidden,
                RedirectStandardOutput = true,
                RedirectStandardError = true
            };

            process.OutputDataReceived += delegate { };
            process.ErrorDataReceived += delegate { };
            process.Start();
            process.BeginOutputReadLine();
            process.BeginErrorReadLine();
            process.WaitForExit();
            return process.ExitCode;
        }
    }
}

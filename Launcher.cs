using System;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;

namespace DataControl
{
    static class Program
    {
        [STAThread]
        static void Main(string[] args)
        {
            try
            {
                string baseDir = AppDomain.CurrentDomain.BaseDirectory;
                string scriptPath = Path.Combine(baseDir, "DataControl.ps1");

                if (!File.Exists(scriptPath))
                {
                    MessageBox.Show(
                        "Could not find DataControl.ps1 in:\n" + baseDir,
                        "DataControl Launcher Error",
                        MessageBoxButtons.OK,
                        MessageBoxIcon.Error
                    );
                    return;
                }

                string passArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + scriptPath + "\"";
                if (args != null && args.Length > 0)
                {
                    passArgs += " " + string.Join(" ", args);
                }

                ProcessStartInfo psi = new ProcessStartInfo
                {
                    FileName = "powershell.exe",
                    Arguments = passArgs,
                    WorkingDirectory = baseDir,
                    UseShellExecute = true,
                    WindowStyle = ProcessWindowStyle.Hidden
                };

                Process.Start(psi);
            }
            catch (Exception ex)
            {
                MessageBox.Show(
                    "Failed to launch DataControl:\n" + ex.Message,
                    "DataControl Launcher Error",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Error
                );
            }
        }
    }
}

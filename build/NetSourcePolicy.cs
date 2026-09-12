using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows.Forms;

namespace NetSourcePolicy
{
    static class Launcher
    {
        [STAThread]
        static void Main()
        {
            string dir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
            string script = Path.Combine(dir, "src", "NetSourcePolicy.ps1");

            if (!File.Exists(script))
            {
                MessageBox.Show("Missing file:\n" + script +
                    "\n\nPlease keep the whole NetSourcePolicy folder together.",
                    "NetSource Policy", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }

            var psi = new ProcessStartInfo
            {
                FileName = "powershell.exe",
                Arguments = string.Format("-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"{0}\"", script),
                WorkingDirectory = dir,
                UseShellExecute = false
            };

            try
            {
                using (Process p = Process.Start(psi))
                {
                    if (p != null) p.WaitForExit();
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show("Failed to start the interface:\n" + ex.Message,
                    "NetSource Policy", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }
    }
}
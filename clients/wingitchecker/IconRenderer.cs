using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Runtime.InteropServices;

namespace WinGitChecker;

/// Builds the tray icon at runtime so it can show the attention count, the way
/// the macOS menu bar shows "⚠ N". A warning glyph + number when repos need
/// attention; a green check when everything is clean.
public static class IconRenderer
{
    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DestroyIcon(IntPtr handle);

    private static readonly Color Warn = Color.FromArgb(0xE0, 0x6C, 0x00); // amber
    private static readonly Color Ok = Color.FromArgb(0x2E, 0xA0, 0x43);   // green

    /// Render an icon for the given state. The caller owns the returned <see cref="Icon"/>
    /// and must pass <paramref name="handle"/> to <see cref="Release"/> when done.
    public static Icon Build(int count, bool attention, out IntPtr handle)
    {
        const int size = 32;
        using var bmp = new Bitmap(size, size);
        using (var g = Graphics.FromImage(bmp))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
            g.Clear(Color.Transparent);

            if (attention)
            {
                using var brush = new SolidBrush(Warn);
                g.FillEllipse(brush, 0, 0, size - 1, size - 1);
                DrawCount(g, count, size);
            }
            else
            {
                using var pen = new Pen(Ok, 4.5f)
                {
                    StartCap = LineCap.Round,
                    EndCap = LineCap.Round,
                    LineJoin = LineJoin.Round,
                };
                g.DrawLines(pen, new[]
                {
                    new PointF(7, 17),
                    new PointF(13, 24),
                    new PointF(26, 9),
                });
            }
        }

        handle = bmp.GetHicon();
        return Icon.FromHandle(handle);
    }

    public static void Release(IntPtr handle)
    {
        if (handle != IntPtr.Zero)
            DestroyIcon(handle);
    }

    private static void DrawCount(Graphics g, int count, int size)
    {
        var text = count > 99 ? "99" : count.ToString();
        // Shrink the font for two-digit counts so it stays inside the circle.
        float em = text.Length >= 2 ? 15f : 19f;
        using var font = new Font("Segoe UI", em, FontStyle.Bold, GraphicsUnit.Pixel);
        using var fmt = new StringFormat
        {
            Alignment = StringAlignment.Center,
            LineAlignment = StringAlignment.Center,
        };
        var rect = new RectangleF(0, 0, size, size);
        using var white = new SolidBrush(Color.White);
        g.DrawString(text, font, white, rect, fmt);
    }
}

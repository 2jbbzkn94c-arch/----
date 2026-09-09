// 旋转窗口工具 (WPF, 纯代码无XAML)
// 功能：下拉选择任意可见窗口 -> 新窗口实时显示其画面旋转90°；点击旋转画面可反向操作原窗口。
// 截图用 PrintWindow(flag=2, 含DWM渲染)：目标窗口即使被遮挡/不在屏幕前，也能截到完整内容。
// 编译：双击 编译镜像工具.bat (用 .NET Framework csc + GAC WPF 程序集)
using System;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

public class MainWin : Window
{
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, IntPtr extra);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, uint msg, IntPtr wParam, IntPtr lParam);
    [DllImport("gdi32.dll")] public static extern bool DeleteObject(IntPtr h);
    const uint MOUSEEVENTF_LEFTDOWN = 0x02, MOUSEEVENTF_LEFTUP = 0x04;

    ComboBox _combo;
    Image _img;
    DispatcherTimer _timer;
    IntPtr _target = IntPtr.Zero;
    int _dir = 1;
    bool _running = false;

    public MainWin()
    {
        Title = "旋转窗口工具 (WPF)";
        Width = 360; Height = 620;
        var root = new DockPanel();

        var top = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(6) };
        _combo = new ComboBox { Width = 200 };
        var btn = new Button { Content = "开始", Width = 70, Margin = new Thickness(6, 0, 0, 0) };
        var dirCombo = new ComboBox { Width = 60, Margin = new Thickness(6, 0, 0, 0), SelectedIndex = 0 };
        dirCombo.Items.Add("顺"); dirCombo.Items.Add("逆"); dirCombo.Items.Add("180");
        top.Children.Add(_combo); top.Children.Add(dirCombo); top.Children.Add(btn);
        DockPanel.SetDock(top, Dock.Top);
        root.Children.Add(top);

        _img = new Image { Stretch = Stretch.Uniform };
        root.Children.Add(_img);
        Content = root;

        foreach (var p in System.Diagnostics.Process.GetProcesses())
        {
            if (p.MainWindowHandle != IntPtr.Zero && p.MainWindowTitle != "")
                _combo.Items.Add(new WinItem { Handle = p.MainWindowHandle, Title = p.MainWindowTitle });
        }
        if (_combo.Items.Count > 0) _combo.SelectedIndex = 0;

        btn.Click += (s, e) =>
        {
            var wi = _combo.SelectedItem as WinItem;
            if (wi == null) { MessageBox.Show("请先选择窗口"); return; }
            _target = wi.Handle;
            _dir = dirCombo.SelectedIndex == 2 ? 3 : (dirCombo.SelectedIndex == 1 ? 2 : 1);
            _running = true;
            Width = 1000; Height = 700;
            var wa = SystemParameters.WorkArea;
            Left = (int)Math.Max(0, wa.Width - 1010); Top = (int)Math.Max(0, (wa.Height - 700) / 2);
            StartTimer();
        };

        // 点击镜像 -> 反旋转坐标 -> 物理鼠标点击目标窗口客户区
        _img.MouseLeftButtonUp += (s, e) =>
        {
            if (!_running || _target == IntPtr.Zero) return;
            Point pos = e.GetPosition(_img);
            double cw = _img.ActualWidth, ch = _img.ActualHeight;
            if (cw < 1 || ch < 1) return;
            RECT cr; GetClientRect(_target, out cr);
            int dw = cr.Right - cr.Left, dh = cr.Bottom - cr.Top;
            if (dw < 1 || dh < 1) return;
            double dx, dy;
            if (_dir == 1) { dx = (pos.Y / ch) * dw; dy = (1.0 - pos.X / cw) * dh; }
            else if (_dir == 2) { dx = (1.0 - pos.Y / ch) * dw; dy = (pos.X / cw) * dh; }
            else { dx = (1.0 - pos.X / cw) * dw; dy = (1.0 - pos.Y / ch) * dh; }
            // SendMessage 直接给目标窗口发鼠标消息(客户区坐标)，后台/被盖也能接收
            int cx = (int)dx, cy = (int)dy;
            IntPtr lp = new IntPtr((cy << 16) | (cx & 0xFFFF));
            SetForegroundWindow(_target);
            SendMessage(_target, 0x0200, IntPtr.Zero, lp); // WM_MOUSEMOVE
            SendMessage(_target, 0x0201, new IntPtr(1), lp); // WM_LBUTTONDOWN
            SendMessage(_target, 0x0202, IntPtr.Zero, lp); // WM_LBUTTONUP
        };
    }

    class WinItem { public IntPtr Handle; public string Title; public override string ToString() { return Title; } }

    void StartTimer()
    {
        _timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(33) };
        _timer.Tick += (s, e) =>
        {
            if (!_running || _target == IntPtr.Zero) return;
            RECT cr; GetClientRect(_target, out cr);
            int w = cr.Right - cr.Left, h = cr.Bottom - cr.Top;
            if (w < 2 || h < 2) return;
            try
            {
                using (var bmp = new System.Drawing.Bitmap(w, h))
                {
                    using (var g = System.Drawing.Graphics.FromImage(bmp))
                    {
                        IntPtr hdc = g.GetHdc();
                        PrintWindow(_target, hdc, 2);   // flag=2: PW_RENDERFULLCONTENT(含DWM渲染)
                        g.ReleaseHdc(hdc);
                    }
                    System.Drawing.Bitmap rot = new System.Drawing.Bitmap(_dir == 3 ? w : h, _dir == 3 ? h : w);
                    using (var g2 = System.Drawing.Graphics.FromImage(rot))
                    {
                        g2.Clear(System.Drawing.Color.Black);
                        g2.TranslateTransform(rot.Width / 2f, rot.Height / 2f);
                        if (_dir == 1) g2.RotateTransform(90);
                        else if (_dir == 2) g2.RotateTransform(-90);
                        else g2.RotateTransform(180);
                        g2.TranslateTransform(-rot.Width / 2f, -rot.Height / 2f);
                        g2.SetClip(new System.Drawing.RectangleF(0, 0, rot.Width, rot.Height));
                        g2.DrawImage(bmp, 0, 0);
                    }
                    bmp.Dispose();
                    IntPtr hBitmap = rot.GetHbitmap();
                    var src = System.Windows.Interop.Imaging.CreateBitmapSourceFromHBitmap(
                        hBitmap, IntPtr.Zero, Int32Rect.Empty, BitmapSizeOptions.FromEmptyOptions());
                    DeleteObject(hBitmap);
                    rot.Dispose();
                    _img.Source = src;
                }
            }
            catch { }
        };
        _timer.Start();
    }

    [STAThread]
    public static void Main()
    {
        var app = new Application();
        app.Run(new MainWin());
    }
}

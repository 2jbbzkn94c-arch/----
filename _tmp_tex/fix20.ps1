param(
  [Parameter(Mandatory=$true)][string]$Src,
  [Parameter(Mandatory=$true)][string]$OutPng,
  [Parameter(Mandatory=$true)][string]$OutJpg,
  [int]$Strip = 54,
  [double]$JointT = 16.0,
  [int]$JointRun = 25,
  [int]$JointMax = 26,
  [switch]$Report,
  [switch]$Crops,
  [string]$CropBefore = '',
  [string]$CropAfter = ''
)

$cs = @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public class Fix20 {
  public static byte[] Rgb; public static byte[] Gray; public static int W, H, Stride;
  public static void Load(string path) {
    Bitmap bmp = new Bitmap(path); W = bmp.Width; H = bmp.Height;
    Bitmap b32 = new Bitmap(W, H, PixelFormat.Format32bppArgb);
    using (Graphics g = Graphics.FromImage(b32)) { g.DrawImage(bmp, 0, 0, W, H); }
    BitmapData bd = b32.LockBits(new Rectangle(0,0,W,H), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
    Stride = bd.Stride; Rgb = new byte[Stride*H];
    Marshal.Copy(bd.Scan0, Rgb, 0, Rgb.Length); b32.UnlockBits(bd);
    Gray = new byte[W*H]; Rebuild();
  }
  public static void Rebuild() {
    for (int y=0;y<H;y++) for (int x=0;x<W;x++) { int i=y*Stride+x*4; Gray[y*W+x]=(byte)(0.114*Rgb[i]+0.587*Rgb[i+1]+0.299*Rgb[i+2]); }
  }
  static int Clamp(double v) { return v<0?0:(v>255?255:(int)Math.Round(v)); }
  static double Ch(int x,int y,int ch) { return Rgb[y*Stride+x*4+ch]; }
  static double G(int x,int y) { if (x<0) x=0; if (x>=W) x=W-1; if (y<0) y=0; if (y>=H) y=H-1; return Gray[y*W+x]; }
  static double Median(List<double> a) { a.Sort(); int n=a.Count; return n==0?0:((n%2==1)?a[n/2]:(a[n/2-1]+a[n/2])*0.5); }

  // ---------- 1) flat-field: only brighten, never darken ----------
  static double[,] BoxBlur(double[,] a, int r) {
    int gx=a.GetLength(0), gy=a.GetLength(1);
    double[,] tmp=new double[gx,gy], outv=new double[gx,gy];
    for (int i=0;i<gx;i++) for (int j=0;j<gy;j++) { double s=0; int n=0; for (int d=-r;d<=r;d++){ int jj=j+d; if (jj<0||jj>=gy) continue; s+=a[i,jj]; n++; } tmp[i,j]=s/n; }
    for (int i=0;i<gx;i++) for (int j=0;j<gy;j++) { double s=0; int n=0; for (int d=-r;d<=r;d++){ int ii=i+d; if (ii<0||ii>=gx) continue; s+=tmp[ii,j]; n++; } outv[i,j]=s/n; }
    return outv;
  }
  public static void FlatField(double maxGain, int down, int blurR) {
    int gx=(W+down-1)/down, gy=(H+down-1)/down;
    double[,] g0=new double[gx,gy];
    for (int i=0;i<gx;i++) for (int j=0;j<gy;j++) {
      double s=0; int n=0;
      for (int y=j*down;y<Math.Min(H,(j+1)*down);y+=2) for (int x=i*down;x<Math.Min(W,(i+1)*down);x+=2) { s+=G(x,y); n++; }
      g0[i,j]=n>0?s/n:0;
    }
    double[,] g1=BoxBlur(g0, blurR);
    List<double> all=new List<double>();
    for (int i=0;i<gx;i++) for (int j=0;j<gy;j++) all.Add(g1[i,j]);
    all.Sort();
    double target=all[(int)(all.Count*0.88)];
    byte[] blur=new byte[Stride*H];
    for (int y=0;y<H;y++) for (int x=0;x<W;x++) {
      double[] s=new double[3]; int n=0;
      for (int dy=-1;dy<=1;dy++) for (int dx=-1;dx<=1;dx++) { int xx=x+dx, yy=y+dy; if (xx<0||xx>=W||yy<0||yy>=H) continue; for (int ch=0;ch<3;ch++) s[ch]+=Ch(xx,yy,ch); n++; }
      for (int ch=0;ch<3;ch++) blur[y*Stride+x*4+ch]=(byte)Clamp(s[ch]/n);
      blur[y*Stride+x*4+3]=255;
    }
    for (int y=0;y<H;y++) for (int x=0;x<W;x++) {
      double fx=(double)x/down, fy=(double)y/down;
      int i0=(int)Math.Floor(fx), j0=(int)Math.Floor(fy);
      int i1=Math.Min(i0+1,gx-1), j1=Math.Min(j0+1,gy-1);
      i0=Math.Max(0,Math.Min(i0,gx-1)); j0=Math.Max(0,Math.Min(j0,gy-1));
      double tx=fx-i0, ty=fy-j0;
      double L=g1[i0,j0]*(1-tx)*(1-ty)+g1[i1,j0]*tx*(1-ty)+g1[i0,j1]*(1-tx)*ty+g1[i1,j1]*tx*ty;
      double gain=target/Math.Max(L,1.0); if (gain<1.0) gain=1.0; if (gain>maxGain) gain=maxGain;
      double w=(gain-1.3)/2.7; if (w<0) w=0; if (w>0.9) w=0.9;
      for (int ch=0;ch<3;ch++) { double basev=Ch(x,y,ch)*(1-w)+blur[y*Stride+x*4+ch]*w; Rgb[y*Stride+x*4+ch]=(byte)Clamp(basev*gain); }
      Rgb[y*Stride+x*4+3]=255;
    }
    Rebuild();
    Console.WriteLine("  flat-field ok (target " + target.ToString("F0") + ", maxGain " + maxGain + ")");
  }

  // ---------- 2) horizontal plank-end joints: mirror-fill each masked run vertically ----------
  public static void RemoveJoints(double T, int runMin, int maxRun) {
    bool[] mark=new bool[W*H];
    for (int y=9;y<H-9;y++) {
      int run=0;
      for (int x=0;x<W;x++) {
        double u=0,d=0;
        for (int k=3;k<=8;k++){ u+=G(x,y-k); d+=G(x,y+k); }
        double dip=(u+d)/12.0 - G(x,y);
        if (dip >= T) run++; else run=0;
        if (run>=runMin) for (int k=0;k<run;k++) mark[y*W+x-k]=true;
      }
    }
    byte[] outRgb=new byte[Stride*H];
    int total=0;
    for (int x=0;x<W;x++) {
      List<int[]> runs=new List<int[]>();
      int y=6;
      while (y<H-6) {
        if (!mark[y*W+x]) { y++; continue; }
        int y0=y,y1=y;
        while (y1+1<H-6 && (mark[(y1+1)*W+x] || (y1+2<H-6 && mark[(y1+2)*W+x]))) { if (mark[(y1+1)*W+x]) y1++; else y1+=2; }
        if (y1-y0+1<=maxRun) runs.Add(new int[]{y0,y1});
        y=y1+1;
      }
      total += runs.Count;
      for (int oy=0;oy<H;oy++) {
        double v=oy;
        for (int guard=0; guard<6; guard++) {
          bool folded=false;
          foreach (int[] r in runs) if (v>=r[0] && v<=r[1]) { v=2.0*r[1]+1.0-v; folded=true; }
          if (!folded) break;
        }
        if (v<0) v=0; if (v>H-1) v=H-1;
        int y0=(int)Math.Floor(v); double fy=v-y0;
        int y1=Math.Min(H-1,y0+1); if (y0<0) y0=0;
        for (int ch=0;ch<4;ch++) outRgb[oy*Stride+x*4+ch]=(byte)Clamp(Rgb[y0*Stride+x*4+ch]*(1-fy)+Rgb[y1*Stride+x*4+ch]*fy);
      }
    }
    Array.Copy(outRgb, Rgb, Rgb.Length);
    Rebuild();
    Console.WriteLine("  joints mirror-filled (runs=" + total + ")");
  }

  // ---------- 3) pick the cleanest strip and mirror-tile it across the width ----------
  public static void TileStrip(int stripW) {
    // column line strength: how much a column differs from its neighbours on average
    double[] sc=new double[W];
    for (int x=0;x<W;x++) {
      double s=0; int n=0;
      for (int y=100;y<H-100;y+=2) {
        double l=0,r=0;
        for (int d=4;d<=10;d++){ l+=G(x-d,y); r+=G(x+d,y); }
        double refv=(l+r)/12.0;
        s += Math.Abs(refv-G(x,y)) / Math.Max(refv,20.0);
        n++;
      }
      sc[x]=s/n;
    }
    int bestX=0; double bestScore=1e9;
    for (int x0=40; x0+stripW < W-40; x0++) {
      double worst=0;
      for (int x=x0;x<x0+stripW;x++) if (sc[x]>worst) worst=sc[x];
      if (worst < bestScore) { bestScore=worst; bestX=x0; }
    }
    Console.WriteLine("  cleanest strip x=" + bestX + ".." + (bestX+stripW-1) + " (worst rel-line " + bestScore.ToString("F3") + ")");
    byte[] outRgb=new byte[Stride*H];
    int period = stripW*2;
    for (int y=0;y<H;y++) {
      for (int x=0;x<W;x++) {
        int k = x % period;
        int sx = bestX + (k < stripW ? k : period-1-k);
        if (sx > W-1) sx = W-1;
        for (int ch=0;ch<4;ch++) outRgb[y*Stride+x*4+ch]=Rgb[y*Stride+sx*4+ch];
      }
    }
    Array.Copy(outRgb, Rgb, Rgb.Length);
    Rebuild();
    Console.WriteLine("  strip mirror-tiled (period " + period + " px)");
  }

  // ---------- verification ----------
  public static void LineStats(string tag) {
    double worst=0; int wx=-1;
    for (int x=9;x<W-9;x++) {
      double s=0; int n=0;
      for (int y=100;y<H-100;y+=2) {
        double l=0,r=0;
        for (int d=4;d<=10;d++){ l+=G(x-d,y); r+=G(x+d,y); }
        double refv=(l+r)/12.0;
        s += (refv-G(x,y)); n++;
      }
      double v=s/n; if (v>worst) { worst=v; wx=x; }
    }
    double bw=0; int by=-1;
    for (int y=9;y<H-9;y++) {
      double s=0; int n=0;
      for (int x=100;x<W-100;x+=2) {
        double u=0,d=0;
        for (int k=4;k<=10;k++){ u+=G(x,y-k); d+=G(x,y+k); }
        s += ((u+d)/14.0-G(x,y)); n++;
      }
      double v=s/n; if (v>bw) { bw=v; by=y; }
    }
    Console.WriteLine(tag + " 最暗竖线=" + worst.ToString("F1") + " @x=" + wx + "；最暗横线=" + bw.ToString("F1") + " @y=" + by);
  }
  public static void EdgeStats(string tag) {
    double t=0,b=0,l=0,r=0,c=0;
    for (int x=200;x<W-200;x+=4){ t+=G(x,2); b+=G(x,H-3); c+=G(x,H/2); }
    for (int y=200;y<H-200;y+=4){ l+=G(2,y); r+=G(W-3,y); }
    int n1=(W-400)/4, n2=(H-400)/4;
    Console.WriteLine(tag + " 上=" + (t/n1).ToString("F0") + " 下=" + (b/n1).ToString("F0") + " 左=" + (l/n2).ToString("F0") + " 右=" + (r/n2).ToString("F0") + " 中心=" + (c/n1).ToString("F0"));
  }
  public static void Strip2(int x0,int x1,int y0,int y1,string tag) {
    double s=0,s2=0; int n=0;
    for (int y=y0;y<y1;y++) for (int x=x0;x<x1;x++){ double v=G(x,y); s+=v; s2+=v*v; n++; }
    double m=s/n; Console.WriteLine(tag + " mean=" + m.ToString("F0") + " sd=" + Math.Sqrt(Math.Max(0,s2/n-m*m)).ToString("F1"));
  }
  public static void Zoom(int x0,int x1,int y0,int y1,string tag) {
    string ramp="@%#*+=-:. ";
    Console.WriteLine("---- " + tag + " x" + x0 + "-" + x1 + " y" + y0 + "-" + y1 + " ----");
    for(int y=y0;y<y1;y++){ string s=""; for(int x=x0;x<x1;x++){ int v=(int)G(x,y); s+=ramp[Math.Min(9,v*10/256)]; } Console.WriteLine(s); }
  }
  public static void CropStack(string path, int[] xs, int[] ys, int cw, int chh, int zoom, int gap) {
    int totalH=(chh*zoom+gap)*xs.Length-gap;
    Bitmap outb=new Bitmap(cw*zoom, totalH, PixelFormat.Format32bppArgb);
    using (Graphics g=Graphics.FromImage(outb)) {
      g.Clear(Color.Black);
      for (int k=0;k<xs.Length;k++) {
        int oy=k*(chh*zoom+gap);
        for (int y=0;y<chh;y++) for (int x=0;x<cw;x++) {
          int sx=xs[k]+x, sy=ys[k]+y;
          if (sx<0||sx>=W||sy<0||sy>=H) continue;
          int i=(sy*Stride+sx*4);
          Color c=Color.FromArgb(Rgb[i+2], Rgb[i+1], Rgb[i]);
          using (SolidBrush b=new SolidBrush(c)) g.FillRectangle(b, x*zoom, oy+y*zoom, zoom, zoom);
        }
      }
    }
    outb.Save(path, ImageFormat.Png); outb.Dispose();
    Console.WriteLine("cropstack saved " + path);
  }
  public static void SavePng(string p){ Save(p,true); }
  public static void SaveJpg(string p){ Save(p,false); }
  static void Save(string path,bool png) {
    Bitmap outb=new Bitmap(W,H,PixelFormat.Format32bppArgb);
    BitmapData bd=outb.LockBits(new Rectangle(0,0,W,H),ImageLockMode.WriteOnly,PixelFormat.Format32bppArgb);
    Marshal.Copy(Rgb,0,bd.Scan0,Math.Min(Rgb.Length,bd.Stride*H)); outb.UnlockBits(bd);
    if (png) outb.Save(path, ImageFormat.Png);
    else {
      ImageCodecInfo jpg=null;
      foreach (ImageCodecInfo c in ImageCodecInfo.GetImageEncoders()) if (c.FormatID==ImageFormat.Jpeg.Guid) jpg=c;
      EncoderParameters ep=new EncoderParameters(1);
      ep.Param[0]=new EncoderParameter(System.Drawing.Imaging.Encoder.Quality,95L);
      outb.Save(path,jpg,ep);
    }
    outb.Dispose(); Console.WriteLine("saved "+path);
  }
}
'@

Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition $cs -ReferencedAssemblies 'System.Drawing' -ErrorAction Stop

$xsC = @(280, 658, 434, 947, 838, 545)
$ysC = @(659, 1781, 1207, 739, 577, 1634)

[Fix20]::Load($Src)
if ($Report) { [Fix20]::LineStats('BEFORE'); [Fix20]::EdgeStats('BEFORE'); [Fix20]::Strip2(500,580,900,1000,'BEFORE 板内'); [Fix20]::Zoom(180,220,1000,1020,'BEFORE x180-220') }
if ($Crops) { [Fix20]::CropStack($CropBefore, $xsC, $ysC, 140, 110, 3, 8) }
[Fix20]::FlatField(9.0, 16, 4)
[Fix20]::RemoveJoints($JointT, $JointRun, $JointMax)
[Fix20]::TileStrip($Strip)
if ($Report) { [Fix20]::LineStats('AFTER '); [Fix20]::EdgeStats('AFTER '); [Fix20]::Strip2(500,580,900,1000,'AFTER  板内'); [Fix20]::Zoom(180,220,1000,1020,'AFTER  x180-220') }
if ($Crops) { [Fix20]::CropStack($CropAfter, $xsC, $ysC, 140, 110, 3, 8) }
[Fix20]::SavePng($OutPng)
[Fix20]::SaveJpg($OutJpg)

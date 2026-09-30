param(
  [Parameter(Mandatory=$true)][string]$Src,
  [Parameter(Mandatory=$true)][string]$OutPng,
  [Parameter(Mandatory=$true)][string]$OutJpg,
  [double]$Pitch = 99.0,
  [int]$MaxHalf = 14,
  [double]$RelT = 0.05,
  [double]$AbsT = 3.0,
  [double]$HitFrac = 0.45,
  [double]$JointT = 14.0,
  [int]$JointRun = 20,
  [int]$JointMax = 26,
  [switch]$Map,
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

public class Fix19 {
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
  static double[,] BoxBlur(double[,] a, int r) {
    int gx=a.GetLength(0), gy=a.GetLength(1);
    double[,] tmp=new double[gx,gy], outv=new double[gx,gy];
    for (int i=0;i<gx;i++) for (int j=0;j<gy;j++) {
      double s=0; int n=0;
      for (int d=-r;d<=r;d++){ int jj=j+d; if (jj<0||jj>=gy) continue; s+=a[i,jj]; n++; }
      tmp[i,j]=s/n;
    }
    for (int i=0;i<gx;i++) for (int j=0;j<gy;j++) {
      double s=0; int n=0;
      for (int d=-r;d<=r;d++){ int ii=i+d; if (ii<0||ii>=gx) continue; s+=tmp[ii,j]; n++; }
      outv[i,j]=s/n;
    }
    return outv;
  }
  // only brighten (never darken): preserves the wood contrast in the well-lit centre
  public static void FlatField(double maxGain, int down, int blurR) {
    int gx=(W+down-1)/down, gy=(H+down-1)/down;
    double[,] g0=new double[gx,gy];
    for (int i=0;i<gx;i++) for (int j=0;j<gy;j++) {
      double s=0; int n=0;
      for (int y=j*down; y<Math.Min(H,(j+1)*down); y+=2)
        for (int x=i*down; x<Math.Min(W,(i+1)*down); x+=2) { s+=G(x,y); n++; }
      g0[i,j]=n>0?s/n:0;
    }
    double[,] g1=BoxBlur(g0, blurR);
    List<double> all=new List<double>();
    for (int i=0;i<gx;i++) for (int j=0;j<gy;j++) all.Add(g1[i,j]);
    all.Sort();
    double target=all[(int)(all.Count*0.88)];
    Console.WriteLine("  illum target(p88)=" + target.ToString("F1") + "  min L=" + all[0].ToString("F1") + "  gain needed at darkest=" + (target/Math.Max(all[0],1)).ToString("F2"));
    byte[] blur=new byte[Stride*H];
    for (int y=0;y<H;y++) for (int x=0;x<W;x++) {
      double[] s=new double[3]; int n=0;
      for (int dy=-1;dy<=1;dy++) for (int dx=-1;dx<=1;dx++) {
        int xx=x+dx, yy=y+dy;
        if (xx<0||xx>=W||yy<0||yy>=H) continue;
        for (int ch=0; ch<3; ch++) s[ch]+=Ch(xx,yy,ch);
        n++;
      }
      for (int ch=0; ch<3; ch++) blur[y*Stride+x*4+ch]=(byte)Clamp(s[ch]/n);
      blur[y*Stride+x*4+3]=255;
    }
    for (int y=0;y<H;y++) for (int x=0;x<W;x++) {
      double fx=(double)x/down, fy=(double)y/down;
      int i0=(int)Math.Floor(fx), j0=(int)Math.Floor(fy);
      int i1=Math.Min(i0+1,gx-1), j1=Math.Min(j0+1,gy-1);
      i0=Math.Max(0,Math.Min(i0,gx-1)); j0=Math.Max(0,Math.Min(j0,gy-1));
      double tx=fx-i0, ty=fy-j0;
      double L=g1[i0,j0]*(1-tx)*(1-ty)+g1[i1,j0]*tx*(1-ty)+g1[i0,j1]*(1-tx)*ty+g1[i1,j1]*tx*ty;
      double gain=target/Math.Max(L,1.0);
      if (gain<1.0) gain=1.0;
      if (gain>maxGain) gain=maxGain;
      double w=(gain-1.3)/2.7; if (w<0) w=0; if (w>0.9) w=0.9;
      for (int ch=0; ch<3; ch++) {
        double basev=Ch(x,y,ch)*(1-w)+blur[y*Stride+x*4+ch]*w;
        Rgb[y*Stride+x*4+ch]=(byte)Clamp(basev*gain);
      }
      Rgb[y*Stride+x*4+3]=255;
    }
    Rebuild();
    Console.WriteLine("  flat-field done (only-brighten, maxGain " + maxGain + ")");
  }

  static int Clamp(double v) { return v<0?0:(v>255?255:(int)Math.Round(v)); }
  static double Ch(int x,int y,int ch) { return Rgb[y*Stride+x*4+ch]; }
  static double G(int x,int y) { if (x<0) x=0; if (x>=W) x=W-1; return Gray[y*W+x]; }

  // per-column line strength (relative + hit fraction over the height)
  // line-ness per column: how often the column is clearly darker (or brighter) than its neighbours,
  // and how strong that is on average. Grain lines are weaker/shorter than plank seams.
  static void ColStats(double relT, double absT, double[] hf, double[] md) {
    int y0=60, y1=H-60, n=y1-y0;
    for (int x=0;x<W;x++) {
      int hits=0; double sum=0;
      for (int y=y0;y<y1;y++) {
        double l=0,r=0;
        for (int d=3;d<=8;d++){ l+=G(x-d,y); r+=G(x+d,y); }
        double refv=(l+r)/12.0;
        double dark = refv-G(x,y);
        double bright = G(x,y)-refv;
        double use = Math.Max(dark, bright);
        sum += Math.Max(0.0, use);
        if (use >= Math.Max(absT, relT*refv)) hits++;
      }
      hf[x]=(double)hits/n; md[x]=sum/n;
    }
  }

  // ---- pass 1: drop the seam columns, then stretch each plank back to its original slot ----
  public static void RemoveSeams(double pitch, int maxHalf, double relT, double absT, double hfTh, double minDip) {
    double[] hf=new double[W], md=new double[W];
    ColStats(relT, absT, hf, md);
    List<double> bounds=new List<double>();
    bounds.Add(0);
    for (double c=pitch; c<W-4; c+=pitch) bounds.Add(Math.Round(c));
    bounds.Add(W);
    // per-boundary remove span (interior boundaries only)
    int nb = bounds.Count;
    int[] rl = new int[nb], rr = new int[nb];   // columns removed left/right of each boundary
    for (int i=1;i<nb-1;i++) {
      int c=(int)bounds[i];
      int lo=c, hi=c;
      for (int x=Math.Max(0,c-maxHalf); x<=Math.Min(W-1,c+maxHalf); x++) {
        if (hf[x] >= hfTh && md[x] >= minDip) { if (x<lo) lo=x; if (x>hi) hi=x; }
      }
      if (hi-lo < 5) { lo=c-5; hi=c+5; }       // always drop the core
      rl[i]=c-lo+1; rr[i]=hi-c+1;
      Console.WriteLine("  boundary x=" + c + " drop [" + lo + ".." + hi + "] (" + (hi-lo+1) + " cols)");
    }
    // mirror-fill: every dropped column is replaced by reflecting the clean wood next to the span
    List<int[]> spans=new List<int[]>();
    for (int i=1;i<nb-1;i++) {
      int c=(int)bounds[i];
      int lo=c, hi=c;
      for (int x=Math.Max(0,c-maxHalf); x<=Math.Min(W-1,c+maxHalf); x++) {
        if (hf[x] >= hfTh && md[x] >= minDip) { if (x<lo) lo=x; if (x>hi) hi=x; }
      }
      if (hi-lo < 9) { lo=c-4; hi=c+4; }
      spans.Add(new int[]{lo,hi});
      Console.WriteLine("  boundary x=" + c + " mirror-fill [" + lo + ".." + hi + "] (" + (hi-lo+1) + " cols dropped)");
    }
    double[] sx=new double[W];
    for (int x=0;x<W;x++) {
      double v=x;
      for (int guard=0; guard<6; guard++) {
        bool folded=false;
        foreach (int[] sp in spans) {
          if (v >= sp[0] && v <= sp[1]) { v = 2.0*sp[1]+1.0 - v; folded=true; }
        }
        if (!folded) break;
      }
      if (v<0) v=0; if (v>W-1) v=W-1;
      sx[x]=v;
    }
    byte[] outRgb=new byte[Stride*H];
    for (int y=0;y<H;y++) {
      for (int ox=0; ox<W; ox++) {
        double s=sx[ox];
        int x0=(int)Math.Floor(s); double fx=s-x0;
        int x1=Math.Min(W-1,x0+1); if (x0<0) x0=0;
        for (int ch=0; ch<4; ch++) outRgb[y*Stride+ox*4+ch]=(byte)Clamp(Rgb[y*Stride+x0*4+ch]*(1-fx)+Rgb[y*Stride+x1*4+ch]*fx);
      }
    }
    Array.Copy(outRgb, Rgb, Rgb.Length);
    Rebuild();    Console.WriteLine("  seams removed (mirror-filled)");
  }

  // ---- pass 2: drop the horizontal joint rows per column, then stretch the segments back ----
  public static void RemoveJoints(double T, int runMin, int maxRun) {
    bool[] mark=new bool[W*H];
    for (int y=9;y<H-9;y++) {
      int run=0;
      for (int x=0;x<W;x++) {
        double u=0,d=0;
        for (int k=3;k<=8;k++){ u+=G(x,Math.Max(0,y-k)); d+=G(x,Math.Min(H-1,y+k)); }
        double dip=(u+d)/12.0 - G(x,y);
        if (dip >= T) run++; else run=0;
        if (run>=runMin) for (int k=0;k<run;k++) mark[y*W+x-k]=true;
      }
    }
    byte[] outRgb=new byte[Stride*H];
    for (int x=0;x<W;x++) {
      List<int[]> runs=new List<int[]>();
      int y=6;
      while (y<H-6) {
        if (!mark[y*W+x]) { y++; continue; }
        int y0=y, y1=y;
        while (y1+1<H-6 && (mark[(y1+1)*W+x] || (y1+2<H-6 && mark[(y1+2)*W+x]))) { if (mark[(y1+1)*W+x]) y1++; else y1+=2; }
        if (y1-y0+1 <= maxRun) runs.Add(new int[]{y0,y1});
        y=y1+1;
      }
      for (int oy=0;oy<H;oy++) {
        double v=oy;
        for (int guard=0; guard<6; guard++) {
          bool folded=false;
          foreach (int[] r in runs) { if (v >= r[0] && v <= r[1]) { v = 2.0*r[1]+1.0 - v; folded=true; } }
          if (!folded) break;
        }
        if (v<0) v=0; if (v>H-1) v=H-1;
        int y0=(int)Math.Floor(v); double fy=v-y0;
        int y1=Math.Min(H-1,y0+1); if (y0<0) y0=0;
        for (int ch=0; ch<4; ch++) outRgb[oy*Stride+x*4+ch]=(byte)Clamp(Rgb[y0*Stride+x*4+ch]*(1-fy)+Rgb[y1*Stride+x*4+ch]*fy);
      }
    }
    Array.Copy(outRgb, Rgb, Rgb.Length);
    Rebuild();    Console.WriteLine("  joints removed (mirror-filled)");
  }

  // ---- verification ----
  public static void LineStats(string tag) {
    double[] hf=new double[W], md=new double[W];
    ColStats(0.05, 3.0, hf, md);
    int cnt=0; double worst=0; int wx=-1;
    for (int x=9;x<W-9;x++) { if (hf[x]>=0.45 && md[x]>=3.0) cnt++; if (md[x]>worst) { worst=md[x]; wx=x; } }
    Console.WriteLine(tag + " 竖线：列(hitFrac>=0.45 且 平均落差>=3)=" + cnt + "，最大列落差=" + worst.ToString("F1") + " @x=" + wx);
    // horizontal
    double bw=0; int by=-1;
    for (int y=9;y<H-9;y++) {
      double s=0; int n=0;
      for (int x=100;x<W-100;x+=2) {
        double u=0,d=0;
        for (int k=3;k<=8;k++){ u+=G(x,Math.Max(0,y-k)); d+=G(x,Math.Min(H-1,y+k)); }
        s += (u+d)/12.0 - G(x,y); n++;
      }
      double v=s/n; if (v>bw) { bw=v; by=y; }
    }
    Console.WriteLine(tag + " 横线：最大行落差=" + bw.ToString("F1") + " @y=" + by);
  }
  public static void EdgeStats(string tag) {
    double t=0,b=0,l=0,r=0,c=0;
    for (int x=200;x<W-200;x+=4){ t+=G(x,2); b+=G(x,H-3); c+=G(x,H/2); }
    for (int y=200;y<H-200;y+=4){ l+=G(2,y); r+=G(W-3,y); }
    int n1=(W-400)/4, n2=(H-400)/4;
    Console.WriteLine(tag + " 上=" + (t/n1).ToString("F0") + " 下=" + (b/n1).ToString("F0") + " 左=" + (l/n2).ToString("F0") + " 右=" + (r/n2).ToString("F0") + " 中心=" + (c/n1).ToString("F0"));
  }
  public static void Strip(int x0,int x1,int y0,int y1,string tag) {
    double s=0,s2=0; int n=0;
    for (int y=y0;y<y1;y++) for (int x=x0;x<x1;x++){ double v=G(x,y); s+=v; s2+=v*v; n++; }
    double m=s/n; Console.WriteLine(tag + " mean=" + m.ToString("F0") + " sd=" + Math.Sqrt(Math.Max(0,s2/n-m*m)).ToString("F1"));
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

# 他圈的位置（从蓝标记里读出来的 16 处）——用来做局部放大对比
$xsC = @(280, 658, 434, 947, 838, 545)
$ysC = @(659, 1781, 1207, 739, 577, 1634)

[Fix19]::Load($Src)
[Fix19]::LineStats(($t=$null)) #'BEFORE')
if ($Crops) { [Fix19]::CropStack($CropBefore, $xsC, $ysC, 140, 110, 3, 8) }
[Fix19]::FlatField(9.0, 16, 4)
[Fix19]::EdgeStats('AFTER-FF ' )
[Fix19]::RemoveSeams($Pitch, $MaxHalf, 0.06, 4.0, $HitFrac, 8.0)
[Fix19]::LineStats(($t=$null)) #'AFTER-SEAM')
[Fix19]::RemoveJoints($JointT, $JointRun, $JointMax)
[Fix19]::LineStats(($t=$null)) #'AFTER-JOINT')
[Fix19]::Strip(500,580,900,1000,'板内(成品)')
if ($Crops) { [Fix19]::CropStack($CropAfter, $xsC, $ysC, 140, 110, 3, 8) }
[Fix19]::SavePng($OutPng)
[Fix19]::SaveJpg($OutJpg)

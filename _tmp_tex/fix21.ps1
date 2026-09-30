param(
  [Parameter(Mandatory=$true)][string]$Src,
  [Parameter(Mandatory=$true)][string]$OutPng,
  [Parameter(Mandatory=$true)][string]$OutJpg,
  [double]$Pitch = 99.0,
  [int]$SeamHalf = 26,
  [double]$JointT = 6.0,
  [int]$JointRun = 20,
  [int]$JointMax = 30,
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

public class Fix21 {
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
  static double G(int x,int y) { if(x<0)x=0; if(x>=W)x=W-1; if(y<0)y=0; if(y>=H)y=H-1; return Gray[y*W+x]; }
  static double Median(List<double> a) { a.Sort(); int n=a.Count; return n==0?0:((n%2==1)?a[n/2]:(a[n/2-1]+a[n/2])*0.5); }

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
    List<double> all=new List<double>(); for (int i=0;i<gx;i++) for (int j=0;j<gy;j++) all.Add(g1[i,j]);
    all.Sort(); double target=all[(int)(all.Count*0.88)];
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
    Rebuild(); Console.WriteLine("  flat-field ok (target " + target.ToString("F0") + ")");
  }

  // ---- vertical seams: mark dark OR bright columns near each boundary, then mirror-fill them ----
  public static void Seams(double pitch, int half, double relT, double absT, double fracTh) {
    int n=H-120;
    double[] dark=new double[W], bright=new double[W];
    int[] darkCnt=new int[W], brightCnt=new int[W];
    for (int x=0;x<W;x++) {
      double sd=0,sb=0; int cd=0,cb=0;
      for (int y=60;y<H-60;y++) {
        double l=0,r=0;
        for (int d=4;d<=10;d++){ l+=G(x-d,y); r+=G(x+d,y); }
        double refv=(l+r)/14.0;
        double dv=refv-G(x,y), bv=G(x,y)-refv;
        double th=Math.Max(absT, relT*refv);
        if (dv>0) sd+=dv; if (bv>0) sb+=bv;
        if (dv>=th) cd++; if (bv>=th) cb++;
      }
      dark[x]=sd/n; bright[x]=sb/n; darkCnt[x]=cd; brightCnt[x]=cb;
    }
    List<int[]> spans=new List<int[]>();
    for (double c=pitch; c<W-half-4; c+=pitch) {
      int cc=(int)Math.Round(c);
      int lo=cc, hi=cc;
      for (int x=Math.Max(0,cc-half); x<=Math.Min(W-1,cc+half); x++) {
        bool line = (darkCnt[x] >= fracTh*n && dark[x] >= 4.0) || (brightCnt[x] >= fracTh*n && bright[x] >= 4.0);
        if (line) { if (x<lo) lo=x; if (x>hi) hi=x; }
      }
      if (hi-lo < 6) { lo=cc-3; hi=cc+3; }
      spans.Add(new int[]{lo,hi});
      Console.WriteLine("  seam x=" + cc + " mirror-fill [" + lo + ".." + hi + "] (" + (hi-lo+1) + " cols)");
    }
    double[] sx=new double[W];
    for (int x=0;x<W;x++) {
      double v=x;
      for (int g=0; g<6; g++) { bool f=false; foreach (int[] sp in spans) if (v>=sp[0]&&v<=sp[1]) { v=2.0*sp[1]+1.0-v; f=true; } if (!f) break; }
      if (v<0) v=0; if (v>W-1) v=W-1; sx[x]=v;
    }
    byte[] outRgb=new byte[Stride*H];
    for (int y=0;y<H;y++) for (int ox=0;ox<W;ox++) {
      double s=sx[ox]; int x0=(int)Math.Floor(s); double fx=s-x0;
      int x1=Math.Min(W-1,x0+1); if (x0<0) x0=0;
      for (int ch=0;ch<4;ch++) outRgb[y*Stride+ox*4+ch]=(byte)Clamp(Rgb[y*Stride+x0*4+ch]*(1-fx)+Rgb[y*Stride+x1*4+ch]*fx);
    }
    Array.Copy(outRgb, Rgb, Rgb.Length); Rebuild();
  }

  // ---- horizontal joints: mark dark OR bright rows (with a horizontal run filter), then mirror-fill per column ----
  public static void Joints(double relT, double absT, int runMin, int maxRun) {
    bool[] mark=new bool[W*H];
    for (int y=9;y<H-9;y++) {
      int run=0;
      for (int x=0;x<W;x++) {
        double u=0,d=0;
        for (int k=4;k<=10;k++){ u+=G(x,y-k); d+=G(x,y+k); }
        double refv=(u+d)/14.0;
        double dev=Math.Abs(refv-G(x,y));
        if (dev >= Math.Max(absT, relT*refv)) run++; else run=0;
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
      total+=runs.Count;
      for (int oy=0;oy<H;oy++) {
        double v=oy;
        for (int g=0; g<6; g++) { bool f=false; foreach (int[] r in runs) if (v>=r[0]&&v<=r[1]) { v=2.0*r[1]+1.0-v; f=true; } if (!f) break; }
        if (v<0) v=0; if (v>H-1) v=H-1;
        int y0=(int)Math.Floor(v); double fy=v-y0;
        int y1=Math.Min(H-1,y0+1); if (y0<0) y0=0;
        for (int ch=0;ch<4;ch++) outRgb[oy*Stride+x*4+ch]=(byte)Clamp(Rgb[y0*Stride+x*4+ch]*(1-fy)+Rgb[y1*Stride+x*4+ch]*fy);
      }
    }
    Array.Copy(outRgb, Rgb, Rgb.Length); Rebuild();
    Console.WriteLine("  joints mirror-filled (runs=" + total + ")");
  }

  // ---- verification ----
  public static void EdgeStats(string tag) {
    double t=0,b=0,l=0,r=0,c=0;
    for (int x=200;x<W-200;x+=4){ t+=G(x,2); b+=G(x,H-3); c+=G(x,H/2); }
    for (int y=200;y<H-200;y+=4){ l+=G(2,y); r+=G(W-3,y); }
    int n1=(W-400)/4, n2=(H-400)/4;
    Console.WriteLine(tag + " edges: top=" + (t/n1).ToString("F0") + " bottom=" + (b/n1).ToString("F0") + " left=" + (l/n2).ToString("F0") + " right=" + (r/n2).ToString("F0") + " center=" + (c/n1).ToString("F0"));
  }
  public static void ProbeAt(int cx,int cy,int rad,string tag) {
    double mx=0,mbx=0,my=0,mby=0; int ax=0,abx=0,ay=0,aby=0;
    for (int x=Math.Max(11,cx-rad); x<=Math.Min(W-12,cx+rad); x++) {
      double s=0; int n=0;
      for (int y=Math.Max(11,cy-rad); y<=Math.Min(H-12,cy+rad); y++) { double l=0,rr=0; for(int d=4;d<=10;d++){ l+=G(x-d,y); rr+=G(x+d,y); } s+=((l+rr)/14.0-G(x,y)); n++; }
      double v=s/n; if (v>mx){mx=v;ax=x;} if (-v>mbx){mbx=-v;abx=x;}
    }
    for (int y=Math.Max(11,cy-rad); y<=Math.Min(H-12,cy+rad); y++) {
      double s=0; int n=0;
      for (int x=Math.Max(11,cx-rad); x<=Math.Min(W-12,cx+rad); x++) { double u=0,d=0; for(int k=4;k<=10;k++){ u+=G(x,y-k); d+=G(x,y+k); } s+=((u+d)/14.0-G(x,y)); n++; }
      double v=s/n; if (v>my){my=v;ay=y;} if (-v>mby){mby=-v;aby=y;}
    }
    Console.WriteLine("  " + tag + " (" + cx + "," + cy + ") vert(dark " + mx.ToString("F1") + "@" + ax + " / bright " + mbx.ToString("F1") + "@" + abx + ")  horiz(dark " + my.ToString("F1") + "@" + ay + " / bright " + mby.ToString("F1") + "@" + aby + ")");
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

$xsC = @(932, 948, 280, 658, 544, 436, 838, 818, 642, 520, 998, 1004, 940, 1032)
$ysC = @(1422, 738, 660, 1782, 1634, 1206, 578, 976, 684, 500, 1092, 1688, 32, 1026)

[Fix21]::Load($Src)
if ($Report) {
  [Fix21]::EdgeStats('BEFORE')
  for ($i=0; $i -lt 14; $i++) { [Fix21]::ProbeAt($xsC[$i], $ysC[$i], 30, 'BEFORE') }
}
if ($Crops) { [Fix21]::CropStack($CropBefore, $xsC, $ysC, 140, 110, 3, 8) }
[Fix21]::FlatField(9.0, 16, 4)
[Fix21]::Seams($Pitch, $SeamHalf, 0.06, 4.0, 0.5)
[Fix21]::Joints(0.06, $JointT, $JointRun, $JointMax)
[Fix21]::EdgeStats('AFTER ')
if ($Report) { for ($i=0; $i -lt 14; $i++) { [Fix21]::ProbeAt($xsC[$i], $ysC[$i], 30, 'AFTER ') } }
if ($Crops) { [Fix21]::CropStack($CropAfter, $xsC, $ysC, 140, 110, 3, 8) }
[Fix21]::SavePng($OutPng)
[Fix21]::SaveJpg($OutJpg)

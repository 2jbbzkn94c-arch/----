param(
  [Parameter(Mandatory=$true)][string]$Src,
  [Parameter(Mandatory=$true)][string]$OutPng,
  [Parameter(Mandatory=$true)][string]$OutJpg,
  [double]$MaxLift = 130.0,
  [double]$T = 9.0,
  [double]$RelT = 0.07,
  [int]$RunMin = 16,
  [int]$Iters = 3,
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

public class Fix22 {
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
  static double Ch(int x,int y,int ch) { if(x<0)x=0; if(x>=W)x=W-1; if(y<0)y=0; if(y>=H)y=H-1; return Rgb[y*Stride+x*4+ch]; }
  static double G(int x,int y) { if(x<0)x=0; if(x>=W)x=W-1; if(y<0)y=0; if(y>=H)y=H-1; return Gray[y*W+x]; }
  static double Median(List<double> a) { a.Sort(); int n=a.Count; return n==0?0:((n%2==1)?a[n/2]:(a[n/2-1]+a[n/2])*0.5); }

  // ---------- additive lift (brightens the vignette WITHOUT amplifying local contrast) ----------
  public static void Lift(double maxLift, int down, int blurR) {
    int gx=(W+down-1)/down, gy=(H+down-1)/down;
    double[,] g0=new double[gx,gy];
    for (int i=0;i<gx;i++) for (int j=0;j<gy;j++) {
      double s=0; int n=0;
      for (int y=j*down;y<Math.Min(H,(j+1)*down);y+=2) for (int x=i*down;x<Math.Min(W,(i+1)*down);x+=2) { s+=G(x,y); n++; }
      g0[i,j]=n>0?s/n:0;
    }
    double[,] tmp=new double[gx,gy], g1=new double[gx,gy];
    for (int i=0;i<gx;i++) for (int j=0;j<gy;j++) { double s=0; int n=0; for (int d=-blurR;d<=blurR;d++){ int jj=j+d; if (jj<0||jj>=gy) continue; s+=g0[i,jj]; n++; } tmp[i,j]=s/n; }
    for (int i=0;i<gx;i++) for (int j=0;j<gy;j++) { double s=0; int n=0; for (int d=-blurR;d<=blurR;d++){ int ii=i+d; if (ii<0||ii>=gx) continue; s+=tmp[ii,j]; n++; } g1[i,j]=s/n; }
    List<double> all=new List<double>(); for (int i=0;i<gx;i++) for (int j=0;j<gy;j++) all.Add(g1[i,j]);
    all.Sort(); double target=all[(int)(all.Count*0.88)];
    for (int y=0;y<H;y++) for (int x=0;x<W;x++) {
      double fx=(double)x/down, fy=(double)y/down;
      int i0=(int)Math.Floor(fx), j0=(int)Math.Floor(fy);
      int i1=Math.Min(i0+1,gx-1), j1=Math.Min(j0+1,gy-1);
      i0=Math.Max(0,Math.Min(i0,gx-1)); j0=Math.Max(0,Math.Min(j0,gy-1));
      double tx=fx-i0, ty=fy-j0;
      double L=g1[i0,j0]*(1-tx)*(1-ty)+g1[i1,j0]*tx*(1-ty)+g1[i0,j1]*(1-tx)*ty+g1[i1,j1]*tx*ty;
      double lift=target-L; if (lift<0) lift=0; if (lift>maxLift) lift=maxLift;
      for (int ch=0;ch<3;ch++) Rgb[y*Stride+x*4+ch]=(byte)Clamp(Ch(x,y,ch)+lift);
      Rgb[y*Stride+x*4+3]=255;
    }
    Rebuild(); Console.WriteLine("  additive lift ok (target " + target.ToString("F0") + ", maxLift " + maxLift + ")");
  }

  // ---------- remove vertical line structures (runs along y, replaced by the horizontal median) ----------
  public static int KillVertical(double T, double relT, int runMin) {
    bool[] m=new bool[W*H];
    for (int y=0;y<H;y++) for (int x=12;x<W-12;x++) {
      List<double> s=new List<double>();
      for (int d=4;d<=12;d++){ s.Add(G(x-d,y)); s.Add(G(x+d,y)); }
      double med=Median(s);
      double dev=Math.Abs(med-G(x,y));
      m[y*W+x]= dev >= Math.Max(T, relT*Math.Max(med,20.0));
    }
    int n=0;
    for (int x=12;x<W-12;x++) {
      int y=0;
      while (y<H) {
        if (!m[y*W+x]) { y++; continue; }
        int y0=y,y1=y; int cnt=1;
        while (y1+1<H) { if (m[(y1+1)*W+x]) { y1++; cnt++; } else if (y1+2<H && m[(y1+2)*W+x]) { y1+=2; cnt+=2; } else break; }
        if (cnt>=runMin) {
          for (int yy=y0; yy<=y1; yy++) {
            List<double>[] hs=new List<double>[3];
            for (int ch=0;ch<3;ch++) hs[ch]=new List<double>();
            for (int d=4;d<=12;d++) for (int ch=0;ch<3;ch++){ hs[ch].Add(Ch(x-d,yy,ch)); hs[ch].Add(Ch(x+d,yy,ch)); }
            for (int ch=0;ch<3;ch++) Rgb[yy*Stride+x*4+ch]=(byte)Clamp(Median(hs[ch]));
            n++;
          }
        }
        y=y1+1;
      }
    }
    Rebuild();
    return n;
  }
  // ---------- remove horizontal line structures (runs along x, replaced by the vertical median) ----------
  public static int KillHorizontal(double T, double relT, int runMin) {
    bool[] m=new bool[W*H];
    for (int y=12;y<H-12;y++) for (int x=0;x<W;x++) {
      List<double> s=new List<double>();
      for (int d=4;d<=12;d++){ s.Add(G(x,y-d)); s.Add(G(x,y+d)); }
      double med=Median(s);
      double dev=Math.Abs(med-G(x,y));
      m[y*W+x]= dev >= Math.Max(T, relT*Math.Max(med,20.0));
    }
    int n=0;
    for (int y=12;y<H-12;y++) {
      int x=0;
      while (x<W) {
        if (!m[y*W+x]) { x++; continue; }
        int x0=x,x1=x; int cnt=1;
        while (x1+1<W) { if (m[y*W+x1+1]) { x1++; cnt++; } else if (x1+2<W && m[y*W+x1+2]) { x1+=2; cnt+=2; } else break; }
        if (cnt>=runMin) {
          for (int xx=x0; xx<=x1; xx++) {
            List<double>[] vs=new List<double>[3];
            for (int ch=0;ch<3;ch++) vs[ch]=new List<double>();
            for (int d=4;d<=12;d++) for (int ch=0;ch<3;ch++){ vs[ch].Add(Ch(xx,y-d,ch)); vs[ch].Add(Ch(xx,y+d,ch)); }
            for (int ch=0;ch<3;ch++) Rgb[y*Stride+xx*4+ch]=(byte)Clamp(Median(vs[ch]));
            n++;
          }
        }
        x=x1+1;
      }
    }
    Rebuild();
    return n;
  }

  // ---------- verification ----------
  public static void EdgeStats(string tag) {
    double t=0,b=0,l=0,r=0,c=0;
    for (int x=200;x<W-200;x+=4){ t+=G(x,2); b+=G(x,H-3); c+=G(x,H/2); }
    for (int y=200;y<H-200;y+=4){ l+=G(2,y); r+=G(W-3,y); }
    int n1=(W-400)/4, n2=(H-400)/4;
    Console.WriteLine(tag + " edges: top=" + (t/n1).ToString("F0") + " bottom=" + (b/n1).ToString("F0") + " left=" + (l/n2).ToString("F0") + " right=" + (r/n2).ToString("F0") + " center=" + (c/n1).ToString("F0"));
  }
  public static void ProbeAt(int cx,int cy,int rad,string tag) {
    double mx=0,mbx=0,my=0,mby=0; int ax=0,abx=0,ay=0,aby=0;
    for (int x=Math.Max(13,cx-rad); x<=Math.Min(W-14,cx+rad); x++) {
      double s=0; int n=0;
      for (int y=Math.Max(13,cy-rad); y<=Math.Min(H-14,cy+rad); y++) { double l=0,rr=0; for(int d=4;d<=10;d++){ l+=G(x-d,y); rr+=G(x+d,y); } s+=((l+rr)/14.0-G(x,y)); n++; }
      double v=s/n; if (v>mx){mx=v;ax=x;} if (-v>mbx){mbx=-v;abx=x;}
    }
    for (int y=Math.Max(13,cy-rad); y<=Math.Min(H-14,cy+rad); y++) {
      double s=0; int n=0;
      for (int x=Math.Max(13,cx-rad); x<=Math.Min(W-14,cx+rad); x++) { double u=0,d=0; for(int k=4;k<=10;k++){ u+=G(x,y-k); d+=G(x,y+k); } s+=((u+d)/14.0-G(x,y)); n++; }
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

[Fix22]::Load($Src)
if ($Report) { [Fix22]::EdgeStats('BEFORE'); for ($i=0;$i -lt 14;$i++) { [Fix22]::ProbeAt($xsC[$i],$ysC[$i],30,'BEFORE') } }
if ($Crops) { [Fix22]::CropStack($CropBefore, $xsC, $ysC, 140, 110, 3, 8) }
[Fix22]::Lift($MaxLift, 16, 4)
for ($it=1; $it -le $Iters; $it++) {
  $a = [Fix22]::KillVertical($T, $RelT, $RunMin)
  $b = [Fix22]::KillHorizontal($T, $RelT, $RunMin)
  Write-Host ("  iter $it : vertical px=$a  horizontal px=$b")
  if ($a -eq 0 -and $b -eq 0) { break }
}
[Fix22]::EdgeStats('AFTER ')
if ($Report) { for ($i=0;$i -lt 14;$i++) { [Fix22]::ProbeAt($xsC[$i],$ysC[$i],30,'AFTER ') } }
if ($Crops) { [Fix22]::CropStack($CropAfter, $xsC, $ysC, 140, 110, 3, 8) }
[Fix22]::SavePng($OutPng)
[Fix22]::SaveJpg($OutJpg)

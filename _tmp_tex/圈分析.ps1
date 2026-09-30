param(
  [Parameter(Mandatory=$true)][string]$Marked,
  [Parameter(Mandatory=$true)][string]$Mine,
  [int]$Step = 2
)

$cs = @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
public class Ana {
  public static byte[] Rgb; public static byte[] Gray; public static int W,H,Stride;
  public static void Load(string path) {
    Bitmap bmp=new Bitmap(path); W=bmp.Width; H=bmp.Height;
    Bitmap b32=new Bitmap(W,H,PixelFormat.Format32bppArgb);
    using(Graphics g=Graphics.FromImage(b32)) g.DrawImage(bmp,0,0,W,H);
    BitmapData bd=b32.LockBits(new Rectangle(0,0,W,H),ImageLockMode.ReadOnly,PixelFormat.Format32bppArgb);
    Stride=bd.Stride; Rgb=new byte[Stride*H]; Marshal.Copy(bd.Scan0,Rgb,0,Rgb.Length); b32.UnlockBits(bd);
    Gray=new byte[W*H];
    for(int y=0;y<H;y++) for(int x=0;x<W;x++){ int i=y*Stride+x*4; Gray[y*W+x]=(byte)(0.114*Rgb[i]+0.587*Rgb[i+1]+0.299*Rgb[i+2]); }
  }
  static bool IsBlue(int x,int y){ int i=y*Stride+x*4; int b=Rgb[i],g=Rgb[i+1],r=Rgb[i+2]; return b>90 && b-r>40 && b-g>30; }
  public static List<int[]> Boxes(int step) {
    int gw=(W+step-1)/step, gh=(H+step-1)/step;
    bool[,] m=new bool[gw,gh];
    for (int j=0;j<gh;j++) for (int i=0;i<gw;i++)
      for (int y=j*step;y<Math.Min(H,(j+1)*step);y++) { for (int x=i*step;x<Math.Min(W,(i+1)*step);x++) if (IsBlue(x,y)) { m[i,j]=true; break; } if (m[i,j]) break; }
    bool[,] seen=new bool[gw,gh];
    List<int[]> cl=new List<int[]>();
    int[] di={1,-1,0,0}, dj={0,0,1,-1};
    for (int j=0;j<gh;j++) for (int i=0;i<gw;i++) {
      if (!m[i,j]||seen[i,j]) continue;
      Queue<int> q=new Queue<int>(); q.Enqueue(i*gh+j); seen[i,j]=true;
      int x0=i,x1=i,y0=j,y1=j,cnt=0;
      while (q.Count>0) {
        int cur=q.Dequeue(); int ci=cur/gh, cj=cur%gh; cnt++;
        if (ci<x0)x0=ci; if (ci>x1)x1=ci; if (cj<y0)y0=cj; if (cj>y1)y1=cj;
        for (int k=0;k<4;k++) { int ni=ci+di[k], nj=cj+dj[k];
          if (ni<0||ni>=gw||nj<0||nj>=gh) continue;
          if (m[ni,nj]&&!seen[ni,nj]) { seen[ni,nj]=true; q.Enqueue(ni*gh+nj); } }
      }
      int bx0=x0*step, by0=y0*step, bx1=x1*step+step-1, by1=y1*step+step-1;
      if (cnt>=5 && (bx1-bx0)<=420 && (by1-by0)<=420) cl.Add(new int[]{bx0,by0,bx1,by1,cnt});
    }
    cl.Sort(delegate(int[] a,int[] b){ return b[4].CompareTo(a[4]); });
    return cl;
  }
  static double G(int x,int y){ if(x<0)x=0; if(x>=W)x=W-1; if(y<0)y=0; if(y>=H)y=H-1; return Gray[y*W+x]; }
  public static void Probe(int cx,int cy,int r) {
    double maxDarkX=0, maxDarkY=0, maxBrightX=0, maxBrightY=0; int dx=0, dy=0, bx=0, by=0;
    for (int x=Math.Max(9,cx-r); x<=Math.Min(W-10,cx+r); x++) {
      double s=0; int n=0;
      for (int y=Math.Max(9,cy-r); y<=Math.Min(H-10,cy+r); y++) { double l=0,rr=0; for(int d=4;d<=10;d++){ l+=G(x-d,y); rr+=G(x+d,y); } s += ((l+rr)/14.0-G(x,y)); n++; }
      double v=s/n; if (v>maxDarkX){maxDarkX=v;dx=x;} if (-v>maxBrightX){maxBrightX=-v;bx=x;}
    }
    for (int y=Math.Max(9,cy-r); y<=Math.Min(H-10,cy+r); y++) {
      double s=0; int n=0;
      for (int x=Math.Max(9,cx-r); x<=Math.Min(W-10,cx+r); x++) { double u=0,d=0; for(int k=4;k<=10;k++){ u+=G(x,y-k); d+=G(x,y+k); } s += ((u+d)/14.0-G(x,y)); n++; }
      double v=s/n; if (v>maxDarkY){maxDarkY=v;dy=y;} if (-v>maxBrightY){maxBrightY=-v;by=y;}
    }
    Console.WriteLine("   竖(暗 " + maxDarkX.ToString("F1") + " @x" + dx + " / 亮 " + maxBrightX.ToString("F1") + " @x" + bx + ")  横(暗 " + maxDarkY.ToString("F1") + " @y" + dy + " / 亮 " + maxBrightY.ToString("F1") + " @y" + by + ")");
  }
}
'@
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition $cs -ReferencedAssemblies 'System.Drawing' -ErrorAction Stop

[Ana]::Load($Marked)
$boxes = [Ana]::Boxes($Step)
Write-Host ("他画了 " + $boxes.Count + " 个圈（去掉了过大的连通块）")
foreach ($b in $boxes) {
  $cx = [int](($b[0]+$b[2])/2); $cy = [int](($b[1]+$b[3])/2)
  Write-Host ("  圈 x=$($b[0])..$($b[2]) y=$($b[1])..$($b[3])  中心($cx,$cy)  宽$($b[2]-$b[0]+1) 高$($b[3]-$b[1]+1)")
}
[Ana]::Load($Mine)
Write-Host "我的成品在这些圈中心处的线强度（竖/横、暗/亮）："
foreach ($b in $boxes) {
  $cx = [int](($b[0]+$b[2])/2); $cy = [int](($b[1]+$b[3])/2)
  Write-Host ("  中心($cx,$cy)")
  [Ana]::Probe($cx,$cy,30)
}

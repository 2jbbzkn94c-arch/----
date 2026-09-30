param(
  [Parameter(Mandatory=$true)][string]$Img,
  [int]$Step = 3
)

$cs = @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
public class Blue {
  public static byte[] Rgb; public static int W,H,Stride;
  public static void Load(string path) {
    Bitmap bmp=new Bitmap(path); W=bmp.Width; H=bmp.Height;
    Bitmap b32=new Bitmap(W,H,PixelFormat.Format32bppArgb);
    using(Graphics g=Graphics.FromImage(b32)) g.DrawImage(bmp,0,0,W,H);
    BitmapData bd=b32.LockBits(new Rectangle(0,0,W,H),ImageLockMode.ReadOnly,PixelFormat.Format32bppArgb);
    Stride=bd.Stride; Rgb=new byte[Stride*H]; Marshal.Copy(bd.Scan0,Rgb,0,Rgb.Length); b32.UnlockBits(bd);
  }
  static bool IsBlue(int x,int y) {
    int i=y*Stride+x*4;
    int b=Rgb[i], g=Rgb[i+1], r=Rgb[i+2];
    return (b > 90) && (b - r > 40) && (b - g > 30) && (b > r + g - 60);
  }
  public static void BlueMap(string tag, int dr, int dg, int db, int cols, int rows) {
    int total=0;
    Console.WriteLine("---- " + tag + " (B-R>" + dr + ", B-G>" + dg + ", B>" + db + ") ----");
    for (int r=0;r<rows;r++) {
      string s="";
      for (int c=0;c<cols;c++) {
        int x0=c*W/cols, x1=(c+1)*W/cols, y0=r*H/rows, y1=(r+1)*H/rows;
        int cnt=0, tot=0;
        for (int y=y0;y<y1;y+=2) for (int x=x0;x<x1;x+=2) {
          int i=y*Stride+x*4; int b=Rgb[i], g=Rgb[i+1], rr=Rgb[i+2];
          tot++;
          if (b>db && b-rr>dr && b-g>dg) cnt++;
        }
        double f = tot>0 ? (double)cnt/tot : 0;
        total += cnt;
        s += f>=0.5?"#":(f>=0.2?"+":(f>=0.05?".":" "));
      }
      Console.WriteLine(s);
    }
    Console.WriteLine("  blue px ~" + total*4);
  }
  public static void Sample(int x,int y) {
    int i=y*Stride+x*4;
    Console.WriteLine("  (" + x + "," + y + ") RGB=" + Rgb[i+2] + "," + Rgb[i+1] + "," + Rgb[i]);
  }
  public static void Find(string name, int step) {
    int gw=(W+step-1)/step, gh=(H+step-1)/step;
    bool[,] m=new bool[gw,gh];
    for (int j=0;j<gh;j++) for (int i=0;i<gw;i++) {
      bool any=false;
      for (int y=j*step; y<Math.Min(H,(j+1)*step) && !any; y++)
        for (int x=i*step; x<Math.Min(W,(i+1)*step); x++) if (IsBlue(x,y)) { any=true; break; }
      m[i,j]=any;
    }
    bool[,] seen=new bool[gw,gh];
    List<int[]> clusters=new List<int[]>();
    for (int j=0;j<gh;j++) for (int i=0;i<gw;i++) {
      if (!m[i,j] || seen[i,j]) continue;
      // BFS
      Queue<int> q=new Queue<int>();
      q.Enqueue(i*gh+j); seen[i,j]=true;
      int x0=i,x1=i,y0=j,y1=j,cnt=0;
      while (q.Count>0) {
        int cur=q.Dequeue(); int ci=cur/gh, cj=cur%gh; cnt++;
        if (ci<x0) x0=ci; if (ci>x1) x1=ci; if (cj<y0) y0=cj; if (cj>y1) y1=cj;
        int[] di={1,-1,0,0}, dj={0,0,1,-1};
        for (int k=0;k<4;k++) {
          int ni=ci+di[k], nj=cj+dj[k];
          if (ni<0||ni>=gw||nj<0||nj>=gh) continue;
          // allow 1-block gaps so a thin circle is one cluster
          for (int gi=-1; gi<=1; gi++) for (int gj=-1; gj<=1; gj++) {
            int mi=ci+di[k]+gi, mj=cj+dj[k]+gj;
            if (mi<0||mi>=gw||mj<0||mj>=gh) continue;
            if (m[mi,mj] && !seen[mi,mj]) { seen[mi,mj]=true; q.Enqueue(mi*gh+mj); }
          }
        }
      }
      clusters.Add(new int[]{ x0*step, y0*step, x1*step+step-1, y1*step+step-1, cnt });
    }
    clusters.Sort(delegate(int[] a, int[] b){ return b[4].CompareTo(a[4]); });
    Console.WriteLine("---- " + name + " 蓝标记簇 (" + clusters.Count + ") ----");
    int lim=Math.Min(24, clusters.Count);
    for (int k=0;k<lim;k++) {
      int[] c=clusters[k];
      int cx=(c[0]+c[2])/2, cy=(c[1]+c[3])/2;
      Console.WriteLine("  #" + (k+1) + " x=" + c[0] + ".." + c[2] + " y=" + c[1] + ".." + c[3] + "  中心(" + cx + "," + cy + ") 宽" + (c[2]-c[0]+1) + " 高" + (c[3]-c[1]+1) + " 块数" + c[4]);
    }
  }
}
'@
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition $cs -ReferencedAssemblies 'System.Drawing' -ErrorAction Stop
[Blue]::Load($Img)
[Blue]::BlueMap('loose', 40, 30, 90, 54, 48)
[Blue]::BlueMap('strict', 60, 50, 120, 54, 48)
[Blue]::Sample(200,200); [Blue]::Sample(500,500); [Blue]::Sample(900,1500)

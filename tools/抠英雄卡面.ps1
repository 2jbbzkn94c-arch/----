# 抠英雄卡面：把 `assets\英雄卡面\<名字>.png`（白底/纯色底人物图）抠成 `<名字>_人物.png`
#   —— 透明底、裁紧 + 2% 边距、颜色铺满透明区（生成 mipmap 时不会混出白边）。
#
# 用法（在仓库根目录）：
#   pwsh -File tools\抠英雄卡面.ps1                 # 处理所有"还没有 _人物.png"的英雄
#   pwsh -File tools\抠英雄卡面.ps1 -Name 毒蛇淑女    # 只处理某一个（可多个：-Name a,b）
#   pwsh -File tools\抠英雄卡面.ps1 -Force           # 已有 _人物.png 也重抠
#
# 之后**必须重导入**，游戏才会用上新图：
#   & "C:\Users\79076\Desktop\godot.exe" --headless --path . --import
#   （或者切回编辑器窗口，它会自动导入）

param(
	[string[]]$Name = @(),
	[switch]$Force
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$dir = Join-Path $root 'assets\英雄卡面'
if (-not (Test-Path $dir)) { throw "找不到目录：$dir" }

$code = @'
using System; using System.Drawing; using System.Drawing.Imaging; using System.Collections.Generic; using System.Runtime.InteropServices;
public class HeroCutout {
  public static string Run(string inPath, string outPath) {
    Bitmap src = new Bitmap(inPath); int W=src.Width, H=src.Height;
    BitmapData bd=src.LockBits(new Rectangle(0,0,W,H), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
    int st=bd.Stride; byte[] buf=new byte[st*H]; Marshal.Copy(bd.Scan0,buf,0,buf.Length); src.UnlockBits(bd); src.Dispose();
    // 底：四角均色，从边界泛洪（阈值 45 = 逐通道差之和）⇒ 只有"连到边界"的底色被抠掉，人物身上的白不被误伤
    long br=0,bg=0,bb=0; int n=0; int[] xs={4,W-5,4,W-5}, ys={4,4,H-5,H-5};
    for(int i=0;i<4;i++) for(int dy=-3;dy<=3;dy++) for(int dx=-3;dx<=3;dx++){
      int o=(ys[i]+dy)*st+(xs[i]+dx)*4; br+=buf[o+2]; bg+=buf[o+1]; bb+=buf[o]; n++; }
    int BR=(int)(br/n), BG=(int)(bg/n), BB=(int)(bb/n);
    bool[] bgm=new bool[W*H]; int[] q=new int[W*H]; int qh=0,qt=0;
    for(int x=0;x<W;x++) for(int k=0;k<2;k++){ int y=k==0?0:H-1,o=y*st+x*4;
      if(Math.Abs(buf[o+2]-BR)+Math.Abs(buf[o+1]-BG)+Math.Abs(buf[o]-BB)<=45 && !bgm[y*W+x]){ bgm[y*W+x]=true; q[qh++]=y*W+x; } }
    for(int y=0;y<H;y++) for(int k=0;k<2;k++){ int x=k==0?0:W-1,o=y*st+x*4;
      if(Math.Abs(buf[o+2]-BR)+Math.Abs(buf[o+1]-BG)+Math.Abs(buf[o]-BB)<=45 && !bgm[y*W+x]){ bgm[y*W+x]=true; q[qh++]=y*W+x; } }
    while(qt<qh){ int p=q[qt++]; int px=p%W, py=p/W;
      for(int k=0;k<4;k++){ int nx=px+(k==0?1:(k==1?-1:0)), ny=py+(k==2?1:(k==3?-1:0));
        if(nx<0||ny<0||nx>=W||ny>=H) continue; int qq=ny*W+nx; if(bgm[qq]) continue;
        int o=ny*st+nx*4;
        if(Math.Abs(buf[o+2]-BR)+Math.Abs(buf[o+1]-BG)+Math.Abs(buf[o]-BB)<=45){ bgm[qq]=true; q[qh++]=qq; } } }
    // 前景连通域：只留最大的那个（人物本体，含武器/帽子的分离小块按面积 >= 最大域 2% 一起留）
    int[] lab=new int[W*H]; int[] stk=new int[W*H]; int cur=0;
    List<int[]> comps=new List<int[]>(); List<List<int>> pixs=new List<List<int>>();
    for(int i=0;i<W*H;i++){ if(bgm[i]||lab[i]!=0) continue; cur++; int sp=0; stk[sp++]=i; lab[i]=cur;
      int minx=W,miny=H,maxx=0,maxy=0; long sr=0,sg=0,sb=0; List<int> pix=new List<int>();
      while(sp>0){ int p=stk[--sp]; int px=p%W, py=p/W; pix.Add(p);
        int o=py*st+px*4; sr+=buf[o+2]; sg+=buf[o+1]; sb+=buf[o];
        if(px<minx)minx=px; if(px>maxx)maxx=px; if(py<miny)miny=py; if(py>maxy)maxy=py;
        for(int dy=-1;dy<=1;dy++) for(int dx=-1;dx<=1;dx++){ int nx=px+dx, ny=py+dy;
          if(nx<0||ny<0||nx>=W||ny>=H) continue; int qq=ny*W+nx; if(!bgm[qq]&&lab[qq]==0){lab[qq]=cur; stk[sp++]=qq;} } }
      // 记录：面积, bbox, **均色**（均色用于下面判"被人物围住的底色残块"）
      comps.Add(new int[]{pix.Count,minx,miny,maxx,maxy,(int)(sr/Math.Max(pix.Count,1)),(int)(sg/Math.Max(pix.Count,1)),(int)(sb/Math.Max(pix.Count,1))});
      pixs.Add(pix); }
    if(comps.Count==0) return "（整张图都是底色，没抠到人物）";
    int big=0; for(int i=1;i<comps.Count;i++) if(comps[i][0]>comps[big][0]) big=i;
    // 保留规则（2026-09-27 两次修正后）：
    //  ① **被人物围住的底色残块 ⇒ 丢**（用户报「负墟有块白色的地方没扣到」：原图里那 162×362 的封闭白区
    //     连不到画面边界、泛洪吃不到 ⇒ 原来被当成"人物身上的元素"整块留下）。判据 = 均色贴近底色 且
    //     面积 ≤ 人物域的 12%（够大才算"残块"；白游侠/圣光那种大片白色是**连着人物轮廓**的同一个域，不受影响）。
    //  ② **人物附近**（最大域 bbox 外扩 6%）且**面积 >= 24px** 的块都留 —— 这批图常带漂浮装饰（星星/礼物/金币）；
    //     面积 < 24px 的是底色噪点、远处的大块是没泛洪干净的底色，两类都丢。
    int bx0=comps[big][1], by0=comps[big][2], bx1=comps[big][3], by1=comps[big][4];
    int pad=Math.Max(8,(int)(Math.Max(bx1-bx0,by1-by0)*0.06));
    bool[] keep=new bool[comps.Count]; int kept=0,dropN=0,dropA=0,pocketN=0,pocketA=0;
    for(int i=0;i<comps.Count;i++){
      if(i==big){ keep[i]=true; kept++; continue; }
      bool near = comps[i][3]>=bx0-pad && comps[i][1]<=bx1+pad && comps[i][4]>=by0-pad && comps[i][2]<=by1+pad;
      bool bgPocket = (Math.Abs(comps[i][5]-BR)+Math.Abs(comps[i][6]-BG)+Math.Abs(comps[i][7]-BB) <= 60)
                      && comps[i][0] <= (int)(comps[big][0]*0.12);
      if(bgPocket){ pocketN++; pocketA+=comps[i][0]; }
      if(near && comps[i][0]>=24 && !bgPocket){ keep[i]=true; kept++; } else { dropN++; dropA+=comps[i][0]; }
    }
    // ③【2026-09-27·用户报「负墟有块白色的地方没扣到」】**挖掉被人物围住的底色洞**。
    //   边界泛洪只吃"连到画面边界"的底色；人物围出来的封闭白区（如两腿之间、身体与武器之间）泛洪吃不到，
    //   而且洞边的抗锯齿像素会把它和人物**并成同一个域** ⇒ ② 的"丢小碎块"碰不到它。这里单独再泛洪一次：
    //   颜色贴近底色（与边界泛洪同容差 45）且**没被边界泛洪吃到**的像素＝洞；按连通块统计，
    //   **只挖面积 ≤ 人物域 12% 的洞**（白游侠/圣光那种大片白色通常超 12%，保留）。
    bool[] holeSeed=new bool[W*H];
    for(int i=0;i<W*H;i++){ if(bgm[i]) continue; int px=i%W, py=i/W; int o=py*st+px*4;
      if(Math.Abs(buf[o+2]-BR)+Math.Abs(buf[o+1]-BG)+Math.Abs(buf[o]-BB)<=45) holeSeed[i]=true; }
    bool[] hole=new bool[W*H]; int holeN=0; long holeA=0;
    int[] hlab=new int[W*H]; int[] hstk=new int[W*H]; int hcur=0;
    for(int i=0;i<W*H;i++){ if(!holeSeed[i]||hlab[i]!=0) continue; hcur++; int sp=0; hstk[sp++]=i; hlab[i]=hcur;
      List<int> hp=new List<int>();
      while(sp>0){ int p=hstk[--sp]; int px=p%W, py=p/W; hp.Add(p);
        for(int dy=-1;dy<=1;dy++) for(int dx=-1;dx<=1;dx++){ int nx=px+dx, ny=py+dy;
          if(nx<0||ny<0||nx>=W||ny>=H) continue; int qq=ny*W+nx; if(holeSeed[qq]&&hlab[qq]==0){hlab[qq]=hcur; hstk[sp++]=qq;} } }
      if(hp.Count <= (int)(comps[big][0]*0.12)){ foreach(int p in hp) hole[p]=true; holeN++; holeA+=hp.Count; }
    }
    int kx0=W,ky0=H,kx1=0,ky1=0;
    for(int i=0;i<comps.Count;i++) if(keep[i]){ if(comps[i][1]<kx0)kx0=comps[i][1]; if(comps[i][2]<ky0)ky0=comps[i][2];
      if(comps[i][3]>kx1)kx1=comps[i][3]; if(comps[i][4]>ky1)ky1=comps[i][4]; }
    int m=Math.Max(4,(int)(Math.Max(kx1-kx0,ky1-ky0)*0.02));
    int cx0=Math.Max(0,kx0-m), cy0=Math.Max(0,ky0-m), cx1=Math.Min(W-1,kx1+m), cy1=Math.Min(H-1,ky1+m);
    int cw=cx1-cx0+1, ch=cy1-cy0+1;
    byte[] outb=new byte[cw*ch*4]; bool[] solid=new bool[W*H];
    for(int i=0;i<comps.Count;i++){ if(!keep[i]) continue; foreach(int p in pixs[i]) solid[p]=true; }
    for(int y=0;y<ch;y++) for(int x=0;x<cw;x++){
      int sp2=(cy0+y)*W+(cx0+x); int oS=sp2*4, oD=(y*cw+x)*4;
      for(int c=0;c<3;c++) outb[oD+c]=buf[oS+c];
      if(solid[sp2] && !hole[sp2]) outb[oD+3]=255; else if(solid[sp2]) outb[oD+3]=0;   // 洞：当底色挖掉
      else { int cnt=0;
        if(cx0+x>0&&solid[sp2-1]&&!hole[sp2-1])cnt++; if(cx0+x<W-1&&solid[sp2+1]&&!hole[sp2+1])cnt++;
        if(cy0+y>0&&solid[sp2-W]&&!hole[sp2-W])cnt++; if(cy0+y<H-1&&solid[sp2+W]&&!hole[sp2+W])cnt++;
        outb[oD+3]=(byte)(cnt*64); } }
    // 多源 BFS：把不透明像素的颜色**铺满**整张画布（alpha 不动）⇒ mipmap 任何一层都不会混出白雾
    int N=cw*ch; bool[] asg=new bool[N]; int[] q2=new int[N]; int qh2=0, qt2=0;
    for(int i=0;i<N;i++) if(outb[i*4+3]==255){ asg[i]=true; q2[qh2++]=i; }
    while(qt2<qh2){ int idx=q2[qt2++]; int x=idx%cw, y=idx/cw; int o=idx*4;
      for(int k=0;k<4;k++){ int nx=x+(k==0?1:(k==1?-1:0)), ny=y+(k==2?1:(k==3?-1:0));
        if(nx<0||ny<0||nx>=cw||ny>=ch) continue; int nidx=ny*cw+nx; if(asg[nidx]) continue;
        int no=nidx*4; outb[no]=outb[o]; outb[no+1]=outb[o+1]; outb[no+2]=outb[o+2]; asg[nidx]=true; q2[qh2++]=nidx; } }
    Bitmap ob=new Bitmap(cw,ch,PixelFormat.Format32bppArgb);
    BitmapData od=ob.LockBits(new Rectangle(0,0,cw,ch), ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
    for(int y=0;y<ch;y++) Marshal.Copy(outb, y*cw*4, (IntPtr)((long)od.Scan0+y*od.Stride), cw*4);
    ob.UnlockBits(od); ob.Save(outPath, ImageFormat.Png); ob.Dispose();
    long rr=0,gg=0,bbb=0; int cc=0;
    for(int i=0;i<N;i++) if(outb[i*4+3]<2){ rr+=outb[i*4+2]; gg+=outb[i*4+1]; bbb+=outb[i*4]; cc++; }
    return String.Format("底色 RGB({0},{1},{2}) · 人物 {3}x{4} ⇒ 输出 {5}x{6}（透明 {7}%，透明区均色 RGB({8},{9},{10})）· 丢掉 {11} 个碎块 {12}px · 保留 {13} 块",
      BR,BG,BB, kx1-kx0+1,ky1-ky0+1, cw,ch, (int)(100.0*cc/N), (int)(rr/Math.Max(cc,1)),(int)(gg/Math.Max(cc,1)),(int)(bbb/Math.Max(cc,1)), dropN,dropA,kept) + String.Format(" · 挖掉被围住的底色洞 {0} 个 {1}px", holeN, holeA); } }
'@
Add-Type -TypeDefinition $code -ReferencedAssemblies System.Drawing

$targets = @()
# 支持 png / jpg / jpeg / webp：豆包那边经常导出 **jpg**（没有透明通道、一定带底色），
#   一样要抠成 `<名字>_人物.png`（游戏只认 png；`assets\英雄卡面\<名字>.jpg` 是找不到的）。
$exts = @('.png', '.jpg', '.jpeg', '.webp')
if ($Name.Count -gt 0) {
	foreach ($nm in $Name) {
		$hit = $null
		foreach ($e in $exts) { $p = Join-Path $dir "$nm$e"; if (Test-Path $p) { $hit = $p; break } }
		if ($null -ne $hit) { $targets += $hit } else { Write-Host "找不到：$nm（.png/.jpg/.jpeg/.webp 都没有）" -ForegroundColor Yellow }
	}
} else {
	Get-ChildItem $dir -File | Where-Object {
		$exts -contains $_.Extension.ToLower() -and $_.BaseName -notlike '*_人物' -and $_.BaseName -notlike '*_原图*'
	} | ForEach-Object { $targets += $_.FullName }
}

$done = 0
foreach ($t in $targets) {
	if (-not (Test-Path $t)) { Write-Host "跳过（找不到）：$t" -ForegroundColor Yellow; continue }
	$base = [System.IO.Path]::GetFileNameWithoutExtension($t)
	if ($base -like '*_人物' -or $base -like '*_原图*') { continue }
	$out = Join-Path $dir "${base}_人物.png"
	if ((Test-Path $out) -and -not $Force) { Write-Host "已有 _人物.png，跳过：$base（要重抠加 -Force）" -ForegroundColor DarkGray; continue }
	Write-Host "抠：$base" -ForegroundColor Cyan
	$r = [HeroCutout]::Run($t, $out)
	Write-Host "   $r"
	$done++
}
Write-Host ""
Write-Host "完成 $done 个。别忘了重导入：godot.exe --headless --path . --import" -ForegroundColor Green

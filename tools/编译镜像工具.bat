@echo off
set CSC="C:\WINDOWS\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
set PF="C:\WINDOWS\Microsoft.NET\assembly\GAC_MSIL\PresentationFramework\v4.0_4.0.0.0__31bf3856ad364e35\PresentationFramework.dll"
set PC="C:\WINDOWS\Microsoft.NET\assembly\GAC_32\PresentationCore\v4.0_4.0.0.0__31bf3856ad364e35\PresentationCore.dll"
set WB="C:\WINDOWS\Microsoft.NET\assembly\GAC_MSIL\WindowsBase\v4.0_4.0.0.0__31bf3856ad364e35\WindowsBase.dll"
set SX="C:\WINDOWS\Microsoft.NET\assembly\GAC_MSIL\System.Xaml\v4.0_4.0.0.0__b77a5c561934e089\System.Xaml.dll"
cd /d "%~dp0"
%CSC% /nologo /target:winexe /out:"旋转窗口工具WPF.exe" /r:%PF% /r:%PC% /r:%WB% /r:%SX% /r:System.Drawing.dll "旋转窗口工具WPF.cs"
echo done: 旋转窗口工具WPF.exe
pause
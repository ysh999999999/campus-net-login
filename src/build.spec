# -*- mode: python ; coding: utf-8 -*-
"""
CampusNetLogin 打包配置（PyInstaller）

选用 onedir 而非原来的 onefile：
  onefile 每次启动都要把整个压缩包解压到 %TEMP%\_MEI*（实测 274~387 MB），
  单次登录常超过 3 分钟；进程被挂起时残留不会清理，曾累积出约 1 GB 垃圾。
  onedir 就地加载，冷启动与磁盘占用都明显更低。

用法：pyinstaller build.spec
产物：dist\CampusNetLogin\CampusNetLogin.exe
"""

from PyInstaller.utils.hooks import collect_all

# ddddocr / onnxruntime / cv2 含大量动态加载的数据文件与 DLL，必须整包收集
datas, binaries, hiddenimports = [], [], []
for pkg in ("ddddocr", "onnxruntime", "cv2", "playwright"):
    try:
        d, b, h = collect_all(pkg)
        datas += d
        binaries += b
        hiddenimports += h
    except Exception:
        pass

block_cipher = None

a = Analysis(
    ["campus_net_login.py"],
    pathex=[],
    binaries=binaries,
    datas=datas,
    hiddenimports=hiddenimports,
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[
        # 体积优化：这些用不到
        "tkinter", "matplotlib", "scipy", "pandas", "notebook",
        "pytest", "PIL.ImageQt",
    ],
    win_no_prefer_redirects=False,
    win_private_assemblies=False,
    cipher=block_cipher,
    noarchive=False,
)

pyz = PYZ(a.pure, a.zipped_data, cipher=block_cipher)

exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name="CampusNetLogin",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    console=True,          # 保持控制台：自动模式会打印进度，且窗口由监控脚本控制显隐
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
)

coll = COLLECT(
    exe,
    a.binaries,
    a.zipfiles,
    a.datas,
    strip=False,
    upx=False,
    upx_exclude=[],
    name="CampusNetLogin",
)

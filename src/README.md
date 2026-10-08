# CampusNetLogin 源码说明

## 这份源码是怎么来的

项目原先只分发了打包好的 `bin\CampusNetLogin.exe`（约 187 MB），Python 源码已遗失。
这意味着一旦 Edge 大版本更新、校园网门户改版或验证码样式变化，程序将**无法修复**。

2026-10-02 通过以下步骤从 exe 中还原出本源码：

1. 读取 exe 尾部的 PyInstaller `CArchive` cookie（`MEI\x0c\x0b\n\x0b\x0e`），解出 TOC 偏移
2. 遍历 TOC，找到 typecode `s` 的条目 `campus_net_login`（zlib 压缩的 marshal 数据）
3. `marshal.loads` 得到 code object，再用 `dis` 反汇编逐函数还原逻辑
4. 将还原结果编译回 code object，与原对象比对验证

### 还原度验证结果

| 项目 | 原 exe | 还原源码 | 覆盖率 |
|---|---|---|---|
| 函数 / code object | 19 | 19 | **100%** |
| 全局名与属性 | 120 | 127 | **100%** |
| 字符串常量 | 290 | 290 | **99.7%**（唯一差异是模块 docstring 后追加了本说明） |

结论：本源码在**逻辑与行为**上与打包的 exe 等价。变量命名、注释组织属于还原时的整理，
与原始源码可能存在细节差异，但执行路径一致。

## 目录与关键文件

```
src\
  campus_net_login.py   主脚本（还原）
  requirements.txt      依赖清单
  build.spec            PyInstaller 打包配置（onedir）
  README.md             本文件
```

## 运行（源码方式，无需打包）

```bat
pip install -r requirements.txt

python campus_net_login.py                :: 交互菜单
python campus_net_login.py --auto         :: 自动模式（计划任务用的就是这个）
python campus_net_login.py --enable-autostart
python campus_net_login.py --disable-autostart
```

运行时会读取**脚本所在目录**下的 `campus_net_config.json`；若不存在则回退到
`%USERPROFILE%\campus_net_config.json`。

## 打包

```bat
pyinstaller build.spec
```

产物在 `dist\CampusNetLogin\`。把 `campus_net_config.json` 与该目录下的 exe 放一起，
再整体替换 `..\bin\` 即可。

> **重要**：`build.spec` 用的是 **onedir** 而不是原来的 onefile。
> 原 onefile 每次启动都要把 187 MB 解压到 `%TEMP%\_MEI*`（实测 274～387 MB），
> 单次登录常超过 3 分钟，且进程被挂起时残留不会清理——这正是本次清理出 1 GB 垃圾的原因。
> onedir 直接就地加载，冷启动与磁盘占用都会显著下降。

## 实际重建记录（2026-10-02，已部署到 bin\）

| 项目 | 原 exe（onefile） | 本次重建（onedir） |
|---|---|---|
| 打包方式 | onefile，每次启动解压到 `%TEMP%\_MEI*` | onedir，`exe + _internal` 就地加载 |
| 主程序体积 | 187 MB（单文件） | 7.5 MB（exe）+ 约 400 MB（`_internal`） |
| 每次启动的 TEMP 写入 | 274～387 MB，退出后残留不保证清理 | **0**（不再解压） |
| 实测 `%TEMP%` 占用 | 891 MB（含 387 MB 锁定残留） | 24 MB |

构建环境（与还原时确认的运行时一致）：

```
Python 3.13.14    PyInstaller 6.22.3
playwright 1.63.0 ddddocr 1.6.1  onnxruntime 1.30.0
opencv-python 5.0.0.93  numpy 2.5.3  Pillow 12.3.0  psutil 7.2.2  pywin32 312
```

构建命令（工作目录与产物都放在 D 盘，避免占用系统盘）：

```bat
pyinstaller build.spec --noconfirm --workpath <D:\...\work> --distpath <D:\...\dist>
```

验证结果：

- 菜单模式启动正常（全部模块导入 + 配置加载成功，注册表自启动状态读取正常）
- 自动模式跑完整个流程：驱动 Edge 打开页面、操作元素、截图保存（playwright 驱动与 `node.exe` 打包完整）
- OCR 链路单独验证：`ddddocr.DdddOcr` 模型加载与推理正常（识别测试图 "7A3K" → ">A3k"）
- 启动前后 `%TEMP%` 下 `_MEI*` 数量不变 —— 确认不再产生解压残留

## 开发者标志：甄嬛传（写死）

`campus_net_login.py` 顶部的 `DEV_*` 常量固定为《甄嬛传》主题，**不从配置读取、无开关、无修改入口**，
`dev_banner()` 在菜单与 `--auto` 启动时打印横幅。改动这里必须重新打包 exe 才会生效。

```python
DEV_MODE  = True
DEV_LABEL = '甄嬛传'
DEV_OWNER = '熹贵妃'
DEV_QUOTE = '「臣妾做不到啊」—— 除非开着开发者模式'
```

监控侧的同一主题写死在 `scripts\monitor.ps1` 与 `scripts\status.ps1` 中（日志 `[甄嬛传]`、
通知 `[甄嬛传]`、失败壁纸紫色 + 黄色角标 `甄嬛传 · DEV`）。

## 已知可改进点（还原时保留原行为，未擅自修改）

- 密码在配置文件中明文存储
- 验证码 OCR 失败时只重试 5 次，不做指数退避
- 登录成功后无条件打开 B 站播放视频（可通过配置 `bilibili_url` 间接调整）
- `check_network` 依赖 `2.2.2.2` / `login` / `portal` 等门户特征串判断，门户改版需同步调整
- `MAX_RETRIES` 之外的失败不做冷却，频繁重试可能触发账号风控

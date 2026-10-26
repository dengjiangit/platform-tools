# apkfind

一条命令，把安卓手机上已安装的 App 的原版 APK 拉到电脑上。

不用去第三方 APK 站找、不用猜版本对不对——直接问系统要手机上正在跑的那一份。

```
$ ./apkfind.sh -p wechat

PACKAGE                                        APK PATH
-------                                        --------
com.tencent.mm                                 /data/app/~~KrCp...==/base.apk

共 1 个

→ com.tencent.mm  248.3 MB
   [████████████░░░░░░░░░░░░]  52%  129.1 MB / 248.3 MB
  ✓ 完成  248.3 MB  耗时 21s
     ./apks/com.tencent.mm.apk

──────────────
✓ 全部完成：1 个包，共 248.3 MB，用时 21s
输出目录: /Users/you/apkfind/apks
```

## 特性

- **按包名搜索**：模糊匹配或 `-e` 精确匹配，支持 `-3` 只看第三方、`-s` 只看系统
- **不会误下**：命中多个时列出序号让你挑，`q` 取消，绝不一股脑全下
- **分包自动处理**：App Bundle 应用（`base.apk` + `split_config.*.apk`）会全部拉取，并按目录归拢
- **实时进度条**：百分比 + 已传/总量，不会黑屏干等
- **多设备可选**：同时连多台手机时列出让你选，也支持 `-S` 指定
- **纯 bash**：macOS 自带 bash 3.2 直接跑，无需 Python / Node

## 前置条件

下面几条缺一不可，任何一种不满足都会卡在「找不到设备」：

| 条件 | 怎么满足 |
|---|---|
| **同一网络** | Mac 和手机连**同一个 WiFi**（或 Mac 连手机热点）。公司/校园网常开 AP 隔离，设备之间互相不可见，会连不上 |
| **开发者选项** | 设置 → 关于手机 → 连续点击「版本号」7 次 |
| **调试开关** | Android 11+：开发者选项 → **无线调试** 打开<br>Android 10 及以下：开发者选项 → **USB 调试** 打开 |
| **platform-tools** | 见下方「安装」，提供 `adb` |
| **已连接** | `adb devices` 里设备状态必须是 `device`（不能是 `unauthorized` / `offline`） |

先确认在同一网段——电脑 IP 和手机上显示的调试 IP 前三段应一致：

```bash
ipconfig getifaddr en0     # 例如 192.168.2.100
```

## 安装

```bash
git clone https://github.com/<your-name>/apkfind.git
cd apkfind
chmod +x apkfind.sh
```

脚本默认使用**同目录下的 `adb`**。两种放法：

```bash
# 方式 A：把官方 platform-tools 解压到本仓库目录
apkfind/
├── adb           ← 从 https://developer.android.com/tools/releases/platform-tools 下载后解压进来
├── apkfind.sh
├── README.md
└── ...

# 方式 B：用系统里已装的 adb，通过环境变量指定
export ADB=$(which adb)
```

> 💡 本仓库的 `.gitignore` 默认排除了 platform-tools 的二进制（`adb`、`fastboot`、`sqlite3` 等，共约 35 MB）——重新分发 Google 的二进制存在许可问题，也会让仓库臃肿。若确实想连二进制一起分发，删掉 `.gitignore` 里对应几行即可。

## 连接手机

`apkfind` 依赖 `adb` 连接，先把这一步打通。三种方式任选。

### 方式 1：无线调试（Android 11+，最常用）

1. 手机：设置 → 开发者选项 → **无线调试** → 打开
2. 点「**使用配对码配对设备**」，屏幕显示 `IP:端口` 和 6 位配对码
3. 电脑上配对：

```bash
./adb pair 192.168.2.6:39489        # 换成手机上显示的【配对】地址
# Enter pairing code: 123456        ← 输入手机上那 6 位
# Successfully paired to 192.168.2.6:39489
```

4. **返回无线调试主页面**，看「IP 地址和端口」——这是**另一个端口**
5. 连接：

```bash
./adb connect 192.168.2.6:37125     # 换成主页面显示的【连接】地址
# connected to 192.168.2.6:37125
```

> ⚠️ **两个端口不一样，不能混用**：配对端口只能给 `adb pair`，连接端口只能给 `adb connect`。
> ⚠️ 每次关掉再打开无线调试，端口都会重新随机，要重新看页面。配对关系一般会被记住，之后通常只需 `adb connect`。

### 方式 2：USB 线（最稳，建议先用它跑通流程）

1. 数据线连电脑（必须是**能传数据**的线，不是只能充电的）
2. 手机弹出「允许 USB 调试吗？」→ 点**允许**（可勾「一律允许」）
3. 用下方「验证连接」确认状态是 `device`

### 方式 3：USB 转无线（Android 10 及以下）

老系统没有「无线调试」开关，借 USB 引导一次：

```bash
./adb tcpip 5555                    # 手机此时仍插着 USB
./adb connect 192.168.2.6:5555
# 成功后可以拔掉数据线
```

### 验证连接

```bash
./adb devices -l
```

| 状态 | 含义 | 处理 |
|---|---|---|
| `device` | 正常 | 可以用了 |
| `unauthorized` | 未授权 | 看手机屏幕，点「允许 USB 调试」 |
| `offline` | 连接失效 | `./adb disconnect` 后重新 `connect`，或 `./adb kill-server` |
| 列表为空 | 没连上 | 对照上面的前置条件逐条排查 |

> 手机锁屏太久、切飞行模式、重启、路由器重启后，无线连接通常都会断，重新 `adb connect` 即可。

## 用法

```
./apkfind.sh [选项] [关键字...]
```

| 选项 | 说明 |
|---|---|
| `-p, --pull` | 拉取 APK 到输出目录 |
| `-e, --exact` | 精确匹配包名（不模糊） |
| `-i, --info` | 显示版本号、安装时间、分片数与每个分片路径 |
| `-3` | 只搜第三方应用 |
| `-s` | 只搜系统应用 |
| `-a, --all` | 列出全部（不给关键字时用） |
| `-y, --yes` | 多结果时跳过询问，直接全拉 |
| `-S, --serial <序列号>` | 指定设备 |
| `-o, --out <目录>` | 输出目录，默认 `./apks` |
| `-h, --help` | 帮助 |

多个关键字之间是**与**关系（都要包含）。

## 示例

```bash
# 搜一下有哪些相关的
./apkfind.sh wechat

# 看详情：版本、安装时间、是不是分包
./apkfind.sh -i -3 tencent

# 知道确切包名，直接下这一个
./apkfind.sh -p -e com.tencent.mm -o ~/Downloads

# 只记得关键字，让脚本列出来自己挑
./apkfind.sh -p vivo
#   要拉取哪一个？序号多选请用逗号（如 1,3）；a=全部；q=取消
#     [1] com.vivo.vhome
#     [2] com.vivo.ai.copilot
#     [3] com.vivo.singularity
#     ...（示例输出，实际以设备为准）
#   选择> 2

# 列出手机上所有第三方应用的名称和路径
./apkfind.sh -3 -a
```

## 分包（Split APK / App Bundle）

Google Play 用 AAB 分发的应用，装到手机上是**一个 base + 若干分片**（按 CPU 架构、语言、屏幕密度拆）。

`pm list packages -f` 只返回 `base.apk`，所以脚本对每个命中包单独调 `pm path <包名>` 拿全量清单。

**怎么判断是不是分包：**

```bash
./adb shell dumpsys package <包名> | grep -E "splits=|codePath="
# splits=[base]                          → 单包，随便拷
# splits=[base, config.arm64_v8a, ...]    → 分包，少一个都装不回去
```

**拉取结果差异：**

```
单包：  apks/com.example.apk
分包：  apks/com.example/
          ├── base.apk
          ├── split_config.arm64_v8a.apk
          └── split_config.zh.apk
```

分包应用拉完后，脚本会打印回装命令：

```bash
adb install-multiple -r base.apk split_config.arm64_v8a.apk split_config.zh.apk
```

> ⚠️ 分包应用**不能**用 `adb install base.apk` 单独安装，会缺资源或 so 库，装上就闪退。

## 工作原理

1. `adb shell pm list packages -f` → 拿到「包名 = APK 路径」全表
2. 按关键字过滤（`grep -F` 模糊 / `awk` 精确比包名）
3. 对命中包执行 `pm path <包名>` → 拿全部分片路径
4. `adb shell stat -c %s` 拿远端大小，`adb pull` 放后台跑，轮询本地文件大小画进度条
5. 汇总成功数、失败数、总大小、耗时

全程只读操作，不修改手机。

## 常见问题

**Q: `adb connect` 报 `failed to connect`？**

99% 是端口用错了——无线调试有**两个端口**：配对端口只给 `adb pair`，连接端口只给 `adb connect`，且每次开关无线调试都会重排。

一步判断手里的地址是哪种：

```bash
./adb pair 192.168.2.6:39489
# 提示 Enter pairing code → 这是配对端口，配对完再去主页面找连接端口
# 报错 Couldn't find port / unable to connect → 它才是连接端口，但手机端没在监听（重开无线调试）
```

其他原因：

- 不在同一网段：`ipconfig getifaddr en0` 和手机 IP 前三段不一致
- 路由器开了 AP 隔离，或连的是访客 WiFi
- 手机开着 VPN / 代理软件
- 端口被别的 adb 实例占用：`./adb kill-server` 后重试

**Q: `adb devices` 是空的？**

对照「前置条件」五项逐条排查，另外：

- USB 方式：换一根**能传数据**的线，手机上别忘点「允许 USB 调试」
- `./adb kill-server && ./adb start-server` 重启 adb 服务
- 手机若装了第三方手机助手（豌豆荚等），可能抢占用 5037 端口，可临时退出

**Q: 拉取失败？**

- 系统预装应用放在 `/system`、`/vendor`，未 root 时通常读不出来
- 部分厂商（小米、OPPO）对 `/data/app` 加了额外保护
- 脚本会打印 adb 的原始报错，据此判断是权限还是路径问题

**Q: 只想拉一个包，结果列出一堆？**

加 `-e` 精确匹配包名：

```bash
./apkfind.sh -p -e com.tencent.mm
```

**Q: 输出重定向到文件时进度条刷屏？**

已处理：检测到 stdout 不是终端时只输出结果行，不画进度条。

## 兼容性说明

脚本刻意兼容 **macOS 自带的 bash 3.2**（不依赖 `mapfile`、不依赖 bash 4 的数组特性）。如果你在 Linux 上跑 bash 4/5，同样可用。

## License

MIT

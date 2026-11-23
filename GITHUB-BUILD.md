# 用 GitHub Actions 云端编译 CarWithin 的未签名 IPA

这个目录就是可以直接推送的仓库根目录：源码在根目录下，编译流程在 `.github/workflows/build-unsigned-ipa.yml`。
不需要 Mac，GitHub 的 macOS 运行器会完成 `xcodebuild`。

## 1. 建仓库（在网页上做，1 分钟）

1. 打开 https://github.com/new
2. Repository name 填 `carwithin-ipa`（随意），**Private** 建议选中
3. **不要**勾选 "Add a README file"、"Add .gitignore"、"Choose a license"（保持空仓库）
4. 点 Create repository，复制页面上的仓库地址，形如
   `https://github.com/<你的用户名>/carwithin-ipa.git`

## 2. 把本目录推上去

在本机 PowerShell 里执行（Git 已安装，但不在 PATH，所以用全路径调用）：

```powershell
$git = "C:\Program Files\Git\cmd\git.exe"
cd "C:\Users\zenos\Doubao\chats\2026-11-23\new-chat\CarWithin\CarWithin-ipa-repo"
& $git remote add origin https://github.com/<你的用户名>/carwithin-ipa.git
& $git push -u origin main
```

推送时会弹出浏览器要求登录 GitHub（Git Credential Manager 授权），登录并同意即可。

## 3. 触发编译

1. 打开仓库页面 → **Actions** 标签
2. 左侧选择 **Build unsigned IPA** → 右侧 **Run workflow** → 分支 `main` → Run
3. 等 5～10 分钟，运行变绿后，在本次运行页面底部 **Artifacts** 下载
   `CarWithin-1.0.3-unsigned`
4. 解压后得到 `CarWithin-1.0.3-unsigned.ipa`

## 4. 装到手机上

这个包是**未签名**的，iOS 不会直接接受，需要用侧载工具以你自己的证书签名后再安装：

- Windows/Mac：**Sideloadly**（需要 Apple ID，免费签名 7 天有效）
- **AltStore / SideStore**：同一思路，自动续签
- 越狱设备：**TrollStore** 可以直接装未签名 IPA

注意事项：

- 工程里的 `App/TDSCarKit.entitlements` 只声明了 `com.apple.developer.networking.wifi-info`。侧载签名通常拿不到这个 entitlement，应用能被装上、也能跑，但涉及 WiFi 名称读取的功能可能失效。
- 首次运行如提示"不受信任的开发者"，去 iOS 设置 → 通用 → VPN 与设备管理 里信任证书；iOS 16 以上可能还要在 设置 → 隐私与安全性 → 开发者模式 中打开开发者模式。
- 未签名包没有任何 Apple 签名材料，安装后每次重签都算新的安装。

## 编译失败怎么办

把 Actions 运行页面的红色步骤日志发我，我按报错改 workflow 或源码。常见几类：

- `xcodebuild: error: ... is not a valid destination`：macos 运行器版本与 SDK 不匹配，改 `runs-on`
- Swift 编译错误：源码本身的问题，需要改代码
- `No signing certificate`：说明哪里漏了 `CODE_SIGNING_ALLOWED=NO`，检查 workflow 是否被改动

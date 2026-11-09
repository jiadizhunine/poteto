<div align="center">

[English](./README.en.md) | **简体中文**

</div>

<h1 align="center">🥔 poteto</h1>

<p align="center"><img src="assets/icon.png" width="144" alt="poteto"></p>

<p align="center">macOS 菜单栏里的 Codex 订阅额度与账号管理工具</p>

![poteto 菜单栏界面，账号信息已遮挡](assets/screenshot-redacted.png)

poteto 显示官方 Codex 订阅的额度与重置时间，支持保存多个官方账号并手动切换。需要 macOS 14 或更新版本；添加账号和启动额度计时需要将官方 ChatGPT 桌面应用安装在 `/Applications/ChatGPT.app`。

## 安装

在 [Releases](https://github.com/jiadizhunine/poteto/releases) 下载 v1.0.0 的 `poteto-v1.0.0-macos-universal.dmg` 或 `poteto-v1.0.0-macos-universal.zip`。两种安装包都包含 Apple Silicon 和 Intel 版本。打开 DMG 或解压 ZIP，将 `poteto.app` 拖到 `/Applications` 或 `~/Applications`，然后打开。下载版无需编译器。

应用使用免费的自签名证书，未经 Apple 公证。自签名证书不是 Apple Developer ID 签名。首次打开时，如果 macOS 阻止运行，先尝试打开应用，再前往 **系统设置 → 隐私与安全性**，选择 **仍要打开**。详情见 [Apple 关于安全打开 Mac 应用的说明](https://support.apple.com/en-us/102445)。

登录时启动支持上述两个安装位置。移动应用后，在设置中重新开启即可更新启动路径；已经加载的启动项会在下次登录时使用新路径，设置开关不会退出当前应用。

## 使用

1. 打开 poteto，点击菜单栏中的 🥔。
2. 选择 **添加账号**，在官方登录页面登录。添加账号不会切换当前主账号。
3. 查看套餐、额度、重置时间和接口返回的余额或重置券信息。poteto 每 5 分钟刷新一次，读取失败会单独标记。
4. 切换账号前，先正常退出 ChatGPT 和 Codex，再选择目标账号。应用会检查原生进程是否仍在运行；运行时不会执行切换。

当一次成功查询确认所有普通额度窗口均为满额，且最长窗口具有完整周期的浮动重置时间时，poteto 会使用该账号的原生默认模型，在独立临时会话中发送一次简短测试消息，启动额度计时。此操作会消耗少量订阅额度。结果不确定时本周期不会自动重试；后续周期需要可靠的重置边界才能再次触发。

切换时，poteto 先将普通本地项目及其线程归属合并到目标账号已有的原生项目分区，再替换 `~/.codex/auth.json`。目标已有项目会保留，源账号的项目会追加；不改会话正文、模型或档位配置，也不复制云端账号权限。

如果目标账号尚未在原生应用中初始化、项目有冲突，或来源包含不支持的项目结构，poteto 会在更换凭据前停止。新账号需先在原生应用中登录一次，再正常退出；不会通过猜测内部账号标识强行继承。切换期间请保持原生应用关闭。

项目继承已用合成账号和安装版原生分区函数验证往返恢复；尚未进行真实账号间的桌面切换回归。

账号凭据保存在本机 macOS 钥匙串中；邮箱、套餐和额度等显示状态保存在本机应用数据目录，文件仅当前用户可读写。登录时启动可在 poteto 的设置中管理。

## 从源码构建

需要 macOS 的 Swift 编译器。首次运行会在本机创建固定的自签名身份，不需要 Apple Developer 会员资格。之后的构建复用该身份。

```sh
git clone https://github.com/jiadizhunine/poteto.git
cd poteto
bash setup-signing.sh
bash build.sh
bash test.sh
bash install.sh
```

`install.sh` 安装到 `~/Applications/poteto.app` 并启用登录时启动。

## 许可证

[MIT](./LICENSE)

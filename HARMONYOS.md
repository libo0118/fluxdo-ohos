# HarmonyOS 移植状态

本 fork 基于 `1molchuan/fluxdo` 的 `61bf1da8290dc8cb335ece30c7cb4787c0c89af0`，保留原 Flutter 界面和业务代码，尝试生成原生 HAP。目前是实验性移植，不能视为已完成全部功能适配的发行版。

## 构建与下载

- 在 Actions 中运行 **HarmonyOS HAP (experimental)**；推送 `main` 也会构建。
- 编译及测试成功后，下载 `fluxdo-ohos-unsigned-experimental` artifact。
- 失败时查看工作流摘要或 `fluxdo-ohos-build-diagnostics`，其中保存构建日志、依赖锁文件和生成工程。
- 产物未签名，安装到手机前需要合适的开发签名与设备授权。

当前工具链为 Flutter OHOS `3.44.9+ohos-0.0.1-canary1` 和 SDK `26.0.0.821`。生成模板的最低系统要求为 HarmonyOS **5.1 / API 18**，设备类型为手机；尚未确认 HarmonyOS 5.0 兼容性。

## 已接入的构建适配

- 鸿蒙移动端识别、通过 CookieManager 复用现有 Cookie 写入逻辑。
- WebView、偏好、文件路径、设备信息、链接等插件的 OHOS 实现。
- OHOS 专用的依赖覆盖和兼容脚本；脚本只在 CI 检出目录运行，并检查源码是否匹配。
- 代理配置解析和 Cookie 域语义的现有回归测试。

## 尚未完成的功能验证

- 原项目的 Rust DoH 代理没有 OHOS 加载分支，当前工作流也没有为它构建 OHOS 原生库；不能宣称保留了 cfluxdo 的 DoH 加速能力。
- 尚未接入鸿蒙系统密钥库。已排除把解密私钥存入普通偏好的候选插件，不提供明文凭据存储替代方案。
- 登录与 Cloudflare 验证、动图/AVIF、音视频、录音、系统通知、分享、扫码及文件操作仍需对应原生适配和真机验证。

构建成功只证明编译与打包通过；请以实际 Actions 结果和后续真机验证记录判断移植进度。

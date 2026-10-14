# HarmonyOS 移植状态

本 fork 基于 `1molchuan/fluxdo` 的 `61bf1da8290dc8cb335ece30c7cb4787c0c89af0`，复用原 Flutter 界面和业务代码，生成原生 HAP。包名保留 **`com.github.molchuan.cfluxdo`**，名称 **`cfluxdo`**，桌面图标取自原工程默认启用的经典 PNG。原作者信息和 GPL-3.0 许可保留。

## 构建与下载

在 [HarmonyOS HAP (experimental)](https://github.com/libo0118/fluxdo-ohos/actions/workflows/harmonyos.yml) 手动运行；推送 `main` 也会构建。成功后下载 `fluxdo-ohos-unsigned-experimental`，内含 HAP、SHA256、源提交、依赖锁文件和本文。失败时下载 `fluxdo-ohos-build-diagnostics` 查看实际错误。

产物**未签名**，安装前需要与包名、设备匹配的开发签名和设备授权。工作流不提供 APK 安装替代流程。模板最低要求为 **HarmonyOS 5.1 / API 18**；目标 SDK 26，具体工具链提交以工作流和 `BUILD-INFO.txt` 为准。HarmonyOS 5.0 兼容性尚未验证。

## 接入范围与验证边界

| 功能 | 实现与检查 | 设备边界 |
| --- | --- | --- |
| 账号、私钥与安全存储 | Asset Store 保存设备密钥，AES-GCM 加密分块偏好；已执行生产 ETS 的加解密/回滚检查 | 未做签名 HAP、重启及卸载迁移测试 |
| DoH / ECH / HTTP3 | 构建真实 OHOS libdoh_proxy.so 和 librhttp.so，校验 AArch64、依赖和 ABI；每台设备 CA | 原生库已在云端成功构建；网络及 Cloudflare 仍待真机 |
| WebView 代理与 Cookie | API20+ 用失败事件 URL、Untrusted、首证书 DER 与当前代理缓存精确匹配。API23+ 读取真实 Cookie 属性；XHR/fetch 仅发空通知 | API18/19 保留直接网页连接，无法使用需要该证书例外的 WebView MITM；被网络阻断时可能失败。API18–22 保留原显式 CF/登录收口，自动低置信通知保守拒绝 |
| 会话注销 | 自动同步只处理可信论坛 URL；注销代过滤登录 Cookie；队列内保存和规范化重新校验 | 等待初始化、队列及注销清理回归须以本次 Actions 结果为准 |
| 动图 / AVIF | 构建真实 libnative_animated_image_codec.so、libflutter_avif.so；GIF/APNG/WebP 帧和 AVIF 原生代码 | 已在云端成功构建、运行真实 codec 回归；上游 WebP RGB 有已观测的 1 LSB 偏差；坏 AVIF 输入和设备显示待测 |
| 音视频 / 录音 | 固定 OHOS video/audio/record 插件，接入视频头、seek、音频焦点、中断、AAC 文件录音、亮度/音量/唤醒锁 | 耳机、权限、播放及手势待设备。应用音量使用可用 API，旧 API 使用播放器音量 |
| 转码 | AVTranscoder + MetadataExtractor，取消、进度、临时输出和 FD 生命周期；实际 ETS 状态检查 | 保留现有调用范围；SDK不支持的帧率/采样率配置不会虚报。带视频的音轨提取请求明确拒绝 |
| 文件 / 分享 / 剪贴板 | 系统另存为、图片授权保存、URI 持久授权、ShareKit，PNG/JPEG/GIF/WebP/AVIF/SVG 粘贴 | 保存需用户选择。持久授权失败保留应用私有副本供历史重开；删除历史只删记录。分享状态表示已发起面板，不能表示已送达 |
| 通知 / 后台 / 点击跳转 | 查询并申请真实通知权限、发布/取消、冷/热 WantAgent；短时后台额度及到期暂停、前台恢复游标 | 后台额度受系统约束、最多30秒。进程被杀后的持续推送需要服务器推送 |
| 深链接 / 登录回跳 | app_links 从 launchWant 和 NewWantListener 接收；注册 fluxdo、discourse://auth_redirect、http(s) 主站与 www | OS host 匹配为字面量，未注册任意子域通配符；子域在应用内的原逻辑保留。未宣称拥有 linux.do 域名验证权限 |
| 更新 | 鸿蒙从本 fork 查询 Release，缓存/ETag 与 Android 隔离；无 Release 时提供 Actions 下载入口 | 目前没有签名 Release 或 HAP OTA 安装。未来版本通过浏览器取包；Android 原 APK 更新保持 |
| Passkey / 扫码 | 原浏览器授权登录和扫码流程保留；浏览器授权后经 discourse 深链收口 | ArkWeb 内 WebAuthn/Passkey 不宣称已验证。可使用现有系统浏览器授权入口；设备浏览器能力和真实登录待测 |

仓库脚本仅在 OHOS 构建目录修改固定版本的依赖，支持重复执行并拒绝源码漂移。生产 ETS/JS 检查使用系统 API 替身，不等同于 ArkTS 编译或真机测试。Flutter/Dart 回归、真实 Rust 测试、四个原生库构建与 HAP 编译均由 Actions 执行；**请看当前提交的实际运行结果**。构建成功不能据此宣称全部设备功能已验证。

## 平台证据

- [官方 URI 配置](https://github.com/openharmony/docs/blob/master/en/application-dev/application-models/app-uri-config.md)、[实际 URI 匹配实现](https://github.com/openharmony/bundlemanager_bundle_framework/blob/master/interfaces/inner_api/appexecfwk_base/src/skill.cpp)。
- [ArkWeb SSL 事件 SDK](https://github.com/openharmony/interface_sdk-js/blob/8a86234f0d542e5062e24e948652f5a484d90904/api/@internal/component/ets/web.d.ts)、[Cookie SDK](https://github.com/openharmony/interface_sdk-js/blob/8a86234f0d542e5062e24e948652f5a484d90904/api/@ohos.web.webview.d.ts)。
- [华为通行密钥原生接入](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/onlineauthentication-passkey-arkts)提供 FIDO2 客户端 API，需要对应服务端集成；这不能证明现有 ArkWeb 页面已支持 WebAuthn。

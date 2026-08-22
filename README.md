# CustomerService iOS 客服端

原生 SwiftUI 客服客户端，面向 `kefu V1.0.8` 服务端接口：

- 前台通过 WebSocket 实时接收消息并自动重连；
- 后台和锁屏通过 APNs 显示声音、角标和横幅通知；
- 点击通知可回到对应客户会话；
- 支持客服登录、会话列表、文字回复和图片回复；
- 最低支持 iOS 16，包名为 `com.yuyanfriends.app`。

## GitHub Actions 构建

仓库使用 XcodeGen 在 macOS Runner 上生成 Xcode 工程，再以 Ad Hoc 描述文件签名并导出 IPA。签名材料只保存在仓库的 Actions Secrets 中，不进入 Git 历史：

- `IOS_CERTIFICATE_P12_BASE64`
- `IOS_PROVISIONING_PROFILE_BASE64`
- `IOS_P12_PASSWORD`

成功构建后，进入仓库的 **Actions → 构建真机 IPA → Artifacts** 下载 `CustomerService-iOS-1.0.8-ad-hoc`。

## 实时通知说明

IPA 使用原生 APNs，不在 `WKWebView` 中模拟网页 Web Push。前台实时消息依赖服务端 `/ws/staff`；锁屏/后台推送还需服务端启用 APNs，并将 `APPLE_BUNDLE_ID` 设为 `com.yuyanfriends.app`。签名证书只用于构建 App，服务端向苹果推送仍需单独的 APNs `.p8` 密钥与 Key ID。

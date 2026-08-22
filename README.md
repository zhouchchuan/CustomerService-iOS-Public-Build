# CustomerService iOS 客服端

原生 SwiftUI 客服客户端 V1.0.9，继续兼容 `kefu V1.0.8` 服务端接口：

- 前台通过 WebSocket 实时接收消息并自动重连；
- 后台和锁屏通过 APNs 显示声音、角标和横幅通知；
- 点击通知可回到对应客户会话；
- 支持客服登录、卡片式会话列表、左滑结束服务、文字和图片回复；
- 显示消息时间与访客已读回执；
- 使用地区、运营商和 IP 生成可辨识的访客名称；
- WebSocket 到达时立即更新界面，并带有轮询补偿机制；
- 图片和短视频可在 App 内点击预览，支持双指缩放、放大后拖动、双击放大/复位，并可点右上角关闭；
- 最低支持 iOS 16，包名为 `com.yuyanfriends.app`。

## GitHub Actions 构建

仓库使用 XcodeGen 在 macOS Runner 上生成 Xcode 工程，并同时输出完全未签名包和爱思兼容待重签包。构建过程不读取证书或描述文件。成功后进入 **Actions → 构建爱思兼容待重签 IPA → Artifacts**，优先下载并使用 `CustomerService-iOS-1.0.9-resignable.ipa`。

## 实时通知说明

IPA 使用原生 APNs，不在 `WKWebView` 中模拟网页 Web Push。前台实时消息依赖服务端 `/ws/staff`；锁屏/后台推送还需服务端启用 APNs，并将 `APPLE_BUNDLE_ID` 设为 `com.yuyanfriends.app`。签名证书只用于构建 App，服务端向苹果推送仍需单独的 APNs `.p8` 密钥与 Key ID。


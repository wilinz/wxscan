# wxscan_example

[English](README.md) · **简体中文**

[`wxscan_live`](../) 插件和 [`wxscan`](../../wxscan) 的演示应用。

这两个包提供的三条路径它都覆盖了：

- **实时扫码**：相机预览，检测到的码标出来，还有闪光灯、变焦和分辨率切换。
- **一帧多个码**：画面冻住，码变成可点的，跟手机相机应用的做法一样。
- **相册解码**：同一个扫描器扫一张静态图，走 `wxscan` 而不是相机那条路。

启动时它会拿一张内置的样图跑两个自检，一个走 FFI 绑定，一个走原生相机路径，结果打进
日志。想在一台设备上确认库、模型和平台绑定有没有接好，这是最快的办法。

## 跑起来

```sh
flutter run              # -d macos、连上的设备，等等
```

第一次要编 Rust、下载 TFLite 库，得等几分钟；之后是增量的。

TFLite 模型在 `assets/models/`，由
[wxscan-rs](https://github.com/wilinz/wxscan-rs) 的 `tools/model_conversion` 从公开的
Caffe 权重转过来。

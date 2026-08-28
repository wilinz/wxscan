# wxscan_example

[English](README.md) · **简体中文**

[`wxscan_live`](../) 插件与 [`wxscan`](../../wxscan) 的演示应用。

它覆盖了这两个包提供的三条路径：

- **实时扫描** —— 相机预览，检测到的码会被标出来，还有闪光灯、变焦控制和分辨率
  切换。
- **一帧里多个码** —— 画面冻结，那些码变成可点击的，就像手机相机应用的做法。
- **从相册解码** —— 同一个扫描器作用在一张静态图片上，走的是 `wxscan` 而不是相机
  那条路径。

启动时它会对一张内置的样例图片跑两个自检，一个走 FFI 绑定，一个走原生相机路径，并把
结果打进日志。要在一台设备上判断库、模型和平台绑定是不是都接好了，这是最快的办法。

## 运行

```sh
flutter run              # -d macos、某台已连接的设备，……
```

第一次构建要编译 Rust 源码并下载 TFLite 库，所以要花几分钟；之后的构建是增量的。

TFLite 模型在 `assets/models/`，由
[wxscan-rs](https://github.com/wilinz/wxscan-rs) 里的 `tools/model_conversion`
从公开的 Caffe 权重转换而来。

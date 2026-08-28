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

TFLite 模型放在 `assets/models/`。这份 checkout 里有，发到 pub.dev 的包里没有：一个
example 的 1.1 MB 权重，是每次 `pub get` `wxscan_live` 都要付的 1.1 MB。没有它也照样
编、照样跑，只是退回到纯图像处理这条路，首页会把这件事说出来，并指向
[`assets/models/README.md`](assets/models/README.md)。权重去
[wilinz/wxscan-weights](https://github.com/wilinz/wxscan-weights) 取，那里也放着
`tools/convert.py`，从公开的 Caffe 模型生成它们的脚本。

## 拿什么扫

仓库里的 [`tool/qr_bench.html`](../../../tool/qr_bench.html) 在一张白底上摆两个二维码，
字符数、模块边长、纠错等级和字符集各调各的，两个都能拖能转。在显示器上打开，拿手机对着扫。

最该动的是模块边长。往后退一步，距离、角度、光照是一起变的；这个滑块只改一个模块能占到
多少个相机像素，别的什么都不动——而那正是 CNN 检测器要解决的事。两个码同时在画面里能试
到多码选择，转一个能试到角点坐标，反色那个开关对应的是 Rust 移植解得出、C++ 实现解不出
的那种图。

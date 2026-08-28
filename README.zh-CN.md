# wxscan

[English](README.md) · **简体中文**

Flutter 的二维码扫描，能扫出别的扫描器扫不动的码。用的是 `wechat_qrcode` 算法——
CNN 检测加超分辨率，不只是一个解码器——整个移植到了 Rust。不依赖 OpenCV，也没有原生
构建文件要维护。

两个包都还没发到 pub.dev，所以都从 git 引：

```yaml
dependencies:
  # 解码图片和像素缓冲，不碰相机。
  wxscan:
    git:
      url: https://github.com/wilinz/wxscan.git
      path: packages/wxscan

  # 实时相机扫描，建在它上面。
  wxscan_live:
    git:
      url: https://github.com/wilinz/wxscan.git
      path: packages/wxscan_live
```

发布之后写成：

```yaml
dependencies:
  wxscan: ^0.1.0        # 图片和像素缓冲，不碰相机
  wxscan_live: ^0.1.0   # 实时相机扫描，建在它上面
```

git 依赖跟着默认分支走。想固定下来就加 `ref`，指向某个 tag 或 commit。

**需要什么**

| | 版本 |
|---|---|
| Dart | 3.10 或更新 |
| Flutter | 3.38.1 或更新——Android 上用 3.44，[有个转屏 bug](packages/wxscan_live/README.zh-CN.md#平台) |
| Rust | `PATH` 上有 rustup 即可；编译器版本是钉死的，第一次构建时自动装 |

就这些。构建钩子会编 Rust、下 TFLite 库，版本（1.95.0）和目标平台都从
`rust-toolchain.toml` 读，rustup 第一次跑的时候把两样一起装上。不需要 Xcode 工程、
不需要 Gradle、不需要 CMake，Android NDK 也只用 Flutter 本来就装的那份。

接下来照 [wxscan](packages/wxscan/README.zh-CN.md#快速开始) 或
[wxscan_live](packages/wxscan_live/README.zh-CN.md#快速开始) 的快速开始走一遍：安装、
权重、权限、第一次扫描，一屏就够。本文剩下的部分讲这个仓库。

**[在线演示](https://wilinz.github.io/wxscan/)**：示例应用跑在浏览器里，用的是同一个
Rust 扫描器编译出来的 WebAssembly。实时扫码，或者选一张相册里的图片，都在你自己机器上
解码。没有东西离开这个页面，也只有你去点实时扫码时才会申请相机。

这两个包提供的是相机画面和每帧的结果。外面那层界面——取景框、码上画的四角、一帧多码
时让人挑——在
[`packages/wxscan_live/example`](packages/wxscan_live/example/lib/scan_page.dart)，
写出来就是给人读、给人抄的。

## 怎么用

两个包都要 CNN 权重，权重不随包分发。去
[wxscan-weights](https://github.com/wilinz/wxscan-weights) 下载 `detect.tflite` 和
`sr.tflite`，再声明一下放它们的目录。没有权重也能解码，只是小码和远处的码会经常扫
不到。

**解码一张图片。** `scanPath` 在原生侧读文件、原生侧解码，一张 1200 万像素的照片不会
在 Dart 里摊成 48 MB 的 RGBA：

下面的 `detectBytes` 和 `srBytes` 就是那两个权重文件的字节，两个快速开始里都写了怎么
从 assets 读，包括偏移量那一步。

```dart
import 'package:wxscan/wxscan.dart';

final scanner = await WxScanner.create(
  detectModel: detectBytes,
  srModel: srBytes,
);

try {
  final outcome = await scanner.scanPath('/path/to/photo.jpg');
  for (final r in outcome.results) print(r.text);
} on PictureUnreadable {
  // 不是图片，或者这个构建解不了这种格式。HEIC 要用平台自带的解码器，
  // 再走 `scanPixels`。这跟「图片里没有码」是两码事，后者返回空结果。
}
```

→ [该调哪个方法](packages/wxscan/README.zh-CN.md#该调哪个方法) ·
[HEIC 怎么办](packages/wxscan/README.zh-CN.md#heic-与平台解码器) ·
[调检测参数](packages/wxscan/README.zh-CN.md#调整检测参数) ·
[扫描器怎么管](packages/wxscan/README.zh-CN.md#与扫描器打交道)

**用相机扫。** 相机权限要在 `initialize` 之前拿到，插件不替你申请。

```dart
import 'package:wxscan_live/wxscan_live.dart';

final controller = WxScanController(resolution: WxResolution.p720);
await controller.initialize(detectModel: detectBytes, srModel: srBytes);

controller.scans.listen((outcome) {
  for (final r in outcome.results) print(r.text);
});

// 预览用 `WxScanPreview(controller: controller)`：原生上是纹理，浏览器里是平台
// 视图。旋转和适配交给外面包着它的东西。controller 是 ValueNotifier，转屏时自己
// 会重绘。

// 也要扫图片？把手上已有的 scanner 借给相机，权重就只占一份内存，不是两份：
// WxScanController(scanner: scanner)
```

→ [权限和完整的第一屏](packages/wxscan_live/README.zh-CN.md#快速开始) ·
[相机控制](packages/wxscan_live/README.zh-CN.md#相机控制) ·
[点击对焦](packages/wxscan_live/README.zh-CN.md#对焦) ·
[实践建议](packages/wxscan_live/README.zh-CN.md#实践建议)

**其余内容在哪**

| 想知道 | 看这里 |
|---|---|
| 一帧返回什么 | [结果](packages/wxscan/README.zh-CN.md#结果) · [实时结果](packages/wxscan_live/README.zh-CN.md#结果) |
| 权重干什么用，没有会怎样 | [模型](packages/wxscan/README.zh-CN.md#模型) |
| 浏览器上怎么部署 | [wxscan](packages/wxscan/README.zh-CN.md#浏览器) · [构建扫描器](packages/wxscan/README.zh-CN.md#构建扫描器) · [wxscan_live](packages/wxscan_live/README.zh-CN.md#浏览器) |
| 原生库怎么编、怎么被找到 | [构建钩子](packages/wxscan/README.zh-CN.md#构建钩子) · [原生库](packages/wxscan_live/README.zh-CN.md#原生库) |
| 一整页可以直接抄的扫描界面 | [`example/lib/scan_page.dart`](packages/wxscan_live/example/lib/scan_page.dart) |

## 为什么用它

**小码、远处的码也扫得到。** 先用一个神经网络在画面里找出可能是码的位置，再用第二个
把每一块放大，然后才解码。有没有这两步，区别就是「码得怼到镜头前」和「隔着半个房间
也能扫」。微信自己的扫描器就是这么干的。

**相机帧不进 Dart。** CameraX 和 AVFoundation 把每一帧直接交给 Rust 扫描器；预览是
一张 Flutter 纹理，用的是同一块缓冲。进到 Dart 的只有结果：一段文本、四个角点。每帧
那份大拷贝压不到 UI isolate 上。

**一帧多个码。** 画面里每个码都带着自己的四角返回，坐标已经按预览的方向修正过，直接
画上去就行。检测到了但没解出来的码也会报出来——这时候该提示用户凑近，而不是说「没找到
二维码」。

**没有原生工程要维护。** 不用 podspec，不用 Gradle，不用 CMake。一个 Dart
[构建钩子](https://dart.dev/tools/hooks) 负责编 Rust、拉 TFLite 库，所以 `dart test`
不牵扯 Flutter 也能跑这个扫描器。

## 包

| 包 | 是什么 |
|---|---|
| [`packages/wxscan`](packages/wxscan) | 扫描器本体。一套 C ABI，Dart 用 FFI 打开它来解图片和像素缓冲。纯 Dart 包，构建钩子负责编译和打包原生库，所以 `dart run`、`dart test` 都能用。 |
| [`packages/wxscan_live`](packages/wxscan_live) | 它前面那台相机。帧从 CameraX 或 AVFoundation 直接进扫描器，不过 Dart；预览是一张 Flutter 纹理。 |
| [`packages/wxscan_live/example`](packages/wxscan_live/example) | 演示应用：实时扫码、相册解码，以及一帧多码时怎么挑。 |

## 平台

| | 解码（`wxscan`） | 实时扫描（`wxscan_live`） |
|---|---|---|
| Android | arm64-v8a、armeabi-v7a、x86_64 | CameraX，API 24+ |
| iOS | 13.0+ | AVFoundation，13.0+ |
| macOS | 10.15+，arm64 | AVFoundation，10.15+ |
| Linux、Windows | x86_64，Linux 还有 arm64 | — |
| Web | worker 里的 WebAssembly；扫描器模块是[单独构建的，不随包分发](packages/wxscan/README.zh-CN.md#构建扫描器) | `getUserMedia`，预览是平台视图 |
| 纯 Dart（无 Flutter） | `dart run`、`dart test` | — |

不支持 32 位 x86 的 Android。LiteRT 没出这个 ABI 的产物，要打这个 ABI 的应用得把它
排掉。

## 权重

两个 CNN 权重文件不在任何一个包里，在
[wxscan-weights](https://github.com/wilinz/wxscan-weights)。那里还有从微信公开的
Caffe 模型重新生成它们的脚本，以及一份可复现性校验，所以权重是能验证的，不用光靠信。

没有权重不会挂，只会降级：普通的码照样解，掉的是小码和远处码的检出率。权重加载失败
也一样，通过 `modelsLoaded` 告诉你，不抛异常。

## 各部分怎么拼起来

Rust 源码在 [`wxscan-rs`](https://github.com/wilinz/wxscan-rs)，开发时放在本仓库
旁边：

```
Documents/
├── wxscan/       本仓库，Dart 和平台这一侧
└── wxscan-rs/    cvlite、wxing、wxscan、wxscan-ffi，算法本身
```

原生库只在一个地方编：`packages/wxscan` 的 `hook/build.dart` 编 `rust/` 下的 crate、
下载 TFLite C 库，把两者都声明成 code asset 交给 Flutter 打包。`wxscan_live` 从 Swift
和 Kotlin 调的是同一个库，运行时才解析入口——Android 上从 `lib/<abi>/` 取，那本来就是
`System.loadLibrary` 找的地方；Apple 平台用 `dlsym`。所以不管应用用了这两个包中的
几个，扫描器和 TFLite 各自都只有一份。细节和换 TFLite 版本的做法在
[wxscan 的 README](packages/wxscan/README.zh-CN.md#构建钩子) 里。

## 跑演示应用

```sh
cd packages/wxscan_live/example
flutter run              # -d macos、连上的设备，等等
```

第一次要编 Rust、下载原生库，得等几分钟；之后是增量的。

## 许可

Apache-2.0，和它移植的上游实现一致。

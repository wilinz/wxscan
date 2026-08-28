# wxscan

[English](README.md) · **简体中文**

给 Flutter 用的二维码扫描，能读出别的扫描器认输的那些码：把 `wechat_qrcode`
算法——CNN 检测加超分辨率，不只是一个解码器——移植到了 Rust。不依赖 OpenCV，
也没有原生构建文件要维护。

两个包都还没发到 pub.dev。下面把两种写法并列列出，等到发布那天，两个方向的切换
都只是改一行：

```yaml
dependencies:
  # 解码图片和像素缓冲，不涉及相机。
  wxscan:
    git:
      url: https://github.com/wilinz/wxscan.git
      path: packages/wxscan
  # wxscan: ^0.1.0                    # 发布后从 pub.dev 引入

  # 实时相机扫描，建立在它之上。
  wxscan_live:
    git:
      url: https://github.com/wilinz/wxscan.git
      path: packages/wxscan_live
  # wxscan_live: ^0.1.0               # 发布后从 pub.dev 引入
```

git 依赖跟随默认分支。想让某样东西不再变动，用 `ref` 固定到某个 tag 或 commit。

然后照着 [wxscan](packages/wxscan/README.zh-CN.md#快速开始) 或
[wxscan_live](packages/wxscan_live/README.zh-CN.md#快速开始) 的快速开始走一遍——
安装、权重、权限，以及第一次扫描，都在一屏之内。本文余下的部分讲的是这个仓库本身。

**[在线演示](https://wilinz.github.io/wxscan/)** —— 示例应用跑在浏览器里，用的是
同一个 Rust 扫描器编译成的 WebAssembly。实时扫描，或者从相册选一张图片，全部在你
自己的机器上解码：没有任何东西离开这个页面，而且只有你主动去用相机时才会请求它。

这两个包给你的是相机画面和每一帧的结果。围绕它们的那层界面——取景框、画在每个码上
的四角、一帧里多个码时让用户挑一个——在
[`packages/wxscan_live/example`](packages/wxscan_live/example/lib/scan_page.dart)，
那是写来给人读、给人抄的。

## 怎么用

两个包都需要 CNN 权重，而权重没有随包分发——从
[wxscan-weights](https://github.com/wilinz/wxscan-weights) 下载 `detect.tflite`
和 `sr.tflite`，并声明存放它们的目录。没有权重解码照样能用；失去的是小码和远处的码
的检出率。

**解码一张图片。** `scanPath` 在原生侧读取并解码文件，所以一张 1200 万像素的照片
不会在 Dart 里变成 48 MB 的 RGBA：

下面的 `detectBytes` 和 `srBytes` 就是那两个文件的字节；两个快速开始里都演示了怎么
从 assets 加载它们，连偏移量都写了。

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
  // 不是图片，或者是这个构建解不了的格式——HEIC 需要平台自己的解码器，配合
  // `scanPixels`。这和「一张里面没有码的图片」不是一回事，后者返回的是一个
  // 空结果。
}
```

→ [该调哪个方法](packages/wxscan/README.zh-CN.md#该调哪个方法) ·
[HEIC 的兜底路径](packages/wxscan/README.zh-CN.md#heic-与平台解码器) ·
[调整检测参数](packages/wxscan/README.zh-CN.md#调整检测参数) ·
[与扫描器打交道](packages/wxscan/README.zh-CN.md#与扫描器打交道)

**用相机扫描。** 相机权限必须在 `initialize` 之前拿到；插件不会替你去申请。

```dart
import 'package:wxscan_live/wxscan_live.dart';

final controller = WxScanController(resolution: WxResolution.p720);
await controller.initialize(detectModel: detectBytes, srModel: srBytes);

controller.scans.listen((outcome) {
  for (final r in outcome.results) print(r.text);
});

// 预览是 `WxScanPreview(controller: controller)`——原生上是一张纹理，浏览器里
// 是一个平台视图——由包着它的东西负责旋转和适配。controller 是 ValueNotifier，
// 所以转屏时它自己会重绘。

// 也要扫图片？把你已经有的那个 scanner 借给相机，CNN 权重就只在内存里存一份，
// 而不是两份：
// WxScanController(scanner: scanner)
```

→ [权限与完整的第一屏](packages/wxscan_live/README.zh-CN.md#快速开始) ·
[相机控制](packages/wxscan_live/README.zh-CN.md#相机控制) ·
[点击对焦](packages/wxscan_live/README.zh-CN.md#对焦) ·
[实践建议](packages/wxscan_live/README.zh-CN.md#实践建议)

**其余内容在哪**

| 问题 | 去处 |
|---|---|
| 一帧返回什么 | [结果](packages/wxscan/README.zh-CN.md#结果) · [实时结果](packages/wxscan_live/README.zh-CN.md#结果) |
| 权重做什么，没有它会怎样 | [模型](packages/wxscan/README.zh-CN.md#模型) |
| 在浏览器里怎么部署 | [wxscan](packages/wxscan/README.zh-CN.md#浏览器) · [构建扫描器](packages/wxscan/README.zh-CN.md#构建扫描器) · [wxscan_live](packages/wxscan_live/README.zh-CN.md#浏览器) |
| 原生库怎么构建、怎么被找到 | [构建钩子](packages/wxscan/README.zh-CN.md#构建钩子) · [原生库](packages/wxscan_live/README.zh-CN.md#原生库) |
| 一整个可读可抄的扫描页 | [`example/lib/scan_page.dart`](packages/wxscan_live/example/lib/scan_page.dart) |

## 为什么是这个

**它看得见小码和远处的码。** 一个神经网络在画面里定位候选符号，第二个把每一块裁剪
放大之后再解码。这就是「必须把码怼到镜头前」和「隔着一个房间也能读」之间的差别，
也正是微信自家扫描器的做法。

**相机帧从不进入 Dart。** CameraX 和 AVFoundation 把每一帧直接交给 Rust 扫描器，
预览则是覆在同一块缓冲上的一张 Flutter 纹理。跨到 Dart 那侧的只有结果——一段文本和
四个角点——所以 UI isolate 上不会落下任何逐帧的拷贝。

**一次多个码。** 画面里每一个符号都会带着它在预览坐标系里的四角返回，旋转和镜像
都已经修正好，可以直接画上去。被看见但没能读出来的符号也会报告，这是提示用户放大，
而不是告诉他「没找到码」。

**没有原生工程要维护。** 没有 podspec，没有 Gradle，没有 CMake。一个 Dart
[构建钩子](https://dart.dev/tools/hooks) 负责编译 Rust 并获取 TFLite 库，所以
`dart test` 能在完全不牵扯 Flutter 的情况下跑这个扫描器。

## 包

| 包 | 是什么 |
|---|---|
| [`packages/wxscan`](packages/wxscan) | 扫描器本身。一套 C ABI，Dart 通过 FFI 打开它来处理图片和像素缓冲。它是个纯 Dart 包：构建钩子负责编译并打包原生库，所以在 `dart run` 和 `dart test` 下同样可用。 |
| [`packages/wxscan_live`](packages/wxscan_live) | 它前面的那台相机。帧从 CameraX 或 AVFoundation 直接进入扫描器，不经过 Dart；预览是一张 Flutter 纹理。 |
| [`packages/wxscan_live/example`](packages/wxscan_live/example) | 演示应用：实时扫描、从相册解码，以及一帧里多个码时的挑选。 |

## 平台

| | 解码（`wxscan`） | 实时扫描（`wxscan_live`） |
|---|---|---|
| Android | arm64-v8a、armeabi-v7a、x86_64 | CameraX，API 24+ |
| iOS | 13.0+ | AVFoundation，13.0+ |
| macOS | 10.15+，arm64 | AVFoundation，10.15+ |
| Linux、Windows | x86_64，Linux 上另有 arm64 | — |
| Web | worker 里的 WebAssembly；扫描器模块是[构建出来的，没有随包分发](packages/wxscan/README.zh-CN.md#构建扫描器) | `getUserMedia`，预览是平台视图 |
| 纯 Dart，无 Flutter | `dart run` 与 `dart test` | — |

不支持 32 位 x86 的 Android：LiteRT 没有为它发布构建产物，所以以那个 ABI 为目标的
应用必须把它排除掉。

## 权重

两个 CNN 权重文件没有打包进任何一个包里。它们在
[wxscan-weights](https://github.com/wilinz/wxscan-weights)，同时还附着从微信公开的
Caffe 模型重新生成它们的脚本——以及一个可复现性校验，所以它们是可以被验证的，而不是
只能被信任。

没有它们，这条流水线是**降级**而不是失效：解码照常工作，失去的是小码和远处的码的
检出率。加载失败的文件同理，这一点通过 `modelsLoaded` 报告出来，而不是抛异常。

## 各部分如何拼在一起

Rust 源码在 [`wxscan-rs`](https://github.com/wilinz/wxscan-rs)，开发时预期它就放在
本仓库旁边：

```
Documents/
├── wxscan/       本仓库 —— Dart 与平台那一侧
└── wxscan-rs/    cvlite、wxing、wxscan、wxscan-ffi —— 算法本身
```

原生库只在一个地方构建：`packages/wxscan` 里的 `hook/build.dart` 编译 `rust/` 下的
Rust crate，下载 TFLite C 库，并把两者都声明为 code asset 交给 Flutter 打包。
`wxscan_live` 随后从 Swift 和 Kotlin 调用**同一个**库，在运行时解析它的入口——
Android 上从 `lib/<abi>/` 里取，那正是 `System.loadLibrary` 会去找的地方；Apple
平台上用 `dlsym`。所以不论一个应用用了这两个包中的几个，它携带的扫描器和 TFLite
都各只有一份。细节，包括怎么更换 TFLite 版本，在
[wxscan 的 README](packages/wxscan/README.zh-CN.md#构建钩子) 里。

## 构建演示应用

```sh
cd packages/wxscan_live/example
flutter run              # -d macos、某台已连接的设备，……
```

第一次构建要编译 Rust 源码并下载原生库，所以要花几分钟；之后的构建是增量的。

## 许可

Apache-2.0，与它移植自的上游实现一致。

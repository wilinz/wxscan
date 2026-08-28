# wxscan

[English](README.md) · **简体中文**

给 Flutter 用的二维码解码，底层是 `wechat_qrcode` 算法的 Rust 移植：基于 CNN 的
检测、超分辨率，以及解码。

这个包解码图片和原始像素缓冲。它不打开相机——实时扫描请用
[`wxscan_live`](https://github.com/wilinz/wxscan/tree/main/packages/wxscan_live)，
它在原生侧驱动相机，并从 Swift 和 Kotlin 调用本包的原生库。

它是一个纯 Dart 包，不是 Flutter 插件：原生库由
[构建钩子](https://dart.dev/tools/hooks) 编译并打包，所以它在 `dart run` 和
`dart test` 下和在 Flutter 应用里一样能用，而且没有平台构建文件要维护。

## 快速开始

还没发到 pub.dev。两种写法都列在这里，等到发布那天切换只是改一行——而且两种在
Flutter 和纯 Dart 下写法都一样：

```yaml
dependencies:
  wxscan:
    git:
      url: https://github.com/wilinz/wxscan.git
      path: packages/wxscan
  # wxscan: ^0.1.0        # 发布后从 pub.dev 引入
```

git 那种写法跟随默认分支；加一个 `ref` 可以固定到某个 tag 或 commit。

CNN 权重没有随包分发。从
[wxscan-weights](https://github.com/wilinz/wxscan-weights) 下载 `detect.tflite`
和 `sr.tflite`，放进 `assets/models/`，并在 `pubspec.yaml` 里声明这个目录：

```yaml
flutter:
  assets:
    - assets/models/
```

```dart
import 'package:flutter/services.dart' show rootBundle;
import 'package:wxscan/wxscan.dart';

Future<Uint8List> _asset(String path) async {
  final data = await rootBundle.load(path);
  // 那个偏移量和长度不是可选的：打包进来的 asset 可能只是一块更大的缓冲里的
  // 一段视图，不带参数的 `asUint8List()` 会读过界。
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

final scanner = await WxScanner.create(
  detectModel: await _asset('assets/models/detect.tflite'),
  srModel: await _asset('assets/models/sr.tflite'),
);

final outcome = await scanner.scanPath('/path/to/photo.jpg');
for (final r in outcome.results) {
  print('${r.text} (v${r.version}/${r.ecLevel}/${r.charset})');
}

scanner.dispose();
```

两个权重都是可选的。不传它们就是在没有 CNN 阶段的模式下解码，普通的码照样能读——
见[模型](#模型)。

## 该调哪个方法

四种入口，区别只在于你手上已经有什么。它们都不在 Dart 里做像素转换。

| 你手上有 | 调用 | 说明 |
|---|---|---|
| 磁盘上的一个文件 | `scanPath` | 在原生侧读取并解码；Dart 里不落地任何东西 |
| 内存里一张编码后的图片 | `scanImage` | 文件的字节——选中的图片、下载的内容、一个 asset |
| 已解码的像素 | `scanPixels` | RGB、RGBA、BGR 或 BGRA，紧密排列 |
| 灰度 | `scanGray` | 每像素一字节，行紧密排列 |
| 一帧相机画面 | `scanFrame` | 多了行跨距、旋转和 `mirror` |

**优先用 `scanPath` 或 `scanImage`，不要自己解码。** 一张 1200 万像素的照片作为
RGBA 是 48 MB；在 Dart 里解码它会把这些字节拷进 worker isolate，再拷进原生内存，
而这些拷贝什么也换不来。浏览器里该用的是 `scanImage`，那里根本没有路径这回事。

```dart
try {
  final outcome = await scanner.scanPath(file.path);
  if (outcome.results.isEmpty) {
    // 一张里面没有码的图片。就这么告诉用户——而如果 `outcome.candidates` 不为空，
    // 说明**确实**找到了一个符号但没能读出来，那值得换一种说法。
  }
} on PictureUnreadable catch (e) {
  // 不是图片，或者不是这个构建能解的图片。这和上面那种不是一回事，
  // 该对用户说的话也不一样。
}
```

这个区分正是那个异常存在的意义。以前「什么都打不开的文件」和「一张没有码的图片」
无法区分，而这两件事该说的话完全不同。

### 哪些图片能解

PNG、JPEG、GIF、WebP、BMP、TIFF 和 HEIC 在本包支持的每个平台上都能解。AVIF 在
Apple 平台和浏览器里能解。RAW、JPEG XL 以及另外五十来种，在 Apple 上能解。

背后的规则是：一个解码器要么由本包自己携带，代价是体积；要么向平台借，代价为零。
**Apple 借得出来**——通过 ImageIO 提供 62 种格式，RAW 也在内，因为每个应用本来就
链接了它。**其它地方借不到可用的**——Android 的 HEIC 解码器要 API 30 而且忽略方向
标签，Linux 根本没有，Windows 只有在用户装过之后才有——所以那三个平台自己带。
**浏览器自己会解它的图片**，这就是 web 构建完全不携带任何解码器的原因。

**[doc/image_formats.md](doc/image_formats.md)** 里是完整的矩阵：每个平台借了什么、
为什么，以及怎么把你自己的解码器借给它。

对于这里什么都读不了的格式，用平台自己的 API 解码，再把像素交给 `scanPixels`：

```dart
Future<ScanOutcome> scanAnyPicture(WxScanner scanner, String path) async {
  try {
    return await scanner.scanPath(path);
  } on PictureUnreadable {
    // Flutter 自己的解码器，设备能显示什么它就能读什么。
    final codec = await ui.instantiateImageCodec(await File(path).readAsBytes());
    final image = (await codec.getNextFrame()).image;
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      // await 放在 try 里面，这样 `finally` 不会在扫描进行中把 image 释放掉。
      return await scanner.scanPixels(
        data!.buffer.asUint8List(),
        image.width,
        image.height,
        format: WxPixelFormat.rgba,
      );
    } finally {
      image.dispose();
      codec.dispose();
    }
  }
}
```

这段的价值比以前小多了：它能覆盖而扫描器覆盖不了的格式，如今都是些少见的——一个
JPEG XL，或者 Apple 之外某个平台上的 RAW 文件。

## 与扫描器打交道

创建一个扫描器代价不小，因为它要构建一个 TFLite 解释器，所以只要还在扫，就一直留着
它。一个实例同一时刻解一张图；并发调用会在原生侧串行化，多个实例则可以并行扫描。

异步方法跑在后台 isolate 上，所以一张大图不会卡住 UI。`scanGraySync` 和
`scanFrameSync` 是给已经不在主 isolate 上的调用方用的。丢掉一个扫描器而不调
`dispose()` 仍然会释放它，但要等垃圾回收器轮到它，在那之前模型一直占着内存——
debug 构建下真发生了会在日志里说一声。

如果一个扫描器只用一次而不打算留着，`WxScanner.use` 会创建一个、交给回调，并且
无论那个回调怎么结束都把它释放掉：

```dart
final outcome = await WxScanner.use((scanner) => scanner.scanImage(bytes));
```

`WxScanner.liveCount` 报告当前进程里有多少个扫描器存活。它是个诊断手段，用来找出
那个从未被释放的：测试可以断言它回到零，一个反复打开关闭的页面可以观察它几轮，
看数字会不会往上爬。它数的是扫描器而不是持有者，所以借给 `wxscan_live` 的那个仍然
只算一个。

对相机帧，`scanFrame` 接受行跨距、旋转，以及一个 `mirror` 标志——它镜像的是返回的
x 坐标。帧本身从不被镜像，因为检测器是在非镜像输入上训练的；这个标志存在，是为了让
坐标和一个镜像显示的预览对得上。

尺寸对不上会抛 `ArgumentError`，而不是返回空结果。一个和它自己的宽高对不上的缓冲是
调用方的错误，而空结果会把它伪装成「这一帧里什么都没有」。

扫描器也可以借给
[`wxscan_live`](https://github.com/wilinz/wxscan/tree/main/packages/wxscan_live)——
`WxScanController(scanner: scanner)`——这样一个既要实时扫又要扫相册的应用只持有
一个扫描器而不是两个，内存里也只有一份权重。controller 只是借用，从不释放它。

### 调整检测参数

`confidenceThreshold`、`nmsThreshold` 和 `scaleFactor` 的读写不会去争扫描器的锁，
所以可以在帧与帧之间改。默认值就是上游算法自带的那一套，也是该从这里起步的值；
调低 `confidenceThreshold` 能找到更暗淡的符号，代价是更多解不出内容的候选——那正是
`hasUndecodable` 会报告的东西。

## 结果

坐标类型是 `ScanPoint`，不是 `dart:ui` 的 `Offset`：本包是纯 Dart 的，不能依赖
Flutter。字段名是对得上的，所以 Flutter 调用方写 `Offset(p.dx, p.dy)` 即可。

`ScanResult` 同时带着 `text` 和 `bytes`。二维码的内容并不要求是文本，所以 `bytes`
才是权威的；`text` 是按 `charset` 解出来的结果，而解码器只报告 `UTF-8` 或 `GB2312`
而不做转换。

`ScanOutcome.candidates` 装的是检测器找到的东西。有候选但没有结果——也就是
`hasUndecodable`——意味着定位到了一个符号却解不出来，通常是因为它太小或者太糊。
这时候提示用户放大，比报告一个失败要好。

## 模型

TFLite 权重没有随包分发；以字节形式传进来，通常来自一个 asset。两个都传 null 就是
选择无模型模式，而加载失败的模型会**退回**到那个模式，不会抛异常。那种模式下解码
照常工作；失去的是小码和远处的码的检出率——那正是 CNN 阶段贡献的东西。`hasModels`
报告当前处于哪种模式。

## 构建钩子

`hook/build.dart` 做了从前由各平台构建系统做的所有事：下载 TFLite C 库、编译
`rust/` 下的 Rust crate，并把两者都声明为 code asset。Dart 工具链随后把它们放在
一起并改写它们之间的依赖关系，所以不需要任何人去安排 rpath。

CNN 推理用的是 TFLite C 库，它在构建时下载，而不是随包携带。每一个产物都在
`tool/tflite.lock` 里用版本号和 SHA-256 钉死；对不上就构建失败。要升级，运行
`tool/update_tflite_lock.sh <litert-version> <desktop-version>`，它会重新下载每个
产物并改写校验和。编辑那个文件是指向另一个构建的**唯一**途径：钩子的运行器会清空
环境变量，所以那里放什么都不会被采纳。

| 平台 | 来源 |
|---|---|
| Android | Google Maven，`com.google.ai.edge.litert:litert` |
| iOS | TensorFlowLiteC pod 所使用的发布渠道——一个静态 framework，所以它是被链接进 Rust 库里，而不是并排放在旁边 |
| macOS、Linux、Windows | 预编译产物；官方没有桌面端分发，所以仓库地址写在 `tflite.lock` 里 |

下载会缓存在钩子的共享输出目录里，所以只有第一次构建付这个代价。那次构建同时还要
编译 Rust 源码，要花几分钟；之后的构建是增量的。

## 浏览器

web 构建是同一套算法、同一批权重，编译成 WebAssembly，跑在一个 worker 里，这样解一
帧不会卡住页面。`WxScanner` 还是同一个类、同一批方法；不同之处在于：

- `scanGraySync` 以及其它 `*Sync` 方法会抛 `UnsupportedError`。引擎是通过消息从
  worker 那边回话的，所以同一次调用里没有东西可以返回。
- 有四个文件必须由应用来提供。其中一个随本包分发；另外三个从 `tool/web.lock` 里
  钉死的 release 获取，按那里的校验和核对，并在多次运行之间缓存。一条命令就能把
  四个都放好，而且什么都不用构建：

  ```sh
  dart run wxscan:fetch_web
  ```

  它们会被放进 `web/wxscan`，也正是本包去找它们的地方，所以别的什么都不用配。想放
  别的目录，就传 `--into`，并用 `package:wxscan/web.dart` 里的 `configureWxScanWeb`
  告诉它在哪。

  它们是文件而不是被声明的 asset，因为声明 Flutter asset 会让本包变成一个 Flutter
  包，`dart run` 和 `dart test` 就用不了了。

### 自己构建扫描器

`wxscan_wasm.wasm` 没有随包分发，旁边那个 TensorFlow Lite 运行时也没有。一个提交在
源码旁边的编译产物迟早会和源码脱节——这一个就脱过节，在线演示曾经有一段时间在提供
一个 Rust 侧已经修好的检测器 bug，就因为重新构建它是件得靠人记得的事。所以两者都由
wxscan-rs 的 CI 构建、从它的 release 获取，而应用只需要 `fetch_web` 这一条命令。

想在不等待发布的情况下试一个 Rust 侧的改动，就自己构建：

```sh
git clone https://github.com/wilinz/wxscan-rs
git clone https://github.com/wilinz/cvlite
git clone https://github.com/wilinz/wxing
cd wxscan-rs
printf '[patch.crates-io]\ncvlite = { path = "../cvlite" }\nwxing = { path = "../wxing" }\n' \
  > .cargo/config.toml
RUSTFLAGS="-C target-feature=+simd128" cargo build -p wxscan-wasm \
  --target wasm32-unknown-unknown --profile wasm
```

然后 `--from wxscan-rs/target/wasm32-unknown-unknown/wasm`。那个目录里有什么就从
那里取什么，其余的仍然从 release 来，所以只构建扫描器——通常的情形——不需要别的。

TensorFlow Lite 运行时要动用 emsdk、花上一刻钟，它有自己的 release，在一个
`tflite-` 前缀的 tag 下；很多个版本的扫描器都指向同一个它，因为只有当钉死的 TFLite
版本变动时它才会动。`tool/check_tflite_web.sh` 会在那种变动发生而它被落下时报错。

**[doc/web_build.md](doc/web_build.md)** 讲的是这件事的全部：四个文件各自是什么、
怎么升级运行时，以及 CI 有哪里做得不一样、为什么。

推理用的是 TensorFlow Lite 加 XNNPACK delegate，和其它平台是同一个运行时，所以
浏览器读的是同样的 `.tflite` 文件。一帧 1080p 大约 220 ms，原生是 135 ms，其中推理
只占 8 ms；其余是解码器，比例和原生一致。

四个文件合计 1.8 MB，压缩后过线 660 KB——扫描器 462 KB，运行时 1.3 MB，后者只带了
这两个模型用到的十六个算子，而不是标准构建注册的一百五十个。

## 平台

| 平台 | 说明 |
|---|---|
| Android | arm64-v8a、armeabi-v7a、x86_64。LiteRT 没有发布 32 位 x86 的构建，所以以那个 ABI 为目标的应用必须排除它。 |
| iOS | 13.0+ |
| macOS | 10.15+，arm64 |
| Linux、Windows | x86_64（Linux 另有 arm64） |
| Dart（无 Flutter） | macOS、Linux、Windows —— `dart run` 和 `dart test` 会通过钩子构建并加载这个库 |
| Web | worker 里的 WebAssembly；见[浏览器](#浏览器) |

## 许可

Apache-2.0。Rust 源码在
[wxscan-rs](https://github.com/wilinz/wxscan-rs)。

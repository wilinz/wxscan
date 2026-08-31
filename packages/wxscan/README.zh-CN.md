# wxscan

[English](README.md) · **简体中文**

Flutter 的二维码解码，底层是 `wechat_qrcode` 算法的 Rust 移植：CNN 检测、超分辨率、
解码。

这个包解图片和原始像素缓冲，不开相机。要实时扫码用
[`wxscan_live`](https://pub.dev/packages/wxscan_live)
（[源码](https://github.com/wilinz/wxscan/tree/main/packages/wxscan_live)），
它在原生侧驱动相机，从 Swift 和 Kotlin 调本包的原生库。

<img src="https://raw.githubusercontent.com/wilinz/wxscan/main/docs/demo.webp" width="300"
     alt="一帧里两个二维码都被框出，点开其中一个显示解出的中文文本，按 UTF-8 读取。">

*从笔记本屏幕上一次读到两个码。真正在解码的是这个包的原生库，它前面那台相机是
`wxscan_live`。*

它是纯 Dart 包，不是 Flutter 插件：原生库由
[构建钩子](https://dart.dev/tools/hooks) 编译和打包，所以在 `dart run`、`dart test`
下和在 Flutter 应用里一样能用，也没有平台构建文件要维护。

## 快速开始

```sh
flutter pub add wxscan     # 不用 Flutter 的话是 `dart pub add wxscan`
```

也可以从 git 引，那样跟着默认分支走，加 `ref` 能钉到某个 tag 或 commit：

```yaml
dependencies:
  wxscan:
    git:
      url: https://github.com/wilinz/wxscan.git
      path: packages/wxscan
```

两种写法在 Flutter 和纯 Dart 下都一样用。

### 需要什么

| | 版本 |
|---|---|
| Dart | 3.10 或更新 |
| Flutter | 从 Flutter 用的话 3.38.1 或更新——这个包在纯 `dart run`、`dart test` 下也能跑 |
| Rust | `PATH` 上有 rustup 即可；编译器版本是钉死的，第一次构建时自动装 |

构建钩子会编 Rust、下 TFLite 库，版本（1.95.0）和目标平台都从 `rust-toolchain.toml`
读，rustup 第一次跑的时候把两样一起装上。别的都不需要：没有 podspec，没有 Gradle，
没有 CMake。

CNN 权重不随包分发。去
[wxscan-weights](https://github.com/wilinz/wxscan-weights) 下载 `detect.tflite` 和
`sr.tflite`，放进 `assets/models/`，在 `pubspec.yaml` 里声明这个目录：

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
  // 偏移量和长度不能省。打包进来的 asset 可能只是一大块缓冲里的一段，
  // 不带参数的 `asUint8List()` 会读过界。
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

两个权重都可以不传。不传就是不带 CNN 阶段的模式，普通的码照样读得出来，见
[模型](#模型)。

## 该调哪个方法

四个入口，区别只在你手上已经有什么。它们都不在 Dart 里转像素。

| 手上有 | 调 | 说明 |
|---|---|---|
| 磁盘上的文件 | `scanPath` | 原生侧读、原生侧解，Dart 里什么都不落地 |
| 内存里编码过的图片 | `scanImage` | 文件的字节：选中的图、下载的内容、一个 asset |
| 解好的像素 | `scanPixels` | RGB、RGBA、BGR、BGRA，紧密排列 |
| 灰度 | `scanGray` | 每像素一字节，行紧密排列 |
| 相机帧 | `scanFrame` | 多了行跨距、旋转和 `mirror` |

**能用 `scanPath` 或 `scanImage`，就别自己解码。** 1200 万像素的照片按 RGBA 是
48 MB；在 Dart 里解，这些字节要拷进 worker isolate，再拷进原生内存，两次拷贝什么都换
不来。浏览器里用 `scanImage`，那边根本没有文件路径。

```dart
try {
  final outcome = await scanner.scanPath(file.path);
  if (outcome.results.isEmpty) {
    // 图片里没有码，就这么告诉用户。如果 `outcome.candidates` 不空，说明
    // 看见码了但没解出来，那得换个说法。
  }
} on PictureUnreadable catch (e) {
  // 不是图片，或者这个构建解不了。跟上面那种不一样，该说的话也不一样。
}
```

这个区分就是这个异常存在的理由。以前「文件根本打不开」和「图片里没有码」分不出来，
可这两件事该对用户说的完全不同。

### 哪些图片能解

PNG、JPEG、GIF、WebP、BMP、TIFF、HEIC，本包支持的每个平台都能解。AVIF 在 Apple 平台
和浏览器上能解。RAW、JPEG XL 以及另外五十多种，只有 Apple 上能解。

规则是这样：解码器要么自己带，代价是体积；要么向平台借，不花钱。**Apple 借得到**，
ImageIO 一口气给 62 种格式，RAW 也在里面，反正每个应用都链接了它。**别的地方借不到
能用的**：Android 的 HEIC 解码器要 API 30，还忽略方向标签；Linux 一个都没有；Windows
要用户自己装过才有。所以这三个平台自己带。**浏览器自己会解图**，所以 web 构建一个
解码器都不带。

以上是默认带的。这里自带的每个解码器都是一个 cargo feature，永远不会拿到 TIFF 的应用
可以把它去掉——[配置构建](#配置构建)里的 `image_formats`，体积数字也在那儿。

完整的矩阵、每个平台借了什么、以及怎么把自己的解码器借进来，都在
**[doc/image_formats.md](doc/image_formats.md)**。

遇到这里读不了的格式，用平台自己的 API 解码，再把像素交给 `scanPixels`：

```dart
Future<ScanOutcome> scanAnyPicture(WxScanner scanner, String path) async {
  try {
    return await scanner.scanPath(path);
  } on PictureUnreadable {
    // Flutter 自己的解码器，设备能显示的它都能读。
    final codec = await ui.instantiateImageCodec(await File(path).readAsBytes());
    final image = (await codec.getNextFrame()).image;
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      // await 放在 try 里面，免得 `finally` 在扫描还没完时就把 image 释放了。
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

这段现在没以前那么值钱了。它能补上的格式如今都挺少见：一个 JPEG XL，或者 Apple 之外
某个平台上的 RAW。

## 与扫描器打交道

建一个扫描器不便宜，它要建一个 TFLite 解释器，所以只要还在扫就一直留着。一个实例同时
只解一张图，并发调用在原生侧排队；要并行就建多个实例。

异步方法跑在后台 isolate 上，大图不会卡 UI。`scanGraySync` 和 `scanFrameSync` 是给
本来就不在主 isolate 上的调用方用的。扫描器不调 `dispose()` 直接丢掉也会被释放，但要
等垃圾回收轮到它，这期间模型一直占着内存——debug 构建下真发生了会往日志里写一句。

只用一次、不打算留着的扫描器，用 `WxScanner.use`：它建一个交给回调，回调不管怎么结束
都把它释放掉。

```dart
final outcome = await WxScanner.use((scanner) => scanner.scanImage(bytes));
```

`WxScanner.liveCount` 告诉你进程里现在有几个扫描器活着。这是个诊断手段，用来抓那些
忘了释放的：测试里可以断言它回到零，一个反复进出的页面可以看它几轮，数字往上爬就是有
问题。它数的是扫描器，不是持有者，所以借给 `wxscan_live` 的那个还是只算一个。

相机帧用 `scanFrame`，它多接受行跨距、旋转，还有一个 `mirror` 标志。这个标志镜像的是
返回的 x 坐标，帧本身从不镜像——检测器是在非镜像的图上训练的。有这个标志，是为了让坐标
跟一个镜像显示的预览对得上。

尺寸对不上会抛 `ArgumentError`，不会返回空结果。缓冲和它自己的宽高对不上是调用方的
错，而空结果会把这个错伪装成「这帧里什么都没有」。

扫描器还可以借给
[`wxscan_live`](https://pub.dev/packages/wxscan_live)
（[源码](https://github.com/wilinz/wxscan/tree/main/packages/wxscan_live)），写成
`WxScanController(scanner: scanner)`。这样一个既扫实时又扫相册的应用只有一个扫描器，
内存里也只有一份权重。controller 只是借用，从不释放它。

### 调整检测参数

`confidenceThreshold`、`nmsThreshold`、`scaleFactor` 读写都不用抢扫描器的锁，可以在
帧与帧之间随时改。默认值是上游算法带的那套，从它起步就对。把 `confidenceThreshold`
调低能找到更淡的码，代价是多出一堆解不出内容的候选，那些会体现在 `hasUndecodable`
上。

## 结果

坐标是 `ScanPoint`，不是 `dart:ui` 的 `Offset`——本包是纯 Dart 的，不能依赖 Flutter。
字段名对得上，Flutter 这边写 `Offset(p.dx, p.dy)` 就行。

`ScanResult` 同时给 `text` 和 `bytes`。二维码的内容不一定是文本，所以 `bytes` 才是准
的；`text` 是按 `charset` 解出来的，而解码器只报 `UTF-8` 或 `GB2312`，不做转换。

`ScanOutcome.candidates` 是检测器找到的东西。有候选没有结果，也就是 `hasUndecodable`，
意思是码看见了但没解出来，一般是太小或者太糊。这时候提示用户凑近，比报个失败有用。

## 模型

TFLite 权重以字节传进来，通常来自 asset。两个都传 null 就是无模型模式；加载失败也会
退回到这个模式，不抛异常。这个模式下解码照常，掉的是小码和远处码的检出率，也就是 CNN
阶段贡献的那部分。`hasModels` 告诉你现在是哪种模式。

权重在磁盘上就改传路径，文件由原生库在 worker isolate 上读，那一兆字节不会落在调用它
的 isolate 上：

```dart
final scanner = await WxScanner.create(
  detectModelPath: '${dir.path}/detect.tflite',
  srModelPath: '${dir.path}/sr.tflite',
);
```

这是给下载下来或者拷到某处的权重用的——**Flutter 的 asset 不是文件**。asset 在应用包
里面，没有可打开的路径，`assets/models/detect.tflite` 在这里什么都不指；那种情况用
`rootBundle` 读出字节传进去。一个模型只能用其中一种方式给。路径读不出来的行为和权重
加载不了完全一样，日志里会写是哪个文件、为什么。浏览器上传路径会抛 `UnsupportedError`：
那里没有文件系统可读。

## 构建钩子

`hook/build.dart` 把从前各平台构建系统做的事全接过来了：下载 TFLite C 库、编 `rust/`
下的 crate，把两者都声明成 code asset。Dart 工具链接着把它们放到一起，改写它们之间的
依赖，所以没人需要去调 rpath。

CNN 推理用 TFLite C 库，构建时下载，不随包携带。每个产物都在 `tool/tflite.lock` 里用
版本号加 SHA-256 钉死，对不上就构建失败。升级用
`tool/update_tflite_lock.sh [tag]`，它会重新下载并改写校验和。改那个文件是指向另一个
构建的**唯一**办法：钩子的运行器会清空环境变量，你在那里设什么都不算数。

| 平台 | 来源 |
|---|---|
| 所有平台 | 同一个仓库的同一个 release，CI 从 TensorFlow 源码构建——tag 写在 `tflite.lock` 里，Android、iOS 和桌面链接的是同一个 TensorFlow |
| iOS | 静态归档，所以它被链进 Rust 库里，不是并排放着 |

下载会缓存在钩子的共享输出目录里，只有第一次构建付这个代价。那次还要编 Rust，得等几
分钟；之后是增量的。

### 配置构建

原生库有两件事该由应用自己定，不该由这个包定，都写在应用自己的 `pubspec.yaml` 里：

```yaml
hooks:
  user_defines:
    wxscan:
      image_formats: [png, jpeg]
      cargo_profile:
        strip: symbols
        codegen_units: 1
```

两个都不写就什么都不变：格式按下面的默认来，profile 就是 `rust/Cargo.toml` 里那份。
格式名或 profile 键拼错会让构建直接失败并说清楚，而不是悄悄产出一个少了某个解码器的
库——这种列表里的拼写错误，代价本来就是这个。

**`image_formats`** 是编进去哪些解码器：`png`、`jpeg`、`gif`、`webp`、`bmp`、`tiff`、
`heic`。默认七个全要，Apple 除外——那边启动时会把 ImageIO 借给库，这七种它全都读得了，
所以默认只留相册选择器写得出的那三种，多要的等于把系统已有的再编一份。只扫相机帧、
或者只扫自己写出来的图片的应用，可以直说：

| `image_formats` | Android arm64（strip 后） | macOS arm64 |
|---|---|---|
| 默认 | 2.13 MB | 1.29 MB |
| `[png, jpeg, gif]` | 1.22 MB | 1.29 MB（那边的默认） |
| `[jpeg]` | 1.02 MB | 1.04 MB |
| `[]` | 866 KB | 916 KB |

去掉的格式在运行时也不是错误：图片会以 `PictureUnreadable` 加 `unsupportedFormat`
回来，和一个从来就没人读过的格式是同一个答案；`scanPixels` 照样收应用自己解出来的
像素。Apple 上借来的 ImageIO 什么都先答一遍，所以在那边少编格式只影响体积，不影响
结果。

**`cargo_profile`** 就是 `[profile.release]`，一个键一个键地写：`opt_level`、`lto`、
`codegen_units`、`strip`、`panic`。它们以 `CARGO_PROFILE_RELEASE_*` 的形式到达 cargo，
优先级高于 manifest。

| profile | macOS arm64 | 1080p 一帧 |
|---|---|---|
| 默认（`opt_level: 3`、`lto: true`） | 1.29 MB | 122 ms |
| `strip: symbols` | 1.14 MB | 122 ms |
| `strip: symbols`、`codegen_units: 1`、`panic: abort` | 1.05 MB | 122 ms |
| 再加 `opt_level: z`、`lto: fat` | 840 KB | **421 ms** |

前三行是白捡的，第四行不是：这是一条在像素上跑循环的流水线，而 `opt_level: z` 正是那个
不让循环展开的开关。库小三分之一，每帧慢三倍半——这笔账要么明明白白地算过再做，要么
就别做。

`panic: abort` 更小，也更诚实——从 Dart 调进来的 Rust panic 本来就无处可展开——但它把
一个跨边界的错误变成了进程结束，这是应用该自己拿的主意。

## 浏览器

web 构建是同一套算法、同一批权重，编成 WebAssembly，跑在 worker 里，所以解一帧不会卡
页面。`WxScanner` 还是那个类、那些方法，区别有这些：

- `scanGraySync` 和其它 `*Sync` 方法会抛 `UnsupportedError`。引擎在 worker 那边，靠
  消息回话，同一次调用里没东西可返回。
- 有四个文件要由应用提供。一个随本包分发，另外三个从 `tool/web.lock` 钉死的 release
  下载，按那里的校验和核对，并且跨运行缓存。一条命令全放好，什么都不用编：

  ```sh
  dart run wxscan:fetch_web
  ```

  它们进 `web/wxscan`，本包也去那里找，别的不用配。想换目录就传 `--into`，再用
  `package:wxscan/web.dart` 里的 `configureWxScanWeb` 告诉它在哪。

  它们是文件而不是声明的 asset，因为一旦声明 Flutter asset，本包就变成 Flutter 包，
  `dart run` 和 `dart test` 就用不了了。

### 自己构建扫描器

`wxscan_wasm.wasm` 不随包分发，旁边那个 TensorFlow Lite 运行时也不。编译产物提交在
源码旁边，迟早会跟源码脱节——这一个就脱过：Rust 那边检测器的 bug 早修好了，在线演示还
供了一阵子旧的，就因为重编是件得靠人记得的事。所以两者都由 CI 构建、从各自的 release
拿——扫描器在 wxscan-rs，运行时在 wxscan-litert-wasm——应用只需要 `fetch_web` 一条命令。

想试 Rust 那边的改动、不等发布，就自己编：

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

然后 `--from wxscan-rs/target/wasm32-unknown-unknown/wasm`。那个目录里有什么就用什么，
其余的照旧从 release 拿，所以只编扫描器——通常就是这种情况——不用管别的。

TensorFlow Lite 运行时要动 emsdk，一编一刻钟。它在自己的仓库
[wxscan-litert-wasm](https://github.com/wilinz/wxscan-litert-wasm) 里构建和发布；好多个
版本的扫描器指向同一个，因为只有钉死的 TFLite 版本变了它才会变。
`tool/check_tflite_web.sh` 就是防它在那种时候被落下的。

四个文件分别是什么、运行时怎么升级、CI 哪里做得不一样，全在
**[doc/web_build.md](doc/web_build.md)**。

推理还是 TensorFlow Lite 加 XNNPACK delegate，和别的平台同一个运行时，所以浏览器读的
是同样的 `.tflite` 文件。一帧 1080p 大约 220 ms，原生是 135 ms，其中推理只占 8 ms，
剩下都是解码器——比例和原生一样。

四个文件合起来 1.8 MB，压缩后过线 660 KB：扫描器 462 KB，运行时 1.3 MB。运行时只带了
这两个模型用到的十六个算子，不是标准构建那 150 个。

## 平台

| 平台 | 说明 |
|---|---|
| Android | arm64-v8a、armeabi-v7a、x86_64。LiteRT 没出 32 位 x86 的构建，要打那个 ABI 的应用得排掉它。 |
| iOS | 13.0+ |
| macOS | 10.15+，arm64 和 x86_64——release 构建是通用二进制，两半都能链 |
| Linux、Windows | x86_64（Linux 还有 arm64） |
| Dart（无 Flutter） | macOS、Linux、Windows，`dart run` 和 `dart test` 会通过钩子编译并加载这个库 |
| Web | worker 里的 WebAssembly，见[浏览器](#浏览器) |

**macOS 两个架构都支持**，也就是 release 构建本来要的那样：`ARCHS` 默认是
`$(ARCHS_STANDARD)`，在 macOS 上就是 arm64 加 x86_64。`tool/tflite.lock` 钉的
`darwin_universal` 产物两半都在，钩子会按每次构建的架构把它切开，Rust 库也是每个架构
各编一遍——应用要出通用二进制，什么都不用设。只想要单个架构的应用照旧在
`macos/Runner/Configs/Release.xcconfig` 里写（`ARCHS = arm64`），但那已经不是构建能
成功的前提了。

## 许可

Apache-2.0。Rust 源码在
[wxscan-rs](https://github.com/wilinz/wxscan-rs)。

# wxscan_live

[English](README.md) · **简体中文**

Flutter 的实时二维码扫描，底层是 `wechat_qrcode` 算法的 Rust 移植：CNN 检测、超分
辨率、解码。

相机帧从 CameraX 或 AVFoundation 直接进扫描器，不跨到 Dart 这边，所以 UI isolate 上
不会有逐帧的拷贝。进到 Dart 的是每帧的结果；预览是一张 Flutter 纹理，用的是同一块
缓冲。

要解一张静态图片，用
[`wxscan`](https://github.com/wilinz/wxscan/tree/main/packages/wxscan)，它把同一个
扫描器暴露给 Dart。

<img src="https://raw.githubusercontent.com/wilinz/wxscan/main/docs/demo.webp" width="300"
     alt="一帧里两个二维码都被框出，点开其中一个显示解出的中文文本，按 UTF-8 读取。">

*一帧里两个码，其中一个还是转过的，从笔记本屏幕上扫下来，然后是点开的那一个。*

**[在浏览器里试试](https://wilinz.github.io/wxscan/)**：就是这个示例应用，构建成 web，
跑着同一个 Rust 扫描器编出来的 WebAssembly。打开是一个菜单，只有点了实时扫码才会申请
相机，解码图片从来不需要。

## 快速开始

```sh
flutter pub add wxscan_live
```

也可以从 git 引，那样跟着默认分支走，加 `ref` 能钉到某个 tag 或 commit：

```yaml
dependencies:
  wxscan_live:
    git:
      url: https://github.com/wilinz/wxscan.git
      path: packages/wxscan_live
```

哪种写法都会把 `wxscan` 一起带上。

### 需要什么

| | 版本 |
|---|---|
| Dart | 3.10 或更新 |
| Flutter | 3.38.1 或更新——Android 上用 3.44，[有个转屏 bug](#平台) |
| Rust | `PATH` 上有 rustup 即可；编译器版本是钉死的，第一次构建时自动装 |

原生库来自 `wxscan`，编 Rust、下 TFLite 库的是它的构建钩子；版本（1.95.0）和目标平台
都从 `rust-toolchain.toml` 读，rustup 第一次跑的时候把两样一起装上。别的都不需要：
没有 podspec，没有 Gradle，没有 CMake。

**1. 权重。** 不随包分发。去
[wxscan-weights](https://github.com/wilinz/wxscan-weights) 下载 `detect.tflite` 和
`sr.tflite`，放进 `assets/models/`，在 `pubspec.yaml` 里声明这个目录：

```yaml
flutter:
  assets:
    - assets/models/
```

**2. 相机权限。** 插件不替你申请，没授权它会抛 `NO_PERMISSION` 的
`PlatformException`。先声明，再在调 `initialize` 之前用
[`permission_handler`](https://pub.dev/packages/permission_handler) 之类的包去要：

| 平台 | 写在哪 |
|---|---|
| Android | `AndroidManifest.xml` 里的 `<uses-permission android:name="android.permission.CAMERA" />` |
| iOS、macOS | `Info.plist` 里的 `NSCameraUsageDescription` |
| macOS | 两个 `.entitlements` 文件里还都要加 `com.apple.security.device.camera` |

**3. 打开相机，监听结果。**

```dart
import 'package:flutter/services.dart' show rootBundle;
import 'package:wxscan_live/wxscan_live.dart';

Future<Uint8List> _asset(String path) async {
  final data = await rootBundle.load(path);
  // 偏移量和长度不能省。打包进来的 asset 可能只是一大块缓冲里的一段，
  // 不带参数的 `asUint8List()` 会读过界。
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

final controller = WxScanController(resolution: WxResolution.p720);
await controller.initialize(
  detectModel: await _asset('assets/models/detect.tflite'),
  srModel: await _asset('assets/models/sr.tflite'),
);

controller.scans.listen((outcome) {
  for (final r in outcome.results) {
    print(r.text);
  }
});
```

`WxScanController` 是 `ValueNotifier<WxScanValue>`，跟 `CameraController` 和
`CameraValue` 一个形状：每个 setter 都等平台返回，再把设备**实际做到的**发出来，所以
`controller.value.zoom` 是当前生效的倍率，不是你要的那个。监听它，或者丢给
`ValueListenableBuilder`，界面就跟着走。

**4. 显示预览。** `WxScanPreview` 只画画面，别的什么都不干——原生上是纹理，浏览器里是
平台视图。它按设备的自然方向保持正立，屏幕转到哪，由外面补回来：

```dart
ValueListenableBuilder<WxScanValue>(
  valueListenable: controller,
  builder: (context, value, _) {
    final size = value.previewSize;
    if (size == null) return const SizedBox.shrink();
    return ClipRect(
      child: FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          // 盒子的尺寸是转过之后的，转是在它里面做的。
          // 两者必须一致，否则 BoxFit 会按错的比例拉。
          width: size.rotatedWidth.toDouble(),
          height: size.rotatedHeight.toDouble(),
          child: RotatedBox(
            quarterTurns: size.quarterTurns,
            child: SizedBox(
              width: size.width.toDouble(),
              height: size.height.toDouble(),
              child: WxScanPreview(controller: controller),
            ),
          ),
        ),
      ),
    );
  },
);
```

要从 controller 构建，别只读一次 `previewSize`。屏幕转的时候它会变，设备退回到另一个
采集尺寸时也会变。

离开页面记得 `controller.dispose()`，不释放的 controller 会一直占着相机。想暂停用
`setScanning(false)`，它停解码但让相机和预览继续跑——弹结果面板的时候要的就是这个。

[`packages/wxscan_live/example`](example) 是把上面这些都做了的完整应用，另外还有闪光
灯、变焦、相册解码，以及一帧多码时怎么挑。

**界面也在那里。** 本包只负责画相机图像、报告找到了什么。取景框、码上的四角、多码时
的选择器，还有那套把帧坐标换成屏幕坐标、让画和点对得上的算法，全在
[`example/lib/scan_page.dart`](example/lib/scan_page.dart)。那是写来给人读、给人抄的，
不是拿来依赖的。

## 结果

每帧一个 `ScanOutcome`，什么都没找到时结果为空。`candidates` 是检测器定位到的东西；
有候选没结果，也就是 `hasUndecodable`，意思是码看见了但没解出来，一般是太小或者太糊，
这时候该提示用户凑近。

坐标在正立的帧里，帧的尺寸就在这个 outcome 上。旋转已经算进去了，预览镜像时镜像也算
进去了，直接往预览上映射就行，不用再修。

## 相机控制

`setResolution`、`setTorch`、`hasTorch`、`setZoom`、`zoomRange`、`focusAt`，还有
`grabFrame`——它按正在解码的尺寸返回最近一帧的正立 JPEG，用户挑码的时候可以拿它当一张
冻住的画面。

分辨率越高，每帧越贵，但一个密集的码像素不够根本解不出来。日常的码 720p 就够。

每项设置读回来的都是设备确认过的，不是你要的：`setZoom` 返回它钳到的倍率；没有闪光灯
的硬件上，`torchEnabled` 设多少次都是 false。

### 对焦

`focusAt(x, y)` 把对焦和测光指到画面里某一点，返回设备接不接受。相机关着、点在画面
外面、或者硬件根本没有对焦可指（所有浏览器都是这种），都会返回 false。两者过几秒都会
回到连续模式，所以没人管的扫描器会自己继续对焦。

**坐标是预览的比例值，在 `previewWidth` 和 `previewHeight` 那个空间里，也就是在屏幕
要的 `quarterTurns` 之前。** 所以一次点击得沿着预览被画出来的那套变换倒推回去：先撤
fit，再撤旋转。

```dart
// `tap` 是相对于预览那个盒子的局部坐标，`size` 是当前的 WxPreviewSize。
final scale = math.max(box.width / size.rotatedWidth,
                       box.height / size.rotatedHeight);
final dx = (box.width - size.rotatedWidth * scale) / 2;
final dy = (box.height - size.rotatedHeight * scale) / 2;
final rx = (tap.dx - dx) / (size.rotatedWidth * scale);
final ry = (tap.dy - dy) / (size.rotatedHeight * scale);
if (rx < 0 || rx > 1 || ry < 0 || ry > 1) return;  // 点在画面外

// 撤销 RotatedBox 顺时针转的那几个四分之一圈。
final (x, y) = switch (size.quarterTurns) {
  1 => (ry, 1 - rx),
  2 => (1 - rx, 1 - ry),
  3 => (1 - ry, rx),
  _ => (rx, ry),
};
await controller.focusAt(x, y);
```

`ScanResult` 自己的坐标在被扫的那一帧里，那一帧相对屏幕是正立的，也就是过了 fit 那步
之后的同一个空间。所以要对焦到帧里找到的某个码，只用上面后半段：中心点除以
`ScanOutcome.width` 和 `height`，再撤旋转。

`example/lib/scan_page.dart` 两件事都做了：一件给点击，一件用来自动对焦到那个看见了却
读不出来的码上。

## 实践建议

**跟着应用生命周期走。** 在后台扫码既费电，出的帧又没人看：

```dart
@override
void didChangeAppLifecycleState(AppLifecycleState state) {
  controller.setScanning(state == AppLifecycleState.resumed);
}
```

**暂停用 `setScanning(false)`，别用 `dispose()`。** 它停解码，相机和预览接着跑——弹
结果面板或者推一个新页面的时候要的就是这个。`dispose()` 是离开页面时用的，而每个
initialize 过的 controller 都必须释放：设备只有一个相机会话，活得比页面还久的
controller 会把它扣着，下一个就开不了。

**`hasUndecodable` 的意思是「再凑近点」，不是失败。** 有候选没结果，说明检测器找到了
一个解码器读不出来的码，几乎总是画面里太小或者太虚。两件事有用，而且互不依赖：

- *变焦，但要慢慢来。* 按候选占画面的比例算个目标值，然后一小步一小步走过去，别一次
  调到位。倍率一跳，用户本来端稳的码就被甩出画面了，看起来像扫描器在瞎猜。另外相机
  只围着画面中心变焦，靠边的码没多少余量，一放大就出去了——那种时候不如等手挪过来。
- *对焦到它上面。* 小码通常也虚：它在画面里某个位置，而偏重中心的连续对焦正把它背后
  的墙对得清清楚楚。对着候选中心调一次 `focusAt` 往往就够了，而且那些偏得太远、变焦
  够不着的码它也管用。

这两者要的耐心不一样。**变焦**要等好几帧一致再动：在一次误检上就动手，画面甩得到处
乱跑，用户瞄的东西也丢了。**对焦**第一帧就可以动：最坏是镜头挪到一个空处，下一帧就
纠正回来，这期间不损失什么；反过来，等待只会推迟那次本来就能成的读取。

**什么都没找到的时候也要对焦。** 上面那些办法都等着一个候选框，而画面糊到检测不出
东西时根本没有框——这个状态会把自己锁死：没有框，就没人要求对焦，于是框永远不出现。
镜头停在上一次会话留下的位置时，扫描器一开就是这个状态；连续自动对焦救不了它，因为
「连续」是对**变化**做反应，而一部举着不动、对着码的手机什么都没变。插件在相机打开时
主动要一次对焦扫描，正是为了这个；应用不该就此为止。当大约一秒的帧里既没有结果也没有
候选，就 `focusAt(0.5, 0.5)`——每一两秒最多一次，因为每次扫描过程中画面都会先糊一下。
这时候也没有正在进行的读取会被它打断：这正是这个状态的全部意思。

**让用户挑之前，先把画面冻住。** 一帧解出多个码时，那些标记属于**那一帧**。预览还在
跑的话，画面会随着手的抖动在标记底下移动，用户永远点不准。`grabFrame()` 返回的就是
那一帧的 JPEG——把它盖在预览上，配合 `setScanning(false)`，标记自然就对齐了。

**测试里可以把相机换掉。** 每次调用都走 `WxScanPlatform.instance`，赋一个子类给它，
整个原生侧就被替换了。widget 测试不用设备也能驱动扫描结果、旋转和变焦钳制。

## 模型

TFLite 权重传给 `initialize`，通常来自 asset。插件把它们加载进一个自己拥有的扫描器，
整个过程在原生侧，因为这条路径不经过 Dart。不传权重，或者权重加载失败，都会退回到不带
CNN 阶段的解码，不会失败——`controller.value.modelsLoaded` 告诉你现在是哪种模式。

权重在磁盘上就改传路径，文件由库来读，一兆字节不用过方法通道：

```dart
await controller.initialize(
  detectModelPath: '${dir.path}/detect.tflite',
  srModelPath: '${dir.path}/sr.tflite',
);
```

这是给下载下来或者拷到某处的权重用的——**Flutter 的 asset 不是文件**。asset 在应用包
里面，没有可打开的路径，`assets/models/detect.tflite` 在这里什么都不指；那种情况用
`rootBundle` 读出字节传进去，快速开始里就是这么做的。

一个模型只能用其中一种方式给，不能两种都给。路径读不出来和权重加载不了一样不致命：
同样退回、同样通过 `modelsLoaded` 反映，原因连同路径打在原生日志里。浏览器上传路径会抛
`UnsupportedError`——那里没有文件系统可读，悄悄忽略只会让页面在没有检测器的情况下扫。

### 共用一个扫描器

一个既扫实时又扫相册的应用，不这么做就会有两个扫描器：内存里两份 CNN 权重，两套阈值，
调过一套之后它们就各走各的。把手上已有的扫描器借给相机，从头到尾只有一个：

```dart
final scanner = await WxScanner.create(detectModel: detect, srModel: sr);

final controller = WxScanController(scanner: scanner);
await controller.initialize();          // 不传权重，用借来的那个

final fromLibrary = await scanner.scanImage(bytes);   // 同一个扫描器
```

相机会对借来的扫描器持有自己的一份引用，关闭时还回去，所以两边按任意顺序释放都行，
最后一个放手的时候扫描器才消失。它们之间传的句柄是个数字，原生库在自己的表里查它，
不是地址。所以就算传进来一个陈旧的句柄——热重启留下的正是这种——也只会被拒掉，不会被
跟着走。

web 上这一节不改变什么：那边的扫描器是个 worker，靠消息访问，本来就没有第二份拷贝要
避免。

## 浏览器

`getUserMedia` 开相机，`<video>` 播放，每帧通过 canvas 读出来送给扫描器，扫描器在
worker 里跑，所以解码不卡页面。方法和手机上完全一样，区别有这些：

- 预览是平台视图不是纹理，所以用
  [`WxScanPreview`](lib/src/preview.dart) 而不是 `Texture` 来组合。它在每个平台上都是
  同一个 widget，也严格顶替 `Texture`：按设备自然方向正立，旋转和定尺寸交给外面。
- 帧在这里会进 Dart，原生上从来不会。一帧 1080p 要一次 canvas 读取加一次传给 worker，
  所以 web 上的扫描速率跟帧尺寸绑得很紧。
- 闪光灯和变焦是 `MediaStreamTrack` 的约束项，各家浏览器支持得参差不齐，所以
  `hasTorch` 和 `zoomRange` 报的是这条轨道实际声称的东西——桌面上通常什么都没有。
- **`<video>` 一旦离开页面就会被浏览器暂停，放回去也不会自己恢复。** HTML 规范对
  「从文档里移除的媒体元素」就是这么规定的，Chromium 执行，WebKit 不执行。所以一个在
  Chrome 上（桌面和 Android 都一样）冻在第一帧的预览，在 Safari 里好好的。任何在宿主
  之间搬动预览元素的代码，挂上之后都得重新 `play()`，而且绝不能把它塞进一个已经被平台
  视图从页面里摘走的宿主。这两点都在
  [`platform_web.dart`](lib/src/web/platform_web.dart) 里处理了。这条写在这里，是因为
  从外面看它长这样：相机开了，出一帧就不动了，轨道是活的，元素在页面上，控制台一片
  干净。
- `wxscan` 在 web 上要的那四个文件得由应用提供：`dart run wxscan:fetch_web` 会放好，
  编译产物从那个包钉死的 release 拿。什么都不用编——
  [wxscan 的 README](../wxscan/README.zh-CN.md#自己构建扫描器)
  写了怎么自己编，以及为什么不以编译好的形式分发。它们放在 `web/wxscan/`，会被自动
  找到，不用配。

## 平台

| 平台 | 相机 |
|---|---|
| Android | CameraX，API 24+ |
| iOS | AVFoundation，13.0+ |
| macOS | AVFoundation，10.15+ |
| Web | `getUserMedia`，见[浏览器](#浏览器) |

**Android 上请用 Flutter 3.44 或更新。** 3.41 及更早的引擎里有个门控，resize 时不把 viewport
metrics 送给 Dart。转屏就是一次 resize，于是 Dart 永远停在上一个朝向，旧布局不再填满的
那块窗口就露出来，表现为转完屏后的一片白。这件事这个包够不着：`FlutterView` 内部的值
一直是对的，只是出不了引擎。修复是
[flutter/flutter#182326](https://github.com/flutter/flutter/pull/182326)，进的是 3.44.0。
没有写进 pubspec 的版本约束里，因为除了转屏别的都能用，也不该为一个 Android 的引擎 bug
拦住只发 iOS 的应用。

## 原生库

这里不编任何原生代码。扫描器来自
[`wxscan`](https://github.com/wilinz/wxscan/tree/main/packages/wxscan)，由它的构建
钩子产出成一个 Dart code asset。本包依赖那个包，所以应用不管用了哪个，拿到的都只有
一份——配置也在同一个地方，应用自己 `pubspec.yaml` 里的 `hooks: user_defines: wxscan:`，
不管它有没有直接依赖 `wxscan`。只扫相机帧的应用可以一个图片解码器都不带，在 Android
上那是将近一兆；见
[配置构建](https://github.com/wilinz/wxscan/tree/main/packages/wxscan#配置构建)。

Swift 和 Kotlin 直接调扫描器的 C ABI，因为相机帧不经过 Dart。code asset 由 Dart 运行时
加载，不由 Xcode 或 Gradle 链接，所以那些入口是运行时解析的：Android 上 Flutter 把它
放进 APK 的 `lib/<abi>/`，那本来就是 `System.loadLibrary` 找的地方；iOS 和 macOS 上
`WxScanNative.swift` 打开打包好的 framework，用 `dlsym` 取符号。

## 许可

Apache-2.0。Rust 源码在
[wxscan-rs](https://github.com/wilinz/wxscan-rs)。

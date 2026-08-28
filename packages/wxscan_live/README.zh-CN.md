# wxscan_live

[English](README.md) · **简体中文**

给 Flutter 用的实时二维码扫描，底层是 `wechat_qrcode` 算法的 Rust 移植：基于 CNN
的检测、超分辨率，以及解码。

相机帧从 CameraX 或 AVFoundation 直接进入扫描器，从不跨到 Dart 这边，这样 UI
isolate 上就不会落下逐帧的拷贝。到达 Dart 的是每一帧的结果；预览是一张覆在同一块
缓冲上的 Flutter 纹理。

要解码一张静态图片，请用
[`wxscan`](https://github.com/wilinz/wxscan/tree/main/packages/wxscan)，它把同一个
扫描器暴露给 Dart。

**[在浏览器里试试](https://wilinz.github.io/wxscan/)** —— 就是这个示例应用，构建成
web，跑着同一个 Rust 扫描器编译出的 WebAssembly。它打开时是一个菜单，只有你选了实时
扫描才会请求相机；解码一张图片从来不需要它。

## 快速开始

还没发到 pub.dev，所以从 git 引入。它会把 `wxscan` 一并带上：

```yaml
dependencies:
  wxscan_live:
    git:
      url: https://github.com/wilinz/wxscan.git
      path: packages/wxscan_live
```

这样会跟随默认分支；加一个 `ref` 可以固定到某个 tag 或 commit。

**1. 权重。** 它们没有随包分发。从
[wxscan-weights](https://github.com/wilinz/wxscan-weights) 下载 `detect.tflite`
和 `sr.tflite`，放进 `assets/models/`，并在 `pubspec.yaml` 里声明这个目录：

```yaml
flutter:
  assets:
    - assets/models/
```

**2. 相机权限。** 插件不会替你申请；没有授权时它会以 `NO_PERMISSION` 的
`PlatformException` 失败。先声明它，并在调用 `initialize` 之前用诸如
[`permission_handler`](https://pub.dev/packages/permission_handler) 这样的包去请求：

| 平台 | 写在哪 |
|---|---|
| Android | `AndroidManifest.xml` 里的 `<uses-permission android:name="android.permission.CAMERA" />` |
| iOS、macOS | `Info.plist` 里的 `NSCameraUsageDescription` |
| macOS | 另外还要在两个 `.entitlements` 文件里都加上 `com.apple.security.device.camera` |

**3. 打开相机并监听。**

```dart
import 'package:flutter/services.dart' show rootBundle;
import 'package:wxscan_live/wxscan_live.dart';

Future<Uint8List> _asset(String path) async {
  final data = await rootBundle.load(path);
  // 那个偏移量和长度不是可选的：打包进来的 asset 可能只是一块更大的缓冲里的
  // 一段视图，不带参数的 `asUint8List()` 会读过界。
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

`WxScanController` 是一个 `ValueNotifier<WxScanValue>`，形状和 `CameraController`
与 `CameraValue` 一样：每个 setter 都会等平台返回，然后把设备**实际做到的**发布
出去，所以 `controller.value.zoom` 是当前生效的倍率，而不是你要求的那个。监听它，
或者把它交给 `ValueListenableBuilder`，界面就会跟着走。

**4. 显示预览。** `WxScanPreview` 只是画面本身，别的什么都不是——原生上是一张纹理，
浏览器里是一个平台视图——它以设备的自然方向保持正立，所以屏幕转到哪个方向，都由
外面补偿回来：

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
          // 这个盒子的尺寸是**旋转之后**的，而旋转是在它里面施加的。
          // 两者必须一致，否则 BoxFit 会按错误的比例拉伸。
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

要从 controller 来构建，而不是只读一次 `previewSize`：屏幕旋转时它会变，设备退回到
一个和你要求的不同的采集尺寸时它也会变。

离开页面时调用 `controller.dispose()`——一个没被释放的 controller 会一直占着相机。
`setScanning(false)` 暂停解码但让相机和预览继续运行，那是结果面板弹出时你想要的
行为。

[`packages/wxscan_live/example`](example) 是一个把上面这些都做了的可运行应用，另外
还有闪光灯、变焦、从相册解码，以及一帧里多个码时的挑选。

**用户界面也在那里。** 本包负责画出相机图像并报告找到了什么；取景框、画在每个已解码
的码上的四角、一帧多码时的选择器，以及那套把帧坐标映射到屏幕坐标、让绘制和点击对得上
的换算，全都在 [`example/lib/scan_page.dart`](example/lib/scan_page.dart) 里，那是
写来给人读、给人抄的，不是拿来依赖的。

## 结果

每一帧产生一个 `ScanOutcome`，什么都没找到时结果为空。`candidates` 装的是检测器
定位到的东西；有候选但没有结果——也就是 `hasUndecodable`——意味着看见了一个符号却
解不出来，通常是因为它太小或者太糊，那正是该提示放大的信号。

坐标位于正立的帧里，帧的尺寸就在这个 outcome 上。它们已经算进了旋转，以及预览被
镜像时的镜像，所以可以直接映射到预览上，不需要再做修正。

## 相机控制

`setResolution`、`setTorch`、`hasTorch`、`setZoom`、`zoomRange`、`focusAt`，以及
`grabFrame`——它以正在解码的尺寸返回最近一帧的正立 JPEG，可以在用户从多个码里挑选
时当作一张冻结的画面来用。

分辨率越高，每帧的开销按比例增加，但一个密集的符号在像素不够时根本解不出来。日常的
码用 720p 就够了。

每一项设置读回来的都是设备确认过的，而不是你要求的：`setZoom` 返回它钳制到的倍率，
而在没有闪光灯的硬件上，无论设多少次 `torchEnabled` 都是 false。

### 对焦

`focusAt(x, y)` 把对焦和测光指向画面里的某一点，并返回设备是否接受了——在相机已关闭、
点落在画面之外，或者硬件根本没有可指的对焦（每一个浏览器都属于这一类）时返回 false。
两者都会在几秒后回到各自的连续模式，所以一个没人管的扫描器会自己继续对焦。

**坐标是预览的比例值，位于 `previewWidth` 和 `previewHeight` 描述的那个空间里——
也就是在屏幕要求的任何 `quarterTurns` 之前。** 因此一次点击必须沿着预览被绘制时
经过的同一套变换倒推回去：先撤销 fit，再撤销旋转。

```dart
// `tap` 是相对于预览所覆盖的那个盒子的局部坐标，`size` 是当前的 WxPreviewSize。
final scale = math.max(box.width / size.rotatedWidth,
                       box.height / size.rotatedHeight);
final dx = (box.width - size.rotatedWidth * scale) / 2;
final dy = (box.height - size.rotatedHeight * scale) / 2;
final rx = (tap.dx - dx) / (size.rotatedWidth * scale);
final ry = (tap.dy - dy) / (size.rotatedHeight * scale);
if (rx < 0 || rx > 1 || ry < 0 || ry > 1) return;  // 落在画面之外

// 撤销 RotatedBox 顺时针的四分之一圈。
final (x, y) = switch (size.quarterTurns) {
  1 => (ry, 1 - rx),
  2 => (1 - rx, 1 - ry),
  3 => (1 - ry, rx),
  _ => (rx, ry),
};
await controller.focusAt(x, y);
```

`ScanResult` 自己的坐标位于被扫描的那一帧里，而那一帧相对屏幕是正立的——同一个空间，
已经过了 fit 这一步——所以要对焦到帧里找到的某个码，只需要上面的后半段：把它的中心
除以 `ScanOutcome.width` 和 `height`，然后撤销旋转。

`example/lib/scan_page.dart` 两件事都做了：一件用于点击，一件用于自动对焦到那个
被看见却读不出来的码上。

## 实践建议

**跟随应用的生命周期。** 在后台扫描既耗电又产出没人看的帧：

```dart
@override
void didChangeAppLifecycleState(AppLifecycleState state) {
  controller.setScanning(state == AppLifecycleState.resumed);
}
```

**暂停用 `setScanning(false)`，不要用 `dispose()`。** 它停止解码，同时让相机和预览
继续运行，那正是一个结果面板或者一个新推入的页面想要的。`dispose()` 是给离开页面
用的，而每一个 initialize 过的 controller 都必须被释放——设备只有一个相机会话，一个
活得比它的页面还久的 controller 会把它扣着，不让下一个用。

**把 `hasUndecodable` 当成「再靠近点」，而不是失败。** 一个没有结果的候选意味着
检测器找到了一个解码器读不出来的符号——几乎总是因为它在画面里太小，或者太虚。有两件
事有帮助，而且它们各自独立起作用：

- *变焦，但要渐进。* 根据候选占据画面的比例算出一个目标值，然后小步走过去，而不是
  一次调到位。倍率的跳变会把用户本来端稳的那个码甩出画面，读起来像是扫描器在瞎猜。
  另外要注意相机只围绕画面中心变焦，别无他法，所以靠近边缘的码没多少余量，一放大
  就出去了——这时候不如等手挪过来。
- *对焦到它上面。* 一个小的码通常也是虚的，它待在画面里某个位置，而偏重中心的连续
  对焦正把它背后的墙对得很清楚。对候选的中心调一次 `focusAt` 往往就是全部的差别，
  而且它对那些偏离中心太远、没法靠变焦够到的码同样有效。

这两者需要的耐心不同。**变焦**要等好几帧取得一致：在一次误检上就动手会把画面甩得
到处乱跑，把用户正在瞄的东西弄丢。**对焦**可以在第一帧就动手——最坏的情况是镜头移到
一个什么都没有的地方，下一帧就会纠正，而且这期间不付出任何代价；相反，等待只会推迟
它本来就能促成的那次成功读取。

**在让用户挑选之前先冻结画面。** 当一帧解出多个码时，那些标记属于**那一帧**；预览
还在跑的话，画面会随着手的每一次抖动在标记底下移动，用户永远点不准。`grabFrame()`
返回的正是那一帧的 JPEG——把它覆在预览上，配合 `setScanning(false)`，标记就自动对齐
了。

**在测试里替换掉相机。** 每一次调用都走 `WxScanPlatform.instance`；把一个子类赋给
它，整个原生侧就被替换掉了，于是 widget 测试可以在没有设备的情况下驱动扫描结果、
旋转和变焦钳制。

## 模型

TFLite 权重传给 `initialize`，通常来自一个 asset。插件把它们加载进一个它自己拥有的
扫描器里，在原生侧完成，因为这条路径从不经过 Dart。不传它们，或者传进去的权重加载
失败，都会**退回**到没有 CNN 阶段的解码，而不是失败——
`controller.value.modelsLoaded` 报告当前处于哪种模式。

### 共用一个扫描器

一个既要实时扫、又要扫相册的应用，否则会持有两个扫描器：内存里两份 CNN 权重，以及
两套阈值——只要调过其中一套，它们就开始各走各的。把你已经有的那个扫描器借给相机，
自始至终就只有一个：

```dart
final scanner = await WxScanner.create(detectModel: detect, srModel: sr);

final controller = WxScanController(scanner: scanner);
await controller.initialize();          // 不传权重：它用借来的那个

final fromLibrary = await scanner.scanImage(bytes);   // 同一个扫描器
```

相机会对借来的扫描器持有它自己的一份引用，并在关闭时还回去，所以两边可以按任意顺序
释放——扫描器在最后一个放手的人放手时才消失。它们之间传递的句柄是一个数字，原生库
在自己的一张表里查它，而不是一个地址，所以即便是一个陈旧的句柄——热重启留下的正是
这种——也会被拒绝，而不是被跟随。

在 web 上这一节不改变任何事：那里的扫描器是一个通过消息访问的 worker，本来就不存在
需要避免的第二份拷贝。

## 浏览器

`getUserMedia` 打开相机，一个 `<video>` 播放它，每一帧通过 canvas 读出来送给扫描器，
而扫描器跑在一个 worker 里，这样解码不会卡住页面。每个方法都和在手机上一样；不同
之处在于：

- 预览是平台视图而不是纹理，所以用
  [`WxScanPreview`](lib/src/preview.dart) 而不是 `Texture` 去组合它。它在每个平台上
  都是同一个 widget，并且严格地替代 `Texture`——以设备的自然方向正立，由包着它的东西
  负责旋转和定尺寸。
- 帧在这里会跨进 Dart，而原生上从不。一帧 1080p 要付出一次 canvas 读取和一次到
  worker 的传输，这就是 web 上的扫描速率紧跟帧尺寸的原因。
- 闪光灯和变焦是 `MediaStreamTrack` 的约束项。各家浏览器支持得参差不齐，所以
  `hasTorch` 和 `zoomRange` 报告的是这条轨道实际声称的东西——在桌面上通常什么都没有。
- **一个离开页面的 `<video>` 会被浏览器暂停，而且放回去之后仍然是暂停的。** 这是
  HTML 规范对「从文档中移除的媒体元素」的规定，Chromium 执行它而 WebKit 不执行——
  这就是为什么一个在 Chrome 上（桌面和 Android 都是）冻结在第一帧的预览，在 Safari
  里却好好的。任何在宿主之间搬动预览元素的代码，挂上之后都必须重新 `play()`，并且
  绝不能把它停放在一个已经被平台视图从页面里摘走的宿主里。这两点都在
  [`platform_web.dart`](lib/src/web/platform_web.dart) 里处理了；这条记在这里，是
  因为从外面看它表现为「相机打开了、送出一帧就不动了」，而轨道是活的、元素在页面上、
  控制台一片干净。
- `wxscan` 在 web 上需要的那四个文件必须由应用来提供：`dart run wxscan:fetch_web`
  会把它们放好，其中编译产物从那个包钉死的 release 获取。什么都不用构建——
  [wxscan 的 README](../wxscan/README.zh-CN.md#自己构建扫描器)
  讲了怎么自己构建，以及为什么它们不以编译好的形式分发。它们放在 `web/wxscan/`，
  在那里会被自动找到，不需要配置。

## 平台

| 平台 | 相机 |
|---|---|
| Android | CameraX，API 24+ |
| iOS | AVFoundation，13.0+ |
| macOS | AVFoundation，10.15+ |
| Web | `getUserMedia`；见[浏览器](#浏览器) |

## 原生库

这里不构建任何原生代码。扫描器来自
[`wxscan`](https://github.com/wilinz/wxscan/tree/main/packages/wxscan)，由它的构建
钩子产出为一个 Dart code asset。本包依赖那个包，所以一个应用不论用了哪一个，拿到的
都正好是一份拷贝。

Swift 和 Kotlin 代码直接调用扫描器的 C ABI，因为相机帧从不经过 Dart。code asset 是
由 Dart 运行时加载的，而不是由 Xcode 或 Gradle 链接的，所以那些入口点是在运行时解析
的：Android 上 Flutter 把这个 asset 放进 APK 的 `lib/<abi>/`，那正是
`System.loadLibrary` 会去找的地方；iOS 和 macOS 上 `WxScanNative.swift` 打开打包好的
framework，用 `dlsym` 读出符号。

## 许可

Apache-2.0。Rust 源码在
[wxscan-rs](https://github.com/wilinz/wxscan-rs)。

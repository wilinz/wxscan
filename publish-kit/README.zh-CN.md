# wxscan publish-kit

[English](README.md) · **简体中文**

wxscan 的发布驱动器。从 [wilinz/froom](https://github.com/wilinz/froom/tree/develop/publish-kit)
的 publish-kit 移植过来，那套是把一个仓库里的四个包发到 pub.dev。

wxscan 要把**四个仓库里的八个目标发到两个注册表**，所以沿用下来的只是形状——按顺序
发布、每步之间等注册表、已经上去的跳过——其余都重写了。

## 跟 froom 那套的区别

| | froom | 这里 |
|---|---|---|
| 注册表 | pub.dev | crates.io **和** pub.dev |
| 仓库 | 一个 | 四个（见下） |
| 发布顺序 | 硬编码在 `publishOrder` | 数据，放在 `lib/src/plan.dart` |
| 「是不是已经发过了」 | `dart pub publish --dry-run` 然后 grep stderr | 注册表的 HTTP API |
| 回到开发模式 | 无 | `restore-dev` |
| 分支 | 建发布分支、合并、打 tag、强制切换 | 不管 |

其中三条值得展开。

**用注册表 API，不 grep dry run。** froom 那套判断「是不是已经发过了」，办法是把整个
包打一遍，再去 stderr 里找 `already exists`。这既慢，又分不清「已经发过」和「打包本身
坏了」——两者退出码都非零。两个注册表都能直接回答：
`crates.io/api/v1/crates/<name>/<version>` 和
`pub.dev/api/packages/<name>/versions/<version>`，200 或者 404。而注册表**连不上**的
时候这套工具会停，不去猜——把一次服务中断当成「还没发布」，接下来就是一次重复上传。

**不管分支。** froom 那套会建发布分支、合并到 main、打 tag、推送，还在等待循环里重新
`git checkout`，防着用户中途切分支。两个连 commit 都还没有的仓库，是这套逻辑能遇到的
最糟的输入。git 的事手工做。

**没有 `all`。** froom 那套有。这条链跨两个注册表，而且版本一旦上去就撤不回来——crate
的版本即使 yank 了也是永久的。每一步都得有意识地去跑。

## 这几个仓库

按每块**干什么用**来分，不按它产出什么：

| 仓库 | 装什么 | 微信专有？ |
|---|---|---|
| `cvlite` | OpenCV imgproc 的移植，零依赖 | 否 |
| `wxing` | ZXing 的分支，二维码解码 | 否 |
| `wxscan-rs` | `wxscan`、`-tflite`、`-ffi` | 是 |
| `wxscan` | `wxscan`、`wxscan_live`（Dart） | 是 |

`wxscan-rs` 那三个 crate 是同一件事的三个面——后端、编排、C ABI——必须同版本一起发，
所以留在一个 workspace 里。权重一个都没在里面，它们在
[wxscan-weights](https://github.com/wilinz/wxscan-weights)：注册表不适合给两兆字节做
版本管理，何况多数调用方本来就有。那两个通用 crate 谁都用得上，能独立存在。

五个 checkout 加上 `wxscan-dev`，并排放在同一个父目录下。这套工具从运行位置往上走，
找到那个父目录。

## 顺序

```
crate:cvlite → crate:wxing → crate:wxscan-tflite
             → crate:wxscan → crate:wxscan-ffi
             → pub:wxscan → pub:wxscan_live
```

这不是偏好。`packages/wxscan/rust` 依赖 `wxscan-ffi` 和 `wxscan` crate，再往下还有
`cvlite` 和 `wxing`。从 pub.dev 装的人没有这些 checkout，所以五个 crate 全上 crates.io、
依赖从路径改成版本号之前，构建钩子跑不起来。

## 版本号

每个仓库一个 `version.txt`，一共四个，不是一个共享文件。当初拆仓库就是为了让它们能各
走各的，一个共享号码等于原样退回去。`update-version` 还会把每个号码带进其它仓库对它
写的每一处约束里。

## 跨仓库开发

每个仓库提交的都是对兄弟仓库的**版本**依赖，那是唯一能从注册表装的形式。
`wxscan-dev/link.sh` 会写一份被 gitignore 的路径覆盖，让本地 checkout 之间还能互相
编译。细节看那个仓库的 README。Dart 包是唯一的例外，由这里的 `release-deps` 和
`restore-dev` 处理。

## 命令

```bash
cd publish-kit && dart pub get

dart run publish_kit check           # 报告阻塞项，什么都不改
dart run publish_kit update-version  # version.txt -> 各清单文件
dart run publish_kit release-deps    # wxscan/rust -> crates.io 版本号
dart run publish_kit publish         # 按顺序发布所有还没上去的
dart run publish_kit restore-dev     # wxscan/rust -> 路径依赖
```

每条都能加 `--dry-run`。`wxscan-rs` 还没有 commit 之前，cargo 需要 `--allow-dirty`。
`--only crate:cvlite` 可以只发一个目标。

`publish` 可以重跑：注册表上已有的会跳过，所以中断的链是接着走，不是从头来。

## 完整发布一次

```bash
dart run publish_kit check
dart run publish_kit update-version
# 手工提交、打 tag、推送两个仓库
dart run publish_kit publish --allow-dirty --only crate:cvlite \
  --only crate:wxing --only crate:wxscan-tflite \
  --only crate:wxscan --only crate:wxscan-ffi
dart run publish_kit release-deps
dart run publish_kit publish          # 那两个 pub 包
dart run publish_kit restore-dev      # ← 别跳过
```

**`restore-dev` 不是可选的。** 依赖一旦是版本号，本地对 Rust 源码的改动 Flutter 构建
就看不见了。把发布模式的清单留在那儿，开发会静默地坏掉，直到有人想明白自己改的 Rust
为什么不生效。

## 有意不做的

- **`packages/wxscan_live/pubspec.yaml` 里的 `dependency_overrides`** 保留。它把
  `wxscan` 指回这个 checkout，供开发用。使用方完全会忽略 overrides，所以带着它发布只
  多一条 pub 提示，别的没有——比每次发布都要剥掉再还原一段注释块的开关便宜。
- **CHANGELOG 同步。** froom 那套会把根 CHANGELOG 的条目复制进每个包，没有条目就拒绝
  运行。wxscan 这两个仓库都没有根 CHANGELOG，而那两个 Dart 包记的本来就是不同的事。
- **README 复制。** froom 是一个 README 覆盖四个包；这里的 crate 和插件记录的是不同的
  对外表面。

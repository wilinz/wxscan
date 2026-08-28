# wxscan publish-kit

[English](README.md) · **简体中文**

wxscan 的发布驱动器。移植自 [wilinz/froom](https://github.com/wilinz/froom/tree/develop/publish-kit)
的 publish-kit，那个是把一个仓库里的四个包发布到 pub.dev。

wxscan 要**把四个仓库里的八个目标发布到两个注册表**，所以沿用下来的是它的形状——
有序发布、每步之间等注册表、跳过已经上去的——其余都是新写的。

## 相对 froom 那套改了什么

| | froom | 这里 |
|---|---|---|
| 注册表 | pub.dev | crates.io **和** pub.dev |
| 仓库 | 一个 | 四个（见下） |
| 发布顺序 | 硬编码在 `publishOrder` 里 | 数据，在 `lib/src/plan.dart` 里 |
| 「是否已发布？」 | `dart pub publish --dry-run` + grep stderr | 注册表的 HTTP API |
| 回到开发模式 | — | `restore-dev` |
| 分支处理 | 创建发布分支、合并、打 tag、强制切换 | 不做 |

其中三条值得展开说。

**用注册表 API，而不是 grep 一次 dry run。** froom 那套回答「这个是不是已经发布了？」
的办法是把整个包打一遍，然后在 stderr 里找 `already exists`。那既慢，又分不清
「已经发布」和「打包本身坏了」——两者的退出码都非零。两个注册表都能直接回答：
`crates.io/api/v1/crates/<name>/<version>` 和
`pub.dev/api/packages/<name>/versions/<version>`，200 或者 404。而当注册表**访问不到**
时，这套工具会停下来而不是去猜，因为把一次服务中断读成「还没发布」意味着会尝试一次
重复上传。

**不管分支。** froom 那套会创建发布分支、合并到 main、打 tag、推送，还会在等待循环里
重新 `git checkout` 以纠正用户切换分支的情况。两个连一个 commit 都还没有的仓库，是
那套逻辑能拿到的最糟糕的输入。git 的事手工来做。

**没有 `all`。** froom 那套有。这条链跨越两个注册表，而且一个版本一旦上去就撤不回来
——一个已发布的 crate 版本即使被 yank 也是永久的。每一步都要有意识地去跑。

## 这些仓库

划分依据是每一块**是干什么用的**，而不是它产出什么产物：

| 仓库 | 装着 | 是否微信专有？ |
|---|---|---|
| `cvlite` | OpenCV imgproc 的移植，零依赖 | 否 |
| `wxing` | ZXing 的分支，二维码解码 | 否 |
| `wxscan-rs` | `wxscan`、`-tflite`、`-ffi` | 是 |
| `wxscan` | `wxscan`、`wxscan_live`（Dart） | 是 |

`wxscan-rs` 里那三个 crate 是同一件事的三个面——后端、编排、C ABI——必须以同一个版本
一起发布，所以它们留在同一个 workspace 里。权重不在它们中的任何一个里；它们在
[wxscan-weights](https://github.com/wilinz/wxscan-weights)，因为注册表不是给两兆字节
（而且多数调用方本来就已经有了）做版本管理的地方。那两个通用 crate 对任何人都有用，
可以独立存在。

五个 checkout 外加 `wxscan-dev`，并排放在同一个父目录下；这套工具从它被运行的位置
向上走来找到那个父目录。

## 顺序

```
crate:cvlite → crate:wxing → crate:wxscan-tflite
             → crate:wxscan → crate:wxscan-ffi
             → pub:wxscan → pub:wxscan_live
```

这不是偏好问题。`packages/wxscan/rust` 依赖 `wxscan-ffi` 和 `wxscan` crate，并间接
依赖 `cvlite` 和 `wxing`。从 pub.dev 安装的人没有那些 checkout，所以在五个 crate 全都
上了 crates.io、并且依赖从路径改成版本号之前，构建钩子跑不起来。

## 版本号

每个仓库一个 `version.txt`，一共四个，而不是一个共享文件。把仓库拆开的全部意义就是
能各自独立地演进；一个共享的版本号会把这一点原样退回去。`update-version` 还会把每个
号码带进其它仓库对它施加的每一处约束里。

## 跨仓库的本地开发

每个仓库提交的是对兄弟仓库的**版本**依赖——那是唯一能从注册表安装的形式。
`wxscan-dev/link.sh` 会写出被 gitignore 的路径覆盖，让本地 checkout 之间仍然能相互
构建。见那个仓库的 README；Dart 包是唯一的例外，由这里的 `release-deps` 和
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

任何一条都可以加 `--dry-run`。在 `wxscan-rs` 还没有 commit 之前，cargo 需要
`--allow-dirty`。`--only crate:cvlite` 把发布限制到一个目标。

`publish` 是可重跑的：注册表已经提供的东西会被跳过，所以一条中断的链是继续而不是
重来。

## 完整的一次发布

```bash
dart run publish_kit check
dart run publish_kit update-version
# 手工提交、打 tag、推送两个仓库
dart run publish_kit publish --allow-dirty --only crate:cvlite \
  --only crate:wxing --only crate:wxscan-tflite \
  --only crate:wxscan --only crate:wxscan-ffi
dart run publish_kit release-deps
dart run publish_kit publish          # 那两个 pub 包
dart run publish_kit restore-dev      # ← 不要跳过
```

**`restore-dev` 不是可选的。** 在版本依赖之下，对 Rust 源码的本地修改对 Flutter 构建
是不可见的。把一份发布模式的清单文件留在那里，会静默地破坏开发，直到有人想明白为什么
自己改的 Rust 不再生效。

## 有意不处理的

- **`packages/wxscan_live/pubspec.yaml` 里的 `dependency_overrides`** 保持原样。它把
  `wxscan` 指回这个 checkout，供开发用。使用方完全会忽略 overrides，所以带着它发布
  只会多一条 pub 提示，别无代价——比在每次发布时都要剥掉又还原一段注释块的开关要
  便宜。
- **CHANGELOG 同步。** froom 那套会把根 CHANGELOG 的条目复制进每个包，而且没有条目
  就拒绝运行。wxscan 的两个仓库都没有根 CHANGELOG，而那两个 Dart 包记录的是不同的
  东西。
- **README 复制。** froom 是一个 README 覆盖四个包；这里的 crate 和插件记录的是不同
  的对外表面。

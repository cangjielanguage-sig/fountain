# fountain::f_app API 参考

> 本文档基于 `f_app` 模块当前源码整理：版本以 `f_app/cjpm.toml` 为准（当前 `1.3.7`，与 `f_version/src/FountainVersion.cj` 同步），输出类型 `dynamic`。
> 依赖包：`f_base`、`f_concurrent`、`f_data`、`f_log`、`f_random`、`f_version`，以及 `std.env` / `std.fs` / `std.process` / `std.regex` / `std.random` / `stdx.net.http` / `stdx.net.tls`（`pub` 查询制品仓库与随机串使用）。
> 全部类型都在唯一包 `fountain::f_app` 下（没有 `f_app.SubCommand` 这样的子包）。

## 目录

1. [快速开始](#1-快速开始)
2. [`App`：应用启动器](#2-app应用启动器)
3. [内置子命令参考](#3-内置子命令参考)
4. [自定义子命令](#4-自定义子命令)
5. [应用初始化](#5-应用初始化)
6. [`pub`：批量发布模块](#6-pub批量发布模块)
7. [其它公开类型](#7-其它公开类型)
8. [内部实现](#8-内部实现)

---

## 1. 快速开始

```cangjie
import fountain::f_app.*

main(args: Array<String>): Int64 {
    App(args, dynamic: true).boot()
}
```

`fboot` 自身的入口（`fboot/src/main.cj`）就是这么写的。

## 2. `App`：应用启动器

```cangjie
public struct App {
    public App(
        private let args: Array<String>,                 // 命令行实参，args[0] 是子命令名
        private let appHomeIsWorkingPath!: Bool = true,  // 当前源码中尚未参与任何逻辑
        private let dynamic!: Bool = true,               // 是否扫描目录并加载其中的动态库（见第 4 节）
        private let name!: String = ''                   // 覆盖启动横幅与应用名
    ) {}

    public func boot(): Int64                            // 按 args[0] 分发
    public static func start(args: Array<String>): Int64 // 等价于 App(['run', ...args]).boot()
}
```

分发规则：先匹配内置子命令（`run` / `shutdown` / `restart` / `module` / `workspace` / `cleanUpdate` / `build` / `test` / `count` / `version` / `help`），未匹配则交给 `SubCommandMediator.exec(args[0], args[1..])`（见第 4 节）。

**只有 `run` / `restart` / `test` 与「未命中任何命令」这条路径才会走 `load()`**（扫描并加载动态库 →
`InitializerCollection.initialize()` → 注册退出回调）；`shutdown` / `version` / `help` / `count` / `build` 等
既不扫描也不初始化。`InitializerCollection.initialize()` 是一次性的（结束时会把自己置空）。

```cangjie
// 使用自己的 main 函数启动应用（会自动补上 run 子命令）
main(args: Array<String>): Int64 {
    App.start(args)
}
```

`App.start(args)` 传入的实参形如 `--dylibPattern='<dylib_name_regex_to_load>'`（即以 `run` 子命令的口径给出）。

应用名与横幅：

* 应用名取 `name` 参数；未指定时按加载路径（`confirmTargetPath(args)` 的结果）推断——路径以 `/target/release` 结尾取项目目录名、以 `/release` 结尾取上一级目录名、否则取路径自身的目录名。
* `run` 启动时打印 `AppVersion.banner` + `'<应用名>(<版本>) started by <fountain 版本> in <耗时>'`；若当前目录存在非空的 `banner.txt`，`build` 阶段会把它作为 `AppVersion` 的横幅（见 3.6）。

## 3. 内置子命令参考

| 子命令 | 形式 | 行为 |
| --- | --- | --- |
| `run` | `fboot run [PATH] --dylibPattern=<正则>` | 加载 `PATH`（缺省当前目录）下匹配的动态库 → 初始化全部 `Initializer` → 打印启动横幅 → 各 `start()` 在新线程中 `spawn` → **永久阻塞**（`while(true){ sleep(Duration.Max) }`），所以该命令不会返回 |
| `shutdown` | `fboot shutdown <PID>` | `findProcess(pid).terminate()` 并轮询等待进程退出；被终止进程的 `atExit` 回调（各模块注册的收尾逻辑）随进程退出执行 |
| `restart` | `fboot restart <PID> [PATH] --dylibPattern=<正则>` | 先 `shutdown` 再 `run` |
| `module` | `fboot module [name]` | 在 `name` 目录（缺省当前目录）执行 `cjpm init --type=dynamic`；若目标目录是当前目录或当前目录的一层子目录，会把模块名加入**上一层目录**的 `cjpm.toml` `members`（该 `cjpm.toml` 必须已存在）；随后写入 `src/<模块名>.cj`（内容 `package <模块名>`） |
| `workspace` | `fboot workspace [dir]` | 在 `dir`（缺省当前目录）执行 `cjpm init --workspace`，并重写其 `cjpm.toml`：`[workspace] version = "1.0.0"`（固定值）、`f_base` / `f_version` 依赖取当前fboot的版本、把空的 `compile-option` 换成 `--dy-std -Woff all`，并补齐各平台 target 与 `path-option` 配置 |
| `cleanUpdate` | `fboot cleanUpdate [PATH]` | 打印命令后依次执行 `cjpm clean --target-dir=<...>`、删除 `cjpm.lock`、`cjpm update` |
| `build` | `fboot build [PATH] [args...]` | 见 3.6 |
| `test` | `fboot test [PATH] [args...] --dylibPattern=<正则>` | 用 `PATH/test/cjpm.toml` 覆盖 `PATH/cjpm.toml`，先 `build` 再用 `run` 启动；缺少 `--dylibPattern` 时抛 `BootException("arg --dylibPattern='...' in command line is required")` |
| `count` | `fboot count [PATH] [--ext=cj] [--ignoreBrackets] [--ignoreComments]` | 统计 modules（`*.toml`）、packages（路径含 `/src/` 的目录）、files、lines（默认按 `--ext=cj`，可忽略纯括号行与注释），并输出耗时 |
| `version` | `fboot version [x.y.z] [msg] [tag [tagmsg]]` | 见 3.7（用于管理 fountain 自身） |
| `help` | `fboot help` | 打印帮助文本（内置命令的说明文本硬编码在 `App.cj`，与本节略有出入：不含 `test`，`module` 一条写的是"当前目录"而实际改的是上一层目录） |
| `pub` | `fboot pub <x.y.z> [--skip-lint] [--skip-test]` | 由 `PublishCommand` 注册的子命令，见第 6 节 |
| `randhex` | `fboot randhex <n>` | 由 `RandHexCommand` 注册：打印 `n` 位随机小写 16 进制串（`RandomString().randomLowerHex(n)`） |

### 3.6 `build` 细节

* `[PATH]` 必须是 `build` 后的第一个参数且只能是路径本身；缺省为当前目录。
* 其余参数分两类：`--key=value` 形式会被转成传给 `cjpm build` 子进程的**环境变量**（与当前进程环境合并后传入），其它参数原样作为 `cjpm build` 的命令行参数。
* 构建前会在项目目录下临时生成版本模块 `<模块名>_stAtIc__`（模块名中的 `.`、`-` 替换为 `_`）：写入 `src/<模块名>_AppVersion.cj`，内容为 `AppVersion.set(<banner>, <name>, <version>)`，并把该模块临时加进 workspace 的 `members`；进程退出（`atExit`）时恢复原 `cjpm.toml` 并删除该临时模块。
* 最终执行的是 `cjpm build --target-dir=<targetDir> <其它参数>`（`targetDir` 由 `PATH` 与工作目录推导）。

### 3.7 `version` 细节

仅用于管理 fountain 自身（要求可免密操作 git）：

* `fboot version`：打印 `FountainVersion`（`f_version` 模块）。
* `fboot version x.y.z [msg] [tag [tagmsg]]`：`git pull` → 递归改写工作目录下所有 `cjpm.toml` 的 `version` 为 `x.y.z`，同时把 `cjc-version` 更新为 `cjc -v` 报出的版本 → 若工作目录属于 `fountain` / `fboot` 项目，替换 `f_version/src/FountainVersion.cj` 中的 `fountain(x.y.z)` 与 `release-x.y.z` → `git add .` → `git commit`（`msg` 缺省时为 `Some codes were changed, version: x.y.z`）→ 只要出现 `tag` 参数就执行 `git tag -a release-x.y.z -m <提交信息>`（额外的 `tagmsg` 只会被拼成附加行，用户给的 `tagmsg` 实际未被直接使用）→ `git push` 与 `git push origin release-x.y.z`。
* 版本号不匹配 `x.y.z` 时只打印提示，不执行任何操作。

## 4. 自定义子命令

```cangjie
package fountain::f_app

public interface SubCommand {
    /**
     * 子命令名，即 fboot <subcommand>
     */
    prop command: String
    /**
     * 执行；args 是去掉子命令名之后的命令行实参
     */
    func exec(args: Array<String>): Int64
}

public struct SubCommandMediator {
    /**
     * 注册子命令（建议在实现类型的 static init() 中调用）
     */
    public static func register(command: SubCommand): Unit
    public static func exec(command: String, args: Array<String>): Int64
}
```

`SubCommandMediator.exec` 的执行链路：

1. 命中已注册命令 → 直接执行；
2. 未命中 → 调用 `load(args, true)`：扫描目录、加载匹配的动态库（匹配规则见第 8 节），动态库的 `static init` 会完成 `SubCommandMediator.register`，然后**重试**一次；
3. 仍未命中 → 抛 `BootException`，消息中列出内置命令与已注册的命令名。

### 参考实现

把子命令编译成动态链接库，把库放到某个目录，然后在该目录执行：

```
fboot <子命令名> [PATH] --dylibPattern='<dylib_name_regex_to_load>'
```

```cangjie
package org::module.pkg

import fountain::f_app.{SubCommand, SubCommandMediator}

public struct NewSubCommand <: SubCommand {
    static init() {
        SubCommandMediator.register(NewSubCommand())
    }
    public prop command: String {
        get() {
            'newcmd'
        }
    }
    public func exec(args: Array<String>): Int64 {
        // do something
        0
    }
}
```

`dynamic` 为 `false`（`App(..., dynamic: false)`）时不进行动态库扫描，此时只有内置命令与随进程静态链接进来的子命令可用。

## 5. 应用初始化

```cangjie
/**
 * 应用初始化API。应用代码通常不需要实现本接口。
 */
public interface Initializer {
    /**
     * 待初始化的功能名称
     * 有些功能只能显式地调用函数完成初始化，fountain::f_bean fountain::f_mvc fountain::f_orm fountain::f_ticktock都是这类
     */
    prop name: String
    /**
     * 依赖项，必须在这些功能初始化后才能初始化当前功能
     */
    prop dependencies: Array<String> {
        get() {
            []
        }
    }
    /**
     * 调用本函数实现完成初始化
     */
    func initialize(): Unit
    /**
     * 返回启动函数，调用返回的函数是否阻塞取决于具体实现，比如调用mvc的启动函数会启动http服务并一直阻塞。
     * 因此不同模块或功能的启动函数不应有依赖关系，否则如果有两个start实现是阻塞的，就无法顺利完成初始化了。
     */
    func start(): Unit {}
}
```

```cangjie
public struct InitializerCollection {
    /**
     * 注册模块的初始化函数。通常应用APP不需要调用它。
     */
    public static func register(initializer: Initializer): Unit
    // initialize() 为包内函数，由 App 在加载阶段调用，返回收集到的全部 start 函数
}
```

行为说明：

* `register` 线程安全（内部 `Mutex`）；登记时会记录 `dependencies` 的“被依赖”关系。
* 初始化顺序：只要某个 `Initializer` 的 `dependencies` 里**还存在未完成初始化的模块**，就把它放回队列等待，因此依赖链会自动拓扑排序；`initialize()` 完成后收集其 `start()`。
* 收集到的 `start()` 由 `App.run()` 逐个 `spawn` 到新线程执行，随后主线程进入永久阻塞；`start()` 是否阻塞由各模块自行决定。
* 其它模块的惯用做法：定义 `<模块名>Initializer <: Initializer`，在 `static init()` 中调用 `InitializerCollection.register(...)`（例如 `f_bean` 的 `BeanInitializer`、`f_mvc` 的 `MVCInitializer`、`f_orm` 的 `ORMInitializer`）。动态库在 `run` 阶段被加载时，这些 `static init()` 会自动执行完成注册，应用代码通常无需手工调用。
* `f_version` 模块的 `AppVersion`（由 `build` 生成 `<模块名>_stAtIc__` 携带）提供启动横幅与应用版本，属于同一套“加载即生效”的机制。

## 6. `pub`：批量发布模块

```
fboot pub <x.y.z> [--skip-test] [--skip-lint]
```

* 由 `PublishCommand` 实现（`f_app` 自身的 `SubCommand`，因为 `fboot` 依赖 `f_app`，执行它不需要额外加载动态库）。
* 第一个位置必须是版本号且形如 `x.y.z`，否则抛异常；紧随其后的参数若以 `--` 开头（如 `--skip-test`、`--skip-lint`），会原样作为 `cjpm bundle` 的参数（即执行 `cjpm bundle --skip-test --skip-lint`），否则只执行 `cjpm bundle`。
* 一次连续发布多个模块时，可在项目根目录放 `.modules` 文件选择范围：

```
[include]
# 后面一个模块名一行，
# 如果当前目录也是一个要发布的模块，用.指代
# 开头的行是注释

[exclude]
# 这是忽略的模块，[include] [exclude]只能指定一个

[detention]
# 这里的模块不发布，只是临时保留，未开发完成的模块名可放在此处，以免将来开发完成了忘记添加到include或exclude
```

* `[include]` 与 `[exclude]` **不能同时指定**（否则抛异常）；也可以两者都不写（发布遍历到的全部模块）。空行与 `#` 开头的行会被忽略。
* 校验：`[include]` 中的模块必须存在于工作目录的模块树中；若待发布模块依赖了同项目内**未包含在发布范围内**的模块，会抛异常提示；模块自依赖也会抛异常。
* 发布顺序：按模块间依赖自动排序——只要还有“同项目内、且尚未发布完成”的被依赖模块，就把当前模块放回队列等待。
* 每个模块的发布步骤：
  1. `checkPublished(..., once: true)` 先探测制品仓库是否已存在该版本，存在则跳过实际发布（`https://pkg.cangjie-lang.cn/v1/artifact/getPackageMetadata?...`）；
     注意探测失败（响应解析异常、body 为空）会被**吞掉并返回「未发布」**、按退避无限重试；`once=true` 也不会因失败而返回 false；
  2. 改写其 `cjpm.toml` 的 `version` 为发布版本、把同项目的 `path` / `git` 依赖改写成 `"x.y.z"`，
     然后才把当前内容备份为 `cjpm.toml.bak`（发布结束在 `finally` 中还原 ⇒ **还原回来的 `version` 仍是发布版本**）；
  3. `cjpm clean` → 删除 `cjpm.lock` → `cjpm bundle ...` → `cjpm publish`；
  4. 若该模块被其它模块依赖，则以斐波那契退避轮询仓库，直到该版本可被安装，
     再由 `checkPublished` 内部执行 `cjpm install <organization>::<module>-<version>`；
  5. 各步骤的成败靠抓子进程 stdout 的固定行（如 `cjpm clean success`）判断，**不看退出码**；任一步失败会打印堆栈并重试整段流程。
* 结束时打印 `publish completed in <耗时>`。

## 7. 其它公开类型

| 类型 | 说明 |
| --- | --- |
| `BootException <: Exception` | `init(message: String)`；用于子命令未知、`test` 缺少 `--dylibPattern` 等场景 |
| `ModuleInfo` | `pub` 的模块元信息：`public var dependenced: Int64`（被依赖次数）、`public var organization: String = 'default'`、`public let dependencing = ArrayList<String>()`（依赖的模块列表） |
| `PublishCommand <: SubCommand` | `pub` 子命令实现，`command = 'pub'`，由 `static init()` 注册 |
| `RandHexCommand <: SubCommand` | `randhex` 子命令实现，`command = 'randhex'`，由 `static init()` 注册 |

## 8. 内部实现

以下符号为包内可见（internal），列在这里便于排查问题：

| 符号 | 说明 |
| --- | --- |
| `internal func load(args: Array<String>, dynamic: Bool): (Path, ArrayList<() -> Unit>)` | 确定目标路径（`confirmTargetPath`）→ 按平台选扩展名（Windows `.dll` / macOS `.dylib` / 其它 `.so`；库搜索路径变量并未实际设置）→ `dynamic` 为真时递归扫描并 `PackageInfo.load` 文件名匹配 `^lib.*(<--dylibPattern 的值>\|.+_stAtIc__).*$` 的库 → 调用 `InitializerCollection.initialize()` → 注册 `ExitCallbacks.toExitGracefully()`。注意 `--dylibPattern` 的提取（`extractPattern`）是「取首个非 `--dylibPattern=` 参数的下一个下标」再切片 ⇒ 只有「正则紧跟第一个位置参数」这种写法可用，缺省 `PATH` 或不带位置参数时会下标越界 |
| `internal const APP_STATIC_RESOURCE_SUFFIX = '_stAtIc__'` | 版本模块的固定后缀，`build` 阶段生成的 `<模块名>_stAtIc__` 会随主库一起被加载，用于携带 `AppVersion` |
| `internal func confirmTargetPath(args: Array<String>): Path` | `args[1]` 不以 `-` 开头时视为路径（不存在则创建），否则用当前工作目录；返回规范化后的绝对路径 |
| `internal let log` | `LoggerFactory.getLogger<App>()` |

> 本文档未覆盖的行为以 `f_app/src/**/*.cj` 为准；`f_app/doc/*.md` 是按主题拆分的旧版摘录（`导入.md`、`子命令.md`、`应用初始化.md`、`应用初始化函数的集合.md`）。

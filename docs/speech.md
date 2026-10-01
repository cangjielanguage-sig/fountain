# fountain 讲稿

## 一站式服务器应用开发工具库

> 配套项目：`fdemo`（仓库内的示例工程，本讲稿所有命令都以它为蓝本）
> 目标：讲清楚「为什么用 fountain」「怎么用 fboot」「IOC / MVC / AOP / ORM 怎么用」，并且全程可以一边讲一边敲命令、一边看输出。
> 建议录制时长：约 75～90 分钟（可按章节裁剪）

---

## 0. 这份讲稿怎么用

每一节的格式统一为：

| 标记 | 含义 |
| --- | --- |
| **【口播】** | 直接念或改写的台词 |
| **【命令】** | 现场要敲的命令，可直接复制 |
| **【预期】** | 屏幕上应该出现什么，用来判断这步有没有翻车 |
| **【镜头】** | 建议切到的画面（终端 / IDE / 浏览器 / 架构图） |

录制前的准备清单（开录前务必确认一遍）：

```bash
# 1. 仓颉 SDK + stdx 就位
cjc -v
echo $CANGJIE_STDX_DYNAMIC_PATH

# 2. 装好 fboot，并把 bin 与动态链接库路径加入环境
cjpm install "fountain::fboot"="<版本号>" --root ~/.cjpm
export PATH=$PATH:~/.cjpm/bin
export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:~/.cjpm/libs/fboot

# 3. fboot 能跑起来
fboot version
```

> 如果 `fboot` 报找不到动态链接库，99% 是 `LD_LIBRARY_PATH` 没带上 `~/.cjpm/libs/fboot`。这个坑适合在视频里故意演一次再修，观众印象最深。

---

# 第一章 为什么使用 fountain

**【镜头】** 仓库根目录 `README.md` 的 ASCII LOGO，再切到模块列表。

## 1.1 先说痛点：写一个服务端应用，我们到底在重复什么

**【口播】**

> 我们写一个普通的后端服务，真正属于「业务」的代码其实很少。大量时间在重复这些事：
>
> 1. 谁来创建对象、谁来装配依赖——于是我们手搓工厂、手搓单例、手搓 `getInstance()`；
> 2. 每个接口都要做登录校验、权限校验、参数校验、异常处理、耗时统计——于是每个函数开头都是同样的十几行；
> 3. 每张表都要写一遍 `insert / update / select / page`——SQL 拼接、参数绑定、结果集到对象的映射，全是体力活；
> 4. 事务边界靠人肉保证——`try { commit } catch { rollback }` 复制粘贴，传播行为全靠约定；
> 5. 定时任务、JWT、连接池、日志、配置——每个项目都重新选型、重新封装一遍。
>
> 这些就是「非业务复杂度」。fountain 的目标很直接：**把这些全部收进工具库，让业务代码只剩下业务。**

## 1.2 fountain 是什么

**【口播】**

> fountain 是仓颉（Cangjie）生态里的一站式服务器应用开发工具库，由 40 多个模块组成。核心的那一层是：
>
> | 能力 | 模块 | 一句话 |
> | --- | --- | --- |
> | IOC 容器 | `f_bean` | `@Bean` + `lookup<T>()`，宏在编译期完成注册 |
> | AOP | `f_aspect` | `Aspect` 接口 + 织入规则，横切逻辑集中一处 |
> | MVC | `f_mvc` | `@Controller` + `@GetMapping`，HTTP 服务开箱即用 |
> | ORM | `f_orm` | DAO 就是接口，`@DAO` 以后 `SqlExecutor` 就是实现 |
> | 安全 | `f_security` | 登录状态、鉴权、权限检查的统一抽象 |
> | JWT | `f_jwt` | 完整的 JWT 编码 / 验签 API |
> | CRON | `f_ticktock` | `@Bean` + cron 表达式即可定时执行 |
> | 启动器 | `fboot` / `f_app` | 没有 `main` 也能启动应用 |
>
> 外围还有 `f_base` `f_util` `f_collection` `f_concurrent` `f_log` `f_data` `f_http` `f_net` `f_pool` `f_crypto` `f_store` `f_rpc` `f_llm`……它们既能被框架使用，也能单独当作工具库引入。
>
> 引用方式有两种，等价：
> ```toml
> [dependencies]
> "fountain::f_orm" = "a.b.c"
> ```
> 对应的包是 `fountain::f_orm.*`，也可以用聚合包 `fountain::fountain.orm.*`。

## 1.3 三个「反直觉」的设计决策（这是 fountain 的灵魂，建议重点讲）

### 决策一：应用项目没有 `main` 函数

**【口播】**

> 用 fountain 开发，你的代码里**不需要写 `main`**。项目初始化成 workspace，每个模块编译成**动态链接库**，然后由 `fboot` 加载这些动态链接库完成启动。
>
> 带来的好处是：
> - **装配发生在运行期**——加一个功能，就是把一个动态链接库放进目录；不要它，就从加载名单里去掉。这是真正的插件化；
> - **启动由框架统一负责**——初始化顺序、依赖拓扑、退出回调，都由 `f_app` 的 `Initializer` 机制统一处理；
> - **业务代码只剩业务**——没有启动样板，没有手写容器初始化。

### 决策二：编译期宏 + 运行期反射，而不是 XML / 注解扫描配置

**【口播】**

> `@Bean`、`@Controller`、`@DAO`、`@QueryMappersGenerator`、`@ORMField`、`@DataAssist` 这些都是**仓颉宏**。它们在编译期就把注册代码、getter/setter、列映射、DAO 实现扩展全部生成好了。
>
> 所以你不会看到一堆配置文件，也不会有「启动扫包扫半天」。代价是：宏的用法必须遵守它的约定（比如 `@ORMField` 只能修饰 `public var` 或 `public mut prop`），这些约定编译期就会报错，不会拖到线上。

### 决策三：一切配置都是环境变量，运行期优先级高于编译期

**【口播】**

> fountain 没有自己的配置文件格式。端口、连接池、事务规则、日志格式、数据库连接串——全部是环境变量。
>
> 好处是容器化/Docker/K8s 天然适配；更妙的是 `fboot build` 支持把SM4 加密KEY/IV、数据库连接URL、数据库的用户名密码以`--key=value` 命令行参数的形式或者环境变量的形式**在编译期注入到产物里**，而运行期同名环境变量会**覆盖**它。
所以你可以：
> - 做到运行环境敏感信息安全性
> - 运行期用环境变量覆盖，做到「一份产物、多环境部署」。

## 1.4 什么时候不该用 fountain

**【口播】**（这段能显著提升可信度）

> 坦白讲，fountain 不是万能的：
> - 它只支持仓颉语言，且当前主要面向 **Linux/macOS/Windows/OHOS** 的服务端场景；
> - IOC 只管理 **class**，不管理 `struct`（值类型反复复制会有性能损失，这是作者明确的取舍）；
> - 它依赖 stdx，需要配置 `CANGJIE_STDX_DYNAMIC_PATH`；
> - 宏的约定比较硬，第一次上手会有「为什么这么写才编译得过」的阶段。
>
> 如果你的项目只有几百行、只有一个接口，直接写 HTTP 服务可能更省事。fountain 的价值在**中大型、需要长期演进的服务端应用**。

---

# 第二章 上台准备：环境

**【镜头】** 终端

**【口播】** 先把环境说清楚，后面所有演示都建立在这上面。

**【命令】**

```bash
# 环境变量（建议写进 ~/.bashrc）
export CANGJIE_STDX_DYNAMIC_PATH=/path/to/dynamic_stdx
export CANGJIE_STDX_PATH=$CANGJIE_STDX_DYNAMIC_PATH
export FOUNTAIN_HOME=~/.cjpm/libs/fboot
export LD_LIBRARY_PATH=$FOUNTAIN_HOME:$LD_LIBRARY_PATH
export PATH=$PATH:~/.cjpm/bin

# 安装 fboot
cjpm install "fountain::fboot"="<版本号>" --root ~/.cjpm

# 验证
fboot version
```

**【预期】** 打印出当前 fountain 版本号，例如 `1.3.x`。

> 讲稿里所有 `<版本号>` 都要替换成实际版本。fountain 各模块版本一致，可在仓库 README 或 `f_version` 模块查看。

---

# 第三章 fboot 命令行

**【镜头】** 终端 + `fboot/src/main.cj`（就 20 行）

**【口播】**

> 先看一下 `fboot` 自己有多简单——整个 `fboot` 可执行程序的源码只有这么几行：
>
> ```cangjie
> package fountain::fboot
> import fountain::f_app.*
>
> main(args: Array<String>): Int64 {
>     App(args, dynamic: true).boot()
> }
> ```
>
> 也就是说，**fboot 只是 `f_app` 的一个壳**。所有子命令的实现都在 `fountain::f_app.App` 里。理解这一点很重要：你自己的应用也可以用同样的方式启动，甚至可以用 `SubCommandMediator` 注册自己的子命令。

## 3.1 `fboot help`

**【命令】**

```bash
fboot help
```

**【预期】**（`f_app/src/App.cj` 中 `help()` 打印的内容）

```
1.  应用项目只需要编译为动态链接库，把应用的动态链接库加入LD_LIBRARY_PATH
2.  fboot run [PATH] --dylibPattern=<DYNAMIC_LIB_NAME_REGEX_WITHOUT_EXTNAME>
3.  fboot shutdown <PID>
4.  fboot restart <PID> [PATH] --dylibPattern=<DYNAMIC_LIB_NAME_REGEX_WITHOUT_EXTNAME>
5.  fboot workspace <dir_path> 将当前目录初始化为仓颉workspace，
    - <dir_path>是要创建workspace的路径，可以是绝对路径或相对路径，缺省是当前工作路径
6.  fboot module 将当前目录初始化为仓颉dynamic项目
7.  fboot module <module_name> 在当前目录创建名为<module_name>的子目录，并初始化为仓颉dynamic模块，并把模块加入当前目录的cjpm.toml
8.  fboot cleanUpdate 其实是为当前仓颉项目执行了cjpm clean && rm ./cjpm.lock && cjpm update
9.  fboot build 编译使用fountain开发的应用项目
    - 如果要指定编译产物保存路径，必须是build后的第一个参数，这个参数只有路径本身
    - 其他参数将分为两类，--开头且包含=的参数作为cjpm build子进程的环境变量传入子进程，其他参数作为cjpm build的命令行参数
10. fboot count 数当前目录的仓颉代码模块数、包数、文件数、行数、计数耗时
11. fboot pub <version> 发布当前路径下的仓颉模块
12. fboot randhex n 生成n位随机16进制数，eg. fboot randhex 16
==============下面的命令用来管理fountain本身===================
13. fboot version x.y.z 用指定版本号替换cjpm.toml和App.cj的版本号，并提交且推送当前全部修改
    - fboot version x.y.z
    - fboot version x.y.z '提交的内容'，以指定内容执行git commit
    - fboot version x.y.z tag，除了替换版本号，还会用指定的版本号创建tag：release-x.y.z
    - fboot version x.y.z tag '版本消息'，除了替换版本号，还会以'版本消息'创建附注tag
    - fboot version x.y.z '提交的内容' tag
    - fboot version x.y.z '提交的内容' tag '版本消息'
14. fboot version 显示当前fountain版本号
15. fboot help 显示命令列表
```

**【口播】**

> 注意第 1 行，它是整个 fountain 世界的第一公理：**应用项目只需要编译成动态链接库**。后面所有命令都围绕这一条展开。
>
> 另外 `help` 里没列全的内置命令还有 `cleanUpdate`、`test`；`pub` 和 `randhex` 不是内置命令，而是 `f_app` 自己注册进 `SubCommandMediator` 的子命令实现——这个机制我们等下会展开。

## 3.2 `fboot workspace` —— 把目录变成仓颉 workspace

### 三种用法

```bash
# ① 把「当前目录」初始化为 workspace
fboot workspace

# ② 在当前目录下新建 <name> 子目录，并初始化为 workspace
fboot workspace fdemo

# ③ 指定（绝对/相对）路径，初始化为 workspace
fboot workspace /path/to/project

```

### 它到底做了什么

**【口播】**

> `fboot workspace` 底层做了两件事：
> 1. 在目标目录执行 `cjpm init --workspace`；
> 2. **重写 `cjpm.toml`**：把 `[workspace] version` 定为 `1.0.0`、写入 `f_base` / `f_version` 依赖、把空的 `compile-option` 换成 `--dy-std -Woff all`、补齐 Linux/macOS/Windows/OHOS 各平台的 `[target.*]` 与 `path-option`。
>
> 换句话说，**它替你写好了那 60 行跨平台配置**，你不用再手抄。

**【命令】**（现场演示，建议使用临时目录，讲完可删）

```bash
mkdir -p /tmp/fountain_live && cd /tmp/fountain_live
fboot workspace hello_app
cd hello_app
cat cjpm.toml
```

**【预期】** `cjpm.toml` 里已经有 `[workspace]`、`f_base` / `f_version` 依赖、`--dy-std -Woff all`、以及各平台 target 段。

> 台上一句话总结：**workspace 是「装模块的盒子」，每个模块都必须编译为动态链接库。**

## 3.3 `fboot module` —— 在 workspace 里加一个动态链接库模块

```bash
# 在 workspace 根目录执行：创建 hello 子模块并挂进 workspace
cd hello_app
fboot module hello
```

**【口播】**

> 它做三件事：
> 1. 在 `hello/` 执行 `cjpm init --type=dynamic`；
> 2. 把 `hello` 加进**上一层目录** `cjpm.toml` 的 `members`（所以必须在 workspace 根执行）；
> 3. 生成 `hello/src/hello.cj`，内容就是一行 `package hello`。
>
> 注意：**模块一定是 `dynamic`**。这是 fountain 「加载即生效」机制的前提。

**【命令】**（现场：从零到第一个接口）

```bash
cd /tmp/fountain_live/hello_app
fboot module hello
cat hello/cjpm.toml          # output-type = "dynamic"
grep -n 'members' cjpm.toml  # members 里出现了 "./hello"

cat > hello/src/HelloWordController.cj <<'EOF'
package hello

import fountain::f_mvc.*
import fountain::f_mvc.macros.*

@Controller
public class HelloWordController {
    @GetMapping[path:"/", produces:'text/plain']
    @IgnoreSecurity
    public func helloWorld(): String {
        return "hello Fountain!"
    }
}
EOF
```

**【预期】** 目录结构变成：

```
hello_app/
├── cjpm.toml          # [workspace] members = ["./hello", ...]
└── hello/
    ├── cjpm.toml      # output-type = "dynamic"
    └── src/
        ├── hello.cj
        └── HelloWordController.cj
```

> 这一段建议**完整录下来**：不到 20 行代码，一个 HTTP 服务就写完了。这是最有说服力的一镜。

## 3.4 `fboot build` —— 编译使用 fountain 的项目

**【口播】**

> `fboot build` 不是简单地转发给 `cjpm build`，它额外做了两件很有意思的事。

### 语法

```bash
fboot build [PATH] [args...]
```

- `PATH` **必须是第一个参数，且只能是路径**；缺省当前目录；
- 其余参数分两类：
  - `--key=value`：作为**配置项**（这就是「编译期注入配置」的实现方式）；
  - 其它：原样作为 `cjpm build` 的命令行参数。

### 两个隐藏动作

1. **生成版本模块 `<模块名>_stAtIc__`**
   在项目下临时创建模块（模块名的 `.` `-` 替换为 `_`），写入 `src/<模块名>_AppVersion.cj`，内容是 `AppVersion.set(<banner>, <name>, <version>)`，并临时加入 workspace `members`；进程退出时恢复原 `cjpm.toml` 并删除临时模块。
   → **这就是为什么启动时能打印出你自己的 BANNER 和版本号。**

2. **读取 `banner.txt`**
   如果当前目录有非空的 `banner.txt`，它会成为 `AppVersion` 的横幅。

**【命令】**（现场：在 `hello_app` 里编译）

```bash
cd /tmp/fountain_live/hello_app
fboot build
```

**【预期】** 终端出现：

```
fboot build is used to compile the project which depends fountain.
fboot build /tmp/fountain_live/hello_app --target-dir=/tmp/fountain_live/hello_app/hello_app
BUILD ARGS: [build, --target-dir=..., ...]
```

**【口播】**（这里有个值得解释的细节）

> 注意 `--target-dir`：当 `PATH` **等于当前工作目录**时，fboot 会把产物目录设为 `<路径>/<目录名>`；否则产物目录就是 `PATH` 本身。
>
> 这解释了仓库里 `fdemo` 的产物为什么在 `fdemo/fdemo/release/`——因为 `boot.sh` 就是在 `fdemo` 目录里执行 `fboot build ./fdemo` 的。

### 编译期注入配置（重要）

**【命令】**（这就是 `fdemo/boot.sh` 里 `build()` 函数在干的事，建议直接切到文件讲）

```bash
fboot build ./fdemo \
  --orm_drivers=postgres \
  --postgres_orm_connectionUrl=$POSTGRES \
  --postgres_orm_option_username=$POSTGRES_USERNAME \
  --postgres_orm_option_password=$POSTGRES_PASSWORD \
  --orm_sm4Key=$(fboot randhex 32) \
  --orm_sm4Iv=$(fboot randhex 32)
```

**【口播】**

> 这些 `--xxx=yyy` 会变成 `fboot build` 执行时的配置项。
> 也可以把`--`去掉，改成环境变量，也是一样的效果。
> 于是：
> - 数据库连接串、用户名密码在**编译期**就被写进产物；
> - 因为同时给了 `orm_sm4Key` / `orm_sm4Iv`，这些敏感信息是 **SM4 加密后的字节数组**嵌入的，不是明文；
> - **运行期同名环境变量优先级更高**——运行环境如果同名配置项有其他值，可以用新值覆盖即可，一份产物跑多套环境。
> 覆盖方法也很简单，同样是`--`开头的命令行参数或同名的环境变量。
> 顺带提醒：真实项目不要把密码写进 `boot.sh`，这里只是演示。

## 3.5 `fboot randhex` —— 生成随机 16 进制串

**【命令】**

```bash
fboot randhex 16
fboot randhex 32
```

**【预期】** 例如 `a3f19c0e7b2d45a8`（16 位）／64 位小写 16 进制串（32 位）。

**【口播】**

> 它的实现是 `fountain::f_random.RandomString().randomLowerHex(n)`，由 `f_app` 的 `RandHexCommand` 注册到 `SubCommandMediator`。
>
> 在 fountain 里它最常见的用途就是上一节那个：给 SM4 生成密钥和 IV。**SM4 密钥是 16 字节 = 32 个 16 进制字符**，所以写 `fboot randhex 32`。
>
> 每次编译换一对 KEY/IV，嵌入的密文就不一样——这是一个很轻量的「产物级」防护。

## 3.6 `fboot cleanUpdate` —— 依赖变了之后的必修课

**【命令】**

```bash
fboot cleanUpdate            # 当前目录
fboot cleanUpdate ./fdemo    # 指定路径
```

**【预期】**

```
fboot cleanUpdate /abs/path --target-dir=...
（cjpm clean 输出）
（删除 cjpm.lock）
（cjpm update 输出）
```

**【口播】**

> 它等价于三步：`cjpm clean --target-dir=<...>` → 删除 `cjpm.lock` → `cjpm update`。
>
> **什么时候必须用它？** 当你改了 `cjpm.toml` 的依赖，或者切换了 SDK / stdx 版本，旧产物可能与新依赖二进制不兼容。这时候不要浪费时间 debug，直接 `fboot cleanUpdate`。
>
> `fdemo/boot.sh` 里也封装了它：`./boot.sh cleanUpdate`。

## 3.7 `fboot run` —— 启动应用

### 语法

```bash
fboot run [PATH] --dylibPattern=<动态链接库文件名正则（不含扩展名）>
```

**【口播】**

> 这是整个框架最有意思的一条命令。它的执行流程是：
>
> 1. 确定目标路径（第一个不以 `-` 开头的参数，缺省当前目录，不存在就创建）；
> 2. 按平台选择动态链接库扩展名和搜索路径变量：Windows `.dll` / `Path`，macOS `.dylib` / `DYLD_FALLBACK_LIBRARY_PATH`，其它 `.so` / `LD_LIBRARY_PATH`；
> 3. **递归扫描目录**，加载文件名匹配 `^lib.*(<--dylibPattern> | .+_stAtIc__).*$` 的库
>    —— 即文件名要以 `lib` 开头，并且匹配你给的正则，或者是前面介绍过的fboot build自动创建的那个`static`版本模块；
> 4. 加载即执行各模块的动态链接库，加载时即执行fountain宏展开时生成的顶级匿名闭包，把 `@Bean` 注册进 IOC、把fountain的各个`Initializer` 实现注册进 `InitializerCollection`、把controller函数注册到mvc；
> 5. 按 `dependencies` 做**拓扑排序**后依次 `initialize()`，收集所有 `start()`；
> 6. 每个 `Initializer.start()`会在新线程执行，其中（MVC 的 `start()` 会启动 HTTP 服务并阻塞）；
> 7. 主线程 `while(true){ sleep(Duration.Max) }` **永久阻塞**。
> 8. **`fboot run` 不会返回**
>
> 最后一条要在视频里强调：**`fboot run` 不会返回，录屏时请另开一个终端敲 curl。**

### `--dylibPattern` 怎么写（重点，也是最容易踩的坑）

**【命令】**（`fdemo/boot.sh` 里的真实写法）

```bash
fboot run ./fdemo --dylibPattern='(boot|user\.util\.(auth|cron)|\.(controller|service\.impl))'
```

**【口播】**

> 这个正则看起来很绕，其实逻辑很清楚——**它枚举了「必须在运行期主动加载的动态链接库」**：
>
> | 片段 | 加载什么 | 为什么必须加载 |
> | --- | --- | --- |
> | `boot` | 初始化包 `fountain::boot` | `ControllerAspect`（切面）、`TransactionHookImpl`（事务钩子）、`LogTextMediaType`（自定义 MediaType）、`Http500Handler`（500 处理器）都在这里，它们都是 `@Bean`，不加载就静默失效 |
> | `\.(controller` | 所有 controller 包 | MVC 路由注册 |
> | `service\.impl` | 所有 service 实现包 | `@TransactionalService` 的织入和业务实现 |
> | `user\.util\.auth` | `AuthCheckerImpl`（登录/权限检查器） | 它是 `@Bean`，不加载 → 所有接口都不做鉴权（危险！） |
> | `user\.util\.cron` | `TickTockTaskImpl`（定时任务） | 它是 `@Bean`，不加载 → 定时任务不执行 |
>
> 一句话：**凡是靠 `@Bean` 生效的东西，所在的动态链接库都必须被 `--dylibPattern` 匹配到。**
> 不给 `--dylibPattern` 会自动加载目录下全部 `lib*` 动态链接库——这么做可能导致重复加载动态链接库，也就是有些被主动加载的动态链接库依赖的动态链接库也会被重复加载，从而导致应用启动失败。

**【命令】**（现场跑 `hello_app`）

```bash
cd /tmp/fountain_live/hello_app
fboot run --dylibPattern='hello'
```

**【预期】**

```
 _______  ...
（BANNER）
hello_app(1.0.0) started by 1.3.x in xxxms
```

**【命令】**（另开终端验证）

```bash
curl http://localhost:8080/
```

**【预期】** `hello Fountain!`

> 到此，从空目录到可服务的 HTTP 应用，**一共只敲了 4 条命令、写了一个类**。这是本章最好的收尾。

## 3.8 其余命令（快速过一遍）

| 命令 | 作用 | 演示 |
| --- | --- | --- |
| `fboot count [PATH] [--ext=cj] [--ignoreBrackets] [--ignoreComments]` | 统计项目的模块数/包数/文件数/行数与耗时 | `fboot count ./fdemo` |
| `fboot test [PATH] [args...] --dylibPattern=<正则>` | 用 `PATH/test/cjpm.toml` 覆盖 `PATH/cjpm.toml`，先 build 再 run | 缺 `--dylibPattern` 会抛 `BootException` |
| `fboot pub <x.y.z> [--skip-lint] [--skip-test]` | 批量发布模块，自动按依赖排序、改版本号、探测制品仓库 | 用 `.modules` 文件的 `[include]`/`[exclude]`/`[detention]` 控制范围 |
| `fboot version` | 打印 fountain 版本（不带参数）/ 管理 fountain 自身版本（带 `x.y.z`，会 git 提交推送打 tag） | **谨慎演示**，它会动 git |
| `fboot <自定义子命令>` | 执行实现了 `fountain::f_app.SubCommand` 的类 | 见下 |

**【口播】**（自定义子命令，30 秒带过）

> `pub` 和 `randhex` 本身就是最好的例子。你只要写一个实现 `SubCommand` 的类，在 `static init()` 里 `SubCommandMediator.register(...)`，把它编译成动态链接库，就可以：
>
> ```bash
> fboot <子命令名> [PATH] --dylibPattern='<库名正则>'
> ```
>
> 未命中时框架会扫描并加载动态链接库、让 `static init()` 完成注册，然后**重试一次**；仍然没有才抛异常并列出可用命令。

---

# 第四章 现场跑通 `fdemo`

**【镜头】** IDE 打开 `fdemo/`，终端执行脚本

## 4.1 目录结构

```
fdemo/
├── cjpm.toml          # workspace：members = ["./boot", "./user"]
├── banner.txt         # 启动横幅（会被 fboot build 打包进版本模块）
├── boot.sh            # Linux/macOS 启动脚本
├── boot-win-gitbash.sh# Windows git-bash 启动脚本
├── boot/              # 初始化模块：切面、事务钩子、MediaType、500 处理器
│   └── src/
│       ├── boot.cj
│       ├── ControllerAspect.cj
│       ├── TransactionHookImpl.cj
│       ├── LogMediaType.cj
│       └── error/ErrorHandler.cj
└── user/              # 业务模块
    └── src/
        ├── controller/     # UserController / CurrentUserController / HellowordController / UploadController / ErrorController
        ├── service/        # UserService（接口）
        ├── service/impl/   # UserServiceImpl / HelloworldServiceImpl
        ├── dao/            # UserDAO
        ├── model/po/       # UserPO（持久化对象）
        ├── model/mvc/      # UserRequest / UserResponse / UserSession / UserList / UploadRequest
        ├── model/entity/   # UserEntity
        └── util/
            ├── UserSessionCache.cj     # JWT 会话
            ├── auth/AuthCheckerImpl.cj # 登录/权限检查
            └── cron/TickTockTest.cj    # 定时任务
```

**【口播】**

> 注意这个分包不是随意的：**分包决定了动态链接库的粒度，而动态链接库粒度决定了 `--dylibPattern`**。所以「切面放哪个包」「鉴权器放哪个包」是需要在设计阶段就想的。

## 4.2 建表

**【命令】**（PostgreSQL）

```sql
CREATE TABLE public.user_info (
    id int8 GENERATED BY DEFAULT AS IDENTITY NOT NULL,
    username varchar(32) DEFAULT ''::character varying NOT NULL,
    "password" varchar(24) DEFAULT ''::character varying NOT NULL,
    save_time timestamptz DEFAULT now() NULL,
    CONSTRAINT user_info_pkey PRIMARY KEY (id),
    CONSTRAINT user_info_username_key UNIQUE (username)
);
```

## 4.3 编译 + 启动

**【命令】**

```bash
cd fdemo
export POSTGRES='postgres://user:pass@host:5432/dbname'
export CANGJIE_STDX_PATH=$CANGJIE_STDX_DYNAMIC_PATH

./boot.sh build      # 内部就是 fboot build ./fdemo --orm_drivers=postgres ... --orm_sm4Key=$(fboot randhex 32) ...
./boot.sh run        # 内部就是 fboot run ./fdemo --dylibPattern='(boot|user\.util\.(auth|cron)|\.(controller|service\.impl))'
```

**【预期】**

```
[INFO-...] ... （fountain 启动日志）
  _____   .___
_/ ____\__| _/____   _____   ____
\   __\/ __ |/ __ \ /     \ /  _ \
 |  | / /_/ \  ___/|  Y Y  (  <_> )
 |__| \____ |\___  >__|_|  /\____/
           \/    \/      \/

fdemo(1.1.0) started by 1.3.x in xxxms
```

## 4.4 接口验证清单（这一段建议做成一张对照表放在画面上）

| # | 目的 | 命令 | 预期 |
| --- | --- | --- | --- |
| 1 | 忽略安全的接口 | `curl -H 'Accept:text/plain' http://localhost:8080/helloworld` | `helloworld` |
| 2 | 注册（忽略鉴权+权限） | `curl -XPOST 'http://localhost:8080/api/user/register' -H 'Content-Type:application/x-www-form-urlencoded' -H 'Accept:text/plain' -d 'username=abcdef&password=bcbcbcbc'` | 返回含 `id/username/password` 的 JSON 文本 |
| 3 | 登录拿 JWT | `curl -XPOST http://localhost:8080/api/user/session -H 'Content-Type:application/json' -H 'Accept:application/json' -d '{"username":"abcdef","password":"bcbcbcbc"}'` | `{"status":1,"fields":{"userId":...,"jwt":"...","logged":true}}` |
| 4 | 带 JWT 访问受保护接口 | `curl -H 'Accept:application/json' -H 'Authorization: <第3步的jwt>' http://localhost:8080/api/user/1` | 用户 JSON |
| 5 | **不带** JWT 访问（演示登录检查） | `curl -i -H 'Accept:application/json' http://localhost:8080/api/user/1` | `401` + `{"status":-1}` |
| 6 | 分页列表 | `curl -H 'Accept:application/json' -H 'Authorization: <jwt>' http://localhost:8080/api/users` | `Pagination<UserPO>` 序列化结果 |
| 7 | 参数校验 | `curl -XPOST http://localhost:8080/api/user/session -H 'Content-Type:application/json' -d '{"username":"ab","password":""}'` | 校验失败（用户名至少 6 位 / 密码必填） |
| 8 | 500 处理器 | `curl -i http://localhost:8080/api/error` | 走 `NameOf500Handler` 返回统一错误体 |
| 9 | 文件上传 | `curl -XPOST http://localhost:8080/upload -F 'name=abc' -F 'file=@./banner.txt'` | `ok` |
| 10 | 重定向 | `curl -i http://localhost:8080/redirect/helloworld` | 302 + `Location: /helloworld` |
| 11 | 自定义 MediaType | `curl -XPOST http://localhost:8080/api/user/sessionLog -H 'Content-Type:application/json+log' -H 'Accept:application/json+log' -d '{"username":"abcdef","password":"bcbcbcbc"}'` | 日志里出现 `fromData:`/`toData:` |
| 12 | 定时任务 | 观察控制台 | 每隔若干秒打印 `TickTockTaskImpl is executing` |

> 第 5 条是全场最直观的「登录状态检查」演示，一定要留 20 秒给观众看清 401。

**【命令】**（可选：压测，展示一下性能）

```bash
./boot.sh loop 100    # 循环 100 次请求 /helloworld，打印总耗时
./boot.sh ab 16 10000 # ab 压测（需先 apt install apache2-utils）
```

---

# 第五章 IOC：`fountain::f_bean`

**【镜头】** `f_bean/README.md` + `fdemo` 中的 `UserController.cj`

## 5.1 最小可用

```cangjie
import fountain::f_bean.*
import fountain::f_bean.macros.*

@Bean
@BeanMeta[                       // 全是默认值时可省略
    name: '',                    // bean 名，默认「类型全限定名 + 序号」
    scope: BeanScope.singleton,  // singleton | prototype
    lazy: true,                  // singleton 懒加载；prototype 下不生效
    primary: false,              // 同类型排最前
    order: 0,                    // 同类型排序
    condition: NoneBeanCondition.instance
]
public class ClassName{}

@Bean[String, Duration|Int64, String]   // 泛型类：| 分隔多组泛型实参
public class GenericClass<T, E>{
    private let bean = lookup<ClassName>()
}
```

**【口播】**

> `@Bean` 展开后会把「构造函数闭包 + `TypeInfo` + `BeanMeta`」注册到 `BeanFactory`，并用三张 HashMap 建索引：
> - KEY = bean 名；
> - KEY = 类 / 父类 / 实现的接口的 `TypeInfo`；
> - KEY = 类上的注解 / 注解父类型的 `TypeInfo`。
>
> 所以**你可以用名字、用类型（含父类型和接口）、用注解三种方式取 bean**。
>
> 另外一个重要取舍：**IOC 只管理 class，不管理 struct**。因为 struct 是值类型，取出来就会复制，我认为得不偿失。

## 5.2 取 bean：`lookup` 家族

| 函数 | 返回 | 说明 |
| --- | --- | --- |
| `lookup<T>()` | `T` | 第一个，找不到抛异常 |
| `lookup<T>(name: String)` | `T` | 按名字 |
| `lookup<T>(cond: StringCond)` | `T` | 名字符合条件 |
| `lookupOption<T>()` / `(name)` / `(cond)` | `?T` | 找不到返回 `None<T>` |
| `lookupList<T>()` / `(cond)` | `ArrayList<T>` | 全部 |
| `lookupHashSet<T>()` | `HashSet<T>` | `T <: Hashable & Equatable<T>` |
| `lookupTreeSet<T>()` | `TreeSet<T>` | `T <: Comparable<T>` |
| `lookupHashMap<T>()` | `HashMap<String, T>` | KEY 是 bean 名 |
| `lookupLables<L, T>()` | `HashMap<L, T>` | `T` 实现 `BeanLabel<L>`，用 `label` 做 KEY |
| `lookupWeights<W, T>()` | `TreeMap<W, T>` | `T` 实现 `BeanWeight<W>`，用 `weight` 排序 |

`StringCond` 是一个匹配规则的枚举：`IgnoreCond | Exactly(s) | Prefix(s) | Suffix(s) | Wildcard(s) | Regexp(s) | Contains(s) | In(s)`。

**【口播】**（`lookupList<T>()` 是重点）

> `lookupList<T>()` 是「策略模式」的免费实现：同一个接口 N 个实现，一行代码全拿到。配合 `BeanLabel` / `BeanWeight` 还能直接做成路由表或加权负载均衡。

## 5.3 生命周期与工厂

```cangjie
// 自定义构造：@Constructor 修饰构造函数或静态函数
@Bean
public class MyBean {
    @Constructor
    public init(@Value[name: 'mvc_port', default: 8080] port: Int64,
                @BeanParam[Prefix('user.')] svc: UserService) {}
}

// 工厂 bean：实现 FactoryBean 后，get() 的返回值才是真正的 bean
public interface FactoryBean {
    static prop typeInfo: TypeInfo
    func get(): Object
}

// 初始化后回调
public interface PostConstruct { func postConstruct(): Unit }
// 销毁回调（prototype 需自己调，singleton 由 IOC 调）
public interface Destroy { func destroy(): Unit }
```

**【口播】**

> `@Value` 把**配置项**直接注入构造参数，支持 `name / default / dateFormat / delim` 四个属性。
> `@BeanParam` 按 `StringCond` 匹配 bean 名，把另一个 bean 注入进来。
> 这两者**只能修饰被 `@Constructor` 修饰的函数形参**，否则编译期就报错。

## 5.4 条件装配：`BeanCondition`

```cangjie
public interface BeanCondition <: ToString {
    func on(factory: BeanFactory): Bool
    operator const func &(right: BeanCondition): BeanCondition
    operator const func |(right: BeanCondition): BeanCondition
    operator const func !(): BeanCondition
}
```

内置实现：

- `NoneBeanCondition` —— 永远 true（默认）
- `AndCond` / `OrCond` / `NotCond`
- `ConfCond` —— `IgnoreConf | Exists(key) | NotExists(key) | Value(key, StringCond)`
- `BeanDef` —— 「存在满足条件的 bean 定义」才成立，可用 `beanType`(BeanDefType) / `beanName`(StringCond) / `scope` / `count`(BeanDefCount) 组合

**【示例】**

```cangjie
@Bean
@BeanMeta[condition: ConfCond.Value('orm_drivers', StringCond.Contains('postgres'))
                   & BeanDef(beanType: BeanDefType.SubOfOnly('fountain::f_orm.base.Dialect'))]
public class PostgresOnlyBean {}
```

**【口播】**

> 这是「按环境装配」的官方方案：配置里有 postgres 且有某个 Dialect 实现，这个 bean 才存在；否则在 `afterRegistered()` 阶段被从 `BeanFactory` 删除。
> 比 Spring 的 `@Conditional` 更灵活的地方是 `& | !` 可以直接用操作符组合。

## 5.5 在 `fdemo` 里看 IOC

**【镜头】** `user/src/controller/UserController.cj`

```cangjie
@Controller
public class UserController {
    private let userService = lookup<UserService>()
    ...
}
```

**【口播】**

> 注意 `lookup<UserService>()` 拿到的是**接口**类型的 bean，而实现类是 `UserServiceImpl`。IOC 用「实现的接口」做了索引，所以按接口取是天然支持的。
>
> 再看 `CurrentUserController`：
> ```cangjie
> @WeavedController
> @BeanMeta[scope: BeanScope.prototype]   // 必须写在 @WeavedController 下面
> public class CurrentUserController { ... }
> ```
> `prototype` 意味着每次访问都 new 一个——它的 `init()` 里有一行 `println`，**每访问一次就会打印一次**，这就是视频里证明 prototype 生效的最简单方式。

## 5.6 `@Configuration` + `@BeanInit`

```cangjie
@Configuration        // 这个类本身不被 IOC 管理
public class AppConfig {
    @BeanInit
    public func initSomething(): Unit { ... }
}
```

**【口播】** 被 `@BeanInit` 修饰的公共成员函数（静态/实例皆可）都是 bean 初始化函数；`@Configuration` 修饰的类自己不会进容器。

---

# 第六章 AOP：`fountain::f_aspect`

**【镜头】** `fdemo/boot/src/ControllerAspect.cj` + `f_aspect/README.md`

## 6.1 切面 = 实现了 `Aspect` 的 `@Bean`

```cangjie
public interface Aspect {
    func before(funcInfo: InvocationFuncInfo): Unit                  // 最先
    func around(funcInfo: InvocationFuncInfo, point: (Array<Any>) -> Any): Any
    func after(funcInfo: InvocationFuncInfo, result: Any): Any       // around 之后
    func throwing(funcInfo: InvocationFuncInfo, e: Exception): Exception
    func final(funcInfo: InvocationFuncInfo): Unit                   // 最后
    func proceed(funcInfo: InvocationFuncInfo, point: (Array<Any>) -> Any): Any
}
```

**【口播】**（把执行顺序讲清楚，这是面试/实战都爱问的）

> 默认 `proceed` 的顺序是：
> ```
> try {
>     before
>     around ──► 原函数体（由你在 around 里决定何时调用 point(...)）
>     after
> } catch (e) {
>     throwing
> } finally {
>     final
> }
> ```
> `before / around / 原函数体 / after` 任意一步抛异常都会进 `throwing`；`final` 一定会执行。
> 如果你有更特别的编排需求，直接覆盖 `proceed` 自己排。

## 6.2 织入规则：`RouteRule`

规则全部支持 `*` `?` 通配符，包名支持 `..`（任意层级）、`.*` `*.` `.*.`（任意包名），组织名用 `::` 分隔。规则之间可以用 `& | !` 组合。

| 规则 | 匹配依据 |
| --- | --- |
| `ExecutionRouteRule(qualifiedName, funcName, argTypes, returnType)` | 类全限定名 + 函数名 + 参数类型 + 返回类型 |
| `WithinRouteRule(qualifiedName)` | 类型名匹配 → 该类全部公共实例函数 |
| `FuncNameRouteRule(name)` | 函数名 |
| `FuncTypeRouteRule(argTypes, returnType)` | 参数 + 返回类型 |
| `ArgsRouteRule(argTypes)` | 参数类型（`**` 任意数量；`*,` `,*` 忽略首尾） |
| `ReturnTypeRouteRule(returnType)` | 返回类型 |
| `TargetRouteRule(qualifiedName)` | 该类及其子类 |
| `TargetAnnotationRouteRule(annotationTypes, sub)` | 目标类型上有指定注解 |
| `FuncAnnotationRouteRule(annotationTypes, sub)` | 目标函数上有指定注解 |
| `ArgAnnotationsRouteRule` / `AnyArgAnnotationsRouteRule` / `ArgPrefixAnnotationsRouteRule` / `ArgSuffixAnnotationsRouteRule` | 参数上的注解 |
| `BeanNameRouteRule(beanName)` | 目标对象的 bean 名 |
| `ConfigExecutionRouteRule(<配置项名>)` | **从环境变量读规则** |
| `AndRouteRule` / `OrRouteRule` / `NotRouteRule` | 组合 |

## 6.3 三个织入宏

```cangjie
@Pointcut       // 修饰函数：只有这个函数织入；修饰类：全部公共函数织入
@WeavedBean     // 注册进 IOC + 全部公共成员函数织入
@WeavedController // mvc模块声明的专用宏：包含@Controller 的全部功能 + 织入
@TransactionalService // orm模块声明的专用宏，包含@Bean的全部功能 + 事务切面织入
```

**【口播】** 织入逻辑在**这些函数首次调用时**执行，不是启动期——所以启动很快。

## 6.4 现场：`ControllerAspect`

**【镜头】** `fdemo/boot/src/ControllerAspect.cj`

```cangjie
@AspectRoute[ConfigExecutionRouteRule('controllerPointcut')]
@Bean
public class ControllerAspect <: Aspect {
    private let log = LoggerFactory.getLogger<ControllerAspect>()
    public func around(funcInfo: InvocationFuncInfo, point: (Array<Any>) -> Any): Any {
        log.info('ControllerAspect around')
        point(funcInfo.args)
    }
}
```

配合 `boot.sh` 里的一行环境变量：

```bash
export controllerPointcut='*::*..*Controller.*(**): *'
```

**【口播】**

> 这里有个非常值得强调的设计：**`controllerPointcut` 不是 MVC 的配置项，它是这个切面的作者自己起的名字**。
> `ConfigExecutionRouteRule('controllerPointcut')` 的意思是「去环境变量里读 `controllerPointcut` 这一项，把它当作 ExecutionRouteRule 规则」。
>
> 于是切点表达式变成了**部署期可配**的：开发环境织上，生产环境改窄甚至关掉，都不用改代码。
>
> 表达式 `*::*..*Controller.*(**): *` 读作：任意组织 `::` 任意多级包名下、以 `Controller` 结尾的类的、任意参数的、任意返回类型的**全部**公共实例函数。

**【演示】** 访问 `http://localhost:8080/helloworld`，控制台出现：

```
[INFO-ControllerAspect]...ControllerAspect around
```

**【演示】** 改一下 `controllerPointcut` 再启动（比如改成 `*::*..*UserController.*(**): *`），只有 User 开头的 controller 会打日志。

## 6.5 AOP 在 fountain 里的两个"杀手级"用法

1. **事务**：`f_orm` 的 `TransactionAspect` 就是 `@AspectRoute[FuncAnnotationRouteRule("fountain::f_orm.base.Transactional") | ConfigExecutionRouteRule(ORMConfig.transactionalFuncExecution)]` 的切面（见第八章）；
2. **统一日志/耗时/审计**：就像 `ControllerAspect`，一处改动覆盖全部 controller。

---

# 第七章 MVC：`fountain::f_mvc`

**【镜头】** `fdemo/user/src/controller/` 全部文件

## 7.1 声明 Controller

```cangjie
import fountain::f_mvc.*
import fountain::f_mvc.macros.*

@Controller          // = 路由注册 + @Bean 展开
public class HellowordController {
    private let helloworldService = lookup<HelloworldService>()

    @GetMapping[path:"/helloworld", produces:'text/plain', consumes:'application/x-www-form-urlencoded']
    @IgnoreSecurity   // @IgnoreSecurity = @IgnoreAuth + @IgnorePrivilege
    public func helloworld(): String {
        helloworldService.sayHello('haha')
        return "helloworld"
    }
}
```

**【口播】**

> 三条规则：
> 1. 只有被 `*Mapping` 注解修饰的**公共实例函数**才会注册到 MVC；
> 2. `@Controller` 同时展开 `@Bean`，所以 controller **天然是 IOC bean**，可以直接 `lookup`；
> 3. 需要织入切面时改用 `@WeavedController`（`CurrentUserController` 就是例子）。

### Mapping 家族与参数

- `@GetMapping` `@PostMapping` `@PutMapping` `@DeleteMapping` `@PatchMapping`
- 公共参数：`path` `produces` `consumes` `params` `headers`，另有 `ignoreAuth` `ignorePrivilege`
- `path` 支持 `{}` 路径参数：`/api/user/{id}`
- `produces` / `consumes` 可用 `|` 分隔多种格式，默认 `application/json`

**`params` / `headers` 的规则 DSL**（这个很酷，值得单独讲 30 秒）：

```
rule1 & rule2      两边都满足
rule1 | rule2      满足一边
!rule              取反
(rules)            改变优先级
contains('a','b')  参数/请求头名需包含这些
subset('a','b')    参数/请求头名是这些的子集
```

示例：`a.contains('1','2') & (b.subset('s','d') | 'orderTime' | goodsId)`

## 7.2 参数绑定注解

| 注解 | 来源 | 备注 |
| --- | --- | --- |
| `@RequestParam` | 表单 / query string | 可带 `name` 与 `default` |
| `@RequestParamObject` | 表单 / query → 对象 | 按字段名逐个取值 |
| `@PathVariable` | 路径参数 | 可带 `name` / `default` |
| `@RequestHeader` | 请求头 | 可带 `name` / `default` |
| `@RequestBody` | 请求体 | 按 `Content-Type` 解析 |

**【镜头】** `CurrentUserController.cj`，一次看全四种写法：

```cangjie
@PostMapping[path:'/api/user/register', consumes:'application/x-www-form-urlencoded',
             produces:'text/plain', ignoreAuth: true, ignorePrivilege: true]
public func register(@RequestParam username: String, @RequestParam password: String): String { ... }

@PostMapping[path:'/api/user/session', consumes:'application/json', produces:'application/json', ignoreAuth: true]
public func login(@RequestBody user: UserRequest): UserResponse { ... }

@PostMapping[path:'/api/user/echo', consumes:'application/x-www-form-urlencoded',
             produces:'application/json', ignoreAuth: true]
public func echo(@RequestParamObject user: UserRequest): UserRequest { ... }

@DeleteMapping[path:'/api/user/session', consumes:'application/x-www-form-urlencoded', produces:'application/json']
public func echoSession(@RequestHeader userId: Int64, @RequestHeader token: String): JsonValue { ... }
```

以及路径参数与默认值：

```cangjie
@GetMapping[path:'/api/user/{id}', produces:'application/json']
public func queryUser(@PathVariable id: Int64): JsonValue { ... }

@PostMapping[path:'/api/user/echo2', ...]
public func echo2(@RequestParam[default: ''] username: String,
                  @RequestParam[default: ''] password: String): UserRequest { ... }
```

## 7.3 参数校验（顺带讲 `f_data`）

**【镜头】** `user/src/model/mvc/UserReqResp.cj`

```cangjie
@DataAssist[props fields]
public class UserRequest {
    @CombinedValidator[IsNotBlank(messageIfNotMatch: '请输入用户名') & StringSize(min: 6, max: 50)]
    private var username: String = ''
    @IsNotBlank[messageIfNotMatch: '请输入密码']
    private var password: String = ''
}
```

**【口播】**

> 校验注解既可以修饰类的成员（MVC 传参对象时生效），也可以修饰函数参数。不满足会抛 `ValidationException`，由我们注册的 500 处理器统一转成响应体（见 7.6）。

## 7.4 安全注解

```cangjie
@IgnoreAuth        // 忽略登录状态检查
@IgnorePrivilege   // 忽略权限检查
@IgnoreSecurity    // 两者都忽略
```

只能修饰 controller 的公共实例函数。也可以在 Mapping 注解里直接写 `ignoreAuth: true`。

## 7.5 配置（全部环境变量）

```bash
export mvc_port=8080
export mvc_maxRequestBodySize=67108864          # 默认 stdx 的 2MB，上传必须调大
export mvc_overallElapsedSwitch=true            # 生产建议 false
export mvc_internalServerErrorMessageKind=BEAN  # BEAN | TEXT | BASE64BINARY
export mvc_internalServerErrorMessage=NameOf500Handler
export mvc_readTimeout=500ms
export mvc_readHeaderTimeout=500ms
export mvc_writeTimeout=500ms
export mvc_keepAliveTimeout=500s
export mvc_maxRequestHeaderSize=102400
export mvc_downloadBufferSize=4096
export mvc_accessControlAllowOrigin='*'
export mvc_accessControlAllowHeaders='*'
export mvc_accessControlMaxAge=0
```

## 7.6 统一异常响应

**【镜头】** `fdemo/boot/src/error/ErrorHandler.cj`

```cangjie
@Bean
@BeanMeta[name: 'NameOf500Handler']
public class Http500Handler <: ErrorHttpRequestHandler {
    public func handle(_: HttpContext, ex: ?Exception): (HttpStatus, Any) {
        if (let Some(e: ValidationException) <- ex) {
            (HttpStatus.INTERNAL_SERVER_ERROR, BaseResponse.error(e.message))
        } else {
            (HttpStatus.OK, BaseResponse.error('error'))
        }
    }
}
```

**【口播】**

> `mvc_internalServerErrorMessageKind=BEAN` 时，`mvc_internalServerErrorMessage` 是**bean 的名字**（这里是 `NameOf500Handler`），这个 bean 必须实现 `ErrorHttpRequestHandler`。
> 返回值是 `(HttpStatus, Any)`，`Any` 可以是 `String` / `ToString` / `InputStream` / `Array<Byte>` / `f_data.ToData`（按 `Accept` 协商格式）。
> 另两个取值：`TEXT` 直接把配置值当响应体；`BASE64BINARY` 把配置值当 BASE64 解码后作为响应体。
>
> 演示方式：访问 `/api/error`（`ErrorController` 里直接 `throw Exception()`），看响应是不是 `BaseResponse.error('error')`。

## 7.7 重定向

```cangjie
Redirect.found('/helloworld')                 // 302
Redirect.permanently('/x', retain: true)      // retain=false → 301；true → 308
Redirect.temporarily('/x', retain: true)      // retain=false → 302；true → 307
```

## 7.8 拿到当前请求上下文

```cangjie
import fountain::f_mvc.CurrentHttpContext
let ctx = CurrentHttpContext.instance   // 当前线程正在处理的 HttpContext
```

**【口播】** 这是 `f_security` 能在 Service/Util 层做鉴权的关键——鉴权逻辑不必写在 controller 里（见第九章 `UserSessionCache.verify()`）。

## 7.9 自定义数据格式（`MediaType`）

**【镜头】** `fdemo/boot/src/LogMediaType.cj`

```cangjie
@Bean
public class LogTextMediaType <: MediaType {
    public init() { super('application/json+log') }
    public func make(mediaType: String): MediaType { this }
    public func toString() { mediaType }
    public func fromData(data: Data): Array<Byte> { ... }   // 请求体 → 字节
    public func toData(data: Array<Byte>): Data { ... }     // 字节 → 数据
    // == 与 hashCode 也必须实现
}
```

**【口播】**

> 只要把 `MediaType` 的实现注册成 `@Bean`，`consumes / produces` 就可以直接写你的自定义类型，比如 `application/json+log`——所有走这个 Content-Type 的请求都会先落一条日志。
> 这就是「协议扩展点」：不用改框架，加个 bean 就多一种数据格式。

---

# 第八章 ORM：`fountain::f_orm`

**【镜头】** `fdemo/user/src/model/po/UserPO.cj` → `dao/UserDAO.cj` → `service/impl/UserServiceImpl.cj`

## 8.1 三个角色：PO、DAO、Service

### PO：用宏生成列映射

```cangjie
@DataAssist[fields tostring]
@QueryMappersGenerator[table: user_info dirty]
public class UserPO {
    @ORMField[true 'id']        // true = 主键；'id' = 列名
    private var id: Int64 = 0
    @ORMField['username']
    private var username: String = ''
    @ORMField['password']
    private var password: String = ''
    @ORMField['save_time']
    private var saveTime: ?DateTime = None<DateTime>
}
```

**`@QueryMappersGenerator` 会生成**：

| 生成物 | 用途 |
| --- | --- |
| `static func queryMappers(): QueryMappers<T>` | 结果集 → 对象的映射 |
| `static func tableName(): String` | 表名 |
| `static func tableColumns(): C` | 列对象集合（属性名是**列名**，不是成员名） |
| `static func isSimpleData(): Bool` | PO 返回 `false` |
| 列集合类 `<PO类名>__cOlUmns___` | 每个列一个 `Column` 属性 |
| `TableMetas.register<T>()` | 供 migro（表结构比对）发现 |

属性写法：

| 写法 | 含义 |
| --- | --- |
| `[user_info]` / `[table: 'user_info']` | 表名 |
| `[table: LowerUnderScore]` | 类名按策略转表名 |
| `[tablePrefix: 't_' tableSuffix: '_tab']` | 表名前后缀 |
| `[classPrefix: 'F_' classSuffix: 'PO']` | 转表名前先剥离类名前后缀 |
| `[dirty]` | setter 注入脏字段标记 |
| `[table: xxx dirty]` | 组合写法 |

**`@ORMField` 属性语法**（各部分可选、顺序任意）：

`true`/`id` 主键 · `false` 非主键 · `'column_name'` 列名 · `LowerUnderScore` / `UpperUnderScore` / `Pascal` / `Camel` 命名策略 · `column: <上述>` · `converter: <beanName>`

> 约束（编译期报错）：`@ORMField` **只能修饰 `public var` 成员变量或 `public mut prop`**，且必须是非静态实例成员。
> 顺序约束：`@DataAssist` 要写在 `@QueryMappersGenerator` **之前**（先展开）。

### DAO：接口即实现

```cangjie
@DAO
public interface UserDAO <: RootDAO {
    func findUser(id: Int64): UserPO {
        executor.FROM<UserPO>().WHERE(UserPO.tableColumns().id.eq(id)).first<UserPO>().getOrThrow()
    }
    func register(username: String, password: String): Int64 {
        let user = UserPO()
        user.username = username
        user.password = password
        executor.INSERT_INTO<UserPO>(user)          // 返回自增主键
    }
    func deleteUser(id: Int64): Int64 {
        executor.setSql('delete from user_info where id = ${arg(id)}').delete
    }
}
```

**【口播】**（这是 ORM 最反直觉也最爽的一点）

> `@DAO` 宏展开的结果是「原接口后面跟着`extend SqlExecutor <: UserDAO {}`」。
> 也就是说——**没有 DAO 实现类，`SqlExecutor` 本身就是实现**，接口里写的函数体就是方法实现。
> 所以约束是：
> - DAO **必须声明为接口**，且所有函数都要有默认实现；
> - 建议 `public`、**不要泛型形参**、继承 `RootDAO`；
> - **一个持久化对象对应一个 DAO 接口**；
> - **同一模块内所有 DAO 的函数名最好不要重名**（因为它们都挂在 `SqlExecutor` 上）。

### Service：`RootService` + `executor()`

```cangjie
public interface UserService <: RootService {
    func queryUser(id: Int64): UserPO
    ...
}

@TransactionalService      // 不需要事务时用 @Bean
public class UserServiceImpl <: UserService {
    public func queryUser(id: Int64): UserPO {
        executor().findUser(id)      // executor() 返回的 SqlExecutor 可直接当 UserDAO 用
    }
}
```

**【口播】**

> `RootService` 提供 `executor()` / `executor(name)` / `dao<T>()` / `dao<T>(driver)`。
> `@TransactionalService` 其实是 `f_aspect.macros.WeavedBean` 的再导出——它把 Service 织进切面链，事务切面才能生效。
>
> 两条铁律（**一定要念出来，这是最常见的线上事故来源**）：
> 1. **每次调用 DAO 函数都必须从 `executor()` 开始**——不要缓存 DAO 实例；
> 2. **一个 DAO 函数只执行一个 SQL**（或一次分页查询：一次 count + 一次列表）。

## 8.2 配置（环境变量）

```bash
export orm_drivers=postgres                  # 逗号分隔
export orm_defaultDriver=postgres            # 缺省取 drivers 第一个
export postgres_orm_connectionUrl=$POSTGRES  # 按驱动覆盖： <driver>_orm_<key>
export postgres_orm_option_username=$POSTGRES_USERNAME
export postgres_orm_option_password=$POSTGRES_PASSWORD
export orm_useCache=true                     # 结果缓存，默认 true
export orm_noPool=false
export orm_useStdPool=false                  # true=标准库池，false=fountain 池
export orm_useThirdPartyPool=false
export orm_databasePoolMaxSize=1
export orm_databasePoolMinSize=1
export orm_databasePoolInitSize=1
export orm_databasePoolConnectTimeout=50     # 毫秒
export orm_databasePoolCheckSql='select 1'
export orm_sm4Key=$(fboot randhex 32)
export orm_sm4Iv=$(fboot randhex 32)
```

> 约定：全局 `orm_<key>`；按驱动覆盖 `<driverName>_orm_<key>`，**后者优先级更高**。

## 8.3 构造 SQL 的三种方式（重点章节）

### 方式一：模板 SQL —— `setSql` + `arg()`

```cangjie
func deleteUser(id: Int64): Int64 {
    executor.setSql('''
        delete
          from user_info
         where id = ${arg(id)}
    ''').delete
}
```

**【口播】**

> `arg(x)` 做两件事：把 x 绑定到 `PreparedStatement`，并返回占位符 `'?'`。所以必须写成字符串插值 `${arg(x)}`。
> **所有参数都走绑定，不存在字符串拼接注入。**
> 支持 `Bool/Int*/UInt*/Float*/BigInt/Decimal/Rune/String/Duration/DateTime/InputStream/Array<Byte>/Data/Any`，以及这些类型的 `?T`（`None` 等价于 `argNull()`）。
>
> 集合展开（用于 `IN`）：
> ```cangjie
> arg(ids)          // 一维 → ' (?,?,?)'
> arg(matrix)       // 二维 → ' ((?,?),(?,?))'
> ```

### 方式二：面向对象 DSL —— `FROM` / `INSERT_INTO` / `UPDATE`

```cangjie
// 查询
executor.FROM<UserPO>()
        .WHERE(UserPO.tableColumns().id.eq(id))
        .first<UserPO>().getOrThrow()

// 插入对象，返回自增主键
let user = UserPO(); user.username = name; user.password = pwd
executor.INSERT_INTO<UserPO>(user)
executor.INTO<UserPO>(user, ignoreColumns: ['password'])

// 更新：Map 直改（key 可以是列名、成员名或 Column 对象）
let map = HashMap<Column, Any>()
map[UserPO.tableColumns().password] = password
map[UserPO.tableColumns().username] = username
executor.UPDATE<UserPO>(map)

// 更新：对象直改（主键作 WHERE 条件）
executor.UPDATE<UserPO>(user, dirty: true)   // 只更新脏字段
```

**【口播】** `dirty: true` 配合 `@QueryMappersGenerator[dirty]`：setter 会自动调用 `DirtyTag.setDirtyField`，`UPDATE` 时只更新被改过的列。

### 方式三：条件构造器 —— `meet` / `choose` / `loop` / `WHERE{}` / `SET{}`

```cangjie
// meet：条件成立才拼
executor.FROM<UserPO>()
        .WHERE(meet(userLike.size > 0){ UserPO.tableColumns().username.LIKE('%${userLike}%') })
        .ORDER_BY(UserPO.tableColumns().id.ASC())
        .page<UserPO>(100, page: 1)

// AND / OR / NOT（LogicalExpr 版本）
executor.FROM<UserPO>()
        .WHERE(AND(UserPO.tableColumns().username.eq(username),
                   UserPO.tableColumns().password.eq(password)))
        .singleFirst<Int64>(UserPO.tableColumns().id)

// 字符串版本的子句拼接
executor.setSql('update user_info ${SET { 'username = ${arg(name)}, password = ${arg(pwd)}' }} where id = ${arg(id)}')
executor.setSql('select * from user_info ${WHERE { 'id = ${arg(id)}' }}')
executor.setSql('select * from user_info where id ${IN(ids)}')
executor.setSql('select * from user_info where id = ${arg(id)} ${AND {'status = ${arg(status)}'}}')
```

**【口播】**

> 关系运算片段一览（注意它们只返回**运算符部分**，左值自己拼）：
> `IN(...)` / `NOT_IN(...)` / `LIKE(...)` / `NOT_LIKE(...)` / `BETWEEN(a,b)` / `EXISTS{...}` / `NOT_EXISTS{...}`，以及 `AND` / `OR` / `NOT` / `paren`。
>
> `WHERE{}` / `SET{}` 的好处是：**内容为空时自动省略关键字**，不会拼出 `where` 后面什么都没有的非法 SQL。

## 8.4 查询结果

```cangjie
// 单列
singleFirst<T>() / singleFirst<T>(index) / singleFirst<T>(column)
singleList<T>()  / singleIterator<T>()

// 对象（依赖 QueryMappers）
first<T>() / list<T>() / iterator<T>() / one<T>()

// 无类型
firstToMap() / mapList()

// 分页
let p = executor.FROM<UserPO>().page<UserPO>(10, page: 1)
p.page    // 当前页（从 1 开始）
p.size    // 每页大小
p.rows    // 总记录数
p.pages   // 总页数
p.list    // 当前页数据
```

**【口播】**

> 分页实现：先 `select count(*) from (<原始SQL>) as __tmp___` 算总数，再 `select * from (<原始SQL>) as __tmp___ <limit/offset>`。
> **limit/offset 由方言（Dialect）生成**，所以换数据库不用改代码。
> `Pagination<T>` 本身实现了 `ObjectData`，**可以直接作为 PO 的字段被序列化**（`fdemo` 的 `UserList.fields` 就是 `Pagination<UserPO>`）。

## 8.5 事务控制（本章重点，建议留 8 分钟）

### 三种开启方式

**① 注解 `@Transactional`**

```cangjie
@Transactional[propagation: Propagation.RequiresNew, rollbackFor: 'fountain::f_exception::BizException']
public func transfer(from: Int64, to: Int64, amount: Decimal): Unit { ... }
```

注解参数：`driverName` `propagation` `isoLevel` `accessMode` `deferrableMode` `rollbackFor` `noRollbackFor`。

**② 配置驱动（批量织入，无需逐个加注解）**

```bash
export orm_transactionalFuncExecution='*::*..*ServiceImpl.del*(**): *'
export orm_transactionalFuncExecution="$orm_transactionalFuncExecution|*::*..*ServiceImpl.insert*(**): *"
export orm_transactionalFuncExecution="$orm_transactionalFuncExecution|*::*..*ServiceImpl.save*(**): *"
export orm_transactionalFuncExecution="$orm_transactionalFuncExecution|*::*..*ServiceImpl.register*(**): *"
export orm_transactionalFuncExecution="$orm_transactionalFuncExecution|*::*..*.userSession(**): *"
# 还可以用正则做包含/排除
export orm_transactionIncluding='...'
export orm_transactionExcluding='...'
```

**【口播】**

> 这两条是 **OR 关系**：`@Transactional` 注解 和 `orm_transactionalFuncExecution` 配置**只要有一个命中，事务切面就会织入**。
>
> `fdemo` 的配置把 `del* remove* insert* save* add* new* create* update* change* register*` 以及 `userSession` 全织上了——**按方法名前缀约定统一开事务**，这是很实用的团队规范落地方式。
> 注意 `fdemo/boot.sh` 里 `sayHello` 那一行是**被注释掉**的，讲的时候可以现场打开它，重启后看 `HelloworldServiceImpl.sayHello` 也开始打事务日志——一个很好的即时反馈演示。

**③ 编程式：`execute` 模板**

```cangjie
executor.execute<Int64>(
    propagation: Propagation.Required,
    isoLevel: None,
    noRollbackFor: 'fountain::f_bean::BeanException',
    rollbackFor: ''
) { exec =>
    exec.setSql('...').update
    1     // 闭包返回 (T, Bool)：true 提交，false 抛异常并回滚
}
```

### 传播行为

| `Propagation` | 语义 |
| --- | --- |
| `Required` | 有则沿用，无则新建（**默认**） |
| `Supports` | 有则沿用，无则不用事务 |
| `Mandatory` | 有则沿用，无则抛 `MandatoryTransactionException` |
| `RequiresNew` | 外层有事务则**新取连接**开新事务 |
| `Never` | 不用事务，外层有则抛 `NeverTransactionException` |
| `NotSupported` | 不用事务，外层有事务则**新取连接**执行 |
| `Nested` | 外层有事务则开内嵌事务 |

默认传播行为、隔离级别、读写模式都可以用环境变量全局配置：

```bash
export orm_transactionPropagation=Required
export orm_transactionLevel=ReadCommitted
export orm_transactionAccessMode=ReadWrite
export orm_transactionNoRollbackFor='...'
export orm_transactionRollbackFor='...'
```

### 事务钩子 `TransactionHook`

**【镜头】** `fdemo/boot/src/TransactionHookImpl.cj`

```cangjie
@Bean
public class TransactionHookImpl <: TransactionHook {
    public func beforeTx(): Unit                    { log.info('beforeTx') }
    public func beforeCommit(readOnly: Bool): Unit  { log.info('beforeCommit') }
    public func afterCommit(): Unit                 { log.info('afterCommit') }
    public func afterThrowing(e: Exception): Unit   { log.info('afterThrowing') }
    public func beforeRollback(e: Exception): Unit  { log.info('beforeRollback') }
    public func afterRollback(e: Exception): Unit   { log.info('afterRollback') }
    public func afterComplete(status: TransactionStatus): Unit { log.info('afterComplete') }
    // prop order 决定多个钩子的执行顺序（升序）
}
```

注册方式：`ORM.registerTransactionHook<MyHook>(MyHook())` 或 `ORM.registerTransactionHooks<MyHook>()`（从 `lookupList<MyHook>()` 批量取）。

**调用顺序（建议做成动画或表格）**：

| 场景 | 顺序 |
| --- | --- |
| 正常提交 | `beforeTx` → `beforeCommit` → commit → `afterCommit` → `afterComplete(Committed)` |
| 一般异常 | `afterThrowing` → `beforeRollback` → rollback → `afterRollback` → `afterComplete(Rollback)` |
| 命中 `noRollbackFor` | `afterThrowing` → `beforeCommit` → **提交** → `afterCommit` → `afterComplete(Committed)` → 重抛 |
| 命中 `rollbackFor` | `afterThrowing` → `beforeRollback` → 回滚 → `afterRollback` → `afterComplete(Rollback)` → 重抛 |
| 配了 `rollbackFor` 但类型不匹配 | 同 `noRollbackFor`：**提交后重抛** |

**【演示】** 访问一次 `/api/user/register`（命中 `register*` → 事务生效），控制台依次出现：

```
[INFO-TransactionHook]...beforeTx
[INFO-TransactionHook]...beforeCommit
[INFO-TransactionHook]...afterCommit
[INFO-TransactionHook]...afterComplete
```

**【演示】** 访问 `/api/error` 或让某个 DAO 抛异常 → 出现 `afterThrowing` / `beforeRollback` / `afterRollback`。

### 底层：为什么同一线程共用连接

**【口播】**

> `SqlExecutor` 缓存在 `ThreadLocal<HashMap<String, SqlExecutor>>` 里，按驱动名区分。
> 所以**同一线程内一次事务的多次数据库访问，用的是同一个连接**——这是事务能成立的根本。
> 事务未开启时，执行完就 `close()` 释放连接；事务中则由 `commit()` / `rollback()` 收尾统一处理。

## 8.6 ORM 常见坑（念一遍能省观众两天）

1. 一个 DAO 函数只执行一个 SQL（或一次分页查询）；
2. 每次调用 DAO 都必须从 `executor()` 开始；
3. 同一模块内 DAO 函数名不能重名；
4. 同一个 `SqlExecutor` 上**不允许并发**：上一次查询结果未关闭时再执行会抛 `ORMException("cannot execute SQL while a previous query result is still active")`；
5. 结果缓存默认开启（`orm_useCache`），写操作后会清空缓存；
6. `@DataAssist` 必须在 `@QueryMappersGenerator` 之前；
7. `tableColumns()` 的属性名是**列名**不是映射类的成员名（`save_time` 不是 `saveTime`）；
8. `page` 系列要求 SQL 以 `select` 开头，否则抛 `ORMException('<sql> is not a select.')`。

---

# 第九章 安全：`f_security` + `f_jwt`

**【镜头】** `fdemo/user/src/util/UserSessionCache.cj`、`util/auth/AuthCheckerImpl.cj`、`f_mvc/src/AuthHandler.cj`

## 9.1 登录状态检查怎么做（重点）

### 第一步：实现 `AuthHandler` 并注册为 bean

```cangjie
@Bean
public class AuthCheckerImpl <: AuthHandler {
    public func check(param: AuthParam): AuthStatus {
        if (param.ignoreAuth) {
            OK
        } else if (UserSessionCache.verify()){
            OK
        } else {
            let json = '{ "status":-1 }'
            InvalidSession(HttpStatus.UNAUTHORIZED, JsonValue.fromStr(json))
        }
    }
}
```

`AuthParam` 提供了：`ctx`（当前 `HttpContext`）、`path`（**controller 定义的映射路径**，不是请求路径）、`args`（参数）、`ignoreAuth`、`ignorePrivilege`。

`AuthStatus` 是一个枚举，决定 MVC 怎么响应：

```
OK                          通过
SessionNotFound(status,any) 没找到登录状态（未登录/已过期）
InvalidSession(status,any)  找到了但本次传入的登录信息无效
SessionError(status,any)    检查登录状态时出错
PrivilegeError(status,any)  检查权限时出错
NoPrivilege(status,any)     没有权限
```

> 不带 `HttpStatus` 的构造器表示状态码 200；带的话用你指定的状态码。
> `Any` 实际支持 `String` / `ToString` / `InputStream` / `Array<Byte>` / `f_data.ToData`。

### 第二步：MVC 怎么挑 handler

**【口播】**（把 `AuthHandlerProxy` 的判断顺序讲清楚，这决定了你的类该怎么设计）

```
1. ignoreAuth && ignorePrivilege 都为 true          → 直接 OK（不查）
2. 存在「通用」AuthHandler                          → 用它一次检查完
3. 否则：!ignoreAuth 且 UserSessionHandler 存在且通过 → 返回 OK
4. 否则：!ignorePrivilege 且 PrivilegeHandler 存在   → 用它检查
5. 都没有                                           → OK
```

> **重要结论**：第 3 步一旦通过就直接返回，**第 4 步的权限检查不会执行**。
> 所以源码注释明确写着：**如果登录状态和权限都要检查，务必在同一个类里实现、一次调用检查完**——`fdemo` 的 `AuthCheckerImpl` 就是这个做法。
> 如果你的系统权限模型很复杂，可以实现 `UserSessionHandler` 和 `PrivilegeHandler` 两个 bean，但要清楚这个优先级语义。

### 第三步：在 controller 上放行

```cangjie
@IgnoreSecurity                                              // 注解方式
// 或
@PostMapping[..., ignoreAuth: true, ignorePrivilege: true]   // Mapping 属性方式
```

## 9.2 用 JWT 维持登录状态

**【镜头】** `fdemo/user/src/util/UserSessionCache.cj`（完整代码建议整屏展示）

```cangjie
public class UserSessionCache {
    // ① 安全上下文：JWT 登录状态 + 堆缓存（有效期 1 小时）+ 生成 principal + 校验函数
    private static let context = JWTSecurityContext<String>(
        JWTHeapCacheStore(Duration.hour),
        {id => JWTPrincipal<String>(id, '', UUID.random().toHexString())}   // 每个登录一把随机签名密钥
    ){verifier, principal => hmacKey(verifier, principal)}

    private static func hmacKey<T>(jwt: T, key: Array<Byte>): T where T <: JWT {
        jwt.hmacMD5(key)
    }
    private static let expire = Duration.hour

    // ② 登录：生成 JWT
    public static func generate(userId: Int64): String {
        let uids = userId.toString()
        let principal = context.login(uids).getOrThrow{SecurityException()}
        hmacKey(JWT.encoder(), principal).keyId(uids).expire(expire).sign()
    }

    // ③ 校验：从当前请求的 Authorization 头里取 JWT 校验
    public static func verify(): Bool {
        context.check(())
    }
}
```

**【口播】**

> 三件事：
> 1. `JWTSecurityContext<String>` —— 用 HTTP `Authorization` 头传递 JWT 的登录状态上下文，身份（`JWTPrincipal<String>`）存在 `JWTHeapCacheStore`（堆缓存，1 小时）里；
> 2. 每次登录用 `UUID.random().toHexString()` 生成一把**独立的 HMAC 密钥**，存进 principal —— 也就是**每个会话一把钥匙**；
> 3. `context.login(id)` 存状态，`context.check(())` 直接从 `CurrentHttpContext` 取当前请求校验——**所以校验逻辑不用写在 controller 里**。

### 其它登录状态方案

| 类型 | 用途 |
| --- | --- |
| `JWTSecurityContext<U>` | 用 `Authorization` 头传 JWT |
| `UserTokenSecurityContext<ID, U>` | 用请求头传 `userId` + `token` |
| `HeapCacheStore<ID, P>` / `UserTokenHeapCacheStore<ID>` | 堆缓存登录状态 |
| `PrincipalStore<ID, P>` | 自己实现（Redis 等） |

```cangjie
public interface PrincipalStore<ID, P> {
    func store(principal: P): Unit
    func get(id: ID): ?P
    func remove(id: ID): ?P
}
public interface Principal<ID, P> {
    prop id: ID
    prop username: String
}
```

**【口播】** 想把登录状态放 Redis？实现 `PrincipalStore` 做成 `@Bean` 就行，其他代码一行不用改。

## 9.3 `f_jwt` API 速览

### 编码（签名）

```cangjie
let token = JWT.encoder()
    .header('x-custom', 'v')            // 自定义 header
    .hmacMD5(key)                       // 也支持 ByBase64Key / ByHexKey
    .keyId('12345')                     // kid
    .issuer('fountain')                 // iss
    .subject('user')                    // sub
    .audience('web')                    // aud
    .expire(Duration.hour)              // exp（也支持 Int64 秒 / DateTime / expireAt）
    .notBeforeAt(DateTime.nowUTC())     // nbf
    .issuedAt(DateTime.nowUTC())        // iat
    .addPayload('userId', 123)          // 自定义负载
    .sign()
```

签名算法全家桶：

- HMAC：`hmacMD5` / `hmacSHA1` / `hmacSHA224` / `hmacSHA256` / `hmacSHA384` / `hmacSHA512`
  （每种都有 `key: Array<Byte>`、`ByBase64Key(String)`、`ByHexKey(String)` 三个重载）
- 非对称：`ecdsa224/256/384/512(privateKeyPem:, publicKeyPem:)`、`rsa256/384/512(privateKeyPem:, publicKeyPem:, padType:)`、SM2（`SM2SignAlgo`）

负载还可以一次性塞进对象或 Map：

```cangjie
.addPayload(userObject)      // T <: Object & ObjectData<T>：公共成员当负载
.addPayload(map)             // Map<String, V>
.jwtId(jti, expire: d, cache: HeapJwtIdCache<T>())   // jti + 防重放缓存
```

### 解码（验签）

```cangjie
let v = JWT.verifier(token)
v.getKeyId()                 // ?String
v.getPayload('userId')       // ?Any
v.getPayloadValue<Int64>('userId')
v.getHeader('alg')           // ?String
v.getExpireAt()              // ?DateTime   （还有 ...Duration / ...Seconds）
v.getNotBefore()
v.isExpired()                // 默认以 DateTime.nowUTC() 判断
v.isNotBefore()
v.verifySign()               // 只验签名
v.verify()                   // exp + nbf + sign 一起验
v.verifyIssuer('fountain')
v.verifySubject('user')
v.verifyAudience('web')
v.verifyPayload('userId', 123)
v.verifyId(cache)            // jti 是否有效
```

**【口播】**

> `verify()` 已经把 `exp`、`nbf`、签名都检查了；没有指定 `exp`/`nbf` 的字段就认为该维度当前有效。
> `jti` 配合 `JwtIdCache`（内置 `HeapJwtIdCache` / `NoneJwtIdCache`）可以做**防重放**。

## 9.4 端到端演示（登录 → 拿 JWT → 访问）

**【命令】**

```bash
# 1) 注册
curl -XPOST 'http://localhost:8080/api/user/register' \
  -H 'Content-Type:application/x-www-form-urlencoded' -H 'Accept:text/plain' \
  -d 'username=abcdef&password=bcbcbcbc'

# 2) 登录（返回 jwt）
JWT=$(curl -s -XPOST http://localhost:8080/api/user/session \
  -H 'Content-Type:application/json' -H 'Accept:application/json' \
  -d '{"username":"abcdef","password":"bcbcbcbc"}' | grep -o '"jwt":"[^"]*"' | cut -d'"' -f4)
echo $JWT

# 3) 不带 JWT：401
curl -i -H 'Accept:application/json' http://localhost:8080/api/user/1

# 4) 带 JWT：200
curl -i -H 'Accept:application/json' -H "Authorization: $JWT" http://localhost:8080/api/user/1
```

**【预期】** 第 3 步 `HTTP/1.1 401 Unauthorized` + `{"status":-1}`；第 4 步 `200` + 用户 JSON。

**【口播】**（把调用链串一遍）

```
HTTP 请求
  → MVC 路由到 UserController.queryUser
  → AuthHandlerProxy.check(AuthParam{ignoreAuth:false, ...})
  → AuthCheckerImpl.check
  → UserSessionCache.verify()
  → JWTSecurityContext.check(())
      ├─ 从 CurrentHttpContext 拿 Authorization 头
      ├─ JWT.verifier(token).verify()   （验签 + exp + nbf）
      └─ 用 principal.key 做 HMAC 密钥
  → OK → 才进入 queryUser → Service → DAO → DB
```

---

# 第十章 CRON 定时任务：`fountain::f_ticktock`

**【镜头】** `fdemo/user/src/util/cron/TickTockTest.cj`

## 10.1 最小可用

```cangjie
import fountain::f_ticktock.*
import fountain::f_bean.*
import fountain::f_bean.macros.*

@Bean
public class TickTockTaskImpl <: CronTicktockTask {
    public prop cron: String {
        get() { '1/3-45' }        // cron 表达式，尾部的 * 可以省略
    }
    public func execute(): Unit {
        log.info('TickTockTaskImpl is executing')
    }
}
```

**【口播】**

> 只有两件事必须做：**实现 `CronTicktockTask`** 和 **`@Bean`**。
> 第三件事是隐式的、也是最容易忘的：**它所在的包必须被 `--dylibPattern` 匹配到**。
> `fdemo` 里它放在 `user/src/util/cron/`，所以 `boot.sh` 的正则里专门有 `user\.util\.(auth|cron)` 这一段。
> **忘了这一段，定时任务不会报错，只是永远不执行**——这是个非常适合在视频里演示的「静默失效」坑。

## 10.2 可选属性

```cangjie
public prop once: Bool { get() { false } }           // true = 只执行一次
public prop concurrentable: Bool { get() { false } } // true = 上次没跑完也允许下次触发
public func executing(stamp: Int64): Bool { ... }    // 自定义「是否正在执行」判断
public func reset(stamp: Int64): Unit { ... }        // 自定义重置执行状态
public open prop name: String { get() { ... } }      // 默认取类型全限定名
```

## 10.3 CRON 表达式语法

时间单位从左到右：**秒 / 分 / 时 / 日 / 月 / 周 / 年**。

| 语法 | 含义 |
| --- | --- |
| `*` | 任意值 |
| `start-end` | 闭区间范围 |
| `start/step` | 从 start 开始，间隔 step |
| `start/step-end` | 从 start 开始，间隔 step，到 end 为止 |
| `a,b,c` | 取值列表 |
| `1,3,5-10,12/3,15/2-45` | 多种写法用 `,` 组合 |
| `L` | 当前时间单位的**最后一个值**（对「日」来说就是当月最后一天） |
| 尾部 `*` | 可以省略 |

**【口播】** `'1/3-45'` 这个例子读作：从第 1 秒开始、每 3 秒一次、直到第 45 秒。完整写法是 `1/3-45 * * * * * *`。

## 10.4 延迟任务

```cangjie
public abstract class DelayedTicktockTask <: CronTicktockTask {
    public prop delayedPeriodic: DelayedPeriodic  // FixedRate：固定频率；FixedDelay：上次结束后再间隔
    public prop immediate: Bool                   // 注册后是否立即执行
    public prop delay: Duration                   // 延迟间隔
    public func execute(): Unit
}
```

**【演示】** 启动 `fdemo`，观察控制台每隔几秒打印一次 `TickTockTaskImpl is executing`。

---

# 第十一章 串讲：一次请求穿过整个框架

**【镜头】** 画一张纵向调用链 + 终端实时日志。用一个 `POST /api/user/register` 走完全流程。

```
① fboot run 加载动态链接库
   └─ static init(): @Bean 注册进 BeanFactory；Initializer 注册进 InitializerCollection
   └─ 拓扑排序 initialize()：BeanInitializer → ORMInitializer → MVCInitializer → TickTockInitializer ...
   └─ 各 start() spawn 到新线程：MVC 启动 HTTP 服务（阻塞）、TickTock 启动定时器

② curl -XPOST /api/user/register
   └─ MVC 路由匹配（@PostMapping + consumes/produces/params/headers）
   └─ 参数绑定（@RequestParam）→ 数据校验（@CombinedValidator）
   └─ AuthHandlerProxy.check：ignoreAuth=true → 直接 OK
   └─ 【AOP】ControllerAspect.around（controllerPointcut 命中）
        └─ 原函数体 register()
             └─ lookup<UserService>() → UserServiceImpl
                  └─ 【AOP】TransactionAspect（orm_transactionalFuncExecution 命中 register*）
                       └─ orm execute：newTxAndBegin
                            ├─ TransactionHook.beforeTx
                            ├─ executor().register(...)  ← SqlExecutor 即 UserDAO
                            │    └─ INSERT_INTO<UserPO>(user) → 绑定参数 → 执行
                            ├─ TransactionHook.beforeCommit
                            ├─ commit
                            ├─ TransactionHook.afterCommit
                            └─ TransactionHook.afterComplete(Committed)
   └─ 返回值按 produces 序列化

③ 定时线程：TickTockTaskImpl 按 cron 触发（独立线程，与请求互不干扰）
```

**【口播】**

> 这一屏就是 fountain 的全部：
> **f_bean 负责装配、f_aspect 负责横切、f_mvc 负责协议、f_orm 负责数据库、f_security + f_jwt 负责身份、f_ticktock 负责CRON定时器。**
> 业务代码里你只写了 `UserController`、`UserService`、`UserDAO`、`UserPO` 四个东西，加起来不到 200 行。

---

# 第十二章 收尾：常见坑与 Q&A

## 12.1 十个高频坑

| # | 现象 | 原因 / 解法 |
| --- | --- | --- |
| 1 | `fboot` 起不来，报找不到动态链接库 | `LD_LIBRARY_PATH` 没带 `~/.cjpm/libs/fboot` 和 stdx 动态链接库路径 |
| 2 | bean 明明写了却不生效 | 它所在的动态链接库没被 `--dylibPattern` 匹配到（鉴权器、切面、定时任务尤其致命） |
| 3 | 改了依赖后各种诡异错误 | `fboot cleanUpdate` 一把梭 |
| 4 | 定时任务不执行 | 同上第 2 条 |
| 5 | 事务没生效 | Service 用了 `@Bean` 而不是 `@TransactionalService`；或方法名没被 `orm_transactionalFuncExecution` 命中；也没加 `@Transactional` |
| 6 | `cannot execute SQL while a previous query result is still active` | 同一个 `SqlExecutor` 上一次结果没关闭就又执行 |
| 7 | DAO 报「不是 select」 | `page` 系列要求 SQL 以 `select` 开头 |
| 8 | `tableColumns().xxx` 找不到 | 属性名是**列名**（`save_time`），不是成员名（`saveTime`） |
| 9 | 宏报「must be modified by public var or public mut prop」 | `@ORMField` 的约束 |
| 10 | `fboot run` 卡住不动 | 这是**预期行为**，它永久阻塞；另开终端发请求 |

## 12.2 预设 Q&A

**Q：能不用动态链接库吗？**
A：IOC/AOP/ORM 这些能力本身不依赖动态链接库，但 `fboot run` 的「扫描加载」机制依赖它。用 `App(..., dynamic: false)` 可以不扫描，此时只有内置命令和静态链接进来的子命令可用，业务 bean 需要你自己保证已被加载。

**Q：性能如何？**
A：`fboot build` 默认带 `-O2 --lto=full`；ORM 有结果缓存（可按驱动关）、连接池可选 fountain 池 / 标准库池 / 第三方池；`boot.sh` 里还有 `perfRecord` / `perfReport`（`cjprof`）和 `loop` / `ab` 可以直接做基线测量。**不要凭感觉谈性能，先跑 `./boot.sh ab 16 10000`。**

**Q：能只用一个模块吗？**
A：可以。`f_base`、`f_util`、`f_collection`、`f_crypto` 等都是独立可用的工具库，在 `cjpm.toml` 里只加你需要的那一个即可。

**Q：数据库不支持怎么办？**
A：`f_orm` 基于 `std.database.sql`，只要有驱动就能用；配置项 `orm_drivers` 是逗号分隔的，可同时注册多个数据源，`ORM.executor(driverName)` 按驱动名取。还可以用 `f_mockdb` 做无数据库的集成测试。

---

# 附录 A：一页速查表

## 命令

```bash
fboot workspace [<dir>] [x.y.z]         # 初始化 workspace（重写 cjpm.toml）
fboot module [<name>]                   # 初始化/新增 dynamic 模块并挂进 members
fboot build [PATH] [--k=v ...]          # 编译；--k=v 作为编译期环境变量注入产物
fboot cleanUpdate [PATH]                # cjpm clean + 删 cjpm.lock + cjpm update
fboot run [PATH] --dylibPattern=<正则>   # 启动（永久阻塞）
fboot randhex <n>                       # n 位随机小写 16 进制（SM4 key 用 32）
fboot count [PATH]                      # 代码统计
fboot test [PATH] --dylibPattern=<正则>  # test/cjpm.toml 覆盖后 build+run
fboot pub <x.y.z> [--skip-lint] [--skip-test]
fboot shutdown <PID> / fboot restart <PID> [PATH] --dylibPattern=<正则>
fboot version [<x.y.z> [msg] [tag [tagmsg]]]
fboot help
```

## 注解 / 宏

| 模块 | 宏 / 注解 | 作用 |
| --- | --- | --- |
| f_bean | `@Bean` `[泛型实参|...]` | 注册为 bean |
| f_bean | `@BeanMeta[name scope lazy primary order condition]` | bean 元数据（须配 `@Bean`） |
| f_bean | `@Constructor` / `@BeanParam(attr)` / `@Value[name default dateFormat delim]` | 构造注入 |
| f_bean | `@Configuration` + `@BeanInit` | 初始化函数集合 |
| f_aspect | `@AspectRoute[规则]` | 声明切面的织入规则 |
| f_aspect | `@Pointcut` / `@WeavedBean` | 织入 |
| f_mvc | `@Controller` / `@WeavedController` | 声明 controller |
| f_mvc | `@Get/Post/Put/Delete/PatchMapping[path produces consumes params headers ignoreAuth ignorePrivilege]` | 路由 |
| f_mvc | `@RequestParam` `@RequestParamObject` `@PathVariable` `@RequestHeader` `@RequestBody` | 参数绑定 |
| f_mvc | `@IgnoreAuth` `@IgnorePrivilege` `@IgnoreSecurity` | 安全放行 |
| f_orm | `@QueryMappersGenerator[table ... dirty]` + `@ORMField[true 'col']` | PO 映射 |
| f_orm | `@DAO` | DAO 接口（`<: RootDAO`） |
| f_orm | `@TransactionalService` | Service 织入（等价于 `@WeavedBean`） |
| f_orm | `@Transactional[propagation rollbackFor noRollbackFor ...]` | 声明式事务 |
| f_data | `@DataAssist[equal hash tostring props fields]` | 生成通用方法 |
| f_data | `@CombinedValidator[...]` `@IsNotBlank[...]` `@StringSize[min max]` | 数据校验 |
| f_ticktock | `@Bean` + `CronTicktockTask` | 定时任务 |

## 关键 API

```cangjie
lookup<T>() / lookup<T>(name) / lookup<T>(cond) / lookupOption / lookupList / lookupHashMap
ORM.initialize() / ORM.register(...) / ORM.executor() / ORM.executor(driver)
executor.setSql(...).update / .insert / .delete
executor.FROM<T>().WHERE(...).ORDER_BY(...).page<T>(size, page:)
executor.INSERT_INTO<T>(po) / executor.UPDATE<T>(map|po, dirty:)
executor.execute<T>(propagation:, rollbackFor:) { exec => (result, true) }
CurrentHttpContext.instance
JWT.encoder()....sign()  /  JWT.verifier(token).verify()
```

---

# 附录 B：录屏分镜建议

| 镜 | 时长 | 内容 | 画面 |
| --- | --- | --- | --- |
| 1 | 3' | 开场：为什么用 fountain（痛点清单） | 幻灯片 |
| 2 | 5' | 三个设计决策：无 main / 宏 / 环境变量 | 幻灯片 + `fboot/src/main.cj` |
| 3 | 3' | 环境准备 | 终端 |
| 4 | 2' | `fboot help` | 终端 |
| 5 | 4' | `fboot workspace` + `fboot module`（从零建项目） | 终端 + IDE |
| 6 | 3' | 写一个 Controller（20 行） | IDE |
| 7 | 4' | `fboot build`（讲版本模块 + banner + 编译期注入） | 终端 + `boot.sh` |
| 8 | 2' | `fboot randhex` + SM4 密钥 | 终端 |
| 9 | 3' | `fboot run` + curl 验证（第一个 hello world） | 终端 |
| 10 | 2' | `fboot cleanUpdate` | 终端 |
| 11 | 5' | 切到 `fdemo`：结构 + 建表 + build + run | IDE + 终端 |
| 12 | 6' | 接口验证清单（12 条 curl，重点 401 那条） | 终端 + 浏览器 |
| 13 | 8' | IOC：f_bean | IDE + 幻灯片 |
| 14 | 7' | AOP：f_aspect + `ControllerAspect` 现场演示 | IDE + 终端 |
| 15 | 10' | MVC：f_mvc（路由/参数/校验/异常/MediaType） | IDE + 终端 |
| 16 | 15' | ORM：f_orm（PO/DAO/Service/SQL 三方式/分页） | IDE |
| 17 | 8' | 事务：三种开启方式 + 钩子顺序 + 现场日志 | IDE + 终端 |
| 18 | 8' | 安全：f_security + f_jwt 端到端 | IDE + 终端（401 vs 200） |
| 19 | 4' | CRON：f_ticktock（含"忘了 dylibPattern"的坑） | IDE + 终端 |
| 20 | 4' | 串讲：一次请求的完整穿越 | 架构图 |
| 21 | 4' | 坑 & Q&A + 性能压测 | 终端 |

---

> 讲稿中所有的路径、包名、注解名均取自本仓库当前源码（`fboot`、`f_app`、`f_bean`、`f_aspect`、`f_mvc`、`f_orm`、`f_security`、`f_ticktock`、`f_jwt`、`fdemo`）。
> 若后续版本有变更，以各模块 `README.md` 与源码为准。

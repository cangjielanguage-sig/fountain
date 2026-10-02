# fountain 讲稿

## 一站式服务器应用开发工具库

> 配套项目：`fdemo`（仓库内的示例工程，本讲稿所有命令都以它为蓝本）
> 目标：讲清楚「为什么用 fountain」「怎么用 fboot」「IOC / MVC / AOP / ORM 怎么用」，并且全程可以一边讲一边敲命令、一边看输出。
> 建议录制时长：约 155～185 分钟（可按章节裁剪；核心链路是 第一、三、四、六、八、九、十、十一、十五（日志）、十六（串讲）章；第十七章（运行时基础设施，含随机数）可按受众深浅整章跳过或挑讲；日志这一章不要跳，至少讲到 15.2 与 15.7）

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
> | 配置 | `f_config` | **没有配置文件**：环境变量 / 命令行 / `Config.set` / 编译期 SM4 内嵌，四级优先级 |
> | IOC 容器 | `f_bean` | `@Bean` + `lookup<T>()`，宏在编译期完成注册 |
> | AOP | `f_aspect` | `Aspect` 接口 + 织入规则，横切逻辑集中一处 |
> | 数据 | `f_data` | `@DataAssist` 一把宏搞定对象复制、JSON 互转、校验、JSONPath |
> | MVC | `f_mvc` | `@Controller` + `@GetMapping`，HTTP 服务开箱即用 |
> | HTTP 数据格式 | `f_http` | `MediaType` 抽象（json / text / multipart）+ 文件上传，可扩展私有协议 |
> | ORM | `f_orm` | DAO 就是接口，`@DAO` 以后 `SqlExecutor` 就是实现 |
> | 安全 | `f_security` | 登录状态、鉴权、权限检查的统一抽象 |
> | JWT | `f_jwt` | 完整的 JWT 编码 / 验签 API |
> | CRON | `f_ticktock` | `@Bean` + cron 表达式即可定时执行 |
> | 随机 | `f_random` | 区间随机数、随机数流、随机字符串、蓄水池抽样 |
> | 工具箱 | `f_util` | UUID(v1~v8) / IdMaker / TextTemplate / PathPattern / TreeTransformer / CaseFormat / 设计模式骨架 |
> | 日志 | `f_log` | `stdx.log` 的实现：默认静默、appender 即输出通道、全程异步、模板化消息 |
> | 基础设施 | `f_cache` `f_pool` `f_collection` `f_time` `f_regex` `f_rx` | 堆缓存 / 对象池 / 集合补位 / 时间 DSL / 正则缓存 / 反应式编程 |
> | 启动器 | `fboot` / `f_app` | 没有 `main` 也能启动应用 |
>
> 外围还有 `f_base` `f_util` `f_collection` `f_concurrent` `f_http` `f_net` `f_pool` `f_crypto` `f_store` `f_rpc` `f_llm`……它们既能被框架使用，也能单独当作工具库引入。
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

### 决策二：项目初始化，宏为主，注解为辅，装配代码由宏在编译期生成；反射只在两处点一下

**【口播】**

> 先把话说准：fountain **也用了很多注解**。IOC 的 bean 元数据（`@BeanMeta`）、AOP 的织入规则（`@AspectRoute`）、controller 的 HTTP 映射（`@GetMapping`、`@PostMapping`）与参数绑定（`@RequestParam`、`@RequestBody`）——**这些都是注解**，写起来和 Spring 很像。
>
> 区别在于**注解由谁处理、什么时候处理**。`@Bean`、`@Controller`、`@DAO`、`@QueryMappersGenerator`、`@ORMField`、`@DataAssist` 这些在 fountain 里是**仓颉宏**：编译期就把注册代码、getter/setter、列映射、DAO 实现扩展全部生成好了。所以你不会看到 XML，也不会有「启动扫包扫半天」——注解负责声明，干活的是宏在编译期生成的代码。
>
> 反射用得极少，只有两个时机各点一下，点完就走：
> - **启动初始化时**：读一遍注解、类型和函数签名，把 bean 表、路由表建起来；
> - **切点函数第一次被调用时**：算出这条链上要织入哪些切面，之后缓存住，后续调用直接走缓存。
>
> 而且这两处反射都只用来**取信息**——注解、类型、函数（参数与返回值），**不会用反射去调你的方法、读写你的字段**。能编译期解决的，绝不留到运行期。
>
> 代价是：宏的用法必须遵守它的约定（比如 `@ORMField` 只能修饰 `public var` 或 `public mut prop`），这些约定编译期就会报错，不会拖到线上。

### 决策三：一切配置都是环境变量或 `--key=value` 命令行参数，运行期优先级高于编译期

**【口播】**

> fountain 没有自己的配置文件格式。端口、连接池、事务规则、日志格式、数据库连接串——全部来自**环境变量或 `--key=value` 形式的命令行参数**，两者完全平级，同名时命令行参数生效。
>
> 好处是容器化/Docker/K8s 天然适配；更妙的是 `fboot build` 支持把SM4 加密KEY/IV、数据库连接URL、数据库的用户名密码以`--key=value` 命令行参数的形式或者环境变量的形式**在编译期注入到产物里**，而运行期的同名环境变量或命令行参数会**覆盖**它。
所以你可以：
> - 做到运行环境敏感信息安全性
> - 运行期用环境变量或命令行参数覆盖，做到「一份产物、多环境部署」。
>
> 这套机制由 `fountain::f_config` 提供，**第四章会完整展开**：命令行参数的四种写法、四级读取优先级、SM4 加密内嵌敏感配置、以及 `@EmbedSensitive` 宏。

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
> 也就是说，**fboot 只是 `f_app` 的一个壳**。所有子命令的实现都在 `fountain::f_app.App` 里。理解这一点很重要：你自己的应用也可以用同样的方式启动，而且可以用 `SubCommandMediator` 注册自己的子命令。

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

> 一句话总结：**workspace 是「装模块的盒子」，每个模块都必须编译为动态链接库。**

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
  --sm4Key=$(fboot randhex 32) \
  --sm4Iv=$(fboot randhex 32)
```

**【口播】**

> 这些 `--xxx=yyy` 会变成 `fboot build` 执行时的配置项。
> 也可以把`--`去掉，改成环境变量，也是一样的效果。
> 于是：
> - 数据库连接串、用户名密码在**编译期**就被写进产物；
> - 因为同时给了 `sm4Key` / `sm4Iv`，这些敏感信息是 **SM4 加密后的字节数组**嵌入的，不是明文；
> - **运行期同名环境变量优先级更高**——运行环境如果同名配置项有其他值，可以用新值覆盖即可，一份产物跑多套环境。
> 覆盖方法也很简单，同样是`--`开头的命令行参数或同名的环境变量。
> 顺带提醒：真实项目不要把密码写进 `boot.sh`，这里只是演示。
>
> 这套「编译期内嵌 + 运行期覆盖」的完整机制，见**第四章 `f_config`**。

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
> **注意**：**`fboot run` 不会返回**

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

# 第四章 配置：`fountain::f_config`

**【镜头】** `f_config/README.md` + `fdemo/boot.sh`（那一整屏 `export`）+ `fdemo/boot-win-gitbash.sh`

## 4.1 开场：fountain 没有配置文件

**【口播】**

> 上一章你已经看到：`fboot build`、`fboot run` 后面总要挂一长串参数——**那些全都是配置**：`mvc_port`、`orm_drivers`、`logger_*`、`controllerPointcut`……
> 它们全都由 `f_config` 统一读取。而 `f_config` 最重要的一句话是：
>
> **「不依赖任何配置文件。」**
>
> 配置项只有四个来源：**环境变量**、**`--key=value` 形式的命令行参数**、进程内 `Config.set`、以及编译期内嵌的敏感配置。没有 `application.yml`，没有 properties，没有 JSON。
>
> 前两个是**完全平级**的：环境变量能做的事，命令行参数都能做，而且**命令行参数会覆盖同名环境变量**。
>
> 这里先埋一个后面会反复用到的规则：**只要一个仓颉进程链接了 `f_config`，它的命令行参数就会被自动解析成配置项**——不限于 `fboot` 的任何子命令，也包括你自己写的、依赖了 `f_config` 的程序。**4.2 会详细讲。**

| 来源 | 形态 | 何时生效 |
| --- | --- | --- |
| 环境变量 | `export mvc_port=8080` | 进程启动时由 `static init` 装载 |
| 命令行参数 | `--mvc_port=9090` | 同上，**覆盖同名环境变量** |
| 进程内 `Config.set(...)` | `Config.set<Int64>([('mvc_port', 9090)])` | 运行期写入/覆盖 |
| 编译期内嵌的敏感值（`@EmbedSensitive`） | `fboot build --paySecret=xxx` | 编译时嵌入产物，运行期解密/还原 |

**【口播】**

> 命令行参数这一条我要特别强调：**`fdemo/boot.sh` 的 `build()` 函数就是现成的例子**——它把驱动名、连接串、用户名、密码、SM4 密钥全部写成 `--orm_drivers=postgres --postgres_orm_connectionUrl=...` 这样的 `--key=value`，而不是 `export`。**详见 4.2。**
>
> 这一条直接决定了部署形态：**一份编译产物，靠环境变量或命令行参数跑遍开发/测试/生产**。这也是 `fboot build --k=v` 那套编译期注入能成立的前提。

## 4.2 命令行参数的四种合法写法

```
--argName=argValue     # key = '=' 左侧，value = '=' 右侧，两侧都 trimAscii，为了跟cjpm参数区分，fboot build只支持这一种写法
--argName              # 等价于 --argName=true
-argName argVal        # 下一个参数若以 '-' 开头则不当作值，该配置项值为 true
-argName               # 等价于 -argName true
```

- 单横线形式**不支持 `=` 赋值**，`-argName=argValue` 会被整体当成配置项名；
- 不以 `-` 开头的参数被忽略；`env.getCommandLine()[0]`（程序自身路径）不参与解析；
- **命名风格不被改写**——仓颉运行时自身的环境变量是驼峰命名，业务配置建议同样用驼峰。

### 现成的例子：`fdemo/boot.sh` 的 `build()` 函数

**【镜头】** `fdemo/boot.sh` 的 `build()`（顺带把它上面那段被注释掉的「环境变量版」一起放出来做对比）

```bash
build(){
    export CANGJIE_STDX_PATH=$CANGJIE_STDX_DYNAMIC_PATH

    # 下面全部是 --key=value 形式的命令行参数
    args='--orm_drivers=postgres'
    args="$args --postgres_orm_connectionUrl=$POSTGRES"
    args="$args --postgres_orm_option_username=$POSTGRES_USERNAME"   # 用户名密码也可以放进 connectionUrl
    args="$args --postgres_orm_option_password=$POSTGRES_PASSWORD"
    args="$args --sm4Key=$(fboot randhex 32)"   # 每次加密用不同的 KEY
    args="$args --sm4Iv=$(fboot randhex 32)"
    # 以上是敏感信息

    fboot build $target_path $args     # ← 注意 $target_path 必须是第一个参数
    echo -e '\a'
}
```

而就在它上面，作者留了一段**被注释掉的等价写法**，用的全是 `export`。注释原文写得很直白：

```bash
###############上面注释的跟下面的脚本功能是一样的，只是一个环境变量，一个命令行参数########################
```

**【口播】**

> 这一屏请记住三件事：
> 1. **`--key=value` 和 `export` 完全等价**——选哪个纯粹是部署习惯：容器里用环境变量方便，脚本里用命令行参数直观、能一眼看全；
> 2. 注意 `$target_path` 必须是 `build` 后的**第一个参数**（见第三章 3.4），`--k=v` 们排在它后面；
> 3. **别误以为这是 `fboot` 的特权**——下一节会说清边界：只要进程链了 `f_config`，命令行参数就自动是配置项。
>
> Windows 版 `boot-win-gitbash.sh` 的 `build()` 是同一套写法，可以顺带扫一眼证明不是特例。

### 关键前提：不是「fboot 支持命令行参数」，而是「任何用了 `f_config` 的仓颉进程都支持」

**【口播】**（这一句先把边界划清，后面才不会误解）

> 请务必记住这句话：
>
> **只要一个仓颉进程链接了 `f_config` 模块，它的 `static init` 就会去读自己的命令行参数（`env.getCommandLine()`），并把 `--key=value` 装载成配置项。**
>
> 这跟 `fboot` 没什么特殊关系——`fboot` 只是**恰好也用了 `f_config`** 的一个仓颉进程而已。同样适用的还有：
>
> - `fboot run` 启动的应用进程（应用就是被加载进这个进程的）；
> - 你自己写的任何带 `main` 的可执行程序（只要 `import fountain::f_config.*`）；
> - 任何用 `cjpm run` 跑起来的、依赖了 `f_config` 的二进制；
> - 任何**间接**依赖了 `f_config` 的程序（比如你引了 `f_orm`，它依赖 `f_config`）。
>
> 所以 `--key=value` 是 **`f_config` 这个模块的能力**，不是某个命令的开关。`fdemo/boot.sh` 的 `build()` 只是一个**恰好长这样**的例子。

### 同一个写法，两个舞台：编译期 vs 运行期

**【口播】**（承接上面那条规则，看它在 `fboot` 的两个子命令上分别落到哪儿）

> 同一个 `--key=value`，在 `fdemo` 的两个脚本函数里走的路径不一样：
>
> | 阶段 | 命令行参数在谁的 argv 里 | 谁读到它 | 效果 |
> | --- | --- | --- | --- |
> | **编译期** | `fboot build` 进程自己的 argv | `fboot` 进程里的 `f_config` | 转成 `cjpm build` 子进程的**环境变量**；宏（`@EmbedSensitive`、`ORMConfig`）在编译期读到它们，把连接串 / 口令**加密嵌入产物** |
> | **运行期** | `fboot run` 进程的 argv（应用就加载在这个进程里） | 同一个 `f_config`，同一套 `static init` | 装载进 `ARGS`，**覆盖同名环境变量** |
>
> 两边**都是同一条规则**在起作用：**谁的命令行里有 `--k=v`，且那个进程链了 `f_config`，谁就把它读成配置项。**
>
> 对照 `fdemo` 的两个启动脚本就更清楚了：
> - `boot.sh` 的 **`build()`** 把 `--k=v` 交给 `fboot build` → 编译期，最终嵌进产物；
> - `boot.sh` 的 **`run()`** 用的是 `export`（环境变量）→ 运行期；
> - 而 **`boot-win-gitbash.sh` 的 `run()`** 直接把 `--k=v` 拼在 `fboot run` 后面：
>   ```bash
>   fboot run $target_path --dylibPattern='(boot|user\.util\.(auth|cron)|\.(controller|service\.impl))' $args
>   ```
>   这些 `--logger_*=...` `--mvc_port=8080` `--orm_*=...` 落在 `fboot run` 进程的 argv 里，被 `f_config` 直接装载 → 运行期。
>
> 不管是哪条路进来，**最终都由 `f_config` 用同一套优先级读取**（见 4.3），所以对你写业务代码是透明的。

## 4.3 读取优先级（重点，建议做成动画）

一次 `Config.getString(key)` 的查找顺序，**先命中者生效**：

| 顺序 | 来源 |
| --- | --- |
| 1 | 环境变量 / 命令行参数（`ARGS[key]`） |
| 2 | 带全局前缀的同名项（`ARGS[fountain_key]`） |
| 3 | 编译期内嵌的敏感值（`sensitiveMap[key]`） |
| 4 | 带全局前缀的敏感值（`sensitiveMap[fountain_key]`） |

> **结论：运行期配置（环境变量/命令行）优先级高于编译期内嵌值。**
> 这就是为什么你可以编译期把数据库密码嵌进产物、生产环境再用环境变量覆盖掉。

### 全局前缀 `fountain`

`Config` 内置全局前缀 `fountain`：原名未命中时会再试 `fountain_${key}`；`getAll` 的结果里则会把 `fountain_` 去掉。

```bash
export myAppSecret='xxx'           # Config.getString('myAppSecret') 命中
export fountain_myAppSecret='xxx'  # 等价写法
```

`getAll(prefix)`：prefix 为空返回全部，否则 key 需以 `${prefix}_` 或 `fountain_${prefix}_` 开头。

## 4.4 `Config` API

```cangjie
package fountain::f_config
public import std.convert.Parsable
public import fountain::f_data.DataParsable

public class Config {
    public static const sm4Operation = 'sm4Operation'
    public static const sm4Padding    = 'sm4Padding'
    public static const sm4Key        = 'sm4Key'
    public static const sm4Iv         = 'sm4Iv'
    public static const sm4Aad        = 'sm4Aad'
    public static const sm4TagSize    = 'sm4TagSize'

    public static func refresher(prefix: String, fn: () -> Unit): Unit
    public static func set<T>(tuples: Array<(String, T)>, ifAbsent!: Bool = false): Unit where T <: ToString
    public static func getAll(prefix: String): Map<String, String>
    public static func getAll(): Map<String, String>
    public static func getString(key: String): ?String
    public static func getValue<T>(key: String, parser: (String) -> ?T): ?T
    public static func getValue<T>(key: String): ?T where T <: Parsable<T>
    public static func getStringArray(key: String, delim!: String = ','): Array<String>
    public static func getValues<T>(key: String, delim!: String = ',', parser!: (String) -> T): Array<T>
    public static func getValues<T>(key: String, delim!: String = ','): Array<T> where T <: Parsable<T>
    public static func getDateTime(key: String, format!: String = ''): ?DateTime
    public static func getDateTimes(key: String, format!: String = '', delim!: String = ','): Array<DateTime>
    public static func getData<T>(key: String): ?T where T <: DataParsable<T>
    public static func getDatas<T>(key: String, delim!: String = ','): Array<T> where T <: DataParsable<T>
    public static func getDuration(key: String): ?Duration
    public static func getDurations(key: String, delim!: String = ','): Array<Duration>
    public static func bufferSize(bufferKey: String, default: Int64, debugging: Bool): Int64
    public static func getSM4(): ?SM4
    public static func registerSensitive(key: String, value: Array<Byte>): Unit
}
```

**【口播】**（挑几个最有辨识度的讲）

> `getValue` / `getData` 是**单例读取**，解析失败返回 `None`，不抛异常；
> `getValues` / `getDatas` 是**数组读取**，解析失败**抛异常**，配置项不存在返回空数组——**这个「单数不抛、复数抛」的不对称一定要记住**。
> `bufferSize` 更贴心：配置项不存在或 `<= 0` 就用默认值；非调试模式下还会**向上取整到 2 的幂**，且恒不小于默认值——环形缓冲区直接拿它。

`bufferSize(bufferKey, default, debugging)` 的返回值：

| 条件 | 返回值 |
| --- | --- |
| 配置项不存在 / 解析失败 / `x <= 0` | `default` |
| `debugging == true` 且 `x > 0` | `x` 原样返回 |
| `x` 是 2 的幂 | `x` |
| 其它 | 向上取整到 2 的幂 `s`；`s >= default` 返回 `s`，否则 `default` |

```cangjie
Config.getValue<Int64>('threadCount')                 // None 或 Int64
Config.getValues<Int64>('ports')                      // ports=8080,9090 -> [8080, 9090]
Config.getDateTime('deadline', format: 'yyyy-MM-dd')
Config.bufferSize('ringBufferSize', 1024, false)      // >= 1024 且向上取到 2 的幂
Config.set<Bool>([('mySwitch', true)], ifAbsent: true) // 不存在才写入
Config.getAll('orm')                                  // 所有 orm_ / fountain_orm_ 开头的配置项
```

## 4.5 敏感配置与 SM4 加密

**【口播】**（这是本章的高潮，也是 `fboot randhex` 的用武之地）

> 数据库密码、第三方密钥这类东西，不适合出现在运行环境的环境变量里。
> `f_config` 的做法是：**编译期**在编译机上读取环境变量，用 **SM4** 加密后作为字节数组嵌入编译产物；进程启动时注册到独立的 `sensitiveMap`，再用常规 `getString` 读取。
>
> - 未配置 SM4 → 嵌入的是 **UTF8 明文**字节数组；
> - 配置了 SM4 → 嵌入的是**密文**，同时把 SM4 参数一并嵌入供运行期解密；
> - 运行期同名配置优先级更高，可以被覆盖。

### SM4 配置项

| 配置项 | 含义 | 默认值 | 取值 / 格式 |
| --- | --- | --- | --- |
| `sm4Operation` | 工作模式 | `CBC` | `CBC` `CFB` `CTR` `GCM` `OFB`（`ECB` 不安全，明确不支持） |
| `sm4Padding` | 填充模式 | `PKCS7Padding` | `NoPadding` `PKCS7Padding` |
| `sm4Key` | 密钥 | **必须配置** | 16 字节 = 长度 32 的 16 进制串 |
| `sm4Iv` | 初始向量 | 配了 key 就必须配 | `CBC`/`OFB`/`CFB` 要 16 字节，`GCM` 要 12 字节 |
| `sm4Aad` | 附加认证数据 | 空字节数组 | 16 进制串 |
| `sm4TagSize` | GCM tag 长度 | `16` | `Int64` 字符串 |

```bash
export paySecretKey='......'
export sm4Key=$(fboot randhex 32)   # 16 字节密钥
export sm4Iv=$(fboot randhex 32)    # CBC 的 IV；GCM 用 fboot randhex 24
```

**【口播】**

> 注意这两点，讲出来比藏着好：
> 1. **SM4 参数本身（含密钥）也会以字节数组形式出现在编译产物里**。这个机制抬高的是「直接从二进制里 grep 出配置」的门槛，**不能替代密钥管理服务**；
> 2. 每次解密都会**重新构造一次 `SM4` 实例**，敏感配置多或读取频繁时建议自己缓存结果。


## 4.6 `@EmbedSensitive` 宏

```cangjie
import fountain::f_config.macros.*

@EmbedSensitive(paySecretKey pushToken)   // 源文件顶层调用，逗号分隔亦可
```

展开后是一个立即执行的匿名闭包：

```cangjie
private let _ = {=>
    Config.registerSensitive('paySecretKey', [...密文或明文字节...])
    Config.registerSensitive('pushToken', [...])
    Config.registerSensitive('sm4Operation', ...)
    Config.registerSensitive('sm4Padding', ...)
    Config.registerSensitive('sm4Key', ...)
    Config.registerSensitive('sm4Iv', ...)
    Config.registerSensitive('sm4Aad', ...)
    Config.registerSensitive('sm4TagSize', ...)
}()
```

嵌入规则：

1. **编译期取不到值的名字会被忽略**（编译机上没有对应环境变量就不注册）；
2. 编译期配了 `sm4Key` 写密文，否则写 UTF8 明文；
3. 只有「至少注册了一项敏感值」且「`sm4Key` 非空」时才把 SM4 的六个参数一并写入（它们本身按明文字节写入）；
4. 同名重复注册以最后一次为准；
5. 运行期读取仍遵循 4.3 的优先级。

**【口播】** `f_orm` 就是基于这个宏的封装：`f_orm/src/ProtectedMacros/EmbedSensitive.cj` 生成 ORM 的连接串/用户名/口令键，再转调 `@EmbedSensitive`，最终在 `f_orm` 里以 `@ORMEmbedSensitive()` 触发。
所以你在 `boot.sh` 里写的 `--postgres_orm_connectionUrl=...` 才能被嵌进产物。我们看看一个boot.sh 的构建实例（fdemo/boot.sh 的build函数）

## 4.7 可配置的时间格式：`DateTimeConfConverter`

**【镜头】** 这是 `f_config` 与 `f_data` 咬合的地方（第八章会再讲 `DataConverter`）

```cangjie
package fountain::f_config

@Annotation[target: [MemberProperty, MemberVariable, Parameter]]
public class DateTimeConfConverter <: AbstractDateTimeConverter {
    public const DateTimeConfConverter(private let conf: String,
                                       private let default!: String = 'yyyy-MM-dd HH:mm:ss'){}
    public func convert(data: Data, flag!: DataConversionFlag = DEFAULT_DATA_FLAG): ?DateTime
}
```

```cangjie
@DateTimeConfConverter[myDateFormat]
private var createdAt: DateTime = DateTime.now()

// export myDateFormat='yyyy/MM/dd'  —— 时间格式本身也变成可配置的
```

**【口播】** `conf` 是**保存时间格式的配置项名**（不是格式本身），按 4.3 的优先级读取，没配就用 `default`。做多租户、多地区系统时，各家日期格式不一样——一个注解解决。

## 4.8 已知问题（讲出来省得观众踩）
**`getValues` / `getDateTimes` 解析失败会抛异常**，而单数版本 `getValue` / `getDateTime`（配置不存在时）返回 `None` / 空数组——写容错代码时别搞混。这是故意的，因为复数项配置，在解析过程中，如果有某一个转换失败，则整个配置失效。

## 4.9 现场演示

**【命令】**

```bash
# 1) 看一眼 fdemo 到底有多少配置（boot.sh 的 exports 函数）
grep -c 'export' fdemo/boot.sh

# 2) 用 fboot build 把敏感配置在编译期注入（--k=v 会变成 cjpm build 子进程的环境变量）
cd fdemo
export POSTGRES='postgres://user:pass@host:5432/dbname'
./boot.sh build
# 内部：--sm4Key=$(fboot randhex 32) --sm4Iv=$(fboot randhex 32)

# 3) 运行期覆盖（写法一：环境变量），产物不用重新编译
export mvc_port=8080
./boot.sh run

# 3') 运行期覆盖（写法二：--key=value 命令行参数），与写法一完全等价
./boot.sh run
# 等价的裸命令（Windows 版 boot-win-gitbash.sh 的 run() 就是这个形态）：
fboot run ./fdemo \
  --dylibPattern='(boot|user\.util\.(auth|cron)|\.(controller|service\.impl))' \
  --mvc_port=9090 \
  --orm_drivers=postgres
```

**【预期】**

- 第 2 步：编译成功，连接串与口令被加密嵌入产物；
- 第 3 / 3' 步：日志里出现 `9090` 端口，`Config.getString('mvc_port')` 拿到的是命令行参数的值，**覆盖了环境变量值**；
- 两种写法效果完全一致——**环境变量与 `--key=value` 平级，后者覆盖前者**。

**【口播】**

> 这一组三步就是 `f_config` 的全部价值：**编译期可内嵌、运行期可覆盖、全程无配置文件**。
> 而且请注意第 3 步的两种写法：同一个配置项 `mvc_port`，你既可以 `export`，也可以写成 `--mvc_port=9090`——**这就是「f_config 支持命令行参数」最直观的证明**。

---

# 第五章 现场跑通 `fdemo`

**【镜头】** IDE 打开 `fdemo/`，终端执行脚本

## 5.1 目录结构

```
fdemo/
├── cjpm.toml          # workspace：members = ["./boot", "./user"]
├── banner.txt         # 启动横幅（会被 fboot build 打包进版本模块）
├── boot.sh            # Linux 启动脚本
├── boot-macos.sh      # macOS 启动脚本
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

## 5.2 建表

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

## 5.3 编译 + 启动

**【命令】**

```bash
cd fdemo
export POSTGRES='postgres://user:pass@host:5432/dbname'
export CANGJIE_STDX_PATH=$CANGJIE_STDX_DYNAMIC_PATH

./boot.sh build      # 内部就是 fboot build ./fdemo --orm_drivers=postgres ... --sm4Key=$(fboot randhex 32) ...
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

## 5.4 接口验证清单（这一段建议做成一张对照表放在画面上）

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

# 第六章 IOC：`fountain::f_bean`

**【镜头】** `f_bean/README.md` + `fdemo` 中的 `UserController.cj`

## 6.1 最小可用

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

## 6.2 取 bean：`lookup` 家族

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

## 6.3 生命周期与工厂

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

## 6.4 条件装配：`BeanCondition`

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

## 6.5 在 `fdemo` 里看 IOC

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

## 6.6 `@Configuration` + `@BeanInit`

```cangjie
@Configuration        // 这个类本身不被 IOC 管理
public class AppConfig {
    @BeanInit
    public func initSomething(): Unit { ... }
}
```

**【口播】** 被 `@BeanInit` 修饰的公共成员函数（静态/实例皆可）都是 bean 初始化函数；`@Configuration` 修饰的类自己不会进容器。

---

# 第七章 AOP：`fountain::f_aspect`

**【镜头】** `fdemo/boot/src/ControllerAspect.cj` + `f_aspect/README.md`

## 7.1 切面 = 实现了 `Aspect` 的 `@Bean`

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

## 7.2 织入规则：`RouteRule`

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

## 7.3 三个织入宏

```cangjie
@Pointcut       // 修饰函数：只有这个函数织入；修饰类：全部公共函数织入
@WeavedBean     // 注册进 IOC + 全部公共成员函数织入
@WeavedController // mvc模块声明的专用宏：包含@Controller 的全部功能 + 织入
@TransactionalService // orm模块声明的专用宏，是WeavedBean的别名
```

**【口播】** 织入逻辑在**这些函数首次调用时**执行，不是启动期——所以启动很快。

## 7.4 现场：`ControllerAspect`

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

> 这里有个非常值得强调的设计：**`controllerPointcut` 不是 MVC 的配置项，它是为这个切面专门起的名字**。
> `ConfigExecutionRouteRule('controllerPointcut')` 的意思是「去配置项里读 `controllerPointcut` 这一项，把它当作 ExecutionRouteRule 规则」。
>
> 于是切点表达式变成了**部署期可配**的：开发环境织上，生产环境改窄甚至关掉，都不用改代码。
>
> 表达式 `*::*..*Controller.*(**): *` 读作：任意组织 `::` 任意多级包名下、以 `Controller` 结尾的类的、任意参数的、任意返回类型的**全部**公共实例函数。

**【演示】** 访问 `http://localhost:8080/helloworld`，控制台出现：

```
[INFO-ControllerAspect]...ControllerAspect around
```

**【演示】** 改一下 `controllerPointcut` 再启动（比如改成 `*::*..User*Controller.*(**): *`），只有 User 开头的 controller 会打日志。

## 7.5 AOP 在 fountain 里的两个"杀手级"用法

1. **事务**：`f_orm` 的 `TransactionAspect` 就是 `@AspectRoute[FuncAnnotationRouteRule("fountain::f_orm.base.Transactional") | ConfigExecutionRouteRule(ORMConfig.transactionalFuncExecution)]` 的切面（见第十二章）；
2. **统一日志/耗时/审计**：就像 `ControllerAspect`，一处改动覆盖全部 controller。

---

# 第八章 数据：`fountain::f_data`

**【镜头】** `f_data/README.md` + `fdemo/boot/src/boot.cj` 里那段 `TestData1/2/3` 演示 + `fdemo/user/src/model/mvc/UserReqResp.cj`

## 8.1 为什么先讲 `f_data`

**【口播】**

> 前面讲的 IOC、AOP 解决的是「对象怎么来、横切逻辑放哪」。这一章解决的是「**数据怎么流动**」。
>
> 一个服务端应用的绝大部分代码，本质上都在做三件事：
> 1. 把 HTTP 请求 / 数据库行 / 配置 → 变成**对象**；
> 2. 在**对象与对象之间**搬运数据（PO → DTO、DTO → Entity）；
> 3. 把**对象 → 变成响应**（JSON / 其它格式）。
>
> 这三件事，`f_data` 全部用「一个宏 + 一个统一数据模型」解决掉了。它是 MVC 的参数绑定、ORM 的结果映射、以及 JWT 负载填充的**共同底座**——所以 `f_mvc`、`f_orm`、`f_jwt` 都依赖它。

`f_data` 的五个基本特性：

- 数据对象的公共成员变量和公共成员属性的**复制**
- 随时**获取**指定名称的公共成员的值
- 随时为指定名称的公共成员**赋值**
- 在**不同的类实例之间**互相复制
- 任意类实例与 **JSON** 之间互相复制

## 8.2 一把钥匙：`@DataAssist`

```cangjie
@DataAssist[equal hash tostring props fields]
public open class TestData1 {
    private var a: Int64 = 1
    private var b: String = 'asfd'
    private var c: Bool = true
    private var d: Float64 = 3.1415926
}
```

| 属性 | 生成什么 |
| --- | --- |
| `equal` | 实现 `Equatable` |
| `hash` | 实现 `Hashable` |
| `tostring` | 实现 `ToString` |
| `props` | 把非公共实例成员变量**改写成公共成员属性**（`private var a` → `private var a_` + `public mut prop a`） |
| `fields` | 实现实例间复制、实例与 JSON 互转的能力（`dataFields()` / `toData()` / `tryFromData()`） |

**【口播】**（把 `props` 的展开结果打在屏幕上，这是最有说服力的一屏）

```cangjie
// 你写的
@DataAssist[props]
public class A {
    private var a: String = ''
    private let b: Int64 = 0
}

// 宏展开后（等价）
public class A {
    private var a_: String = ''
    private let b_: Int64 = 0
    public mut prop a: String {
        get() { a_ }
        value(value) { a_ = value }
    }
    public prop b: Int64 {
        get() { b_ }
        value(value) { b_ = value }
    }
}
```

> **顺序约束**：在 PO 上，`@DataAssist` 必须写在 `@QueryMappersGenerator` **之前**（先展开）。
> 只写 `props` 保护了封装（字段还是私有的），同时又能被框架读写——这是「不破坏封装的反射」，不过它靠的是宏生成的属性访问器，而不是反射。

## 8.3 统一数据模型：`Data`

**【口播】**

> `f_data` 定义了一棵统一的「数据树」，一切转换都先落到这棵树上，再从树上长出来。
> 这就是为什么任意两个类之间都能互相复制：**它们都先变成 `Data`，再从 `Data` 变回去**。

| 类型 | 说明 |
| --- | --- |
| `Data` | 所有数据值的根接口 |
| `DataReal(Decimal)` | 数值 |
| `DataString(String)` | 字符串 |
| `DataBool` | 布尔（`DataBool.TRUE` / `DataBool.FALSE`） |
| `DataNone` | 空值（`DataNone.INSTANCE`） |
| `DataList` | 有序列表 |
| `DataDict` | 键值映射 |
| `DataDateTime` / `DataDuration` | 时间 / 时间间隔 |
| `DataAny` | 任意值的包装 |

核心接口：

```cangjie
public interface ToData   { func toData(): Data }
public interface FromData {
    static func fromData(data: Data, flag: DataConversionFlag): Any
    static func tryFromData(data: Data, flag: DataConversionFlag): Any
}
public interface FromToData <: FromData & ToData {}

public interface ObjectData<T> <: ToDataFields & DataFields<T> where T <: ObjectData<T> & DataFields<T> {
    static func isSimple(): Bool { false }
    static func tryFromData(data: Data, flag: DataConversionFlag): Any
}
```

`DataObject<T>` 是操作入口——它把任意对象包成「可读写字段的容器」：

```cangjie
let dobj = DataObject<TestData2>(data2)
dobj['b']                              // 按名字读（返回 Data）
dobj['b'] = 'x'.toData()               // 按名字写
dobj.get<Int64>('a', DEFAULT_DATA_FLAG) // 按名字读并转成指定类型
for ((k, v) in dobj) { ... }            // 遍历 (字段名, Data)
dobj.annotations('b')                   // 取字段上的全部注解（校验就靠它）
dobj.annotation<IsNotBlank>('b')        // 取字段上的指定注解
```

## 8.4 实例复制：`DataObject.populate`

**【镜头】** `fdemo/boot/src/boot.cj`（这是仓库里现成的可运行演示，直接跑给观众看）

```cangjie
@DataAssist[equal hash tostring props fields]
public open class TestData1 { private var a: Int64 = 1; private var b: String = 'asfd'; ... }

@DataAssist[equal hash tostring props fields]
public class TestData2 <: TestData1 { ... }   // 有 DateTime / Array / ArrayList / HashMap

@DataAssist[equal hash tostring props fields]
public class TestData3 { ... }                 // 字段与 TestData2 部分同名

// ① 不同类之间复制（只复制同名字段）
var data3 = DataObject<TestData3>.populate(data2).getOrThrow()

// ② 忽略验证 / 忽略验证失败
data3 = DataObject<TestData3>.populate(data2, flag: DEFAULT_DATA_FLAG | IGNORE_VALIDATION).getOrThrow()
data3 = DataObject<TestData3>.populate(data2, flag: DEFAULT_DATA_FLAG | IGNORE_NOT_MATCHED_VALIDATION).getOrThrow()

// ③ 对象 ↔ JSON
let json = JsonValue.from(DataObject<TestData2>(data2))   // 或 JsonValue.tryFromData(dobj)
let back = json.toData()                                   // JSON → Data
let s = toJson(data2)                                      // 对象 → JSON 串
let d = fromJson<TestData2>(s)                             // JSON 串 → 对象

// ④ Map 也能当数据源（先转成 Data 再复制）
let map = HashMap<String, Int64>([('0', 0), ('1', 1), ('2', 2)])
let data4 = map.toData()
data2 = DataObject<TestData2>.populate(data4).getOrThrow()
```

### `DataConversionFlag`：复制行为的开关

`DataConversionFlag` 是 `UInt64`，用 `|` 组合：

| 常量 | 含义 |
| --- | --- |
| `DEFAULT_DATA_FLAG` | `WRAPPING_ON_INT_OVERFLOW \| SILENCE` |
| `SILENCE` | `IGNORE_FIELD_NOT_FOUND \| IGNORE_FIELD_TYPE_NOT_MATCH \| IGNORE_FIELD_NOT_CONVERTABLE \| IGNORE_NONE` |
| `IGNORE_FIELD_NOT_FOUND` | 目标没有这个字段时忽略 |
| `IGNORE_FIELD_TYPE_NOT_MATCH` | 类型不匹配时忽略 |
| `IGNORE_FIELD_NOT_CONVERTABLE` | 无法转换时忽略 |
| `DEEP` | 深拷贝 |
| `IGNORE_VALIDATION` | **跳过校验** |
| `IGNORE_NOT_MATCHED_VALIDATION` | **校验不通过也继续** |
| `WRAPPING_ON_INT_OVERFLOW` / `THROWING_ON_INT_OVERFLOW` / `SATURATING_ON_INT_OVERFLOW` | 整数溢出的三种策略（优先级 `WRAPPING > THROWING > SATURATING`） |

**【口播】**

> 这一组 flag 是 `f_data` 的「容错旋钮」。默认 `SILENCE` 意味着**同名字段就复制，尽量完成数据类型转换，包括字符串跟其他类型之间的转换，对不上的静默跳过**——所以 DTO 少几个字段、多几个字段都不会炸。
> 需要严格模式时，把 `SILENCE` 去掉即可（不传 `DEFAULT_DATA_FLAG`，自己组合）。

## 8.5 数据校验

**【镜头】** `fdemo/user/src/model/mvc/UserReqResp.cj`（MVC 章节会再用到它）

```cangjie
@DataAssist[props fields]
public class UserRequest {
    @CombinedValidator[IsNotBlank(messageIfNotMatch: '请输入用户名') & StringSize(min: 6, max: 50)]
    private var username: String = ''
    @IsNotBlank[messageIfNotMatch: '请输入密码']
    private var password: String = ''
}
```

所有校验器都是 `fountain::f_data.validation.Validator` 的子类，并且可以用 `& | !` 组合：

```cangjie
public abstract class Validator {
    public const Validator(public let messageIfNotMatch!: String = '')
    public func validate(value: ?String): Bool
    public const operator func &(right: Validator): Validator
    public const operator func |(right: Validator): Validator
    public const operator func !(): Validator
    public prop description: String
}

@Annotation[target: [MemberVariable, MemberProperty, Parameter]]
public class CombinedValidator <: Validator {
    public const CombinedValidator(messageIfNotMatch: String, public let validator: Validator)
}
```

内置校验器一览：

| 注解 | 规则 |
| --- | --- |
| `@IsNotEmpty` | 必须非空 |
| `@IsNotBlank` | 非空且不能是空白字符 |
| `@StringSize[min max]` | 字符串长度区间 |
| `@IsInteger` | 必须是整数 |
| `@IsDecimal` | 必须是实数 |
| `@IsEmail` | 邮箱格式 |
| `@IsChineseCellPhone` | 中国手机号 |
| `@IsIntegerRange[min max minInclusive maxInclusive]` | 整数区间（可配开闭） |
| `@IsBool` | `true` / `false` |
| `@IsDateTime[format]` | 必须符合指定时间格式 |
| `@IsDuration` | 必须是 Duration 字符串 |
| `@IsIntegers[separator]` | 按分隔符切开后每部分都是整数 |
| `@DoesMatchRegex[regex]` | 必须匹配正则 |
| `@IsUUID` | 必须匹配UUID，此注解在fountain::f_util定义 |

> 校验注解可以修饰**成员变量、成员属性、函数参数**三处。`f_mvc` 在绑定 controller 实参时会触发参数上的校验，`DataObject.set` 在复制时会触发成员上的校验。
> 校验失败抛 `ValidationException`，`fdemo` 里由 `Http500Handler` 统一转成响应体（见 10.6）。

## 8.6 数据转换扩展

默认转换搞不定时（最典型：字符串 → `DateTime`），实现 `DataConverter`：

```cangjie
public abstract class DataConverter<T> {
    public func convert(data: Data, flag!: DataConversionFlag): ?T
}
public open class AbstractDateTimeConverter <: DataConverter<DateTime> {
    protected func doConvert(data: Data, flag: DataConversionFlag, format: String)
}
public class DateTimeConverter <: AbstractDateTimeConverter {
    public const DateTimeConverter(private let format: String){}   // 'yyyy-MM-dd HH:mm:ss'
    public func convert(data: Data, flag!: DataConversionFlag = DEFAULT_DATA_FLAG): ?DateTime
}
```

**【口播】** 这也是 `f_mvc` 的 `@RequestParam` 能把 `?createTime=2026-10-01 12:00:00` 直接转成 `DateTime` 的原因——转换器在链路里被自动调用。

## 8.7 JSON Schema

```cangjie
package fountain::f_data.json
public interface ToJsonSchema {
    static func toJsonSchema<T>(): String where T <: ObjectData<T>
}
extend JsonObject <: ToJsonSchema
```

给字段打上 `@JsonStringSchema` / `@JsonIntSchema` / `@JsonFloatSchema` / `@JsonBoolSchema` / `@JsonArraySchema` / `@JsonObjectSchema` 注解，就能直接产出 JSON Schema——做前后端契约、做低代码表单都很好用。

```cangjie
@JsonStringSchema[minLength: 6, maxLength: 50, title: '用户名']
private var username: String = ''
@JsonIntSchema[minimum: 0, maximum: 150]
private var age: Int64 = 0
```

## 8.8 JSONPath 查询（`fountain::f_data.path`）

**【口播】**（这一段是 `f_data` 的"彩蛋"，讲 1 分钟就够，但很能体现库的深度）

> `f_data` 实现了 **RFC 9535（JSONPath）** 查询。任何 `Data` 树都能用路径表达式选取节点：
> 日志过滤、配置抽取、响应裁剪、规则引擎的取数——一行解决。

```cangjie
import fountain::f_data.base.*
import fountain::f_data.path.*

let path = DataPath.cache("$.store.books[?(@.price > 9)].title")
for (title in path.get(data)) {
    println(title)
}
```

| API | 说明 |
| --- | --- |
| `DataPath.cache(path)` | 编译路径，缓存在 `HeapCache`（`maxLife: 1 天`, `maxSize: 10000`）——适合用户输入的动态路径 |
| `DataPath.solid(path)` | 永久缓存（进程内固定路径用这个） |
| `DataPath.get(data)` | 求值，返回匹配节点的 `Iterator<Data>` |

语法速览（RFC 9535 兼容）：

| 类别 | 语法 |
| --- | --- |
| 标识符 | `$` 根节点、`@` 当前节点（filter 内） |
| 子段 | `.name` `.*` `['name']` `[*]` `[0]` `[0,2]` `['a','b']` `[start:end:step]` `[-1:]` |
| 递归段 | `..name` `..*` `..['name']` `..[0]` `..[?(...)]` |
| 路径函数 | `min()` `max()` `avg()` `length()` `count()` `value()` |
| 比较 | `==` `!=` `<` `<=` `>` `>=`，支持 `@.x == @.y` 路径间比较 |
| 逻辑 | `&&` `\|\|` `!` `(...)` |
| 存在性 | `?(@.name)`、`?(!(@.name))` |
| 函数扩展 | `match(p, re)` `search(p, re)` `count(p)` `value(p)` `length(p)`，可任意层嵌套 |
| 自定义扩展 | `=~ /regex/`、`in` `nin` `anyof` `subsetof` `nooneof` `[...]`、`size N` |
| 结构相等 | `@.* == [1,2,3]`、`@ == {"k": v}` |

> 边界：`[-1]` 作为索引已被禁用（用切片 `[-1:]`）；裸的 `$..` 后面必须跟选择器；异常统一是 `DataException`。

## 8.9 快速失败 `BreakingCommand`

```cangjie
import fountain::f_data.BreakingCommand
// 业务执行过程中执行 perform BreakingCommand(data) 立即结束当前业务，data 是返回给客户端的数据
perform BreakingCommand(someValue.toData())
perform BreakingCommand.new(someValue)   // T <: ToData 的便捷入口
```

**【口播】** 当你在很深的调用栈里需要「立刻返回，别再往下走」时，用它比一层层 `return` 干净得多——MVC 会把它携带的 `Data` 直接作为响应体。

## 8.10 现场演示

**【命令】** 直接跑 `fdemo`，启动日志里会打出这一组输出（`boot.cj` 的 `static init` 里写的）：

```
AAAAAAAAAAAAAAAAAAAAAAAAAAAAA {TestData2 的 toString}
BBBBBBBBBBBBBBBBBBBBBBBBBBBBB {TestData3：从 TestData2 复制而来}
CCCCCCCCCCCCCCCCCCCCCCCCCCCCC {TestData2 转成的 JSON}
DDDDDDDDDDDDDDDDDDDDDDDDDDDDD {JSON → Data → TestData3}
EEEEEEEEEEEEEEEEEEEEEEEEEEEEE {反向复制回来，b 字段被改空}
FFFFFFFFFFFFFFFFFFFFFFFFFFFFF {HashMap 转成的 JSON}
GGGGGGGGGGGGGGGGGGGGGGGGGGGGG {toJson(TestData2)}
HHHHHHHHHHHHHHHHHHHHHHHHHHHHH {fromJson 回来后的 Data}
@@@@@@@@@@@@@@@@@@@@@@@@@@@@ user_info          ← UserPO.tableName()
@@@@@@@@@@@@@@@@@@@@@@@@@@@@ t_user_info        ← UserInfoPO.tableName()（前缀演示）
```

**【口播】**

> 这一屏就是 `f_data` 的全部能力：8 行字母标号，走完了「对象→对象」「对象→JSON」「JSON→对象」「Map→对象」四条路。**这些代码不需要你写，全部是宏生成的。**

>
> 下一章我们接着讲 `f_util` 工具箱——`UUID`、`IsUUID`、`IdMaker`、`TextTemplate`、`PathPattern`、`TreeTransformer` 以及几个设计模式的现成骨架，它们大多也是**站在 `f_data` 肩膀上**的。

---

# 第九章 工具箱：`fountain::f_util`

**【镜头】** `f_util/doc/` 下的文档 + `f_util/src/` 的文件列表（先给一个全景）

## 9.1 开场：fountain 的「瑞士军刀」

**【口播】**

> 前面几章讲的都是「框架能力」——IOC、AOP、数据、MVC、ORM。
> 这一章换个节奏，讲 `f_util`：一个**不依赖框架、可以单独引入**的工具箱。
>
> 它的定位是：**把中大型服务端项目里那些「每次都要重写一遍」的小东西，一次性做掉。**

| 类别 | 成员 |
| --- | --- |
| ID | `UUID`、`@IsUUID`、`IdMaker` |
| 文本 | `TextTemplate`、`CaseFormat` |
| 结构 | `PathPattern`、`TreeTransformer` |
| 设计模式骨架 | `Factory`、`Strategy`/`Strategies`、`ResponsibilityChain`、`Mediator`、`StatePattern` |
| 哈希/摘要 | `crc16` `crc32` `crc64`、`CityHash`、`MurmurHash3X128`、`wyhash`、`UInt128` |
| 其它 | `geohash`、`DiffieHellmanKeyExchanger`（密钥交换）、`prime`（素数） |

> 这一章挑其中 **9 个最常用**的讲，剩下的————哈希家族、geohash、密钥交换————它们在 `f_util/doc/` 下都有独立文档，需要时查即可。

## 9.2 `UUID`：全版本覆盖的唯一 ID

**【口播】**

> 参照 RFC 4122bis 草案实现，**v1 / v3 / v4 / v5 / v6 / v7 / v8 全支持**——这是很多语言标准库都做不到的。
> 它最妙的一点是：`UUID` 实现了 `DataFields<UUID>` 和 `DataParsable<UUID>`，**所以它天然能进 `f_data` 的体系**——可以直接作为 PO 字段、可以直接被 `DataObject.populate` 复制、可以直接和 JSON 互转，不需要任何胶水代码。

```cangjie
public struct UUID <: Hashable & Comparable<UUID> & ToString & Parsable<UUID> & DataParsable<UUID> & DataFields<UUID>
```

### 生成

| 工厂函数 | 版本 | 说明 |
| --- | --- | --- |
| `UUID.random()` | v4 | 随机（内部用 `ThreadLocalRandom.current.nextBytes(16)`） |
| `UUID.unixTimeBased()` | v7 | **Unix 毫秒时间戳 + 随机**，时间有序，**适合做数据库主键** |
| `UUID.timeBased(timeLowFirst:)` | v1/v6 | 返回 `TimeBasedUUIDBuilder`，可再配 node / UID / GID / 序列号 |
| `UUID.md5(value)` / `md5(bytes)` | v3 | 基于 MD5 的命名空间 UUID（同名输入恒等） |
| `UUID.randomMd5(bytes:)` | v3 | 随机字节的 MD5 UUID |
| `UUID.sha1(value)` / `sha1(bytes)` | v5 | 基于 SHA-1 的命名空间 UUID |
| `UUID.randomSha1(bytes:)` | v5 | 随机字节的 SHA-1 UUID |
| `UUID.custom(values)` | v8 | 自定义，只取前 16 字节 |
| `UUID.Nil` / `UUID.Max` | — | 全 0 / 全 `0xff` |

### 常用成员

```cangjie
let id = UUID.random()

id.toString()          // 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'（带连字符）
id.toHexString()       // 32 位无连字符的 16 进制
id.toString(radix: 36) // 按指定进制输出（radix == 16 等价于 toHexString）
id.version             // 版本号（1/3/4/5/6/7/8）
id.variant             // 变体
id.timestampNanos      // v1/v6 的时间戳（纳秒）
id.timestamp           // v1/v6 的时间戳（DateTime）

UUID.parse(s)          // 解析，失败抛异常
UUID.tryParse(s)       // 解析，失败返回 None<UUID>

id.toData()            // 转成 Data（字符串形式），因此可以进出 f_data 的一切转换
```

### 基于时间的 UUID 构造器

```cangjie
UUID.timeBased()                       // TimeBasedUUIDBuilder
    .registerSequenceGenerator()       // 注册序列号生成器（防同一时刻冲突）
    .registerFileSequenceGenerator()   // 或用文件持久化的序列号生成器
    .randomSeq                         // 随机序列号 / .serialSeq 递增序列号
    .UID(uid)                          // 设置 UID
    .GID(gid)                          // 设置 GID
    .eth0()                            // 用 eth0 网卡的 MAC 作 node
    .etherName('eth0')                 // 指定网卡名
    .ether('xx:xx:xx:xx:xx:xx')        // 直接给 MAC
    .randomNode()                      // 随机 node
    .node(0x...)
```

> `TimeBasedUUIDBuilder` 是 `Resource`，用完记得 `close()`。

## 9.3 `@IsUUID`：一个注解搞定 UUID 校验

**【镜头】** `f_util/src/IsUUID.cj`（只有 35 行）

```cangjie
@Annotation[target: [MemberVariable, MemberProperty, Parameter]]
public class IsUUID <: Validator {
    public const init(){}
    public func validate(value: ?String): Bool {
        if(let Some(x) <- value){ UUID.tryParse(x).isSome() } else { false }
    }
    public prop description: String { get(){ '必须是UUID格式的字符串' } }
}
```

**【口播】**

> 注意它的父类——`fountain::f_data.validation.Validator`。
> 也就是说，`f_util` 的校验注解和 `f_data` 那十几个内置校验器**是同一套体系**，可以一起用 `& | !` 组合：

```cangjie
@DataAssist[props fields]
public class OrderRequest {
    @IsUUID                                        // 必须是 UUID
    private var orderId: String = ''
    @CombinedValidator[IsNotBlank(messageIfNotMatch: '请输入用户名') & StringSize(min: 6, max: 50)]
    private var username: String = ''
}
```

> 而且因为它是 `@Annotation[target: [MemberVariable, MemberProperty, Parameter]]`，**函数参数上也能用**——`f_mvc` 绑定 controller 实参时会自动触发。

## 9.4 `IdMaker`：趋势递增的分布式 ID

```cangjie
public class IdMaker {
    public static const HOST_SERIAL = "idMakerHostSerial"
    public IdMaker(private let hostSerial!: Int64)   // 必须 0..1023，否则抛 IdException
    public init()                                    // 从配置项 idMakerHostSerial 读主机序列号
    public func nextInt64(): Int64                   // 获取下一个 ID
}
```

**【口播】**（这是 snowflake 思路，讲的时候画一下位图）

> `IdMaker` 是一个**雪花算法**风格的实现：ID 是一个 `Int64`，位布局是
> **10 bit 主机序列号 + 41 bit 毫秒时间戳 + 12 bit 毫秒内自增序号**。
>
> - 主机序列号 0～1023，来自配置项 `idMakerHostSerial`（走 `Config.getValue`，也就是第四章那套优先级）；
> - 时间戳取**构造时的毫秒数**作为起点；
> - `nextInt64()` 就是一个 `AtomicInt64.fetchAdd(1)`，**无锁、线程安全**。

```cangjie
let maker = IdMaker()          // export idMakerHostSerial=7
let id = maker.nextInt64()
```

> 三个必须讲的注意点：
> 1. 主机序列号**必须全局唯一**，重复会产生重复 ID；
> 2. 12 bit 序号意味着**每毫秒 4096 个**，超出自增位宽会向时间戳位进位——ID 仍然唯一且递增，但时间戳含义会漂移；
> 3. 起点是**构造时刻**，进程重启后时间戳基准改变，但因为有主机号兜底，跨进程仍然不冲突。

**【口播】** 和 `UUID` 怎么选？**要时间有序、要索引局部性好 → `IdMaker` 或 `UUID.unixTimeBased()`；要无中心、随便哪台机器都能生成 → `UUID.random()`。**

## 9.5 `CaseFormat`：命名风格互转

```cangjie
CaseFormat.Pascal.convert("CaseFormat",          to: CaseFormat.Camel)           // "caseFormat"
CaseFormat.Pascal.convert("CaseFormat",          to: CaseFormat.LowerUnderScore) // "case_format"
CaseFormat.Pascal.convert("CaseFormat",          to: CaseFormat.UpperUnderScore) // "CASE_FORMAT"
CaseFormat.Pascal.convert("CaseFormat",          to: CaseFormat.LowerHyphen)     // "case-format"
CaseFormat.Pascal.convert("CaseFormat",          to: CaseFormat.UpperHyphen)     // "CASE-FORMAT"
```

六种风格两两互转：`Pascal`、`Camel`、`LowerUnderScore`、`UpperUnderScore`、`LowerHyphen`、`UpperHyphen`。

**【口播】**（把工具和前面 ORM 的内容连起来——这是很好的「原来如此」时刻）

> 还记得后面ORM 里的 `@ORMField[LowerUnderScore]` 和 `@QueryMappersGenerator[table: LowerUnderScore]` 吗？
> **它们底层用的就是这个 `CaseFormat`**，完成默认的类实例成员名与表列名转换。
> 所以当你自己写命名策略、写代码生成器、写导入导出工具时，直接用同一个枚举，命名风格就和框架生成的一致了。

## 9.6 `TextTemplate`：文本模板

**【口播】** 短信、邮件、推送文案、固定格式报文——别再拼字符串了。

```cangjie
public class TextTemplate {
    // 由一对 # 包含的是模板变量
    public static func compile(template: String, placeholder!: String = "#"): TextTemplate
    // 由 prefix / suffix 包含的是模板变量（默认 ${ }）
    public static func compile(template: String, prefix!: String = #"${"#, suffix!: String = "}"): TextTemplate

    public func format<T>(data: Array<T>,     noneConverter!: ?String = None<String>): String where T <: ToString
    public func format<T>(data: ArrayList<T>, noneConverter!: ?String = None<String>): String where T <: ToString
    public func format<V>(data: HashMap<String, V>,  noneConverter!: ?String = None<String>): String where V <: ToString
    public func format<V>(data: TreeMap<String, V>,  noneConverter!: ?String = None<String>): String where V <: ToString
    // ...还有 ConcurrentHashMap / LinkedHashMap
    public func format<T>(data: T, noneConverter!: ?String = None<String>): String where T <: Object & ObjectData<T>
}
```

```cangjie
let tpl = TextTemplate.compile('亲爱的 ${name}，您于 ${time:yyyy/MM/dd} 消费 ${number:##.##} 元')
tpl.format(user)     // user 是 @DataAssist[fields] 的 PO 或任意 Map
```

占位符的三种高级形态：

| 形态 | 写法 | 作用 |
| --- | --- | --- |
| 时间 | `${time:`yyyy/MM/dd`}` | 按指定格式格式化日期 |
| 数字 | `${number:`##.##,HALF_UP`}` | 数字格式化；`#` 数量=位数，`.`=小数点；支持 `o/O`(八进制) `x/X`(十六进制) `e/E`(科学计数) `+`(正数前置+) `(`(负数用括号) |
| 正则 | `${regex:`.*_name`}` | 用正则匹配 Map 的 key，**只接受 Map 作为数据源** |

还有两个很好用的细节：

- **`.` 分隔的路径占位符**：`a.0.b.c` 表示取参数 `a` 属性（数组/List）索引 0 的 `b` 属性的 `c` 属性，参数可以是数组、List、PO、Map；
- **`noneConverter`**：占位符在数据源里找不到时用这个兜底字符串。

> ⚠️ 实现上依赖 `ThreadLocalStringBuilder`。如果你的方法本身也在用 `ThreadLocalStringBuilder` 拼字符串，**不要**在那个方法内嵌套调用 `TextTemplate`；要么先调用 `TextTemplate` 再拿 `StringBuilder`。

## 9.7 `PathPattern`：路径匹配（MVC 路由的引擎）

**【镜头】** `f_util/src/PathPattern.cj`

**【口播】**

> 你在 MVC 里写的 `/api/user/{id}`，能匹配到 `/api/user/1` 并抽出 `id=1`——**干这件事的就是 `PathPattern`**。
> 它按作者的说法「从生产环境用过的 Java 实现移植而来」，不只 MVC 能用，任何「按路径找数据」的场景都能用：静态资源路由、网关转发规则、日志文件路径归集。

```cangjie
let patterns = PathPattern()
patterns.compileIfAbsent('/api/user/{id}'){ handler }   // 注册路径 + 关联数据
patterns.data<Handler>('/api/user/1')                   // 用路径反查数据
patterns.extractVariableInPath('/api/user/1', 'id')     // Some("1")
patterns.matches('/api/user/1')                         // true
```

核心 API：

| 函数 | 作用 |
| --- | --- |
| `compile(pattern)` / `compile(pattern, data)` | 注册路径（可挂任意数据：handler、配置、元数据） |
| `compileIfAbsent(pattern, supplier)` | 不存在才注册，返回已存在/新建的数据 |
| `data<T>(path)` / `dataByPrefix<T>(path)` | 按路径取出挂的数据 |
| `matches(path)` / `matchesPrefix(path)` | 是否匹配 / 是否前缀匹配 |
| `extractVariableInPath(path, name)` | 取单个路径变量 |
| `extractVariablesInPath(path)` | 取全部路径变量（`Map<String,String>`） |
| `extractTimeVariableInPath(path, name, format)` | 直接把路径变量解析成 `DateTime` |
| `extractParsableVariableInPath<T>` / `extractDataParsableVariableInPath<T>` | 解析成 `Parsable` / `DataParsable` 类型 |
| 各函数的 `withExtName` 重载 | 是否把扩展名（最后一个 `.` 之后）当作路径的一部分 |

支持的模式与**匹配优先级**（优先级高的先试）：

| 优先级 | 模式 | 例子 |
| --- | --- | --- |
| a（最高） | 字符串相等 | `/api/user/list` |
| b = c = d | `*`（单级多字符）、`?`（单级单字符）、`{#regex:...}`（单级正则） | `/api/*.json`、`/api/user/?`、`/api/{#regex:\d+}` |
| e | 单 `*`（独占一整级） | `/api/*/detail` |
| f = g | `{name}`（占位符）、`{*name}` | `/api/user/{id}` |
| h（最低） | `**`（跨多级） | `/static/**` |

> 规则补充：只能匹配绝对路径（不以 `/` 开头也按 `/` 开头处理）；连续多个 `/` 会合并成一个；`{name:regex}` 形式的占位符自带正则约束；`#regex:` 形式的那一节**不作为路径变量**。

## 9.8 `TreeTransformer`：平铺列表 → 树

**【镜头】** `f_util/src/TreeTransformer.cj`

```cangjie
public interface TreeNode<ID, T> where ID <: Hashable & Equatable<ID>, T <: Object & TreeNode<ID, T> {
    prop children: ArrayList<T>
    prop id: ID
    prop parentId: ID
    func addChild(child: T): Unit { children.add(child) }
    func addChildren(children: Iterable<T>): Unit
    func addChildren(children: Array<T>): Unit

    static func transform<S>(iterable: Iterable<S>, emptyId: ID,
                             ignoreDuplicate: Bool, transferFn: (S) -> ?T): ArrayList<T>
    static func transform<S>(iterable: Iterable<S>, emptyId: ID, transferFn: (S) -> ?T): ArrayList<T>
    static func transform<S>(iterable: Iterable<S>, emptyId: ID): ArrayList<T>
    static func transform<S>(iterable: Iterable<S>, emptyId: ID, ignoreDuplicate: Bool): ArrayList<T>
}
```

**【口播】**

> 菜单树、组织树、分类树、评论楼层——数据库查出来永远是**平铺的 List**，前端永远要**树**。
> 这段代码你大概写过十遍，`TreeTransformer` 把它变成一个静态函数调用：

```cangjie
// ① 让你的树节点类实现 TreeNode<ID, T>
public class MenuNode <: TreeNode<Int64, MenuNode> {
    public let id: Int64
    public let parentId: Int64
    public let children = ArrayList<MenuNode>()
    ...
}

// ② 一行把 DAO 查出来的平铺列表变成森林
let roots = MenuNode.transform<MenuPO>(poList, emptyId: 0){ po => MenuNode(po) }
```

> 参数含义：`emptyId` 是「根节点的 parentId 值」（通常是 0 或 -1）；`ignoreDuplicate: true` 时遇到重复 id 会跳过而不是抛异常；`transferFn` 负责把源元素转成树节点，返回 `None` 会抛 `IllegalArgumentException`。
> 不带 `transferFn` 的重载等价于 `{s => s as T}`，即**源元素本身就是树节点**。

## 9.9 三个现成的设计模式骨架

**【口播】**

> 设计模式这种东西，道理大家都懂，但每次都要写一遍接口 + 注册表。`f_util` 直接给了骨架。

### 工厂模式 `Factory`

```cangjie
public interface Producer<A, O> {
    func produce(): O            // 默认抛 IllegalAccessException
    func produce(arg: A): O      // 默认抛 IllegalAccessException
}

public class Factory<A, O> {
    public func assemble<T>(producer: Producer<A, O>): Unit
    public func assemble<T>(producers: Iterable<Producer<A, O>>): Unit
    public func produce<T>(): T
    public func produce<T>(arg: A): T
}
```

`assemble<T>` 用 `TypeInfo.of<T>()` 当 KEY 注册生产者，`produce<T>()` 按目标类型取——**按类型分派的工厂**，取不到会抛 `TypeNotMatchException`。

### 策略模式 `Strategy` / `Strategies`

```cangjie
public interface Strategy<N, A, R> where N <: Hashable & Equatable<N> {
    prop name: N                 // 策略标识
    func execute(arg: A): R
}

public class Strategies<N, A, R> where N <: Hashable & Equatable<N> {
    public func register(strategy: Strategy<N, A, R>): Strategies<N, A, R>
    public func register<S>(strategies: Iterable<S>): Unit where S <: Strategy<N, A, R>
    public func execute(name: N, arg: A): R    // 找不到抛 IllegalAccessException
}
```

**【口播】** 这和 IOC 的 `lookupLables<L, T>()`（第六章）是互补的两种做法：**要 bean 的完整生命周期管理用 IOC；只是想按 key 分派一段逻辑，用 `Strategies` 更轻。**

### 责任链模式 `ResponsibilityChain`

```cangjie
public interface Responsibility<C, A, R> {
    func check(condition: C): Bool   // 是否由本策略处理
    func execute(arg: A): R
}
/** 只做校验、不返回结果的策略 */
public interface ValidationResponsibility<C, A> <: Responsibility<C, A, Unit> {
    func execute(arg: A): Unit {}
}

public class ResponsibilityChain<C, A, R> {
    public init()
    public init(resposibilities: Iterable<Responsibility<C, A, R>>)
    public func register(resposibility: Responsibility<C, A, R>): ResponsibilityChain<C, A, R>
    public func register<S>(resposibilities: Iterable<S>): Unit where S <: Responsibility<C, A, R>
    public func execute(condition: C, arg: A): R      // 第一个 check 通过的；全不通过抛 IllegalAccessException
    public func executeAll(condition: C, arg: A): Unit // 执行**所有**满足条件的
}
```

**【口播】**

> `execute` 是「找到第一个能处理的就执行」，`executeAll` 是「所有符合条件的都执行一遍」——后者特别适合**多级校验、多环节加工**。

### 顺带一提：还有两个

```cangjie
// 中介者模式：Colleague（有 name）+ ColleagueArgument（用 name 找 Colleague）+ Mediator
public class Mediator<N, C, A, R> {
    public func register(colleague: Colleague<N, A, R>): Unit
    public func execute(arg: A): R        // 用参数里的 name 找策略并执行
}

// 状态模式
public interface State<D> {
    prop continues: Bool { get() { true } }   // 是否还有后继状态
    prop data: D                              // 当前状态的数据
    func exec<S>(): S where S <: State<D>
    func startup<D>(): D
}
```

## 9.10 一句话带过的其余工具

| 工具 | 一句话 |
| --- | --- |
| `crc16` / `crc32` / `crc64` | 循环冗余校验，做数据完整性校验、短摘要 |
| `CityHash` / `MurmurHash3X128` / `wyhash` | 高性能非加密哈希，做分库分表路由、布隆过滤器 |
| `UInt128` | 128 位无符号整数（`MurmurHash3X128` 的返回值类型） |
| `geohash` | 经纬度编码，做「附近的人」、网格聚合 |
| `DiffieHellmanKeyExchanger` | 密钥交换协议（详见 `f_util/doc/密钥交换协议.md`） |
| `prime` | 素数判定与生成 |

## 9.11 现场演示

**【镜头】** 建议临时建一个小模块现场跑，或者直接用仓库里的测试（`CaseFormat_test.cj`、`PathPattern_test.cj` 都是可运行的）

```bash
# 跑 f_util 自带的测试，看 CaseFormat / PathPattern 的断言全过
cd f_util && cjpm test
```

**【命令】**（如果现场写代码，建议演示这段——一条链路串起 4 个工具）

```cangjie
import fountain::f_util.*

// ① ID：给订单发号
let orderId = UUID.unixTimeBased().toHexString()          // 时间有序
let seqId   = IdMaker().nextInt64()                        // 趋势递增

// ② 命名风格：PO 成员名 <-> 列名
let column = CaseFormat.Camel.convert('userName', to: CaseFormat.LowerUnderScore)  // user_name

// ③ 路径匹配：网关规则
let rules = PathPattern()
rules.compileIfAbsent('/api/{version}/user/{id}'){'user-service'}
let svc = rules.data<String>('/api/v1/user/1001')          // Some('user-service')
let id  = rules.extractVariableInPath('/api/v1/user/1001', 'id')  // Some('1001')

// ④ 文本模板：通知文案
TextTemplate.compile('订单 ${orderId} 已创建').format(['orderId': orderId])
```

**【口播】**

> 这四个东西看起来零碎，但**每一个都对应一类你迟早会写的需求**。
> 它们的共同点是：**零依赖、零配置、拿来即用**——这也是 `f_util` 的设计原则：不绑架你的架构，只消灭重复劳动。

---

# 第十章 MVC：`fountain::f_mvc`

**【镜头】** `fdemo/user/src/controller/` 全部文件

## 10.1 声明 Controller

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

## 10.2 参数绑定注解

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

## 10.3 参数校验（`f_data` 的校验注解，详见第八章）

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

> 校验注解既可以修饰类的成员（MVC 传参对象时生效），也可以修饰函数参数。不满足会抛 `ValidationException`，由我们注册的 500 处理器统一转成响应体（见 10.6）。

## 10.4 安全注解

```cangjie
@IgnoreAuth        // 忽略登录状态检查
@IgnorePrivilege   // 忽略权限检查
@IgnoreSecurity    // 两者都忽略
```

只能修饰 controller 的公共实例函数。也可以在 Mapping 注解里直接写 `ignoreAuth: true`。

## 10.5 配置（环境变量，或等价的 `--key=value` 命令行参数）

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

## 10.6 统一异常响应

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

## 10.7 重定向

```cangjie
Redirect.found('/helloworld')                 // 302
Redirect.permanently('/x', retain: true)      // retain=false → 301；true → 308
Redirect.temporarily('/x', retain: true)      // retain=false → 302；true → 307
```

## 10.8 拿到当前请求上下文

```cangjie
import fountain::f_mvc.CurrentHttpContext
let ctx = CurrentHttpContext.instance   // 当前线程正在处理的 HttpContext
```

**【口播】** 这是 `f_security` 能在 Service/Util 层做鉴权的关键——鉴权逻辑不必写在 controller 里（见第十三章 `UserSessionCache.verify()`）。

## 10.9 自定义数据格式（`MediaType`）

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
> **下一章（第十一章）会把 `MediaType` 这套机制完整展开**——它是 `f_http` 提供的，只是被 `f_mvc` 直接 `public import` 了出来。

---

# 第十一章 HTTP 数据格式：`fountain::f_http`

**【镜头】** `f_http/README.md` + `f_http/src/MediaTypes.cj` + `fdemo/boot/src/LogMediaType.cj`

## 11.1 `f_http` 是什么

**【口播】**

> `f_mvc` 能同时处理 `text/plain`、`application/json`、`multipart/form-data`，靠的不是 MVC 自己，而是 **`f_http`**。
> `f_http` 目前实现了两件事：
> 1. **HTTP 数据格式（`MediaType`）的定义**——text/plain、application/json、multipart/form-data；
> 2. **multipart/form-data 的编解码**——也就是文件上传。
>
> 而 `f_mvc/src/MediaType.cj` 只有一行：`public import fountain::f_http.*`。
> 所以你在 MVC 里 `import fountain::f_mvc.MediaType`，拿到的其实**就是 `f_http` 的类型**——它们不是两套东西。

## 11.2 `MediaType`：所有数据格式的父类型

```cangjie
public abstract class MediaType <: ToString & Hashable & Equatable<MediaType> {
    public MediaType(public let mediaType: String)
    public open func toString(): String
    public open func hashCode(): Int64
    public open operator func ==(other: MediaType): Bool

    /** 用格式名称得到一个新的 MediaType 实例：
     *  文本格式可能有不同的 charset，multipart 可能有不同的 boundary，
     *  所以要用本函数基于当前实例创建新的 MediaType */
    public func make(mediaType: String): MediaType

    /** 对象 → 字节数组（内部先 toData() 再 fromData(data: Data)） */
    public func fromDataFields<T>(data: T): Array<Byte> where T <: DataFields<T>
    public open func fromData(data: Data): Array<Byte>
    /** 字节数组 / 输入流 / 字符串 → Data */
    public open func toData(data: Array<Byte>): Data
    public open func toData(input: InputStream): Data
    public open func toData(data: String): Data
    /** Data / 字节数组 / 输入流 / 字符串 → 指定类型（内部调 T.fromData） */
    public func toDataFields<T>(data: Data): T where T <: DataFields<T>
    public func toDataFields<T>(data: Array<Byte>): T
    public func toDataFields<T>(input: InputStream): T
    public func toDataFields<T>(data: String): T
}
```

**【口播】**（把数据流向讲清楚——这一屏是理解 MVC 参数绑定的关键）

```
请求方向：字节 / InputStream / String --toData--> Data --toDataFields--> 对象（controller 实参）
响应方向：controller 返回值（对象）--fromDataFields--> 字节数组 --> 写回客户端
```

> 这就是为什么 `@RequestBody` 能直接把请求体变成controller函数实参，返回值能直接变成 JSON——**中间那一层就是 `MediaType`**。
> 而 `Data` 是 `f_data` 的类型，所以 `f_http` 和 `f_data` 是咬合在一起的：`MediaType` 负责「字节 ↔ Data」，`f_data` 负责「Data ↔ 对象」。

## 11.3 内置的三种实现

```cangjie
public class PlainTextMediaType <: TextMediaType   // text/plain
public class JsonMediaType      <: TextMediaType   // application/json
public class MultipartMediaType <: MediaType       // multipart/form-data、multipart/mixed
```

`TextMediaType` 是带字符集的文本格式父类，它处理 `; charset=` 后缀：

```cangjie
public abstract class TextMediaType <: MediaType {
    protected TextMediaType(mediaType: String, public let charset!: Charset = Charsets.UTF8)
    protected func doMake(mediaType: String, creator: (Charset) -> MediaType): MediaType
    public func toString() { "${mediaType}; charset=${charset}" }
}
```

- `JsonMediaType.toData(String)` = `JsonValue.fromStr(data).toData()`
- `JsonMediaType.fromData(Data)` = `JsonValue.tryFromData(data).toString()` 再按 charset 编码
- `MultipartMediaType` 带 `boundary`，`toString()` 形如 `multipart/form-data; boundary=xxx`；它的 `fromData(Data)` / `toData(Array<Byte>)` **直接抛异常**，只支持 `toData(input: InputStream)`（解析上传流）

## 11.4 `MediaTypes`：格式注册表

```cangjie
public class MediaTypes {
    public static func register(mediaType: MediaType): Unit
    public static func parse(mediaType: String): MediaType      // 找不到抛 MediaTypeException
    public static func tryParse(mediaType: String): ?MediaType  // 找不到返回 None
}
```

**【口播】**（这一段是重点，解释「为什么加个 `@Bean` 就多了一种数据格式」）

> `MediaTypes` 内部是一张 `ConcurrentHashMap<String, MediaType>`。它有两个注册来源：
>
> 1. **`static init()` 里内置注册**：`JsonMediaType.instance`、`MultipartMediaType.formData`、`MultipartMediaType.mixed`、`PlainTextMediaType.instance`；
> 2. **首次 `tryParse` 时从 IOC 拉取**：`registerFromBeanFactory()` 会 `BeanFactory.instance.getList<MediaType>()`，把所有 `@Bean` 修饰的 `MediaType` 一并注册（用 `AtomicInt8` + 条件变量保证只做一次、且并发安全）。
>
> 所以 `fdemo` 的 `LogTextMediaType` 只要加个 `@Bean`，`application/json+log` 就自动可用了——**不需要任何注册代码**。
>
> 解析时还有一个宽容处理：`tryParse` 先按完整的media type字符串查找，找不到就**截掉 `;` 之后的参数**再找一次（比如 `application/json; charset=utf-8` → `application/json`），找到后再调用用 MediaType的`make()`函数把参数带回去。

## 11.5 自定义数据格式：完整清单

**【镜头】** `fdemo/boot/src/LogMediaType.cj`（整屏展示）

```cangjie
@Bean
public class LogTextMediaType <: MediaType {
    private static let log = LoggerFactory.getLogger<LogTextMediaType>()
    public init() {
        super('application/json+log')
    }
    public func make(mediaType: String): MediaType { this }
    public func toString() { mediaType }
    public operator func ==(other: MediaType) { ... }   // 必须实现
    public func hashCode(): Int64 { ... }               // 必须实现
    public func fromData(data: Data): Array<Byte> { fromData(JsonValue.from(data)) }
    public func fromData(data: JsonValue): Array<Byte> {
        let json = data.toString()
        log.info{'fromData:${json}'}
        json.unsafeBytes()
    }
    public func toData(data: Array<Byte>): Data { toData(String.fromUtf8(data)) }
    public func toData(data: String): Data { JsonValue.fromStr(data).toData() }
}
```

**必须做的事**（漏一件就会编译不过或匹配不上）：

1. 构造器里 `super('<你的格式名>')`；
2. 实现 `make`（同一种格式可能带不同参数，用它创建新实例；不需要参数就返回 `this`）；
3. 实现 `toString()`；
4. 实现 `==` 与 `hashCode()`（它是 `Hashable & Equatable<MediaType>`，而且 `MediaTypes` 会拿它做比较）；
5. 实现 `fromData`（响应方向：对象 → 字节）与 `toData`（请求方向：字节 → `Data`）；
6. **加 `@Bean`**——这是它被 `MediaTypes` 发现的唯一途径。

**【演示】** 用起来就是 `consumes / produces` 里写你自己的格式名：

```cangjie
@PostMapping[path:'/api/user/sessionLog',
             consumes:'application/json+log',
             produces:'application/json+log',
             ignoreAuth: true]
public func loginLog(@RequestBody user: UserRequest): UserRequest { ... }
```

```bash
curl -XPOST http://localhost:8080/api/user/sessionLog \
  -H 'Content-Type:application/json+log' -H 'Accept:application/json+log' \
  -d '{"username":"abcdef","password":"bcbcbcbc"}'
```

**【预期】** 控制台出现 `fromData:` 与 `toData:` 两条日志——证明请求体和响应体都走了自定义格式。

**【口播】** 这就是「协议扩展点」的用法：**私有协议、加密报文、带签名的请求体**，都可以用这种方式接入，业务代码完全不用关心编解码。

## 11.6 文件上传：`multipart/form-data`

### 接收

**【镜头】** `fdemo/user/src/controller/UploadController.cj`

```cangjie
@DataAssist[props fields]
public class UploadRequest {
    private var name: String = ''
    private var file: ?MultipartFile = None
}

@Controller
public class UploadController {
    @PostMapping[path: '/upload', produces: 'text/plain', consumes: 'multipart/form-data']
    @IgnoreSecurity
    public func upload(@RequestBody multipart: UploadRequest): String {
        println('${multipart.file?.size} ${multipart.name}')
        'ok'
    }
}
```

**【口播】**

> 注意 `file` 的类型是 `?MultipartFile`——它是 `f_http` 的类型，同时实现了 `Multipart & InputStream & Resource & DataFields<MultipartFile> & Data`。
> 也就是说**它既是数据（能进 `f_data` 体系），又是一个 `InputStream`**（能直接读）。
>
> `MultipartFile` 常用成员：
> - `filename` / `size` / `empty`
> - `isAttachment` / `isInline` / `isFormData`（来自 `ContentDisposition`）
> - `read(buffer)` / `bytes()` / `copyTo(output)` / `reader`
> - 它是 `Resource`，**用完要 `close()`**——`close()` 会连临时文件一起删掉，不会在磁盘上留垃圾。

### 发送

```cangjie
let form = MultipartFormData()
form.newPart().name('name').value('abc')
form.newPart().file(fileName: 'a.txt', content: inputStream, size: 1234)
form.encode(output)          // 写到输出流
let in = form.input()        // 或拿到 MultipartFileInputStream 自己读
```

`MultipartFileBuilder` 的 API：`name()` / `value(content)` / `file(file)` / `file(fileName, content, size!, creationDate!, modificationDate!)` / `build()`。
`MultipartFormData` 的 `boundary` 是自动生成的：`FountainBoundary${RandomString().randomLettersNumbers(32)}`（又见 `f_random`）。

### 配置

```bash
export http_halfBufferSize=2048              # multipart 缓冲区的一半大小，默认 2048 字节
export http_uploadDir=/tmp/fountain/upload   # 上传文件的临时保存路径
```

**【演示】**

```bash
curl -XPOST http://localhost:8080/upload -F 'name=abc' -F 'file=@./banner.txt'
```

**【预期】** 控制台打印出文件大小与 `name`，响应 `ok`。

## 11.7 异常与排错

| 异常 | 场景 |
| --- | --- |
| `MediaTypeException('<x> is an illegal MediaType string')` | `MediaTypes.parse()` 遇到没注册的格式 |
| `MediaTypeException('charset in <x> is not be supported')` | 文本格式的 charset 不支持 |
| `MediaTypeException('<x> does not support current access')` | 对 `multipart` 调用了 `fromData(Data)` / `toData(Array<Byte>)` |

**【口播】** 遇到 `is an illegal MediaType string`，99% 是自定义 `MediaType` 的 **`@Bean` 没生效**——回到第三章 3.7 那条：**它所在的动态库必须被 `--dylibPattern` 匹配到**。`fdemo` 的 `LogTextMediaType` 在 `boot` 包里，而正则里有 `boot`，所以能加载到。

---

# 第十二章 ORM：`fountain::f_orm`

**【镜头】** `fdemo/user/src/model/po/UserPO.cj` → `dao/UserDAO.cj` → `service/impl/UserServiceImpl.cj`

## 12.1 三个角色：PO、DAO、Service

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
> 1. **每次调用 DAO 函数都必须从 `executor()` 开始**——不要试图声明SqlExecutor或DAO接口类型的变量；
> 2. **一个 DAO 函数只执行一个 SQL**（或一次分页查询：一次 count + 一次列表）。

## 12.2 配置（环境变量 / `--key=value` 命令行参数）

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
export sm4Key=$(fboot randhex 32)
export sm4Iv=$(fboot randhex 32)
```

> 约定：全局 `orm_<key>`；按驱动覆盖 `<driverName>_orm_<key>`，**后者优先级更高**。

## 12.3 构造 SQL 的三种方式（重点章节）

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
executor.UPDATE<UserPO>(user, ignoredColumns: [UserPO.tableColumns().id]) // 还有includingColumns命名参数
// dirty ignoredColumns includingColumns 是同一个函数的三个命名实参，每次调用，只能指定其中一个，一次指定任意两个会抛出异常
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

## 12.4 查询结果

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

## 12.5 事务控制（本章重点，建议留 8 分钟）

### 三种开启方式

**① 注解 `@Transactional`**

```cangjie
@Transactional[propagation: Propagation.RequiresNew, rollbackFor: 'fountain::f_exception::BizException']
public func transfer(from: Int64, to: Int64, amount: Decimal): Unit { ... }
```

注解参数：`driverName` `propagation` `isoLevel` `accessMode` `deferrableMode` `rollbackFor` `noRollbackFor`。
其中rollbackFor是发生了rollbackFor指定的异常才会回滚，noRollbackFor是只有发生了这个参数指定的异常才不回滚。
**② 配置驱动（批量织入，无需逐个加注解）**

```bash
export orm_transactionalFuncExecution='*::*..*ServiceImpl.del*(**): *'
export orm_transactionalFuncExecution="$orm_transactionalFuncExecution|*::*..*ServiceImpl.insert*(**): *"
export orm_transactionalFuncExecution="$orm_transactionalFuncExecution|*::*..*ServiceImpl.save*(**): *"
export orm_transactionalFuncExecution="$orm_transactionalFuncExecution|*::*..*ServiceImpl.register*(**): *"
export orm_transactionalFuncExecution="$orm_transactionalFuncExecution|*::*..*.userSession(**): *"
```

**【口播】**

> 这两条是 **OR 关系**：`@Transactional` 注解 和 `orm_transactionalFuncExecution` 配置**只要有一个命中，事务切面就会织入**。
>
> `fdemo` 的配置把 `del* remove* insert* save* add* new* create* update* change* register*` 开头的函数，以及名为 `userSession`的函数全织入了事务切面——**按方法名前缀约定统一开事务**，这是很实用的团队规范落地方式。
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

## 12.6 ORM 常见坑（念一遍能省观众两天）

1. 一个 DAO 函数只执行一个 SQL（或一次分页查询）；
2. 每次调用 DAO 都必须从 `executor()` 开始；
3. 同一模块内 DAO 函数名不能重名；
4. 同一个 `SqlExecutor` 上**不允许并发**：上一次查询结果未关闭时再执行会抛 `ORMException("cannot execute SQL while a previous query result is still active")`；
5. 结果缓存默认开启（`orm_useCache`），写操作后会清空缓存；
6. `@DataAssist` 必须在 `@QueryMappersGenerator` 之前；
7. `tableColumns()` 的属性名是**数据库表的列名**不是映射类的成员名（`save_time` 不是 `saveTime`）；
8. `page` 系列函数要求 SQL 以 `select` 开头，否则抛 `ORMException('<sql> is not a select.')`。

---

# 第十三章 安全：`f_security` + `f_jwt`

**【镜头】** `fdemo/user/src/util/UserSessionCache.cj`、`util/auth/AuthCheckerImpl.cj`、`f_mvc/src/AuthHandler.cj`

## 13.1 登录状态检查怎么做（重点）

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
3. 否则：!ignoreAuth 且 UserSessionHandler 存在 → 用它检查登录状态 → 通过执行第4步，否则失败
4. !ignorePrivilege 且 PrivilegeHandler 存在   → 用它检查权限
5. 都没有                                           → OK
```

> **重要结论**：第 3 步一旦通过就直接返回，**第 4 步的权限检查不会执行**。
> 所以源码注释明确写着：**如果登录状态和权限都要检查，最好在同一个类里实现、一次调用检查完**——`fdemo` 的 `AuthCheckerImpl` 就是这个做法。
> 如果你的系统权限模型很复杂，可以实现 `UserSessionHandler` 和 `PrivilegeHandler` 两个 bean，但要清楚这个优先级语义。

### 第三步：在 controller 上放行

```cangjie
@IgnoreSecurity                                              // 注解方式
// 或
@PostMapping[..., ignoreAuth: true, ignorePrivilege: true]   // Mapping 属性方式
```

## 13.2 用 JWT 维持登录状态

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

## 13.3 `f_jwt` API 速览

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

## 13.4 端到端演示（登录 → 拿 JWT → 访问）

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

# 第十四章 CRON 定时任务：`fountain::f_ticktock`

**【镜头】** `fdemo/user/src/util/cron/TickTockTest.cj`

## 14.1 最小可用

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

## 14.2 可选属性

```cangjie
public prop once: Bool { get() { false } }           // true = 只执行一次
public prop concurrentable: Bool { get() { false } } // true = 上次没跑完也允许下次触发
public func executing(stamp: Int64): Bool { ... }    // 自定义「是否正在执行」判断
public func reset(stamp: Int64): Unit { ... }        // 自定义重置执行状态
public open prop name: String { get() { ... } }      // 默认取类型全限定名
```

## 14.3 CRON 表达式语法

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

## 14.4 延迟任务

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

# 第十五章 日志：`fountain::f_log`

**【镜头】** 左半边终端 `tail -f ./log/fdemo.log`，右半边 IDE 里打开 `f_log/README.md` 和 `fdemo/boot.sh` 的 `logger_*` 那一段

## 15.1 为什么还要自己写一个日志模块

**【口播】**

> `f_log` 和后头第十七章那八个模块是同一个定位——**可以单独拿走**：不用启动器、不用 IOC，`import` 进来就能用。但它比工具箱更靠前一步：**一个服务上线前，第一件要配好的事就是日志**，所以我们把它放在正文里讲，不放进基础设施那一章。
>
> 你可能会问：仓颉生态里已经有 `stdx.log` 了（`Logger` / `LogRecord` / `LogWriter` / `LogValue` 一整套抽象），为什么 fountain 还要再写一个？
>
> 三个理由：
>
> **第一，它是 `stdx.log` 的实现，不是替代品。** `f_log` 的 `AbstractLogger` 直接继承 `stdx.log.Logger`，stdx.log 的写法你照用；更重要的是，它在模块加载时把 **stdx.log 的全局 logger 接管**了：
>
> ```cangjie
> // f_log/src/base/global.cj
> setGlobalLogger(LoggerFactory.getLogger('fountain::f_log.global'))
> ```
>
> 也就是说，**任何第三方库只要用全局 logger 打日志，输出也会进你的 appender**。两个真例子：`stdx.net.http` 的日志被接进了 MVC（`builder.logger(LoggerFactory.getLogger('stdx.net.http'))`）；openGauss 驱动的日志用 `LoggerFactory.getLogger('opengauss')`。**它们和你的业务日志在同一个文件里、同一套格式、同一个进程号。**
>
> **第二，零配置、零注入，而且默认静默。** 不需要启动器、不需要 `logback.xml` 那种配置文件——`private static let log = LoggerFactory.getLogger<MyClass>()` 这一行就能用。而且**不配 appender 它什么都不输出**，不会像很多框架那样先给你刷一屏。
>
> **第三，异步 + 模板化。** 业务线程只负责「记下当下时间与线程 ID、把消息闭包排进队列」，渲染、落盘、刷屏全在专属线程上做；消息支持 `{}` 占位符，还能直接拿 `@DataAssist` 对象做**具名取值**——这是 stdx.log 没有的。
>
> 先看一页结构：
>
> ```
> LoggerFactory.getLogger<T>()   名字 = T 的完整限定名（如 fountain::f_orm.base.SqlExecutor）
>   └─ LoggerWrapper            持有 facade 的引用，可 CAS 热替换（15.8）
>        └─ LoggerAppenderFacade  本身也是异步的：一个名字 → 一条队列 + 一个消费线程
>             ├─ ConsoleAppender  队列 tag = console://（所有 console 共享）
>             ├─ FileAppender     队列 tag = file:///<路径>（同路径共享）
>             └─ Tcp / Udp / Unix / UnixDatagram Appender
> ```

## 15.2 三条纪律（先记这个，后面都是细节）

**【口播】**（这三条是本模块最容易踩的坑）

> **纪律一：默认什么都不输出。**
>
> 内置 6 种 appender：`console`、`file`、`tcp`、`udp`、`unix`、`unixDatagram`。**但一个都不会自动启用**——`logger_appender_<kind>` 没配，这类 appender 就不存在。所以你至少得写一行：
>
> ```bash
> export logger_appender_console=myConsole     # 值是你给这个 appender 起的名字
> ```
>
> 才会有第一条日志。这也是为什么 `fdemo/boot.sh` 里必须有那几行 `logger_*`。
>
> **纪律二：级别和格式挂在 appender 上，不挂在 logger 名字上。**
>
> 命名规则是两段式的：
>
> ```
> logger_appender_<kind>=<AppenderName>[,<AppenderName2>...]   # 先给这类 appender 挂上若干个具名实例
> logger_appender_<AppenderName>_level=DEBUG                   # 再逐个配级别
> logger_appender_<AppenderName>_pattern='...'                 # 和格式
> ```
>
> 所以 fountain **没有** log4j 那种「logger 名字树」的概念：你没法说「只给 `fountain.orm.*` 开 DEBUG」。级别是这个 appender 全局的，**要区分来源就靠格式里的 `%name`**。
>
> **纪律三：业务线程只入队，渲染在后台；但默认「队列满就等」。**
>
> 调 `log.info{...}` 时，业务线程做的事只有两件：采集时间戳 / 线程 ID，然后把闭包投进队列。**级别判断、字符串渲染、落盘都在后台线程**。而 `loggerAsyncTimeout` 的默认值是 `Duration.Max`，意味着**队列满时入队方会一直等**（业务线程投 facade 队列时就是业务线程等），而不是丢日志。想丢就显式配 `loggerAsyncTimeout` 加 `loggerAsyncTimeoutPolicy`（见 15.5）。

## 15.3 配置项全表

**【口播】** 这张表就是本节的全部，左边一列可以直接抄。

| 配置项 | 默认值 | 说明 |
| --- | --- | --- |
| `logger_appender_console` | 无 | 值 = 你起的 console appender 名；逗号分隔可挂多个 |
| `logger_appender_file` | 无 | 同上，文件 appender |
| `logger_appender_tcp` / `_udp` / `_unix` / `_unixDatagram` | 无 | 远端 appender |
| `logger_appender_<Name>_level` | `INFO` | `OFF` / `ERROR` / `WARN` / `INFO` / `DEBUG` / `TRACE` / `ALL` |
| `logger_appender_<Name>_pattern` | `[%level-%name] %d{yyyy/MM/dd,HH:mm:ss.SSS}\|%m` | 见 15.4 占位符表 |
| `logger_appender_<Name>_path` | `${工作目录}/logs/${命令名}.log` | file 专用；目录自动创建 |
| `logger_appender_<Name>_rotateDuration` | `DAY` | file 专用；`NANOSECOND`…`YEAR`，大小写不敏感（**别用亚秒级**，见 15.6） |
| `logger_appender_<Name>_rotateSize` | `Int64.Max` | file 专用；支持 `100k` / `100M` / `1G` 这种写法 |
| `logger_appender_<Name>_compressFormat` | `''` | file 专用；`Deflate` / `GZip`，可带级别如 `Deflate(9)` |
| `logger_appender_<Name>_url` | 无 | file 专用；`file://<路径>?rotateSize=..&rotateDuration=..&compressFormat=..`，**url 里的参数优先于上面三个独立配置项** |
| `logger_appender_<Name>_host` / `_port` | 无 | tcp / udp 专用 |
| `logger_appender_<Name>_bufSize` | 无 | tcp / unix 专用（发送缓冲字节数） |
| `logger_appender_<Name>_sendTimeout` / `_writeTimeout` | 无 | udp / unix 专用（`Duration` 字符串） |
| `loggerAsyncBufsize` | `1024` | 异步队列容量，**同时也是缓冲区池的大小** |
| `loggerAsyncTimeout` | `Duration.Max` | 队列满时等待多久（超时后才轮到 policy 生效） |
| `loggerAsyncTimeoutPolicy` | `discard` | `discard` 丢这条 / `abort` 抛 `LogException` / `alwaysWaiting` 死等 |
| `logger_asyncWaitTimeout` | `5ms` | 借不到缓冲区时的等待时长；超时**丢弃本条**并打印 `AsyncLogger.SyncQueueOutputStream.EmptyPool` |

**【命令】**（`fdemo/boot.sh` 的 `exports()`，一个字都不用改）

```bash
export logger_appender_console=FDemoConsole     # 这是控制台日志记录器的名称，可以任意起名，名称得符合标识符规范
export logger_appender_FDemoConsole_level=DEBUG
export logger_appender_FDemoConsole_pattern='[%level-%name]%d{yyyy/MM/dd,HH:mm:ss.SSS}|%tid;%m'
export logger_appender_file=FDemoFile           # 这是文件日志记录器的名称，可以任意起名
export logger_appender_FDemoFile_level=INFO
export logger_appender_FDemoFile_pattern='[%level-%name]%d{yyyy/MM/dd,HH:mm:ss.SSS}|%tid;%m'
export logger_appender_FDemoFile_path=./log/fdemo.log
export logger_appender_FDemoFile_rotateDuration=DAY
export logger_asyncWaitTimeout=5ms              # 异步日志缓冲区等待时间，默认是5毫秒，超过这个时间，本次日志被忽略
```

**【口播】**

> 读法：**「一类 appender 挂几个自定义名字，每个名字自己配级别和格式」**。所以上面这段等于：
>
> - 控制台：一个叫 `FDemoConsole` 的 appender，级别 `DEBUG`；
> - 文件：一个叫 `FDemoFile` 的 appender，级别 `INFO`，写 `./log/fdemo.log`，按天切割。
>
> 注意 `fdemo` 给控制台是 `DEBUG`、给文件是 `INFO`——**同一个 Logger 打出来的日志，两个 appender 收的粒度不一样**。这就是「级别挂在 appender 上」带来的第一个好处：**排查问题时开控制台，长期留档只留 INFO。**

## 15.4 写日志：三种写法 + 占位符

**【口播】**（三种写法，覆盖 99% 的场景）

> ```cangjie
> private static let log = LoggerFactory.getLogger<UserServiceImpl>()   // 名字 = 完整限定名
> // 也可以起任意名字：LoggerFactory.getLogger('my.business')          // 名字 = 你写的字面量
> ```

**① 惰性 lambda（最常用，推荐）**

```cangjie
log.info{'start create user: ${name}'}            // info(message: () -> String)
log.debug{'args = ${someExpensiveToString()}'}    // 级别不够时，这个 lambda 根本不会执行
```

**【口播】**

> 关键在「惰性」：**级别不够时这个 lambda 不会被执行**，所以它里面的字符串拼接、`toString()`、JSON 序列化全都省掉了。对比一下下面的做法——**字符串在调用点就拼好了，日志级别不符也白拼**：
>
> ```cangjie
> log.debug('args = ' + someExpensiveToString())   // 反例：拼字符串的成本跑不掉
> ```
>
> 但要补一个准确的说明：**级别判断发生在后台消费线程上**（见 15.5），所以 `log.debug{...}` 在 DEBUG 关掉时**仍然会有一次入队**（队列满时这一入队同样会等）。也就是说「零成本」省的是渲染，不是排队本身。

**② 模板占位（`{}` 位置 / `{name}` 具名）**

```cangjie
log.info('user {} login from {}', [name, ip])        // 位置占位：按数组顺序填
log.info('user {name} is {age}', user)               // 具名占位：user 是 @DataAssist[fields] 的对象
log.info('order {id} paid', map)                     // Map / ArrayList / TreeMap 等也支持
```

**【口播】**

> 底层就是第九章那个 `TextTemplate`（`compile(message, prefix: "{", suffix: "}")`），所以它能用 `TextTemplate` 的全部能力——比如 `{time:yyyy/MM/dd}`、`{a.0.b}` 这种路径取值。
>
> 具名形态有个额外好处：**字段会过一次 `LoggerConfig.filter`**，天生就能做脱敏：
>
> ```cangjie
> LoggerConfig.filter = MyLogFilter()   // 实现 LogFilter：filter(key, value) -> Option<(String, String)>
> ```

**③ 异常（栈会一起写出去）**

```cangjie
log.error(e){'query user failed: ${id}'}          // error(ex: Exception, message: () -> String)
log.error('query user failed', e)                 // 或者 message 在前、异常在后
```

**【口播】** 该用哪个级别：

| 级别 | 什么时候用 |
| --- | --- |
| `trace` | 只在本地调疑难杂症时开，基本等于「打点」 |
| `debug` | 框架自己的 SQL、`MVC.accessLog` 都在这一级 |
| `info` | 业务关键节点：注册、下单、状态变更 |
| `warn` | 可恢复的异常：重试、降级、参数被纠正 |
| `error` | 请求失败、依赖不可用，**一定要带异常对象** |
| `fatal` | 进程级不可继续 |

另外 `log.debugEnabled` / `infoEnabled` / `errorEnabled`⋯⋯这六个属性是给你在**极端热路径**上做前置判断用的。既然级别判断在后台，`if (log.debugEnabled)` 就不是多余的——**在被调用次数极高的循环里，它能帮你省掉那次入队**。

**【口播】** 占位符全表（`pattern` 里能写什么）：

| 占位符 | 输出 | 备注 |
| --- | --- | --- |
| `%level` | `DEBUG` / `INFO` / `WARN` / `ERROR` / `FATAL` / `TRACE` | 纯文本，没有颜色控制符 |
| `%name` | logger 名字 | `getLogger<T>()` 时是完整限定名；排查问题的第一线索 |
| `%m` | 消息正文 | 若带了 attrs，会以 `;{"k":v}` 追加在消息后面 |
| `%d{yyyy/MM/dd HH:mm:ss.SSS}` | 时间 | `%d` 不带参数时默认 `yyyy-MM-dd,HH:mm:ss.SSS` |
| `%tid` | 线程 ID | **在调用点采集**（记录日志的那个线程） |
| `%tname` | 线程名 | **在写出时采集**（消费线程），排查问题请用 `%tid` |
| `%pid` | 进程 ID | 多副本部署时用来对号 |
| `%app` / `%appver` | 应用名 / 应用版本 | 来自应用自己的 `cjpm.toml`（`fboot build` 生成模块注入） |
| `%fver` | `fountain(1.3.7)` | 框架版本 |
| 其它 `%x` | 原样输出 | 不认识的占位符不会报错 |

**【口播】** 两条实用规则：一是**结尾会自动加换行**，`pattern` 里别自己写 `\n`；二是 `%d{...}` 里用的是仓颉 `DateTime.format` 的格式串，`yyyy`/`MM`/`dd`/`HH`/`mm`/`ss`/`SSS` 该大小写敏感就大小写敏感。

## 15.5 一条日志的旅程：异步是怎么做的

**【镜头】** 幻灯片上一张流向图

**【口播】**（本节是全章最硬核的一节，但结论很简单：**业务线程只入队，渲染与落盘都在专属线程**）

> 一条 `log.info{'...'}` 在 fdemo 里的完整路径：
>
> ```
> ① 业务线程：AbstractLogger.append(level, message, ex)
>      ├─ 先采集时间戳 DateTime.now() 和 %tid（此刻的线程 ID）   ← 时间/线程 ID 是「调用点」的
>      └─ 交给 LoggerAppenderFacade：把「广播给所有 appender」这个闭包投进队列
>           队列 tag = f_log.LoggerAppenderFacade_<logger 名字>，容量 = loggerAsyncBufsize
>
> ② facade 的消费线程：取出闭包，遍历所有 appender
>      └─ 对每个 appender 再调 append(level, message, now, tid, ex)
>           └─ 这里才做「级别判断」+ 求值 lambda（所以 message 字符串是在消费线程上拼出来的）
>              └─ AsyncLogger：把 pattern + 消息渲染成字节，写进 SyncQueueOutputStream
>                   遇到 '\0' 结束符 → 这一条日志 = 一个批次，提交到批次队列
>                   └─ 再往 appender 自己的队列投一个闭包（tag = console:// 或 file:///<path>）
>
> ③ appender 的消费线程：把批次按顺序写进真正的 OutputStream（终端 / 文件），并 flush
> ```

**【口播】** 这段路径里有四个设计点值得单独讲：

> **（1）两级异步，两级队列。** facade 一条队列（**每个 logger 名字一条**），每个 appender 一条队列（**console 全局共享一条；file 按路径共享**）。所以线程数是可算的：
>
> ```
> 线程数 ≈ 不同 logger 名字的个数 + appender 个数
> ```
>
> 一个应用里 `getLogger<T>()` 被几十个类用到，就是几十条常驻消费线程——都是空转等队列，开销很小，但**心里要有这笔账**。
>
> **（2）`\0` 是批次边界。** 写日志就是往缓冲区塞字节，塞完写一个 `\0`，`SyncQueueOutputStream` 看到 `\0` 就把整块提交换缓冲区。这样**一条日志在文件里不会被别的线程插进来切成两半**。顺带一个小特性：`\0` 本身**不会**被写进日志文件。
>
> **（3）缓冲区是池化的，池空会丢日志。** 缓冲区池大小 = `loggerAsyncBufsize`（默认 1024）。上面 ② 那个消费线程在把日志渲染成字节之前，先要从池里借一块缓冲（借用时最多等 `logger_asyncWaitTimeout`，默认 5ms），借不到就打印一行 `AsyncLogger.SyncQueueOutputStream.EmptyPool` 并**丢掉本次写入**。这条 5ms 的配置在 `fdemo/boot.sh` 里就有，注释也写明了：「超过这个时间，本次日志被忽略」。
>
> **（4）队列满了怎么办，由 timeout + policy 决定。**
>
> ```
> loggerAsyncTimeout      默认 Duration.Max  → 相当于「一直等到有空位」（入队方被拖住）
> loggerAsyncTimeoutPolicy 默认 discard      → 只在上面那个 timeout 真的超时后才会被执行
> ```
>
> 这里要特别提醒：**因为默认 timeout 是 `Duration.Max`，默认配置下「队列满」= 入队方阻塞等待，policy 根本轮不到生效**。而"入队方"在两级队列上不是同一个角色：往 facade 队列投递的是**业务线程本身**，往 appender 队列投递的是 **facade 的消费线程**——所以队列满时被拖慢的是业务线程，或者这条日志链路的后续搬运。所以：
>
> - 想要「宁可丢日志也别拖慢业务」：`loggerAsyncTimeout=10ms` + `loggerAsyncTimeoutPolicy=discard`；
> - 想要「日志一条不能少，慢就慢」：保持默认，或明确写 `loggerAsyncTimeoutPolicy=alwaysWaiting`；
> - `abort` 会抛 `LogException`，**不建议在业务路径上开**。
>
> 最后别忘了**退出**：facade 在 `env.atExit` 里注册了关闭动作，`close()` 会**先把队列排空**（自旋等 `queue.size == 0`，再等 100 微秒把最后一个字节数组写出）然后才关流。**这就是为什么 `Ctrl-C` 之后日志文件里不会缺最后几条。**

## 15.6 文件切割与压缩

**【口播】**

> 文件 appender 的行为，一句话概括：**「默认按天切，切完的文件加时间后缀，配了压缩就压」**。
>
> **（1）切割时机**，两个条件满足任一即切：
> - **跨周期**：文件创建时间早于当前时间单位的起点（按天切 = 今天凌晨之前创建的）；
> - **超大小**：`size + 本批字节数 >= rotateSize`（写在文件里的预判，不是事后检查）。
>
> **（2）切割动作**：关掉当前文件 → `rename` 成 `<原路径>.<上一个周期的时间戳>` → 如果配了 `compressFormat`，在**独立线程里**压缩（`Deflate` → `.lz`，`GZip` → `.gz`），然后原文件被删掉 → 重新以 Append 模式打开原路径。
>
> 所以按天切、不压缩时，你会看到：
>
> ```
> log/fdemo.log         ← 当前正在写
> log/fdemo.log.20261001 ← 昨天那份（后缀是"上一个周期"）
> ```
>
> **（3）`_url` 写法**（一个字符串替代四个配置项，url 参数优先）：
>
> ```bash
> export logger_appender_myfile_url='file://./log/app.log?rotateSize=100M&rotateDuration=HOUR&compressFormat=GZip'
> ```
>
> **（4）`rotateSize` 支持人类可读写法**：`100k`、`10M`、`1G`（内部 `computeBytes` 解析，不写单位就是字节）。
>
> ⚠️ **两个要注意的地方**：
>
> - **`rotateDuration` 不要配亚秒级**（`MILLISECOND` / `MICROSECOND` / `NANOSECOND`）。切割后文件名的后缀粒度只到秒，而"跨周期"判断几乎每一次写入都会成立——结果是**每次写日志都 rename 一次 + 重开文件**。按 `MINUTE` 起步、常用 `HOUR` / `DAY`。
> - **压缩失败也会删掉原文件**：压缩那段的 `finally` 里直接 `removeIfExists(原路径)`，压缩过程中出的错只打印栈。**日志是重要证据的场景（审计、计费）建议先不压缩，或者自测一遍压缩路径。**

## 15.7 现场演示：把框架自己的日志调出来

**【镜头】** 终端 `cd fdemo && ./boot.sh run`；另一个终端 `curl`

**【命令】**

```bash
# ① 启动（boot.sh 的 exports() 已经带了 console=DEBUG、file=INFO）
./boot.sh run

# ② 另开终端发一个注册请求（这个接口声明的是 form 表单，不是 JSON）
curl -X POST 'http://127.0.0.1:8080/api/user/register' \
     -d 'username=fountain&password=123456'

# ③ 看文件那份
tail -f ./log/fdemo.log
```

**【预期】**

> 控制台（`FDemoConsole`，`DEBUG`）里会出现两类**框架自己打的**日志：
>
> ```
> [DEBUG-std.reflect.TypeInfo.get("fountain::f_orm.base.SqlExecutor")]2026/10/02,10:21:33.508649747|12876;postgres is executing a sql: insert into user_info( "id" , "username" , "password" , "save_time" )values(?,?,?,?) returning id, args: [(0, Int64, 0), (1, String, fountain), (2, String, 123456), null], consumed: 3ms200us101ns
> [INFO-std.reflect.TypeInfo.get("fountain::user.controller.CurrentUserController")]2026/10/02,10:21:33.512649747|12876;MVC.accessLog:POST:/api/user/register?username=fountain&password=123456; consumes:Some(application/x-www-form-urlencoded); params:[fountain,123456]; returned:{…}; status:200; elapsed:2ms300us123ns
> ```
>
> 文件（`FDemoFile`，`INFO`）里只有第二行——**第一条是 `DEBUG`，被文件 appender 过滤掉了**。

**【口播】**

> 这一屏要讲的其实是三件事：
>
> **第一，`%name` 是你定位问题的第一把钥匙。** `std.reflect.TypeInfo.get("fountain::f_orm.base.SqlExecutor")` 这一行告诉你：**这是 ORM 在执行 SQL**——`%name` 就是 `LoggerFactory.getLogger<T>()` 里 `T` 的完整限定名（仓颉的限定名用 `::` 分段）；`consumed:` 后面是这条 SQL 的耗时，`3ms200us101ns` 就是 3 毫秒 200 微秒 101 纳秒。而 `...CurrentUserController` 这一行是 MVC 的 access log——**名字就是处理这个请求的 controller 类**，`MVC.accessLog:` 后面依次是方法、URL（POST 的表单字段拼在 `?` 后面）、Content-Type、入参、返回值、状态码、耗时。
>
> 两个可以顺嘴讲的细节：SQL 里 `"id"`、`"username"` 的双引号是方言的 `involve` 包上去的，末尾的 `returning id` 也是 PostgreSQL 方言追加的 `lastInsertId` 片段；`returned:` 后面是 controller 的返回值**原样拼进去**的——这个接口返回的是多行 JSON，所以文件里这条 access log 会跟着展开成好几行。
>
> 换句话说：**你几乎不用写日志，框架已经给你打好了。** 排查线上问题时，你需要的动作是「把级别调成 DEBUG，然后按 `%name` 去 grep」。
>
> **第二，`fboot` 生成的应用信息自动进了日志。** `%app` / `%appver` 的值不来自任何配置文件——`fboot build` 读你的 `cjpm.toml`，生成一段代码调 `AppVersion.set(banner, name, version)`，日志里的应用名和版本就是从这里来的。这是 `fboot` 和 `f_log` 之间唯一的一根线，也是「零配置」为什么不等于「没有信息」。
>
> **第三，想只看文件不看控制台？** 把 `logger_appender_console` 那两行删掉（或注掉）重启就行——**没有配置就没有这个 appender**，这正是纪律一。

**【命令】**（再演示一次「按小时切 + 压缩」）

```bash
export logger_appender_FDemoFile_rotateDuration=HOUR
export logger_appender_FDemoFile_rotateSize=10M
export logger_appender_FDemoFile_compressFormat=GZip
./boot.sh run
```

**【预期】** `log/` 目录下会积累 `fdemo.log.2026100210.gz` 这样的文件。**演示完记得把这三行撤掉**，否则一小时一个文件。

## 15.8 运行期刷新：`LoggerFactory.refresh()`

**【口播】**

> 配置读一次就固定了吗？不是。
>
> ```
> LoggerWrapper.refresh()
>   → 按当前配置新建一个 LoggerAppenderFacade
>   → CAS 把引用换过去（换的时候老的 facade 关闭：排空队列、关流）
> ```
>
> 所以「运行期换级别、换格式、加一个 appender」在理论上是支持的，入口是一行：
>
> ```cangjie
> LoggerFactory.refresh()    // 刷新所有已创建的 logger
> ```
>
> 但这里有个**必须知道的现实**：`LoggerConfig` 的 `static init` 里确实注册了回调——
>
> ```cangjie
> Config.refresher(confPrefix, LoggerFactory.refresh)
> ```
>
> 可是按第四章 4.8 里那条已知问题，`f_config` 的 `refresher` 前缀匹配恒不成立，**`Config.set` 不会触发任何刷新回调**。所以现阶段的实际做法是：**改完配置自己调一次 `LoggerFactory.refresh()`。**
>
> ```cangjie
> Config.set('logger_appender_FDemoConsole_level', 'DEBUG')
> LoggerFactory.refresh()      // 立刻生效，不用重启
> ```
>
> 想看效果，就在 fdemo 里随便找个 controller 加一个临时端点干这两件事，然后观察同一份日志文件里前后两段的粒度变化。**注意 level 是读 `logger_appender_<Name>_level` 这个键，不是 `logger_appender_console_level`——`<Name>` 是你起的名字。**
>
> 顺便交个底：**哪些配置 `refresh()` 能改、哪些必须重启**——
>
> | 配置 | 生效方式 |
> | --- | --- |
> | appender 的名字、级别、pattern、路径、切割、压缩 | `refresh()` 生效（重建 facade 与 appender） |
> | `loggerAsyncTimeout`、`loggerAsyncTimeoutPolicy`、异步队列容量 | 在 logger / appender **构造时**读取，`refresh()` 生效 |
> | `loggerAsyncBufsize` 的**池大小**那一半 | 缓冲区池是**进程级静态单例**，只在首次用到时按当时的配置建一次——**只能重启** |
>
> 「改配置→刷新」这条路最适合做的是**调级别**（`INFO` ↔ `DEBUG`），这也是线上最常用的动作；其余配置建议当成「重启才生效」来对待。

## 15.9 八个坑

| # | 现象 | 原因 / 解法 |
| --- | --- | --- |
| 1 | 日志一条都不输出 | 没配任何 appender。fountain **默认静默**，至少要 `logger_appender_console=<名字>` |
| 2 | 配了级别没生效 | 写成了 `logger_appender_console_level`。级别挂在**你起的名字**上：`logger_appender_FDemoConsole_level` |
| 3 | 想只给某个包开 DEBUG，做不到 | 级别挂在 appender 上，没有 logger 名字树。要分来源就加一个 appender 配不同 pattern，用 `%name` 区分 |
| 4 | 高并发时丢日志，控制台出现 `AsyncLogger.SyncQueueOutputStream.EmptyPool` | 缓冲区池（`loggerAsyncBufsize`，默认 1024）被占满且 `logger_asyncWaitTimeout`（默认 5ms）内没借到。加大 `loggerAsyncBufsize`，或接受丢弃 |
| 5 | 业务线程偶发变慢 / 卡顿 | 队列满时默认 `loggerAsyncTimeout=Duration.Max` 会**一直等**。要「宁可丢日志」就设 `loggerAsyncTimeout=10ms` + `loggerAsyncTimeoutPolicy=discard` |
| 6 | 日志按秒切割，文件爆炸 | `rotateDuration` 配了亚秒级（`MILLISECOND` 等）。按 `MINUTE` 起步，常用 `HOUR` / `DAY` |
| 7 | 改了 `loggerAsyncBufsize` 没生效 | 它同时是**缓冲区池的大小**，而池是进程级静态单例——首次用到时建一次，**改它只能重启** |
| 8 | 改了 `loggerAsyncTimeout` / `_policy` 没生效 | 这两个值在 logger / appender **构造时**读取。改完要 `LoggerFactory.refresh()`（见 15.8） |

**【口播】**（再补两条不算坑但常被误会的）

> - 日志格式里没有颜色控制符，别指望控制台是彩色的（`%level` 输出的是纯文本 `DEBUG` / `ERROR`⋯⋯）。

## 15.10 速查卡

```cangjie
// 拿 logger：名字 = 完整限定名（推荐）/ 或任意字面量
private static let log = LoggerFactory.getLogger<UserServiceImpl>()
private static let log2 = LoggerFactory.getLogger('my.business')

// 写日志：惰性 lambda（级别不够零成本）/ 模板 / 异常
log.info{'start create user: ${name}'}
log.info('user {} login from {}', [name, ip])
log.info('user {name} is {age}', userPo)          // @DataAssist[fields] 对象 → 具名占位
log.error(e){'query user failed: ${id}'}
log.error('query user failed', e)

// 脱敏 / 附带属性
LoggerConfig.filter = MyLogFilter()               // LogFilter 接口
log.withAttrs([Attr('traceId', LogValue('...'))])

// 运行期刷新（f_config 的 refresher 目前不会自动触发，要手动调）
LoggerFactory.refresh()
```

```bash
# 配置：一类 appender 挂若干具名实例，实例各自配级别/格式
export logger_appender_console=FDemoConsole
export logger_appender_FDemoConsole_level=DEBUG
export logger_appender_FDemoConsole_pattern='[%level-%name]%d{yyyy/MM/dd,HH:mm:ss.SSS}|%tid;%m'
export logger_appender_file=FDemoFile
export logger_appender_FDemoFile_level=INFO
export logger_appender_FDemoFile_path=./log/fdemo.log
export logger_appender_FDemoFile_rotateDuration=DAY          # NANOSECOND..YEAR，别用亚秒级
export logger_appender_FDemoFile_rotateSize=100M             # 可选，支持 100k/100M/1G
export logger_appender_FDemoFile_compressFormat=GZip         # 可选：Deflate / GZip
export logger_asyncWaitTimeout=5ms                           # 借不到缓冲区→丢弃本条
# export loggerAsyncBufsize=1024                             # 队列容量 & 缓冲区池大小
# export loggerAsyncTimeout=10ms                             # 队列满时的等待（默认 Duration.Max＝死等）
# export loggerAsyncTimeoutPolicy=discard                    # discard / abort / alwaysWaiting
```

**【口播】**（收尾）

> 这一章的核心其实就两句话：
>
> **第一，`f_log` 是 stdx.log 的实现，而且默认静默**——它不是「又一个日志框架」，而是「把你的日志（业务日志、MVC access log、ORM SQL、第三方库日志、数据库驱动日志）统一收进同一条异步管道」的那一层。
>
> **第二，调试靠 `%name` + 级别，落盘靠 appender**——级别挂在 appender 上（所以没有「只给某个包开 DEBUG」），来源靠 `%name` 认（所以排查时 `grep 'fountain::f_orm' ./log/fdemo.log` 就行了）。
>
> 下一章我们把这些东西串起来：**一次 `POST /api/user/register`，从 `f_config` 装载配置开始，穿过 MVC、bean、aspect、ORM，最后落进这张日志表。**

---

# 第十六章 串讲：一次请求穿过整个框架

**【镜头】** 画一张纵向调用链 + 终端实时日志。用一个 `POST /api/user/register` 走完全流程。

```
⓪ 进程启动：f_config 的 static init 装载环境变量 + 命令行参数（命令行覆盖环境变量），
   并准备 sensitiveMap（编译期内嵌的敏感配置，配了 SM4 则运行期解密）
① fboot run 加载动态链接库
   └─ static init(): @Bean 注册进 BeanFactory；Initializer 注册进 InitializerCollection
   └─ 拓扑排序 initialize()：BeanInitializer → ORMInitializer → MVCInitializer → TickTockInitializer ...
   └─ 各 start() spawn 到新线程：MVC 启动 HTTP 服务（阻塞）、TickTock 启动定时器

② curl -XPOST /api/user/register
   └─ MVC 路由匹配（@PostMapping + consumes/produces/params/headers）
   └─ 参数绑定（@RequestParam）
        └─ f_http 的 MediaType 把请求体字节转成 Data
        └─ f_data 把 Data 转成对象并触发校验（@CombinedValidator）
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

④ 旁路：f_util.UUID + f_random 给会话发密钥（UserSessionCache 里的 UUID.random()），
   f_http 的 MediaType 配合 f_data 给响应做序列化；
   f_util 的 PathPattern 是 ② 里「路由匹配 + 抽路径变量」的引擎

⑤ 底座：f_cache 存登录状态、f_pool 撑起数据库连接池、f_regex 缓存住路径正则、
   f_time 解析所有 Duration 型配置；f_log 在 ② 的每一步上落日志——SQL 的 DEBUG、accessLog 的 INFO；
   而 f_base 在进程退出时按权重把上面这些依次收掉（先停服务、最后关数据库）
```

**【口播】**

> 这一屏就是 fountain 的全部：
> **f_config 负责配置、f_bean 负责装配、f_aspect 负责横切、f_data 负责流动、f_util 提供工具箱、f_http 负责格式、f_mvc 负责协议、f_orm 负责数据库、f_security + f_jwt 负责身份、f_ticktock 负责CRON定时器、f_random 负责随机性、f_log 负责日志、f_cache/f_pool/f_collection/f_time/f_regex/f_rx 构成运行时底座。**
> 而且从头到尾你没写过一个配置文件、没写过一行 `main`。
> 业务代码里你只写了 `UserController`、`UserService`、`UserDAO`、`UserPO` 四个东西，加起来不到 200 行。

---

# 第十七章 运行时基础设施：`f_base` / `f_cache` / `f_pool` / `f_collection` / `f_time` / `f_regex` / `f_rx` / `f_random

**【镜头】** 先给八个模块的 README 各一屏，再回到它们在框架内部的调用点

## 17.1 开场：框架之下的那一层

**【口播】**

> 前面讲了 IOC、AOP、MVC、ORM、安全、定时任务、日志——这些是**你能直接感知到的框架能力**。
> 但它们是站在另一层之上的。这一章讲的就是那一层：**运行时基础设施**，当「零部件手册」单独翻也完全可以。
>
> | 模块 | 一句话 | 在 fountain 里被谁用了 |
> | --- | --- | --- |
> | `f_base` | 所有模块的公共底座：进程优雅退出、Result/Option 与集合迭代器扩展、`Comparator`、`StringGenerator`、`FutureTask` | 全部模块；`f_app` 启动时调 `ExitCallbacks.toExitGracefully()`，`f_mvc` / `f_pool` / `f_cache` / `f_orm` / `f_bean` / `f_rpc` 都用 `atExit` 登记清理 |
> | `f_cache` | 堆缓存（强引用 / 弱引用），可设寿命与容量 | `f_security` 的 `JWTHeapCacheStore`、`f_data` 的 `DataPath.cache`、`f_orm` 的结果缓存 |
> | `f_pool` | 通用对象池、键池、数组池 | `f_orm` 的 `DatabasePool`（`orm_databasePool*` 那批配置项） |
> | `f_collection` | 标准库没有的集合 + 集合扩展 | `f_store`（LSM-Tree）、`f_concurrent`、ORM 分页 |
> | `f_time` | `std.time` 扩展：`TimeUnit` + `Int64` 时间 DSL | 所有用 `Duration` 作配置项的地方（`mvc_readTimeout` 等） |
> | `f_regex` | 正则扩展 + **正则缓存** | `f_util` 的 `PathPattern`、`f_data` 的校验器 |
> | `f_rx` | 反应式编程（Observable / Observer / 背压） | 流式数据处理场景 |
> | `f_random` | 随机数扩展：区间随机、随机流、随机字符串、蓄水池抽样 | `f_app` 的 `fboot randhex`、`fdemo` 的 `UserSessionCache` 会话密钥 |
>
> 这八个模块的共同特点：**零配置、可以单独引入、不绑架你的架构**。就算你不用 fountain 的框架部分，把它们当工具库用也完全没问题。

## 17.2 `f_base`：所有模块脚下的那一层

**【口播】**

> `f_base` 是 fountain 的公共底座——README 的第一句话就是「建议开发时无脑导入本包」。它自己只有一个外部依赖（字符集转换库 `charset4cj`），但仓库里每个模块都依赖它，所以先讲它。
> 它做的事可以归成四类：**一个 import 打底、进程退出、类型转换与集合扩展、一批通用小工具**。

### 一个 import 打底

```cangjie
import fountain::f_base.*
```

**注意**：`f_base` 在包里做了 `public import`——`std.collection.*`、`std.reflect.*`、`std.regex.*`、`std.time.*`，以及 `std.math.MathExtension`。所以这一个 import 之后，`ArrayList`、`HashMap`、`Regex`、`Duration`、`DateTime` 都不必再单独引入。这也是 `fboot workspace` 生成的 `cjpm.toml` 里默认就带 `f_base` 依赖的原因（见 3.2）。

### 进程退出：`ExitCallbacks`（`f_base` 最容易被低估的一段）

```cangjie
public struct ExitCallbacks {
    // 重置并注册 SIGTERM / SIGINT，回调跑完 exit(0)
    public static func toExitGracefully(): Unit
    // 回调按权重升序执行，权重相同的按注册顺序
    public static func atExit(priority: UInt16, atexit: () -> Unit): Unit
}
```

**【口播】**

> 只要进程收到 `kill 15`（SIGTERM）或 `Ctrl+C`（SIGINT），`f_base` 注册的处理函数就会依次执行所有通过 `atExit` 登记的清理函数，**权重升序、权重相同的按注册顺序**，全部跑完再 `exit(0)`。
> 注册时机是**所有动态链接库加载完成之后**，而且会先重置之前注册的同名处理函数——避免和第三方库、或你自己注册的 SIGTERM / SIGINT 处理函数打架。
>
> 什么时候需要自己调 `toExitGracefully()`？**用了 `f_app` 就不需要**——fountain 应用的启动器在初始化 starter 之后会自动调用它；只有「只引 `f_base`、不引 `f_app`」的独立工具才会漏掉这一步。
>
> 业务代码基本碰不到它，因为框架模块在自己的 `static init` 或构造阶段就把清理登记好了：

| 模块 | 登记的内容 | 权重 |
| --- | --- | --- |
| `f_mvc` | 关闭 HTTP 服务器（`closeGracefully`） | 0 |
| `f_rpc` | 服务端注销、客户端关连接 | 0 / 252 |
| `f_bean` | `BeanFactory.shutdown` | 253 |
| `f_pool` | `KeyPool.close` | 254 |
| `f_cache` | `HeapCache.destroy`（停检查线程） | 254 |
| `f_orm` | `ORM.close`（关数据库） | 255 |

> 权重小的先跑，所以 `Ctrl+C` 的顺序是**先停服务、再关中间件、最后关数据库**——一个进程最体面的下线姿势。想给自己的模块加清理，就来一行 `ExitCallbacks.atExit(200){ ... }`。
>
> 一个前提：Windows 上这整段是条件编译出来的空实现（`@When[os != "Windows"]`），所以这套优雅退出只在非 Windows 平台生效。

### `Result<T, E>` 与 `Option` 扩展：把转换补齐

```cangjie
// Result：Ok / Ok(T) / Err / Err(E) / NoResult 五态
r.isOk / r.withValue / r.result() / r.err()
r.orDefault(0) / r.orElse{ 0 } / r.mapValue{ v => ... } / r.mapError{ e => Ok(...) }
r.filterOk() / r.filterErr() / r.ignore() / r.flatten() / r.transpose<U>()

// Option：转 Result、当迭代器、链式调用
v.toResult<Int64, String>() / v.iterator() / v.call{ x => x + 1 }
v.caller{ x => x + 1 }.none{ 0 }.call()
```

**【口播】** 标准库的 `Option` / `Result` 本身没多少转换手段，`f_base` 把 `Option ↔ Result ↔ 迭代器` 之间的桥都补上了：一个 `?` 值可以变迭代器、可以 `call` 成 `?R`、也可以 `toResult()` 变成五态枚举。写业务代码时能省掉大量 `if (let Some(x) <- ...)`。

### 集合与迭代器扩展

```cangjie
EmptyArray<Int64>.instance() / EmptySet<String>.instance() / EmptyMap<String, Int64>.instance()
it.toArray() / it.toArrayList() / it.groupBy{ x => x.dept } / it.peekable()
itr.min(cmp) / itr.max(cmp) / itr.flatten(toThrow: true) / itr.filterType<Sub>(exactly: false)
arr.grow(10) / arr * 3                        // 扩容 / 重复
1.isOdd / 1.flip() / Int64.BYTES / i.numberOfLeadingZeros()
'abcabc'.replaceFirst('a', 'x') / stringJoin(['a', 'b'], delimiter: ',')
'  x  '.trimAsciiBlanks()
```

**【口播】**（挑三个讲）

> `EmptyArray` 这一组空集合是标准库各类容器的「空实现」：`EmptySet` 实现了 `Set`、`EmptyIterator` 实现了 `Iterator`、`EmptyMap` 同时是 `Map` 和 `Bucket`……需要返回「空的那一个」时一行 `instance()` 就行，不用自己造空容器、也不会拿到 `null`。它们都把构造函数声明成 `private`，只能通过 `instance()` 取，本身没有任何状态。
> `groupBy` 一行把列表按 key 分组，返回 `HashMap<K, ArrayList<T>>`。
> `peekable()` 可以先 `peek()` 看一眼下一个元素、**不消费**——「看一眼再决定」的解析逻辑用它最舒服；它还实现了 `Resource`：关自己时会顺带关掉底层迭代器（底层没实现 `Resource` 就什么都不做）。

### 通用小工具（快速过一遍）

```cangjie
StringGenerator()                // 加强版 StringBuilder：indexOf / lastIndexOf / insert
                                 // / replaceFirst / replaceLast / reverse / substring / unsafeBytes
Comparator<T>(cmp).then{...}.reverse()   // 链式比较器；Comparator.create<T>() 把 Comparable 包成比较器
Equaler<T>                       // 同上，用于"多字段相等"与去重
HashBuilder()                    // 局部变量的哈希计算：.append(a).append(b).build()
resource(res){ r => ... }        // 替代 try-with-resource：fn 返回即关闭
ResourceManager(new)             // 每次 call 新建资源、结束时关闭
FutureTask<T>(fn)                // 父子任务：shutdownSubOnFinish 决定父任务结束时是否连子任务一起结束
InheritedTaskLocal<T>            // 可继承的 ThreadLocal：本任务没值就去父任务找
OverSizePolicy 家族               // 满了怎么办：Abort / Discard / RemoveSomeOne / CallerRuns / Blocking
Addable / Subable / Mulable / Cmpable / BitAndable ...   // 基础运算符接口：给泛型加"支持 +"这类约束
Option<T> 的 + - * / % ** & | ^ ! << >>                  // v + 1 -> ?T（另一个操作数是 T 或 ?T 都行）
@nameof(obj.field) / @nameValueOf(obj.field)             // 宏包 fountain::f_base.macros
```

**【口播】**

> 这批东西没什么故事，但都「写起来顺手」：`StringGenerator` 比标准库 `StringBuilder` 多出一整套查找与替换；`Comparator.then` 把多级排序写成一条链；`OverSizePolicy` 这套「满了怎么办」的策略家族被 `f_collection` 的优先队列与 `f_concurrent` 的同步优先队列拿去复用；`Addable` / `Cmpable` 这些接口解决的是「泛型参数想用 `+`、`>` 怎么约束」——标准库只给到 `Comparable` / `Equatable`。
> `@nameof` 这类宏适合把字段名当字符串用（日志键、配置键），展开发生在编译期，没有运行期开销。

## 17.3 `f_cache`：堆缓存

### 强引用 `HeapCache`

```cangjie
public class HeapCache<V> where V <: Object {
    public HeapCache(
        private let concurrencyLevel!: Int64 = DEFAULT_HEAP_CACHE_CONCURRENCY_LEVEL,  // 并发度，默认 128
        private let maxLife!: Duration = DEFAULT_HEAP_CACHE_MAX_LIFE,                 // 最大寿命
        private let maxSize!: Int64 = DEFAULT_HEAP_CACHE_MAX_SIZE,                    // 最大对象数
        private let checkDuration!: Duration = DEFAULT_HEAP_CHECK_CHECK_DURATION,     // 检查周期
        private let evictionCallback!: (String, V) -> Unit = {_, _ => ()}             // 失效回调
    )
    public static func builder(): HeapCacheBuilder<V>
    public func get(key: String): Option<V>
    public func contains(key: String): Bool
    public func once(key: String): Bool                          // 是否「一次性」对象
    public func prolong(key: String, life: Duration, once!: Bool = false): Bool
    public func prolong(key: String, deathTime: DateTime): Bool
    public func set(key: String, value: V, life!: Duration = this.maxLife, once!: Bool = false): ?V
    public func set(key: String, value: V, dieAt: DateTime): ?V
    public func getOrDefault(key: String, default: V): V
    public func getOrStore(key: String, value: V): V
    public func getOrCompute(key: String, callable: () -> V): V
    public func getOrCompute(key: String, callable: () -> (V, DateTime)): V
    public func getOrCompute(key: String, callable: () -> (V, Duration, Bool)): V
    public func remove(key: String): Option<V>
    public func removeIf(predicate: (String, V) -> Bool): Unit
    public prop size: Int64
    public func clear(): Unit
    public func destroy(): Unit                                  // 销毁后不可再用
}

public open class HeapCacheBuilder<V> where V <: Object {
    public func setMaxLife(maxLife: Duration): HeapCacheBuilder<V>
    public func setConcurrencyLevel(concurrencyLevel: Int64): HeapCacheBuilder<V>
    public func setMaxSize(maxSize: Int64): HeapCacheBuilder<V>
    public func setEvictionCallback(callback: (String, V) -> Unit): HeapCacheBuilder<V>
    public func setCheckDuration(checkDuration: Duration): HeapCacheBuilder<V>
    public open func build(): HeapCache<V>
}
```

**【口播】**（「一次性对象」这个概念要讲清楚，它和常见的 TTL 缓存不一样）

> 默认是**非一次性**的：每次 `get` 都会把过期时间**重新计时**（滑动窗口）。
> `once: true` 的对象则相反：**取用不续期**，到点就走，适合做「绝对过期」的会话、验证码。
> `prolong` 可以在运行中改寿命和一次性标志；`evictionCallback` 让你在对象失效时做收尾（比如关掉文件句柄）。

### 弱引用 `WeakHeapCache`

```cangjie
public class WeakHeapCache<T> where T <: Object {
    public init()
    public func set(key: String, value: T): ?T
    public func getOrCompute(key: String, fn: () -> ?T): ?T
    public func get(key: String): ?T
    public func getOrDefault(key: String, default: T): T
    public func getOrStore(key: String, value: T): T
    public func remove(key: String): ?T
    public func removeIf(predicate: (String, T) -> Bool): Unit
    public prop size: Int64
    public func clear(): Unit
}
```

**【口播】** 内部键和值都被弱引用包装，**定时遍历清除已经被 GC 掉的弱引用**——适合缓存「可被重建的大对象」，不会因为缓存导致内存泄漏。

### 在 `fdemo` 里看它

```cangjie
// UserSessionCache：登录状态存 1 小时
private static let context = JWTSecurityContext<String>(JWTHeapCacheStore(Duration.hour), ...)
```

**【口播】** `JWTHeapCacheStore` 就是 `HeapCacheStore<String, JWTPrincipal<String>>`，底层正是 `f_cache` 的堆缓存——所以第十三章那个「登录状态存 1 小时」的能力，根源在这里。

## 17.4 `f_pool`：对象池

### 池的存储模式

```cangjie
public enum Mode {
  | Fifo      // 先进先出，默认
  | Lifo      // 后进先出
  | WeakFifo  // 弱引用先进先出（DEFERRED 策略）
  | WeakLifo  // 弱引用后进先出
}
```

### `Pool<V>`：通用对象池

```cangjie
public interface ObjectManager<V> {
    func create(): V                 // 创建对象
    func check(value: V): Bool       // 检查对象
    func destroy(value: V): Unit     // 销毁对象
    func clear(value: V): Unit {}    // 清除对象
}

public struct Pool<V> <: Resource {
    public init(
        mode!: Mode = Mode.Fifo,
        initSize!: Int64,
        minSize!: Int64 = 0,
        maxSize!: Int64 = 10,
        idleTimeout!: Duration = Duration.hour,      // 空闲时间
        checkOnCreation!: Bool = false,              // 创建时检查
        checkOnBorrowing!: Bool = true,              // 借出时检查
        checkOnReturning!: Bool = true,              // 归还时检查
        clearOnReturning!: Bool = false,             // 归还时清除
        checkInterval!: Duration = Duration.minute,  // 检查周期
        creator!: () -> V,
        checker!: (V) -> Bool,
        destroier!: (V) -> Unit,
        clear!: (V) -> Unit = {_ =>}
    )
    public static func builder(): PoolBuilder<V>
    public func get(timeout!: Duration = Duration.Max): ?V   // timeout <= 0 时不等待立即返回
    public func giveBack(value: V): Unit
}
```

**【口播】**

> 看到 `initSize / minSize / maxSize / idleTimeout / checkOnCreation / checkOnBorrowing / checkOnReturning / checkInterval` 这八个参数是不是很眼熟？
> **对，它们就是第十二章 ORM 那批 `orm_databasePool*` 配置项**。ORM 的 `DatabasePool` 就是 `f_pool` 的一个应用——所以你调 ORM 连接池和直接调 `f_pool`，手感完全一样。
>
> 另外 `Pool` 实现了 `Resource`，用完 `close()`。

### `KeyPool<K, V>`：每个键一个池

```cangjie
public class KeyPool<K, V> <: Resource where K <: Hashable & Equatable<K> {
    public func get(key: K, timeout!: Duration = Duration.Max): ?V
    public func giveBack(key: K, object: V): Unit
}
```

**【口播】** 只有池对象需要销毁，**键不需要销毁**。典型场景：多数据源 / 多租户，每个库一个连接池；`totalSize` 与 `maxSize` 共同约束总量。

### 数组池

```cangjie
public ArrayPool(initSize!, minSize!, maxSize!, elementLife!, checkInterval!,
                 clearOnReturning!, arraySize!: Int64 = 128, creator!: () -> T)
public ArrayListPool(...)   // 参数同上
```

**【口播】** 高频临时缓冲区的老问题：每次 new 一个 128 长度的数组，GC 压力全在这儿。数组池直接复用——这是 `f_base` 里 `StringGenerator` 那类组件敢放开手脚用的底气。

## 17.5 `f_collection`：补标准库的位

**【口播】** 这节不用逐条念，挑四个最能解决痛点的讲。

### `BitSet`

```cangjie
public init()                      // 64 位
public init(capacity: Int64)       // 64 * capacity 位
public init(set: BitSet)           // 拷贝
public prop size: Int64
public func contains<T>(value: T): Bool where T <: Hashable   // 用哈希判断存在
public func set<T>(value: T): Bool where T <: Hashable
public func remove<T>(value: T): Bool where T <: Hashable
public operator func [](index: Int64): Bool                    // 读写指定位
public operator func |(index: Int64): Bool                     // 位或
public operator func &(index: Int64): Bool                     // 位与
public operator func ^(index: Int64): Bool                     // 位异或
```

**【口播】** 布隆过滤器的底座（`f_bloom` 就依赖它）、权限位、标记位、去重集合——**一个 Int64 数组存 64N 个开关**。

### `Dict<K, V>` 家族：KEY 不要求 `Hashable`

**【口播】**（这是它最独特的地方）

> 标准库的 `HashMap` 要求 `K <: Hashable & Equatable<K>`，`TreeMap` 要求 `K <: Comparable<K>`。
> 但现实中大量 KEY 类型**两个都不实现**——比如第三方库的类型、接口类型。
> `Dict` 家族的解法是：**把 `hasher` 和 `equals` 作为构造函数参数传进去**。

```cangjie
public interface Dict<K, V> <: Collection<(K, V)> {
    func get(key: K): Option<V>
    func contains(key: K): Bool
    func add(key: K, value: V): Option<V>
    func addIfAbsent(key: K, value: V): ?V
    func replace(key: K, value: V): ?V
    func remove(key: K): Option<V>
    func removeIf(predicate: (K, V) -> Bool): Unit
    operator func [](key: K): V
    operator func [](key: K, value!: V): Unit
    func keys(): Collection<K>
    func values(): Collection<V>
    prop size: Int64
    ...
}

public class HashDict<K, V> <: Dict<K, V> {
    public init(hasher: (K) -> Int64, equals: (K, K) -> Bool)
    public init(elements: Array<(K, V)>, hasher: (K) -> Int64, equals: (K, K) -> Bool)
    public init(size: Int64, hasher: (K) -> Int64, equals: (K, K) -> Bool)
}

public class LinkedHashDict<K, V> <: Dict<K, V> { ... }   // 按最近访问顺序遍历
public class TreeDict<K, V>       <: Dict<K, V> { public TreeDict(private let cmp: (K, K) -> Ordering) }
```

### 保持插入/访问顺序的集合

```cangjie
public class LinkedHashMap<K, V> <: Map<K, V> where K <: Hashable & Equatable<K>   // 按最近访问顺序遍历
public class LinkedHashSet<T>    <: Set<T>     where T <: Hashable & Equatable<T>   // 按最近访问顺序遍历
```

**【口播】** LRU 缓存只差一层封装——`LinkedHashMap` 已经按访问顺序排好了。

### `PriorityQueue` 与集合运算视图

```cangjie
public class PriorityQueue<T> <: Queue<T> & Iterable<T> & Collection<T> & Growable {
    public PriorityQueue(comparator: (T, T) -> Ordering, capacity!: Int64, overSizePolicy!: OverSizePolicy<...>)
    public static func create<T>(capacity!, overSizePolicy!): PriorityQueue<T> where T <: Comparable<T>
    public static func createReverse<T>(...)                       // 反序
    public func add(x: T): Unit
    public func peek(): Option<T>
    public func remove(): Option<T>
    public func removeIf(predicate: (T) -> Bool): Unit
    public func toArray(): Array<T>
}

// 所有 Set 实现都扩展了 SetOp<T>：返回**只读视图**，不复制数据
public interface SetOp<T> {
    func intersection<C>(collection: C): Set<T> where C <: Collection<T>   // 交集
    func union<C>(collection: C): Set<T>                                    // 并集
    func difference<C>(collection: C): Set<T>                               // 差集
}
```

**【口播】** `PriorityQueue` 容量满时**自动扩容**，也可以给 `OverSizePolicy` 做拒绝策略；`SetOp` 的 `IntersectionSetView` / `UnionSetView` / `DifferenceSetView` 都是**只读视图**——做集合运算不产生拷贝。

## 17.6 `f_time`：把时间操作变成 DSL

**【口播】**

> 标准库的 `DateTime` / `Duration` 能用，但「下一个整分钟」「今天零点」「5 秒后」这种需求每次都要手写。
> `f_time` 把这类操作变成**可读的链式 DSL**。

### `TimeUnit`：10 个粒度

```cangjie
public enum TimeUnit <: ToString & Parsable<TimeUnit> {
    | NANOSECOND | MICROSECOND | MILLISECOND | SECOND | MINUTE
    | HOUR | DAY | WEEK | MONTH | YEAR
}
public type TU = TimeUnit        // 简写别名

TimeUnit.parse("minute")         // MINUTE（大小写不敏感）；失败抛 IllegalArgumentException
TimeUnit.tryParse("Foo")         // None<TimeUnit>
```

| 成员 | 作用 |
| --- | --- |
| `trim(t)` | 截断到当前单位的整点：`WEEK` 对齐到周一，`MONTH` 对齐到 1 号，`YEAR` 对齐到 1 月 1 日 |
| `next(datetime!, duration!, toTrim!)` | 未来第 `duration` 个整点（可为负） |
| `prev(...)` | 过去第 `duration` 个整点 |
| `since(datetime!, duration!)` | 距离未来整点还有多久，返回 `Duration` |
| `ago(n)` / `later(n)` | 以**当前时间**为基准回退 / 推进 |
| `before(t, n)` / `after(t, n)` | 以 `t` 为基准回退 / 推进 |
| `duration(n)` | `n` 个单位 → `Duration`；**`WEEK`/`MONTH`/`YEAR` 不定长，返回 `None`** |
| `current` | 当前时刻 `trim` 后的值 |

```cangjie
TimeUnit.MINUTE.next(datetime: '2023-10-11 12:31:32.568900')  // → 2023-10-11 12:32:00.000000
TimeUnit.MINUTE.prev(datetime: '2023-10-11 12:31:32.568900')  // → 2023-10-11 12:31:00.000000
TimeUnit.MINUTE.since(datetime: '2023-10-11 12:31:32.568900') // ≈ Duration.minute
```

### `Int64` 的时间 DSL

```cangjie
public interface DurationCategory {
    prop nanoseconds / nanosecond / microseconds / microsecond / milliseconds / millisecond
    prop seconds / second / minutes / minute / hours / hour / days / day / weeks / week
}
extend Int64 <: DurationCategory
```

```cangjie
let d1   = 5.seconds.later       // 5 秒后的 DateTime
let d2   = 2.minutes.ago         // 2 分钟前的 DateTime
let dur  = 1.day.duration        // Some(Duration.day)
let bad  = 1.month.duration      // None<Duration>  ← MONTH 不定长
```

**【口播】** 单复数同义（`second == seconds`），读起来就是自然语言。

### `DateTime` / `Duration` / 其它扩展

```cangjie
// DateTime
DateTime.today          // 今日 00:00:00
DateTime.yesterday      // 昨日 00:00:00
DateTime.tomorrow       // 明日 00:00:00
DateTime.currentDuration
today.isLeapYear        // 是否闰年
today.isLastMonthDay    // 是否当月最后一天
now.toUnixEpochSeconds() / .toUnixEpochMillis() / .toUnixEpochMicros() / .toUnixEpochNanos()
now.setYear(2026) / .setMonth(Month.January) / .setDay(1) / .setHour(0) / .setMinute(0) ...
now.addMilliseconds(500) / .addMicroseconds(500)

// Duration
Duration.minute.ago                // DateTime.now() - 1min
Duration.hour.later                // DateTime.now() + 1h
Duration.day.before(DateTime.tomorrow)
Duration.day.after(DateTime.today)

// DayOfWeek / Month 支持相减
DayOfWeek.Monday - DayOfWeek.Sunday   // 1
Month.January   - Month.December      // -11

// TimeZone
TimeZone.Z                            // UTC 时区常量
```

## 17.7 `f_regex`：正则扩展与正则缓存

### 常用正则常量

```cangjie
public interface ExtendRegex {
    static prop INTEGER: Regex          // 整数
    static prop DECIMAL: Regex          // 小数
    static prop REAL_NUMBER: Regex      // 实数
    static prop EMAIL: Regex            // 电邮
    static prop DURATION: Regex         // Duration 字符串
    static prop IDENTIFIER: Regex       // 标识符
    static prop BASE64: Regex           // BASE64
    static func wildcard(wildcard: String): Regex          // 通配符串 → 正则
    func doReplace(input: String, replacement!: String, index!: Int64): String
    func doReplaceAll(input: String, replacement!: String, index!: Int64): String
    func doReplaceAll(input: String, replacement!: (MatchData) -> ?String, index!: Int64): String
}
```

**【口播】** `doReplace` / `doReplaceAll` 相比标准库多了**起始下标**和**「按匹配内容动态决定替换值」**两个能力（回调返回 `None` 就不替换）——做模板渲染、脱敏很顺手。

### 字符串直接变正则（带缓存）

```cangjie
public interface RegexFromString {
    func regex(flags!: Array<RegexFlag>, solid!: Bool): Regex
}
```

```cangjie
let r = '^/api/.*'.regex(solid: false)
```

**【口播】**（这一条很关键，值得强调）

> `solid: true` → 正则在**整个进程生命周期**内存在；
> `solid: false` → 用 `f_cache.HeapCache` 缓存，**最多 10000 个、寿命一天**。
>
> **编译正则是有成本的**。热路径上反复 `str.regex()` 而不用缓存，是很多服务的隐形 CPU 杀手。
> 顺带闭环：`f_util.PathPattern` 在编译路径时会先做几步正则预处理（把 `{*name}` 归一化、把连续 `//` 合并成 `/`），这些正则就是用 `regex(solid: true)` 建的——进程内编译一次、复用一生。

## 17.8 `f_rx`：反应式编程

**【口播】**

> `f_rx` 是一套 Observable / Observer 实现。它的价值不在「又一套 Rx」，而在于：**把「数据怎么产出」和「数据怎么处理」的线程模型、背压策略、错误恢复都显式化了**。

### 最小可用

```cangjie
let observable = Observable<Int64>
    .iterable([1, 2, 3])
    .subscribe('test', FuncObserver<Int64>().setNext{v => println(v)})
    .withCurrent()
    .defer()

observable.pause()   // 暂停产生新数据
```

### 六种创建方式

| 方式 | 入参 |
| --- | --- |
| `iterable` | `Iterable<T>` / `()->Iterable<T>` / `Future<Iterable<T>>` / `()->Future<Iterable<T>>` |
| `emitter` | `(Emitter<T>) -> Unit`；`Emitter` 有 `onNext(T)` / `onComplete()` / `onError(Exception)` |
| `single` | `T` / `()->T` / `Future<T>` / `()->Future<T>` |
| `maybe` | `?T` / `()->?T` / `Future<?T>` / `()->Future<?T>` |
| `empty` | 创建空的被观察者 |
| `concat` | `Iterable<Iterable<T>>` 及其 Future/闭包变体，展开成 `Iterator<T>` |

### 每条数据的处理策略

| 策略 | 线程模型 |
| --- | --- |
| `withAlwaysNew()` | 每条数据都开**新线程** |
| `withCurrent()` | 始终用**当前线程** |
| `withSingle(...)` | 固定**一个线程**处理所有数据（支持背压） |
| `withFixed(...)` | 固定**若干线程**处理所有数据（支持背压） |

### 启动与停止

```cangjie
.delay(Duration)     // 延迟启动
.defer()             // 0 延迟，新线程启动
.immediately()       // 当前线程立即启动

dispose(completion!: Bool = false)   // 停止；true 则发送 onComplete
dispose(name)                        // 注销指定名称的观察者
dispose<O>()                         // 注销指定类型的全部观察者
disposeAll()                         // 注销全部
pause(completion!: Bool = false)     // 暂停产生新数据
```

> 细节：内部 `disposed_` 是 `AtomicBool`，每次取下一批数据前检查；**没有观察者时会自动暂停产出**，直到注册新观察者并重新启动。

### 背压策略 `BackPressure`

**【口播】** 只有 `withSingle` / `withFixed` 支持背压——因为只有固定线程池才有「队列满了」这件事。

| 策略 | 队列满时 |
| --- | --- |
| `Discarding` | 丢弃新数据 |
| `ToDropOldest` | 丢弃队头 |
| `AlwaysBlocking` | 一直阻塞 |
| `Throwing` | 立即抛异常 |
| `Current` | 立即用当前线程处理 |
| `NewThread` | 立即开新线程处理 |
| `Action((()->Unit) -> Unit)` | 用你给的函数处理 |
| `AfterBlockingOrCurrent(Duration, BackPressure<T>)` | 阻塞指定时长后仍满 → 执行指定策略（默认 `Discarding`） |

### 观察者与错误恢复

```cangjie
// FuncObserver：三个回调都能单独设
FuncObserver<T>().setNext{v => ...}.setError{e => ...}.setComplete{() => ...}
// setNext 还可以接收 Single<T>（= SingleIterator<T> 别名），闭包内可用 Iterator 的各类函数

// 错误恢复器（四个重载）
public func setErrorResumer(resumer: (Exception) -> ?Iterable<T>): This
public func setErrorResumer(resumeIfNone: Bool, resumer: (Exception) -> ?T): This
public func setErrorResumer(resumer: (Exception) -> Unit): This
public func setErrorResumer(resumeIfFalse: Bool, resumer: (Exception) -> Bool): This
public func setErrorResumer(resumeIfNone: Bool, resumer: (Exception) -> ?(Emitter<T>) -> Unit): This

// 重放
Observable.replaySize(capacity)   // 启动后再注册的观察者会异步重放最多 capacity 条缓存数据
```

### 多观察者

每个创建函数都接受命名参数 `asyncCombined!: Bool`——决定多个观察者**各自开线程**还是**共用一个线程**。

## 17.9 `f_random`：随机数

**【镜头】** `f_random/README.md` + `fdemo/user/src/util/UserSessionCache.cj`（那行 `UUID.random().toHexString()`）

### 它补了标准库什么

**【口播】**

> 仓颉标准库有 `std.random.Random`，stdx 有 `stdx.crypto.crypto.SecureRandom`。但它们缺三样常用的东西：
> 1. **区间随机数**——`nextInt64(1, 100, closed: true)` 这种；
> 2. **随机数流**——一次性要一万个随机数时，不想写循环；
> 3. **随机字符串**——做 token / 验证码 / 盐值时每次都手搓。
>
> `f_random` 就干这三件事，外加**蓄水池抽样**和**线程本地随机源**。
> 它不自己实现随机算法，而是用 `extend Random <: ExtendRandom<Random>` 和 `extend SecureRandom <: ExtendRandom<SecureRandom>` 把能力**扩展到标准库类型上**——所以 API 是「加在原类上」的，不用换类型。

```toml
[dependencies]
  "fountain::f_random" = {path = "../f_random"}
```

```cangjie
import fountain::f_random.*
// 或聚合包：import fountain::fountain.random.*
```

> 注意：扩展方法（如 `nextInt64(min, max, closed:)`）**只有导入本模块后才可见**。

### 区间随机数：`ExtendRandom`

```cangjie
public interface ExtendRandom<R> where R <: ExtendRandom<R> {
    func nextFloat64(min: Float64, max: Float64, closed!: Bool): Float64
    func nextFloat32(min: Float32, max: Float32, closed!: Bool): Float32
    func nextInt64  (min: Int64,  max: Int64,  closed!: Bool): Int64
    func nextUInt64 (min: UInt64, max: UInt64, closed!: Bool): UInt64
    func nextInt32  (min: Int32,  max: Int32,  closed!: Bool): Int32
    func nextUInt32 (min: UInt32, max: UInt32, closed!: Bool): UInt32
}
```

`closed` 在实现中默认 `false`，所以 `rand.nextInt64(1, 100)` 也是合法的。

`BaseRandom` 则把标准库自带的方法统一到一个接口上（大部分是转发，本模块不重复实现）：

```cangjie
nextBool() / nextInt8/16/32/64() / nextUInt8/16/32/64()
nextInt64(max) / nextUInt32(max) ...          // [0, max)
nextFloat16/32/64()                            // [0.0, 1.0)
nextGaussianFloat16/32/64(mean!, sigma!)       // 高斯分布
nextBytes(length) / nextUInt8s(array)          // 字节数组 / 原地填充
```

**【口播】** `Random` 和 `SecureRandom` 用法**完全相同**：需要密码学强度时把 `Random()` 换成 `SecureRandom()` 或 `ThreadLocalRandom.current` 即可，业务代码一行不用改。

### 随机数流（无限迭代器）

```cangjie
let stream = rand.randomInt64(0, 10)          // Iterator<Int64>，(0,10) 或 [0,10]
let next   = stream.next() ?? 0

// 也有 UInt64 / Int32 / UInt32 版本，以及高斯分布流：
rand.randomGaussianFloat64Stream(mean: 0.0, sigma: 1.0)
rand.randomGaussianFloat32Stream()
rand.randomGaussianFloat16Stream()
```

**【口播】** 这些迭代器的 `next()` **永远返回 `Some`**，是无限流——要多少自己控制（`take(n)` 或循环 break）。具体迭代器类是包内可见的，用工厂方法拿就行。

### 随机字符串：`RandomString`

```cangjie
let rs = RandomString()
println(rs.randomLettersNumbers(16))   // 16 位字母+数字
println(rs.randomLowerHex(8))          // 8 位小写 16 进制
```

| 方法 | 字符集 |
| --- | --- |
| `randomAscii` | `U+0000`–`U+007F`（**含控制字符**，慎用） |
| `randomLowerLetters` | `a`–`z` |
| `randomUpperLetters` | `A`–`Z` |
| `randomAllLetters` | `A`–`Z` + `a`–`z` |
| `randomNumbers` | `0`–`9` |
| `randomLowerHex` | `0`–`9` + `a`–`f` |
| `randomUpperHex` | `0`–`9` + `A`–`F` |
| `randomLowerLettersNumbers` | `a`–`z` + `0`–`9` |
| `randomUpperLettersNumbers` | `A`–`Z` + `0`–`9` |
| `randomLettersNumbers` | `A`–`Z` + `a`–`z` + `0`–`9` |
| `randomPrintableAsciis` | 字母数字 + `` `~!@#$%^&*()-_=+[{]}\|'";:/?.>,< `` |
| `randomAllChars` | 全部 Unicode scalar（自动避开代理区 `0xD800`–`0xDFFF`） |
| `random(count, source)` | 调用方给定的 `String` 或 `Array<Rune>` |

每个方法都有两个重载：`(count)` 生成固定长度，`(min, max)` 先随机出长度再生成。

### `ThreadLocalRandom`

```cangjie
public class ThreadLocalRandom {
    private init()
    @Frozen
    public static prop current: SecureRandom
}
```

**【口播】**

> 每个线程首次访问 `current` 时创建一个 `SecureRandom`（默认 `priv`），之后一直复用——**不用自己处理加锁和复用**。
> 而且 `RandomString()` 的无参构造器默认就把它作为随机源，所以**默认的 `RandomString` 实例天然线程安全**。
> 高并发下生成 token、验证码、盐值，用 `RandomString()` 默认构造就对了。

### 蓄水池抽样

```cangjie
public func randomReservoir<T>(count: Int64, source: Iterable<T>, priv!: Bool = false): ArrayList<T>

let sample = randomReservoir<Int64>(3, [1, 2, 3, 4, 5, 6, 7, 8])
```

**【口播】** 只需**遍历一次**数据源就能随机取 `count` 个元素，**不需要事先知道总数**——适合流式数据或超大集合抽样（比如从日志流里随机采样做监控）。`priv` 是内部 `SecureRandom` 的初始化参数，每次调用新建一个 `SecureRandom`。

### 它在 fountain 里的三个位置

**【口播】**（把工具库和前面讲过的内容串起来）

1. **`fboot randhex`** —— 实现就是 `RandomString().randomLowerHex(n)`（第三章讲过，给 SM4 生成密钥/IV，机制见第四章）；
2. **JWT 会话密钥** —— `fdemo` 的 `UserSessionCache` 里 `UUID.random().toHexString()` 给每个登录生成独立 HMAC 密钥；
3. **业务侧** —— 验证码、邀请码、临时 token、幂等号、抽样的盐值。

**【演示】**

```bash
fboot randhex 32        # ← 就是 f_random 的 randomLowerHex(32)
```

### 注意事项与已知行为（照着 README 念，别踩）

> 这几条是 `f_random` 当前实现与直觉不一致的地方，README 按代码实际行为记录。讲出来比让观众自己撞墙好。

1. **浮点版的 `closed` 不是「包含上界」**：实现是 `nextFloat64() * (max - min + (closed ? 1 : 0)) + min`。`closed: true` 时落在 `[min, max + 1.0)`，**有可能超过 `max`**；`closed: false` 落在 `[min, max)`。需要严格不超过上界请自己裁剪。
2. **整数版先转浮点再取整**：`nextInt64/nextUInt64` 走 `Float64`，`nextInt32/nextUInt32` 走 `Float32`，最后 `floor` 取整。区间接近 `Int64.Max` 时会有精度损失甚至溢出。
3. **区间参数不校验**：不检查 `min <= max`，传反了不报错，只会得到反转区间的结果。
4. **`RandomString` 的三个 `(min, max)` 重载调错了方法**：
   - `randomAllLetters(min, max)` 实际产出**只有小写字母**；
   - `randomUpperLettersNumbers(min, max)` 实际产出**小写字母+数字**；
   - `randomLettersNumbers(min, max)` 实际产出**小写字母+数字**。

   需要对应字符集时请自己先算长度再调 `(count)` 重载：

   ```cangjie
   let rs = RandomString()
   let len = ThreadLocalRandom.current.nextInt64(8, 16, closed: true)
   let s = rs.randomLettersNumbers(len)
   ```
5. **长度区间不统一**：只有 `randomAscii(min, max)` 和 `random(min, max, source)` 用了 `closed: true`（长度落在 `[min, max]`），其余 `(min, max)` 重载的长度是 `[min, max)`。
6. **`randomReservoir` 的边界**：`count <= 0` 且数据源非空时会抛参数非法异常；返回值大小是 `min(count, 元素个数)`，不总是等于 `count`；替换下标取自 `[0, i)` 而非经典算法的 `[0, i]`，**抽样结果并非严格均匀**——对均匀性有硬要求的场景请自己实现。

## 17.10 现场演示

**【镜头】** 建议临时建一个小模块，把八个模块各跑一行

```bash
cd /tmp/fountain_live/hello_app
fboot module infra
cat > infra/src/Infra.cj <<'EOF'
package infra
...
EOF
fboot build && fboot run --dylibPattern='infra'
```

```cangjie
import fountain::f_base.*
import fountain::f_cache.*
import fountain::f_pool.*
import fountain::f_collection.*
import fountain::f_time.*
import fountain::f_regex.*
import fountain::f_rx.*

// ① f_base：一个 import 打底 + 优雅退出的清理登记 + 各类容器的空实现
EmptyArray<Int64>.instance()
ExitCallbacks.atExit(200){ println('byebye from my module') }

// ② f_cache：1 小时寿命、最多 10000 个的堆缓存
let cache = HeapCache<String>(maxLife: Duration.hour, maxSize: 10000)
cache.getOrCompute('k'){ expensive() }

// ③ f_pool：最多 8 个连接的对象池
let pool = Pool<Conn>(mode: Mode.Fifo, initSize: 2, maxSize: 8,
                      idleTimeout: Duration.minute,
                      creator: {=> connect()},
                      checker: {c => c.isValid()},
                      destroier: {c => c.close()})
let c = pool.get(timeout: Duration.second * 5)
// ... 用完
pool.giveBack(c.getOrThrow())

// ④ f_collection：KEY 不需要 Hashable 的字典
let dict = HashDict<Conn, String>(hasher: {c => c.id}, equals: {a, b => a.id == b.id})

// ⑤ f_time：时间 DSL
let deadline = 30.minutes.later
let startOfDay = DateTime.today
let nextHour = TimeUnit.HOUR.next()

// ⑥ f_regex：带缓存的正则
let r = '^/api/.*'.regex(solid: false)

// ⑦ f_rx：反应式流
Observable<Int64>.iterable([1, 2, 3])
    .subscribe('demo', FuncObserver<Int64>().setNext{v => println(v)})
    .withCurrent()
    .defer()

// ⑧ f_random：带线程本地随机源的随机字符串
RandomString().randomLowerHex(16)
```

**【口播】**

> 这八个模块没有一个需要配置文件、没有一个需要启动器、没有一个依赖 IOC。
> **它们就是八个可以随手拿走的工具库**——这也是 fountain 的设计哲学：**框架给你便利，但不劫持你的代码。**

---

# 第十八章 收尾：常见坑与 Q&A

## 18.1 二十二个高频坑

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
| 11 | `populate` 之后目标对象字段是空的 | 目标类没加 `@DataAssist[fields]`；或默认 `SILENCE` 把「字段不存在 / 类型不匹配 / 无法转换」静默跳过了（见第八章） |
| 12 | 随机字符串里只有小写字母 | `randomLettersNumbers(min,max)` 等三个 `(min,max)` 重载的实现与命名不符；自己先算长度再调 `(count)` 重载（见第十七章 17.9） |
| 13 | 自定义格式报 `<x> is an illegal MediaType string` | 自定义 `MediaType` 漏了 `@Bean`，或它所在的动态库没被 `--dylibPattern` 匹配到（见第十一章） |
| 14 | 上传的文件在磁盘上堆积 | `MultipartFile` 是 `Resource`，用完必须 `close()`——`close()` 才会删掉临时文件 |
| 15 | 改了配置却不生效 | 有编译期内嵌值被运行期覆盖了（或反过来）；或用了 `fountain_` 前缀却写成了原名。按第四章的四级优先级逐层排查 |
| 16 | `Config.set` 之后相关模块没刷新 | 已知问题：`refresher` 的前缀匹配恒不成立，`set` **不会**触发任何刷新回调（见第四章 4.8） |
| 17 | `TreeTransformer.transform` 抛 `IllegalArgumentException` | 源数据里有重复 id（`ignoreDuplicate` 默认 `false`），或 `transferFn` 返回了 `None`（见第九章） |
| 18 | 找不到 `Responsibility` / `ResponsibilityChain` 类型 | 源码拼写是 **`Responsibility`**（少一个 n），文件名也是 `ResponsibilityChain.cj` |
| 19 | 缓存对象「取了就续期」，永远不过期 | `HeapCache` 默认是**非一次性**对象（滑动窗口）。要绝对过期请 `set(..., once: true)` 或用 `prolong(key, deathTime)` |
| 20 | 热路径上反复 `str.regex()` 导致 CPU 高 | 正则编译没走缓存。用 `regex(solid: true)`（进程内常驻）或 `solid: false`（`HeapCache`，1 万条 / 1 天） |
| 21 | 日志一条都不输出 | `f_log` **默认静默**：不配 appender 就没有输出通道。至少 `logger_appender_console=<你起的名字>`（见第十五章 15.2） |
| 22 | 想只给某个包开 DEBUG，配不出来 | 级别挂在 **appender** 上（`logger_appender_<你起的名字>_level`），不是挂在 logger 名字上，没有名字树；来源用 pattern 里的 `%name` 区分（见第十五章 15.2） |

## 18.2 预设 Q&A

**Q：能不用动态链接库吗？**
A：IOC/AOP/ORM 这些能力本身不依赖动态链接库，但 `fboot run` 的「扫描加载」机制依赖它。用 `App(..., dynamic: false)` 可以不扫描，此时只有内置命令和静态链接进来的子命令可用，业务 bean 需要你自己保证已被加载。

**Q：性能如何？**
A：`fboot build` 默认带 `-O2 --lto=full`；ORM 有结果缓存（可按驱动关）、连接池可选 fountain 池 / 标准库池 / 第三方池；`boot.sh` 里还有 `perfRecord` / `perfReport`（`cjprof`）和 `loop` / `ab` 可以直接做基线测量。**不要凭感觉谈性能，先跑 `./boot.sh ab 16 10000`。**

**Q：能只用一个模块吗？**
A：可以。`f_base`、`f_util`、`f_collection`、`f_crypto`、`f_random` 等都是独立可用的工具库，在 `cjpm.toml` 里只加你需要的那一个即可。比如只想要随机字符串和区间随机数，就只引 `f_random`（它只依赖 `f_base`）。

**Q：`f_data` 的复制能替代手写 DTO 转换吗？**
A：绝大多数场景可以。`DataObject<Target>.populate(src)` 按**同名字段**复制，`DateTime`/集合/Map 都支持，还能用 `DataConversionFlag` 控制严格程度。只有字段名不一致或需要计算逻辑时，才需要手写几行。

**Q：没有配置文件，本地开发怎么管理几十个配置项？**
A：写进启动脚本。`fdemo/boot.sh` 的 `exports()` 函数就是标准答案——所有 `export` 集中在一个地方，`fboot run` 之前 source 一下。容器化时这些 `export` 换成 ConfigMap / Secret 即可，`f_config` 的读取逻辑一行不用改。

**Q：`--key=value` 是 `fboot` 的功能吗？我自己写的程序能用吗？**
A：能用，而且不需要做任何事。**这不是 `fboot` 的开关，而是 `f_config` 模块的能力**：任何链接了 `f_config` 的仓颉进程，在 `static init` 时都会读 `env.getCommandLine()` 并装载 `--key=value`。`fboot` 只是恰好也用了 `f_config` 而已——`fboot build`、`fboot run`、你自己 `import fountain::f_config.*` 的 `main`、甚至只是间接依赖（比如引了 `f_orm`）都一视同仁。

**Q：`fboot build --k=v` 和 `fboot run --k=v` 有什么区别？**
A：**在配置的解析方式上没有任何区别**——都是 `f_config` 读当前进程的 argv。区别在**这个进程要拿配置干什么**：`fboot build` 是把它转成 `cjpm build` 子进程的环境变量，供**编译期宏**（`@EmbedSensitive`、`ORMConfig`）读取并嵌入产物；`fboot run` 是让**应用运行期**直接读到。

**Q：为什么我一条日志都看不到？**
A：先看有没有配 appender——fountain 的日志**默认静默**。至少要 `logger_appender_console=随便一个名字`，然后再用 `logger_appender_<这个名字>_level` 配级别（注意：名字是你自己起的，不是 `console`）。第二看级别：控制台默认 `INFO`，`log.debug{...}` 不会出现。

**Q：日志丢了怎么办？**
A：三种可能。① 缓冲区池被占满且 5ms 内没借到 → 控制台会打印 `AsyncLogger.SyncQueueOutputStream.EmptyPool`，加大 `loggerAsyncBufsize`；② 你配了 `loggerAsyncTimeout` + `discard`，队列满时被主动丢弃；③ 进程被 `kill -9` —— `f_log` 在 `atExit` 里会排空队列再关流，但 `-9` 抓不到。正常 `Ctrl-C` 不会丢（`atExit` 与信号处理见第十七章 17.2）。

**Q：日志文件能按天切割并压缩吗？**
A：能，两个配置项：`logger_appender_<Name>_rotateDuration=DAY`、`logger_appender_<Name>_compressFormat=GZip`（`Deflate` 也行）。切割出来的文件是 `<路径>.<上一周期时间戳>.gz`。注意两点：`rotateDuration` 别配亚秒级（会疯狂 rename）；压缩失败时原文件也会被删掉，审计类日志建议先不压缩。

**Q：运行期能改日志级别吗？**
A：能，`LoggerFactory.refresh()` 会按当前配置重建 facade 并 CAS 换过去。但 `Config.set` **不会**自动触发它（`f_config` 的 refresher 前缀匹配有已知问题，见第四章 4.8），所以现状是「`Config.set` + 手动 `LoggerFactory.refresh()`」两步。

**Q：把密码编进产物安全吗？**
A：它解决的是「不让密码出现在运行环境里」，**不是**「密码不可破解」——SM4 密钥本身也在产物里。真要保护密钥请用 KMS。另外记得运行期同名环境变量可以覆盖内嵌值。

**Q：想支持私有二进制协议 / 加密报文，要改 MVC 吗？**
A：不用。写一个 `MediaType` 子类实现 `fromData` / `toData`，加 `@Bean`，然后 controller 的 `consumes` / `produces` 里写你的格式名即可——`MediaTypes` 首次 `tryParse` 时会把 IOC 里所有 `MediaType` bean 自动注册进来（见第十一章）。

**Q：主键该用自增 ID 还是 UUID？**
A：`f_orm` 的 `INSERT_INTO` 直接返回自增主键；需要分布式生成就用 `UUID.unixTimeBased()`（v7，时间有序，索引局部性好于 v4）。`UUID` 实现了 `DataFields<UUID>`，可以**直接作为 PO 字段**参与 ORM 映射和 JSON 序列化，不用自己写转换器。

**Q：主键该用 `IdMaker` 还是 `UUID`？**
A：要**时间有序、索引局部性好** → `IdMaker`（需保证 `idMakerHostSerial` 全局唯一）或 `UUID.unixTimeBased()`；要**去中心、任何机器随时可生成** → `UUID.random()`。`UUID` 实现了 `DataFields<UUID>`，可以**直接作为 PO 字段**参与 ORM 映射和 JSON 序列化，不用自己写转换器。

**Q：本地缓存用 `f_cache` 还是自己写 `HashMap`？**
A：只要涉及**过期**就用 `f_cache`：`HeapCache` 自带寿命、最大容量、检查周期和失效回调；并且默认是**滑动续期**的，想要绝对过期就 `once: true`。缓存「可被重建的大对象」时用 `WeakHeapCache`（弱引用，被 GC 后自动清理），不会内存泄漏。

**Q：`f_rx` 和直接用 `spawn` + `Channel` 怎么选？**
A：要**背压、错误恢复、重放、多观察者**这些语义时用 `f_rx`（它把线程模型和队列满策略都显式化了）；只是简单地「扔个任务到后台」，`spawn` 就够了。

**Q：`Strategies` 和 IOC 的 `lookupList<T>()` 该怎么选？**
A：**要 bean 的完整生命周期（懒加载、条件装配、`@Value` 注入、销毁回调）→ 用 IOC**；只是想把「一段按 key 分派的逻辑」集中管理 → `Strategies` 更轻。两者不冲突，很多项目是混着用的。

**Q：随机数够安全吗？要用哪个？**
A：默认优先 `SecureRandom` / `ThreadLocalRandom.current`（`RandomString()` 的无参构造就是它）。只有对性能极度敏感、且不涉及安全语义的场景（比如模拟数据、抽样）才用 `Random`。另外记住 `f_random` 那几条已知行为——尤其是浮点 `closed` 的含义（见第十七章 17.9）。

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
| f_data | `@DataAssist[equal hash tostring props fields]` | 生成属性/Equals/Hash/ToString/复制能力 |
| f_data | `@CombinedValidator[...]` `@IsNotBlank[...]` `@StringSize[min max]` `@DoesMatchRegex[regex]` … | 数据校验（`& \| !` 可组合） |
| f_data | `@JsonStringSchema` `@JsonIntSchema` `@JsonArraySchema` `@JsonObjectSchema` … | 生成 JSON Schema |
| f_ticktock | `@Bean` + `CronTicktockTask` | 定时任务 |
| f_http | `@Bean` + 继承 `MediaType` | 自定义数据格式（须实现 `make` / `toString` / `==` / `hashCode` / `fromData` / `toData`） |

## 配置（`f_config`）

```bash
# 优先级：命令行参数 > 环境变量 > 编译期内嵌（fountain_ 前缀为等价回退）
# 命令行参数对「任何链接了 f_config 的仓颉进程」都生效（不限于 fboot）
--argName=argValue | --argName | -argName argVal | -argName
export sm4Key=$(fboot randhex 32)   # 16 字节；GCM 的 IV 用 fboot randhex 24
export sm4Iv=$(fboot randhex 32)
export sm4Operation=CBC             # CBC CFB CTR GCM OFB
export sm4Padding=PKCS7Padding      # NoPadding PKCS7Padding
```

```cangjie
Config.getString(key) / getValue<T>(key) / getData<T>(key)      // 单数：失败返回 None
Config.getValues<T>(key, delim:) / getDatas<T>(key, delim:)     // 复数：失败抛异常
Config.getStringArray(key, delim:) / getDuration(key) / getDateTime(key, format:)
Config.bufferSize(key, default:, debugging:)                    // 向上取到 2 的幂
Config.getAll(prefix) / getAll() / set<T>(tuples, ifAbsent:) / refresher(prefix, fn)
Config.getSM4() / Config.registerSensitive(key, value)
@EmbedSensitive(paySecretKey pushToken)          // 编译期把敏感值嵌入产物
@DateTimeConfConverter[myDateFormat]             // 时间格式本身也可配置
```

```bash
# 日志（f_log）：默认静默——不配 appender 就没有任何输出
export logger_appender_console=MyConsole          # 值 = 你起的 appender 名，逗号分隔可多个
export logger_appender_MyConsole_level=INFO        # OFF/ERROR/WARN/INFO/DEBUG/TRACE/ALL（无 FATAL）
export logger_appender_MyConsole_pattern='[%level-%name]%d{yyyy/MM/dd,HH:mm:ss.SSS}|%tid;%m'
export logger_appender_file=MyFile
export logger_appender_MyFile_level=INFO
export logger_appender_MyFile_path=./log/app.log   # 默认 ${工作目录}/logs/${命令名}.log
export logger_appender_MyFile_rotateDuration=DAY   # NANOSECOND..YEAR，别用亚秒级
export logger_appender_MyFile_rotateSize=100M      # 可选，支持 100k/100M/1G
export logger_appender_MyFile_compressFormat=GZip  # 可选：Deflate / GZip
# export loggerAsyncBufsize=1024                   # 异步队列容量 & 缓冲区池大小
# export loggerAsyncTimeout=10ms                   # 队列满时的等待（默认 Duration.Max＝死等）
# export loggerAsyncTimeoutPolicy=discard          # discard / abort / alwaysWaiting
# export logger_asyncWaitTimeout=5ms               # 借不到缓冲区→丢弃本条并打印 EmptyPool
```

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

// f_log：日志（默认静默；级别/格式挂在 appender 上，不挂在 logger 名字上）
LoggerFactory.getLogger<T>() / getLogger('任意名字')       // 名字 = 完整限定名 / 字面量
log.info{'...${name}'} / log.debug{'...'}                 // lambda：级别不够不求值
log.info('user {} login', [name, ip])                     // 模板占位（TextTemplate）
log.info('user {name} is {age}', data)                    // @DataAssist 对象 → 具名占位
log.error(e){'...'} / log.error('...', e)                 // 异常栈一起写出
log.debugEnabled / infoEnabled / warnEnabled / errorEnabled / fatalEnabled / logLevelEnabled(level)
log.withAttrs([Attr('traceId', LogValue('...'))])         // 附加属性（输出为 ;{"k":v}）
LoggerConfig.filter = MyLogFilter()                       // LogFilter：脱敏 / 改键
LoggerFactory.refresh()                                   // 按当前配置重建 facade（CAS 热替换）

// f_data：对象 / JSON / Map 互转
DataObject<T>.populate(src, flag: DEFAULT_DATA_FLAG)      // 类实例 → 类实例
DataObject<T>(obj)['field'] / .get<V>('field')            // 按名读写
toJson(obj) / fromJson<T>(jsonString)                     // 对象 ↔ JSON 串
JsonValue.from(DataObject<T>(obj)) / JsonValue.fromStr(s) // 对象/串 → JsonValue
DataPath.cache("$.a[?(@.b > 1)].c").get(data)             // JSONPath 查询

// f_random：随机数与随机字符串
rand.nextInt64(1, 100, closed: true) / rand.nextFloat64(0.0, 1.0)
rand.randomInt64(0, 10)                                   // 无限随机数流
RandomString().randomLowerHex(32) / .randomLettersNumbers(16)
ThreadLocalRandom.current                                 // 线程本地 SecureRandom
randomReservoir<T>(3, source)                             // 蓄水池抽样

// f_util.UUID：v1/v3/v4/v5/v6/v7/v8
UUID.random() / UUID.unixTimeBased() / UUID.timeBased()...node(...)
UUID.md5(s) / UUID.sha1(s)                                // v3 / v5 命名空间 UUID
UUID.parse(s) / UUID.tryParse(s) / id.toHexString() / id.version

// f_util 工具箱
@IsUUID                                                   // 校验注解（Validator 子类，可 & | ! 组合）
IdMaker().nextInt64()                                     // 10bit主机号+41bit毫秒+12bit序号
CaseFormat.Camel.convert('userName', to: CaseFormat.LowerUnderScore)
TextTemplate.compile('订单 ${id} 已创建').format(map)      // 支持 time: number: regex:
PathPattern().compileIfAbsent('/api/{id}'){data}.data<T>(path)  // + extractVariableInPath
MenuNode.transform<MenuPO>(list, emptyId: 0){po => MenuNode(po)}
Factory<A,O>.assemble<T>(producer) / .produce<T>(arg)     // 按类型分派的工厂
Strategies<N,A,R>.register(strategy) / .execute(name, arg)
ResponsibilityChain<C,A,R>.register(...) / execute / executeAll  // 注意拼写 Responsibility

// f_base：公共底座（建议无脑导入；顺带 public import std.collection/reflect/regex/time/math）
ExitCallbacks.atExit(priority){...} / ExitCallbacks.toExitGracefully()   // 权重升序执行清理；f_app 已自动注册 SIGTERM/SIGINT
EmptyArray/EmptySet/EmptyMap/EmptyList<T>.instance()                     // 各类容器的"空实现"，private 构造，只能这么取
it.toArrayList()/groupBy{...}/peekable()/flatten(toThrow:)/filterType<R>(exactly:)
arr.grow(n) / arr * 3 / 1.isOdd / 1.flip() / Int64.BYTES
Option.toResult()/iterator()/caller{...}  /  Result.orDefault/orElse/mapValue/filterOk/transpose
StringGenerator().append/insert/replaceFirst/reverse/unsafeBytes
Comparator<T>(cmp).then{...}.reverse() / Comparator.create<T>() / Equaler<T> / HashBuilder()
resource(res){ r => ... } / ResourceManager<R>(new) / FutureTask<T>(fn) / InheritedTaskLocal<T>
@nameof(expr) / @nameValueOf(expr)                                       // 宏包 fountain::f_base.macros

// f_cache：堆缓存
HeapCache<V>(maxLife:, maxSize:, checkDuration:, evictionCallback:)   // builder() 亦可
  .get/set(life:,once:)/prolong/getOrCompute/getOrDefault/removeIf/destroy
WeakHeapCache<T>                                                      // 弱引用，GC 后自动清理

// f_pool：对象池（ORM 的 DatabasePool 就是它）
Pool<V>(mode:, initSize:, minSize:, maxSize:, idleTimeout:,
        checkOnCreation:, checkOnBorrowing:, checkOnReturning:,
        checkInterval:, creator:, checker:, destroier:)
  .get(timeout:) / .giveBack(v)          // Mode: Fifo Lifo WeakFifo WeakLifo
KeyPool<K,V>.get(key, timeout:) / .giveBack(key, obj)
ArrayPool / ArrayListPool

// f_collection
BitSet / HashDict<K,V>(hasher:, equals:) / LinkedHashDict / TreeDict
LinkedHashMap / LinkedHashSet / PriorityQueue.create<T>() / SetOp(交集并集差集视图)

// f_time：时间 DSL
TimeUnit.{NANOSECOND..YEAR}  .trim .next .prev .since .ago .later .before .after .duration
5.seconds.later / 2.minutes.ago / 1.day.duration
DateTime.today / .yesterday / .tomorrow / .isLeapYear / .toUnixEpochMillis()
Duration.minute.ago / Duration.hour.later / TimeZone.Z

// f_regex：正则扩展 + 缓存
ExtendRegex.{INTEGER DECIMAL REAL_NUMBER EMAIL DURATION IDENTIFIER BASE64}
'pattern'.regex(solid: true|false)       // solid:false → HeapCache，1 万条 / 1 天

// f_rx：反应式
Observable<T>.iterable/emitter/single/maybe/empty/concat
  .subscribe(name, FuncObserver<T>().setNext{}.setError{}.setComplete{})
  .withAlwaysNew() / withCurrent() / withSingle(...) / withFixed(...)
  .delay(d) / .defer() / .immediately()
BackPressure.{Discarding ToDropOldest AlwaysBlocking Throwing Current NewThread ...}
setErrorResumer(...) / Observable.replaySize(capacity)

// f_http：数据格式
MediaTypes.parse('application/json') / .tryParse(s) / .register(mt)
mediaType.fromData(data)                                  // Data → 字节（响应）
mediaType.toData(input)  / .toDataFields<T>(bytes)        // 字节/流 → Data → 对象（请求）
MultipartFormData().newPart().name('n').value('v').build() // 构造 multipart 请求
MultipartFile.filename / .size / .bytes() / .copyTo(out) / .close()
```

---

# 附录 B：录屏分镜建议

| 镜 | 时长 | 内容 | 画面 |
| --- | --- | --- | --- |
| 1 | 3' | 开场：为什么用 fountain（痛点清单） | 幻灯片 |
| 2 | 5' | 三个设计决策：无 main / 宏与注解 / 配置来源（环境变量或命令行） | 幻灯片 + `fboot/src/main.cj` |
| 3 | 3' | 环境准备 | 终端 |
| 4 | 2' | `fboot help` | 终端 |
| 5 | 4' | `fboot workspace` + `fboot module`（从零建项目） | 终端 + IDE |
| 6 | 3' | 写一个 Controller（20 行） | IDE |
| 7 | 4' | `fboot build`（讲版本模块 + banner + 编译期注入） | 终端 + `boot.sh` |
| 8 | 2' | `fboot randhex` + SM4 密钥 | 终端 |
| 9 | 3' | `fboot run` + curl 验证（第一个 hello world） | 终端 |
| 10 | 2' | `fboot cleanUpdate` | 终端 |
| 11 | 8' | 配置：f_config（无配置文件 / 四级优先级 / SM4 内嵌 / `@EmbedSensitive`） | IDE + `boot.sh` |
| 12 | 5' | 切到 `fdemo`：结构 + 建表 + build + run | IDE + 终端 |
| 13 | 6' | 接口验证清单（12 条 curl，重点 401 那条） | 终端 + 浏览器 |
| 14 | 8' | IOC：f_bean | IDE + 幻灯片 |
| 15 | 7' | AOP：f_aspect + `ControllerAspect` 现场演示 | IDE + 终端 |
| 16 | 8' | 数据：f_data（`@DataAssist` / `populate` / JSON / 校验 / JSONPath） | IDE + 终端（`boot.cj` 的 A~H 输出） |
| 17 | 12' | 工具箱：f_util（UUID / @IsUUID / IdMaker / CaseFormat / TextTemplate / PathPattern / TreeTransformer / 三个设计模式骨架） | IDE + 终端（`cjpm test`） |
| 18 | 10' | MVC：f_mvc（路由/参数/校验/异常） | IDE + 终端 |
| 19 | 8' | HTTP 格式：f_http（`MediaType` / `MediaTypes` 注册表 / 自定义格式 / 文件上传） | IDE + 终端（`curl -F`） |
| 20 | 15' | ORM：f_orm（PO/DAO/Service/SQL 三方式/分页） | IDE |
| 21 | 8' | 事务：三种开启方式 + 钩子顺序 + 现场日志 | IDE + 终端 |
| 22 | 8' | 安全：f_security + f_jwt 端到端 | IDE + 终端（401 vs 200） |
| 23 | 4' | CRON：f_ticktock（含"忘了 dylibPattern"的坑） | IDE + 终端 |
| 24 | 11' | 日志：f_log（默认静默 / 级别挂 appender / 异步管道 / 切割压缩 / 现场调 DEBUG 看 access log 与 SQL） | IDE + 终端（`tail -f ./log/fdemo.log`） |
| 25 | 4' | 串讲：一次请求的完整穿越 | 架构图 |
| 26 | 19' | 基础设施：f_base（优雅退出 + 扩展）+ f_cache / f_pool / f_collection / f_time / f_regex / f_rx / f_random（含随机数的区间/流/字符串/已知行为） | IDE + 终端（`fboot randhex 32`） |
| 27 | 5' | 坑 & Q&A + 性能压测 | 终端 |

---

> 讲稿中所有的路径、包名、注解名均取自本仓库当前源码（`fboot`、`f_app`、`f_config`、`f_bean`、`f_aspect`、`f_data`、`f_util`、`f_mvc`、`f_http`、`f_orm`、`f_security`、`f_ticktock`、`f_jwt`、`f_random`、`f_log`、`f_cache`、`f_pool`、`f_collection`、`f_time`、`f_regex`、`f_rx`、`fdemo`）。
> 若后续版本有变更，以各模块 `README.md` 与源码为准。

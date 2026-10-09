# workspace / 模块 / 依赖：产物样例与校验

本文所有样例来自 `fboot workspace`、`fboot module` 的实际行为（实现见 `f_app/src/App.cj` 的
`appendToml` / `initWorkspace` / `initModule` / `addModule`）。如果实际产物与本文件不一致，以仓库代码与现场产物为准。

## 1. `fboot workspace <name>` 之后的 cjpm.toml

> 本节与第 2 节的产物样例只用于**校验 fboot 的结果**，不要照着手工造：workspace 与模块一律用
> `fboot workspace` / `fboot module` 创建（依赖注入、`[target]` 段补齐、`members` 追加都只有 fboot 会做，
> 见 SKILL.md 工作流 B / C）。

fboot 先执行 `cjpm init --workspace`，再对生成的 cjpm.toml 做四次替换并追加 `[profile.build]` 与 `[target]`。
等价产物形态（`${FVersion}` 是 fboot 自身携带的版本号，如 `1.3.14`）：

```toml
[package]
  cjc-version = "1.2.0"
  name = "demo"
  description = "..."
  version = "1.0.0"
  ...

[dependencies]
  "fountain::f_base" = "1.3.14"
  "fountain::f_version" = "1.3.14"

[workspace]
  version = "1.0.0"
  members = []
  compile-option = "--dy-std -Woff all"
  override-compile-option = "--dy-std -Woff all"

[profile.build]
  incremental = true

[target]
[target.x86_64-unknown-linux-gnu]
  compile-option = "--dy-std -Woff all -ldl"
  override-compile-option = "--dy-std -Woff all -ldl"
[target.x86_64-unknown-linux-gnu.bin-dependencies]
  path-option = ["${CANGJIE_STDX_DYNAMIC_PATH}", "${CANGJIE_STDX_PATH}"]
# …其余平台（aarch64-linux / x86_64-w64-mingw32 / darwin / ohos）同构
```

要点：

- `[workspace] version = "1.0.0"` 是 fboot 写死的固定值，与依赖版本无关。
- `f_base` / `f_version` 的版本**等于当前 fboot 的版本**；换成别的 fboot 重装后要同步改这两条。
- `[target]` 的 `path-option` 引用 `${CANGJIE_STDX_DYNAMIC_PATH}` 与 `${CANGJIE_STDX_PATH}`，所以编译前这两个变量必须已设置。
- 若目标目录已有非空内容，`fboot workspace` 无参形式不可用（`cjpm init --workspace` 只对空目录干净），改用 `fboot workspace <name>` 建子目录。

校验命令：

```bash
grep -n "fountain::f_base" cjpm.toml          # 依赖已注入
grep -n "\[target.x86_64-unknown-linux-gnu\]" cjpm.toml   # target 段已补齐
fboot build                                    # 能解析依赖并开始构建
```

## 2. `fboot module <module_name>` 之后的模块

```text
<workspace>/
├── cjpm.toml          # members 里出现 "./<module_name>"
└── <module_name>/
    ├── cjpm.toml      # cjpm init --type=dynamic 生成（含 output-type = "dynamic"）
    └── src/
        └── <module_name>.cj   # 占位内容：package <module_name>
```

- 模块 cjpm.toml 由 `fboot module`（内部执行 `cjpm init --type=dynamic`）生成，保持默认即可：`output-type = "dynamic"`、`compile-option = "--dy-std"`。不要手写、不要直接用 `cjpm init` 建模块、不要改成 executable。
- fboot 只会自动写一个占位 `.cj`；包结构（`controller/`、`service/impl/` 等）由开发者自己建，包名与目录一致。
- 目标目录是「当前目录或当前目录的一层子目录」时自动追加 members；其它位置不会（`App.cj` 的 `addModule`）。
- workspace 根声明的依赖对所有成员可见，成员自己的 cjpm.toml 不需要 `[dependencies]`（`fdemo/boot`、`fdemo/user` 即是如此）。

包名由源码的 `package` 声明决定，与模块目录名不必相同：fboot module 生成的占位文件是 `package <module_name>`；
fdemo 则统一用 `fountain::` 前缀（模块目录 `user` 里是 `fountain::user.controller`、`fountain::user.service` 等）。
模块之间、以及引用 fountain 库模块时都用**包名** import（如 `import fountain::user.service.HelloworldService`），
包名一旦定下，其它模块的 import 必须跟着它写。

## 3. 依赖的三种写法

在 **workspace 根** cjpm.toml 的 `[dependencies]` 声明（版本号换成与 fboot 相同的版本）：

```toml
[dependencies]
  # 1) 中心仓版本依赖（默认选择）
  "fountain::f_mvc" = "1.3.14"
  # 2) 本地路径依赖（fountain 源码在本地、或模块未发布时）
  "fountain::f_mvc" = {path = "../fountain/f_mvc"}
  # 3) git 依赖（引用仓库）
  fountain = {git = "https://gitcode.com/Cangjie-SIG/fountain.git", branch = "master"}
  # 4) 带属性的第三方依赖（output-type 等）
  "postgres_driver" = {version = "0.0.3", output-type="dynamic"}
```

规则：

- 只声明**直接使用**的模块；传递依赖由 cjpm 自动解析。
- 版本依赖必须用与 fboot 相同的版本号；混用不同版本的 `fountain::f_*` 可能符号不匹配。
- 版本依赖要求**中心仓已发布该版本**：目标版本未发布（或只发布了部分模块）时 `cjpm update`/`fboot build` 会失败——
  改用 path 依赖指向本地 fountain 源码（`"fountain::f_xxx" = {path = "<fountain>/f_xxx"}`），
  或重装一个已发布版本的 fboot（workspace 依赖版本会随之变化）。发布状态以中心仓查询与 `.modules` 为准。
- `.modules` 的 `[detention]` 段（当前为 `f_llm`、`fleet`）不发布中心仓，不能用版本依赖；需要时用 path/git 依赖并与用户确认。
- 依赖变更后用 `fboot build`（或 `cjpm update`）验证解析；`fboot cleanUpdate` 可清掉旧缓存重来。

## 4. fdemo 参考结构（应用范式的完整样本）

```text
fdemo/
├── cjpm.toml            # workspace 根：本地 path 依赖 + members=["./boot","./user"] + target 段
├── boot.sh              # build/run 脚本：环境变量、dylibPattern、LD_LIBRARY_PATH 兜底
└── boot/  user/         # 两个模块
    boot/src/boot.cj     # 初始化：ORM 驱动注册等（包级 `private let _ = {=> ...}()` 静态初始化）
    user/src/
    ├── controller/      # @Controller + @GetMapping 等（HTTP 入口）
    ├── service/  service/impl/   # @Bean 实现 + lookup<T>() 注入
    ├── dao/             # @DAO 接口 + SQL
    ├── model/           # 数据模型（PO/DTO）
    ├── util/            # 定时任务（f_ticktock）、认证等工具
    └── user.cj          # 模块占位文件
```

运行入口（`fdemo/boot.sh:92`）：

```bash
fboot run $target_path --dylibPattern='(boot|user\.util\.(auth|cron)|\.(controller|service\.impl))'
```

即：`--dylibPattern` 必须覆盖 **controller 包、service.impl 包、初始化包、cron 所在包** 的动态库文件名
（fountain 按库文件名正则匹配加载；详见 `fdemo/README.md` 与 `f_app/README.md`）。

## 5. 初始化完成的检查清单

1. workspace 根 cjpm.toml：`[dependencies]` 含 `f_base`/`f_version`（版本=fboot 版本）+ 本次要用的模块。
2. `members` 含全部模块目录。
3. 每个模块 `output-type = "dynamic"`。
4. `fboot build` 成功，`target/release/` 下出现对应 `*.so`。
5. `fboot run --dylibPattern='...'` 能启动（长驻进程按 SKILL.md 的约定执行）。

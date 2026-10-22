# 服务器应用开发指南（fountain）

本文是工作流 F 的展开。所有 API 细节以 `fdemo/` 实际代码与各模块 README 为准；语法与标准库问题用
`cangjie-coding` / `cangjie-doc-lookup` 技能查证，不要凭记忆写。

## 1. 应用模型

- **没有 main 函数**：应用项目每个模块都编译为动态链接库，由 `fboot run` 加载并启动（`f_app` 负责）。
- 启动链路：`fboot run --dylibPattern='...'` → 加载名字匹配正则的动态库 → 各库的 static init 注册
  Initializer / 子命令 / Bean 等 → 按依赖顺序初始化 → 各 `start()` 在新线程中运行 → 主线程永久阻塞。
- 初始化接口 `fountain::f_app.Initializer`（`name` / `dependencies` / `init()`）；`f_bean`、`f_mvc`、`f_orm`、
  `f_ticktock` 这类需要显式初始化的功能都通过 Initializer 完成，应用代码通常不需要自己实现。
- 需要在启动前做额外初始化的（如注册数据库驱动），放在单独的初始化模块里用**包级静态初始化**表达：

  ```cangjie
  package fountain::boot
  import fountain::f_orm.*
  import postgres_driver.*

  private let _ = {=>
      // 注册驱动 / ORM.register(...) 等
  }()
  ```

  参考 `fdemo/boot/src/boot.cj`（内部有完整注释）。

## 2. 分层结构（对齐 fdemo）

| 目录（模块内） | 职责 | 关键写法 | fdemo 参考 |
| --- | --- | --- | --- |
| `controller/` | HTTP 入口 | `@Controller` + `@GetMapping[...]` 等 | `fdemo/user/src/controller/UserController.cj` |
| `service/`、`service/impl/` | 业务逻辑、依赖注入 | `@Bean` + `@BeanMeta`，`lookup<T>()` | `fdemo/user/src/service/impl/UserServiceImpl.cj` |
| `dao/` | 数据库访问 | `@DAO` 接口 `<: RootDAO`，`executor.setSql(...)` | `fdemo/user/src/dao/UserDAO.cj` |
| `model/` | 数据模型（PO/DTO/校验） | `@DataAssist`、`@ORMField`、`@QueryMappersGenerator` | `fdemo/user/src/model/` |
| `util/` | 定时任务、认证等 | `f_ticktock` cron、工具类 | `fdemo/user/src/util/` |

模块划分建议：一个业务模块（对齐原项目/需求的分层）+ 一个可选 `boot` 初始化模块（只用环境变量配置不够时）。

## 3. 常用写法

### 3.1 Controller 与路由

```cangjie
package demo::user.controller   // 包名按项目自定，与目录结构一致（fdemo 用 fountain::user.controller）

import fountain::f_mvc.*
import fountain::f_mvc.macros.*

@Controller
public class HelloController {
    private let helloService = lookup<HelloService>()

    @GetMapping[path: "/hello", produces: 'text/plain', consumes: 'application/x-www-form-urlencoded']
    @IgnoreSecurity
    public func hello(@RequestParam username: String): String {
        helloService.sayHello(username)
        return "hello"
    }
}
```

- 注解族：`@Controller`、`@RequestMapping`、`@GetMapping`/`@PostMapping` 等、`@RequestBody`、`@RequestParam`、
  `@RequestHeader`、`Redirect`（重定向）、`@IgnoreSecurity` / `@IgnorePrivilege` / `@IgnoreAuth`（安全豁免）。
- 完整路由规则、produces/consumes 取值、参数绑定细节读 `f_mvc/README.md`。

### 3.2 依赖注入（f_bean）

- 实现类加 `@Bean`、`@BeanMeta`；使用处 `lookup<T>()` 取实例。
- 参考 `fdemo/user/src/service/impl/UserServiceImpl.cj` 与 `f_bean/README.md`。

### 3.3 数据访问（f_orm）

- DAO 是 `@DAO` 修饰的接口，继承 `RootDAO`，方法体里写 SQL：

  ```cangjie
  @DAO
  public interface UserDAO <: RootDAO {
      func register(username: String, password: String): Int64 {
          executor.setSql('''
              insert into user_info(username, password)
              values(${arg(username)}, ${arg(password)})
              returning id''').insert
      }
  }
  ```

- 模型映射：`@ORMField`（字段/主键）、`@DataAssist`（生成通用方法）、`@QueryMappersGenerator`（查询映射）。
- 驱动：数据库驱动是**第三方依赖**（如 `postgres_driver`，在 workspace 根 cjpm.toml 声明，`output-type="dynamic"`）；
  mock 场景用 `f_mockdb`。
- 连接池与事务：全部通过 `orm_*` 环境变量配置（`fdemo/boot.sh` 第 35-75 行是完整清单），事务注解 `@Transactional`
  与 `orm_transactionalFuncExecution` 配置；细节读 `f_orm/README.md`。

### 3.4 AOP（f_aspect）

- `@AspectRoute(route = ExecutionRouteRule(...))` 修饰切面类，实现 `before` / `after` / `around` / `throwing` / `final`。
- 切点用环境变量声明，变量名由开发者自定（如 `controllerPointcut='*::*..*Controller.*(**): *'`，见 `fdemo/boot.sh:29`），在切面声明处引用。
- 参考 `f_aspect/README.md` 与 `docs/快速开始/000.get-start.md` 的 AOP 示例。

### 3.5 定时任务（f_ticktock）

- CRON 定时器；参考 `fdemo/user/src/util/` 下的 cron 用法与 `f_ticktock/README.md`。
- 注意：定时任务所在包要在 `--dylibPattern` 里（fdemo 的 pattern 就包含 `cron`）。

### 3.6 认证与权限

- `f_jwt` 负责令牌，`f_security` 配合 MVC 做认证/权限；Controller 上按需 `@IgnoreSecurity` 豁免。
- 默认安全策略、令牌校验细节读 `f_security/README.md` + `f_jwt/README.md`。

### 3.7 日志（f_log）

- `LoggerFactory.getLogger<T>()`（按类型）或 `LoggerFactory.getLogger('name')`（按名字）。
- 输出目标、级别、格式、异步缓冲全部用 `logger_*` 环境变量配置（`fdemo/boot.sh` 第 19-28 行）。

### 3.8 配置（f_config / 环境变量）

- 配置以环境变量为主：运行期配置优先级高于编译期；`fboot build` 支持 `--key=value`，会作为编译期环境变量嵌入产物。
- 敏感信息（数据库 URL、密钥）建议只在运行期用环境变量提供；确要嵌入时可用 `fboot randhex` 生成密钥配合加密。
- `f_config` 模块提供读取封装；具体 API 读其 README。

### 3.9 外部 HTTP 调用

- 用 `f_httpclient`；接口细节以其 README 与 `fdemo`（如有用例）为准。

## 4. 构建 / 运行 / 测试

```bash
# 构建（自动生成版本模块 AppVersion，再 cjpm build；--key=value 变编译期环境变量）
fboot build [PATH] [--key=value ...]

# 运行（永久阻塞；长驻进程交给用户或后台执行）
fboot run [PATH] --dylibPattern='<正则>'

# 测试（用 PATH/test/cjpm.toml 覆盖后 build + run）
fboot test [PATH] --dylibPattern='<正则>'

# 清理重建（cjpm clean + 删 cjpm.lock + cjpm update）
fboot cleanUpdate [PATH]
```

`--dylibPattern` 决定加载哪些库，必须覆盖：**controller 包、service.impl 包、初始化包、cron 所在包**。
目录形态照抄 `fdemo/boot.sh`（搜 `dylibPattern=`）；不确定时先 `fboot build`，再 `ls target/release`（或对应产物目录）看实际库文件名。
项目启动脚本（`boot.sh` / `boot-macos.sh` / `boot-win-gitbash.sh`）的生成与合并见 `references/launch-scripts.md`。

单元测试用仓颉 unittest（写法见 `cangjie-coding` 技能与 `~/.autocode/cj/doc/cj_unittest.md`）。

## 5. 需求覆盖检查与缺口处理

1. 功能点 → 模块初筛：`references/module-index.md` 的选型速查。
2. 命中核对：`python scripts/fountain_lookup.py search "<能力关键词>"`（必要时 `--in code`），再读该模块 README 与 `src/`
   （脚本按项目在用版本切文档副本，读到的即该版本；输出头部有版本标注，换版本用 `--version`）。
3. 有缺口时的固定动作（不得跳过）：**停下来问用户**，给出四选一（继续用简单方案 / 用户提供第三方依赖 / 缩减范围 /
   在项目内自行实现完整功能和要求的基础设施代码、工具代码），并明确说明缺口是什么、影响哪些需求点。
4. 禁止项：把缺失能力写成空实现或假数据；引用没核对过的第三方库；把「标准库/其它语言有」当成「fountain 有」。

## 6. 测试与验收

三类测试的分工与门禁见 `references/delivery-workflow.md`（第 3–5 节）：

- **单元测试（TDD）**：每个功能点先写测试再实现（Red-Green-Refactor）；`cjpm test` / `fboot test`。
- **回归测试**：每批功能完成后跑全量测试（含既有用例）；交付节点（提交前 / 打 tag 前）必须再跑一次。
- **冒烟测试**：起服务后验证关键路径（HTTP 项目 curl 核心接口；RPC 项目 runServer + runClient 打通一次），并检查日志（`logger_*`）无异常堆栈。
- 数据库相关：先用 `f_mockdb` 或真实库跑通最小 DAO 用例再铺开。

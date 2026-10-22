# 旧版本项目升级（工作流 I 展开）：SDK 1.0.x + fountain 1.0.x → 与当前 fboot 同版

目标：把**已经跑起来的老项目**（仓颉 SDK 1.0.x + fountain 1.0.x）升到「fountain 依赖版本 = 当前 fboot 版本」。
产出默认是**同一个项目就地升级**（保留 git 历史）；用户要求时才重建骨架、在新目录产出。
与工作流 G / H 不同：这里**不改技术栈、不重写业务**，只做「环境 → 依赖 → 包名 → API → 配置 → 验证」的版本升级。

**版本升级属高风险改动**：交付门禁（TDD / 全量回归 / 冒烟 / 提交 / 建 tag）按 `references/delivery-workflow.md`，
其中第 4 节的「高风险改动做针对性回归」对本流程尤其适用。

## 0. 先决判断（三条信号，任一命中即属本流程）

| 信号 | 1.0.x 时代（升级前） | 当前（升级目标） |
| --- | --- | --- |
| 根 cjpm.toml 的 fountain 依赖 | `fountain = {path = "../"}` 或 `fountain = {git = "...", branch = "master"}`（聚合根一包） | `"fountain::f_mvc" = "<fboot 版本>"` 等**按模块**依赖 |
| 模块 cjpm.toml 的 `cjc-version` | `"1.0.4"`（SDK 1.0.x） | `"1.2.0"`（以目标版本仓库 / fboot 新建模板为准） |
| 源码 import | `import fountain.mvc.*`（聚合根）、`import f_mvc.*`（扁平模块名） | `import fountain::f_mvc.*` |

补充判据：启动脚本只有一个 `boot.sh`、库搜索路径**后插**（见第 5 节）；根目录没有 `.modules`（中心仓发布尚未出现）。
1.1.x / 1.2.x 起步的项目流程相同、差异更小，也走本流程（第 4 节逐条核对）。

## 1. 环境对齐（先做，否则后面全是假错误）

1. 工作流 A：安装 / 配置**当前 fboot**；`fboot version` 拿到目标版本号 `x.y.z`（= 待写入的依赖版本 = 后续查询版本）。
2. **换 SDK / stdx**：老项目模块写的是 `cjc-version = "1.0.4"`，当前 fountain 模块是 `"1.2.0"` —— 用旧 SDK 编译
   会在依赖解析 / 语法上先失败。把本机 SDK 与 stdx 切到与 fboot 匹配的版本（版本号以目标版本仓库的
   各 `cjpm.toml` 与 `fboot module` 新建模块模板写出的值为准），并配好 `CANGJIE_STDX_PATH` /
   `CANGJIE_STDX_DYNAMIC_PATH`（`[target]` 段的 `path-option` 要用）。平台细节见 `references/environment.md`。
3. 验收：`fboot version` 正常；`cjc -v` 是新 SDK；此时**先不要动项目**。

## 2. 现状评估（只读，先出清单再动手）

| 维度 | 看什么 | 记录什么（后续要用） |
| --- | --- | --- |
| 依赖形态 | 根 cjpm.toml `[dependencies]` | 老写法（聚合根 path/git）、第三方依赖清单、`members` |
| 模块清单 | 各模块 cjpm.toml | `cjc-version`、`output-type`（必须仍是 `dynamic`）、`version` |
| 代码范围 | `import fountain.*` / `import f_*` 的**去重模块名** | 升级后要声明的 `fountain::f_xxx` 直接依赖清单 |
| 配置清单 | `boot.sh` 的 `export` 与 `fboot build` 参数 | 老配置项名（后面逐个核对是否仍存在） |
| 第三方依赖 | 驱动 / 字符集等 | 老写法（git 依赖居多）与新写法的对照（第 4.3 节） |
| 测试 | `*_test.cj` 的位置与写法 | 迁移范围（`@Test` / `@TestCase` / `@Assert` 写法不变） |

```bash
fboot version
grep -n "fountain" cjpm.toml                                   # 依赖形态
grep -rn "import fountain\.\|import f_" --include='*.cj' .     # 旧 import 形态（哪几个模块）
grep -n "export " boot.sh                                       # 老配置项清单
```

## 3. 依赖与骨架升级

### 3.1 推荐：就地升级（保留 git 历史）

1. 动手前：`git status` 干净、按用户项目规范开分支（如 `feature/upgrade-1.3`）。
2. 根 cjpm.toml：
   - 删掉聚合根依赖（`fountain = {path/git}`），改为**按模块**声明第 2 节记录的模块：
     `"fountain::f_mvc" = "<fboot 版本>"`（只列直接使用的，传递依赖交给 cjpm；`.modules` 的 `[detention]` 模块不能版本依赖）；
   - `[workspace] version` 保持；`members` 保持；
   - `[profile.build] incremental = true` 保留；
   - `[target.*]` 段对齐：`bin-dependencies.path-option` 要**同时**含 `${CANGJIE_STDX_DYNAMIC_PATH}` 与
     `${CANGJIE_STDX_PATH}`（旧产物通常只写了前者）。
3. 模块 cjpm.toml：`cjc-version` 改成当前值；`version` 同步；`output-type = "dynamic"` 不动；不要在模块里写依赖。
4. **对照模板再动手**：在临时目录跑一次 `fboot workspace <tmp>` + `fboot module <tmpmod>`，拿它生成的 cjpm.toml
   逐段对照自己的项目，避免漏项（产物样例见 `references/project-setup.md`）。

### 3.2 可选：重建骨架（与用户确认后）

项目结构混乱、或用户想顺带对齐 `fdemo` 分层时：`fboot workspace <新目录>` → `fboot module <名>` →
源码 `git mv` 搬入（同工作流 H 步骤 4）。除用户明确要求，默认不做——重建会打散历史、放大改动面。

## 4. 代码适配（编译驱动，逐条修）

### 4.1 第一步：机械替换 import 包名（用脚本，别手改）

```bash
python <skill-root>/scripts/migrate_fountain_imports.py <项目根>            # 预演（只报告）
python <skill-root>/scripts/migrate_fountain_imports.py <项目根> --apply    # 落盘
```

覆盖两种老写法与宏包子包，依据是两版的 shim 声明：

| 老写法（1.0.x） | 新写法 | 依据（`src/<seg>/<seg>.cj`） |
| --- | --- | --- |
| `import fountain.mvc.*` | `import fountain::f_mvc.*` | 旧 `package fountain.mvc` + `public import f_mvc.*` → 新 `package fountain::fountain.mvc` + `public import fountain::f_mvc.*` |
| `import fountain.mvc.macros.*` | `import fountain::f_mvc.macros.*` | 同上（`macro package` 子包） |
| `import f_mvc.*`（旧扁平模块名） | `import fountain::f_mvc.*` | 旧 `f_mvc/src/*.cj` 是 `package f_mvc`，新是 `package fountain::f_mvc` |
| `import fountain.data.macros.*` | `import fountain::f_data.macros.*` | `src/data/macros/macros.cj` |

脚本只改 `import` 行、默认 dry-run；非 import 行里出现的 `fountain.<seg>`（完全限定引用）会列进
「需人工确认」。落盘后复验：`grep -rn "import fountain\.\|import f_" --include='*.cj' .` 应无输出。
**这次替换单独一个提交**，便于回退。

### 4.2 第二步：`fboot build` 逐条修编译错误（两版对照查证）

```bash
fboot build                     # 从第一个错误开始修，改完再跑，滚动推进
python <skill-root>/scripts/fountain_lookup.py --version <老项目在用版本> search "<关键词>" --module f_mvc  # 旧版行为
python <skill-root>/scripts/fountain_lookup.py --version <目标版本> search "<关键词>" --module f_mvc      # 新版行为
```

- **老版本号怎么取**：读老项目所依赖的 fountain 源码里 `f_version/src/FountainVersion.cj` 的 `Version`
  （老项目的 fountain 依赖正是指向该源码的 path / git 依赖），例如 `1.0.48`。
- **1.0.x 的 tag 名与版本标记不总相等**：实测 `release-1.0.49` ~ `release-1.0.54` 的 `FountainVersion` 标记都还是 `1.0.48`。
  查旧版时出现 `⚠ 版本不一致` 先分辨：若是「tag 名 ≠ 标记」属常态，内容以切到的 tag 为准；若是真切错了版本，按提示重切。
- `--version X.Y.Z` 只切**技能目录下的文档副本**（同一副本先后切两版即完成对照），不动任何项目源码；输出头部有版本标注。
  语法 / 关键字 / stdx 问题加载 `cangjie-coding` 与 `cangjie-doc-lookup`（见 SKILL.md「必须遵守」）。

### 4.3 已知硬差异（先按表核对，再用两版对照确认细节）

| 差异 | 老 → 新 | 证据 |
| --- | --- | --- |
| 包名 / import | `fountain.mvc.*` / `f_mvc.*` → `fountain::f_mvc.*` | 第 4.1 节（用脚本） |
| AOP 参数对象 | `InvocationFuncInfo`：`class` → `struct`（值类型、不可变、每层调用一个实例） | `f_aspect/src/QualifiedFuncInfo.cj`、`f_aspect/README.md` |
| 连接池 | `DatabasePool`（老代码里是 `fountain.orm.wrap.DatabasePool`）**迁到 `fountain::f_dbpool`**，`f_orm.wrap.DatabasePool` 变成重导出；`init(driver, ds)` 已删除，`init(driver, options!)` 改为显式传 url；`ConnectionException` 归属 f_dbpool | `f_dbpool/README.md`、`f_orm/src/wrap/DatabasePool.cj`、`f_orm/README.md` |
| 第三方依赖写法 | `charset4cj = {git = ...}` → 中心仓版本依赖 `"cangjie_tpc::charset4cj" = "1.0.5"`；opengauss 旧 git 驱动 → 示例改用 `"postgres_driver" = {version = "0.0.3", output-type = "dynamic"}` | 根 cjpm.toml、`fdemo/cjpm.toml` 注释 |
| 新模块可用（可选换用） | `f_rpc` / `f_protocol` / `f_codec` / `f_dbpool` / `f_store` / `f_uring` / `f_health` / `f_bloom` / `f_crypto` / `f_egraph` | `fountain_lookup.py modules`；选型见 `references/module-index.md` |
| fboot 子命令 | 新增 `pub` / `randhex` / `shutdown` 等；`fboot version` 是查询，`fboot version x.y.z [...]` 才是升版 / 打 tag | `f_app/README.md` 第 3 节 |
| 聚合根 import | 老聚合根 `import fountain.*` 系不再作为新代码路线（新版聚合根叫 `fountain::fountain.*`，只作过渡）：shim **冻结不演进**，停在旧模块集合，没有 f_codec / f_rpc / f_dbpool / f_store / f_uring 等 | `src/` 目录（对比 1.0.54 与当前的 shim 集合） |

### 4.4 测试

- `@Test` / `@TestCase` / `@Assert` 来自 `std.unittest`（`std.unittest.testmacro`），**写法不变**，用例随包迁移。
- `cjpm test` 跑模块用例；`fboot test [PATH] --dylibPattern='...'` 跑应用整体（见 `f_app/README.md`）。
- 老项目若把测试放在业务包里：保持原位置即可，别顺手重构。

## 5. 配置与启动脚本升级

按 `references/launch-scripts.md` 生成 / 对齐三平台脚本（老项目通常只有 `boot.sh`）。老脚本 → 新脚本的**必改点**：

| 点 | 老脚本 | 新脚本 |
| --- | --- | --- |
| 库搜索路径 | `LD_LIBRARY_PATH=$LD_LIBRARY_PATH:$(find ...)`（**后插**） | 工程自己的 `release/*` 子目录**前插**（否则命中安装目录旧副本 ⇒ `undefined symbol`） |
| 平台 | 只有 Linux 版 | `boot.sh` / `boot-macos.sh` / `boot-win-gitbash.sh` 三份同步 |
| 编译期配置 | 靠环境变量 | `fboot build --key=value`（嵌入产物）；运行期 `exports()` 保留 |
| Windows | 无 | `--key=value` 传参、`cygpath -w` 转 stdx 路径 |

配置项逐个核对（清单来自老 `boot.sh` 的 `export`）：`orm_*`（含 `orm_useThirdPartyPool` / `orm_noPool` /
`orm_useStdPool` / `orm_databasePool*`）、`mvc_*`、`logger_*`、切面配置 —— 是否存在、默认值、生效方式一律以
**目标版本**的模块 README 为准（旧项可能被删除或改语义；`orm_databasePoolMaxWaiting` 就是新增项）。
不确定的项写进升级报告交给用户，不要凭老注释沿用。

## 6. 回归 + 冒烟 + 交付

1. **针对性回归**：老版本行为变化逐条核对（第 4.3 / 5 节的项都要有用例或手工验证），再跑**全量回归**
   （`cjpm test` / `fboot test`），失败先修实现再改用例（与用户确认后）。
2. **冒烟**：`./boot.sh build` → `./boot.sh run`（长驻进程交给用户或后台跑），关键路径（HTTP `curl` / RPC 调一次）
   + 日志无异常堆栈。
3. **交付**：按 `references/delivery-workflow.md` 第 6 / 7 节提交与建 tag。提交粒度：**依赖与 cjpm.toml 一处、
   机械 import 重写一处、API / 配置适配按模块各一处**，便于回退与 review。
4. **升级报告**（给用户）：旧 → 新对照表（依赖 / 包名 / API / 配置项 / 脚本）+ 行为变化 + 未适配项 + 启动方式。

## 7. 常见问题

- **只改版本号能跑吗**：不能。顺序必须是「环境 → 依赖与 cjpm.toml → import 包名 → 编译驱动修 API → 配置与脚本」；
  跳过前两步会得到一堆假错误。
- **聚合根依赖还能留吗**：`fountain = {path = "../"}` 配 `import fountain::fountain.mvc.*` 在本地仍可用，但
  shim 冻结、没有新模块、也不随模块演进 ⇒ 新代码统一用按模块依赖 `"fountain::f_*"` + `fountain::f_*` import。
- **`cjc-version` 报不匹配**：SDK 没换到位，回步骤 1。
- **错误太多不要慌**：先完成 4.1 的机械替换（能把大部分 import 错误一次消掉），再逐模块 `fboot build`；
  编译错误定位流程加载 `cangjie-coding`。
- **老项目自带启动脚本一坨 export**：先把「库路径前插 + 三平台 + 编译期参数」三件事做对，配置项是否保留
  按第 5 节核对，别整段照搬。
- **不要顺手重构**：升级提交里只放升级相关的改动（包名、API、配置）；业务逻辑的改进另开分支 / 另开提交。

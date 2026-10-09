# 非 fountain 的仓颉项目 → fountain 风格项目（工作流 H 展开）

目标：把「普通 cjpm 项目（executable / static / dynamic，不依赖 fountain）」改造成
「fountain workspace + 动态库模块 + fboot 启动」的形态。原项目只读，产出在用户确认的新目录。

## 0. 先决判断

- fountain 面向**服务端应用**；纯 CLI / 纯库项目改造成本高、收益低 ⇒ 先与用户确认是否有必要。
- 原项目若已依赖 `fountain::f_*`（哪怕只用了部分模块）⇒ 属于工作流 I（加 / 改配置），不走本流程。

## 1. 评估清单（只读）

| 维度 | 看什么 | 映射目标 |
| --- | --- | --- |
| 入口 | 有没有 `main()` / CLI 参数 | 初始化搬进 `boot` 模块；参数改环境变量 / `--key=value` |
| 构建 | cjpm.toml 的 `output-type`、`compile-option`、`[target]` | 改为 workspace + dynamic 模块（由 fboot 生成） |
| 网络 | stdx.net.http / 自研 socket / 第三方 | `f_mvc`（HTTP）；`f_net` + `f_protocol`（自定义协议） |
| 数据 | std.database.sql / 第三方驱动 / 手写 SQL | `f_orm`（驱动 + `orm_*` 配置） |
| 日志 | stdx.log / `println` | `f_log`（`logger_*` 配置） |
| 配置 | 硬编码 / 自读环境变量 / 配置文件 | `f_config` + 环境变量（编译期 / 运行期） |
| 并发 / 定时 | 手写线程池 / 定时器 | `f_concurrent` / `f_ticktock` |
| 序列化 | json / 自定义协议 | `f_codec`；stdx `encoding.json`（以模块 README 推荐为准） |
| 测试 | `*_test.cj` | 跟随包迁移；用仓颉 unittest |

## 2. 迁移步骤

合规前提：workspace 与模块**只能用 `fboot workspace` / `fboot module` 创建**，不要手工造 cjpm.toml。
交付环节（配置演进 / 严格 TDD / 回归 / 冒烟 / 提交 / 建 tag）的通用门禁见 `references/delivery-workflow.md`。

1. 建骨架：`fboot workspace <新目录>` → `cd <新目录>` → 按原项目分层 `fboot module <名>`（业务模块 + boot 初始化模块）。
2. 迁移源码（保留 git 历史优先）：

   ```bash
   git mv <原项目>/src/... <新目录>/<模块>/src/...   # 同一仓库内；跨仓库用 cp
   ```

   包名：模块内包名与目录一致；原顶层包名按新模块前缀重排（保持全 workspace 无重名）。
3. 拆 `main()`：
   - 初始化逻辑（注册驱动、启动服务、加载配置）→ `boot` 模块的包级静态初始化或 `Initializer`（参考 `fdemo/boot/src/boot.cj`）；
   - 命令行参数 → 环境变量或 `fboot build --key=value`；
   - 确认全项目不再有 `main()`（应用由 `fboot run` 加载动态库启动）。
4. 能力替换（**严格 TDD**）：按第 1 节映射逐类改写 import 与调用；每类按 Red-Green-Refactor 推进——
   先把对应测试迁移 / 补写成失败用例 → 最小实现转绿 → 重构；缺口按工作流 F 第 3 步处理（a–d 选项）。
5. 依赖与配置：依赖统一声明在 workspace 根 cjpm.toml（fountain 模块版本 = fboot 版本；第三方驱动保留，确认 `output-type`），
   **随功能演进补齐**；运行期 / 编译期配置落到三平台启动脚本。
6. 启动脚本：按 `references/launch-scripts.md` 生成三平台脚本（`dylibPattern` 覆盖 controller / service.impl / boot / cron 所在库）。
7. 回归 + 冒烟：

   ```bash
   fboot build        # 逐批修复编译错误（cangjie-coding 的流程）
   cjpm test          # 全量回归（含从原项目迁移过来的用例）
   ./boot.sh run      # 冒烟：关键路径 + 日志检查，再对照原项目行为逐项验证（长驻进程交给用户 / 后台）
   ```
8. 交付：按 `references/delivery-workflow.md` 完成提交与建 tag（提交前单元测试 / 回归 / 冒烟全绿；tag 前提交已推送）。

## 3. 常见问题

- 原项目是 executable：去掉 `main()` 后模块 `output-type` 由 fboot 生成为 `dynamic`，不要手改回 executable。
- 原项目用 stdx.net.http 等：改成 `f_mvc` 后路由 / 中间件语义要逐条核对，不是 1:1 映射。
- 包名冲突：迁移后同名包出现在两个模块会造成歧义 ⇒ 统一前缀或改名。
- 测试：`*_test.cj` 跟随包迁移；`cjpm test` 与 `fboot test` 的差异见 `f_app/README.md`。
- 原仓库：本流程不改原仓库；`git mv` 仅在同一仓库且用户确认时使用，绝不删用户文件。

## 4. 验收与报告

- 对照表：原功能 → 新实现（模块 / 文件）→ 状态（已验证 / 缺口 / 未实现）。
- 运行说明：构建命令、环境变量、启动命令、`dylibPattern`。
- 缺口与后续建议（报告口径同 `references/porting-guide.md`）。
- 交付：按 `references/delivery-workflow.md` 完成提交与建 tag。

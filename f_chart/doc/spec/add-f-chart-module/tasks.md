# Tasks

## 1. 模块骨架

- [x] 1.1 新建 `f_chart/cjpm.toml`：动态库、`fountain::f_chart`、依赖 `f_data` 与 `f_svg`、目标平台与 `f_svg` 对齐
- [x] 1.2 新建 `f_chart/README.md` 与 `f_chart/README_en.md`（能力、安装、M0 用法）
- [x] 1.3 根 `cjpm.toml` 增加 `fountain::f_chart` path 依赖
- [x] 1.4 `.modules` 的 `[include]` 增加 `f_chart`

## 2. M0：Chart 接口（TDD）

- [x] 2.1 Red：写 `src/Chart_test.cj`，用测试内 `ProbeChart <: Chart` 验证接口可多态调用、返回字符串
- [x] 2.2 运行 `cjpm test`，确认因 `Chart` 不存在而失败
- [x] 2.3 Green：写 `src/Chart.cj` 声明 `public interface Chart`
- [x] 2.4 写 `src/ChartException.cj`（`ChartErrorKind` + `ChartException <: BaseException`），补测试覆盖 kind / message / path
- [x] 2.5 `cjpm test` 全绿（5/5）

## 3. JSON 规范文档

- [x] 3.1 写 `doc/chart-json-spec.md` 总则：信封字段、类型、默认值、错误语义
- [x] 3.2 为 M1–M106 每一种图写字段表与完整 JSON 示例（重复别名标注复用）
- [x] 3.3 文档中的 106 段示例 JSON 已用 `json.loads` 全量校验；103 个唯一 `type` 全部有示例

## 4. 模块设计文档

- [x] 4.1 写 `doc/f_chart模块设计.md`：边界、依赖、渲染管线、文件映射、里程碑
- [x] 4.2 README 与设计文档互相链接

## 5. 验证与归档

- [x] 5.1 `cjpm build` + `cjpm test` 通过
- [x] 5.2 `openspec validate add-f-chart-module --strict` 通过
- [x] 5.3 `openspec archive add-f-chart-module`
- [x] 5.4 四件套同步到 `f_chart/doc/spec/add-f-chart-module/`
- [x] 5.5 分支内独立提交（含测试）

## 鸿蒙侧测试流程

鸿蒙沙箱只允许执行已签名的 ELF。`cjpm test` 生成的测试运行器与动态库需要先剥离旧的
`.codesign` 段并自签名，再执行：

```bash
cjpm test --no-run
python3 ~/tmp_sign/sign_elfs.py target/release
cjpm test --skip-build
```

M0 实跑结果：`TOTAL: 5, PASSED: 5, FAILED: 0`。

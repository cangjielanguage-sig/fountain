# add-f-svg-m7-output-overloads 验证

## 1. 测试

| 项 | 命令 | 结果 |
|---|---|---|
| 定向 | `cjpm test --filter SvgBuilderM7_test` | 20 / 20 PASSED（含新增 `writeOutputStreamMatchesString`、`saveOpenedFile`） |
| 全量 | `cjpm test` | 1228 / 1228 PASSED，0 ERROR / 0 FAILED |
| 构建 | `cjpm build` | success；`f_svg` 自身 0 warning |
| 规格 | `openspec validate add-f-svg-m7-output-overloads --strict` | valid |

## 2. 新增 API

| API | 行为 |
|---|---|
| `write(output: OutputStream): Unit` | 复用 `SvgWriter` 写入并 `flush`，不关闭流 |
| `save(file: File): Unit` | 等价 `write(file)`，不关闭文件 |

## 3. Requirement 覆盖

| Requirement | 新增 Scenario | 用例 |
|---|---|---|
| XML 文本输出契约 | 写入输出流 | `SvgBuilderM7_test.writeOutputStreamMatchesString` |
| 文件落盘 | 写入已打开文件 | `SvgBuilderM7_test.saveOpenedFile` |

## 4. 边界与兼容

- `save(path: String)` 与 `save(path: Path)` 语义不变。
- 既有 1226 条用例零改动；M7 之前全部用例零回归。
- 写入失败仍按 D9 包装为 `SvgException(kind: InvalidValue)`；`save(file:)` 的异常来自写入阶段。
- `write` / `save(file:)` 不接管所有权：调用方负责关闭。

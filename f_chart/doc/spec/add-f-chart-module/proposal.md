# Proposal

## Why

fountain 已具备 `f_svg`（SVG 1.1 生成）与 `f_data.json`（JSON 解析），但没有「用 JSON 描述图表、运行期生成 SVG」的统一能力。上层应用若要出图，只能各自拼 SVG，样式、坐标轴、图例与数据校验无法复用。

本变更建立 `f_chart` 模块与 M0 契约：用同一套 JSON 信封描述所有图，所有图实现同一个 `Chart` 接口，一个图一个源文件，按需导入。

## What Changes

- 新建仓颉动态链接库模块 `f_chart`（包名 `fountain::f_chart`），依赖 `f_svg` 与 `f_data`。
- **M0**：声明 `public interface Chart { func draw(data: JsonObject): String }`，`JsonObject` 来自 `fountain::f_data.json`。
- 定义跨图一致的 JSON 信封：`type` / `title` / `width` / `height` / `theme` / `legend` / `xAxis` / `yAxis` / `series` / `annotations`，各图只追加专属字段。
- 在 `f_chart/doc/chart-json-spec.md` 为每一种图给出字段定义与可运行 JSON 示例。
- 建立公共绘图基础设施（比例尺、坐标框、调色板、SVG 输出助手），后续每个图复用。
- 在仓库根 `cjpm.toml` 与 `.modules` 登记 `f_chart`。
- 后续 M1–M106 每个图独立走一遍 OpenSpec 全流程（proposal → specs → design → tasks → TDD apply → verify → archive），一个图一个源文件。

**BREAKING**：无。新模块不影响既有模块。

## Capabilities

### New Capabilities

- `chart-rendering`：JSON 驱动的 SVG 图表渲染契约——统一 `Chart` 接口、跨图一致的数据信封、各图实现的可导入性与错误语义。

### Modified Capabilities

无。

## Impact

- 新增 `f_chart/`（`cjpm.toml`、`src/`、`doc/`、`README.md` / `README_en.md`）。
- 根 `cjpm.toml` 增加 `fountain::f_chart` path 依赖；`.modules` 增加 `f_chart`。
- 依赖方向：`f_chart → f_svg → f_xml/f_base`，`f_chart → f_data → ...`；不反向依赖。
- 后续每个图新增独立源文件与测试文件，不修改既有图的行为。

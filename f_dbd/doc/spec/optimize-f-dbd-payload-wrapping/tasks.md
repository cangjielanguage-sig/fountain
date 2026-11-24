# 任务：sqlPayload 单层包装

> TDD：先建载荷等价回归与基准（Red：旧写法 2,321 B/次）→ 调用处改 `add<Data>`（Green）→ 全量回归。
> 只改 `DbdStatement.sqlPayload` 的一行；公开 API 0 变化。

## 1. 现状与测量

- [x] 1.1 探针：`DataAny` 是 struct；`add<DataAny>(DataAny(data))` 因泛型装箱产生冗余，8 参数 payload 2,321 B/次 vs `add<Data>` 1,744 B/次（验证：探针打印 `perCallTwo=2321 perCallOne=1744`，运行后删除）
- [x] 1.2 确认两种写法最终 `params` 内容一致：`add` 内部 `param.toData()` 拆回 `Data` 后重新 `DataAny(...)`（验证：`payload.cj:41-43` 与 `DataAny.cj:35-37`）
- [x] 1.3 确认 `Data` 的 `toData()` 默认返回自身（验证：`f_data/src/base/Data.cj:19-21`）

## 2. 等价回归与基准（Red）

- [x] 2.1 新增 `f_dbd/src/common/PayloadWrapping_test.cj`：旧写法与新写法各构造一份 8 参数（含一个 NULL 空洞）payload，用 `DefaultCodec` 编码后逐字节比较（验证：旧实现上通过，锁住载荷）
- [x] 2.2 用例：解码后再编码，两种写法的往返结果仍逐字节相等（验证：旧实现上通过）
- [x] 2.3 分配基准：`F_DBD_BENCH=1` 时重复 2000 次，打印两条路径的 `allocPerCall`（不设硬断言，GC 噪声不可控）
- [x] 2.4 `cd f_dbd && cjpm test --filter "*PayloadWrapping*"` 行为用例全绿（验证：FAILED 0）

## 3. 实现（Green）

- [x] 3.1 `DbdStatement.sqlPayload` 的 `payload.add<DataAny>(DataAny(data))` 改为 `payload.add<Data>(data)`（验证：2.1–2.2 保持通过）
- [x] 3.2 开启 `F_DBD_BENCH=1` 重跑基准（验证：打印两条路径数值，行为用例保持全绿）

## 4. 回归与契约

- [x] 4.1 `cd f_dbd && cjpm test` 连续两次全绿（验证：两次 Summary FAILED 0）
- [x] 4.2 `SqlPayload.add<T>` 签名、`DbdStatement` 公开方法无变化（验证：`git diff -- f_dbd/src | rg "^[+-].*public"` 只命中新增测试类）
- [x] 4.3 既有 `PayloadTest` 全通过（验证：按套件过滤运行）

## 5. 产物与提交

- [x] 5.1 `docs/LocalMode.md` 的 f_dbd 行回写真实热点与结果（验证：行内含 `泛型装箱` 与 `1,744`）
- [x] 5.2 镜像 `openspec/changes/optimize-f-dbd-payload-wrapping/` 到 `f_dbd/doc/spec/optimize-f-dbd-payload-wrapping/`，两份逐文件一致（验证：`diff -r` 仅差 `.openspec.yaml`）
- [x] 5.3 `openspec validate optimize-f-dbd-payload-wrapping --strict` 通过（验证：输出 `is valid`）
- [x] 5.4 提交到 `feature/local-mode-f-dbd-sql-payload`（验证：`git log -1 --stat` 只含预期文件）

## Workflow follow-up

- 推送 `feature/local-mode-f-dbd-sql-payload`，合并回 `sts/1.3.x-LocalMode`，合并后再跑 `f_dbd` 全量。
- 执行 `opsx:verify`，通过后 `opsx:archive` 并同步主规格。

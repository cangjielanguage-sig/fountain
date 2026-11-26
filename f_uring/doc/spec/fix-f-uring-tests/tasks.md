# Tasks

## 1. 失败基线取证（Red）

- [x] 1.1 在 WSL（`source cangjie.sh` + `cangjie_env 1.3.0 1.3.0`）对 `f_uring` 执行 `cjpm test`，把输出落盘为基线日志，确认失败形态为 24 个编译错误（23×`undeclared identifier 'IOUringStream'` + 1×`no matching constructor for call 'IoUringFuture'`），据此记录「修复前」证据。

## 2. 测试包补根包导入（D1）

- [x] 2.1 在 `src/tests/iouring_stream_test.cj` 增加 `import fountain::f_uring.*`，重跑 `cjpm test` 确认该文件相关的 `undeclared identifier` 错误消失（剩余错误数量下降且不再指向改文件）。
- [x] 2.2 在 `src/tests/iouring_stream_perf_test.cj` 增加 `import fountain::f_uring.*`，重跑 `cjpm test` 确认 23 个 `undeclared identifier 'IOUringStream'` 全部消失。（经核实 `iouring_stream_read_micro_perf_test.cj` 只用底层 `IoUring`，不引用根包符号，故不加导入以免产生 unused import。）
- [x] 2.3 确认所加导入不引入新的编译错误或命名冲突（`cjpm test` 输出中不出现新增 error）。

## 3. 公开 IoUringFuture 构造器（D2）

- [x] 3.1 把 `src/base/uring_future.cj` 的 `init(promise: IoUringPromise<T>)` 改为 `public init(...)`，重跑 `cjpm test` 确认 `no matching constructor for call 'IoUringFuture'` 消失、编译阶段零错误（`cjpm test --no-run` 退出码 0）。
- [x] 3.2 确认包内既有调用点（若有）无需改动即可编译通过，验证可见性放宽是纯增量。（全模块搜索确认 `IoUringFuture` 在模块内无生产构造点，编译通过即证明无既有调用方被影响。）

## 4. 运行期全绿（D3）

- [x] 4.1 跑全量 `cjpm test`，记录失败用例清单（用例名 + 断言/异常信息）；编译均通过但存在失败用例时，为每个失败用例先构造最小复现（Red）再修（Green）。（结果：TOTAL 59 / PASSED 59 / FAILED 0 / ERROR 0，无失败用例。）
- [x] 4.2 逐个修复失败用例，每修一个重跑该用例确认转绿且未影响其他用例；修复边界为「不改公开签名与既有语义」。（无可修失败项。）
- [x] 4.3 连续两次跑全量 `cjpm test` 均为全绿（排除偶发），并记录通过用例数与耗时。（两次均 59/59 PASSED。）
- [x] 4.4 补齐规格场景的用例覆盖：`testFutureCompletedState`（完成前 `isCompleted=false` / `tryGet` 为空，完成后可取到结果）与 `testFutureCancelled`（取消后 `isCancelled=true`、`get()` 抛 `IoUringException`）；RED 取证方式为临时回退 `public init` 后编译失败（`no matching constructor`），恢复后 61/61 PASSED。

## 5. 文档同步

- [x] 5.1 在 `f_uring/README.md` 的 `IoUringFuture<T>` 小节补充构造方式（`public init(promise: IoUringPromise<T>)`）与「Promise 需先注册到 ring 完成槽位」的说明，并把 `IOUringStream` 小节里「包: `fountain::f_io`」更正为 `fountain::f_uring`；确认文中的 API 名称与源码一致。
- [x] 5.2 在 `f_uring/README_en.md` 做与 5.1 对等的英文修改，确认中英两版章节结构一致。

## Workflow follow-up

- 全量回归（`cjpm test`）+ `openspec validate fix-f-uring-tests --strict` 通过后执行 `opsx:verify`，CRITICAL 清零。
- 归档变更并把最终版四件套覆盖写入 `f_uring/doc/spec/fix-f-uring-tests/`。

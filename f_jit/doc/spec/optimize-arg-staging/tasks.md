# 任务：实参暂存区（`optimize-arg-staging`）

> 纯测量/判定（`skip_specs: true`）。编号 A = Argument staging。

## A1 测量

- [x] A1.1 `LibC.malloc(8) + free`：21–39 ns/次（历史探针，与 2026-11-27 数据一致）。
- [x] A1.2 反向拷贝（n=1）：~5–10 ns。
- [x] A1.3 `JitContext.create + free`（含 8 写 + 2 原子 + malloc）：132–133 ns（TLS 合并后）。
- [x] A1.4 拆解 394 ns/参：调用点 `Array<Any>` ~170 ns、封送/记账 ~50–100 ns、
      cells ~170 ns、`invokeOff` malloc+拷贝 **21–49 ns**。

## A2 判定

- [x] A2.1 `invokeOff` 自身成本 21–49 ns < MOV（≥300 ns / 8.4%）⇒ **不做**。
- [x] A2.2 若用 `RuntimeEnv.current()` 取暂存区，每次多 300 ns TLS ⇒ 净负收益，**否决**。

## A3 收口

- [x] A3.1 `verify.md`；镜像 `f_jit/doc/spec/optimize-arg-staging/`；`openspec validate --strict`。
- [x] A3.2 归档 `2026-11-27-optimize-arg-staging`（无代码改动）。

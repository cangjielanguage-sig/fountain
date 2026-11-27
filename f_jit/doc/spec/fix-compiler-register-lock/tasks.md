# 任务：fix-compiler-register-lock

- [x] T1.1 `registerClass`：`classes.register` 与其后的方法并入、`snapCache=None` 同处一个临界区。
- [x] T1.2 `registerType` / `registerInterface`：反射注册与 `snapCache=None` 同处一个临界区。
- [x] T1.3 注释写明锁序 `this.mtx → ClassRegistry.mtx` 与反向路径不存在。
- [x] T1.4 新增 `CompilerRegistrationConcurrency_test`：4 线程 × 20 类，成对断言 + 80 次编译。
- [x] T2.1 改前对照：旧实现也能通过（窗口极窄，未复现）——已在 verify 中如实记录。
- [x] T2.2 全量零失败。
- [x] T3.1 `verify.md`；T3.2 镜像；T3.3 归档 + 提交。

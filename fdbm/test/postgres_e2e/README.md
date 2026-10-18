# PostgreSQL 真库联调（兼容入口）

夹具已抽到共享目录 `fdbm/test/e2e/`，支持 `postgres` / `mysql` 两个后端。

- 运行 PostgreSQL：`bash fdbm/test/postgres_e2e/run.sh`（等价于 `bash fdbm/test/e2e/run.sh postgres`）
- 后端矩阵、环境变量、驱动实测名与已知边界：见 [`../e2e/README.md`](../e2e/README.md)

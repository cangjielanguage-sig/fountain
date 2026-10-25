# Tasks

> 每个任务按 Red-Green-Refactor 推进；测试在 `f_jsonrpc/src/JsonRpcMacro_test.cj`。

## 1. 宏与注解

- [x] 1.1 `JsonRpcMeta` 注解（description + timeout 字符串）
- [x] 1.2 `@jsonrpc` / `@jsonrpc[topic: ...]` 宏：加 `@Bean`、枚举 public 实例方法
- [x] 1.3 `@jsonrpcmeta[...]` 语法糖
- [x] 1.4 编译期读取注解（`ClassDecl.toTokens()` 扫描），生成 description / timeout

## 2. 注册与转换

- [x] 2.1 每个方法生成 `private let _` 注册代码，方法名 `<topic>.<fn>`
- [x] 2.2 `JsonRpcRegister.instance<T>`（bean 查找）与 `getMeta<T>`（运行期反射 API）
- [x] 2.3 `JsonRpcArgs.extract`：单参数（裸值 / 单元素数组 / 命名对象）与多参数对象
- [x] 2.4 `JsonRpcArgs.toJson`：`DataFields<T>` 与 `Unit`

## 3. 测试覆盖

- [x] 3.1 注册范围：public 实例方法被注册，private / 构造函数不被注册
- [x] 3.2 单参数、多参数、缺参数、类型不符
- [x] 3.3 `Unit` 返回 `null`
- [x] 3.4 `@DataAssist` 对象参数与返回值
- [x] 3.5 meta：描述 / 超时 / 缺省 / 语法糖
- [x] 3.6 `getMeta` 反射读取
- [x] 3.7 topic 路由（`/rpc/kb` 命中、未知 topic `-32004`）

## 4. 文档与交付

- [x] 4.1 `f_jsonrpc/README.md` / `README_en.md` 增加「注解驱动注册」
- [x] 4.2 规格落盘 `f_jsonrpc/doc/spec/add-jsonrpc-macro/`
- [ ] 4.3 全量回归（`fusion_build.sh`）
- [ ] 4.4 提交、合并回 `sts/1.3.x`、推送

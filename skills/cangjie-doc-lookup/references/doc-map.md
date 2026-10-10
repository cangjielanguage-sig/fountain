# 仓颉编程语言文档地图

本文件由 `scripts/build_index.py` 自动生成，记录三个本地文档源的目录结构与文档路径。
**本副本是随技能分发的快照**：三个文档源的路径取自技能固化的 `paths.json`；在这台机器上
`python scripts/skill_paths.py check` 通过、且文档源有更新后，重新运行
`python scripts/build_index.py` 刷新本地图，使索引与固化路径一致。


## 语言特性文档

仓颉编程语言官方文档（mdBook 源码），含开发指南、工具链、中央仓库说明。

根目录：`D:\docs\work\cangjie\cangjie-doc\cangjie_docs`

共 164 个 Markdown 文档。

| 文档 | 说明 |
| ---- | ---- |
| [`CONTRIBUTING.md`](CONTRIBUTING.md) | Contributing Documents |
| [`CONTRIBUTING_zh.md`](CONTRIBUTING_zh.md) | 贡献文档 |
| [`docs/central-repo/source_zh_cn/agreement/agreement.md`](docs/central-repo/source_zh_cn/agreement/agreement.md) | 仓颉中心仓用户使用协议 |
| [`docs/central-repo/source_zh_cn/agreement/privacy.md`](docs/central-repo/source_zh_cn/agreement/privacy.md) | 仓颉中心仓网站隐私政策 |
| [`docs/central-repo/source_zh_cn/agreement/safety.md`](docs/central-repo/source_zh_cn/agreement/safety.md) | 仓颉中心仓平台安全策略 |
| [`docs/central-repo/source_zh_cn/appendix/api.md`](docs/central-repo/source_zh_cn/appendix/api.md) | 中心仓通信规格 |
| [`docs/central-repo/source_zh_cn/appendix/meta_data.md`](docs/central-repo/source_zh_cn/appendix/meta_data.md) | 中心仓元数据规格 |
| [`docs/central-repo/source_zh_cn/artifact.md`](docs/central-repo/source_zh_cn/artifact.md) | 中心仓制品规格 |
| [`docs/central-repo/source_zh_cn/client/config.md`](docs/central-repo/source_zh_cn/client/config.md) | 中心仓客户端配置 |
| [`docs/central-repo/source_zh_cn/client/download.md`](docs/central-repo/source_zh_cn/client/download.md) | 制品包使用 |
| [`docs/central-repo/source_zh_cn/client/upload.md`](docs/central-repo/source_zh_cn/client/upload.md) | 制品包发布 |
| [`docs/central-repo/source_zh_cn/contact.md`](docs/central-repo/source_zh_cn/contact.md) | 联系方式 |
| [`docs/central-repo/source_zh_cn/overview.md`](docs/central-repo/source_zh_cn/overview.md) | 概述 |
| [`docs/central-repo/source_zh_cn/website_page.md`](docs/central-repo/source_zh_cn/website_page.md) | 中心仓官网 |
| [`docs/central-repo/summary_central_repository.md`](docs/central-repo/summary_central_repository.md) | - [概述](source_zh_cn/overview.md) |
| [`docs/central-repo/summary_central_repository_EN.md`](docs/central-repo/summary_central_repository_EN.md) | - [Overview](source_en/overview.md) |
| [`docs/dev-guide/source_zh_cn/Appendix/cangjie_package_compatibility.md`](docs/dev-guide/source_zh_cn/Appendix/cangjie_package_compatibility.md) | 仓颉包兼容性检查 |
| [`docs/dev-guide/source_zh_cn/Appendix/cjo_artifacts.md`](docs/dev-guide/source_zh_cn/Appendix/cjo_artifacts.md) | cjo 产物说明 |
| [`docs/dev-guide/source_zh_cn/Appendix/compile_options.md`](docs/dev-guide/source_zh_cn/Appendix/compile_options.md) | `cjc` 编译选项 |
| [`docs/dev-guide/source_zh_cn/Appendix/keyword.md`](docs/dev-guide/source_zh_cn/Appendix/keyword.md) | 关键字 |
| [`docs/dev-guide/source_zh_cn/Appendix/linux_toolchain_install.md`](docs/dev-guide/source_zh_cn/Appendix/linux_toolchain_install.md) | Linux 版本工具链的支持与安装 |
| [`docs/dev-guide/source_zh_cn/Appendix/operator.md`](docs/dev-guide/source_zh_cn/Appendix/operator.md) | 操作符 |
| [`docs/dev-guide/source_zh_cn/Appendix/operator_function.md`](docs/dev-guide/source_zh_cn/Appendix/operator_function.md) | 操作符函数 |
| [`docs/dev-guide/source_zh_cn/Appendix/runtime_env.md`](docs/dev-guide/source_zh_cn/Appendix/runtime_env.md) | runtime 环境变量使用手册 |
| [`docs/dev-guide/source_zh_cn/Appendix/tokenkind_type.md`](docs/dev-guide/source_zh_cn/Appendix/tokenkind_type.md) | TokenKind 类型 |
| [`docs/dev-guide/source_zh_cn/basic_data_type/array.md`](docs/dev-guide/source_zh_cn/basic_data_type/array.md) | 数组类型 |
| [`docs/dev-guide/source_zh_cn/basic_data_type/basic_operators.md`](docs/dev-guide/source_zh_cn/basic_data_type/basic_operators.md) | 基本操作符 |
| [`docs/dev-guide/source_zh_cn/basic_data_type/bool.md`](docs/dev-guide/source_zh_cn/basic_data_type/bool.md) | 布尔类型 |
| [`docs/dev-guide/source_zh_cn/basic_data_type/characters.md`](docs/dev-guide/source_zh_cn/basic_data_type/characters.md) | 字符类型 |
| [`docs/dev-guide/source_zh_cn/basic_data_type/float.md`](docs/dev-guide/source_zh_cn/basic_data_type/float.md) | 浮点类型 |
| [`docs/dev-guide/source_zh_cn/basic_data_type/integer.md`](docs/dev-guide/source_zh_cn/basic_data_type/integer.md) | 整数类型 |
| [`docs/dev-guide/source_zh_cn/basic_data_type/nothing.md`](docs/dev-guide/source_zh_cn/basic_data_type/nothing.md) | Nothing 类型 |
| [`docs/dev-guide/source_zh_cn/basic_data_type/range.md`](docs/dev-guide/source_zh_cn/basic_data_type/range.md) | 区间类型 |
| [`docs/dev-guide/source_zh_cn/basic_data_type/strings.md`](docs/dev-guide/source_zh_cn/basic_data_type/strings.md) | 字符串类型 |
| [`docs/dev-guide/source_zh_cn/basic_data_type/tuple.md`](docs/dev-guide/source_zh_cn/basic_data_type/tuple.md) | 元组类型 |
| [`docs/dev-guide/source_zh_cn/basic_data_type/unit.md`](docs/dev-guide/source_zh_cn/basic_data_type/unit.md) | Unit 类型 |
| [`docs/dev-guide/source_zh_cn/Basic_IO/basic_IO_overview.md`](docs/dev-guide/source_zh_cn/Basic_IO/basic_IO_overview.md) | I/O 流概述 |
| [`docs/dev-guide/source_zh_cn/Basic_IO/basic_IO_process_stream.md`](docs/dev-guide/source_zh_cn/Basic_IO/basic_IO_process_stream.md) | I/O 处理流 |
| [`docs/dev-guide/source_zh_cn/Basic_IO/basic_IO_source_stream.md`](docs/dev-guide/source_zh_cn/Basic_IO/basic_IO_source_stream.md) | I/O 节点流 |
| [`docs/dev-guide/source_zh_cn/basic_programming_concepts/expression.md`](docs/dev-guide/source_zh_cn/basic_programming_concepts/expression.md) | 表达式 |
| [`docs/dev-guide/source_zh_cn/basic_programming_concepts/function.md`](docs/dev-guide/source_zh_cn/basic_programming_concepts/function.md) | 函数 |
| [`docs/dev-guide/source_zh_cn/basic_programming_concepts/identifier.md`](docs/dev-guide/source_zh_cn/basic_programming_concepts/identifier.md) | 标识符 |
| [`docs/dev-guide/source_zh_cn/basic_programming_concepts/program_structure.md`](docs/dev-guide/source_zh_cn/basic_programming_concepts/program_structure.md) | 程序结构 |
| [`docs/dev-guide/source_zh_cn/class_and_interface/class.md`](docs/dev-guide/source_zh_cn/class_and_interface/class.md) | 类 |
| [`docs/dev-guide/source_zh_cn/class_and_interface/interface.md`](docs/dev-guide/source_zh_cn/class_and_interface/interface.md) | 接口 |
| [`docs/dev-guide/source_zh_cn/class_and_interface/prop.md`](docs/dev-guide/source_zh_cn/class_and_interface/prop.md) | 属性 |
| [`docs/dev-guide/source_zh_cn/class_and_interface/subtype.md`](docs/dev-guide/source_zh_cn/class_and_interface/subtype.md) | 子类型关系 |
| [`docs/dev-guide/source_zh_cn/class_and_interface/typecast.md`](docs/dev-guide/source_zh_cn/class_and_interface/typecast.md) | 类型转换 |
| [`docs/dev-guide/source_zh_cn/collections/collection_arraylist.md`](docs/dev-guide/source_zh_cn/collections/collection_arraylist.md) | ArrayList |
| [`docs/dev-guide/source_zh_cn/collections/collection_hashmap.md`](docs/dev-guide/source_zh_cn/collections/collection_hashmap.md) | HashMap |
| [`docs/dev-guide/source_zh_cn/collections/collection_hashset.md`](docs/dev-guide/source_zh_cn/collections/collection_hashset.md) | HashSet |
| [`docs/dev-guide/source_zh_cn/collections/collection_iterable_collections.md`](docs/dev-guide/source_zh_cn/collections/collection_iterable_collections.md) | Iterable 和 Collections |
| [`docs/dev-guide/source_zh_cn/collections/collection_overview.md`](docs/dev-guide/source_zh_cn/collections/collection_overview.md) | 基础 Collection 类型概述 |
| [`docs/dev-guide/source_zh_cn/compile_and_build/cjc_usage.md`](docs/dev-guide/source_zh_cn/compile_and_build/cjc_usage.md) | `cjc` 使用 |
| [`docs/dev-guide/source_zh_cn/compile_and_build/cjpm_usage.md`](docs/dev-guide/source_zh_cn/compile_and_build/cjpm_usage.md) | `cjpm` 介绍 |
| [`docs/dev-guide/source_zh_cn/compile_and_build/conditional_compilation.md`](docs/dev-guide/source_zh_cn/compile_and_build/conditional_compilation.md) | 条件编译 |
| [`docs/dev-guide/source_zh_cn/compile_and_build/cross_compilation.md`](docs/dev-guide/source_zh_cn/compile_and_build/cross_compilation.md) | 交叉编译 |
| [`docs/dev-guide/source_zh_cn/concurrency/concurrency_overview.md`](docs/dev-guide/source_zh_cn/concurrency/concurrency_overview.md) | 并发概述 |
| [`docs/dev-guide/source_zh_cn/concurrency/create_thread.md`](docs/dev-guide/source_zh_cn/concurrency/create_thread.md) | 创建线程 |
| [`docs/dev-guide/source_zh_cn/concurrency/sleep.md`](docs/dev-guide/source_zh_cn/concurrency/sleep.md) | 线程睡眠指定时长 sleep |
| [`docs/dev-guide/source_zh_cn/concurrency/sync.md`](docs/dev-guide/source_zh_cn/concurrency/sync.md) | 同步机制 |
| [`docs/dev-guide/source_zh_cn/concurrency/terminal_thread.md`](docs/dev-guide/source_zh_cn/concurrency/terminal_thread.md) | 终止线程 |
| [`docs/dev-guide/source_zh_cn/concurrency/use_thread.md`](docs/dev-guide/source_zh_cn/concurrency/use_thread.md) | 访问线程 |
| [`docs/dev-guide/source_zh_cn/deploy_and_run/run.md`](docs/dev-guide/source_zh_cn/deploy_and_run/run.md) | 运行仓颉可执行程序 |
| [`docs/dev-guide/source_zh_cn/deploy_and_run/runtime_deploy.md`](docs/dev-guide/source_zh_cn/deploy_and_run/runtime_deploy.md) | 部署仓颉运行时 |
| [`docs/dev-guide/source_zh_cn/enum_and_pattern_match/enum.md`](docs/dev-guide/source_zh_cn/enum_and_pattern_match/enum.md) | 枚举类型 |
| [`docs/dev-guide/source_zh_cn/enum_and_pattern_match/match.md`](docs/dev-guide/source_zh_cn/enum_and_pattern_match/match.md) | match 表达式 |
| [`docs/dev-guide/source_zh_cn/enum_and_pattern_match/option_type.md`](docs/dev-guide/source_zh_cn/enum_and_pattern_match/option_type.md) | Option 类型 |
| [`docs/dev-guide/source_zh_cn/enum_and_pattern_match/other.md`](docs/dev-guide/source_zh_cn/enum_and_pattern_match/other.md) | 其他使用模式的地方 |
| [`docs/dev-guide/source_zh_cn/enum_and_pattern_match/pattern_overview.md`](docs/dev-guide/source_zh_cn/enum_and_pattern_match/pattern_overview.md) | 模式概述 |
| [`docs/dev-guide/source_zh_cn/enum_and_pattern_match/pattern_refutability.md`](docs/dev-guide/source_zh_cn/enum_and_pattern_match/pattern_refutability.md) | 模式的 Refutability |
| [`docs/dev-guide/source_zh_cn/error_handle/common_runtime_exceptions.md`](docs/dev-guide/source_zh_cn/error_handle/common_runtime_exceptions.md) | 常见运行时异常 |
| [`docs/dev-guide/source_zh_cn/error_handle/exception_overview.md`](docs/dev-guide/source_zh_cn/error_handle/exception_overview.md) | 定义异常 |
| [`docs/dev-guide/source_zh_cn/error_handle/handle.md`](docs/dev-guide/source_zh_cn/error_handle/handle.md) | throw 和处理异常 |
| [`docs/dev-guide/source_zh_cn/error_handle/use_option.md`](docs/dev-guide/source_zh_cn/error_handle/use_option.md) | 使用 Option |
| [`docs/dev-guide/source_zh_cn/extension/access_rules.md`](docs/dev-guide/source_zh_cn/extension/access_rules.md) | 访问规则 |
| [`docs/dev-guide/source_zh_cn/extension/direct_extension.md`](docs/dev-guide/source_zh_cn/extension/direct_extension.md) | 直接扩展 |
| [`docs/dev-guide/source_zh_cn/extension/extend_overview.md`](docs/dev-guide/source_zh_cn/extension/extend_overview.md) | 扩展概述 |
| [`docs/dev-guide/source_zh_cn/extension/interface_extension.md`](docs/dev-guide/source_zh_cn/extension/interface_extension.md) | 接口扩展 |
| [`docs/dev-guide/source_zh_cn/FFI/cangjie-c.md`](docs/dev-guide/source_zh_cn/FFI/cangjie-c.md) | 仓颉-C 互操作 |
| [`docs/dev-guide/source_zh_cn/first_understanding/basic.md`](docs/dev-guide/source_zh_cn/first_understanding/basic.md) | 初识仓颉语言 |
| [`docs/dev-guide/source_zh_cn/first_understanding/hello_world.md`](docs/dev-guide/source_zh_cn/first_understanding/hello_world.md) | 运行第一个仓颉程序 |
| [`docs/dev-guide/source_zh_cn/first_understanding/install.md`](docs/dev-guide/source_zh_cn/first_understanding/install.md) | 安装仓颉工具链 |
| [`docs/dev-guide/source_zh_cn/function/call_functions.md`](docs/dev-guide/source_zh_cn/function/call_functions.md) | 调用函数 |
| [`docs/dev-guide/source_zh_cn/function/closure.md`](docs/dev-guide/source_zh_cn/function/closure.md) | 闭包 |
| [`docs/dev-guide/source_zh_cn/function/const_func_and_eval.md`](docs/dev-guide/source_zh_cn/function/const_func_and_eval.md) | const 函数和常量求值 |
| [`docs/dev-guide/source_zh_cn/function/define_functions.md`](docs/dev-guide/source_zh_cn/function/define_functions.md) | 定义函数 |
| [`docs/dev-guide/source_zh_cn/function/first_class_citizen.md`](docs/dev-guide/source_zh_cn/function/first_class_citizen.md) | 函数类型 |
| [`docs/dev-guide/source_zh_cn/function/function_call_desugar.md`](docs/dev-guide/source_zh_cn/function/function_call_desugar.md) | 函数调用语法糖 |
| [`docs/dev-guide/source_zh_cn/function/function_overloading.md`](docs/dev-guide/source_zh_cn/function/function_overloading.md) | 函数重载 |
| [`docs/dev-guide/source_zh_cn/function/lambda.md`](docs/dev-guide/source_zh_cn/function/lambda.md) | Lambda 表达式 |
| [`docs/dev-guide/source_zh_cn/function/nested_functions.md`](docs/dev-guide/source_zh_cn/function/nested_functions.md) | 嵌套函数 |
| [`docs/dev-guide/source_zh_cn/function/operator_overloading.md`](docs/dev-guide/source_zh_cn/function/operator_overloading.md) | 操作符重载 |
| [`docs/dev-guide/source_zh_cn/generic/generic_class.md`](docs/dev-guide/source_zh_cn/generic/generic_class.md) | 泛型类 |
| [`docs/dev-guide/source_zh_cn/generic/generic_constraint.md`](docs/dev-guide/source_zh_cn/generic/generic_constraint.md) | 泛型约束 |
| [`docs/dev-guide/source_zh_cn/generic/generic_enum.md`](docs/dev-guide/source_zh_cn/generic/generic_enum.md) | 泛型枚举 |
| [`docs/dev-guide/source_zh_cn/generic/generic_function.md`](docs/dev-guide/source_zh_cn/generic/generic_function.md) | 泛型函数 |
| [`docs/dev-guide/source_zh_cn/generic/generic_interface.md`](docs/dev-guide/source_zh_cn/generic/generic_interface.md) | 泛型接口 |
| [`docs/dev-guide/source_zh_cn/generic/generic_overview.md`](docs/dev-guide/source_zh_cn/generic/generic_overview.md) | 泛型概述 |
| [`docs/dev-guide/source_zh_cn/generic/generic_struct.md`](docs/dev-guide/source_zh_cn/generic/generic_struct.md) | 泛型结构体 |
| [`docs/dev-guide/source_zh_cn/generic/generic_subtype.md`](docs/dev-guide/source_zh_cn/generic/generic_subtype.md) | 泛型类型的子类型关系 |
| [`docs/dev-guide/source_zh_cn/generic/typealias.md`](docs/dev-guide/source_zh_cn/generic/typealias.md) | 类型别名 |
| [`docs/dev-guide/source_zh_cn/Macro/builtin_compilation_flags.md`](docs/dev-guide/source_zh_cn/Macro/builtin_compilation_flags.md) | 内置编译标记 |
| [`docs/dev-guide/source_zh_cn/Macro/compiling_error_reporting_and_debugging.md`](docs/dev-guide/source_zh_cn/Macro/compiling_error_reporting_and_debugging.md) | 编译、报错与调试 |
| [`docs/dev-guide/source_zh_cn/Macro/defining_and_importing_macro_package.md`](docs/dev-guide/source_zh_cn/Macro/defining_and_importing_macro_package.md) | 宏包定义和导入 |
| [`docs/dev-guide/source_zh_cn/Macro/implementation_of_macros.md`](docs/dev-guide/source_zh_cn/Macro/implementation_of_macros.md) | 宏的实现 |
| [`docs/dev-guide/source_zh_cn/Macro/macro_introduction.md`](docs/dev-guide/source_zh_cn/Macro/macro_introduction.md) | 宏的简介 |
| [`docs/dev-guide/source_zh_cn/Macro/practical_case.md`](docs/dev-guide/source_zh_cn/Macro/practical_case.md) | 实用案例 |
| [`docs/dev-guide/source_zh_cn/Macro/syntax_node.md`](docs/dev-guide/source_zh_cn/Macro/syntax_node.md) | 语法节点 |
| [`docs/dev-guide/source_zh_cn/Macro/Tokens_types_and_quote_expressions.md`](docs/dev-guide/source_zh_cn/Macro/Tokens_types_and_quote_expressions.md) | Tokens 相关类型和 quote 表达式 |
| [`docs/dev-guide/source_zh_cn/multiplatform/cangjie-android-Java.md`](docs/dev-guide/source_zh_cn/multiplatform/cangjie-android-Java.md) | 仓颉-Java 互操作 |
| [`docs/dev-guide/source_zh_cn/multiplatform/cangjie-ios-objc.md`](docs/dev-guide/source_zh_cn/multiplatform/cangjie-ios-objc.md) | 仓颉-ObjC 互操作 |
| [`docs/dev-guide/source_zh_cn/multiplatform/common_platform.md`](docs/dev-guide/source_zh_cn/multiplatform/common_platform.md) | 跨平台 |
| [`docs/dev-guide/source_zh_cn/Net/net_http.md`](docs/dev-guide/source_zh_cn/Net/net_http.md) | HTTP 编程 |
| [`docs/dev-guide/source_zh_cn/Net/net_overview.md`](docs/dev-guide/source_zh_cn/Net/net_overview.md) | 网络编程概述 |
| [`docs/dev-guide/source_zh_cn/Net/net_socket.md`](docs/dev-guide/source_zh_cn/Net/net_socket.md) | Socket 编程 |
| [`docs/dev-guide/source_zh_cn/Net/net_websocket.md`](docs/dev-guide/source_zh_cn/Net/net_websocket.md) | WebSocket 编程 |
| [`docs/dev-guide/source_zh_cn/package/entry.md`](docs/dev-guide/source_zh_cn/package/entry.md) | 程序入口 |
| [`docs/dev-guide/source_zh_cn/package/import.md`](docs/dev-guide/source_zh_cn/package/import.md) | 包的导入 |
| [`docs/dev-guide/source_zh_cn/package/package_module_management.md`](docs/dev-guide/source_zh_cn/package/package_module_management.md) | 包和模块管理 |
| [`docs/dev-guide/source_zh_cn/package/package_name.md`](docs/dev-guide/source_zh_cn/package/package_name.md) | 包的声明 |
| [`docs/dev-guide/source_zh_cn/package/package_overview.md`](docs/dev-guide/source_zh_cn/package/package_overview.md) | 包的概述 |
| [`docs/dev-guide/source_zh_cn/package/toplevel_access.md`](docs/dev-guide/source_zh_cn/package/toplevel_access.md) | 顶层声明的可见性 |
| [`docs/dev-guide/source_zh_cn/reflect_and_annotation/anno.md`](docs/dev-guide/source_zh_cn/reflect_and_annotation/anno.md) | 注解 |
| [`docs/dev-guide/source_zh_cn/reflect_and_annotation/dynamic_feature.md`](docs/dev-guide/source_zh_cn/reflect_and_annotation/dynamic_feature.md) | 动态特性 |
| [`docs/dev-guide/source_zh_cn/struct/create_instance.md`](docs/dev-guide/source_zh_cn/struct/create_instance.md) | 创建 struct 实例 |
| [`docs/dev-guide/source_zh_cn/struct/define_struct.md`](docs/dev-guide/source_zh_cn/struct/define_struct.md) | 定义 struct 类型 |
| [`docs/dev-guide/source_zh_cn/struct/mut.md`](docs/dev-guide/source_zh_cn/struct/mut.md) | mut 函数 |
| [`docs/dev-guide/summary_cjnative.md`](docs/dev-guide/summary_cjnative.md) | - [初识仓颉语言]() |
| [`docs/dev-guide/summary_cjnative_EN.md`](docs/dev-guide/summary_cjnative_EN.md) | - [Getting Started with Cangjie Language]() |
| [`docs/tools/source_zh_cn/cangjie-language-server/LSPServer_manual.md`](docs/tools/source_zh_cn/cangjie-language-server/LSPServer_manual.md) | 语言服务器工具 |
| [`docs/tools/source_zh_cn/cmd-tools/chir_dis_manual.md`](docs/tools/source_zh_cn/cmd-tools/chir_dis_manual.md) | CHIR 反序列化工具 |
| [`docs/tools/source_zh_cn/cmd-tools/cj-c2cj-translation-rules.md`](docs/tools/source_zh_cn/cmd-tools/cj-c2cj-translation-rules.md) | C 语言转换到仓颉胶水代码的规则 |
| [`docs/tools/source_zh_cn/cmd-tools/cj-dts2cj-translation-rules.md`](docs/tools/source_zh_cn/cmd-tools/cj-dts2cj-translation-rules.md) | ArkTS 三方模块生成仓颉胶水代码的转换规则 |
| [`docs/tools/source_zh_cn/cmd-tools/cjcompat_manual.md`](docs/tools/source_zh_cn/cmd-tools/cjcompat_manual.md) | 兼容检查工具 |
| [`docs/tools/source_zh_cn/cmd-tools/cjcov_manual.md`](docs/tools/source_zh_cn/cmd-tools/cjcov_manual.md) | 覆盖率统计工具 |
| [`docs/tools/source_zh_cn/cmd-tools/cjdb_manual.md`](docs/tools/source_zh_cn/cmd-tools/cjdb_manual.md) | 调试工具 |
| [`docs/tools/source_zh_cn/cmd-tools/cjfmt_manual.md`](docs/tools/source_zh_cn/cmd-tools/cjfmt_manual.md) | 格式化工具 |
| [`docs/tools/source_zh_cn/cmd-tools/cjlint_manual.md`](docs/tools/source_zh_cn/cmd-tools/cjlint_manual.md) | 静态检查工具 |
| [`docs/tools/source_zh_cn/cmd-tools/cjpm_manual.md`](docs/tools/source_zh_cn/cmd-tools/cjpm_manual.md) | 项目管理工具 |
| [`docs/tools/source_zh_cn/cmd-tools/cjprof_manual.md`](docs/tools/source_zh_cn/cmd-tools/cjprof_manual.md) | 性能分析工具 |
| [`docs/tools/source_zh_cn/cmd-tools/cjtrace_recover_manual.md`](docs/tools/source_zh_cn/cmd-tools/cjtrace_recover_manual.md) | 异常堆栈信息还原工具 |
| [`docs/tools/source_zh_cn/cmd-tools/HLE_manual.md`](docs/tools/source_zh_cn/cmd-tools/HLE_manual.md) | HLE 工具 |
| [`docs/tools/source_zh_cn/command_line_overview.md`](docs/tools/source_zh_cn/command_line_overview.md) | 工具使用指南 |
| [`docs/tools/source_zh_cn/library_evolution_spec/Chapter_00_Cover.md`](docs/tools/source_zh_cn/library_evolution_spec/Chapter_00_Cover.md) | 封面 |
| [`docs/tools/source_zh_cn/library_evolution_spec/Chapter_01_Change_Log.md`](docs/tools/source_zh_cn/library_evolution_spec/Chapter_01_Change_Log.md) | 修订记录 |
| [`docs/tools/source_zh_cn/library_evolution_spec/Chapter_02_Overview.md`](docs/tools/source_zh_cn/library_evolution_spec/Chapter_02_Overview.md) | 概述 |
| [`docs/tools/source_zh_cn/library_evolution_spec/Chapter_03_Rules.md`](docs/tools/source_zh_cn/library_evolution_spec/Chapter_03_Rules.md) | 兼容性规则 |
| [`docs/tools/source_zh_cn/library_evolution_spec/Summary.md`](docs/tools/source_zh_cn/library_evolution_spec/Summary.md) | 目录 |
| [`docs/tools/summary_cjnative.md`](docs/tools/summary_cjnative.md) | - [工具使用指南](source_zh_cn/command_line_overview.md) |
| [`docs/tools/summary_cjnative_EN.md`](docs/tools/summary_cjnative_EN.md) | - [Tool Usage Guide](source_en/command_line_overview.md) |
| [`README.md`](README.md) | Cangjie Programming Language Documentation |
| [`README_zh.md`](README_zh.md) | 仓颉编程语言文档 |
| [`release-notes/cangjie-1.1.0.alpha.33-release-notes.md`](release-notes/cangjie-1.1.0.alpha.33-release-notes.md) | Cangjie 1.1.0.alpha.33 Release Notes |
| [`release-notes/cangjie-1.1.0.alpha.40-release-notes.md`](release-notes/cangjie-1.1.0.alpha.40-release-notes.md) | Cangjie 1.1.0.alpha.40 Release Notes |
| [`release-notes/cangjie-1.1.0.alpha.41-release-notes.md`](release-notes/cangjie-1.1.0.alpha.41-release-notes.md) | Cangjie 1.1.0.alpha.41 Release Notes |
| [`release-notes/cangjie-1.1.0.alpha.42-release-notes.md`](release-notes/cangjie-1.1.0.alpha.42-release-notes.md) | Cangjie 1.1.0.alpha.42 Release Notes |
| [`release-notes/cangjie-1.1.0.alpha.50-release-notes.md`](release-notes/cangjie-1.1.0.alpha.50-release-notes.md) | Cangjie 1.1.0.alpha.50 Release Notes |
| [`release-notes/cangjie-1.1.0.alpha.51-release-notes.md`](release-notes/cangjie-1.1.0.alpha.51-release-notes.md) | Cangjie 1.1.0.alpha.51 Release Notes |
| [`release-notes/cangjie-1.1.0.alpha.52-release-notes.md`](release-notes/cangjie-1.1.0.alpha.52-release-notes.md) | Cangjie 1.1.0.alpha.52 Release Notes |
| [`release-notes/cangjie-1.1.0.alpha.53-release-notes.md`](release-notes/cangjie-1.1.0.alpha.53-release-notes.md) | Cangjie 1.1.0.alpha.53 Release Notes |
| [`release-notes/cangjie-1.1.0.alpha.60-release-notes.md`](release-notes/cangjie-1.1.0.alpha.60-release-notes.md) | Cangjie 1.1.0.alpha.60 Release Notes |
| [`release-notes/cangjie-1.1.0.alpha.61-release-notes.md`](release-notes/cangjie-1.1.0.alpha.61-release-notes.md) | Cangjie 1.1.0.alpha.61 Release Notes |
| [`release-notes/cangjie-release-notes-template.md`](release-notes/cangjie-release-notes-template.md) | Cangjie Release Notes |


## 标准库文档

仓颉编程语言标准库（std）API 文档，按包组织。

根目录：`D:\docs\work\cangjie\projects\cangjie_runtime\std\doc\libs\std`

共 248 个 Markdown 文档。

| 文档 | 说明 |
| ---- | ---- |
| [`argopt/argopt_package_api/argopt_package_classes.md`](argopt/argopt_package_api/argopt_package_classes.md) | 类 |
| [`argopt/argopt_package_api/argopt_package_enums.md`](argopt/argopt_package_api/argopt_package_enums.md) | 枚举 |
| [`argopt/argopt_package_api/argopt_package_exception.md`](argopt/argopt_package_api/argopt_package_exception.md) | 异常 |
| [`argopt/argopt_package_api/argopt_package_function.md`](argopt/argopt_package_api/argopt_package_function.md) | 函数 |
| [`argopt/argopt_package_api/argopt_package_struct.md`](argopt/argopt_package_api/argopt_package_struct.md) | 结构体 |
| [`argopt/argopt_package_overview.md`](argopt/argopt_package_overview.md) | std.argopt |
| [`argopt/argopt_samples/argument_parse.md`](argopt/argopt_samples/argument_parse.md) | 命令行解析 |
| [`argopt/argopt_samples/long_argument_parse.md`](argopt/argopt_samples/long_argument_parse.md) | 长命令行参数解析 <sup>(deprecated)</sup> |
| [`argopt/argopt_samples/short_argument_parse.md`](argopt/argopt_samples/short_argument_parse.md) | 短命令行参数解析 <sup>(deprecated)</sup> |
| [`ast/ast_package_api/ast_package_classes.md`](ast/ast_package_api/ast_package_classes.md) | 类 |
| [`ast/ast_package_api/ast_package_enums.md`](ast/ast_package_api/ast_package_enums.md) | 枚举 |
| [`ast/ast_package_api/ast_package_exceptions.md`](ast/ast_package_api/ast_package_exceptions.md) | 异常类 |
| [`ast/ast_package_api/ast_package_funcs.md`](ast/ast_package_api/ast_package_funcs.md) | 函数 |
| [`ast/ast_package_api/ast_package_interfaces.md`](ast/ast_package_api/ast_package_interfaces.md) | 接口 |
| [`ast/ast_package_api/ast_package_structs.md`](ast/ast_package_api/ast_package_structs.md) | 结构体 |
| [`ast/ast_package_overview.md`](ast/ast_package_overview.md) | std.ast |
| [`ast/ast_samples/context.md`](ast/ast_samples/context.md) | Macro With Context |
| [`ast/ast_samples/dump.md`](ast/ast_samples/dump.md) | 语法树节点打印 |
| [`ast/ast_samples/operate.md`](ast/ast_samples/operate.md) | 操作 AST 对象示例 |
| [`ast/ast_samples/parse.md`](ast/ast_samples/parse.md) | 将仓颉源码解析为 AST 对象示例 |
| [`ast/ast_samples/report.md`](ast/ast_samples/report.md) | 自定义报错接口 |
| [`ast/ast_samples/traverse.md`](ast/ast_samples/traverse.md) | 自定义访问函数遍历 AST 对象示例 |
| [`binary/binary_package_api/binary_package_interfaces.md`](binary/binary_package_api/binary_package_interfaces.md) | 接口 |
| [`binary/binary_package_overview.md`](binary/binary_package_overview.md) | std.binary |
| [`collection/collection_package_api/collection_package_class.md`](collection/collection_package_api/collection_package_class.md) | 类 |
| [`collection/collection_package_api/collection_package_exception.md`](collection/collection_package_api/collection_package_exception.md) | 异常 |
| [`collection/collection_package_api/collection_package_function.md`](collection/collection_package_api/collection_package_function.md) | 函数 |
| [`collection/collection_package_api/collection_package_interface.md`](collection/collection_package_api/collection_package_interface.md) | 接口 |
| [`collection/collection_package_overview.md`](collection/collection_package_overview.md) | std.collection |
| [`collection/collection_package_samples/sample_arraylist_add.md`](collection/collection_package_samples/sample_arraylist_add.md) | ArrayList 的 add 函数 |
| [`collection/collection_package_samples/sample_arraylist_get_set.md`](collection/collection_package_samples/sample_arraylist_get_set.md) | ArrayList 的 get/set 函数 |
| [`collection/collection_package_samples/sample_arraylist_remove_clear_slice.md`](collection/collection_package_samples/sample_arraylist_remove_clear_slice.md) | ArrayList 的 remove/clear/slice 函数 |
| [`collection/collection_package_samples/sample_hashmap_add_remove_clear.md`](collection/collection_package_samples/sample_hashmap_add_remove_clear.md) | HashMap 的 add/remove/clear 函数 |
| [`collection/collection_package_samples/sample_hashmap_get_add_contains.md`](collection/collection_package_samples/sample_hashmap_get_add_contains.md) | HashMap 的 get/add/contains 函数 |
| [`collection/collection_package_samples/sample_hashset_add_iterator_remove.md`](collection/collection_package_samples/sample_hashset_add_iterator_remove.md) | HashSet 的 add/iterator/remove 函数 |
| [`collection/collection_package_samples/sample_iterator.md`](collection/collection_package_samples/sample_iterator.md) | 迭代器操作函数 |
| [`collection/collection_package_samples/sample_treeset_add_iterator_remove.md`](collection/collection_package_samples/sample_treeset_add_iterator_remove.md) | TreeSet 的 add/iterator/remove 函数 |
| [`collection_concurrent/collection_concurrent_package_api/collection_concurrent_class.md`](collection_concurrent/collection_concurrent_package_api/collection_concurrent_class.md) | 类 |
| [`collection_concurrent/collection_concurrent_package_api/collection_concurrent_interface.md`](collection_concurrent/collection_concurrent_package_api/collection_concurrent_interface.md) | 接口 |
| [`collection_concurrent/collection_concurrent_package_api/collection_concurrent_types.md`](collection_concurrent/collection_concurrent_package_api/collection_concurrent_types.md) | 类型别名 |
| [`collection_concurrent/collection_concurrent_package_overview.md`](collection_concurrent/collection_concurrent_package_overview.md) | std.collection.concurrent |
| [`collection_concurrent/collection_concurrent_samples/sample_concurrent_linked_queue.md`](collection_concurrent/collection_concurrent_samples/sample_concurrent_linked_queue.md) | ConcurrentLinkedQueue 使用示例 |
| [`collection_concurrent/collection_concurrent_samples/sample_concurrenthashmap.md`](collection_concurrent/collection_concurrent_samples/sample_concurrenthashmap.md) | ConcurrentHashMap 使用示例 |
| [`console/console_package_api/console_package_class.md`](console/console_package_api/console_package_class.md) | 类 |
| [`console/console_package_overview.md`](console/console_package_overview.md) | std.console<sup>(deprecated)</sup> |
| [`console/console_samples/console_sample.md`](console/console_samples/console_sample.md) | Console 示例 |
| [`convert/convert_package_api/convert_package_interfaces.md`](convert/convert_package_api/convert_package_interfaces.md) | 接口 |
| [`convert/convert_package_overview.md`](convert/convert_package_overview.md) | std.convert |
| [`convert/convert_samples/convert_samples.md`](convert/convert_samples/convert_samples.md) | convert 包使用示例 |
| [`core/core_package_api/core_package_classes.md`](core/core_package_api/core_package_classes.md) | 类 |
| [`core/core_package_api/core_package_enums.md`](core/core_package_api/core_package_enums.md) | 枚举 |
| [`core/core_package_api/core_package_exceptions.md`](core/core_package_api/core_package_exceptions.md) | 异常类 |
| [`core/core_package_api/core_package_funcs.md`](core/core_package_api/core_package_funcs.md) | 函数 |
| [`core/core_package_api/core_package_interfaces.md`](core/core_package_api/core_package_interfaces.md) | 接口 |
| [`core/core_package_api/core_package_intrinsics.md`](core/core_package_api/core_package_intrinsics.md) | 内置类型 |
| [`core/core_package_api/core_package_structs.md`](core/core_package_api/core_package_structs.md) | 结构体 |
| [`core/core_package_api/core_package_types.md`](core/core_package_api/core_package_types.md) | 类型别名 |
| [`core/core_package_overview.md`](core/core_package_overview.md) | std.core |
| [`core/core_samples/core_cstring_sample.md`](core/core_samples/core_cstring_sample.md) | 使用 CString 与 C 代码交互示例 |
| [`core/core_samples/core_spawn_sample.md`](core/core_samples/core_spawn_sample.md) | 仓颉并发编程示例 |
| [`crypto/cipher/cipher_package_api/cipher_package_interfaces.md`](crypto/cipher/cipher_package_api/cipher_package_interfaces.md) | 接口 |
| [`crypto/cipher/cipher_package_overview.md`](crypto/cipher/cipher_package_overview.md) | std.crypto.cipher |
| [`crypto/digest/digest_package_api/digest_package_funcs.md`](crypto/digest/digest_package_api/digest_package_funcs.md) | 函数 |
| [`crypto/digest/digest_package_api/digest_package_interfaces.md`](crypto/digest/digest_package_api/digest_package_interfaces.md) | 接口 |
| [`crypto/digest/digest_package_overview.md`](crypto/digest/digest_package_overview.md) | std.crypto.digest |
| [`database_sql/database_sql_package_api/database_sql_package_classes.md`](database_sql/database_sql_package_api/database_sql_package_classes.md) | 类 |
| [`database_sql/database_sql_package_api/database_sql_package_enums.md`](database_sql/database_sql_package_api/database_sql_package_enums.md) | 枚举 |
| [`database_sql/database_sql_package_api/database_sql_package_exceptions.md`](database_sql/database_sql_package_api/database_sql_package_exceptions.md) | 异常类 |
| [`database_sql/database_sql_package_api/database_sql_package_interfaces.md`](database_sql/database_sql_package_api/database_sql_package_interfaces.md) | 接口 |
| [`database_sql/database_sql_package_overview.md`](database_sql/database_sql_package_overview.md) | std.database.sql |
| [`database_sql/database_sql_samples/db_get_connection.md`](database_sql/database_sql_samples/db_get_connection.md) | 获取数据库连接示例 |
| [`database_sql/database_sql_samples/db_modify_table.md`](database_sql/database_sql_samples/db_modify_table.md) | 删除表、创建表示例 |
| [`database_sql/database_sql_samples/db_operations.md`](database_sql/database_sql_samples/db_operations.md) | 执行数据库操作语句示例 |
| [`database_sql/database_sql_samples/db_transactions.md`](database_sql/database_sql_samples/db_transactions.md) | 执行事务控制语句示例 |
| [`deriving/deriving_package_api/deriving_package_macros.md`](deriving/deriving_package_api/deriving_package_macros.md) | 宏 |
| [`deriving/deriving_package_overview.md`](deriving/deriving_package_overview.md) | std.deriving |
| [`deriving/deriving_samples/deriving_user_guide.md`](deriving/deriving_samples/deriving_user_guide.md) | Deriving |
| [`env/env_package_api/env_package_classes.md`](env/env_package_api/env_package_classes.md) | 类 |
| [`env/env_package_api/env_package_exceptions.md`](env/env_package_api/env_package_exceptions.md) | 异常 |
| [`env/env_package_api/env_package_funcs.md`](env/env_package_api/env_package_funcs.md) | 函数 |
| [`env/env_package_overview.md`](env/env_package_overview.md) | std.env |
| [`env/env_samples/env_sample.md`](env/env_samples/env_sample.md) | env 相关操作 |
| [`fs/fs_package_api/fs_package_classes.md`](fs/fs_package_api/fs_package_classes.md) | 类 |
| [`fs/fs_package_api/fs_package_enums.md`](fs/fs_package_api/fs_package_enums.md) | 枚举 |
| [`fs/fs_package_api/fs_package_exceptions.md`](fs/fs_package_api/fs_package_exceptions.md) | 异常类 |
| [`fs/fs_package_api/fs_package_funcs.md`](fs/fs_package_api/fs_package_funcs.md) | 函数 |
| [`fs/fs_package_api/fs_package_structs.md`](fs/fs_package_api/fs_package_structs.md) | 结构体 |
| [`fs/fs_package_overview.md`](fs/fs_package_overview.md) | std.fs |
| [`fs/fs_samples/directory_samples.md`](fs/fs_samples/directory_samples.md) | Directory 示例 |
| [`fs/fs_samples/file_samples.md`](fs/fs_samples/file_samples.md) | File 示例 |
| [`fs/fs_samples/fileinfo_samples.md`](fs/fs_samples/fileinfo_samples.md) | FileInfo 示例 |
| [`fs/fs_samples/path_samples.md`](fs/fs_samples/path_samples.md) | Path 示例 |
| [`io/io_package_api/io_package_classes.md`](io/io_package_api/io_package_classes.md) | 类 |
| [`io/io_package_api/io_package_enums.md`](io/io_package_api/io_package_enums.md) | 枚举 |
| [`io/io_package_api/io_package_exceptions.md`](io/io_package_api/io_package_exceptions.md) | 异常 |
| [`io/io_package_api/io_package_funcs.md`](io/io_package_api/io_package_funcs.md) | 函数 |
| [`io/io_package_api/io_package_interfaces.md`](io/io_package_api/io_package_interfaces.md) | 接口 |
| [`io/io_package_overview.md`](io/io_package_overview.md) | std.io |
| [`io/io_samples/buffered_input_stream.md`](io/io_samples/buffered_input_stream.md) | BufferedInputStream 示例 |
| [`io/io_samples/buffered_output_stream.md`](io/io_samples/buffered_output_stream.md) | BufferedOutputStream 示例 |
| [`io/io_samples/byte_buffer.md`](io/io_samples/byte_buffer.md) | ByteBuffer 示例 |
| [`io/io_samples/chained_input_stream.md`](io/io_samples/chained_input_stream.md) | ChainedInputStream 示例 |
| [`io/io_samples/multi_output_stream.md`](io/io_samples/multi_output_stream.md) | MultiOutputStream 示例 |
| [`io/io_samples/string_reader.md`](io/io_samples/string_reader.md) | StringReader 示例 |
| [`io/io_samples/string_writer.md`](io/io_samples/string_writer.md) | StringWriter 示例 |
| [`math/math_package_api/math_package_enums.md`](math/math_package_api/math_package_enums.md) | 枚举 |
| [`math/math_package_api/math_package_funcs.md`](math/math_package_api/math_package_funcs.md) | 函数 |
| [`math/math_package_api/math_package_interfaces.md`](math/math_package_api/math_package_interfaces.md) | 接口 |
| [`math/math_package_overview.md`](math/math_package_overview.md) | std.math |
| [`math/math_samples/math_basic_operation.md`](math/math_samples/math_basic_operation.md) | 数学基础运算示例 |
| [`math_numeric/math_numeric_package_api/math_numeric_package_enums.md`](math_numeric/math_numeric_package_api/math_numeric_package_enums.md) | 枚举 |
| [`math_numeric/math_numeric_package_api/math_numeric_package_funcs.md`](math_numeric/math_numeric_package_api/math_numeric_package_funcs.md) | 函数 |
| [`math_numeric/math_numeric_package_api/math_numeric_package_structs.md`](math_numeric/math_numeric_package_api/math_numeric_package_structs.md) | 结构体 |
| [`math_numeric/math_numeric_package_overview.md`](math_numeric/math_numeric_package_overview.md) | std.math.numeric |
| [`math_numeric/math_numeric_samples/bigInt_basic_arithmetic.md`](math_numeric/math_numeric_samples/bigInt_basic_arithmetic.md) | BigInt 基础数学运算示例 |
| [`math_numeric/math_numeric_samples/bigInt_basic_prop.md`](math_numeric/math_numeric_samples/bigInt_basic_prop.md) | BigInt 基本属性示例 |
| [`math_numeric/math_numeric_samples/bigInt_compare_opration.md`](math_numeric/math_numeric_samples/bigInt_compare_opration.md) | BigInt 大小比较示例 |
| [`math_numeric/math_numeric_samples/decimal_basic_arithmetic.md`](math_numeric/math_numeric_samples/decimal_basic_arithmetic.md) | Decimal 基础数学运算示例 |
| [`math_numeric/math_numeric_samples/decimal_basic_prop.md`](math_numeric/math_numeric_samples/decimal_basic_prop.md) | Decimal 基本属性示例 |
| [`math_numeric/math_numeric_samples/decimal_compare_opration.md`](math_numeric/math_numeric_samples/decimal_compare_opration.md) | Decimal 大小比较示例 |
| [`net/net_package_api/net_package_classes.md`](net/net_package_api/net_package_classes.md) | 类 |
| [`net/net_package_api/net_package_enums.md`](net/net_package_api/net_package_enums.md) | 枚举 |
| [`net/net_package_api/net_package_exceptions.md`](net/net_package_api/net_package_exceptions.md) | 异常类 |
| [`net/net_package_api/net_package_interfaces.md`](net/net_package_api/net_package_interfaces.md) | 接口 |
| [`net/net_package_api/net_package_structs.md`](net/net_package_api/net_package_structs.md) | 结构体 |
| [`net/net_package_overview.md`](net/net_package_overview.md) | std.net |
| [`net/net_samples/socket_option.md`](net/net_samples/socket_option.md) | 属性配置使用用例 |
| [`net/net_samples/tcp.md`](net/net_samples/tcp.md) | TCP 使用示例 |
| [`net/net_samples/udp.md`](net/net_samples/udp.md) | UDP 使用示例 |
| [`net/net_samples/unix.md`](net/net_samples/unix.md) | UNIX 使用示例 |
| [`net/net_samples/unix_datagram.md`](net/net_samples/unix_datagram.md) | UnixDatagram 使用示例 |
| [`objectpool/objectpool_package_api/objectpool_package_classes.md`](objectpool/objectpool_package_api/objectpool_package_classes.md) | 类 |
| [`objectpool/objectpool_package_overview.md`](objectpool/objectpool_package_overview.md) | std.objectpool |
| [`overflow/overflow_package_api/overflow_package_exceptions.md`](overflow/overflow_package_api/overflow_package_exceptions.md) | 异常类 |
| [`overflow/overflow_package_api/overflow_package_interfaces.md`](overflow/overflow_package_api/overflow_package_interfaces.md) | 接口 |
| [`overflow/overflow_package_overview.md`](overflow/overflow_package_overview.md) | std.overflow |
| [`overflow/overflow_samples/option.md`](overflow/overflow_samples/option.md) | 返回 `Option` 策略的示例 |
| [`overflow/overflow_samples/saturating.md`](overflow/overflow_samples/saturating.md) | 饱和策略的示例 |
| [`overflow/overflow_samples/throwing.md`](overflow/overflow_samples/throwing.md) | 抛出异常策略的示例 |
| [`overflow/overflow_samples/wrapping.md`](overflow/overflow_samples/wrapping.md) | 高位截断策略的示例 |
| [`posix/posix_package_api/posix_package_constants_vars.md`](posix/posix_package_api/posix_package_constants_vars.md) | 常量&变量 |
| [`posix/posix_package_api/posix_package_funcs.md`](posix/posix_package_api/posix_package_funcs.md) | 函数 |
| [`posix/posix_package_overview.md`](posix/posix_package_overview.md) | std.posix |
| [`posix/posix_samples/posix_get_file_content_samples.md`](posix/posix_samples/posix_get_file_content_samples.md) | 文件内容相关操作 |
| [`posix/posix_samples/posix_get_file_info_samples.md`](posix/posix_samples/posix_get_file_info_samples.md) | 文件信息相关操作 |
| [`posix/posix_samples/posix_get_os_envinfo_samples.md`](posix/posix_samples/posix_get_os_envinfo_samples.md) | 获取各类系统信息 |
| [`posix/posix_samples/posix_process_samples.md`](posix/posix_samples/posix_process_samples.md) | 进程相关信息操作 |
| [`process/process_package_api/process_package_classes.md`](process/process_package_api/process_package_classes.md) | 类 |
| [`process/process_package_api/process_package_enums.md`](process/process_package_api/process_package_enums.md) | 枚举 |
| [`process/process_package_api/process_package_exceptions.md`](process/process_package_api/process_package_exceptions.md) | 异常 |
| [`process/process_package_api/process_package_funcs.md`](process/process_package_api/process_package_funcs.md) | 函数 |
| [`process/process_package_overview.md`](process/process_package_overview.md) | std.process |
| [`process/process_samples/process_sample.md`](process/process_samples/process_sample.md) | 任意进程相关操作 |
| [`process/process_samples/process_subprocess_sample.md`](process/process_samples/process_subprocess_sample.md) | 子进程相关操作 |
| [`random/random_package_api/random_package_classes.md`](random/random_package_api/random_package_classes.md) | 类 |
| [`random/random_package_overview.md`](random/random_package_overview.md) | std.random |
| [`ref/ref_package_api/ref_package_classes.md`](ref/ref_package_api/ref_package_classes.md) | 类 |
| [`ref/ref_package_api/ref_package_enums.md`](ref/ref_package_api/ref_package_enums.md) | 枚举 |
| [`ref/ref_package_overview.md`](ref/ref_package_overview.md) | std.ref |
| [`ref/ref_samples/weakref_in_cache.md`](ref/ref_samples/weakref_in_cache.md) | WeakRef 用于缓存 |
| [`reflect/reflect_package_api/reflect_package_classes.md`](reflect/reflect_package_api/reflect_package_classes.md) | 类 |
| [`reflect/reflect_package_api/reflect_package_enums.md`](reflect/reflect_package_api/reflect_package_enums.md) | 枚举 |
| [`reflect/reflect_package_api/reflect_package_exceptions.md`](reflect/reflect_package_api/reflect_package_exceptions.md) | 异常类 |
| [`reflect/reflect_package_api/reflect_package_funcs.md`](reflect/reflect_package_api/reflect_package_funcs.md) | 函数 |
| [`reflect/reflect_package_api/reflect_package_types.md`](reflect/reflect_package_api/reflect_package_types.md) | 类型别名 |
| [`reflect/reflect_package_overview.md`](reflect/reflect_package_overview.md) | std.reflect |
| [`reflect/reflect_samples/annotation.md`](reflect/reflect_samples/annotation.md) | 注解的使用 |
| [`reflect/reflect_samples/dynload.md`](reflect/reflect_samples/dynload.md) | 动态加载的使用 |
| [`reflect/reflect_samples/memberInfo.md`](reflect/reflect_samples/memberInfo.md) | 成员信息的使用 |
| [`reflect/reflect_samples/typeInfo.md`](reflect/reflect_samples/typeInfo.md) | TypeInfo 的使用 |
| [`regex/regex_package_api/regex_package_classes.md`](regex/regex_package_api/regex_package_classes.md) | 类 |
| [`regex/regex_package_api/regex_package_enums.md`](regex/regex_package_api/regex_package_enums.md) | 枚举 |
| [`regex/regex_package_api/regex_package_exceptions.md`](regex/regex_package_api/regex_package_exceptions.md) | 异常 |
| [`regex/regex_package_api/regex_package_structs.md`](regex/regex_package_api/regex_package_structs.md) | 结构体 |
| [`regex/regex_package_overview.md`](regex/regex_package_overview.md) | std.regex |
| [`regex/regex_samples/regex_sample.md`](regex/regex_samples/regex_sample.md) | regex 示例 |
| [`runtime/runtime_package_api/runtime_package_funcs.md`](runtime/runtime_package_api/runtime_package_funcs.md) | 函数 |
| [`runtime/runtime_package_api/runtime_package_structs.md`](runtime/runtime_package_api/runtime_package_structs.md) | 结构体 |
| [`runtime/runtime_package_overview.md`](runtime/runtime_package_overview.md) | std.runtime |
| [`sort/sort_package_api/sort_package_funcs.md`](sort/sort_package_api/sort_package_funcs.md) | 函数 |
| [`sort/sort_package_api/sort_package_interfaces.md`](sort/sort_package_api/sort_package_interfaces.md) | 接口 |
| [`sort/sort_package_overview.md`](sort/sort_package_overview.md) | std.sort |
| [`sort/sort_samples/sort_sample_array.md`](sort/sort_samples/sort_sample_array.md) | 对 Array 和 List 进行排序 |
| [`std_module_overview.md`](std_module_overview.md) | 仓颉编程语言标准库概述 |
| [`sync/sync_package_api/sync_package_classes.md`](sync/sync_package_api/sync_package_classes.md) | 类 |
| [`sync/sync_package_api/sync_package_constants_vars.md`](sync/sync_package_api/sync_package_constants_vars.md) | 常量&变量 |
| [`sync/sync_package_api/sync_package_enums.md`](sync/sync_package_api/sync_package_enums.md) | 枚举 |
| [`sync/sync_package_api/sync_package_exceptions.md`](sync/sync_package_api/sync_package_exceptions.md) | 异常类 |
| [`sync/sync_package_api/sync_package_interfaces.md`](sync/sync_package_api/sync_package_interfaces.md) | 接口 |
| [`sync/sync_package_api/sync_package_structs.md`](sync/sync_package_api/sync_package_structs.md) | 结构体 |
| [`sync/sync_package_overview.md`](sync/sync_package_overview.md) | std.sync |
| [`sync/sync_samples/sync_samples.md`](sync/sync_samples/sync_samples.md) | Atomic、Monitor 和 Timer 的使用 |
| [`time/time_package_api/time_package_classes.md`](time/time_package_api/time_package_classes.md) | 类 |
| [`time/time_package_api/time_package_enums.md`](time/time_package_api/time_package_enums.md) | 枚举 |
| [`time/time_package_api/time_package_exceptions.md`](time/time_package_api/time_package_exceptions.md) | 异常类 |
| [`time/time_package_api/time_package_structs.md`](time/time_package_api/time_package_structs.md) | 结构体 |
| [`time/time_package_overview.md`](time/time_package_overview.md) | std.time |
| [`time/time_samples/datetime_compare.md`](time/time_samples/datetime_compare.md) | DateTime 比较 |
| [`time/time_samples/datetime_parse.md`](time/time_samples/datetime_parse.md) | DateTime 与 String 类型的转换 |
| [`time/time_samples/datetime_prop.md`](time/time_samples/datetime_prop.md) | 获取日期时间信息 |
| [`time/time_samples/datetime_tz.md`](time/time_samples/datetime_tz.md) | 同一时间在不同时区的本地时间 |
| [`time/time_samples/monotime_test.md`](time/time_samples/monotime_test.md) | 利用 MonoTime 作计时 |
| [`unicode/unicode_package_api/unicode_package_enums.md`](unicode/unicode_package_api/unicode_package_enums.md) | 枚举 |
| [`unicode/unicode_package_api/unicode_package_interfaces.md`](unicode/unicode_package_api/unicode_package_interfaces.md) | 接口 |
| [`unicode/unicode_package_overview.md`](unicode/unicode_package_overview.md) | std.unicode |
| [`unittest/unittest_package_api/unittest_package_classes.md`](unittest/unittest_package_api/unittest_package_classes.md) | 类 |
| [`unittest/unittest_package_api/unittest_package_enums.md`](unittest/unittest_package_api/unittest_package_enums.md) | 枚举 |
| [`unittest/unittest_package_api/unittest_package_exceptions.md`](unittest/unittest_package_api/unittest_package_exceptions.md) | 异常类 |
| [`unittest/unittest_package_api/unittest_package_functions.md`](unittest/unittest_package_api/unittest_package_functions.md) | 函数 |
| [`unittest/unittest_package_api/unittest_package_interfaces.md`](unittest/unittest_package_api/unittest_package_interfaces.md) | 接口 |
| [`unittest/unittest_package_api/unittest_package_structs.md`](unittest/unittest_package_api/unittest_package_structs.md) | 结构体 |
| [`unittest/unittest_package_api/unittest_package_types.md`](unittest/unittest_package_api/unittest_package_types.md) | 类型别名 |
| [`unittest/unittest_package_overview.md`](unittest/unittest_package_overview.md) | std.unittest |
| [`unittest/unittest_samples/unittest_basics.md`](unittest/unittest_samples/unittest_basics.md) | Unittest 基础概念及用法 |
| [`unittest/unittest_samples/unittest_benchmarks.md`](unittest/unittest_samples/unittest_benchmarks.md) | 基准测试 |
| [`unittest/unittest_samples/unittest_dynamic_tests.md`](unittest/unittest_samples/unittest_dynamic_tests.md) | 动态测试 |
| [`unittest/unittest_samples/unittest_getting_started.md`](unittest/unittest_samples/unittest_getting_started.md) | Unittest 快速入门 |
| [`unittest/unittest_samples/unittest_parameterized_tests.md`](unittest/unittest_samples/unittest_parameterized_tests.md) | 参数化测试 |
| [`unittest/unittest_samples/unittest_test_templates.md`](unittest/unittest_samples/unittest_test_templates.md) | 测试模版 |
| [`unittest_common/unittest_common_package_api/unittest_common_constants_vars.md`](unittest_common/unittest_common_package_api/unittest_common_constants_vars.md) | 常量&变量 |
| [`unittest_common/unittest_common_package_api/unittest_common_package_classes.md`](unittest_common/unittest_common_package_api/unittest_common_package_classes.md) | 类 |
| [`unittest_common/unittest_common_package_api/unittest_common_package_enums.md`](unittest_common/unittest_common_package_api/unittest_common_package_enums.md) | 枚举 |
| [`unittest_common/unittest_common_package_api/unittest_common_package_exceptions.md`](unittest_common/unittest_common_package_api/unittest_common_package_exceptions.md) | 异常 |
| [`unittest_common/unittest_common_package_api/unittest_common_package_functions.md`](unittest_common/unittest_common_package_api/unittest_common_package_functions.md) | 函数 |
| [`unittest_common/unittest_common_package_api/unittest_common_package_interfaces.md`](unittest_common/unittest_common_package_api/unittest_common_package_interfaces.md) | 接口 |
| [`unittest_common/unittest_common_package_api/unittest_common_package_structs.md`](unittest_common/unittest_common_package_api/unittest_common_package_structs.md) | 结构体 |
| [`unittest_common/unittest_common_package_overview.md`](unittest_common/unittest_common_package_overview.md) | std.unittest.common |
| [`unittest_diff/unittest_diff_package_api/unittest_diff_package_interfaces.md`](unittest_diff/unittest_diff_package_api/unittest_diff_package_interfaces.md) | 接口 |
| [`unittest_diff/unittest_diff_package_overview.md`](unittest_diff/unittest_diff_package_overview.md) | std.unittest.diff |
| [`unittest_mock/unittest_mock_package_api/unittest_mock_package_classes.md`](unittest_mock/unittest_mock_package_api/unittest_mock_package_classes.md) | 类 |
| [`unittest_mock/unittest_mock_package_api/unittest_mock_package_enums.md`](unittest_mock/unittest_mock_package_api/unittest_mock_package_enums.md) | 枚举 |
| [`unittest_mock/unittest_mock_package_api/unittest_mock_package_exceptions.md`](unittest_mock/unittest_mock_package_api/unittest_mock_package_exceptions.md) | 异常类 |
| [`unittest_mock/unittest_mock_package_api/unittest_mock_package_functions.md`](unittest_mock/unittest_mock_package_api/unittest_mock_package_functions.md) | 函数 |
| [`unittest_mock/unittest_mock_package_api/unittest_mock_package_interfaces.md`](unittest_mock/unittest_mock_package_api/unittest_mock_package_interfaces.md) | 接口 |
| [`unittest_mock/unittest_mock_package_overview.md`](unittest_mock/unittest_mock_package_overview.md) | std.unittest.mock |
| [`unittest_mock/unittest_mock_samples/mock_framework_basics.md`](unittest_mock/unittest_mock_samples/mock_framework_basics.md) | mock 基础概念及用法 |
| [`unittest_mock/unittest_mock_samples/mock_framework_getting_started.md`](unittest_mock/unittest_mock_samples/mock_framework_getting_started.md) | mock 框架入门 |
| [`unittest_mock/unittest_mock_samples/mock_framework_stubs.md`](unittest_mock/unittest_mock_samples/mock_framework_stubs.md) | 桩使用指南 |
| [`unittest_mock/unittest_mock_samples/mock_framework_verification.md`](unittest_mock/unittest_mock_samples/mock_framework_verification.md) | mock 框架验证 API |
| [`unittest_mock_mockmacro/unittest_mock_mockmacro_package_api/unittest_mock_mockmacro_package_macros.md`](unittest_mock_mockmacro/unittest_mock_mockmacro_package_api/unittest_mock_mockmacro_package_macros.md) | 宏 |
| [`unittest_mock_mockmacro/unittest_mock_mockmacro_package_overview.md`](unittest_mock_mockmacro/unittest_mock_mockmacro_package_overview.md) | std.unittest.mock.mockmacro |
| [`unittest_prop_test/unittest_prop_test_package_api/unittest_prop_test_package_classes.md`](unittest_prop_test/unittest_prop_test_package_api/unittest_prop_test_package_classes.md) | 类 |
| [`unittest_prop_test/unittest_prop_test_package_api/unittest_prop_test_package_functions.md`](unittest_prop_test/unittest_prop_test_package_api/unittest_prop_test_package_functions.md) | 函数 |
| [`unittest_prop_test/unittest_prop_test_package_api/unittest_prop_test_package_interfaces.md`](unittest_prop_test/unittest_prop_test_package_api/unittest_prop_test_package_interfaces.md) | 接口 |
| [`unittest_prop_test/unittest_prop_test_package_api/unittest_prop_test_package_structs.md`](unittest_prop_test/unittest_prop_test_package_api/unittest_prop_test_package_structs.md) | 结构体 |
| [`unittest_prop_test/unittest_prop_test_package_overview.md`](unittest_prop_test/unittest_prop_test_package_overview.md) | std.unittest.prop_test |
| [`unittest_testmacro/unittest_testmacro_package_api/unittest_testmacro_package_macros.md`](unittest_testmacro/unittest_testmacro_package_api/unittest_testmacro_package_macros.md) | 宏 |
| [`unittest_testmacro/unittest_testmacro_package_overview.md`](unittest_testmacro/unittest_testmacro_package_overview.md) | std.unittest.testmacro |


## 扩展库文档

仓颉编程语言扩展库（stdx）API 文档，按包组织。

根目录：`D:\docs\work\cangjie\projects\cangjie_stdx\doc\libs_stdx`

共 161 个 Markdown 文档。

| 文档 | 说明 |
| ---- | ---- |
| [`actors/actors_package_api/actors_package_classes.md`](actors/actors_package_api/actors_package_classes.md) | 类 |
| [`actors/actors_package_overview.md`](actors/actors_package_overview.md) | stdx.actors |
| [`actors/macros/macros_package_api/macros_package_macros.md`](actors/macros/macros_package_api/macros_package_macros.md) | 宏 |
| [`actors/macros/macros_package_overview.md`](actors/macros/macros_package_overview.md) | stdx.actors.macros |
| [`aspect_cj/aspect_cj_package_api/aspect_cj_package_classes.md`](aspect_cj/aspect_cj_package_api/aspect_cj_package_classes.md) | 类 |
| [`aspect_cj/aspect_cj_package_overview.md`](aspect_cj/aspect_cj_package_overview.md) | stdx.aspect_cj |
| [`aspect_cj/aspect_cj_samples/aspect_cj_sample.md`](aspect_cj/aspect_cj_samples/aspect_cj_sample.md) | AOP 开发示例 |
| [`chir/chir_package_api/chir_package_classes.md`](chir/chir_package_api/chir_package_classes.md) | 类 |
| [`chir/chir_package_api/chir_package_enums.md`](chir/chir_package_api/chir_package_enums.md) | 枚举 |
| [`chir/chir_package_api/chir_package_structs.md`](chir/chir_package_api/chir_package_structs.md) | 结构体 |
| [`chir/chir_package_overview.md`](chir/chir_package_overview.md) | stdx.chir |
| [`compress/compress_package_api/compress_package_classes.md`](compress/compress_package_api/compress_package_classes.md) | 类 |
| [`compress/compress_package_overview.md`](compress/compress_package_overview.md) | stdx.compress |
| [`compress/tar/tar_package_api/tar_package_classes.md`](compress/tar/tar_package_api/tar_package_classes.md) | 类 |
| [`compress/tar/tar_package_api/tar_package_enums.md`](compress/tar/tar_package_api/tar_package_enums.md) | 枚举 |
| [`compress/tar/tar_package_api/tar_package_exceptions.md`](compress/tar/tar_package_api/tar_package_exceptions.md) | 异常类 |
| [`compress/tar/tar_package_overview.md`](compress/tar/tar_package_overview.md) | stdx.compress.tar |
| [`compress/tar/tar_samples/tar_reader_writer.md`](compress/tar/tar_samples/tar_reader_writer.md) | Tar 格式数据的归档与提取 |
| [`compress/zlib/zlib_package_api/zlib_package_classes.md`](compress/zlib/zlib_package_api/zlib_package_classes.md) | 类 |
| [`compress/zlib/zlib_package_api/zlib_package_enums.md`](compress/zlib/zlib_package_api/zlib_package_enums.md) | 枚举 |
| [`compress/zlib/zlib_package_api/zlib_package_exceptions.md`](compress/zlib/zlib_package_api/zlib_package_exceptions.md) | 异常类 |
| [`compress/zlib/zlib_package_overview.md`](compress/zlib/zlib_package_overview.md) | stdx.compress.zlib |
| [`compress/zlib/zlib_samples/deflate_compress_decompress.md`](compress/zlib/zlib_samples/deflate_compress_decompress.md) | Deflate 格式数据的压缩和解压 |
| [`compress/zlib/zlib_samples/gzip_compress_decompress.md`](compress/zlib/zlib_samples/gzip_compress_decompress.md) | Gzip 格式数据的压缩和解压 |
| [`crypto/common/crypto_common_package_api/crypto_common_package_exceptions.md`](crypto/common/crypto_common_package_api/crypto_common_package_exceptions.md) | 异常类 |
| [`crypto/common/crypto_common_package_api/crypto_common_package_funcs.md`](crypto/common/crypto_common_package_api/crypto_common_package_funcs.md) | 函数 |
| [`crypto/common/crypto_common_package_api/crypto_common_package_interfaces.md`](crypto/common/crypto_common_package_api/crypto_common_package_interfaces.md) | 接口 |
| [`crypto/common/crypto_common_package_api/crypto_common_package_structs.md`](crypto/common/crypto_common_package_api/crypto_common_package_structs.md) | 结构体 |
| [`crypto/common/crypto_common_package_overview.md`](crypto/common/crypto_common_package_overview.md) | stdx.crypto.common |
| [`crypto/crypto/crypto_package_api/crypto_package_classes.md`](crypto/crypto/crypto_package_api/crypto_package_classes.md) | 类 |
| [`crypto/crypto/crypto_package_api/crypto_package_exceptions.md`](crypto/crypto/crypto_package_api/crypto_package_exceptions.md) | 异常类 |
| [`crypto/crypto/crypto_package_api/crypto_package_structs.md`](crypto/crypto/crypto_package_api/crypto_package_structs.md) | 结构体 |
| [`crypto/crypto/crypto_package_overview.md`](crypto/crypto/crypto_package_overview.md) | stdx.crypto.crypto |
| [`crypto/crypto/crypto_samples/sample_crypto.md`](crypto/crypto/crypto_samples/sample_crypto.md) | SM4 使用 |
| [`crypto/crypto/crypto_samples/sample_secure_random.md`](crypto/crypto/crypto_samples/sample_secure_random.md) | SecureRandom 使用 |
| [`crypto/digest/crypto_digest_package_overview.md`](crypto/digest/crypto_digest_package_overview.md) | stdx.crypto.digest |
| [`crypto/digest/digest_package_api/digest_package_classes.md`](crypto/digest/digest_package_api/digest_package_classes.md) | 类 |
| [`crypto/digest/digest_package_api/digest_package_structs.md`](crypto/digest/digest_package_api/digest_package_structs.md) | 结构体 |
| [`crypto/digest/digest_samples/sample_digest.md`](crypto/digest/digest_samples/sample_digest.md) | digest 使用 |
| [`crypto/keys/keys_package_api/keys_package_classes.md`](crypto/keys/keys_package_api/keys_package_classes.md) | 类 |
| [`crypto/keys/keys_package_api/keys_package_enums.md`](crypto/keys/keys_package_api/keys_package_enums.md) | 枚举 |
| [`crypto/keys/keys_package_api/keys_package_structs.md`](crypto/keys/keys_package_api/keys_package_structs.md) | 结构体 |
| [`crypto/keys/keys_package_overview.md`](crypto/keys/keys_package_overview.md) | stdx.crypto.keys |
| [`crypto/keys/keys_samples/sample_keys.md`](crypto/keys/keys_samples/sample_keys.md) | keys 使用 |
| [`crypto/kit/crypto_kit_package_api/crypto_kit_package_classes.md`](crypto/kit/crypto_kit_package_api/crypto_kit_package_classes.md) | 类 |
| [`crypto/kit/crypto_kit_package_overview.md`](crypto/kit/crypto_kit_package_overview.md) | stdx.crypto.kit |
| [`crypto/x509/x509_package_api/x509_package_classes.md`](crypto/x509/x509_package_api/x509_package_classes.md) | 类 |
| [`crypto/x509/x509_package_api/x509_package_enums.md`](crypto/x509/x509_package_api/x509_package_enums.md) | 枚举 |
| [`crypto/x509/x509_package_api/x509_package_exceptions.md`](crypto/x509/x509_package_api/x509_package_exceptions.md) | 异常类 |
| [`crypto/x509/x509_package_api/x509_package_structs.md`](crypto/x509/x509_package_api/x509_package_structs.md) | 结构体 |
| [`crypto/x509/x509_package_api/x509_package_type.md`](crypto/x509/x509_package_api/x509_package_type.md) | 类型别名 |
| [`crypto/x509/x509_package_overview.md`](crypto/x509/x509_package_overview.md) | stdx.crypto.x509 |
| [`crypto/x509/x509_samples/sample_x509.md`](crypto/x509/x509_samples/sample_x509.md) | x509 使用 |
| [`effect/effect_package_api/effect_package_classes.md`](effect/effect_package_api/effect_package_classes.md) | 类 |
| [`effect/effect_package_api/effect_package_exceptions.md`](effect/effect_package_api/effect_package_exceptions.md) | 异常类 |
| [`effect/effect_package_overview.md`](effect/effect_package_overview.md) | stdx.effect |
| [`effect/effect_samples/simple_immediate_effect.md`](effect/effect_samples/simple_immediate_effect.md) | 即时效应处理器（Immediate Effect Handler） |
| [`encoding/base64/base64_package_api/base64_package_funcs.md`](encoding/base64/base64_package_api/base64_package_funcs.md) | 函数 |
| [`encoding/base64/base64_package_overview.md`](encoding/base64/base64_package_overview.md) | stdx.encoding.base64 |
| [`encoding/base64/base64_samples/base64.md`](encoding/base64/base64_samples/base64.md) | Byte 数组和 Base64 互转 |
| [`encoding/hex/hex_package_api/hex_package_funcs.md`](encoding/hex/hex_package_api/hex_package_funcs.md) | 函数 |
| [`encoding/hex/hex_package_overview.md`](encoding/hex/hex_package_overview.md) | stdx.encoding.hex |
| [`encoding/hex/hex_samples/hex.md`](encoding/hex/hex_samples/hex.md) | Byte 数组和 Hex 互转 |
| [`encoding/json/json_package_api/encoding_json_package_classes.md`](encoding/json/json_package_api/encoding_json_package_classes.md) | 类 |
| [`encoding/json/json_package_api/encoding_json_package_enums.md`](encoding/json/json_package_api/encoding_json_package_enums.md) | 枚举 |
| [`encoding/json/json_package_api/encoding_json_package_exceptions.md`](encoding/json/json_package_api/encoding_json_package_exceptions.md) | 异常类 |
| [`encoding/json/json_package_api/encoding_json_package_interfaces.md`](encoding/json/json_package_api/encoding_json_package_interfaces.md) | 接口 |
| [`encoding/json/json_package_overview.md`](encoding/json/json_package_overview.md) | stdx.encoding.json |
| [`encoding/json/json_samples/json_array_sample.md`](encoding/json/json_samples/json_array_sample.md) | JsonArray 使用示例 |
| [`encoding/json/json_samples/json_value_sample.md`](encoding/json/json_samples/json_value_sample.md) | JsonValue 和 String 互相转换 |
| [`encoding/json/json_samples/to_json_sample.md`](encoding/json/json_samples/to_json_sample.md) | JsonValue 与 DataModel 的转换 |
| [`encoding/json_stream/json_stream_package_api/encoding_json_stream_package_classes.md`](encoding/json_stream/json_stream_package_api/encoding_json_stream_package_classes.md) | 类 |
| [`encoding/json_stream/json_stream_package_api/encoding_json_stream_package_enums.md`](encoding/json_stream/json_stream_package_api/encoding_json_stream_package_enums.md) | 枚举 |
| [`encoding/json_stream/json_stream_package_api/encoding_json_stream_package_interfaces.md`](encoding/json_stream/json_stream_package_api/encoding_json_stream_package_interfaces.md) | 接口 |
| [`encoding/json_stream/json_stream_package_api/encoding_json_stream_package_structs.md`](encoding/json_stream/json_stream_package_api/encoding_json_stream_package_structs.md) | 结构体 |
| [`encoding/json_stream/json_stream_package_overview.md`](encoding/json_stream/json_stream_package_overview.md) | stdx.encoding.json.stream |
| [`encoding/json_stream/json_stream_samples/sample_json_reader.md`](encoding/json_stream/json_stream_samples/sample_json_reader.md) | 使用 Json Stream 进行反序列化 |
| [`encoding/json_stream/json_stream_samples/sample_json_writeconfig.md`](encoding/json_stream/json_stream_samples/sample_json_writeconfig.md) | WriteConfig 使用示例 |
| [`encoding/json_stream/json_stream_samples/sample_json_writer.md`](encoding/json_stream/json_stream_samples/sample_json_writer.md) | 使用 Json Stream 进行序列化 |
| [`encoding/url/url_package_api/url_package_classes.md`](encoding/url/url_package_api/url_package_classes.md) | 类 |
| [`encoding/url/url_package_api/url_package_exceptions.md`](encoding/url/url_package_api/url_package_exceptions.md) | 异常类 |
| [`encoding/url/url_package_overview.md`](encoding/url/url_package_overview.md) | stdx.encoding.url |
| [`encoding/url/url_samples/form.md`](encoding/url/url_samples/form.md) | Form 的构造使用 |
| [`encoding/url/url_samples/url_parse.md`](encoding/url/url_samples/url_parse.md) | URL 解析函数 parse 的使用 |
| [`fuzz/fuzz_package_api/fuzz_package_classes.md`](fuzz/fuzz_package_api/fuzz_package_classes.md) | 类 |
| [`fuzz/fuzz_package_api/fuzz_package_constants_vars.md`](fuzz/fuzz_package_api/fuzz_package_constants_vars.md) | 常量&变量 |
| [`fuzz/fuzz_package_api/fuzz_package_exceptions.md`](fuzz/fuzz_package_api/fuzz_package_exceptions.md) | 异常类 |
| [`fuzz/fuzz_package_overview.md`](fuzz/fuzz_package_overview.md) | stdx.fuzz |
| [`fuzz/fuzz_samples/basic_fuzzing_test.md`](fuzz/fuzz_samples/basic_fuzzing_test.md) | 测试猜测字符功能 |
| [`fuzz/fuzz_samples/dataprovider_usage.md`](fuzz/fuzz_samples/dataprovider_usage.md) | 使用 DataProvider 功能进行测试 |
| [`fuzz/fuzz_samples/fake_coverage_usage.md`](fuzz/fuzz_samples/fake_coverage_usage.md) | 使用 FakeCoverage 避免 DataProvider 模式下 Fuzz 异常终止 |
| [`fuzz/fuzz_samples/print_cj-fuzz_usage.md`](fuzz/fuzz_samples/print_cj-fuzz_usage.md) | 打印 fuzz 使用方法 |
| [`fuzz/fuzz_samples/print_coverage.md`](fuzz/fuzz_samples/print_coverage.md) | 实验性特性-覆盖率信息打印 |
| [`fuzz/fuzz_samples/stack_backtrace_missing_solution.md`](fuzz/fuzz_samples/stack_backtrace_missing_solution.md) | 栈回溯缺失的处理方案 |
| [`libs_overview.md`](libs_overview.md) | 仓颉编程语言扩展库概述 |
| [`log/log_package_api/log_package_classes.md`](log/log_package_api/log_package_classes.md) | 类 |
| [`log/log_package_api/log_package_exceptions.md`](log/log_package_api/log_package_exceptions.md) | 异常类 |
| [`log/log_package_api/log_package_funcs.md`](log/log_package_api/log_package_funcs.md) | 函数 |
| [`log/log_package_api/log_package_interfaces.md`](log/log_package_api/log_package_interfaces.md) | 接口 |
| [`log/log_package_api/log_package_structs.md`](log/log_package_api/log_package_structs.md) | 结构体 |
| [`log/log_package_api/log_package_types.md`](log/log_package_api/log_package_types.md) | 类型别名 |
| [`log/log_package_overview.md`](log/log_package_overview.md) | stdx.log |
| [`log/log_samples/log_sample.md`](log/log_samples/log_sample.md) | 日志打印示例 |
| [`logger/logger_package_api/logger_package_classes.md`](logger/logger_package_api/logger_package_classes.md) | 类 |
| [`logger/logger_package_overview.md`](logger/logger_package_overview.md) | stdx.logger |
| [`logger/logger_samples/logger_sample.md`](logger/logger_samples/logger_sample.md) | 日志打印示例 |
| [`net/http/http_package_api/http_package_classes.md`](net/http/http_package_api/http_package_classes.md) | 类 |
| [`net/http/http_package_api/http_package_enums.md`](net/http/http_package_api/http_package_enums.md) | 枚举 |
| [`net/http/http_package_api/http_package_exceptions.md`](net/http/http_package_api/http_package_exceptions.md) | 异常类 |
| [`net/http/http_package_api/http_package_funcs.md`](net/http/http_package_api/http_package_funcs.md) | 函数 |
| [`net/http/http_package_api/http_package_interfaces.md`](net/http/http_package_api/http_package_interfaces.md) | 接口 |
| [`net/http/http_package_api/http_package_structs.md`](net/http/http_package_api/http_package_structs.md) | 结构体 |
| [`net/http/http_package_overview.md`](net/http/http_package_overview.md) | stdx.net.http |
| [`net/http/http_samples/cookie.md`](net/http/http_samples/cookie.md) | cookie |
| [`net/http/http_samples/h1_gzip.md`](net/http/http_samples/h1_gzip.md) | h1_gzip |
| [`net/http/http_samples/http_client.md`](net/http/http_samples/http_client.md) | client |
| [`net/http/http_samples/http_server.md`](net/http/http_samples/http_server.md) | server |
| [`net/http/http_samples/log.md`](net/http/http_samples/log.md) | log |
| [`net/http/http_samples/webSocket.md`](net/http/http_samples/webSocket.md) | webSocket |
| [`net/tls/common/tls_common_package_api/tls_common_package_enums.md`](net/tls/common/tls_common_package_api/tls_common_package_enums.md) | 枚举 |
| [`net/tls/common/tls_common_package_api/tls_common_package_exceptions.md`](net/tls/common/tls_common_package_api/tls_common_package_exceptions.md) | 异常类 |
| [`net/tls/common/tls_common_package_api/tls_common_package_funcs.md`](net/tls/common/tls_common_package_api/tls_common_package_funcs.md) | 函数 |
| [`net/tls/common/tls_common_package_api/tls_common_package_interfaces.md`](net/tls/common/tls_common_package_api/tls_common_package_interfaces.md) | 接口 |
| [`net/tls/common/tls_common_package_overview.md`](net/tls/common/tls_common_package_overview.md) | stdx.net.tls.common |
| [`net/tls/tls_package_api/tls_package_classes.md`](net/tls/tls_package_api/tls_package_classes.md) | 类 |
| [`net/tls/tls_package_api/tls_package_enums.md`](net/tls/tls_package_api/tls_package_enums.md) | 枚举 |
| [`net/tls/tls_package_api/tls_package_structs.md`](net/tls/tls_package_api/tls_package_structs.md) | 结构体 |
| [`net/tls/tls_package_api/tls_package_type.md`](net/tls/tls_package_api/tls_package_type.md) | 类型别名 |
| [`net/tls/tls_package_overview.md`](net/tls/tls_package_overview.md) | stdx.net.tls |
| [`net/tls/tls_samples/cert_key.md`](net/tls/tls_samples/cert_key.md) | 服务端证书及公钥在一份文件中 |
| [`net/tls/tls_samples/client.md`](net/tls/tls_samples/client.md) | 客户端示例 |
| [`net/tls/tls_samples/custom_verify.md`](net/tls/tls_samples/custom_verify.md) | 自定义证书校验 |
| [`net/tls/tls_samples/hot_update_cert.md`](net/tls/tls_samples/hot_update_cert.md) | 证书热更新 |
| [`net/tls/tls_samples/server.md`](net/tls/tls_samples/server.md) | 服务端示例 |
| [`plugin/manager/plugin_manager_package_api/plugin_manager_package_classes.md`](plugin/manager/plugin_manager_package_api/plugin_manager_package_classes.md) | 类 |
| [`plugin/manager/plugin_manager_package_api/plugin_manager_package_structs.md`](plugin/manager/plugin_manager_package_api/plugin_manager_package_structs.md) | 结构体 |
| [`plugin/manager/plugin_manager_package_overview.md`](plugin/manager/plugin_manager_package_overview.md) | stdx.plugin.manager |
| [`plugin/plugin_package_api/plugin_package_macros.md`](plugin/plugin_package_api/plugin_package_macros.md) | 宏 |
| [`plugin/plugin_package_overview.md`](plugin/plugin_package_overview.md) | stdx.plugin |
| [`serialization/serialization_package_api/serialization_package_classes.md`](serialization/serialization_package_api/serialization_package_classes.md) | 类 |
| [`serialization/serialization_package_api/serialization_package_exceptions.md`](serialization/serialization_package_api/serialization_package_exceptions.md) | 异常类 |
| [`serialization/serialization_package_api/serialization_package_functions.md`](serialization/serialization_package_api/serialization_package_functions.md) | 函数 |
| [`serialization/serialization_package_api/serialization_package_interfaces.md`](serialization/serialization_package_api/serialization_package_interfaces.md) | 接口 |
| [`serialization/serialization_package_overview.md`](serialization/serialization_package_overview.md) | stdx.serialization.serialization |
| [`serialization/serialization_samples/serialize_and_deserialize_class.md`](serialization/serialization_samples/serialize_and_deserialize_class.md) | class 序列化和反序列化 |
| [`serialization/serialization_samples/serialize_hashmap_and_hashset.md`](serialization/serialization_samples/serialize_hashmap_and_hashset.md) | HashSet 和 HashMap 序列化 |
| [`source_code_dependency.md`](source_code_dependency.md) | 扩展库源码集成指南 |
| [`string_intern/string_intern_package_api/string_intern_package_interfaces.md`](string_intern/string_intern_package_api/string_intern_package_interfaces.md) | 接口 |
| [`string_intern/string_intern_package_overview.md`](string_intern/string_intern_package_overview.md) | stdx.string_intern |
| [`string_intern/string_intern_samples/string_intern_sample.md`](string_intern/string_intern_samples/string_intern_sample.md) | 字符串池化缓存示例 |
| [`syntax/syntax_package_api/syntax_package_classes.md`](syntax/syntax_package_api/syntax_package_classes.md) | 类 |
| [`syntax/syntax_package_api/syntax_package_enums.md`](syntax/syntax_package_api/syntax_package_enums.md) | 枚举 |
| [`syntax/syntax_package_api/syntax_package_funcs.md`](syntax/syntax_package_api/syntax_package_funcs.md) | 函数 |
| [`syntax/syntax_package_api/syntax_package_structs.md`](syntax/syntax_package_api/syntax_package_structs.md) | 结构体 |
| [`syntax/syntax_package_overview.md`](syntax/syntax_package_overview.md) | stdx.syntax |
| [`syntax/syntax_samples/parse.md`](syntax/syntax_samples/parse.md) | 使用语法解析函数示例 |
| [`syntax/syntax_samples/rewrite.md`](syntax/syntax_samples/rewrite.md) | 遍历时修改节点示例 |
| [`syntax/syntax_samples/visit.md`](syntax/syntax_samples/visit.md) | 遍历节点示例 |
| [`unittest/data/data_package_api/data_package_classes.md`](unittest/data/data_package_api/data_package_classes.md) | 类 |
| [`unittest/data/data_package_api/data_package_functions.md`](unittest/data/data_package_api/data_package_functions.md) | 函数 |
| [`unittest/data/data_package_overview.md`](unittest/data/data_package_overview.md) | stdx.unittest.data |

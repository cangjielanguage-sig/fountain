# Spec Delta

## Purpose

让 x86_64 的发射审计与 aarch64 的"宿主绝对地址豁免"规则**对称**，并保证含常量镜像的单元不会被
审计误判而静默回退；同时把 `f_util` 的用例纳入可复跑的执行记录。

## ADDED Requirements

### Requirement: x86_64 审计的绝对地址例外（与 aarch64 对称）

x86_64 发射审计 SHALL 区分两类内存基址：

- **受控基址**：`rsp(4)`、`rbp(5)`、`r15(15)`；
- **宿主绝对地址**：常量镜像（`PUSH_KH`）与函数入口表（`CALL_FUNC`）把地址物化到寄存器后解引用，
  以哨兵 `-1` 显式登记，SHALL 视为合规（与 aarch64 对 `movImm64` + `ldr` 的豁免同一条规则）。

除上述两类以外的基址 SHALL 判定为违规（整单元退回解释器）。

#### Scenario: 绝对地址不误判

- **WHEN** 审计集合为 `[4, -1, 15]`（含绝对地址哨兵）
- **THEN** `auditAllows` 返回真；集合为 `[0]` 时返回假

#### Scenario: 含常量镜像的单元仍走 JIT

- **WHEN** 编译含字符串字面量的单元（触发 `PUSH_KH` 的绝对地址访问）并在 Linux x86_64 上调用
- **THEN** `JitFunction.isJitBacked()` 为真（未因审计而整单元回退），调用结果正确

### Requirement: f_util 用例可复跑并留档

`f_util` 的单元测试（含 FNV 全字宽）SHALL 有可复跑的执行命令与结果记录（WSL x86_64）。
仓库当前无 CI 配置，故以 `doc/spec/f-jit-m1/verify.md` 的记录 + 命令为门禁。

#### Scenario: FNV 用例在 x86_64 通过

- **WHEN** 在 WSL Ubuntu-24.04 / x86_64 执行 `cd f_util && cjpm test`
- **THEN** 全部用例通过，结果写入 `verify.md`

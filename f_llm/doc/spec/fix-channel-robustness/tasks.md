# Tasks

## 1. 实例表

- [x] 1.1 `register` 覆盖同键时先 `close()` 旧实例；验证：假通道记录 close 次数，二次注册后旧实例 `closed==1`（先失败）。
- [x] 1.2 空账号重复注册抛错；验证：两次 `account=''` 注册，第二次抛 `ChannelException` 且信息含 `account`。
- [x] 1.3 新增 `closeAll()`；验证：注册 2 个实例后调用，两者 `closed==1` 且 `accounts()` 为空。

## 2. 配置解析

- [x] 2.1 `strOf` 对 `JsonNull` 返回空串；验证：`{"platform":"email","account":null,...}` 安装成功且账号为空（先失败，当前得到 `"null"`）。
- [x] 2.2 端口越界跳过；验证：`smtpPort:70000` → `skipped=1`、错误含 `port`。
- [x] 2.3 email 必填校验；验证：缺 `smtpHost` → `skipped=1`、错误含 `smtpHost`。
- [x] 2.4 `tls` 白名单；验证：`starttls` → skipped 且错误含 `starttls`；`ssl` → installed。
- [x] 2.5 `installFromConfig` 包 try；验证：配置读取异常时返回带 error 的报告、不抛（用桩函数验证 catch 分支存在即可，或标注为代码审查项）。

## 3. 收信健壮性

- [x] 3.1 单条附件读取失败不中断；验证：假附件 `read()` 抛异常 → 该附件 `error` 非空、同批第二封邮件正常返回（先失败）。
- [x] 3.2 `FEmailTransport.receive` 首封前失败抛错、部分成功后保留；验证：无网络用例（需真实 IMAP），以代码审查 + `receive` 层用例覆盖语义。

## 4. 集成验证

- [x] 4.1 全量回归 `cd f_llm && cjpm test` 全绿（基线 613）。
- [x] 4.2 `doc/loom.md` 通道小节补「收信失败显式、附件单条隔离、非法条目跳过」三行；`doc/known-limitations.md` 标注 `tls` 仅支持默认 SSL。

## Workflow follow-up

- `openspec validate --strict` → 归档 → 覆盖 `f_llm/doc/spec/fix-channel-robustness/`。

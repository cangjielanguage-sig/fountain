# 开发环境（WSL Ubuntu 24.04）

这份文档只记「本机怎么把依赖跑起来、踩过哪些坑」，不描述 f_llm 的功能。

## MySQL

本机的 MySQL 不是 apt 装的，是二进制包解压在 `/opt/mysql97`（9.7.4）：

| 项 | 值 |
|---|---|
| 二进制 | `/opt/mysql97/bin/mysqld`、`mysql`、`mysqladmin` |
| 数据目录 | `/opt/mysql97/data`（属主 `mysql:mysql`） |
| 监听 | `127.0.0.1:3306` |
| 测试账号 | `fllm_test` / `fllm_test`，库 `fllm_test` |
| 向量组件 | `component_myvector`（已 `INSTALL COMPONENT`） |

### 启动命令（socket 路径不能改）

```bash
sudo -u mysql /opt/mysql97/bin/mysqld \
  --basedir=/opt/mysql97 --datadir=/opt/mysql97/data \
  --port=3306 --bind-address=127.0.0.1 \
  --socket=/tmp/mysql97.sock --pid-file=/tmp/mysql.pid \
  --log-error=/tmp/mysql-orig.err --daemonize

ss -xl | grep mysql97     # 应看到 /tmp/mysql97.sock
```

**为什么必须是 `/tmp/mysql97.sock`**：`mysql.MYVECTOR_INDEX_BUILD` 等存储过程内部按这个路径回连数据库。用 `/tmp/mysql.sock` 启动会看到：

```
ERROR: Error connecting to validate vector index request:
Can't connect to local MySQL server through socket '/tmp/mysql97.sock' (2)
```

建软链无效（会变成 `errno 13`，它要真实 socket）。症状是 `CALL` 返回后向量索引没建起来，测试报：

```
myvector_ann_set: Vector index not defined or not open for access
```

### 验证向量能力

```bash
/opt/mysql97/bin/mysql -h127.0.0.1 -ufllm_test -pfllm_test fllm_test -e "
DROP TABLE IF EXISTS vec_probe;
CREATE TABLE vec_probe(id INT PRIMARY KEY, v MYVECTOR(type=HNSW,dim=8,size=100,dist=COSINE,m=16,ef=100));
CALL mysql.MYVECTOR_INDEX_BUILD('fllm_test.vec_probe.v','id');"
```

看到 `SUCCESS: Index created & saved ...` 即正常。

### 停机

```bash
sudo /opt/mysql97/bin/mysqladmin --socket=/tmp/mysql97.sock -uroot shutdown
```

## 跑测试前先清残留

```bash
rm -rf /tmp/fllm-* /tmp/loom-*
cd f_llm && cjpm test
```

**原因**：测试用 `/tmp/fllm-*` 放 f_store 的 SST 文件；跑批被中断（超时、Ctrl-C）会留下半写文件，下次读到就抛：

```
OutOfMemoryError
  at fountain::f_store.SSTable::openFromFile(...)
```

看到这个错，先清目录；清完仍报，再按下一节加堆。

## 内存不足时加大堆

Cangjie 运行时用环境变量 `cjHeapSize` 控制堆：

```bash
export cjHeapSize=4gb      # 默认只有几百 MB
cd f_llm && cjpm test
```

典型需要加堆的场景：`f_store` 压缩/合并用例、大向量检索用例。加到 4GB 后本机全量 424 条稳定通过。

## 常用命令

```bash
# 全量
cd f_llm && cjpm test

# 单类
cd f_llm && cjpm test --filter=LoomPersona_test

# 完整重建（改过公共依赖后）
cd f_llm && cjpm clean && cjpm test
```

## 已知环境陷阱

| 现象 | 原因 | 处理 |
|---|---|---|
| `myvector_index_build` 报 socket 连不上 | MySQL 用了 `/tmp/mysql.sock` 启动 | 改用 `/tmp/mysql97.sock` |
| `Vector index not defined or not open` | 上一条的后果，索引没建成 | 同上，重建索引 |
| `OutOfMemoryError @ SSTable.openFromFile` | `/tmp/fllm-*` 残留坏文件 | `rm -rf /tmp/fllm-*` |
| `Table ... doesn't exist` / 结果条数翻倍 | 多个测试类共用 `fllm_test` 库、互相 DROP/CREATE | 清库 `DROP DATABASE fllm_test; CREATE DATABASE fllm_test;` |
| `Connection refused 127.0.0.1:3306` | MySQL 没起 | 按上面的启动命令拉起 |

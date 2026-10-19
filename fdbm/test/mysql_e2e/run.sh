#!/bin/bash
# MySQL 8.0 真库联调入口。
# 共享夹具见 fdbm/test/e2e/，后端默认 127.0.0.1:3306（可用 FDBM_E2E_MYSQL_* 覆盖）。
set -euo pipefail
exec bash "$(cd "$(dirname "$0")/../e2e" && pwd)/run.sh" mysql

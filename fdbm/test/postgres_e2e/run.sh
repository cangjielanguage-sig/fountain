#!/bin/bash
# 兼容入口：PostgreSQL 后端转调共享夹具。
# 新入口：bash fdbm/test/e2e/run.sh postgres
set -euo pipefail
exec bash "$(cd "$(dirname "$0")/../e2e" && pwd)/run.sh" postgres

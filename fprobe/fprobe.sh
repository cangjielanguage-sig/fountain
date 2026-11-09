#!/usr/bin/env bash
#
# Copyright (c) 2026 WuJingrun（吴京润）
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# fprobe.sh - fprobe 启动脚本
#
# 用法:
#   ./fprobe.sh agent       [额外参数...]
#   ./fprobe.sh supervisor  [额外参数...]
#   ./fprobe.sh resident    [额外参数...]
#
# 约定:
#   1. 每个子命令对应一个函数，函数内列出该模式读取的全部配置项；
#   2. 默认值非空的配置项写成实际参数，默认值即参数值；
#   3. 默认未配置（空串 / 空数组）或默认关闭的可选项整块注释，注释中保留默认值；
#   4. 脚本名之后的额外参数会追加在默认参数之后，优先级更高，可覆盖任意默认值。
#
# 可执行文件解析顺序: $FPROBE_BIN > ./target/release/bin/main > PATH 中的 fprobe。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

resolve_bin() {
    if [[ -n "${FPROBE_BIN:-}" ]]; then
        printf '%s\n' "${FPROBE_BIN}"
        return 0
    fi
    if [[ -x "${SCRIPT_DIR}/target/release/bin/main" ]]; then
        printf '%s\n' "${SCRIPT_DIR}/target/release/bin/main"
        return 0
    fi
    if command -v fprobe >/dev/null 2>&1; then
        command -v fprobe
        return 0
    fi
    return 1
}

if ! FPROBE_BIN="$(resolve_bin)"; then
    echo "fprobe.sh: 找不到 fprobe 可执行文件" >&2
    echo "  请先在模块目录执行 cjpm build，或用 FPROBE_BIN=/path/to/fprobe 指定" >&2
    exit 127
fi

run_fprobe() {
    exec "${FPROBE_BIN}" "$@"
}

usage() {
    cat <<'EOF'
fprobe - 服务器监控节点代理与多节点监督端

用法:
  fprobe.sh agent              在服务器节点上启动采集代理
  fprobe.sh supervisor         启动多节点监督端（TUI）
  fprobe.sh resident           以常驻模式启动（无 TUI，日志输出）
  fprobe.sh --help             显示本帮助

每个子命令都预置了该模式的完整默认配置，脚本名之后的参数会覆盖对应默认值:
  ./fprobe.sh agent --probe_port=12324
  ./fprobe.sh supervisor --probe_nodes=web1@10.0.0.1:12323,web2@10.0.0.2:12323
  ./fprobe.sh resident --probe_alarmRules='[{"name":"cpu-high","kind":"cpu","path":"$.usagePercent","op":"gt","threshold":85,"forSeconds":60,"level":"warning"}]'
EOF
}

fprobe_agent() {
    local -a args=(
        # ---- 基础 ----
        "--probe_port=12323"
        "--probe_hostId=1"
        "--probe_host=$(hostname 2>/dev/null || echo localhost)"
        "--probe_intervalMs=5000"

        # ---- 扩展动态库 ----
        "--probe_customDir=./custom"
        "--probe_customFailFast=true"

        # ---- 磁盘 ----
        "--probe_diskExcludeFs=tmpfs,devtmpfs,overlay,squashfs"

        # ---- 超时 ----
        "--probe_httpTimeoutMs=2000"
        "--probe_commandTimeoutMs=3000"

        # ---- 可选探针：默认未配置，整块注释 ----
        # 服务可达性，格式 name@url 或 name@tcp://host:port，多个用逗号分隔（默认空）
        # "--probe_serviceTargets=web@http://127.0.0.1:8080,db@tcp://127.0.0.1:3306"
        # f_mvc 健康检查地址，必须是 http(s)（默认空）
        # "--probe_mvcHealthUrl=http://127.0.0.1:8080/health"
        # f_rpc 健康目标，格式 name@host:port，多个用逗号分隔（默认空）
        # "--probe_rpcHealthTargets=svc@127.0.0.1:12321"
        # SNMP 设备，格式 name@host@community，多个用逗号分隔（默认空）
        # "--probe_snmpDevices=sw1@10.0.0.1@public"
        # IPMI 硬件健康，默认关闭
        # "--probe_ipmiEnabled=false"
        # SMART 磁盘路径，多个用逗号分隔（默认空）
        # "--probe_smartDevices=/dev/sda,/dev/sdb"
        # 只统计指定网卡，多个用逗号分隔；默认空表示统计全部网卡
        # "--probe_networkInterfaces=eth0,eth1"
    )

    if (($# > 0)); then
        args+=("$@")
    fi
    run_fprobe agent "${args[@]}"
}

# supervisor 的 TUI 模式与 resident 模式共用同一份配置；
# 两个函数各自列全，修改配置项时请同步另一处。
fprobe_supervisor() {
    local -a args=(
        # ---- 节点与拉取 ----
        "--probe_nodes=localhost@127.0.0.1:12323"
        "--probe_hostId=1"
        "--probe_pollIntervalMs=5000"
        "--probe_nodeTimeoutMs=3000"
        "--probe_missingThreshold=2"
        "--probe_historyPoints=60"

        # ---- 告警 ----
        "--probe_alarmCooldownSeconds=300"
        "--probe_alarmRecoverNotify=true"
        "--probe_alarmChannels=email"
        # 告警规则，JSON 数组，默认空（不告警）
        # '--probe_alarmRules=[{"name":"cpu-high","kind":"cpu","path":"$.usagePercent","op":"gt","threshold":85,"forSeconds":60,"level":"warning"}]'
        # 每个节点都应存在的监控项，缺失即告警，默认空
        # "--probe_expectKinds=cpu,memory,disk,system,network,hardware,topology"

        # ---- 图表类型覆盖：默认不写这些键，由 ChartSelector 内置默认决定 ----
        # "--probe_chart_cpu_usagePercent=line"
        # "--probe_chart_memory_usedPercent=area"
        # "--probe_chart_disk_usedPercent=bar"
        # "--probe_chart_network_rxBps=line"
        # "--probe_chart_service_latencyMs=line"

        # ---- 周期报告：默认关闭（probe_reportCron 为空） ----
        # CRON 为 6 段：秒 分 时 日 月 周；下面表示每 5 分钟一次
        # "--probe_reportCron=0 0/5 * * * *"
        # "--probe_reportReceivers=ops@example.com"
        # "--probe_reportTmpDir=./data/fprobe-report"
        # 文档保留项，当前版本未接线
        # "--probe_reportChannels=email"

        # ---- 邮件告警渠道：默认关闭（smtpHost 为空时不构建 email 渠道） ----
        # "--probe_channel_email_smtpHost=smtp.example.com"
        # "--probe_channel_email_smtpPort=465"
        # "--probe_channel_email_smtpUser=fprobe@example.com"
        # "--probe_channel_email_smtpPassword="
        # "--probe_channel_email_smtpTls=true"
        # "--probe_channel_email_from=fprobe@example.com"
        # "--probe_channel_email_receivers=ops@example.com"
        # 有权指挥智能体的账号
        # "--probe_channel_email_replyAccount=ops@example.com"
        # "--probe_channel_email_subjectPrefix=[fprobe]"
        # "--probe_channel_email_imapHost=imap.example.com"
        # "--probe_channel_email_imapPort=993"
        # 文档保留项，当前版本未接线
        # "--probe_channel_email_receiveLimit=20"

        # ---- LLM 智能体：默认关闭 ----
        # "--probe_llmAgent=false"
        # "--probe_llmName=deepseek-flash"
        # "--probe_llmTrigger=alarm"
        # "--probe_llmReplyPollMs=30000"
        # "--probe_llmIntervalMs=300000"
        # "--probe_llmMuteSeconds=600"
        # "--probe_replyStateFile=./data/reply-state.json"
        # 文档保留项，当前版本未接线
        # "--probe_llmMaxTokens="
    )

    if (($# > 0)); then
        args+=("$@")
    fi
    run_fprobe supervisor "${args[@]}"
}

fprobe_resident() {
    local -a args=(
        # ---- 节点与拉取 ----
        "--probe_nodes=localhost@127.0.0.1:12323"
        "--probe_hostId=1"
        "--probe_pollIntervalMs=5000"
        "--probe_nodeTimeoutMs=3000"
        "--probe_missingThreshold=2"
        "--probe_historyPoints=60"

        # ---- 告警 ----
        "--probe_alarmCooldownSeconds=300"
        "--probe_alarmRecoverNotify=true"
        "--probe_alarmChannels=email"
        # 告警规则，JSON 数组，默认空（不告警）
        # '--probe_alarmRules=[{"name":"cpu-high","kind":"cpu","path":"$.usagePercent","op":"gt","threshold":85,"forSeconds":60,"level":"warning"}]'
        # 每个节点都应存在的监控项，缺失即告警，默认空
        # "--probe_expectKinds=cpu,memory,disk,system,network,hardware,topology"

        # ---- 图表类型覆盖：默认不写这些键，由 ChartSelector 内置默认决定 ----
        # "--probe_chart_cpu_usagePercent=line"
        # "--probe_chart_memory_usedPercent=area"
        # "--probe_chart_disk_usedPercent=bar"
        # "--probe_chart_network_rxBps=line"
        # "--probe_chart_service_latencyMs=line"

        # ---- 周期报告：默认关闭（probe_reportCron 为空） ----
        # CRON 为 6 段：秒 分 时 日 月 周；下面表示每 5 分钟一次
        # "--probe_reportCron=0 0/5 * * * *"
        # "--probe_reportReceivers=ops@example.com"
        # "--probe_reportTmpDir=./data/fprobe-report"
        # 文档保留项，当前版本未接线
        # "--probe_reportChannels=email"

        # ---- 邮件告警渠道：默认关闭（smtpHost 为空时不构建 email 渠道） ----
        # "--probe_channel_email_smtpHost=smtp.example.com"
        # "--probe_channel_email_smtpPort=465"
        # "--probe_channel_email_smtpUser=fprobe@example.com"
        # "--probe_channel_email_smtpPassword="
        # "--probe_channel_email_smtpTls=true"
        # "--probe_channel_email_from=fprobe@example.com"
        # "--probe_channel_email_receivers=ops@example.com"
        # 有权指挥智能体的账号
        # "--probe_channel_email_replyAccount=ops@example.com"
        # "--probe_channel_email_subjectPrefix=[fprobe]"
        # "--probe_channel_email_imapHost=imap.example.com"
        # "--probe_channel_email_imapPort=993"
        # 文档保留项，当前版本未接线
        # "--probe_channel_email_receiveLimit=20"

        # ---- LLM 智能体：默认关闭 ----
        # "--probe_llmAgent=false"
        # "--probe_llmName=deepseek-flash"
        # "--probe_llmTrigger=alarm"
        # "--probe_llmReplyPollMs=30000"
        # "--probe_llmIntervalMs=300000"
        # "--probe_llmMuteSeconds=600"
        # "--probe_replyStateFile=./data/reply-state.json"
        # 文档保留项，当前版本未接线
        # "--probe_llmMaxTokens="
    )

    if (($# > 0)); then
        args+=("$@")
    fi
    # resident 必须紧跟在 supervisor 之后，不能被配置项隔开
    run_fprobe supervisor resident "${args[@]}"
}

main() {
    local command="${1:-}"
    if (($# > 0)); then
        shift
    fi

    case "${command}" in
        agent)
            fprobe_agent "$@"
            ;;
        supervisor)
            fprobe_supervisor "$@"
            ;;
        resident)
            fprobe_resident "$@"
            ;;
        -h | --help)
            usage
            ;;
        *)
            usage >&2
            exit 2
            ;;
    esac
}

main "$@"

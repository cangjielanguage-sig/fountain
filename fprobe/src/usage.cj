/*
Copyright (c) 2026 WuJingrun（吴京润）

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/
package fountain::fprobe

/**
 * 命令行用法文本。
 *
 * 顶层帮助列出子命令；子命令帮助只列该模式的关键配置项。
 */
public class Usage {
    public static func root(): String {
        '''
fprobe - 服务器监控节点代理与多节点监督端

用法:
  fprobe agent              在服务器节点上启动采集代理
  fprobe supervisor         启动多节点监督端（TUI）
  fprobe supervisor resident
                            以常驻模式启动（无 TUI，日志输出）
  fprobe --help             显示本帮助

配置项使用 `probe_` 前缀，可通过配置文件、环境变量或 `--key=value` 传入。
'''
    }

    public static func agent(): String {
        '''
fprobe agent - 在服务器节点上启动采集代理

用法:
  fprobe agent [--key=value]

关键配置项:
  probe_port           RPC 监听端口，默认 12323
  probe_host           主机标识，默认本机名
  probe_intervalMs     采集间隔（毫秒），默认 5000
  probe_customDir      扩展动态库目录，默认 ./custom
  probe_customFailFast 扩展加载失败是否终止启动，默认 true
'''
    }

    public static func supervisor(): String {
        '''
fprobe supervisor - 启动多节点监督端

用法:
  fprobe supervisor [--key=value]
  fprobe supervisor resident [--key=value]

关键配置项:
  probe_nodes             节点列表，格式 name@host:port，逗号分隔
  probe_pollIntervalMs    拉取间隔（毫秒），默认 5000
  probe_nodeTimeoutMs     单节点单次拉取超时（毫秒），默认 3000
  probe_missingThreshold  连续失败告警阈值，默认 2
  probe_historyPoints     历史点数，默认 60
'''
    }
}

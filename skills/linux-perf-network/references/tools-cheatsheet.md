# 网络排查工具速查

## 连通性与路径

| 工具 | 关键用法 | 看什么 |
|---|---|---|
| ping | `ping -c3 host` | RTT 与丢包（ICMT 被禁时不可全信） |
| mtr | `mtr -rwzbc 50 host` | 逐跳 RTT 与丢包率，定位丢包在哪一跳 |
| tracepath | `tracepath host` | 路径 MTU 发现，识别 PMTU 黑洞 |
| iperf3 | `iperf3 -c host -t 30` | 端到端带宽/PPS 基准 |

## 套接字与协议栈

| 工具 | 关键用法 | 看什么 |
|---|---|---|
| ss | `ss -s`；`ss -ti`；`ss -lnt` | socket 概览/TIME_WAIT；TCP 重传 cwnd rtt；监听 backlog |
| nstat | `nstat -az` | TcpRetransSegs、ListenOverflows、TcpExt* 全量计数 |
| sar | `sar -n DEV 1` / `sar -n TCP,ETCP 1` | 网卡 PPS/带宽；连接与重传统计 |
| ip | `ip -s link`；`ip route` | 网卡 RX dropped/error；路由 |
| conntrack | `conntrack -L \| wc -l` | conntrack 表用量，对比 nf_conntrack_max |
| curl | `curl -w` 分阶段计时 | dns/connect/ttfb/total 各段延迟 |

## bcc/eBPF 工具

| 工具 | 用途 |
|---|---|
| `tcpdrop-bpfcc` | 内核 TCP 丢包事件及原因（丢包首选） |
| `tcpretrans-bpfcc` | 重传与 TLP 实时事件 |
| `tcpconnlat-bpfcc` | 主动 connect 建连延迟 |
| `tcprtt-bpfcc` | RTT 直方图 |
| `tcplife-bpfcc` | 连接生命周期（时长、收发字节、端口） |
| `tcpstates-bpfcc` | TCP 状态变迁及各状态停留时间 |
| `tcpsynbl-bpfcc` | SYN backlog 溢出 |
| `gethostlatency-bpfcc` | getaddrinfo/gethostbyname DNS 解析耗时（按进程） |
| `tcpconnect/tcpaccept-bpfcc` | 主动/被动连接事件 |
| `netqtop-bpfcc` | 网卡多队列上的包分布 |
| `softirqs-bpfcc` | 软中断耗时（NET_RX/NET_TX） |

## 抓包与 DNS

```sh
tcpdump -i any -nn -w /tmp/cap.pcap host <ip>          # Wireshark 分析
# Wireshark 过滤：dns / tcp.analysis.retransmissions / tcp.flags.syn==1
dig +trace <domain>; dig <domain> @<ns>; nslookup <domain>
```

## 关键 sysctl（语义以内核文档为准）

| 参数 | 判定要点 |
|---|---|
| `net.core.somaxconn` | listen backlog 上限；与应用 backlog、tcp_max_syn_backlog 一起调 |
| `net.ipv4.tcp_max_syn_backlog` | 半连接队列上限 |
| `net.ipv4.ip_local_port_range` | 本地端口范围；端口耗尽时扩大，避开 reserved_ports |
| `net.ipv4.tcp_tw_reuse` | 0 关/1 全局/2 仅回环（现代内核默认 2），NAT 环境谨慎 |
| `net.ipv4.tcp_rmem/wmem` | 缓冲区三档；高 BDP 链路调 max，勿盲目 setsockopt 固定值 |
| `net.netfilter.nf_conntrack_max` | 默认等于哈希桶数；表满即丢包，dmesg 可见 table full |
| `net.ipv4.tcp_congestion_control` | 拥塞算法，可用列表见 tcp_available_congestion_control |

## 关键判定

- **TcpRetransSegs 持续增长** → 确实在丢包/抖动；mtr 找丢包跳，tcpdrop 看内核原因。
- **ListenOverflows/ListenDrops** 增长 → accept 队列溢出，同步调三件套。
- TIME_WAIT 量大但无端口耗尽通常无害；伴随 `Cannot assign requested address` 才处理，优先长连接。
- conntrack count 接近 max → 调大 max/buckets 或减少 NAT 依赖。
- MTU 问题：大包挂小包通、TLS 握手卡住，tracepath 验证；修复用统一 MTU + MSS clamping。
- DNS 慢先用 `curl -w` 的 time_namelookup 与连接慢区分开。

## 故障注入（实验用，用完清理）

```sh
tc qdisc add dev eth0 root netem loss 30%      # 30% 丢包
tc qdisc add dev eth0 root netem delay 100ms   # 100ms 延迟
iptables -I INPUT -m statistic --mode random --probability 0.3 -j DROP
# 清理
tc qdisc del dev eth0 root; iptables -F
```

---
name: linux-perf-network
description: Linux 网络性能诊断。当出现网络延迟高、DNS 解析慢或抖动、丢包重传、NAT/conntrack 导致并发连接上不去或延迟增大、MTU 不匹配、端口耗尽、TIME_WAIT 堆积、SYN backlog 溢出、TCP 连接异常、Nginx 访问变慢、tcpdump/Wireshark 抓包分析，或需要用 ss/netstat/sar -n/tc/iptables/nstat/PSI/tcpretrans/tcpdrop/dig 定位网络问题时使用。配套 dns、network-latency、nat、packet-drop 四个可复现案例。
license: MIT
metadata:
  domain: network
  source: "Linux 性能诊断教学案例集"
---

# Linux 网络性能诊断

涉及延迟、丢包、DNS、NAT/conntrack、MTU、连接数瓶颈时加载。案例在 `cases/`，Docker 复现；网络案例常用 `tc netem`/`iptables` 注入故障。

## 分层诊断流程

1. **确认可达与基础指标**：`ping -c3`（连通性与 RTT）、`mtr -rwzbc 50`（逐跳丢包定位）、`sar -n DEV 1`（网卡 PPS/带宽/丢包）、`ip -s link`（RX/TX dropped、error）。
2. **协议栈与套接字**：
   - `ss -s`（socket 总览/TIME_WAIT 统计）、`ss -lnt`（监听队列，`Send-Q` 即 backlog）、`ss -ti`（每条连接的 RTT、cwnd、retrans、rttvar）。
   - `nstat -az`：重点看 `TcpRetransSegs`（重传）、`ListenOverflows`/`ListenDrops`（accept 队列溢出）、`TcpExtTCPConnectionTimeout`、`IpExtInNoRoutes`。
3. **eBPF 动态跟踪（bcc）**：`tcpdrop-bpfcc`（内核丢包及原因）、`tcpretrans-bpfcc`（重传实时事件）、`tcpconnlat-bpfcc`（主动建连延迟）、`tcprtt-bpfcc`（RTT 直方图）、`tcpstates-bpfcc`（状态变迁耗时）、`tcpsynbl-bpfcc`（SYN backlog）、`gethostlatency-bpfcc`（getaddrinfo 解析延迟）、`netqtop-bpfcc`（网卡队列分布）。
4. **抓包定位**：`tcpdump -i eth0 -nn 'host x and port y' -w /tmp/a.pcap`，Wireshark 过滤 `tcp.analysis.retransmissions`、`dns`、`tcp.flags.syn==1`（DNS 案例附带 pcap 可直接分析）。
5. **中间件层**：Nginx `$request_time`/`$upstream_response_time` 日志分段、错误日志、`sslsniff-bpfcc`（必要时解密前的明文观测）。
6. **内核瓶颈**：conntrack 表、本地端口范围、somaxconn、MTU、缓冲区。

## 根因模式与案例

### 模式 A：DNS 解析抖动（cases/dns，案例 37）
- 现象：请求偶发变慢，卡在域名解析阶段。
- 素材：三个预抓 pcap（`ping.pcap`、`web.pcap`、`4-times-close.pcap`）+ dnsmasq 容器（`dnsmasq.conf`、`resolv.conf.dnsmasq`）。
- 手法：`dig +trace`、`dig @<ns>` 对比权威/递归耗时；bcc `gethostlatency-bpfcc` 直接按进程输出解析耗时；Wireshark 过滤 `dns` 看超时重传、AAAA/A 串行查询、TTL。
- 常见根因：上游 DNS 慢、UDP 53 丢包后退避、nsswitch 串行查找、未启用本地缓存。修复：部署 dnsmasq/nscd/systemd-resolved 缓存、合理 TTL、调整 `/etc/resolv.conf` 的 `timeout:`/`attempts:`、应用侧连接池复用避免重复解析。

### 模式 B：链路延迟（cases/network-latency，案例 40）
- Nginx 单容器，延迟注入与观测练习。
- 手法：`ping` 看 RTT、`tc qdisc show`、`curl -w` 分阶段计时（dns/connect/ttfb/total）、`ss -ti` 看重传与 RTT、`tcprtt-bpfcc` 看分布。
- 修复方向：确认跨可用区/地域链路、开启 keepalive 复用连接、评估拥塞控制算法（`sysctl net.ipv4.tcp_congestion_control`，现代内核默认 `cubic`，长肥管道可评估 `bbr`）。

### 模式 C：NAT 与 conntrack 限制并发（cases/nat，案例 41/42）
- 根因：容器端口映射依赖 iptables NAT，每连接占用一条 conntrack 表项和一个本地端口；表满或端口耗尽后新连接被丢、延迟飙升。
- 量化：`conntrack -L | wc -l` 对比 `nf_conntrack_max`；`dmesg | grep conntrack`（"table full, dropping packet"）；`dropwatch.stp`（SystemTap）定位内核丢包点，现代替代 `dropwatch -l kas` 或 `tcpdrop-bpfcc`。
- 官方默认值（内核文档）：`nf_conntrack_max` 默认等于 conntrack 哈希桶数 `nf_conntrack_buckets`，而桶数默认是内存推算值（约 totalram_pages/... 的架构相关值），小规格机器上很容易成为瓶颈。
- 修复：调大 `net.netfilter.nf_conntrack_max`（同时评估桶数 `nf_conntrack_buckets`，模块加载参数）、扩大 `ip_local_port_range`、复用长连接；高并发用 hostNetwork/IPVS/DSR 替代 iptables NAT。

### 模式 D：丢包与 MTU（cases/packet-drop，案例 47/48）
- 故障注入全在 `start.sh`：
  - `ifconfig eth0 mtu 100` —— 超小 MTU 制造大量分片；
  - `tc qdisc add dev eth0 root netem loss 30%` —— 30% 模拟丢包；
  - `iptables ... --mode random --probability 0.30 -j DROP`（INPUT/OUTPUT 各一条）。
- 手法：`nstat` 看 TcpRetransSegs、`ip -s link` 看 RX dropped、`ss -ti` 看 retrans；`mtr` 逐跳定位丢包点；`tracepath` 发现 PMTU 黑洞；`tcpdrop-bpfcc` 直接给出内核丢弃原因。
- 修复：清除故障规则（`tc qdisc del`、`iptables -F`）、统一 MTU 并开启 MSS clamping（`iptables ... --clamp-mss-to-pmtu`）、排查缓冲区 `rmem/wmem` 与 `somaxconn`。

## 关键 sysctl 语义（依据内核官方文档，避免凭经验误调）

| 参数 | 语义与判定 |
|---|---|
| `net.core.somaxconn` | `listen()` backlog 上限；连接被拒/`ListenOverflows` 增长时调大，且应用层 backlog 要同步调（Nginx `backlog`、Go `net.ListenConfig`） |
| `net.ipv4.tcp_max_syn_backlog` | SYN_RECV 半连接队列上限；官方文档明确提示要与 somaxconn 一起检查 |
| `net.ipv4.ip_local_port_range` | 主动连接的本地端口范围；端口耗尽（`Cannot assign requested address`）时扩大，注意避开 `ip_local_reserved_ports` |
| `net.ipv4.tcp_tw_reuse` | 官方语义：0 关闭、1 全局启用、**2 仅回环启用（现代内核默认值）**；NAT/非回环环境需谨慎评估，不要无脑设 1 |
| `net.ipv4.tcp_rmem/wmem` | 三档 min/default/max；高 BDP 链路调 max，盲目设 `SO_SNDBUF` 会关闭内核自动调优 |
| `net.netfilter.nf_conntrack_max` | conntrack 表项上限，默认等于哈希桶数；表满直接丢包 |
| `net.ipv4.tcp_congestion_control` | 拥塞控制算法，`sysctl net.ipv4.tcp_available_congestion_control` 看可用列表 |

## 补充高频场景

- **SYN backlog 溢出**：`tcpsynbl-bpfcc` 或 `nstat` 的 ListenOverflows；同步调 somaxconn、应用 backlog、tcp_max_syn_backlog。
- **TIME_WAIT 堆积**：先判断是否真有害（主动关闭方才产生 TW，且 TW 本身很轻量）；只有伴随端口耗尽才需处理，优先长连接/连接池，再评估 tw_reuse。
- **软中断瓶颈**：PPS 打满单核（`mpstat` 的 si%、`softirqs-bpfcc`），开启 RPS/RFS、调整 NIC 队列数与中断亲和性、检查是否为单队列网卡。
- **DNS 53 端口的 UDP/TCP 差异**：截断响应（TC 标志）会回退 TCP，抓包时两种协议都要覆盖。

## 常用命令速查（详见 references/tools-cheatsheet.md）

```sh
ping -c3 host; mtr -rwzbc 50 host; tracepath host
ss -s; ss -ti; ss -lnt
nstat -az; sar -n DEV 1; ip -s link
tcpdump -i any -nn -w /tmp/cap.pcap host <ip>
dig +trace <domain>; gethostlatency-bpfcc
tcpdrop-bpfcc; tcpretrans-bpfcc; tcpconnlat-bpfcc; tcprtt-bpfcc
conntrack -L | wc -l; sysctl net.netfilter.nf_conntrack_max
tc qdisc show dev eth0; iptables -nvL
curl -o /dev/null -sw 'dns:%{time_namelookup} conn:%{time_connect} ttfb:%{time_starttransfer} total:%{time_total}\n' <url>
```

## 复现实验

```sh
cd cases/dns && docker build -t local/dns-lab images/ && docker run -it local/dns-lab
cd cases/packet-drop && make build && make run        # 容器启动即注入 30% 丢包 + MTU 100
cd cases/nat && make build && make run
cd cases/network-latency && make build && make run
```

注意：`tc`/`iptables` 故障注入需要 `NET_ADMIN` capability；实验结束记得清理规则，避免规则残留持续影响网络。

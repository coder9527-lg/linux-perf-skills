# 网络症状驱动排障决策树（Runbook）

## 症状 1：请求变慢，先分段

```
curl -o /dev/null -sw 'dns:%{time_namelookup} connect:%{time_connect} ttfb:%{time_starttransfer} total:%{time_total}\n' URL
├─ dns 段大 → 症状 2（DNS）
├─ connect 段大 → 症状 3（建连/丢包/队列）
├─ ttfb 大（connect 正常）→ 服务端处理慢，转对应 CPU/内存/IO 技能
└─ total 与 ttfb 接近但下载慢 → 带宽/拥塞，症状 4
```

## 症状 2：DNS 解析慢/抖动

```
dig +trace DOMAIN                 # 递归链路每一跳耗时
dig DOMAIN @NS                    # 直接问指定 NS，对比定位慢在上游还是本地
gethostlatency-bpfcc              # 按进程输出 getaddrinfo 实际耗时
tcpdump -i any -nn port 53        # UDP/TCP 53 都抓（截断响应回退 TCP）
├─ 首次慢、后续快 → 缺本地缓存：部署 dnsmasq/nscd/systemd-resolved
├─ 间歇性超时重传 → UDP 53 丢包，查 /etc/resolv.conf 的 timeout/attempts
├─ AAAA 与 A 串行查询放大延迟 → 按需关闭 IPv6 解析或调 nsswitch
└─ TTL 过短导致反复解析 → 合理调大 TTL（dns 案例）
```

## 症状 3：连接建立慢 / 失败

```
ss -lnt                           # Send-Q 是监听 backlog 当前上限
nstat -az | grep -E 'ListenOver|ListenDrop'
├─ ListenOverflows 增长 → accept 队列溢出
│   └─ 三件套一起调：net.core.somaxconn + 应用 backlog（Nginx/Go）+ tcp_max_syn_backlog
│       tcpsynbl-bpfcc 可实时看 SYN backlog
├─ 报 Cannot assign requested address
│   └─ 本地端口耗尽：cat /proc/sys/net/ipv4/ip_local_port_range，扩大范围
│       检查 TIME_WAIT 量（ss -s），优先长连接/连接池
├─ SYN 发出无响应/超时
│   ├─ tcpconnlat-bpfcc 看建连延迟分布
│   ├─ mtr 逐跳找丢包点；安全组/防火墙是否放行
│   └─ conntrack 表满：conntrack -L | wc -l 对比 nf_conntrack_max（nat 案例）
└─ 建连延迟周期性毛刺 → 查 conntrack 建立开销、ARP 表、DNS（回症状 2）
```

## 症状 4：已建立连接上的延迟与丢包

```
nstat -az | grep TcpRetransSegs   # 两次采样计数增长=确有重传
├─ 有重传
│   ├─ tcpdrop-bpfcc              # 内核丢包的具体原因（首选）
│   ├─ tcpretrans-bpfcc           # 重传事件实时流
│   ├─ mtr -rwzbc 50 HOST         # 定位丢包在哪一跳
│   ├─ ip -s link                 # 网卡 RX dropped/error
│   └─ ss -ti                     # 单连接 rtt/cwnd/retrans/rttvar
├─ 无重传但延迟高
│   ├─ tcprtt-bpfcc 看 RTT 分布；ping 对照基础 RTT
│   ├─ 跨可用区/地域链路 → 就近部署、keepalive 复用
│   └─ 评估拥塞控制：sysctl net.ipv4.tcp_congestion_control（长肥管道评估 bbr）
└─ 大包卡、小包通 → MTU/PMTU 黑洞
    tracepath HOST；修复统一 MTU + iptables --clamp-mss-to-pmtu（packet-drop 案例）
```

## 症状 5：NAT/网关/四层代理场景

```
dmesg | grep -i conntrack         # "table full, dropping packet"
├─ conntrack 表满
│   ├─ 调大 net.netfilter.nf_conntrack_max（同时评估 buckets）
│   ├─ 减少 NAT 依赖：hostNetwork、IPVS、DSR、长连接复用
│   └─ 无需跟踪的流量加 NOTRACK 规则
├─ 软中断打满单核（mpstat si%）
│   └─ RPS/RFS、多队列网卡、调中断亲和性；softirqs-bpfcc 确认 NET_RX
└─ netqtop-bpfcc 看网卡多队列包分布是否均衡
```

## 症状 6：TIME_WAIT / 连接数困惑

```
ss -s
├─ TIME_WAIT 量大但无端口耗尽、无报错
│   └─ 通常无害（主动关闭方才产生，内核维护成本低），不必谈 TW 色变
├─ 伴随端口耗尽或建连失败 → 回症状 3
│   ├─ 首选：长连接、连接池、复用
│   └─ tcp_tw_reuse 现代内核默认 2（仅回环），全局开 1 需按官方文档谨慎评估
└─ CLOSE_WAIT 堆积 → 应用未 close()，是应用 bug，用 lsof/ss -tp 定位进程
```

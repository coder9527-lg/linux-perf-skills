# 关键指标权威释义与判定阈值

释义依据内核官方文档（proc、PSI、cgroup-v2、ip-sysctl、nf_conntrack）整理。
阈值为通用起点，生产环境应结合基线与 SLO 校准，不是硬性红线。

## 一、CPU

| 指标 | 来源 | 官方口径 | 经验判定 |
|---|---|---|---|
| load average | `/proc/loadavg` | R 状态 + D（不可中断睡眠）任务的 1/5/15 分钟指数均值 | 持续 >CPU 核数说明排队；高但 CPU 闲多为 I/O |
| us/sy/wa/hi/si/st | `/proc/stat`、top | 用户态/内核态/iowait/硬中断/软中断/虚拟化窃取时间 | st 持续 >10% 考虑宿主机超卖迁移 |
| PSI cpu some | `/proc/pressure/cpu` | 至少一个任务因等 CPU 停滞的时间占比，avg10/60/300 窗口 | avg10 持续 >10% 关注，>30% 需扩容/优化 |
| PSI cpu full | 同上 | 系统级 CPU full 无定义，内核 5.13 起上报 0 以兼容 | 恒为 0，不要误读 |
| nr_throttled | cgroup `cpu.stat` | 被 CFS 带宽限制的周期数 | 增长即容器在被限流 |
| r（vmstat） | vmstat | 运行队列中任务数 | 持续 >核数 = CPU 饱和 |
| cs（vmstat） | vmstat | 每秒上下文切换 | 结合 pidstat -w 区分自愿/非自愿 |

## 二、内存

| 指标 | 来源 | 官方口径 | 经验判定 |
|---|---|---|---|
| MemAvailable | `/proc/meminfo` | 估算的、无需换出即可分配的内存 | 判断余量以此为准，不是 MemFree |
| Buff/Cache | 同上 | 块缓冲与页缓存，可回收 | 高不等于泄漏 |
| PSI memory some | `/proc/pressure/memory` | 部分任务因内存回收停滞 | 增长即有回收压力 |
| PSI memory full | 同上 | 所有非空闲任务同时停滞（thrashing） | avg10 持续 >0 即严重颠簸 |
| pgscand/s | sar -B | 每秒直接回收（direct reclaim）次数 | 非 0 说明分配路径被同步回收拖慢 |
| si/so | vmstat | swap 换入/换出速率 | 持续非 0 对延迟敏感服务不可接受 |
| memory.events high | cgroup v2 | 超 memory.high 被节流回收次数 | 增长说明软上限在生效 |
| memory.events oom_kill | cgroup v2 | cgroup 内进程被 OOM 杀死次数 | 任何增长都需告警 |
| VmRSS | `/proc/PID/status` | 进程实际驻留物理内存 | 泄漏判定看其是否单调不降 |

## 三、磁盘 I/O

| 指标 | 来源 | 口径 | 经验判定 |
|---|---|---|---|
| %util | iostat | 设备忙碌时间占比 | 接近 100% 饱和；NVMe 多队列可能失真 |
| await | iostat | I/O 平均耗时（排队+服务，ms） | 对比设备基线；云盘看实例规格标称 |
| aqu-sz | iostat | 平均队列长度 | 持续 >1 有积压 |
| r_await/w_await | iostat | 读/写分开的平均耗时 | 分开定位读慢还是写慢 |
| PSI io some/full | `/proc/pressure/io` | 因 I/O 停滞的任务占比 | 比 wa% 更能反映多核真实卡顿 |
| biolatency P99 | bcc | 块 I/O 延迟分位数 | 比均值更能代表业务尾延迟 |

## 四、网络

| 指标 | 来源 | 官方口径 | 经验判定 |
|---|---|---|---|
| TcpRetransSegs | nstat（/proc/net/snmp） | 重传段累计数 | 两次采样增长即存在丢包/抖动 |
| ListenOverflows | nstat | 超过 listen backlog 被拒的连接 | 增长即 somaxconn/backlog 不足 |
| somaxconn | sysctl | listen() backlog 全局上限 | 高并发服务常见调至 4096 |
| tcp_tw_reuse | sysctl | 0 关/1 全局/2 仅回环（现代内核默认 2） | 不要无脑设 1 |
| nf_conntrack_max | sysctl | 连接跟踪表上限，默认等于哈希桶数 | 用量接近即调大或减少 NAT |
| ip_local_port_range | sysctl | 主动连接本地端口范围 | 端口耗尽时扩大，避开 reserved |
| RX dropped | `ip -s link` | 网卡/协议栈丢包计数 | 增长结合软中断与缓冲区排查 |
| rtt/cwnd/retrans | `ss -ti` | 单连接 RTT、拥塞窗口、重传数 | 连接级诊断的一手数据 |

## 五、PSI 阈值告警机制（内核文档）

PSI 支持 poll 通知：向 `/proc/pressure/<resource>` 写入 `<some|full> <停滞微秒> <窗口微秒>`，
再对 fd 做 poll/epoll 等待 `POLLPRI`。例如 `some 150000 1000000` 表示 1 秒窗口内
累计停滞超 150ms 即唤醒。窗口合法范围 500ms~10s；非特权用户窗口须为 2s 的倍数。
这比定期轮询 avg10 更适合做低延迟告警。

## 六、K8s 资源语义（官方文档）

- CPU limit 通过 **CFS 节流**强制（可短时突发后被限流），memory limit 超限直接 **OOMKilled**。
- CPU 单位：`1` = 1 核，`100m` = 0.1 核；内存单位：`Mi`/`Gi`（二进制）或 `M`/`G`（十进制）。
- 只设 limit 不设 request 时：CPU 的 request 默认取 limit 值；memory 行为类似但计费/调度要分别核对。
- Pod 级可在 `spec.resources` 统一设置 requests/limits。
- 容器状态 `OOMKilled`（退出码 137）优先排查 limit 与泄漏，而非节点全局内存。

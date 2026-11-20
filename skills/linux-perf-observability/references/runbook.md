# 工具选择决策树（可观测性 Runbook）

核心原则：**先低成本聚合指标定方向，再高成本事件跟踪抓细节**；先回答"哪个资源、哪个进程"，再回答"哪个函数、哪笔 I/O、哪个包"。

## 第一步：不知道问题在哪——USE 巡检

对每个资源依次检查使用率/饱和度/错误，30 秒完成全局扫描：

```
CPU:   uptime / mpstat -P ALL 1 / cat /proc/pressure/cpu
内存:  free -h / cat /proc/pressure/memory / sar -B 1
磁盘:  iostat -xz 1 / cat /proc/pressure/io
网络:  sar -n DEV 1 / nstat -az / ip -s link
其它:  fd 用量（cat /proc/sys/fs/file-nr）、conntrack 用量、dmesg 错误
```

任一资源的 Saturation（PSI、队列、backlog）或 Errors（dropped、oom、retrans）异常即锁定领域，
转对应领域技能；全部正常但业务仍慢，进入第二步。

## 第二步：按问题类型选工具

```
问题长什么样？
├─ "谁在烧 CPU"
│   ├─ perf top / profile-bpfcc（on-CPU 采样）→ 函数级热点
│   ├─ 火焰图：perf record -F99 -ag → flamegraph.pl
│   └─ top 看不到进程 → execsnoop（短时进程）
├─ "进程在等什么"（延迟问题，CPU 不忙但慢）
│   ├─ offcputime-bpfcc -df -p PID → off-CPU 栈
│   ├─ runqlat/runqslower → 等调度；biolatency → 等磁盘
│   └─ 锁竞争 → klockstat-bpfcc / offwaketime
├─ "内存去哪了/谁泄漏"
│   ├─ 进程排行 → ps/smem/pmap
│   ├─ 未释放分配的栈 → memleak-bpfcc
│   └─ 回收压力 → PSI memory / drsnoop
├─ "I/O 慢在哪一层"
│   ├─ 块设备 → biolatency/biosnoop
│   ├─ 文件 → filetop/fileslower/filelife
│   ├─ 缓存命中 → cachestat
│   └─ 系统调用 → strace -c / vfsstat
├─ "网络/连接问题"
│   ├─ 丢包 → tcpdrop / nstat / mtr
│   ├─ 延迟分段 → curl -w / tcpconnlat / gethostlatency
│   ├─ 连接生命周期 → tcpstates/tcplife
│   └─ 深度协议问题 → tcpdump 抓包 Wireshark
└─ "需要一次性临时统计"
    └─ bpftrace 一行流（bpftrace-lab 案例），优先 tracepoint 而非 kprobe
```

## 第三步：验证与回归

1. 修复前先存基线：同一条压测命令记录 P50/P95/P99 与资源指标。
2. 单变量修改，每次只动一个参数/一处代码。
3. 修复后同条件重测，用**差异火焰图**（difffolded.pl）或指标对比确认。
4. 动态跟踪工具下线，避免常驻事件采集的生产开销。

## 工具成本与权限对照

| 工具类型 | 典型开销 | 权限要求 | 适用时机 |
|---|---|---|---|
| /proc、vmstat、iostat、ss | 极低 | 普通用户 | 常驻监控、首查 |
| PSI | 极低 | 普通用户 | 容器/主机压力告警 |
| perf 采样 | 低（频率相关） | perf_event/perfmon | 热点定位 |
| bcc 聚合型（*lat/*top/*stat） | 中 | CAP_BPF/SYS_ADMIN | 方向确认 |
| bcc 事件型（*snoop）、bpftrace printf | 中高（事件量相关） | 同上 | 短时细节抓取 |
| strace | 高（ptrace 串行化） | 普通用户/ptrace 权限 | 单点深挖，避免长期附着生产进程 |
| tcpdump | 中高（流量相关） | CAP_NET_RAW | 协议级取证，限定过滤表达式 |
| valgrind | 极高（10~50 倍慢化） | 普通用户 | 测试环境内存正确性 |

## 采样常见坑

- 采样频率不是越高越好：99Hz 是避开锁相的常用值，高频采样本身扰动目标。
- 看不到用户态栈/函数名是十六进制 → 缺 frame pointer 或 dbgsym，见 tools-cheatsheet。
- 容器内 bcc 报版本错 → 内核与 bpfcc-tools 版本匹配问题；BTF/CO-RE 方案（bpftrace）抗版本漂移更好。
- kprobe attach 失败先怀疑内核符号变更，换 tracepoint 验证。

# CPU 症状驱动排障决策树（Runbook）

按"你看到的现象"进入，每条分支给出命令与下一步判定。

## 症状 1：load average 很高

```
uptime 看 1/5/15 分钟 load
├─ load 高且 top 的 us/sy 也高？
│   ├─ 是 → 进入症状 2（CPU 使用率高）
│   └─ 否（CPU 闲但 load 高）
│       ├─ ps -eo stat,cmd | grep '^D' 有 D 状态进程？
│       │   ├─ 是 → 瓶颈在 I/O，转 linux-perf-io（load 统计 R+D，D 也计入）
│       │   └─ 否 → 检查是否大量进程排队：runqlat-bpfcc、cat /proc/pressure/cpu
│       └─ 虚拟化环境同时看 st%，>10% 持续为宿主机超卖
```

## 症状 2：CPU 使用率高

```
top 看 %Cpu(s) 分解
├─ us% 高（用户态）
│   ├─ pidstat -u 1 能看到稳定高 CPU 进程？
│   │   ├─ 能 → perf top -p PID 定位函数
│   │   │        ├─ 业务函数热点 → 优化算法/循环/锁竞争（nginx-high-cpu 案例）
│   │   │        ├─ GC 热点（Java/Go）→ 转内存技能查堆与 GC 频率
│   │   │        └─ 解释器热点（PHP/Python）→ OPcache、编译型扩展、减少动态特性
│   │   └─ 看不到 → 症状 3：短时进程
├─ sy% 高（内核态）
│   ├─ strace -c -p PID 看系统调用量 → 高频 epoll/ioctl/读写 → 批量化、异步化
│   ├─ klockstat-bpfcc 看内核锁竞争
│   ├─ softirqs/hardirqs-bpfcc 中断耗时高 → 症状 4
│   └─ perf top 看内核函数（如 copy_user、调度函数）
├─ wa% 高 → 转 I/O 技能（先 cat /proc/pressure/io 确认是否真饱和）
└─ si%/hi% 高 → 症状 4
```

## 症状 3：top 看不到高 CPU 进程但 us% 高（短时进程）

```
execsnoop-bpfcc          # 一条命令抓所有 fork+exec，瞬时进程现形
├─ 看到高频外部命令（如 stress/curl/shell）
│   ├─ pstree -p PPID 找父进程
│   ├─ 修复：应用内用库调用替代 exec、合并脚本、降 cron 频率（short-lived-process 案例）
│   └─ 监控 agent 自身高频采集 → 调整采集间隔
└─ pidpersec-bpfcc 量化每秒新建进程速率（正常值应接近 0）
伴随大量 Z 状态僵尸：ps -eo pid,ppid,stat,cmd | grep Z → 父进程未 wait()
```

## 症状 4：软中断/中断高

```
mpstat -P ALL 1           # si% 是否集中在单个 CPU
├─ 集中单核 → 网卡单队列/中断亲和性问题
│   ├─ cat /proc/interrupts 看网卡中断分布
│   ├─ cat /proc/irq/N/smp_affinity 调亲和性打散
│   ├─ 开启 RPS/RFS，或用多队列网卡（SoloRSS/驱动队列数）
│   └─ softirqs-bpfcc 确认是 NET_RX 还是 TIMER
└─ 多核都高 → 真的包量大，评估 PPS 上限、offload（GRO/TSO）、转网络技能
```

## 症状 5：容器内应用延迟毛刺，但平均 CPU 不高

```
cat /sys/fs/cgroup/cpu.stat          # v2
├─ nr_throttled / throttled_usec 持续增长？
│   ├─ 是 → CFS 节流（cfs-throttle 案例）
│   │   ├─ 提高 --cpus / limits.cpu
│   │   ├─ 评估 cpu.max.burst（5.14+）
│   │   └─ 降低 worker 瞬时并发
│   └─ 否 → runqlat-bpfcc 看宿主机全局调度排队，可能是邻居容器噪声
└─ docker stats 的 CPU% 是相对单核口径，多核可超 100%，别误读
```

## 症状 6：上下文切换频繁

```
pidstat -w 1
├─ nvcswch/s（非自愿切换）高 → CPU 不够用、时间片被抢，结合 runqlat
├─ cswch/s（自愿切换）高 → 进程频繁主动睡眠（等 I/O/锁），offcputime-bpfcc 看阻塞栈
└─ vmstat 的 cs 列做系统级总量对照
```

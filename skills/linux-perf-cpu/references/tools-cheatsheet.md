# CPU 排查工具速查

## 基础工具

| 工具 | 关键用法 | 看什么 |
|---|---|---|
| uptime | `uptime` | 1/5/15 分钟 load average（R+D 状态均值），持续超过 CPU 核数即饱和 |
| top | `top`，按 P 排序、`1` 展开每核 | us/sy/wa/hi/si/st、load、%CPU |
| vmstat | `vmstat 1` | r=运行队列长度；us/sy/wa；cs=上下文切换；in=中断 |
| mpstat | `mpstat -P ALL 1` | 单核热点、软中断 si% 集中在哪核 |
| pidstat | `pidstat -u 1` / `pidstat -w 1` | 进程 CPU；自愿(cswch)/非自愿(nvcswch)切换 |
| ps | `ps -eo pid,ppid,stat,psr,pcpu,cmd --sort -pcpu \| head` | 进程排行、D/Z 状态、运行核 |

## PSI 与调度（现代内核）

| 工具 | 关键用法 | 看什么 |
|---|---|---|
| PSI | `cat /proc/pressure/cpu` | some 的 avg10/60/300 停滞占比、total 累计微秒（毛刺检测） |
| runqlat | `runqlat-bpfcc 1` | 运行队列等待延迟直方图（调度饱和的直接证据） |
| runqlen | `runqlen-bpfcc 1` | 运行队列长度分布 |
| runqslower | `runqslower-bpfcc 10000` | 超过 10ms 的调度延迟事件及进程 |
| cpudist | `cpudist-bpfcc 1` | 每任务 on-CPU/off-CPU 时长分布 |
| offcputime | `offcputime-bpfcc -df -p PID 10` | off-CPU 内核栈，回答"在等什么" |
| profile | `profile-bpfcc -af 49` | 全系统栈采样（perf 的 bcc 等价物） |
| softirqs/hardirqs | `softirqs-bpfcc 1` | 软/硬中断耗时 |
| llcstat | `llcstat-bpfcc` | 各进程末级缓存引用与未命中 |

## perf

```sh
perf top -p PID                    # 实时函数热点
perf record -F99 -a -g -- sleep 30 && perf report
perf stat -p PID sleep 10          # IPC、cache-miss、上下文切换计数
perf trace -p PID                  # 系统调用流
```

## 短时进程与僵尸

```sh
execsnoop-bpfcc                    # 抓 fork+exec 短时进程
pidpersec-bpfcc                    # 每秒新建进程数
ps -eo pid,ppid,stat,cmd | grep Z  # 僵尸（STAT=Z），用 PPID 找失职父进程
```

## 容器

```sh
cat /sys/fs/cgroup/cpu.stat        # v2: nr_throttled/throttled_usec/nr_bursts
cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us   # v1 配额
docker stats                       # 注意 CPU% 相对单核，可超 100%
```

## 关键判定

- **us 高**：应用代码热点，perf/profile 找函数。
- **sy 高**：系统调用/锁/内核线程，strace/perf 看内核栈，`klockstat-bpfcc` 查锁。
- **wa 高**：转 I/O 技能；**si 高**：网卡/磁盘中断，mpstat + softirqs，调中断亲和性/RPS。
- **st 高（虚拟化）**：宿主机超卖，>10% 持续即考虑迁移。
- load 高但 CPU 闲：多为 I/O 等待或 D 状态进程，`ps -eo stat,cmd | grep D`。
- 容器延迟毛刺但平均 CPU 不高：优先查 `cpu.stat` 节流计数。
- 僵尸进程根因永远是父进程未 wait/waitpid；`SIGCHLD` 置 `SIG_IGN` 可让内核自动回收。

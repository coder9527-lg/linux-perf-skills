---
name: linux-perf-observability
description: Linux 性能剖析工具与可观测性方法论。当需要用 perf 生成火焰图（on-CPU/off-CPU/差异火焰图）、用 bcc/BPF/eBPF（execsnoop、opensnoop、biolatency、memleak、filetop、tcpdrop、runqlat 等）动态跟踪内核与应用、用 bpftrace 写一行脚本、用 SystemTap 定位丢包、做全链路性能分析、应用 USE/RED/PSI 方法或压测吞吐量（ab/wrk/fio）时使用。配套 flamegraph、bcc、nginx-throughput 三个案例及跨领域工具速查。
license: MIT
metadata:
  domain: observability
  source: "Linux 性能诊断教学案例集"
---

# Linux 性能剖析与可观测性

当任务是"用什么工具、怎么采样、怎么读懂剖析结果"时加载本技能。它是其余四个领域技能的工具底座；具体领域问题先加载对应技能，工具细节回到这里查。

## 方法论

- **USE 方法**（资源视角）：对每个资源检查 Utilization（使用率）、Saturation（饱和度/排队）、Errors（错误计数）。适用主机维度：CPU、内存、磁盘、网络、文件描述符、conntrack 表。
- **RED 方法**（服务视角）：Rate（请求量）、Errors（错误率）、Duration（延迟分布，至少 P50/P95/P99）。适用在线服务，配合压测做容量评估。
- **PSI（Pressure Stall Information，内核 4.20+）**：`/proc/pressure/{cpu,memory,io}` 用 `some/full` + 10s/60s/300s 窗口量化任务因资源竞争**实际停滞的时间占比**，弥补使用率指标无法反映排队的缺陷；支持 poll 阈值告警（如 1 秒窗口内累计停滞 150ms 触发）。`full` 表示所有非空闲任务同时停滞（thrashing）。
- 排查黄金法则：**先确认现象与指标 → 自顶向下缩小范围（系统→进程→线程→函数/系统调用/IO）→ 用对照实验验证假设 → 修复后回归对比**，全程保留命令输出与时间线。

## 工具一：perf 与火焰图（cases/flamegraph）

```sh
# 1. 采样（-a 全系统 -g 调调用栈 -F 99 频率）
perf record -F 99 -a -g -- sleep 30
# 2. 生成火焰图（需开源 FlameGraph 工具集）
perf script -i perf.data | ./stackcollapse-perf.pl --all | ./flamegraph.pl > out.svg
# 实时函数热点
perf top -p <pid>
# 计数器（IPC、缓存未命中、分支预测、上下文切换）
perf stat -p <pid> sleep 10
# 系统调用流（类 strace，开销更低）
perf trace -p <pid>
```

进阶要点：
- **on-CPU vs off-CPU 火焰图**：on-CPU（perf 采样）回答"谁在烧 CPU"；off-CPU（`offcputime-bpfcc -df -p PID` 后折叠成图）回答"谁在等什么"（锁、I/O、调度），延迟问题两类都要看。
- **差异火焰图（difffolded.pl）**：修复前后各采一份，红色变宽=回归，蓝色变宽=改善，适合回归验证。
- 读图：x 轴是采样占比（**不是时间顺序**，越宽代表占用越多），y 轴是调用栈深度；找"宽平顶"热点；`[k]` 标记内核态栈。
- 采样无栈/栈名是十六进制：安装 dbgsym 包、确认 frame pointer（编译加 `-fno-omit-frame-pointer`），或开启 DWARF/ORC  unwind（`--call-graph dwarf`）。
- `cases/flamegraph/` 附数据库、ksoftirqd（软中断）、jbd2（ext4 日志线程）三张示例 SVG。

## 工具二：bcc / eBPF 动态跟踪（cases/bcc）

`cases/bcc/trace-open.py` 示范用 kprobe 挂内核函数 `do_sys_open`，通过 `BPF_PERF_OUTPUT` 把 PID/进程名/文件名实时送用户态。

**版本适配（重要）**：新内核（5.x+）已把 `do_sys_open` 改为 `do_sys_openat2`，原脚本直接 attach 会报 `could not open kprobe`。优先挂稳定的 **tracepoint**（`syscalls:sys_enter_openat`）而非易变的 kprobe 符号；bpftrace 可用 `tracepoint:syscalls:sys_enter_openat { printf("%s\n", comm); }`。

bcc 工具按领域地图（命令在 Debian 系常带 `-bpfcc` 后缀，如 `execsnoop-bpfcc`）：

| 领域 | 工具 |
|---|---|
| CPU/调度 | `execsnoop`（短时进程）、`cpudist`（on/off-CPU 时长分布）、`runqlat`/`runqlen`/`runqslower`（调度延迟与队列）、`offcputime`、`profile`、`llcstat`（末级缓存未命中）、`cpuunclaimed` |
| 内存 | `memleak`（泄漏调用栈）、`oomkill`（OOM 现场）、`drsnoop`（直接回收）、`compactsnoop`（规整）、`slabratetop`、`shmsnoop`、`numasched`（NUMA 迁移） |
| 文件/IO | `filetop`、`fileslower`、`filelife`、`opensnoop`、`cachestat`/`cachetop`、`vfsstat`、`dcstat`、`readahead`、`syncsnoop` |
| 块设备/文件系统 | `biolatency`、`biosnoop`、`biotop`、`biopattern`、`bitehist`、`ext4slower`/`xfsdist`/`btrfsdist`/`nfsslower` |
| 网络 | `tcpdrop`（内核丢包原因）、`tcpretrans`、`tcpconnlat`、`tcprtt`、`tcplife`、`tcpstates`、`tcpsynbl`、`tcptop`、`gethostlatency`（DNS 解析）、`solisten`、`netqtop` |
| 通用/语言 | `funclatency`（任意函数延迟）、`funcslower`、`funccount`、`trace`、`argdist`、`stackcount`、`hardirqs`/`softirqs`、`syscount`；USDT 类：`dbslower`/`mysqld_qslower`、`ucalls`/`ugc`/`uobjnew`（高级语言 GC/对象分配） |

工具选择原则：先用**聚合型**工具（直方图/排行，开销低）定位方向，再用**事件型**工具（snoop 类逐事件输出）抓细节；生产环境避免长期全量事件跟踪。

## 工具三：bpftrace 与 SystemTap

- bpftrace 是 bcc 之外的现代选择，一行脚本即可完成统计，内核 ≥4.9 逐步成熟、5.x 后能力完整：
  ```sh
  bpftrace -e 'tracepoint:raw_syscalls:sys_enter { @[comm] = count(); }'   # 按进程统计系统调用
  bpftrace -e 'profile:hz:99 { @[kstack] = count(); }'                    # 内核态 on-CPU 栈
  ```
- SystemTap（`cases/nat/dropwatch.stp`）在 kfree_skb 等丢包点埋探针；新环境优先 eBPF 等价方案（`tcpdrop-bpfcc`、`dropwatch -l kas`）。

## 工具四：PSI 与 cgroup v2（容器时代的一等指标）

```sh
cat /proc/pressure/cpu /proc/pressure/memory /proc/pressure/io
# 容器内（cgroup v2）
cat /sys/fs/cgroup/cpu.stat        # nr_throttled/throttled_usec/burst
cat /sys/fs/cgroup/memory.events   # high/max/oom/oom_kill 累计计数
cat /sys/fs/cgroup/io.stat         # 按设备的 rbytes/wbytes/rios/wios
```

## 压测与吞吐量（cases/nginx-throughput，案例 52）

- Nginx+PHP-FPM 吞吐瓶颈练习，`init.sh` 故意制造内核瓶颈：端口范围仅 51 个、关闭 `tcp_tw_reuse`、`fin_timeout=3600`、`somaxconn=10`、`nf_conntrack_max=200`。
- 压测：`ab -c 100 -n 10000 http://127.0.0.1:10000/` 或 `wrk -t4 -c100 -d30s <url>`；对照 `ss -s`（TIME_WAIT）、`nstat`（ListenOverflows）、conntrack 计数、PSI 定位瓶颈层级。
- 优化：调 backlog 三件套（somaxconn/应用 backlog/tcp_max_syn_backlog）、端口范围、连接复用、PHP-FPM `pm.max_children` 与 OPcache。
- 压测纪律：先定基线再改参数、单次变量、记录 P99 而非只看均值、压测端与被测端分离、磁盘用 `fio`、网络用 `iperf3`/`netperf`。

## 通用排查工具箱（详见 references/tools-cheatsheet.md）

```sh
# 一键采集（出问题时先留证据）
uptime; top -b -n1; free -h; vmstat 1 5; iostat -xz 1 5
cat /proc/pressure/cpu /proc/pressure/memory /proc/pressure/io
ss -s; nstat -az; sar -n DEV 1 3; dmesg -T | tail -50
# 容器场景补充
docker stats; cat /sys/fs/cgroup/cpu.stat /sys/fs/cgroup/memory.events
```

# 可观测性工具速查（跨领域）

## 方法论对照

| 方法 | 视角 | 指标 |
|---|---|---|
| USE | 资源（CPU/内存/磁盘/网络/FD/conntrack） | Utilization、Saturation、Errors |
| RED | 服务 | Rate、Errors、Duration（P50/P95/P99） |
| PSI | 内核压力（4.20+） | `/proc/pressure/{cpu,memory,io}` 的 some/full、avg10/60/300 |

## 一键现场采集（出问题先留证据）

```sh
uptime
top -b -n1 | head -30
free -h
vmstat 1 5
iostat -xz 1 5
cat /proc/pressure/cpu /proc/pressure/memory /proc/pressure/io
ss -s; nstat -az
sar -n DEV 1 3
dmesg -T | tail -50
# 容器
docker stats --no-stream
cat /sys/fs/cgroup/cpu.stat /sys/fs/cgroup/memory.events 2>/dev/null
```

## perf 火焰图

```sh
perf record -F 99 -a -g -- sleep 30
perf script | stackcollapse-perf.pl --all | flamegraph.pl > on-cpu.svg
# off-CPU（bcc 采样后折叠）
offcputime-bpfcc -df -p PID 10 > off.stacks
# 差异火焰图：修复前后两份 folded
difffolded.pl before.folded after.folded | flamegraph.pl > diff.svg
```

## bcc 工具全地图（命令常带 -bpfcc 后缀）

| 领域 | 工具 |
|---|---|
| CPU/调度 | execsnoop、cpudist、runqlat、runqlen、runqslower、offcputime、offwaketime、profile、llcstat、cpuunclaimed、numasched |
| 内存 | memleak、oomkill、drsnoop、compactsnoop、slabratetop、shmsnoop、uobjnew |
| 文件/IO | filetop、fileslower、filelife、opensnoop、cachestat、cachetop、vfsstat、dcstat、dcsnoop、readahead、syncsnoop |
| 块/文件系统 | biolatency、biosnoop、biotop、biopattern、bitehist、mdflush、ext4slower、xfsdist、btrfsdist、nfsslower、zfsslower |
| 网络 | tcpdrop、tcpretrans、tcpconnlat、tcprtt、tcplife、tcpstates、tcpsynbl、tcptop、tcpconnect、tcpaccept、gethostlatency、solisten、bindsnoop、netqtop |
| 中断/通用 | hardirqs、softirqs、softirqslower、criticalstat、klockstat、deadlock |
| 函数/系统调用 | funclatency、funcslower、funccount、trace、argdist、stackcount、syscount、statsnoop |
| 数据库/语言 USDT | dbslower、dbstat、mysqld_qslower、ucalls、uflow、ugc、ustat、uthreads、sslsniff、bashreadline、capable |

选择顺序：聚合型（latency/top/stat，低开销）定位方向 → 事件型（snoop）抓细节 → 生产避免长时间全量事件跟踪。

## bpftrace 一行流

```sh
bpftrace -e 'tracepoint:raw_syscalls:sys_enter { @[comm] = count(); }'
bpftrace -e 'profile:hz:99 { @[kstack] = count(); }'
bpftrace -e 'tracepoint:syscalls:sys_enter_openat { printf("%s %s\n", comm, str(args->filename)); }'
bpftrace -e 'kprobe:vfs_read { @start[tid] = nsecs; } kretprobe:vfs_read /@start[tid]/ { @us = hist((nsecs - @start[tid])/1000); delete(@start[tid]); }'
```

## 压测

| 场景 | 工具 | 示例 |
|---|---|---|
| HTTP | ab / wrk | `wrk -t4 -c100 -d30s http://host/path`；`ab -c100 -n10000 URL` |
| 裸磁盘/文件系统 | fio | `fio --name=t --rw=randread --bs=4k --iodepth=32 --direct=1 --runtime=30 --time_based --filename=...` |
| 网络带宽 | iperf3 / netperf | `iperf3 -c host -t 30` |
| MySQL | sysbench | `sysbench oltp_read_only --tables=10 --table-size=100000 run` |

压测纪律：固定基线、单变量、记录 P99/P999 而非只看均值、压测端分离、改后回归对比。

## 常见无栈/无符号问题

1. 二进制 strip 且无 frame pointer：重新编译 `-fno-omit-frame-pointer -g`，或 perf 用 `--call-graph dwarf`。
2. 缺内核/发行版 dbgsym：Debian/Ubuntu 装 `linux-image-$(uname -r)-dbgsym`；RHEL 用 `debuginfo-install`。
3. kprobe 符号随内核版本变化（如 do_sys_open → do_sys_openat2）：优先挂稳定 tracepoint。
4. 容器内无权限：bcc/bpftrace 需要 `--privileged` 或 CAP_BPF/CAP_SYS_ADMIN 与对应内核版本。

---
name: linux-perf-memory
description: Linux 内存问题诊断与优化。当出现内存持续增长、内存泄漏（RSS 只涨不降）、OOM/OOM Killer、容器内存限制导致启动慢/被杀、JVM/Tomcat 在 Docker 中内存异常、memleak/valgrind 抓不到调用栈、页缓存与 buff/cache 占比困惑、swap 抖动、直接回收（direct reclaim）、NUMA 内存不均，或需要用 free/vmstat/PSI/memleak/docker stats/memory.events/jstat 定位内存问题时使用。配套 mem-leak、tomcat 两个可复现案例。
license: MIT
metadata:
  domain: memory
  source: "Linux 性能诊断教学案例集"
---

# Linux 内存性能诊断

涉及内存泄漏、容器/JVM 内存、buff/cache 辨析、OOM 与回收压力时加载。案例在 `cases/`，Docker 复现，`make build/run/clean`。

## 先分清三类"内存占用"

`free -h` / `/proc/meminfo`：
- **used（进程匿名页）**：真正被应用 malloc/mmap 占用，泄漏看这里。
- **buff/cache（页缓存）**：内核为加速磁盘 I/O 占用，内存紧张时自动回收，**不是泄漏**。
- **available**：评估真实余量（含可回收 cache 的估算），而非 free 列。

排查泄漏先确认增长的是进程 RSS（`top` RES 列、`ps -o rss`、`/proc/<pid>/status` 的 VmRSS），不要把 cache 增长误判成泄漏。

## 诊断流程

1. **系统层**：`free -h`、`vmstat 1`（si/so 换入换出、free/buff/cache）、`sar -B 1`（pgscank/s 后台回收、pgscand/s 直接回收、pgsteal/s）。
2. **PSI 内存压力（内核 4.20+）**：`cat /proc/pressure/memory`
   - `some`：至少部分任务因内存回收而停滞；`full`：所有非空闲任务同时停滞（thrashing，性能严重受损）。
   - `full avg10` 持续 >0 或 `total` 快速增长，说明已在剧烈回收/换页，优先于 free 数值作为告警依据。
3. **定位增长进程**：`top` 按 M 排序、`ps -eo pid,rss,cmd --sort -rss | head`、`smem -tk`（PSS/USS，扣除共享库重复计算）、容器场景 `docker stats`。
4. **泄漏定性**：多次采样 RSS 单调上涨且不回落；`pmap -x <pid>` 看内存块分布，定位大块匿名内存或文件映射。
5. **定位调用栈**：
   - 内核态 bcc：`memleak-bpfcc -a -p <pid>`（需要 frame pointer，见下）。
   - 用户态：`valgrind --leak-check=full ./app`；常驻进程可用 gdb 定时 dump 堆或语言自带工具（jmap、py-spy、pprof）。
   - 高级：bcc `uobjnew`（按对象类型统计分配）、`drsnoop-bpfcc`（直接回收事件与延迟）、`compactsnoop-bpfcc`（内存规整）、`oomkill-bpfcc`（OOM 击杀现场）。
6. **容器/JVM**：进容器看 cgroup 文件（v2：`/sys/fs/cgroup/memory.max`、`memory.current`、`memory.events`），JVM 用 `jstat -gcutil <pid>`、`jmap -heap <pid>`。

## OOM 排查闭环

1. 确认发生 OOM：`dmesg -T | grep -i -E 'oom|killed process'`，或 cgroup v2 `memory.events` 的 `oom`/`oom_kill`/`oom_group_kill` 计数增长。
2. 区分 **系统级 OOM**（全局内存耗尽）与 **cgroup OOM**（容器超自己的 memory.max，宿主机仍有余量）——后者只在容器 cgroup 的 events 里体现，宿主机 dmesg 可能没有全局告警。
3. 读内核 OOM 报告：`anon-rss`（进程实际匿名内存）、`file-rss`（页缓存）、oom_score_adj；容器环境还要核对 `memory.max` 与 JVM 堆+Metaspace+线程栈+直接内存+页缓存的总和。
4. 对策：调大 limit、修泄漏、降低堆配置、合理设置 `memory.oom.group` 行为、关键进程用 `oom_score_adj=-1000` 保护。

## 根因模式与案例

### 模式 A：用户态内存泄漏 + memleak 无调用栈（cases/mem-leak，案例 18）
- 根因：`cases/mem-leak/app.c` 的 `fibonacci()` 每轮 `calloc(1024, sizeof(long long))` 后从不 `free`，每秒泄漏 8KB；`app-fix.c` 仅补一行 `free(v)` 即修复。
- memleak 抓不到栈的两个原因与对策：
  1. 二进制无 frame pointer：编译加 `-fno-omit-frame-pointer -g`（glibc 自身也需有符号）。
  2. 发行版 stripped：安装对应 dbgsym 包（`debuginfo-install` / `apt install linux-tools-$(uname -r)`、`dbgsym` 包）。
- 对照文件：`app-no-calloc.c` 演示 calloc 与 malloc 行为差异（calloc 首次触碰才清零，可能延迟暴露增长）。

### 模式 B：容器 cgroup 限制下的 JVM 启动慢（cases/tomcat，案例 46）
- 现象：`docker run --cpus 0.1 -m 512M` 下 Tomcat 8 启动异常缓慢；JSP 一进来就 `new byte[256*1024*1024]`（256MB）。
- 根因：旧 JRE 8 早期版本**不感知容器 cgroup 限制**，按宿主机内存做 GC ergonomics，堆配置与 512M cgroup 冲突触发频繁 GC；CPU 配额 0.1 核进一步放大启动时间。
- 修复：换 JRE 11（容器感知，见 `Dockerfile.jre11`），或显式 `-Xmx` 限制堆并预留非堆内存余量。
- 手法：`docker stats`、容器内 `top`、`jstat -gcutil 1 1s` 观察 GC 频率与耗时；cgroup v2 直接看 `cpu.stat` 的 `throttled_usec` 和 `memory.events`。
- 现代要点：JVM 容器感知自 8u191 起默认开启（UseContainerSupport），但 `-Xmx` 仍建议显式设置；堆 + Metaspace + 代码缓存 + 线程栈（每线程约 1MB）+ 直接内存（Netty/NIO 常被忽略）总和应低于 memory.max 的 70%~80%，给页缓存留空间。

## 容器 cgroup v2 内存文件速查

| 文件 | 含义 |
|---|---|
| `memory.current` | 当前 cgroup 总内存占用 |
| `memory.max` | 硬上限，触达后先直接回收，失败即 OOM |
| `memory.high` | 软上限，超过后被限流并强制回收（节流但不杀） |
| `memory.events` | `low/high/max/oom/oom_kill/sock_throttled` 累计计数（层级聚合） |
| `memory.events.local` | 本 cgroup 局部计数，不含子层级 |
| `memory.swap.max` | swap 上限，设 0 禁用该 cgroup swap |
| `cpu.stat` | `nr_throttled/throttled_usec` CPU 节流（内存问题常与 CPU 回收处理交织） |

## 常用命令速查（详见 references/tools-cheatsheet.md）

```sh
free -h; cat /proc/meminfo; cat /proc/pressure/memory
vmstat 1; sar -B 1
ps -eo pid,rss,cmd --sort -rss | head; smem -tk
pmap -x <pid>
memleak-bpfcc -a -p <pid>              # bcc，需 frame pointer
drsnoop-bpfcc; compactsnoop-bpfcc; oomkill-bpfcc
valgrind --leak-check=full ./app
docker stats; cat /sys/fs/cgroup/memory.events
jstat -gcutil <pid> 1000; jmap -heap <pid>
dmesg -T | grep -i oom
```

## 复现实验

```sh
cd cases/mem-leak && make build && make run
# 另开终端：while true; do ps -o pid,rss,cmd -C app; sleep 2; done
# 再跑：memleak-bpfcc -a -p $(pidof app)
cd cases/tomcat && make build && make run          # JRE8 慢
make run-jre11                                     # JRE11 对照
```

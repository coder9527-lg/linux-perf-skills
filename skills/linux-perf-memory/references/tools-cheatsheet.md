# 内存排查工具速查

## 基础工具

| 工具 | 关键用法 | 看什么 |
|---|---|---|
| free | `free -h` | used / buff-cache / available；以 available 判断余量 |
| vmstat | `vmstat 1` | si/so 换入换出（非 0 说明在用 swap）；free/buff/cache |
| sar | `sar -B 1` / `sar -r 1` | 缺页、pgscank（后台回收）/pgscand（直接回收）；占用趋势 |
| ps/top | `ps -eo pid,rss,cmd --sort -rss \| head`；top 按 M | RES/RSS 进程排行 |
| pmap | `pmap -x PID` | 进程内存块分布，定位大块匿名内存/文件映射 |
| smem | `smem -tk` | PSS/USS 实际占用，扣除共享库重复计算 |
| /proc | `cat /proc/PID/status` | VmRSS/VmSwap/VmPeak，逐进程精确口径 |

## PSI 与回收（现代内核）

| 工具 | 关键用法 | 看什么 |
|---|---|---|
| PSI | `cat /proc/pressure/memory` | some/full 的 avg10/60/300；full 持续非 0 即 thrashing |
| drsnoop | `drsnoop-bpfcc` | 直接回收事件的 PID 与延迟（分配被回收拖慢的直接证据） |
| compactsnoop | `compactsnoop-bpfcc` | 内存规整事件与延迟（高阶分配失败相关） |
| slabratetop | `slabratetop-bpfcc` | 内核 SLAB/SLUB 缓存分配速率 |
| oomkill | `oomkill-bpfcc` | OOM killer 触发现场与被杀进程 |
| memleak | `memleak-bpfcc -a -p PID` | 未释放分配的调用栈聚合；需 frame pointer |
| valgrind | `valgrind --leak-check=full ./app` | 用户态精确泄漏（开销大，测试环境） |

## 容器 cgroup v2

| 文件 | 含义 |
|---|---|
| `/sys/fs/cgroup/memory.current` | 当前占用 |
| `/sys/fs/cgroup/memory.max` | 硬上限（触达→回收→OOM） |
| `/sys/fs/cgroup/memory.high` | 软上限（超过即节流回收，不杀） |
| `/sys/fs/cgroup/memory.events` | low/high/max/oom/oom_kill/sock_throttled 累计计数 |
| `/sys/fs/cgroup/memory.swap.max` | swap 上限，0 为禁用 |

## JVM

```sh
jstat -gcutil PID 1000     # 各代使用率与 GC 次数/耗时（FGC/FGCT 频繁即问题）
jmap -heap PID             # 堆配置与分代使用
jcmd PID GC.heap_info      # 现代 JDK 推荐的堆信息命令
```

## 关键判定

- buff/cache 上涨是正常页缓存行为，**不是泄漏**；泄漏判定是某进程 RSS 单调上涨且不回落。
- memleak 无栈：编译加 `-fno-omit-frame-pointer -g`，安装 glibc/linux dbgsym。
- PSI `full` 与 vmstat si/so 同时活跃 → 系统在颠簸，优先减载或加内存，而非调参数硬扛。
- 容器 OOM：先查 cgroup `memory.events` 的 oom_kill（区分系统级 OOM 与 cgroup OOM）；JVM 总和=堆+Metaspace+代码缓存+线程栈+直接内存，应控制在 memory.max 的 70%~80%。
- 老 JRE（8u191 之前）不感知 cgroup，按宿主机规格做 GC ergonomics；升级或显式 `-Xmx`。
- swap 活跃让延迟毛刺显著上升，延迟敏感服务考虑 `vm.swappiness=10` 或关闭 swap。
- NUMA 机型注意跨节点访问，`numastat -p PID` 检查本地/远端内存比例。

# 内存症状驱动排障决策树（Runbook）

## 症状 1：内存"快满了"

```
free -h
├─ 主要是 buff/cache 高、available 充足？
│   └─ 正常页缓存，不是问题；内存紧张时内核自动回收，无需手动 drop_caches
├─ used 高且 available 持续走低？
│   └─ 进入症状 2（定位增长进程）
└─ swap 已在用（vmstat 的 si/so 非 0）
    ├─ cat /proc/pressure/memory 的 full 非 0 → 已颠簸，立即减载
    └─ 延迟敏感服务调小 vm.swappiness（如 10）
```

## 症状 2：某进程 RSS 持续增长（疑似泄漏）

```
ps -eo pid,rss,cmd --sort -rss | head    # 多次采样确认单调上涨
├─ 确认是匿名内存（泄漏）而非文件映射
│   ├─ pmap -x PID 看大块 anon 区
│   ├─ memleak-bpfcc -a -p PID           # 内核态跟踪未释放分配的调用栈
│   │   ├─ 无调用栈？→ 二进制缺 frame pointer：重编 -fno-omit-frame-pointer -g
│   │   └─ 仍无 → 装 glibc/linux dbgsym 包
│   ├─ 语言原生工具：
│   │   Java: jmap -histo / jcmd GC.class_histogram
│   │   Go: pprof heap
│   │   Python: py-spy dump / tracemalloc
│   │   通用: valgrind --leak-check=full（测试环境，开销大）
│   └─ uobjnew-bpfcc 按对象类型统计分配（高级语言）
└─ 修复后对照：RSS 稳定在平台期不再爬升（mem-leak 案例：补 free()）
```

## 症状 3：进程被杀 / 容器重启

```
dmesg -T | grep -iE 'oom|killed process'
├─ 有全局 OOM 记录 → 系统级内存耗尽
│   └─ 看 oom_score、anon-rss 找真凶；调整 overcommit 或扩容
├─ dmesg 没有但容器退出码 137、K8s 状态 OOMKilled
│   └─ cgroup OOM（容器超自己的 limit，宿主机可能很闲）
│       ├─ cat /sys/fs/cgroup/memory.events：oom/oom_kill 增长即确认
│       ├─ docker inspect -f '{{.State.OOMKilled}}' 容器
│       └─ 修复顺序：
│           1. limit 是否过低（JVM 堆+Metaspace+线程栈+直接内存总和）
│           2. 是否真泄漏（回症状 2）
│           3. 非堆是否超预期（Netty 直接内存、线程数×1MB 栈）
│           4. 用 memory.high 软限流替代硬杀（cgroup-oom-pressure 案例）
└─ 不是 OOM 的 137？排查 SIGKILL 来源（liveness 探针、人工 kill、节点压力驱逐）
```

## 症状 4：系统卡顿但内存数值看着还行

```
cat /proc/pressure/memory
├─ some avg10 高 → 部分任务在等回收
├─ full avg10 高 → 全任务停滞（thrashing），比 free 数值更早暴露问题
├─ drsnoop-bpfcc → 直接回收事件延迟（分配路径同步回收是延迟来源）
└─ compactsnoop-bpfcc → 内存规整慢，常见于高阶分配（大页/大块连续内存）失败
sar -B 1：pgscand/s 非 0 即直接回收正在发生
```

## 症状 5：JVM/容器内存异常

```
容器内 jstat -gcutil PID 1000
├─ FGC 频繁、FGCT 持续涨 → GC 压力
│   ├─ 旧 JRE（<8u191）不感知 cgroup，按宿主机规格做 ergonomics → 升级或显式 -Xmx
│   ├─ 堆设置 + 非堆总和 > memory.max → 调小堆或调大 limit（tomcat 案例）
│   └─ jmap -heap 确认实际生效的堆参数
├─ GC 不频繁但 RSS 仍涨 → 堆外内存（直接内存/NIO、JNI、线程栈）
│   └─ pmap 找大块 anon，NativeMemoryTracking（JVM）细分
└─ K8s：只设 limits.memory 时 requests 不自动等于 limit，调度与计费口径要分别核对
```

## 症状 6：NUMA 相关

```
numastat -p PID          # 远端节点内存占比高（numa_foreign / other_node）
├─ 跨节点访问有显著延迟 → numactl --cpunodebind --membind 绑定
├─ numasched-bpfcc 跟踪进程在 NUMA 节点间迁移
└─ 大页（HugePages）分配失败也会进 compactsnoop，结合 vm.nr_hugepages 检查
```

---
name: linux-perf-cpu
description: Linux CPU 性能问题诊断与优化。当出现 usr%/sys% CPU 使用率过高、平均负载（load average）异常、top/pidstat 看不到高 CPU 进程（疑似短时进程）、僵尸进程、上下文切换频繁、容器 CPU 节流（throttling）、调度延迟、软中断高、php-fpm/nginx 等应用 CPU 飙高，或需要用 top/vmstat/pidstat/PSI/perf/execsnoop/runqlat 定位 CPU 热点时使用。配套 nginx-high-cpu、nginx-short-process、short-lived-process 三个可复现案例。
license: MIT
metadata:
  domain: cpu
  source: "Linux 性能诊断教学案例集"
---

# Linux CPU 性能诊断

当任务涉及 CPU 使用率、负载、热点函数、调度延迟或短时进程排查时加载本技能。所有案例源码在 `cases/` 下，均提供 `Makefile`（`make build/run/clean`），依赖 Docker 且多数需要 `--privileged`。

## 诊断总流程（自顶向下）

1. **确认现象与资源压力**：
   - `uptime` 看 1/5/15 分钟 load average 趋势（与 CPU 核数比较，而非绝对值）。
   - `top` 看 `%Cpu(s)` 的 us/sy/wa/hi/si/st 分解，按 `1` 展开每核。
   - **PSI（内核 4.20+，量化"卡顿"而非只看使用率）**：`cat /proc/pressure/cpu`，`some avg10` 表示有任务因等 CPU 而停滞的时间占比；`total` 是累计停滞微秒，可做毛刺检测。
2. **定位进程**：`pidstat -u 1` 找持续高 CPU 进程；`ps -eo pid,psr,pcpu,comm --sort -pcpu | head`。
3. **定位函数/调用栈**：
   - 应用内热点：`perf top -p <pid>` 或 `perf record -F 99 -a -g -- sleep 30` 后 `perf report`。
   - 系统态（sy%）高：看系统调用、锁、内核线程，配合 `perf trace` / `strace -c -p <pid>`、`klockstat-bpfcc`。
   - **off-CPU 分析（进程在等什么）**：`offcputime-bpfcc -df -p <pid> 10`，区分"在 CPU 上跑"与"被阻塞/排队"。
4. **调度延迟量化**：`runqlat-bpfcc`（运行队列等待直方图）、`runqslower-bpfcc 10000`（超过 10ms 的调度延迟事件）。
5. **特殊：top 里没有高 CPU 进程但 usr% 高** → 必然是**短时进程**在采样间隙退出，转下面的"短时进程模式"。

## 关键概念与量化判定

- **load average 的正确读法**：它统计的是 R（运行）+ D（不可中断睡眠，通常是 I/O）状态的平均任务数。load 高但 CPU 闲，先 `ps -eo stat,cmd | grep '^D'` 排查 I/O 等待，不要只盯 CPU。
- **CPU 使用率 ≠ 卡顿**：单核 100% 但无排队，延迟可能正常；使用率不高但 runqueue 长（`runqlen-bpfcc`）才是延迟来源。PSI 和 runqlat 用于发现这类"隐性饱和"。
- **st%（steal time）**：虚拟化环境被宿主机抢占的 CPU，st 持续 >10% 说明宿主机超卖，需迁移或降配。
- **si%/hi%（软/硬中断）**：网卡中断集中在单个 CPU 时常见；`mpstat -P ALL 1` 定位，`softirqs-bpfcc` 量化耗时，开启 RPS/RFS 或调整网卡中断亲和性（`/proc/irq/<n>/smp_affinity`）打散。
- **容器 CPU 节流（throttling，CFS bandwidth control）**：容器被 `--cpus` 限制后，即使宿主机有空闲 CPU 也会被周期性限流，表现为延迟毛刺但平均使用率不高。
  - cgroup v2：`cat /sys/fs/cgroup/<cg>/cpu.stat` 看 `nr_throttled`、`throttled_usec`、`nr_bursts`、`burst_usec`（计数增长即被节流）。
  - cgroup v1：`cat /sys/fs/cgroup/cpu,cpuacct/<cg>/cpu.stat`。
  - 对策：提高 CPU quota、开启 `cpu.max.burst`（内核 5.14+ 的 burst 机制）、或优化应用降低瞬时峰值。

## 根因模式与案例映射

### 模式 A：应用自身计算热点（cases/nginx-high-cpu，案例 05）
- 现象：us% 高，`pidstat` 能稳定看到 php-fpm 进程占满 CPU。
- 根因：`cases/nginx-high-cpu/app/ok.php` 内 100 万次 `sqrt()` 空转循环。
- 手法：`perf top -p <php-fpm pid>` 直接看到解释器执行的热点函数；语言层还可用 bcc 的 `profile -af 49` 采样用户态栈。
- 修复：消除业务代码中的 CPU 空转/低效循环；PHP 场景开启 OPcache 降低解释开销。

### 模式 B：短时进程逃逸采样（cases/nginx-short-process，案例 06；cases/short-lived-process）
- 现象：us% 高，但 `top`/`pidstat` 抓不到高 CPU 进程。
- 根因：父进程不断 `fork()+exec()` 出短命子进程（php-fpm 请求处理、或 C 程序每 5 秒 exec 一次 `stress`），采样间隔内子进程已退出。
- 关键工具：**`execsnoop`（bcc）** 实时打印所有 exec 事件，一条命令抓住瞬时进程；`pidpersec-bpfcc` 看每秒新建进程速率；辅以 `pstree -p <ppid>`。
- 僵尸进程：子进程退出后父进程未 `wait()` 回收。`short-lived-process/app.c` 演示用 `signal(SIGCHLD, SIG_IGN)` 让内核自动回收；通用修法是父循环内 `while (waitpid(-1, &st, WNOHANG) > 0);`。排查：`ps -eo pid,ppid,stat,cmd | grep Z`，再用 ppid 找失职父进程。
- 常见现实场景：监控脚本被 cron 高频拉起、CI 构建脚本、shell 循环里调用外部命令（应用内 exec 替代为库调用）。

## 容器环境补充

- `docker stats` 的 CPU% 是相对**单核**的百分比，多核可超过 100%；以 cgroup `cpu.stat` 的节流计数为准判断瓶颈。
- 容器内 `top`/`nproc` 默认看到的是宿主机 CPU 数（除非用 lxcfs 或较新 runtime），线程池/连接池按此值配置会过度膨胀，需显式按 quota 配置。
- 跨 NUMA 迁移带来缓存失效：`numasched-bpfcc` 跟踪进程 NUMA 迁移，必要时用 `numactl --cpunodebind` 绑核。

## 常用命令速查（详见 references/tools-cheatsheet.md）

```sh
uptime; top; mpstat -P ALL 1          # 负载、CPU 分解、每核
cat /proc/pressure/cpu                # PSI 压力（some/full, avg10/60/300）
vmstat 1                              # r 运行队列、us/sy/wa、cs 上下文切换
pidstat -u 1; pidstat -w 1            # 进程 CPU；自愿/非自愿切换
perf top -p <pid>; perf record -F99 -a -g -- sleep 30 && perf report
execsnoop; pidpersec-bpfcc            # 短时进程（bcc）
runqlat-bpfcc; runqslower-bpfcc 10000 # 调度延迟（bcc）
cpudist-bpfcc; offcputime-bpfcc -df -p <pid> 10
cat /sys/fs/cgroup/cpu.stat           # 容器节流计数（cgroup v2）
ps -eo pid,ppid,stat,cmd | grep Z     # 僵尸进程
```

## 复现实验

```sh
cd cases/nginx-high-cpu && make build && make run      # 模式 A
cd cases/short-lived-process && make build && make run # 模式 B + 僵尸进程
# 另开终端：execsnoop；ps aux | grep stress
```

注意：案例基于较早的 Ubuntu LTS 镜像，新版 Docker 构建失败时优先换基础镜像或仅参考源码与排查思路。

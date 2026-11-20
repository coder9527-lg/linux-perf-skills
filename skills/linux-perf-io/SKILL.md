---
name: linux-perf-io
description: Linux 磁盘与文件 I/O 性能诊断。当出现 iowait% 高、平均负载高但 CPU 空闲、磁盘利用率 100%、I/O 延迟大、O_DIRECT 直接 I/O 绕过页缓存导致读慢、应用狂打日志打满磁盘、文件读写瓶颈、fsync/flush 慢、随机/顺序 I/O 模式问题、MySQL/Redis 等中间件因磁盘慢而延迟，或需要用 iostat/PSI/pidstat -d/iotop/filetop/biolatency/biosnoop/ext4slower 定位 I/O 问题时使用。配套 high-iowait-process、io-cached、io-latency、logging-app、mysql-slow、redis-slow 六个可复现案例。
license: MIT
metadata:
  domain: io
  source: "Linux 性能诊断教学案例集"
---

# Linux 磁盘 I/O 性能诊断

涉及 iowait、磁盘利用率、文件系统、直接 I/O、日志风暴或中间件 I/O 瓶颈时加载。案例在 `cases/`，Docker 复现，磁盘案例需 `--privileged` 访问块设备。

## 诊断流程（自顶向下五层）

1. **系统层**：
   - `top`/`vmstat 1` 看 wa%、b 列（D 状态进程数）与 load。
   - **PSI（内核 4.20+）**：`cat /proc/pressure/io`，`some/full` 的 avg10/60/300 直接量化任务因 I/O 停滞的时间占比，比 wa% 更能反映真实卡顿（wa% 在多核上容易被稀释）。
   - `iostat -xz 1` 看 `%util`、`await`（平均 I/O 延迟）、`r_await/w_await`、`aqu-sz` 队列长度、`rkB/s wkB/s`。
2. **进程层**：`pidstat -d 1` 找读写量大与 iodelay 高的进程；`iotop -oP`。
3. **文件/系统调用层**：bcc `filetop`（按进程×文件统计读写）、`opensnoop`、`fileslower`（慢同步读写）、`filelife`（短命文件，小文件风暴现形）、`strace -f -e trace=read,write,openat,fsync -p <pid> -T`、`syncsnoop-bpfcc`（sync/fsync 耗时）。
4. **块设备层**：bcc `biolatency`（I/O 延迟直方图）、`biosnoop`（每笔 I/O 的进程/大小/延迟）、`biotop`（按进程汇总）、`biopattern`（随机/顺序模式识别）、`bitehist`（I/O 大小分布）。
5. **文件系统层**：`ext4slower`/`xfsdist`/`btrfsdist` 按文件系统操作统计延迟；`cachestat`/`cachetop` 看页缓存命中率；`dcstat`/`dcsnoop` 看目录项缓存。
6. **应用内部**：MySQL 慢查询日志/`EXPLAIN`（或 bcc `dbslower`/`mysqld_qslower` 无侵入跟踪）、Redis `SLOWLOG`、应用自己的耗时打点。

关键辨析：**wa% 高不等于磁盘坏了**——先看 PSI 与 `%util` 是否真的饱和，再用 `aqu-sz` 区分是队列排队（饱和）还是单笔 I/O 延迟高（设备慢）。NVMe 多队列下 `%util` 可能失真（设备仍有余量但显示 100%），以 `await`/`biolatency` 为准。

## 根因模式与案例

### 模式 A：直接 I/O 绕过页缓存（cases/io-cached，案例 17）
- 根因：`app.c` 用 `open(disk, O_RDONLY | O_DIRECT ...)` 周期性读盘，每次都穿透到块设备；缓存命中数与 I/O 大小对不上。
- 修复（`app-cached.c`）：去掉 `O_DIRECT` 走缓冲 I/O，重复读命中页缓存，磁盘 `%util` 骤降。
- 手法：`cachestat-bpfcc` 观察页缓存命中率；`readahead-bpfcc` 看预读效率。
- 注意：数据库（MySQL/PostgreSQL）主动用 O_DIRECT 是**合理设计**（自带 buffer pool，避免双重缓存），不要无脑去掉；问题通常出在通用应用误用。

### 模式 B：多进程并发读盘 + 僵尸进程（cases/high-iowait-process，案例 07/08）
- 根因：多个子进程各以 64MB 大块 `O_DIRECT` 读盘，打满设备队列；父进程未回收子进程产生僵尸。
- 两级修复：`app-fix1.c` 去掉 `O_DIRECT`；`app-fix2.c` 把 `wait()` 移入循环实时回收子进程。
- 参数化：`/app -d /dev/sdb -s 67108864 -c 20`（设备/块大小/次数）。

### 模式 C：应用架构产生海量小文件 I/O（cases/io-latency，案例 27）
- 根因：Flask 接口 `/popularity/<word>` 每次请求写 1000 个文件再逐个读回（`os.walk` 遍历），元数据与系统调用开销巨大。
- 修复：对照接口 `/popular/<word>` 全程在内存 list 中处理，不落盘；或合并文件、批量 I/O、用内存数据库。
- 手法：`strace -c` 统计 openat/read/write 调用次数，`filetop`/`filelife-bpfcc` 看小文件风暴，`vfsstat-bpfcc` 看 VFS 调用量。

### 模式 D：狂打日志打满 I/O（cases/logging-app，案例 26）
- 根因：`app.py` 每 100ms 写一条 300MB 的 INFO 日志，RotatingFileHandler 单文件上限 1GB，磁盘 I/O 与 iowait 被打满。
- 修复：动态调日志级别——程序内置 `SIGUSR1→INFO`、`SIGUSR2→WARNING` 信号处理，`kill -USR2 <pid>` 即时降噪；根治手段是异步日志、降低级别、日志采样、限流、systemd-journald 统一收集。
- 手法：`filetop` 定位写盘最猛的文件，`syncsnoop-bpfcc` 看是否有频繁 fsync，`biolatency` 确认延迟分布。

### 模式 E：数据库被磁盘拖累（cases/mysql-slow 案例 28、cases/redis-slow 案例 29）
- MySQL：简单查询 15 秒、iowait 高、磁盘 100%。配置 `mysqld.cnf` 中 `innodb_buffer_pool_size` 仅 5MB、`innodb_flush_log_at_trx_commit=1`（每次事务都 fsync）放大写放大；用慢查询日志 + `EXPLAIN` 定位全表扫描，合理调大缓冲池（物理机常用内存的 50%~70%）。无侵入手段：`mysqld_qslower-bpfcc <pid> 1000` 抓超过 1s 的查询。
- Redis：`app.py` 的 `/get_cache` 对 5000 个 key 逐个 `GET`（N 次往返 RTT）；对照接口 `/get_cache_data` 用一次 `MGET` 批量取，耗时数量级下降。通用法则：**用 pipeline/批量命令消除循环内单 key 操作**；再查 `SLOWLOG GET`、`INFO persistence`（aof_fsync、rdc_bgrun 状态）确认 RDB/AOF fsync 是否阻塞主线程。

## 补充根因模式（案例之外的高频场景）

- **I/O 调度器不匹配**：机械盘适合 `mq-deadline`，NVMe 适合 `none`/`kyber`；查看 `cat /sys/block/<dev>/queue/scheduler`。云盘通常透传，调度器影响小。
- **预读失效**：随机 I/O 场景下大预读浪费带宽，`blockdev --getra <dev>` 查看并调小；`readahead-bpfcc` 验证。
- **swap 引发的伪 I/O 问题**：`vmstat` 的 si/so 非 0 时，磁盘活动可能是换页而非业务 I/O；延迟敏感服务调小 `vm.swappiness`（10）或关闭 swap，结合 PSI memory 一起判断。
- **基准测试**：改动前先量化，`fio --name=t --filename=/dev/<dev> --rw=randread --bs=4k --iodepth=32 --runtime=30 --time_based --direct=1` 测裸设备 IOPS/延迟；文件系统层去掉 `--direct` 或指定目录文件。

## 常用命令速查（详见 references/tools-cheatsheet.md）

```sh
cat /proc/pressure/io; iostat -xz 1; vmstat 1
pidstat -d 1; iotop -oP
filetop-bpfcc; opensnoop-bpfcc; fileslower-bpfcc 1
biolatency-bpfcc -mF; biosnoop-bpfcc; biotop-bpfcc; biopattern-bpfcc
cachestat-bpfcc 1; ext4slower-bpfcc; syncsnoop-bpfcc
strace -f -c -e trace=openat,read,write,fsync -p <pid>
dbslower-bpfcc mysql 1; mysqld_qslower-bpfcc $(pidof mysqld) 1000
fio --name=t --rw=randread --bs=4k --iodepth=32 --runtime=30 --time_based --direct=1 --filename=/dev/sdb
```

## 复现实验

```sh
cd cases/io-cached && make build && make run            # 直接 I/O vs 缓存 I/O
cd cases/high-iowait-process && make build && make run  # iowait + 僵尸
cd cases/logging-app && make build && make run          # 日志风暴，kill -USR2 <pid> 验证
cd cases/mysql-slow && make build && make run           # 多容器：mysql+应用+数据处理
cd cases/redis-slow && make build && make run
```

注意：块设备案例默认寻找 `/dev/sd*` 或 `/dev/xvd*`，云环境需用 `-d` 显式指定存在的设备；容器内访问块设备需要 `--privileged` 或对应的 device cgroup 权限。

# 磁盘 I/O 排查工具速查

## 基础工具

| 工具 | 关键用法 | 看什么 |
|---|---|---|
| PSI | `cat /proc/pressure/io` | some/full 停滞占比，比 wa% 更真实反映卡顿 |
| iostat | `iostat -xz 1` | %util、await/r_await/w_await、aqu-sz、rkB/s wkB/s |
| vmstat | `vmstat 1` | wa%、b 列（D 状态进程数）、bi/bo、si/so（换页） |
| pidstat | `pidstat -d 1` | 进程级读写 kB/s 与 iodelay |
| iotop | `iotop -oP` | 实时 I/O 占用排行 |
| blktrace | `blktrace -d /dev/sdb -o - \| blkparse -i -` | 块层完整 I/O 路径剖析 |

## bcc/eBPF 工具

| 工具 | 关键用法 | 看什么 |
|---|---|---|
| biolatency | `biolatency-bpfcc -mF` | 块 I/O 延迟直方图，判断慢在设备还是排队 |
| biosnoop | `biosnoop-bpfcc` | 每笔 I/O 的进程、设备、大小、延迟明细 |
| biotop | `biotop-bpfcc` | 按进程汇总的块 I/O 排行 |
| biopattern | `biopattern-bpfcc` | 随机/顺序访问模式识别 |
| bitehist | `bitehist-bpfcc` | I/O 大小分布 |
| filetop | `filetop-bpfcc -C 1` | 按进程×文件的读写排行，小文件风暴现形 |
| fileslower | `fileslower-bpfcc 1` | 慢于 1s 的同步文件读写 |
| filelife | `filelife-bpfcc` | 短命文件的创建/删除（临时文件风暴） |
| opensnoop | `opensnoop-bpfcc` | 实时 open/openat 事件 |
| cachestat | `cachestat-bpfcc 1` | 页缓存命中率（hits/misses/dirty） |
| cachetop | `cachetop-bpfcc 1` | 按进程的页缓存命中率 |
| readahead | `readahead-bpfcc` | 预读缓存效率 |
| syncsnoop | `syncsnoop-bpfcc` | sync/fsync 耗时，日志类应用必查 |
| ext4slower | `ext4slower-bpfcc` | ext4 慢操作（xfs/btrfs/nfs 各有对应 *slower/*dist） |
| vfsstat | `vfsstat-bpfcc 1` | VFS 调用量 |
| dbslower | `dbslower-bpfcc mysql 1` | 无侵入抓 MySQL/PostgreSQL 慢查询 |

## strace 与基准

```sh
strace -f -c -e trace=openat,read,write,fsync -p PID   # 系统调用次数与耗时
fio --name=t --filename=/dev/sdb --rw=randread --bs=4k \
    --iodepth=32 --runtime=30 --time_based --direct=1   # 裸设备 4k 随机读 IOPS/延迟
blockdev --getra /dev/sdb                               # 预读大小（KB）
cat /sys/block/sdb/queue/scheduler                      # I/O 调度器
```

## iostat 列解读

- `%util` 接近 100%：设备饱和；但多队列 NVMe 上可能失真，结合 aqu-sz/await 判断。
- `await` 高而 aqu-sz 低：单笔 I/O 慢（设备/调度器）；aqu-sz 高：排队导致的延迟。
- `aqu-sz` 持续 >1：存在 I/O 积压。
- `r_await` 与 `w_await` 分开读，区分读慢还是写慢（写慢常见于 fsync 策略）。

## 常见根因清单

1. `O_DIRECT` 绕过页缓存 → 去掉标志走缓冲 I/O（io-cached 案例）；但数据库自带缓冲池时 O_DIRECT 是合理设计。
2. 大量小文件/频繁 openat → 合并文件、内存处理、批量读写（io-latency 案例）。
3. 同步日志/fsync 风暴 → 异步日志、降级别、信号动态调级（logging-app 案例）。
4. 数据库缓冲池过小、全表扫描 → 调大 buffer pool、加索引、看慢查询/EXPLAIN。
5. Redis 循环单 key 访问 → MGET/pipeline 批量，消除 RTT 放大。
6. 调度器不匹配：机械盘 mq-deadline，NVMe 用 none/kyber。
7. swap 换页伪装成磁盘问题：先看 vmstat si/so 与 PSI memory。

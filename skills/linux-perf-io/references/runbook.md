# 磁盘 I/O 症状驱动排障决策树（Runbook）

## 症状 1：iowait 高 / load 高但 CPU 闲

```
cat /proc/pressure/io
├─ some/full 的 avg10 也高 → 确有 I/O 停滞（wa% 在多核上会被稀释，PSI 更可信）
│   ├─ iostat -xz 1
│   │   ├─ %util 接近 100% + aqu-sz 高 → 设备饱和、排队
│   │   ├─ await 高但 aqu-sz 低 → 单笔 I/O 慢（设备本身/调度器/云盘限流）
│   │   ├─ r_await 高 → 读慢；w_await 高 → 写慢（常见 fsync 策略）
│   │   └─ NVMe 多队列下 %util 可能失真，以 await/biolatency 为准
│   └─ pidstat -d 1 / iotop -oP 定位是哪个进程
└─ PSI 不高但 wa% 高 → 可能只是偶发 D 状态，结合 vmstat b 列持续观察
```

## 症状 2：定位到进程后，继续往下挖

```
filetop-bpfcc -C 1               # 该进程在读写哪些文件
├─ 海量小文件、open/read/write 调用爆炸
│   └─ strace -f -c -e trace=openat,read,write,fsync -p PID 确认系统调用量
│       修复：合并文件、内存处理、批量 I/O（io-latency 案例）
├─ 单个大文件持续 Direct I/O
│   └─ cachestat-bpfcc 命中率为 0 → O_DIRECT 绕过页缓存
│       通用应用去掉 O_DIRECT（io-cached 案例）；数据库自带缓冲池属合理设计
├─ 日志文件疯狂写
│   └─ syncsnoop-bpfcc 看 fsync 频率 → 异步日志、降级别、采样限流（logging-app 案例）
└─ 数据库文件
    ├─ MySQL: dbslower-bpfcc mysql 1 / 慢查询日志 + EXPLAIN（mysql-slow 案例）
    └─ Redis: SLOWLOG GET；循环单 key 改 MGET/pipeline（redis-slow 案例）
```

## 症状 3：块设备层深入

```
biolatency-bpfcc -mF             # 延迟直方图，判断整体分布与长尾
biosnoop-bpfcc                   # 每笔 I/O 的 PID/大小/延迟，抓异常毛刺
biopattern-bpfcc                 # 随机 vs 顺序占比
bitehist-bpfcc                   # I/O 大小分布
├─ 随机小 I/O 为主且性能差
│   ├─ 机械盘：检查调度器（cat /sys/block/sdX/queue/scheduler），mq-deadline
│   ├─ 预读在随机场景浪费：blockdev --getra，调小，readahead-bpfcc 验证
│   └─ 业务层加缓存/本地 SSD，减少随机落盘
└─ 顺序大 I/O 但吞吐低
    ├─ 检查 iodepth 是否打不上去（同步 I/O 瓶颈）→ 异步 io_uring/libaio
    └─ fio 基准对比设备标称能力（fio-benchmark 案例）
```

## 症状 4：文件系统层

```
ext4slower-bpfcc（xfs/btrfs/nfs 有对应 *slower/*dist）
├─ 慢操作集中在 fsync/写事务
│   ├─ 检查挂载选项（data=ordered/writeback）、barrier
│   ├─ 日志型应用考虑批量提交而非每条 fsync
│   └─ jbd2/kworker 内核栈出现在火焰图 → ext4 journal 瓶颈
├─ 元数据操作慢（openat/getdents/stat）
│   ├─ dcstat/dcsnoop-bpfcc 看目录项缓存
│   └─ 目录文件数过多 → 分桶子目录、避免单目录百万条目
└─ NFS 慢 → nfsslower-bpfcc，区分本地盘与网络存储
```

## 症状 5：写缓存与脏页

```
grep -E 'dirty|writeback' /proc/meminfo；sysctl vm.dirty*
├─ dirty 页堆积后一次性回写造成周期性卡顿
│   ├─ 调小 vm.dirty_ratio/dirty_bytes 让回写更平滑
│   └─ 延迟敏感场景考虑同步写 + 带电池保护的设备
├─ mdflush-bpfcc 看软 RAID 刷新事件
└─ 云盘突发写被限流（credit 机制）→ 云厂商监控对照突发积分
```

## 症状 6：伪 I/O 问题（先排除）

```
vmstat 1 的 si/so 非 0 → 是 swap 换页产生的磁盘活动，转内存技能
ps -eo stat,cmd | grep D → D 状态可能是等网络锁/NFS，不全是本地盘
容器内看不到宿主设备 → 确认 device cgroup 权限与挂载，--privileged 或显式 --device
```

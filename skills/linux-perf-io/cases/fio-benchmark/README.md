# 案例：fio 块 I/O 基准测试与指标读法

## 为什么需要基准

性能调优必须先有可重复的量化基线。fio 是事实标准的 I/O 压测工具，
本案例用 tmpfs 做无副作用的练习（真实测试应挂载目标块设备或文件系统目录）。

## 复现

```sh
make build && make run
make direct       # direct=1 绕过页缓存，测裸 I/O 能力
make cached       # direct=0 对照，缓冲 I/O
```

## 三种典型负载（job-randread.fio）

| job | 用途 | 对应业务 |
|---|---|---|
| randread 4k qd32 | 随机读 IOPS/尾延迟 | 数据库 OLTP、缓存未命中 |
| randwrite 4k qd32 | 随机写 IOPS | 数据库写入、消息队列 |
| seqread 128k qd8 | 顺序读吞吐 | 全表扫描、日志分析、备份 |

`stonewall` 保证各 job 串行执行，互不干扰；`percentile_list` 输出 P50/P95/P99/P99.9。

## 输出怎么读

```
read: IOPS=..., BW=...MiB/s
  lat (usec): 50=... 95=... 99=... 99.9=...
  cpu: usr=... sys=...
```

- **IOPS**：每秒 I/O 次数，小块随机负载的核心指标。
- **BW（带宽）**：大块顺序负载的核心指标。
- **lat 分位数**：平均值会掩盖长尾，**P99/P99.9 才是延迟敏感业务的判定依据**。
- iodepth 与实际队列深度对照 `iostat` 的 aqu-sz。

## 与观测工具联动

```sh
docker exec -it fio-lab watch -n1 'cat /proc/pressure/io'   # PSI
docker exec -it fio-lab iostat -xz 1                        # %util/await/aqu-sz
docker exec -it fio-lab biolatency-bpfcc -mF                # 延迟直方图
docker exec -it fio-lab biosnoop-bpfcc                      # 每笔 I/O 明细
```

## 常见误读

1. **只看 IOPS 不看延迟分位数**：高队列深度堆出高 IOPS，但 P99 延迟可能已不可接受。
2. **用缓存 I/O 测裸盘**：direct=0 时结果被页缓存放大，不代表设备能力。
3. **在被测试盘上跑 fio 自身与日志**：引入竞争，结果失真；压测端与被测设备分离。
4. **NVMe 上 %util=100% 不等于没余量**：多队列设备以 await/biolatency 为准。
5. **测试文件太小**：小于设备缓存时数据全在缓存里，`size` 应显著大于缓存。

# 案例：CFS CPU 节流（容器配额导致的延迟毛刺）

## 背景

容器设置 `--cpus 0.25` 后，CFS bandwidth control 会在每个调度周期（默认 100ms）内
限制该 cgroup 最多使用 25ms CPU 时间，用完即被节流（throttle）到下一周期。此时：

- 宿主机可能整体很闲（`top` 看不出瓶颈）；
- 容器内进程平均 CPU 使用率不高，但请求出现周期性毛刺（P99 变差）；
- 根因证据只存在于 cgroup 的 `cpu.stat`。

## 复现

```sh
make build
make run-throttled        # 0.25 核配额 + 4 个 stress-ng 忙等 worker
# 另开终端
make observe
```

## 关键指标（cgroup v2 cpu.stat，语义依据内核 cgroup-v2 文档）

| 字段 | 含义 |
|---|---|
| `usage_usec` | 占用 CPU 的总时间 |
| `nr_periods` | 经历的 CFS 周期数 |
| `nr_throttled` | 被节流的周期数（持续增长=配额不够） |
| `throttled_usec` | 累计被节流的时长 |
| `nr_bursts` / `burst_usec` | 内核 5.14+ burst 机制借用的突发额度 |

对照实验：

```sh
make stop && make run-unthrottled   # 4 核配额，nr_throttled 不再增长
```

## 结论与修复

1. 节流严重 → 提高 CPU quota（`--cpus` / K8s `limits.cpu`）。
2. 突发型负载 → 评估 `cpu.max.burst`（K8s 1.27+ 的 CPU burst 特性）。
3. 减少瞬时并发 worker 数，让负载平滑。
4. K8s 中注意：只设 `limits.cpu` 不设 `requests.cpu` 时，requests 默认等于 limits；
   官方文档明确 CPU limit 通过节流强制生效，而 memory limit 超限直接 OOMKilled。

## 延伸：调度延迟量化

容器内可用 bcc 工具直接看排队延迟（需特权）：

```sh
docker run --privileged -it --rm local/cfs-throttle bash
runqlat-bpfcc 1            # 运行队列等待直方图
runqslower-bpfcc 10000     # 超过 10ms 的调度延迟事件
```

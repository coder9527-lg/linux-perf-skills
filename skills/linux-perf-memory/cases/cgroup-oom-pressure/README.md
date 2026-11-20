# 案例：容器内存压力、PSI 与 cgroup OOM

## 学习目标

1. 区分 **系统级 OOM** 与 **cgroup OOM**：后者是容器超过自己的 `memory.max`
   （即 `docker run -m`），宿主机其余内存仍然空闲。
2. 用 PSI 在 OOM 发生前量化内存回收压力，而不是等进程被杀。
3. 读懂 cgroup v2 `memory.events` 的各计数含义（依据内核 cgroup-v2 官方文档）。

## 实验一：压力但不 OOM

```sh
make build
make run-pressure          # 256M 限制，2 个 worker 各占 90% 可用内存
make observe               # 另开终端，看 PSI 与 events
```

预期：

```
some avg10=... avg60=... avg300=... total=...
full avg10=... ...        # full 非 0 说明所有任务同时停滞（thrashing）
```

同时 `memory.events` 中 `high`（触及 memory.high 被节流回收）增长，`oom_kill` 不增长。

## 实验二：硬限制触发 OOMKilled

```sh
make stop
make run-oom               # 128M 限制申请 200M
docker inspect -f '{{.State.OOMKilled}} {{.State.ExitCode}}' cgroup-oom-lab
# 预期：true 137
make events
# 预期：oom 与 oom_kill 计数增长
```

## memory.events 字段释义

| 字段 | 含义（官方文档口径） |
|---|---|
| `low` | 用量在 low 线以下仍被回收，通常说明 low 线配置过高/全局紧张 |
| `high` | 超过 memory.high 被节流并强制直接回收的次数 |
| `max` | 用量触及 memory.max、进入硬回收的次数 |
| `oom` | 分配即将失败、触发 OOM 的次数 |
| `oom_kill` | 本 cgroup 内进程被 OOM killer 杀死的次数 |
| `oom_group_kill` | 触发 group OOM（整组一起杀）的次数 |
| `sock_throttled` | 本 cgroup 关联的网络 socket 被节流次数 |

> `memory.events` 是层级聚合的（含子 cgroup 事件）；只看本层用 `memory.events.local`。

## 配套动态工具（特权容器内）

```sh
drsnoop-bpfcc          # 直接回收事件：哪个 PID 因回收等了多久
compactsnoop-bpfcc     # 内存规整延迟（高阶分配失败相关）
oomkill-bpfcc          # OOM 击杀现场，含内核栈与 oom_score
```

## 修复方向

- 调大 `memory.max` / K8s `limits.memory`，并为页缓存与非堆内存留余量。
- JVM 等运行时显式限制堆（`-Xmx`），总和控制在 limit 的 70%~80%。
- 用 `memory.high` 做软限流，让进程在被杀前先被节流，比硬 OOM 更平滑。
- K8s 中容器状态 `OOMKilled`、退出码 137 即本场景；排查顺序：limit 是否过低 → 是否泄漏 → 是否非堆（直接内存/线程栈/Metaspace）超预期。

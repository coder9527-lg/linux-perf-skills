# linux-perf-skills

一套按性能领域组织的 **Linux 性能诊断 Agent Skills 集合**，遵循 [Agent Skills 规范](https://agentskills.io/specification)。每个 skill 把一类性能问题的**诊断流程、根因模式、修复手法和可复现实验**打包，AI Agent 可按 `description` 自动路由加载。

## Skill 列表

| Skill | 领域 | 覆盖案例 | 典型触发场景 |
|---|---|---|---|
| [`linux-perf-cpu`](skills/linux-perf-cpu/SKILL.md) | CPU | nginx-high-cpu、nginx-short-process、short-lived-process、cfs-throttle | usr%/sys% 高、负载异常、短时进程、僵尸进程、上下文切换、CFS 限流 |
| [`linux-perf-memory`](skills/linux-perf-memory/SKILL.md) | 内存 | mem-leak、tomcat、cgroup-oom-pressure | 内存泄漏、RSS 增长、OOM、容器/JVM 内存限制、memleak 无栈、cgroup 压力 |
| [`linux-perf-io`](skills/linux-perf-io/SKILL.md) | 磁盘 I/O | high-iowait-process、io-cached、io-latency、logging-app、mysql-slow、redis-slow、fio-benchmark | iowait 高、磁盘 100%、直接 I/O、日志风暴、中间件 I/O 瓶颈、fio 基准 |
| [`linux-perf-network`](skills/linux-perf-network/SKILL.md) | 网络 | dns、network-latency、nat、packet-drop、netem-lab | 延迟、丢包重传、DNS 抖动、NAT/conntrack、MTU、端口耗尽、netem 故障注入 |
| [`linux-perf-observability`](skills/linux-perf-observability/SKILL.md) | 工具/方法论 | flamegraph、bcc、bpftrace-lab、nginx-throughput | perf 火焰图（on/off-CPU/差异）、eBPF/bcc 全工具地图、bpftrace、SystemTap、USE/RED/PSI、压测 |

## 内容覆盖

每个 SKILL.md 除案例讲解外，还包含：自顶向下的诊断流程、量化判定阈值、容器/cgroup v2 场景、现代内核特性（PSI、bcc 工具链、内核版本适配坑）、案例之外的扩展根因模式，以及带完整命令的工具速查表（`references/tools-cheatsheet.md`）。技术依据来自内核官方文档（PSI、cgroup-v2、ip-sysctl、nf_conntrack）与 bcc 官方工具目录。

每个 skill 还配有 `references/runbook.md`：症状驱动的决策树，从告警/现象出发，按「看哪个指标 → 阈值怎么判 → 分叉到哪个根因 → 对应修复」组织，可在不读完全部案例时快速走查。可观测性 skill 额外提供 `references/metrics-glossary.md`，给出 CPU/内存/I-O/网络关键指标的官方口径释义与经验判定阈值。

## 一键现场采集

```sh
# 采样 5 秒（默认），输出到 /tmp/perf-snapshot-<时间戳>/ 并打包 tar.gz
./scripts/perf-snapshot.sh
# 自定义采样秒数与输出目录
./scripts/perf-snapshot.sh 10 /tmp/my-snapshot
```

脚本零特殊依赖（procps/sysstat/iproute2 缺失自动跳过）、全程只读，自动识别 cgroup v1/v2 与 PSI，按 USE 方法采集 top/vmstat/mpstat/iostat/ss/nstat/sar/PSI/cgroup 等 20 余项现场；bcc 工具存在时各限时采样 10 秒。采集结束输出快速判读指引，也可直接把 tar.gz 交给性能分析人员。

## 目录结构

```text
linux-perf-skills/
├── README.md
├── scripts/
│   └── perf-snapshot.sh           # 一键只读采集现场快照（容器/cgroup v2 自适应）
└── skills/<skill-name>/
    ├── SKILL.md                   # 技能主体：frontmatter + 诊断流程 + 根因模式 + 修复
    ├── references/
    │   ├── runbook.md             # 症状驱动决策树
    │   ├── tools-cheatsheet.md    # 该领域工具速查表
    │   └── metrics-glossary.md    # （仅 observability）指标权威释义与阈值
    └── cases/                     # 可复现实验案例（Dockerfile + Makefile + 源码）
```

## 安装

### Pi / 兼容 Agent Skills 的 Agent

```sh
git clone <your-repo-url>/linux-perf-skills.git
# 方式一：放到用户级 skills 目录
ln -s "$(pwd)/linux-perf-skills/skills/"* ~/.agents/skills/
# 方式二：项目内使用
mkdir -p .agents/skills && cp -r linux-perf-skills/skills/* .agents/skills/
```

重启 Agent 后通过 `/skill:linux-perf-cpu` 等命令显式调用，或由模型按描述自动加载。

### 运行案例的环境要求

```sh
# Ubuntu/Debian
sudo apt-get install -y docker.io build-essential bpfcc-tools linux-tools-common linux-tools-$(uname -r)
```

案例均为 Docker 化实验，进入 `skills/<skill>/cases/<case>` 后 `make build && make run`，多数磁盘/网络案例需要 `--privileged` 或 `NET_ADMIN`。

## 说明与已知限制

- 工具命令以 Debian/Ubuntu 命名为准（bcc 工具带 `-bpfcc` 后缀，如 `execsnoop-bpfcc`）；RHEL 系通常去掉后缀。PSI 需内核 4.20+，部分 bcc 能力依赖 5.x 内核，eBPF/块设备/网络注入案例需特权容器。
- 案例基于较早的 Ubuntu LTS 基础镜像，部分镜像在新版本 Docker 上构建可能失败，可仅参考源码与排查思路或替换基础镜像。
- `bcc` 案例挂的 `do_sys_open` 在 5.x+ 内核已改名为 `do_sys_openat2`，新内核请改用 tracepoint `syscalls:sys_enter_openat`（observability skill 中已说明）。
- 故障注入类实验（`tc netem`、`iptables DROP`、MTU 修改）结束后务必清理规则。
- 所有案例镜像名统一使用 `local/*` 本地命名空间，仅用于本机实验，不指向任何远程仓库。

## 许可

MIT License，详见 [LICENSE](LICENSE)。

#!/usr/bin/env bash
# perf-snapshot.sh — 一键采集 Linux 性能现场快照
#
# 设计原则：
#   - 零特殊依赖，仅用 procps/sysstat/iproute2 常见命令，缺失自动跳过
#   - 只读采集，不修改任何系统状态
#   - 同时支持物理机/虚拟机/容器，自动识别 cgroup v1/v2 与 PSI
#
# 用法：
#   ./perf-snapshot.sh [采样秒数，默认5] [输出目录，默认 /tmp/perf-snapshot-<时间戳>]
#
# 采集后按 README 的"如何读快照"逐项排查，或把目录打包发给性能分析人员。

set -u
DURATION="${1:-5}"
OUT="${2:-/tmp/perf-snapshot-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUT"

have() { command -v "$1" >/dev/null 2>&1; }
section() { printf '\n========== %s ==========\n' "$1"; }

# 命令存在才执行，输出同时落盘，缺失命令记录占位而非报错
run() {
    local name="$1"; shift
    section "$name: $*" | tee -a "$OUT/summary.txt"
    if have "$1"; then
        "$@" >"$OUT/$name.txt" 2>&1 && echo "  -> $OUT/$name.txt" | tee -a "$OUT/summary.txt"
    else
        echo "SKIPPED: $1 not installed" | tee "$OUT/$name.txt" | tee -a "$OUT/summary.txt"
    fi
}

echo "perf snapshot: duration=${DURATION}s out=$OUT" | tee "$OUT/summary.txt"
section "system" | tee -a "$OUT/summary.txt"
{
    date; uname -a;
    echo "--- uptime ---"; uptime
    echo "--- cpu count ---"; nproc
    echo "--- kernel cmdline ---"; cat /proc/cmdline 2>/dev/null
    echo "--- virtualization ---"; systemd-detect-virt 2>/dev/null || echo "unknown"
} | tee "$OUT/00-system.txt"

# ---- USE 巡检：资源使用率 / 饱和度 / 错误 ----
run 01-top top -b -n1
run 02-vmstat vmstat 1 "$DURATION"
run 03-mpstat mpstat -P ALL 1 "$DURATION"
run 04-memory free -h
run 05-meminfo cat /proc/meminfo
run 06-iostat iostat -xz 1 "$DURATION"
run 07-disk-space df -hT
run 08-ss-summary ss -s
run 09-ss-listen ss -lntup
run 10-nstat nstat -az
run 11-sar-net sar -n DEV 1 "$DURATION"
run 12-ip-link ip -s link
run 13-ps-topcpu ps -eo pid,ppid,psr,stat,pcpu,rss,comm --sort -pcpu
run 14-interrupts cat /proc/interrupts
run 15-softnet cat /proc/net/softnet_stat
run 16-dmesg dmesg -T
run 17-fd-nr cat /proc/sys/fs/file-nr

# ---- PSI（内核 4.20+，容器与主机均适用）----
section "PSI pressure" | tee -a "$OUT/summary.txt"
if [ -d /proc/pressure ]; then
    for r in cpu memory io; do
        echo "--- /proc/pressure/$r ---" | tee -a "$OUT/summary.txt"
        tee "$OUT/18-psi-$r.txt" <"/proc/pressure/$r"
    done
else
    echo "PSI unavailable (kernel < 4.20)" | tee "$OUT/18-psi.txt"
fi

# ---- cgroup 版本识别与容器指标 ----
section "cgroup" | tee -a "$OUT/summary.txt"
CG="$(stat -fc %T /sys/fs/cgroup 2>/dev/null || echo unknown)"
echo "cgroup fs type: $CG" | tee "$OUT/19-cgroup.txt"
if [ "$CG" = "cgroup2fs" ]; then
    echo "[v2] cpu / memory / io controller" | tee -a "$OUT/19-cgroup.txt"
    for f in cpu.stat memory.current memory.max memory.high memory.events io.stat; do
        for p in /sys/fs/cgroup "/sys/fs/cgroup$(cat /proc/self/cgroup 2>/dev/null | cut -d: -f3)"; do
            [ -f "$p/$f" ] && { echo "--- $p/$f ---"; cat "$p/$f"; } >>"$OUT/19-cgroup.txt" 2>/dev/null
        done
    done
elif [ "$CG" = "tmpfs" ]; then
    echo "[v1] legacy controllers" | tee -a "$OUT/19-cgroup.txt"
    for f in cpu,cpuacct/cpu.stat memory/memory.usage_in_bytes memory/memory.limit_in_bytes memory/memory.stat; do
        p="/sys/fs/cgroup/$f"
        [ -f "$p" ] && { echo "--- $p ---"; cat "$p"; } >>"$OUT/19-cgroup.txt" 2>/dev/null
    done
else
    echo "cgroup info unavailable" | tee -a "$OUT/19-cgroup.txt"
fi

# ---- 可选的 eBPF 工具：存在才采，各自限时避免常驻 ----
section "eBPF (optional, 10s each)" | tee -a "$OUT/summary.txt"
for tool in runqlat-bpfcc biolatency-bpfcc tcpretrans-bpfcc; do
    if have "$tool"; then
        echo "sampling $tool 10s ..." | tee -a "$OUT/summary.txt"
        # bcc 工具需 SIGINT 才输出最终直方图，SIGTERM 会丢输出
        timeout -s INT 10 "$tool" 1 >"$OUT/20-$tool.txt" 2>&1 || true
    fi
done

# ---- 打包 ----
cd "$(dirname "$OUT")" && tar czf "$OUT.tar.gz" "$(basename "$OUT")"
section "done" | tee -a "$OUT/summary.txt"
echo "snapshot dir : $OUT"
echo "archive      : $OUT.tar.gz"
echo
echo "快速判读："
echo "  1. 18-psi-*  是否有 full 停滞（最优先的饱和信号）"
echo "  2. 03-mpstat  us/sy/wa/si/st 分解，定位 CPU 类型"
echo "  3. 06-iostat  %util/await/aqu-sz，判断磁盘饱和还是单笔慢"
echo "  4. 10-nstat   TcpRetransSegs/ListenOverflows 是否增长"
echo "  5. 19-cgroup  nr_throttled 与 oom_kill 计数（容器问题）"

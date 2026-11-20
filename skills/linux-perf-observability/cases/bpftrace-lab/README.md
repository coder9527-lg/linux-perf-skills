# 案例：bpftrace 一行流与现代 eBPF 跟踪

## 与旧 bcc 案例的关系

旧 `bcc/trace-open.py` 挂的 kprobe `do_sys_open` 在 5.x+ 内核已改名为
`do_sys_openat2`，直接运行会报 `could not open kprobe`。本案例展示现代做法：
**优先挂稳定的 tracepoint，而不是随版本变化的内核函数符号**。

## 复现

```sh
make build && make run
make check          # 确认 BTF 与 bpftrace 可用
make shell          # 进入容器执行下面的脚本
```

## 八个一行流（覆盖四大领域）

```sh
# 1. 按进程统计系统调用量（CPU/通用）
bpftrace -e 'tracepoint:raw_syscalls:sys_enter { @[comm] = count(); }'

# 2. on-CPU 内核栈采样（CPU 热点）
bpftrace -e 'profile:hz:99 { @[kstack] = count(); }'

# 3. openat 跟踪（替代旧 do_sys_open kprobe，符号稳定）
bpftrace -e 'tracepoint:syscalls:sys_enter_openat { printf("%s -> %s\n", comm, str(args->filename)); }'

# 4. read() 延迟直方图（I/O）
bpftrace -e 'kprobe:vfs_read { @s[tid] = nsecs; }
  kretprobe:vfs_read /@s[tid]/ { @read_us = hist((nsecs - @s[tid]) / 1000); delete(@s[tid]); }'

# 5. 块 I/O 延迟（I/O，tracepoint 比 blk_* kprobe 稳定）
bpftrace -e 'tracepoint:block:block_rq_issue { @s[tid] = nsecs; }
  tracepoint:block:block_rq_complete /@s[tid]/ { @bio_us = hist((nsecs - @s[tid]) / 1000); delete(@s[tid]); }'

# 6. TCP 重传统计（网络）
bpftrace -e 'kprobe:tcp_retransmit_skb { @retrans[comm] = count(); }'

# 7. 内存分配排行（内存）
bpftrace -e 'uprobe:/lib/x86_64-linux-gnu/libc.so.6:malloc { @bytes[comm] = sum(arg0); }
  interval:s:10 { print(@bytes); clear(@bytes); }'

# 8. 进程退出码（短时进程/异常退出）
bpftrace -e 'tracepoint:sched:sched_process_exit { printf("%s pid=%d\n", comm, pid); }'
```

## 选型与注意

1. **tracepoint 优先于 kprobe**：tracepoint 是内核稳定 ABI，kprobe 符号可能跨版本消失。
2. **聚合 map 优先于逐事件 printf**：生产环境用 `count()/hist()/sum()` 聚合降低开销，
   事件型输出只在短时排障时用。
3. **CO-RE 与 BTF**：现代内核内置 `/sys/kernel/btf/vmlinux`，bpftrace 靠它自动适配结构体布局，
   无需为每个内核版本编译。
4. 权限：新内核 `CAP_BPF`+`CAP_PERFMON` 即可（本案例 Makefile 已配置）；
   老内核（<5.8）仍需 `--privileged`。
5. 与 bcc 的关系：一次性查询用 bpftrace 更简洁；需要复杂用户态程序、长期守护用 bcc/Python。

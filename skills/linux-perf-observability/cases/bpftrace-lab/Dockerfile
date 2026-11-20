FROM ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        bpftrace bpfcc-tools linux-tools-common sysstat \
        strace curl procps kmod && \
    rm -rf /var/lib/apt/lists/*
# bpftrace 需要内核头与 BTF；现代发行版内核一般内置 BTF（/sys/kernel/btf/vmlinux）
CMD ["sleep", "infinity"]

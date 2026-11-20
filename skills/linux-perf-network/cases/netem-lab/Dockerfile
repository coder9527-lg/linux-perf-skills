FROM ubuntu:22.04
RUN apt-get update && apt-get install -y --no-install-recommends \
        iproute2 iputils-ping curl tcpdump conntrack \
        sysstat bpfcc-tools && \
    rm -rf /var/lib/apt/lists/*
CMD ["sleep", "infinity"]

FROM ubuntu:22.04
RUN apt-get update && apt-get install -y --no-install-recommends \
        stress-ng sysstat procps bpfcc-tools && \
    rm -rf /var/lib/apt/lists/*
CMD ["sleep", "infinity"]

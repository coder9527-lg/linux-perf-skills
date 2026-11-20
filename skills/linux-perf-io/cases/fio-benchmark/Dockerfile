FROM ubuntu:22.04
RUN apt-get update && apt-get install -y --no-install-recommends \
        fio sysstat bpfcc-tools && \
    rm -rf /var/lib/apt/lists/*
COPY job-randread.fio /jobs/job-randread.fio
WORKDIR /data
CMD ["sleep", "infinity"]

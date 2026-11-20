IMAGE := local/bpftrace-lab
NAME  := bpftrace-lab

.PHONY: build run shell check stop clean

build:
	docker build -t $(IMAGE) .

# 现代内核用 CAP_BPF + CAP_PERFMON；旧内核退回 --privileged
run:
	docker run -d --name $(NAME) \
		--cap-add BPF --cap-add PERFMON --cap-add SYS_ADMIN --cap-add SYS_RESOURCE \
		-v /sys/kernel/btf:/sys/kernel/btf:ro \
		--pid host --rm $(IMAGE)

shell:
	docker exec -it $(NAME) bash

check:
	@docker exec $(NAME) ls -l /sys/kernel/btf/vmlinux
	@docker exec $(NAME) bpftrace --version

stop:
	docker stop $(NAME) 2>/dev/null || true

clean: stop
	docker rmi $(IMAGE) 2>/dev/null || true

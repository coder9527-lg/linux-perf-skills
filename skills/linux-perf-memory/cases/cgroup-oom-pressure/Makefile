IMAGE := local/cgroup-oom
NAME  := cgroup-oom-lab

.PHONY: build run-pressure run-oom observe events stop clean

build:
	docker build -t $(IMAGE) .

# 256M 限制下制造内存压力（但不立刻 OOM），观察 PSI 与直接回收
run-pressure:
	docker run -d --name $(NAME) -m 256m --memory-reservation 128m --rm $(IMAGE)
	docker exec -d $(NAME) stress-ng --vm 2 --vm-bytes 90% --vm-keep --timeout 120s

# 超过硬限制，触发 cgroup OOMKilled（注意与系统级 OOM 区分）
run-oom:
	docker run -d --name $(NAME) -m 128m --rm $(IMAGE)
	-docker exec $(NAME) stress-ng --vm 1 --vm-bytes 200M --vm-keep
	@sleep 3; docker ps -a --filter name=$(NAME) --format '{{.Status}}'

# 宿主机观察 cgroup v2 计数
events:
	@CID=$$(docker inspect -f '{{.Id}}' $(NAME) 2>/dev/null); \
	echo "== memory.events（high/max/oom/oom_kill 计数）=="; \
	cat /sys/fs/cgroup/system.slice/docker-$$CID.scope/memory.events 2>/dev/null || \
	cat /sys/fs/cgroup/memory/docker/$$CID/memory.events 2>/dev/null || \
	docker exec $(NAME) cat /sys/fs/cgroup/memory.events

observe:
	@CID=$$(docker inspect -f '{{.Id}}' $(NAME)); \
	watch -n1 "docker exec $(NAME) cat /proc/pressure/memory; echo; \
	          cat /sys/fs/cgroup/system.slice/docker-$$CID.scope/memory.events 2>/dev/null || true"

stop:
	docker stop $(NAME) 2>/dev/null || true

clean: stop
	docker rmi $(IMAGE) 2>/dev/null || true

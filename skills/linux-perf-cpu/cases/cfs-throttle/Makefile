IMAGE := local/cfs-throttle
NAME  := cfs-throttle-lab

.PHONY: build run run-throttled run-unthrottled observe stop clean

build:
	docker build -t $(IMAGE) .

# 受限：0.25 核配额，观察 CFS 节流导致的延迟毛刺
run-throttled:
	docker run -d --name $(NAME) --cpus 0.25 --rm $(IMAGE)
	docker exec -d $(NAME) stress-ng --cpu 4 --timeout 120s

# 对照：给足 4 核，不节流
run-unthrottled:
	docker run -d --name $(NAME) --cpus 4 --rm $(IMAGE)
	docker exec -d $(NAME) stress-ng --cpu 4 --timeout 120s

# 在宿主机另开终端执行：观察节流计数（cgroup v2）
observe:
	@echo "== cpu.stat（nr_throttled/throttled_usec 增长即被限流）=="
	@CID=$$(docker inspect -f '{{.Id}}' $(NAME)); \
	 watch -n1 "cat /sys/fs/cgroup/system.slice/docker-$$CID.scope/cpu.stat 2>/dev/null || \
	           cat /sys/fs/cgroup/cpu/docker/$$CID/cpu.stat 2>/dev/null || \
	           docker exec $(NAME) cat /sys/fs/cgroup/cpu.stat"

stop:
	docker stop $(NAME) 2>/dev/null || true

clean: stop
	docker rmi $(IMAGE) 2>/dev/null || true

IMAGE := local/fio-lab
NAME  := fio-lab

.PHONY: build run direct cached observe stop clean

build:
	docker build -t $(IMAGE) .

# 用 tmpfs 挂载避免污染宿主机磁盘，重点学习指标读法；真实磁盘测试改为挂载块设备
run:
	docker run -d --name $(NAME) --tmpfs /data:size=2g --privileged --rm $(IMAGE)

direct:
	docker exec $(NAME) fio /jobs/job-randread.fio

# 缓冲 I/O 对照：direct=0，观察页缓存命中与延迟差异
cached:
	docker exec $(NAME) sh -c 'sed "s/direct=1/direct=0/" /jobs/job-randread.fio > /tmp/c.fio && fio /tmp/c.fio'

observe:
	docker exec -d $(NAME) sh -c 'iostat -xz 1 > /tmp/iostat.log 2>&1'
	@echo "运行 make direct 后，另开：docker exec -it $(NAME) sh -c \"watch -n1 cat /proc/pressure/io\""

stop:
	docker stop $(NAME) 2>/dev/null || true

clean: stop
	docker rmi $(IMAGE) 2>/dev/null || true

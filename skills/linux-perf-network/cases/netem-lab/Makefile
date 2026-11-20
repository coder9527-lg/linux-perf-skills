IMAGE := local/netem-lab
NAME  := netem-lab
IFACE := eth0

.PHONY: build run shell loss delay reorder corrupt clear observe stop clean

build:
	docker build -t $(IMAGE) .

# NET_ADMIN + NET_RAW 是 tc/iptables/tcpdump 的最小权限，不用 --privileged
run:
	docker run -d --name $(NAME) --cap-add NET_ADMIN --cap-add NET_RAW --rm $(IMAGE)

shell:
	docker exec -it $(NAME) bash

# === 故障注入（tc netem）===
loss:
	docker exec $(NAME) tc qdisc replace dev $(IFACE) root netem loss 30%

delay:
	docker exec $(NAME) tc qdisc replace dev $(IFACE) root netem delay 100ms 20ms distribution normal

reorder:
	docker exec $(NAME) tc qdisc replace dev $(IFACE) root netem delay 50ms reorder 25%

corrupt:
	docker exec $(NAME) tc qdisc replace dev $(IFACE) root netem corrupt 5%

clear:
	docker exec $(NAME) tc qdisc del dev $(IFACE) root

observe:
	@echo "== qdisc =="; docker exec $(NAME) tc -s qdisc show dev $(IFACE)
	@echo "== TCP 计数 =="; docker exec $(NAME) nstat -az 2>/dev/null | grep -E 'Retrans|ListenOverflow|Timeout' || true
	@echo "== 重传实时事件（Ctrl-C 退出）=="; docker exec -it $(NAME) tcpretrans-bpfcc

stop:
	docker stop $(NAME) 2>/dev/null || true

clean: stop
	docker rmi $(IMAGE) 2>/dev/null || true

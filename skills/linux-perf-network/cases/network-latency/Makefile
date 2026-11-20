.PHONY: run
run:
	docker run --name nginx --network=host -itd local/nginx:latency

.PHONY: build
build:
	docker build -t local/nginx:latency -f Dockerfile .

.PHONY: push
push:
	docker push local/nginx:latency

.PHONY: clean
clean:
	docker rm -f nginx || echo "Container nginx already deleted."

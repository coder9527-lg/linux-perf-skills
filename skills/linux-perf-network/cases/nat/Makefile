.PHONY: run
run:
	docker run --name nginx --privileged -p 8080:8080 -itd local/nginx:nat

.PHONY: host-network
host-network:
	docker run --name nginx-hostnet --privileged --network=host -itd local/nginx:80

.PHONY: build
build:
	docker build -t local/nginx:nat -f Dockerfile .
	docker build -t local/nginx:80 -f Dockerfile.80 .

.PHONY: push
push:
	docker push local/nginx:nat
	docker push local/nginx:80

.PHONY: clean
clean:
	docker rm -f nginx nginx-hostnet || echo "Containers already deleted."

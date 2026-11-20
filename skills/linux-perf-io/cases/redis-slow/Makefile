DATA_NUM ?= 5000

.PHONY: run
run: redis
	docker run --name=app --network=container:redis -itd local/redis-app

.PHONY: redis
redis:
	docker run --name=redis -itd -p 10000:80 local/redis-server


.PHONY: build
build:
	docker build -t local/redis-app -f Dockerfile .
	docker build -t local/redis-server -f Dockerfile.redis .


.PHONY: init
init:
	curl http://127.0.0.1:10000/init/$(DATA_NUM)


.PHONY: push
push:
	docker push local/redis-app
	docker push local/redis-server

.PHONY: clean
clean:
	docker rm -f app redis || echo "Containers already deleted."

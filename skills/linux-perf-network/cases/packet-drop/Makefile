.PHONY: run
run:
	docker run --name nginx --hostname nginx --privileged -p 80:80 -itd local/nginx:drop

.PHONY: build
build:
	docker build -t local/nginx:drop -f Dockerfile .

.PHONY: push
push:
	docker push local/nginx:drop

.PHONY: clean
clean:
	docker rm -f nginx || echo "Container nginx already deleted."
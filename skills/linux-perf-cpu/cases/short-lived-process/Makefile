.PHONY: build
build:
	gcc -o app app.c
	docker build -t local/app:short-process -f Dockerfile .

.PHONY: push
push:
	docker push local/app:short-process

.PHONY: run
run:
	docker run --name=app -itd local/app:short-process

.PHONY: clean
clean:
	rm -f app
	docker rm -f app || echo "Container app already deleted."

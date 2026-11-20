.PHONY: build
build:
	gcc -o app app.c
	docker build -t local/app:io-direct -f Dockerfile .
	gcc -o app app-cached.c
	docker build -t local/app:io-cached -f Dockerfile .

.PHONY: push
push:
	docker push local/app:io-direct
	docker push local/app:io-cached

.PHONY: run
run:
	docker run --privileged --name=app -itd local/app:io-direct

.PHONY: clean
clean:
	rm -f app
	docker rm -f app || echo "Container app already deleted."

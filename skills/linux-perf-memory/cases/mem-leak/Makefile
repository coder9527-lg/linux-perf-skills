.PHONY: build
build:
	gcc -o app app.c -pthread
	docker build -t local/app:mem-leak -f Dockerfile .
	gcc -o app app-fix.c -pthread
	docker build -t local/app:mem-leak-fix -f Dockerfile .

.PHONY: push
push:
	docker push local/app:mem-leak
	docker push local/app:mem-leak-fix

.PHONY: run
run:
	docker run --name=app -itd local/app:mem-leak

.PHONY: clean
clean:
	rm -f app
	docker rm -f app || echo "Container app already deleted."

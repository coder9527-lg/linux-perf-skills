.PHONY: run
run:
	docker run --name=app -p 10000:80 -itd local/word-pop


.PHONY: build
build:
	docker build -t local/word-pop -f Dockerfile .


.PHONY: push
push:
	docker push local/word-pop


.PHONY: clean
clean:
	docker rm -f app || echo "Container app already deleted."

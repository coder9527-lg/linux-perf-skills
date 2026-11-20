.PHONY: run
run:
	docker run -v /tmp:/tmp --name=app -itd local/logapp


.PHONY: build
build:
	docker build -t local/logapp -f Dockerfile .


.PHONY: push
push:
	docker push local/logapp


.PHONY: clean
clean:
	docker rm -f app || echo "Container app already deleted."

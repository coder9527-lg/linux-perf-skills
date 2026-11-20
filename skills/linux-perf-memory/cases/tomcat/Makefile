.PHONY: run
run:
	docker run --name tomcat --cpus 0.1 -m 512M -p 8080:8080 -itd local/tomcat:8

.PHONY: run-jre11
run-jre11:
	docker run --name tomcat-jre11 --cpus 0.1 -m 512M -p 8080:8080 -itd local/tomcat:11

.PHONY: build
build:
	docker build -t local/tomcat:11 -f Dockerfile.jre11  .
	docker build -t local/tomcat:8 -f Dockerfile .

.PHONY: push
push:
	docker push local/tomcat:11
	docker push local/tomcat:8

.PHONY: clean
clean:
	docker rm -f tomcat tomcat-jre11 || echo "Container comcat already deleted."

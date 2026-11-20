DATA_NUM ?= 10000

.PHONY: run
run: mysql dataservice
	docker run --name=app --network=container:mysql -itd local/mysql-slow

.PHONY: dataservice
dataservice:
	docker run --name=dataservice -itd --privileged local/mysql-dataservice


.PHONY: mysql
mysql:
	docker run --name=mysql -itd -p 10000:80 -m 800m local/mysql:5.6


.PHONY: init
init:
	docker exec -i mysql mysql -uroot -P3306 < tables.sql
	curl http://127.0.0.1:10000/db/insert/products/$(DATA_NUM)


.PHONY: build
build:
	docker build -t local/mysql-slow -f Dockerfile .
	docker build -t local/mysql:5.6 -f Dockerfile.mysql .
	docker build -t local/mysql-dataservice -f Dockerfile.dataservice .


.PHONY: test
test:
	curl http://127.0.0.1:10000/products/sample-word


.PHONY: push
push:
	docker push local/mysql-slow
	docker push local/mysql:5.6
	docker push local/mysql-dataservice


.PHONY: clean
clean:
	docker rm -f app mysql dataservice || echo "Containers already deleted."

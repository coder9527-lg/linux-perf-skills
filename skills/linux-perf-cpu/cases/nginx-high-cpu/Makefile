.PHONY: run
run:
	docker run --name nginx -p 10000:80 -itd local/nginx:cpu
	docker run --name phpfpm -itd --network container:nginx local/php-fpm:cpu

.PHONY: build
build:
	docker build -t local/nginx:cpu -f Dockerfile.nginx .
	docker build -t local/php-fpm:cpu -f Dockerfile.php-fpm .

.PHONY: push
push:
	docker push local/nginx:cpu
	docker push local/php-fpm:cpu

.PHONY: clean
clean:
	docker rm -f nginx phpfpm || echo "Container nginx already deleted."

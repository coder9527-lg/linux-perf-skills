.PHONY: run
run:
	docker run --name nginx -p 10000:80 -itd local/nginx:sp
	docker run --name phpfpm -itd --network container:nginx local/php-fpm:sp

.PHONY: build
build:
	docker build -t local/nginx:sp -f Dockerfile.nginx .
	docker build -t local/php-fpm:sp -f Dockerfile.php-fpm .

.PHONY: push
push:
	docker push local/nginx:sp
	docker push local/php-fpm:sp

.PHONY: clean
clean:
	docker rm -f nginx phpfpm  || echo "Container nginx already deleted."

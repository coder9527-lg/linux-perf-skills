.PHONY: run
run:
	docker run --name nginx --network host --privileged -itd local/nginx-tp
	docker run --name phpfpm --network host --privileged -itd local/php-fpm-tp

.PHONY: build
build:
	docker build -t local/nginx-tp -f Dockerfile.nginx .
	docker build -t local/php-fpm-tp -f Dockerfile.php-fpm .

.PHONY: push
push:
	docker push local/nginx-tp
	docker push local/php-fpm-tp

.PHONY: clean
clean:
	docker rm -f nginx phpfpm || echo "Container nginx already deleted."

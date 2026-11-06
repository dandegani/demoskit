check:
	bash deploy/ci/check.sh

run:
	python main.py

up:
	docker compose up -d --build

down:
	docker compose down

logs:
	docker compose logs -f --tail=200

.PHONY: check run up down logs

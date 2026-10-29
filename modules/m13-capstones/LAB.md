# Module 13 — Capstones: hands-on

## 13.1 Your URL shortener
Build your own version (any language), with this contract:
- `POST /api/links` with `{"url": "..."}` answers `201` and `{"code": "..."}`
- `GET /{code}` answers `302` with `Location:` the long URL; an unknown code answers `404`

Run it on port 8080 (or any port), then:
```bash
make check-capstone URL=http://localhost:8080
```
The checker tests the contract, then sends 500 redirects per second for 30 s and passes if p99 stays under 50 ms with
at least 99.9% correct answers. Then write down: where did it break first, and what would you change?

## 13.3 News feed
```bash
docker compose up -d --build --wait db && docker compose run --rm --no-deps app drill feed
```
**Predict:** for fan-out on write vs on read: time to post (ordinary user, celebrity) and time to read a feed.
Then change the follower counts in `app/feed.go` and add the hybrid (copy on write for ordinary users only).

## 13.4 Chat rooms
```bash
export COMPOSE_FILE=compose.yaml:modules/m13-capstones/compose.chat.yaml UID GID=$(id -g)
docker compose up -d --build --wait
docker compose run --rm -e CONNS=500 -e RESULT=/lab/mine-chat.json k6 run --quiet modules/m13-capstones/chat.js
curl -s localhost:8080/stats/chat
```
**Predict:** delivery time p99, and memory per connection. Then double `CONNS`.

Clean up: `make down`.

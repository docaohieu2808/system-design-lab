# System Design Lab

Labs for the course *System Design in Practice: Build It, Load It, Break It*.
Every number in the course comes from running these files.

## Module 1: one server, honestly measured

```bash
docker compose up -d --build                     # app + Postgres (half a CPU core each)
curl -i localhost:8080/1C                        # 302 to the long URL
docker compose run --rm k6 run m01-find-the-ceiling.js   # step the load up
docker compose down -v                           # clean up
```

`STEPS=4000,5000 docker compose run --rm -e STEPS k6 run ...` runs only some steps.
While it runs, `docker stats` shows which container is full. If k6 is at its limit,
you are measuring k6, not the server.

The demo app is a URL shortener: `POST /api/links {"url": ...}`, `GET /{code}` redirects.
The database is seeded with 100,000 links.

Reference results from the course machine: `load/results/m01-steps.json`. Your numbers
will differ with your CPU; the shape of the curve will not.

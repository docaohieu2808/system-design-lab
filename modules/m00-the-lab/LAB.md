# Module 0 — The lab: hands-on

Do this alongside lessons 0.1–0.5. Every step: **predict first, write it down, then run.**

## 0. Before you start
- Docker with Compose v2, `make`, `curl`, Python 3. A machine with 4 cores and 8 GB RAM is the reference; smaller works.
- Close what you can, plug in your laptop: background programs change the numbers.

## 1. Start the lab (lesson 0.2)
```bash
git clone https://github.com/docaohieu2808/system-design-lab && cd system-design-lab
make up
curl -i localhost:8080/1C
```
**Predict:** what status code does a short link answer with, and what header tells the browser where to go?
**Check:** `HTTP/1.1 302 Found` and `Location: https://example.com/articles/100`.

## 2. Check before every experiment (lesson 0.2)
```bash
make verify
```
**Check:** three `ok` lines, then `verify passed`. If a line says FAIL, the message names the part; paste the whole
output, your machine (cores, RAM, OS) and the command into the Q&A.

## 3. Calibrate your machine (lesson 0.3)
```bash
make calibrate          # about 2 minutes
make calibrate          # again: the two ratios should be close
```
**Predict:** will your ceiling be higher or lower than the course machine's 3,900 requests per second?
**Use it:** multiply every request rate in the videos by your ratio. If the two runs differ a lot, your machine is too
busy to measure; close more programs and try again.

## 4. The test that hides a slow server (lesson 0.4)
```bash
make m00                # about 15 minutes: closed vs open load, each with and without a 2-second freeze, 3 runs
cat modules/m00-the-lab/results/results.json
```
**Predict:** with the closed test ("doorman"), will a 2-second freeze change the p99? With the open test ("street")?
**Check:** closed freeze p99 stays near the calm p99; open freeze p99 jumps to about the length of the freeze.
Course machine: 3.08 ms vs 1,542 ms. Your numbers differ; the gap between the two should not.

## 5. When the load generator lies (lesson 0.5)
```bash
make m01-starved        # Module 1's test with k6 squeezed to one core
```
Then compare `modules/m01-one-server/results-k6-1core/results.json` with `results/results.json` (after `make m01`).
**Look at:** `peak_cpu_pct.k6`. Near 100% of its limit means the tester, not the server, set the numbers.

### Variation: more closed users (added 06/11/2026)
Repeat the closed run with `-e VUS=200` (the default is 10): `docker compose run --rm -e MODEL=closed -e VUS=200 -e RESULT=/lab/mine-closed200.json k6 run --quiet modules/m00-the-lab/open-vs-closed.js`,
with the 2-second freeze as before. **Predict:** does p99 now show the freeze? How many requests does the run send? Check p99.9 and max too.
`make m00-closed200` runs the 10-user, 200-user and open arms interleaved (about 15 minutes).

## 6. Watch a test live (optional dashboard, lesson 0.2)
```bash
make dash                                   # Grafana + Prometheus + cAdvisor next to the lab; pulls about 1.5 GB of images the first time
export COMPOSE_FILE=compose.yaml:compose.dash.yaml
docker compose run --rm -e MODEL=open -e RATE=400 k6 run modules/m00-the-lab/open-vs-closed.js &
```
Open **http://localhost:3000** (no login; it listens on your own machine only). The page shows six panels while k6 runs: requests per second, p99 and p50 latency,
failed %, dropped iterations (requests k6 could not send), CPU and memory of every lab container. See `dash-screenshot.png` for how it looks.
- **Measurements run with it OFF.** It adds about 0.12 of a core (Prometheus, Grafana, cAdvisor) and k6 sends its metrics to it, so the host is busier and p99 is higher
  (course machine: host 27% busy without it, 32% with it; p99 8.5 ms against 12.8 ms at 400 req/s). Use it to watch, never for numbers you write down.
- Prometheus keeps one hour of data and nothing is written outside the container; `make down` removes it all.
- Free about 1.5 GB of disk first. After you are done, `docker rmi prom/prometheus:v3.16.0 grafana/grafana:13.2.5` gets the space back.

## If something goes wrong
- `port is already allocated`: something else uses port 8080. Stop it, or `make down` an old lab first.
- `make verify` says k6 peak CPU is high: your machine is busy or small; close programs, or accept noisier numbers.
- `make dash` says port 3000 is in use: stop whatever uses it (the dashboard only listens on 127.0.0.1:3000).
- Clean up any time: `make down` (it removes the dashboard too).

## Try next
Change the freeze length in `tools/run-omission.sh` (`freeze-app.sh 32 2` → `32 5`) and predict the new open-test p99.

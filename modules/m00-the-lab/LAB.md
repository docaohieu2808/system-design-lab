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

## If something goes wrong
- `port is already allocated`: something else uses port 8080. Stop it, or `make down` an old lab first.
- `make verify` says k6 peak CPU is high: your machine is busy or small; close programs, or accept noisier numbers.
- Clean up any time: `make down`.

## Try next
Change the freeze length in `tools/run-omission.sh` (`freeze-app.sh 32 2` → `32 5`) and predict the new open-test p99.

# inkling-serve

Inkling 2 Mini on [NInfer-all](https://github.com/iamwavecut/ninfer-all), one command to a local
OpenAI-compatible API (also Anthropic Messages and OpenAI Responses). It's tuned for a single 24 GB card.

```bash
git clone https://github.com/mfranzon/rtx-6000-inference-engine.git && cd rtx-6000-inference-engine
./install.sh             # checks the GPU/driver, installs Docker + NVIDIA Container Toolkit if missing,
                         # writes .env, starts the stack and runs a smoke test
```

Or in one line (clones into `~/inkling-serve`):

```bash
curl -fsSL https://raw.githubusercontent.com/mfranzon/rtx-6000-inference-engine/main/install.sh | bash
```

`./install.sh --check` only reports what's missing. `--model-dir DIR` reuses an existing download,
`--concurrency 4` serves several clients, `--port N` changes the port, `--no-start` configures without starting.
The installer supports Ubuntu/Debian with an NVIDIA driver already installed. It won't install a driver,
because that needs a reboot. On other distributions, install Docker and the toolkit yourself and run:

```bash
cp .env.example .env     # optional
docker compose up -d --wait   # first start: downloads 16.5 GB, verifies sha256, loads (~20 s on a warm disk)
curl localhost:9000/v1/models
```

## Requirements

- Linux with an NVIDIA GPU with 24 GB: RTX 20 (Turing, sm_75), 30, 40 or 50 series, Quadro/RTX A-series of those generations.
- An NVIDIA driver that supports CUDA 13, plus the [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html).
- Docker Compose v2.20+ and about 17 GB of free disk.

## What it runs

| | |
|---|---|
| engine | `ghcr.io/iamwavecut/ninfer-all:cuda13.4`, pinned by digest |
| model | `WaveCut/Inkling-2-Mini-UD-IQ4_XS-NInfer-v3` at revision `50d6ad60`, sha256-verified: Unsloth UD-IQ4_XS weights, Q8_0 vision tower, DSpark drafter |
| API | `http://127.0.0.1:9000/v1`, model id `Inkling-2-Mini-UD-IQ4_XS-ninfer-v3` (requests must use this id) |
| default mode | 1 request at a time, DSpark speculative decoding (output identical to plain decoding), 128K context, vision on |

Two compose services: `fetch` downloads the model (resumable, pinned) and exits, then `ninfer` serves it.
`docker compose up -d --wait` returns once the healthcheck passes.

## Modes (`.env`)

| use | settings | measured on a Quadro RTX 6000 |
|---|---|---|
| one agent or chat (default) | `MAX_CONCURRENCY=1` | 80-115 tok/s decode, ~1,730 tok/s prefill |
| several clients | `MAX_CONCURRENCY=4`, `MAX_CONTEXT=32768` | ~147 tok/s aggregate, no drafting |
| text only | `VISION=--no-vision` | frees ~0.6 GB |

`MODEL_DIR` points to an existing download (`<dir>/inkling2/*.ninfer`) to skip the 16.5 GB fetch.

## Use it

Any OpenAI-compatible client: base URL `http://localhost:9000/v1`, any API key. The model always reasons
(`reasoning_content`), so give `max_tokens` room.

From another machine, tunnel the port instead of exposing it (the API has no authentication):
`ssh -N -L 9000:127.0.0.1:9000 user@gpu-host`.

## Operate

```bash
docker compose logs -f ninfer     # load progress, throughput stats
docker compose down               # stop (the model stays on disk)
docker compose pull && docker compose up -d   # after changing the pinned digest
```

ECC on workstation cards (Quadro/RTX A) costs about 10% decode bandwidth. `sudo nvidia-smi -e 0` and a reboot turn it off.

## License

Apache License 2.0 (`LICENSE`). The scripts here download the NInfer-all image and the Inkling 2 Mini
weights, which come under their own licenses (both Apache 2.0); see `NOTICE`.

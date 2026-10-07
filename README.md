# nginx-translator

🇯🇵 [日本語版 README はここをクリック](README.ja.md)

A reverse proxy built on OpenResty. It auto-detects the language of HTML text
nodes served by any upstream and translates them through a local LLM
(vLLM, OpenAI-compatible API) before returning the page — text nodes only,
everything else byte-identical.

Design/acceptance criteria: [SPEC.md](SPEC.md) · implementation plan: [PLAN.md](PLAN.md).

## Quick start

```sh
# Start (gateway :8080, demo upstream :8090)
sudo openresty -p "$(pwd)" -c nginx.conf

# Stop / reload
sudo openresty -p "$(pwd)" -c nginx.conf -s stop
sudo openresty -p "$(pwd)" -c nginx.conf -s reload

# Try it
curl -H 'Accept-Language: ja' http://127.0.0.1:8080/                 # en -> ja
curl -H 'Accept-Language: ja' http://127.0.0.1:8080/?_tcache=refresh # force re-translation
curl -X POST http://127.0.0.1:8080/_translator/cache/flush           # wipe cache

# Verification suites
bash t/verify.sh            # acceptance suite (21 checks)
resty t/tokenize_test.lua   # HTML tokenizer unit tests
resty t/detect_test.lua     # language detection unit tests
```

Requires [OpenResty](https://openresty.org/) and an OpenAI-compatible
chat-completions endpoint (the bundled demo targets vLLM at
`http://127.0.0.1:18024/v1`; change `lua/config.lua`).

## Layout

| File | Role |
|---|---|
| `nginx.conf` | gateway :8080 / demo :8090 / cache admin endpoints |
| `lua/filter.lua` | content_by_lua handler (routing, decision, wiring) |
| `lua/tokenize.lua` | HTML text-node extraction with byte-exact offset write-back |
| `lua/detect.lua` | zero-dependency language detection (10 languages) |
| `lua/translate.lua` | batched vLLM calls, shared-dict + disk-persistent cache |
| `lua/charset.lua` | latin-1 family → UTF-8 |
| `lua/config.lua` | LLM URL/model, concurrency 3, batch 1200 B, TTL 24 h, 2 MiB buffer cap, etc. |

## Behavior highlights

- Only `text/html` + status 200 is translated. `script`/`style`/`pre`/
  `textarea`/comments/attributes are left untouched. HTML entities are
  preserved verbatim (enforced via the prompt).
- Detected language equals target, detection inconclusive, LLM down,
  unsupported charset, or page over 2 MiB → the original document is returned
  as-is with status 200. A backend failure never produces a 5xx.
- `X-Translator` response header reports target/source languages and stats
  (`segs` / `cached` / `translated` / `failed` / `llm_ms`).
- Translation cache lives in a shared dict plus 60-second disk snapshots, so
  it **survives full restarts**. Use `?_tcache=refresh` to bypass+overwrite
  per request, or `/_translator/cache/flush` to wipe everything.

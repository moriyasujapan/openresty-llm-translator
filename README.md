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

## The nginx.conf

The whole gateway is this one config file (replace `/path/to/nginx-translator`
and `user` with your own; the complete working file is [nginx.conf](nginx.conf)):

```nginx
worker_processes 2;
user build;
pid nginx-translator.pid;
error_log logs/error.log warn;

events { worker_connections 256; }

http {
    include /usr/local/openresty/nginx/conf/mime.types;
    default_type application/octet-stream;
    access_log logs/access.log;

    lua_package_path "/path/to/nginx-translator/lua/?.lua;;";

    # translation cache (shared across workers; disk snapshots persist it
    # across full restarts)
    lua_shared_dict translate_cache 64m;

    init_worker_by_lua_block {
        require("filter").init_worker()
    }

    # ---- demo upstream (static); replace with your real upstream ----
    server {
        listen 127.0.0.1:8090;
        server_name demo;
        location / {
            root /path/to/nginx-translator/demo;
            default_type text/html;
        }
    }

    # ---- translator gateway ----
    server {
        listen 127.0.0.1:8080;
        server_name gateway;

        # cache admin endpoints
        location = /_translator/cache/flush {
            content_by_lua_block { require("filter").flush_cache() }
        }
        location = /_translator/cache/dump {
            content_by_lua_block { require("filter").dump_cache() }
        }

        # everything else goes through the translator
        location / {
            content_by_lua_block { require("filter").handle() }
        }

        # plain passthrough (non-GET requests, translation disabled)
        location @up {
            internal;
            proxy_pass http://127.0.0.1:8090;
            proxy_set_header Accept-Encoding "";   # translate uncompressed HTML
            proxy_set_header Host "demo-upstream";
            proxy_http_version 1.1;
            proxy_set_header Connection "";
        }

        # upstream fetch used by ngx.location.capture() inside handle()
        # (capture() cannot target a named location, hence a real internal
        # location that rewrites /__upstream/<path> -> /<path>)
        location ^~ /__upstream/ {
            internal;
            rewrite ^/__upstream(/.*) $1 break;
            proxy_pass http://127.0.0.1:8090;
            proxy_set_header Accept-Encoding "";
            proxy_set_header Host "demo-upstream";
            proxy_http_version 1.1;
            proxy_set_header Connection "";
        }
    }
}
```

Design note: translation runs in the **content phase** (`content_by_lua` +
`ngx.location.capture`), not in `body_filter_by_lua`, because the body-filter
context disables cosockets and `ngx.thread` — yielding there is impossible.

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

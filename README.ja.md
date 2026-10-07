# nginx-translator

🇬🇧 [English README here](README.md)

OpenResty製リバースプロキシ。upstreamのHTMLテキストノードを言語自動検出→
ローカルLLM(vLLM, OpenAI互換)で翻訳して返す。設計・受け入れ基準は [SPEC.md](SPEC.md)、
実装計画は [PLAN.md](PLAN.md)。

## 起動 / テスト

```sh
# 起動 (gateway :8080, demo upstream :8090)
sudo openresty -p "$(pwd)" -c nginx.conf

# 停止・リロード
sudo openresty -p "$(pwd)" -c nginx.conf -s stop
sudo openresty -p "$(pwd)" -c nginx.conf -s reload

# 動作例
curl -H 'Accept-Language: ja' http://127.0.0.1:8080/       # 英→ja
curl -H 'Accept-Language: ja' http://127.0.0.1:8080/?_tcache=refresh  # 再翻訳
curl -X POST http://127.0.0.1:8080/_translator/cache/flush  # キャッシュ全消去

# 検証スイート (21項目)
bash t/verify.sh
resty t/tokenize_test.lua   # HTML tokenizer 単体
resty t/detect_test.lua     # 言語検出 単体
```

## 構成

| ファイル | 役割 |
|---|---|
| `nginx.conf` | gateway:8080 / demo:8090 / キャッシュ管理エンドポイント |
| `lua/filter.lua` | content_by_lua ハンドル(判定・配線) |
| `lua/tokenize.lua` | HTMLテキストノード抽出・offset写し戻し |
| `lua/detect.lua` | 依存ゼロの言語検出(10言語) |
| `lua/translate.lua` | vLLMバッチ翻訳・共有辞書/ディスクキャッシュ |
| `lua/charset.lua` | latin-1系→UTF-8 |
| `lua/config.lua` | LLM URL/model、同時3、batch 1200B、TTL 24h、上限2MiB等 |

## nginx.conf

ゲートウェイはこの設定1ファイルで完結します（`/path/to/nginx-translator` と
`user` を自分の環境に置き換えてください。実物の動作ファイルは
[nginx.conf](nginx.conf)）:

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

    # 翻訳キャッシュ（ワーク-shared。ディスクスナップショットで完全再起動も耐える）
    lua_shared_dict translate_cache 64m;

    init_worker_by_lua_block {
        require("filter").init_worker()
    }

    # ---- demo upstream (静的)。実運用では実際のupstreamに置換 ----
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

        # キャッシュ管理エンドポイント
        location = /_translator/cache/flush {
            content_by_lua_block { require("filter").flush_cache() }
        }
        location = /_translator/cache/dump {
            content_by_lua_block { require("filter").dump_cache() }
        }

        # それ以外はすべて翻訳ゲートウェイへ
        location / {
            content_by_lua_block { require("filter").handle() }
        }

        # 素通し（非GET、翻訳無効時）
        location @up {
            internal;
            proxy_pass http://127.0.0.1:8090;
            proxy_set_header Accept-Encoding "";   # 非圧縮HTMLを受け取る
            proxy_set_header Host "demo-upstream";
            proxy_http_version 1.1;
            proxy_set_header Connection "";
        }

        # handle()内の ngx.location.capture() がたどるinternal location
        # （captureはnamed locationを直接指定できないため、実locationで
        #  /__upstream/<path> -> /<path> にrewriteする）
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

設計メモ: 翻訳は`body_filter_by_lua`ではなく**content phase**
（`content_by_lua` + `ngx.location.capture`）で実行します。body_filterコンテキストは
cosocketと`ngx.thread`がAPI disabledで yield 不可なためです。

## 振る舞いの要点

- `text/html` + 200 のみ翻訳。script/style/pre/textarea/comments/属性は不変。
  HTMLエンティティは原文のまま保持される（プロンプトで強制）。
- 検出言語==翻訳先、検出不能、LLM障害、charset非対応、2MiB超過 → すべて
  原文パススルー(200)。障害で5xxを返さない。
- `X-Translator` ヘッダに対象言語・統計(segs/cached/translated/failed/llm_ms)。
- 翻訳キャッシュは共有辞書+60秒スナップショットで、**完全再起動をまたいで保持**。
  `?_tcache=refresh` で個別再翻訳、`/_translator/cache/flush` で全消去。

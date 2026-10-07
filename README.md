# nginx-translator

OpenResty製リバースプロキシ。upstreamのHTMLテキストノードを言語自動検出→
ローカルLLM(vLLM, OpenAI互換)で翻訳して返す。設計・受け入れ基準は [SPEC.md](SPEC.md)、
実装計画は [PLAN.md](PLAN.md)。

## 起動 / テスト

```sh
# 起動 (gateway :8080, demo upstream :8090)
sudo openresty -p /home/build/ai/nginx-translator -c nginx.conf

# 停止・リロード
sudo openresty -p /home/build/ai/nginx-translator -c nginx.conf -s stop
sudo openresty -p /home/build/ai/nginx-translator -c nginx.conf -s reload

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

## 振る舞いの要点

- `text/html` + 200 のみ翻訳。script/style/pre/textarea/comments/属性は不変。
  HTMLエンティティは原文のまま保持される（プロンプトで強制）。
- 検出言語==翻訳先、検出不能、LLM障害、charset非対応、2MiB超過 → すべて
  原文パススルー(200)。障害で5xxを返さない。
- `X-Translator` ヘッダに対象言語・統計(segs/cached/translated/failed/llm_ms)。
- 翻訳キャッシュは共有辞書+60秒スナップショットで、**完全再起動をまたいで保持**。
  `?_tcache=refresh` で個別再翻訳、`/_translator/cache/flush` で全消去。

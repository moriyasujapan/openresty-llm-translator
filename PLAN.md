# PLAN: nginx-translator 実装計画

Plan basis: 承認済み [SPEC.md](SPEC.md)（2026-10-07 設計・spec両承認済み）
TDD Route: mode=auto, decision=light（strict権限なし）。純ロジックモジュールは
実装直後に `resty` CLI単体テストで回帰。E2Eは Task 6 の検証スイートで保証。
Compatibility Boundary: 新規プロジェクト。既存システムへの影響は :8080/:8090 リスンと
vLLM(18024)への追加リクエストのみ。vLLM側の契約変更なし。
Execution route: **inline**（タスクが逐次依存で独立並列化の利得なし／新projectで
shared coreなし → Ripple signalなし）。

## Architecture（固定済み）

OpenResty :8080 が upstream(:8090 demo / 任意upstream)をプロキシし、
`text/html` のみ全バッファ→lpegテキスト断片抽出→言語検出→vLLMバッチ翻訳→
offset写し戻し→chunked送出。失敗時原文パススルー。

## Tasks

### T0 — 環境: OpenRestyインストール
- `apt-get install -y openresty`（sudo承認プロンプト発生見込み）
- 検証: `openresty -v` / `resty -e 'print(require("lpeg").S("a"))'` が成功し、
  `curl http://127.0.0.1:18024/v1/models` が model を返すこと（確認済み）。

### T1 — Skeleton: nginx.conf + demo + config.lua
- ファイル: `nginx.conf`（:8080 gateway→:8090 静的demo、lua_shared_dict
  translate_cache 64m、`proxy_set_header Accept-Encoding ""`）、
  `config.lua`（LLM URL/model/thinking無効/同時3/batch 1200B/TTL 24h/
  buffer 2MiB/default_target="ja"/言語表）、
  `demo/index.html`(英) `demo/de.html` `demo/fr.html`（見出し・本文・list・
  script/style・title・属性・コメント・エスケープ文字を含む）
- 変更の最小性: フィルタはまだ仕込まない。プロキシのみで動作。
- 検証: `curl -s localhost:8080/ | diff - demo/index.html` が完全一致（無変換）。

### T2 — tokenize.lua + 単体テスト
- `lua/tokenize.lua`: `M.extract(html) -> { {off,len,text},... }, err`
  lpeg素走査。スキップ: script/style/textarea/code/pre/svg/noscript/template/
  コメント。タグ・属性（`<`を属性値に含む場合）・CDATA・エンティティを原文位置のまま保持。
- `t/tokenize_test.lua`: 上記ケース+マルチバイト（日本語/emoji）。
- 検証: `resty t/tokenize_test.lua` 全パス。抽出断片を原文へ写し戻すと
  元HTMLとバイト一致するroundtripテストを必須化。

### T3 — detect.lua + 単体テスト
- `lua/detect.lua`: script系=Unicode range比率、ラテン系=機能語頻度。
  対応 en ja zh ko ru de fr es it pt。信頼度低→nil（原文パススルー側へ倒す）。
- `t/detect_test.lua`: 各言語のサンプル文、短文、混在文。
- 検証: `resty t/detect_test.lua` 全パス。

### T4 — translate.lua（LLMクライアント）
- `lua/translate.lua`: `M.translate_segments(segs, target) -> translated, stats`
  バッチパック(≤1200byte/件順守)、shared dictキャッシュ（sha1(target\0src)）、
  残りを同時3の cosocket 並列POST。OpenAI互換 /v1/chat/completions、
  `chat_template_kwargs={"thinking":false}`, temp 0。応答は番号対応JSON配列、
  パース失敗は原文（nilでなく原文を返す契約）。
- 検証: 実vLLMへのスモーク `resty t/translate_live_test.lua`（"Hello world"→ja）。
  2回目でcached statsが全ヒット。vLLM URLを無生存ポートに向け原文返却を確認。

### T5 — filter.lua（オーケストレーション）+ 配線
- `lua/filter.lua`: header_filter(text/html判定・Content-Length除去・charset)、
  body_filter(バッファ/上限)、eof時パイプライン（charset変換→tokenize→detect
  →translate→写し戻し→`X-Translator`ヘッダ→chunked送出）。失敗は全工程で
  原文パススルー＋ngx.log。charset: utf-8/iso-8859-1/windows-1252のみ変換。
- nginx.confへ `header_filter_by_lua`/`body_filter_by_lua` 配線。
- 検証: T1のdiff一致が「同一言語リクエスト」では依然成立。

### T6 — 受け入れ検証スイート
- `t/verify.sh`: SPEC §7 の6項目をcurlで自動判定（構造保持はscript/style部分を
  抽出diff、キャッシュ速度差、vLLM停止→原文は一時iptables不要のconfig無効化
  フラグ `translate_enabled` で代替可）。
- 検証: 全項目PASS。`resty` 単体テスト再実行。

## Verification（総括）

- 単体: `resty t/tokenize_test.lua && resty t/detect_test.lua`
- 統合: `bash t/verify.sh`（SPEC §7 全項目）
- 目視: 翻訳後HTMLをブラウザで構造崩れなしを確認（任意）

## Risks / 将来

- flash-next-w4a16はGUI駆動中と同一vLLM → 同時3で抑制、専用モデル差し替えは
  config.luaのみ。
- 検出精度が低い短文はパススルー。属性翻訳・ストリーミングはv2候補。

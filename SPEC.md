# SPEC: nginx HTML Response 自動翻訳ゲートウェイ (OpenResty + ローカルLLM)

状態: 設計承認済み (2026-10-07) / v1スコープ
実装主体: OpenResty (nginx) + Lua。Cモジュールは対象外。

## 1. 目的

リバースプロキシとして、upstreamが返すHTMLレスポンスの**テキストノードのみ**を
言語自動検出し、ローカルLLM（OpenAI互換API）でクライアント希望言語へ翻訳して返す。

- 非ゴール(v1): 属性翻訳(alt/title/placeholder)、ストリーミング翻訳、
  JS動的DOM、URLプレフィックスによる翻訳先指定、非HTMLコンテンツの翻訳。

## 2. 固定された前提（承認済み決定）

| 決定 | 内容 |
|---|---|
| 実装形態 | OpenResty `body_filter_by_lua` + cosocket |
| 翻訳先 | `Accept-Language` 上位言語。未対応/欠落は `config.lua` の `default_target`（既定 `ja`）へフォールバック。それも検出言語と一致すればパススルー |
| LLM | vLLM `http://127.0.0.1:18024/v1/chat/completions`, model `flash-next-w4a16`, authなし。`chat_template_kwargs: {"thinking": false}` 必須（有効だとcontentが空になる） |
| 処理方式 | 完全バッファ → 断片バッチ翻訳 → 写し戻し。ゲートウェイlocationは **content_by_lua + `ngx.location.capture("@up")`** 方式（body_filter_by_lua は cosocket/ngx.thread が API disabled のため、同挙動を yield 可能なcontent phaseで実装。仕様変更: 実測に基づく機構変更） |
| HTML抽出 | 方式A: lpegによるテキストノード素走査（DOMツリー不要）。
  lpegはOpenResty非同梱のため `lua-lpeg` のlpeg.soをOpenResty lualibへ配置して使用（実測OK）。JSONは同梱cjson |
| 運用 | ゲートウェイ :8080 → 任意upstream。検証用demoサイトを同梱 |

## 3. 構成

```
nginx-translator/
├── SPEC.md
├── nginx.conf              # :8080 ゲートウェイ, :8090 demo upstream
├── lua/
│   ├── config.lua          # LLM URL/model/limit/言語表/キャッシュサイズ
│   ├── tokenize.lua        # lpeg: (offset,len,text) 断片リスト抽出
│   ├── detect.lua          # Unicode script range + 高頻度語による言語検出
│   ├── translate.lua       # バッチ化、vLLM呼び出し、JSONパース、キャッシュ
│   └── filter.lua          # header/body/log phaseをつなぐオーケストレーション
├── demo/                   # 検証用: 英語・ドイツ語・フランス語のHTMLページ
└── t/                      # 検証スクリプト (curlベース) + OpenResty resty CLI単体テスト
```

## 4. リクエストフロー (実装確定版: content_by_lua + capture)

1. **content_by_lua (handle)**: GETかつ翻訳有効時のみ `ngx.location.capture("/__upstream"..uri)`
   で上流を内部取得（internal location経由のproxy。captureはnamed location不可のため）。
   非GET/無効時は `ngx.exec("@up")` で素通し。
2. 上流応答: `Accept-Encoding ""` でgzip回避。`res.header`/`res.status`/`res.body` を取得。
3. **判定**: status==200 かつ Content-Type が text/html のみ翻訳。それ以外は
   バイト一致パススルー（X-Translatorヘッダも付けない）。HTMLで `skipped` の場合のみ
   `X-Translator: skipped; reason=...` を付与。
4. **バッファ**: 2MiB超過は原文ストリームパススルー。
5. **翻訳パイプライン**（全て yield 可能なcontent phaseで実行）:
   a. charsetが非UTF-8ならLua表でUTF-8化（v1対応: iso-8859-1 / windows-1252 のみ。
      翻訳後出力は UTF-8 とし Content-Type の charset を書き換える
      — 原文charset(ラテン1系)は日本語等を表現できないため逆変換しない）。
      それ以外のcharset（shift_jis, euc-kr, gb18030等）は
      原文パススルー＋ログ。
   b. `tokenize.lua` でテキスト断片リスト `(off, len, toff, tlen, text)` を抽出。
      スキップ要素: `script style textarea code pre svg noscript template` と
      コメント `<!-- -->`。`<title>` は通常テキストノードとして翻訳対象。
      断片は前後空白trim済みで、写し戻しは toff..toff+tlen-1 の完全置換。
   c. 全断片連結テキストで言語検出。検出言語 == 翻訳先、または断片なし/判定不能 →
      原文通過。
   d. 断片を原文順に ~1200byte/バッチにまとめ、キャッシュヒットはLLM呼出前に除外。
      残バッチを同時実行数 3 以内の ngx.thread で並列POST。
      プロンプト: 番号付きJSON文字列配列を返す（翻訳以外的一切のテキスト禁止）。
   e. 応答JSONをパースし、番号→断片へ対応付け。キャッシュへ保存
      (key = sha1(target + "\0" + source_text), shared dict `translate_cache` 64MiB,
      TTL 24h)。**ディスク永続化**: 60s間隔タイマーでdirty分を `cache/cache.jsonl`
      へ追記保存、`init_worker` 起動時に読み戻す（完全再起動をまたいで保持）。
      **Refresh**: リクエストパラメータ `_tcache=refresh` はキャッシュ読取バイパス+
      上書き更新。`/_translator/cache/flush`（GET/POST, 同一dictのflush_all+
      ディスク削除）で全消去。`/_translator/cache/dump` で手動スナップショット。
   f. 断片を後方→前方の順に原文へ写し戻し（前方オフセット不変）、翻訳HTML送出。
   g. `X-Translator: ja; src=en; segs=N; cached=M; translated=T; failed=F; llm_ms=X`
      ヘッダ付与（debug可視化）。
6. **エラー处理**: LLM失敗/タイムアウト(既定10s)/JSONパース失敗/要素数不一致 →
   該当バッチは原文のまま（全体パススルー）、レスポンスは必ず200で返す。errorログ。

## 5. 言語検出 (detect.lua)

- script判定: Han→zh / Hiragana+Katakana→ja / Hangul→ko / Cyrillic→ru /
  Arabic→ar / Thai→th の存在比率。
- ラテン文字: 高頻度機能語（the/of/and, le/de/est, der/die/und, ...）のカウント。
- 対応言語表: en ja zh ko ru de fr es it pt（翻訳先対応と同一。検出のみ追加可）。

## 6. 翻訳プロンプト契約

- system: 「あなたは翻訳エンジン。入力JSON文字列配列の各要素を{TARGET}へ翻訳し、
  入力と同一長のJSON文字列配列のみを出力。説明・コードフェンス・余白禁止」
- user: `["seg1","seg2",...]`（JSON）
- temperature 0, max_tokens = 入力文字数×2(上限4096), JSONモード指定可なら指定。
- 出力がJSON配列としてパース不能 or 長不一致 → 全文字列置換の緩い再生式を試み、
  失敗時は原文。

## 7. 検証（受け入れ基準）

1. demo英語ページを `Accept-Language: ja` で取得 → 本文テキストが日本語、
   `<script>`/`<style>`/属性/改行構造/HTML構造がバイト一致で保持。
2. `Accept-Language: en` で英語ページ → 翻訳スキップ（X-Translator: skipped; same-lang）。
3. デモの独/仏ページ → 日本語化される。
4. 同一ページ2回目 → `cached=` が全セグメント、応答が明白に高速。
   OpenRestyを完全再起動しても3と同様のキャッシュヒット（ディスク永続化）。
5. `?_tcache=refresh` 付きリクエスト → 再翻訳され（`cached=0`）、キャッシュが
   更新される。`/_translator/cache/flush` 後は次のリクエストが全面翻訳になる。
6. vLLM停止 → 原文が200で返る。
7. 非HTML（画像/JSON API）→ 無変換パススルー。
8. tokenize.lua/detect.lua は `resty` CLIで単体テスト（エスケープ文字、
   属性内`<`、コメント、CDATA、マルチバイト境界）。

## 8. 既知のリスク・将来項目

- 同一vLLMモデルが本GUI駆動中: 翻訳負荷が競合。同時実行数3で抑制、
  必要なら翻訳専用モデル追加（config.luaのmodel切替で対応可能にしておく）。
- chunked/巨大ページはバッファ上限で保護するが、体感遅延はページサイズに比例。
- 検出の誤り（短いテキスト、混在言語）は原文パススルー側に倒す。

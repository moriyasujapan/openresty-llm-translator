#!/usr/bin/env bash
# SPEC §7 受け入れ検証スイート
cd "$(dirname "$0")/.." || exit 1
GW=http://127.0.0.1:8080
pass=0; fail=0
ok()   { pass=$((pass+1)); echo "PASS $1"; }
bad()  { fail=$((fail+1)); echo "FAIL $1"; }
chk()  { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
HDR()  { grep -i '^x-translator' "$1" || true; }
hdr_has() { grep -qi "^x-translator.*$2" "$1"; }

script_range() { awk '/<script>/,/<\/script>/' "$1"; }
style_range()  { awk '/<style>/,/<\/style>/' "$1"; }

echo "== 1. 英→ja 翻訳と構造保持"
curl -s "$GW/_translator/cache/flush" >/dev/null   # 決定論のために常に空から
curl -s -D /tmp/v.h1 -o /tmp/v1.html -H 'Accept-Language: ja' "$GW/"
chk "1a X-Translator: ja; src=en and translated>0" \
    'hdr_has /tmp/v.h1 "ja; src=en" && hdr_has /tmp/v.h1 "translated=[1-9]"'
chk "1b script block byte-identical" \
    'diff <(script_range demo/index.html) <(script_range /tmp/v1.html) >/dev/null'
chk "1c style block byte-identical" \
    'diff <(style_range demo/index.html) <(style_range /tmp/v1.html) >/dev/null'
chk "1d entities preserved" 'grep -q "&amp;" /tmp/v1.html && grep -q "&lt;tags&gt;" /tmp/v1.html && grep -q "&quot;" /tmp/v1.html'
chk "1e pre block untranslated" 'grep -q "Preformatted text" /tmp/v1.html'
chk "1f comment preserved" 'grep -q "<!-- this comment should be skipped -->" /tmp/v1.html'
chk "1g body actually changed vs source" '! cmp -s /tmp/v1.html demo/index.html'
cp /tmp/v1.html /tmp/v_first.html

echo "== 2. 同一言語はスキップ"
curl -s -D /tmp/v.h2 -o /tmp/v2.html -H 'Accept-Language: en' "$GW/"
chk "2 skipped; reason=same-lang" 'hdr_has /tmp/v.h2 "skipped; reason=same-lang" && cmp -s /tmp/v2.html demo/index.html'

echo "== 3. 独/仏→ja"
curl -s -D /tmp/v.h3 -o /tmp/v3.html -H 'Accept-Language: ja' "$GW/de.html"
chk "3a de -> ja translated" 'hdr_has /tmp/v.h3 "src=de" && hdr_has /tmp/v.h3 "translated=[1-9]"'
curl -s -D /tmp/v.h4 -o /tmp/v4.html -H 'Accept-Language: ja' "$GW/fr.html"
chk "3b fr -> ja translated" 'hdr_has /tmp/v.h4 "src=fr" && hdr_has /tmp/v.h4 "translated=[1-9]"'

echo "== 4. キャッシュと再起動永続化"
t0=$(date +%s%N)
curl -s -D /tmp/v.h5 -o /tmp/v5.html -H 'Accept-Language: ja' "$GW/"
t1=$(date +%s%N)
cached_ms=$(( (t1-t0)/1000000 ))
chk "4a cached=12 (全ヒット)" 'hdr_has /tmp/v.h5 "cached=12"'
chk "4b translated body identical to first run" 'cmp -s /tmp/v5.html /tmp/v_first.html'
echo "    (cached request took ${cached_ms}ms)"
curl -s "$GW/_translator/cache/dump" >/dev/null
sudo openresty -p . -c nginx.conf -s stop; sleep 0.4
sudo openresty -p . -c nginx.conf; sleep 0.5
curl -s -D /tmp/v.h6 -o /tmp/v6.html -H 'Accept-Language: ja' "$GW/"
chk "4c after FULL restart cache still hits" 'hdr_has /tmp/v.h6 "cached=12"'
chk "4d body identical after restart" 'cmp -s /tmp/v6.html /tmp/v_first.html'

echo "== 5. refresh と flush"
curl -s -D /tmp/v.h7 -o /tmp/v7.html "$GW/?_tcache=refresh" -H 'Accept-Language: ja'
chk "5a refresh bypasses cache (cached=0, retranslated)" \
    'hdr_has /tmp/v.h7 "cached=0" && hdr_has /tmp/v.h7 "translated=[1-9]"'
curl -s "$GW/_translator/cache/flush" | grep -q '"flushed":true'
chk "5b flush endpoint responds" true
curl -s -D /tmp/v.h8 -o /dev/null -H 'Accept-Language: ja' "$GW/"
chk "5c after flush full retranslate" 'hdr_has /tmp/v.h8 "cached=0" && hdr_has /tmp/v.h8 "translated=12"'

echo "== 6. 非HTMLは無変換パススルー"
curl -s -D /tmp/v.h9 -o /tmp/v9.json "$GW/api.json"
chk "6a json byte-identical" 'cmp -s /tmp/v9.json demo/api.json'
chk "6b no X-Translator header" '! grep -qi x-translator /tmp/v.h9'

echo "== 7. LLM停止時は原文200"
cp lua/config.lua /tmp/config.lua.bak
sed -i 's|http://127.0.0.1:18024|http://127.0.0.1:19999|' lua/config.lua
sudo openresty -p . -c nginx.conf -s reload; sleep 0.4
curl -s "$GW/_translator/cache/flush" >/dev/null
curl -s -D /tmp/v.h10 -o /tmp/v10.html -H 'Accept-Language: ja' "$GW/"
chk "7a failed recorded, status 200" 'hdr_has /tmp/v.h10 "failed=[1-9]" && grep -q " 200" /tmp/v.h10'
chk "7b source text returned" 'cmp -s /tmp/v10.html demo/index.html'
cp /tmp/config.lua.bak lua/config.lua
sudo openresty -p . -c nginx.conf -s reload; sleep 0.4

echo
echo "== RESULT: PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]

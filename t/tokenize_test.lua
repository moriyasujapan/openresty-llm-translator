package.path = "/home/build/ai/nginx-translator/lua/?.lua;" .. package.path
local tok = require("tokenize")

local fail = 0
local function check(cond, name)
    if cond then print("ok   " .. name)
    else fail = fail + 1; print("FAIL " .. name) end
end

local function texts(html)
    local out = {}
    for _, s in ipairs(tok.extract(html)) do out[#out + 1] = s.text end
    return table.concat(out, "|")
end

-- 1) 基本抽出
local h1 = "<p>Hello <b>world</b>!</p>"
check(texts(h1) == "Hello|world|!", "basic text nodes")

-- 2) スキップ要素
local h2 = [[<p>a</p><script>var x="<div>";</script><style>b{}</style>
<textarea>t</textarea><code>c</code><pre>p</pre><svg><g/></svg>
<noscript>n</noscript><template>tp</template>d]]
check(texts(h2) == "a|d", "skip script/style/textarea/code/pre/svg/noscript/template")

-- 3) コメント・doctype・CDATAはスキップ、titleは翻訳対象
local h3 = [[<!DOCTYPE html><title>Ti</title><!-- c -->x<!--y-->z]]
check(texts(h3) == "Ti|x|z", "comment/doctype skipped, title kept")

-- 4) 属性内の ">" / "<" と引用符
local h4 = [[<a title="a>b<c" href='/x>y'>link</a>]]
check(texts(h4) == "link", "quoted attr with angle brackets")

-- 5) スクリプト内容の "<" (demoの実ケース)
local h5 = [[<script>if (a < b && c > d) { x }</script>after]]
check(texts(h5) == "after", "script content with < and >")

-- 6) 孤立の "<"
local h6 = [[a < b]]
check(texts(h6) == "a|<|b", "bare < treated as text")

-- 7) マルチバイト
local h7 = [[<p>日本語とemoji😀 mixed</p>]]
check(texts(h7) == "日本語とemoji😀 mixed", "utf-8 multibyte preserved")

-- 8) 空白のみのノードは除外
check(#tok.extract("<p>a</p>\n   <p>b</p>") == 2, "whitespace-only nodes dropped")

-- 9) ラウンドトリップ: 原文のままでのrebuildは完全一致
local demo = io.open("/home/build/ai/nginx-translator/demo/index.html"):read("a")
for _, html in ipairs({ h1, h2, h3, h4, h5, h6, h7, demo }) do
    local segs = tok.extract(html)
    check(tok.rebuild(html, segs) == html, "roundtrip byte-identical")
end

-- 10) rebuildで翻訳差し替えが正しい位置に入る
local segs = tok.extract(h1)
segs[1].text = "こんにちは"
check(tok.rebuild(h1, segs) == "<p>こんにちは <b>world</b>!</p>", "replace at exact offset")

print(fail == 0 and "ALL PASS" or ("FAILURES: " .. fail))
if fail > 0 then os.exit(1) end

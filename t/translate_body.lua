-- 翻訳クライアントのライブテスト本体。t/live.conf のテストサーバーから呼ばれる。
return function()
    local tr = require("translate")
    local config = require("config")

    local lines, fail = {}, 0
    local function check(cond, name)
        if cond then lines[#lines + 1] = "ok   " .. name
        else fail = fail + 1; lines[#lines + 1] = "FAIL " .. name end
    end

    local texts = { "Hello world, welcome to our site!", "First item about databases" }

    -- 1) 実vLLMで翻訳
    local out1, st1 = tr.translate_segments(texts, "ja")
    lines[#lines + 1] = ("ja => %s | %s  (translated=%s failed=%s llm_ms=%s)")
        :format(out1[1], out1[2], st1.translated, st1.failed, st1.llm_ms)
    check(st1.translated == 2 and st1.failed == 0, "live translation works")
    check(out1[1] ~= texts[1] and #out1[1] > 0, "output changed and non-empty")
    local function has_cjk(s)
        return s:match("[\227\129-\131][\128-\191]") or s:match("[\228-\233][\128-\191][\128-\191]")
    end
    check(has_cjk(out1[1]) or has_cjk(out1[2]), "output contains CJK (ja)")

    -- 2) 2回目はキャッシュヒット
    local out2, st2 = tr.translate_segments(texts, "ja")
    check(st2.cached == 2 and st2.translated == 0, "second call fully cached")

    -- 3) refresh はキャッシュ読取をバイパスして再翻訳+上書き
    local _, st3 = tr.translate_segments(texts, "ja", { refresh = true })
    check(st3.translated == 2 and st3.cached == 0, "refresh bypasses cache")

    -- 4) ディスク保存→ロード往復
    local okdump, n = tr.dump_to_disk()
    check(okdump and n >= 2, "dump_to_disk wrote " .. tostring(n) .. " entries")
    local loaded = tr.load_from_disk()
    check(loaded >= n, "load_from_disk restored " .. loaded)

    -- 5) LLM停止時: 原文フォールバック
    local saved = config.llm.base_url
    config.llm.base_url = "http://127.0.0.1:1/v1/chat/completions"
    local out5, st5 = tr.translate_segments({ "Goodbye, this must stay in English" }, "ja")
    config.llm.base_url = saved
    check(out5[1] == "Goodbye, this must stay in English", "LLM down -> source text")
    check(st5.failed == 1, "failed stat recorded")

    -- 6) 多言語: 独→英
    local out6 = tr.translate_segments({ "Dies ist eine deutsche Demoseite zur ueberpruefung" }, "en")
    lines[#lines + 1] = ("de=>en => %s"):format(out6[1])
    check(out6[1]:lower():find("german") ~= nil, "de->en translation mentions german")

    lines[#lines + 1] = (fail == 0) and "ALL PASS" or ("FAILURES: " .. fail)
    return fail == 0, table.concat(lines, "\n")
end

-- filter.lua: content_by_lua ハンドル。capture("@up") で上流全文を取得し、
-- text/html+200 のみ翻訳して返す。全障害経路は原文パススルー。
local config    = require("config")
local tokenize  = require("tokenize")
local detect    = require("detect")
local translate = require("translate")
local charset   = require("charset")

local M = {}

--------------------------------------------------------------------------
function M.init_worker()
    if ngx.worker.id() ~= 0 then return end
    local n = translate.load_from_disk()
    if n > 0 then ngx.log(ngx.NOTICE, "translation cache restored: ", n, " entries") end
    translate.start_timer()
end

--------------------------------------------------------------------------
-- Accept-Language から最高qの対応言語(無ければdefault_target)を返す
local function pick_target(header)
    if not header or header == "" then return config.default_target end
    local best, best_q
    for part in header:gmatch("[^,]+") do
        local tag = part:match("^%s*([%w%-]+)")
        if tag then
            local lang = tag:lower():match("^(%w+)%-?")
            local qv = tonumber(part:match("%q%s*=%s*([%d%.]+)")) or 1.0
            if config.supported[lang] and (not best_q or qv > best_q) then
                best, best_q = lang, qv
            end
        end
    end
    return best or config.default_target
end

local function skip_and_send(reason, res)
    if reason ~= "not-html" then
        ngx.header["X-Translator"] = "skipped; reason=" .. reason
    end
    ngx.print(res.body or "")
end

--------------------------------------------------------------------------
function M.handle()
    local method = ngx.req.get_method()
    if not config.translate_enabled or method ~= "GET" then
        return ngx.exec("@up")
    end

    local res = ngx.location.capture("/__upstream" .. ngx.var.uri, { method = ngx.HTTP_GET })
    if not res or not res.status then
        ngx.status = 502
        ngx.say("upstream request failed")
        return
    end
    ngx.status = res.status

    local hdrs = res.header or {}
    local ct = hdrs["Content-Type"] or ""
    if ct ~= "" then ngx.header.content_type = ct end
    local sc = hdrs["Set-Cookie"]
    if type(sc) == "string" then ngx.header["Set-Cookie"] = sc end

    if res.status ~= 200 or not ct:lower():find("text/html") then
        return skip_and_send("not-html", res)
    end

    local body = res.body or ""
    if #body == 0 then return ngx.print(body) end
    if #body > config.buffer_max_bytes then return skip_and_send("too-large", res) end

    local charset_name = (ct:lower():match("charset%s*=%s*\"?([%w%-]+)\"?")) or "utf-8"
    local kind = config.charsets[charset_name]
    if charset_name ~= "utf-8" and not kind then
        ngx.log(ngx.WARN, "unsupported charset: ", charset_name)
        return skip_and_send("charset-unsupported", res)
    end

    local target  = pick_target(ngx.req.get_headers()["accept-language"])
    local refresh = ngx.var.arg__tcache == "refresh"

    local ok, out, reason = pcall(function()
        local html = kind and charset.to_utf8(body, kind) or body

        local segs = tokenize.extract(html)
        if #segs == 0 then return nil, "no-text" end

        local texts, joined = {}, {}
        for i, s in ipairs(segs) do texts[i] = s.text; joined[i] = s.text end
        local src_lang = detect.detect(table.concat(joined, " "))
        if not src_lang then return nil, "lang-unknown" end
        if src_lang == target then return nil, "same-lang" end

        local translated, stats = translate.translate_segments(texts, target,
                                                               { refresh = refresh })
        for i, s in ipairs(segs) do s.text = translated[i] end
        local new_body = tokenize.rebuild(html, segs)

        ngx.header["X-Translator"] =
            ("%s; src=%s; segs=%d; cached=%d; translated=%d; failed=%d; llm_ms=%d"):format(
            target, src_lang, stats.total, stats.cached, stats.translated,
            stats.failed, stats.llm_ms)
        if kind then
            ngx.header.content_type = "text/html; charset=utf-8"
        end
        return new_body, nil
    end)

    if ok and out then
        ngx.print(out)
    else
        if ok and not out then
            return skip_and_send(reason, res)
        end
        ngx.log(ngx.ERR, "translator pipeline error: ", tostring(out))
        return skip_and_send("error", res)
    end
end

--------------------------------------------------------------------------
function M.flush_cache()
    local d = ngx.shared[config.cache.dict]
    d:flush_all()
    os.remove(translate.snapshot_path())
    ngx.header["Content-Type"] = "application/json"
    ngx.say('{"flushed":true}')
end

--------------------------------------------------------------------------
function M.dump_cache()
    local ok, n = translate.dump_to_disk()
    ngx.header["Content-Type"] = "application/json"
    if ok then
        ngx.say('{"dumped":', n, '}')
    else
        ngx.status = 500
        ngx.say('{"error":"', n or "dump failed", '"}')
    end
end

return M

-- translate.lua: vLLM(OpenAI互換)へのバッチ翻訳、shared dictキャッシュ、
-- ディスク永続化(60sスナップショット)、Refresh対応。失敗時は原文を返す(never error)。
local cjson  = require("cjson")
local config = require("config")
local sha1   = ngx.sha1_bin

local M = {}

local LANG_NAME = {
    en = "English", ja = "Japanese", zh = "Chinese", ko = "Korean",
    ru = "Russian", de = "German", fr = "French", es = "Spanish",
    it = "Italian", pt = "Portuguese",
}

local function dict()
    return ngx.shared[config.cache.dict]
end

local function cache_key(target, text)
    return sha1(target .. "\0" .. text)
end

--------------------------------------------------------------------------
-- 最小HTTP POST (cosocket, http:// のみ)
--------------------------------------------------------------------------
local function parse_url(url)
    local host, port, path = url:match("^http://([^:/]+):?(%d*)(/.*)$")
    return host, tonumber(port) or 80, path
end

local function http_post(url, body, timeout_ms)
    local host, port, path = parse_url(url)
    if not host then return nil, "bad url" end
    local sock = ngx.socket.tcp()
    sock:settimeouts(timeout_ms, timeout_ms, timeout_ms)
    local ok, err = sock:connect(host, port)
    if not ok then return nil, "connect: " .. err end
    local req = table.concat({
        "POST ", path, " HTTP/1.1\r\n",
        "Host: ", host, "\r\n",
        "Content-Type: application/json\r\n",
        "Content-Length: ", #body, "\r\n",
        "Connection: close\r\n\r\n",
        body,
    })
    ok, err = sock:send(req)
    if not ok then sock:close(); return nil, "send: " .. err end
    local data = sock:receive("*a")
    sock:close()
    if not data then return nil, "recv timeout" end

    local head, res_body = data:match("^(.-\r\n\r\n)(.*)$")
    if not head then return nil, "bad http" end
    local status = tonumber(head:match("^HTTP/%d%.%d (%d%d%d)"))
    if head:lower():find("transfer%-encoding: chunked") then
        local out, pos = {}, 1
        while true do
            local hl, hx = res_body:find("\r\n", pos, true)
            if not hl then break end
            local n = tonumber(res_body:sub(pos, hl - 1), 16)
            if not n or n == 0 then break end
            out[#out + 1] = res_body:sub(hl + 2, hl + 1 + n)
            pos = hl + 2 + n + 2
        end
        res_body = table.concat(out)
    end
    return status, res_body
end

--------------------------------------------------------------------------
-- LLM呼び出し: texts(配列) -> 翻訳配列 or nil
--------------------------------------------------------------------------
local function strip_fences(s)
    s = s:match("^%s*```[a-zA-Z]*\n?(.-)\n?```%s*$") or s
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function call_llm(texts, target)
    local joined_len = 0
    for _, t in ipairs(texts) do joined_len = joined_len + #t end

    local sys = ("You are a translation engine. Translate each element of the input "
        .. "JSON array of strings into %s. Output ONLY one JSON array of strings with "
        .. "the same length and order as the input. Preserve HTML entities such as "
        .. "&amp; &lt; &quot; exactly. No explanations, no code fences, no extra text."):format(
        LANG_NAME[target] or target)

    cjson.encode_sparse_array(true)
    local user = cjson.encode(#texts > 0 and texts or {})
    local payload = {
        model = config.llm.model,
        messages = { { role = "system", content = sys },
                     { role = "user", content = user } },
        temperature = 0,
        max_tokens = math.min(config.llm.max_tokens_per_req, math.max(64, joined_len * 2)),
        chat_template_kwargs = config.llm.chat_template_kwargs,
    }

    local status, body = http_post(config.llm.base_url, cjson.encode(payload),
                                   config.llm.timeout_ms)
    if not status then return nil, body end
    if status ~= 200 then return nil, "http " .. status end

    local resp = cjson.decode(body)
    local content = resp and resp.choices and resp.choices[1]
                    and resp.choices[1].message and resp.choices[1].message.content
    if not content or content == cjson.null then
        return nil, "content null (thinking not disabled?)"
    end
    if type(content) ~= "string" then return nil, "content not string" end

    local arr = cjson.decode(strip_fences(content))
    if type(arr) ~= "table" or #arr ~= #texts then return nil, "length mismatch" end
    for i = 1, #texts do
        if type(arr[i]) ~= "string" or arr[i] == "" then return nil, "bad element" end
    end
    return arr
end

--------------------------------------------------------------------------
-- バッチ翻訳本体
--------------------------------------------------------------------------
-- texts: 原文の配列。返り値: 翻訳済み配列(失敗要素は原文), stats
function M.translate_segments(texts, target, opts)
    opts = opts or {}
    local d = dict()
    local n = #texts
    local out = { table.unpack(texts) }
    local stats = { total = n, cached = 0, translated = 0, failed = 0, llm_ms = 0 }
    if n == 0 then return out, stats end

    -- 1) キャッシュ引き当て
    local pending = {} -- {idx, text}
    for i = 1, n do
        local hit = nil
        if not opts.refresh then
            hit = d:get(cache_key(target, texts[i]))
        end
        if hit then
            out[i] = hit
            stats.cached = stats.cached + 1
        else
            pending[#pending + 1] = i
        end
    end
    if #pending == 0 then return out, stats end

    -- 2) バッチパック (batch_bytes 上限, 1断片が超過しても1件で出す)
    local batches = {}
    local cur, cur_len = {}, 0
    for _, idx in ipairs(pending) do
        local t = texts[idx]
        if #cur > 0 and cur_len + #t > config.llm.batch_bytes then
            batches[#batches + 1] = cur
            cur, cur_len = {}, 0
        end
        cur[#cur + 1] = idx
        cur_len = cur_len + #t
    end
    if #cur > 0 then batches[#batches + 1] = cur end

    -- 3) 同時実行数を絞って並列実行 (concurrency本の実行順に分割)
    local worker_n = math.min(config.llm.concurrency, #batches)
    local failed_flag = false

    local function run_group(start)
        for b = start, #batches, worker_n do
            local idxs = batches[b]
            local src = {}
            for j, idx in ipairs(idxs) do src[j] = texts[idx] end
            local t0 = ngx.now()
            local arr, err = call_llm(src, target)
            stats.llm_ms = stats.llm_ms + (ngx.now() - t0) * 1000
            if arr then
                for j, idx in ipairs(idxs) do
                    out[idx] = arr[j]
                    stats.translated = stats.translated + 1
                    d:set(cache_key(target, texts[idx]), arr[j], config.cache.ttl_sec)
                end
            else
                failed_flag = true
                stats.failed = stats.failed + #idxs
                ngx.log(ngx.WARN, "translate batch failed: ", err or "?")
            end
        end
    end

    local threads = {}
    for w = 0, worker_n - 1 do
        threads[#threads + 1] = ngx.thread.spawn(run_group, w + 1)
    end
    for _, th in ipairs(threads) do
        local ok, err = ngx.thread.wait(th)
        if not ok then
            failed_flag = true
            ngx.log(ngx.ERR, "translate thread: ", err)
        end
    end
    stats.llm_ms = math.floor(stats.llm_ms)
    if failed_flag then stats.failed_note = "failed segments kept in source language" end
    return out, stats
end

--------------------------------------------------------------------------
-- ディスク永続化
--------------------------------------------------------------------------
function M.snapshot_path() return config.cache.disk_file end

function M.dump_to_disk()
    local d = dict()
    local keys = d:get_keys(0)
    local f = io.open(M.snapshot_path() .. ".tmp", "w")
    if not f then return false, "open failed" end
    local n = 0
    for _, k in ipairs(keys) do
        local v = d:get(k)
        if v then
            -- get_keys時点のTTLは取得できないため、ロード時にフルTTLで復元する
            f:write(cjson.encode({ k = ngx.encode_base64(k), v = v,
                                   ttl = config.cache.ttl_sec }), "\n")
            n = n + 1
        end
    end
    f:close()
    os.rename(M.snapshot_path() .. ".tmp", M.snapshot_path())
    return true, n
end

function M.load_from_disk()
    local f = io.open(M.snapshot_path(), "r")
    if not f then return 0 end
    local d = dict()
    local n = 0
    for line in f:lines() do
        local ok, rec = pcall(cjson.decode, line)
        if ok and rec and rec.k then
            local k = ngx.decode_base64(rec.k)
            if k and rec.v then
                d:set(k, rec.v, math.max(60, rec.ttl or config.cache.ttl_sec))
                n = n + 1
            end
        end
    end
    f:close()
    return n
end

function M.start_timer()
    local ok = ngx.timer.every(config.cache.dump_every_sec, function(premature)
        if premature then return end
        local ok2, n = M.dump_to_disk()
        if not ok2 then ngx.log(ngx.WARN, "cache dump failed: ", n) end
    end)
    return ok
end

return M

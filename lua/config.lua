local M = {
    llm = {
        base_url = "http://127.0.0.1:18024/v1/chat/completions",
        model    = "flash-next-w4a16",
        timeout_ms = 10000,
        concurrency = 3,
        batch_bytes = 1200,       -- 1リクエストに詰める原文の合計バイト上限
        max_tokens_per_req = 4096,
        -- vLLM実測: このモデルのthinkingは無効化しないとcontentがnull/空になる。
        -- 正解キーは enable_thinking (thinkingキーは両方入れておく)
        chat_template_kwargs = { thinking = false, enable_thinking = false },
    },

    cache = {
        dict        = "translate_cache",
        ttl_sec     = 24 * 3600,
        disk_file   = "/home/build/ai/nginx-translator/cache/cache.jsonl",
        dump_every_sec = 60,
    },

    buffer_max_bytes = 2 * 1024 * 1024,

    default_target = "ja",
    supported = { en = true, ja = true, zh = true, ko = true, ru = true,
                  de = true, fr = true, es = true, it = true, pt = true },

    -- latin-1系のみLua表でUTF-8変換して扱う。それ以外の非UTF-8charsetは原文パススルー
    charsets = { ["iso-8859-1"] = "latin1", ["windows-1252"] = "cp1252" },

    translate_enabled = true,
}

return M

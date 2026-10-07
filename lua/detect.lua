-- detect.lua: 依存ゼロの言語検出。
-- script系はUTF-8バイトパターンの出現数、ラテン系は機能語頻度。
-- 信頼できなければ nil を返す（呼び出し側は原文パススルーに倒す）。
local M = {}

local PAT = {
    kana   = "[\227\129-\131][\128-\191]",          -- U+3040-U+30FF ひらがな/カタカナ
    han    = "[\228-\233][\128-\191][\128-\191]",   -- U+4E00-U+9FFF 漢字(近似)
    hangul = "[\234-\237][\128-\191][\128-\191]",   -- U+AC00-U+D7AF(近似)
    cyril  = "[\208-\211][\128-\191]",              -- U+0400-U+04FF
    arab   = "[\216-\219][\128-\191]",              -- U+0600-U+06FF
    thai   = "\224[\184-\191][\128-\191]",          -- U+0E00-U+0E7F
}

local function count(text, pat)
    local _, n = text:gsub(pat, "")
    return n
end

local STOP = {
    en = " the and of to in is that it for you with this are was not on have has but they their from we your at as be by an ",
    de = " und der die das ist ein eine nicht mit auf fur sie ich aber auch den dem des von war zu im ",
    fr = " le la les et des est une dans que pour vous nous avec vous au est cette il ne pas plus ",
    es = " el la los las que de es y en un una por para con no se sus lo del como ",
    it = " il la che di per con una non sono questo come gli del le della ",
    pt = " o a de que e do da em um uma para com nao os as dos das se esta ",
}

function M.detect(text)
    if not text or #text < 8 then return nil end

    local kana, han = count(text, PAT.kana), count(text, PAT.han)
    local hangul = count(text, PAT.hangul)
    local cyril = count(text, PAT.cyril)
    local arab = count(text, PAT.arab)
    local thai = count(text, PAT.thai)

    if kana > 0 then return "ja" end
    if han >= 3 and han * 2 > kana + han then return "zh" end
    if hangul >= 2 then return "ko" end
    if arab >= 3 then return "ar" end
    if thai >= 3 then return "th" end
    if cyril >= 3 then return "ru" end
    if han + hangul + cyril + arab + thai > 0 then return nil end -- 判定不能

    -- ラテン系: 機能語スコア (word boundary一致で重複消費を避ける)
    local lower = text:lower()
    local best, best_n, second
    for lang, list in pairs(STOP) do
        local n = 0
        for w in list:gmatch("%a+") do
            local _, c = lower:gsub("%f[%a]" .. w .. "%f[^%a]", "\1")
            n = n + c
        end
        if not best or n > best_n then
            second = best_n; best, best_n = lang, n
        elseif n > (second or 0) then
            second = n
        end
    end
    -- 最小サンプルと優位マージンがなければ信頼できず nil
    if best and best_n >= 3 and (second == nil or best_n - second >= 1) then
        return best
    end
    return nil
end

return M

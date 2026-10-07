-- charset.lua: v1対応のラテン系charset -> UTF-8 変換のみ（逆変換はしない:
-- 翻訳先が日本語等の場合原文charsetで表現不可なため、出力は常にUTF-8）。
local M = {}

local CP1252 = {
    [0x80] = 0x20AC, [0x82] = 0x201A, [0x83] = 0x0192, [0x84] = 0x201E,
    [0x85] = 0x2026, [0x86] = 0x2020, [0x87] = 0x2021, [0x88] = 0x02C6,
    [0x89] = 0x2030, [0x8A] = 0x0160, [0x8B] = 0x2039, [0x8C] = 0x0152,
    [0x8E] = 0x017D, [0x91] = 0x2018, [0x92] = 0x2019, [0x93] = 0x201C,
    [0x94] = 0x201D, [0x95] = 0x2022, [0x96] = 0x2013, [0x97] = 0x2014,
    [0x98] = 0x02DC, [0x99] = 0x2122, [0x9A] = 0x0161, [0x9B] = 0x203A,
    [0x9C] = 0x0153, [0x9E] = 0x017E, [0x9F] = 0x0178,
}

local function utf8_of(cp)
    if cp < 0x80 then
        return string.char(cp)
    elseif cp < 0x800 then
        return string.char(0xC0 + math.floor(cp / 64), 0x80 + cp % 64)
    else
        return string.char(0xE0 + math.floor(cp / 4096),
                           0x80 + math.floor(cp / 64) % 64,
                           0x80 + cp % 64)
    end
end

local cache = {}

function M.to_utf8(data, kind)
    local out, map = {}, nil
    if kind == "cp1252" then map = CP1252 end
    for i = 1, #data do
        local b = data:byte(i)
        if b < 0x80 then
            out[i] = string.char(b)
        else
            local u = cache[b]
            if not u then
                local cp = (map and map[b]) or b
                u = utf8_of(cp)
                cache[b] = u
            end
            if map and map[b] then
                out[i] = utf8_of(map[b])
            else
                out[i] = u
            end
        end
    end
    return table.concat(out)
end

return M

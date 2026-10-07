-- tokenize.lua: HTMLから翻訳対象テキストノードだけを (offset,len,text) で抽出する素走査。
-- DOMツリーを作らない。写し戻しは toff..toff+tlen-1 の置換で完全ラウンドトリップする。
local M = {}

local SKIP = {
    script = true, style = true, textarea = true, code = true,
    pre = true, svg = true, noscript = true, template = true,
}

-- html 全体を走査し、翻訳断片リストを返す。
-- 各断片: { off, len,            -- 生のspan(デバッグ用)
--           toff, tlen,          -- trim後のtext実体(写し戻しはここを置換)
--           text }
function M.extract(html)
    local segs = {}
    local lower = html:lower()
    local i, len = 1, #html

    local function add_text(a, b)
        local span = html:sub(a, b)
        local s = span:match("^[ \t\r\n\f\v]*()")
        local e = span:match("()[ \t\r\n\f\v]*$")
        local t = span:sub(s, e - 1)
        if #t > 0 then
            segs[#segs + 1] = { off = a, len = b - a + 1, toff = a + s - 1,
                                tlen = #t, text = t }
        end
    end

    while i <= len do
        local lt = html:find("<", i, true)
        if not lt then
            add_text(i, len)
            break
        end
        if lt > i then add_text(i, lt - 1) end

        local c = html:sub(lt + 1, lt + 1)

        if c == "!" then
            if html:sub(lt + 2, lt + 3) == "--" then          -- comment
                local e = html:find("-->", lt + 4, true)
                i = e and (e + 3) or (len + 1)
            elseif lower:sub(lt + 2, lt + 8) == "[cdata[" then -- CDATA
                local e = html:find("]]>", lt + 9, true)
                i = e and (e + 3) or (len + 1)
            else                                              -- doctype等
                local e = html:find(">", lt + 1, true)
                i = e and (e + 1) or (len + 1)
            end

        elseif c == "/" then
            local e = html:find(">", lt + 1, true)
            i = e and (e + 1) or (len + 1)

        elseif c:match("%a") then
            -- タグ名
            local j = lt + 1
            while j <= len and html:sub(j, j):match("[a-zA-Z0-9%-]") do j = j + 1 end
            local name = html:sub(lt + 1, j - 1):lower()

            -- タグ終端まで (属性値内の ">" を尊重)
            local k, inq = lt + 1, nil
            while k <= len do
                local ch = html:sub(k, k)
                if inq then
                    if ch == inq then inq = nil end
                elseif ch == '"' or ch == "'" then
                    inq = ch
                elseif ch == ">" then
                    break
                end
                k = k + 1
            end
            local selfclose = (k > lt and html:sub(k - 1, k - 1) == "/")
            local after = k + 1

            if SKIP[name] and not selfclose then
                -- クローズ要素まで丸ごとスキップ
                local cl = lower:find("</" .. name, after, true)
                if cl then
                    local ce = html:find(">", cl, true)
                    i = ce and (ce + 1) or (len + 1)
                else
                    i = len + 1
                end
            else
                i = after
            end

        else
            -- "<" + 非文字 はテキスト扱い
            add_text(lt, lt)
            i = lt + 1
        end
    end
    return segs
end

-- 原文と断片(翻訳後text入り)からラウンドトリップ。断片順は原文順を仮定(末尾から置換)。
function M.rebuild(html, segs)
    local out, prev = {}, #html + 1
    for n = #segs, 1, -1 do
        local s = segs[n]
        out[#out + 1] = html:sub(s.toff + s.tlen, prev - 1)
        out[#out + 1] = s.text
        prev = s.toff
    end
    out[#out + 1] = html:sub(1, prev - 1)
    local parts = {}
    for n = #out, 1, -1 do parts[#parts + 1] = out[n] end
    return table.concat(parts)
end

return M

package.path = "/home/build/ai/nginx-translator/lua/?.lua;" .. package.path
local detect = require("detect").detect

local fail = 0
local function check(lang, want, name)
    if lang == want then print("ok   " .. name)
    else fail = fail + 1; print(("FAIL %s (got %s want %s)"):format(name, tostring(lang), tostring(want))) end
end

check(detect("This is an English demo page used to verify the translation gateway and it contains multiple paragraphs"), "en", "english")
check(detect("Dies ist eine deutsche Demoseite zur ueberpruefung und der Text enthaelt mehrere Absätze"), "de", "german")
check(detect("Ceci est une page de demonstration francaise pour verifier la passerelle de traduction et le texte contient plusieurs paragraphes"), "fr", "french")
check(detect("Esta es una pagina de demostracion en español y contiene varios parrafos para la prueba"), "es", "spanish")
check(detect("Questa è una pagina di dimostrazione e contiene diversi paragrafi per la verifica"), "it", "italian")
check(detect("Esta é uma página de demonstração e contém vários parágrafos para a verificação"), "pt", "portuguese")
check(detect("これは翻訳ゲートウェイを検証するための英語のデモページです"), "ja", "japanese")
check(detect("这是一个用于验证翻译网关的演示页面，包含多个段落"), "zh", "chinese")
check(detect("번역 게이트웨이를 확인하기 위한 데모 페이지입니다"), "ko", "korean")
check(detect("Это демонстрационная страница для проверки шлюза перевода"), "ru", "russian")
check(detect("هذه صفحة تجريبية للتحقق من بوابة الترجمة"), "ar", "arabic")
check(detect("นนี่เป็นหน้าสาธิตสำหรับตรวจสอบการแปล"), "th", "thai")

-- 短文・判定不能は nil（原文パススルー側へ倒す）
check(detect("Hi"), nil, "too short -> nil")
check(detect(""), nil, "empty -> nil")
check(detect("12345 67890 !!$$ %%^^"), nil, "no words -> nil")

print(fail == 0 and "ALL PASS" or ("FAILURES: " .. fail))
if fail > 0 then os.exit(1) end

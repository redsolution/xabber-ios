//
//  TranslationsManager.swift
//  Xabber
//
//
//
//
//  This program is free software; you can redistribute it and/or
//  modify it under the terms of the GNU General Public License as
//  published by the Free Software Foundation; either version 3 of the
//  License.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
//  General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//
//

import Foundation
import UIKit

class TranslationsManager: NSObject {
    open class var shared: TranslationsManager {
        struct TranslationsManagerSingleton {
            static let instance = TranslationsManager()
        }
        return TranslationsManagerSingleton.instance
    }
    
    override init() {
        super.init()
    }
    
    open var currentLang: String? = nil
    
    public final func prepare() {
        let currentLanguage = SettingManager.shared.getKey(for: "", scope: .languages, key: "current_language")
        if currentLanguage == "Default" {
            self.currentLang = "en"
        } else {
            self.currentLang = currentLanguage
        }
    }
    
    public func save(language: String) {
        SettingManager.shared.saveItem(for: "", scope: .languages, key: "current_language", value: language)
        prepare()
    }
    
    
    public func prepareLanCode(language: String) -> String {
        var code: String = ""
        
        switch language {
        case Languages.en.rawValue: code = "en"
        case Languages.sq.rawValue: code = "sq"
        case Languages.ar.rawValue: code = "ar"
        case Languages.hy.rawValue: code = "hy"
        case Languages.az.rawValue: code = "az"
        case Languages.be.rawValue: code = "be"
        case Languages.bs.rawValue: code = "bs"
        case Languages.bg.rawValue: code = "bg"
        case Languages.ca.rawValue: code = "ca"
        case Languages.zh.rawValue: code = "zh"
        case Languages.zh_Hans.rawValue: code = "zh-Hans"
        case Languages.hr.rawValue: code = "hr"
        case Languages.cs.rawValue: code = "cs"
        case Languages.da.rawValue: code = "da"
        case Languages.nl.rawValue: code = "nl"
        case Languages.et.rawValue: code = "et"
        case Languages.fil.rawValue: code = "fil"
        case Languages.fi.rawValue: code = "fi"
        case Languages.fr.rawValue: code = "fr"
        case Languages.ka.rawValue: code = "ka"
        case Languages.de.rawValue: code = "de"
        case Languages.el.rawValue: code = "el"
        case Languages.hi.rawValue: code = "hi"
        case Languages.he.rawValue: code = "he"
        case Languages.hu.rawValue: code = "hu"
        case Languages.is__.rawValue: code = "is"
        case Languages.ga.rawValue: code = "ga"
        case Languages.it.rawValue: code = "it"
        case Languages.id.rawValue: code = "id"
        case Languages.ja.rawValue: code = "ja"
        case Languages.ko.rawValue: code = "ko"
        case Languages.ku.rawValue: code = "ku"
        case Languages.tlh.rawValue: code = "tlh"
        case Languages.ky.rawValue: code = "ky"
        case Languages.la.rawValue: code = "la"
        case Languages.lt.rawValue: code = "lt"
        case Languages.lb.rawValue: code = "lb"
        case Languages.mk.rawValue: code = "mk"
        case Languages.ms.rawValue: code = "ms"
        case Languages.mr.rawValue: code = "mr"
        case Languages.mn.rawValue: code = "mn"
        case Languages.ne.rawValue: code = "ne"
        case Languages.nb.rawValue: code = "nb"
        case Languages.nb_NO.rawValue: code = "nb_NO"
        case Languages.oc.rawValue: code = "oc"
        case Languages.fa.rawValue: code = "fa"
        case Languages.pl.rawValue: code = "pl"
        case Languages.pt.rawValue: code = "pt"
        case Languages.pt_BR.rawValue: code = "pt_BR"
        case Languages.pa.rawValue: code = "pa"
        case Languages.ro.rawValue: code = "ro"
        case Languages.ru.rawValue: code = "ru"
        case Languages.sat.rawValue: code = "sat"
        case Languages.sco.rawValue: code = "sco"
        case Languages.sr.rawValue: code = "sr"
        case Languages.si.rawValue: code = "si"
        case Languages.sk.rawValue: code = "sk"
        case Languages.sl.rawValue: code = "sl"
        case Languages.es.rawValue: code = "es"
        case Languages.sw.rawValue: code = "sw"
        case Languages.sv.rawValue: code = "sv"
        case Languages.tg.rawValue: code = "tg"
        case Languages.ta.rawValue: code = "ta"
        case Languages.te.rawValue: code = "te"
        case Languages.tr.rawValue: code = "tr"
        case Languages.tk.rawValue: code = "tk"
        case Languages.uk.rawValue: code = "uk"
        case Languages.uz.rawValue: code = "uz"
        case Languages.vi.rawValue: code = "vi"
        case Languages.cy.rawValue: code = "cy"
        case Languages.yo.rawValue: code = "yo"
        case Languages.zu.rawValue: code = "zu"
        default: code = "en"
        }
        
        return code
    }
    
    
    enum Languages: String, CaseIterable {
        case en = "English 🇬🇧"
        case sq = "Shqip 🇦🇱"
        case ar = "عربي 🇸🇦"
        case hy = "Հայերէն 🇦🇲"
        case az = "Azərbaycan dili 🇦🇿"
        case be = "Беларуская мова 🇧🇾"
        case bs = "Bosanski 🇧🇦"
        case bg = "Български 🇧🇬"
        case ca = "Català"
        case zh = "中國人 🇨🇳"
        case zh_Hans = "简体中文 🇨🇳"
        case hr = "Hrvatski 🇭🇷"
        case cs = "Čeština 🇨🇿"
        case da = "Dansk 🇩🇰"
        case nl = "Nederlands 🇳🇱"
        case et = "Eesti keel 🇪🇪"
        case fil = "Filipino 🇵🇭"
        case fi = "Suomi 🇫🇮"
        case fr = "Français 🇫🇷"
        case ka = "ქართული ენა 🇬🇪"
        case de = "Deutsch 🇩🇪"
        case el = "ελληνικά 🇬🇷"
        case hi = "हिन्दी 🇮🇳"
        case he = "העברעאיש 🇮🇱"
        case hu = "Magyar 🇭🇺"
        case is__ = "Íslenska 🇮🇸"
        case ga = "Gaeilge 🇮🇪"
        case it = "Italiano 🇮🇹"
        case id = "Bahasa Indonesia 🇮🇩"
        case ja = "日本語 🇯🇵"
        case ko = "한국어 🇰🇷"
        case ku = "کوردی"
        case tlh = "Klingon"
        case ky = "Кыргыз тили 🇰🇬"
        case la = "Lingua Latina 🇻🇦"
        case lt = "Lietuvių kalba 🇱🇹"
        case lb = "Lëtzebuergesch 🇱🇺"
        case mk = "Македонски 🇲🇰"
        case ms = "മലയാളം 🇲🇾"
        case mr = "मराठी 🇮🇳"
        case mn = "Монгол 🇲🇳"
        case ne = "नेपाली 🇳🇵"
        case nb = "Bokmål 🇳🇴"
        case nb_NO = "Norsk 🇳🇴"
        case oc = "Occitan 🇫🇷"
        case fa = "فارسی 🇮🇷"
        case pl = "Polski 🇵🇱"
        case pt = "Português 🇵🇹"
        case pt_BR = "Português do Brasil 🇧🇷"
        case pa = "ਪੰਜਾਬੀ 🇮🇳"
        case ro = "Limba română 🇷🇴"
        case ru = "Русский язык 🇷🇺"
        case sat = "ᱥᱟᱱᱛᱟᱲᱤ 🇮🇳"
        case sco = "Scots Leid 🏴󠁧󠁢󠁳󠁣󠁴󠁿"
        case sr = "Cрпски / srpski  🇷🇸"
        case si = "සිංහල 🇱🇰"
        case sk = "Slovenčina 🇸🇰"
        case sl = "Slovenščina 🇸🇮"
        case es = "Español 🇪🇸"
        case sw = "Kiswahili 🇹🇿"
        case sv = "Svenska 🇸🇪"
        case tg = "Тоҷикӣ 🇹🇯"
        case ta = "தமிழ் 🇮🇳"
        case te = "తెలుగు 🇮🇳"
        case tr = "Türkçe 🇹🇷"
        case tk = "Türkmen dili 🇹🇲"
        case uk = "Українська мова 🇺🇦"
        case uz = "Ўзбек тили 🇺🇿"
        case vi = "Tiếng Việt 🇻🇳"
        case cy = "Cymraeg 🏴󠁧󠁢󠁷󠁬󠁳󠁿"
        case yo = "Èdè Yorùbá 🇳🇬"
        case zu = "isiZulu 🇿🇦"
    }
}

extension Notification.Name {
    static let newLanguageSelected = Notification.Name("NewLanguageSelected")
}

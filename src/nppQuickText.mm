/*
 * QuickText plugin for Notepad++ macOS
 * Ported from nppQuickText by Joao Moreno / TonyM / MVincent
 *
 * Code snippet expansion engine: type a snippet tag, press the assigned
 * shortcut (default Tab), and QuickText expands it with hotspot navigation.
 * Snippets are stored per-language in an INI-like file (~/.nextpad++/QuickText.ini).
 *
 * License: GPLv2+
 */

#include "NppPluginInterfaceMac.h"
#include "Scintilla.h"
#import <Cocoa/Cocoa.h>
#include <string>
#include <vector>
#include <map>
#include <fstream>
#include <sstream>
#include <regex>
#include <algorithm>
#include <cstdlib>
#include <cstring>

// ── Types ────────────────────────────────────────────────────────────────

typedef std::map<std::string, std::string> KeyMap;
typedef std::map<std::string, KeyMap>       IniMap;
typedef std::vector<std::string>            SnipList;

// ── Plugin constants ─────────────────────────────────────────────────────

static const char *PLUGIN_NAME = "QuickText";
static const int NB_FUNC = 7;
static FuncItem funcItem[NB_FUNC];
static NppData nppData;

static const int SZ_SNIP = 32;

// ── Config paths ─────────────────────────────────────────────────────────

static std::string snipsFilePath;
static std::string confFilePath;

// ── Snippet data ─────────────────────────────────────────────────────────

static IniMap snips;
static std::string allowedChars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890._-";

// ── Hotspot tracking ─────────────────────────────────────────────────────

struct QuickTextState {
    std::string text;
    std::vector<intptr_t> hotSpotsPos;
    std::vector<intptr_t> hotSpotsLen;
    bool editing = false;
    int cHotSpot = 0;
};

static QuickTextState cQuickText;

// ── Settings ─────────────────────────────────────────────────────────────

static bool g_bUseSciAutoC   = false;
static bool g_bInsertOnAutoC = false;
static bool g_bConvertTabs   = false;
static bool g_bCharAdded     = false;

// ── Helpers ──────────────────────────────────────────────────────────────

static NppHandle getCurScintilla()
{
    int which = -1;
    nppData._sendMessage(nppData._nppHandle, NPPM_GETCURRENTSCINTILLA, 0, (intptr_t)&which);
    return (which == 0) ? nppData._scintillaMainHandle : nppData._scintillaSecondHandle;
}

static intptr_t sci(NppHandle h, uint32_t msg, uintptr_t w = 0, intptr_t l = 0)
{
    return nppData._sendMessage(h, msg, w, l);
}

static std::string getConfigDir()
{
    // Ask the host for its plugin config directory (creates it if needed).
    // Fall back to ~/Library/Application Support/Nextpad++/plugins/Config if
    // NPPM_GETPLUGINSCONFIGDIR returns empty (it does not on shipped versions).
    char buf[1024] = {};
    nppData._sendMessage(nppData._nppHandle,
                         NPPM_GETPLUGINSCONFIGDIR,
                         (uintptr_t)sizeof(buf),
                         (intptr_t)buf);
    if (buf[0] != '\0')
        return std::string(buf);

    @autoreleasepool {
        NSString *dir = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,
                             NSUserDomainMask, YES).firstObject
                             stringByAppendingPathComponent:@"Nextpad++/plugins/Config"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
        return std::string([dir UTF8String]);
    }
}

// ── INI file parser ──────────────────────────────────────────────────────

static bool readIniFile(const std::string &filename, IniMap &data)
{
    std::ifstream f(filename);
    if (!f) return false;

    std::string line;
    std::string curSection;

    while (std::getline(f, line)) {
        // Remove trailing \r
        if (!line.empty() && line.back() == '\r')
            line.pop_back();

        // Section: [N]
        std::regex secRegex("\\[([\\d]+)\\]");
        std::smatch m;
        if (std::regex_search(line, m, secRegex)) {
            curSection = m[1].str();
            continue;
        }

        // Skip comments
        if (line.find("#LANGUAGE_NAME") == 0)
            continue;

        // Key=Value
        auto eq = line.find('=');
        if (eq != std::string::npos && !curSection.empty()) {
            std::string key = line.substr(0, eq);
            std::string val = line.substr(eq + 1);
            if (!key.empty() && !val.empty())
                data[curSection][key] = val;
        }
    }
    return true;
}

static SnipList querySnips(const IniMap &data, const std::string &section, const std::string &prefix)
{
    SnipList result;
    auto it = data.find(section);
    if (it == data.end()) return result;

    for (auto &kv : it->second) {
        if (kv.first.find(prefix) == 0)
            result.push_back(kv.first);
    }
    return result;
}

static bool snipExists(const IniMap &data, const std::string &section, const std::string &snip)
{
    auto it = data.find(section);
    if (it == data.end()) return false;
    return it->second.find(snip) != it->second.end();
}

// ── Text processing ─────────────────────────────────────────────────────

static void replaceTabs(std::string &str, int tabWidth)
{
    std::string spaces(tabWidth, ' ');
    size_t pos = 0;
    while ((pos = str.find('\t', pos)) != std::string::npos) {
        str.replace(pos, 1, spaces);
        pos += tabWidth;
    }
}

static void stripBreaks(std::string &str, NppHandle scintilla, const std::string &indent)
{
    int mode = (int)sci(scintilla, SCI_GETEOLMODE);
    const char *newline = "\n";
    switch (mode) {
        case 0: newline = "\r\n"; break;  // SC_EOL_CRLF
        case 1: newline = "\r"; break;    // SC_EOL_CR
        case 2: newline = "\n"; break;    // SC_EOL_LF
    }
    int nlLen = (int)strlen(newline);

    size_t i = 0;
    while (i < str.length()) {
        i = str.find("\\n", i);
        if (i == std::string::npos) break;

        if (i == 0 || str[i - 1] != '\\') {
            str.erase(i, 2);
            str.insert(i, newline, nlLen);
            str.insert(i + nlLen, indent);
        } else {
            str.erase(i - 1, 1); // remove escape backslash
        }
    }
}

static void clearQuickText()
{
    cQuickText.editing = false;
    cQuickText.hotSpotsPos.clear();
    cQuickText.hotSpotsLen.clear();
    cQuickText.text.clear();
    cQuickText.cHotSpot = 0;
}

static void decodeStr(const std::string &str, intptr_t start, const std::string &indent, NppHandle scintilla)
{
    cQuickText.text = str;

    bool useTabs = (bool)sci(scintilla, SCI_GETUSETABS);
    if (!useTabs && g_bConvertTabs) {
        int tabWidth = (int)sci(scintilla, SCI_GETTABWIDTH);
        replaceTabs(cQuickText.text, tabWidth);
    }
    stripBreaks(cQuickText.text, scintilla, indent);

    // Find hotspots ($)
    for (auto it = cQuickText.text.begin(); it != cQuickText.text.end(); ) {
        if (*it == '$') {
            if (it != cQuickText.text.begin() && *(it - 1) == '\\') {
                cQuickText.text.erase(it - 1);
                continue;
            }
            cQuickText.text.erase(it);
            cQuickText.hotSpotsPos.push_back(start + (intptr_t)(it - cQuickText.text.begin()));
            cQuickText.hotSpotsLen.push_back(0);
            continue;
        }
        ++it;
    }
}

static void jumpToHotspot(NppHandle scintilla)
{
    if (cQuickText.cHotSpot < (int)cQuickText.hotSpotsPos.size()) {
        intptr_t pos = cQuickText.hotSpotsPos[cQuickText.cHotSpot];
        intptr_t len = cQuickText.hotSpotsLen[cQuickText.cHotSpot];
        sci(scintilla, SCI_SETSEL, (uintptr_t)pos, (intptr_t)(pos + len));
        cQuickText.cHotSpot++;
        if (cQuickText.cHotSpot >= (int)cQuickText.hotSpotsPos.size())
            clearQuickText();
    }
}

// ── Load config ──────────────────────────────────────────────────────────

static void loadFiles()
{
    @autoreleasepool {
        std::string cfgDir = getConfigDir();
        NSString *dir = [NSString stringWithUTF8String:cfgDir.c_str()];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES
                                                  attributes:nil
                                                       error:nil];

        snipsFilePath = cfgDir + "/QuickText.ini";
        confFilePath  = cfgDir + "/QuickText.conf.json";

        // One-shot migration from the pre-fix location
        // (~/.nextpad++/QuickText.* → plugins/Config/QuickText.*).
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *oldBase = [NSHomeDirectory() stringByAppendingPathComponent:@".nextpad++"];
        auto migrate = [&](const std::string &newPath, NSString *oldName) {
            NSString *newNS = [NSString stringWithUTF8String:newPath.c_str()];
            NSString *oldNS = [oldBase stringByAppendingPathComponent:oldName];
            if (![newNS isEqualToString:oldNS] &&
                [fm fileExistsAtPath:oldNS] &&
                ![fm fileExistsAtPath:newNS]) {
                [fm moveItemAtPath:oldNS toPath:newNS error:nil];
            }
        };
        migrate(snipsFilePath, @"QuickText.ini");
        migrate(confFilePath,  @"QuickText.conf.json");

        // Create default snips file if absent
        NSString *snipsPath = [NSString stringWithUTF8String:snipsFilePath.c_str()];
        if (![[NSFileManager defaultManager] fileExistsAtPath:snipsPath]) {
            // Write a minimal default
            const char *defaultSnips =
                "[3]\n"
                "#LANGUAGE_NAME=C++\n"
                "for=for ($;$;$)\\n{\\n\\t$\\n}\\n$\n"
                "if=if ($)\\n{\\n\\t$\\n}\\n$\n"
                "while=while ($)\\n{\\n\\t$\\n}\\n$\n"
                "\n"
                "[255]\n"
                "#LANGUAGE_NAME=GLOBAL\n"
                "todo=// TODO: $\n";
            NSData *d = [NSData dataWithBytes:defaultSnips length:strlen(defaultSnips)];
            [d writeToFile:snipsPath atomically:YES];
        }

        // Load settings from JSON
        NSString *confPath = [NSString stringWithUTF8String:confFilePath.c_str()];
        if ([[NSFileManager defaultManager] fileExistsAtPath:confPath]) {
            NSData *data = [NSData dataWithContentsOfFile:confPath];
            if (data) {
                NSError *err = nil;
                NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
                if (dict && [dict isKindOfClass:[NSDictionary class]]) {
                    NSString *ac = dict[@"allowedChars"];
                    if (ac) allowedChars = [ac UTF8String];
                    NSNumber *uSci = dict[@"useSciAutoC"];
                    if (uSci) g_bUseSciAutoC = [uSci boolValue];
                    NSNumber *iAuto = dict[@"insertOnAutoC"];
                    if (iAuto) g_bInsertOnAutoC = [iAuto boolValue];
                    NSNumber *cTabs = dict[@"convertTabs"];
                    if (cTabs) g_bConvertTabs = [cTabs boolValue];
                }
            }
        }

        snips.clear();
        readIniFile(snipsFilePath, snips);
    }
}

static void saveSettings()
{
    @autoreleasepool {
        NSDictionary *dict = @{
            @"allowedChars": [NSString stringWithUTF8String:allowedChars.c_str()],
            @"useSciAutoC": @(g_bUseSciAutoC),
            @"insertOnAutoC": @(g_bInsertOnAutoC),
            @"convertTabs": @(g_bConvertTabs)
        };
        NSData *data = [NSJSONSerialization dataWithJSONObject:dict
                                                      options:NSJSONWritingPrettyPrinted
                                                        error:nil];
        if (data) {
            NSString *path = [NSString stringWithUTF8String:confFilePath.c_str()];
            [data writeToFile:path atomically:YES];
        }
    }
}

// ── Main QuickText command ───────────────────────────────────────────────

static void doQuickText()
{
    NppHandle scintilla = getCurScintilla();
    if (!scintilla) return;

    // Cannot handle multiple selections
    int sels = (int)sci(scintilla, SCI_GETSELECTIONS);
    if (sels > 1) return;

    // Set word characters
    sci(scintilla, SCI_SETWORDCHARS, 0, (intptr_t)allowedChars.c_str());

    // Get word at cursor
    intptr_t curPos = sci(scintilla, SCI_GETCURRENTPOS);
    intptr_t startPos = sci(scintilla, SCI_WORDSTARTPOSITION, (uintptr_t)curPos, 1);
    intptr_t endPos = sci(scintilla, SCI_WORDENDPOSITION, (uintptr_t)curPos, 1);
    if ((endPos - startPos) > SZ_SNIP || (endPos - startPos) <= 0) {
        sci(scintilla, SCI_SETCHARSDEFAULT);
        return;
    }

    char snip[SZ_SNIP + 1] = {0};
    // Use a manual text range
    struct {
        struct { intptr_t cpMin; intptr_t cpMax; } chrg;
        char *lpstrText;
    } tr;
    tr.chrg.cpMin = startPos;
    tr.chrg.cpMax = endPos;
    tr.lpstrText = snip;
    sci(scintilla, SCI_GETTEXTRANGEFULL, 0, (intptr_t)&tr);

    // Get language type
    int langType = 0;
    nppData._sendMessage(nppData._nppHandle, NPPM_GETCURRENTLANGTYPE, 0, (intptr_t)&langType);
    std::string sLangType = std::to_string(langType);
    std::string sGlobalType = "255";

    bool snipInLang   = snipExists(snips, sLangType, snip);
    bool snipInGlobal = snipExists(snips, sGlobalType, snip);

    // Build autocomplete list
    SnipList snipList = querySnips(snips, sLangType, snip);
    SnipList gList    = querySnips(snips, sGlobalType, snip);
    snipList.insert(snipList.end(), gList.begin(), gList.end());
    std::sort(snipList.begin(), snipList.end());

    if (!snipList.empty() && (endPos - startPos > 0) && g_bUseSciAutoC) {
        // Show autocomplete list
        std::ostringstream ss;
        for (size_t i = 0; i < snipList.size(); i++) {
            if (i > 0) ss << ' ';
            ss << snipList[i];
        }
        std::string listStr = ss.str();
        sci(scintilla, SCI_AUTOCSETSEPARATOR, (uintptr_t)' ');
        sci(scintilla, SCI_AUTOCSETIGNORECASE, 1);
        sci(scintilla, SCI_AUTOCSHOW, (uintptr_t)strlen(snip), (intptr_t)listStr.c_str());
    }

    if (g_bCharAdded) {
        sci(scintilla, SCI_SETCHARSDEFAULT);
        g_bCharAdded = false;
        return;
    }

    // Check exact match
    if (snipInLang || snipInGlobal) {
        clearQuickText();

        // Get indentation of current line
        std::string indent;
        intptr_t lineNum = sci(scintilla, SCI_LINEFROMPOSITION, (uintptr_t)startPos);
        intptr_t lineStart = sci(scintilla, SCI_POSITIONFROMLINE, (uintptr_t)lineNum);
        intptr_t lineIndent = sci(scintilla, SCI_GETLINEINDENTPOSITION, (uintptr_t)lineNum);
        if (lineIndent > lineStart) {
            size_t indLen = (size_t)(lineIndent - lineStart);
            char *indBuf = new char[indLen + 1];
            struct { struct { intptr_t cpMin; intptr_t cpMax; } chrg; char *lpstrText; } itr;
            itr.chrg.cpMin = lineStart;
            itr.chrg.cpMax = lineIndent;
            itr.lpstrText = indBuf;
            sci(scintilla, SCI_GETTEXTRANGEFULL, 0, (intptr_t)&itr);
            indBuf[indLen] = 0;
            indent = indBuf;
            delete[] indBuf;
        }

        // Get snippet text
        std::string snippetText;
        if (snipInLang)
            snippetText = snips[sLangType][snip];
        else
            snippetText = snips[sGlobalType][snip];

        // Decode: expand \n, find hotspots
        decodeStr(snippetText, startPos, indent, scintilla);

        // Replace the tag with expanded text
        sci(scintilla, SCI_SETTARGETSTART, (uintptr_t)startPos);
        sci(scintilla, SCI_SETTARGETEND, (uintptr_t)endPos);
        sci(scintilla, SCI_REPLACETARGET, (uintptr_t)cQuickText.text.length(),
            (intptr_t)cQuickText.text.c_str());

        if (!cQuickText.hotSpotsPos.empty()) {
            cQuickText.editing = true;
            cQuickText.cHotSpot = 0;
            jumpToHotspot(scintilla);
        }
    }

    sci(scintilla, SCI_SETCHARSDEFAULT);
}

// ── Menu commands ────────────────────────────────────────────────────────

static void openSnipsFile()
{
    if (!snipsFilePath.empty())
        nppData._sendMessage(nppData._nppHandle, NPPM_DOOPEN, 0, (intptr_t)snipsFilePath.c_str());
}

static void openConfigFile()
{
    @autoreleasepool {
        if (confFilePath.empty()) return;

        // Ensure config file exists
        NSString *path = [NSString stringWithUTF8String:confFilePath.c_str()];
        if (![[NSFileManager defaultManager] fileExistsAtPath:path])
            saveSettings();

        nppData._sendMessage(nppData._nppHandle, NPPM_DOOPEN, 0, (intptr_t)confFilePath.c_str());
    }
}

static void refreshConfig()
{
    @autoreleasepool {
        loadFiles();
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"QuickText";
        alert.informativeText = @"QuickText.ini and config files reloaded!";
        [alert addButtonWithTitle:@"OK"];
        [alert runModal];
    }
}

static void showSettings()
{
    @autoreleasepool {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"QuickText Settings";
        alert.informativeText = [NSString stringWithFormat:
            @"Allowed chars: %s\n"
             "Use Scintilla AutoComplete: %s\n"
             "Insert on AutoComplete: %s\n"
             "Convert tabs: %s\n\n"
             "Edit QuickText.conf.json in the plugin config folder to change settings,\n"
             "then use 'Refresh Configuration'.",
            allowedChars.c_str(),
            g_bUseSciAutoC ? "Yes" : "No",
            g_bInsertOnAutoC ? "Yes" : "No",
            g_bConvertTabs ? "Yes" : "No"];
        [alert addButtonWithTitle:@"OK"];
        [alert runModal];
    }
}

// ── Plugin exports ───────────────────────────────────────────────────────

extern "C" NPP_EXPORT void setInfo(NppData data)
{
    nppData = data;
    loadFiles();

    int idx = 0;
    auto addItem = [&](const char *name, PFUNCPLUGINCMD func) {
        strlcpy(funcItem[idx]._itemName, name, NPP_MENU_ITEM_SIZE);
        funcItem[idx]._pFunc = func;
        funcItem[idx]._init2Check = false;
        funcItem[idx]._pShKey = nullptr;
        idx++;
    };
    auto addSep = [&]() {
        funcItem[idx]._itemName[0] = '\0';
        funcItem[idx]._pFunc = nullptr;
        funcItem[idx]._init2Check = false;
        funcItem[idx]._pShKey = nullptr;
        idx++;
    };

    addItem("Replace Snip",            doQuickText);
    addSep();
    addItem("Open Snips File",         openSnipsFile);
    addItem("Open Config File",        openConfigFile);
    addItem("Refresh Configuration",   refreshConfig);
    addSep();
    addItem("Settings",                showSettings);
}

extern "C" NPP_EXPORT const char *getName()
{
    return PLUGIN_NAME;
}

extern "C" NPP_EXPORT FuncItem *getFuncsArray(int *nbF)
{
    *nbF = NB_FUNC;
    return funcItem;
}

extern "C" NPP_EXPORT void beNotified(SCNotification *notifyCode)
{
    NppHandle scintilla = getCurScintilla();
    if (!scintilla) return;

    switch (notifyCode->nmhdr.code) {
        case SCN_MODIFIED:
            if (cQuickText.editing) {
                if (notifyCode->modificationType & SC_MOD_INSERTTEXT) {
                    for (auto &pos : cQuickText.hotSpotsPos)
                        if (pos > notifyCode->position)
                            pos += notifyCode->length;

                    intptr_t currpos = sci(scintilla, SCI_GETCURRENTPOS);
                    if (!cQuickText.hotSpotsPos.empty() &&
                        currpos == cQuickText.hotSpotsPos.back())
                        clearQuickText();
                    else if (cQuickText.cHotSpot > 0 &&
                             cQuickText.cHotSpot - 1 < (int)cQuickText.hotSpotsLen.size())
                        cQuickText.hotSpotsLen[cQuickText.cHotSpot - 1] += notifyCode->length;
                }
                if (notifyCode->modificationType & SC_MOD_DELETETEXT) {
                    if (cQuickText.cHotSpot > 0 &&
                        cQuickText.cHotSpot - 1 < (int)cQuickText.hotSpotsLen.size() &&
                        cQuickText.hotSpotsLen[cQuickText.cHotSpot - 1] == 0) {
                        clearQuickText();
                        return;
                    }
                    for (auto &pos : cQuickText.hotSpotsPos)
                        if (pos > notifyCode->position)
                            pos -= notifyCode->length;
                    if (cQuickText.cHotSpot > 0 &&
                        cQuickText.cHotSpot - 1 < (int)cQuickText.hotSpotsLen.size())
                        cQuickText.hotSpotsLen[cQuickText.cHotSpot - 1] -= notifyCode->length;
                }
            }
            break;

        case SCN_UPDATEUI:
            if (cQuickText.editing) {
                intptr_t currpos = sci(scintilla, SCI_GETCURRENTPOS);
                bool inside = false;
                for (size_t i = 0; i < cQuickText.hotSpotsPos.size(); i++) {
                    if (currpos >= cQuickText.hotSpotsPos[i] &&
                        currpos <= cQuickText.hotSpotsPos[i] + cQuickText.hotSpotsLen[i]) {
                        inside = true;
                        break;
                    }
                }
                if (!inside) clearQuickText();
            }
            break;

        case SCN_CHARADDED:
            if (!cQuickText.editing && g_bUseSciAutoC) {
                g_bCharAdded = true;
                doQuickText();
            }
            break;

        case SCN_AUTOCCOMPLETED:
            if (g_bInsertOnAutoC) doQuickText();
            break;

        case NPPN_SHUTDOWN:
            saveSettings();
            break;

        default:
            break;
    }
}

extern "C" NPP_EXPORT intptr_t messageProc(uint32_t, uintptr_t, intptr_t)
{
    return 1;
}

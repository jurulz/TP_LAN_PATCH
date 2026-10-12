; =====================================================================
;  Crazy Ride (疯狂DD V1.9.0) - LAN Patcher  (AutoHotkey v2)
;  - Forces the IP used by the game (instead of the 1st IP from gethostbyname)
;  - Forces the network adapter used for multicast 234.2.2.1:8888 (join + send)
;  - Skips the network check (PingIP=127.0.0.1) -> any subnet works
;  - Enables online mode + firewall rules
;  - Original CRC32 of the DLLs is preserved (TeknoParrot compatible)
; =====================================================================
#Requires AutoHotkey v2.0
#SingleInstance Force

if !A_IsAdmin {
    try Run('*RunAs "' A_AhkPath '" /restart "' A_ScriptFullPath '"')
    ExitApp
}

; ---------- Patch definitions ----------
global MCAST := { name: "McastUDP.dll", crc: 0x2C363E25, size: 43008, fix: 0x6220
    , orig: [[0x1870, "33C9FF15D84D0000"], [0x1D41, "C744243401000000"], [0x1D51, "448D420A"]] }
global USB := { name: "UsbPluginsDll_R.dll", crc: 0xAA8790EB, size: 136704, fix: 0x17040
    , orig: [[0xC260, "40534881ECE0020000488B05203201004833C4488984"]] }
; BIND_GetIP replacement: copies the UTF-16 string stored 0x20 bytes further, returns 8
global GETIP_CODE := "488D15190000000FB702668901" "4883C1024883C2026685C075ED" "B808000000C3"

global CRCT := []
Loop 256 {
    c := A_Index - 1
    Loop 8
        c := (c & 1) ? ((c >> 1) ^ 0xEDB88320) : (c >> 1)
    CRCT.Push(c)
}
global CRCREV := Map()
for i, v in CRCT
    CRCREV[v >> 24] := i - 1

; ---------- Locate the game ----------
global GameDir := FindGame(A_ScriptDir)
if !GameDir {
    sel := DirSelect(, 0, "Select the Crazy Ride (or CrazyCab) folder")
    GameDir := sel ? FindGame(sel) : ""
    if !GameDir {
        MsgBox("CrazyTaxiGame\Plugins\McastUDP.dll not found.", "Crazy Ride LAN Patcher", 16)
        ExitApp
    }
}
global PlugDir := GameDir "\CrazyTaxiGame\Plugins"
global CfgFile := GameDir "\CrazyTaxiGame\Config\DefaultSettingData.ini"
global SysIni  := GameDir "\CrazyTaxiGame\Binaries\Win64\Setting_System.ini"
global ShipExe := GameDir "\CrazyTaxiGame\Binaries\Win64\CrazyTaxiGame-Win64-Shipping.exe"

; ---------- GUI ----------
g := Gui(, "Crazy Ride - LAN Patcher")
g.SetFont("s10", "Segoe UI")
g.AddText("w460", "Game folder:`n" GameDir)

g.AddGroupBox("xm w460 h120 Section", "Game IP address")
rbForce := g.AddRadio("xs+12 ys+24 Checked", "Force this IP (DLL patch):")
ips := SysGetIPAddresses()
cbIP := g.AddComboBox("x+8 yp-3 w150", ips)
if ips.Length
    cbIP.Text := PickLanIP(ips)
rbAuto := g.AddRadio("xs+12 y+12", "Automatic: original DLLs (1st IP of this PC)")
g.AddText("xs+12 y+6 cGray", "Detected IPs: " (ips.Length ? JoinArr(ips, ", ") : "none"))

g.AddGroupBox("xm w460 h110 Section", "Options")
chkPing := g.AddCheckbox("xs+12 ys+24 Checked", "Skip network check (PingIP=127.0.0.1) - any subnet OK")
chkOnline := g.AddCheckbox("xs+12 y+8 Checked", "Enable online mode (bEnableOnline=true)")
chkFw := g.AddCheckbox("xs+12 y+8 Checked", "Firewall rules (UDP 8888, TCP 4399, game exe)")

btnApply := g.AddButton("xm w150 Default", "Apply")
btnRestore := g.AddButton("x+5 w150", "Restore original")
btnQuit := g.AddButton("x+5 w150", "Quit")
logBox := g.AddEdit("xm w460 r12 ReadOnly -Wrap")
btnApply.OnEvent("Click", DoApply)
btnRestore.OnEvent("Click", DoRestore)
btnQuit.OnEvent("Click", (*) => ExitApp())
g.Show()
Log("State McastUDP.dll: " DllState(MCAST) " | UsbPluginsDll_R.dll: " DllState(USB))

; =====================================================================
DoApply(*) {
    logBox.Value := ""
    try {
        if rbForce.Value {
            ip := Trim(cbIP.Text)
            if !IsIPv4(ip)
                throw Error("Invalid IP address: " ip)
            if !HasLocalIP(ip)
                if MsgBox(ip " is not an IP of this PC.`nMulticast will fail until an adapter has this IP.`nContinue?", "Warning", 52) != "Yes"
                    return
            PatchDll(MCAST, ip, PatchMcast)
            PatchDll(USB, ip, PatchUsb)
        } else {
            RestoreDll(MCAST), RestoreDll(USB)
        }
        EditConfig(chkOnline.Value, chkPing.Value)
        if chkFw.Value
            Firewall()
        Log("`nDone. Repeat on the other cabinet with ITS own IP.")
    } catch as e {
        Log("ERROR: " e.Message)
        MsgBox(e.Message, "Error", 16)
    }
}

DoRestore(*) {
    logBox.Value := ""
    try {
        RestoreDll(MCAST), RestoreDll(USB)
        if FileExist(CfgFile ".bak") {
            FileCopy(CfgFile ".bak", CfgFile, 1)
            Log("DefaultSettingData.ini restored.")
        }
        IniWrite("false", SysIni, "/Script/CrazyTaxiGame.SettingData", "bEnableOnline")
        Log("bEnableOnline=false (Setting_System.ini)")
    } catch as e
        Log("ERROR: " e.Message)
}

; ---------- Patches ----------
PatchMcast(buf, ip) {
    ; join multicast : xor ecx,ecx / call htonl  ->  mov eax, <ip> / nop x3   (imr_interface)
    PutHex(buf, 0x1870, "B8"), PutIP(buf, 0x1871, ip), PutHex(buf, 0x1875, "909090")
    ; send socket: IP_MULTICAST_TTL(=1) -> IP_MULTICAST_IF(<ip>)   (multicast TTL defaults to 1)
    PutHex(buf, 0x1D41, "C7442434"), PutIP(buf, 0x1D45, ip)
    PutHex(buf, 0x1D51, "448D4209")
}

PatchUsb(buf, ip) {
    ; BIND_GetIP(wchar_t* out) -> returns the fixed IP
    Loop 64
        NumPut("UChar", 0, buf, 0xC260 + A_Index - 1)
    PutHex(buf, 0xC260, GETIP_CODE)
    StrPut(ip, buf.Ptr + 0xC260 + 0x20, 16, "UTF-16")
}

PatchDll(d, ip, fn) {
    path := PlugDir "\" d.name, bak := path ".orig"
    if !FileExist(bak) {
        if Crc32File(path) != d.crc
            throw Error(d.name " is not the original version and no .orig backup exists.")
        FileCopy(path, bak)
        Log("Backup: " d.name ".orig")
    }
    buf := FileRead(bak, "RAW")
    if buf.Size != d.size || Crc32(buf, 0, buf.Size) != d.crc
        throw Error(d.name ".orig does not match the expected V1.9.0.")
    for o in d.orig
        if GetHex(buf, o[1], StrLen(o[2]) // 2) != o[2]
            throw Error(d.name ": unexpected bytes at 0x" Format("{:X}", o[1]))
    fn(buf, ip)
    ForceCrc(buf, d.fix, d.crc)
    if Crc32(buf, 0, buf.Size) != d.crc
        throw Error(d.name ": CRC32 compensation failed.")
    f := FileOpen(path, "w")
    f.RawWrite(buf), f.Close()
    Log(d.name " patched (IP " ip ") - CRC32 preserved " Format("{:08X}", d.crc))
}

RestoreDll(d) {
    path := PlugDir "\" d.name
    if FileExist(path ".orig") {
        FileCopy(path ".orig", path, 1)
        Log(d.name " restored (original).")
    } else
        Log(d.name ": already original.")
}

DllState(d) {
    path := PlugDir "\" d.name
    if !FileExist(path)
        return "absent"
    buf := FileRead(path, "RAW")
    o := d.orig[1]
    return GetHex(buf, o[1], StrLen(o[2]) // 2) = o[2] ? "original" : "patched"
}

; ---------- Config ----------
EditConfig(online, ignorePing) {
    if !FileExist(CfgFile ".bak")
        FileCopy(CfgFile, CfgFile ".bak")
    txt := FileRead(CfgFile, "CP28591")          ; GBK file: Latin-1 keeps the bytes intact
    v := online ? "true" : "false"
    txt := RegExReplace(txt, "m)^bEnableOnline=[^\r\n]*", "bEnableOnline=" v)
    txt := RegExReplace(txt, "m)^bEnableOnline_Default=[^\r\n]*", "bEnableOnline_Default=" v)
    txt := RegExReplace(txt, "m)^PingIP=[^\r\n]*", "PingIP=" (ignorePing ? "127.0.0.1" : ""))
    f := FileOpen(CfgFile, "w", "CP28591")
    f.Write(txt), f.Close()
    for p in [SysIni, StrReplace(SysIni, ".ini", "_Backups.ini")]
        IniWrite(v, p, "/Script/CrazyTaxiGame.SettingData", "bEnableOnline")
    Log("Config: bEnableOnline=" v ", PingIP=" (ignorePing ? "127.0.0.1" : "(auto x.x.x.1)"))
}

Firewall() {
    RunWait('netsh advfirewall firewall delete rule name="CrazyRide LAN"', , "Hide")
    for exe in [ShipExe, GameDir "\CrazyTaxiGame.exe"]
        if FileExist(exe)
            RunWait('netsh advfirewall firewall add rule name="CrazyRide LAN" dir=in action=allow program="' exe '" enable=yes profile=any', , "Hide")
    RunWait('netsh advfirewall firewall add rule name="CrazyRide LAN" dir=in action=allow protocol=UDP localport=8888 profile=any', , "Hide")
    RunWait('netsh advfirewall firewall add rule name="CrazyRide LAN" dir=in action=allow protocol=TCP localport=4399 profile=any', , "Hide")
    Log("Firewall: 'CrazyRide LAN' rules added.")
}

; ---------- CRC32 ----------
Crc32(buf, off, len) => DllCall("ntdll\RtlComputeCrc32", "UInt", 0, "Ptr", buf.Ptr + off, "UInt", len, "UInt")
Crc32File(path) {
    b := FileRead(path, "RAW")
    return Crc32(b, 0, b.Size)
}
; Writes 4 bytes at 'pos' so that the buffer's CRC32 = target
ForceCrc(buf, pos, target) {
    c := Crc32(buf, 0, pos) ^ 0xFFFFFFFF            ; register state before the 4 bytes
    t := target ^ 0xFFFFFFFF
    i := buf.Size
    while (i > pos + 4) {
        i--
        j := CRCREV[t >> 24]
        t := (((t ^ CRCT[j + 1]) << 8) | (j ^ NumGet(buf, i, "UChar"))) & 0xFFFFFFFF
    }
    Loop 4 {
        j := CRCREV[t >> 24]
        t := (((t ^ CRCT[j + 1]) << 8) | j) & 0xFFFFFFFF
    }
    NumPut("UInt", t ^ c, buf, pos)
}

; ---------- Helpers ----------
FindGame(base) {
    for d in [base, base "\SysStart\Game\CrazyCab", base "\Game\CrazyCab", base "\CrazyCab", base "\.."]
        if FileExist(d "\CrazyTaxiGame\Plugins\McastUDP.dll")
            return RTrim(d, "\")
    return ""
}
PutHex(buf, off, hex) {
    Loop StrLen(hex) // 2
        NumPut("UChar", Integer("0x" SubStr(hex, 2 * A_Index - 1, 2)), buf, off + A_Index - 1)
}
GetHex(buf, off, n) {
    s := ""
    Loop n
        s .= Format("{:02X}", NumGet(buf, off + A_Index - 1, "UChar"))
    return s
}
PutIP(buf, off, ip) {
    for i, p in StrSplit(ip, ".")
        NumPut("UChar", Integer(p), buf, off + i - 1)
}
IsIPv4(ip) {
    if !RegExMatch(ip, "^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$", &m)
        return false
    Loop 4
        if Integer(m[A_Index]) > 255
            return false
    return true
}
HasLocalIP(ip) {
    for a in SysGetIPAddresses()
        if a = ip
            return true
    return false
}
PickLanIP(ips) {
    for a in ips   ; prefer a regular private LAN, skip VirtualBox (192.168.56.x)
        if RegExMatch(a, "^(192\.168\.(?!56\.)|10\.|172\.(1[6-9]|2\d|3[01])\.)")
            return a
    return ips[1]
}
JoinArr(a, sep) {
    s := ""
    for v in a
        s .= (A_Index > 1 ? sep : "") v
    return s
}
Log(msg) {
    logBox.Value .= msg "`r`n"
}

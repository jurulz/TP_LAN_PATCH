#Requires AutoHotkey v2.0
#SingleInstance Force
; =============================================================================
;  K.O. Drive / M-DriveR (SBXA, Sega RingWide) - LAN link patcher for TeknoParrot
;  v1.0
;
;  One "Apply" button:
;    1. patches the game exe (all required patches, original CRC32 preserved
;       so TeknoParrot still accepts it)
;    2. writes the TeknoParrot EEPROM (%appdata%\TeknoParrot\SBXA_e2prom.bin):
;       number of cabinets + this PC's link ID (group and region are kept)
;
;  Supported exe (5,307,904 bytes):
;    9B1CC57C  original 1920x1080 (the one TeknoParrot accepts)
;    0C2B0515  1024x600 variant
;
;  Patches (always applied together):
;    A  VA 0x488222 / file 0x87622  no EEPROM wipe when the region byte is 0xFF
;         (TestMode writes 0xFF there, the game then reset every setting)
;         8B 56 0C 0F B6 4A 10 ... 0F 95 C2 8B CA -> 8B 56 0C 88 42 10 90 ... 90 90 90 8B CA
;    B  VA 0x488236 / file 0x87636  no EEPROM wipe when keychip game ID / region "changed"
;         83 F8 01 74 29 83 F8 02 74 24 -> 83 F8 01 90 90 83 F8 02 90 90
;    C  VA 0x4C9D12 / file 0xC9112  skip the DHCP check (Error 8002 Network setting error)
;         75 0D -> 90 90
;    D  VA 0x59E8A0 / 0x59E850 (file 0x19DCA0 / 0x19DC50)  amNetwork must not
;         reconfigure the network card:  83 EC 20 -> 33 C0 C3  and  83 EC 1C -> 33 C0 C3
;    E  VA 0x59E690 / file 0x19DA90  cabinet IPs (instead of hardcoded 192.168.99.x)
;         85 F6 / B8 <IP_ID1> / 74 06 / 8D 86 <IP_ID2-1> / 90 x5
;         -> ID1 and ID2 free, ID3..ID6 follow ID2 (+1, +2...)
;    CRC: 4 compensation bytes in unused int3 padding (file 0x174AD8) so the
;         file CRC32 stays identical to the original.
;
;  Notes:
;    - the IP settings in teknoparrot.ini are NOT used by this game: each PC
;      must have its cabinet IP on its own network card.
;    - DongleRegion must be the same on every cabinet, otherwise Error 1006
;      (the game compares the keychip region of all cabinets during link-up).
;
;  EEPROM: "SBXA" record, 0x40 bytes, CRC32 of [4:0x40] stored at [0:4], copies at 0x00/0x40/0x80
;    0x10: region (0 Japan, 1 USA, 2 Export, 3 China) - 0x30: low = ID-1, high = cabinets-1
;    0x31: low = group
; =============================================================================

if !A_IsAdmin {
    try {
        Run('*RunAs "' A_AhkPath '" /restart "' A_ScriptFullPath '"')
        ExitApp
    }
}

global EXE_SIZE  := 5307904
global KNOWN_CRC := Map(0x9B1CC57C, "original 1920x1080", 0x0C2B0515, "1024x600 variant")
global PATCHES   := [
    {off: 0x87622, orig: "8B 56 0C 0F B6 4A 10 33 D2 3B C1 8B 44 24 14 0F 95 C2 8B CA", new: "8B 56 0C 88 42 10 90 33 D2 3B C1 8B 44 24 14 90 90 90 8B CA"},
    {off: 0x87636, orig: "83 F8 01 74 29 83 F8 02 74 24", new: "83 F8 01 90 90 83 F8 02 90 90"},
    {off: 0xC910E, orig: "39 44 24 04 75 0D C7 86", new: "39 44 24 04 90 90 C7 86"},
    {off: 0x19DCA0, orig: "83 EC 20 33 C0 56 50 89", new: "33 C0 C3 33 C0 56 50 89"},
    {off: 0x19DC50, orig: "83 EC 1C 33 C0 50 89 44", new: "33 C0 C3 33 C0 50 89 44"}
]
global IP_OFF    := 0x19DA90
global IP_ORIG   := "8D 54 40 FA 8B 41 44 8D 04 50 8D 0C 40 8D 14 4E 8D 44 3A 01"
global IP_OLDV2  := "8B 04 B5 20 84 8C 00 90 90 90 90 90 90 90 90 90 90 90 90 90"
global COMP_OFF  := 0x174AD8
global TBL_OFF   := 0x4C7220          ; leftovers from an early beta (cleaned up)
global VSZ_OFF   := 0x260
global VSZ_ORIG  := 0x8C418
global MASK_OFF  := 0x496280
global MASK_LEN  := 16
global MASKS     := ["255.255.255.0", "255.255.0.0", "255.0.0.0"]
global SLOTS     := [0x00, 0x40, 0x80]
global REGIONS   := ["Japan", "USA", "Export", "China"]
global IFACES    := []

; =================================================================== GUI ======
g := Gui("", "K.O. Drive (SBXA) - LAN patcher")
g.SetFont("s9", "Segoe UI")

g.SetFont("s9 bold")
g.Add("Text", "xm", "1. Game exe launched by TeknoParrot")
g.SetFont("s9 norm")
edExe := g.Add("Edit", "xm y+4 w470 ReadOnly")
g.Add("Button", "x+6 yp-1 w90", "Browse...").OnEvent("Click", BrowseExe)
txtExe := g.Add("Text", "xm y+6 w570 h32", "No exe selected.")

g.SetFont("s9 bold")
g.Add("Text", "xm y+8", "2. Cabinets")
g.SetFont("s9 norm")
g.Add("Text", "xm y+6", "Network cards on this PC:")
ddIface := g.Add("DropDownList", "xm y+4 w470")
g.Add("Button", "x+6 yp-1 w90", "Refresh").OnEvent("Click", (*) => FillIfaces())
g.Add("Text", "xm y+10", "Number of cabinets")
ddNb := g.Add("DropDownList", "x+6 yp-3 w45 Choose1", ["2", "3", "4", "5", "6"])
ddNb.OnEvent("Change", (*) => UpdateRows())
g.Add("Text", "x+14 yp+3", "This PC is cabinet ID")
ddThisId := g.Add("DropDownList", "x+6 yp-3 w45 Choose1", ["1", "2", "3", "4", "5", "6"])
g.Add("Text", "x+14 yp+3", "Mask")
ddMask := g.Add("DropDownList", "x+6 yp-3 w115 Choose1", MASKS)
g.Add("Button", "xm y+8 w180", "Suggest IPs").OnEvent("Click", ProposeIps)
g.Add("Button", "x+8 w180", "Check IPs (ping)").OnEvent("Click", PingCheck)

edIp := [], txtIp := [], lblIp := []
Loop 6 {
    lblIp.Push(g.Add("Text", "xm y+" (A_Index = 1 ? 10 : 5) " w120", "Cabinet ID " A_Index (A_Index = 1 ? " (master):" : ":")))
    edIp.Push(g.Add("Edit", "x+4 yp-3 w130"))
    edIp[A_Index].OnEvent("Change", (*) => LocalMark())
    txtIp.Push(g.Add("Text", "x+8 yp+3 w300", ""))
}
txtNet := g.Add("Text", "xm y+6 w570 h30 cGray", "ID 1 and ID 2: any IP - ID 3 to 6: follow ID 2. Use the same IP list on every cabinet, only 'This PC is cabinet ID' changes.")

g.SetFont("s9 bold")
g.Add("Text", "xm y+8", "3. TeknoParrot EEPROM")
g.SetFont("s9 norm")
edEep := g.Add("Edit", "xm y+4 w470 ReadOnly")
g.Add("Button", "x+6 yp-1 w90", "Browse...").OnEvent("Click", BrowseEep)
txtEep := g.Add("Text", "xm y+6 w570 h32", "")

btnApply := g.Add("Button", "xm y+10 w200 h30 Default", "Apply (exe + EEPROM)")
btnApply.OnEvent("Click", Apply)
g.Add("Button", "x+8 w180 h30", "Restore original exe").OnEvent("Click", RestoreExe)
g.Add("Button", "x+8 w90 h30", "Quit").OnEvent("Click", (*) => ExitApp())

g.OnEvent("DropFiles", OnDrop)
g.OnEvent("Close", (*) => ExitApp())
g.Show()

UpdateRows()
FillIfaces()
if FileExist(A_AppData "\TeknoParrot\SBXA_e2prom.bin")
    LoadEep(A_AppData "\TeknoParrot\SBXA_e2prom.bin")
else
    txtEep.Value := "No EEPROM in %appdata%\TeknoParrot yet: run the game once from TeknoParrot."
for a in A_Args
    if FileExist(a)
        OnDrop(g, 0, [a])

; ================================================================ events =====
OnDrop(gui, ctrl, files, *) {
    for p in files {
        SplitPath(p, , , &ext)
        if (ext = "bin")
            LoadEep(p)
        else
            LoadExe(p)
    }
}

BrowseExe(*) {
    p := FileSelect(1, , "Exe launched by TeknoParrot (M-DriveR_RingWide.exe)", "Executable (*.exe; *.bak)")
    if (p != "")
        LoadExe(p)
}

BrowseEep(*) {
    p := FileSelect(1, A_AppData "\TeknoParrot", "Select SBXA_e2prom.bin", "EEPROM (*.bin)")
    if (p != "")
        LoadEep(p)
}

UpdateRows() {
    nb := ddNb.Value + 1
    Loop 6 {
        on := (A_Index <= nb)
        edIp[A_Index].Enabled := on
        lblIp[A_Index].Enabled := on
        if !on {
            edIp[A_Index].Value := ""
            txtIp[A_Index].Value := ""
        }
    }
    if (ddThisId.Value > nb)
        ddThisId.Value := nb
    LocalMark()
}

; ------------------------------------------------------------------- EXE ------
LoadExe(path) {
    edExe.Value := path
    RefreshExe(true)
}

ExeState(buf) {
    st := {patches: "", ip: "", ip1: 0, ip2: 0}
    nNew := 0, nOrig := 0
    for p in PATCHES {
        if BufEq(buf, p.off, HexToBytes(p.new))
            nNew++
        else if BufEq(buf, p.off, HexToBytes(p.orig))
            nOrig++
    }
    st.patches := (nNew = PATCHES.Length) ? "all" : (nOrig = PATCHES.Length) ? "none" : (nNew + nOrig = PATCHES.Length) ? "partial" : "unknown"

    if BufEq(buf, IP_OFF, HexToBytes(IP_ORIG))
        st.ip := "orig"
    else if BufEq(buf, IP_OFF, HexToBytes(IP_OLDV2))
        st.ip := "old"
    else if (BufEq(buf, IP_OFF, [0x8D, 0x86]) && AllNops(buf, IP_OFF + 6, 14)) {
        st.ip := "new"
        st.ip1 := NumGet(buf, IP_OFF + 2, "UInt")
        st.ip2 := st.ip1 + 1
    } else if (BufEq(buf, IP_OFF, [0x85, 0xF6, 0xB8]) && BufEq(buf, IP_OFF + 7, [0x74, 0x06, 0x8D, 0x86]) && AllNops(buf, IP_OFF + 15, 5)) {
        st.ip := "new"
        st.ip1 := NumGet(buf, IP_OFF + 3, "UInt")
        st.ip2 := (NumGet(buf, IP_OFF + 11, "UInt") + 1) & 0xFFFFFFFF
    } else
        st.ip := "unknown"
    return st
}

RefreshExe(loadFields := false) {
    path := edExe.Value
    if (path = "" || !FileExist(path)) {
        txtExe.Value := "No exe selected."
        return
    }
    if (FileGetSize(path) != EXE_SIZE) {
        txtExe.Value := "Unexpected size (" FileGetSize(path) " bytes): this is not the supported K.O. Drive exe."
        return
    }
    try buf := FileRead(path, "RAW")
    catch {
        txtExe.Value := "Cannot read the file (is the game running?)."
        return
    }
    st := ExeState(buf)
    crc := Crc32(buf.Ptr, buf.Size)
    if (st.patches = "all" && st.ip = "new")
        state := "PATCHED"
    else if (st.patches = "none" && st.ip = "orig")
        state := "original (not patched yet)"
    else if (st.patches = "unknown" || st.ip = "unknown")
        state := "unknown bytes (unsupported version?)"
    else
        state := "partially patched (Apply will complete it)"
    if KNOWN_CRC.Has(crc)
        crcTxt := Format("{:08X}", crc) " = " KNOWN_CRC[crc] " (accepted by TeknoParrot)"
    else
        crcTxt := Format("{:08X}", crc) " unknown (Apply will fix it)"
    t := "State: " state "`nCRC32: " crcTxt
    if (st.ip = "new")
        t .= "    |    IPs: ID1 " IpToStr(st.ip1) ", ID2 " IpToStr(st.ip2)
    txtExe.Value := t

    if (loadFields && st.ip = "new") {
        mask := StrGet(buf.Ptr + MASK_OFF, -MASK_LEN, "CP0")
        for i, m in MASKS
            if (m = mask)
                ddMask.Value := i
        nb := ddNb.Value + 1
        Loop nb
            edIp[A_Index].Value := IpToStr(A_Index = 1 ? st.ip1 : st.ip2 + A_Index - 2)
        LocalMark()
    }
    RegionInfo()
}

Apply(*) {
    path := edExe.Value
    if (path = "" || !FileExist(path))
        return Err("Select the exe launched by TeknoParrot first.")
    if (FileGetSize(path) != EXE_SIZE)
        return Err("Unsupported exe (wrong size). Nothing was changed.")
    eep := edEep.Value
    if (eep = "" || !FileExist(eep))
        return Err("EEPROM not found. Run the game once from TeknoParrot, then try again.")
    try eb := FileRead(eep, "RAW")
    catch
        return Err("Cannot read the EEPROM.")
    if (eb.Size < 0xC0 || BaseSlot(eb) < 0)
        return Err("EEPROM has no valid record. Run the game once from TeknoParrot, then try again.")

    nb := ddNb.Value + 1
    thisId := ddThisId.Value
    ipPair := GetIps(nb)
    if !IsObject(ipPair)
        return
    myIp := (thisId = 1) ? ipPair[1] : ipPair[2] + thisId - 2
    if !IsLocalIp(myIp) {
        r := MsgBox("The IP of cabinet ID " thisId " (" IpToStr(myIp) ") is not set on any network card of this PC.`nThe link will not work until this PC has that IP.`n`nContinue anyway?", "LAN patcher", "YesNo Icon!")
        if (r != "Yes")
            return
    }

    try buf := FileRead(path, "RAW")
    catch
        return Err("Cannot read the exe (is the game running?).")
    target := TargetCrc(buf, path)
    if !target
        return Err("Unknown CRC32 and no original .bak. Restore the original exe and try again.")
    st := ExeState(buf)
    if (st.patches = "unknown" || st.ip = "unknown")
        return Err("Unexpected bytes in the exe (unsupported version?). Nothing was changed.")

    ; --- exe: every patch
    NumPut("UInt", VSZ_ORIG, buf, VSZ_OFF)
    Loop 6
        NumPut("UInt", 0, buf, TBL_OFF + (A_Index - 1) * 4)
    for p in PATCHES
        BufWriteHex(buf, p.off, p.new)
    BufWriteHex(buf, IP_OFF, "85 F6 B8 00 00 00 00 74 06 8D 86 00 00 00 00 90 90 90 90 90")
    NumPut("UInt", ipPair[1], buf, IP_OFF + 3)
    NumPut("UInt", (ipPair[2] - 1) & 0xFFFFFFFF, buf, IP_OFF + 11)
    BufWriteCStr(buf, MASK_OFF, MASK_LEN, MASKS[ddMask.Value])
    if !ForgeCrc(buf, COMP_OFF, target)
        return Err("CRC compensation failed. Nothing was changed.")

    if !FileExist(path ".bak")
        try FileCopy(path, path ".bak")
    e := WriteFile(path, buf)
    if (e != "")
        return Err("Cannot write the exe: " e "`n(Is TeknoParrot or the game still open?)")

    ; --- EEPROM
    e := WriteEep(eep, nb, thisId)
    RefreshExe()
    LoadEep(eep)
    if (e != "")
        return Err("The exe is patched, but the EEPROM could not be written:`n" e)

    msg := "Exe patched (CRC32 " Format("{:08X}", target) " preserved)."
    msg .= "`nEEPROM: " nb " cabinets, this PC = ID " thisId (thisId = 1 ? " (master)" : "") "."
    msg .= "`n`nCabinet IPs (mask " MASKS[ddMask.Value] "):"
    Loop nb
        msg .= "`n  ID " A_Index " -> " IpToStr(A_Index = 1 ? ipPair[1] : ipPair[2] + A_Index - 2) (A_Index = thisId ? "   <- this PC" : "")
    msg .= "`n`nOn the other cabinets: same exe, same IPs, only the ID changes."
    msg .= "`nThe TeknoParrot region must be identical everywhere (otherwise Error 1006)."
    MsgBox(msg, "LAN patcher", "Iconi")
}

RestoreExe(*) {
    path := edExe.Value
    if (path = "" || !FileExist(path))
        return Err("Select the exe first.")
    if (MsgBox("Remove every patch from the exe?", "LAN patcher", "YesNo Icon?") != "Yes")
        return
    try buf := FileRead(path, "RAW")
    catch
        return Err("Cannot read the exe (is the game running?).")
    target := TargetCrc(buf, path)
    st := ExeState(buf)
    if (!target || st.patches = "unknown" || st.ip = "unknown") {
        if FileExist(path ".bak") {
            try FileCopy(path ".bak", path, 1)
            catch
                return Err("Could not restore from the .bak file.")
            RefreshExe()
            MsgBox("Exe restored from the .bak file.", "LAN patcher", "Iconi")
            return
        }
        return Err("Cannot rebuild the original and no .bak file found.")
    }
    NumPut("UInt", VSZ_ORIG, buf, VSZ_OFF)
    Loop 6
        NumPut("UInt", 0, buf, TBL_OFF + (A_Index - 1) * 4)
    for p in PATCHES
        BufWriteHex(buf, p.off, p.orig)
    BufWriteHex(buf, IP_OFF, IP_ORIG)
    BufWriteCStr(buf, MASK_OFF, MASK_LEN, "255.255.255.0")
    if !ForgeCrc(buf, COMP_OFF, target)
        return Err("CRC compensation failed.")
    e := WriteFile(path, buf)
    if (e != "")
        return Err("Cannot write the exe: " e)
    RefreshExe()
    MsgBox("Exe restored to original (CRC32 " Format("{:08X}", target) ").", "LAN patcher", "Iconi")
}

; CRC to preserve: the file's own CRC if known, otherwise the .bak's
TargetCrc(buf, path) {
    c := Crc32(buf.Ptr, buf.Size)
    if KNOWN_CRC.Has(c)
        return c
    if (FileExist(path ".bak") && FileGetSize(path ".bak") = EXE_SIZE) {
        bb := FileRead(path ".bak", "RAW")
        c := Crc32(bb.Ptr, bb.Size)
        if KNOWN_CRC.Has(c)
            return c
    }
    return 0
}

; shows the region seen by the game and DongleRegion from teknoparrot.ini
RegionInfo() {
    t := ""
    eep := edEep.Value
    if (eep != "" && FileExist(eep)) {
        b := FileRead(eep, "RAW")
        if (b.Size >= 0xC0 && RecValid(b, 0x80)) {
            r := NumGet(b, 0x90, "UChar")
            t .= "Region seen by the game: " (r <= 3 ? REGIONS[r + 1] : "unknown")
        }
    }
    if (edExe.Value != "") {
        SplitPath(edExe.Value, , &dir)
        if FileExist(dir "\teknoparrot.ini") {
            dr := IniRead(dir "\teknoparrot.ini", "General", "DongleRegion", "?")
            t .= (t = "" ? "" : "    |    ") "DongleRegion (teknoparrot.ini): " dr
        }
    }
    if (t != "")
        txtNet.Value := t "`nThe region must be identical on every cabinet (otherwise Error 1006)."
}

; ---------------------------------------------------------------- EEPROM ------
LoadEep(path) {
    edEep.Value := path
    try buf := FileRead(path, "RAW")
    catch {
        txtEep.Value := "Cannot read the EEPROM."
        return
    }
    if (buf.Size < 0xC0) {
        txtEep.Value := "File too small."
        return
    }
    b := BaseSlot(buf)
    if (b < 0) {
        txtEep.Value := "No valid SBXA record: run the game once from TeknoParrot."
        return
    }
    b30 := NumGet(buf, b + 0x30, "UChar")
    cabs := (b30 >> 4) + 1, id := (b30 & 15) + 1
    grp := NumGet(buf, b + 0x31, "UChar") & 15
    t := "Current: " (cabs = 1 ? "1 cabinet (no link)" : cabs " cabinets, this PC = ID " id) ", group " Chr(65 + grp)
    ok := 0
    for o in SLOTS
        ok += RecValid(buf, o) ? 1 : 0
    t .= "    |    valid copies: " ok "/3"
    txtEep.Value := t "`nApply will write the number of cabinets and the ID selected above."
    if (cabs >= 2 && cabs <= 6) {
        ddNb.Value := cabs - 1
        UpdateRows()
        ddThisId.Value := Min(id, cabs)
        LocalMark()
    }
    RegionInfo()
}

WriteEep(path, cabs, id) {
    if (id > cabs)
        return "ID (" id ") is higher than the number of cabinets (" cabs ")."
    buf := FileRead(path, "RAW")
    b := BaseSlot(buf)
    if (b < 0)
        return "No valid SBXA record."
    rec := Buffer(0x40)
    DllCall("RtlMoveMemory", "Ptr", rec.Ptr, "Ptr", buf.Ptr + b, "UPtr", 0x40)
    region := NumGet(rec, 0x10, "UChar")
    if (RecValid(buf, 0x80) && NumGet(buf, 0x90, "UChar") <= 3)
        region := NumGet(buf, 0x90, "UChar")
    NumPut("UChar", region, rec, 0x10)
    NumPut("UChar", ((cabs - 1) << 4) | (id - 1), rec, 0x30)
    NumPut("UInt", Crc32(rec.Ptr + 4, 0x3C), rec, 0)
    for o in SLOTS
        DllCall("RtlMoveMemory", "Ptr", buf.Ptr + o, "Ptr", rec.Ptr, "UPtr", 0x40)
    if !FileExist(path ".bak")
        try FileCopy(path, path ".bak")
    return WriteFile(path, buf)
}

; --------------------------------------------------------------- network ------
FillIfaces() {
    global IFACES
    IFACES := DetectIfaces()
    items := []
    for it in IFACES
        items.Push(it.ip " / " (it.mask = "" ? "?" : it.mask) "  -  " it.desc (it.dhcp ? "  (DHCP)" : "  (static)"))
    ddIface.Delete()
    if (items.Length = 0) {
        ddIface.Add(["No IPv4 network card found"])
        ddIface.Value := 1
        return
    }
    ddIface.Add(items)
    ddIface.Value := 1
    LocalMark()
}

DetectIfaces() {
    list := []
    try {
        wmi := ComObjGet("winmgmts:\\.\root\cimv2")
        q := "SELECT Description, IPAddress, IPSubnet, DHCPEnabled FROM Win32_NetworkAdapterConfiguration WHERE IPEnabled = True"
        for nic in wmi.ExecQuery(q) {
            ips := nic.IPAddress, masks := nic.IPSubnet
            if !(ips is ComObjArray)
                continue
            Loop ips.MaxIndex() + 1 {
                ip := ips[A_Index - 1]
                if (InStr(ip, ":") || SubStr(ip, 1, 4) = "127." || SubStr(ip, 1, 8) = "169.254.")
                    continue
                m := ""
                if ((masks is ComObjArray) && masks.MaxIndex() >= A_Index - 1)
                    m := masks[A_Index - 1]
                list.Push({ip: ip, mask: m, desc: nic.Description, dhcp: nic.DHCPEnabled ? true : false})
            }
        }
    }
    if (list.Length = 0)
        for ip in SysGetIPAddresses()
            if (SubStr(ip, 1, 8) != "169.254.")
                list.Push({ip: ip, mask: "", desc: "network card", dhcp: false})
    return list
}

IsLocalIp(v) {
    for it in IFACES
        if (IpToInt(it.ip) = v)
            return true
    return false
}

; consecutive IPs around the selected network card
ProposeIps(*) {
    if (IFACES.Length = 0 || ddIface.Value > IFACES.Length)
        return Err("No network card selected.")
    it := IFACES[ddIface.Value]
    thisId := ddThisId.Value, nb := ddNb.Value + 1
    mi := 1
    for i, m in MASKS
        if (m = it.mask)
            mi := i
    ddMask.Value := mi
    maskVal := IpToInt(MASKS[mi])
    base := IpToInt(it.ip)
    net := base & maskVal
    bcast := net | (~maskVal & 0xFFFFFFFF)
    first := base - (thisId - 1)
    if (first <= net || first + nb - 1 >= bcast)
        return Err("Cannot fit " nb " consecutive IPs around " it.ip ".")
    Loop nb
        edIp[A_Index].Value := IpToStr(first + A_Index - 1)
    LocalMark()
}

; marks this PC's IP and picks 'This PC is cabinet ID' automatically
LocalMark() {
    nb := ddNb.Value + 1
    found := 0
    Loop nb {
        v := IpToInt(Trim(edIp[A_Index].Value))
        mine := (v > 0 && IsLocalIp(v))
        if (mine && !found)
            found := A_Index
        txtIp[A_Index].Opt(mine ? "cGreen" : "cDefault")
        txtIp[A_Index].Value := mine ? "= this PC" : ""
    }
    if found
        ddThisId.Value := found
}

PingCheck(*) {
    LocalMark()
    nb := ddNb.Value + 1
    Loop nb {
        s := Trim(edIp[A_Index].Value)
        if (s = "" || txtIp[A_Index].Value = "= this PC")
            continue
        if (IpToInt(s) <= 0) {
            txtIp[A_Index].Value := "invalid IP"
            continue
        }
        txtIp[A_Index].Value := "ping..."
        if PingOk(s) {
            txtIp[A_Index].Opt("cMaroon")
            txtIp[A_Index].Value := "replies: OK if it is the other cabinet, otherwise a conflict"
        } else {
            txtIp[A_Index].Opt("cGray")
            txtIp[A_Index].Value := "no reply (free, powered off or firewall)"
        }
    }
}

PingOk(ip) {
    try {
        wmi := ComObjGet("winmgmts:\\.\root\cimv2")
        for r in wmi.ExecQuery("SELECT StatusCode FROM Win32_PingStatus WHERE Address='" ip "' AND Timeout=600")
            return (r.StatusCode = 0)
    }
    return false
}

; validates the nb IPs, returns [IP_ID1, IP_ID2] or 0
GetIps(nb) {
    maskVal := IpToInt(MASKS[ddMask.Value])
    ips := []
    Loop nb {
        v := IpToInt(Trim(edIp[A_Index].Value))
        if (v <= 0)
            return Err("Missing or invalid IP for cabinet ID " A_Index ".")
        ips.Push(v)
    }
    if (ips[1] = ips[2])
        return Err("ID 1 and ID 2 have the same IP.")
    for i, v in ips {
        if (i >= 3 && v != ips[2] + i - 2)
            return Err("From ID 3 on, IPs follow ID 2: ID " i " must be " IpToStr(ips[2] + i - 2) ".")
        if (i >= 3 && v = ips[1])
            return Err("The IP of ID " i " is the same as ID 1.")
        if ((v & maskVal) != (ips[1] & maskVal))
            return Err("Cabinet ID " i " (" IpToStr(v) ") is not in the same subnet as ID 1.")
        h := v & ~maskVal & 0xFFFFFFFF
        if (h = 0 || h = (~maskVal & 0xFFFFFFFF))
            return Err(IpToStr(v) " is a network or broadcast address.")
    }
    return [ips[1], ips[2]]
}

; ================================================================ helpers ====
Err(msg) {
    MsgBox(msg, "LAN patcher", "Icon!")
    return 0
}

WriteFile(path, buf) {
    try {
        f := FileOpen(path, "w")
        f.RawWrite(buf, buf.Size)
        f.Close()
    } catch as ex {
        return ex.Message
    }
    return ""
}

; CRC32: finds the 4 bytes at `pos` that give the whole buffer the CRC `target`
; (CRC is affine in those 32 bits: 33 CRCs + Gaussian elimination over GF(2))
ForgeCrc(buf, pos, target) {
    f0 := CompCrc(buf, pos, 0)
    basis := Map()
    Loop 32 {
        tag := 1 << (A_Index - 1)
        v := CompCrc(buf, pos, tag) ^ f0
        bit := 31
        while (bit >= 0) {
            if ((v >> bit) & 1) {
                if basis.Has(bit) {
                    v ^= basis[bit][1]
                    tag ^= basis[bit][2]
                } else {
                    basis[bit] := [v, tag]
                    break
                }
            }
            bit--
        }
    }
    r := target ^ f0, x := 0
    bit := 31
    while (bit >= 0) {
        if ((r >> bit) & 1) {
            if !basis.Has(bit)
                return false
            r ^= basis[bit][1]
            x ^= basis[bit][2]
        }
        bit--
    }
    return CompCrc(buf, pos, x) = target
}

CompCrc(buf, pos, c) {
    NumPut("UInt", c, buf, pos)
    return Crc32(buf.Ptr, buf.Size)
}

Crc32(ptr, len) => DllCall("ntdll\RtlComputeCrc32", "UInt", 0, "Ptr", ptr, "UInt", len, "UInt")

RecValid(buf, o) {
    if (NumGet(buf, o + 4, "UInt") != 0x53425841)      ; "AXBS"
        return false
    return NumGet(buf, o, "UInt") = Crc32(buf.Ptr + o + 4, 0x3C)
}

BaseSlot(buf) {
    for o in SLOTS
        if RecValid(buf, o)
            return o
    return -1
}

BufEq(buf, off, arr) {
    for i, v in arr
        if (NumGet(buf, off + i - 1, "UChar") != v)
            return false
    return true
}

AllNops(buf, off, n) {
    Loop n
        if (NumGet(buf, off + A_Index - 1, "UChar") != 0x90)
            return false
    return true
}

BufWriteHex(buf, off, hex) {
    for i, v in HexToBytes(hex)
        NumPut("UChar", v, buf, off + i - 1)
}

BufWriteCStr(buf, off, n, s) {
    Loop n
        NumPut("UChar", 0, buf, off + A_Index - 1)
    StrPut(s, buf.Ptr + off, n, "CP0")
}

HexToBytes(hex) {
    arr := []
    for tok in StrSplit(Trim(hex), " ")
        if (tok != "")
            arr.Push(Integer("0x" tok))
    return arr
}

IpToInt(s) {
    if !RegExMatch(Trim(s), "^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$", &m)
        return -1
    v := 0
    Loop 4 {
        n := Integer(m[A_Index])
        if (n > 255)
            return -1
        v := (v << 8) | n
    }
    return v
}

IpToStr(v) => ((v >> 24) & 255) "." ((v >> 16) & 255) "." ((v >> 8) & 255) "." (v & 255)

#Requires AutoHotkey v2.0
#SingleInstance Force
#Include OCR.ahk
;@Ahk2Exe-Base "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe"

; ==========================================
; Once Human 全自動釣魚腳本 (AHK v2.0)
; ==========================================

; ------------------------------------------
; 可配置參數 (全域設定)
; ------------------------------------------
global GameTitle := "ahk_exe ONCE_HUMAN.exe" ; 遊戲進程視窗名稱
global BaseWidth := 1534                     ; 基準解析度寬度 (提供螢幕截圖的解析度)
global BaseHeight := 862                     ; 基準解析度高度 (提供螢幕截圖的解析度)
global SearchTolerance := 80                 ; 圖片搜尋容差值 (0-255)，80 適合已去背、有邊緣抗鋸齒的圖片

; 圖片特徵路徑 (使用使用者在 stateImages/cropped/ 下的自訂去背圖)
global ImageDir := A_ScriptDir . "\stateImages\cropped"
global State3Img := ImageDir . "\state3_indicator.png" ; 下竿等待魚咬鉤 (去背綠色掛鉤圖示)
global State8Img := ImageDir . "\state8_indicator.png" ; 釣上與收魚 (F鍵提示去背圖)

; 狀態機變數
global CurrentState := 1       ; 目前狀態 (1-8)
global StateTime := 0          ; 進入目前狀態的時間戳記 (用於超時檢測)
global IsPaused := true        ; 預設為暫停狀態，需按下 F8 啟動
global OcrThrottle := 0        ; 限流偵測變數，降低 CPU 佔用
global IsFilterFish := false   ; 是否開啟篩選魚種功能 (F11切換)，預設關閉
global IsFishFilterPassed := false ; 是否已通過魚種過濾篩選
global FilterOcrCount := 0     ; 魚種過濾 OCR 掃描次數
global FilterOcrLog := ""      ; 魚種過濾即時 OCR 日誌內容

; 時間控制法拉魚相關變數 (取代舊的像素張力檢測)
global IsNewReelSession := true ; 是否為全新的拉魚會話 (從等待狀態首次進入狀態5)
global State5Phase := "initial"  ; 狀態5的子階段 ("initial": 2秒長按, "cyclic": 循環點擊)
global State5PhaseStart := 0     ; 狀態5子階段的開始時間戳記 (A_TickCount)
global CyclicClickState := "down" ; 循環點擊的當前狀態 ("down": 按下0.3秒, "up": 釋放1.0秒)

; 啟動初始化
StateTime := A_TickCount
SetTimer(StateMachine, 30)   ; 每 30ms 運行一次狀態機 (提高掃描頻率，反應更靈敏)
SetTimer(UpdateStatus, 100)  ; 每 100ms 更新一次 ToolTip 狀態顯示

; ------------------------------------------
; 控制熱鍵定義
; ------------------------------------------

; F8：啟動 / 恢復自動釣魚
F8:: {
    global IsPaused, CurrentState, StateTime, OcrThrottle, IsNewReelSession
    if (IsPaused) {
        IsPaused := false
        StateTime := A_TickCount
        OcrThrottle := 0
        IsNewReelSession := true
        ToolTip("已恢復自動釣魚", 10, 10)
    } else {
        IsPaused := false
        CurrentState := 1
        StateTime := A_TickCount
        OcrThrottle := 0
        IsNewReelSession := true
        ToolTip("已重新啟動自動釣魚", 10, 10)
    }
}

; F9：暫停自動釣魚
F9:: {
    global IsPaused
    IsPaused := true
    ReleaseAllKeys()
    ToolTip("已暫停自動釣魚", 10, 10)
}

; F11：切換是否挑選魚種 (開關)
F11:: {
    global IsFilterFish
    IsFilterFish := !IsFilterFish
    if (IsFilterFish) {
        ToolTip("篩選魚種已開啟`n(此功能目前為實驗性功能，受畫面背景與文字渲染影響較大)", 10, 10)
    } else {
        ToolTip("篩選魚種已關閉", 10, 10)
    }
    SetTimer(() => ToolTip(), -3000) ; 3秒後自動關閉 ToolTip 提示
}

; F12：強制終止並結束腳本
F12:: {
    ReleaseAllKeys()
    ToolTip("腳本終止中...", 10, 10)
    Sleep(1000)
    ExitApp()
}

; ------------------------------------------
; 狀態機核心邏輯
; ------------------------------------------
StateMachine() {
    global CurrentState, StateTime, IsPaused, GameTitle, State3Img, OcrThrottle, IsFilterFish, IsFishFilterPassed, FilterOcrCount, FilterOcrLog
    
    ; 若處於暫停狀態，不執行動作
    if (IsPaused) {
        return
    }
    
    ; 檢查遊戲視窗是否存在，若不存在則直接返回
    if (!WinExist(GameTitle)) {
        return
    }
    ; 安全防護：若切換到其他視窗（遊戲視窗未處於活動狀態），則自動釋放按鍵並暫停腳本，避免干擾其他程式
    if (!WinActive(GameTitle)) {
        IsPaused := true
        ReleaseAllKeys()
        ToolTip("遊戲視窗未處於活動狀態，自動暫停自動釣魚 (按 F8 重新啟動)", 10, 10)
        return
    }
    
    ; 防呆機制 (Timeout)：若單一狀態持續超過 60 秒未改變，視為異常
    if (A_TickCount - StateTime > 60000) {
        ResetToState1("狀態 [" . CurrentState . "] 停留超過 60 秒（異常超時）")
        return
    }
    
    switch CurrentState {
        case 1: ; 狀態 01：釣竿就緒 (預設狀態)
            ReleaseAllKeys()
            
            ; 偵測是否沒有任何釣魚 UI，確認已經回到就緒畫面
            if (!DetectAnyFishingUI()) {
                ; 稍微延遲 1.5 秒，確保角色完全收回釣竿並穩定
                Sleep(1500)
                if (!DetectAnyFishingUI()) {
                    SetState(2) ; 進入拋竿狀態
                }
            }
            
        case 2: ; 狀態 02：拋竿
            ; 依使用者偏好，不強制控制游標中心點，直接執行長按左鍵 1 秒拋竿
            Click("Down")
            Sleep(1000)
            Click("Up")
            
            OcrThrottle := 0
            SetState(3) ; 進入等待狀態
            
        case 3: ; 狀態 03：等待魚咬鉤
            ; 使用 Windows Media OCR 偵測視窗上半部是否出現咬鉤文字
            OcrThrottle++
            if (OcrThrottle >= 4) { ; 每 4 次循環 (約 120ms) 偵測一次 OCR，降低 CPU 負荷
                OcrThrottle := 0
                ocrText := DetectTextOCR()
                
                ; 在螢幕上即時顯示 OCR 偵測到的文字，以利除錯與校準
                if (ocrText != "") {
                    ToolTip("OCR 偵測文字 (除錯): " . ocrText, 10, 150, 2)
                } else {
                    ToolTip("OCR 偵測文字 (除錯): (無)", 10, 150, 2)
                }
                
                ; 1. 額外偵測是否異常卡在狀態 8 收魚展示畫面 (畫面上出現 "重量" 或 "尺寸" 字樣)
                isStuckState8 := (InStr(ocrText, "重") && InStr(ocrText, "量"))
                              || (InStr(ocrText, "尺") && InStr(ocrText, "寸"))
                if (isStuckState8) {
                    ToolTip("", , , 2) ; 清除除錯 ToolTip
                    SetState(8)
                    return
                }
                
                ; 2. 統計辨識到的目標字元數量 (解決字元間有空格及個別字元辨識誤差的問題)
                ; 目標字句："請在5秒內收線" (共 7 個字)
                matchCount := 0
                if (InStr(ocrText, "請"))
                    matchCount++
                if (InStr(ocrText, "在"))
                    matchCount++
                if (InStr(ocrText, "5"))
                    matchCount++
                if (InStr(ocrText, "秒"))
                    matchCount++
                if (InStr(ocrText, "內") || InStr(ocrText, "内"))
                    matchCount++
                if (InStr(ocrText, "收"))
                    matchCount++
                if (InStr(ocrText, "線") || InStr(ocrText, "线"))
                    matchCount++
                
                ; 只要 7 個目標字元中成功匹配 5 個 or 以上，即判定為魚咬鉤
                if (matchCount >= 5) {
                    ToolTip("", , , 2) ; 清除除錯 ToolTip
                    Sleep(100)
                    SetState(4)
                    return
                }
            }
            
        case 4: ; 狀態 04：咬鉤收線
            ; 必須在 5 秒內收線，點擊滑鼠左鍵一次
            Click()
            Sleep(250) ; 延遲 250ms 確保點擊指令確實傳入遊戲
            SetState(5) ; 進入拉魚微調狀態
            
        case 5: ; 狀態 05：拉魚 (張力控制 - 時間控制法)
            ; 此狀態為拉魚主迴圈，需動態監測收魚與 QTE 提示
            
            ; 1. 偵測收魚與 QTE 提示 (OCR 偵測 - 限流以降低 CPU 使用率)
            OcrThrottle++
            if (OcrThrottle >= 4) { ; 每 4 次循環 (約 120ms) 偵測一次 OCR
                OcrThrottle := 0
                
                ; A. 優先偵測是否已經耗盡體力可以收魚，或已成功捕獲並進入收魚結算畫面 (狀態 08)
                ; 掃描範圍為整個視窗長寬縮 1/5 區域。比對關鍵字包括："收起"、"放生"、"F+收" 或魚的重量/尺寸資訊 ("重量"、"尺寸")
                ocrTextCenter := DetectTextOCRCenter()
                isState8 := (InStr(ocrTextCenter, "收") && InStr(ocrTextCenter, "起"))
                         || (InStr(ocrTextCenter, "放") && InStr(ocrTextCenter, "生"))
                         || (InStr(ocrTextCenter, "F") && InStr(ocrTextCenter, "收"))
                         || (InStr(ocrTextCenter, "重") && InStr(ocrTextCenter, "量"))
                         || (InStr(ocrTextCenter, "尺") && InStr(ocrTextCenter, "寸"))
                if (isState8) {
                    SetState(8)
                    return
                }
                
                ; B. 進行智慧魚種過濾篩選 (非阻塞，最大 15 次偵測，約 1.8 秒)
                if (IsFilterFish && !IsFishFilterPassed) {
                    ; 使用全視窗 OCR 掃描獲取魚種名稱，徹底相容任何 UI 位移與 DPI 縮放
                    ocrTextFish := DetectTextOCRFull()
                    
                    ; 高容許度 OCR 判定：因為目標魚名只會在釣上時才出現，故僅需匹配其中任意一個核心特徵字元即可確定 (水母排除"水"字以防與淡水魚等重合)
                    isJihan := InStr(ocrTextFish, "極") || InStr(ocrTextFish, "极") || InStr(ocrTextFish, "寒") || InStr(ocrTextFish, "母")
                    isDianman := InStr(ocrTextFish, "電") || InStr(ocrTextFish, "电") || InStr(ocrTextFish, "鰻") || InStr(ocrTextFish, "鳗")
                    
                    ; 更新背景日誌以利主狀態面板進行即時渲染
                    FilterOcrLog := "次數: " . FilterOcrCount . "/15 | 讀取: " . (ocrTextFish == "" ? "(無)" : StrReplace(ocrTextFish, "`n", " "))
                    
                    if (isJihan || isDianman) {
                        IsFishFilterPassed := true
                        matchedFishName := isJihan ? "極寒水母" : "電鰻"
                        FilterOcrLog := "匹配成功 [" . matchedFishName . "]"
                        ToolTip("【目標魚】檢測到 " . matchedFishName . "！繼續拉魚...", 10, 200, 3)
                        SetTimer(() => ToolTip(, , , 3), -2000)
                    } else {
                        FilterOcrCount++
                        if (FilterOcrCount >= 15) {
                            ; 超過 15 次仍未匹配，判定為雜魚，釋放按鍵並按 ESC 斷線
                            ReleaseAllKeys()
                            ToolTip("【非目標魚】偵測未匹配，按下 ESC 放棄拉線...", 10, 200, 3)
                            SetTimer(() => ToolTip(, , , 3), -3000)
                            Send("{Esc}")
                            Sleep(3000) ; 此時拉魚已結束，安全不影響張力
                            SetState(1)
                            return
                        }
                    }
                }
                
                ; C. 偵測是否未成功拋竿或已提早收竿 (狀態 01)
                ; 掃描範圍為視窗上半部中段，比對關鍵字為 "長按拋竿"
                ocrTextUpper := DetectTextOCR()
                matchCount1 := 0
                if (InStr(ocrTextUpper, "長"))
                    matchCount1++
                if (InStr(ocrTextUpper, "按"))
                    matchCount1++
                if (InStr(ocrTextUpper, "拋") || InStr(ocrTextUpper, "抛"))
                    matchCount1++
                if (InStr(ocrTextUpper, "竿"))
                    matchCount1++
                
                if (matchCount1 >= 3) {
                    SetState(1)
                    return
                }
                
                ; C. 偵測向左/向右拉扯 QTE 提示
                ocrTextBottom := DetectTextOCRBottom()
                
                ; 偵測 向右拉 (D) - 必須同時辨識到 "向"、"右"、"拉" 三個字
                if (InStr(ocrTextBottom, "向") && InStr(ocrTextBottom, "右") && InStr(ocrTextBottom, "拉")) {
                    SetState(6)
                    return
                }
                
                ; 偵測 向左拉 (A) - 必須同時辨識到 "向"、"左"、"拉" 三個字
                if (InStr(ocrTextBottom, "向") && InStr(ocrTextBottom, "左") && InStr(ocrTextBottom, "拉")) {
                    SetState(7)
                    return
                }
            }
            
            ; 2. 執行時間控制法 Reeling 點擊邏輯 (非阻塞)
            RunTimeBasedClicking()
            
        case 6: ; 狀態 06：向右拉扯 QTE (長按 D)
            ; QTE 期間，不執行狀態 05 的左鍵微調，因此須確保左鍵鬆開
            if (GetKeyState("LButton")) {
                Click("Up")
            }
            
            ; 長按鍵盤 D 鍵
            if (!GetKeyState("D")) {
                Send("{D down}")
            }
            
            ; 結束條件：進入狀態 6 後滿 2 秒 (2000ms)，直接切回狀態 5，且不鬆開 D 鍵
            if (A_TickCount - StateTime >= 2000) {
                SetState(5)
            }
            
        case 7: ; 狀態 07：向左拉扯 QTE (長按 A)
            ; QTE 期間，不執行狀態 05 的左鍵微調，因此須確保左鍵鬆開
            if (GetKeyState("LButton")) {
                Click("Up")
            }
            
            ; 長按鍵盤 A 鍵
            if (!GetKeyState("A")) {
                Send("{A down}")
            }
            
            ; 結束條件：進入狀態 7 後滿 2 秒 (2000ms)，直接切回狀態 5，且不鬆開 A 鍵
            if (A_TickCount - StateTime >= 2000) {
                SetState(5)
            }
            
        case 8: ; 狀態 08：釣上與收魚
            ; 停止所有按鍵長按狀態，包含 A 和 D
            ReleaseAllKeys()
            
            ; 等待 6 秒動畫時間
            Sleep(6000)
            
            ; 進入收魚確認迴圈，最多嘗試 6 次 (約 9 秒)，確保 F 鍵被伺服器接收且畫面文字消失
            retryCount := 0
            Loop {
                ; 按下 F 鍵收魚
                Send("{F}")
                
                ; 等待 1.5 秒讓遊戲響應並加載收魚動畫/清除介面
                Sleep(1500)
                
                ; 使用 OCR 偵測視窗中央是否仍有 "F 收 起 G 放 生" 的相關字樣
                ocrTextCenter := DetectTextOCRCenter()
                stillOnScreen := (InStr(ocrTextCenter, "收") && InStr(ocrTextCenter, "起"))
                              || (InStr(ocrTextCenter, "放") && InStr(ocrTextCenter, "生"))
                              || (InStr(ocrTextCenter, "F") && InStr(ocrTextCenter, "收"))
                
                ; 如果文字消失，代表收魚成功，跳出迴圈
                if (!stillOnScreen) {
                    break
                }
                
                retryCount++
                if (retryCount >= 6) {
                    ; 若嘗試 6 次依舊有字，可能是遊戲卡住或 OCR 誤判，觸發安全重置
                    ResetToState1("收魚超時，重試 6 次 F 鍵後畫面仍顯示收魚提示")
                    return
                }
            }
            
            ; 等待 1.5 秒收魚結算畫面完全消失，回到狀態 01 重置循環
            Sleep(1500)
            SetState(1)
    }
}

; ------------------------------------------
; 輔助邏輯與控制函式
; ------------------------------------------

; 設定新狀態並更新時間戳記
SetState(newState) {
    global CurrentState, StateTime, IsNewReelSession, State5Phase, State5PhaseStart, CyclicClickState, IsFilterFish, IsFishFilterPassed, FilterOcrCount, FilterOcrLog
    
    ; 若即將離開狀態 3 時，清除 OCR 的除錯 ToolTip
    if (CurrentState == 3 && newState != 3) {
        ToolTip("", , , 2)
    }
    
    ; 若即將離開狀態 5，確保滑鼠左鍵被放開
    if (CurrentState == 5 && newState != 5) {
        if (GetKeyState("LButton")) {
            Click("Up")
        }
    }
    
    ; 當進入狀態 5 時，初始化時間控制法的階段與計時器
    if (newState == 5) {
        if (IsNewReelSession) {
            IsNewReelSession := false
            State5Phase := "initial" ; 首次進入拉魚：執行 2 秒長按
            IsFishFilterPassed := false
            FilterOcrCount := 0
            FilterOcrLog := "" ; 重置日誌內容
        } else {
            State5Phase := "cyclic"  ; 從 QTE 返回：直接進入按壓/釋放循環
        }
        State5PhaseStart := A_TickCount
        CyclicClickState := "down"
        Click("Down") ; 立即按下左鍵啟動拉扯
    }
    
    ; 當進入狀態 6/7 時，先鬆開對應按鍵再長按，確保觸發鍵盤按壓事件
    if (newState == 6) {
        Send("{D up}")
        Send("{D down}")
    }
    if (newState == 7) {
        Send("{A up}")
        Send("{A down}")
    }
    
    ; 回到狀態 1 時，重置全新拉魚會話標記，並執行防 AFK 防踢微幅移動 (A -> D)
    if (newState == 1) {
        IsNewReelSession := true
        
        ; 僅在腳本未暫停時執行防踢移動，避免手動操作時干擾
        if (!IsPaused) {
            Send("{A up}")
            Send("{D up}")
            Sleep(500)
            Send("{A down}")
            Sleep(60)
            Send("{A up}")
            Sleep(200)
            Send("{D down}")
            Sleep(60)
            Send("{D up}")
            Sleep(500) ; 稍微延遲以確保角色動作完成
        }
    }
    
    CurrentState := newState
    StateTime := A_TickCount
}

; 釋放所有按下的按鍵，避免卡鍵
ReleaseAllKeys() {
    if (GetKeyState("LButton"))
        Click("Up")
    Send("{A up}")
    Send("{D up}")
}

; 狀態異常重置
ResetToState1(reason) {
    global CurrentState, StateTime, IsPaused, IsNewReelSession, GameTitle
    
    ReleaseAllKeys()
    
    ; 暫停狀態 ToolTip 刷新，避免提示訊息被蓋掉
    SetTimer(UpdateStatus, 0)
    
    ToolTip("【自動釣魚異常】`n原因：" . reason . "`n`n正在透過 OCR 偵測當前畫面以自動恢復狀態...", 10, 10)
    
    ; 預設重置回狀態 1
    targetState := 1
    stateName := "01-釣竿就緒"
    
    ; 獲取視窗客戶區位置與尺寸，進行全視窗 OCR 偵測
    if (WinExist(GameTitle)) {
        WinGetClientPos(&winX, &winY, &winW, &winH, GameTitle)
        if (winW > 0 && winH > 0) {
            try {
                result := OCR.FromRect(winX, winY, winW, winH)
                ocrFullText := result.Text
                
                ; 1. 檢查是否卡在收魚結算畫面 (F 收起 G 放生)
                isState8 := (InStr(ocrFullText, "收") && InStr(ocrFullText, "起"))
                         || (InStr(ocrFullText, "放") && InStr(ocrFullText, "生"))
                         || (InStr(ocrFullText, "F") && InStr(ocrFullText, "收"))
                
                ; 2. 檢查是否已拋竿在水中等待魚咬鉤 (畫面下方會有 "收線" 文字)
                isState3 := (InStr(ocrFullText, "收") && (InStr(ocrFullText, "線") || InStr(ocrFullText, "线")))
                
                if (isState8) {
                    targetState := 8
                    stateName := "08-釣上與收魚 (收魚畫面)"
                } else if (isState3) {
                    targetState := 3
                    stateName := "03-等待魚咬鉤 (釣線已在水中)"
                }
            } catch {
                ; 靜默捕獲
            }
        }
    }
    
    ToolTip("【自動釣魚異常】`n原因：" . reason . "`n`n自動分析結果：檢測到卡在 [" . stateName . "]`n腳本將在 5 秒後切換至該狀態繼續執行...", 10, 10)
    Sleep(5000)
    
    ; 重新開啟 ToolTip 刷新
    SetTimer(UpdateStatus, 100)
    
    ; 執行狀態轉移並重置計時器，繼續自動執行
    IsNewReelSession := true
    SetState(targetState)
}

; 偵測畫面是否有任何釣魚相關的活動 UI 元素
DetectAnyFishingUI() {
    global State3Img, State8Img, SearchTolerance
    return SearchImage(State3Img, SearchTolerance)
        || SearchImage(State8Img, SearchTolerance)
}

; 獲取動態縮放後的標準下方 UI 搜尋區域 (用於狀態 3, 狀態 8)
GetScaledSearchRegion(&x1, &y1, &x2, &y2) {
    global BaseWidth, BaseHeight, GameTitle
    
    ; 基準搜尋區域 (在 1534x862 下涵蓋下方掛鉤圖示與收魚提示的區域)
    bx1 := 550
    by1 := 520
    bx2 := 980
    by2 := 850
    
    if (!WinExist(GameTitle)) {
        x1 := bx1, y1 := by1, x2 := bx2, y2 := by2
        return
    }
    
    WinGetClientPos(&winX, &winY, &winW, &winH, GameTitle)
    if (winW <= 0 || winH <= 0) {
        x1 := bx1, y1 := by1, x2 := bx2, y2 := by2
        return
    }
    
    ; 動態比例換算
    scaleX := winW / BaseWidth
    scaleY := winH / BaseHeight
    
    x1 := Round(bx1 * scaleX)
    y1 := Round(by1 * scaleY)
    x2 := Round(bx2 * scaleX)
    y2 := Round(by2 * scaleY)
}

; 呼叫 UWP OCR 引擎獲取視窗上半部的文字內容 (排除側邊 20% 避免偵測到腳本 ToolTip)
DetectTextOCR() {
    global GameTitle
    
    if (!WinExist(GameTitle)) {
        return ""
    }
    
    WinGetClientPos(&winX, &winY, &winW, &winH, GameTitle)
    if (winW <= 0 || winH <= 0) {
        return ""
    }
    
    ; 鎖定視窗中上方的客戶區域，排除左側與右側各 20% 的寬度
    ocrX := winX + Round(winW * 0.2)
    ocrY := winY
    ocrW := Round(winW * 0.6)
    ocrH := winH // 2
    
    try {
        result := OCR.FromRect(ocrX, ocrY, ocrW, ocrH)
        return result.Text
    } catch {
        return ""
    }
}

; 呼叫 UWP OCR 引擎獲取視窗下半部中段的文字內容 (X 軸 1/3 到 2/3, Y 軸 1/2 到 1)
DetectTextOCRBottom() {
    global GameTitle
    
    if (!WinExist(GameTitle)) {
        return ""
    }
    
    WinGetClientPos(&winX, &winY, &winW, &winH, GameTitle)
    if (winW <= 0 || winH <= 0) {
        return ""
    }
    
    ; 鎖定視窗下半部的中段區域 (X 軸切為 3 等份取中間，Y 軸切為 2 等份取下面)
    ocrX := winX + winW // 3
    ocrY := winY + winH // 2
    ocrW := winW // 3
    ocrH := winH // 2
    
    try {
        result := OCR.FromRect(ocrX, ocrY, ocrW, ocrH)
        return result.Text
    } catch {
        return ""
    }
}

; 呼叫 UWP OCR 引擎獲取視窗中央區域 (長與寬分別往內縮 1/5)
DetectTextOCRCenter() {
    global GameTitle
    
    if (!WinExist(GameTitle)) {
        return ""
    }
    
    WinGetClientPos(&winX, &winY, &winW, &winH, GameTitle)
    if (winW <= 0 || winH <= 0) {
        return ""
    }
    
    ; 鎖定視窗中央區域 (長與寬分別往內縮 1/5)
    ocrX := winX + winW // 5
    ocrY := winY + winH // 5
    ocrW := winW - 2 * (winW // 5)
    ocrH := winH - 2 * (winH // 5)
    
    try {
        result := OCR.FromRect(ocrX, ocrY, ocrW, ocrH)
        return result.Text
    } catch {
        return ""
    }
}

; 呼叫 UWP OCR 引擎獲取整個遊戲視窗的文字內容 (解決所有 UI 偏移、DPI 縮放與角度變化問題)
DetectTextOCRFull() {
    global GameTitle
    
    if (!WinExist(GameTitle)) {
        return ""
    }
    
    WinGetClientPos(&winX, &winY, &winW, &winH, GameTitle)
    if (winW <= 0 || winH <= 0) {
        return ""
    }
    
    ; 排除左側 25% 寬度區域以防狀態 ToolTip 橫向拉長，同時排除上方 15% 高度以防 ToolTip 高度影響，避免誤讀與遞歸增長
    ocrX := winX + Round(winW * 0.25)
    ocrY := winY + Round(winH * 0.15)
    ocrW := Round(winW * 0.75)
    ocrH := Round(winH * 0.85)
    
    try {
        result := OCR.FromRect(ocrX, ocrY, ocrW, ocrH)
        return result.Text
    } catch {
        return ""
    }
}

; ------------------------------------------
; 時間控制法拉魚 Reeling 點擊邏輯 (非阻塞)
; ------------------------------------------
RunTimeBasedClicking() {
    global State5Phase, State5PhaseStart, CyclicClickState
    
    elapsed := A_TickCount - State5PhaseStart
    
    if (State5Phase == "initial") {
        ; 階段一：首次進入狀態5，固定長按左鍵 2 秒 (保留使用者自訂參數)
        if (elapsed >= 2000) {
            State5Phase := "cyclic"
            State5PhaseStart := A_TickCount
            CyclicClickState := "up"
            Click("Up") ; 先釋放左鍵
        } else {
            if (!GetKeyState("LButton")) {
                Click("Down")
            }
        }
    } else if (State5Phase == "cyclic") {
        ; 階段二：循環點擊階段 (使用者自訂參數：按 0.35 秒，放 1.0 秒)
        if (CyclicClickState == "down") {
            if (elapsed >= 350) {
                Click("Up")
                CyclicClickState := "up"
                State5PhaseStart := A_TickCount
            } else {
                if (!GetKeyState("LButton")) {
                    Click("Down")
                }
            }
        } else if (CyclicClickState == "up") {
            if (elapsed >= 1000) {
                Click("Down")
                CyclicClickState := "down"
                State5PhaseStart := A_TickCount
            } else {
                if (GetKeyState("LButton")) {
                    Click("Up")
                }
            }
        }
    }
}

; ------------------------------------------
; ImageSearch 共用包裝函式
; ------------------------------------------
SearchImage(imagePath, tolerance := 80) {
    ; 獲取動態縮放後的下方 UI 局部搜尋區域
    GetScaledSearchRegion(&x1, &y1, &x2, &y2)
    searchOption := "*" . tolerance . " " . imagePath
    
    try {
        if ImageSearch(&foundX, &foundY, x1, y1, x2, y2, searchOption) {
            return {x: foundX, y: foundY}
        }
    } catch Error as err {
        ; 靜默捕獲
    }
    return false
}

; ------------------------------------------
; 狀態顯示更新
; ------------------------------------------
UpdateStatus() {
    global CurrentState, IsPaused, StateTime
    
    stateNames := [
        "01-釣竿就緒",
        "02-拋竿",
        "03-等待魚咬鉤",
        "04-咬鉤收線",
        "05-拉魚 (控制張力)",
        "06-向右拉扯 (QTE-D)",
        "07-向左拉扯 (QTE-A)",
        "08-收魚 (等待動畫)"
    ]
    
    statusText := "=== Once Human 自動釣魚 ===`n"
    statusText .= "篩選魚種 (F11)：" . (IsFilterFish ? "開啟 (極寒水母/電鰻)" : "關閉") . "`n"
    if (IsFilterFish && CurrentState == 5) {
        statusText .= "篩選紀錄：" . (FilterOcrLog == "" ? "(進行中...)" : FilterOcrLog) . "`n"
    }
    if (IsPaused) {
        statusText .= "目前狀態：已暫停 (按 F8 恢復)`n"
    } else {
        elapsed := Round((A_TickCount - StateTime) / 1000, 1)
        statusText .= "目前狀態：" . stateNames[CurrentState] . " (" . elapsed . " 秒)`n"
    }
    
    ; 組合鍵盤與滑鼠的實際按壓狀態
    heldKeys := ""
    if (GetKeyState("LButton"))
        heldKeys .= "[滑鼠左鍵] "
    if (GetKeyState("A"))
        heldKeys .= "[A 鍵] "
    if (GetKeyState("D"))
        heldKeys .= "[D 鍵] "
        
    statusText .= "長按狀態：" . (heldKeys = "" ? "無" : heldKeys) . "`n"
    statusText .= "----------------------------`n"
    statusText .= "F8: 啟動/恢復 | F9: 暫停 | F12: 強制終止"
    
    ToolTip(statusText, 10, 10)
}
; NextGen Envanter kaldırıcısı: uygulamanın kendi yazdığı kayıt defteri girdilerini siler.
; - envanter:// kaydı (HKCU\Software\Classes\envanter) uygulama ilk açılışta yazar; electron-builder Windows'ta
;   bu kaydı yapmadığı için kaldırırken de silmez.
; - "Windows açılınca başlat" (HKCU\...\CurrentVersion\Run, değer adı uygulama kimliği) uygulamanın kendi ayarıdır.
; Silinmezse kaldırılmış exe'yi gösteren ölü girdiler kalır (bağlantı tıklamasında "bulunamadı" hatası, Görev
; Yöneticisi → Başlangıç'ta ölü satır). Yalnızca bu kurulumu gösteren girdiler silinir.

!macro envanterKurulumunuGosterir VALUE RESULT
  ; VALUE "$INSTDIR\..." (tırnaklı ya da tırnaksız) ile başlıyorsa RESULT = 1
  StrCpy ${RESULT} 0
  StrLen $R8 '"$INSTDIR\'
  StrCpy $R9 ${VALUE} $R8
  ${if} $R9 == '"$INSTDIR\'
    StrCpy ${RESULT} 1
  ${endif}
  StrLen $R8 '$INSTDIR\'
  StrCpy $R9 ${VALUE} $R8
  ${if} $R9 == '$INSTDIR\'
    StrCpy ${RESULT} 1
  ${endif}
!macroend

!macro customUnInstall
  ; Güncellemede eski sürümün kaldırıcısı da çalışır: o zaman hiçbir şey silinmez (otomatik başlatma korunur)
  ${ifNot} ${isUpdated}
    Push $0
    Push $1
    Push $R8
    Push $R9

    ReadRegStr $0 HKCU "Software\Classes\envanter\shell\open\command" ""
    !insertmacro envanterKurulumunuGosterir $0 $1
    ${if} $1 == 1
      DeleteRegKey HKCU "Software\Classes\envanter"
    ${endif}

    ReadRegStr $0 HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "${APP_ID}"
    !insertmacro envanterKurulumunuGosterir $0 $1
    ${if} $1 == 1
      DeleteRegValue HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "${APP_ID}"
      DeleteRegValue HKCU "Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run" "${APP_ID}"
    ${endif}

    ClearErrors
    Pop $R9
    Pop $R8
    Pop $1
    Pop $0
  ${endif}
!macroend

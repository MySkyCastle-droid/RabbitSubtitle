# RabbitSubtitle 3.203 實機乾淨 Windows 驗收

這份清單只適用於 GitHub Draft Release 中、檔名固定為 `RabbitSubtitle-3.203-Windows-x64.zip` 的精確資產。它不會發布 Release、修改網站或上傳個人檔案。任一項失敗時，PowerShell producer 只留下 FAIL 診斷，不會產生可放行的 `physicalCleanWindows.json`。

## 測試電腦條件

- Windows 10/11 x64 的另一台電腦或全新帳號。
- `python.exe` 與 `py.exe` 均不在 `PATH`。
- `%LOCALAPPDATA%\RabbitSubtitle`、`%USERPROFILE%\.cache\huggingface` 等位置沒有既有語音模型快取。
- Microsoft Defender、防毒服務及即時保護保持開啟。
- 不安裝 Python、Node 或任何開發套件；不把開發目錄複製到這台電腦。
- 測試期間不要開啟其他終端機，否則 console-window monitor 會正確判定失敗。

## 準備檔案

從同一個 Draft Release 下載 ZIP 與 `.sha256`。另外從 Release repo 的同一個 `main` commit 取得：

- `.github/scripts/produce-physical-clean-windows-evidence.ps1`
- 本清單 `PHYSICAL-CLEAN-WINDOWS-3.203.md`

先以原生 PowerShell 計算 ZIP：

```powershell
$zip = 'C:\Users\Public\Downloads\RabbitSubtitle-3.203-Windows-x64.zip'
$sha = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
$bytes = (Get-Item -LiteralPath $zip).Length
$sha
$bytes
```

`$sha`、`$bytes` 必須與 Draft asset metadata 及 `.sha256` 完全一致。請另外建立一個空資料夾供去識別化的人工證據使用，例如 `C:\RabbitSubtitle-3.203-manual-records`。

## 執行 producer

請用未提升權限的一般帳號開啟 Windows PowerShell，並以實際核准值執行：

```powershell
$script = 'C:\RabbitSubtitle-acceptance\produce-physical-clean-windows-evidence.ps1'
$evidence = 'C:\RabbitSubtitle-3.203-physical-evidence'
$records = 'C:\RabbitSubtitle-3.203-manual-records'
& $script -ArchivePath $zip -ArtifactSha256 $sha -ArtifactBytes $bytes -EvidenceDirectory $evidence -ManualRecordsDirectory $records
```

`EvidenceDirectory` 必須是尚不存在的新路徑。Producer 會自動完成：

- ZIP traversal、絕對路徑、重複名稱、symlink、壓縮比、解壓根目錄與 reparse-point 檢查。
- `RELEASE-BUILD.json`、來源 SHA、兩份 spec SHA、EXE SHA、PE 版本及必要檔案檢查。
- `speaker-setup-copy.json` 的五語內容檢查。
- 真正的系統 `PATH` 無 Python/py 與最初模型快取為空的檢查。
- 外部工作目錄與桌面捷徑啟動、loopback UI 回應及 console 視窗事件監控。
- Defender 對 ZIP 與解壓 package 的掃描。
- 測試前後 package tree 逐檔 SHA-256 不變檢查。
- producer 自身、所有 records 及最終 JSON 的實體雜湊綁定。

## 七項人工操作

Producer 每次只接受畫面顯示的精確 `PASS <checkName>`。每項操作至少存一個已遮罩的截圖或文字紀錄到 `$records`，檔名必須以指定前綴開始，例如 `bilingualOutput--final-preview.png`。

| checkName／檔名前綴 | 實際操作與通過條件 |
|---|---|
| `bilingualOutput` | 匯入有權使用、無敏感資訊的短素材，輸出雙字幕；播放開頭、中段、結尾，兩語均不漏字、不超出安全區。 |
| `missingModel` | 第一次安裝前，直接在 producer 已記錄的空模型狀態執行語音工作；需顯示本地化缺少模型訊息，不能崩潰。 |
| `modelInstallCancel` | 啟動第一次安裝後按程式內取消；需進入受控取消狀態，不能卡住或閃現命令視窗。 |
| `modelInstallResume` | 取消後重新安裝／續裝，需成功完成且程式仍可操作。 |
| `firstModelInstall` | 確認上述從空快取開始、包含取消與續裝的首次安裝流程最後已顯示 ready。 |
| `offlineReopen` | 模型完成後切斷網路，完全關閉再由桌面捷徑重開，並成功完成一次本機語音操作。 |
| `batch` | 以數個非敏感檔案跑小批次，其中含一個刻意失敗檔；成功檔不受污染，輸出 ZIP 可開啟且內容正確。 |

Hugging Face token 若需要，只能由測試者在 RabbitSubtitle 的遮罩欄位直接輸入。不得貼入聊天、PowerShell、截圖、檔名、文字紀錄或 evidence。不要在 records 中放個人影片、完整輸出媒體、姓名、信箱、授權碼或完整使用者路徑。

人工證據允許 `.png`、`.jpg`、`.jpeg`、`.webp`、`.txt`、`.json`、`.log`、`.csv`，每檔不得超過 25 MiB。文字 evidence 會自動掃描常見 token／私鑰型態；二進位截圖必須由測試者自行遮罩。

## 成功輸出與交回

成功時 `$evidence` 必須包含：

```text
physicalCleanWindows.json
produce-physical-clean-windows-evidence.ps1
physicalCleanWindows.records\...
```

交回整個 `$evidence` 資料夾，不要只交 JSON。Assembler 會重新核對 producer、records、ZIP 的 bytes 與 SHA-256；任何檔案被改名、刪除或重存都會失敗。請另行交回原本的 Draft ZIP，供 `--artifact-path` 作最後一次實體重算。

Producer PASS 不取代 GitHub `windows-latest` 的 `githubWindowsRunner` 證據；兩個獨立角色都通過後，`cleanWindowsPackage` gate 才能成立。

# Pterodactyl 管理員指南

本文教你點樣用 Pterodactyl Panel 管理 Minecraft 伺服器，包括建立新世界、安裝模組、切換伺服器等。

> **重要：** Pterodactyl 係管理 Minecraft 伺服器嘅**唯一方法**。所有 MC 伺服器進程都由 Pterodactyl Wings 喺 Docker 容器入面管理，系統無 `minecraft.service`。世界資料存放喺 `/var/lib/pterodactyl/volumes/<uuid>/world/`。所有伺服器操作（啟動、停止、設定、插件、檔案管理）都必須透過 Pterodactyl Panel GUI 或者 RCON 進行。

---

## 登入 Panel

- **最簡單方法：** 去 MC Web Control Panel（`http://it114115.duckdns.org:8080?token=koei2026`），按 **"Open Pterodactyl Panel"** 按鈕。呢個連結會自動帶正確嘅 IP，唔需要自己查。
- 帳號：`alexchang2828@gmail.com`
- 注意：MC 伺服器熄咗嘅時候 Panel 無法存取（因為 Panel 裝喺 MC 機上）

> MC 伺服器嘅公開 IP 每次開機都會變，但 `fix-panel-ip.service` 會自動修正 Panel 設定。你唔需要手動改任何 IP — 直接用 Web Control Panel 嘅按鈕就可以。

---

## 基本操作

### 啟動伺服器

1. 登入 Panel
2. 點擊你想啟動嘅伺服器（例如 **Survival World**）
3. 按綠色 **Start** 按鈕
4. 等 Console 出現 `Done! For help, type "help"` 即完成
5. 用 Minecraft 連入 `it114115.duckdns.org`

### 停止伺服器

1. 入去伺服器頁面
2. 按紅色 **Stop** 按鈕（會先儲存世界再關閉）
3. 如果卡住，可以按 **Kill** 強制關閉（唔建議，可能損壞世界資料）

### 重啟伺服器

1. 按 **Restart** 按鈕
2. 適用於安裝新插件/模組後需要重新載入

### 執行指令

1. 入去伺服器頁面
2. 喺 Console 底部嘅輸入框打指令（唔需要加 `/`）
3. 常用指令：
   - `list` — 睇線上玩家
   - `op 玩家名` — 給予管理員權限
   - `kick 玩家名` — 踢走玩家
   - `ban 玩家名` — 封禁玩家
   - `save-all` — 強制儲存世界
   - `tps` — 查看伺服器效能（20 = 正常）

---

## 管理檔案

1. 入去伺服器頁面 → 點 **Files** 分頁
2. 可以：
   - 上傳檔案（拖拉或者按 Upload）
   - 編輯設定檔（例如 `server.properties`）
   - 下載檔案（備份用）
   - 刪除檔案

### 重要檔案

| 檔案 | 用途 |
|---|---|
| `server.properties` | 伺服器基本設定（人數上限、難度、RCON 等） |
| `server.jar` | 伺服器核心（PaperMC / Forge / Fabric） |
| `eula.txt` | Minecraft EULA 同意書（必須係 `true`） |
| `plugins/` | PaperMC 插件資料夾 |
| `mods/` | Forge / Fabric 模組資料夾 |
| `world/` | 主世界資料 |
| `world_nether/` | 地獄世界資料 |
| `world_the_end/` | 終界世界資料 |

---

## 建立新世界（原版 / PaperMC）

### Step 1：建立新 Server

1. 點右上角頭像 → **Admin**（進入管理面板）
2. 左邊揀 **Servers** → **Create New**
3. 填寫：
   - **Server Name**：例如 `Creative World` 或 `SMP Season 2`
   - **Server Owner**：揀你自己嘅帳號
   - **Node**：揀 `mc-server`
   - **Default Allocation**：之後設定（見 Step 1b）

### Step 1b：新增 Port（如果冇可用嘅 Allocation）

因為 port 25565 已經俾第一個伺服器用咗，新伺服器需要用唔同 port。但同一時間只會開一個伺服器，所以可以共用 25565：

**方法 A — 共用 port（推薦，同時只開一個）：**
1. 去 Admin → **Nodes** → `mc-server` → **Allocation** 分頁
2. 新增一個 port，例如 `25566`
3. 建立新 Server 時選呢個 port
4. **但係**玩家連線要打 `it114115.duckdns.org:25566`

**方法 B — 刪除舊 Server 嘅 allocation 再重用（唔推薦）**

> 建議：所有伺服器都用唔同 port，但每次只啟動一個。玩家根據你話佢哋嘅 port 連入。

### Step 2：設定資源

- **Memory**：`12288` MB（12GB）
- **Disk**：`20000` MB（20GB）
- **CPU**：`0`（不限制）

### Step 3：選擇遊戲類型

喺 **Nest** 揀 `Minecraft`，然後 **Egg** 揀：

| Egg | 適用場景 |
|---|---|
| **Paper** | 原版 + 插件（最常用） |
| **Forge** | 模組包（需要玩家裝 Forge + 相同 mods） |
| **Fabric** | 模組包（較新嘅模組框架） |
| **Vanilla** | 純原版（無插件無模組） |

### Step 4：設定啟動參數

- **Docker Image**：揀 `Java 21`
- **Server Jar File**：`server.jar`
- **Minecraft Version**：例如 `1.21.11`

### Step 5：按 **Create Server**

建立後會自動安裝。第一次啟動需要幾分鐘下載伺服器核心。

### Step 6：接受 EULA（重要！）

Server 建立後第一次啟動會失敗，因為 Minecraft 要求接受 EULA：

1. 去 **Files** 分頁
2. 搵到 `eula.txt`，點開
3. 將內容改為 `eula=true`
4. 按 **Save Content**
5. 返去 **Console** → 按 **Start**

---

## 建立模組世界（Forge / Fabric）

### Step 1：喺 Panel 建立新 Server

同上面一樣，但 **Egg** 揀 **Forge** 或 **Fabric**。

### Step 2：上傳模組

1. 等 Server 安裝完成（Console 會顯示進度）
2. 去 **Files** 分頁
3. 入去 `mods/` 資料夾
4. 按 **Upload** 上傳所有 `.jar` 模組檔案
5. 確保所有模組版本同 Minecraft 版本 + Forge/Fabric 版本相容

### Step 3：啟動

1. 按 **Start**
2. 第一次啟動較慢（需要載入所有模組）
3. 如果出錯，睇 Console 嘅錯誤訊息，通常係模組版本唔相容

### 玩家要做嘅事

模組伺服器需要玩家安裝相同嘅模組：
1. 下載並安裝 Forge / Fabric 客戶端
2. 將相同嘅 mods 放入玩家自己電腦嘅 `.minecraft/mods/` 資料夾
3. 用對應版本嘅 Forge / Fabric 啟動 Minecraft
4. 連入伺服器

> 建議用 **CurseForge** 或 **Modrinth** 整一個模組包，分享俾所有玩家安裝。

---

## 切換世界

同一時間只能開一個伺服器（因為 t3.xlarge 嘅資源限制）。

### 切換步驟

1. **停止** 當前運行嘅伺服器（按 Stop）
2. 等完全停止（Console 顯示 server stopped）
3. 入去你想玩嘅伺服器
4. 按 **Start**
5. 同玩家講新伺服器嘅連線地址（如果 port 唔同）

### 注意事項

- 停止伺服器前唔需要手動儲存，Stop 會自動儲存
- 世界資料保留喺各自嘅 Server 入面，切換唔會影響其他世界
- 如果兩個伺服器用同一個 port（25565），玩家唔需要改連線地址

---

## 備份同還原

### 用 Panel 備份

1. 入去伺服器頁面 → **Backups** 分頁
2. 按 **Create Backup**
3. 可以選擇備份整個伺服器或者指定檔案
4. 備份完成後可以下載或者還原

### 用 S3 自動備份（已設定）

系統每 1 小時自動備份世界到 S3，另外每次開機（`fix-panel-ip.sh`）同關機（MC Web Control Panel）都會觸發備份。備份腳本會自動搵 Pterodactyl volumes 入面嘅世界資料。

新建嘅伺服器建議用 Panel 內建嘅 Backup 功能。

### 還原備份

1. 入去 **Backups** 分頁
2. 搵到你要還原嘅備份
3. 按右邊嘅 ⋮ 選單 → **Restore**
4. 確認還原（會覆蓋當前世界資料）

---

## 常見問題

### Panel 打唔開

MC 伺服器 EC2 未開機。去 AWS Console → EC2 → 啟動 `minecraft-server`，等 1-2 分鐘後重試。

### 伺服器啟動失敗

1. 睇 Console 嘅錯誤訊息
2. 常見原因：
   - `eula.txt` 入面唔係 `true` → 去 Files 改做 `eula=true`
   - Java 版本唔啱 → 去 Startup 分頁改 Docker Image
   - 模組版本衝突 → 移除最近加嘅模組再試
   - 記憶體不足 → 去 Admin → Server → 增加 Memory limit

### 玩家連唔到

1. 確認伺服器已經 Start 咗（Console 顯示 `Done!`）
2. 確認連線地址正確（`it114115.duckdns.org` 或者加 port `:25566`）
3. 確認 Minecraft 版本同伺服器版本一致
4. 如果係模組伺服器，確認玩家裝咗相同嘅 mods

### 想改伺服器設定

1. **Stop** 伺服器
2. 去 **Files** → 編輯 `server.properties`
3. 常改嘅設定：
   - `max-players=8` — 最大人數
   - `difficulty=hard` — 難度（peaceful/easy/normal/hard）
   - `pvp=true` — 開關 PVP
   - `view-distance=8` — 可見距離（越大越 lag）
   - `gamemode=survival` — 預設模式（survival/creative/adventure）
4. **Start** 伺服器

### 想加插件（PaperMC 伺服器）

1. 去 https://hangar.papermc.io 或 https://modrinth.com 下載 `.jar` 插件
2. 喺 Panel → Files → `plugins/` 資料夾上傳
3. **Restart** 伺服器載入新插件

---

## 安全提醒

- **定期改密碼**：Panel 密碼同 RCON 密碼都要定期更換
- **唔好俾 SSH 權限其他人**：管理員用 Panel GUI 就夠，唔需要 SSH
- **備份**：開新世界前確保舊世界有備份
- **模組安全**：只從信任嘅來源（CurseForge、Modrinth）下載模組

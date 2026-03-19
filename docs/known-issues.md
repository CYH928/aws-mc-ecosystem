# 已知問題同踩坑記錄

部署過程中遇到嘅所有問題同解決方法。幫助下一次部署避免踩同樣嘅坑。

---

## 1. Terraform `templatefile()` 同 Shell 變量衝突

**問題：** `terraform plan` 報錯 `vars map does not contain key "UPPERCASE_VAR"`

**原因：** Terraform 嘅 `templatefile()` 會將所有 `${...}` 當成模板變量。Shell 腳本入面嘅 `${MY_VAR}`（大寫 shell 變量）會被 Terraform 嘗試解析，但佢唔喺 vars map 入面。

**解決：** Shell 變量用 `$${VAR_NAME}` escape。Terraform 會將 `$${}` 輸出為 `${}`。

```bash
# 錯誤 — Terraform 會嘗試解析 ${BACKUP_BUCKET}
echo "${BACKUP_BUCKET}" > /etc/mc-backup-bucket

# 正確 — Terraform 輸出為 ${BACKUP_BUCKET}，shell 再解析
echo "$${BACKUP_BUCKET}" > /etc/mc-backup-bucket
```

**影響範圍：** `terraform/scripts/watcher_init.sh` 同 `terraform/scripts/mc_init.sh` 所有大寫 shell 變量。

---

## 2. mc-hibernation v2.5.0 同預期唔相容

**問題：** mc-hibernation 安裝後唔能代理到遠端 MC server。

**原因：**
- 最新穩定版係 v2.5.0，唔係 v2.6.2（v2.6.2 唔存在，下載 404）
- v2.5.0 嘅 binary 命名格式係 `msh-v2.5.0-0876091-linux-arm64.bin`，唔係 `msh-linux-arm64`
- v2.5.0 嘅 config 格式用 `Server.Folder` / `Commands.StartServer`，唔係 `Basic.MinecraftServerAddress`
- **最重要：** mc-hibernation 設計用嚟管理本機 Minecraft process，唔支援代理到遠端 EC2 instance

**解決：** 放棄 mc-hibernation，改用自寫嘅 Python TCP proxy（`/opt/mc-proxy/proxy.py`），功能：
- 監聽 port 25565
- 驗證 Minecraft 協議 handshake — 拒絕 port scanner 同垃圾連線
- Server list ping（狀態查詢）→ 回應假 MOTD "Server is sleeping - join to wake up!"，唔啟動 EC2
- 真玩家 login → 檢查 MC EC2 狀態，如果 stopped 就自動啟動
- 等待 MC server ready 後 replay handshake 再代理所有 TCP traffic
- 支援多個同時連線（threading）

**教訓：** 使用第三方工具前要確認：版本號是否存在、binary 命名、config 格式、是否支援遠端代理。

---

## 3. GitHub API Rate Limit 導致 Chunky 下載失敗

**問題：** `mc_init.sh` 執行時 Chunky 插件下載失敗，`jq: error: Cannot iterate over null`

**原因：** EC2 instance 嘅 IP 被 GitHub API rate limit（未認證嘅請求每小時只有 60 次，EC2 IP 共享配額容易爆）。API 返回 rate limit 錯誤而唔係 release 資料。

**解決：** 改用 Modrinth API 下載 Chunky：
```bash
# 錯誤 — GitHub API 容易 rate limit
curl -s "https://api.github.com/repos/pop4959/Chunky/releases/latest" | jq ...

# 正確 — Modrinth API 唔會 rate limit
curl -s "https://api.modrinth.com/v2/project/fALzjamp/version?loaders=%5B%22paper%22%5D" | jq -r '.[0].files[0].url'
```

**教訓：** 喺 EC2 user_data 腳本入面避免用 GitHub API 下載 release assets。用 Modrinth、PaperMC Hangar 或直接 URL。

---

## 4. cloud-init `set -euo pipefail` 導致整個腳本中斷

**問題：** user_data 腳本只完成一部分就停止。

**原因：** `set -euo pipefail` 令任何非零 exit code 立即中斷整個腳本。Chunky 下載失敗（問題 3）觸發中斷，之後嘅 systemd service 建立、cron 設定等全部冇執行。

**解決：** 對可能失敗但唔致命嘅操作加 `|| true` 或用 `if` 包裝：
```bash
# 加 fallback，唔好讓非關鍵步驟中斷整個腳本
CHUNKY_URL=$(curl -s "..." | jq -r '...' || echo "")
if [ -n "$CHUNKY_URL" ] && [ "$CHUNKY_URL" != "null" ]; then
  curl -sLo plugins/Chunky.jar "$CHUNKY_URL"
fi
```

**教訓：** user_data 腳本只會行一次，失敗就要手動修復。關鍵步驟（Java、PaperMC、systemd）同可選步驟（Chunky 插件）要分開處理。

---

## 5. Pterodactyl Panel WebSocket 連接失敗（CORS）

**問題：** Panel 顯示紅色 banner "We're having some trouble connecting to your server"。瀏覽器 F12 Console 顯示 WebSocket 連線失敗。

**原因：** 三個問題疊加：
1. **Port 8443 未開放** — Wings API/WebSocket 監聽 port 8443，Security Group 冇開
2. **Node FQDN 設為 127.0.0.1** — 瀏覽器嘗試連去 `ws://127.0.0.1:8443`（即自己電腦），當然連唔到
3. **CORS 未設定** — Wings 預設 `allowed_origins: []`，瀏覽器被 CORS policy 擋住

**解決（三個都要做）：**

```bash
# 1. Security Group 開放 port 8443
# 喺 terraform/security_groups.tf 加：
ingress {
  description = "Pterodactyl Wings API"
  from_port   = 8443
  to_port     = 8443
  protocol    = "tcp"
  cidr_blocks = [var.admin_cidr]
}

# 2. Node FQDN 設為公開 IP（喺 Panel Admin → Nodes → Edit）
# 或者用 API / database 更新

# 3. Wings config 加 CORS（/etc/pterodactyl/config.yml 最底加）：
allowed_origins:
  - "http://MC_PUBLIC_IP:8080"
allow_cors_private_network: true

# 重啟 Wings
sudo systemctl restart wings
```

**注意：** MC server 每次 stop/start 公開 IP 會變。需要同步更新：
- Panel 嘅 Node FQDN
- Wings config 嘅 `allowed_origins`
- Panel 嘅 `APP_URL`（`/var/www/pterodactyl/.env`）

**教訓：** Pterodactyl Panel 同 Wings 喺同一台機但瀏覽器 WebSocket 係從用戶電腦直接連 Wings，唔係透過 Panel 轉發。所以 Wings 必須用公開 IP + 開 port + 設 CORS。

---

## 6. Pterodactyl Server 啟動失敗 — EULA 未接受

**問題：** 喺 Panel 按 Start 後 server 立即 crash，Console 冇顯示任何內容。

**原因：** Minecraft server 要求 `eula.txt` 入面有 `eula=true`。Pterodactyl 建立新 server 時唔會自動接受 EULA。Docker logs 顯示：
```
You need to agree to the EULA in order to run the server. Go to eula.txt for more info.
```

**解決：** Panel → Files → 編輯 `eula.txt` → 改為 `eula=true` → Save → 再按 Start。

**教訓：** 每次建立新 Minecraft server 後，第一件事就係改 EULA。可以喺 Pterodactyl 嘅 Egg 入面設定自動接受。

---

## 7. Pterodactyl Node FQDN 同 Panel APP_URL 要一致

**問題：** Panel 可以開但 WebSocket 連唔到 Wings。

**原因：** 如果 Panel `APP_URL` 用 IP-A 但 Node FQDN 用 IP-B，瀏覽器會因為 cross-origin 而被擋。

**三個地方嘅 IP 必須一致：**
1. `/var/www/pterodactyl/.env` 入面嘅 `APP_URL`
2. Panel Admin → Nodes 入面嘅 FQDN
3. `/etc/pterodactyl/config.yml` 入面嘅 `allowed_origins`

**MC server stop/start 後 IP 會變，需要更新以上三個地方。**

---

## 8. admin_cidr 同 Claude Code 嘅 IP 唔同

**問題：** Claude Code 無法 SSH 入 EC2 instances。

**原因：** `terraform.tfvars` 入面嘅 `admin_cidr` 設為用戶嘅家用 IP（例如 `223.122.75.103/32`），但 Claude Code 嘅 outgoing IP 唔同（例如 `91.207.174.3`）。

**解決：** 暫時改 `admin_cidr = "0.0.0.0/0"`，完成設定後改返用戶 IP。

**教訓：** 如果需要 AI 工具 SSH 入 server，要預先考慮 IP 白名單問題。

---

## 9. MC 伺服器公開 IP 每次 stop/start 都會變

**問題：** MC 伺服器冇 Elastic IP，每次 EC2 stop 再 start 之後公開 IP 都會變。Pterodactyl Panel 嘅 APP_URL、Node FQDN、Wings CORS 全部寫死咗舊 IP，導致 Panel 開唔到或者 WebSocket 連唔到。

**之前嘅影響：** 每次 MC 伺服器重新開機後，管理員都要手動 SSH 入去更新三個地方嘅 IP（見問題 #5 同 #7）。

**解決：** 喺 MC 伺服器安裝 `fix-panel-ip.service`（腳本位於 `/opt/fix-panel-ip.sh`），每次 EC2 開機時自動：
1. 偵測當前公開 IP（從 EC2 instance metadata）
2. 更新 Panel `APP_URL`（`/var/www/pterodactyl/.env`）
3. 更新 Node FQDN（Pterodactyl database）
4. 更新 Wings CORS `allowed_origins`（`/etc/pterodactyl/config.yml`）
5. 重啟 Panel 同 Wings 服務
6. 自動啟動所有 Pterodactyl 伺服器

**結果：** MC 伺服器開機後 Pterodactyl Panel 即刻可用，唔需要任何手動修改。配合 Watcher 上嘅 MC Web Control Panel 使用，管理員可以直接點 "Open Pterodactyl Panel" 按鈕就得到正確 URL。

---

## 總結：部署順序建議

根據以上踩坑經驗，推薦嘅部署順序：

1. `terraform apply` — 建立基礎設施
2. 等 cloud-init 完成（睇 `/var/log/cloud-init-output.log`）
3. 如果 cloud-init 失敗，SSH 入去手動執行剩餘步驟
4. 安裝 Pterodactyl（用 `scripts/install_pterodactyl.sh`）
5. 建立 Node（FQDN 用公開 IP）
6. 生成 Wings token → 寫入 config → **加 CORS 設定** → 啟動 Wings
7. 建立 Server → **改 EULA** → Start
8. 測試連線

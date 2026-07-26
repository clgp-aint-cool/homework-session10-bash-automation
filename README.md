# Operations Automation Toolkit — `web01-ops`

Bộ công cụ Ops nhỏ gọn chạy trên shell Bash để giám sát (health-check), sao lưu tự động (rotating backup với verified restore), bẫy lỗi (error trapping) và lập lịch (cron) trên máy chủ Linux `web01`.

---

## 📂 Cấu trúc thư mục dự án

```text
web01-ops/
├── health-check.sh           # Script giám sát hệ thống và cảnh báo
├── backup.sh                 # Script sao lưu dữ liệu kèm bẫy lỗi on_error
├── restore-test.sh           # Script khôi phục và kiểm chứng manifest
├── cron/
│   └── lab05-monitoring      # Cấu hình cron.d mẫu
├── examples/
│   ├── monitoring.env.example # Cấu hình mẫu cho health-check
│   └── backup.env.example     # Cấu hình mẫu cho backup
├── REPORT.md                 # Báo cáo chi tiết quá trình thực hiện
└── README.md                 # Hướng dẫn setup và chạy (file này)
```

---

## 🛠️ Yêu cầu môi trường

- **Hệ điều hành:** Ubuntu Server 22.04 LTS hoặc CentOS Stream 9.
- **Phần mềm yêu cầu:** `bash`, `tar`, `rsync` hoặc `cp`, `find`, `cron` (cronie hoặc systemd-cron), `curl`, `msmtp` (hoặc `mailutils`).
- **Python 3:** Thư viện chuẩn (dùng cho web endpoint).

---

## 🚀 Hướng dẫn thiết lập (Setup)

### 1. Khởi chạy Web Endpoint giả lập
Tạo thư mục dữ liệu web và khởi chạy server HTTP của Python trên port 8080:
```bash
mkdir -p ~/web01-data && echo "hello from web01" > ~/web01-data/index.html
cd ~/web01-data && python3 -m http.server 8080 &
```

### 2. Cấu hình msmtp gửi Email
Cài đặt `msmtp` và `mailutils`:
```bash
sudo apt update && sudo apt install -y msmtp mailutils
```
Cấu hình tài khoản gửi thư tại `/etc/msmtprc` (cho quyền root) hoặc `~/.msmtprc` (cho user hiện tại):
```ini
defaults
auth             on
tls              on
tls_trust_file   /etc/ssl/certs/ca-certificates.crt
logfile          ~/mail-log/msmtp.log

account gmail
host             smtp.gmail.com
port             587
from             your-email@gmail.com
user             your-email@gmail.com
password         your-app-password

account default : gmail
```
*Lưu ý:* Phân quyền file cấu hình để bảo mật thông tin tài khoản:
```bash
chmod 600 ~/.msmtprc
```

### 3. Tạo các file biến môi trường (Config)
Copy cấu hình mẫu và điền các tham số thực tế:
```bash
sudo mkdir -p /etc
```

#### File cấu hình giám sát `/etc/monitoring.env`
```bash
sudo tee /etc/monitoring.env <<'EOF'
ALERT_TO="your-email@gmail.com"
DISK_THRESHOLD=90
RAM_MIN_FREE=10
SERVICES="ssh cron"
HEALTH_URL="http://localhost:8080"
EOF
sudo chmod 600 /etc/monitoring.env
sudo chown root:root /etc/monitoring.env
```

#### File cấu hình backup `/etc/backup.env`
```bash
sudo tee /etc/backup.env <<'EOF'
DATA_DIR="/home/lab05/web01-data"
ALERT_TO="your-email@gmail.com"
DEST="/srv/backup-target"
RETAIN_DAYS=7
EOF
sudo chmod 600 /etc/backup.env
sudo chown root:root /etc/backup.env
```

---

## 💻 Cách chạy các Scripts

Đảm bảo các script đã có quyền thực thi:
```bash
chmod +x health-check.sh backup.sh restore-test.sh
```

### 1. Giám sát hệ thống (Health Check)
Chạy script giám sát (nên chạy bằng `sudo` để có quyền đọc cấu hình `/etc/monitoring.env`):
```bash
sudo ./health-check.sh
```
- Nếu hệ thống bình thường: Script kết thúc im lặng với exit code `0`.
- Nếu có lỗi xảy ra (ví dụ tắt server web): Script gửi email cảnh báo chi tiết và kết thúc với exit code `1`.

### 2. Sao lưu dữ liệu (Backup)
Chạy script backup:
```bash
sudo ./backup.sh
```
- Nén thư mục dữ liệu (loại trừ `*.log` và `*.tmp`).
- Tạo manifest chứa mã băm MD5 của từng file.
- Đẩy file nén sang thư mục đích.
- Tự động xóa các bản sao lưu cũ hơn `$RETAIN_DAYS`.
- Bẫy lỗi `trap on_error` tích hợp sẵn: nếu dòng lệnh nào bị lỗi, email chi tiết lỗi (chứa số dòng, câu lệnh chính xác và exit code) sẽ lập tức được gửi đi.

### 3. Kiểm chứng khôi phục (Restore Test)
Verify độ toàn vẹn của bản backup mới nhất so với manifest:
```bash
sudo ./restore-test.sh
```
Script sẽ tự động giải nén bản backup mới nhất vào thư mục tạm, chạy kiểm tra `md5sum -c manifest.txt` và in ra kết quả kiểm chứng.

---

## 🕒 Lập lịch chạy tự động bằng Cron

Copy file cấu hình cron vào thư mục quản lý của hệ thống:
```bash
sudo cp cron/lab05-monitoring /etc/cron.d/lab05-monitoring
sudo chmod 644 /etc/cron.d/lab05-monitoring
sudo chown root:root /etc/cron.d/lab05-monitoring
```

Nội dung file `/etc/cron.d/lab05-monitoring`:
```cron
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
SHELL=/bin/bash

# Chạy health-check mỗi 5 phút
*/5 * * * * root /home/lab05/homework-session10-bash-automation/health-check.sh >> /var/log/lab05-cron/health-check.log 2>&1

# Chạy backup hàng ngày vào lúc 02:00 sáng
0 2 * * * root /home/lab05/homework-session10-bash-automation/backup.sh >> /var/log/lab05-cron/backup.log 2>&1
```

*Lưu ý quan trọng khi chạy dưới Cron:*
1. Phải chạy dưới quyền user `root` để đọc các tệp cấu hình bảo mật `chmod 600`.
2. Khai báo biến `PATH` rõ ràng ở đầu file cron để tránh các lỗi không tìm thấy câu lệnh do môi trường cron bị rút gọn.
3. Đảm bảo thư mục lưu log `/var/log/lab05-cron` đã được tạo trước khi cron chạy:
   ```bash
   sudo mkdir -p /var/log/lab05-cron
   ```

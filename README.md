<div align="center">

<br>

```
╔══════════════════════════════════════════════════════════════════╗
║                                                                  ║
║                                                                  ║
║                                                                  ║
║    /$$      /$$ /$$$$$$$          /$$$$$$  /$$$$$$$$  /$$$$$$    ║
║   | $$  /$ | $$| $$__  $$        /$$__  $$| $$_____/ /$$__  $$   ║
║   | $$ /$$$| $$| $$  \ $$       | $$  \__/| $$      | $$  \__/   ║
║   | $$/$$ $$ $$| $$$$$$$//$$$$$$|  $$$$$$ | $$$$$   | $$         ║
║   | $$$$_  $$$$| $$____/|______/ \____  $$| $$__/   | $$         ║
║   | $$$/ \  $$$| $$              /$$  \ $$| $$      | $$    $$   ║
║   | $$/   \  $$| $$             |  $$$$$$/| $$$$$$$$|  $$$$$$/   ║
║   |__/     \__/|__/              \______/ |________/ \______/    ║
║                                                                  ║
║                                                                  ║
║                                                                  ║
╚══════════════════════════════════════════════════════════════════╝
```

**wp-security-audit.sh** — A comprehensive WordPress security scanner that runs over SSH and produces a full remediation report.

<br>

[![Version](https://img.shields.io/badge/version-2.2.0-4ade99?style=flat-square)](https://github.com/youruser/wp-security-audit)
[![Bash](https://img.shields.io/badge/bash-3.x%2B-4ade99?style=flat-square&logo=gnubash&logoColor=white)](https://www.gnu.org/software/bash/)
[![WordPress](https://img.shields.io/badge/wordpress-2.x–6.x-21759b?style=flat-square&logo=wordpress&logoColor=white)](https://wordpress.org)
[![License](https://img.shields.io/badge/license-MIT-555?style=flat-square)](LICENSE)
[![No dependencies](https://img.shields.io/badge/dependencies-none-4ade99?style=flat-square)](#)

<br>

</div>

---

## What is this?

A single bash script you copy to your server and run over SSH. It performs a deep security audit of any WordPress installation — scanning for malware, backdoors, misconfigured files, exposed secrets, and known vulnerabilities — then writes a timestamped report with exact file paths and remediation steps.

No WordPress plugin. No SaaS account. No data leaves your server.

```bash
sudo bash wp-security-audit.sh /home/mysite/htdocs/mysite.com/
```

**What you see while it runs:**

```
  ╔══════════════════════════════════════════════════════════╗
  ║   WordPress Security Audit  v2.2.0                     ║
  ╚══════════════════════════════════════════════════════════╝

  Path:  /home/mysite/htdocs/mysite.com
  Mode:  Standard scan

  ✓  PASS      Dependencies & Tools
  ✓  PASS      WordPress Installation
  ⚠  WARN      File & Directory Permissions
                1 warn
  ✓  PASS      wp-config.php Security
  ✓  PASS      Core File Integrity
  ✗  CRITICAL  Malware & Code Injection
                3 crit  1 high
  ⠹  Recently Modified Files (7 days)    ← spinner while scanning
```

**What you get when it finishes:**

```
  ────────────────────────────────────────────────────────────

  Scan Results   (52s · WP 6.4.3 · PHP 8.2.18)

  ●  3 CRITICAL
  ●  1 HIGH
  ●  4 WARNINGS

  Full report: /root/wpsecurity/wp-audit-20260331_143021.txt
```

---

## Features

- **Spinner progress UI** — one line per check category, no wall of text during the scan
- **Malware scanner** — 60+ regex patterns covering eval/base64 chains, webshells (c99, r57, b374k, WSO, weevely), cryptominer injection, JS obfuscation, and hidden iframes
- **Core integrity check** — fetches official MD5 checksums from WordPress.org and validates every core file; also uses `wp core verify-checksums` if WP-CLI is available
- **Live database audit** — scans `wp_options`, `wp_posts`, and `wp_users` directly for injected code, SEO spam, and rogue administrator accounts
- **HTTP security headers** — checks HSTS, X-Frame-Options, X-Content-Type-Options, CSP, and PHP version disclosure
- **Graceful degradation** — works without WP-CLI, without MySQL client, without curl; skips unavailable checks cleanly
- **Verbose mode** — `--full` and `--verbose` flags for deeper scans or raw terminal output
- **Zero install** — pure bash, no apt/yum packages required; works on any Linux server

---

## Checks at a glance

| # | Category | Key checks |
|---|----------|------------|
| 01 | **File Permissions** | wp-config.php chmod, world-writable PHP, 777 dirs, PHP in uploads |
| 02 | **wp-config.php** | Secret keys, debug mode, table prefix, DISALLOW_FILE_EDIT, FORCE_SSL_ADMIN |
| 03 | **Core Integrity** | WP-CLI checksums, WordPress.org MD5 comparison, unexpected files in wp-includes |
| 04 | **Malware & Backdoors** | eval+base64, shell execution, known shell signatures, cryptominers, JS obfuscation, hex-named files, mu-plugins |
| 05 | **Recent Modifications** | PHP/JS files changed in last 7 days with timestamps |
| 06 | **WordPress Hardening** | Default 'admin' username, plugin/theme update status, inactive plugins, xmlrpc.php |
| 07 | **.htaccess** | Malicious handlers, auto_prepend injection, PHP blocking in uploads |
| 08 | **Database** | wp_options code injection, injected post content, unauthorized admins, SEO spam |
| 09 | **SSL & HTTP Headers** | HTTPS, HSTS, X-Frame-Options, X-Content-Type-Options, CSP, PHP exposure |
| 10 | **Login Security** | 2FA plugin detection, brute-force log evidence, xmlrpc.php |
| 11 | **Sensitive Files** | .env, .git, phpinfo.php, adminer.php, wp-config backups, SQL dumps, zip archives |
| 12 | **Plugins & Themes** | Suspicious code in plugin/theme files, high-risk plugins, nulled/pirated indicators |

---

## Severity levels

| Level | Meaning |
|-------|---------|
| `[CRITICAL]` | Active exploit or confirmed malware present — act immediately |
| `[HIGH]` | Significant vulnerability or misconfiguration — fix before next deployment |
| `[WARN]` | Security best practice not followed — plan remediation |
| `[INFO]` | Contextual information — no action required |
| `[OK]` | Check passed |

---

## Installation

**1. Copy the script to your server**

```bash
# From your local machine
scp wp-security-audit.sh root@yourserver:/root/wpsecurity/

# Or create it directly on the server
mkdir -p ~/wpsecurity && cd ~/wpsecurity
nano wp-security-audit.sh   # paste contents, save
```

**2. Make it executable**

```bash
chmod +x wp-security-audit.sh
```

**3. Run it**

```bash
sudo bash wp-security-audit.sh /path/to/wordpress/
```

---

## Usage

```
sudo bash wp-security-audit.sh <wordpress-path> [options]
```

| Flag | Description |
|------|-------------|
| *(none)* | Standard scan — wp-content and root-level files |
| `--full` | Deep scan — includes wp-admin and wp-includes directories |
| `--verbose` | Print every finding to terminal as it runs (no spinner UI) |
| `--help` | Show usage information |

**Examples:**

```bash
# Standard scan
sudo bash wp-security-audit.sh /var/www/html/mysite

# Full deep scan
sudo bash wp-security-audit.sh /home/user/public_html --full

# Verbose output (useful for piping to a log)
sudo bash wp-security-audit.sh /var/www/wordpress --verbose

# Weekly cron — silent, log to file
# Add to /etc/cron.weekly/wp-audit
sudo bash /root/wpsecurity/wp-security-audit.sh /home/mysite/htdocs/ --verbose \
  > /var/log/wp-audit.log 2>&1
```

---

## Report output

Every run saves a timestamped plain-text report to the current directory:

```
wp-audit-20260331_143021.txt
```

Sample report excerpt:

```
================================================================
 WordPress Security Audit Report
 Generated : 2026-03-31 14:30:21 UTC
 Host      : lotus.myserver.com
 Scan Path : /home/mysite/htdocs/mysite.com
 Mode      : Standard
================================================================

## Malware & Code Injection
────────────────────────────────────────────────────────────────

  [CRITICAL] Dangerous PHP patterns in 3 file(s):
             └─ /home/mysite/htdocs/wp-content/uploads/2024/cache.php
             └─ /home/mysite/htdocs/wp-content/mu-plugins/updater.php
             └─ /home/mysite/htdocs/wp-content/plugins/contact-form-7/includes/helper.php

  [CRITICAL] Known backdoor signatures in 1 file(s):
             └─ /home/mysite/htdocs/wp-content/mu-plugins/updater.php

  [OK]       No suspicious JS obfuscation found
  [OK]       No suspiciously named PHP files

  [WARN]     mu-plugins has 1 PHP file(s) — auto-loaded, verify:
             └─ /home/mysite/htdocs/wp-content/mu-plugins/updater.php

## Database Security
────────────────────────────────────────────────────────────────

  [INFO]     DB: mysite_wp @ localhost
  [OK]       Database connection successful
  [OK]       No malicious code in wp_options
  [OK]       No injected scripts in posts
  [OK]       No SEO spam in options

================================================================
 SUMMARY
================================================================
 Duration:    52s
 WordPress:   6.4.3
 PHP:         8.2.18

 CRITICAL:    3
 HIGH:        1
 WARN:        4
 INFO:        9

 REMEDIATION STEPS
 1.  Update WP core, all plugins and themes immediately
 2.  Remove PHP files from wp-content/uploads/
 3.  Replace modified core files with fresh WP download
 4.  Change all admin passwords + DB password
 5.  Regenerate secret keys: https://api.wordpress.org/secret-key/1.1/salt/
 6.  chmod 640 wp-config.php
 7.  Add: define('DISALLOW_FILE_EDIT', true); to wp-config.php
 8.  Block PHP in uploads/ with .htaccess
 9.  Remove readme.html, license.txt, xmlrpc.php
 10. Add HSTS, X-Frame-Options, X-Content-Type-Options headers
 11. Enable 2FA for all admin accounts
 12. Delete .env, .git, phpinfo.php, adminer.php from web root
 13. Review all administrator accounts in DB
 14. If malware found: rotate ALL credentials, scan DB
================================================================
```

---

## Optional enhancements

### WP-CLI (strongly recommended)

Unlocks: live plugin/theme update status, core verify-checksums, admin user enumeration, inactive plugin count.

```bash
curl -sO https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
chmod +x wp-cli.phar
sudo mv wp-cli.phar /usr/local/bin/wp
```

### MySQL client

Unlocks: live database scanning (wp_options, wp_posts, wp_users).

```bash
# Debian/Ubuntu
sudo apt install mysql-client -y

# CentOS/AlmaLinux
sudo yum install mysql -y
```

### curl

Unlocks: SSL/header checks and WordPress.org checksum fetching.

```bash
sudo apt install curl -y   # Debian/Ubuntu
sudo yum install curl -y   # CentOS/AlmaLinux
```

> All three are optional. Without them, the relevant checks are skipped and the rest of the scan runs normally.

---

## Compatibility

| Component | Requirement |
|-----------|-------------|
| WordPress | 2.x through 6.x and beyond |
| Bash | 3.x and above (no associative arrays used) |
| OS | Ubuntu 18+, Debian 10+, CentOS 7+, AlmaLinux 8+ |
| PHP | 5.6 through 8.x (for the `php` CLI) |
| Privileges | Recommended: `sudo` or root |
| WP-CLI | Optional — enhanced checks |
| MySQL client | Optional — database checks |
| curl | Optional — remote checks, SSL headers |

---

## How findings compare to known attacks

The malware patterns and checks in this script are based on real WordPress attack campaigns documented by Sucuri, Wordfence, Patchstack, and MalCare research published between 2024–2026, including:

- **eval+base64 PHP droppers** — the most common obfuscation method for injecting payloads
- **mu-plugins backdoors** — attackers place PHP in `wp-content/mu-plugins/` because files there auto-load without appearing in the plugin list
- **Uploaded webshells** — PHP files placed inside `wp-content/uploads/` after a file upload vulnerability exploit
- **Fake admin accounts** — hidden administrator accounts created by backdoors to maintain persistent access
- **wp_options injection** — malicious code stored in autoloaded database options, surviving file cleanup
- **SEO spam injection** — pharmaceutical and casino keywords injected into posts or options for blackhat SEO
- **Cryptominer injection** — CoinHive, CryptoLoot and similar scripts injected into theme files

---

## What this script does not do

- It does **not** modify or delete any files
- It does **not** make any outbound connections except to `api.wordpress.org` for core checksums (optional)
- It does **not** send data anywhere
- It does **not** fix issues automatically — it reports and you decide

---

## Contributing

Pull requests are welcome. If you have a new malware pattern, a check for a recently disclosed vulnerability, or a compatibility fix, open a PR with a brief description of what it catches and why.

**Adding a new pattern:**

```bash
# Patterns go inside check_malware() — one grep per pattern group
grep -rlP 'your_new_pattern_here' \
    --include="*.php" "$sdir" 2>/dev/null >> "$p1" || true
```

---

## License

MIT — do whatever you want with it, just don't sell it as your own product.

---

<div align="center">

Built for self-hosted WordPress environments running on Proxmox, CloudPanel, Hetzner, and similar setups.

**[Download the script](wp-security-audit.sh)** · **[View HTML docs](README.html)** · [Open an issue](../../issues)

<br>

</div>
# wp-security-audit

# Disclaimer

[简体中文](DISCLAIMER.md) | **English**

**Read this before you proceed. This project exposes you to real risk.**

---

## 1. Device risk: three kinds of "brick"

What people call "bricking" is actually three different outcomes with wildly different recovery costs:

| Level | Symptom | Recoverable | Cost |
|---|---|---|---|
| **Soft brick** | Won't boot, but fastboot / recovery works | Yes | Restore the backup, minutes |
| **Hard brick** | fastboot unreachable, only EDL / 9008 | Yes, but painful | License or disassembly, **all data lost** |
| **Permanent damage** | Even EDL can't help | **No** | Motherboard replacement |

### What causes permanent damage

- **Flashing a kernel or firmware below your device's anti-rollback (ARB) version.**
  Some Xiaomi, OPPO and Samsung devices keep an ARB counter — flashing lower burns an
  eFuse, **irreversibly**. **Confirm your kernel version is ≥ the current system version
  before flashing.**
- Writing to the wrong partition table or into the bootloader partition.
- Using sketchy third-party unlock services (scams, or worse — backdoors).

### The reality of EDL / 9008

- Xiaomi devices from 2020 on **require an authorized account** to enter 9008. Paid
  third-party unlocks are unreliable.
- Some models require **removing the back cover and shorting test points**.
- Flashing in EDL **always wipes all data**.

### Other device risks

- Unlocking the bootloader **erases all data** and **may permanently void your warranty**.
- OEM unlock policies change over time. After unlocking, OTA updates, payment app risk checks,
  and some system features (Find My Device, cloud services) may stop working.
- A miscompiled or mispackaged kernel can break the **baseband, Wi-Fi, or camera**.

## 2. Data risk

- Container data lives in `/data/docker`, **on the same partition as Android itself**.
  Filling that partition breaks the system: no camera, no app installs, potentially no boot.
- This project provides **no backup mechanism**. Container removal, image pruning, and
  `docker system prune` are irreversible. Back up anything important yourself.
- `start.sh` calls `setenforce 0`, modifies iptables, and mounts/unmounts filesystems.
  An unclean exit (power loss, forced reboot) can leave inconsistent state that requires
  manual cleanup.

## 3. Security risk

- **`setenforce 0` switches SELinux from Enforcing to Permissive.**
  Android's mandatory access control stops being enforced. Malicious apps find it easier
  to escalate privileges, read other apps' data, and access hardware without authorization.
  **This is the single biggest cost of this project — not a temporary inconvenience.**
- Containers run as **root** and their processes are **not constrained by the Android sandbox**.
  Do not run images from untrusted sources. Do not mount `/data` or `/data/adb` into
  containers you don't fully trust.
- Ports exposed to the LAN (8080, 5244, …) can be reached by any device on the same network
  if misconfigured. **Never expose Docker ports to the public internet.** SMB on 445 is
  especially dangerous (it is a primary target for ransomware).
- Use this on a **dedicated test device**. Do not do this on the phone holding your primary
  accounts, work files, or family photos.

## 4. Hardware risk

- Phones are not built for 24/7 operation. Continuous charging accelerates battery aging,
  and **third-party batteries have a significantly higher swelling risk** than OEM cells.
- For long-running setups, cap the charge level (around 80%) and periodically check the
  battery: run a finger over the back where the cell sits, and stand the phone on a flat
  surface — if it rocks or bulges, stop using it immediately.
- Sustained high temperatures can damage the display and mainboard solder joints.
  Provide airflow and avoid direct sunlight.

## 5. Legal and compliance

### 5.1 Warranty and ownership

- Unlocking the bootloader typically **violates the manufacturer's warranty terms**. Even
  after restoring the stock image, the unlock record often persists on vendor servers
  (Xiaomi exposes an unlock-status API) and **can be used to deny service**.
- Some jurisdictions (e.g. the U.S. Magnuson-Moss Warranty Act) prevent manufacturers from
  voiding a warranty merely because the user repaired the device — but they may still deny
  claims if the damage was caused by the user. **This does not apply everywhere**; in many
  markets the vendor terms simply state "unlocking voids warranty".
- Unlocking a carrier-locked device may **breach your carrier contract** and incur penalties.

### 5.2 Liability as a service provider

- If you expose services built on this project **to the public**, you become a service
  provider and take on the associated obligations:
  - In mainland China: Cybersecurity Law, Data Security Law, Personal Information
    Protection Law; public-facing internet services generally also require ICP filing
    and public security filing.
  - Storing other people's data makes you a personal-information handler (notice, consent,
    data minimisation, cross-border transfer restrictions).
  - Do not use it to distribute illegal content, infringe copyright, or host gambling,
    fraud, or adult platforms.
- **Never expose SMB (445) or database ports to the internet.** If an intrusion exposes
  other people's data, the operator is responsible.

### 5.3 Technical protection measures

- In some jurisdictions, bypassing the bootloader lock may be treated as circumventing a
  technical protection measure (e.g. U.S. DMCA §1201 — exemptions exist, but the boundaries
  are complicated).
- This project **ships no unlock tools** and does not encourage bypassing vendor security.
  You are responsible for confirming that unlocking your own device is lawful where you live.

### 5.4 Resale and contractual constraints

- When reselling an unlocked or rooted device you **must disclose it**. Concealment can
  constitute fraud.
- Some corporate purchase agreements, insurance policies, and lease contracts **prohibit
  unlocked or rooted devices**; violating them may be a breach of contract.

### 5.5 Corporate and institutional environments

- Operating on a company-issued device may **violate your organisation's security policy**
  and can trigger an internal audit.
- Connecting to a corporate network (especially with container ports open) may violate
  **network admission policies**.
- Note that this project's security model (SELinux disabled, containers as root) **does not
  satisfy most enterprise compliance frameworks** (ISO 27001, SOC 2, PCI DSS, and similar).

### 5.6 Minors

- Minors must have **guardian consent**. The guardian bears the consequences of a bricked
  device or lost data.

### 5.7 Prohibited uses

**Do not** use this project to:

- operate on any device you do not own
- circumvent DRM or copyright protection
- run a public-facing service without the required filings or licences
- violate anyone's privacy or damage anyone's systems
- mine cryptocurrency (phone compute is negligible and sustained load damages hardware)

**This project is for learning, research, and personal testing. Follow the laws of your
jurisdiction.**

## 6. Open-source licence obligations (commonly missed)

This project's own code is MIT, but **not everything it depends on is**:

| Component | Licence | Your obligation |
|---|---|---|
| This project's scripts | MIT | Keep the copyright notice |
| **Linux kernel** | **GPLv2** | **Distributing a modified build requires providing the complete corresponding source** |
| Docker / containerd | Apache 2.0 | Keep NOTICE and licence files |
| **Magisk** | **GPLv3** | Distributing a modified Magisk requires publishing the source |

**The one people trip over**: if you compile a kernel following
[docs/kernel.en.md](docs/kernel.en.md) and then share the resulting `boot.img`
(on a forum, a cloud drive, a group chat), **you must also provide the modified kernel
source** — or a written offer to supply it. **Shipping the binary alone violates GPLv2.**

This is not hypothetical. Kernel developers have litigated GPL source obligations before,
and "here's a build, no source" has been a long-standing problem in the ROM community.

**Don't want that obligation? Use it on your own device only and don't distribute builds.**

## 7. No warranty

Provided under the **MIT License**, **without warranty of any kind**, express or implied,
including but not limited to the warranties of merchantability, fitness for a particular
purpose, title, and non-infringement.

**The authors and contributors accept no liability for:**

- device damage, bricking, or hardware failure
- data loss, account compromise, or privacy leakage
- voided warranty or refused service by the manufacturer
- security incidents (intrusion, cryptomining, ransomware)
- legal disputes or regulatory penalties
- any **direct, indirect, incidental, special, or consequential damages** arising from the
  use or inability to use this project

**By using this project you confirm that you have read, understood, and accepted all of the
above, and that you take full responsibility for the consequences. If you disagree with any
part of it, do not use this project.**

---

## Issues and support

- Technical issues are welcome, but **no response time or resolution is guaranteed**.
- Problems caused by not reading this document or not following the documentation may not
  receive a reply.
- Before asking, check [docs/troubleshooting.md](docs/troubleshooting.md) and include the
  diagnostic information described there.

---

*Last updated: 2026-11-15*

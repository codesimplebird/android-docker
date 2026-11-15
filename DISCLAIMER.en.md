# Disclaimer

[简体中文](DISCLAIMER.md) | **English**

**Read this before you proceed. This project exposes you to real risk.**

---

## 1. Device risk

- Flashing a custom kernel **can brick your device**. Recovery may require fastboot-restoring
  the stock image, or — in the worst case — EDL / 9008 mode, which on some models means
  opening the phone and shorting test points.
- Unlocking the bootloader **erases all data** on the device and **may permanently void your warranty**.
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

- Unlocking the bootloader and rooting may **violate local regulations or carrier terms**
  and can affect warranty and resale value.
- This project is for **learning, research, and personal testing**. Follow the laws of your
  jurisdiction.
- **Do not** use this project to:
  - operate on any device you do not own
  - circumvent DRM or copyright protection
  - run a public-facing commercial service without the required registration or licensing
  - violate anyone's privacy or damage anyone's systems

## 6. No warranty

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
